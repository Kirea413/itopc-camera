import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct CaptureRequest {
    let width: Int32
    let height: Int32
    let fps: Int32
}

struct CaptureConfiguration {
    let width: Int32
    let height: Int32
    let fps: Int32
}

protocol CameraCaptureDelegate: AnyObject {
    func cameraCapture(_ capture: CameraCapture, didOutput sampleBuffer: CMSampleBuffer)
}

enum CameraCaptureError: LocalizedError {
    case cameraUnavailable
    case permissionDenied
    case inputCreationFailed(Error)
    case noCompatibleFormat
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "背面カメラを取得できません。"
        case .permissionDenied:
            return "カメラの使用が許可されていません。設定アプリでiToPCのカメラ権限を有効にしてください。"
        case .inputCreationFailed(let error):
            return "カメラ入力を作成できません: \(error.localizedDescription)"
        case .noCompatibleFormat:
            return "利用できるカメラ形式が見つかりません。"
        case .cannotAddInput:
            return "カメラ入力をセッションへ追加できません。"
        case .cannotAddOutput:
            return "映像出力をセッションへ追加できません。"
        }
    }
}

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    weak var delegate: CameraCaptureDelegate?

    private let sessionQueue = DispatchQueue(label: "local.itopc.capture.session", qos: .userInteractive)
    private let videoQueue = DispatchQueue(label: "local.itopc.capture.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var isConfigured = false

    func discoverSupportedPresets(completion: @escaping ([StreamPreset]) -> Void) {
        sessionQueue.async {
            let presets: [StreamPreset]
            if let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) {
                presets = StreamPreset.allCases.filter { preset in
                    device.formats.contains { format in
                        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        guard dimensions.width == preset.width,
                              dimensions.height == preset.height else { return false }
                        return format.videoSupportedFrameRateRanges.contains { range in
                            range.minFrameRate <= Double(preset.fps) &&
                                range.maxFrameRate >= Double(preset.fps)
                        }
                    }
                }
            } else {
                presets = []
            }
            DispatchQueue.main.async { completion(presets) }
        }
    }

    func configure(
        request: CaptureRequest,
        completion: @escaping (Result<CaptureConfiguration, Error>) -> Void
    ) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAuthorized(request: request, completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    DispatchQueue.main.async { completion(.failure(CameraCaptureError.permissionDenied)) }
                    return
                }
                self?.configureAuthorized(request: request, completion: completion)
            }
        default:
            DispatchQueue.main.async { completion(.failure(CameraCaptureError.permissionDenied)) }
        }
    }

    private func configureAuthorized(
        request: CaptureRequest,
        completion: @escaping (Result<CaptureConfiguration, Error>) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                let configuration = try self.configureLocked(request: request)
                DispatchQueue.main.async { completion(.success(configuration)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureLocked(request: CaptureRequest) throws -> CaptureConfiguration {
        if isConfigured {
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
            isConfigured = false
        }

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CameraCaptureError.cameraUnavailable
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraCaptureError.inputCreationFailed(error)
        }

        let choice = try chooseFormat(device: device, request: request)

        try device.lockForConfiguration()
        device.activeFormat = choice.format
        let frameDuration = CMTime(value: 1, timescale: choice.fps)
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        device.unlockForConfiguration()

        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }

        session.commitConfiguration()
        isConfigured = true

        let dimensions = CMVideoFormatDescriptionGetDimensions(choice.format.formatDescription)
        return CaptureConfiguration(width: dimensions.width, height: dimensions.height, fps: choice.fps)
    }

    private func chooseFormat(
        device: AVCaptureDevice,
        request: CaptureRequest
    ) throws -> (format: AVCaptureDevice.Format, fps: Int32) {
        guard let format = device.formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == request.width,
                  dimensions.height == request.height else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= Double(request.fps) &&
                    range.maxFrameRate >= Double(request.fps)
            }
        }) else {
            throw CameraCaptureError.noCompatibleFormat
        }
        return (format, request.fps)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        delegate?.cameraCapture(self, didOutput: sampleBuffer)
    }
}
