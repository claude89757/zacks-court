import Foundation
import AVFoundation
import VideoToolbox

public struct EncodedFrame {
    public let packet: StreamPacket
    public let sample: CMSampleBuffer
}

private final class FrameContext {
    let sequence: UInt64
    let captureDrops: UInt64
    let transportDrops: UInt64
    let captureMetadata: CaptureFrameMetadata?
    let captureMetadataOmissionReason: CaptureFrameMetadata.OmissionReason?
    init(_ sequence: UInt64, _ captureDrops: UInt64, _ transportDrops: UInt64, captureMetadata: CaptureFrameMetadata?, omissionReason: CaptureFrameMetadata.OmissionReason?) {
        self.sequence = sequence; self.captureDrops = captureDrops; self.transportDrops = transportDrops
        self.captureMetadata = captureMetadata; self.captureMetadataOmissionReason = omissionReason
    }
}

public final class H264Encoder {
    public let streamID: UUID
    public var onFrame: ((EncodedFrame) -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var hardwareAccelerated = false
    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let fps: Int
    private var sequence: UInt64 = 0
    private let kind: String

    /// `kind` labels emitted packets: "video" for the local recording log, "preview" for the wire.
    public init(width: Int, height: Int, fps: Int, bitrate: Int = 8_000_000, kind: String = "video",
                keyframeInterval: Double = 1, streamID: UUID = UUID()) throws {
        self.width = width; self.height = height; self.fps = fps; self.kind = kind; self.streamID = streamID
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { reference, frameReference, status, _, sample in
                guard let reference else { return }
                let encoder = Unmanaged<H264Encoder>.fromOpaque(reference).takeUnretainedValue()
                let context = frameReference.map { Unmanaged<FrameContext>.fromOpaque($0).takeRetainedValue() }
                guard status == noErr, let sample, let context else {
                    if status != noErr { encoder.onError?("视频编码失败：\(status)") }; return
                }
                do { try encoder.output(sample, context: context) }
                catch { encoder.onError?(error.localizedDescription) }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { throw CourtError.message("无法启动 H.264 编码器：\(status)") }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: max(1, Int((Double(fps) * keyframeInterval).rounded())),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: keyframeInterval
        ]
        for (key, value) in properties {
            let code = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            guard code == noErr else { throw CourtError.message("编码参数设置失败：\(key) (\(code))") }
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else { throw CourtError.message("编码器准备失败：\(prepared)") }
        if #available(iOS 17.4, *) {
            let hardware = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
            hardware.initialize(to: nil)
            defer { hardware.deinitialize(count: 1); hardware.deallocate() }
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: nil, valueOut: UnsafeMutableRawPointer(hardware))
            hardwareAccelerated = (hardware.pointee as? NSNumber)?.boolValue ?? false
        }
    }

    public func encode(_ image: CVPixelBuffer, pts: CMTime, captureDrops: UInt64 = 0, transportDrops: UInt64 = 0, forceKeyframe: Bool = false, captureMetadata: CaptureFrameMetadata? = nil) {
        guard let session else { return }
        sequence += 1
        let omission = captureMetadata?.omissionReason(pts: pts, deliveredWidth: CVPixelBufferGetWidth(image),
            deliveredHeight: CVPixelBufferGetHeight(image), encoderWidth: width, encoderHeight: height)
        let context = Unmanaged.passRetained(FrameContext(sequence, captureDrops, transportDrops,
            captureMetadata: omission == nil ? captureMetadata : nil, omissionReason: omission))
        let properties: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: properties,
            sourceFrameRefcon: context.toOpaque(), infoFlagsOut: nil)
        if status != noErr { context.release(); onError?("无法编码这一帧：\(status)") }
    }

    public func finish() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session); self.session = nil
    }
    deinit { finish() }

    private func output(_ sample: CMSampleBuffer, context: FrameContext) throws {
        guard CMSampleBufferDataIsReady(sample), let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let size = CMBlockBufferGetDataLength(block)
        guard size > 0, size < PacketDecoder.maximumBody - PacketDecoder.maximumHeader else { throw CourtError.message("编码帧大小异常。") }
        var payload = Data(count: size)
        let copied = payload.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
        }
        guard copied == noErr else { throw CourtError.message("无法读取编码帧。") }
        var header = StreamHeader(kind: kind)
        header.streamID = streamID; header.sequence = context.sequence
        header.pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        header.duration = 1 / Double(fps); header.keyframe = keyframe
        header.width = width; header.height = height; header.fps = fps
        header.captureDrops = context.captureDrops; header.transportDrops = context.transportDrops
        header.captureMetadata = context.captureMetadata
        header.captureMetadataOmissionReason = context.captureMetadataOmissionReason
        if keyframe {
            header.parameterSets = try (0..<2).map { index in
                var pointer: UnsafePointer<UInt8>?; var length = 0; var count = 0; var nalLength: Int32 = 0
                let code = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &length, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
                guard code == noErr, let pointer, nalLength == 4 else { throw CourtError.message("不支持的 H.264 参数。") }
                return Data(bytes: pointer, count: length)
            }
        }
        onFrame?(EncodedFrame(packet: StreamPacket(header: header, payload: payload), sample: sample))
    }
}

/// Reconstructs compressed samples without inventing timestamps or interpolated frames.
public final class H264SampleAssembler {
    private var format: CMVideoFormatDescription?
    private var streamID: UUID?
    private var lastPTS: Double?
    private var lastSequence: UInt64?
    public init() {}
    public func reset() { format = nil; streamID = nil; lastPTS = nil; lastSequence = nil }

    public func sample(from packet: StreamPacket) throws -> CMSampleBuffer? {
        let h = packet.header
        guard h.kind == "video" || h.kind == "preview", let id = h.streamID, let pts = h.pts, pts.isFinite,
              pts >= 0, let duration = h.duration, duration.isFinite, duration > 0, duration <= 1,
              let sequence = h.sequence, !packet.payload.isEmpty, packet.payload.count < PacketDecoder.maximumBody else {
            throw CourtError.message("缺少视频时间信息。")
        }
        if streamID != id { reset(); streamID = id }
        if let lastPTS, pts <= lastPTS { throw CourtError.message("视频时间戳未递增。") }
        if let lastSequence, sequence != lastSequence &+ 1 {
            // Predictive compressed frames after a gap are unsafe until the next keyframe.
            format = nil
        }
        lastSequence = sequence; lastPTS = pts
        if h.keyframe == true, let sets = h.parameterSets {
            guard sets.count == 2, sets.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else {
                throw CourtError.message("缺少 H.264 参数集。")
            }
            let status = sets[0].withUnsafeBytes { first in sets[1].withUnsafeBytes { second in
                let pointers = [first.bindMemory(to: UInt8.self).baseAddress!, second.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sets[0].count, sets[1].count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }}
            guard status == noErr else { throw CourtError.message("无法解析 H.264 参数：\(status)") }
            if let format {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 1920, dimensions.height <= 1920,
                      dimensions.width * dimensions.height <= 1920 * 1080 else { throw CourtError.message("视频尺寸超出 1080p 上限。") }
            }
        }
        guard let format else { return nil }
        var block: CMBlockBuffer?
        let code = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: packet.payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: packet.payload.count, flags: 0, blockBufferOut: &block)
        guard code == noErr, let block else { throw CourtError.message("无法创建视频缓冲。") }
        let copyStatus = packet.payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: packet.payload.count)
        }
        guard copyStatus == noErr else { throw CourtError.message("视频缓冲写入失败。") }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000),
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = packet.payload.count; var sample: CMSampleBuffer?
        let result = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard result == noErr, let sample else { throw CourtError.message("无法创建可播放视频帧。") }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_NotSync] = h.keyframe != true
        }
        return sample
    }
}
