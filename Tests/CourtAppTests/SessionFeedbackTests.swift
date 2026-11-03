#if os(macOS)
import XCTest
import SwiftUI
import CourtCore
@testable import CourtApp

/// End-of-record summary, notices and haptic triggers on the display model. The camera end of the
/// summary (finishing on the camera, mirrored over TLS) is covered by the integration tests.
final class SessionFeedbackTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] }
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("court-feedback-\(UUID().uuidString)", isDirectory: true)
        roots.append(root); return root
    }

    /// The card appears when the mirrored record turns from open to completed, shows only saved
    /// values, and goes away when closed or when the next record opens.
    @MainActor func testSummaryFollowsTheFinishedRecordUntilClosedOrReplaced() throws {
        let model = WorkspaceModel(storageDirectory: makeRoot())
        var record = CourtSession(title: "周四晚")
        model.session = record
        XCTAssertNil(model.finishedRecord, "No card while the record is open")
        record.mergeRemoteTennisEvents([
            TennisShotEvent(streamID: UUID(), sourcePTS: 1, stroke: .serve, confidence: 0.9, speedKPH: 140),
            TennisShotEvent(streamID: UUID(), sourcePTS: 2, stroke: .forehand, confidence: 0.9, speedKPH: nil),
        ])
        record.finish()
        model.session = record
        let summary = try XCTUnwrap(model.finishedRecord)
        XCTAssertEqual(summary.title, "周四晚")
        XCTAssertEqual(summary.shotCount, 2)
        XCTAssertEqual(summary.maximumSpeed, 140)
        XCTAssertEqual(summary.averageSpeed, 140, "The shot without a speed is not averaged in as 0")

        model.dismissFinishedRecord()
        XCTAssertNil(model.finishedRecord, "Closed")

        // The next record finishes: its card shows, then a new record replaces it.
        var next = CourtSession(title: "周五")
        model.session = next
        next.finish(); model.session = next
        XCTAssertEqual(model.finishedRecord?.title, "周五")
        model.session = CourtSession(title: "周六")
        XCTAssertNil(model.finishedRecord, "A new record replaces the previous summary")
    }

    /// While the summary card shows, the panels and boards keep the finished record's shots (and say
    /// so) instead of going blank; closing the card or starting a record clears them.
    @MainActor func testFinishedRecordShotsStayUntilTheCardGoes() throws {
        let model = WorkspaceModel(storageDirectory: makeRoot())
        var record = CourtSession(title: "周四晚")
        model.session = record
        XCTAssertNil(model.finishedRecordShots)
        XCTAssertEqual(model.shownEventsStatus.text, "未连接机位")
        record.mergeRemoteTennisEvents([
            TennisShotEvent(streamID: UUID(), sourcePTS: 1, stroke: .serve, confidence: 0.9, speedKPH: 140),
            TennisShotEvent(streamID: UUID(), sourcePTS: 2, stroke: .forehand, confidence: 0.9, speedKPH: nil),
        ])
        record.finish()
        model.session = record
        XCTAssertEqual(model.shownEvents.count, 2, "The finished record's shots stay on the display")
        XCTAssertEqual(model.finishedRecordShots?.title, "周四晚")
        XCTAssertEqual(model.shownEventsStatus.text, "上一次记录「周四晚」")

        model.dismissFinishedRecord()
        XCTAssertNil(model.finishedRecordShots)
        XCTAssertTrue(model.shownEvents.isEmpty, "Closing the summary clears them")

        var next = CourtSession(title: "周五")
        model.session = next
        next.mergeRemoteTennisEvents([TennisShotEvent(streamID: UUID(), sourcePTS: 1, stroke: .serve, confidence: 0.9, speedKPH: 120)])
        next.finish(); model.session = next
        XCTAssertEqual(model.shownEvents.count, 1)
        model.session = CourtSession(title: "周六")
        XCTAssertNil(model.finishedRecordShots, "A new record clears the previous record's shots")
    }

    /// A completed record the display only learns about (a camera reconnecting with its last
    /// record) did not just finish here: no card.
    @MainActor func testACompletedRecordSeenFirstIsNotASummary() {
        let model = WorkspaceModel(storageDirectory: makeRoot())
        var record = CourtSession(title: "早先的记录")
        record.finish()
        model.session = record
        XCTAssertNil(model.finishedRecord)
    }

    @MainActor func testNoticesGoAwayAfterAReadingTime() async throws {
        XCTAssertEqual(WorkspaceModel.noticeLifetime("短"), 6)
        XCTAssertEqual(WorkspaceModel.noticeLifetime(String(repeating: "字", count: 60)), 12)
        XCTAssertEqual(WorkspaceModel.noticeLifetime(String(repeating: "字", count: 400)), 20)
        let model = WorkspaceModel(storageDirectory: makeRoot())
        model.notice = "离线补算完成"
        XCTAssertEqual(model.notice, "离线补算完成")
        // A newer notice restarts the clock; the old timer must not clear it.
        try await Task.sleep(for: .seconds(1))
        model.notice = "已删除"
        XCTAssertEqual(model.notice, "已删除")
    }

    func testHapticsFollowConfirmedRecordChanges() {
        var session = CourtSession(title: "触感")
        let none = RecordFeedbackKey(nil)
        let started = RecordFeedbackKey(session)
        XCTAssertEqual(RecordFeedbackKey.feedback(from: none, to: started), .impact(weight: .medium), "A new record started")
        XCTAssertNil(RecordFeedbackKey.feedback(from: none, to: RecordFeedbackKey(session, now: Date().addingTimeInterval(600))),
                     "Joining a record that has been running is not a start")
        session.addMarker("精彩")
        let marked = RecordFeedbackKey(session)
        XCTAssertEqual(RecordFeedbackKey.feedback(from: started, to: marked), .success)
        XCTAssertNil(RecordFeedbackKey.feedback(from: marked, to: marked), "Nothing changed")
        session.pause()
        let paused = RecordFeedbackKey(session)
        XCTAssertEqual(RecordFeedbackKey.feedback(from: marked, to: paused), .impact(weight: .light))
        session.resume()
        XCTAssertEqual(RecordFeedbackKey.feedback(from: paused, to: RecordFeedbackKey(session)), .impact(weight: .medium))
        let resumed = RecordFeedbackKey(session)
        session.finish()
        XCTAssertEqual(RecordFeedbackKey.feedback(from: resumed, to: RecordFeedbackKey(session)), .impact(weight: .heavy))
    }
}
#endif
