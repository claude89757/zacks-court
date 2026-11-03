import XCTest
@testable import CourtApp

@MainActor
final class CameraStandbyTests: XCTestCase {
    private final class FakeScreen: StandbyScreen {
        var value: Double? = 0.8
        var writes: [Double] = []
        var brightness: Double? { value }
        func setBrightness(_ value: Double) { self.value = value; writes.append(value) }
    }
    private var clock = Date(timeIntervalSince1970: 1_000)
    private func make(_ screen: FakeScreen) -> CameraStandby {
        let defaults = UserDefaults(suiteName: "court.standby.tests.\(UUID().uuidString)")!
        return CameraStandby(screen: screen, now: { [unowned self] in self.clock }, defaults: defaults)
    }
    private func advance(_ seconds: TimeInterval, _ standby: CameraStandby) {
        for _ in 0..<Int(seconds) { clock += 1; standby.tick() }
    }

    func testDimsAfterDelayAndRestoresBrightnessOnEveryExit() {
        let screen = FakeScreen(), standby = make(screen)
        XCTAssertEqual(standby.delay, .twenty)
        standby.update(eligible: true)
        advance(19, standby); XCTAssertFalse(standby.isDimmed)
        advance(1, standby); XCTAssertTrue(standby.isDimmed)
        XCTAssertEqual(screen.value, CameraStandby.dimBrightness)
        standby.suspend()
        XCTAssertFalse(standby.isDimmed); XCTAssertEqual(screen.value, 0.8, "Control Center or background restores brightness")
        advance(30, standby); XCTAssertFalse(standby.isDimmed, "No standby while the scene is inactive")
        standby.resume(); advance(20, standby); XCTAssertTrue(standby.isDimmed)
        standby.update(eligible: false)
        XCTAssertFalse(standby.isDimmed); XCTAssertEqual(screen.value, 0.8, "Stopping the recording restores brightness")
    }

    func testTouchPostponesAndTapWakesForPeekOnly() {
        let screen = FakeScreen(), standby = make(screen)
        standby.update(eligible: true)
        advance(15, standby); standby.noteActivity()
        advance(15, standby); XCTAssertFalse(standby.isDimmed, "A touch restarts the idle delay")
        advance(5, standby); XCTAssertTrue(standby.isDimmed)
        standby.wake()
        XCTAssertFalse(standby.isDimmed); XCTAssertEqual(screen.value, 0.8)
        XCTAssertEqual(standby.peekRemaining, 15)
        advance(14, standby); XCTAssertFalse(standby.isDimmed); XCTAssertEqual(standby.peekRemaining, 1)
        advance(1, standby); XCTAssertTrue(standby.isDimmed, "A wake lasts the peek period, not the full delay")
        XCTAssertNil(standby.peekRemaining)
    }

    func testNeverDelayAndDimmerUserBrightnessAreRespected() {
        let screen = FakeScreen(), standby = make(screen)
        standby.delay = .never
        standby.update(eligible: true)
        advance(120, standby); XCTAssertFalse(standby.isDimmed)
        standby.delay = .ten
        screen.value = 0.05; screen.writes = []
        advance(10, standby); XCTAssertTrue(standby.isDimmed)
        XCTAssertEqual(screen.writes, [], "A screen already dimmer than standby brightness is never brightened")
        standby.teardown(); XCTAssertFalse(standby.isDimmed); XCTAssertEqual(screen.value, 0.05)
    }
}
