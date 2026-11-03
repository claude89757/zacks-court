import Foundation
import CourtCore

/// court-analyze independent-shots REPORT.json PEOPLE.json OUT.json CAMERA.json[@START:END] [...] [--live | --person-frames]
///
/// Runs the in-house shot chain on a saved `independent-full-video` report with explicit cameras
/// (one per fixed-camera segment, seconds) and person boxes in the `people.swift` layout. Used to
/// check the native port against the Python development run; it adds no new evidence of accuracy.
/// `--live` replays the candidates in time order through `IndependentLiveShots` (update every 0.25 s)
/// and writes the last published version of each shot, to compare the bounded-lag chain with the batch one.
/// `--person-frames` writes the frames (1/60 s units) that need person boxes, one per line, for `people.swift`.
enum IndependentShotsCommand {
    static func run(_ allArgs: [String]) throws {
        let live = allArgs.contains("--live"), framesOnly = allArgs.contains("--person-frames")
        let args = allArgs.filter { $0 != "--live" && $0 != "--person-frames" }
        guard args.count >= 5 else {
            throw CourtError.message("Usage: court-analyze independent-shots REPORT.json PEOPLE.json OUT.json CAMERA.json[@START:END] ...")
        }
        let out = URL(fileURLWithPath: args[3])
        guard !FileManager.default.fileExists(atPath: out.path) else { throw CourtError.message("Output already exists; choose a new output path.") }
        let began = ProcessInfo.processInfo.systemUptime
        let candidates = try loadCandidates(URL(fileURLWithPath: args[1]))
        let people = framesOnly ? IndependentPeople([:]) : try loadPeople(URL(fileURLWithPath: args[2]))
        var segments = [IndependentShotPipeline.Segment]()
        for spec in args.dropFirst(4) {
            let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
            let camera = try JSONDecoder().decode(IndependentPinholeCamera.self, from: Data(contentsOf: URL(fileURLWithPath: parts[0])))
            var start = 0.0, end = Double.infinity
            if parts.count == 2 {
                let r = parts[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard r.count == 2, let s = Double(r[0]) else { throw CourtError.message("Segment range must be START:END seconds") }
                start = s; end = r[1].isEmpty ? .infinity : (Double(r[1]) ?? .infinity)
            }
            segments.append(.init(camera: camera, start: start, end: end))
        }
        if framesOnly {   // first pass: the frames that need person boxes (PEOPLE.json is not read)
            let frames = Set(segments.flatMap { IndependentShotPipeline.events(candidates: candidates, segment: $0).personFrames })
            try (frames.sorted().map(String.init).joined(separator: "\n") + "\n").write(to: out, atomically: false, encoding: .utf8)
            print("PERSON_FRAMES \(frames.count)"); return
        }
        let shots = live ? replay(candidates, segments, people) : IndependentShotPipeline.run(candidates: candidates, segments: segments) { _, _ in people }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(shots).write(to: out, options: .withoutOverwriting)
        let speeds = shots.compactMap(\.reportedSpeedKmh).count
        print("INDEPENDENT_SHOTS rules=\(IndependentShotPipeline.rulesVersion) candidates=\(candidates.count) shots=\(shots.count) accepted=\(shots.filter(\.accepted).count) reportedSpeeds=\(speeds) strokes=\(shots.filter { $0.stroke != nil }.count) seconds=\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - began))")
    }

    /// Bounded-lag replay: candidates arrive in presentation order, the chain updates every 0.25 s.
    static func replay(_ candidates: [IndependentShotCandidate], _ segments: [IndependentShotPipeline.Segment],
                       _ people: IndependentPeople) -> [IndependentShotResult] {
        let ordered = candidates.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        guard let first = ordered.first, let last = ordered.last else { return [] }
        var live = IndependentLiveShots(), next = 0, segment: Int?
        var now = (first.time / 60).rounded(.down), updates = 0
        let began = ProcessInfo.processInfo.systemUptime
        while now <= last.time / 60 + live.options.window {
            now += 0.25
            guard let k = segments.firstIndex(where: { now > $0.start && now - 0.25 < $0.end }) else { continue }
            if segment != k { if segment != nil { live.reset() }; segment = k }
            var batch = [IndependentShotCandidate]()
            while next < ordered.count, ordered[next].time / 60 < min(now, segments[k].end) {
                if ordered[next].time / 60 >= segments[k].start { batch.append(ordered[next]) }
                next += 1
            }
            live.append(batch)
            live.update(now: min(now, segments[k].end), camera: segments[k].camera, people: people); updates += 1
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let pub = live.published.sorted { $0.shot.tHit < $1.shot.tHit }
        func stats(_ xs: [Double]) -> String {
            guard !xs.isEmpty else { return "n 0" }
            let s = xs.sorted(); return String(format: "n %d median %.2f s  p90 %.2f s  max %.2f s", s.count, s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.9))], s[s.count - 1])
        }
        print("LIVE_REPLAY updates=\(updates) seconds=\(String(format: "%.1f", elapsed)) perUpdateMs=\(String(format: "%.1f", elapsed / Double(max(updates, 1)) * 1000)) revised=\(pub.filter { $0.revisions > 0 }.count)")
        print("LIVE_REPLAY stroke latency after hit: " + stats(pub.filter { $0.shot.stroke != nil }.map { $0.firstPublished - $0.shot.tHit }))
        print("LIVE_REPLAY speed latency after bounce: " + stats(pub.compactMap { p in p.speedPublished.flatMap { t in p.shot.tBounce.map { t - $0 } } }))
        print("LIVE_REPLAY speed latency after hit: " + stats(pub.compactMap { p in p.speedPublished.map { $0 - p.shot.tHit } }))
        return pub.map(\.shot)
    }

    /// Candidates of every frame in decode order; time in 1/60 s units of presentation time.
    static func loadCandidates(_ url: URL) throws -> [IndependentShotCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let frames = root["frames"] as? [[String: Any]] else { throw CourtError.message("Report has no frames") }
        var out = [IndependentShotCandidate]()
        for (i, f) in frames.enumerated() {
            guard let pt = f["presentationTime"] as? [String: Any], let value = (pt["value"] as? NSNumber)?.int64Value,
                  let scale = (pt["timescale"] as? NSNumber)?.int32Value, scale > 0 else { throw CourtError.message("Frame \(i) has no presentation time") }
            let t = Double(value) * 60 / Double(scale)
            for c in ((f["candidateBank"] as? [String: Any])?["candidates"] as? [[String: Any]]) ?? [] {
                guard let xy = c["originalXY"] as? [NSNumber], xy.count == 2, let peak = (c["peak"] as? NSNumber)?.doubleValue else { continue }
                out.append(IndependentShotCandidate(decodeIndex: i, time: t, u: xy[0].doubleValue, v: xy[1].doubleValue, peak: peak))
            }
        }
        return out
    }

    static func loadPeople(_ url: URL) throws -> IndependentPeople {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [[NSNumber]]] else {
            throw CourtError.message("People file must map frame -> [[x0, y0, x1, y1, confidence, fromCrop, cropBottom]]")
        }
        var byFrame = [Int: [IndependentPersonBox]]()
        for (k, boxes) in root { if let f = Int(k) { byFrame[f] = boxes.compactMap { IndependentPersonBox(array: $0.map(\.doubleValue)) } } }
        return IndependentPeople(byFrame)
    }
}
