import Foundation
import simd

/// Serve swings read from the region poses (v29): at either end, a player at their own baseline holding a
/// wrist a torso length above the shoulders. The far players give no pose on the whole frame (v27 could name
/// near serves only); in a region around their box, read ten times a second, they do. The top of the hitting
/// wrist's path is the contact, within a frame or two: the time a serve's speed needs and a 5 Hz sample
/// cannot give.
extension IndependentStrokeRules {
    enum Swing {
        static let high = 0.6          // the hitting wrist is looked for among samples this far above the shoulders, torso lengths
        static let topWithin = 0.15    // its top: the highest of those this close before the last one, seconds
        static let around = 0.3        // samples this long before and after the event are read for the wrist's path
        static let follow = 0.9        // between samples the wrist moves at most this (torso lengths, times the root of the frames apart)
        static let slack = 0.2         //   plus this
        static let stepGap = 0.09      // the path ends at a gap longer than this and than 2.6 sample periods, seconds
        static let racket = 0.5        // the ball at contact above the hitting wrist, metres
        static let flight = 0.2...1.6  // contact to first bounce of a serve timed by the swing, seconds
        static let watchBefore = 1.5, watchAfter = 0.3   // a far flight's server is looked for this long around its start, seconds
        static let near = 0.6          //   and a swing this close to it is its server's
        static let fall = 0.7, fallWithin = 0.21   // a swing's wrist drops this far (torso lengths) this soon after its top (s)
        static let pathAfter = 0.55    //   and its path ends within this of the top, seconds
        static let tossLead = 0.3      // a far wrist top this long before the flight's own start is the toss arm's, seconds
        static let sameSwing = 0.5     // a region swing this close to a whole-frame pose event is the same serve, seconds
        static let held = 0.09         // an event this long needs a peak of `PoseServe.strong`, a shorter one `single`, seconds
        static let densePeriod = 0.125 // poses read at least this often time a contact and can deny a serve (8 Hz), seconds
    }

    struct ServeSwing: Equatable {
        var near: Bool
        var start: Double, end: Double, peak: Double
        var samples = 1
        /// The top of the hitting wrist's path, seconds; nil when the wrist was not followed.
        var contact: Double?
        /// The wrist there, image pixels.
        var hand: SIMD2<Double>?
        /// The wrist came down right after its top and its path ended soon: a swing through the ball. A toss
        /// arm's top looks otherwise: it comes down slowly, and the path runs on into the swing that follows.
        var swung = false
    }

    /// Where the ball was when a seen serve was hit: over the server's baseline (`ServeSpeed.inside` into the
    /// court, as the serve refits put it), half a metre above the hitting wrist. Without the wrist: 2.6 m up,
    /// at the fitted contact's side position.
    static func seenContact(hand: [Double]?, near: Bool, camera cam: IndependentProjector, fallbackX: Double?) -> SIMD3<Double> {
        let y = near ? IndependentShotFlights.ServeSpeed.inside : IndependentCourt.length - IndependentShotFlights.ServeSpeed.inside
        if let hand, hand.count >= 2 {
            let (W, along) = cam.onPlaneY(hand[0], hand[1], y: y)
            if along > 0, W.x.isFinite, W.z.isFinite, abs(W.x) <= IndependentCourt.doublesHalfWidth + PoseServe.side {
                return SIMD3(W.x, y, min(max(W.z + Swing.racket, Serve.contactZ.lowerBound), Serve.contactZ.upperBound))
            }
        }
        return SIMD3(fallbackX.map { min(max($0, -6), 6) } ?? 0, y, 2.6)
    }

    /// The pose's feet behind its own baseline in the image, in body heights (as `behindInBoxHeights`, with
    /// the body from the shoulders to the lowest joint found standing in for the box).
    static func behind(_ s: IndependentPoseSample, near: Bool, _ cam: IndependentProjector) -> Double? {
        guard s.point(.leftAnkle) != nil || s.point(.rightAnkle) != nil, let feet = s.feet,
              let shoulders = s.row(.leftShoulder, .rightShoulder) else { return nil }
        let y = near ? 0 : IndependentCourt.length
        let a = cam.project(SIMD3(-6, y, 0)), b = cam.project(SIMD3(6, y, 0))
        guard a.depth > 0, b.depth > 0, abs(b.u - a.u) > 1 else { return nil }
        let line = a.v + (feet.x - a.u) / (b.u - a.u) * (b.v - a.v)
        return (near ? feet.y - line : line - feet.y) / max(1.35 * (feet.y - shoulders), 1)
    }

    /// The swings at one end, in time order.
    static func serveSwings(_ people: IndependentPeople, camera cam: IndependentProjector, near: Bool) -> [ServeSwing] {
        let frames = people.poses.keys.sorted()
        var events = [ServeSwing]()
        for frame in frames {
            var up = -Double.infinity
            for s in people.poses[frame] ?? [] where s.near == near {
                guard let a = s.armUp, a >= PoseServe.raised else { continue }
                // at the baseline. A near player whose ankles are below the picture is taken on the region's word:
                // it follows a box that stood there
                if let b = behind(s, near: near, cam) { guard Serve.behindPx.contains(b) else { continue } } else if !near { continue }
                up = max(up, a)
            }
            guard up >= PoseServe.raised else { continue }
            let t = Double(frame) / 60
            if let last = events.last, t - last.end <= PoseServe.gap {
                events[events.count - 1].end = t; events[events.count - 1].peak = max(last.peak, up); events[events.count - 1].samples += 1
            } else { events.append(ServeSwing(near: near, start: t, end: t, peak: up)) }
        }
        // an arm held up for a tenth of a second, or once straight up (by time, not by samples: read at 20 Hz a
        // follow-through gives two samples where 10 Hz gives one)
        events = events.filter { e in
            guard e.peak >= (e.end - e.start >= Swing.held ? PoseServe.strong : PoseServe.single) else { return false }
            // only where the poses were read densely. A camera shedding load reads them on person frames alone
            // (5 Hz and less): the wrist's top is then a sample up to 0.1 s off, a short swing falls between
            // samples, and the rules go by the whole-frame pose and the flights as before v29
            let around = frames.filter { let t = Double($0) / 60; return t >= e.start - Swing.around && t <= e.end + Swing.around }
            return around.count >= 3 && Double(around[around.count - 1] - around[0]) / 60 / Double(around.count - 1) <= Swing.densePeriod
        }
        for i in events.indices {
            guard let c = contact(of: events[i], frames: frames, people: people) else { continue }
            events[i].contact = c.t; events[i].hand = c.hand; events[i].swung = c.swung
        }
        return events
    }

    /// The contact of a swing: the hitting wrist is the upper wrist at its last top (the highest sample within
    /// `topWithin` before the last one `high` above the shoulders: the toss arm came down before), followed
    /// to both sides by the nearest wrist of each sample; the contact is the top of that path, between samples
    /// by the parabola through the three around it.
    static func contact(of swing: ServeSwing, frames: [Int], people: IndependentPeople) -> (t: Double, hand: SIMD2<Double>, swung: Bool)? {
        struct Sample { var t: Double, shoulders: Double, torso: Double?, wrists: [SIMD2<Double>] }
        var S = [Sample]()
        for frame in frames {
            let t = Double(frame) / 60
            guard t >= swing.start - Swing.around, t <= swing.end + Swing.around else { continue }
            var best: (Double, Sample)?
            for s in people.poses[frame] ?? [] where s.near == swing.near {
                guard let shoulders = s.row(.leftShoulder, .rightShoulder) else { continue }
                let wrists = [IndependentPoseSample.Joint.leftWrist, .rightWrist].compactMap { s.point($0) }
                guard !wrists.isEmpty else { continue }
                let up = s.armUp ?? -9
                if best == nil || up > best!.0 { best = (up, Sample(t: t, shoulders: shoulders, torso: s.torso, wrists: wrists)) }
            }
            if let best { S.append(best.1) }
        }
        let torsos = S.compactMap(\.torso).sorted()
        guard S.count >= 3, !torsos.isEmpty else { return nil }
        let T = torsos.count % 2 == 1 ? torsos[torsos.count / 2] : (torsos[torsos.count / 2 - 1] + torsos[torsos.count / 2]) / 2
        func upper(_ s: Sample) -> SIMD2<Double> { s.wrists.min { $0.y < $1.y }! }
        let up = S.map { ($0.shoulders - upper($0).y) / T }
        let high = S.indices.filter { up[$0] >= Swing.high }
        guard let last = high.last else { return nil }
        let top = high.filter { S[last].t - S[$0].t <= Swing.topWithin }.max { up[$0] < up[$1] }!
        var path = [top: upper(S[top])]
        let period = S[1].t - S[0].t
        for step in [-1, 1] {
            var from = top, i = top + step
            while i >= 0, i < S.count, abs(S[i].t - S[from].t) < max(Swing.stepGap, 2.6 * period) {
                let at = path[from]!
                let p = S[i].wrists.min { simd_length($0 - at) < simd_length($1 - at) }!
                let apart = max(1, abs(S[i].t - S[from].t) * 60)
                if simd_length(p - at) <= Swing.follow * T * apart.squareRoot() + Swing.slack * T { path[i] = p; from = i }
                i += step
            }
        }
        let order = path.keys.sorted()
        guard order.count >= 3 else { return nil }
        let k = order.indices.min { path[order[$0]]!.y < path[order[$1]]!.y }!
        let t1 = S[order[k]].t, hand = path[order[k]]!
        // through the ball: down by `fall` torso lengths within `fallWithin`, and the path over within `pathAfter`
        let after = order[(k + 1)...].filter { S[$0].t - t1 <= Swing.fallWithin }.map { (path[$0]!.y - hand.y) / T }
        let swung = (after.max() ?? 0) >= Swing.fall && S[order[order.count - 1]].t - t1 <= Swing.pathAfter
        guard k > 0, k < order.count - 1 else { return (t1, hand, swung) }
        let t0 = S[order[k - 1]].t, t2 = S[order[k + 1]].t
        let y0 = path[order[k - 1]]!.y, y1 = path[order[k]]!.y, y2 = path[order[k + 1]]!.y, bend = y0 - 2 * y1 + y2
        guard abs((t2 - t1) - (t1 - t0)) < 1e-3, bend > 1e-6 else { return (t1, hand, swung) }
        return (t1 + 0.5 * (y0 - y2) / bend * (t1 - t0), hand, swung)
    }
}
