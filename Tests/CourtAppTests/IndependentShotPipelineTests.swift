import XCTest
import simd
@testable import CourtCore

/// Synthetic checks of the in-house shot chain. They prove the code path and the geometry, not
/// tennis accuracy: the flights are generated with the same drag model the fit assumes.
final class IndependentShotPipelineTests: XCTestCase {
    let camera = IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0), from: SIMD3(0.3, -6.4, 3.1), f: 1400)

    func testRotationVectorRoundTripAndRayInversion() {
        let r = SIMD3(1.84, -0.013, 0.013)
        let back = IndependentPinholeCamera.rotationVector(IndependentPinholeCamera.rodrigues(r))
        XCTAssertLessThan(simd_length(back - r), 1e-9)
        let cam = IndependentProjector(camera)
        let X = SIMD3(2.0, 18.0, 0.033)
        let q = cam.project(X)
        XCTAssertGreaterThan(q.depth, 0)
        XCTAssertLessThan(simd_length(cam.onPlaneZ(q.u, q.v, z: 0.033) - X), 1e-6)
        XCTAssertLessThan(simd_length(camera.centre - SIMD3(0.3, -6.4, 3.1)), 1e-9)
    }

    func testSimulationRunsBackwardsToItsStart() {
        let s0 = IndependentFlight.State(p: SIMD3(0, 0, 1), v: SIMD3(1, 25, 4))
        let ahead = IndependentFlight.simulate(s0, [30.5])[0]
        let back = IndependentFlight.simulate(ahead, [-30.5])[0]
        XCTAssertLessThan(simd_length(back.p - s0.p), 1e-6)
        XCTAssertLessThan(ahead.p.y, 25 * 30.5 / 60, "drag slows the ball")
    }

    /// A near-baseline hit to a far bounce, seen from the first frames after contact.
    func testSyntheticShotGetsABounceAnchoredSpeed() throws {
        let cam = IndependentProjector(camera)
        let t0 = 600.0                       // 10 s, in 1/60 s units
        var s = IndependentFlight.State(p: SIMD3(0.5, 0.3, 1.0), v: SIMD3(-1.0, 24, 3.0))
        var truth = [(Double, IndependentFlight.State)]()
        var k = 0.0
        while s.p.z > IndependentCourt.ballRadius || k == 0 {
            truth.append((t0 + k, s)); s = IndependentFlight.rk4(s, 1 / 60); k += 1
        }
        let bounceTime = t0 + k
        var after = IndependentFlight.State(p: SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius), v: SIMD3(s.v.x * 0.8, s.v.y * 0.75, -s.v.z * 0.65))
        for j in 0..<18 { truth.append((bounceTime + Double(j), after)); after = IndependentFlight.rk4(after, 1 / 60) }
        var candidates = [IndependentShotCandidate]()
        for (n, (t, st)) in truth.enumerated() where t >= t0 + 2 {
            let q = cam.project(st.p)
            candidates.append(IndependentShotCandidate(decodeIndex: n, time: t, u: q.u, v: q.v, peak: 0.9))
        }
        let shots = IndependentShotPipeline.run(candidates: candidates, segments: [.init(camera: camera)]) { _, _ in IndependentPeople([:]) }
        let shot = try XCTUnwrap(shots.first { $0.bounceFound })
        XCTAssertTrue(shot.accepted, shot.reason ?? "")
        let speed = try XCTUnwrap(shot.reportedSpeedKmh)
        // S家's endpoint formula on the true flight, from the first observation to the net
        let first = truth.first { $0.0 == t0 + 2 }!.1
        let net = truth.first { $0.1.p.y >= IndependentCourt.netY }!
        let prev = truth[truth.firstIndex { $0.0 == net.0 }! - 1]
        let fr = (IndependentCourt.netY - prev.1.p.y) / (net.1.p.y - prev.1.p.y)
        let pNet = prev.1.p + fr * (net.1.p - prev.1.p), T = (prev.0 + fr - (t0 + 2)) / 60
        var v = (pNet - first.p) / T; v.z += 0.5 * IndependentFlight.g * T
        let reference = simd_length(v) * 3.6
        XCTAssertEqual(speed, reference, accuracy: reference * 0.03)
        let ground = try XCTUnwrap(shot.bounceGround)
        XCTAssertEqual(ground[1], s.p.y, accuracy: 0.4)
        let rows = IndependentShotPipeline.rows(from: shots, streamID: UUID())
        XCTAssertTrue(rows.allSatisfy { $0.origin == "independent" })
        XCTAssertNotNil(rows.first { $0.speedKPH != nil }?.bounce?.yMeters)
    }

    /// 2026-11-06: a shot with no bounce, no speed and a contact off the court has nothing to show and makes no
    /// row; anything with one of the three keeps one. Callers that pair rows with shots filter by `keeps`.
    func testAShotWithNothingToShowMakesNoRow() {
        var empty = IndependentShotResult(hitKind: "hit junction", hitterFound: true, bounceFound: false, contactUV: [960, 540],
                                          hitterBox: nil, incoming: nil, hitterSide: nil, tHit: 10, nObs: 3, firstFrame: 0, lastFrame: 0)
        XCTAssertFalse(IndependentShotPipeline.keeps(empty))
        XCTAssertTrue(IndependentShotPipeline.rows(from: [empty], streamID: UUID()).isEmpty)
        empty.fitHit = [1e73, 5e73, 1]
        XCTAssertFalse(IndependentShotPipeline.keeps(empty), "a contact hundreds of metres away is not a shot")
        empty.fitHit = [1, 20, 1]
        XCTAssertTrue(IndependentShotPipeline.keeps(empty))
        XCTAssertEqual(IndependentShotPipeline.rows(from: [empty], streamID: UUID()).count, 1)
        empty.fitHit = nil
        empty.bounceGround = [1, 5, 0]
        XCTAssertTrue(IndependentShotPipeline.keeps(empty), "a bounce is always worth a row")
        empty.bounceGround = nil
        empty.accepted = true; empty.speedKmh = 120; empty.speedAnchor = .serveBaseline
        XCTAssertTrue(IndependentShotPipeline.keeps(empty), "so is a speed")
    }

    /// The same synthetic shot fed in time order: the live chain publishes it once settled, with the
    /// batch speed, within a second of the bounce; a reset freezes it.
    func testLiveChainPublishesTheBatchShotAfterTheBounce() throws {
        let cam = IndependentProjector(camera)
        let t0 = 600.0
        var s = IndependentFlight.State(p: SIMD3(0.5, 0.3, 1.0), v: SIMD3(-1.0, 24, 3.0))
        var points = [(Double, SIMD3<Double>)]()
        var k = 0.0
        while s.p.z > IndependentCourt.ballRadius || k == 0 { points.append((t0 + k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        let bounceTime = (t0 + k) / 60
        var after = IndependentFlight.State(p: SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius), v: SIMD3(s.v.x * 0.8, s.v.y * 0.75, -s.v.z * 0.65))
        for j in 0..<18 { points.append((t0 + k + Double(j), after.p)); after = IndependentFlight.rk4(after, 1 / 60) }
        let candidates = points.enumerated().filter { $0.element.0 >= t0 + 2 }.map { n, p in
            let q = cam.project(p.1); return IndependentShotCandidate(decodeIndex: n, time: p.0, u: q.u, v: q.v, peak: 0.9)
        }
        let people = IndependentPeople([:])
        let batch = IndependentShotPipeline.run(candidates: candidates, segments: [.init(camera: camera)]) { _, _ in people }
        let expected = try XCTUnwrap(batch.first { $0.bounceFound }?.reportedSpeedKmh)

        var live = IndependentLiveShots(), next = 0, now = 9.75
        while now < 13 {
            now += 0.25
            var arrived = [IndependentShotCandidate]()
            while next < candidates.count, candidates[next].time / 60 < now { arrived.append(candidates[next]); next += 1 }
            live.append(arrived)
            live.update(now: now, camera: camera, people: people)
        }
        let shown = try XCTUnwrap(live.published.first { $0.shot.reportedSpeedKmh != nil })
        XCTAssertEqual(try XCTUnwrap(shown.shot.reportedSpeedKmh), expected, accuracy: 1e-9)
        let delay = try XCTUnwrap(shown.speedPublished) - bounceTime
        XCTAssertGreaterThan(delay, 0.5, "not shown before the flight settles")
        XCTAssertLessThan(delay, 1.2)
        live.reset()
        XCTAssertTrue(live.published.allSatisfy(\.frozen))
        XCTAssertTrue(live.update(now: 13.25, camera: camera, people: people).isEmpty, "nothing is stitched across a reset")
    }

    /// A recorded trace (court unknown at first, then found and caught up) survives a JSON round trip
    /// and replays to exactly what the live chain published.
    func testLiveTraceReplaysThePublishedShots() throws {
        let cam = IndependentProjector(camera)
        var s = IndependentFlight.State(p: SIMD3(0.5, 0.3, 1.0), v: SIMD3(-1.0, 24, 3.0))
        var candidates = [IndependentShotCandidate](), k = 0
        while s.p.z > IndependentCourt.ballRadius || k < 60 {
            let q = cam.project(s.p)
            if k >= 2 { candidates.append(IndependentShotCandidate(decodeIndex: k, time: 600 + Double(k), u: q.u, v: q.v, peak: 0.9)) }
            s = IndependentFlight.rk4(s, 1 / 60); k += 1
            if s.p.z < IndependentCourt.ballRadius { s.p.z = IndependentCourt.ballRadius; s.v.z = -0.65 * s.v.z; s.v.x *= 0.8; s.v.y *= 0.75 }
        }
        let bystander = IndependentPersonBox(x0: 40, y0: 40, x1: 60, y1: 100, confidence: 0.8, fromCrop: false, cropBottom: nil)
        var trace: [IndependentLiveTraceEvent] = [.newStream, .people(frame: 610, boxes: [bystander])]
        let people = IndependentPeople([610: [bystander]])
        var live = IndependentLiveShots(), next = 0, now = 9.75, found = false
        while now < 13 {
            now += 0.25
            var arrived = [IndependentShotCandidate]()
            while next < candidates.count, candidates[next].time / 60 < now { arrived.append(candidates[next]); next += 1 }
            live.append(arrived); trace.append(.candidates(arrived))
            if now < 10.5 {
                live.trim(keeping: IndependentLiveEngine.pendingSeconds, now: now); trace.append(.trim(now: now))
            } else if !found {
                found = true; trace += [.camera(camera), .catchUp(now: now)]
                live.catchUp(now: now, camera: camera, people: people)
            } else {
                trace.append(.update(now: now)); live.update(now: now, camera: camera, people: people)
            }
        }
        XCTAssertFalse(live.published.isEmpty)
        let decoded = try JSONDecoder().decode([IndependentLiveTraceEvent].self, from: JSONEncoder().encode(trace))
        XCTAssertEqual(decoded, trace)
        let replayed = IndependentLiveTrace.replay(decoded)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed[0].map(\.tHit), live.published.map(\.shot.tHit))
        XCTAssertEqual(replayed[0].map(\.reportedSpeedKmh), live.published.map(\.shot.reportedSpeedKmh))
        XCTAssertEqual(replayed[0].map(\.stroke), live.published.map(\.shot.stroke))
    }

    /// The candidate override keeps every other event where it was (2026-11-06): a detector's candidates
    /// land in the batch whose last candidate is not earlier than them, so trims and updates between
    /// batches still apply to the candidates in their own time.
    func testCandidateOverrideKeepsTheOtherEventsInPlace() throws {
        let a = IndependentShotCandidate(decodeIndex: 1, time: 10, u: 100, v: 100, peak: 0.9)
        let b = IndependentShotCandidate(decodeIndex: 2, time: 20, u: 110, v: 100, peak: 0.9)
        let events: [IndependentLiveTraceEvent] = [.newStream, .candidates([a]), .trim(now: 0.3), .candidates([b]), .update(now: 0.5)]
        let replaced = IndependentLiveTrace.replacingCandidates(in: events, with: [
            IndependentShotCandidate(decodeIndex: 1, time: 5, u: 1, v: 2, peak: 0.4),
            IndependentShotCandidate(decodeIndex: 2, time: 15, u: 3, v: 4, peak: 0.4),
            IndependentShotCandidate(decodeIndex: 3, time: 25, u: 5, v: 6, peak: 0.4),
        ])
        guard case .candidates(let first) = replaced[1], case .candidates(let second) = replaced[3] else { return XCTFail("the batches moved") }
        XCTAssertEqual(first.map(\.u), [1], "a candidate later than the batch's last one waits for the next batch")
        XCTAssertEqual(second.map(\.u), [3])
        guard case .candidates(let tail) = replaced[5] else { return XCTFail("the trailing candidates are dropped") }
        XCTAssertEqual(tail.map(\.u), [5], "candidates after the last batch are appended, not lost")
        guard case .trim(let now) = replaced[2] else { return XCTFail("the trim moved") }
        XCTAssertEqual(now, 0.3)
        guard case .update(let updated) = replaced[4] else { return XCTFail("the update moved") }
        XCTAssertEqual(updated, 0.5)
    }

    /// The picture moved while the shot flew: the live chain drops those candidates (`discard`), the
    /// catch-up publishes nothing from them, and the trace replays to the same empty list.
    func testDiscardedCandidatesAreNotCaughtUp() throws {
        let cam = IndependentProjector(camera)
        var s = IndependentFlight.State(p: SIMD3(0.5, 0.3, 1.0), v: SIMD3(-1.0, 24, 3.0))
        var candidates = [IndependentShotCandidate](), k = 0
        while s.p.z > IndependentCourt.ballRadius || k < 60 {
            let q = cam.project(s.p)
            if k >= 2 { candidates.append(IndependentShotCandidate(decodeIndex: k, time: 600 + Double(k), u: q.u, v: q.v, peak: 0.9)) }
            s = IndependentFlight.rk4(s, 1 / 60); k += 1
            if s.p.z < IndependentCourt.ballRadius { s.p.z = IndependentCourt.ballRadius; s.v.z = -0.65 * s.v.z; s.v.x *= 0.8; s.v.y *= 0.75 }
        }
        let end = (candidates.last?.time ?? 600) / 60 + 0.01
        var live = IndependentLiveShots()
        var trace: [IndependentLiveTraceEvent] = [.newStream, .candidates(candidates), .discard(before: end), .camera(camera), .catchUp(now: end + 2)]
        live.append(candidates); live.trim(keeping: 0, now: end)
        XCTAssertTrue(live.catchUp(now: end + 2, camera: camera, people: IndependentPeople([:])).isEmpty)
        XCTAssertTrue(live.published.isEmpty, "nothing seen while moving is published")
        trace = try JSONDecoder().decode([IndependentLiveTraceEvent].self, from: JSONEncoder().encode(trace))
        XCTAssertEqual(IndependentLiveTrace.replay(trace).first?.count, 0)
    }

    /// Right-handed rules: near forehand to the image right, far forehand to the image left,
    /// a serve at the baseline above the head, a volley inside the service line.
    func testStrokeRules() {
        let cam = IndependentProjector(camera)
        func box(feet: SIMD3<Double>) -> IndependentPersonBox {
            let f = cam.project(feet), head = cam.project(feet + SIMD3(0, 0, 1.8))
            let h = f.v - head.v, w = 0.4 * h
            return IndependentPersonBox(x0: f.u - w / 2, y0: head.v, x1: f.u + w / 2, y1: f.v, confidence: 0.9, fromCrop: false, cropBottom: nil)
        }
        func shot(_ t: Double, _ b: IndependentPersonBox, du: Double, dv: Double) -> IndependentShotResult {
            IndependentShotResult(hitKind: "hit junction", hitterFound: true, bounceFound: false,
                                  contactUV: [(b.x0 + b.x1) / 2 + du * b.width, b.y0 + dv * b.height], hitterBox: b,
                                  incoming: nil, hitterSide: nil, tHit: t, nObs: 20, firstFrame: 0, lastFrame: 0)
        }
        let near = box(feet: SIMD3(1.2, -1.5, 0)), far = box(feet: SIMD3(-0.5, 25.0, 0))
        let farServer = box(feet: SIMD3(0.3, 23.9, 0)), netPlayer = box(feet: SIMD3(0.5, 8.0, 0))
        var serve = shot(10, farServer, du: 0.2, dv: -0.4)       // far serve: crosses the net, contact 2.6 m high
        serve.crossesNet = true; serve.fitHit = [0.3, 23.9, 2.6]
        var shots = [serve,
                     shot(11.2, near, du: 0.6, dv: 0.5),          // near forehand
                     shot(12.4, far, du: -0.6, dv: 0.5),          // far forehand
                     shot(13.5, netPlayer, du: -0.6, dv: 0.5),    // near backhand volley (no near bounce since 12.4)
                     shot(20, far, du: 0.6, dv: 0.5)]             // far backhand
        IndependentStrokeRules.classify(&shots, bounces: [(9.0, 5.0)], cameras: [cam])
        XCTAssertEqual(shots.map(\.stroke), ["发球", "正手", "正手", "反手 截击", "反手"])
        XCTAssertEqual(IndependentStrokeRules.kind("反手 截击"), .volley)
        var unseen = [IndependentShotResult(hitKind: "first observation", hitterFound: false, bounceFound: true, contactUV: [900, 400],
                                            hitterBox: nil, incoming: nil, hitterSide: "near", tHit: 3, nObs: 20, firstFrame: 0, lastFrame: 0)]
        IndependentStrokeRules.classify(&unseen, bounces: [], cameras: [cam])
        XCTAssertNil(unseen[0].stroke, "an unseen hitter stays unknown")
    }

    /// v14 serve rules: serve-like flights (hitter at the own baseline in the image, contact 1.9-3.3 m,
    /// crossing the net) after a dead ball; one serve per point start, the flight with most points.
    func testServeRules() {
        let cam = IndependentProjector(camera)
        func box(feet: SIMD3<Double>) -> IndependentPersonBox {
            let f = cam.project(feet), head = cam.project(feet + SIMD3(0, 0, 1.8))
            let h = f.v - head.v, w = 0.4 * h
            return IndependentPersonBox(x0: f.u - w / 2, y0: head.v, x1: f.u + w / 2, y1: f.v, confidence: 0.9, fromCrop: false, cropBottom: nil)
        }
        let nearServer = box(feet: SIMD3(1.0, -0.4, 0)), farServer = box(feet: SIMD3(-1.0, 24.2, 0))
        let midCourt = box(feet: SIMD3(1.0, 4.0, 0))
        // image baseline offset: at the line ~0, behind it positive on both sides, inside the court negative
        XCTAssertEqual(IndependentStrokeRules.behindInBoxHeights(box(feet: SIMD3(1, 0, 0)), near: true, cam)!, 0, accuracy: 0.02)
        XCTAssertGreaterThan(IndependentStrokeRules.behindInBoxHeights(nearServer, near: true, cam)!, 0.05)
        XCTAssertGreaterThan(IndependentStrokeRules.behindInBoxHeights(farServer, near: false, cam)!, 0)
        XCTAssertLessThan(IndependentStrokeRules.behindInBoxHeights(midCourt, near: true, cam)!, -0.35)

        func flight(_ t: Double, _ b: IndependentPersonBox, z: Double = 2.6, n: Int = 30, net: Bool = true, du: Double = 0.6) -> IndependentShotResult {
            var s = IndependentShotResult(hitKind: "hit junction", hitterFound: true, bounceFound: false,
                                          contactUV: [(b.x0 + b.x1) / 2 + du * b.width, b.y0 + 0.5 * b.height], hitterBox: b,
                                          incoming: nil, hitterSide: nil, tHit: t, nObs: n, firstFrame: Int(t * 60), lastFrame: Int(t * 60) + 2 * n)
            s.crossesNet = net; s.fitHit = [0, 0, z]; s.rmsPx = 1.5; s.accepted = true   // rally evidence is an accepted fit (v18)
            return s
        }
        var shots = [flight(10, nearServer),                       // serve: nothing before it
                     flight(11.5, farServer, z: 1.0),              // return (contact too low for a serve)
                     flight(13, nearServer, z: 1.2),               // rally
                     flight(16, nearServer),                       // serve-like, but the rally at 13 is 3 s before
                     flight(30, farServer, n: 18),                 // fault and second ball of a point start:
                     flight(31.2, farServer, n: 28),               //   one serve, the flight with more points
                     flight(45, midCourt, z: 1.1),                 // rally flight just before a serve-like one
                     flight(46.5, nearServer),
                     flight(60, farServer, net: false)]            // does not cross the net
        IndependentStrokeRules.classify(&shots, bounces: [], cameras: [cam])
        XCTAssertEqual(shots.map { $0.stroke == "发球" }, [true, false, false, false, false, true, false, false, false])
        XCTAssertTrue(IndependentStrokeRules.isRallyFlight(shots[2]))
        XCTAssertFalse(IndependentStrokeRules.isRallyFlight(flight(0, nearServer, n: 20)), "short flights are not rally evidence")

        // the live window passes earlier published rally flights: same dead-ball test at the window start
        var alone = [flight(80, nearServer)]
        IndependentStrokeRules.classify(&alone, bounces: [], cameras: [cam], priorRally: [77])
        XCTAssertNotEqual(alone[0].stroke, "发球")
        alone = [flight(80, nearServer)]
        IndependentStrokeRules.classify(&alone, bounces: [], cameras: [cam], priorRally: [74])
        XCTAssertEqual(alone[0].stroke, "发球", "a rally more than 5 s before is a dead ball")
    }

    /// v22 serve rules: a climbing flight is no serve; on a low camera an own-fit serve needs its contact near
    /// the server's baseline; of two same-end candidates the later wins when the earlier ended short of the net.
    func testServeRulesV22() {
        func flight(_ t: Double, side: String = "near", n: Int = 30, y: Double = 0.2, rise: Double? = 0.1,
                    net: Bool = true, frames: Int? = nil) -> IndependentShotResult {
            var s = IndependentShotResult(hitKind: "hit junction", hitterFound: true, bounceFound: false, contactUV: [0, 0], hitterBox: nil,
                                          incoming: nil, hitterSide: side, tHit: t, nObs: n, firstFrame: Int(t * 60),
                                          lastFrame: Int(t * 60) + (frames ?? 2 * n))
            s.crossesNet = net; s.accepted = net; s.fitHit = [0, y, 2.6]; s.rmsPx = 1.5; s.serveBehindPx = 0.2; s.riseM = rise
            return s
        }
        XCTAssertTrue(IndependentStrokeRules.isServeLike(flight(10)))
        XCTAssertFalse(IndependentStrokeRules.isServeLike(flight(10, rise: 1.6)), "a lob climbs")
        var fed = flight(10, side: "far", y: 18.4)
        XCTAssertTrue(IndependentStrokeRules.isServeLike(fed), "high camera: the own fit's depth decides nothing")
        fed.lowCamera = true
        XCTAssertFalse(IndependentStrokeRules.isServeLike(fed), "low camera: contact 5 m inside the far baseline")
        var hyp = flight(10, rise: 1.6); hyp.serveFit = true; hyp.fromToss = true; hyp.serveRise = 0.2
        XCTAssertTrue(IndependentStrokeRules.isServeLike(hyp), "the serve hypothesis's own rise counts")

        // a bounce or toss before the serve (more points, short of the net), then the serve
        let shots = [flight(20, n: 47, net: false, frames: 50), flight(21.8, n: 44)]
        XCTAssertEqual(IndependentStrokeRules.serves(shots, priorRally: []), [1])
        // a serve that crossed the net, then another same-end flight: the one with more points
        let crossed = [flight(30, n: 47, frames: 30), flight(31.5, n: 24)]
        XCTAssertEqual(IndependentStrokeRules.serves(crossed, priorRally: []), [0])
    }

    /// v27 (2026-11-11, night videos): a second serve is not blocked by the first, a return's bounce does not take
    /// the serve from the serve, a serve that lands short of the net is a serve, and the near server's raised
    /// arm names the serve.
    func testServeRulesV27() {
        func flight(_ t: Double, side: String = "near", n: Int = 30, speed: Double? = 100, bounce: [Double]? = nil,
                    net: Bool = true) -> IndependentShotResult {
            var s = IndependentShotResult(hitKind: "first observation", hitterFound: true, bounceFound: bounce != nil, contactUV: [0, 0],
                                          hitterBox: nil, incoming: nil, hitterSide: side, tHit: t, nObs: n, firstFrame: Int(t * 60),
                                          lastFrame: Int(t * 60) + 2 * n)
            s.crossesNet = net; s.accepted = net; s.fitHit = [0, side == "near" ? 0.2 : 23.6, 2.6]; s.rmsPx = 1.5
            s.serveBehindPx = 0.1; s.riseM = 0; s.speedKmh = speed; s.bounceGround = bounce
            return s
        }
        // a first serve (a long, clean flight over the net) and the second serve 4.5 s later
        XCTAssertEqual(IndependentStrokeRules.serves([flight(1357.7, n: 36, bounce: [1, 17]), flight(1362.3, n: 49, bounce: [1, 17])],
                                                     priorRally: []), [0, 1])
        // a 131 km/h serve without a tracked landing, and its return 1.8 s later with one
        XCTAssertEqual(IndependentStrokeRules.serves([flight(847.7, speed: 131), flight(849.5, side: "far", n: 44, speed: 37, bounce: [1, 3])],
                                                     priorRally: []), [0])
        // a far serve that lands on its own side, 9 m from the baseline, and a ball bounced at the server's feet
        let short = flight(1301.7, side: "far", n: 23, speed: 91, bounce: [-2.4, 15.0], net: false)
        XCTAssertTrue(IndependentStrokeRules.isShortFault(short)); XCTAssertTrue(IndependentStrokeRules.isServeLike(short))
        XCTAssertFalse(IndependentStrokeRules.isServeLike(flight(10, side: "far", speed: 30, bounce: [0, 22.5], net: false)))

        // the pose: raised samples at the near baseline make one event; a follow-through (0.7) does not
        let cam = IndependentProjector(camera)
        func person(_ up: Double?, feet: SIMD3<Double> = SIMD3(1.0, -0.3, 0)) -> IndependentPersonBox {
            let f = cam.project(feet), head = cam.project(feet + SIMD3(0, 0, 1.8))
            var b = IndependentPersonBox(x0: f.u - 40, y0: head.v, x1: f.u + 40, y1: f.v, confidence: 0.9, fromCrop: false, cropBottom: nil)
            b.armUp = up
            return b
        }
        let people = IndependentPeople([600: [person(0.2)], 612: [person(0.7)], 624: [person(1.4)], 636: [person(1.1)], 648: [person(-0.5)],
                                        1200: [person(0.7)], 1800: [person(1.5, feet: SIMD3(1, 6, 0))]])
        let events = IndependentStrokeRules.poseServes(people, camera: cam)
        XCTAssertEqual(events.count, 1, "the follow-through and the raised arm at mid-court are not serves")
        XCTAssertEqual(events[0].end, 10.6, accuracy: 0.001)
        var garbled = flight(10.5, n: 46, speed: nil, net: false); garbled.fitHit = [-0.5, 57.7, -3.5]
        let returned = flight(12.0, side: "far", n: 40, speed: 60, bounce: [1, 4])
        XCTAssertEqual(IndependentStrokeRules.poseServeShot(events[0], shots: [garbled, returned], segment: 0), 0)
        // v30: the serve itself, first seen 0.1 s after the seen contact and its hit reached back half a second, not
        // the eight points at the contact that go nowhere although their hit is nearer the raised arm
        let piece = flight(10.6, n: 8, speed: nil, net: false)
        var served = flight(10.15, n: 33, speed: 98); served.firstFrame = Int(10.8 * 60)
        XCTAssertEqual(IndependentStrokeRules.poseServeShot(events[0], contact: 10.7, shots: [served, piece, returned], segment: 0), 0)
        XCTAssertEqual(IndependentStrokeRules.poseServeShot(events[0], contact: 10.7, shots: [piece, returned], segment: 0), 0,
                       "nothing goes anywhere: the nearest hit, as before")
        garbled.poseServe = true
        XCTAssertEqual(IndependentStrokeRules.serves([garbled, returned], priorRally: [5.0]), [0], "seen serving: no fit needed")
        // v28: a rally flight in the three seconds before says the raised arm was a swing in the rally
        XCTAssertEqual(IndependentStrokeRules.serves([garbled, returned], priorRally: [8.0]), [])
        var rally = flight(8.6, side: "far", n: 40, speed: 70, bounce: [1, 4]); rally.fitHit = [0, 20, 1.0]; rally.serveBehindPx = nil
        XCTAssertTrue(IndependentStrokeRules.isRallyFlight(rally))
        XCTAssertEqual(IndependentStrokeRules.serves([rally, garbled], priorRally: []), [])
        // v28: the pose serve is a row although its fit has no usable contact; the same flight unnamed is not
        garbled.bounceGround = nil; garbled.fitHit = [-0.5, 577, -3.5]
        XCTAssertFalse(IndependentShotPipeline.keeps(garbled))
        garbled.stroke = "发球"
        XCTAssertTrue(IndependentShotPipeline.keeps(garbled))
    }

    /// v29: the region poses follow the near players at their baseline and the far players behind their service
    /// line; a sample reads the raised arm like the whole-frame pose does; a trace carries the samples.
    func testRegionPosesFollowTheServersAndReplay() throws {
        let cam = IndependentProjector(camera)
        func person(_ feet: SIMD3<Double>, crop: Bool = false) -> IndependentPersonBox {
            let f = cam.project(feet), head = cam.project(feet + SIMD3(0, 0, 1.8)), w = 0.25 * (f.v - head.v)
            return IndependentPersonBox(x0: f.u - w, y0: head.v, x1: f.u + w, y1: f.v, confidence: 0.9, fromCrop: crop, cropBottom: crop ? 2000 : nil)
        }
        let server = person(SIMD3(1, -0.3, 0)), atNet = person(SIMD3(-2, 8, 0)), farServer = person(SIMD3(-1, 24, 0), crop: true)
        let farNet = person(SIMD3(2, 14, 0), crop: true)
        let found = IndependentLivePoses.players(boxes: [server, atNet, farServer, farNet], camera: camera)
        XCTAssertEqual(found.near, [server]); XCTAssertEqual(found.far, [farServer])
        let regions = IndependentLivePoses.regions(near: found.near, far: found.far, width: 1920, height: 1080)
        XCTAssertEqual(regions.map(\.near), [true, false])
        XCTAssertLessThan(Double(regions[0].rect.minY), server.y0 - 0.5 * server.height + 1, "room for the racket arm above the box")
        XCTAssertGreaterThanOrEqual(Double(regions[1].rect.width), 299); XCTAssertGreaterThanOrEqual(Double(regions[1].rect.height), 149)
        XCTAssertTrue(regions[1].rect.contains(CGPoint(x: (farServer.x0 + farServer.x1) / 2, y: farServer.y0)))
        XCTAssertTrue(regions.allSatisfy { CGRect(x: 0, y: 0, width: 1920, height: 1080).contains($0.rect) })

        // shoulders at row 400, hips at 440, the right wrist at 350: 1.25 torso lengths above the shoulders
        var joints = [Double](repeating: 0, count: 30)
        func set(_ j: IndependentPoseSample.Joint, _ u: Double, _ v: Double, _ c: Double = 0.8) { joints.replaceSubrange((j.rawValue * 3)..<(j.rawValue * 3 + 3), with: [u, v, c]) }
        set(.leftShoulder, 990, 400); set(.rightShoulder, 1010, 400); set(.leftHip, 992, 440); set(.rightHip, 1008, 440)
        set(.rightWrist, 1015, 350); set(.leftWrist, 985, 300, 0.1); set(.leftAnkle, 995, 480)
        let sample = IndependentPoseSample(near: false, region: [850, 330, 300, 150], joints: joints)
        XCTAssertEqual(sample.armUp ?? 0, 1.25, accuracy: 1e-9, "the wrist found with 0.1 confidence does not count")
        XCTAssertEqual(sample.feet?.y, 480)
        XCTAssertNil(IndependentPoseSample(near: false, region: [], joints: [Double](repeating: 0, count: 30)).armUp)

        let events: [IndependentLiveTraceEvent] = [.newStream, .poses(frame: 600, samples: [sample]), .peopleReset]
        XCTAssertEqual(try JSONDecoder().decode([IndependentLiveTraceEvent].self, from: JSONEncoder().encode(events)), events)
        XCTAssertEqual(IndependentPeople([:], poses: [600: [sample]]).poses[600]?.first?.armUp ?? 0, 1.25, accuracy: 1e-9)
    }

    /// v29: a far server's swing in the region poses is an event with its contact at the top of the hitting
    /// wrist; a far flight with nobody swinging where the players were watched is denied; the seen contact is
    /// a point over the baseline above the wrist.
    func testServeSwingsTimeTheContactAndDenyUnswungServes() {
        let cam = IndependentProjector(camera)
        // a far server at 10 Hz: the toss arm up first, then the hitting wrist to its top at frame 660 (11.0 s)
        func pose(wrist z: Double, other: Double = 0.9) -> IndependentPoseSample {
            func at(_ x: Double, _ z: Double) -> [Double] { let q = cam.project(SIMD3(x, 24.2, z)); return [q.u, q.v, 0.8] }
            let joints = at(-0.2, 1.45) + at(0.2, 1.45) + at(-0.3, 1.2) + at(0.3, 1.2) + at(-0.25, other) + at(0.25, z)
                + at(-0.15, 0.95) + at(0.15, 0.95) + at(-0.15, 0.05) + at(0.15, 0.05)
            return IndependentPoseSample(near: false, region: [800, 300, 300, 150], joints: joints)
        }
        var poses = [Int: [IndependentPoseSample]]()
        for (k, f) in stride(from: 600, through: 720, by: 6).enumerated() {
            let t = Double(k - 10) / 10                                  // seconds from the contact
            poses[f] = [pose(wrist: abs(t) <= 0.3 ? 2.45 - 15 * t * t : 0.9, other: t < -0.4 && t > -0.9 ? 2.1 : 0.9)]
        }
        // ... and one whose hitting wrist is never found: only the toss arm, up for half a second and slowly down
        var tossOnly = [Int: [IndependentPoseSample]]()
        for (k, f) in stride(from: 600, through: 720, by: 6).enumerated() {
            let t = Double(k - 10) / 10
            tossOnly[f] = [pose(wrist: 0.9, other: t > -0.9 && t < 0.1 ? 2.2 - 0.6 * (t + 0.5) * (t + 0.5) : 0.9)]
        }
        for f in stride(from: 1200, through: 1320, by: 6) { poses[f] = [pose(wrist: 0.9)] }
        let people = IndependentPeople([:], poses: poses)
        let swings = IndependentStrokeRules.serveSwings(people, camera: cam, near: false)
        XCTAssertEqual(swings.count, 1)
        XCTAssertEqual(swings.first?.contact ?? 0, 11.0, accuracy: 0.02, "the hitting wrist's top, not the toss arm's 0.6 s before")
        XCTAssertEqual(swings.first?.swung, true)
        let tossed = IndependentStrokeRules.serveSwings(IndependentPeople([:], poses: tossOnly), camera: cam, near: false)
        XCTAssertEqual(tossed.count, 1); XCTAssertEqual(tossed.first?.swung, false, "a toss arm's top is not a contact")
        XCTAssertTrue(IndependentStrokeRules.serveSwings(people, camera: cam, near: true).isEmpty)

        func flight(_ t: Double, side: String?) -> IndependentShotResult {
            IndependentShotResult(hitKind: "first observation", hitterFound: side != nil, bounceFound: false, contactUV: [0, 0], hitterBox: nil,
                                  incoming: nil, hitterSide: side, tHit: t, nObs: 30, firstFrame: Int(t * 60), lastFrame: Int(t * 60) + 40)
        }
        var shots = [flight(10.2, side: "near"), flight(10.5, side: "far"), flight(10.9, side: "far"), flight(11.3, side: "far")]
        XCTAssertNil(IndependentStrokeRules.swingShot(swings[0], shots: shots, segment: 0), "an arm raised with no flight over the net names nothing")
        shots[2].crossesNet = true; shots[3].crossesNet = true
        XCTAssertEqual(IndependentStrokeRules.swingShot(swings[0], shots: shots, segment: 0), 2, "the flight over the net, not the toss piece before it")
        XCTAssertEqual(IndependentStrokeRules.watched(people, near: false, from: 9.5, to: 11.3), .raised)
        XCTAssertEqual(IndependentStrokeRules.watched(people, near: false, from: 20.0, to: 21.8), .lowered)
        XCTAssertEqual(IndependentStrokeRules.watched(people, near: false, from: 30.0, to: 31.8), .unseen)
        XCTAssertEqual(IndependentStrokeRules.watched(people, near: true, from: 20.0, to: 21.8), .unseen)
        var denied = flight(20.5, side: "far"); denied.poseDenied = true; denied.serveFit = true; denied.fromToss = true
        XCTAssertFalse(IndependentStrokeRules.isServeLike(denied))

        // the seen contact: over the far baseline, half a metre above the wrist, at serve height
        let hand = swings[0].hand!
        let P = IndependentStrokeRules.seenContact(hand: [hand.x, hand.y], near: false, camera: cam, fallbackX: nil)
        XCTAssertEqual(P.y, IndependentCourt.length - 0.4, accuracy: 1e-9)
        XCTAssertEqual(P.x, 0.25, accuracy: 0.3); XCTAssertTrue((2.6...3.3).contains(P.z))
        XCTAssertEqual(IndependentStrokeRules.seenContact(hand: nil, near: true, camera: cam, fallbackX: 1.5), SIMD3(1.5, 0.4, 2.6))

        // a trace recorded at 20 Hz replays at 10 Hz, or without poses
        let events: [IndependentLiveTraceEvent] = [.newStream] + (0..<6).map { .poses(frame: 600 + 3 * $0, samples: []) } + [.update(now: 11)]
        XCTAssertEqual(IndependentLiveTrace.thinningPoses(in: events, every: 2).count, 5)
        XCTAssertEqual(IndependentLiveTrace.thinningPoses(in: events, every: 0), [.newStream, .update(now: 11)])

        // a flight first seen late keeps its usual fit for the serve rules and takes the late one afterwards
        var usual = flight(12.0, side: "far"); usual.reason = "hit and bounce on the same side of the net"
        var late = usual; late.tHit = 11.2; late.fitHit = [1, 23.5, 1.1]; late.speedKmh = 72; late.accepted = true; late.reason = nil
        usual.lateHit = IndependentShotResult.LateHit(late)
        XCTAssertEqual(usual.tHit, 12.0)
        usual.applyLateHit()
        XCTAssertEqual(usual.tHit, 11.2); XCTAssertTrue(usual.accepted); XCTAssertNil(usual.reason); XCTAssertNil(usual.lateHit)
        XCTAssertEqual(usual.hitKind, IndependentShotFlights.reachedKind)
    }

    /// v22: a toss glued to the start of a flight (one tracked piece) marks the flight as leaving a toss.
    func testGluedTossMarksTheFlightAsFromToss() {
        let cam = IndependentProjector(camera)
        var all = [(Double, SIMD3<Double>)](), b = SIMD3(1.25, 0.2, 1.6), vz = 4.95, k = 600.0
        while !(vz < 0 && b.z <= 2.75) { all.append((k, b)); b.z += vz / 60; vz -= IndependentFlight.g / 60; k += 1 }
        var s = IndependentFlight.State(p: b, v: SIMD3(-4, 36, -2.5))
        while s.p.z > IndependentCourt.ballRadius { all.append((k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        let track = all.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
            let q = cam.project(p.1); return IndependentTrackPoint(t: p.0, u: q.u, v: q.v)
        }
        let flights = IndependentShotFlights.flights(pieces: [track], junctions: [], people: IndependentPeople([:]), camera: cam)
        XCTAssertEqual(flights.count, 1)
        XCTAssertEqual(flights.first?.fromToss, true)
    }

    /// Ball positions of a toss and a serve by a near server, then the bounce in the far service box.
    func serveWithToss(at t0: Double, contactY: Double = -0.3) -> (points: [(Double, SIMD3<Double>)], hit: Double, server: IndependentPersonBox) {
        var points = [(Double, SIMD3<Double>)]()
        var k = 0.0, b = SIMD3(1.25, contactY, 1.5), vz = 5.5
        while !(vz < 0 && b.z <= 2.7) { points.append((t0 + k, b)); b.z += vz / 60; vz -= IndependentFlight.g / 60; k += 1 }
        let hit = t0 + k
        var s = IndependentFlight.State(p: b, v: SIMD3(-1.5, 38, -2.5))
        while s.p.z > IndependentCourt.ballRadius { points.append((t0 + k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        var after = IndependentFlight.State(p: SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius), v: SIMD3(s.v.x * 0.8, s.v.y * 0.75, -s.v.z * 0.65))
        for _ in 0..<18 { points.append((t0 + k, after.p)); after = IndependentFlight.rk4(after, 1 / 60); k += 1 }
        let cam = IndependentProjector(camera)
        // the box stops at the head (1.8 m): contact at 2.7 m is above the usual hit margin of the box
        let f = cam.project(SIMD3(1.0, -0.4, 0)), head = cam.project(SIMD3(1.0, -0.4, 1.8))
        let h = f.v - head.v
        let server = IndependentPersonBox(x0: f.u - 0.2 * h, y0: head.v, x1: f.u + 0.2 * h, y1: f.v, confidence: 0.9, fromCrop: false, cropBottom: nil)
        return (points, hit / 60, server)
    }

    /// A toss then a serve: one shot, a serve at the hit (the toss is the serve's incoming flight, and its
    /// end is the hit although the contact is above the server's box).
    func testTossIsPartOfTheServe() throws {
        let cam = IndependentProjector(camera)
        let (points, hit, server) = serveWithToss(at: 600)
        let candidates = points.enumerated().map { n, p in
            let q = cam.project(p.1); return IndependentShotCandidate(decodeIndex: n, time: p.0, u: q.u, v: q.v, peak: 0.9)
        }
        let people = IndependentPeople(Dictionary(uniqueKeysWithValues: (590...700).map { ($0, [server]) }))
        let shots = IndependentShotPipeline.run(candidates: candidates, segments: [.init(camera: camera)]) { _, _ in people }
        XCTAssertEqual(shots.count, 1, "\(shots.map { ($0.tHit, $0.hitKind, $0.stroke ?? "-") })")
        let serve = try XCTUnwrap(shots.first)
        XCTAssertEqual(serve.tHit, hit, accuracy: 0.1)
        XCTAssertEqual(serve.stroke, "发球", serve.strokeReason ?? "")
        XCTAssertNotNil(serve.reportedSpeedKmh)
    }

    /// S家's endpoint speed of the true flight: from the point at `depth` to the net (or, `toBounce`, to the
    /// first ground contact past the net, as S家 shows serves, v23), gravity-corrected.
    func trueServeSpeed(_ points: [(Double, SIMD3<Double>)], depth: Double, toBounce: Bool = false) -> Double {
        func at(_ y: Double) -> (Double, SIMD3<Double>) {
            let k = points.firstIndex { (p: (Double, SIMD3<Double>)) -> Bool in p.1.y >= y }!
            let a = points[k - 1], b = points[k], fr = (y - a.1.y) / (b.1.y - a.1.y)
            let d: SIMD3<Double> = b.1 - a.1
            let p: SIMD3<Double> = a.1 + fr * d
            return (a.0 + fr * (b.0 - a.0), p)
        }
        let (t0, p0) = at(depth)
        var (t1, p1) = at(IndependentCourt.netY)
        if toBounce {
            let k = points.firstIndex { (p: (Double, SIMD3<Double>)) -> Bool in p.1.y > IndependentCourt.netY && p.1.z <= IndependentCourt.ballRadius + 1e-9 }!
            let a = points[k - 1], b = points[k], fr = (a.1.z - IndependentCourt.ballRadius) / (a.1.z - b.1.z)
            let d: SIMD3<Double> = b.1 - a.1
            (t1, p1) = (a.0 + fr * (b.0 - a.0), a.1 + fr * d)
        }
        let T = (t1 - t0) / 60
        let dp: SIMD3<Double> = p1 - p0
        var v: SIMD3<Double> = dp / T
        v.z += 0.5 * IndependentFlight.g * T
        return simd_length(v) * 3.6
    }

    /// v16: a serve seen past the net but never to its bounce gets a speed from the server's baseline.
    /// Contact at the anchor depth (0.4 m inside): within 3 %; 0.7 m behind it (on the baseline's far side):
    /// the single camera cannot tell, and the speed comes out about 6 % high (v16; 8 % with v17's
    /// service-box landing prior and longer reach search).
    func testServeWithoutABounceGetsABaselineSpeed() throws {
        try baselineServe(contactY: IndependentShotFlights.ServeSpeed.inside, tolerance: 0.03)
        try baselineServe(contactY: -0.3, tolerance: 0.09)
    }

    func baselineServe(contactY: Double, tolerance: Double) throws {
        let cam = IndependentProjector(camera)
        let (all, hit, server) = serveWithToss(at: 600, contactY: contactY)
        let netFrame = try XCTUnwrap(all.first { $0.0 > hit * 60 && $0.1.y >= IndependentCourt.netY }).0
        let points = all.filter { $0.0 <= netFrame + 10 }           // lost 10 frames after the net, still in the air
        let candidates = points.enumerated().map { n, p in
            let q = cam.project(p.1); return IndependentShotCandidate(decodeIndex: n, time: p.0, u: q.u, v: q.v, peak: 0.9)
        }
        let people = IndependentPeople(Dictionary(uniqueKeysWithValues: (590...700).map { ($0, [server]) }))
        let shots = IndependentShotPipeline.run(candidates: candidates, segments: [.init(camera: camera)]) { _, _ in people }
        let serve = try XCTUnwrap(shots.first { $0.stroke == "发球" }, "\(shots.map { ($0.tHit, $0.stroke ?? "-") })")
        XCTAssertFalse(serve.bounceFound)
        XCTAssertEqual(serve.speedAnchor, .serveBaseline)
        let speed = try XCTUnwrap(serve.reportedSpeedKmh)
        XCTAssertEqual(serve.speedTo, "bounce")
        let reference = trueServeSpeed(all, depth: contactY + 0.01, toBounce: true)
        XCTAssertEqual(speed, reference, accuracy: reference * tolerance)
        XCTAssertLessThan(speed, trueServeSpeed(all, depth: contactY + 0.01), "drag: hit to bounce is slower than hit to net")
        XCTAssertEqual(IndependentShotPipeline.rows(from: [serve], streamID: UUID()).first?.speedKPH, speed)
    }

    /// v17: a toss piece followed by the serve piece is a hit at their junction even with no person box;
    /// two pieces of one vertical toss are not.
    func testTossThenServeJunction() throws {
        let cam = IndependentProjector(camera)
        let (all, hit, _) = serveWithToss(at: 600)
        let track = all.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
            let q = cam.project(p.1); return IndependentTrackPoint(t: p.0, u: q.u, v: q.v)
        }
        let toss = track.filter { $0.t < hit * 60 }, serve = track.filter { $0.t >= hit * 60 }
        XCTAssertTrue(IndependentBallEvents.tossThenServe(toss, serve))
        let half = toss.count / 2
        XCTAssertFalse(IndependentBallEvents.tossThenServe(Array(toss.prefix(half)), Array(toss.suffix(from: half))))
    }

    /// v17: the serve hypothesis refits the first 0.6 s of a flight with the contact at the server's
    /// baseline. A serve whose track runs on through junk after 0.6 s still passes; the flight of a rally
    /// shot from mid-court does not have a serve contact at the baseline.
    func testServeHypothesisUsesTheFirstHalfSecond() throws {
        let cam = IndependentProjector(camera)
        let (all, hit, server) = serveWithToss(at: 600, contactY: IndependentShotFlights.ServeSpeed.inside)
        var track = all.filter { $0.0 > hit * 60 }.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
            let q = cam.project(p.1); return IndependentTrackPoint(t: p.0, u: q.u, v: q.v)
        }
        let end = track[track.count - 1]
        for k in 1...20 { track.append(IndependentTrackPoint(t: end.t + Double(k), u: end.u + 40, v: end.v - 30)) }  // glued junk
        let job = IndependentShotFlight(points: track, tHit: hit * 60, hitter: server, bounce: nil, kind: .junction,
                                        contact: track[0].uv, incoming: nil, hitterSide: "near")
        XCTAssertGreaterThan(IndependentShotFlights.analyse(job, camera: cam).rmsPx ?? 0, 4, "the whole glued track has no clean fit")
        let r = try XCTUnwrap(IndependentShotFlights.serveHypothesis(job, near: true, camera: cam))
        XCTAssertEqual(r.crossesNet, true)
        XCTAssertTrue(IndependentStrokeRules.Serve.contactZ.contains(try XCTUnwrap(r.fitHit)[2]))

        var rally = IndependentFlight.State(p: SIMD3(0.5, 8, 1.0), v: SIMD3(0, 22, 3))
        var pts = [IndependentTrackPoint]()
        for k in 0..<36 { let q = cam.project(rally.p); pts.append(IndependentTrackPoint(t: 900 + Double(k), u: q.u, v: q.v)); rally = IndependentFlight.rk4(rally, 1 / 60) }
        let rallyJob = IndependentShotFlight(points: pts, tHit: 900, hitter: server, bounce: nil, kind: .junction,
                                             contact: pts[0].uv, incoming: nil, hitterSide: "near")
        XCTAssertNil(IndependentShotFlights.serveHypothesis(rallyJob, near: true, camera: cam))
    }

    /// v18: a toss glued to the start of a serve flight is trimmed at the contact; a serve flight without a
    /// toss, and a rally flight, are left as they are.
    func testGluedTossIsTrimmedAtTheContact() throws {
        let cam = IndependentProjector(camera)
        // a toss struck just after its apex (2.85 m), then a serve with some sideways speed
        var all = [(Double, SIMD3<Double>)](), b = SIMD3(1.25, 0.2, 1.6), vz = 4.95, k = 600.0
        while !(vz < 0 && b.z <= 2.75) { all.append((k, b)); b.z += vz / 60; vz -= IndependentFlight.g / 60; k += 1 }
        let hit = k / 60
        var s = IndependentFlight.State(p: b, v: SIMD3(-4, 36, -2.5))
        while s.p.z > IndependentCourt.ballRadius { all.append((k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        let track = all.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
            let q = cam.project(p.1); return IndependentTrackPoint(t: p.0, u: q.u, v: q.v)
        }
        let cut = IndependentShotFlights.tossTrimmed(track)
        XCTAssertLessThan(cut.count, track.count)
        XCTAssertEqual(cut[0].t, hit * 60, accuracy: 2, "contact frame \(hit * 60), cut at \(cut[0].t)")
        let serve = track.filter { $0.t >= hit * 60 }
        XCTAssertEqual(IndependentShotFlights.tossTrimmed(serve).count, serve.count)
        var rally = IndependentFlight.State(p: SIMD3(0.5, 8, 1.0), v: SIMD3(0, 22, 3))
        var pts = [IndependentTrackPoint]()
        for k in 0..<36 { let q = cam.project(rally.p); pts.append(IndependentTrackPoint(t: 900 + Double(k), u: q.u, v: q.v)); rally = IndependentFlight.rk4(rally, 1 / 60) }
        XCTAssertEqual(IndependentShotFlights.tossTrimmed(pts).count, pts.count)
    }

    /// v19: a far serve on a low camera, in the image: the toss goes straight up and down (no sideways
    /// motion) and the serve leaves it at about the same image speed, so only the departure from the toss
    /// parabola marks the contact.
    func testSlowFarServeLeavesTheTossParabola() {
        let apex = 36.0, contact = 48.0, c = 0.04
        func tossV(_ t: Double) -> Double { 502 + c * (t - apex) * (t - apex) }
        var track = [IndependentTrackPoint]()
        for f in 0..<90 {
            let t = Double(f)
            if t < contact { track.append(IndependentTrackPoint(t: 1000 + t, u: 896, v: tossV(t))) }
            else { track.append(IndependentTrackPoint(t: 1000 + t, u: 896 + 1.1 * (t - contact), v: tossV(contact) + 1.3 * (t - contact))) }
        }
        let cut = IndependentShotFlights.tossTrimmed(track)
        XCTAssertLessThan(cut.count, track.count, "the toss is trimmed")
        XCTAssertEqual(cut[0].t, 1000 + contact, accuracy: 8, "cut at \(cut[0].t), contact \(1000 + contact)")
        let toss = (0..<60).map { IndependentTrackPoint(t: 1000 + Double($0), u: 896, v: tossV(Double($0))) }
        XCTAssertEqual(IndependentShotFlights.tossTrimmed(toss).count, toss.count, "a toss alone is not cut")
    }

    /// v19: on a low camera (1.5 m) the serve's own fit trades depth for speed; the toss alone, slow and
    /// near vertical, is fitted freely and gravity's pull in the image puts it over the server's baseline.
    func testTossContactIsMeasuredFromTheToss() {
        let low = IndependentProjector(IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0.5), from: SIMD3(0.26, -6.1, 1.53), f: 1158))
        var s = IndependentFlight.State(p: SIMD3(1.25, 0.2, 1.6), v: SIMD3(0.1, 0.2, 4.95)), k = 600.0
        var toss = [IndependentTrackPoint]()
        while !(s.v.z < 0 && s.p.z <= 2.75) {
            let q = low.project(s.p); toss.append(IndependentTrackPoint(t: k, u: q.u, v: q.v))
            s = IndependentFlight.rk4(s, 1 / 60); k += 1
        }
        let c = IndependentShotFlights.tossContact(toss, at: k, near: true, camera: low)
        XCTAssertNotNil(c)
        if let c { XCTAssertLessThan(simd_length(c.P - s.p), 0.2, "measured \(c.P), true \(s.p)") }
        XCTAssertNil(IndependentShotFlights.tossContact(toss, at: k, near: false, camera: low), "not over the far baseline")
    }

    /// v19: a re-timed serve revises its own published row (same flight start), not the shot before it
    /// that happens to lie within 0.25 s.
    func testLiveRevisionKeepsTheFlightStart() {
        func shot(_ t: Double, _ first: Int) -> IndependentShotResult {
            IndependentShotResult(hitKind: "hit junction", hitterFound: true, bounceFound: false, contactUV: [0, 0], hitterBox: nil,
                                  incoming: nil, hitterSide: "near", tHit: t, nObs: 20, firstFrame: first, lastFrame: first + 40)
        }
        let published = [IndependentLiveShots.Published(shot: shot(251.97, 15128), firstPublished: 253),
                         IndependentLiveShots.Published(shot: shot(252.49, 15155), firstPublished: 255)]
        XCTAssertEqual(IndependentLiveShots.match(shot(252.12, 15155), in: published, from: 0), 1)
        XCTAssertEqual(IndependentLiveShots.match(shot(252.05, 15130), in: published, from: 0), 0, "nearest hit")
        XCTAssertNil(IndependentLiveShots.match(shot(253.0, 15200), in: published, from: 0))
    }

    /// 2026-11-06: of two serve-like flights from opposite ends, the one with a fitted landing wins, even when
    /// the other one fits faster (double-test-003 462.27: the receiver's false serve beat the real one).
    func testTheServeLikeFlightWithALandingWinsOverAFasterOne() {
        func serve(_ t: Double, _ side: String, _ speed: Double, bounce: Bool) -> IndependentShotResult {
            var s = IndependentShotResult(hitKind: "first observation", hitterFound: true, bounceFound: bounce, contactUV: [0, 0],
                                          hitterBox: nil, incoming: nil, hitterSide: side, tHit: t, nObs: 33, firstFrame: 0, lastFrame: 60)
            s.serveFit = true; s.fromToss = true; s.serveRise = 0; s.speedKmh = speed; s.accepted = true; s.crossesNet = true
            return s
        }
        let fast = serve(461.97, "near", 80.2, bounce: false)
        let real = serve(462.23, "far", 64.8, bounce: true)
        XCTAssertEqual(IndependentStrokeRules.serves([fast, real], priorRally: []), [1], "the landing decides")
        let return_ = serve(461.97, "near", 80.2, bounce: true)
        XCTAssertEqual(IndependentStrokeRules.serves([return_, serve(462.23, "far", 64.8, bounce: true)], priorRally: []), [0],
                       "with a landing on both sides the faster fit still wins")
    }

    /// 2026-11-06: a shorter recomputation without a bounce must not erase the row that already had one
    /// (a same-frame fragment published over it, test.MOV 264.02).
    func testShorterBounceLessRecomputationKeepsABouncedRow() {
        func shot(_ n: Int, bounce: Bool) -> IndependentShotResult {
            IndependentShotResult(hitKind: "hit junction", hitterFound: true, bounceFound: bounce, contactUV: [0, 0], hitterBox: nil,
                                  incoming: nil, hitterSide: "near", tHit: 264.02, nObs: n, firstFrame: 15841, lastFrame: 15881)
        }
        XCTAssertFalse(IndependentLiveShots.replaces(shot(40, bounce: true), with: shot(8, bounce: false)))
        XCTAssertTrue(IndependentLiveShots.replaces(shot(40, bounce: true), with: shot(60, bounce: false)), "a longer recomputation may revise it")
        XCTAssertTrue(IndependentLiveShots.replaces(shot(40, bounce: true), with: shot(8, bounce: true)))
        XCTAssertTrue(IndependentLiveShots.replaces(shot(40, bounce: false), with: shot(8, bounce: false)))
    }

    /// v18: a serve into the net. The track runs on as the ball drops down the net, so no single flight
    /// fits it; the tracker's "bounce" lies at the foot of the net. The refit ends the flight on the net
    /// plane and gives the hit-to-net speed.
    func testServeIntoTheNetIsTimedAtTheNet() throws {
        let cam = IndependentProjector(camera)
        let depth = IndependentShotFlights.ServeSpeed.inside
        var s = IndependentFlight.State(p: SIMD3(1.0, depth - 0.05, 2.6), v: SIMD3(-1.0, 30, -3.4))
        var serve = [(Double, SIMD3<Double>)](), k = 600.0
        while s.p.y < IndependentCourt.netY { serve.append((k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        let netZ = serve[serve.count - 1].1.z
        XCTAssertTrue((0.3...0.9).contains(netZ), "the serve meets the net at \(netZ) m")
        var drop = IndependentFlight.State(p: SIMD3(s.p.x, IndependentCourt.netY - 0.05, netZ), v: SIMD3(0, -0.5, 0))
        var all = serve
        while drop.p.z > IndependentCourt.ballRadius { all.append((k, drop.p)); drop = IndependentFlight.rk4(drop, 1 / 60); k += 1 }
        let tBounce = k / 60, ground = SIMD3(drop.p.x, IndependentCourt.netY - 0.3, IndependentCourt.ballRadius)
        for _ in 0..<6 { all.append((k, SIMD3(drop.p.x, drop.p.y, IndependentCourt.ballRadius))); k += 1 }
        let track = all.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
            let q = cam.project(p.1); return IndependentTrackPoint(t: p.0, u: q.u, v: q.v)
        }
        let (_, _, server) = serveWithToss(at: 600)
        let job = IndependentShotFlight(points: track, tHit: 600, hitter: server, bounce: (tBounce, ground), kind: .junction,
                                        contact: track[0].uv, incoming: nil, hitterSide: "near")
        XCTAssertFalse(IndependentShotFlights.analyse(job, camera: cam).accepted, "no single flight explains the track")
        let r = try XCTUnwrap(IndependentShotFlights.serveNetRefit(job, near: true, camera: cam))
        XCTAssertEqual(r.speedAnchor, .serveNet)
        XCTAssertNotNil(r.reportedSpeedKmh)
        let truth = trueServeSpeed(serve + [(serve[serve.count - 1].0 + 1, s.p)], depth: depth)
        XCTAssertEqual(try XCTUnwrap(r.speedKmh), truth, accuracy: truth * 0.08)
        // v24: the speed reported for a net serve runs to the measured net contact (the refit's anchor):
        // `landSpeedKmh` when the fitted flight crosses the net line first, else the anchor is the end already
        XCTAssertEqual(try XCTUnwrap(r.landSpeedKmh ?? r.speedKmh), truth, accuracy: truth * 0.08)
    }

    /// v24: a serve into the net that the tracker did not split: no "bounce" at all, the track runs from
    /// the contact through the drop at the net and the ball's bounce at its foot. The drop is found in the
    /// track and stands in for the bounce; a serve that clears the net has no such drop.
    func testUnsplitServeIntoTheNetIsFoundFromTheDrop() throws {
        let cam = IndependentProjector(camera)
        let depth = IndependentShotFlights.ServeSpeed.inside
        var s = IndependentFlight.State(p: SIMD3(1.0, depth - 0.05, 2.6), v: SIMD3(-1.0, 30, -3.4))
        var serve = [(Double, SIMD3<Double>)](), k = 600.0
        while s.p.y < IndependentCourt.netY { serve.append((k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        let netZ = serve[serve.count - 1].1.z
        var drop = IndependentFlight.State(p: SIMD3(s.p.x, IndependentCourt.netY - 0.05, netZ), v: SIMD3(0, -0.5, 0))
        var all = serve
        while drop.p.z > IndependentCourt.ballRadius { all.append((k, drop.p)); drop = IndependentFlight.rk4(drop, 1 / 60); k += 1 }
        drop.v = SIMD3(0, -0.5, 1.5)    // the bounce at the foot of the net
        for _ in 0..<12 { drop = IndependentFlight.rk4(drop, 1 / 60); all.append((k, drop.p)); k += 1 }
        let track = all.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
            let q = cam.project(p.1); return IndependentTrackPoint(t: p.0, u: q.u, v: q.v)
        }
        let (_, _, server) = serveWithToss(at: 600)
        let job = IndependentShotFlight(points: track, tHit: 600, hitter: server, bounce: nil, kind: .junction,
                                        contact: track[0].uv, incoming: nil, hitterSide: "near")
        let d = try XCTUnwrap(IndependentShotFlights.netDrop(track, near: true, camera: cam))
        XCTAssertLessThan(abs(d.ground.y - IndependentCourt.netY), IndependentShotFlights.ServeSpeed.netBounceY)
        let nj = try XCTUnwrap(IndependentShotFlights.netJob(job, near: true, camera: cam))
        let r = try XCTUnwrap(IndependentShotFlights.serveNetHypothesis(nj, near: true, camera: cam))
        XCTAssertEqual(r.speedAnchor, .serveNet)
        XCTAssertEqual(r.crossesNet, true, "recognised as a flight to the net")
        let truth = trueServeSpeed(serve + [(serve[serve.count - 1].0 + 1, s.p)], depth: depth)
        XCTAssertEqual(try XCTUnwrap(r.landSpeedKmh ?? r.speedKmh), truth, accuracy: truth * 0.08)
        // a serve that clears the net and bounces in the service box: no drop at the net
        var over = IndependentFlight.State(p: SIMD3(1.0, depth, 2.6), v: SIMD3(-1.0, 30, -2.2)), clear = [IndependentTrackPoint](), f = 600.0
        while over.p.z > IndependentCourt.ballRadius { let q = cam.project(over.p); clear.append(IndependentTrackPoint(t: f, u: q.u, v: q.v)); over = IndependentFlight.rk4(over, 1 / 60); f += 1 }
        over.v.z = -over.v.z * 0.6
        for _ in 0..<12 { over = IndependentFlight.rk4(over, 1 / 60); let q = cam.project(over.p); clear.append(IndependentTrackPoint(t: f, u: q.u, v: q.v)); f += 1 }
        XCTAssertNil(IndependentShotFlights.netDrop(clear, near: true, camera: cam))
    }

    /// v20: a serve with a bounce whose own fit is rejected for a 4-6 px residual (a noisy track) gets its
    /// speed from the bounce refit: anchored at the contact and at the bounce, the speed hardly depends on
    /// the fit's detail.
    func testNoisyServeGetsTheBounceRefitSpeed() throws {
        let cam = IndependentProjector(camera)
        let depth = IndependentShotFlights.ServeSpeed.inside
        var s = IndependentFlight.State(p: SIMD3(1.0, depth, 2.6), v: SIMD3(-1.0, 30, -2.2))
        var serve = [(Double, SIMD3<Double>)](), k = 600.0
        while s.p.z > IndependentCourt.ballRadius { serve.append((k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        let ground = SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius)
        XCTAssertTrue((IndependentCourt.netY...(IndependentCourt.netY + 6.4)).contains(ground.y), "lands in the service box at \(ground.y)")
        let track = serve.enumerated().map { (i: Int, p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
            let q = cam.project(p.1); return IndependentTrackPoint(t: p.0, u: q.u, v: q.v + (i % 2 == 0 ? 5.2 : -5.2))
        }
        let (_, _, server) = serveWithToss(at: 600)
        let job = IndependentShotFlight(points: track, tHit: 600, hitter: server, bounce: (k / 60, ground), kind: .junction,
                                        contact: track[0].uv, incoming: nil, hitterSide: "near")
        let own = IndependentShotFlights.analyse(job, camera: cam)
        XCTAssertFalse(own.accepted, "own fit RMS \(own.rmsPx ?? -1)")
        let r = try XCTUnwrap(IndependentShotFlights.serveBounceRefit(job, near: true, camera: cam))
        let truth = trueServeSpeed(serve, depth: depth + 0.01)
        XCTAssertEqual(try XCTUnwrap(r.speedKmh), truth, accuracy: truth * 0.08)
    }

    /// v21: a far serve whose toss piece runs on past the flight's first point (two tracks overlap for a few
    /// frames): the chain start records the ball's last earlier sighting next to its first point.
    func testChainStartRecordsTheBallSeenJustBefore() {
        let low = IndependentProjector(IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0.5), from: SIMD3(0.26, -6.1, 1.53), f: 1158))
        var s = IndependentFlight.State(p: SIMD3(0.3, 23.9, 1.6), v: SIMD3(0, 0, 5.4)), k = 560.0
        var toss = [IndependentTrackPoint]()      // only the falling half: the rising half was a piece of its own
        while !(s.v.z < 0 && s.p.z <= 2.6) {
            if s.v.z < 0 { let q = low.project(s.p); toss.append(IndependentTrackPoint(t: k, u: q.u, v: q.v)) }
            s = IndependentFlight.rk4(s, 1 / 60); k += 1
        }
        let contactFrame = k
        // the toss track runs on for two frames past the contact (a racket or hand candidate)
        for j in 0..<3 { let q = low.project(s.p - SIMD3(0, 0, 0.05 * Double(j))); toss.append(IndependentTrackPoint(t: k + Double(j), u: q.u, v: q.v + 8)) }
        var f = IndependentFlight.State(p: s.p, v: SIMD3(-0.4, -24, -2.0)), serve = [IndependentTrackPoint]()
        k = contactFrame + 1; f = IndependentFlight.rk4(f, 1 / 60)
        while f.p.y > 15 { let q = low.project(f.p); serve.append(IndependentTrackPoint(t: k, u: q.u, v: q.v)); f = IndependentFlight.rk4(f, 1 / 60); k += 1 }
        let flights = IndependentShotFlights.flights(pieces: [toss, serve], junctions: [], people: IndependentPeople([:]), camera: low)
        let flight = flights.first { $0.points.first?.t == serve[0].t }
        XCTAssertNotNil(flight)
        XCTAssertEqual(flight?.kind, .firstObservation)
        XCTAssertEqual(flight?.seenBefore, contactFrame, "the toss's last point before the flight starts")
    }

    /// v21: a serve speed refit does not put the contact before the ball was last seen: a far serve first
    /// observed mid-flight is extrapolated back to the server's baseline only when nothing saw the ball later.
    func testServeSpeedRefitKeepsTheContactAfterTheLastSighting() {
        let low = IndependentProjector(IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0.5), from: SIMD3(0.26, -6.1, 1.53), f: 1158))
        let depth = IndependentCourt.length - IndependentShotFlights.ServeSpeed.inside
        var s = IndependentFlight.State(p: SIMD3(0.4, depth, 2.5), v: SIMD3(-0.6, -27, -2.6)), k = 600.0
        var track = [IndependentTrackPoint]()
        while s.p.z > IndependentCourt.ballRadius {
            if k >= 612 { let q = low.project(s.p); track.append(IndependentTrackPoint(t: k, u: q.u, v: q.v)) }
            s = IndependentFlight.rk4(s, 1 / 60); k += 1
        }
        var job = IndependentShotFlight(points: track, tHit: 612, hitter: nil, bounce: (k / 60, SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius)),
                                        kind: .firstObservation, contact: track[0].uv, incoming: nil, hitterSide: "far")
        job.serveDepth = depth
        let free = IndependentShotFlights.analyse(job, camera: low)
        XCTAssertEqual(free.tHit, 10.0, accuracy: 0.1, "unbounded: back to the baseline")
        job.seenBefore = 610; job.contactBounded = true
        let bounded = IndependentShotFlights.analyse(job, camera: low)
        XCTAssertGreaterThanOrEqual(bounded.tHit, 610 / 60.0 - 1e-9, "bounded: not before the last sighting")
        job.contactBounded = false
        XCTAssertEqual(IndependentShotFlights.analyse(job, camera: low).tHit, free.tHit, "recognition refits stay free")
    }

    /// v26: a hit junction whose incoming piece is the toss bounds the speed refit's contact too: the ball
    /// fell over the server until the toss's last point. Any other incoming piece, and recognition, stay free.
    func testServeSpeedRefitKeepsTheContactAfterAJunctionToss() {
        let low = IndependentProjector(IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0.5), from: SIMD3(0.26, -6.1, 1.53), f: 1158))
        let depth = IndependentCourt.length - IndependentShotFlights.ServeSpeed.inside
        var s = IndependentFlight.State(p: SIMD3(0.4, depth, 2.5), v: SIMD3(-0.6, -27, -2.6)), k = 600.0
        var track = [IndependentTrackPoint]()
        while s.p.z > IndependentCourt.ballRadius {
            if k >= 612 { let q = low.project(s.p); track.append(IndependentTrackPoint(t: k, u: q.u, v: q.v)) }
            s = IndependentFlight.rk4(s, 1 / 60); k += 1
        }
        var b = IndependentFlight.State(p: SIMD3(0.4, depth + 0.3, 1.9), v: SIMD3(0, 0, 3.6)), tossK = 575.0
        var toss = [IndependentTrackPoint]()      // up and down over the server, last seen at frame 610
        while tossK <= 610 { let q = low.project(b.p); toss.append(IndependentTrackPoint(t: tossK, u: q.u, v: q.v)); b = IndependentFlight.rk4(b, 1 / 60); tossK += 1 }
        XCTAssertTrue(IndependentShotFlights.isToss(toss))
        let sideways = toss.map { IndependentTrackPoint(t: $0.t, u: $0.u - 6 * ($0.t - 575), v: $0.v) }    // a rally ball, not a toss
        XCTAssertFalse(IndependentShotFlights.isToss(sideways))
        func job(_ incoming: [IndependentTrackPoint]?, bounded: Bool) -> IndependentShotFlight {
            var j = IndependentShotFlight(points: track, tHit: 612, hitter: nil, bounce: (k / 60, SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius)),
                                          kind: .junction, contact: track[0].uv, incoming: incoming, hitterSide: "far")
            j.serveDepth = depth; j.contactBounded = bounded
            return j
        }
        let free = IndependentShotFlights.analyse(job(nil, bounded: true), camera: low)
        XCTAssertEqual(free.tHit, 10.0, accuracy: 0.1, "no toss: back to the baseline")
        XCTAssertGreaterThanOrEqual(IndependentShotFlights.analyse(job(toss, bounded: true), camera: low).tHit, 610 / 60.0 - 1e-9,
                                    "not before the toss's last point")
        XCTAssertEqual(IndependentShotFlights.analyse(job(sideways, bounded: true), camera: low).tHit, free.tHit, accuracy: 1e-9)
        XCTAssertEqual(IndependentShotFlights.analyse(job(toss, bounded: false), camera: low).tHit, free.tHit, accuracy: 1e-9,
                       "recognition refits stay free")
    }

    /// v17: a serve speed refit lands in the receiver's service box.
    func testServeSpeedRefitLandsInTheServiceBox() throws {
        let cam = IndependentProjector(camera)
        let (all, hit, server) = serveWithToss(at: 600, contactY: IndependentShotFlights.ServeSpeed.inside)
        let netFrame = try XCTUnwrap(all.first { $0.0 > hit * 60 && $0.1.y >= IndependentCourt.netY }).0
        let track = all.filter { $0.0 > hit * 60 && $0.0 <= netFrame + 10 }.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
            let q = cam.project(p.1); return IndependentTrackPoint(t: p.0, u: q.u, v: q.v)
        }
        let job = IndependentShotFlight(points: track, tHit: hit * 60, hitter: server, bounce: nil, kind: .junction,
                                        contact: track[0].uv, incoming: nil, hitterSide: "near")
        let r = try XCTUnwrap(IndependentShotFlights.serveSpeed(job, near: true, camera: cam))
        let y = try XCTUnwrap(r.landing)[1]
        let box = IndependentCourtModel.serviceFromNet + IndependentShotFlights.ServeSpeed.landingMargin
        XCTAssertTrue((IndependentCourt.netY - 0.5)...(IndependentCourt.netY + box) ~= y, "landing y \(y)")
    }

    /// 2026-11-06: the landing gate used by `junctions` tells a bounce (falling into the kink, rising out
    /// of it) from a straight continuation. The link choice itself is measured on the dev and held-out videos.
    func testVerifiedLandingTellsABounceFromAContinuation() throws {
        let cam = IndependentProjector(camera)
        // a far hit toward the near court: the ball falls to a bounce near y = 5 m and rises after it
        var s = IndependentFlight.State(p: SIMD3(-1.0, 22.0, 1.6), v: SIMD3(0.8, -24.0, -1.5))
        var falling = [(Double, SIMD3<Double>)]()
        var n = 600.0
        while s.p.z > IndependentCourt.ballRadius && n < 700 { falling.append((n, s.p)); s = IndependentFlight.rk4(s, 1 / 60); n += 1 }
        let landing = falling.removeLast()
        var after = IndependentFlight.State(p: SIMD3(landing.1.x, landing.1.y, IndependentCourt.ballRadius),
                                            v: SIMD3(s.v.x * 0.8, s.v.y * 0.75, -s.v.z * 1.5))
        var rising = [(Double, SIMD3<Double>)]()
        for _ in 0..<26 { rising.append((n, after.p)); after = IndependentFlight.rk4(after, 1 / 60); n += 1 }
        func points(_ xs: [(Double, SIMD3<Double>)]) -> [IndependentTrackPoint] {
            xs.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
                let q = cam.project(p.1)
                return IndependentTrackPoint(t: p.0, u: (q.u / 4).rounded() * 4, v: (q.v / 4).rounded() * 4)
            }
        }
        let A = points(falling)
        let B = points(Array(rising.dropFirst(6)))
        let e0 = A[A.count - 2], e1 = A[A.count - 1]
        let du = e1.u - e0.u, dv = e1.v - e0.v
        let C = (1...5).map { (k: Int) -> IndependentTrackPoint in
            let f = Double(k) / 4
            return IndependentTrackPoint(t: e1.t + Double(k), u: e1.u + du * f, v: e1.v + dv * f)
        }
        let pcs = [A, C, B]
        let bounce = try XCTUnwrap(IndependentBallEvents.junctions([A, B]).first)
        XCTAssertEqual(bounce.a, 0)
        XCTAssertEqual(bounce.b, 1)
        XCTAssertTrue(IndependentBallEvents.verifiedLanding(pcs, 0, 2, t: bounce.t, uv: SIMD2(bounce.u, bounce.v), camera: cam),
                      "falling into the landing and rising out of it is a bounce")
        let straight = try XCTUnwrap(IndependentBallEvents.junctions([A, C]).first)
        XCTAssertEqual(straight.b, 1)
        XCTAssertFalse(IndependentBallEvents.verifiedLanding(pcs, 0, 1, t: straight.t, uv: SIMD2(straight.u, straight.v), camera: cam),
                       "a straight continuation is not a landing")
    }

    /// v32 (night videos): a ball rolling at the net, or one hit from the next court, is no rally evidence; a pose
    /// serve takes the flight first seen at the contact although a glued toss reached its hit back further.
    func testServeRulesV32() {
        func flight(_ t: Double, side: String = "far", n: Int = 40) -> IndependentShotResult {
            var s = IndependentShotResult(hitKind: "first observation", hitterFound: true, bounceFound: false, contactUV: [0, 0],
                                          hitterBox: nil, incoming: nil, hitterSide: side, tHit: t, nObs: n, firstFrame: Int(t * 60),
                                          lastFrame: Int(t * 60) + 2 * n)
            s.crossesNet = true; s.accepted = true; s.fitHit = [0, 20, 1.0]; s.rmsPx = 1.5; s.imageStep = 9
            return s
        }
        XCTAssertTrue(IndependentStrokeRules.isRallyFlight(flight(8.6)))
        var rolling = flight(8.6); rolling.imageStep = 0.6
        XCTAssertFalse(IndependentStrokeRules.isRallyFlight(rolling), "a ball rolling at the net")
        var nextCourt = flight(8.6); nextCourt.fitHit = [-13.7, 20, 1.0]
        XCTAssertFalse(IndependentStrokeRules.isRallyFlight(nextCourt), "hit 13.7 m off the centre line")
        // the arm's contact at 10.7 s; the serve's hit was reached back to 9.9 s by a glued toss, its ball first seen at 10.75 s
        let event = IndependentStrokeRules.PoseServeEvent(start: 10.2, end: 10.6, peak: 1.4, samples: 3)
        var served = flight(9.9, side: "near", n: 33); served.firstFrame = Int(10.75 * 60)
        XCTAssertEqual(IndependentStrokeRules.poseServeShot(event, contact: 10.7, shots: [served], segment: 0), 0)
        served.firstFrame = Int(9.9 * 60)
        XCTAssertNil(IndependentStrokeRules.poseServeShot(event, contact: 10.7, shots: [served], segment: 0), "first seen 0.8 s before the contact")
    }

    /// v31: a far serve landing in the near service box, seen for only five points after it. A flight rising from
    /// the landing, on toward the near baseline, explains the tail, and the junction is a bounce; the falling ball
    /// carried straight on is none. (On clean points the usual fits find this bounce as well; the short-tail test
    /// is for real tails, whose fit often settles on falling.)
    func testShortTailAfterANearLanding() throws {
        let cam = IndependentProjector(camera)
        var s = IndependentFlight.State(p: SIMD3(-1.0, 22.0, 2.7), v: SIMD3(0.5, -30.0, -3.0))
        var falling = [(Double, SIMD3<Double>)]()
        var t = 600.0
        while IndependentFlight.rk4(s, 1 / 60).p.z > IndependentCourt.ballRadius {
            falling.append((t, s.p)); s = IndependentFlight.rk4(s, 1 / 60); t += 1
        }
        // `s` is the frame the ball lands on (8.1 m from the near baseline); that frame is not seen
        let ground = SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius)
        func flight(from start: IndependentFlight.State) -> [IndependentTrackPoint] {
            var q = start
            return (1...5).map { (k: Int) -> IndependentTrackPoint in
                q = IndependentFlight.rk4(q, 1 / 60)
                let uv = cam.project(q.p)
                return IndependentTrackPoint(t: t + Double(k), u: uv.u, v: uv.v)
            }
        }
        let A = falling.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
            let uv = cam.project(p.1)
            return IndependentTrackPoint(t: p.0, u: uv.u, v: uv.v)
        }
        let B = flight(from: .init(p: ground, v: SIMD3(s.v.x * 0.8, s.v.y * 0.75, -s.v.z * 0.6)))
        XCTAssertLessThan(IndependentFlight.risingAnchoredRMS(cam, frames: B.map(\.t), uv: B.map(\.uv), anchor: ground, at: t, along: -1), 2)
        var link = try XCTUnwrap(IndependentBallEvents.junctions([A, B]).first)
        IndependentBallEvents.testBounce(&link, pieces: [A, B], camera: cam)
        XCTAssertTrue(link.bounce)
        let straight = flight(from: s)
        var none = try XCTUnwrap(IndependentBallEvents.junctions([A, straight]).first)
        IndependentBallEvents.testBounce(&none, pieces: [A, straight], camera: cam)
        XCTAssertFalse(none.bounce)
    }

    /// v31: two flights starting together with as many points: the one that lands is kept.
    func testDuplicateFlightsKeepTheOneThatLands() {
        func flight(_ t: Double, bounce: Bool) -> IndependentShotResult {
            var r = IndependentShotResult(hitKind: "first observation", hitterFound: false, bounceFound: bounce, contactUV: [0, 0], hitterBox: nil,
                                          incoming: nil, hitterSide: "far", tHit: t, nObs: 25, firstFrame: Int(t * 60), lastFrame: Int(t * 60) + 24)
            if bounce { r.bounceGround = [1, 4, 0] }
            return r
        }
        let kept = IndependentShotFlights.deduplicate([flight(10.0, bounce: false), flight(10.0, bounce: true)])
        XCTAssertEqual(kept.count, 1)
        XCTAssertNotNil(kept[0].bounceGround)
        XCTAssertNil(IndependentShotFlights.deduplicate([flight(10.0, bounce: false), flight(10.1, bounce: false)])[0].bounceGround)
    }

    /// v33: a far ball landing on the near half whose bounce stayed in its last two points (no junction): the step
    /// across the bounce nearly stops in the image, and the near line call takes that landing with at least the
    /// 1 m sigma floor. Without such a knee the fit brought down a frame or two past the end is taken, when low and
    /// accepted. Not for a near hit right then (a volley), a fit still high, a flight ending at a hit, or at the net.
    func testIncomingLandingV33() throws {
        let cam = IndependentProjector(camera)
        var s = IndependentFlight.State(p: SIMD3(1.0, 23.0, 1.0), v: SIMD3(-0.5, -24.0, 3.5))
        var t = 600.0, falling = [IndependentTrackPoint]()
        while true {   // every frame down to the last one above the ground
            let uv = cam.project(s.p); falling.append(IndependentTrackPoint(t: t, u: uv.u, v: uv.v))
            let next = IndependentFlight.rk4(s, 1 / 60)
            if next.p.z <= IndependentCourt.ballRadius { break }
            s = next; t += 1
        }
        XCTAssertNil(IndependentShotFlights.tailKnee(frames: falling.map(\.t), uv: falling.map(\.uv)), "still coming down")
        var up = IndependentFlight.State(p: SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius), v: SIMD3(s.v.x * 0.8, s.v.y * 0.75, -s.v.z * 0.6))
        var tail = falling
        for k in 1...2 {
            up = IndependentFlight.rk4(up, 1 / 60)
            let uv = cam.project(up.p); tail.append(IndependentTrackPoint(t: t + Double(k), u: uv.u, v: uv.v))
        }
        let j = try XCTUnwrap(IndependentShotFlights.tailKnee(frames: tail.map(\.t), uv: tail.map(\.uv)), "two points after the bounce")
        let m = (tail[j].uv + tail[j + 1].uv) / 2, g = cam.onPlaneZ(m.x, m.y, z: IndependentCourt.ballRadius)
        XCTAssertLessThan(simd_length(SIMD2(g.x - s.p.x, g.y - s.p.y)), 0.5, "the slow step's middle is at the landing")

        func incoming(knee: [Double]?, zLast: Double = 0.2, y: Double = 4, endsAtHit: Bool = false) -> IndependentShotResult {
            var r = IndependentShotResult(hitKind: "first observation", hitterFound: true, bounceFound: false, contactUV: [0, 0], hitterBox: nil,
                                          incoming: nil, hitterSide: "far", tHit: 10, nObs: 40, firstFrame: 600, lastFrame: 690)
            r.fitHit = [0, 23, 1]
            // Live descents always carry `last`; keep it here so `endsAtHit` is refused by both the fit path and v35.
            r.descent = .init(t: 11.52, x: 1, y: y, vx: 0, vy: -15, ahead: 1, zLast: zLast, u: 900, v: 800, px: 20, tLast: 11.5,
                              accepted: true, rms: 2, hitY: 23, endsAtHit: endsAtHit, knee: knee, last: [900, 820])
            return r
        }
        func landing(_ shots: [IndependentShotResult]) -> IndependentShotResult.LandEstimate? {
            IndependentShotPipeline.incomingLanding(0, shots: shots, camera: cam)
        }
        let knee = try XCTUnwrap(landing([incoming(knee: [11.51, 1.2, 3.5])]))
        XCTAssertTrue(knee.knee)
        XCTAssertEqual(knee.y, 3.5)
        XCTAssertGreaterThanOrEqual(knee.sigma.min() ?? 0, IndependentIncomingLanding.sigmaFloor)
        var volley = incoming(knee: nil); volley.hitterSide = "near"; volley.tHit = 11.55
        XCTAssertNil(landing([incoming(knee: [11.51, 1.2, 3.5]), volley]), "the near player hit it then")
        XCTAssertNil(landing([incoming(knee: [11.51, 1.2, 3.5], zLast: 1.2)]), "the fit still high at the end")
        let fit = try XCTUnwrap(landing([incoming(knee: nil)]))
        XCTAssertFalse(fit.knee)
        XCTAssertGreaterThan(fit.sigma[1], knee.sigma[1], "a landing brought down is less certain")
        XCTAssertNil(landing([incoming(knee: nil, zLast: 0.5)]))
        XCTAssertNil(landing([incoming(knee: nil, endsAtHit: true)]))
        XCTAssertNil(landing([incoming(knee: nil, y: 11)]), "at the net")

        var shot = incoming(knee: nil); shot.landEstimate = fit
        let row = try XCTUnwrap(IndependentShotPipeline.rows(from: [shot], streamID: UUID(), all: true).first)
        XCTAssertEqual(row.bounce?.reasonCode, .estimate)
        XCTAssertEqual(row.bounce?.sigmaYMeters, fit.sigma[1])
        XCTAssertEqual(row.speedReasonCode, .speedUnreliable, "the row shows a landing")
        var shorter = incoming(knee: nil); shorter.nObs = 20
        XCTAssertFalse(IndependentLiveShots.replaces(shot, with: shorter), "a shorter recomputation without it keeps the landing")
    }

    /// v35: an incoming flight followed down to the ground and lost there: its fit is still a little high at the
    /// last observation and comes down well past it, so the landing is that observation on the ground, with a sigma
    /// of its own (no 1 m floor). Not when the fit is still high there (the ball in the air), not at a near volley,
    /// and not past the net.
    func testIncomingLandingAtTheLastObservation() throws {
        let cam = IndependentProjector(camera)
        func incoming(lastAt ground: SIMD2<Double>, zLast: Double = 0.3) -> IndependentShotResult {
            var r = IndependentShotResult(hitKind: "first observation", hitterFound: true, bounceFound: false, contactUV: [0, 0], hitterBox: nil,
                                          incoming: nil, hitterSide: "far", tHit: 10, nObs: 40, firstFrame: 600, lastFrame: 690)
            r.fitHit = [0, 23, 1]
            let q = cam.project(SIMD3(ground.x, ground.y, IndependentCourt.ballRadius))
            r.descent = .init(t: 11.56, x: ground.x, y: ground.y - 1.5, vx: 0, vy: -15, ahead: 3.5, zLast: zLast, u: q.u, v: q.v + 120,
                              px: 120, tLast: 11.5, accepted: true, rms: 2, hitY: 23)
            r.descent?.last = [q.u, q.v]
            return r
        }
        func landing(_ shots: [IndependentShotResult]) -> IndependentShotResult.LandEstimate? {
            IndependentShotPipeline.incomingLanding(0, shots: shots, camera: cam)
        }
        let l = try XCTUnwrap(landing([incoming(lastAt: SIMD2(1.0, 3.0))]), "the fit comes down 120 px past the end")
        XCTAssertEqual(l.x, 1.0, accuracy: 1e-6); XCTAssertEqual(l.y, 3.0, accuracy: 1e-6); XCTAssertEqual(l.t, 11.5)
        XCTAssertTrue(l.knee)
        XCTAssertGreaterThanOrEqual(l.sigma.min() ?? 0, IndependentIncomingLanding.lastLandSigmaFloor)
        XCTAssertLessThan(l.sigma[1], IndependentIncomingLanding.sigmaFloor, "its own sigma, not the brought-down floor")
        XCTAssertNil(landing([incoming(lastAt: SIMD2(1.0, 3.0), zLast: 0.7)]), "the ball still in the air there")
        var struck = incoming(lastAt: SIMD2(1.0, 3.0)); struck.descent?.endsAtHit = true
        XCTAssertNil(landing([struck]), "the chain ended at a hit, not a bounce")
        var volley = incoming(lastAt: SIMD2(1.0, 3.0)); volley.hitterSide = "near"; volley.tHit = 11.55
        XCTAssertNil(landing([incoming(lastAt: SIMD2(1.0, 3.0)), volley]), "the near player hit it then")
        XCTAssertNil(landing([incoming(lastAt: SIMD2(1.0, 12.5))]), "past the net")
        XCTAssertNil(landing([incoming(lastAt: SIMD2(1.0, 11.0))]), "at the net")
    }

    /// v34: a bounce whose fitted contact is no place to stand (a serve fitted 88 m away) takes the flight's
    /// fitted landing velocity for the half-frame term, not the 66 m/s chord; a plausible contact keeps the chord,
    /// and a fitted landing far from the bounce is not used.
    func testBounceSigmaSkipsTheChordOfAnImplausibleContact() throws {
        let cam = IndependentProjector(camera)
        func bounce(hit: [Double], landingAt t: Double = 11.0) -> IndependentShotResult {
            var r = IndependentShotResult(hitKind: "first observation", hitterFound: true, bounceFound: true, contactUV: [0, 0], hitterBox: nil,
                                          incoming: nil, hitterSide: "far", tHit: 10, nObs: 40, firstFrame: 600, lastFrame: 660)
            r.bounceGround = [1, 5, IndependentCourt.ballRadius]; r.tBounce = 11; r.fitHit = hit
            r.descent = .init(t: t, x: 1, y: 5, vx: 0, vy: -20, ahead: 0, zLast: 0.1, u: 900, v: 800, px: 2, tLast: 11)
            return r
        }
        func sigmaY(_ s: IndependentShotResult) throws -> Double { try XCTUnwrap(IndependentShotPipeline.bounceSigma(s, camera: cam))[1] }
        let pixelOnly = try XCTUnwrap(IndependentShotPipeline.pixelVariance(x: 1, y: 5, camera: cam)).yy
        func expected(vy: Double) -> Double { (pixelOnly + pow(vy * 0.5 / IndependentShotFlights.fps, 2)).squareRoot() }
        XCTAssertEqual(try sigmaY(bounce(hit: [1, 23, 2.5])), expected(vy: -18), accuracy: 1e-9, "a plausible contact: the chord")
        XCTAssertEqual(try sigmaY(bounce(hit: [-6, 88, 1.8])), expected(vy: -20), accuracy: 1e-9, "the fitted landing velocity")
        XCTAssertEqual(try sigmaY(bounce(hit: [-6, 88, 1.8], landingAt: 11.3)), expected(vy: -83), accuracy: 1e-9,
                       "a fitted landing 0.3 s away is another landing: the chord stays")
    }

    /// v16: a serve whose bounce stayed inside one tracked piece: the bounce is found in the service box and
    /// anchors the speed. A short serve flight without a bounce gets no speed.
    func testServeRefitFindsABounceInsideTheTrackAndSkipsShortFlights() throws {
        let cam = IndependentProjector(camera)
        let (all, hit, server) = serveWithToss(at: 600)
        let after = all.filter { $0.0 > hit * 60 }
        func job(_ pts: [(Double, SIMD3<Double>)]) -> IndependentShotFlight {
            let track = pts.map { (p: (Double, SIMD3<Double>)) -> IndependentTrackPoint in
                let q = cam.project(p.1); return IndependentTrackPoint(t: p.0, u: q.u, v: q.v)
            }
            return IndependentShotFlight(points: track, tHit: hit * 60, hitter: server, bounce: nil, kind: .junction,
                                         contact: track[0].uv, incoming: nil, hitterSide: "near")
        }
        let r = try XCTUnwrap(IndependentShotFlights.serveSpeed(job(after), near: true, camera: cam))
        XCTAssertEqual(r.speedAnchor, .serveBounce)
        let landing = try XCTUnwrap(after.first { $0.1.z <= IndependentCourt.ballRadius + 1e-9 }).1
        let ground = try XCTUnwrap(r.bounceGround)
        let miss: SIMD2<Double> = SIMD2<Double>(ground[0] - landing.x, ground[1] - landing.y)
        XCTAssertLessThan(simd_length(miss), 0.6)
        let reference = trueServeSpeed(after, depth: IndependentShotFlights.ServeSpeed.inside)
        XCTAssertEqual(try XCTUnwrap(r.speedKmh), reference, accuracy: reference * 0.05)

        XCTAssertNil(IndependentShotFlights.serveSpeed(job(Array(after.prefix(18))), near: true, camera: cam),
                     "18 observations ending before the net: no speed")
    }

    /// Ball positions of a far server's toss and serve (to the near court, then the bounce), on a 4 px grid
    /// like the ball model's heatmap peaks, and the server's box stopping at the head.
    func farServeWithToss(at t0: Double, vx: Double = 5, x0: Double = -1.0) -> (candidates: [IndependentShotCandidate], hit: Double, server: IndependentPersonBox) {
        var points = [(Double, SIMD3<Double>)]()
        var k = 0.0, b = SIMD3<Double>(x0, 24.1, 1.6), vz = 6.5
        while !(vz < 0 && b.z <= 2.7) { points.append((t0 + k, b)); b.z += vz / 60; b.y += 0.3 / 60; vz -= IndependentFlight.g / 60; k += 1 }
        let hit = t0 + k
        var s = IndependentFlight.State(p: b, v: SIMD3<Double>(vx, -36, -2))
        while s.p.z > IndependentCourt.ballRadius { points.append((t0 + k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        let bounceV: SIMD3<Double> = s.v * SIMD3<Double>(0.8, 0.75, -0.65)
        var after = IndependentFlight.State(p: SIMD3<Double>(s.p.x, s.p.y, IndependentCourt.ballRadius), v: bounceV)
        for _ in 0..<18 { points.append((t0 + k, after.p)); after = IndependentFlight.rk4(after, 1 / 60); k += 1 }
        let cam = IndependentProjector(camera)
        let candidates = points.enumerated().map { (n: Int, p: (Double, SIMD3<Double>)) -> IndependentShotCandidate in
            let q = cam.project(p.1)
            return IndependentShotCandidate(decodeIndex: n, time: p.0, u: (q.u / 4).rounded() * 4, v: (q.v / 4).rounded() * 4, peak: 0.9)
        }
        let f = cam.project(SIMD3<Double>(-1.2, 24.4, 0)), head = cam.project(SIMD3<Double>(-1.2, 24.4, 1.8))
        let h = f.v - head.v
        let server = IndependentPersonBox(x0: f.u - 0.2 * h, y0: head.v, x1: f.u + 0.2 * h, y1: f.v, confidence: 0.9, fromCrop: false, cropBottom: nil)
        return (candidates, hit / 60, server)
    }

    /// A far serve whose toss and serve stay one tracked piece (the served ball starts slowly in the image, so
    /// `splitTrack` bends with it): v15 cuts it where the vertical toss turns sideways, and the chain reports one
    /// serve at the hit instead of a shot from the start of the toss.
    func testFarServeTossAndServeInOnePiece() throws {
        let (candidates, hit, server) = farServeWithToss(at: 600)
        let track = try XCTUnwrap(IndependentBallEvents.tracks(from: candidates).max { $0.count < $1.count })
        let whole = try XCTUnwrap(IndependentBallEvents.splitTrack(track).first { (a, b) in track[a].t < hit * 60 - 20 && track[b - 1].t > hit * 60 + 10 },
                                  "the toss and the first part of the serve are one piece for splitTrack")
        let cut = try XCTUnwrap(IndependentBallEvents.tossCut(track[whole.0..<whole.1]))
        XCTAssertEqual(track[cut].t, hit * 60, accuracy: 4, "cut within a few frames of the hit")
        let (pieces, tossEnds) = IndependentBallEvents.piecesAndTossEnds(of: [track])
        XCTAssertEqual(tossEnds.count, 1)
        XCTAssertEqual(pieces[tossEnds.first!].last!.t, track[cut - 1].t)

        let people = IndependentPeople(Dictionary(uniqueKeysWithValues: (590...700).map { ($0, [server]) }))
        let shots = IndependentShotPipeline.run(candidates: candidates, segments: [.init(camera: camera)]) { _, _ in people }
        XCTAssertEqual(shots.count, 1, "the toss is not a shot: \(shots.map { ($0.tHit, $0.hitKind, $0.stroke ?? "-") })")
        let serve = try XCTUnwrap(shots.first)
        XCTAssertEqual(serve.tHit, hit, accuracy: 0.1)
        XCTAssertEqual(serve.startKind, IndependentShotFlight.HitKind.junction.rawValue)
        XCTAssertEqual(serve.hitterSide, "far")
        XCTAssertEqual(serve.stroke, "发球", serve.strokeReason ?? "")
    }

    /// The tracker picked the far toss up only on its way down, 10 points before the hit (as on test.MOV at
    /// 590 s, where the 12-point minimum before v25 left the toss glued to the serve): the cut is at the hit.
    func testShortFarTossIsCut() throws {
        let (all, hit, _) = farServeWithToss(at: 600)
        let candidates = all.filter { $0.time >= hit * 60 - 10 }
        let track = try XCTUnwrap(IndependentBallEvents.tracks(from: candidates).max { $0.count < $1.count })
        let whole = try XCTUnwrap(IndependentBallEvents.splitTrack(track).first { (a, b) in track[a].t < hit * 60 && track[b - 1].t > hit * 60 + 10 })
        let cut = try XCTUnwrap(IndependentBallEvents.tossCut(track[whole.0..<whole.1]))
        XCTAssertEqual(track[cut].t, hit * 60, accuracy: 4, "cut within a few frames of the hit")
    }

    /// The toss cut leaves ordinary flights and a toss with no sideways turn alone.
    func testTossCutLeavesOtherFlightsAlone() {
        let cam = IndependentProjector(camera)
        func points(_ s0: IndependentFlight.State, frames: Int) -> [IndependentTrackPoint] {
            var s = s0
            return (0..<frames).map { (k: Int) -> IndependentTrackPoint in
                let q = cam.project(s.p); s = IndependentFlight.rk4(s, 1 / 60)
                return IndependentTrackPoint(t: 600 + Double(k), u: (q.u / 4).rounded() * 4, v: (q.v / 4).rounded() * 4)
            }
        }
        // a rally flight from the far baseline, and a lob rising then falling at the far court
        XCTAssertNil(IndependentBallEvents.tossCut(points(.init(p: SIMD3<Double>(1, 23, 1), v: SIMD3<Double>(-2, -24, 4)), frames: 50)[...]))
        XCTAssertNil(IndependentBallEvents.tossCut(points(.init(p: SIMD3<Double>(1, 23, 1), v: SIMD3<Double>(0.5, -9, 9)), frames: 80)[...]))
        // a toss that is caught: up and down with no sideways turn
        XCTAssertNil(IndependentBallEvents.tossCut(points(.init(p: SIMD3<Double>(-1, 24, 1.6), v: SIMD3<Double>(0, 0.2, 5)), frames: 60)[...]))
    }

    /// A rally flight published before a reset is not history for the serve rules after it.
    func testServeAfterAResetIgnoresTheEarlierRally() throws {
        let cam = IndependentProjector(camera)
        var rally = [(Double, SIMD3<Double>)]()
        var s = IndependentFlight.State(p: SIMD3(0.5, 0.3, 1.0), v: SIMD3(-1.0, 24, 3.0)), k = 0.0
        while s.p.z > IndependentCourt.ballRadius { rally.append((600 + k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        var up = IndependentFlight.State(p: SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius), v: SIMD3(s.v.x * 0.8, s.v.y * 0.75, -s.v.z * 0.65))
        for _ in 0..<18 { rally.append((600 + k, up.p)); up = IndependentFlight.rk4(up, 1 / 60); k += 1 }
        let (serve, hit, server) = serveWithToss(at: 780)
        func candidates(_ pts: [(Double, SIMD3<Double>)]) -> [IndependentShotCandidate] {
            pts.enumerated().map { n, p in let q = cam.project(p.1); return IndependentShotCandidate(decodeIndex: n, time: p.0, u: q.u, v: q.v, peak: 0.9) }
        }
        // boxes only for the serve: the rally's hitter is unseen, so its hit stays at the stream start
        let people = IndependentPeople(Dictionary(uniqueKeysWithValues: (770...900).map { ($0, [server]) }))
        var live = IndependentLiveShots()
        func feed(_ c: [IndependentShotCandidate], from: Double, to: Double) {
            var next = 0, now = from
            while now < to {
                now += 0.25
                var arrived = [IndependentShotCandidate]()
                while next < c.count, c[next].time / 60 < now { arrived.append(c[next]); next += 1 }
                live.append(arrived); live.update(now: now, camera: camera, people: people)
            }
        }
        feed(candidates(rally), from: 9.75, to: 12.5)
        let first = try XCTUnwrap(live.published.first)
        XCTAssertTrue(IndependentStrokeRules.isRallyFlight(first.shot), "the earlier flight counts as a rally")
        XCTAssertLessThan(hit - first.shot.tHit, 5)
        live.reset()
        feed(candidates(serve), from: 12.75, to: 17)
        let called = try XCTUnwrap(live.published.last { abs($0.shot.tHit - hit) < 0.1 })
        XCTAssertEqual(called.shot.stroke, "发球")
    }
}
