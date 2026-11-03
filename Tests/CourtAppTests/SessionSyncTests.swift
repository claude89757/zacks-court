#if os(macOS)
import XCTest
import Foundation
@testable import CourtCore
@testable import CourtApp

/// Session state between the camera (the authority) and an app display over real TLS on
/// localhost: display commands wait for the camera, refusals leave nothing behind, a drifted
/// mirror repairs itself, and interrupted or finished-while-apart sessions reach the display.
/// Synthetic frames only; these tests prove the state flow, not recording quality.
final class SessionSyncTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] }

    @MainActor func testDisplayCommandsWaitForTheCameraAndRefusalsLeaveNothingBehind() async throws {
        let root = makeRoot("court-sync-commands")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let rig = CameraRig(root: root.appendingPathComponent("camera"))
        do {
            try await connect(display, rig)

            // A start that reaches a busy camera is refused: no display-only session is left.
            rig.camera.testingSetBusy(true)
            display.startSession()
            XCTAssertEqual(display.pendingCommand, .start, "The buttons lock at once")
            try await waitFor("start answered", timeout: 10) { display.pendingCommand == nil }
            XCTAssertNil(display.session)
            XCTAssertNil(rig.camera.session)
            XCTAssertEqual(try sessions(display).count, 0, "A refused start must not leave a session on the display")
            XCTAssertNotNil(display.error)
            // The camera pushes its busy state at once; the display's buttons wait for it.
            try await waitFor("display sees the camera busy", timeout: 3) { display.cameraBusy }
            XCTAssertTrue(display.sessionCommandsLocked)
            XCTAssertNotNil(display.sessionWaitReason)
            rig.camera.testingSetBusy(false)
            try await waitFor("camera free", timeout: 3) { !display.cameraBusy }
            display.error = nil

            // Accepted: the session exists once the camera adopted and echoed it.
            display.sessionTitle = "看板开始"
            display.startSession()
            try await waitFor("camera owns the started session", timeout: 10) {
                display.pendingCommand == nil && display.cameraOwnsSession && display.session?.id == rig.camera.session?.id
            }
            XCTAssertEqual(rig.camera.session?.title, "看板开始")
            XCTAssertEqual(try sessions(display).count, 1)
            rig.source.start()
            try await waitFor("recording", timeout: 10) { display.isRecording }

            // A finish the camera refuses keeps the session open on the display, with nothing queued.
            rig.camera.testingSetBusy(true)
            await display.finishSession()
            XCTAssertEqual(display.session?.state, .active, "The camera is still recording; the display must say so")
            XCTAssertEqual(rig.camera.session?.state, .active)
            XCTAssertTrue(display.pendingIntents.isEmpty, "A refused finish must not replay after a reconnect")
            XCTAssertNotNil(display.error)
            XCTAssertEqual(try sessions(display).first?.state, .active)
            // While the camera reports busy, the finish button does nothing at all.
            try await waitFor("display sees the camera busy", timeout: 3) { display.cameraBusy }
            await display.finishSession()
            XCTAssertEqual(display.session?.state, .active)
            rig.camera.testingSetBusy(false)
            try await waitFor("camera free", timeout: 3) { !display.cameraBusy }
            display.error = nil

            // Pause waits for the camera; a second tap meanwhile is ignored.
            display.pauseOrResume()
            XCTAssertEqual(display.pendingCommand, .pause)
            display.pauseOrResume()
            try await waitFor("paused on both", timeout: 15) {
                display.pendingCommand == nil && display.session?.state == .paused && rig.camera.session?.state == .paused
            }
            display.pauseOrResume()
            try await waitFor("resumed on both", timeout: 15) {
                display.pendingCommand == nil && display.session?.state == .active && rig.camera.session?.state == .active
            }
            let resumes = rig.camera.session?.events.filter { $0.kind == .resume }.count
            XCTAssertEqual(resumes, 1, "The ignored second tap sent nothing")

            await display.finishSession()
            XCTAssertEqual(display.session?.state, .completed)
            XCTAssertEqual(rig.camera.session?.state, .completed)
            XCTAssertNil(display.error)
        } catch {
            await rig.close(); await display.shutdown(); throw error
        }
        await rig.close(); await display.shutdown()
    }

    @MainActor func testDisplayRepairsADriftedMirrorFromTheCameraStatus() async throws {
        let root = makeRoot("court-sync-repair")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let rig = CameraRig(root: root.appendingPathComponent("camera"))
        do {
            try await connect(display, rig)
            display.startSession()
            try await waitFor("camera owns the session", timeout: 10) { display.pendingCommand == nil && display.cameraOwnsSession }
            try await waitFor("status reports the session", timeout: 5) { display.cameraStatus?.sessionState == .active }
            XCTAssertEqual(display.resyncRequests, 0)

            // The mirror drifts (as if a session update were lost): it shows paused, the camera is active.
            display.session?.pause()
            try await waitFor("mirror repaired", timeout: 10) { display.session?.state == .active }
            XCTAssertEqual(display.resyncRequests, 1, "One re-handshake repairs it")
            XCTAssertEqual(rig.camera.session?.state, .active, "Repairing never changes the camera")
            XCTAssertEqual(rig.camera.session?.events.filter { $0.kind == .pause }.count, 0)
            // Agreement holds afterwards: no further handshakes.
            try await Task.sleep(for: .seconds(3.5))
            XCTAssertEqual(display.resyncRequests, 1)
        } catch {
            await rig.close(); await display.shutdown(); throw error
        }
        await rig.close(); await display.shutdown()
    }

    @MainActor func testInterruptedCameraSessionResumesAndFinishesFromTheDisplay() async throws {
        let root = makeRoot("court-sync-interrupted")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let cameraRoot = root.appendingPathComponent("camera")
        let first = CameraRig(root: cameraRoot)
        var rigs: [CameraRig] = []
        do {
            try await connect(display, first)
            display.startSession()
            try await waitFor("camera owns the session", timeout: 10) { display.pendingCommand == nil && display.cameraOwnsSession }
            let owner = try XCTUnwrap(display.session?.id)

            // The camera app restarts mid-session: the old process is gone without finishing.
            first.camera.unpair()
            try await waitFor("display lost the camera", timeout: 5) { !display.connected }
            let restarted = CameraRig(root: cameraRoot); rigs.append(restarted)
            restarted.camera.pair(try localTicket(display))
            try await waitFor("interrupted session mirrored", timeout: 10) {
                display.connected && display.session?.id == owner && display.session?.state == .interrupted
            }
            XCTAssertEqual(restarted.camera.session?.state, .interrupted, "Recovered, not silently active without recording")
            XCTAssertTrue(display.hasControllableSession, "The display offers 继续/结束 like the camera does")
            XCTAssertFalse(display.hasActiveSession)

            // It restarts once more before anyone resumes: the display's handshake still brings the
            // interrupted session, so the camera recovers it from disk again.
            restarted.camera.unpair()
            try await waitFor("display lost the camera again", timeout: 5) { !display.connected }
            let third = CameraRig(root: cameraRoot); rigs.append(third)
            third.camera.pair(try localTicket(display))
            try await waitFor("interrupted session recovered again", timeout: 10) {
                display.connected && third.camera.session?.id == owner && third.camera.session?.state == .interrupted
            }
            XCTAssertEqual(display.session?.state, .interrupted)

            display.pauseOrResume()
            try await waitFor("resumed", timeout: 10) {
                display.pendingCommand == nil && display.session?.state == .active && third.camera.session?.state == .active
            }
            third.source.start()
            try await waitFor("recording again", timeout: 10) { display.isRecording }
            await display.finishSession()
            XCTAssertEqual(display.session?.state, .completed)
            XCTAssertEqual(third.camera.session?.state, .completed)
            try await waitFor("recording saved", timeout: 10) { display.session?.recordings.count == 1 }
        } catch {
            for rig in rigs.reversed() { await rig.close() }; await first.close(); await display.shutdown(); throw error
        }
        // The earlier processes "died": close them only now (their shutdown would finish the session).
        for rig in rigs.reversed() { await rig.close() }; await first.close(); await display.shutdown()
    }

    @MainActor func testSessionFinishedWhileApartReachesTheDisplayBeforeTheNewOne() async throws {
        let root = makeRoot("court-sync-apart")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let rig = CameraRig(root: root.appendingPathComponent("camera"))
        do {
            try await connect(display, rig)
            display.startSession()
            try await waitFor("camera owns the session", timeout: 10) { display.pendingCommand == nil && display.cameraOwnsSession }
            let first = try XCTUnwrap(display.session?.id)
            rig.source.start()
            try await waitFor("recording", timeout: 10) { display.isRecording }

            await display.setForeground(false)
            try await waitFor("camera notices", timeout: 5) { rig.camera.linkState != .connected }
            // Apart, the camera finishes that session (saving its recording) and starts another.
            await rig.camera.finish()
            rig.camera.startSession(title: "机位新记录")
            let second = try XCTUnwrap(rig.camera.session?.id)

            await display.setForeground(true)
            try await waitFor("display follows the camera's new session", timeout: 20) {
                display.connected && display.session?.id == second && display.session?.state == .active
            }
            let stored = try XCTUnwrap(try sessions(display).first { $0.id == first })
            XCTAssertEqual(stored.state, .completed)
            XCTAssertEqual(stored.recordings.count, 1, "The camera's finished copy, with its recording, reached the mirror")
            XCTAssertNil(display.notice, "Nothing open was closed on the display: the camera had already finished it")
        } catch {
            await rig.close(); await display.shutdown(); throw error
        }
        await rig.close(); await display.shutdown()
    }

    // MARK: Helpers

    @MainActor private func connect(_ display: WorkspaceModel, _ rig: CameraRig) async throws {
        display.selectRole(.server)
        try await waitFor("display pairing ticket", timeout: 10) { !display.pairingURL.isEmpty }
        rig.camera.pair(try localTicket(display))
        try await waitFor("connected with status", timeout: 10) { display.connected && display.cameraStatus != nil }
    }
    @MainActor private func sessions(_ display: WorkspaceModel) throws -> [CourtSession] {
        try SessionStore(directory: display.storageDirectory).loadAll(recoverUnfinished: false)
    }
    private func makeRoot(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        roots.append(url); return url
    }
    @MainActor private func localTicket(_ display: WorkspaceModel) throws -> PairingTicket {
        var ticket = try PairingTicket.parse(display.pairingURL); ticket.host = "127.0.0.1"; return ticket
    }
    @MainActor private func waitFor(_ condition: String, timeout: Double, predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SyncFailure.timeout(condition) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}

private enum SyncFailure: LocalizedError {
    case timeout(String)
    var errorDescription: String? { if case .timeout(let what) = self { return "Timed out waiting for \(what)." }; return nil }
}
#endif
