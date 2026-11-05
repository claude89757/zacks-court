#if os(macOS)
import XCTest
import Foundation
import AVFoundation
@testable import CourtCore
@testable import CourtApp

/// Phase 2: graded load shedding, recording transfer and offline backfill. Synthetic frames only
/// prove the software flow; nothing here measures heat, battery or tennis accuracy.
final class CameraPhase2Tests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] }

    func testLoadPolicyRisesAtOnceAndRecoversOneLevelPerMinute() {
        var policy = CameraLoadPolicy()
        XCTAssertFalse(policy.update(thermal: "nominal", pressure: "nominal", lowPower: false, now: 0))
        XCTAssertTrue(policy.update(thermal: "nominal", pressure: nil, lowPower: true, now: 1))
        XCTAssertEqual(policy.level, 1)
        XCTAssertTrue(policy.update(thermal: "critical", pressure: "serious", lowPower: false, now: 2))
        XCTAssertEqual(policy.level, 3)
        XCTAssertNotNil(policy.reason)
        // Cooling down: nothing for 60 s, then one level per further 60 s.
        XCTAssertFalse(policy.update(thermal: "nominal", pressure: nil, lowPower: false, now: 3))
        XCTAssertFalse(policy.update(thermal: "nominal", pressure: nil, lowPower: false, now: 62))
        XCTAssertTrue(policy.update(thermal: "nominal", pressure: nil, lowPower: false, now: 63))
        XCTAssertEqual(policy.level, 2)
        XCTAssertFalse(policy.update(thermal: "nominal", pressure: nil, lowPower: false, now: 100))
        // A spike while recovering applies at once and restarts the wait.
        XCTAssertTrue(policy.update(thermal: "critical", pressure: nil, lowPower: false, now: 101))
        XCTAssertEqual(policy.level, 3)
        for now in stride(from: 102.0, through: 400, by: 1) { policy.update(thermal: "nominal", pressure: nil, lowPower: false, now: now) }
        XCTAssertEqual(policy.level, 0)
        XCTAssertNil(policy.reason)
        XCTAssertEqual(CameraLoadPolicy.target(thermal: "nominal", pressure: "shutdown", lowPower: false).level, 4)
    }

    /// The camera reports AVFoundation's raw pressure values (seen on iPhone18,2 as
    /// `AVCaptureSystemPressureLevelNominal`); the policy must act on them, not only on short names.
    func testLoadPolicyReadsTheCameraRawPressureValues() {
        for (raw, level) in [("AVCaptureSystemPressureLevelNominal", 0), ("AVCaptureSystemPressureLevelFair", 1),
                             ("AVCaptureSystemPressureLevelSerious", 2), ("AVCaptureSystemPressureLevelCritical", 3),
                             ("AVCaptureSystemPressureLevelShutdown", 4)] {
            XCTAssertEqual(CameraLoadPolicy.target(thermal: "nominal", pressure: raw, lowPower: false).level, level, raw)
        }
        XCTAssertEqual(CameraLoadPolicy.target(thermal: "nominal", pressure: "AVCaptureSystemPressureLevelFair", lowPower: false).reason?.hasPrefix("机位相机负载偏高"), true)
        // Recovery keeps naming camera pressure, not heat, as the cause.
        var policy = CameraLoadPolicy()
        XCTAssertTrue(policy.update(thermal: "nominal", pressure: "AVCaptureSystemPressureLevelShutdown", lowPower: false, now: 0))
        XCTAssertEqual(policy.level, 4)
        XCTAssertFalse(policy.update(thermal: "nominal", pressure: "AVCaptureSystemPressureLevelNominal", lowPower: false, now: 1))
        XCTAssertTrue(policy.update(thermal: "nominal", pressure: "AVCaptureSystemPressureLevelNominal", lowPower: false, now: 61))
        XCTAssertEqual(policy.level, 3)
        XCTAssertEqual(policy.reason?.hasPrefix("机位相机负载过高"), true, policy.reason ?? "nil")
        // Heat-driven shedding still reads as heat while recovering.
        var heat = CameraLoadPolicy()
        heat.update(thermal: "serious", pressure: "AVCaptureSystemPressureLevelFair", lowPower: false, now: 0)
        heat.update(thermal: "nominal", pressure: nil, lowPower: false, now: 1)
        heat.update(thermal: "nominal", pressure: nil, lowPower: false, now: 61)
        XCTAssertEqual(heat.level, 1)
        XCTAssertEqual(heat.reason?.hasPrefix("机位偏暖"), true, heat.reason ?? "nil")
    }

    /// Analysis lag on a cool phone (2026-11-05: about 1.3 s behind on iPhone18,2, level never moved).
    /// Lag that stays above 1 s for 5 s sheds one level, another 5 s the next, never past L2; the
    /// reason names lag, not heat; once lag is low the usual 60 s per level brings it back.
    func testSustainedAnalysisLagShedsStepByStepAndRecovers() {
        var policy = CameraLoadPolicy()
        func tick(_ now: Double, lag: Double?, thermal: String = "nominal") -> Bool {
            policy.update(thermal: thermal, pressure: "AVCaptureSystemPressureLevelNominal", lowPower: false, analysisLag: lag, now: now)
        }
        XCTAssertFalse(tick(0, lag: 0.3))
        for now in 1...5 { XCTAssertFalse(tick(Double(now), lag: 1.3), "not before 5 s of lag (t=\(now))") }
        XCTAssertTrue(tick(6, lag: 1.3))
        XCTAssertEqual(policy.level, 1); XCTAssertEqual(policy.cause, .lag)
        let first = policy.reason
        XCTAssertEqual(first?.hasPrefix("实时分析跟不上画面"), true, first ?? "nil")
        for word in ["温度", "阴凉", "降温", "过热"] { XCTAssertFalse(first?.contains(word) ?? true, word) }
        // Still behind and not draining at L1: the next window sheds L2.
        for now in 7...10 { XCTAssertFalse(tick(Double(now), lag: 1.4)) }
        XCTAssertTrue(tick(11, lag: 1.4))
        XCTAssertEqual(policy.level, 2); XCTAssertEqual(policy.cause, .lag)
        XCTAssertEqual(policy.reason, CameraLoadPolicy.lagReason(level: 2))
        // Lag never pauses analysis: L3 would stop the very thing that is behind.
        for now in 12...120 { XCTAssertFalse(tick(Double(now), lag: 3)) }
        XCTAssertEqual(policy.level, 2)
        // Between 0.5 s and 1 s the demand holds: no recovery.
        for now in 121...300 { XCTAssertFalse(tick(Double(now), lag: 0.8)) }
        XCTAssertEqual(policy.level, 2)
        // Caught up: 60 s per level, still naming lag on the way down.
        XCTAssertFalse(tick(301, lag: 0.2))
        XCTAssertFalse(tick(360, lag: 0.2))
        XCTAssertTrue(tick(361, lag: 0.2))
        XCTAssertEqual(policy.level, 1); XCTAssertEqual(policy.cause, .lag)
        XCTAssertEqual(policy.reason, CameraLoadPolicy.lagReason(level: 1))
        XCTAssertFalse(tick(400, lag: 0))
        XCTAssertTrue(tick(421, lag: 0))
        XCTAssertEqual(policy.level, 0); XCTAssertNil(policy.reason); XCTAssertNil(policy.cause)
    }

    /// A short spike (a court solve holding the queue) or a backlog that is already draining does not
    /// shed; lag that cannot be measured (capture stopped, analysis paused) counts as low.
    func testShortOrDrainingLagDoesNotShedAndUnmeasuredLagRecovers() {
        var policy = CameraLoadPolicy()
        func tick(_ now: Double, lag: Double?) -> Bool {
            policy.update(thermal: "nominal", pressure: nil, lowPower: false, analysisLag: lag, now: now)
        }
        var now = 0.0
        for _ in 0..<10 { for lag in [2.0, 2.6, 1.9, 1.2, 0.3] { XCTAssertFalse(tick(now, lag: lag)); now += 1 } }
        // 3 s behind, catching up 0.1 s a second: the current level keeps up.
        for step in 0..<21 { XCTAssertFalse(tick(now, lag: 3 - Double(step) * 0.1)); now += 1 }
        XCTAssertEqual(policy.level, 0)
        // Flat lag sheds; then capture stops (no measurement) and the level recovers.
        for _ in 0...5 { _ = tick(now, lag: 1.5); now += 1 }
        XCTAssertEqual(policy.level, 1)
        XCTAssertFalse(tick(now, lag: nil))
        XCTAssertTrue(tick(now + 60, lag: nil))
        XCTAssertEqual(policy.level, 0)
    }

    /// Lag stacks on heat: warm (L1) and behind sheds L2 for lag. When lag clears while heat holds the
    /// level, the reason switches to heat; lag never adds a level to serious heat.
    func testAnalysisLagStacksOnHeatAndHandsTheReasonBack() {
        var policy = CameraLoadPolicy()
        XCTAssertTrue(policy.update(thermal: "fair", pressure: nil, lowPower: false, analysisLag: 1.5, now: 0))
        XCTAssertEqual(policy.level, 1); XCTAssertEqual(policy.cause, .heat)
        for now in 1...4 { policy.update(thermal: "fair", pressure: nil, lowPower: false, analysisLag: 1.5, now: Double(now)) }
        XCTAssertTrue(policy.update(thermal: "fair", pressure: nil, lowPower: false, analysisLag: 1.5, now: 5))
        XCTAssertEqual(policy.level, 2); XCTAssertEqual(policy.cause, .lag)
        XCTAssertFalse(policy.update(thermal: "serious", pressure: nil, lowPower: false, analysisLag: 1.5, now: 6))
        XCTAssertEqual(policy.cause, .lag)
        XCTAssertTrue(policy.update(thermal: "serious", pressure: nil, lowPower: false, analysisLag: 0.1, now: 7))
        XCTAssertEqual(policy.level, 2); XCTAssertEqual(policy.cause, .heat)
        XCTAssertEqual(policy.reason?.hasPrefix("机位温度偏高"), true, policy.reason ?? "nil")
        for now in 8...60 { policy.update(thermal: "serious", pressure: nil, lowPower: false, analysisLag: 2, now: Double(now)) }
        XCTAssertEqual(policy.level, 2, "lag does not take serious heat on to L3")
    }

    /// The camera page suggests cooling only when the phone is warm, and says the camera is catching up
    /// when it shed for lag; the capture log carries the cause.
    func testLagWarningAndLogNameTheCause() {
        let cool = CameraModel.lagWarning(1.3, shed: 0, cause: nil, thermal: .nominal)
        XCTAssertTrue(cool.hasPrefix("实时分析落后 1.3 秒"), cool)
        XCTAssertFalse(cool.contains("降温"), cool)
        XCTAssertTrue(CameraModel.lagWarning(1.3, shed: 1, cause: .lag, thermal: .nominal).contains("追赶"))
        XCTAssertTrue(CameraModel.lagWarning(1.3, shed: 0, cause: nil, thermal: .fair).contains("遮阳降温"))
        XCTAssertFalse(CameraModel.lagWarning(1.3, shed: 2, cause: .lag, thermal: .nominal).contains("降温"))

        var status = CameraStatus()
        status.shed = 1; status.shedReason = CameraLoadPolicy.lagReason(level: 1); status.shedCause = CameraLoadPolicy.Cause.lag.rawValue
        status.analysis.latestPTS = 10.3; status.analysis.analyzedPTS = 9
        let line = CameraLogLine(status: status, t: 0, shots: nil, display: false, browsers: 0, linkPath: nil)
        XCTAssertEqual(line.shed, 1); XCTAssertEqual(line.shedCause, "lag"); XCTAssertEqual(line.analysisDelay, 1.3)
        XCTAssertEqual(line.shedReason?.hasPrefix("实时分析跟不上画面"), true)
        let decoded = try? JSONDecoder().decode(CameraStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded?.shedCause, "lag")
    }

    @MainActor func testCriticalLoadPausesAnalysisRecordsAGapAndKeepsRecording() async throws {
        let rig = CameraRig(root: makeRoot("court-shed"))
        rig.camera.appliesLoadPolicy = false
        rig.camera.startSession(title: "降载测试")
        rig.source.start()
        try await waitFor("recording", timeout: 10) { rig.camera.counters.recording }
        try await Task.sleep(for: .milliseconds(300))
        rig.camera.shed = (2, "测试：L2")
        XCTAssertFalse(rig.camera.analyzer.isLocalizingBounces)
        XCTAssertFalse(rig.pipeline.isPreviewing)
        XCTAssertNil(rig.camera.session?.analysisGaps)
        rig.camera.shed = (3, "测试：L3")
        XCTAssertFalse(rig.camera.analyzer.isAdmitting)
        let gap = try XCTUnwrap(rig.camera.session?.analysisGaps?.first)
        XCTAssertNil(gap.endPTS); XCTAssertEqual(gap.reason, "测试：L3")
        // Wait on the capture clock, not wall time: a slow runner may produce fewer than 60 frames a second.
        try await waitFor("frames during the gap", timeout: 10) { (rig.pipeline.currentCounters.latestPTS ?? 0) > gap.startPTS + 0.5 }
        rig.camera.shed = (0, nil)
        XCTAssertTrue(rig.camera.analyzer.isAdmitting)
        let closed = try XCTUnwrap(rig.camera.session?.analysisGaps?.first?.endPTS)
        XCTAssertGreaterThan(closed, gap.startPTS + 0.4)
        XCTAssertTrue(rig.camera.counters.recording, "Recording continues through load shedding")
        await rig.camera.finish()
        let saved = try XCTUnwrap(try SessionStore(directory: rig.root).loadAll(recoverUnfinished: false).first)
        XCTAssertEqual(saved.analysisGaps?.count, 1)
        XCTAssertEqual(saved.recordings.count, 1)
        await rig.close()
    }

    @MainActor func testRecordingTransferVerifiesResumesAndIsRefusedWhileRecording() async throws {
        let root = makeRoot("court-transfer")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let rig = CameraRig(root: root.appendingPathComponent("camera"))
        do {
            display.selectRole(.server)
            try await waitFor("ticket", timeout: 10) { !display.pairingURL.isEmpty }
            var ticket = try PairingTicket.parse(display.pairingURL); ticket.host = "127.0.0.1"
            rig.camera.pair(ticket)
            try await waitFor("connected", timeout: 10) { display.connected && rig.camera.linkState == .connected }
            rig.source.start()
            display.sessionTitle = "回传测试"; display.startSession()
            try await waitFor("camera records", timeout: 10) { (rig.camera.counters.recordingSeconds ?? 0) > 1.5 }
            let owner = try XCTUnwrap(display.session?.id)

            // Refused while the camera records.
            let early = try XCTUnwrap(rig.camera.session)
            display.pauseOrResume()
            try await waitFor("first clip", timeout: 10) { display.session?.recordings.count == 1 && display.session?.state == .paused }
            display.pauseOrResume()
            try await waitFor("recording again", timeout: 10) { rig.camera.session?.state == .active && rig.camera.counters.recording }
            let first = try XCTUnwrap(display.session?.recordings.first)
            display.transferRecording(try XCTUnwrap(display.session), first)
            try await waitFor("refusal", timeout: 5) { display.transfer?.error != nil }
            XCTAssertTrue(display.transfer?.error?.contains("正在记录") == true, display.transfer?.error ?? "")
            XCTAssertEqual(early.id, owner)

            await display.finishSession()
            try await waitFor("completed", timeout: 15) { display.session?.state == .completed && display.session?.recordings.count == 2 }
            let session = try XCTUnwrap(display.session)
            let source = rig.root.appendingPathComponent(first.filename)
            let target = display.recordingURL(filename: first.filename)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            // An earlier, interrupted copy of the first half resumes from there.
            let whole = try Data(contentsOf: source)
            let head = whole.prefix(whole.count / 2)
            let part = display.storageDirectory.appendingPathComponent(".\(first.filename).part")
            try head.write(to: part)
            display.transferRecording(session, first)
            try await waitFor("transfer done", timeout: 30) { display.transfer?.done == true }
            XCTAssertNil(display.transfer?.error)
            XCTAssertEqual(try RecordingTransfer.sha256(of: target), try RecordingTransfer.sha256(of: source))
            XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
            // A copy that is already complete but was never verified finishes with an empty final chunk.
            let second = session.recordings[1]
            try Data(contentsOf: rig.root.appendingPathComponent(second.filename))
                .write(to: display.storageDirectory.appendingPathComponent(".\(second.filename).part"))
            display.transferRecording(session, second)
            try await waitFor("verified complete copy", timeout: 30) { display.transfer?.done == true && display.transfer?.filename == second.filename }
            try FileManager.default.removeItem(at: display.recordingURL(filename: second.filename))
            // The second clip then transfers from scratch.
            display.transferRecording(session, second)
            try await waitFor("second transfer", timeout: 30) { display.transfer?.done == true && display.transfer?.filename == second.filename }
            XCTAssertEqual(try RecordingTransfer.sha256(of: display.recordingURL(filename: second.filename)),
                           try RecordingTransfer.sha256(of: rig.root.appendingPathComponent(second.filename)))
            XCTAssertNil(display.error)
        } catch {
            await rig.close(); await display.shutdown(); throw error
        }
        await rig.close(); await display.shutdown()
    }

    /// Runs the real models over the recorded MOV inside an L3 gap. Synthetic frames contain no
    /// tennis, so this checks the time mapping and bookkeeping, not that shots are found.
    @MainActor func testOfflineBackfillAnalysesTheGapOfTheRecording() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = AnalysisModelLocator.directory ?? repository.appendingPathComponent(".local/AnalysisModels")
        guard ReferenceChain.isAvailable, FileManager.default.fileExists(atPath: models.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Prepare analysis models (scripts/prepare-analysis-models.sh) to run offline backfill.")
        }
        let rig = CameraRig(root: makeRoot("court-backfill"))
        rig.camera.appliesLoadPolicy = false
        rig.camera.startSession(title: "补算测试")
        rig.source.start()
        try await waitFor("recording", timeout: 10) { (rig.camera.counters.recordingSeconds ?? 0) > 2.5 }
        rig.camera.shed = (3, "测试：过热")
        try await Task.sleep(for: .seconds(1))
        rig.camera.shed = (0, nil)
        try await Task.sleep(for: .seconds(1))
        await rig.camera.finish()
        await rig.close()
        let session = try XCTUnwrap(try SessionStore(directory: rig.root).loadAll(recoverUnfinished: false).first)
        let gap = try XCTUnwrap(session.analysisGaps?.first)
        let end = try XCTUnwrap(gap.endPTS)
        XCTAssertEqual(OfflineBackfill.pendingGaps(in: session, directory: rig.root), [0])
        let result = try await OfflineBackfill.run(session: session, directory: rig.root,
                                                   configuration: TennisAnalysisConfiguration(modelDirectory: models))
        XCTAssertEqual(result.filledGaps, [0])
        // Warm-up (2 s) + gap + 1 s tail, at 60 fps, clipped by the recording's own start.
        let recording = try XCTUnwrap(session.recordings.first)
        let expected = (min(end + 1, recording.firstPTS + recording.duration) - max(gap.startPTS - 2, recording.firstPTS)) * 60
        XCTAssertEqual(Double(result.analyzedFrames), expected, accuracy: 6)
        XCTAssertTrue(result.events.allSatisfy { $0.origin == "offline" && $0.sourcePTS >= gap.startPTS && $0.sourcePTS <= end })
        var updated = session
        updated.markAnalysisGapsBackfilled(result.filledGaps)
        XCTAssertEqual(OfflineBackfill.pendingGaps(in: updated, directory: rig.root), [])
    }

    private func makeRoot(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        roots.append(url); return url
    }
    @MainActor private func waitFor(_ condition: String, timeout: Double, predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CourtError.message("Timed out waiting for \(condition)")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}
#endif
