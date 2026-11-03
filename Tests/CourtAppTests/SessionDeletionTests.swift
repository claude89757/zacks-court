#if os(macOS)
import XCTest
import Foundation
@testable import CourtCore
@testable import CourtApp

/// Deleting a saved record removes its JSON, recordings with their timestamp logs and partial
/// transfers, the detection and camera-status logs and fetched clips, on this device only, and
/// never touches another session or an open one.
final class SessionDeletionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] }

    @MainActor func testDeletingASavedSessionRemovesItsFilesOnly() throws {
        let root = makeRoot()
        let store = try SessionStore(directory: root)
        let doomed = try saved(store, title: "要删的记录", recording: "Court-doomed.mov")
        let kept = try saved(store, title: "保留的记录", recording: "Court-kept.mov")
        let doomedFiles = files(for: doomed, recording: "Court-doomed.mov", in: root)
        let keptFiles = files(for: kept, recording: "Court-kept.mov", in: root)
        for url in doomedFiles + keptFiles where !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3])))
        }

        let model = WorkspaceModel(storageDirectory: root)
        XCTAssertEqual(Set(model.history.map(\.id)), [doomed.id, kept.id])
        XCTAssertNil(model.deletionBlocker(doomed))
        XCTAssertTrue(model.deleteSession(doomed))
        XCTAssertNil(model.error)

        for url in doomedFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "left behind: \(url.lastPathComponent)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.clipsDirectory(id: doomed.id).path), "the clip folder goes too")
        for url in keptFiles { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "other session touched: \(url.lastPathComponent)") }
        XCTAssertEqual(model.history.map(\.id), [kept.id])
        XCTAssertEqual(try store.loadAll().map(\.id), [kept.id])
        XCTAssertNotNil(model.notice)
    }

    /// A mirror whose recording stayed on the camera has no local files beyond its JSON.
    @MainActor func testDeletingAMirrorWithoutLocalRecordingSucceeds() throws {
        let root = makeRoot()
        let store = try SessionStore(directory: root)
        let mirror = try saved(store, title: "机位上的录像", recording: "Court-on-camera.mov")
        let model = WorkspaceModel(storageDirectory: root)
        XCTAssertTrue(model.deleteSession(mirror))
        XCTAssertTrue(try store.loadAll().isEmpty)
    }

    @MainActor func testOpenSessionsCannotBeDeleted() throws {
        let root = makeRoot()
        let store = try SessionStore(directory: root)
        var open = CourtSession(title: "进行中")
        try store.save(open)
        let model = WorkspaceModel(storageDirectory: root)
        // The launch load recovers an unfinished file as interrupted; a live one is still active.
        model.session = open
        XCTAssertNotNil(model.deletionBlocker(open))
        XCTAssertFalse(model.deleteSession(open))
        XCTAssertNotNil(model.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionFileURL(id: open.id).path))
        open.pause()
        XCTAssertNotNil(model.deletionBlocker(open), "A paused record is still open")
    }

    /// The camera forgets a finished session it is deleting, so a late checkpoint or a display
    /// that connects later cannot write it back.
    @MainActor func testCameraForgetsTheFinishedSessionItDeletes() async throws {
        let root = makeRoot()
        let rig = CameraRig(root: root)
        rig.camera.startSession(title: "机位记录")
        let id = try XCTUnwrap(rig.camera.session?.id)
        XCTAssertFalse(rig.camera.forgetFinishedSession(id), "An open session is never forgotten")
        await rig.camera.finish()
        XCTAssertTrue(rig.camera.forgetFinishedSession(id))
        XCTAssertNil(rig.camera.session)
        let store = try SessionStore(directory: root)
        let session = try XCTUnwrap(store.loadAll().first { $0.id == id })
        try store.delete(session)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionFileURL(id: id).path))
        await rig.close()
    }

    private func saved(_ store: SessionStore, title: String, recording: String) throws -> CourtSession {
        var session = CourtSession(title: title)
        try session.addRecording(StoredRecording(filename: recording, frames: 60, duration: 1, firstPTS: 0))
        session.finish()
        try store.save(session)
        return session
    }

    private func files(for session: CourtSession, recording: String, in root: URL) -> [URL] {
        let id = session.id.uuidString
        return [root.appendingPathComponent("\(id).json"),
                root.appendingPathComponent(recording),
                root.appendingPathComponent(recording).deletingPathExtension().appendingPathExtension("jsonl"),
                root.appendingPathComponent(".\(recording).part"),
                root.appendingPathComponent("\(id)-analysis.jsonl"),
                CameraStatusLog.url(directory: root, session: session.id),
                root.appendingPathComponent("Clips/\(id.lowercased())/clip-\(UUID().uuidString.lowercased()).mov")]
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("court-delete-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }
}
#endif
