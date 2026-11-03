import Foundation
import AVFoundation

/// Offline backfill (docs/camera-side-analysis.md §7): runs the same streaming engine over the
/// saved recording inside each analysis gap of a session (load shedding paused live analysis
/// there). Rows are tagged `origin == "offline"`, keep the recording's stream ID so replay finds
/// them, and are merged by stable ID without touching live rows outside the gap.
///
/// Source PTS of a recorded frame = recording.firstPTS + (sample time − first sample time).
public enum OfflineBackfill {
    public struct Result: Sendable {
        public let events: [TennisShotEvent]
        public let filledGaps: [Int]
        public let analyzedFrames: Int
    }
    /// Frames before a gap that warm up the temporal model; their rows are discarded.
    public static let warmupSeconds = 2.0

    /// Gaps that can be backfilled: closed (or closed by the session end), not yet backfilled,
    /// and covered by at least one local recording of the same stream.
    public static func pendingGaps(in session: CourtSession, directory: URL) -> [Int] {
        guard let gaps = session.analysisGaps else { return [] }
        return gaps.indices.filter { index in
            let gap = gaps[index]
            guard gap.backfilled != true else { return false }
            let end = gap.endPTS ?? .infinity
            return session.recordings.contains { recording in
                (gap.streamID == nil || recording.streamID == gap.streamID) &&
                    recording.firstPTS < end && recording.firstPTS + recording.duration > gap.startPTS &&
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent(recording.filename).path)
            }
        }
    }

    public static func run(session: CourtSession, directory: URL, configuration: TennisAnalysisConfiguration,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> Result {
        let store = try SessionStore(directory: directory)
        let pending = pendingGaps(in: session, directory: directory)
        guard let gaps = session.analysisGaps, !pending.isEmpty else { return Result(events: [], filledGaps: [], analyzedFrames: 0) }
        var rows: [UUID: TennisShotEvent] = [:], frames = 0, filled: [Int] = []
        for (position, index) in pending.enumerated() {
            let gap = gaps[index]
            let end = gap.endPTS ?? session.recordings.map { $0.firstPTS + $0.duration }.max() ?? gap.startPTS
            for recording in session.recordings where (gap.streamID == nil || recording.streamID == gap.streamID)
                && recording.firstPTS < end && recording.firstPTS + recording.duration > gap.startPTS {
                let url = try store.recordingURL(filename: recording.filename)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let found = try await analyse(url: url, recording: recording, from: gap.startPTS, to: end, configuration: configuration) { fraction in
                    progress?((Double(position) + fraction) / Double(pending.count))
                }
                frames += found.frames
                for row in found.rows { rows[row.id] = row }
            }
            filled.append(index)
        }
        progress?(1)
        return Result(events: rows.values.sorted { $0.sourcePTS < $1.sourcePTS }, filledGaps: filled, analyzedFrames: frames)
    }

    private static func analyse(url: URL, recording: StoredRecording, from start: Double, to end: Double,
                                configuration: TennisAnalysisConfiguration, progress: (Double) -> Void) async throws -> (rows: [TennisShotEvent], frames: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CourtError.message("录像没有视频轨道：\(recording.filename)") }
        let fps = Double(try await track.load(.nominalFrameRate))
        var config = configuration
        if fps.isFinite, fps > 0 { config.nominalFPS = fps }
        let engine = try ReferenceChain.makeEngine(configuration: config)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CourtError.message("无法读取录像：\(recording.filename)") }
        let stream = recording.streamID ?? UUID()
        let from = start - warmupSeconds
        var first: Double?, rows: [UUID: TennisShotEvent] = [:], frames = 0
        func keep(_ snapshot: TennisAnalysisSnapshot) {
            for var row in snapshot.events where row.sourcePTS >= start && row.sourcePTS <= end {
                row.origin = "offline"; rows[row.id] = row
            }
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite else { continue }
            if first == nil { first = time }
            let pts = recording.firstPTS + (time - (first ?? time))
            if pts < from { continue }
            if pts > end + 1 { reader.cancelReading(); break }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            if let snapshot = try autoreleasepool(invoking: { try engine.process(pixels, pts: pts, streamID: stream) }) { keep(snapshot) }
            frames += 1
            if frames % 60 == 0 { progress(min(1, max(0, (pts - from) / max(0.001, end + 1 - from)))) }
        }
        if reader.status == .failed { throw reader.error ?? CourtError.message("录像解码失败：\(recording.filename)") }
        if let final = engine.finish() { keep(final) }
        return (Array(rows.values), frames)
    }
}
