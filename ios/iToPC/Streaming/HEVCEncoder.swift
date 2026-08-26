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
    private var session: VTCompressionSession?
    private var fps: Int32 = 60
    private var forceNextKeyFrame = true

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
        queue.async { [weak self] in
            guard
                let self,
                let session = self.session,
                let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }

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
        }
    }

    private func configureLocked(width: Int32, height: Int32, fps: Int32, bitrate: Int) throws {
        if let oldSession = session {
            VTCompressionSessionInvalidate(oldSession)
            session = nil
        }

        let encoderSpecification: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary

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
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: fps, on: newSession)
        try set(kVTCompressionPropertyKey_AverageBitRate, value: bitrate, on: newSession)
        try set(kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8, 1], on: newSession)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: max(1, fps / 2), on: newSession)
        try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 0.5, on: newSession)
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
