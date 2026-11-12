#if os(macOS)
import XCTest
import Foundation
@testable import CourtCore
@testable import CourtApp

/// Field diagnostics: the camera's own capture log, the diagnostic package of a record and its summary,
/// and how storage counts and clears the logs. Synthetic frames only prove the flow, not any analysis.
final class CameraDiagnosticsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] }

    private func makeRoot(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        roots.append(url); return url
    }

    /// A camera used alone writes one capture file per capture run, a line a second with its session,
    /// and the record's package zips the record with that file and a summary.
    @MainActor func testCameraWritesItsCaptureLogAndThePackageZipsIt() async throws {
        let rig = CameraRig(root: makeRoot("court-capture-log"))
        rig.camera.startSession(title: "诊断测试")
        rig.source.start()
        let id = try XCTUnwrap(rig.camera.session?.id)
        let folder = DiagnosticBundle.folder(in: rig.root)
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var lines: [CameraLogLine] = []
        while lines.filter({ $0.session == id }).count < 2 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("no capture log lines: \(lines.count)") }
            try await Task.sleep(for: .milliseconds(200))
            rig.camera.captureLog.flush()
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            lines = files.compactMap(DiagnosticBundle.readLog).flatMap(\.lines)
        }
        await rig.camera.finish()
        await rig.close()
        rig.camera.captureLog.flush()

        let logs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap(DiagnosticBundle.readLog)
        XCTAssertEqual(logs.count, 1, "one capture run, one file")
        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(log.lines.first?.kind, .start)
        XCTAssertEqual(log.lines.first?.app, "test")
        XCTAssertEqual(log.lines.last?.kind, .stop, "shutdown ends the file")
        let status = log.lines.filter { $0.kind == .status && $0.session == id }
        XCTAssertGreaterThanOrEqual(status.count, 2)
        XCTAssertEqual(status.first?.sessionState, .active)
        XCTAssertEqual(status.first?.display, false)

        let session = try XCTUnwrap(try SessionStore(directory: rig.root).loadAll(recoverUnfinished: false).first)
        let out = makeRoot("court-package")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let zip = try DiagnosticBundle.build(session: session, storageDirectory: rig.root, into: out)
        XCTAssertEqual(zip.pathExtension, "zip")
        let names = try unzipList(zip)
        XCTAssertTrue(names.contains { $0.hasSuffix("/\(id.uuidString).json") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("/README.txt") }, "\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("/" + log.url.lastPathComponent) }, "\(names)")
        XCTAssertFalse(names.contains { $0.hasSuffix(".mov") }, "no video in the package")
        let staging = out.appendingPathComponent(zip.deletingPathExtension().lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the staging folder is removed")
    }

    /// The summary says how long the court took after capture began, why it was refused meanwhile and
    /// how much of the record had a court; a capture run long before the record is left out.
    func testSummaryReportsCourtLockAndLeavesOutOldRuns() throws {
        let root = makeRoot("court-summary")
        let store = try SessionStore(directory: root)
        let t0 = Date().addingTimeInterval(-600).timeIntervalSince1970.rounded()
        let session = CourtSession(title: "摘要测试", startedAt: Date(timeIntervalSince1970: t0 + 5))
        try store.save(session)

        func status(_ t: Double, _ state: CameraCourtDiagnostics.State?, text: String?, inSession: Bool) -> CameraLogLine {
            var line = CameraLogLine(kind: .status, t: t)
            if let state { var court = CameraCourtDiagnostics(state: state); court.motion = .still; court.lines = 7; court.solves = 3
                court.solveSeconds = 0.3; court.maxSolveSeconds = 0.2; court.heightMeters = 3.1; court.behindBaselineMeters = 5.2
                court.focalPixels = 1400; court.rmsPixels = 0.8; line.court = court }
            line.courtText = text; line.thermal = "fair"; line.captureDrops = 0
            if inSession { line.session = session.id; line.sessionState = .active }
            if t - t0 >= 6 { line.shed = 1; line.shedCause = "lag" }     // analysis fell behind for the last 4 s
            return line
        }
        var start = CameraLogLine(kind: .start, t: t0); start.app = "1.1 (7)"; start.hardware = "iPhone18,2"
        var lines = [start]
        for s in 1...3 { lines.append(status(t0 + Double(s), .searching, text: "正在识别球场 · 近端底线和发球线都要在画面里", inSession: false)) }
        for s in 4...9 { lines.append(status(t0 + Double(s), .found, text: "自动识别 · 7 条球场线", inSession: s >= 5)) }
        lines.append(CameraLogLine(kind: .stop, t: t0 + 10))
        let folder = DiagnosticBundle.folder(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(lines, to: folder.appendingPathComponent("capture-now.jsonl"))
        var old = CameraLogLine(kind: .start, t: t0 - 7200); old.app = "old"
        try write([old, status(t0 - 7199, .searching, text: "旧的", inSession: false)], to: folder.appendingPathComponent("capture-old.jsonl"))

        let logs = DiagnosticBundle.captureLogs(for: session, storageDirectory: root)
        XCTAssertEqual(logs.map(\.url.lastPathComponent), ["capture-now.jsonl"], "a run two hours before the record is not included")
        let text = DiagnosticBundle.summary(session: session, logs: logs)
        XCTAssertTrue(text.contains("开始后约 4 秒认出球场"), text)
        XCTAssertTrue(text.contains("「正在识别球场 · 近端底线和发球线都要在画面里」3 秒"), text)
        XCTAssertTrue(text.contains("记录中 5 秒，有球场 5 秒（100%）"), text)
        XCTAssertTrue(text.contains("机高约 3.1 米"), text)
        XCTAssertTrue(text.contains("App：1.1 (7)"), text)
        XCTAssertTrue(text.contains("最高温度状态：fair"), text)
        XCTAssertTrue(text.contains("最高降载等级：L1，降载 4 秒（原因：分析落后）"), text)
    }

    /// Capture logs count as diagnostic logs, are never leftovers, and are cleared with the logs; a run
    /// still being written starts its file again.
    func testCaptureLogsCountAsLogsAndAreCleared() throws {
        let root = makeRoot("court-capture-storage")
        let store = try SessionStore(directory: root)
        let cleanup = StorageCleanup(store: store)
        let log = CameraCaptureLog(storageDirectory: root)
        log.open(CameraLogLine(kind: .start, t: 1))
        log.append(CameraLogLine(kind: .status, t: 2))
        log.flush()
        let usage = cleanup.usage(sessions: [], canJudgeLeftovers: true)
        XCTAssertGreaterThan(usage.logs, 0)
        XCTAssertEqual(usage.leftovers, 0)
        XCTAssertTrue(cleanup.leftovers(sessions: []).isEmpty)
        XCTAssertGreaterThan(try cleanup.clearLogs(inUse: []), 0)
        let folder = DiagnosticBundle.folder(in: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        log.append(CameraLogLine(kind: .status, t: 3))
        log.close(CameraLogLine(kind: .stop, t: 4))
        log.flush()
        let again = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap(DiagnosticBundle.readLog)
        XCTAssertEqual(again.first?.lines.map(\.kind), [.start, .status, .stop], "restarted with its start line")
    }

    /// A capture log last written long before the record is not read at all (14 days of logs are not
    /// decoded for one package), and court numbers that are not finite become unknown instead of
    /// breaking the JSON of the status and the log.
    func testOldLogFilesAreSkippedAndCourtNumbersStayFinite() throws {
        let root = makeRoot("court-log-dates")
        let store = try SessionStore(directory: root)
        let session = CourtSession(title: "日期测试", startedAt: Date().addingTimeInterval(-60))
        try store.save(session)
        let folder = DiagnosticBundle.folder(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let t = session.startedAt.timeIntervalSince1970
        let lines = [CameraLogLine(kind: .start, t: t), CameraLogLine(kind: .status, t: t + 1)]
        let fresh = folder.appendingPathComponent("capture-fresh.jsonl"), stale = folder.appendingPathComponent("capture-stale.jsonl")
        try write(lines, to: fresh)
        try write(lines, to: stale)
        let old = Date().addingTimeInterval(-3 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: stale.path)
        XCTAssertEqual(DiagnosticBundle.captureLogs(for: session, storageDirectory: root).map(\.url.lastPathComponent), ["capture-fresh.jsonl"],
                       "the file dates rule out the stale one before it is read")

        var court = CameraCourtDiagnostics(state: .found)
        court.rmsPixels = .nan; court.motionPixels = .infinity; court.solveSeconds = .nan; court.heightMeters = 3.1
        XCTAssertThrowsError(try JSONEncoder().encode(court), "JSON refuses NaN")
        let clean = court.finiteOnly
        XCTAssertNoThrow(try JSONEncoder().encode(clean))
        XCTAssertNil(clean.rmsPixels); XCTAssertNil(clean.motionPixels)
        XCTAssertEqual(clean.solveSeconds, 0); XCTAssertEqual(clean.heightMeters, 3.1)
    }

    /// The summary says how often the server's arm was read while recording with a court (the serve rules
    /// need 8 a second), how many of those seconds fell short, shed or behind, and a request's cost. Seconds
    /// without a court, and a count that went back (the analysis restarted), are left out; an older camera's
    /// status without pose counts still decodes.
    func testSummaryReportsHowOftenTheServerWasRead() throws {
        let root = makeRoot("court-pose-summary")
        let store = try SessionStore(directory: root)
        let t0 = Date().addingTimeInterval(-300).timeIntervalSince1970.rounded()
        let session = CourtSession(title: "姿态测试", startedAt: Date(timeIntervalSince1970: t0))
        try store.save(session)
        func line(_ s: Int, _ state: CameraCourtDiagnostics.State, frames: Int, skipped: Int, shed: Int = 0) -> CameraLogLine {
            var l = CameraLogLine(kind: .status, t: t0 + Double(s))
            l.session = session.id; l.sessionState = .active; l.court = CameraCourtDiagnostics(state: state); l.shed = shed
            l.poses = CameraPoseCounts(frames: frames, requests: 2 * frames, seconds: 0.02 * Double(frames), skippedBehind: skipped)
            return l
        }
        var start = CameraLogLine(kind: .start, t: t0); start.app = "1.3 (1)"
        let lines = [start,
                     line(1, .found, frames: 0, skipped: 0), line(2, .found, frames: 10, skipped: 0), line(3, .found, frames: 20, skipped: 0),
                     line(4, .found, frames: 24, skipped: 6),             // behind: 4 read, 6 passed over
                     line(5, .found, frames: 24, skipped: 6, shed: 1),    // shed: none read
                     line(6, .found, frames: 34, skipped: 6),
                     line(7, .searching, frames: 44, skipped: 6),         // no court: not counted
                     line(8, .found, frames: 3, skipped: 0),              // the analysis restarted: not counted
                     CameraLogLine(kind: .stop, t: t0 + 9)]
        let expected = "记录中有球场的 5 秒里平均每秒读 6.8 次，不到 8 次的 2 秒（40%），其中降载 1 秒不读；分析落后时跳过 6 次；每次请求约 10 毫秒"
        let report = try XCTUnwrap(DiagnosticBundle.poseReport(lines))
        XCTAssertTrue(report.contains(expected), report)
        XCTAssertNil(DiagnosticBundle.poseReport([CameraLogLine(kind: .status, t: t0), CameraLogLine(kind: .status, t: t0 + 1)]),
                     "no pose counts (S家 lane, older versions): no line")

        let folder = DiagnosticBundle.folder(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(lines, to: folder.appendingPathComponent("capture-poses.jsonl"))
        let text = DiagnosticBundle.summary(session: session, logs: DiagnosticBundle.captureLogs(for: session, storageDirectory: root))
        XCTAssertTrue(text.contains(expected), text)

        var analysis = CameraAnalysisStatus()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self).contains("poses"), "nil is left out on the wire")
        analysis.poses = CameraPoseCounts(frames: 3, requests: 6, seconds: 0.0601, skippedBehind: 1)
        let again = try JSONDecoder().decode(CameraAnalysisStatus.self, from: try JSONEncoder().encode(analysis))
        XCTAssertEqual(again.poses, CameraPoseCounts(frames: 3, requests: 6, seconds: 0.06, skippedBehind: 1))
        let older = try JSONDecoder().decode(CameraLogLine.self, from: Data(#"{"kind":"status","t":1,"shed":0}"#.utf8))
        XCTAssertNil(older.poses)
    }

    private func write(_ lines: [CameraLogLine], to url: URL) throws {
        try lines.compactMap(CameraCaptureLog.encode).reduce(Data(), +).write(to: url)
    }

    private func unzipList(_ zip: URL) throws -> [String] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-Z1", zip.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
    }
}
#endif
