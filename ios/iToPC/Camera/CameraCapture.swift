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
    case inputCreationFailed(Error)
    case noCompatibleFormat
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "背面カメラを取得できません。"
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

    func configure(
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
        let fallbackTargets: [(Int32, Int32, Int32)] = request.width >= 3840
            ? [
                (3840, 2160, request.fps),
                (3840, 2160, min(request.fps, 60)),
                (3840, 2160, 30),
                (1920, 1080, request.fps),
                (1920, 1080, min(request.fps, 60)),
                (1920, 1080, 30)
            ]
            : [
                (1920, 1080, request.fps),
                (1920, 1080, min(request.fps, 60)),
                (1920, 1080, 30)
            ]

        for target in fallbackTargets {
            if let format = device.formats.first(where: { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dimensions.width == target.0, dimensions.height == target.1 else { return false }
                return format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= Double(target.2) && range.maxFrameRate >= Double(target.2)
                }
            }) {
                return (format, target.2)
            }
        }

        guard let best = device.formats.max(by: { lhs, rhs in
            let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let leftPixels = Int64(left.width) * Int64(left.height)
            let rightPixels = Int64(right.width) * Int64(right.height)
            if leftPixels == rightPixels {
                return (lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
                    < (rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            }
            return leftPixels < rightPixels
        }), let range = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            throw CameraCaptureError.noCompatibleFormat
        }

        let fps = Int32(min(Double(request.fps), range.maxFrameRate).rounded(.down))
        guard fps > 0 else { throw CameraCaptureError.noCompatibleFormat }
        return (best, fps)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        delegate?.cameraCapture(self, didOutput: sampleBuffer)
    }
}
