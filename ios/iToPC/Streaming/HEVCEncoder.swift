import CoreMedia
import Foundation
import VideoToolbox

enum HEVCEncoderError: LocalizedError {
    case creationFailed(OSStatus)
    case propertyFailed(CFString, OSStatus)
    case prepareFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let status):
            return "HEVCハードウェアエンコーダを作成できません (\(status))。"
        case .propertyFailed(let key, let status):
            return "エンコーダ設定 \(key) に失敗しました (\(status))。"
        case .prepareFailed(let status):
            return "HEVCエンコーダを開始できません (\(status))。"
        }
    }
}

final class HEVCEncoder {
    var onEncodedFrame: ((Data, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "local.itopc.encoder", qos: .userInteractive)
    private let outstandingFramesLock = NSLock()
    private let maximumOutstandingFrames = 2
    private var session: VTCompressionSession?
    private var fps: Int32 = 60
    private var forceNextKeyFrame = true
    private var outstandingFrames = 0

    func configure(
        width: Int32,
        height: Int32,
        fps: Int32,
        bitrate: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureLocked(width: width, height: height, fps: fps, bitrate: bitrate)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard reserveFrame() else { return }

        queue.async { [weak self] in
            guard
                let self,
                let session = self.session,
                let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else {
                self?.releaseFrame()
                return
            }

            var infoFlags = VTEncodeInfoFlags()
            let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMTime(value: 1, timescale: self.fps)

            let frameProperties: CFDictionary?
            if self.forceNextKeyFrame {
                frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                self.forceNextKeyFrame = false
            } else {
                frameProperties = nil
            }

            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration,
                frameProperties: frameProperties,
                sourceFrameRefcon: nil,
                infoFlagsOut: &infoFlags
            )
            if status != noErr {
                self.releaseFrame()
                self.reportError(HEVCEncoderError.creationFailed(status))
            }
        }
    }

    func requestKeyFrame() {
        queue.async { [weak self] in self?.forceNextKeyFrame = true }
    }

    func invalidate() {
        queue.sync { [weak self] in
            guard let self else { return }
            if let session = self.session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            self.session = nil
            self.forceNextKeyFrame = true
            self.resetOutstandingFrames()
        }
    }

    private func configureLocked(width: Int32, height: Int32, fps: Int32, bitrate: Int) throws {
        if let oldSession = session {
            VTCompressionSessionInvalidate(oldSession)
            session = nil
        }

        let encoderSpecification: CFDictionary?
        if #available(iOS 17.4, *) {
            encoderSpecification = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ] as CFDictionary
        } else {
            // These specification keys are unavailable before iOS 17.4. HEVC encoding on
            // supported iPhones still uses VideoToolbox's native hardware encoder.
            encoderSpecification = nil
        }

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: hevcCompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw HEVCEncoderError.creationFailed(status)
        }
        session = newSession
        self.fps = fps
        forceNextKeyFrame = true

        try set(kVTCompressionPropertyKey_RealTime, value: true, on: newSession)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, value: false, on: newSession)
        // Some older hardware does not expose this optional low-latency hint.
        // The explicit two-frame admission limit above remains the fallback.
        try? set(kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1, on: newSession)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: fps, on: newSession)
        try set(kVTCompressionPropertyKey_AverageBitRate, value: bitrate, on: newSession)
        try set(kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8, 1], on: newSession)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: max(1, fps / 4), on: newSession)
        try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 0.25, on: newSession)
        try set(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel, on: newSession)

        if #available(iOS 15.0, *) {
            try set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: true, on: newSession)
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(newSession)
        guard prepareStatus == noErr else {
            throw HEVCEncoderError.prepareFailed(prepareStatus)
        }
    }

    private func set(_ key: CFString, value: Any, on session: VTCompressionSession) throws {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        guard status == noErr else { throw HEVCEncoderError.propertyFailed(key, status) }
    }

    fileprivate func receiveEncodedSample(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        releaseFrame()
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
            if status != noErr { reportError(HEVCEncoderError.creationFailed(status)) }
            return
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        do {
            let annexB = try AnnexBConverter.convert(
                sampleBuffer: sampleBuffer,
                includeParameterSets: isKeyFrame
            )
            onEncodedFrame?(annexB, isKeyFrame)
        } catch {
            reportError(error)
        }
    }

    private func reportError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    private func reserveFrame() -> Bool {
        outstandingFramesLock.lock()
        defer { outstandingFramesLock.unlock() }
        guard outstandingFrames < maximumOutstandingFrames else { return false }
        outstandingFrames += 1
        return true
    }

    private func releaseFrame() {
        outstandingFramesLock.lock()
        outstandingFrames = max(0, outstandingFrames - 1)
        outstandingFramesLock.unlock()
    }

    private func resetOutstandingFrames() {
        outstandingFramesLock.lock()
        outstandingFrames = 0
        outstandingFramesLock.unlock()
    }
}

private let hevcCompressionOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    _,
    sampleBuffer in
    guard let outputCallbackRefCon else { return }
    let encoder = Unmanaged<HEVCEncoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    encoder.receiveEncodedSample(status: status, sampleBuffer: sampleBuffer)
}
