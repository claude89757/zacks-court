import Foundation
import simd

/// One TrackNetV3 candidate: decode index of its frame, real presentation time in 1/60 s units,
/// original-image pixel and heatmap peak.
public struct IndependentShotCandidate: Sendable, Equatable, Codable {
    public let decodeIndex: Int
    public let time: Double
    public let u: Double, v: Double, peak: Double
    public init(decodeIndex: Int, time: Double, u: Double, v: Double, peak: Double) {
        self.decodeIndex = decodeIndex; self.time = time; self.u = u; self.v = v; self.peak = peak
    }
}

/// A 2D ball track point: time (1/60 s units), pixel.
public struct IndependentTrackPoint: Sendable, Hashable {
    public var t: Double, u: Double, v: Double
    var uv: SIMD2<Double> { SIMD2(u, v) }
}

/// A junction between two consecutive smooth pieces, with the bounce test result.
public struct IndependentJunction: Sendable {
    public let a: Int, b: Int
    public let t: Double            // seconds
    public let u: Double, v: Double
    public let miss: Double
    public var ground: SIMD3<Double>?
    public var bounce = false
    /// Passed only the shorter second-chance test; used for the volley rule, not as a flight end.
    public var secondChanceBounce = false
}

/// Tracks -> smooth pieces -> junctions -> bounce tests (`tracks.py`, `segment2d.py`, `junctions.py`).
public enum IndependentBallEvents {
    static let fps = 60.0

    // MARK: candidates -> tracks (decode-order frame counter, as make_tracks.py)

    /// A track of fewer than `stubPoints` points is dropped after `stubGap` missing frames, not `maxGap`
    /// (2026-11-11). Two stray candidates have no velocity worth extrapolating: left to wait ten frames, their
    /// gate grows to 90 px and they take the first points of the next flight (tt night video 1330.5: a far
    /// serve's track began 12 frames early, its contact 0.15 s early, its speed 93 for 116 km/h).
    static let stubPoints = 4, stubGap = 3
    public static func tracks(from candidates: [IndependentShotCandidate], minPeak: Double = 0.3, maxGap: Int = 10) -> [[IndependentTrackPoint]] {
        guard let first = candidates.map(\.decodeIndex).min(), let last = candidates.map(\.decodeIndex).max() else { return [] }
        var byFrame = [Int: [IndependentShotCandidate]]()
        var timeOf = [Int: Double]()
        for c in candidates {
            timeOf[c.decodeIndex] = c.time
            if c.peak >= minPeak { byFrame[c.decodeIndex, default: []].append(c) }
        }
        // track points use the decode index while linking; times are swapped in at the end
        var active = [[(f: Int, u: Double, v: Double)]](), done = [[(f: Int, u: Double, v: Double)]]()
        for f in first...last {
            let cands = byFrame[f] ?? []
            var preds = [(SIMD2<Double>, Double)]()
            for tr in active {
                let lastF = tr[tr.count - 1].f
                let gap = Double(f - lastF)
                let recentAll = tr.filter { $0.f >= lastF - 15 }
                let recent = Array(recentAll.suffix(8))
                var pred: SIMD2<Double>, gate: Double
                if recent.count >= 4 {
                    let t = recent.map { Double($0.f - f) }
                    let pu = IndependentPoly(t: t, y: recent.map(\.u), degree: 2)
                    let pv = IndependentPoly(t: t, y: recent.map(\.v), degree: 2)
                    pred = SIMD2(pu.value(0), pv.value(0)); gate = 16 + 5 * (gap - 1)
                } else if recent.count >= 2 {
                    let r0 = recent[0], r1 = recent[recent.count - 1], lastPoint = tr[tr.count - 1]
                    let span = Double(max(1, r1.f - r0.f))
                    let du: Double = (r1.u - r0.u) / span, dv: Double = (r1.v - r0.v) / span
                    pred = SIMD2(lastPoint.u + du * gap, lastPoint.v + dv * gap); gate = 25 + 8 * (gap - 1)
                } else {
                    pred = SIMD2(tr[tr.count - 1].u, tr[tr.count - 1].v); gate = 60 + 10 * (gap - 1)
                }
                preds.append((pred, min(gate, 90)))
            }
            var pairs = [(Double, Int, Int)]()
            for (i, (pred, gate)) in preds.enumerated() {
                for (j, c) in cands.enumerated() {
                    let d = ((c.u - pred.x) * (c.u - pred.x) + (c.v - pred.y) * (c.v - pred.y)).squareRoot()
                    if d < gate { pairs.append((d / gate, i, j)) }
                }
            }
            pairs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2) }
            var ti = Set<Int>(), cj = Set<Int>()
            for (_, i, j) in pairs where !ti.contains(i) && !cj.contains(j) {
                ti.insert(i); cj.insert(j); active[i].append((f, cands[j].u, cands[j].v))
            }
            for (j, c) in cands.enumerated() where !cj.contains(j) { active.append([(f, c.u, c.v)]) }
            var keep = [[(f: Int, u: Double, v: Double)]]()
            for tr in active { if f - tr[tr.count - 1].f > (tr.count < stubPoints ? stubGap : maxGap) { done.append(tr) } else { keep.append(tr) } }
            active = keep
        }
        done += active
        var kept = [[(f: Int, u: Double, v: Double)]]()
        for tr in done where tr.count >= 5 {
            let us = tr.map(\.u), vs = tr.map(\.v)
            let ext = (pow(us.max()! - us.min()!, 2) + pow(vs.max()! - vs.min()!, 2)).squareRoot()
            if ext >= 20 { kept.append(tr) }
        }
        // sorted by first decode index (as make_tracks.py), then times become real presentation times
        return stableSorted(kept) { $0[0].f < $1[0].f }.map { tr in
            tr.map { IndependentTrackPoint(t: timeOf[$0.f] ?? Double($0.f), u: $0.u, v: $0.v) }
        }
    }

    // MARK: tracks -> smooth pieces

    static func predict(_ P: ArraySlice<IndependentTrackPoint>, lastIndex j: Int, window: Double = 0.3) -> SIMD2<Double>? {
        let pts = Array(P)
        let tj = pts[j].t / fps
        let idx = pts.indices.filter { let t = pts[$0].t / fps; return t < tj && t >= tj - window }
        if idx.count < 4 { return nil }
        let d = min(2, idx.count - 2)
        let tt = idx.map { pts[$0].t / fps - tj }
        let pu = IndependentPoly(t: tt, y: idx.map { pts[$0].u }, degree: d)
        let pv = IndependentPoly(t: tt, y: idx.map { pts[$0].v }, degree: d)
        return SIMD2(pu.value(0), pv.value(0))
    }

    /// Pieces [a, b): a point breaks when the quadratic fit of the previous <= 0.3 s misses it by more
    /// than tol (+2 px per missing frame); a cut needs `need` consecutive breaking points.
    static func splitTrack(_ P: [IndependentTrackPoint], tol: Double = 8, need: Int = 3, startPoints: Int = 5) -> [(Int, Int)] {
        let n = P.count
        var pieces = [(Int, Int)](), a = 0, j = startPoints
        while j < n {
            var k = 0
            while k < need && j + k < n {
                let Q = Array(P[a..<j]) + [P[j + k]]
                let pr = predict(Q[...], lastIndex: Q.count - 1)
                let gap = P[j + k].t - P[j - 1].t - 1
                if pr == nil || hypot(pr!.x - P[j + k].u, pr!.y - P[j + k].v) <= tol + 2 * gap { break }
                k += 1
            }
            if k == need { pieces.append((a, j)); a = j; j = a + startPoints } else { j += 1 }
        }
        pieces.append((a, n))
        return pieces.filter { $0.1 - $0.0 >= 3 }
    }

    public static func pieces(of tracks: [[IndependentTrackPoint]]) -> [[IndependentTrackPoint]] {
        piecesAndTossEnds(of: tracks).pieces
    }

    /// Smooth pieces in start order, and the indices of pieces that end where a serve toss turns into the
    /// serve inside what `splitTrack` kept as one piece (`tossCut`).
    public static func piecesAndTossEnds(of tracks: [[IndependentTrackPoint]]) -> (pieces: [[IndependentTrackPoint]], tossEnds: Set<Int>) {
        var out = [([IndependentTrackPoint], Bool)]()
        for P in tracks {
            for (a, b) in splitTrack(P) where b - a >= 4 {
                if let k = tossCut(P[a..<b]) {
                    out.append((Array(P[a..<k]), true)); out.append((Array(P[k..<b]), false))
                } else {
                    out.append((Array(P[a..<b]), false))
                }
            }
        }
        let sorted = stableSorted(out) { (x: ([IndependentTrackPoint], Bool), y: ([IndependentTrackPoint], Bool)) -> Bool in x.0[0].t < y.0[0].t }
        let tossEnds = Set<Int>(sorted.indices.filter { (i: Int) -> Bool in sorted[i].1 })
        return (sorted.map { (piece: ([IndependentTrackPoint], Bool)) -> [IndependentTrackPoint] in piece.0 }, tossEnds)
    }

    /// Serve toss turning into the serve inside one piece (v15). A far serve starts slowly in the image, so
    /// the quadratic predictor of `splitTrack` bends with it and the toss and the serve stay one piece (hit
    /// time early, serve fit polluted). Cut where a vertical stretch (>= 0.15 s and 9 points in the last 0.6 s,
    /// >= 15 px high, sideways range <= max(8 px, 0.35 x its height), at or past its apex) turns sideways: the
    /// horizontal image speed of the next 6 points differs from the previous 6 by >= 2 px/frame and is
    /// >= 2.5 x it. The first such index, moved to the largest change within 3 more points. One pass over
    /// the piece with bounded windows: O(points). v25: 0.15 s (was 0.2 s and 12 points), for a far toss the
    /// tracker picks up only on its way down.
    static func tossCut(_ P: ArraySlice<IndependentTrackPoint>, window W: Int = 6, minBefore: Int = 9) -> Int? {
        let Q = Array(P), n = Q.count
        guard n >= minBefore + W else { return nil }
        func uSlope(_ lo: Int, _ hi: Int) -> Double {        // least-squares du/dt (px per frame) over Q[lo..<hi]
            let m = Double(hi - lo)
            var st = 0.0, su = 0.0
            for i in lo..<hi { st += Q[i].t; su += Q[i].u }
            let mt = st / m, mu = su / m
            var num = 0.0, den = 0.0
            for i in lo..<hi { let dt = Q[i].t - mt; num += dt * (Q[i].u - mu); den += dt * dt }
            return den > 0 ? num / den : 0
        }
        func change(_ j: Int) -> Double { abs(uSlope(j, j + W) - uSlope(j - W, j)) }
        for j in minBefore...(n - W) {
            let lo = max(0, j - 36)
            guard (Q[j - 1].t - Q[lo].t) / fps >= 0.15 else { continue }
            var vMin = Double.infinity, vMax = -Double.infinity, uMin = Double.infinity, uMax = -Double.infinity, apex = lo
            for i in lo..<j {
                if Q[i].v < vMin { vMin = Q[i].v; apex = i }
                vMax = max(vMax, Q[i].v); uMin = min(uMin, Q[i].u); uMax = max(uMax, Q[i].u)
            }
            let vr = vMax - vMin
            guard vr >= 15, uMax - uMin <= max(8, 0.35 * vr) else { continue }
            if apex >= j - 2 && Q[j - 1].v < Q[j - 3].v { continue }     // still rising: a hit follows the apex
            let before = uSlope(j - W, j), after = uSlope(j, j + W)
            guard abs(after - before) >= 2, abs(after) >= 2.5 * max(abs(before), 0.6) else { continue }
            var best = j, bestChange = abs(after - before)
            for k in (j + 1)..<min(j + 4, n - W + 1) where change(k) > bestChange { best = k; bestChange = change(k) }
            return P.startIndex + best
        }
        return nil
    }

    /// Least-squares du/dt (px per frame) of a run of points.
    static func uSlope(_ Q: ArraySlice<IndependentTrackPoint>) -> Double {
        let m = Double(Q.count)
        var st = 0.0, su = 0.0
        for q in Q { st += q.t; su += q.u }
        let mt = st / m, mu = su / m
        var num = 0.0, den = 0.0
        for q in Q { let dt = q.t - mt; num += dt * (q.u - mu); den += dt * dt }
        return den > 0 ? num / den : 0
    }

    /// `tossCut` across a junction (v17): A ends in a toss (>= 0.2 s of mostly vertical image motion over
    /// its last <= 36 points) and B leaves with the sideways image speed of a serve. On a far serve, or a
    /// near server half out of the frame, no person box is found at the contact, and without this the toss
    /// and the serve were chained into one flight that no physics fit explains.
    static func tossThenServe(_ A: [IndependentTrackPoint], _ B: [IndependentTrackPoint], window W: Int = 6) -> Bool {
        guard A.count >= W, B.count >= W else { return false }
        let lo = max(0, A.count - 36)
        guard (A[A.count - 1].t - A[lo].t) / fps >= 0.2 else { return false }
        let tail = A[lo...]
        let vr: Double = tail.map(\.v).max()! - tail.map(\.v).min()!
        let ur: Double = tail.map(\.u).max()! - tail.map(\.u).min()!
        guard vr >= 15, ur <= max(8, 0.35 * vr) else { return false }
        let before = uSlope(A.suffix(W)), after = uSlope(B.prefix(W))
        return abs(after - before) >= 2 && abs(after) >= 2.5 * max(abs(before), 0.6)
    }

    static func localPoly(_ P: [IndependentTrackPoint], atEnd: Bool, n: Int = 8) -> (IndependentPoly, IndependentPoly) {
        let Q = atEnd ? Array(P.suffix(n)) : Array(P.prefix(n))
        let t = Q.map { $0.t / fps }
        let d = max(0, min(2, Q.count - 2))    // a one- or two-point piece asked for a negative degree, which the fit traps on
        return (IndependentPoly(t: t, y: Q.map(\.u), degree: d), IndependentPoly(t: t, y: Q.map(\.v), degree: d))
    }

    /// A ends, B starts: time (s), pixel and miss (px) at the closest approach of their extrapolations.
    static func kink(_ A: [IndependentTrackPoint], _ B: [IndependentTrackPoint]) -> (Double, SIMD2<Double>, Double) {
        let (ua, va) = localPoly(A, atEnd: true), (ub, vb) = localPoly(B, atEnd: false)
        let t0 = A[A.count - 1].t / fps, t1 = B[0].t / fps
        let count = max(5, Int((t1 - t0) * fps * 8) + 5)
        let lo = t0 - 1 / fps, hi = t1 + 1 / fps
        var best = (0.0, SIMD2<Double>(0, 0), Double.infinity)
        for i in 0..<count {
            let ts = count == 1 ? lo : lo + Double(i) * (hi - lo) / Double(count - 1)
            let da = SIMD2(ua.value(ts), va.value(ts)), db = SIMD2(ub.value(ts), vb.value(ts))
            let d = simd_length(da - db)
            if d < best.2 { best = (ts, (da + db) / 2, d) }
        }
        return best
    }

    /// Image-direction turn (degrees) between the end of A and the start of B.
    static func turnDegrees(_ A: [IndependentTrackPoint], _ B: [IndependentTrackPoint]) -> Double {
        let (ua, va) = localPoly(A, atEnd: true), (ub, vb) = localPoly(B, atEnd: false)
        let ta = A[A.count - 1].t / fps, tb = B[0].t / fps
        let da = SIMD2(ua.derivative(ta), va.derivative(ta)), db = SIMD2(ub.derivative(tb), vb.derivative(tb))
        let c = simd_dot(da, db) / max(simd_length(da) * simd_length(db), 1e-9)
        return acos(min(1, max(-1, c))) * 180 / .pi
    }

    /// Best successor for each piece (one-to-one, smallest kink miss); gaps up to 24 frames.
    ///
    /// With a camera, a flight that would end on a dead-end fragment (a blip with no successor of its own) is
    /// re-pointed to a piece the bounce test verifies (2026-11-06). At double-test-003 142.8 the flight from
    /// the far hit ended on a five-point fragment and the real landing, 21.7 px of kink away, was never used;
    /// re-pointing recovers that call while every other call and speed row stays (docs/verification.md).
    public static func junctions(_ pcs: [[IndependentTrackPoint]], maxGap: Double = 24, maxMiss: Double = 25,
                                 camera cam: IndependentProjector? = nil) -> [IndependentJunction] {
        let starts = pcs.map { $0[0].t }
        var cand = [(Double, Int, Int, Double, SIMD2<Double>)]()
        for (i, A) in pcs.enumerated() {
            let e = A[A.count - 1].t
            for j in pcs.indices where starts[j] > e - 3 && starts[j] <= e + maxGap && j != i {
                let B = pcs[j]
                if B[B.count - 1].t <= e { continue }
                let (t, uv, miss) = kink(A, B)
                if miss < maxMiss && A[A.count - 1].t - 4 <= t * fps && t * fps <= B[0].t + 4 { cand.append((miss, i, j, t, uv)) }
            }
        }
        cand.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2) }
        var usedA = Set<Int>(), usedB = Set<Int>(), links = [IndependentJunction]()
        for (miss, i, j, t, uv) in cand where !usedA.contains(i) && !usedB.contains(j) {
            usedA.insert(i); usedB.insert(j)
            links.append(IndependentJunction(a: i, b: j, t: t, u: uv.x, v: uv.y, miss: miss))
        }
        guard let cam else { return links }
        // a blip that ends a flight must not hide the landing the ball really made: a link the bounce test
        // verifies may take over from a dead-end fragment (2026-11-06, docs/verification.md)
        var landingOf = [Int: (t: Double, uv: SIMD2<Double>)]()   // candidate (a, b) -> its kink
        for (_, i, j, t, uv) in cand { landingOf[i * 100000 + j] = (t, uv) }
        var verified = [Int: Bool]()
        func landing(_ a: Int, _ b: Int) -> Bool {
            let key = a * 100000 + b
            if let v = verified[key] { return v }
            guard let q = landingOf[key] else { return false }
            let v = verifiedLanding(pcs, a, b, t: q.t, uv: q.uv, camera: cam)
            verified[key] = v
            return v
        }
        let hasSucc = Set(links.map(\.a))
        var linkOfA = [Int: Int](), predOf = [Int: Int]()
        for (k, l) in links.enumerated() { linkOfA[l.a] = k; predOf[l.b] = k }
        for (miss, i, j, t, uv) in cand {
            // the fits only run for a candidate that could replace a blip, which is a handful per segment
            guard var k = linkOfA[i] else { continue }
            let c = links[k].b
            guard c != j, pcs[c].count <= deadEndPoints, !hasSucc.contains(c) else { continue }
            guard landing(i, j) else { continue }
            if let pk = predOf[j] {
                if landing(links[pk].a, j) { continue }   // that end already shows a landing
                links.remove(at: pk)
                linkOfA = [:]; predOf = [:]
                for (n, l) in links.enumerated() { linkOfA[l.a] = n; predOf[l.b] = n }
                // removing the predecessor shifts every later index, so the link's own index has to be
                // looked up again; using the old one wrote past the end of the array (2026-11-07)
                guard let again = linkOfA[i] else { continue }
                k = again
            }
            links[k] = IndependentJunction(a: i, b: j, t: t, u: uv.x, v: uv.y, miss: miss)
            predOf[j] = k
        }
        return links
    }

    /// A piece short enough to be a detection blip rather than a flight.
    static let deadEndPoints = 8

    /// True when the two pieces fit one flight either side of the kink, falling into it and rising out of it:
    /// the bounce test of `IndependentShotFlights.testBounce` (6 px, falling before, rising after), asked here
    /// to decide which link is the landing.
    static func verifiedLanding(_ pcs: [[IndependentTrackPoint]], _ a: Int, _ b: Int, t: Double,
                                uv: SIMD2<Double>, camera cam: IndependentProjector) -> Bool {
        let Pg = cam.onPlaneZ(uv.x, uv.y, z: IndependentCourt.ballRadius)
        guard -8 < Pg.y, Pg.y < 32, abs(Pg.x) < 9 else { return false }
        let A = Array(pcs[a].suffix(25)), B = Array(pcs[b].prefix(15))
        guard A.count >= 4, B.count >= 4 else { return false }
        let tt = t * fps
        let fa = IndependentFlight.bestAnchored(cam, frames: A.map(\.t), uv: A.map(\.uv), anchor: Pg, at: tt, before: true)
        guard fa.rms <= 6, fa.velocity.z < 0 else { return false }
        let fb = IndependentFlight.bestAnchored(cam, frames: B.map(\.t), uv: B.map(\.uv), anchor: Pg, at: tt, before: false)
        return fb.rms <= 6 && 0 < fb.velocity.z
    }

    /// Bounce test: both sides fit a flight anchored at the junction's ground point within 6 px, falling
    /// before and rising after. The former 4 px limit missed bounces whose two fits were only marginally
    /// worse: 5 px recovered near-side calls on both development videos (all consistent with the reference
    /// app) and on the held-out ones, at the cost of one call that merges into a long piece; 6 px adds one
    /// more on the first development video and five on the held-out ones with no call lost anywhere (see
    /// docs/verification.md, 2026-11-06). A shorter-window second chance (5.5 px) is recorded separately.
    public static func testBounce(_ junction: inout IndependentJunction, pieces pcs: [[IndependentTrackPoint]], camera cam: IndependentProjector) {
        let Pg = cam.onPlaneZ(junction.u, junction.v, z: IndependentCourt.ballRadius)
        junction.ground = Pg
        guard -8 < Pg.y && Pg.y < 32 && abs(Pg.x) < 9 else { return }
        let A = Array(pcs[junction.a].suffix(25)), B = Array(pcs[junction.b].prefix(15))
        guard A.count >= 4 && B.count >= 4 else { return }
        let t = junction.t * fps
        let fa = IndependentFlight.bestAnchored(cam, frames: A.map(\.t), uv: A.map(\.uv), anchor: Pg, at: t, before: true)
        let fb = IndependentFlight.bestAnchored(cam, frames: B.map(\.t), uv: B.map(\.uv), anchor: Pg, at: t, before: false)
        junction.bounce = fa.rms <= 6 && fb.rms <= 6 && fa.velocity.z < 0 && 0 < fb.velocity.z
        if !junction.bounce && B.count >= 6 {
            let A2 = Array(A.suffix(15)), B2 = Array(B.prefix(8))
            let fa2 = IndependentFlight.bestAnchored(cam, frames: A2.map(\.t), uv: A2.map(\.uv), anchor: Pg, at: t, before: true)
            let fb2 = IndependentFlight.bestAnchored(cam, frames: B2.map(\.t), uv: B2.map(\.uv), anchor: Pg, at: t, before: false)
            junction.secondChanceBounce = fa2.rms <= 5.5 && fb2.rms <= 5.5 && fa2.velocity.z < -1.0 && fb2.velocity.z > 0.5
        }
    }

    static func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
        a.enumerated().sorted { less($0.element, $1.element) || (!less($1.element, $0.element) && $0.offset < $1.offset) }.map(\.element)
    }
}
