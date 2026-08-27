import AVFoundation
import Combine
import Foundation
import UIKit
import VideoToolbox

final class CameraStreamer: ObservableObject, CameraCaptureDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var isClientConnected = false
    @Published private(set) var statusText = "停止中"
    @Published private(set) var actualFormatText: String?
    @Published private(set) var supportedPresets: [StreamPreset] = []
    @Published private(set) var isDetectingPresets = true
    @Published var isShowingError = false
    @Published private(set) var errorText: String?

    let wifiAddress = NetworkAddress.wifiIPv4
    var captureSession: AVCaptureSession { capture.session }

    private let capture = CameraCapture()
    private let encoder = HEVCEncoder()
    private let server = StreamServer()
    private var runID = UUID()
    private var attemptedEncoderFormats = Set<String>()

    init() {
        capture.delegate = self
        encoder.onEncodedFrame = { [weak server = self.server] data, isKeyFrame in
            server?.send(data, isKeyFrame: isKeyFrame)
        }
        encoder.onError = { [weak self] error in
            guard let self, self.isRunning else { return }
            self.failAndStop(error)
        }
        server.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            self.isClientConnected = connected
            self.statusText = connected ? "PC接続中" : (self.isRunning ? "PC待機中 :5000" : "停止中")
        }
        server.onNeedsKeyFrame = { [weak encoder = self.encoder] in encoder?.requestKeyFrame() }
        server.onError = { [weak self] error in
            guard let self, self.isRunning else { return }
            self.errorText = "転送エラー: \(error.localizedDescription)"
        }
        refreshSupportedPresets()
    }

    func start(preset: StreamPreset) {
        guard !isRunning else { return }
        guard supportedPresets.contains(preset) else {
            show(CameraCaptureError.noCompatibleFormat)
            return
        }
        isRunning = true
        statusText = "カメラ準備中"
        errorText = nil
        actualFormatText = nil
        attemptedEncoderFormats.removeAll(keepingCapacity: true)
        let currentRunID = UUID()
        runID = currentRunID
        UIApplication.shared.isIdleTimerDisabled = true

        attemptStart(presets: fallbackPresets(startingAt: preset), runID: currentRunID)
    }

    private func attemptStart(presets: [StreamPreset], runID: UUID) {
        guard isRunning, self.runID == runID, let preset = presets.first else {
            if isRunning, self.runID == runID {
                failAndStop(HEVCEncoderError.creationFailed(kVTVideoEncoderNotAvailableNowErr))
            }
            return
        }

        statusText = "\(preset.rawValue) を準備中"
        let remainingPresets = Array(presets.dropFirst())
        let request = CaptureRequest(width: preset.width, height: preset.height, fps: preset.fps)
        capture.configure(request: request) { [weak self] result in
            guard let self, self.isRunning, self.runID == runID else { return }
            switch result {
            case .failure(let error):
                self.failAndStop(error)
            case .success(let configuration):
                let signature = "\(configuration.width)x\(configuration.height)x\(configuration.fps)"
                if self.attemptedEncoderFormats.contains(signature) {
                    self.attemptStart(presets: remainingPresets, runID: runID)
                    return
                }
                self.attemptedEncoderFormats.insert(signature)

                let scaledBitrate = self.scaledBitrate(
                    base: preset.bitrate,
                    requested: request,
                    actual: configuration
                )
                self.encoder.configure(
                    width: configuration.width,
                    height: configuration.height,
                    fps: configuration.fps,
                    bitrate: scaledBitrate
                ) { [weak self] encoderResult in
                    guard let self, self.isRunning, self.runID == runID else { return }
                    switch encoderResult {
                    case .failure(let error):
                        if remainingPresets.isEmpty {
                            self.failAndStop(error)
                        } else {
                            self.encoder.invalidate()
                            self.errorText = "\(signature)のHEVCエンコードを開始できないため、次の形式を試します。"
                            self.attemptStart(presets: remainingPresets, runID: runID)
                        }
                    case .success:
                        self.actualFormatText = "\(configuration.width)×\(configuration.height) / \(configuration.fps)fps"
                        self.server.start()
                        self.capture.start()
                        self.statusText = "PC待機中 :5000"
                    }
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        runID = UUID()
        capture.stop()
        server.stop()
        encoder.invalidate()
        isRunning = false
        isClientConnected = false
        statusText = "停止中"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func fallbackPresets(startingAt preset: StreamPreset) -> [StreamPreset] {
        let candidates: [StreamPreset]
        switch preset {
        case .ultra:
            candidates = [.ultra, .high, .fast, .balanced]
        case .high:
            candidates = [.high, .balanced]
        case .fast:
            candidates = [.fast, .balanced]
        case .balanced:
            candidates = [.balanced]
        }
        return candidates.filter(supportedPresets.contains)
    }

    private func refreshSupportedPresets() {
        capture.discoverSupportedPresets { [weak self] presets in
            guard let self else { return }
            self.supportedPresets = presets
            self.isDetectingPresets = false
            if presets.isEmpty {
                self.statusText = "対応するカメラ形式なし"
            }
        }
    }

    func cameraCapture(_ capture: CameraCapture, didOutput sampleBuffer: CMSampleBuffer) {
        encoder.encode(sampleBuffer)
    }

    private func scaledBitrate(
        base: Int,
        requested: CaptureRequest,
        actual: CaptureConfiguration
    ) -> Int {
        let requestedLoad = Double(requested.width) * Double(requested.height) * Double(requested.fps)
        let actualLoad = Double(actual.width) * Double(actual.height) * Double(actual.fps)
        guard requestedLoad > 0 else { return base }
        return max(12_000_000, Int(Double(base) * actualLoad / requestedLoad))
    }

    private func failAndStop(_ error: Error) {
        show(error)
        stop()
    }

    private func show(_ error: Error) {
        errorText = error.localizedDescription
        isShowingError = true
    }
}
