import XCTest
import Foundation
@testable import CourtCore
@testable import CourtApp

/// Storage cleanup: sizes by kind, removing recordings while keeping records, never touching a
/// recording another kept record lists or a record in use, leftovers, and the retention setting.
final class StorageCleanupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("court-storage-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// A completed record with one recording of `bytes` (plus its timestamp file), ended `daysAgo`.
    private func record(_ store: SessionStore, _ name: String, bytes: Int, daysAgo: Double, file: String? = nil) throws -> CourtSession {
        let started = Date().addingTimeInterval(-daysAgo * 86_400 - 600)
        var session = CourtSession(title: name, startedAt: started)
        let filename = file ?? "Court-\(name).mov"
        let url = store.directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(count: bytes).write(to: url)
            try Data(count: 100).write(to: url.deletingPathExtension().appendingPathExtension("jsonl"))
        }
        try session.addRecording(StoredRecording(filename: filename, frames: 60, duration: 1, firstPTS: 0))
        session.finish(at: started.addingTimeInterval(600))
        try store.save(session)
        return session
    }

    func testClearingRecordingsKeepsRecordsAndSharedFiles() throws {
        let store = try SessionStore(directory: root)
        let cleanup = StorageCleanup(store: store)
        let old = try record(store, "old", bytes: 5000, daysAgo: 40)
        let recent = try record(store, "recent", bytes: 3000, daysAgo: 2)
        // A second record listing the old record's file (a mirror, or a split session).
        let sharer = try record(store, "sharer", bytes: 0, daysAgo: 1, file: "Court-old.mov")
        try Data(count: 200).write(to: root.appendingPathComponent("\(old.id.uuidString)-analysis.jsonl"))
        let clips = root.appendingPathComponent("Clips/\(recent.id.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try Data(count: 700).write(to: clips.appendingPathComponent("clip-a.mov"))
        let all = try store.loadAll(recoverUnfinished: false)

        let usage = cleanup.usage(sessions: all, canJudgeLeftovers: true)
        XCTAssertEqual(usage.recordings, 5000 + 100 + 3000 + 100)
        XCTAssertEqual(usage.recordingCount, 2)
        XCTAssertEqual(usage.logs, 200)
        XCTAssertEqual(usage.clips, 700)
        XCTAssertEqual(usage.leftovers, 0)

        // Older than 30 days: only "old", but "sharer" (kept) still lists its file, so nothing goes.
        let shared = cleanup.planRecordings(of: StorageCleanup.olderThan(30, in: all), all: all, inUse: [])
        XCTAssertTrue(shared.isEmpty, "A recording another kept record lists stays")
        // Both records that list it: the file goes once.
        let both = cleanup.planRecordings(of: all.filter { $0.id != recent.id }, all: all, inUse: [])
        XCTAssertEqual(both.filenames, ["Court-old.mov"])
        XCTAssertEqual(both.bytes, 5100)
        // A record in use is skipped and its file stays.
        let busy = cleanup.planRecordings(of: all, all: all, inUse: [recent.id])
        XCTAssertEqual(busy.skipped, [recent.id])
        XCTAssertFalse(busy.filenames.contains("Court-recent.mov"))

        XCTAssertEqual(try cleanup.clearRecordings(both), 5100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Court-old.mov").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Court-old.jsonl").path))
        let after = try store.loadAll(recoverUnfinished: false)
        XCTAssertEqual(Set(after.map(\.id)), Set([old.id, recent.id, sharer.id]), "Records stay")
        XCTAssertEqual(after.first { $0.id == old.id }?.recordings.count, 1, "The record still lists the recording")
        XCTAssertNotNil(cleanup.clearedRecordings()["Court-old.mov"], "Marked as cleared, not lost")
        XCTAssertNil(cleanup.clearedRecordings()["Court-recent.mov"])
        XCTAssertEqual(cleanup.usage(sessions: after, canJudgeLeftovers: true).recordings, 3100)

        XCTAssertEqual(try cleanup.clearClips(inUse: []), 700)
        XCTAssertEqual(try cleanup.clearLogs(inUse: []), 200)
        let final = cleanup.usage(sessions: after, canJudgeLeftovers: true)
        XCTAssertEqual(final.clips + final.logs + final.leftovers, 0)
        XCTAssertGreaterThan(final.data, 0, "Session JSON and the cleared ledger remain")
    }

    func testLeftoversAreFilesNoRecordLists() throws {
        let store = try SessionStore(directory: root)
        let cleanup = StorageCleanup(store: store)
        let kept = try record(store, "kept", bytes: 1000, daysAgo: 1)
        try Data(count: 400).write(to: root.appendingPathComponent("Court-crash.mov"))     // a crash before the JSON listed it
        try Data(count: 300).write(to: root.appendingPathComponent(".Court-x.mov.part"))  // an interrupted transfer
        let gone = UUID().uuidString
        try Data(count: 50).write(to: root.appendingPathComponent("\(gone)-status.jsonl")) // log of a deleted record
        let orphanClips = root.appendingPathComponent("Clips/\(gone.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanClips, withIntermediateDirectories: true)
        try Data(count: 25).write(to: orphanClips.appendingPathComponent("clip-b.mov"))
        try Data(count: 10).write(to: root.appendingPathComponent("hawk-eye.json"))         // settings are data
        let all = try store.loadAll(recoverUnfinished: false)

        XCTAssertEqual(cleanup.usage(sessions: all, canJudgeLeftovers: true).leftovers, 400 + 300 + 50)
        XCTAssertEqual(cleanup.usage(sessions: all, canJudgeLeftovers: false).leftovers, 0, "Not judged while recording")
        XCTAssertEqual(cleanup.leftoverBytes(sessions: all), 400 + 300 + 50 + 25)
        XCTAssertEqual(try cleanup.clearLeftovers(sessions: all), 775)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Court-kept.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("hawk-eye.json").path))
        XCTAssertEqual(try store.loadAll(recoverUnfinished: false).map(\.id), [kept.id])
    }

    @MainActor func testRetentionClearsOldRecordingsOnly() async throws {
        let store = try SessionStore(directory: root)
        _ = try record(store, "month", bytes: 2000, daysAgo: 40)
        _ = try record(store, "week", bytes: 1000, daysAgo: 3)
        let model = WorkspaceModel(storageDirectory: root)
        defer { UserDefaults.standard.removeObject(forKey: "court.storage.recordingRetentionDays") }
        model.reloadHistory()
        XCTAssertEqual(model.recordingCleanupPlan(model.recordsWithRecordings(olderThan: 30)).filenames, ["Court-month.mov"])
        model.recordingRetentionDays = 30
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Court-month.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Court-week.mov").path))
        XCTAssertNotNil(model.recordingCleared("Court-month.mov"))
        XCTAssertEqual(model.history.count, 2, "Both records stay")
        XCTAssertTrue(model.notice?.contains("自动清理") == true, model.notice ?? "")
        await model.shutdown()
    }
}
