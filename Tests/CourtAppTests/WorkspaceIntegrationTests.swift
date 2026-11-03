#if os(macOS)
import XCTest
import Foundation
import AVFoundation
import Network
@testable import CourtCore
@testable import CourtApp

/// Protocol v2 over real TLS on localhost: an in-process camera (`CameraSessionController` fed by
/// labelled synthetic frames) and the app's display model. Shot rows are injected through a test
/// seam, so these tests prove the data flow, never tennis accuracy.
final class WorkspaceIntegrationTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] }

    @MainActor func testCameraAdoptsDisplaySessionMirrorsResyncsAndRecordsPlayableClips() async throws {
        let root = makeRoot("court-v2")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let rig = CameraRig(root: root.appendingPathComponent("camera"))
        do {
            display.selectRole(.server)
            try await waitFor("display pairing ticket", timeout: 10) { !display.pairingURL.isEmpty }
            // A display-local session before any camera joins keeps its marker after adoption.
            display.sessionTitle = "Synthetic camera-side integration"
            display.startSession()
            display.markEvent("手动训练标记")
            let owner = try XCTUnwrap(display.session?.id)
            XCTAssertFalse(display.cameraOwnsSession)

            rig.camera.pair(try localTicket(display))
            try await waitFor("camera adopts the display session", timeout: 10) {
                rig.camera.session?.id == owner && display.cameraOwnsSession && display.connected
            }
            XCTAssertEqual(rig.camera.session?.events.filter { $0.kind == .marker }.count, 1)
            XCTAssertEqual(display.session?.capturedOn, "测试机位（合成画面）")

            rig.source.start()
            try await waitFor("camera live and recording", timeout: 10) { display.isLive && display.isRecording }
            let stream = try XCTUnwrap(rig.camera.streamID)
            let start = try XCTUnwrap(rig.camera.counters.latestPTS)
            var rows = [TennisShotEvent(streamID: stream, sourcePTS: start + 0.5, stroke: .forehand, confidence: 0.7),
                        TennisShotEvent(streamID: stream, sourcePTS: start + 1.2, stroke: .backhand, confidence: 0.6)]
            rig.camera.testingDeliver(Self.snapshot(stream, rows))
            try await waitFor("rows mirrored", timeout: 5) { display.session?.tennisEvents?.count == 2 }

            // The display leaves (backgrounds); the camera keeps recording and analysing.
            await display.setForeground(false)
            XCTAssertEqual(display.session?.state, .active, "A camera-owned session must not pause when the display leaves")
            XCTAssertFalse(display.connected)
            try await waitFor("camera notices the display left", timeout: 5) { rig.camera.linkState != .connected }
            rows[0].speedKPH = 101
            rows.append(TennisShotEvent(streamID: stream, sourcePTS: start + 2, stroke: .serve, confidence: 0.8))
            rig.camera.testingDeliver(Self.snapshot(stream, rows))
            XCTAssertEqual(rig.camera.session?.tennisEvents?.count, 3)
            XCTAssertEqual(rig.camera.session?.state, .active)

            await display.setForeground(true)
            try await waitFor("reconnect resync fills the gap", timeout: 20) {
                display.connected && display.session?.tennisEvents?.count == 3 &&
                    display.session?.tennisEvents?.first?.speedKPH == 101
            }
            // A late bounce update for a published row reaches the mirror as one changed row.
            var late = rows[1]; late.bounce = TennisBounceEstimate(sourcePTS: late.sourcePTS + 0.4, confidence: 0.5, reason: "测试")
            rig.camera.testingDeliverLate([late])
            try await waitFor("late bounce mirrored", timeout: 5) { display.session?.tennisEvents?[1].bounce != nil }

            display.pauseOrResume()
            try await waitFor("camera paused with first clip", timeout: 10) {
                rig.camera.session?.state == .paused && display.session?.state == .paused &&
                    display.session?.recordings.count == 1 && !rig.camera.isBusy && display.pendingCommand == nil
            }
            let pausedElapsed = try XCTUnwrap(display.session?.elapsed())
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(display.session?.elapsed() ?? -1, pausedElapsed, accuracy: 0.001)
            display.pauseOrResume()
            try await waitFor("resumed second recording", timeout: 10) {
                rig.camera.session?.state == .active && (rig.camera.counters.recordingSeconds ?? 0) >= 0.6
            }
            await display.finishSession()
            try await waitFor("completed with two clips", timeout: 15) {
                display.session?.state == .completed && display.session?.recordings.count == 2
            }
            XCTAssertNil(display.error)
            XCTAssertNil(rig.camera.error)
            // The end-of-record summary on both ends, from the saved ledger.
            try await waitFor("summary has the resent ledger", timeout: 10) { display.finishedRecord?.shotCount == 3 }
            XCTAssertEqual(display.finishedRecord?.sessionID, owner)
            XCTAssertEqual(rig.camera.finishedSessionID, owner)

            let cameraCopy = try XCTUnwrap(try SessionStore(directory: rig.root).loadAll(recoverUnfinished: false).first { $0.id == owner })
            XCTAssertEqual(cameraCopy.state, .completed)
            XCTAssertEqual(cameraCopy.tennisEvents?.count, 3)
            XCTAssertEqual(cameraCopy.recordings.count, 2)
            for recording in cameraCopy.recordings {
                XCTAssertEqual(recording.streamID, stream)
                XCTAssertGreaterThanOrEqual(recording.firstPTS, 2_000)
                let decoded = try await decodeMovie(rig.root.appendingPathComponent(recording.filename))
                XCTAssertEqual(decoded, recording.frames, "Every saved compressed frame must decode")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("\(owner.uuidString)-analysis.jsonl").path) ||
                          (cameraCopy.analysis.analyzedFrames == 0), "Person samples, when taken, are journaled on the camera")
            display.reloadHistory()
            let mirrored = try XCTUnwrap(display.history.first { $0.id == owner })
            XCTAssertEqual(mirrored.state, .completed)
            XCTAssertEqual(mirrored.tennisEvents?.map(\.id), cameraCopy.tennisEvents?.map(\.id))
            XCTAssertEqual(mirrored.recordingFilenames, cameraCopy.recordingFilenames)
            XCTAssertEqual(mirrored.events.filter { $0.kind == .marker }.count, 1)
            // Recordings stay on the camera until transferred; the display must not resolve them.
            XCTAssertFalse(FileManager.default.fileExists(atPath: display.recordingURL(filename: mirrored.recordings[0].filename).path))
            // The display kept the camera's status once a second while the camera owned the session,
            // with a disconnected line for the time it was in the background.
            display.statusLog.flush()
            let lines = try String(contentsOf: display.statusFileURL(mirrored), encoding: .utf8).split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            XCTAssertGreaterThanOrEqual(lines.filter { $0["connected"] as? Bool == true && $0["fps"] != nil }.count, 2)
            XCTAssertEqual(lines.filter { $0["connected"] as? Bool == false }.count, 1, "One line for the background disconnect")
            XCTAssertTrue(lines.allSatisfy { $0["t"] is Double })
        } catch {
            await rig.close(); await display.shutdown(); throw error
        }
        await rig.close(); await display.shutdown()
    }

    @MainActor func testCameraSessionWinsConflictAndStandaloneSessionPersists() async throws {
        let root = makeRoot("court-conflict")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let rig = CameraRig(root: root.appendingPathComponent("camera"))
        do {
            // Standalone camera session with analysis rows, no display.
            rig.camera.startSession(title: "机位独立记录")
            rig.source.start()
            try await waitFor("standalone recording", timeout: 10) { rig.camera.counters.recording }
            let stream = try XCTUnwrap(rig.camera.streamID), start = try XCTUnwrap(rig.camera.counters.latestPTS)
            let rows = [TennisShotEvent(streamID: stream, sourcePTS: start + 0.3, stroke: .serve, confidence: 0.9)]
            rig.camera.testingDeliver(Self.snapshot(stream, rows))
            let cameraSession = try XCTUnwrap(rig.camera.session?.id)

            display.selectRole(.server)
            try await waitFor("display ticket", timeout: 10) { !display.pairingURL.isEmpty }
            display.sessionTitle = "看板本地会话"; display.startSession(); display.markEvent("精彩")
            let local = try XCTUnwrap(display.session?.id)
            rig.camera.pair(try localTicket(display))
            try await waitFor("camera session replaces the local one", timeout: 10) {
                display.session?.id == cameraSession && display.session?.tennisEvents?.count == 1
            }
            XCTAssertNotNil(display.notice)
            XCTAssertEqual(rig.camera.session?.id, cameraSession)
            let stored = try SessionStore(directory: display.storageDirectory).loadAll(recoverUnfinished: false)
            let closed = try XCTUnwrap(stored.first { $0.id == local })
            XCTAssertEqual(closed.state, .completed)
            XCTAssertEqual(closed.events.filter { $0.kind == .marker }.count, 1)

            // Finishing on the camera completes the display mirror too.
            await rig.camera.finish()
            try await waitFor("display sees completion", timeout: 10) { display.session?.state == .completed && display.session?.recordings.count == 1 }
            XCTAssertEqual(display.finishedRecord?.sessionID, cameraSession, "A record the camera finished gets its summary on the display")
        } catch {
            await rig.close(); await display.shutdown(); throw error
        }
        await rig.close(); await display.shutdown()
    }

    @MainActor func testBackgroundDuringPauseFinishesSaveAndKeepsPairing() async throws {
        let root = makeRoot("court-background")
        let model = WorkspaceModel(storageDirectory: root)
        do {
            model.selectRole(.server)
            try await waitFor("initial listener", timeout: 8) { !model.pairingURL.isEmpty }
            let firstService = try PairingTicket.parse(model.pairingURL).service
            model.startSession()
            let owner = try XCTUnwrap(model.session?.id)
            model.pauseOrResume()
            XCTAssertEqual(model.session?.state, .paused)
            await model.setForeground(false)
            try await waitFor("background shutdown", timeout: 8) { !model.isBusy && model.pairingURL.isEmpty }
            XCTAssertFalse(model.connected)
            XCTAssertEqual(model.session?.state, .paused)
            let elapsed = try XCTUnwrap(model.session?.elapsed())
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(model.session?.elapsed() ?? -1, elapsed, accuracy: 0.001)
            await model.setForeground(true)
            try await waitFor("listener back on foreground", timeout: 8) { !model.pairingURL.isEmpty }
            // The same ticket comes back so a camera that holds it can reconnect by itself.
            XCTAssertEqual(try PairingTicket.parse(model.pairingURL).service, firstService)
            XCTAssertEqual(model.session?.id, owner)
            XCTAssertEqual(model.session?.state, .paused)
            let stored = try SessionStore(directory: root).loadAll(recoverUnfinished: false)
            XCTAssertEqual(stored.first?.state, .paused)
            XCTAssertEqual(stored.first?.elapsed() ?? -1, elapsed, accuracy: 0.001)
            // A display-local session still pauses on background when no camera has joined.
            model.pauseOrResume()
            await model.setForeground(false)
            XCTAssertEqual(model.session?.state, .paused)
            await model.setForeground(true)
        } catch {
            await model.shutdown(); throw error
        }
        await model.shutdown()
    }

    /// A v1 display (or any other version) is terminal for the camera link: no reconnect loop.
    @MainActor func testCameraLinkStopsOnVersionMismatchAndWhenSuperseded() async throws {
        let server = CourtServer()
        let ticket = try PairingTicket(name: "Mismatch")
        let resolved: PairingTicket = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            server.onListening = { if once.take() { continuation.resume(returning: $0) } }
            server.onError = { if once.take() { continuation.resume(throwing: CourtError.message($0)) } }
            server.start(ticket: ticket)
        }
        var local = resolved; local.host = "127.0.0.1"
        server.onConnected = {
            var old = StreamHeader(kind: "hello"); old.version = 1
            server.send(StreamPacket(header: old))
        }
        let states = StateLog()
        let link = CameraLink(ticket: local)
        link.onState = { states.add($0) }
        link.start()
        try await waitFor("terminal mismatch", timeout: 10) { states.terminal != nil }
        XCTAssertTrue(states.terminal?.contains("v1") == true, states.terminal ?? "")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(states.connectingCount, 1, "A version mismatch must not be retried")
        link.stop()

        // Two cameras on one ticket: the newer one stays, the older one stops retrying.
        server.onConnected = nil
        let first = StateLog(), second = StateLog()
        let a = CameraLink(ticket: local), b = CameraLink(ticket: local)
        a.onState = { first.add($0) }; b.onState = { second.add($0) }
        a.start()
        try await waitFor("first camera connected", timeout: 10) { first.connected }
        b.start()
        try await waitFor("older camera superseded", timeout: 10) { first.terminal != nil }
        XCTAssertTrue(second.connected)
        a.stop(); b.stop(); server.stop()
    }

    /// Optional real-video acceptance: the camera analyses a local tennis video with the real
    /// models in-process and the display mirrors it. No network fetch, no generated tennis facts.
    @MainActor func testRealTennisVideoAnalysedOnCameraMirrorsToDisplay() async throws {
        guard ReferenceChain.isAvailable, let videoPath = ProcessInfo.processInfo.environment["COURT_TEST_VIDEO"],
              let models = AnalysisModelLocator.directory else {
            throw XCTSkip("Set COURT_TEST_VIDEO and COURT_ANALYSIS_MODELS_DIR for real model acceptance.")
        }
        let root = makeRoot("court-tennis")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let rig = CameraRig(root: root.appendingPathComponent("camera"), configuration: TennisAnalysisConfiguration(modelDirectory: models), synthetic: false)
        do {
            display.selectRole(.server)
            try await waitFor("display ticket", timeout: 10) { !display.pairingURL.isEmpty }
            display.sessionTitle = "Real video camera-side validation"; display.startSession()
            rig.camera.pair(try localTicket(display))
            try await waitFor("adopted", timeout: 10) { display.cameraOwnsSession }
            let file = try await FileFrameSource(pipeline: rig.pipeline, video: URL(fileURLWithPath: videoPath))
            let done = Once()
            file.onFinished = { _ in _ = done.take() }
            file.start()
            try await waitFor("real model shot events mirrored", timeout: 60) { !(display.session?.tennisEvents ?? []).isEmpty }
            try await waitFor("replay end", timeout: max(45, file.duration * 2 + 30)) { done.used }
            try await waitFor("capture end pauses", timeout: 20) { display.session?.state == .paused && !rig.camera.isBusy }
            await display.finishSession()
            try await waitFor("completed", timeout: 15) { display.session?.state == .completed }
            let shots = try XCTUnwrap(display.session?.tennisEvents)
            XCTAssertEqual(shots.map(\.id), rig.camera.session?.tennisEvents?.map(\.id))
            XCTAssertEqual(Set(shots.map(\.id)).count, shots.count, "Stable-ID updates must not count a shot twice")
            XCTAssertTrue(shots.allSatisfy { $0.sourcePTS.isFinite && $0.sourcePTS >= 0 })
            XCTAssertEqual(display.session?.tennisModelVersion, "S家-local-live-v1")
            var reasons: [String: Int] = [:]
            for shot in shots where shot.bounce?.xMeters == nil { reasons[shot.bounce?.reason ?? "无触地候选", default: 0] += 1 }
            print("REAL_TENNIS_CAMERA shots=\(shots.count) speeds=\(shots.filter { $0.speedKPH != nil }.count) landings=\(shots.filter { $0.bounce?.xMeters != nil }.count) bounces=\(shots.filter { $0.bounce != nil }.count) calibration=\(display.session?.tennisCalibration?.isAvailable == true) reasons=\(reasons.sorted { $0.value > $1.value })")
        } catch {
            await rig.close(); await display.shutdown(); throw error
        }
        await rig.close(); await display.shutdown()
    }

    // MARK: Helpers

    private func makeRoot(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        roots.append(url); return url
    }
    @MainActor private func localTicket(_ display: WorkspaceModel) throws -> PairingTicket {
        var ticket = try PairingTicket.parse(display.pairingURL); ticket.host = "127.0.0.1"; return ticket
    }
    static func snapshot(_ stream: UUID, _ events: [TennisShotEvent]) -> TennisAnalysisSnapshot {
        TennisAnalysisSnapshot(streamID: stream, pts: events.map(\.sourcePTS).max() ?? 0, processedFrames: 1, inferenceMilliseconds: 1,
                               events: events, calibration: TennisCourtCalibrationState(), modelVersion: "test", limitations: [])
    }
    @MainActor private func waitFor(_ condition: String, timeout: Double, predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw IntegrationFailure.timeout(condition) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private func decodeMovie(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? IntegrationFailure.decode }
        var count = 0, previous = -Double.infinity
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            XCTAssertGreaterThan(pts, previous); previous = pts
            count += 1
        }
        guard reader.status == .completed else { throw reader.error ?? IntegrationFailure.decode }
        return count
    }
}

/// In-process camera: pipeline, controller and a labelled synthetic frame source.
@MainActor final class CameraRig {
    let root: URL
    let pipeline = CameraMediaPipeline(queue: DispatchQueue(label: "court.test.camera", qos: .userInitiated))
    let camera: CameraSessionController
    let source: SyntheticFrameSource
    init(root: URL, configuration: TennisAnalysisConfiguration? = nil, synthetic: Bool = true) {
        self.root = root
        camera = CameraSessionController(storageDirectory: root, configuration: configuration,
                                         identity: CameraIdentity(device: synthetic ? "测试机位（合成画面）" : "测试机位（录像回放）", hardware: "test", app: "test"),
                                         pipeline: pipeline)
        source = SyntheticFrameSource(pipeline: pipeline)
    }
    func close() async { source.stop(); await camera.shutdown() }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [CameraLink.State] = []
    func add(_ state: CameraLink.State) { lock.lock(); states.append(state); lock.unlock() }
    var terminal: String? {
        lock.lock(); defer { lock.unlock() }
        for state in states { if case .failed(let reason) = state { return reason } }
        return nil
    }
    var connected: Bool { lock.lock(); defer { lock.unlock() }; return states.contains(.connected) }
    var connectingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return states.filter { if case .connecting = $0 { return true } else { return false } }.count
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    var used: Bool { lock.lock(); defer { lock.unlock() }; return done }
}

private enum IntegrationFailure: LocalizedError {
    case timeout(String), decode
    var errorDescription: String? {
        switch self {
        case .timeout(let condition): return "Integration test timed out waiting for \(condition)."
        case .decode: return "Saved movie could not be decoded."
        }
    }
}
#endif
