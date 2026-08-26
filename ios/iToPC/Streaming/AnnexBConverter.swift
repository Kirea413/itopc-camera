import CoreMedia
import Foundation

enum AnnexBConverterError: LocalizedError {
    case missingFormatDescription
    case missingDataBuffer
    case invalidNALLength
    case parameterSetReadFailed(OSStatus)
    case blockBufferReadFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingFormatDescription:
            return "HEVCフォーマット情報がありません。"
        case .missingDataBuffer:
            return "エンコード済み映像データがありません。"
        case .invalidNALLength:
            return "HEVC NALユニットの長さが不正です。"
        case .parameterSetReadFailed(let status):
            return "HEVCパラメータセットの取得に失敗しました (\(status))。"
        case .blockBufferReadFailed(let status):
            return "HEVCデータの読み出しに失敗しました (\(status))。"
        }
    }
}

enum AnnexBConverter {
    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    static func convert(sampleBuffer: CMSampleBuffer, includeParameterSets: Bool) throws -> Data {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AnnexBConverterError.missingFormatDescription
        }

        var parameterSetCount = 0
        var nalLengthFieldSize: Int32 = 0
        var firstParameterPointer: UnsafePointer<UInt8>?
        var firstParameterSize = 0

        let parameterStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &firstParameterPointer,
            parameterSetSizeOut: &firstParameterSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalLengthFieldSize
        )
        guard parameterStatus == noErr else {
            throw AnnexBConverterError.parameterSetReadFailed(parameterStatus)
        }
        guard (1...4).contains(nalLengthFieldSize) else {
            throw AnnexBConverterError.invalidNALLength
        }

        var output = Data()
        if includeParameterSets {
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let pointer else {
                    throw AnnexBConverterError.parameterSetReadFailed(status)
                }
                output.append(startCode)
                output.append(pointer, count: size)
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw AnnexBConverterError.missingDataBuffer
        }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return output }
        var bytes = Data(count: totalLength)
        let copyStatus: OSStatus = bytes.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw AnnexBConverterError.blockBufferReadFailed(copyStatus)
        }

        var offset = 0
        let lengthSize = Int(nalLengthFieldSize)
        while offset + lengthSize <= bytes.count {
            var nalLength = 0
            for byte in bytes[offset..<(offset + lengthSize)] {
                nalLength = (nalLength << 8) | Int(byte)
            }
            offset += lengthSize
            guard nalLength > 0, offset + nalLength <= bytes.count else {
                throw AnnexBConverterError.invalidNALLength
            }
            output.append(startCode)
            output.append(bytes[offset..<(offset + nalLength)])
            offset += nalLength
        }

        guard offset == bytes.count else {
            throw AnnexBConverterError.invalidNALLength
        }
        return output
    }
}
