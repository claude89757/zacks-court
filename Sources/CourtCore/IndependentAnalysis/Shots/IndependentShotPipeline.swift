import Foundation
import simd

/// The in-house shot chain (rules frozen as development run v13 on test.MOV, cross-checked on
/// double-test-003, see docs/speed-model-training.md; v14 replaced the serve rule and drops serve
/// tosses; v15 cuts a toss that turns into the serve inside one tracked piece; v16 gives serves without a
/// bounce a speed from the server's baseline or from a bounce found inside the serve's track; v17 splits a
/// toss from the serve at their junction, calls serves from a refit of the flight's first 0.6 s with the
/// contact at the server's baseline, and fits serve speeds with a service-box landing prior; v18 trims a
/// toss glued to the serve's start, times serves into the net at the net plane, tries the other end's serve
/// on a low camera, and only lets accepted flights count as rally evidence; v19 measures a glued toss's
/// contact from the toss itself (a free fit: gravity sets its distance from the camera) and anchors the serve
/// refit there, finds the contact where the ball leaves the toss parabola, and in the live window revises
/// the published shot with the same flight start; v20 gives serves whose bounce-anchored fit was rejected a
/// speed from the bounce refit, which is accepted up to 6 px RMS; v21 does not let a serve speed refit put the
/// contact before the ball was last seen in the toss or on its way to the flight's first point; v22 bounds the
/// serve hypothesis by the toss's end as well, counts a toss glued to a flight's start as leaving a toss, prefers
/// the later of two same-end serve candidates when the earlier did not cross the net and ended before it,
/// rejects serve candidates whose fitted flight climbs over 1 m, and on a low camera takes an own-fit serve
/// only with its contact within 2.5 m of the server's baseline; v23 shows a serve that crosses the net with
/// S家's speed, the endpoint speed from the contact to the first bounce, not to the net).
/// Inputs: TrackNetV3 ball candidates, a camera per segment and Apple Vision person boxes.
/// Outputs per-shot stroke type and a speed only when the flight is anchored at a detected bounce (serves:
/// or at the server's baseline under the serve checks).
/// Results are model estimates, not measurements.
public enum IndependentShotPipeline {
    public static let rulesVersion = "independent-shots-v27"

    /// A stretch of video with one fixed camera (a camera that moved needs a new segment).
    public struct Segment: Sendable {
        public var camera: IndependentPinholeCamera
        public var start: Double                 // seconds, inclusive
        public var end: Double                   // seconds, exclusive
        public init(camera: IndependentPinholeCamera, start: Double = 0, end: Double = .infinity) {
            self.camera = camera; self.start = start; self.end = end
        }
    }

    /// Ball events of one segment, before person boxes are needed.
    public struct SegmentEvents: Sendable {
        public let pieces: [[IndependentTrackPoint]]
        public let junctions: [IndependentJunction]
        /// Pieces that end where a serve toss turns into the serve inside one tracked piece (v15).
        public var tossEnds: Set<Int> = []
        /// Frames (1/60 s units) where person boxes are needed: around junctions and piece starts.
        public var personFrames: [Int] {
            var fr = Set<Int>()
            let hasPred = Set(junctions.map(\.b))
            for l in junctions { let k = IndependentNumerics.pyRound(l.t * 60); fr.insert(k - 2); fr.insert(k) }
            for (i, Q) in pieces.enumerated() where !hasPred.contains(i) {
                let k = IndependentNumerics.pyRound(Q[0].t); for d in [12, 6, 3, 0] { fr.insert(k - d) }
            }
            return fr.filter { $0 >= 0 }.sorted()
        }
    }

    public static func events(candidates: [IndependentShotCandidate], segment: Segment) -> SegmentEvents {
        let inside = candidates.filter { $0.time / 60 >= segment.start && $0.time / 60 < segment.end }
        let (pcs, tossEnds) = IndependentBallEvents.piecesAndTossEnds(of: IndependentBallEvents.tracks(from: inside))
        let cam = IndependentProjector(segment.camera)
        var links = IndependentBallEvents.junctions(pcs, camera: cam)
        links.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: buffer.count) { i in
                IndependentBallEvents.testBounce(&base[i], pieces: pcs, camera: cam)
            }
        }
        return SegmentEvents(pieces: pcs, junctions: links, tossEnds: tossEnds)
    }

    /// Shot flights and fits of one segment.
    public static func shots(events: SegmentEvents, people: IndependentPeople, segment: Segment, index: Int) -> [IndependentShotResult] {
        fits(events: events, people: people, segment: segment, index: index).map(\.1)
    }

    /// Flights with their fitted results (deduplicated like `shots`).
    static func fits(events: SegmentEvents, people: IndependentPeople, segment: Segment, index: Int) -> [(IndependentShotFlight, IndependentShotResult)] {
        let cam = IndependentProjector(segment.camera)
        let jobs = IndependentShotFlights.flights(pieces: events.pieces, junctions: events.junctions, people: people, camera: cam,
                                                  tossEnds: events.tossEnds)
        var results = [IndependentShotResult?](repeating: nil, count: jobs.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                var r = IndependentShotFlights.analyse(jobs[i], camera: cam); r.segment = index
                if IndependentStrokeRules.lowCamera(cam) { r.lowCamera = true }
                base[i] = r
            }
        }
        let pairs: [(IndependentShotFlight, IndependentShotResult)] = jobs.indices.map { (i: Int) -> (IndependentShotFlight, IndependentShotResult) in (jobs[i], results[i]!) }
        return IndependentShotFlights.deduplicate(pairs) { (p: (IndependentShotFlight, IndependentShotResult)) -> IndependentShotResult in p.1 }
    }

    /// Whole video: events and shots per segment, merged in time order, then stroke types.
    /// `priorRally`: hit times of rally flights before these candidates (the live window's earlier
    /// published shots), so the dead-ball test of a serve does not depend on where the window starts.
    public static func run(candidates: [IndependentShotCandidate], segments: [Segment], priorRally: [Double] = [],
                           people: (Int, SegmentEvents) throws -> IndependentPeople) rethrows -> [IndependentShotResult] {
        var cache: ServeRefitCache?
        return try run(candidates: candidates, segments: segments, priorRally: priorRally, serveCache: &cache, people: people)
    }

    /// Serve refits keyed by everything they read: the live window recomputes the same serve on every
    /// update, and a refit of the same inputs gives the same result.
    public struct ServeRefitCache: Sendable {
        struct Key: Hashable {
            var points: [IndependentTrackPoint], tHit: Double, near: Bool, hadBounce: Bool, camera: IndependentPinholeCamera
            var hypothesis = 0           // 0: serve refit (speed), 1: hypothesis (recognition), 2: hypothesis (speed),
                                         // 3: bounce refit, 4: net refit, 5: net drop from the track (v24)
        }
        var entries: [Key: IndependentShotResult?] = [:]
        public init() {}
        /// Forget refits of serves hit before `t` (seconds).
        mutating func prune(before t: Double) {
            entries = entries.filter { (e: (key: Key, value: IndependentShotResult?)) -> Bool in e.key.tHit >= t * IndependentShotFlights.fps }
        }
    }

    static func run(candidates: [IndependentShotCandidate], segments: [Segment], priorRally: [Double],
                    serveCache: inout ServeRefitCache?, people: (Int, SegmentEvents) throws -> IndependentPeople) rethrows -> [IndependentShotResult] {
        var pairs = [(IndependentShotFlight, IndependentShotResult)](), bounces = [(Double, Double)](), crowd = [IndependentPeople]()
        for (k, segment) in segments.enumerated() {
            let ev = events(candidates: candidates, segment: segment)
            let p = try people(k, ev)
            crowd.append(p)
            pairs += fits(events: ev, people: p, segment: segment, index: k)
            bounces += ev.junctions.filter { $0.bounce || $0.secondChanceBounce }.compactMap { l in l.ground.map { (l.t, $0.y) } }
        }
        pairs = IndependentBallEvents.stableSorted(pairs) { $0.1.tHit < $1.1.tHit }
        var shots = pairs.map(\.1)
        let cameras = segments.map { IndependentProjector($0.camera) }
        func cached(_ i: Int, near: Bool, hypothesis: Int, job keyJob: IndependentShotFlight? = nil, _ f: () -> IndependentShotResult?) -> IndependentShotResult? {
            guard serveCache != nil else { return f() }
            let job = keyJob ?? pairs[i].0
            let key = ServeRefitCache.Key(points: job.points, tHit: job.tHit, near: near, hadBounce: job.bounce != nil,
                                          camera: segments[shots[i].segment].camera, hypothesis: hypothesis)
            if let c = serveCache!.entries[key] { return c }
            let r = f(); serveCache!.entries[key] = r
            return r
        }
        // serve hypothesis (v17) for point starts whose own fit is not serve-like
        var contact = [Int: Double]()     // serve refits' contact times (a glued toss trimmed, v18)
        for (i, near, speedOnly) in IndependentStrokeRules.hypothesisCandidates(shots, cameras: cameras, priorRally: priorRally) {
            let job = pairs[i].0, cam = cameras[shots[i].segment]
            if let h = cached(i, near: near, hypothesis: 1, { IndependentShotFlights.serveHypothesis(job, near: near, camera: cam) }) {
                shots[i].serveFit = true; shots[i].serveRise = h.riseM; contact[i] = h.tHit
            } else if shots[i].hitterBox != nil, IndependentStrokeRules.lowCamera(cam),
                      let h = cached(i, near: !near, hypothesis: 1, { IndependentShotFlights.serveHypothesis(job, near: !near, camera: cam) }) {
                shots[i].serveFit = true; shots[i].serveRise = h.riseM; shots[i].serveOtherEnd = true; shots[i].hitterSide = near ? "far" : "near"; contact[i] = h.tHit
            } else if speedOnly, cached(i, near: near, hypothesis: 0, { IndependentShotFlights.serveSpeed(job, near: near, camera: cam) }) != nil {
                shots[i].serveFit = true    // the whole flight refitted from the server's baseline is a serve
            } else if let nj = IndependentShotFlights.netJob(job, near: near, camera: cam),
                      let h = cached(i, near: near, hypothesis: 5, job: nj, { IndependentShotFlights.serveNetHypothesis(nj, near: near, camera: cam) }) {
                shots[i].serveFit = true; shots[i].serveRise = h.riseM; contact[i] = h.tHit    // a serve into the net (v24)
            }
        }
        // the near server's raised arm names the serve where the ball's first metres were not tracked (v27)
        for (k, people) in crowd.enumerated() {
            for e in IndependentStrokeRules.poseServes(people, camera: cameras[k]) {
                guard let i = IndependentStrokeRules.poseServeShot(e, shots: shots, segment: k) else { continue }
                shots[i].poseServe = true; shots[i].hitterSide = "near"
                let t = e.end + IndependentStrokeRules.PoseServe.contactLag
                if contact[i] == nil, t > shots[i].tHit + IndependentStrokeRules.PoseServe.early { contact[i] = t }
            }
        }
        IndependentStrokeRules.classify(&shots, bounces: bounces, cameras: cameras, priorRally: priorRally)
        // serves into the net: the "bounce" next to the net is where the ball met it (v18)
        for i in shots.indices where shots[i].stroke == "发球" {
            guard let side = shots[i].hitterSide, let b = pairs[i].0.bounce, abs(b.ground.y - IndependentCourt.netY) <= IndependentShotFlights.ServeSpeed.netBounceY else { continue }
            let job = pairs[i].0, near = side == "near", cam = cameras[shots[i].segment]
            if let r = cached(i, near: near, hypothesis: 4, { IndependentShotFlights.serveNetRefit(job, near: near, camera: cam) }) {
                applyServeSpeed(r, to: &shots[i]); shots[i].bounceFound = false; shots[i].serveSpeedFrom = "net"
            }
        }
        // serves into the net the tracker did not split (v24): the track drops at the foot of the net
        for i in shots.indices where shots[i].stroke == "发球" && shots[i].serveSpeedFrom != "net" {
            guard let side = shots[i].hitterSide else { continue }
            let job = pairs[i].0, near = side == "near", cam = cameras[shots[i].segment]
            guard !(job.bounce.map { abs($0.ground.y - IndependentCourt.netY) <= IndependentShotFlights.ServeSpeed.netBounceY } ?? false),
                  let nj = IndependentShotFlights.netJob(job, near: near, camera: cam) else { continue }
            if let r = cached(i, near: near, hypothesis: 5, job: nj, { IndependentShotFlights.serveNetHypothesis(nj, near: near, camera: cam) }) {
                applyServeSpeed(r, to: &shots[i]); shots[i].bounceFound = false; shots[i].bounceGround = nil; shots[i].tBounce = nil
                shots[i].serveSpeedFrom = "net"
            }
        }
        // serves with a bounce-anchored speed: the same bounce, with the contact at the server's baseline (v17)
        for i in shots.indices where shots[i].stroke == "发球" && shots[i].reportedSpeedKmh != nil && shots[i].speedAnchor == nil {
            guard let side = shots[i].hitterSide else { continue }
            let job = pairs[i].0, near = side == "near", cam = cameras[shots[i].segment]
            if let r = cached(i, near: near, hypothesis: 3, { IndependentShotFlights.serveBounceRefit(job, near: near, camera: cam) }) {
                shots[i].speedKmh = r.speedKmh; shots[i].vInstKmh = r.vInstKmh; shots[i].intervalS = r.intervalS
                shots[i].endKind = r.endKind; shots[i].fitNetZ = r.fitNetZ; shots[i].fitNetX = r.fitNetX; shots[i].serveSpeedFrom = "bounce refit"
                shots[i].landSpeedKmh = r.landSpeedKmh; shots[i].landY = r.landY
            }
        }
        // serves without a bounce-anchored speed: refit from the server's baseline (v16)
        for i in shots.indices where shots[i].stroke == "发球" && shots[i].reportedSpeedKmh == nil {
            // a serve known only by landing short of the net (v27) has no flight to the other side to time:
            // the refits read 61 and 49 km/h where the reference has 115 and 95, so it stays without a speed
            if shots[i].crossesNet != true, shots[i].serveFit != true, IndependentStrokeRules.isShortFault(shots[i]) { continue }
            guard let side = shots[i].hitterSide else { continue }
            let job = pairs[i].0, near = side == "near", cam = cameras[shots[i].segment]
            if let r = cached(i, near: near, hypothesis: 0, { IndependentShotFlights.serveSpeed(job, near: near, camera: cam) }) {
                applyServeSpeed(r, to: &shots[i]); shots[i].serveSpeedFrom = "refit"
            } else if var h = cached(i, near: near, hypothesis: 2, { IndependentShotFlights.serveHypothesis(job, near: near, camera: cam, landing: true) }),
                      IndependentShotFlights.hypothesisSpeedShown(h) {
                if h.speedAnchor == nil { h.speedAnchor = .serveBaseline }
                applyServeSpeed(h, to: &shots[i]); shots[i].serveSpeedFrom = "hypothesis"
            } else if job.bounce != nil,    // a bounce whose own fit was rejected: the bounce refit (v20)
                      let r = cached(i, near: near, hypothesis: 3, { IndependentShotFlights.serveBounceRefit(job, near: near, camera: cam) }) {
                applyServeSpeed(r, to: &shots[i]); shots[i].serveSpeedFrom = "bounce refit (rejected fit)"
            }
        }
        // a serve is reported at its refit's contact when a glued toss was trimmed (v18); `tHit` stays the
        // flight's own (the live window matches shots by it)
        for i in shots.indices where shots[i].stroke == "发球" {
            if let t = contact[i], t > shots[i].tHit + 0.1 { shots[i].contactT = t }
        }
        // serve speeds as S家 defines them (v23): hit to the first bounce past the net, not hit to net.
        // Serves into the net keep the hit-to-net speed, to the measured net contact (v24): the net refit's
        // anchor, where the fitted flight's own net crossing can come early.
        for i in shots.indices where shots[i].stroke == "发球" && shots[i].reportedSpeedKmh != nil {
            if shots[i].serveSpeedFrom == "net", let v = shots[i].landSpeedKmh { shots[i].speedKmh = v; continue }
            guard shots[i].serveSpeedFrom != "net", let v = shots[i].landSpeedKmh, let y = shots[i].landY,
                  abs(y - IndependentCourt.netY) > IndependentShotFlights.ServeSpeed.netBounceY,
                  (shots[i].fitNetZ ?? 0) >= IndependentStrokeRules.Serve.landNetZ else { continue }
            shots[i].speedKmh = v; shots[i].speedTo = "bounce"
        }
        // a "serve" under 45 km/h is a contact timed too early (a toss glued to the flight) or not a serve (v27):
        // on the two night videos all ten such speeds were wrong, four real serves read at half their speed
        // and six flights the reference does not call serves. The row stays; the speed is not shown.
        for i in shots.indices where shots[i].stroke == "发球" {
            guard let v = shots[i].reportedSpeedKmh, v < IndependentStrokeRules.Serve.shownFromKmh else { continue }
            shots[i].slowServe = true
            if shots[i].reason == nil { shots[i].reason = "serve speed under 45 km/h, contact time not believed" }
        }
        for i in shots.indices { shots[i].bounceSigma = bounceSigma(shots[i], camera: cameras[shots[i].segment]) }
        return shots
    }

    /// Image noise of a bounce, in pixels, for its uncertainty on the ground.
    static let bouncePixelSigma = 2.0

    /// Standard deviations (m) of a bounce's ground x and y: `bouncePixelSigma` through the ground
    /// mapping's Jacobian at the bounce, plus half a frame of ground travel (the bounce falls between frames).
    static func bounceSigma(_ s: IndependentShotResult, camera: IndependentProjector) -> [Double]? {
        guard let b = s.bounceGround, b.count >= 2 else { return nil }
        let p = camera.project(SIMD3(b[0], b[1], 0))
        guard p.depth > 0 else { return nil }
        let g0 = camera.onPlaneZ(p.u, p.v, z: 0), gu = camera.onPlaneZ(p.u + 1, p.v, z: 0), gv = camera.onPlaneZ(p.u, p.v + 1, z: 0)
        let ju = gu - g0, jv = gv - g0
        let px2 = bouncePixelSigma * bouncePixelSigma
        var sxx = px2 * (ju.x * ju.x + jv.x * jv.x), syy = px2 * (ju.y * ju.y + jv.y * jv.y)
        if let h = s.fitHit, h.count >= 2, let tb = s.tBounce, tb - s.tHit > 0.1 {
            let T = tb - s.tHit, step = 0.5 / IndependentShotFlights.fps
            let vx = (b[0] - h[0]) / T, vy = (b[1] - h[1]) / T
            sxx += (vx * step) * (vx * step); syy += (vy * step) * (vy * step)
        }
        guard sxx.isFinite, syy.isFinite else { return nil }
        return [sxx.squareRoot(), syy.squareRoot()]
    }

    /// Speed fields of a serve refit. Fit quality, hit time and stroke fields stay those of the original
    /// flight: the serve and rally rules (and the live window's history) read them.
    static func applyServeSpeed(_ r: IndependentShotResult, to s: inout IndependentShotResult) {
        s.speedKmh = r.speedKmh; s.vInstKmh = r.vInstKmh; s.intervalS = r.intervalS; s.endKind = r.endKind
        s.fitNetZ = r.fitNetZ; s.fitNetX = r.fitNetX; s.accepted = r.accepted; s.reason = r.reason; s.speedAnchor = r.speedAnchor
        s.landSpeedKmh = r.landSpeedKmh; s.landY = r.landY
        if r.speedAnchor == .serveBounce {
            s.bounceFound = true; s.bounceGround = r.bounceGround; s.tBounce = r.tBounce
        }
    }

    /// App rows: every detected hit, with a speed only when it passed the bounce-anchored gate.
    /// Rows carry finite numbers only: a value a degenerate fit left NaN or infinite is unknown (nil), so
    /// it can never block saving the record (JSON has no NaN; 2026-11-05 a camera showed 「记录保存失败」).
    public static func rows(from shots: [IndependentShotResult], streamID: UUID, ptsOffset: Double = 0) -> [TennisShotEvent] {
        func finite(_ values: [Double]?, count: Int) -> [Double]? {
            guard let values, values.count >= count, values.prefix(count).allSatisfy(\.isFinite) else { return nil }
            return values
        }
        return shots.filter(keeps).map { s in
            let speed = s.reportedSpeedKmh.flatMap { $0.isFinite ? $0 : nil }
            var row = TennisShotEvent(streamID: streamID, sourcePTS: (s.contactT ?? s.tHit) + ptsOffset, stroke: IndependentStrokeRules.kind(s.stroke),
                                      confidence: 0, speedKPH: speed, speedReason: speed == nil ? reasonText(s) : nil, sampleCount: s.nObs)
            if speed == nil { row.speedReasonCode = reasonCode(s) }
            if let g = finite(s.bounceGround, count: 2), let t = s.tBounce, t.isFinite {
                row.bounce = TennisBounceEstimate(sourcePTS: t + ptsOffset, xMeters: IndependentCourt.courtX(fromCentred: g[0]), yMeters: g[1],
                                                  confidence: 0, reason: "模型估计，不是判罚")
                row.bounce?.reasonCode = .estimate
                if let sg = finite(s.bounceSigma, count: 2) { row.bounce?.sigmaXMeters = sg[0]; row.bounce?.sigmaYMeters = sg[1] }
            }
            if let h = finite(s.fitHit, count: 3) { row.hit = TennisCourtPoint(x: IndependentCourt.courtX(fromCentred: h[0]), y: h[1], z: h[2]) }
            row.origin = "independent"
            return row
        }
    }

    /// Whether a shot becomes a row (2026-11-06). A shot with no bounce, no speed and a contact that is not
    /// even on the court has nothing to show: the night video writes 1264 of those for 325 real shots, 87 of
    /// them with a contact hundreds of metres away. Callers that pair rows with shots must filter by this.
    public static func keeps(_ s: IndependentShotResult) -> Bool {
        if s.bounceGround != nil { return true }
        if let v = s.reportedSpeedKmh, v.isFinite { return true }
        guard let h = s.fitHit, h.count >= 2, h[0].isFinite, h[1].isFinite else { return false }
        return HawkEye.contactUsable(TennisCourtPoint(x: IndependentCourt.courtX(fromCentred: h[0]), y: h[1],
                                                      z: h.count > 2 && h[2].isFinite ? h[2] : 0))
    }

    static func reasonCode(_ s: IndependentShotResult) -> TennisReason {
        if s.reason == "fewer than 8 ball observations between hit and bounce" || s.reason == "no initial flight hypothesis" { return .ballNotSeen }
        return s.bounceFound ? .speedUnreliable : .noBounceSeen
    }
    static func reasonText(_ s: IndependentShotResult) -> String {
        if let r = s.reason { return "自研：\(r)" }
        return s.bounceFound ? "自研：球速未通过检查" : "自研：没有触地锚点，不给球速"
    }
}

/// Stroke type rules (strokes.py with the v14 serve rule; right-handed default).
public enum IndependentStrokeRules {
    static let netY = IndependentCourt.netY

    static func kind(_ stroke: String?) -> TennisStrokeKind {
        switch stroke {
        case "发球": return .serve
        case "正手": return .forehand
        case "反手": return .backhand
        case "正手 截击", "反手 截击": return .volley
        default: return .unknown
        }
    }

    /// Feet behind the hitter's own baseline in the image, in box heights (positive: outside the court).
    /// Image-based, so far-court depth errors of the feet do not grow into metres.
    static func behindInBoxHeights(_ box: IndependentPersonBox, near: Bool, _ cam: IndependentProjector) -> Double? {
        let y = near ? 0 : IndependentCourt.length
        let a = cam.project(SIMD3(-6, y, 0)), b = cam.project(SIMD3(6, y, 0))
        guard a.depth > 0, b.depth > 0, abs(b.u - a.u) > 1 else { return nil }
        let uf = (box.x0 + box.x1) / 2
        let vb = a.v + (uf - a.u) / (b.u - a.u) * (b.v - a.v)
        return (near ? box.y1 - vb : vb - box.y1) / max(box.height, 1)
    }

    /// Serve rules (v14): a serve is the best serve-like flight after a dead ball.
    enum Serve {
        static let behindPx = -0.45...1.0        // feet at the own baseline, in box heights (image)
        static let minPoints = 15
        static let speedKmh = 20.0...250.0        // own-fit serve: a plausible fitted speed (v18)
        static let landNetZ = 0.8                 // hit-to-bounce serve speed (v23): the fitted flight clears the net at least this high, m
        static let lowCameraZ = 2.0               // camera height at most this: a low camera (v18)
        static let contactZ = 1.9...3.3          // fitted contact height, metres
        static let compete = 2.0                 // serve-like flights closer than this: one serve, most points wins
        static let returnWithin = 2.5            // a serve-like flight from the other end this soon after: the return
        static let ownDepth = 2.5                // own-fit serve: contact within this of the server's baseline, metres (v22)
        static let maxRise = 1.0                 // fitted climb above the contact at most this, metres (v22)
        static let restartGap = 0.3              // same end: a flight starting this long after the other ended is a new hit (v22)
        static let deadBall = 3.0                // no rally flight in the deadBall seconds before the competition window
        static let rallyPoints = 25, rallySeconds = 0.4, rallyRMS = 4.0
        static let duplicateWithin = 0.6         // opposite-end serve-like flights this close: one flight read from both ends (v27)
        static let shortTravel = 5.5             // a serve that lands on its own side: at least this far from the baseline, metres (v27)
        static let shownFromKmh = 45.0           // a serve speed under this is not shown (v27)
        static let shortSpeedKmh = 40.0          //   and at least this fast (a ball bounced before the serve is neither)
    }

    /// A serve that did not reach the net (v27): the fitted contact is a serve's, the ball lands on the server's
    /// own side past the service line. The reference calls these 下网; before v27 they needed a net crossing
    /// and were named forehands (night video 215.60, 1301.67, 1398.86).
    static func isShortFault(_ s: IndependentShotResult) -> Bool {
        guard s.bounceFound, let g = s.bounceGround, g.count >= 2, let side = s.hitterSide,
              let v = s.speedKmh, v >= Serve.shortSpeedKmh else { return false }
        let base = side == "near" ? 0 : IndependentCourt.length
        return abs(g[1] - base) >= Serve.shortTravel && (g[1] < netY) == (side == "near")
    }

    /// The near server seen serving (v27). At night the ball leaves a near server's racket as a streak the
    /// ball model does not find for the first 0.2-0.3 s, so the flight's own fit cannot say "serve"; the body
    /// pose can: only a toss and a serve swing hold a wrist a torso length above the shoulders. On the first
    /// two night videos 78 of 84 such events were the near player's serves (offline pose at 5 Hz); a forehand's
    /// follow-through peaks at 0.6-0.8 and touches 0.9 for one sample at most. The far player is about 20 px of torso and gives no usable pose.
    enum PoseServe {
        static let raised = 0.55      // a sample counts towards an event from here, torso lengths
        static let strong = 0.9       // an event of two or more samples needs one this high
        static let single = 1.2       // an event of one sample needs it this high (a follow-through can touch 0.9 once)
        static let gap = 1.5          // samples further apart than this are two events, seconds
        static let before = 0.6, after = 0.4   // the flight starts this close to the event's last raised sample, seconds
        static let contactLag = 0.1   // the contact after the last raised sample (pose is sampled at 5 Hz), seconds
        static let early = 0.25       // a flight starting this long before the contact is reported at the contact
        static let side = 3.0         // the server stands within this of the doubles sidelines, metres
    }
    struct PoseServeEvent { var start: Double, end: Double, peak: Double, samples = 1 }

    static func poseServes(_ people: IndependentPeople, camera cam: IndependentProjector) -> [PoseServeEvent] {
        var events = [PoseServeEvent]()
        for frame in people.byFrame.keys.sorted() {
            var up = -Double.infinity
            for box in people.byFrame[frame] ?? [] where !box.fromCrop {
                guard let a = box.armUp, a >= PoseServe.raised else { continue }
                let feet = IndependentShotFlights.feet(box, cam)
                guard feet.y < netY, abs(feet.x) <= IndependentCourt.doublesHalfWidth + PoseServe.side,
                      let b = behindInBoxHeights(box, near: true, cam), Serve.behindPx.contains(b) else { continue }
                up = max(up, a)
            }
            guard up >= PoseServe.raised else { continue }
            let t = Double(frame) / 60
            if let last = events.last, t - last.end <= PoseServe.gap {
                events[events.count - 1].end = t; events[events.count - 1].peak = max(last.peak, up); events[events.count - 1].samples += 1
            } else { events.append(PoseServeEvent(start: t, end: t, peak: up)) }
        }
        return events.filter { $0.peak >= ($0.samples >= 2 ? PoseServe.strong : PoseServe.single) }
    }

    /// The flight a pose serve belongs to: from the near end (or with no hitter found), starting nearest
    /// the event's last raised sample. Flights given to a far hitter are left alone: taking those that start
    /// just after the sample found two more serves on one night video and one false serve on the other.
    static func poseServeShot(_ e: PoseServeEvent, shots: [IndependentShotResult], segment: Int) -> Int? {
        shots.indices.filter { i in
            let s = shots[i], dt = s.tHit - e.end
            return s.segment == segment && s.hitterSide != "far" && -PoseServe.before <= dt && dt <= PoseServe.after
        }.min { abs(shots[$0].tHit - e.end) < abs(shots[$1].tHit - e.end) }
    }

    /// A flight that is part of a rally: long, cleanly fitted and crossing the net.
    public static func isRallyFlight(_ s: IndependentShotResult) -> Bool {
        s.accepted && s.crossesNet == true && s.nObs >= Serve.rallyPoints && Double(s.lastFrame - s.firstFrame) / 60 >= Serve.rallySeconds
            && (s.rmsPx ?? .infinity) <= Serve.rallyRMS
    }

    /// Shots that get the serve hypothesis refit (v17), with the server's end: a hitter behind their own
    /// baseline, no rally flight in the dead-ball window, and a flight whose own fit is not serve-like.
    static func hypothesisCandidates(_ shots: [IndependentShotResult], cameras: [IndependentProjector],
                                     priorRally: [Double]) -> [(Int, Bool, Bool)] {
        let rally: [Double] = priorRally + shots.filter { (s: IndependentShotResult) -> Bool in isRallyFlight(s) }.map(\.tHit)
        return shots.indices.compactMap { (i: Int) -> (Int, Bool, Bool)? in
            let s = shots[i]
            guard s.nObs >= IndependentShotFlights.ServeSpeed.hypothesisPoints else { return nil }
            let cam = cameras[s.segment]
            var near: Bool, speedOnly = false
            if let box = s.hitterBox, let b = behindInBoxHeights(box, near: IndependentShotFlights.feet(box, cam).y < netY, cam),
               Serve.behindPx.contains(b) {
                near = IndependentShotFlights.feet(box, cam).y < netY
                var own = s; own.serveBehindPx = b
                if isServeLike(own) { return nil }
                own.speedKmh = nil; speedOnly = isServeLike(own)    // serve-like but for an implausible fitted speed
            } else if s.fromToss == true, let side = s.hitterSide {
                near = side == "near"     // no server box behind the baseline: the toss and the refit are the evidence
            } else { return nil }
            let from = s.tHit - Serve.compete - Serve.deadBall, to = s.tHit - Serve.compete
            if rally.contains(where: { (t: Double) -> Bool in from <= t && t < to }) { return nil }
            return (i, near, speedOnly)
        }
    }

    /// A low camera (v18): the near players' heads stand above the horizon, so their boxes cover the far
    /// court in the image and a far serve can be given a near hitter (and the other way round). The serve
    /// hypothesis is then tried from the other end as well.
    static func lowCamera(_ cam: IndependentProjector) -> Bool { cam.C.z <= Serve.lowCameraZ }

    static func isServeLike(_ s: IndependentShotResult) -> Bool {
        if s.poseServe == true { return true }
        // a flight climbing well above its contact is a lob or a ball fed between points, not a serve (v22)
        if let r = s.serveFit == true ? (s.serveRise ?? s.riseM) : s.riseM, r > Serve.maxRise { return false }
        if s.serveFit == true {
            if let b = s.serveBehindPx, Serve.behindPx.contains(b) { return true }
            if s.fromToss == true || s.serveOtherEnd == true { return true }
        }
        guard let b = s.serveBehindPx, Serve.behindPx.contains(b), s.nObs >= Serve.minPoints, s.crossesNet == true || isShortFault(s),
              let z = s.fitHit?[2], Serve.contactZ.contains(z), (s.speedKmh.map { Serve.speedKmh.contains($0) } ?? true) else { return false }
        // the fitted contact on the server's side of the net (v18); otherwise the serve hypothesis decides
        if let side = s.hitterSide, let y = s.fitHit?[1], (side == "near") != (y < netY) { return false }
        // ... and, on a low camera, near the server's baseline (v22): there the own fit trades depth for speed,
        // and a ball fed from mid-court fits as a slow "serve"; the serve hypothesis decides instead
        if s.lowCamera == true, let side = s.hitterSide, let y = s.fitHit?[1], abs(y - (side == "near" ? 0 : IndependentCourt.length)) > Serve.ownDepth { return false }
        return true
    }

    /// Indices (into `shots`) called serves under the v14 rules.
    static func serves(_ shots: [IndependentShotResult], priorRally: [Double]) -> Set<Int> {
        let like = Set(shots.indices.filter { isServeLike(shots[$0]) })
        let returns = serveReturns(shots, like: like)
        // dead ball: no rally flight before the competition window (and none that is not serve-like inside it).
        // The return of a serve-like flight is not rally evidence (v17): a returned fault is followed by the
        // second serve a few seconds later.
        let open = like.filter { i in
            let t = shots[i].tHit
            if shots[i].poseServe == true { return true }    // seen serving: no dead-ball test needed
            let earlyFrom = t - Serve.compete - Serve.deadBall, earlyTo = t - Serve.compete
            if priorRally.contains(where: { earlyFrom <= $0 && $0 < earlyTo }) { return false }
            return !shots.indices.contains { j in
                guard j != i, isRallyFlight(shots[j]), !returns.contains(j) else { return false }
                let tj = shots[j].tHit
                // an earlier serve-like flight is not rally evidence either (v27): a second serve, or the next
                // ball of a serving drill, follows the first within the window (night video 1362.29, 1426.99)
                return !like.contains(j) && earlyFrom <= tj && tj < t
            }
        }
        // one serve per point start. Serve-like flights from opposite ends (a serve and its return, or the ball
        // sent back to the server before the serve): the faster fitted flight is the serve (v17); from the same
        // end: the flight with the most ball points.
        return open.filter { i in
            let t = shots[i].tHit
            return !open.contains { j in
                guard j != i else { return false }
                // a serve seen in the server's pose is the serve; other serve-like flights around it are not (v27)
                if shots[i].poseServe == true { return false }
                if shots[j].poseServe == true { return abs(shots[j].tHit - t) < Serve.returnWithin }
                if let a = shots[i].hitterSide, let b = shots[j].hitterSide, a != b {
                    guard abs(shots[j].tHit - t) < Serve.returnWithin else { return false }
                    // a fitted landing in the service box is stronger evidence than a faster fit: at
                    // double-test-003 462.27 the receiver's false "serve" (no bounce, 80.2 km/h) won over the
                    // real serve's landing (54.8 km/h, bounce, 2026-11-06)
                    // ... but only between two readings of one flight (v27). Further apart they are a serve and
                    // its return, and the return's bounce took the serve from a 131 km/h flight that had none
                    // (night video 847.68, 881.51, 1116.12)
                    if abs(shots[j].tHit - t) < Serve.duplicateWithin, shots[i].bounceFound != shots[j].bounceFound { return shots[j].bounceFound }
                    let vi: Double = shots[i].speedKmh ?? 0, vj: Double = shots[j].speedKmh ?? 0
                    return vj > vi || (vj == vi && shots[j].tHit < t)
                }
                guard abs(shots[j].tHit - t) < Serve.compete else { return false }
                // the earlier flight did not cross the net and the later one starts after it ended (the ball
                // bounced or tossed before the serve, back at the server's end): the later flight is the serve (v22)
                let (a, b) = shots[j].tHit < t ? (shots[j], shots[i]) : (shots[i], shots[j])
                if !(a.accepted && a.crossesNet == true), b.tHit - Double(a.lastFrame) / 60 >= Serve.restartGap { return shots[j].tHit > t }
                return shots[j].nObs > shots[i].nObs || (shots[j].nObs == shots[i].nObs && shots[j].tHit < t)
            }
        }
    }

    /// Indices of flights that return a serve-like flight: the first flight from the other end within
    /// `Serve.compete` seconds after it.
    static func serveReturns(_ shots: [IndependentShotResult], like: Set<Int>) -> Set<Int> {
        var out = Set<Int>()
        for k in like {
            guard let side = shots[k].hitterSide else { continue }
            let tk = shots[k].tHit
            let later = shots.indices.filter { (j: Int) -> Bool in
                let dt: Double = shots[j].tHit - tk
                return j != k && dt > 0 && dt <= Serve.returnWithin && shots[j].hitterSide != nil
            }
            guard let first = later.min(by: { (a: Int, b: Int) -> Bool in shots[a].tHit < shots[b].tHit }) else { continue }
            if shots[first].hitterSide != side { out.insert(first) }
        }
        return out
    }

    static func classify(_ shots: inout [IndependentShotResult], bounces: [(Double, Double)], cameras: [IndependentProjector],
                         priorRally: [Double] = []) {
        let order = IndependentBallEvents.stableSorted(Array(shots.indices)) { shots[$0].tHit < shots[$1].tHit }
        var sides = [Int: (String, SIMD3<Double>)]()
        for i in order {
            if let box = shots[i].hitterBox {
                let ft = IndependentShotFlights.feet(box, cameras[shots[i].segment])
                sides[i] = (ft.y < netY ? "near" : "far", ft)
            }
        }
        for i in order {
            if let (side, _) = sides[i], let box = shots[i].hitterBox {
                shots[i].serveBehindPx = behindInBoxHeights(box, near: side == "near", cameras[shots[i].segment])
            }
        }
        let serveSet = serves(shots, priorRally: priorRally)
        for (n, i) in order.enumerated() {
            let s = shots[i]
            if serveSet.contains(i) { shots[i].stroke = "发球"; continue }
            guard let (side, ft) = sides[i], let box = s.hitterBox else {
                shots[i].stroke = nil; shots[i].strokeReason = "no hitter found"; continue
            }
            let uv = SIMD2(s.contactUV[0], s.contactUV[1])
            let off = uv.x - (box.x0 + box.x1) / 2
            if abs(off) < 0.1 * box.width {
                shots[i].stroke = nil; shots[i].strokeReason = "ball too close to the body centre"; continue
            }
            let fore = side == "near" ? off > 0 : off < 0
            var stroke = fore ? "正手" : "反手"
            let prevT = order.prefix(n).compactMap { j -> Double? in
                guard let (other, _) = sides[j], other != side, s.tHit - shots[j].tHit <= 2.0 else { return nil }
                return shots[j].tHit
            }
            if abs(ft.y - netY) <= 6.4, let t0 = prevT.max() {
                let own = bounces.filter { t0 < $0.0 && $0.0 < s.tHit && (($0.1 < netY) == (side == "near")) }
                if own.isEmpty { stroke += " 截击" }
            }
            shots[i].stroke = stroke
        }
    }
}
