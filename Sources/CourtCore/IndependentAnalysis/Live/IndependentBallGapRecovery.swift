import simd

/// Short gaps where a small, moving ball crosses a pale wall. Start only from three moving model
/// observations. Each additional point needs a yellow-green transient at its own source time.
struct IndependentBallGapRecovery {
    typealias Point = SIMD2<Double>
    private struct Observation { var time: Double; var point: Point }
    private struct Track { var recent: [Observation]; var lastModel: Double }
    private var tracks = [Track]()
    private var seeds = [[Observation]]()
    private var previous: [UInt8]?, earlier: [UInt8]?
    let floorRow: Int
    static let width = IndependentLiveFrameScaler.width, height = IndependentLiveFrameScaler.height

    init?(background: [UInt8]) {
        guard let row = IndependentCourtEvidence.paintedFloorRow(width: Self.width, height: Self.height, rgb: { i in
            (background[3 * i], background[3 * i + 1], background[3 * i + 2])
        }), row > 0 else { return nil }
        floorRow = row
    }

    /// Model-grid coordinates and true PTS (in 1/60 s units); no camera buffers or additional inference.
    mutating func update(model: [Point], frame: [UInt8], time: Double) -> [Point] {
        defer { earlier = previous; previous = frame }
        let points = model.filter { $0.y < Double(floorRow) }
        var used = Set<Int>(), recovered = [Point]()
        // Losing the pixels for four frames, or the model for 0.3 s, ends the search.
        tracks.removeAll { time - $0.lastModel > 18 || time - $0.recent.last!.time > 3.5 }
        for i in tracks.indices {
            let history = tracks[i].recent, first = history.first!, last = history.last!
            let velocity = (last.point - first.point) / (last.time - first.time)
            let predicted = last.point + (time - last.time) * velocity
            let closest = points.indices.filter { !used.contains($0) }.min {
                simd_distance_squared(points[$0], predicted) < simd_distance_squared(points[$1], predicted)
            }
            let observed: Point
            if let j = closest, simd_distance(points[j], predicted) <= 7 {
                used.insert(j); observed = points[j]; tracks[i].lastModel = time
            } else {
                guard simd_length(velocity) >= 1, let previous, let earlier,
                      let p = transient(near: predicted, frame: frame, background: earlier, previous: previous),
                      !(points + recovered).contains(where: { simd_distance_squared($0, p) < 9 }) else { continue }
                observed = p; recovered.append(p)
            }
            tracks[i].recent = Array(history.suffix(3)) + [Observation(time: time, point: observed)]
        }
        let current = points.map { Observation(time: time, point: $0) }
        if seeds.count == 2 {
            for j in points.indices where !used.contains(j) && tracks.count < 4 {
                if let track = seed(endingAt: current[j]) { tracks.append(track) }
            }
        }
        seeds = Array(seeds.suffix(1)) + [current]
        return recovered
    }

    private func seed(endingAt c: Observation) -> Track? {
        for b in seeds[1] {
            let dt = c.time - b.time
            guard dt > 0, dt < 3.5 else { continue }
            let v = (c.point - b.point) / dt, speed = simd_length(v)
            guard (1.0...17.0).contains(speed) else { continue }
            for a in seeds[0] {
                let earlier = b.time - a.time
                guard earlier > 0, earlier < 3.5 else { continue }
                if simd_distance((b.point - a.point) / earlier, v) <= 2 + 0.3 * speed {
                    return Track(recent: [a, b, c], lastModel: c.time)
                }
            }
        }
        return nil
    }

    private func transient(near p: Point, frame: [UInt8], background: [UInt8], previous: [UInt8]) -> Point? {
        let cx = Int(p.x.rounded()), cy = Int(p.y.rounded())
        let x0 = max(0, cx - 7), x1 = min(Self.width - 1, cx + 7)
        let y0 = max(0, cy - 7), y1 = min(floorRow - 1, cy + 7)
        guard x0 <= x1, y0 <= y1 else { return nil }
        var best: Point?, bestScore = 10.0
        for y in y0...y1 {
            for x in x0...x1 {
                let i = 3 * (y * Self.width + x)
                let br = Int(background[i]), bg = Int(background[i + 1]), bb = Int(background[i + 2])
                guard min(br, bg, bb) >= 42, max(br, bg, bb) - min(br, bg, bb) <= 30 else { continue }
                let r = Int(frame[i]), g = Int(frame[i + 1]), colour = min(r + 24, g) - Int(frame[i + 2])
                let gain = colour - (min(br + 24, bg) - bb)
                let change = colour - (min(Int(previous[i]) + 24, Int(previous[i + 1])) - Int(previous[i + 2]))
                guard g >= r - 9, colour >= 11, gain >= 6, change >= 3 else { continue }
                let point = Point(Double(x), Double(y)), distance = simd_distance(point, p)
                guard distance <= 7 else { continue }
                let score = Double(min(gain, 45)) + 0.55 * Double(min(change, 35)) - 1.75 * distance
                if score > bestScore { best = point; bestScore = score }
            }
        }
        return best
    }
}
