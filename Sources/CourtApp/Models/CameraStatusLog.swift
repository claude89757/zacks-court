import Foundation

/// Display-side record of the camera's 1 Hz status during a camera-owned session, for field tests
/// (heat, battery, load shedding, analysis delay and link over time): `<sessionID>-status.jsonl`
/// next to the session JSON. The camera stays the authority for the session itself; this is a
/// diagnostic log of what the display saw. Nothing arrives while the display is disconnected, so
/// each disconnect writes a `connected: false` line. Lines are written on a background queue.
final class CameraStatusLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "court.status.log", qos: .utility)
    private var handle: FileHandle?
    private var session: UUID?

    static func url(directory: URL, session: UUID) -> URL {
        directory.appendingPathComponent("\(session.uuidString)-status.jsonl")
    }

    /// Appends one JSON object; failures are dropped, since the log is diagnostic only.
    func append(_ line: [String: Any], session id: UUID, directory: URL) {
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(10)
        queue.async { [self] in
            if session != id { try? handle?.close(); handle = nil; session = id }
            if handle == nil {
                let url = Self.url(directory: directory, session: id)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: data)
        }
    }

    func close() { queue.async { [self] in try? handle?.close(); handle = nil; session = nil } }
    /// Waits for queued lines (tests).
    func flush() { queue.sync {} }
}
