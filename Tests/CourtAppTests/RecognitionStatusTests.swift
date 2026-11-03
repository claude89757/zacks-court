import XCTest
import CourtCore
@testable import CourtApp

/// 「识别状态」 rows: court mapping, people, shots, and recent speed / landing counts with reasons.
final class RecognitionStatusTests: XCTestCase {
    private let stream = UUID()

    private func row(_ status: RecognitionStatus, _ key: String) throws -> RecognitionStatus.Row {
        try XCTUnwrap(status.rows.first { $0.id == "court.recognition.\(key)" })
    }
    private func shot(_ pts: Double, speed: Double? = nil, speedReason: String? = nil, bounce: TennisBounceEstimate? = nil, stream: UUID? = nil) -> TennisShotEvent {
        TennisShotEvent(streamID: stream ?? self.stream, sourcePTS: pts, stroke: .groundstroke, confidence: 0.8,
                        speedKPH: speed, speedReason: speedReason, bounce: bounce)
    }
    private func live(_ events: [TennisShotEvent] = [], calibration: TennisCourtCalibrationState? = nil,
                      shed: Int = 0, people: RecognitionStatus.People? = nil, latest: Double? = 100) -> RecognitionStatus {
        RecognitionStatus(.init(isLive: true, calibration: calibration, shed: shed, people: people,
                                latestPTS: latest, streamID: stream, events: events))
    }

    func testNothingIsClaimedBeforeLiveData() throws {
        let status = RecognitionStatus(.init(isLive: false, calibration: nil))
        XCTAssertEqual(status.rows.map(\.title), ["球场", "人员", "击球", "球速", "落点"])
        XCTAssertEqual(status.rows.map(\.value), ["—", "—", "尚无击球", "—", "—"])
        XCTAssertTrue(status.rows.allSatisfy { $0.tone == .idle })
    }

    func testCourtRowNamesTheAutomaticMappingAndTheReasonWhenMissing() throws {
        let auto = try row(live(calibration: .init(isAvailable: true, landmarkCount: 10, validationErrorMeters: 0.57, reason: nil)), "court")
        XCTAssertEqual(auto.value, "球场映射可用")
        XCTAssertEqual(auto.detail, "自动识别 · 10 个场地参考点 · 拟合残差 0.57 m")
        XCTAssertEqual(auto.tone, .good)
        // the in-house court states its lines and pixel error itself
        let inHouse = try row(live(calibration: .init(isAvailable: true, landmarkCount: 7, reason: "自动识别 · 7 条球场线 · 对齐误差 0.6 像素")), "court")
        XCTAssertEqual(inHouse.detail, "自动识别 · 7 条球场线 · 对齐误差 0.6 像素")
        let missing = try row(live(calibration: .init(isAvailable: false, landmarkCount: 3, reason: "受支持的可见地面地标不足七个")), "court")
        XCTAssertEqual(missing.value, "球场映射未就绪")
        XCTAssertEqual(missing.tone, .warning)
        XCTAssertTrue(missing.detail?.hasPrefix("受支持的可见地面地标不足七个") == true)
        XCTAssertFalse(missing.detail?.contains("标定") == true, "no manual calibration to point to")
        XCTAssertEqual(try row(live(), "court").value, "球场映射未就绪", "Live but no calibration yet")
    }

    func testPeopleRowIsPausedUnderLoadAndNeverShowsAStaleCount() throws {
        let fresh = RecognitionStatus.People(streamID: stream, pts: 99, count: 2)
        XCTAssertEqual(try row(live(people: fresh), "people").value, "2 人")
        // The camera keeps its last result while person detection is shed (L1).
        XCTAssertEqual(try row(live(shed: 1, people: fresh), "people").value, "已暂停")
        XCTAssertEqual(try row(live(people: .init(streamID: stream, pts: 90, count: 2)), "people").value, "—")
        XCTAssertEqual(try row(live(people: .init(streamID: UUID(), pts: 99, count: 2)), "people").value, "—")
        XCTAssertEqual(try row(live(people: fresh, latest: nil), "people").value, "—")
    }

    func testShotsRowCountsTheLedgerAndTimesOnlyTheSameStream() throws {
        let events = [shot(80), shot(92)]
        let same = try row(live(events), "shots")
        XCTAssertEqual(same.value, "2 拍")
        XCTAssertEqual(same.detail, "最近一拍 8 秒前")
        let other = try row(live([shot(80), shot(92, stream: UUID())]), "shots")
        XCTAssertNil(other.detail, "Clocks of different streams are not compared")
    }

    /// Shaped like the 2026-10-28 screen-filmed run: most bounce candidates fail ball localization.
    func testLandingCountsSettledShotsAndNamesTheMainReasonInPlainWords() throws {
        let focus = TennisBounceEstimate(sourcePTS: 0, confidence: 0, reason: "Focus球位置缺失、低分或存在竞争目标")
        var events = (0..<7).map { shot(Double($0), speedReason: "下一段击球前没有可靠首弹地证据", bounce: focus) }
        events.append(shot(10, speed: 95, bounce: .init(sourcePTS: 10.5, xMeters: 5, yMeters: 18, confidence: 0.7)))
        events.append(shot(12, speedReason: "超过已支持的飞行时间，未确认首弹地")) // concluded, no bounce
        events.append(shot(14, speedReason: "等待首弹地及连续三维轨迹")) // still in flight: not counted
        events.append(shot(15, speed: 120, bounce: .init(sourcePTS: 15.6, confidence: 0, reason: "等待独立队列触地定位")))
        let landing = try row(live(events), "landing")
        XCTAssertEqual(landing.value, "1 / 9 拍")
        XCTAssertEqual(landing.detail, "未给出的主要原因：没看清球（7 拍）")
        XCTAssertEqual(landing.tone, .good)
        let speed = try row(live(events), "speed")
        XCTAssertEqual(speed.value, "2 / 10 拍", "The shot waiting on its landing already has a speed")
        XCTAssertTrue(speed.detail?.contains("没看到球落地（8 拍）") == true, "Flights that ended without a first bounce share one plain reason")
        // None located over enough shots is a warning, not a silent zero.
        let none = try row(live(Array(events.prefix(7))), "landing")
        XCTAssertEqual(none.value, "0 / 7 拍")
        XCTAssertEqual(none.tone, .warning)
    }

    func testLandingIsPausedUnderHeavyLoadAndCountsOnlyTheRecentWindow() throws {
        let located = TennisBounceEstimate(sourcePTS: 0, xMeters: 4, yMeters: 20, confidence: 0.7)
        XCTAssertEqual(try row(live([shot(1, bounce: located)], shed: 2), "landing").value, "已暂停")
        // the in-house lane keeps estimating landing points and only slows person detection
        var inHouse = RecognitionStatus.Input(isLive: true, calibration: nil, shed: 2, latestPTS: 100)
        inHouse.inHouse = true; inHouse.events = [shot(1, bounce: located)]
        let status = RecognitionStatus(inHouse)
        XCTAssertNotEqual(status.rows.first { $0.id == "court.recognition.landing" }?.value, "已暂停")
        XCTAssertEqual(status.rows.first { $0.id == "court.recognition.people" }?.value, "已放慢")
        let many = (0..<30).map { shot(Double($0), speed: 100, bounce: located) }
        XCTAssertEqual(try row(live(many), "landing").value, "\(RecognitionStatus.window) / \(RecognitionStatus.window) 拍")
        let waiting = try row(live([shot(1, speedReason: "等待首弹地及连续三维轨迹")]), "speed")
        XCTAssertEqual(waiting.value, "—")
        XCTAssertEqual(waiting.detail, "还在分析已检出的击球。")
        XCTAssertNil(try row(live(many.map { var e = $0; e.speedKPH = 90; return e }), "speed").detail, "No reason line when every shot has a value")
    }
}
