import XCTest
import CoreVideo
import simd
@testable import CourtCore

/// The live lane's automatic court: sampling, the banded median, the find / move / lose cycle on
/// rendered courts, restarting after a zoom, and catching up the shots from before the court was found.
/// Synthetic inputs only: these prove the plumbing and geometry, not field accuracy.
final class IndependentLiveCourtTests: XCTestCase {
    static let cameraA = IndependentPinholeCamera.lookingAt(SIMD3(0, 9, 0), from: SIMD3(0.3, -6.4, 3.2), f: 1150)
    /// The mount moved 0.4 m sideways and turned a little.
    static let cameraB = IndependentPinholeCamera.lookingAt(SIMD3(0.2, 9, 0), from: SIMD3(0.7, -6.4, 3.2), f: 1150)

    private func bgra(_ image: IndependentCourtImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let b = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(b, []); defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let k = y * image.width + x, o = y * row + 4 * x
                p[o] = image.blue[k]; p[o + 1] = image.green[k]; p[o + 2] = image.red[k]; p[o + 3] = 255
            }
        }
        return b
    }

    private func nv12(y: UInt8, cb: UInt8, cr: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let b = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(b, []); defer { CVPixelBufferUnlockBaseAddress(b, []) }
        memset(CVPixelBufferGetBaseAddressOfPlane(b, 0), Int32(y), CVPixelBufferGetBytesPerRowOfPlane(b, 0) * 1080)
        let c = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(CVPixelBufferGetBytesPerRowOfPlane(b, 1) * 540) { c[i] = i % 2 == 0 ? cb : cr }
        return b
    }

    func testBandedMedianEqualsTheWholeImageMedian() throws {
        var rng = SplitMix(seed: 7)
        var images = [IndependentCourtImage]()
        for _ in 0..<3 {
            let n = 1920 * 1080
            images.append(try IndependentCourtImage(width: 1920, height: 1080, blue: (0..<n).map { _ in rng.byte() },
                                                    green: (0..<n).map { _ in rng.byte() }, red: (0..<n).map { _ in rng.byte() }))
        }
        let samples = try images.map { try XCTUnwrap(IndependentLiveCourt.sample(try bgra($0))) }
        XCTAssertEqual(samples[0].planes.map(\.count), [1920 * 1080 * 4])
        XCTAssertEqual(try IndependentLiveCourt.median(samples), try IndependentCourtMedian.median(of: images))
        XCTAssertNil(IndependentLiveCourt.sample(try bgra(try IndependentCourtImage(width: 64, height: 64, blue: .init(repeating: 0, count: 4096),
                                                                                      green: .init(repeating: 0, count: 4096), red: .init(repeating: 0, count: 4096)))),
                     "the calibrator only takes 1920×1080")
    }

    func testNV12SamplesAreKeptAsPlanesAndConvertedWithBT709() throws {
        let sample = try XCTUnwrap(IndependentLiveCourt.sample(try nv12(y: 100, cb: 150, cr: 90)))
        XCTAssertEqual(sample.planes.map(\.count), [1920 * 1080, 1920 * 540], "3.1 MB per sample, not an RGB copy")
        let image = try IndependentLiveCourt.median([sample, sample])
        let yy = (100.0 - 16) * 255 / 219, pb = (150.0 - 128) * 255 / 224, pr = (90.0 - 128) * 255 / 224
        let k = 540 * 1920 + 960
        XCTAssertEqual(Double(image.red[k]), min(255, max(0, yy + 1.5748 * pr)), accuracy: 3)
        XCTAssertEqual(Double(image.green[k]), yy - 0.1873 * pb - 0.4681 * pr, accuracy: 3)
        XCTAssertEqual(Double(image.blue[k]), min(255, yy + 1.8556 * pb), accuracy: 3)
    }

    /// Rendered court → found; same court on a re-check → kept; moved mount → replaced; lines gone → lost
    /// after two misfits, then searching again with the refusal reason. One sample per solve keeps the
    /// debug-build run short (about six solves); the multi-frame median is covered above.
    func testFindsKeepsMovesAndLosesTheCourt() throws {
        var options = IndependentLiveCourt.Options()
        options.sampleInterval = 0.1; options.firstAttemptFrames = 1; options.retryFrames = 1
        options.recheckInterval = 1; options.recheckFrames = 1
        options.motionPixels = nil              // the slow path: a re-check sees the mount moved (no tracking)
        let court = IndependentLiveCourt(options: options)
        let a = try bgra(try CourtRenderer(camera: Self.cameraA).render())
        let b = try bgra(try CourtRenderer(camera: Self.cameraB, seed: 2).render())
        let blank = try bgra(try CourtRenderer(camera: Self.cameraA).render(masked: { _, _ in true }))
        var pts = 100.0, changes = [IndependentLiveCourt.Change]()
        func feed(_ frame: CVPixelBuffer, seconds: Double) {
            for _ in 0..<Int((seconds / 0.1).rounded()) {
                pts += 0.1
                if let change = court.offer(frame, pts: pts) { changes.append(change) }
                court.drain()
            }
        }
        feed(a, seconds: 0.2)
        guard case .found(let found)? = changes.first else { return XCTFail("court not found: \(court.latest?.refusals ?? [])") }
        XCTAssertLessThan(IndependentLiveCourt.distance(found, Self.cameraA), 1.5)
        XCTAssertEqual(court.latest?.quality, .good)
        let diagnostics = court.diagnostics
        XCTAssertEqual(diagnostics.state, .found)
        XCTAssertEqual(diagnostics.lines, court.latest?.linesUsed.count)
        XCTAssertEqual(try XCTUnwrap(diagnostics.heightMeters), Self.cameraA.centre.z, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(diagnostics.behindBaselineMeters), -Self.cameraA.centre.y, accuracy: 0.5)
        XCTAssertGreaterThan(diagnostics.maxSolveSeconds, 0)
        XCTAssertNil(diagnostics.refusals)

        feed(a, seconds: 1.2)
        XCTAssertEqual(changes.count, 1, "a re-check of the same court changes nothing")
        XCTAssertEqual(court.stats.solves, 2)

        feed(b, seconds: 1.2)
        guard case .moved(let moved)? = changes.last, changes.count == 2 else { return XCTFail("move not seen: \(changes)") }
        XCTAssertLessThan(IndependentLiveCourt.distance(moved, Self.cameraB), 1.5)
        XCTAssertGreaterThan(IndependentLiveCourt.distance(moved, found), options.movedPixels)

        feed(blank, seconds: 1.4)
        XCTAssertEqual(changes.last, .lost, "two misfits in a row: \(changes)")
        XCTAssertTrue(court.searching)
        feed(blank, seconds: 0.2)
        XCTAssertEqual(changes.count, 3, "searching a blank court finds nothing")
        XCTAssertFalse(court.latest?.refusals.isEmpty ?? true, "the refusal reason is kept for the camera screen")
        XCTAssertEqual(court.diagnostics.state, .searching)
        XCTAssertEqual(court.diagnostics.refusals, court.latest?.refusals.map(\.rawValue))
        XCTAssertEqual(court.diagnostics.lost, 1)
    }

    /// The renderer's sky clutter is drawn fixed in the image, which no real camera sees: left out here
    /// (poles off, sky above row 300 painted as court) so that the picture moves with the camera.
    private func uncluttered(_ camera: IndependentPinholeCamera) throws -> CVPixelBuffer {
        try bgra(try CourtRenderer(camera: camera, poleSpacing: 100_000).render(masked: { _, y in y < 300 }))
    }

    /// A still picture is not motion and a turned mount is. With hand-held tracking off (`movingInterval`
    /// nil, the behaviour before 2026-11-04 evening) nothing is sampled while the picture shakes and a found
    /// camera is dropped, then the court is found again at the new pose once still.
    func testShakingPictureWithoutHandHeldTrackingDropsTheCamera() throws {
        func render(_ camera: IndependentPinholeCamera) throws -> CVPixelBuffer { try uncluttered(camera) }
        let a = try render(Self.cameraA)
        // turned about 1 degree (about 20 px), and about 0.06 degree (about 1 px)
        let turned = IndependentPinholeCamera.lookingAt(SIMD3(0.27, 9, 0), from: SIMD3(0.3, -6.4, 3.2), f: 1150)
        let nudged = IndependentPinholeCamera.lookingAt(SIMD3(0.016, 9, 0), from: SIMD3(0.3, -6.4, 3.2), f: 1150)
        let c = try render(turned), n = try render(nudged)
        let ta = try XCTUnwrap(IndependentLiveCourt.thumbnail(a))
        XCTAssertLessThan(IndependentLiveCourt.motion(ta, ta), 0.01)
        XCTAssertLessThan(IndependentLiveCourt.motion(ta, try XCTUnwrap(IndependentLiveCourt.thumbnail(n))), 4, "1 px is not motion")
        XCTAssertGreaterThan(IndependentLiveCourt.motion(ta, try XCTUnwrap(IndependentLiveCourt.thumbnail(c))), 4, "20 px is")

        var options = IndependentLiveCourt.Options()
        options.sampleInterval = 0.1; options.firstAttemptFrames = 1; options.retryFrames = 1
        // The flat rendered court has few edges, so the measure tops out near 6 px however far the mount
        // turns (real footage reads 15-30 px when handled): the threshold is lowered to make this a knock.
        options.shakePixels = 4.5
        options.movingInterval = nil
        let court = IndependentLiveCourt(options: options)
        var pts = 100.0, changes = [IndependentLiveCourt.Change](), moving = 0
        func feed(_ frame: CVPixelBuffer, seconds: Double) {
            for _ in 0..<Int((seconds / 0.1).rounded()) {
                pts += 0.1
                if let change = court.offer(frame, pts: pts) { changes.append(change) }
                court.drain()
                if court.moving { moving += 1; XCTAssertTrue(court.searching) }
            }
        }
        feed(a, seconds: 1.2)
        guard case .found(let found)? = changes.first else { return XCTFail("court not found: \(court.latest?.refusals ?? [])") }
        XCTAssertLessThan(IndependentLiveCourt.distance(found, Self.cameraA), 1.5)
        XCTAssertEqual(moving, 0)
        let samples = court.stats.samples
        feed(c, seconds: 0.5)
        XCTAssertEqual(changes.last, .lost, "the mount was turned: the old court is not kept")
        XCTAssertEqual(court.stats.samples, samples, "nothing sampled while moving")
        feed(c, seconds: 1.0)
        guard case .found(let again)? = changes.last, changes.count == 3 else { return XCTFail("not found again: \(changes)") }
        XCTAssertLessThan(IndependentLiveCourt.distance(again, turned), 1.5)
        XCTAssertFalse(court.moving)

        // full frames that stop coming for a while (dropped copies, heat): "moving" never sticks
        let sparse = IndependentLiveCourt(options: options)
        for frame in [a, a, a, a, a, a, c] { pts += 0.2; _ = sparse.offer(frame, pts: pts); sparse.drain() }
        XCTAssertTrue(sparse.moving)
        pts += 4; _ = sparse.offer(c, pts: pts); sparse.drain()
        XCTAssertFalse(sparse.moving, "nothing recent to compare with counts as still")
        pts += 0.2; _ = sparse.offer(c, pts: pts); sparse.drain()
        XCTAssertLessThan(IndependentLiveCourt.distance(try XCTUnwrap(sparse.camera, "sampling resumed and found the court"), turned), 1.5)
    }

    /// A phone held in the hand: the picture shakes, yet the found camera is followed on single frames.
    /// A 1 degree jump (about 20 px, twice the refinement window) is predicted from the picture's shift and
    /// tracked, not dropped. A 6 degree swing (about 120 px) is past prediction: the camera is dropped and
    /// single frames are searched again while the picture still shakes, without waiting for it to stop.
    func testHandHeldPictureKeepsTheCourt() throws {
        var options = IndependentLiveCourt.Options()
        options.sampleInterval = 0.1; options.firstAttemptFrames = 1; options.retryFrames = 1
        options.movingInterval = 0.1
        options.shakePixels = 4.5               // the flat rendered court reads at most about 6 px (see above)
        let court = IndependentLiveCourt(options: options)
        func pose(_ x: Double) -> IndependentPinholeCamera { .lookingAt(SIMD3(x, 9, 0), from: SIMD3(0.3, -6.4, 3.2), f: 1150) }
        var pts = 100.0, changes = [IndependentLiveCourt.Change](), shaking = 0
        func feed(_ frame: CVPixelBuffer, seconds: Double) {
            for _ in 0..<Int((seconds / 0.1).rounded()) {
                pts += 0.1
                if let change = court.offer(frame, pts: pts) { changes.append(change) }
                court.drain()
                if court.motion == .shaking { shaking += 1 }
            }
        }
        feed(try uncluttered(pose(0)), seconds: 1.2)
        guard case .found? = changes.first else { return XCTFail("court not found: \(court.latest?.refusals ?? [])") }
        feed(try uncluttered(pose(0.27)), seconds: 0.6)
        XCTAssertGreaterThan(shaking, 0, "the turn reads as a shake")
        XCTAssertFalse(changes.contains(.lost), "a hand-held turn inside the tracking range keeps the court: \(changes)")
        XCTAssertLessThan(IndependentLiveCourt.distance(try XCTUnwrap(court.camera), pose(0.27)), 2)

        // a 6 degree swing (about 120 px) is past prediction: dropped, then found again while still shaking
        let far = pose(0.27 + 1.7)
        shaking = 0
        feed(try uncluttered(far), seconds: 0.6)
        XCTAssertTrue(changes.contains(.lost), "\(changes)")
        guard case .found(let again)? = changes.last else { return XCTFail("not found again while shaking: \(changes)") }
        XCTAssertGreaterThan(shaking, 0, "found again before the picture counted as still")
        XCTAssertLessThan(IndependentLiveCourt.distance(again, far), 2)
    }

    /// The camera turn measured on the motion thumbnails predicts the turned camera to within a pixel
    /// or two, for small and large (2 degree) turns.
    func testTurnOfTheCameraIsMeasuredFromThePicture() throws {
        let a = Self.cameraA
        let ta = try XCTUnwrap(IndependentLiveCourt.thumbnail(try uncluttered(a)))
        for (pan, tilt) in [(1.0, -0.4), (-2.2, 0.6), (0.15, 0.1)] {
            let b = IndependentLiveCourt.turned(a, pan: pan * .pi / 180, tilt: tilt * .pi / 180)
            let tb = try XCTUnwrap(IndependentLiveCourt.thumbnail(try uncluttered(b)))
            let turn = try XCTUnwrap(IndependentLiveCourt.turn(ta, tb, camera: a))
            let predicted = IndependentLiveCourt.turned(a, pan: turn.x, tilt: turn.y)
            XCTAssertGreaterThan(IndependentLiveCourt.distance(a, b), 0.9 * abs(pan) * .pi / 180 * a.f)
            XCTAssertLessThan(IndependentLiveCourt.distance(predicted, b), 2, "pan \(pan) tilt \(tilt) -> \(turn * 180 / .pi)")
        }
    }

    /// A hand-held or loosely propped phone keeps turning slowly. The found camera is followed by refining
    /// it on single frames (each step about 12 px) instead of being dropped and searched for again, whether
    /// the measure calls the picture drifting or still.
    func testDriftingMountIsFollowed() throws {
        var options = IndependentLiveCourt.Options()
        options.sampleInterval = 0.1; options.firstAttemptFrames = 1; options.retryFrames = 1
        options.stillTrackInterval = 0.3
        let court = IndependentLiveCourt(options: options)
        func pose(_ x: Double) -> IndependentPinholeCamera {
            .lookingAt(SIMD3(x, 9, 0), from: SIMD3(0.3, -6.4, 3.2), f: 1150)
        }
        var pts = 100.0, changes = [IndependentLiveCourt.Change]()
        func feed(_ frame: CVPixelBuffer, seconds: Double) {
            for _ in 0..<Int((seconds / 0.1).rounded()) {
                pts += 0.1
                if let change = court.offer(frame, pts: pts) { changes.append(change) }
                court.drain()
            }
        }
        feed(try uncluttered(pose(0)), seconds: 1.2)
        guard case .found? = changes.first else { return XCTFail("court not found: \(court.latest?.refusals ?? [])") }
        for x in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6] { feed(try uncluttered(pose(x)), seconds: 0.5) }
        XCTAssertFalse(changes.contains(.lost), "a drifting mount keeps its court: \(changes)")
        XCTAssertGreaterThanOrEqual(changes.filter { if case .moved = $0 { return true } else { return false } }.count, 3)
        XCTAssertLessThan(IndependentLiveCourt.distance(try XCTUnwrap(court.camera), pose(0.60)), 2)
    }

    /// A zoom change: the camera in use no longer matches the picture, so it is dropped and the court is
    /// searched for again in the new framing.
    func testRestartDropsTheCameraAndSearchesAgain() throws {
        var options = IndependentLiveCourt.Options()
        options.sampleInterval = 0.1; options.firstAttemptFrames = 1; options.retryFrames = 1
        let court = IndependentLiveCourt(options: options)
        court.adopt(Self.cameraA, pts: 0)
        court.restart()
        XCTAssertTrue(court.searching)
        let b = try bgra(try CourtRenderer(camera: Self.cameraB).render())
        var pts = 1.0, found: IndependentPinholeCamera?
        for _ in 0..<5 where found == nil {
            pts += 0.1
            if case .found(let camera)? = court.offer(b, pts: pts) { found = camera }
            court.drain()
        }
        if found == nil { pts += 0.1; if case .found(let camera)? = court.offer(b, pts: pts) { found = camera } }
        XCTAssertLessThan(IndependentLiveCourt.distance(try XCTUnwrap(found, "found again"), Self.cameraB), 1.5)
    }

    // MARK: catch-up of shots from before the court was found

    private func syntheticShot(camera: IndependentPinholeCamera, t0: Double) -> [IndependentShotCandidate] {
        let cam = IndependentProjector(camera)
        var s = IndependentFlight.State(p: SIMD3(0.5, 0.3, 1.0), v: SIMD3(-1.0, 24, 3.0))
        var points = [(Double, SIMD3<Double>)]()
        var k = 0.0
        while s.p.z > IndependentCourt.ballRadius || k == 0 { points.append((t0 + k, s.p)); s = IndependentFlight.rk4(s, 1 / 60); k += 1 }
        var after = IndependentFlight.State(p: SIMD3(s.p.x, s.p.y, IndependentCourt.ballRadius), v: SIMD3(s.v.x * 0.8, s.v.y * 0.75, -s.v.z * 0.65))
        for j in 0..<18 { points.append((t0 + k + Double(j), after.p)); after = IndependentFlight.rk4(after, 1 / 60) }
        return points.enumerated().filter { $0.element.0 >= t0 + 2 }.map { n, p in
            let q = cam.project(p.1); return IndependentShotCandidate(decodeIndex: n, time: p.0, u: q.u, v: q.v, peak: 0.9)
        }
    }

    /// Candidates arrive while the court is unknown (only trimmed); once found, one pass publishes the
    /// earlier shot with the batch chain's speed, and later updates do not publish it again.
    func testCatchUpPublishesShotsFromBeforeTheCourtWasFound() throws {
        let camera = IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0), from: SIMD3(0.3, -6.4, 3.1), f: 1400)
        let candidates = syntheticShot(camera: camera, t0: 600)
        let people = IndependentPeople([:])
        let expected = try XCTUnwrap(IndependentShotPipeline.run(candidates: candidates, segments: [.init(camera: camera)]) { _, _ in people }
            .first { $0.bounceFound }?.reportedSpeedKmh)
        var live = IndependentLiveShots(), next = 0, now = 9.75
        func advance(to end: Double, known: Bool) {
            while now < end {
                now += 0.25
                var arrived = [IndependentShotCandidate]()
                while next < candidates.count, candidates[next].time / 60 < now { arrived.append(candidates[next]); next += 1 }
                live.append(arrived)
                if known { live.update(now: now, camera: camera, people: people) } else { live.trim(keeping: 30, now: now) }
            }
        }
        advance(to: 25, known: false)                   // court found 15 s after the shot
        XCTAssertTrue(live.published.isEmpty)
        let changed = live.catchUp(now: now, camera: camera, people: people)
        let shown = try XCTUnwrap(live.published.first { $0.shot.reportedSpeedKmh != nil })
        XCTAssertFalse(changed.isEmpty)
        XCTAssertEqual(try XCTUnwrap(shown.shot.reportedSpeedKmh), expected, accuracy: 1e-9)
        let count = live.published.count
        advance(to: 32, known: true)
        XCTAssertEqual(live.published.count, count, "normal updates do not publish the caught-up shot again")

        // found more than 30 s later: the shot was trimmed away and is not invented
        var late = IndependentLiveShots()
        late.append(candidates)
        late.trim(keeping: 30, now: 45)
        XCTAssertTrue(late.catchUp(now: 45, camera: camera, people: people).isEmpty)
    }

    func testFreezeKeepsCandidatesButStopsRevisions() throws {
        let camera = IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0), from: SIMD3(0.3, -6.4, 3.1), f: 1400)
        var live = IndependentLiveShots()
        live.append(syntheticShot(camera: camera, t0: 600))
        _ = live.catchUp(now: 13, camera: camera, people: IndependentPeople([:]))
        XCTAssertFalse(live.published.isEmpty)
        live.freeze()
        XCTAssertTrue(live.published.allSatisfy(\.frozen))
        let moved = IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0), from: SIMD3(0.6, -6.4, 3.1), f: 1400)
        XCTAssertTrue(live.catchUp(now: 13.25, camera: moved, people: IndependentPeople([:])).isEmpty, "frozen shots are not revised or duplicated")
    }
}
