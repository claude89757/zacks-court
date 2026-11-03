import Foundation
import CoreImage
import CoreVideo

/// Session row for the browser's history list (`/api/sessions`).
struct WebSessionSummary: Encodable {
    let id: UUID
    let title: String
    let kind: SessionKind
    let state: SessionState
    let startedAt: Date
    let endedAt: Date?
    let elapsed: Double
    let shots: Int
    let speeds: Int
    let landings: Int
    let capturedOn: String?
    let recordings: [StoredRecording]
    init(_ session: CourtSession) {
        let rows = session.tennisEvents ?? []
        id = session.id; title = session.title; kind = session.kind; state = session.state
        startedAt = session.startedAt; endedAt = session.endedAt; elapsed = session.elapsed()
        shots = rows.count; speeds = rows.filter { $0.speedKPH != nil }.count
        landings = rows.filter { $0.bounce?.xMeters != nil && $0.bounce?.yMeters != nil }.count
        capturedOn = session.capturedOn; recordings = session.recordings
    }
}

/// Full session for the browser's shot review (`/api/session`), with the elapsed time computed
/// on the camera so the page does not depend on the two clocks agreeing.
struct WebSessionDetail: Encodable {
    let session: CourtSession
    let elapsed: Double
    /// Recordings still on the camera; the others were cleared (or lost), so the page offers no download.
    let available: [String]?
    init(_ session: CourtSession, store: SessionStore? = nil) {
        self.session = session; elapsed = session.elapsed()
        available = store.map { store in
            session.recordingFilenames.filter { name in
                (try? store.recordingURL(filename: name)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }
        }
    }
}

/// Scales the analyzer's latest frame to 640×360 and encodes a JPEG on its own queue, with at
/// most one frame in flight; a tick that finds one in flight is skipped.
final class WebPreviewEncoder: @unchecked Sendable {
    static let width = 640.0
    static let quality = 0.6
    private let queue = DispatchQueue(label: "court.web.preview", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var busy = false

    func encodeLatest(from analyzer: CameraSideAnalyzer, streamID: UUID, completion: @escaping @Sendable (Data?) -> Void) {
        lock.lock()
        guard !busy else { lock.unlock(); return }
        busy = true; lock.unlock()
        analyzer.latestFrameBuffer(streamID: streamID) { [self] pixels in
            guard let pixels else { done(); completion(nil); return }
            queue.async { [self] in
                defer { done() }
                let image = CIImage(cvPixelBuffer: pixels)
                let scale = min(1, Self.width / max(1, image.extent.width))
                let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Self.quality]
                guard let jpeg = context.jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(), options: options) else {
                    completion(nil); return
                }
                let info = WebWire.ImageInfo(width: Int(scaled.extent.width.rounded()), height: Int(scaled.extent.height.rounded()), streamID: streamID)
                completion(try? WebWire.binary(.preview, info: info, jpeg: jpeg))
            }
        }
    }
    private func done() { lock.lock(); busy = false; lock.unlock() }
}
