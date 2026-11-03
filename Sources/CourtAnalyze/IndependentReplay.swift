import Foundation
import CourtCore

/// court-analyze independent-replay TRACE.json OUT.json
///
/// Replays the shot-rule inputs an `independent-live` run recorded (`OUT.trace.json`: ball candidates,
/// person boxes, camera changes and update times, in order) through the current rules, without the ball
/// model, Vision or the video. Writes the rows the lane would have ended with (`events`, the same format
/// as `independent-live`, readable by `compare_rows.py`) and the full per-shot results (`shots`). With
/// unchanged rules it reproduces the live run's rows; it measures rule changes only, not detection.
enum IndependentReplayCommand {
    static func run(_ args: [String]) throws {
        guard args.count >= 3 else { throw CourtError.message("Usage: court-analyze independent-replay TRACE.json OUT.json") }
        let out = URL(fileURLWithPath: args[2])
        guard !FileManager.default.fileExists(atPath: out.path) else { throw CourtError.message("Output already exists; choose a new output path.") }
        let began = ProcessInfo.processInfo.systemUptime
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let events = try decoder.decode([IndependentLiveTraceEvent].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let streams = IndependentLiveTrace.replay(events)
        var paired = [(TennisShotEvent, IndependentShotResult)]()
        for shots in streams {
            let stream = UUID()
            paired += zip(IndependentShotPipeline.rows(from: shots, streamID: stream), shots)
        }
        // rows in time order, and `shots[i]` is the full result behind `events[i]`
        let order: [Int] = paired.indices.sorted { (i: Int, j: Int) -> Bool in
            let ti: Double = paired[i].0.sourcePTS, tj: Double = paired[j].0.sourcePTS
            return ti != tj ? ti < tj : i < j
        }
        paired = order.map { (i: Int) -> (TennisShotEvent, IndependentShotResult) in paired[i] }
        let rows = paired.map(\.0)
        let report = Report(rulesVersion: IndependentShotPipeline.rulesVersion, events: rows, shots: paired.map(\.1))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(report).write(to: out, options: .withoutOverwriting)
        print("INDEPENDENT_REPLAY rules=\(IndependentShotPipeline.rulesVersion) events=\(events.count) streams=\(streams.count) rows=\(rows.count) speeds=\(rows.filter { $0.speedKPH != nil }.count) strokes=\(rows.filter { $0.stroke != .unknown }.count) seconds=\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - began))")
    }

    struct Report: Encodable {
        let rulesVersion: String
        let events: [TennisShotEvent]
        let shots: [IndependentShotResult]
        let physicalAccuracyValidated = false
    }
}
