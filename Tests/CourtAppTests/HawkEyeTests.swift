import XCTest
@testable import CourtCore
@testable import CourtApp

/// Line-call geometry (`HawkEye.judge`) on hand-placed bounces, and the display's alert bookkeeping.
/// Checks the rules only; how well a real camera's bounces fall is a separate, field question.
final class HawkEyeTests: XCTestCase {
    private let c = HawkEye.centreX
    private let on = HawkEyeSettings(enabled: true, format: .singles, farHalf: false)

    private func judge(_ cx: Double, _ y: Double, sigma: Double? = 0.01, serve: Bool = false, server: Double? = nil,
                       _ settings: HawkEyeSettings? = nil) -> HawkEyeJudgement? {
        HawkEye.judge(x: cx + c, y: y, sigmaX: sigma, sigmaY: sigma, serve: serve, serverX: server.map { $0 + c }, settings: settings ?? on)
    }

    func testRallySinglesAndDoublesSidelines() throws {
        // centre 10 cm past the singles line's outer edge, plus the ball's radius: 10 cm clear
        let wide = HawkEye.singlesHalfWidth + HawkEye.ballRadius + 0.10
        let singles = try XCTUnwrap(judge(wide, 8))
        XCTAssertEqual(singles.call, .out); XCTAssertEqual(singles.line, .sideline)
        XCTAssertEqual(singles.distanceM, 0.10, accuracy: 1e-9)
        var doubles = on; doubles.format = .doubles
        XCTAssertEqual(judge(wide, 8, doubles)?.call, .in, "Inside the doubles alley")
        XCTAssertEqual(judge(-wide, 8)?.call, .out, "Either sideline")
        // the footprint touching the line is in; within the margin it is close
        let touching = HawkEye.singlesHalfWidth + 0.02
        XCTAssertEqual(judge(touching, 8, sigma: 0.001)?.call, .close, "1.3 cm inside, within the 3 cm floor")
        XCTAssertEqual(judge(touching - 0.3, 8, sigma: 0.001)?.call, .in)
    }

    func testBaselineAndMargin() throws {
        let long = try XCTUnwrap(judge(0, -0.25, sigma: 0.05))
        XCTAssertEqual(long.line, .baseline); XCTAssertEqual(long.call, .out)
        XCTAssertEqual(long.marginM, 0.10, accuracy: 1e-9, "2 sigma")
        XCTAssertEqual(judge(0, -0.25, sigma: 0.2)?.call, .close, "A wide uncertainty makes it close")
        XCTAssertEqual(judge(0, -0.25, sigma: nil)?.marginM, HawkEye.defaultMargin)
        // near the net on the near half: the net edge is not a line, the closest line decides
        let atNet = try XCTUnwrap(judge(0, HawkEye.netY - 0.01))
        XCTAssertEqual(atNet.call, .in); XCTAssertNotEqual(atNet.line, .baseline)
    }

    func testFarHalfIsOffByDefault() {
        XCTAssertNil(judge(0, 23.9), "Far half not judged unless asked")
        var far = on; far.farHalf = true
        XCTAssertEqual(judge(0, 23.9, far)?.call, .out)
        XCTAssertEqual(judge(0, 23.9, far)?.farHalf, true)
        XCTAssertNil(judge(0, 8, .off), "Off: no calls")
    }

    func testServeUsesTheDiagonalBox() throws {
        var far = on; far.farHalf = true
        let deep = HawkEye.netY + HawkEye.serviceFromNet + HawkEye.ballRadius + 0.2
        let long = try XCTUnwrap(judge(-1, deep, serve: true, server: 2, far))
        XCTAssertEqual(long.call, .out); XCTAssertEqual(long.line, .serviceLine); XCTAssertTrue(long.serve)
        // server right of centre: the box left of centre; a ball into the right box is out by the centre line
        let wrongBox = try XCTUnwrap(judge(1, HawkEye.netY + 3, serve: true, server: 2, far))
        XCTAssertEqual(wrongBox.call, .out); XCTAssertEqual(wrongBox.line, .centreLine)
        XCTAssertEqual(judge(-1, HawkEye.netY + 3, serve: true, server: 2, far)?.call, .in)
        // near-half serve from the far end, server left of centre (from the near camera): right box
        XCTAssertEqual(judge(1, HawkEye.netY - 3, serve: true, server: -2)?.call, .in)
        XCTAssertEqual(judge(-1, HawkEye.netY - 3, serve: true, server: -2)?.call, .out)
        // no server position: either box counts
        XCTAssertEqual(judge(1, HawkEye.netY - 3, serve: true)?.call, .in)
        XCTAssertEqual(judge(-1, HawkEye.netY - 3, serve: true)?.call, .in)
        // doubles serves still go to the singles box
        var doubles = on; doubles.format = .doubles
        XCTAssertEqual(judge(4.6, HawkEye.netY - 3, serve: true, doubles)?.call, .out)
    }

    func testAnnotateSkipsBallsThatStayOnTheHittersHalf() {
        var row = TennisShotEvent(streamID: UUID(), sourcePTS: 1, stroke: .forehand, confidence: 0)
        row.bounce = TennisBounceEstimate(sourcePTS: 1.5, xMeters: c, yMeters: -0.5, confidence: 0)
        row.bounce?.sigmaXMeters = 0.01; row.bounce?.sigmaYMeters = 0.01
        XCTAssertEqual(HawkEye.annotate(row, settings: on).bounce?.hawkEye?.call, .out)
        row.hit = TennisCourtPoint(x: c, y: 2, z: 1)
        XCTAssertNil(HawkEye.annotate(row, settings: on).bounce?.hawkEye, "Hit and bounce on the same half: no call")
        row.hit = TennisCourtPoint(x: c, y: 22, z: 1)
        XCTAssertEqual(HawkEye.annotate(row, settings: on).bounce?.hawkEye?.call, .out)
        XCTAssertNil(HawkEye.annotate(row, settings: .off).bounce?.hawkEye, "Turning it off clears the call")
        // the call survives the wire
        let annotated = HawkEye.annotate(row, settings: on)
        let decoded = try? JSONDecoder().decode(TennisShotEvent.self, from: JSONEncoder().encode(annotated))
        XCTAssertEqual(decoded, annotated)
    }

    @MainActor func testAlertsOncePerShotAndNotForOldRows() {
        let alerts = HawkEyeAlerts()
        func row(_ t: Double, _ call: HawkEyeCall) -> TennisShotEvent {
            var r = TennisShotEvent(streamID: UUID(), sourcePTS: t, stroke: .forehand, confidence: 0)
            r.bounce = TennisBounceEstimate(sourcePTS: t + 0.5, xMeters: c, yMeters: 1, confidence: 0)
            r.bounce?.hawkEye = HawkEyeJudgement(call: call, distanceM: 0.1, marginM: 0.03, line: .baseline, format: .singles, serve: false, farHalf: false)
            return r
        }
        let first = row(10, .out)
        let a = alerts.next(for: [first], current: nil, soundOn: false)
        XCTAssertEqual(a?.id, first.id)
        XCTAssertEqual(alerts.next(for: [first], current: nil, soundOn: false), nil, "Announced once")
        var revised = first; revised.bounce?.hawkEye?.call = .close
        XCTAssertEqual(alerts.next(for: [revised], current: a, soundOn: false)?.judgement.call, .close, "A revision updates the shown call")
        let seen = row(11, .in); alerts.markSeen([seen])
        XCTAssertNil(alerts.next(for: [seen], current: nil, soundOn: false), "Rows from a catch-up are never announced")
        let old = row(1, .out), new = row(20, .in)
        XCTAssertEqual(alerts.next(for: [old, new], current: nil, soundOn: false)?.id, new.id, "Stale calls are skipped")
    }

    @MainActor func testCameraKeepsSettingsAndJudgesRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("court-hawkeye-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = CameraRig(root: root)
        XCTAssertEqual(rig.camera.hawkEye, .off)
        let doubles = HawkEyeSettings(enabled: true, format: .doubles, farHalf: true)
        rig.camera.setHawkEye(doubles)
        XCTAssertEqual(rig.camera.status.hawkEye, doubles, "Echoed in status")
        await rig.close()
        let again = CameraRig(root: root)
        XCTAssertEqual(again.camera.hawkEye, doubles, "Kept across a camera restart")
        await again.close()
    }

    // MARK: Challenges

    private func shot(_ pts: Double, bounce: (x: Double, y: Double)?, hitY: Double = 22, stroke: TennisStrokeKind = .forehand) -> TennisShotEvent {
        var row = TennisShotEvent(streamID: UUID(), sourcePTS: pts, stroke: stroke, confidence: 0)
        row.hit = TennisCourtPoint(x: c, y: hitY, z: 1)
        if let bounce {
            row.bounce = TennisBounceEstimate(sourcePTS: pts + 0.6, xMeters: bounce.x, yMeters: bounce.y, confidence: 0)
            row.bounce?.sigmaXMeters = 0.02; row.bounce?.sigmaYMeters = 0.05
        }
        return row
    }

    func testChallengePicksTheNewestBounceUnlessANewerShotIsFresh() {
        let a = shot(10, bounce: (c, 5)), b = shot(12, bounce: (c, 20), hitY: 1), late = shot(14, bounce: nil)
        XCTAssertEqual(HawkEye.challengeTarget([a, b], latestPTS: 13)?.id, b.id, "The newest bounced shot")
        XCTAssertEqual(HawkEye.challengeTarget([a, b, late], latestPTS: 15)?.id, late.id, "A shot a moment old may still get its bounce")
        XCTAssertEqual(HawkEye.challengeTarget([a, b, late], latestPTS: 20)?.id, b.id, "Too old to wait for")
        XCTAssertEqual(HawkEye.challengeTarget([a, b, late], latestPTS: nil)?.id, b.id, "Nothing analysed: nothing on its way")
        XCTAssertEqual(HawkEye.challengeTarget([late], latestPTS: 30)?.id, late.id, "No bounce at all: the newest, refused later")
        XCTAssertNil(HawkEye.challengeTarget([], latestPTS: 1))
        XCTAssertEqual(HawkEye.previousBounced(before: late.id, in: [b, a, late])?.id, b.id)
        XCTAssertNil(HawkEye.previousBounced(before: a.id, in: [a, b]))
    }

    func testChallengeJudgesBothHalvesWithItsFormat() throws {
        let start = HawkEyeChallenge(format: .singles)
        // far half, settings off: a challenge still judges it
        let far = HawkEye.judgeChallenge(start, for: shot(1, bounce: (c, 24.3), hitY: 1), waiting: false)
        XCTAssertEqual(far.judgement?.call, .out); XCTAssertEqual(far.judgement?.farHalf, true); XCTAssertNil(far.reason)
        // the doubles alley is in only by doubles lines
        let alley = c + HawkEye.singlesHalfWidth + 0.5
        XCTAssertEqual(HawkEye.judgeChallenge(start, for: shot(1, bounce: (alley, 6)), waiting: false).judgement?.call, .out)
        XCTAssertEqual(HawkEye.judgeChallenge(HawkEyeChallenge(format: .doubles), for: shot(1, bounce: (alley, 6)), waiting: false).judgement?.call, .in)
        // no call for a ball that stayed on the hitter's half, nor without a bounce
        XCTAssertEqual(HawkEye.judgeChallenge(start, for: shot(1, bounce: (c, 20)), waiting: false).reason, HawkEyeChallenge.sameHalfReason)
        let waiting = HawkEye.judgeChallenge(start, for: shot(1, bounce: nil), waiting: true)
        XCTAssertEqual(waiting.pending, true); XCTAssertNil(waiting.judgement)
        let gone = HawkEye.judgeChallenge(waiting, for: shot(1, bounce: nil), waiting: false)
        XCTAssertNil(gone.pending); XCTAssertEqual(gone.reason, HawkEyeChallenge.noBounceReason)
        XCTAssertEqual(start.id, gone.id, "Same challenge as it settles")
    }

    /// The camera takes a challenge, stores it on the row (not on the call of its time), keeps it when
    /// the analysis sends the row again, and finishes a pending one when the bounce arrives. Injected
    /// rows: the flow only, not accuracy.
    @MainActor func testCameraChallengesTheNewestShotAndKeepsTheResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("court-challenge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = CameraRig(root: root)
        do {
            XCTAssertEqual(rig.camera.challenge(), "还没有可以挑战的击球。")
            rig.source.start()
            try await waitFor { rig.camera.capturing && rig.camera.streamID != nil && rig.pipeline.currentCounters.latestPTS != nil }
            rig.camera.startSession(title: "挑战")
            let stream = try XCTUnwrap(rig.camera.streamID)
            let pts = try XCTUnwrap(rig.pipeline.currentCounters.latestPTS)
            var long = shot(pts, bounce: (c, -0.4), hitY: 22); long.streamID = stream
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [long]))
            try await waitFor { rig.camera.session?.tennisEvents?.contains { $0.id == long.id } == true }
            try await Task.sleep(for: .seconds(HawkEye.challengeBounceWait + 0.5))   // no newer shot pending

            XCTAssertNil(rig.camera.challenge(format: .doubles))
            XCTAssertEqual(rig.camera.hawkEye.format, .doubles, "The format sticks for line calls too")
            XCTAssertFalse(rig.camera.hawkEye.enabled, "Challenging does not turn line calls on")
            var row = try XCTUnwrap(rig.camera.session?.tennisEvents?.first { $0.id == long.id })
            let first = try XCTUnwrap(row.challenge)
            XCTAssertEqual(first.judgement?.call, .out); XCTAssertEqual(first.judgement?.line, .baseline)
            XCTAssertNil(row.bounce?.hawkEye, "The call of its time stays as it was (off)")
            XCTAssertEqual(rig.camera.latestChallenge, HawkEyeChallengeRef(shot: long.id, challenge: first.id))
            let coded = try JSONDecoder().decode(TennisShotEvent.self, from: JSONEncoder().encode(row))
            XCTAssertEqual(coded.challenge, first, "Saved and sent with the row")

            // the analysis sends the row again: the challenge stays
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [long]))
            try await Task.sleep(for: .milliseconds(200))
            row = try XCTUnwrap(rig.camera.session?.tennisEvents?.first { $0.id == long.id })
            XCTAssertEqual(row.challenge, first)

            // a fresh shot without its bounce yet: pending, then judged when the bounce lands
            let now = try XCTUnwrap(rig.pipeline.currentCounters.latestPTS)
            var fresh = shot(now, bounce: nil, hitY: 22); fresh.streamID = stream
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [fresh]))
            try await waitFor { rig.camera.session?.tennisEvents?.contains { $0.id == fresh.id } == true }
            XCTAssertNil(rig.camera.challenge())
            XCTAssertEqual(rig.camera.latestChallenge?.shot, fresh.id)
            XCTAssertEqual(rig.camera.session?.tennisEvents?.first { $0.id == fresh.id }?.challenge?.pending, true)
            fresh.bounce = TennisBounceEstimate(sourcePTS: now + 0.6, xMeters: c, yMeters: 3, confidence: 0)
            rig.camera.testingDeliver(WorkspaceIntegrationTests.snapshot(stream, [fresh]))
            try await waitFor { rig.camera.session?.tennisEvents?.first { $0.id == fresh.id }?.challenge?.judgement != nil }
            XCTAssertEqual(rig.camera.session?.tennisEvents?.first { $0.id == fresh.id }?.challenge?.judgement?.call, .in)
            XCTAssertNil(rig.camera.session?.tennisEvents?.first { $0.id == fresh.id }?.challenge?.pending)
            XCTAssertEqual(rig.camera.challenge(shot: UUID()), "找不到这一拍，可能已不在当前记录里。")
        } catch { await rig.close(); throw error }
        await rig.close()
    }

    @MainActor private func waitFor(timeout: Double = 10, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}
