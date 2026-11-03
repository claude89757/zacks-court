import Foundation

public enum CourtError: LocalizedError {
    case message(String)
    /// The peer speaks another protocol version. Terminal: reconnecting cannot fix it.
    case incompatible(String)
    public var errorDescription: String? {
        switch self { case .message(let text), .incompatible(let text): return text }
    }
}

/// Protocol v2: the camera analyses on device and sends per-shot data, status and an optional
/// low-resolution preview. v1 (full 1080p60 video to the display) is rejected with an explicit reason.
public enum WireProtocol {
    public static let version = 2
    static func mismatch(_ peer: Int) -> String {
        peer < version
            ? "另一台设备运行旧版 Zacks Court（协议 v\(peer)），请把两台设备更新到同一版本。"
            : "另一台设备运行更新版本的 Zacks Court（协议 v\(peer)），请更新这台设备。"
    }
}

public enum WireKind: String, CaseIterable, Sendable {
    case hello, status, control, analysis, session, preview, still, file
}

public struct StreamHeader: Codable {
    public var version = WireProtocol.version
    public var kind: String
    public var streamID: UUID?
    public var sequence: UInt64?
    public var pts: Double?
    public var duration: Double?
    public var keyframe: Bool?
    public var parameterSets: [Data]?
    public var command: String?
    public var message: String?
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var captureDrops: UInt64?
    public var transportDrops: UInt64?
    /// Per-frame raw capture observations, also persisted in the recording JSONL.
    public var captureMetadata: CaptureFrameMetadata?
    public var captureMetadataOmissionReason: CaptureFrameMetadata.OmissionReason?
    /// Recording transfer: owning session, safe file name, byte offset of this chunk and total size.
    public var sessionID: UUID?
    public var filename: String?
    public var offset: Int64?
    public var total: Int64?
    public var sha256: String?

    public init(kind: String) { self.kind = kind }
}

public struct StreamPacket {
    public let header: StreamHeader
    public let payload: Data
    public init(header: StreamHeader, payload: Data = Data()) { self.header = header; self.payload = payload }

    // 4-byte big-endian body length, 4-byte JSON length, JSON metadata, AVCC bytes.
    public func encoded() throws -> Data {
        let metadata = try JSONEncoder().encode(header)
        let size = 4 + metadata.count + payload.count
        guard metadata.count <= PacketDecoder.maximumHeader, size <= PacketDecoder.maximumBody else {
            throw CourtError.message("传输包超过协议上限。")
        }
        var data = Data()
        data.appendUInt32(UInt32(size)); data.appendUInt32(UInt32(metadata.count))
        data.append(metadata); data.append(payload)
        return data
    }
}

public struct PacketDecoder {
    public static let maximumBody = 4 * 1024 * 1024
    public static let maximumHeader = 16 * 1024
    private var pending = Data()
    public init() {}

    public mutating func append(_ chunk: Data) throws -> [StreamPacket] {
        guard chunk.count <= Self.maximumBody + 4,
              pending.count + chunk.count <= Self.maximumBody * 2 + 8 else {
            throw CourtError.message("接收缓冲超限。")
        }
        pending.append(chunk)
        var packets: [StreamPacket] = []
        var offset = 0
        while pending.count - offset >= 4 {
            let count = Int(pending.uint32(at: offset))
            guard count >= 4, count <= Self.maximumBody else { throw CourtError.message("无效的视频包长度。") }
            guard pending.count - offset >= count + 4 else { break }
            let headerCount = Int(pending.uint32(at: offset + 4))
            guard headerCount > 0, headerCount <= Self.maximumHeader, headerCount <= count - 4 else {
                throw CourtError.message("无效的视频元数据长度。")
            }
            let start = offset + 8
            let header = try JSONDecoder().decode(StreamHeader.self, from: pending.subdata(in: start..<(start + headerCount)))
            guard header.version == WireProtocol.version else { throw CourtError.incompatible(WireProtocol.mismatch(header.version)) }
            guard let kind = WireKind(rawValue: header.kind) else { throw CourtError.message("不支持的传输内容：\(header.kind)") }
            let payload = pending.subdata(in: (start + headerCount)..<(offset + 4 + count))
            switch kind {
            case .preview:
                guard let pts = header.pts, pts.isFinite, pts >= 0,
                      let duration = header.duration, duration.isFinite, duration > 0, duration <= 1,
                      header.streamID != nil, header.sequence != nil,
                      header.keyframe != nil, !payload.isEmpty else {
                    throw CourtError.message("视频帧缺少有效的来源时间戳。")
                }
                if let sets = header.parameterSets {
                    guard sets.count == 2, sets.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else {
                        throw CourtError.message("无效的 H.264 参数集。")
                    }
                }
            case .still:
                guard !payload.isEmpty, let width = header.width, let height = header.height,
                      (1...4096).contains(width), (1...4096).contains(height) else { throw CourtError.message("无效的标定静帧。") }
            case .file:
                guard header.sessionID != nil, let name = header.filename, let chunkOffset = header.offset, let total = header.total,
                      chunkOffset >= 0, total >= chunkOffset + Int64(payload.count) else { throw CourtError.message("无效的录像传输分块。") }
                try SessionStore.validateRecordingFilename(name)
            case .hello, .status, .control, .analysis, .session:
                break
            }
            packets.append(StreamPacket(header: header, payload: payload))
            offset += count + 4
        }
        if offset > 0 { pending = Data(pending.dropFirst(offset)) }
        return packets
    }
}

private extension Data {
    mutating func appendUInt32(_ number: UInt32) {
        var big = number.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    func uint32(at index: Int) -> UInt32 {
        (UInt32(self[index]) << 24) | (UInt32(self[index + 1]) << 16) |
            (UInt32(self[index + 2]) << 8) | UInt32(self[index + 3])
    }
}
