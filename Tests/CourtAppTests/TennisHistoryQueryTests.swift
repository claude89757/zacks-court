import XCTest
import CourtCore

final class TennisHistoryQueryTests: XCTestCase {
    private func session(_ title: String, at date: Date, speeds: [Double?], firstPTS: Double = 10) -> CourtSession {
        let stream = UUID()
        var session = CourtSession(title: title, startedAt: date)
        let events = speeds.enumerated().map { index, speed in
            TennisShotEvent(streamID: stream, sourcePTS: firstPTS + Double(index), stroke: index == 0 ? .serve : .groundstroke,
                            confidence: 0.9, speedKPH: speed,
                            bounce: index == 0 ? .init(sourcePTS: firstPTS + 0.5, xMeters: 3, yMeters: 18, confidence: 0.8) : nil)
        }
        session.recordTennisAnalysis(.init(streamID: stream, pts: firstPTS + 5, processedFrames: 3, inferenceMilliseconds: 10,
                                           events: events, calibration: .init(), modelVersion: "test", limitations: []))
        return session
    }
    func testQueryCombinesNameDateSpeedAndStrokeWithoutCountingUnknownAsZero() {
        let date = Date(timeIntervalSince1970: 1_000)
        let a = session("周一练习", at: date, speeds: [120, nil, 60])
        let b = session("周二练习", at: date.addingTimeInterval(86_400), speeds: [90, nil])
        let index = TennisHistoryShot.index(sessions: [a, b])
        var query = TennisHistoryQuery()
        query.text = "周一"; query.from = date; query.until = date.addingTimeInterval(86_400)
        query.stroke = .serve; query.minimumSpeed = 100; query.maximumSpeed = 130
        XCTAssertEqual(query.results(in: index).map(\.event.validSpeedKPH), [120])
        query = TennisHistoryQuery(); query.minimumSpeed = 0; query.maximumSpeed = 80
        XCTAssertEqual(query.results(in: index).map(\.event.validSpeedKPH), [60])
        query.availability = .missingSpeed
        XCTAssertTrue(query.results(in: index).isEmpty)
        query.availability = .all; query.minimumSpeed = .nan
        XCTAssertTrue(query.results(in: index).isEmpty)
        query.minimumSpeed = 100; query.maximumSpeed = 80
        XCTAssertTrue(query.results(in: index).isEmpty)
    }
    func testServeSummaryCountsOnlyServesWithUsableSpeed() {
        let stream = UUID()
        func shot(_ pts: Double, _ stroke: TennisStrokeKind, _ speed: Double?) -> TennisShotEvent {
            TennisShotEvent(streamID: stream, sourcePTS: pts, stroke: stroke, confidence: 0.9, speedKPH: speed)
        }
        let empty = TennisServeSummary(events: [shot(1, .forehand, 120)])
        XCTAssertEqual(empty.serveCount, 0); XCTAssertNil(empty.latest); XCTAssertNil(empty.maximumSpeed)
        XCTAssertNil(empty.averageSpeed); XCTAssertNil(empty.minimumSpeed); XCTAssertFalse(empty.isHoldingPreviousValue)
        let rows = [shot(1, .serve, 150), shot(2, .forehand, 170), shot(9, .serve, nil), shot(15, .serve, 130),
                    shot(16, .backhand, 60), shot(22, .serve, .nan), shot(30, .serve, 0)]
        let summary = TennisServeSummary(events: rows)
        XCTAssertEqual(summary.serveCount, 5)
        // Serve numbers count every serve, so gaps in the trend stay visible.
        XCTAssertEqual(summary.points.map(\.serveNumber), [1, 3])
        XCTAssertEqual(summary.points.map(\.speedKPH), [150, 130])
        XCTAssertEqual(summary.maximumSpeed, 150); XCTAssertEqual(summary.minimumSpeed, 130)
        XCTAssertEqual(try XCTUnwrap(summary.averageSpeed), 140, accuracy: 1e-9)
        // The newest serve has no speed: hold the last usable serve, never a groundstroke's 170.
        XCTAssertEqual(summary.latest?.speedKPH, 130)
        XCTAssertTrue(summary.isHoldingPreviousValue)
        XCTAssertFalse(TennisServeSummary(events: Array(rows.prefix(4))).isHoldingPreviousValue)
    }
    func testOrderingUsesSessionAndShotOrdinalWhenSourceClocksRestart() {
        let date = Date(timeIntervalSince1970: 1_000)
        let a = session("旧", at: date, speeds: [130, 50], firstPTS: 1_000)
        let b = session("新", at: date.addingTimeInterval(10), speeds: [90, nil], firstPTS: 0)
        let index = TennisHistoryShot.index(sessions: [a, b])
        var query = TennisHistoryQuery()
        XCTAssertEqual(query.results(in: index).map(\.ordinal), [2, 1, 2, 1])
        XCTAssertEqual(query.results(in: index).first?.sessionTitle, "新")
        query.order = .fastest
        XCTAssertEqual(query.results(in: index).compactMap(\.event.validSpeedKPH), [130, 90, 50])
        XCTAssertNil(query.results(in: index).last?.event.validSpeedKPH)
        query.availability = .placement
        XCTAssertEqual(query.results(in: index).count, 2)
        query.availability = .missingPlacement
        XCTAssertEqual(query.results(in: index).count, 2)
    }
    func testSummaryRejectsNonFiniteAndInvalidSpeedsAndPreservesLastValidValue() {
        let row = session("缺失", at: Date(), speeds: [100, nil, 0, -1, .nan, .infinity])
        let summary = TennisEventSummary(events: row.tennisEvents ?? [])
        XCTAssertEqual(summary.count, 6)
        XCTAssertEqual(summary.speedCount, 1)
        XCTAssertEqual(summary.averageSpeed, 100)
        XCTAssertEqual(summary.maximumSpeed, 100)
        XCTAssertEqual(summary.latestValidSpeed?.speedKPH, 100)
        XCTAssertNil(TennisEventSummary(events: []).averageSpeed)
    }
    func testPlaybackLookupUsesMatchingStreamAndRecordingInterval() throws {
        var row = session("片段", at: Date(), speeds: [100], firstPTS: 10)
        let stream = try XCTUnwrap(row.tennisEvents?.first?.streamID)
        try row.addRecording(.init(filename: "other.mov", frames: 60, duration: 2, firstPTS: 9, streamID: UUID()))
        try row.addRecording(.init(filename: "matching.mov", frames: 60, duration: 2, firstPTS: 9, streamID: stream))
        let shot = try XCTUnwrap(TennisHistoryShot.index(sessions: [row]).first)
        XCTAssertEqual(shot.recording?.filename, "matching.mov")
        XCTAssertEqual(shot.recordingSeconds, 1)
    }

    /// The end-of-record card only reports what the saved session holds: unusable speeds (missing,
    /// 0, NaN, negative, infinite) count as shots but never enter the top or the average.
    func testSessionSummaryUsesOnlyValidValues() {
        let stream = UUID(), start = Date(timeIntervalSince1970: 1_000)
        var session = CourtSession(title: "周四晚 · 单打", startedAt: start)
        let rows: [(TennisStrokeKind, Double?)] = [(.serve, 150), (.forehand, nil), (.forehand, 0), (.backhand, .nan),
                                                   (.forehand, -20), (.unknown, .infinity), (.backhand, 90)]
        let events = rows.enumerated().map { index, row in
            TennisShotEvent(streamID: stream, sourcePTS: Double(index), stroke: row.0, confidence: 0.8, speedKPH: row.1)
        }
        session.mergeRemoteTennisEvents(events)
        session.addMarker("精彩", at: start.addingTimeInterval(5))
        session.pause(at: start.addingTimeInterval(60))
        session.resume(at: start.addingTimeInterval(100))
        session.finish(at: start.addingTimeInterval(130))
        let summary = CourtSessionSummary(session: session, now: start.addingTimeInterval(9_999))
        XCTAssertEqual(summary.sessionID, session.id)
        XCTAssertEqual(summary.title, "周四晚 · 单打")
        // The pause is not recording time, and a finished record does not keep counting.
        XCTAssertEqual(summary.duration, 90, accuracy: 1e-6)
        XCTAssertEqual(summary.shotCount, 7)
        XCTAssertEqual(summary.speedCount, 2)
        XCTAssertEqual(summary.maximumSpeed, 150)
        XCTAssertEqual(try XCTUnwrap(summary.averageSpeed), 120, accuracy: 1e-9)
        XCTAssertEqual(summary.strokes.map(\.kind), [.forehand, .backhand, .serve, .unknown].sorted { a, b in
            TennisStrokeKind.allCases.firstIndex(of: a)! < TennisStrokeKind.allCases.firstIndex(of: b)!
        })
        XCTAssertEqual(summary.strokes.first { $0.kind == .forehand }?.count, 3)
        XCTAssertEqual(summary.strokes.reduce(0) { $0 + $1.count }, 7, "Every shot is in the distribution, unknown included")
        XCTAssertEqual(summary.markerCount, 1)
    }

    func testSessionSummaryWithoutShotsStaysEmptyNotZero() {
        var withoutLedger = CourtSession(title: "无分析", startedAt: Date(timeIntervalSince1970: 0))
        withoutLedger.finish(at: Date(timeIntervalSince1970: 30))
        let none = CourtSessionSummary(session: withoutLedger)
        XCTAssertNil(none.shotCount, "No ledger: the count is unknown, not 0")
        XCTAssertNil(none.maximumSpeed); XCTAssertNil(none.averageSpeed)
        XCTAssertTrue(none.strokes.isEmpty)
        XCTAssertEqual(none.speedCount, 0)
        XCTAssertEqual(none.duration, 30, accuracy: 1e-6)

        var noSpeeds = withoutLedger
        noSpeeds.mergeRemoteTennisEvents([TennisShotEvent(streamID: UUID(), sourcePTS: 1, stroke: .forehand, confidence: 0.5, speedKPH: nil)])
        let summary = CourtSessionSummary(session: noSpeeds)
        XCTAssertEqual(summary.shotCount, 1)
        XCTAssertNil(summary.maximumSpeed); XCTAssertNil(summary.averageSpeed)
    }
}
