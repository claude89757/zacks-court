#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import CourtCore
@testable import CourtApp

/// Offscreen renders of the Mac display, history and camera page from fixture data, for reviewing
/// the Mac layout without running the app or capturing the screen. Opt-in: set
/// COURT_MAC_SNAPSHOTS=/path to render and write PNGs there; skipped otherwise.
///
/// The views are hosted in an `NSHostingView` inside a borderless window that is never shown, so
/// AppKit-backed controls (lists, text fields, menus) draw too. No window chrome or toolbar is drawn,
/// the live picture is the placeholder (no frames are decoded), and sheets are rendered as their
/// content view. Fixtures are made up: no real video, no pairing code.
@MainActor
final class MacSnapshotTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] }

    private var folder: URL? {
        ProcessInfo.processInfo.environment["COURT_MAC_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    /// Typical window sizes, and the window's minimum (760×600, `CourtMacApp`).
    private static let sizes: [(String, CGSize)] = [("1280x800", CGSize(width: 1280, height: 800)), ("1024x700", CGSize(width: 1024, height: 700)),
                                                    ("760x600", CGSize(width: 760, height: 600))]

    func testDisplayStates() async throws {
        guard let folder else { throw XCTSkip("Set COURT_MAC_SNAPSHOTS=/path to render the Mac views") }
        let fixture = Fixture()

        // Not connected: a display with no camera yet.
        let idle = WorkspaceModel(storageDirectory: makeRoot())
        idle.testingActAsDisplay()
        try await renderBoth(CourtWorkspace(model: idle), "dashboard-1-not-connected", folder)

        // Connected and capturing, no record open.
        let connected = WorkspaceModel(storageDirectory: makeRoot())
        connected.testingActAsDisplay()
        try fixture.connect(connected, recording: nil)
        try await renderBoth(CourtWorkspace(model: connected), "dashboard-2-connected", folder) { try fixture.status(connected, recording: nil) }

        // Recording with shots coming in.
        let live = WorkspaceModel(storageDirectory: makeRoot())
        live.testingActAsDisplay()
        let session = fixture.liveSession()
        try fixture.connect(live, recording: session)
        try fixture.send(live, .session, session)
        for message in WireAnalysis.resync(sessionID: session.id, events: fixture.events, calibration: fixture.calibration, modelVersion: fixture.modelVersion) {
            try fixture.send(live, .analysis, message)
        }
        try await renderBoth(CourtWorkspace(model: live), "dashboard-3-recording", folder) { try fixture.status(live, recording: session) }
        XCTAssertEqual(live.dashboardEvents.count, fixture.events.count)

        // Just finished: the camera echoes the finished record, the summary card shows.
        let finished = WorkspaceModel(storageDirectory: makeRoot())
        finished.testingActAsDisplay()
        var record = fixture.liveSession()
        try fixture.connect(finished, recording: record)
        try fixture.send(finished, .session, record)
        for message in WireAnalysis.resync(sessionID: record.id, events: fixture.events, calibration: fixture.calibration, modelVersion: fixture.modelVersion) {
            try fixture.send(finished, .analysis, message)
        }
        record.mergeRemoteTennisEvents(fixture.events, calibration: fixture.calibration, modelVersion: fixture.modelVersion)
        record.finish()
        try fixture.send(finished, .session, record)
        try fixture.status(finished, recording: nil, finished: record)
        XCTAssertNotNil(finished.finishedRecord, "The summary card needs a just-finished record")
        try await renderBoth(CourtWorkspace(model: finished), "dashboard-4-finished", folder) { try fixture.status(finished, recording: nil, finished: record) }

        for model in [idle, connected, live, finished] { await model.shutdown() }
    }

    func testHistoryAndCameraPage() async throws {
        guard let folder else { throw XCTSkip("Set COURT_MAC_SNAPSHOTS=/path to render the Mac views") }
        let fixture = Fixture()
        let root = makeRoot()
        let store = try SessionStore(directory: root)
        let saved = fixture.historySessions()
        for session in saved { try store.save(session) }
        let model = WorkspaceModel(storageDirectory: root)
        model.testingActAsDisplay()
        XCTAssertEqual(model.history.count, saved.count)
        try await render(CourtHistory(model: model), size: CGSize(width: 900, height: 760), folder.appendingPathComponent("history-list.png"))
        let detail = try XCTUnwrap(model.history.first { $0.id == saved[0].id })
        try await render(SessionDetail(model: model, session: detail).frame(maxWidth: .infinity, maxHeight: .infinity).background(CourtStyle.background),
                         size: CGSize(width: 900, height: 1500), folder.appendingPathComponent("history-detail.png"))
        try await render(ScrollView { CourtShotBrowser(model: model, sessions: model.history).padding(24) }.background(CourtStyle.background),
                         size: CGSize(width: 900, height: 1300), folder.appendingPathComponent("history-query.png"))
        await model.shutdown()

        // Role selection, and the camera page as a Mac shows it: a Mac cannot capture, so camera mode
        // opens without a picture (`CameraModel.start` refuses before asking for camera access).
        let start = WorkspaceModel(storageDirectory: makeRoot())
        try await render(CourtWorkspace(model: start), size: CGSize(width: 1280, height: 800), folder.appendingPathComponent("start-1280x800.png"))
        start.selectRole(.camera)
        XCTAssertFalse(start.camera.streaming)
        try await render(CourtWorkspace(model: start), size: CGSize(width: 1280, height: 800), folder.appendingPathComponent("camera-1280x800.png"))
        await start.shutdown()
    }

    // MARK: Rendering

    private func renderBoth<V: View>(_ view: V, _ name: String, _ folder: URL, refresh: () throws -> Void = {}) async throws {
        for (label, size) in Self.sizes {
            try refresh()
            try await render(view, size: size, folder.appendingPathComponent("\(name)-\(label).png"))
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, _ url: URL) async throws {
        let dark = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark).preferredColorScheme(.dark))
        host.appearance = dark
        host.frame = CGRect(origin: .zero, size: size)
        // Never ordered front: the window only gives AppKit controls a backing to draw into.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = dark
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let `.task`, `.onAppear` and list layout settle.
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
        window.close()
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("court-mac-snapshots-\(UUID().uuidString)", isDirectory: true)
        roots.append(root); return root
    }
}

/// Made-up shots and records, shaped like what a camera sends.
@MainActor
private struct Fixture {
    let stream = UUID()
    let modelVersion = "示例模型"
    let calibration = TennisCourtCalibrationState(isAvailable: true, landmarkCount: 14, validationErrorMeters: 0.12, reason: nil)
    let device = "场边 iPhone"
    let events: [TennisShotEvent]

    init() {
        let stream = self.stream
        // (stroke, km/h or nil, speed reason, landing x/y metres or nil, landing reason)
        let rows: [(TennisStrokeKind, Double?, String?, (Double, Double)?, String?)] = [
            (.serve, 162, nil, (7.1, 18.6), nil),
            (.forehand, 104, nil, (3.2, 3.9), nil),
            (.backhand, 88, nil, (8.4, 19.7), nil),
            (.forehand, nil, "缺少击球轨迹样本", (5.6, 2.1), nil),
            (.serve, 171, nil, (3.9, 18.2), nil),
            (.backhand, 91, nil, nil, "下一段击球前没有可靠首弹地证据"),
            (.forehand, 112, nil, (2.4, 4.6), nil),
            (.volley, 64, nil, (6.6, 15.9), nil),
            (.groundstroke, 97, nil, (9.1, 1.4), nil),
            (.serve, nil, "三维轨迹拟合残差过大", nil, "首弹地前检测到触网候选"),
            (.forehand, 118, nil, (4.8, 22.6), nil),
            (.backhand, 95, nil, (7.7, 3.3), nil),
            (.overhead, 126, nil, (5.2, 17.4), nil),
            (.forehand, 109, nil, (1.9, 21.1), nil),
            (.serve, 158, nil, (7.4, 18.9), nil),
            (.backhand, nil, "等待首弹地及连续三维轨迹", nil, "等待独立队列触地定位"),
        ]
        events = rows.enumerated().map { index, row in
            let pts = 40 + Double(index) * 37.5
            let bounce: TennisBounceEstimate? = row.3.map {
                TennisBounceEstimate(sourcePTS: pts + 0.7, xMeters: $0.0, yMeters: $0.1, confidence: 0.8, reason: "模型弹地候选，未验证物理触地或判线精度")
            } ?? row.4.map { TennisBounceEstimate(sourcePTS: pts + 0.7, confidence: 0, reason: $0) }
            return TennisShotEvent(streamID: stream, sourcePTS: pts, endPTS: pts + 1.2, stroke: row.0, confidence: 0.86,
                                   speedKPH: row.1, speedReason: row.2, bounce: bounce, sampleCount: 24)
        }
    }

    /// A record the camera started about 25 minutes ago, with two markers.
    func liveSession() -> CourtSession {
        var session = CourtSession(title: "周四晚 · 底线对拉", startedAt: Date().addingTimeInterval(-25 * 60 - 12))
        session.setCapturedOn(device + " · iPhone 17 Pro")
        session.addMarker("精彩", at: Date().addingTimeInterval(-14 * 60), sourcePTS: 300, streamID: stream)
        session.addMarker("待复核", at: Date().addingTimeInterval(-6 * 60), sourcePTS: 520, streamID: stream)
        return session
    }

    func historySessions() -> [CourtSession] {
        let base = Date(timeIntervalSince1970: 1_793_000_000) // late October 2026
        func record(_ title: String, daysAgo: Double, minutes: Double, shots: ArraySlice<TennisShotEvent>, recordings: Int) -> CourtSession {
            let start = base.addingTimeInterval(-daysAgo * 86_400)
            var session = CourtSession(title: title, startedAt: start)
            session.setCapturedOn(device + " · iPhone 17 Pro")
            // A saved record has no shot still waiting: the last one ended without a speed or landing.
            let settled = shots.map { shot -> TennisShotEvent in
                guard shot.speedReasonCode == .pending else { return shot }
                var shot = shot
                shot.setSpeedReason("缺少击球轨迹样本")
                shot.bounce = TennisBounceEstimate(sourcePTS: shot.sourcePTS + 0.7, confidence: 0, reason: "会话结束前没有可靠首弹地证据")
                return shot
            }
            session.mergeRemoteTennisEvents(settled, calibration: calibration, modelVersion: modelVersion)
            session.addMarker("精彩", at: start.addingTimeInterval(minutes * 20), sourcePTS: 300, streamID: stream)
            for index in 0..<recordings {
                try? session.addRecording(StoredRecording(filename: "\(session.id.uuidString)-\(index + 1).mov", frames: Int(minutes * 3600 / Double(recordings)),
                                                          duration: minutes * 60 / Double(recordings), firstPTS: Double(index) * minutes * 60 / Double(recordings), streamID: stream))
            }
            session.finish(at: start.addingTimeInterval(minutes * 60))
            return session
        }
        return [
            record("周四晚 · 底线对拉", daysAgo: 0, minutes: 26, shots: events[...], recordings: 1),
            record("发球练习", daysAgo: 2, minutes: 41, shots: events.filter { $0.stroke == .serve }[...], recordings: 2),
            record("周末双打热身", daysAgo: 5, minutes: 18, shots: events.prefix(9), recordings: 1),
            record("截击专项", daysAgo: 9, minutes: 12, shots: [], recordings: 0),
        ]
    }

    func connect(_ model: WorkspaceModel, recording: CourtSession?) throws {
        try send(model, .hello, WireHello(role: .camera, device: device, hardware: "iPhone18,2", app: "test", modelVersion: modelVersion,
                                          capabilities: [WireHello.clips]))
        try status(model, recording: recording)
    }

    func status(_ model: WorkspaceModel, recording: CourtSession?, finished: CourtSession? = nil) throws {
        var status = CameraStatus()
        status.capturing = true; status.fps = 60; status.previewing = true; status.zoom = 1
        status.recording = recording != nil
        status.recordingSeconds = recording.map { Date().timeIntervalSince($0.startedAt) }
        status.sessionID = recording?.id ?? finished?.id
        status.sessionState = recording != nil ? .active : finished != nil ? .completed : nil
        status.busy = false
        status.analysis.available = true
        status.analysis.streamID = stream
        status.analysis.latestPTS = 640; status.analysis.analyzedPTS = 639.6
        status.analysis.processedFrames = 38_000; status.analysis.inferenceMilliseconds = 18
        status.analysis.calibration = calibration; status.analysis.modelVersion = modelVersion
        status.device.battery = 0.78; status.device.charging = false; status.device.thermal = "fair"
        try send(model, .status, status)
    }

    func send<T: Encodable>(_ model: WorkspaceModel, _ kind: WireKind, _ body: T) throws {
        model.testingReceiveFromCamera(try .message(kind, body))
    }
}
#endif
