import AVFoundation
import CoreML
import Foundation
import CourtCore

/// court-analyze independent-live VIDEO FP16_MODEL_DIR CAMERA.json|auto OUT.json [START_SECONDS [DURATION_SECONDS]] [--realtime] [--no-pose-fill]
///
/// `auto` finds the court from the frames as the App does (`IndependentLiveCourt`); a camera file fixes
/// it and turns the automatic court off, for comparisons with the offline chain.
/// Feeds a local video through the camera's in-house live lane (`CameraSideAnalyzer` with
/// `IndependentLiveConfiguration`): frames are decoded as 420v NV12 like the iPhone camera delivers,
/// scaled on the "capture" thread, analysed on the worker, and the rows the lane publishes are saved.
/// By default frames wait for the worker (no drops, for comparisons); `--realtime` paces at the source
/// clock and lets the lane drop frames like a live camera would. A Mac run, not an iPhone measurement.
/// Next to OUT.json: `OUT.candidates.json` (ball candidates) and `OUT.trace.json` (every input of the
/// shot rules, for `independent-replay`).
enum IndependentLiveCommand {
    static func run(_ allArgs: [String]) async throws {
        let realtime = allArgs.contains("--realtime"), poseFill = !allArgs.contains("--no-pose-fill")
        let args = allArgs.filter { $0 != "--realtime" && $0 != "--no-pose-fill" }
        guard args.count >= 5 else {
            throw CourtError.message("Usage: court-analyze independent-live VIDEO FP16_MODEL_DIR CAMERA.json|auto OUT.json [START [DURATION]] [--realtime] [--no-pose-fill]")
        }
        let video = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: out.path) else { throw CourtError.message("Output already exists; choose a new output path.") }
        let assets = try IndependentBallModelAssets.load(directory: URL(fileURLWithPath: args[2], isDirectory: true), variant: .fp16)
        let automatic = args[3] == "auto"
        let camera = automatic ? nil : try JSONDecoder().decode(IndependentPinholeCamera.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let startSeconds = args.count > 5 ? Double(args[5]) ?? 0 : 0
        let duration = args.count > 6 ? Double(args[6]) ?? .infinity : .infinity

        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CourtError.message("No video track") }
        let transform = try await track.load(.preferredTransform)
        guard transform == .identity else { throw CourtError.message("Rotated videos are not supported by the live lane check") }
        let reader = try AVAssetReader(asset: asset)
        if startSeconds > 0 { reader.timeRange = CMTimeRange(start: CMTime(seconds: startSeconds, preferredTimescale: 600), duration: .positiveInfinity) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CourtError.message("Cannot start video reader") }

        var live = IndependentLiveConfiguration(assets: assets, camera: camera, automaticCourt: automatic)
        live.poseFill = poseFill
        let analyzer = CameraSideAnalyzer(configuration: nil, independent: live)
        let rows = RowBox(), court = CourtBox()
        analyzer.onSnapshot = { snapshot in rows.add(snapshot.events); court.note(snapshot) }
        analyzer.onEventUpdate = { events in rows.add(events) }
        let candidateLog = CandidateBox(), trace = TraceBox()
        analyzer.observeIndependentCandidates { batch in candidateLog.add(batch) }
        analyzer.observeIndependentTrace { event in trace.add(event) }
        while !analyzer.currentMetrics.ready { try await Task.sleep(nanoseconds: 20_000_000) }
        if let error = analyzer.currentMetrics.loadError { throw CourtError.message("Live lane failed to load: \(error)") }

        let stream = UUID(), began = ProcessInfo.processInfo.systemUptime
        var frames = 0, firstPTS: Double?
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            if pts < startSeconds { continue }
            if firstPTS == nil { firstPTS = pts }
            if pts - firstPTS! > duration { reader.cancelReading(); break }
            if realtime {
                let due = began + (pts - firstPTS!)
                let wait = due - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            } else {
                while analyzer.currentMetrics.pendingFrames > 24 { try await Task.sleep(nanoseconds: 2_000_000) }
            }
            analyzer.submit(pixels, pts: pts, streamID: stream)
            frames += 1
            if frames % 600 == 0 {
                let m = analyzer.currentMetrics
                fputs("LIVE source_seconds=\(String(format: "%.1f", pts)) frames=\(frames) pending=\(m.pendingFrames) batches=\(m.ballBatches) published=\(m.publishedShots)\n", stderr)
            }
        }
        let final = FinalBox()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            analyzer.finish { events, metrics in final.set(events, metrics); done.resume() }
        }
        let wall = ProcessInfo.processInfo.systemUptime - began
        let timings = analyzer.drainTimings()
        let (lastEvents, metrics) = final.get()
        rows.add(lastEvents)
        // The analyzer keeps only its latest 600 rows (the session keeps the rest); the report keeps all.
        let events = rows.all
        let scale = timings.scale.sorted()
        let report = Report(source: video.lastPathComponent, startSeconds: startSeconds, frames: frames, wallSeconds: wall,
                            sourceSeconds: frames > 0 ? Double(frames) / 60 : 0, realtime: realtime,
                            scaleMillisecondsMedian: scale.isEmpty ? 0 : scale[scale.count / 2],
                            inferenceMillisecondsPerBatch: metrics.ballBatches > 0 ? metrics.ballInferenceSeconds / Double(metrics.ballBatches) * 1000 : 0,
                            personMillisecondsPerSample: metrics.personSamplesLive > 0 ? metrics.personSecondsLive / Double(metrics.personSamplesLive) * 1000 : 0,
                            courtFirstAvailablePTS: court.firstAvailable, courtReasons: court.reasons,
                            metrics: metrics, events: events)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(report).write(to: out, options: .withoutOverwriting)
        // ball candidates next to the report: [[time (1/60 s), u, v, peak], ...]
        try JSONSerialization.data(withJSONObject: candidateLog.all.map { [$0.time, $0.u, $0.v, $0.peak] })
            .write(to: out.deletingPathExtension().appendingPathExtension("candidates.json"), options: .withoutOverwriting)
        // every input of the shot rules, for `court-analyze independent-replay` with changed rules
        let compact = JSONEncoder()
        compact.nonConformingFloatEncodingStrategy = encoder.nonConformingFloatEncodingStrategy
        try compact.encode(trace.all).write(to: out.deletingPathExtension().appendingPathExtension("trace.json"), options: .withoutOverwriting)
        print("INDEPENDENT_LIVE court=\(court.firstAvailable.map { String(format: "%.1f", $0) } ?? "none") solves=\(metrics.courtSolves) frames=\(frames) wall=\(String(format: "%.1f", wall))s rows=\(events.count) speeds=\(events.filter { $0.speedKPH != nil }.count) strokes=\(events.filter { $0.stroke != .unknown }.count) batches=\(metrics.ballBatches) resets=\(metrics.ballResets) overflows=\(metrics.queueOverflows) scaleMs=\(String(format: "%.2f", report.scaleMillisecondsMedian)) inferMs=\(String(format: "%.1f", report.inferenceMillisecondsPerBatch)) personMs=\(String(format: "%.1f", report.personMillisecondsPerSample)) seen=\(rows.count)")
    }

    struct Report: Encodable {
        let source: String, startSeconds: Double, frames: Int, wallSeconds: Double, sourceSeconds: Double, realtime: Bool
        let scaleMillisecondsMedian: Double, inferenceMillisecondsPerBatch: Double, personMillisecondsPerSample: Double
        /// Automatic court: stream time it was first available, and each distinct status text in order.
        let courtFirstAvailablePTS: Double?, courtReasons: [String]
        let metrics: CameraSideAnalyzer.Metrics
        let events: [TennisShotEvent]
        let physicalAccuracyValidated = false
    }
    final class RowBox: @unchecked Sendable {
        private let lock = NSLock(); private var rows: [UUID: TennisShotEvent] = [:]
        func add(_ events: [TennisShotEvent]) { lock.lock(); for e in events { rows[e.id] = e }; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return rows.count }
        var all: [TennisShotEvent] { lock.lock(); defer { lock.unlock() }; return rows.values.sorted { $0.sourcePTS < $1.sourcePTS } }
    }
    final class CourtBox: @unchecked Sendable {
        private let lock = NSLock(); private var first: Double?; private var list: [String] = []
        func note(_ s: TennisAnalysisSnapshot) {
            lock.lock(); defer { lock.unlock() }
            if s.calibration.isAvailable, first == nil { first = s.pts }
            let text = (s.calibration.isAvailable ? "available: " : "unavailable: ") + (s.calibration.reason ?? "")
            if list.last != text { list.append(text) }
        }
        var firstAvailable: Double? { lock.lock(); defer { lock.unlock() }; return first }
        var reasons: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }
    final class CandidateBox: @unchecked Sendable {
        private let lock = NSLock(); private var list: [IndependentShotCandidate] = []
        func add(_ c: [IndependentShotCandidate]) { lock.lock(); list += c; lock.unlock() }
        var all: [IndependentShotCandidate] { lock.lock(); defer { lock.unlock() }; return list }
    }
    final class TraceBox: @unchecked Sendable {
        private let lock = NSLock(); private var list: [IndependentLiveTraceEvent] = []
        func add(_ e: IndependentLiveTraceEvent) { lock.lock(); list.append(e); lock.unlock() }
        var all: [IndependentLiveTraceEvent] { lock.lock(); defer { lock.unlock() }; return list }
    }
    final class FinalBox: @unchecked Sendable {
        private let lock = NSLock(); private var events: [TennisShotEvent] = []; private var metrics = CameraSideAnalyzer.Metrics()
        func set(_ e: [TennisShotEvent], _ m: CameraSideAnalyzer.Metrics) { lock.lock(); events = e; metrics = m; lock.unlock() }
        func get() -> ([TennisShotEvent], CameraSideAnalyzer.Metrics) { lock.lock(); defer { lock.unlock() }; return (events, metrics) }
    }
}
