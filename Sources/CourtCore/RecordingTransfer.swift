import Foundation
import CryptoKit

/// Recording transfer (Phase 2, docs/camera-side-analysis.md §10). The camera streams a MOV in
/// ≤1 MB `file` packets from the offset the display asks for; the display appends to
/// `<name>.part`, verifies the whole file's SHA-256 and only then renames it into place.
public enum RecordingTransfer {
    public static let chunkSize = 1 << 20
    /// The camera keeps at most this much unsent, so control messages stay close behind chunks.
    public static let backlogLimit = 2 << 20

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Display-side writer for one transfer at a time. `receive` may be called on the network queue:
/// disk writes and the final SHA-256 run on the receiver's own queue, so heartbeats never stall.
public final class TransferReceiver: @unchecked Sendable {
    public struct Progress: Equatable, Sendable {
        public let sessionID: UUID
        public let filename: String
        public var received: Int64
        public var total: Int64
        public var bytesPerSecond: Double
        public var done = false
        public var error: String?
        public init(sessionID: UUID, filename: String, received: Int64, total: Int64, bytesPerSecond: Double) {
            self.sessionID = sessionID; self.filename = filename; self.received = received; self.total = total; self.bytesPerSecond = bytesPerSecond
        }
    }
    public var onProgress: ((Progress) -> Void)?
    private let io = DispatchQueue(label: "court.transfer.receiver", qos: .utility)
    private let lock = NSLock()
    private var expected: (sessionID: UUID, filename: String, directory: URL)?
    private var handle: FileHandle?
    private var progress: Progress?
    private var lastReport = 0.0
    private var windowStart = 0.0, windowBytes: Int64 = 0

    public init() {}

    /// Prepares to receive `filename`; returns the offset to request. With `resume` an earlier
    /// partial file continues; without it (clips, which are cut again and differ byte for byte)
    /// it is discarded first.
    public func expect(sessionID: UUID, filename: String, directory: URL, resume: Bool = true) throws -> Int64 {
        try SessionStore.validateRecordingFilename(filename)
        lock.lock(); defer { lock.unlock() }
        try? handle?.close(); handle = nil
        expected = (sessionID, filename, directory)
        let part = Self.partURL(directory: directory, filename: filename)
        if !resume { try? FileManager.default.removeItem(at: part) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.int64Value ?? 0
        progress = Progress(sessionID: sessionID, filename: filename, received: size, total: 0, bytesPerSecond: 0)
        windowStart = ProcessInfo.processInfo.systemUptime; windowBytes = 0
        return size
    }

    public func cancel(_ reason: String? = nil) {
        lock.lock()
        try? handle?.close(); handle = nil
        var final = progress; final?.error = reason
        expected = nil; progress = nil
        lock.unlock()
        if let final, reason != nil { onProgress?(final) }
    }

    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return expected != nil }

    public func receive(_ packet: StreamPacket) { io.async { [self] in write(packet) } }

    private func write(_ packet: StreamPacket) {
        lock.lock()
        guard let expected, var current = progress, packet.header.sessionID == expected.sessionID,
              packet.header.filename == expected.filename, let offset = packet.header.offset, let total = packet.header.total else {
            lock.unlock(); return
        }
        let part = Self.partURL(directory: expected.directory, filename: expected.filename)
        do {
            guard offset == current.received else { throw CourtError.message(courtFormat("录像分块偏移不连续（期望 %1$@，收到 %2$@）。", "\(current.received)", "\(offset)")) }
            if handle == nil {
                if !FileManager.default.fileExists(atPath: part.path) {
                    guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw CourtError.message(courtText("无法创建回传文件。")) }
                }
                handle = try FileHandle(forWritingTo: part)
                try handle?.seek(toOffset: UInt64(offset))
            }
            try handle?.write(contentsOf: packet.payload)
            current.received += Int64(packet.payload.count); current.total = total
            windowBytes += Int64(packet.payload.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - windowStart >= 1 { current.bytesPerSecond = Double(windowBytes) / (now - windowStart); windowStart = now; windowBytes = 0 }
            if current.received >= total {
                try handle?.close(); handle = nil
                let digest = try RecordingTransfer.sha256(of: part)
                guard let wanted = packet.header.sha256, digest == wanted else {
                    try? FileManager.default.removeItem(at: part)
                    throw CourtError.message(courtText("回传的录像校验不一致，已删除不完整文件，请重新回传。"))
                }
                let final = expected.directory.appendingPathComponent(expected.filename)
                if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
                try FileManager.default.moveItem(at: part, to: final)
                current.done = true
                self.expected = nil; progress = nil
                lock.unlock(); onProgress?(current); return
            }
            progress = current
            let report = now - lastReport >= 0.25
            if report { lastReport = now }
            lock.unlock()
            if report { onProgress?(current) }
        } catch {
            try? handle?.close(); handle = nil
            current.error = error.localizedDescription
            self.expected = nil; progress = nil
            lock.unlock(); onProgress?(current)
        }
    }

    static func partURL(directory: URL, filename: String) -> URL {
        directory.appendingPathComponent(".\(filename).part")
    }
}
