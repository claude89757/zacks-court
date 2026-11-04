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
