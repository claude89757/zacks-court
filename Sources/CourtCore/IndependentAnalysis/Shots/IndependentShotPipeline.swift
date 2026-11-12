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
    public static let rulesVersion = "independent-shots-v35"

    /// Median image step of a run of track points, pixels per frame (0 for fewer than two points).
    static func imageSpeed(_ P: [IndependentTrackPoint]) -> Double {
        guard P.count >= 2 else { return 0 }
        var s = [Double]()
        for i in 1..<P.count { s.append(simd_length(P[i].uv - P[i - 1].uv) / max(P[i].t - P[i - 1].t, 1)) }
        s.sort(); return s[s.count / 2]
    }

    /// The speed of a ball leaving `P` that is at `Q` `T` seconds later, km/h: the two measured ends of a serve
    /// (v29), gravity corrected, drag left out.
    static func twoPointSpeed(from P: SIMD3<Double>, to Q: SIMD3<Double>, over T: Double) -> Double {
        var v = (Q - P) / T; v.z += 0.5 * IndependentFlight.g * T
        return simd_length(v) * 3.6
    }

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
        var landings = [(segment: Int, t: Double, ground: SIMD3<Double>)]()
        var segmentEvents = [SegmentEvents]()     // kept for the serve rules after `classify` (v32)
        var farSwings = [[IndependentStrokeRules.ServeSwing]](repeating: [], count: segments.count)
        for (k, segment) in segments.enumerated() {
            let ev = events(candidates: candidates, segment: segment)
            segmentEvents.append(ev)
            let p = try people(k, ev)
            crowd.append(p)
            pairs += fits(events: ev, people: p, segment: segment, index: k)
            bounces += ev.junctions.filter { $0.bounce || $0.secondChanceBounce }.compactMap { l in l.ground.map { (l.t, $0.y) } }
            landings += ev.junctions.filter(\.bounce).compactMap { l in l.ground.map { (k, l.t, $0) } }
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
            let cam = cameras[k]
            var events = IndependentStrokeRules.poseServes(people, camera: cam).map { (event: $0, contact: Double?.none, hand: SIMD2<Double>?.none) }
            // ... and the region poses (v29) time its contact, and see the swings a 5 Hz sample missed
            for w in IndependentStrokeRules.serveSwings(people, camera: cam, near: true) {
                let slack = IndependentStrokeRules.Swing.sameSwing
                if let j = events.firstIndex(where: { w.start <= $0.event.end + slack && $0.event.start - slack <= w.end }) {
                    if events[j].contact == nil { events[j].contact = w.contact; events[j].hand = w.hand }
                } else {
                    events.append((IndependentStrokeRules.PoseServeEvent(start: w.start, end: w.end, peak: w.peak, samples: w.samples), w.contact, w.hand))
                }
            }
            for (e, seen, hand) in events {
                guard let i = IndependentStrokeRules.poseServeShot(e, contact: seen, shots: shots, segment: k) else { continue }
                shots[i].poseServe = true; shots[i].hitterSide = "near"; shots[i].poseContact = seen; shots[i].poseHand = hand.map { [$0.x, $0.y] }
                if let seen { contact[i] = seen; continue }
                let t = e.end + IndependentStrokeRules.PoseServe.contactLag
                if contact[i] == nil, t > shots[i].tHit + IndependentStrokeRules.PoseServe.early { contact[i] = t }
            }
            // the far server's swing (v29): the far players are too small for the whole-frame pose, not for a
            // region around them
            let far = IndependentStrokeRules.serveSwings(people, camera: cam, near: false)
            farSwings[k] = far
            for w in far {
                guard let i = IndependentStrokeRules.swingShot(w, shots: shots, segment: k) else { continue }
                shots[i].poseServe = true; shots[i].hitterSide = "far"
                // a far server's hitting wrist is not always found (about 20 px of arm); the top that is left is the
                // toss arm's, half a second before the contact (13 of 24 far serves on one night video, none of 13 on
                // the other). The path says so (`swung`), and the ball: a far serve is tracked from the racket on, so
                // its flight does not start that long after the contact
                guard w.swung, let t = w.contact, t >= (contact[i] ?? shots[i].tHit) - IndependentStrokeRules.Swing.tossLead else {
                    // ... and when that toss is glued to the start of the flight, the row was timed at the toss, half a
                    // second early: no serve at the reference's time and a false one before it (v32). The far serve
                    // hypothesis trims the toss and times the contact; it is taken when later than the flight's own hit
                    // (tt night video 99.57, 134.50, 497.85: three serves found, two false ones gone)
                    if contact[i] == nil, shots[i].fromToss == true {
                        let job = pairs[i].0
                        if let h = cached(i, near: false, hypothesis: 1, { IndependentShotFlights.serveHypothesis(job, near: false, camera: cam) }),
                           h.tHit > shots[i].tHit + IndependentStrokeRules.PoseServe.early {
                            contact[i] = h.tHit; shots[i].tossGluedContact = h.tHit
                        }
                    }
                    continue
                }
                shots[i].poseContact = t; shots[i].poseHand = w.hand.map { [$0.x, $0.y] }; contact[i] = t
            }
            // ... and where the far players were watched and kept their arms down, a flight from their end is
            // not a serve, however serve-like its fit
            for i in shots.indices where shots[i].segment == k && shots[i].hitterSide == "far" && shots[i].poseServe != true {
                let t = shots[i].tHit, W = IndependentStrokeRules.Swing.self
                guard IndependentStrokeRules.watched(people, near: false, from: t - W.watchBefore, to: t + W.watchAfter) == .lowered else { continue }
                if !far.contains(where: { $0.start - W.near <= t && t <= $0.end + W.near }) { shots[i].poseDenied = true }
            }
            // the same at the near end (v32): a near flight that is no pose serve, while the near players were watched
            // with every arm down and no raised-arm event is near it (from its hit to a serve refit's contact). Night
            // videos: six false serves gone, no serve lost
            let W = IndependentStrokeRules.Swing.self
            for i in shots.indices where shots[i].segment == k && shots[i].hitterSide == "near" && shots[i].poseServe != true {
                let t0 = shots[i].tHit, t1 = max(shots[i].tHit, contact[i] ?? shots[i].tHit)
                guard IndependentStrokeRules.watched(people, near: true, from: t0 - W.watchBefore, to: t1 + W.watchAfter) == .lowered,
                      !events.contains(where: { $0.event.start - W.near <= t1 && t0 <= $0.event.end + W.near }) else { continue }
                shots[i].poseDenied = true
            }
        }
        // how far each flight moves in the image: a rally flight moves, a ball lying or rolling does not (v32)
        for i in shots.indices { shots[i].imageStep = imageSpeed(pairs[i].0.points) }
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
            // ... and at the contact seen in the server's pose, earlier or later (v29)
            if let seen = shots[i].poseContact { if abs(seen - shots[i].tHit) > 0.02 { shots[i].contactT = seen } }
            else if let t = contact[i], t > shots[i].tHit + 0.1 { shots[i].contactT = t }
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
        // a serve whose contact was seen in the server's pose (v29): the speed between the two measured ends, the
        // contact and the first bounce past the net. No fit decides where the flight began, so a toss glued to the
        // track, or a ball first tracked at the net, no longer moves the contact.
        func seenContactSpeed(_ i: Int, tc: Double, g: [Double], tb: Double) -> Bool {
            guard let side = shots[i].hitterSide, g.count >= 2 else { return false }
            let near = side == "near", netY = IndependentCourt.netY, T = tb - tc
            guard (g[1] > netY) == near, abs(g[1] - netY) > IndependentShotFlights.ServeSpeed.netBounceY,
                  IndependentStrokeRules.Swing.flight.contains(T) else { return false }
            let P = IndependentStrokeRules.seenContact(hand: shots[i].poseHand, near: near, camera: cameras[shots[i].segment], fallbackX: shots[i].fitHit?[0])
            let speed = twoPointSpeed(from: P, to: SIMD3(g[0], g[1], IndependentCourt.ballRadius), over: T)
            guard (20...250).contains(speed) else { return false }     // the gate every accepted speed passes (`analyse`)
            shots[i].speedKmh = speed; shots[i].intervalS = T; shots[i].fitHit = [P.x, P.y, P.z]
            shots[i].accepted = true; shots[i].reason = nil; shots[i].bounceFound = true; shots[i].speedTo = "bounce"; shots[i].serveSpeedFrom = "seen contact"
            return true
        }
        for i in shots.indices where shots[i].stroke == "发球" {
            guard let tc = shots[i].poseContact, let g = shots[i].bounceGround, let tb = shots[i].tBounce else { continue }
            _ = seenContactSpeed(i, tc: tc, g: g, tb: tb)
        }
        // a far serve into the net (v32): from its contact (the pose's; else a far swing's that no row took; else the
        // flight's own hit junction) to the junction in its own flight where the track meets the net plane at net
        // height and the ball stops. The net refit reads the crossing off a curve fitted to a short, dim far flight
        // and was 20-30 % off (tt night video 204.70, 544.04). Night videos: two more within 20 %, and in the check
        // halves one more and none worse.
        let takenContacts = Set(shots.compactMap(\.poseContact))
        for i in shots.indices where shots[i].stroke == "发球" && shots[i].serveSpeedFrom == "net" && shots[i].hitterSide == "far" {
            let k = shots[i].segment, job = pairs[i].0, cam = cameras[k], ev = segmentEvents[k]
            var tc: Double?, hand = shots[i].poseHand, from = ""
            if let pc = shots[i].poseContact {
                tc = pc; from = "pose"
            } else if let w = farSwings[k].first(where: { (w: IndependentStrokeRules.ServeSwing) -> Bool in
                guard w.swung, let c = w.contact, !takenContacts.contains(c) else { return false }
                return w.start - IndependentStrokeRules.PoseServe.before <= shots[i].tHit && shots[i].tHit <= w.end + IndependentStrokeRules.PoseServe.after
            }) {
                tc = w.contact; hand = w.hand.map { [$0.x, $0.y] }; from = "far swing"
            } else if job.kind == .junction || job.kind == .afterToss {
                tc = job.tHit / IndependentShotFlights.fps; from = "hit junction"
            }
            guard let tc, let stop = netStop(job, events: ev, camera: cam, after: tc) else { continue }
            let P = IndependentStrokeRules.seenContact(hand: hand, near: false, camera: cam, fallbackX: shots[i].fitHit?[0])
            let T = stop.t - tc, speed = twoPointSpeed(from: P, to: stop.Q, over: T)
            guard (IndependentStrokeRules.Serve.shownFromKmh...250).contains(speed) else { continue }
            shots[i].speedKmh = speed; shots[i].intervalS = T; shots[i].serveSpeedFrom = "net junction (\(from))"
        }
        // ... and one whose own flight has no bounce (v30): the first bounce of any track piece past the net, within
        // the court and 2 m around it. At night a serve is often lost for a third of a second past the net; the piece
        // picked up again on the other side holds the bounce but is not the serve's flight (too short to fit, or a
        // slow stroke of its own: tt night video 652.08, a far "forehand" at 19 km/h), so the serve had no bounce and
        // no speed although both ends were seen. On the two night videos nine serves gained a speed within 20 % and
        // none got worse. The row takes that bounce only with the speed.
        for i in shots.indices where shots[i].stroke == "发球" && shots[i].reportedSpeedKmh == nil && shots[i].serveSpeedFrom != "net" {
            guard let tc = shots[i].poseContact, let side = shots[i].hitterSide, shots[i].bounceGround == nil else { continue }
            let near = side == "near", netY = IndependentCourt.netY, margin = IndependentShotFlights.ServeSpeed.netBounceY
            guard let l = landings.filter({ l in
                let y = l.ground.y
                let pastNet = near ? (y > netY + margin && y < IndependentCourt.length + 2) : (y < netY - margin && y > -2)
                return l.segment == shots[i].segment && IndependentStrokeRules.Swing.flight.contains(l.t - tc) && pastNet
                    && abs(l.ground.x) <= IndependentCourt.doublesHalfWidth + 2
            }).min(by: { $0.t < $1.t }) else { continue }
            let g = [l.ground.x, l.ground.y, l.ground.z]
            if seenContactSpeed(i, tc: tc, g: g, tb: l.t) {
                shots[i].bounceGround = g; shots[i].tBounce = l.t; shots[i].serveSpeedFrom = "seen contact, piece bounce"
            }
        }
        // ... and a near serve seen hit and still without a landing (v32): its landing in the far half found from the
        // ball alone, where the bounce tests did not call one (`farHalfLanding`). Night videos: four serves gained a
        // speed within 20 % (tt 301.03, 403.80, 714.75 and one in the check half), none worse.
        for i in shots.indices where shots[i].stroke == "发球" && shots[i].reportedSpeedKmh == nil && shots[i].serveSpeedFrom != "net" {
            guard let tc = shots[i].poseContact, shots[i].hitterSide == "near", shots[i].bounceGround == nil,
                  let l = farHalfLanding(segmentEvents[shots[i].segment], camera: cameras[shots[i].segment], contact: tc) else { continue }
            let g = [l.ground.x, l.ground.y, l.ground.z]
            if seenContactSpeed(i, tc: tc, g: g, tb: l.t) {
                shots[i].bounceGround = g; shots[i].tBounce = l.t; shots[i].serveSpeedFrom = "seen contact, \(l.how)"
            }
        }
        // a "serve" under 45 km/h is a contact timed too early (a toss glued to the flight) or not a serve (v27):
        // on the two night videos all ten such speeds were wrong, four real serves read at half their speed
        // and six flights the reference does not call serves. The row stays; the speed is not shown.
        for i in shots.indices where shots[i].stroke == "发球" {
            guard let v = shots[i].reportedSpeedKmh, v < IndependentStrokeRules.Serve.shownFromKmh else { continue }
            shots[i].slowServe = true
            if shots[i].reason == nil { shots[i].reason = "serve speed under 45 km/h, contact time not believed" }
        }
        // flights first seen late that the rules did not name serves: the hit is where the longer reach finds it (v29)
        for i in shots.indices where shots[i].stroke != "发球" { shots[i].applyLateHit() }
        for i in shots.indices { shots[i].bounceSigma = bounceSigma(shots[i], camera: cameras[shots[i].segment]) }
        // an incoming flight from the far half without a bounce: where it came down on the near half (v33). Night
        // videos: near calls agreeing with the reference +6 in the halves the rule was built on, +2 in the others,
        // none wrong; the 1 m sigma floor makes calls within about 2 m of a line 「压线附近」.
        for i in shots.indices where shots[i].bounceGround == nil {
            shots[i].landEstimate = incomingLanding(i, shots: shots, camera: cameras[shots[i].segment])
        }
        return shots
    }

    /// The near landing of shot `i`, hit on the far half, that has no bounce (v33): the bounce inside its last steps
    /// (`IndependentShotFlights.tailKnee`), else, when there is no such knee, where its own accepted fit comes down a
    /// few frames past the last observation, low and close to it in the image, unless the flight ends at a hit.
    /// Else, when the flight was followed down to the ground and lost there, its last observation (v35).
    /// Neither at the net, nor when a near player hits the ball right then (a volley).
    static func incomingLanding(_ i: Int, shots: [IndependentShotResult], camera: IndependentProjector) -> IndependentShotResult.LandEstimate? {
        typealias L = IndependentIncomingLanding
        let s = shots[i], netY = IndependentCourt.netY
        guard let d = s.descent else { return nil }
        func onNearHalf(_ x: Double, _ y: Double) -> Bool { netY - y >= L.netMargin && y > -8 && abs(x) < 9 }
        func receiverHits(from t0: Double, to t1: Double) -> Bool {
            shots.indices.contains { j in
                j != i && shots[j].segment == s.segment && shots[j].hitterSide == "near" && shots[j].tHit >= t0 && shots[j].tHit <= t1
            }
        }
        if let k = d.knee {
            guard onNearHalf(k[1], k[2]), let h = s.fitHit, h.count >= 2, h[1] > netY,
                  d.zLast <= L.kneeHighZ, d.ahead <= L.kneeAheadFrames,
                  !receiverHits(from: k[0] - L.receiverBefore, to: k[0] + L.receiverAfter) else { return nil }
            return landEstimate(t: k[0], x: k[1], y: k[2], vx: d.vx, vy: d.vy, frames: L.kneeSigmaFrames, knee: true, camera: camera)
        }
        if d.accepted, let rms = d.rms, rms <= L.maxRms, !d.endsAtHit, onNearHalf(d.x, d.y),
           let hitY = d.hitY, hitY > netY, d.zLast <= L.fitHighZ,
           (0...L.frameWidth).contains(d.u), (0...L.frameHeight).contains(d.v),
           L.aheadFrames.contains(d.ahead), d.px <= L.maxImagePx,
           !receiverHits(from: d.tLast - L.receiverBefore, to: d.t + L.receiverAfter) {
            // a tracked bounce's half frame of travel, plus the landing time's uncertainty
            let frames = (0.5 * 0.5 + pow(L.timingFrames + L.perAheadFrame * abs(d.ahead), 2)).squareRoot()
            return landEstimate(t: d.t, x: d.x, y: d.y, vx: d.vx, vy: d.vy, frames: frames, knee: false, camera: camera)
        }
        // Tracked down to the ground and lost right there (v35): the fit is still a little high at the last
        // observation, so the landing is that observation on the ground, not where the fit comes down. Night videos: of the incoming flights without a landing whose last observation is a colour-found
        // bounce, 14 of 16 pass; of those still in the air there (fit 0.63-1.01 m high), none.
        guard d.accepted, let rms = d.rms, rms <= L.maxRms, let hitY = d.hitY, hitY > netY,
              L.lastLandZ.contains(d.zLast), let last = d.last, last.count >= 2 else { return nil }
        let g = camera.onPlaneZ(last[0], last[1], z: IndependentCourt.ballRadius)
        guard g.x.isFinite, g.y.isFinite, onNearHalf(g.x, g.y),
              !receiverHits(from: d.tLast - L.receiverBefore, to: d.tLast + L.receiverAfter) else { return nil }
        return landEstimate(t: d.tLast, x: g.x, y: g.y, vx: d.vx, vy: d.vy, frames: L.lastLandFrames, knee: true,
                            camera: camera, floor: L.lastLandSigmaFloor)
    }

    /// A landing with its standard deviations (m): `bouncePixelSigma` through the ground mapping, `frames` of the
    /// ball's ground travel, and `floor` (`IndependentIncomingLanding.sigmaFloor` unless given); nil when they are
    /// not finite.
    static func landEstimate(t: Double, x: Double, y: Double, vx: Double, vy: Double, frames: Double, knee: Bool,
                             camera: IndependentProjector, floor: Double = IndependentIncomingLanding.sigmaFloor) -> IndependentShotResult.LandEstimate? {
        guard let pixel = pixelVariance(x: x, y: y, camera: camera) else { return nil }
        let dt = frames / IndependentShotFlights.fps, floor2 = floor * floor
        let sxx = pixel.xx + (vx * dt) * (vx * dt) + floor2, syy = pixel.yy + (vy * dt) * (vy * dt) + floor2
        guard t.isFinite, x.isFinite, y.isFinite, sxx.isFinite, syy.isFinite else { return nil }
        return IndependentShotResult.LandEstimate(t: t, x: x, y: y, sigma: [sxx.squareRoot(), syy.squareRoot()], knee: knee)
    }

    /// Where a serve into the net met it (v32): the first junction inside the serve's own flight, `netJunctionAfter`
    /// seconds after the contact `tc`, whose image point lies on the net plane at net height within the doubles width,
    /// and where the ball stops: the image speed of the 6 points after it at most `netStopRatio` of the 6 before.
    static func netStop(_ job: IndependentShotFlight, events ev: SegmentEvents, camera cam: IndependentProjector,
                        after tc: Double) -> (t: Double, Q: SIMD3<Double>)? {
        let times = Set(job.points.map(\.t)), S = IndependentShotFlights.ServeSpeed.self
        let stops = ev.junctions.compactMap { (l: IndependentJunction) -> (t: Double, Q: SIMD3<Double>)? in
            let A = ev.pieces[l.a], B = ev.pieces[l.b]
            guard !l.bounce, times.contains(A[A.count - 1].t), times.contains(B[0].t), S.netJunctionAfter.contains(l.t - tc) else { return nil }
            let (Q, s) = cam.onPlaneY(l.u, l.v, y: IndependentCourt.netY)
            guard s > 0, Q.z >= S.netLowZ, Q.z <= S.netTopZ, abs(Q.x) <= IndependentCourt.doublesHalfWidth,
                  imageSpeed(Array(B.prefix(6))) / max(imageSpeed(Array(A.suffix(6))), 1e-6) <= S.netStopRatio else { return nil }
            return (l.t, Q)
        }
        return stops.min { $0.t < $1.t }
    }

    /// The first landing in the far half of a near serve contacted at `tc` (seconds), found from the ball where the
    /// bounce tests called none (v32). At night the far half is dim: the landing is a junction followed by only a few
    /// points, or no junction at all, the ball tracked smoothly through it. (a) A junction past the net whose tail
    /// (4-7 points) is too short for the bounce test, the ball falling into it (anchored fit within 6 px) and a flight
    /// rising from it explaining the tail (`IndependentFlight.risingAnchoredRMS`, 6 px). (b) Inside one piece, the
    /// lowest image point with anchored fits falling into it and rising out of it, each within 4 px.
    static func farHalfLanding(_ ev: SegmentEvents, camera cam: IndependentProjector, contact tc: Double) -> (t: Double, ground: SIMD3<Double>, how: String)? {
        let fps = IndependentShotFlights.fps, netY = IndependentCourt.netY, margin = IndependentShotFlights.ServeSpeed.netBounceY
        func pastNet(_ g: SIMD3<Double>) -> Bool {
            g.y > netY + margin && g.y < IndependentCourt.length + 2 && abs(g.x) <= IndependentCourt.doublesHalfWidth + 2
        }
        var found = [(t: Double, ground: SIMD3<Double>, how: String)]()
        for l in ev.junctions where !l.bounce {
            guard let g = l.ground, pastNet(g), IndependentStrokeRules.Swing.flight.contains(l.t - tc) else { continue }
            let A = Array(ev.pieces[l.a].suffix(25)), B = Array(ev.pieces[l.b].prefix(15))
            guard A.count >= 4, (4...7).contains(B.count) else { continue }
            let fa = IndependentFlight.bestAnchored(cam, frames: A.map(\.t), uv: A.map(\.uv), anchor: g, at: l.t * fps, before: true)
            guard fa.rms <= 6, fa.velocity.z < 0,
                  IndependentFlight.risingAnchoredRMS(cam, frames: B.map(\.t), uv: B.map(\.uv), anchor: g, at: l.t * fps) <= 6 else { continue }
            found.append((l.t, g, "short tail"))
        }
        for P in ev.pieces where P.count >= 7 {
            for j in 3..<(P.count - 3) {
                let t = P[j].t / fps
                guard IndependentStrokeRules.Swing.flight.contains(t - tc), P[j].v >= P[j - 1].v, P[j].v >= P[j + 1].v else { continue }
                let g = cam.onPlaneZ(P[j].u, P[j].v, z: IndependentCourt.ballRadius)
                guard g.x.isFinite, g.y.isFinite, pastNet(g) else { continue }
                let A = Array(P[max(0, j - 24)...j]), B = Array(P[j..<min(P.count, j + 15)])
                let fa = IndependentFlight.bestAnchored(cam, frames: A.map(\.t), uv: A.map(\.uv), anchor: g, at: P[j].t, before: true)
                guard fa.rms <= 4, fa.velocity.z < 0 else { continue }
                let fb = IndependentFlight.bestAnchored(cam, frames: B.map(\.t), uv: B.map(\.uv), anchor: g, at: P[j].t, before: false)
                guard fb.rms <= 4, fb.velocity.z > 0 else { continue }
                found.append((t, g, "in piece"))
                break
            }
        }
        return found.min { $0.t < $1.t }
    }

    /// Image noise of a bounce, in pixels, for its uncertainty on the ground.
    static let bouncePixelSigma = 2.0
    /// How close (s) the flight's own fitted landing must be to the bounce to stand in for its ground speed.
    static let landingMatchSeconds = 0.1

    /// Standard deviations (m) of a bounce's ground x and y: `bouncePixelSigma` through the ground
    /// mapping's Jacobian at the bounce, plus half a frame of ground travel (the bounce falls between frames).
    /// The ground speed is the hit-to-bounce chord. When the fitted contact is not where a player could stand
    /// (v34, `HawkEye.plausibleHit`), the chord is no speed: three serves on the night video fitted contacts
    /// 54-144 m away and chords of 40-118 m/s. Such a bounce takes the flight's fitted velocity at its landing.
    static func bounceSigma(_ s: IndependentShotResult, camera: IndependentProjector) -> [Double]? {
        guard let b = s.bounceGround, b.count >= 2, let pixel = pixelVariance(x: b[0], y: b[1], camera: camera) else { return nil }
        var sxx = pixel.xx, syy = pixel.yy
        if let h = s.fitHit, h.count >= 2, let tb = s.tBounce, tb - s.tHit > 0.1 {
            let T = tb - s.tHit, step = 0.5 / IndependentShotFlights.fps
            var vx = (b[0] - h[0]) / T, vy = (b[1] - h[1]) / T
            if h.count >= 3, !HawkEye.plausibleHit(xCentred: h[0], y: h[1], z: h[2]),
               let d = s.descent, abs(d.t - tb) <= landingMatchSeconds { vx = d.vx; vy = d.vy }
            sxx += (vx * step) * (vx * step); syy += (vy * step) * (vy * step)
        }
        guard sxx.isFinite, syy.isFinite else { return nil }
        return [sxx.squareRoot(), syy.squareRoot()]
    }

    /// Variances (m²) of a ground point's x and y from `bouncePixelSigma` of image noise, through the ground
    /// mapping's Jacobian there; nil when the point is behind the camera.
    static func pixelVariance(x: Double, y: Double, camera: IndependentProjector) -> (xx: Double, yy: Double)? {
        let p = camera.project(SIMD3(x, y, 0))
        guard p.depth > 0 else { return nil }
        let g0 = camera.onPlaneZ(p.u, p.v, z: 0), gu = camera.onPlaneZ(p.u + 1, p.v, z: 0), gv = camera.onPlaneZ(p.u, p.v + 1, z: 0)
        let ju = gu - g0, jv = gv - g0, px2 = bouncePixelSigma * bouncePixelSigma
        return (px2 * (ju.x * ju.x + jv.x * jv.x), px2 * (ju.y * ju.y + jv.y * jv.y))
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
    /// `all`: also the shots `keeps` leaves out (the live lane's update of a row it has already shown).
    public static func rows(from shots: [IndependentShotResult], streamID: UUID, ptsOffset: Double = 0, all: Bool = false) -> [TennisShotEvent] {
        func finite(_ values: [Double]?, count: Int) -> [Double]? {
            guard let values, values.count >= count, values.prefix(count).allSatisfy(\.isFinite) else { return nil }
            return values
        }
        return shots.filter { all || keeps($0) }.map { s in
            let speed = s.reportedSpeedKmh.flatMap { $0.isFinite ? $0 : nil }
            var row = TennisShotEvent(streamID: streamID, sourcePTS: (s.contactT ?? s.tHit) + ptsOffset, stroke: IndependentStrokeRules.kind(s.stroke),
                                      confidence: 0, speedKPH: speed, speedReason: speed == nil ? reasonText(s) : nil, sampleCount: s.nObs)
            if speed == nil { row.speedReasonCode = reasonCode(s) }
            if let g = finite(s.bounceGround, count: 2), let t = s.tBounce, t.isFinite {
                row.bounce = TennisBounceEstimate(sourcePTS: t + ptsOffset, xMeters: IndependentCourt.courtX(fromCentred: g[0]), yMeters: g[1],
                                                  confidence: 0, reason: "模型估计，不是判罚")
                row.bounce?.reasonCode = .estimate
                if let sg = finite(s.bounceSigma, count: 2) { row.bounce?.sigmaXMeters = sg[0]; row.bounce?.sigmaYMeters = sg[1] }
            } else if let l = s.landEstimate {
                row.bounce = TennisBounceEstimate(sourcePTS: l.t + ptsOffset, xMeters: IndependentCourt.courtX(fromCentred: l.x), yMeters: l.y,
                                                  confidence: 0, reason: l.knee ? "模型估计（来球最后几帧里的触地），不是判罚" : "模型估计（来球拟合落地），不是判罚")
                row.bounce?.reasonCode = .estimate
                row.bounce?.sigmaXMeters = l.sigma[0]; row.bounce?.sigmaYMeters = l.sigma[1]
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
        // a serve seen in the server's pose is a row whatever its flight's fit says (v28): the pose named it
        // because the ball's first metres were not tracked, and a fit of the few points left has no usable contact
        if s.poseServe == true, s.stroke == "发球" { return true }
        if let v = s.reportedSpeedKmh, v.isFinite { return true }
        guard let h = s.fitHit, h.count >= 2, h[0].isFinite, h[1].isFinite else { return false }
        return HawkEye.contactUsable(TennisCourtPoint(x: IndependentCourt.courtX(fromCentred: h[0]), y: h[1],
                                                      z: h.count > 2 && h[2].isFinite ? h[2] : 0))
    }

    static func reasonCode(_ s: IndependentShotResult) -> TennisReason {
        if s.reason == "fewer than 8 ball observations between hit and bounce" || s.reason == "no initial flight hypothesis" { return .ballNotSeen }
        // a row showing an estimated landing (v33) does not say the ball was not seen landing
        return s.bounceFound || s.landEstimate != nil ? .speedUnreliable : .noBounceSeen
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
        static let rallyStep = 1.5               // a rally flight moves at least this in the image, median px per frame (v32)
        static let rallyHitX = 7.5               // and was hit within this of the centre line: the doubles width + 2 m, metres (v32)
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
    /// follow-through peaks at 0.6-0.8 and touches 0.9 for one sample at most. The far player is about 20 px of
    /// torso and gives no pose on the whole frame; from v29 the region poses read the far players too (`serveSwings`).
    enum PoseServe {
        static let raised = 0.55      // a sample counts towards an event from here, torso lengths
        static let strong = 0.9       // an event of two or more samples needs one this high
        static let single = 1.2       // an event of one sample needs it this high (a follow-through can touch 0.9 once)
        static let gap = 1.5          // samples further apart than this are two events, seconds
        static let before = 0.6, after = 0.4   // the flight starts this close to the event's last raised sample, seconds
        static let contactLag = 0.1   // the contact after the last raised sample (pose is sampled at 5 Hz), seconds
        static let early = 0.25       // a flight starting this long before the contact is reported at the contact
        static let side = 3.0         // the server stands within this of the doubles sidelines, metres
        static let rallyFrom = 3.0, rallyTo = 0.6   // a rally flight this long before a pose serve: a swing in a rally, seconds (v28)
        static let seenFrom = 0.6, seenTo = 0.45    // a flight first seen this close to the contact (v32), seconds
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

    /// The flight a pose serve belongs to: from the near end (or with no hitter found), its hit within
    /// [-`before`, `after`] of the event's last raised sample. Flights given to a far hitter are left alone:
    /// taking those that start just after the sample found two more serves on one night video and one false
    /// serve on the other. Of those, a flight that goes somewhere (over the net, to a bounce past it, or a short
    /// fault), first seen nearest the contact (v30): the nearest hit alone took the 7–8 points tracked at the
    /// contact, which reach nowhere, while the serve itself, first seen 0.1 s later and its hit reached back
    /// half a second too far, became a forehand (night videos: five more serve speeds within 20 %, none worse).
    /// None going anywhere: the nearest hit, as before. A flight whose hit was reached back further than `before`
    /// is taken as well when first seen within [-`seenFrom`, `seenTo`] of the contact (v32): a toss glued to the
    /// serve moves the fitted hit 0.7 s early while the ball is first seen at the contact (tt night video 657.44,
    /// 733.15: two serves found, none lost).
    static func poseServeShot(_ e: PoseServeEvent, contact: Double? = nil, shots: [IndependentShotResult], segment: Int) -> Int? {
        let tc = contact ?? e.end + PoseServe.contactLag
        let found = shots.indices.filter { i in
            let s = shots[i], dt = s.tHit - e.end
            guard s.segment == segment && s.hitterSide != "far" else { return false }
            if -PoseServe.before <= dt && dt <= PoseServe.after { return true }
            let firstSeen = Double(s.firstFrame) / IndependentShotFlights.fps - tc
            return dt < -PoseServe.before && -PoseServe.seenFrom <= firstSeen && firstSeen <= PoseServe.seenTo
        }
        let flying = found.filter { i in
            let s = shots[i]
            return s.crossesNet == true || isShortFault(s) || (s.bounceGround.map { $0.count >= 2 && $0[1] > netY } ?? false)
        }
        let firstSeenAfterContact = { (i: Int) in abs(Double(shots[i].firstFrame) / IndependentShotFlights.fps - tc) }
        if let best = flying.min(by: { firstSeenAfterContact($0) < firstSeenAfterContact($1) }) { return best }
        return found.min { abs(shots[$0].tHit - e.end) < abs(shots[$1].tHit - e.end) }
    }

    /// The flight a far swing belongs to: not given to a near hitter, starting between a little before the
    /// swing's first raised sample (a toss glued to the flight) and a little after its last, and crossing the
    /// net (or landing as a short fault). A far serve is tracked from the racket on, so a piece that goes
    /// nowhere is the toss, or a ball bounced before the serve; an arm raised with no flight is not a serve.
    /// Of several, the first: nothing comes back over the net within the window. (A far serve into the net
    /// crosses nothing and is left to the flight rules: naming it by a swing seen through the ball found four
    /// more serves on one night video, and three false ones and a speed gone wrong on the other.)
    static func swingShot(_ w: ServeSwing, shots: [IndependentShotResult], segment: Int) -> Int? {
        let found = shots.indices.filter { i in
            let s = shots[i]
            return s.segment == segment && s.hitterSide != (w.near ? "far" : "near")
                && w.start - PoseServe.before <= s.tHit && s.tHit <= w.end + PoseServe.after
        }
        let flying = found.filter { shots[$0].crossesNet == true || isShortFault(shots[$0]) }
        return flying.min { shots[$0].tHit < shots[$1].tHit }
    }

    /// What the region poses saw of the players at one end over a stretch: not enough (shoulders, hips and a
    /// wrist in fewer of the frames than a reading every `Swing.densePeriod` has), an arm raised in some
    /// sample, or every arm down throughout.
    enum Watch { case unseen, raised, lowered }
    static func watched(_ people: IndependentPeople, near: Bool, from: Double, to: Double) -> Watch {
        var seen = 0, raised = false
        for f in people.poses.keys {
            let t = Double(f) / 60
            guard t >= from, t <= to else { continue }
            let ups = (people.poses[f] ?? []).filter { $0.near == near }.compactMap(\.armUp)
            if !ups.isEmpty { seen += 1 }
            if ups.contains(where: { $0 >= PoseServe.raised }) { raised = true }
        }
        if raised { return .raised }
        return Double(seen) >= (to - from) / Swing.densePeriod ? .lowered : .unseen
    }

    /// A flight that is part of a rally: long, cleanly fitted and crossing the net, moving in the image and hit
    /// from within reach of the court (v32). A ball rolling at the net, or one on the next court whose fit put the
    /// hitter 8-14 m off the centre line, looked like a rally and kept the serve that followed from being one
    /// (tt night video 353.60, 683.13: two serves found, none lost).
    public static func isRallyFlight(_ s: IndependentShotResult) -> Bool {
        s.accepted && s.crossesNet == true && s.nObs >= Serve.rallyPoints && Double(s.lastFrame - s.firstFrame) / 60 >= Serve.rallySeconds
            && (s.rmsPx ?? .infinity) <= Serve.rallyRMS
            && (s.imageStep ?? .infinity) >= Serve.rallyStep
            && (s.fitHit.map { $0.isEmpty || abs($0[0]) <= Serve.rallyHitX } ?? true)
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
        if s.poseDenied == true { return false }
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
            var t = shots[i].tHit
            if shots[i].poseServe == true {
                // the window is measured back from the contact when one was seen or refitted (v32): from a hit timed
                // at a glued toss, half a second early, it took in a flight hit 3.2 s before the contact (tt 134.50)
                t = shots[i].tossGluedContact ?? shots[i].poseContact ?? t
                // seen serving. A forehand's follow-through can hold the wrist as high for a sample or two, but
                // only in a rally: a rally flight in the seconds before says so (v28; tt night video 182.47, 562.45)
                let from = t - PoseServe.rallyFrom, to = t - PoseServe.rallyTo
                if priorRally.contains(where: { from <= $0 && $0 < to }) { return false }
                return !shots.indices.contains { j in
                    j != i && isRallyFlight(shots[j]) && !returns.contains(j) && !like.contains(j) && from <= shots[j].tHit && shots[j].tHit < to
                }
            }
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
                // a serve seen in the server's pose is the serve; other serve-like flights around it are not (v27).
                // Seen at both ends within the return window (v29): the later swing is the return, hit overhead
                if shots[i].poseServe == true {
                    guard shots[j].poseServe == true, let a = shots[i].hitterSide, let b = shots[j].hitterSide, a != b else { return false }
                    return shots[j].tHit < t && t - shots[j].tHit < Serve.returnWithin
                }
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
