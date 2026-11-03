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
}
