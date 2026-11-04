import SwiftUI
import Observation
import AVFoundation
import CourtCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

public enum WorkspaceRole: String { case camera, server }

/// Link-level counters for the display, refreshed once a second.
struct LinkStats {
    var previewFPS = 0.0
    var kilobytesPerSecond = 0.0
    var messages: UInt64 = 0
}

/// One workspace and one role own all resources. Network, decoding and disk work stay off the UI thread.
///
/// Display role (`.server`): the camera analyses and owns the session once it joins; this model
/// mirrors the camera's session, shot rows and status and sends commands. Before any camera joins
/// the display can keep a local session (markers, pause, finish), which the camera adopts on connect.
/// Camera role: `CameraModel` and its `CameraSessionController` do the work; shared sheets read the
/// role-aware accessors below.
@MainActor @Observable public final class WorkspaceModel {
    public private(set) var role: WorkspaceRole?
    let camera = CameraModel()
    let preview = PreviewPipeline()
    var serverStatus = "等待开启看板"
    var connected = false
    var deviceName = "尚未连接机位"
    var pairingURL = ""
    var addresses: [String] = []
    var selectedAddress = ""
    var cameraStatus: CameraStatus?
    var linkStats = LinkStats()
    var analysisError: String?
    var dashboardEvents: [TennisShotEvent] = []
    var tennisAnalysisError: String?
    var error: String?
    /// A neutral message (record switched, backfill done, record deleted) shown in the shared
    /// banner on every surface. It goes away by itself after a reading time; see `noticeLifetime`.
    var notice: String? { didSet { scheduleNoticeDismissal() } }
    var session: CourtSession? { didSet { sessionChanged(from: oldValue) } }
    /// Display: the mirrored record that just turned from open to completed (finished here or by the
    /// camera). The summary card shows it until dismissed or another record opens.
    private(set) var displayFinishedID: UUID?
    /// The summary card the user closed.
    private(set) var dismissedSummaryID: UUID?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    var history: [CourtSession] = []
    var isBusy = false
    var sessionTitle = ""
    var now = Date()
    /// Recording transfer in progress (display), or its last error.
    var transfer: TransferReceiver.Progress?
    /// Offline backfill in progress: session and fraction done.
    var backfill: (session: UUID, fraction: Double)?
    /// Clip being fetched from the camera (Phase 3): the shot and its progress, or the last failure.
    var clip: (shot: UUID, progress: TransferReceiver.Progress)?
    /// Features the connected camera listed in its hello.
    var cameraCapabilities: [String] = []
    /// Display: the line call on screen (camera's call of the newest judged shot), cleared after a few seconds.
    var hawkEyeAlert: HawkEyeAlert?
    /// Display: settings sent to the camera and not yet echoed in its status.
    var hawkEyePending: HawkEyeSettings?
    /// Display: speak "Out!" for clear outs. Stored per device; on by default.
    var hawkEyeSound = (UserDefaults.standard.object(forKey: "court.hawkEye.sound") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(hawkEyeSound, forKey: "court.hawkEye.sound") }
    }
    @ObservationIgnored let hawkEyeAlerts = HawkEyeAlerts()
    @ObservationIgnored private var hawkEyeTimer: Task<Void, Never>?
    @ObservationIgnored private var hawkEyeRequest: UUID?
    /// Interface the camera connection runs over.
    var linkPath: LinkPath?
    /// Display also listens over peer-to-peer Wi-Fi, so a camera can join without a shared network.
    /// Stored per device; on by default.
    var peerToPeerEnabled = (UserDefaults.standard.object(forKey: "court.display.peerToPeer") as? Bool) ?? true
    /// Analysis models in effect on this device (S家 by default); chosen on the start screen only.
    var analysisBackend = CourtAnalysisBackend.effective() ?? .sjia
    /// Model sets this build carries; the switch shows only when there are two.
    let bundledBackends = CourtAnalysisBackend.bundled()
    /// Switches the analysis models. Refused once a role is chosen, so a record never mixes models.
    func setAnalysisBackend(_ backend: CourtAnalysisBackend) {
        guard role == nil, bundledBackends.contains(backend) else { return }
        CourtAnalysisBackend.save(backend)
        analysisBackend = backend
    }
    /// Display: a session command sent to the connected camera and not yet answered. The session
    /// buttons wait for the camera's reply and its session echo instead of changing state locally.
    private(set) var pendingCommand: WireControl.Command?
    /// Display: handshakes re-sent because the camera's status disagreed with the mirrored session.
    @ObservationIgnored private(set) var resyncRequests = 0
    @ObservationIgnored private var disagreements = 0
    @ObservationIgnored private var resyncAttempts = 0
    @ObservationIgnored private var nextResyncAt = Date.distantPast
    @ObservationIgnored private let transferReceiver = TransferReceiver()
    @ObservationIgnored private var transferRequest: UUID?
    @ObservationIgnored let statusLog = CameraStatusLog()
    @ObservationIgnored private let clipReceiver = TransferReceiver()
    @ObservationIgnored private var clipRequest: UUID?
    @ObservationIgnored private var clipWaiter: CheckedContinuation<URL?, Never>?
    @ObservationIgnored private var displaySnapshot: TennisAnalysisSnapshot?
    @ObservationIgnored private var lastStatusAt: Date?
    @ObservationIgnored private var server: CourtServer?
    @ObservationIgnored private var ticket: PairingTicket?
    @ObservationIgnored private var listeningPort: UInt16?
    @ObservationIgnored private var store: SessionStore?
    /// Cleanup helper over the session directory (nil when the directory is unavailable).
    var storageCleanup: StorageCleanup? { store.map(StorageCleanup.init(store:)) }
    /// What this device holds, by kind; refreshed when the storage page opens and after each cleanup.
    var storageUsage: StorageUsage?
    var storageFreeBytes: Int64?
    /// Recordings removed on purpose (filename → when), so history says "录像已清理".
    var clearedRecordings: [String: Date] = [:]
    /// Days a completed record keeps its recordings; 0 keeps them until the user clears them.
    var recordingRetentionDays: Int = UserDefaults.standard.integer(forKey: "court.storage.recordingRetentionDays") {
        didSet { UserDefaults.standard.set(recordingRetentionDays, forKey: "court.storage.recordingRetentionDays"); applyRecordingRetention() }
    }
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var serviceGeneration = UUID()
    @ObservationIgnored private var recentRows: [TennisShotEvent] = []
    @ObservationIgnored private(set) var pendingIntents: [WireControl] = []
    @ObservationIgnored private var replyWaiters: [UUID: CheckedContinuation<WireControl?, Never>] = [:]
    @ObservationIgnored private var previewViewers = 0
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    @ObservationIgnored private var mirrorDirty = false
    @ObservationIgnored private var lastPresentation = -Double.infinity
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var persisted = true
    @ObservationIgnored private let traffic = TrafficCounter()
    /// Finished sessions deleted on this display: a camera re-sending its copy (on reconnect)
    /// must not write the mirror back.
    @ObservationIgnored private var deletedSessions: Set<UUID> = []
    let storageDirectory: URL

    public init(storageDirectory: URL? = nil) {
        #if os(macOS)
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        self.storageDirectory = storageDirectory ?? base.appendingPathComponent("Zacks Court/Sessions", isDirectory: true)
        VideoExport.clearLeftovers()
        do {
            let store = try SessionStore(directory: self.storageDirectory)
            self.store = store
            history = try store.loadAll()
            clearedRecordings = StorageCleanup(store: store).clearedRecordings()
            // UI tests and store recordings: the display shows the newest demo record (`court-probe
            // demo-session`, titled 演示数据) as just finished, so its boards and replays have shots.
            if Self.replayDemo {
                displayFinishedID = history.filter { $0.state == .completed && $0.title.contains("演示数据") }.max { $0.startedAt < $1.startedAt }?.id
            }
        } catch { self.error = "读取历史记录失败：\(error.localizedDescription)。检查存储空间后重新打开 App。" }
        // Retention runs once the app has settled, never while a record is open.
        Task { [weak self] in try? await Task.sleep(for: .seconds(3)); self?.applyRecordingRetention() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    deinit { ticker?.cancel() }

    /// Set by UI tests only (`COURT_UI_REPLAY_DEMO=1`); it shows records titled 演示数据 and nothing else.
    static let replayDemo = ProcessInfo.processInfo.environment["COURT_UI_REPLAY_DEMO"] == "1"

    // MARK: Role-aware state (shared sheets and dashboards)

    var controller: CameraSessionController? { role == .camera ? camera.controller : nil }
    /// Camera role: capturing. Display: the camera's 1 Hz status is fresh and it is capturing.
    var isLive: Bool {
        if role == .camera { return camera.streaming }
        return connected && cameraStatus?.capturing == true && lastStatusAt.map { now.timeIntervalSince($0) < 3 } == true
    }
    var hasActiveSession: Bool {
        if let controller { return controller.hasOpenSession }
        return session.map { $0.state == .active || $0.state == .paused } ?? false
    }
    var tennisAnalysis: TennisAnalysisSnapshot? { controller?.tennisAnalysis ?? (role == .server ? displaySnapshot : nil) }
    var analysis: AnalysisSnapshot? { controller?.people ?? (isLive ? cameraStatus?.people : nil) }
    var nearHandedness: TennisHandedness { controller?.nearHandedness ?? cameraStatus?.near ?? .right }
    var farHandedness: TennisHandedness { controller?.farHandedness ?? cameraStatus?.far ?? .right }
    /// 「识别状态」 rows from the camera's own state (camera role) or its 1 Hz status and the mirrored ledger (display).
    var recognition: RecognitionStatus {
        if let controller {
            let people = controller.people.map { RecognitionStatus.People(streamID: $0.streamID, pts: $0.pts, count: $0.people.count) }
            let events = controller.dashboardEvents.isEmpty ? controller.tennisAnalysis?.events ?? [] : controller.dashboardEvents
            return RecognitionStatus(.init(isLive: isLive, calibration: controller.tennisAnalysis?.calibration,
                                           shed: controller.shed.level,
                                           inHouse: Self.isInHouse(controller.tennisAnalysis), people: people, latestPTS: controller.counters.latestPTS,
                                           streamID: controller.streamID, events: events))
        }
        let status = isLive ? cameraStatus : nil
        let people = analysis.map { RecognitionStatus.People(streamID: $0.streamID, pts: $0.pts, count: $0.people.count) }
        return RecognitionStatus(.init(isLive: isLive, calibration: tennisAnalysis?.calibration,
                                       shed: status?.shed ?? 0,
                                       inHouse: Self.isInHouse(tennisAnalysis), people: people, latestPTS: status?.analysis.latestPTS,
                                       streamID: status?.analysis.streamID, events: dashboardEvents))
    }
    /// Rows from the in-house live lane carry its model version (`IndependentLiveConfiguration`).
    static func isInHouse(_ snapshot: TennisAnalysisSnapshot?) -> Bool { snapshot?.modelVersion.hasPrefix("independent-") == true }
    var isRecording: Bool { controller.map { $0.counters.recording } ?? (isLive && cameraStatus?.recording == true) }
    var isSaving: Bool { controller.map { $0.counters.saving } ?? (connected && cameraStatus?.saving == true) }
    /// Seconds the camera's analysis trails its own capture clock (both from the camera).
    var analysisProgressGap: Double? {
        guard isLive else { return nil }
        let latest: Double?, analyzed: Double?
        if let controller { latest = controller.counters.latestPTS; analyzed = controller.metrics.lastAnalyzedPTS }
        else { latest = cameraStatus?.analysis.latestPTS; analyzed = cameraStatus?.analysis.analyzedPTS }
        guard let latest, let analyzed else { return nil }
        return max(0, latest - analyzed)
    }
    /// True once a camera adopted the open session: it is then the authority.
    var cameraOwnsSession: Bool { session?.capturedOn != nil }
    /// A session the session panel controls: open, or interrupted (the camera restarted mid-session)
    /// and still waiting to be resumed or finished, as on the camera's own panel.
    var hasControllableSession: Bool {
        if let controller { return controller.hasOpenSession || controller.session?.state == .interrupted }
        return hasActiveSession || (session?.state == .interrupted && cameraOwnsSession)
    }
    /// The connected camera is pausing or finishing; its session buttons wait.
    var cameraBusy: Bool { role == .server && connected && cameraStatus?.busy == true }
    /// Session buttons wait for the camera (a command in flight, or the camera busy) or this model.
    var sessionCommandsLocked: Bool {
        if let controller { return controller.isBusy }
        return isBusy || pendingCommand != nil || cameraBusy
    }
    /// Why the session buttons wait, for a caption under them.
    var sessionWaitReason: String? {
        if let controller { return controller.isBusy ? "正在保存录像与分析…" : nil }
        if pendingCommand != nil { return "已发送到机位，等待机位确认…" }
        if cameraBusy { return "机位正在保存录像与分析…" }
        return nil
    }
    var analysisModelsAvailable: Bool {
        if role == .server, let status = cameraStatus { return status.analysis.available || status.analysis.reason == nil }
        return AnalysisModelLocator.directory != nil
    }
    var tennisAnalysisStatus: String {
        if let tennisAnalysisError { return tennisAnalysisError }
        if role == .server {
            guard connected else { return "等待机位连接。机位实时分析球速、落点与动作，结果逐拍发到这里。" }
            if let reason = cameraStatus?.analysis.reason { return "机位：\(reason)" }
            guard isLive else { return "机位已连接，等待机位开始采集。" }
            guard tennisAnalysis != nil else { return "机位正在积累连续画面…" }
            return "机位正在分析 · 逐拍结果实时同步"
        }
        if analysisBackend == .independent && role != .server {
            guard isLive else { return "自研模型：开始采集后，在本机实时分析球速、落点与动作，并自动识别球场。" }
            guard let analysis = tennisAnalysis else { return "自研模型：正在加载并校验模型…" }
            guard analysis.calibration.isAvailable else {
                return "自研模型：" + (analysis.calibration.reason ?? "正在识别球场") + "。识别出球场后补算之前的击球（最多 30 秒）。"
            }
            return "自研模型：正在分析 · 逐拍结果随后续画面更新"
        }
        guard analysisModelsAvailable else { return "分析模型未安装，请使用包含模型的开发构建。" }
        guard isLive else { return "开始采集后，在本机实时分析球速、落点与动作。" }
        guard tennisAnalysis != nil else { return "正在加载模型并积累连续画面…" }
        return "正在分析 · 逐拍结果随后续画面更新"
    }
    var backupStatus: String {
        guard let status = cameraStatus, connected else { return "录像与分析保存在机位上，看板保存逐拍数据的副本。" }
        if status.saving { return "机位正在保存录像…" }
        if status.recording { return "机位正在录像" + (status.recordingSeconds.map { " · " + courtDuration($0) } ?? "") }
        return "机位未在录像"
    }

    // MARK: End of record and notices

    /// The record that just finished on this device or its camera, for the summary card: built from
    /// the saved session only. Nil while a record is open, after the card is closed, or once another
    /// record starts.
    var finishedRecord: CourtSessionSummary? {
        finishedSession.map { CourtSessionSummary(session: $0, now: now) }
    }

    /// The saved record behind `finishedRecord`.
    private var finishedSession: CourtSession? {
        guard let id = controller.map({ $0.finishedSessionID }) ?? displayFinishedID,
              id != dismissedSummaryID, !hasControllableSession else { return nil }
        let saved = controller?.session?.id == id ? controller?.session
            : session?.id == id ? session : history.first { $0.id == id }
        guard let saved, saved.state == .completed else { return nil }
        return saved
    }

    /// While the summary card shows, the finished record's shots stay on the speed, placement and
    /// shot panels and the full-screen boards, so the numbers do not seem to vanish when the record
    /// ends. Nil otherwise (the card closed, a new record started, or nothing finished here).
    var finishedRecordShots: (title: String, events: [TennisShotEvent])? {
        guard let saved = finishedSession, let events = saved.tennisEvents, !events.isEmpty else { return nil }
        return (saved.title, events)
    }

    /// Shots the display's panels and boards show: the finished record's while its summary card
    /// shows, otherwise the open record's or the camera's latest (`dashboardEvents`).
    var shownEvents: [TennisShotEvent] { finishedRecordShots?.events ?? dashboardEvents }

    /// Says where the shown shots come from, for the full-screen boards' status line.
    var shownEventsStatus: (text: String, tone: CourtStatus.Tone) {
        if let finished = finishedRecordShots { return ("上一次记录「\(finished.title)」", .idle) }
        if isLive { return ("实时数据", .live) }
        if !dashboardEvents.isEmpty { return ("画面已停止 · 保留最近结果", .idle) }
        return (connected ? "已连接 · 等待采集" : "未连接机位", .idle)
    }

    func dismissFinishedRecord() {
        dismissedSummaryID = controller.map { $0.finishedSessionID } ?? displayFinishedID
    }

    /// A display mirror that turned from open to completed is a record that just finished; one that
    /// opens replaces the summary of the previous record.
    private func sessionChanged(from old: CourtSession?) {
        guard let new = session else { return }
        switch new.state {
        case .active, .paused:
            if displayFinishedID != new.id { displayFinishedID = nil }
        case .completed:
            if let old, old.id == new.id, old.state != .completed { displayFinishedID = new.id; dismissedSummaryID = nil }
        case .interrupted: break
        }
    }

    /// Long enough to read the notice at a glance from courtside: about five characters a second,
    /// between 6 and 20 seconds. Errors stay until dismissed; notices only inform.
    static func noticeLifetime(_ text: String) -> Double { min(20, max(6, Double(text.count) / 5)) }

    private func scheduleNoticeDismissal() {
        noticeTimer?.cancel(); noticeTimer = nil
        guard let text = notice else { return }
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeLifetime(text)))
            guard !Task.isCancelled, let self, self.notice == text else { return }
            self.notice = nil
        }
    }

    // MARK: Role lifecycle

    func selectRole(_ role: WorkspaceRole) {
        guard self.role == nil, !isBusy else { return }
        self.role = role
        if role == .server { startServer() } else {
            camera.activate(storageDirectory: storageDirectory)
            Task { await camera.autoStart() }
        }
        updateIdleTimer()
    }

    func leaveRole() async {
        guard !isBusy else { return }
        isBusy = true
        await finishCurrentSession(leaving: true)
        guard persisted else { isBusy = false; return }
        // Intents queued for a camera that never came back must not replay in a later display session.
        pendingIntents = []
        await stopServices()
        ticket = nil; listeningPort = nil
        displayFinishedID = nil
        role = nil
        isBusy = false
        reloadHistory()
        updateIdleTimer()
    }

    public func shutdown() async {
        isBusy = true
        await finishCurrentSession(leaving: true)
        await stopServices()
        isBusy = false
    }

    public func setForeground(_ active: Bool) async {
        foreground = active
        if active { camera.standby.resume() } else { camera.standby.suspend() }
        guard !isBusy else { return }
        if active {
            if role == .server, server == nil { startServer() }
            if role == .camera { camera.resumeWebDisplay(); Task { await camera.autoStart() } }
            updateIdleTimer()
            return
        }
        isBusy = true
        #if os(iOS)
        let background = UIApplication.shared.beginBackgroundTask(withName: "保存球场记录")
        #endif
        if role == .camera {
            await camera.suspendForBackground()
        } else if role == .server {
            // A camera that joined keeps recording and analysing; only a display-local session pauses.
            if session?.state == .active, !cameraOwnsSession { session?.pause(); persistSession() }
            if mirrorDirty { persistSession() }
            await stopServer()
            serverStatus = cameraOwnsSession ? "应用已进入后台 · 机位继续录像，回到前台后自动补齐数据" : "应用已进入后台，记录已暂停"
        }
        isBusy = false
        #if os(iOS)
        if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        #endif
        if foreground, role == .server { startServer() }
        updateIdleTimer()
    }

    /// Scene inactive (Control Center, notification shade, app switcher) or active again.
    /// Standby restores the app-set brightness at once; it would otherwise persist until lock.
    public func setSceneActive(_ active: Bool) {
        if active { camera.standby.resume() } else { camera.standby.suspend() }
    }

    /// A link never silently interrupts an active display session.
    public func handleURL(_ url: URL) {
        guard !isBusy else { return }
        do { _ = try PairingTicket.parse(url.absoluteString) }
        catch { self.error = error.localizedDescription; return }
        guard role == nil || role == .camera else {
            error = "请先返回首页，选择机位，再打开配对链接。"; return
        }
        if role == nil { selectRole(.camera) }
        camera.pair(url.absoluteString)
    }

    func refreshPairing() {
        guard !hasActiveSession, !isSaving, !isBusy else {
            error = "请先结束当前记录，再刷新配对。"; return
        }
        pairingURL = ""; ticket = nil; listeningPort = nil
        Task { await stopServer(); if role == .server { startServer() } }
    }

    /// Turns peer-to-peer listening on or off. The pairing key stays the same, but the camera has to
    /// scan the new code to use the changed connection options.
    func setPeerToPeer(_ enabled: Bool) {
        guard enabled != peerToPeerEnabled else { return }
        guard !connected, !hasActiveSession, !isBusy else { error = "请先结束记录并断开机位，再更改连接方式。"; return }
        peerToPeerEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "court.display.peerToPeer")
        ticket?.peerToPeer = enabled
        pairingURL = ""
        Task { await stopServer(); if role == .server { startServer() } }
    }

    func updatePairingAddress() {
        guard var ticket, !selectedAddress.isEmpty else { return }
        ticket.host = selectedAddress
        do { pairingURL = try ticket.url() }
        catch { self.error = error.localizedDescription }
    }

    // MARK: Hawk-Eye line calls

    /// Settings the camera uses (its own on the camera, the echoed ones on a display).
    var hawkEyeSettings: HawkEyeSettings { controller?.hawkEye ?? cameraStatus?.hawkEye ?? .off }
    /// The connected camera makes line calls (an older camera does not list the capability).
    var canUseHawkEye: Bool { controller != nil || (connected && cameraCapabilities.contains(WireHello.hawkEye)) }
    var hawkEyeUnavailableReason: String? {
        if canUseHawkEye { return nil }
        return connected ? "机位的 App 版本不支持界内外判定，请更新机位。" : "连接机位后才能开启界内外。"
    }

    func setHawkEye(_ settings: HawkEyeSettings) {
        if let controller { controller.setHawkEye(settings); return }
        guard canUseHawkEye else { error = hawkEyeUnavailableReason; return }
        var control = WireControl(.hawkEye); control.hawkEye = settings
        hawkEyePending = settings; hawkEyeRequest = control.id
        sendControl(control)
        if !settings.enabled { dismissHawkEyeAlert() }
    }

    func dismissHawkEyeAlert() { hawkEyeTimer?.cancel(); hawkEyeAlert = nil }

    // MARK: Challenges (docs/hawk-eye.md §7)

    /// The challenge replay on screen: opened on every device when a new challenge arrives.
    var presentedChallenge: HawkEyeChallengeRef?
    /// The connected camera takes challenges (the camera role always does).
    var canChallenge: Bool { controller != nil || (connected && cameraCapabilities.contains(WireHello.challenge)) }
    var challengeUnavailableReason: String? {
        if canChallenge { return nil }
        return connected ? "机位的 App 版本不支持挑战，请更新机位。" : "连接机位后才能挑战。"
    }
    /// Lines a challenge uses: the line-call format when 界内外 is on, else the one picked for this record.
    var challengeFormat: HawkEyeFormat? {
        if hawkEyeSettings.enabled { return hawkEyeSettings.format }
        return challengeFormats[challengeFormatKey]
    }
    @ObservationIgnored private var challengeFormats: [String: HawkEyeFormat] = [:]
    @ObservationIgnored private var seenChallenges = Set<UUID>()
    private var challengeFormatKey: String { (controller?.session?.id ?? session?.id)?.uuidString ?? "none" }

    /// Shots the challenge replay steps through: the camera's own rows on the camera, else the shown ones.
    var challengeEvents: [TennisShotEvent] {
        if let controller { return finishedRecordShots?.events ?? controller.dashboardEvents }
        return shownEvents
    }

    /// Asks the camera to challenge `shot` (nil: the newest). The replay opens on every screen when the
    /// camera's row comes back, here too; a refusal shows as an error.
    func challenge(shot: UUID? = nil, format: HawkEyeFormat? = nil) {
        if let format { challengeFormats[challengeFormatKey] = format }
        let format = format ?? challengeFormat
        if let controller {
            if let refusal = controller.challenge(shot: shot, format: format) { error = refusal }
            return
        }
        guard canChallenge else { error = challengeUnavailableReason; return }
        var control = WireControl(.challenge); control.shot = shot; control.format = format
        sendControl(control)
    }

    /// A row carrying a challenge this screen has not seen opens the replay (live rows only; rows from a
    /// catch-up after reconnecting are remembered, never replayed).
    func noteChallenges(in rows: [TennisShotEvent], replay: Bool) {
        for row in rows {
            guard let c = row.challenge, !seenChallenges.contains(c.id) else { continue }
            seenChallenges.insert(c.id)
            if replay { presentedChallenge = HawkEyeChallengeRef(shot: row.id, challenge: c.id) }
        }
    }

    @ObservationIgnored private var announcedChallenges = Set<UUID>()
    /// The challenge's verdict, said once per challenge however many replays show it ("Out" / "In";
    /// a close call is shown, not said). Follows the 「出界时语音播报」 switch.
    func announceChallenge(_ id: UUID, call: HawkEyeCall) {
        guard hawkEyeSound, call != .close, announcedChallenges.insert(id).inserted else { return }
        hawkEyeAlerts.say(call)
    }

    @ObservationIgnored private var cameraCallsPrimed = false
    /// Camera role: the camera shows and says its own calls like a display (rows already there when the
    /// camera page opens are remembered, never announced).
    func cameraRowsChanged(_ rows: [TennisShotEvent]) {
        guard controller != nil else { return }
        let recent = Array(rows.suffix(24))
        if !cameraCallsPrimed { cameraCallsPrimed = true; hawkEyeAlerts.markSeen(recent); return }
        raiseHawkEye(for: recent)
    }

    /// Camera role: the controller's newest challenge (from this phone or any display).
    func noteCameraChallenge(_ ref: HawkEyeChallengeRef?) {
        guard let ref, !seenChallenges.contains(ref.challenge) else { return }
        seenChallenges.insert(ref.challenge)
        presentedChallenge = ref
    }

    private func raiseHawkEye(for rows: [TennisShotEvent]) {
        guard role == .server else { return }
        let next = hawkEyeAlerts.next(for: rows, current: hawkEyeAlert, soundOn: hawkEyeSound)
        guard next != hawkEyeAlert else { return }
        let fresh = next?.id != hawkEyeAlert?.id
        hawkEyeAlert = next
        guard fresh, let id = next?.id else { return }
        hawkEyeTimer?.cancel()
        hawkEyeTimer = Task { [weak self] in
            try? await Task.sleep(for: HawkEyeAlerts.lifetime)
            guard !Task.isCancelled, self?.hawkEyeAlert?.id == id else { return }
            self?.hawkEyeAlert = nil
        }
    }

    // MARK: Handedness

    func setHandedness(near: TennisHandedness, far: TennisHandedness) {
        if let controller { controller.setHandedness(near: near, far: far); return }
        var control = WireControl(.handedness); control.near = near; control.far = far
        guard connected else { error = "机位未连接，持拍手设置需要在机位连接后保存。"; return }
        sendControl(control)
        displaySnapshot = nil
    }

    // MARK: Session commands

    func startSession() {
        if let controller { controller.startSession(title: sessionTitle); return }
        guard role == .server, !hasActiveSession, !sessionCommandsLocked, !isSaving else { return }
        guard store != nil else { error = "记录目录不可用：检查存储空间后重新打开 App。"; return }
        if !persisted { persistSession(); guard persisted else { return } }
        let title = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = CourtSession(title: title.isEmpty ? "球场分析" : String(title.prefix(100)))
        if connected {
            // The camera is the authority: the session exists once the camera adopts it and echoes
            // it back. A refusal (camera busy, or its own session open) leaves nothing behind here.
            var start = WireControl(.start, sessionID: created.id); start.session = created.withoutTennisEvents()
            launchSessionCommand(start)
            return
        }
        // No camera yet: a display-local session that the camera adopts when it joins.
        session = created
        dashboardEvents = []; lastPresentation = -.infinity
        persistSession()
        updateIdleTimer()
    }

    func pauseOrResume() {
        if let controller {
            guard !controller.isBusy else { return }
            if controller.session?.state == .active { Task { await controller.pause() } } else { controller.resume() }
            return
        }
        guard !sessionCommandsLocked, let state = session?.state, let id = session?.id else { return }
        guard state == .active || state == .paused || (state == .interrupted && cameraOwnsSession) else { return }
        let command: WireControl.Command = state == .active ? .pause : .resume
        // Connected: the camera decides, and its session echo changes this mirror.
        if connected { launchSessionCommand(WireControl(command, sessionID: id)); return }
        if state == .active { session?.pause() } else { session?.resume() }
        persistSession()
        if cameraOwnsSession { queueIntent(WireControl(command, sessionID: id)) }
        updateIdleTimer()
    }

    /// Sends a session command to the connected camera and waits for its reply; the camera echoes
    /// the session before replying, so the mirror is already up to date when this returns.
    /// Returns the reply, or nil when the camera did not answer (the reason is then in `error`).
    /// Locks the session buttons now (a second tap before the task runs must not send twice).
    private func launchSessionCommand(_ control: WireControl) {
        pendingCommand = control.command
        Task { await sendSessionCommand(control) }
    }
    @discardableResult private func sendSessionCommand(_ control: WireControl, timeout: Double = 20) async -> WireControl? {
        pendingCommand = control.command
        defer { pendingCommand = nil; updateIdleTimer() }
        let reply = await request(control, timeout: timeout)
        if reply == nil {
            error = connected ? "机位没有回应，请看机位上的状态后再试。" : "机位连接中断，命令可能没有送达，请重新连接后查看机位状态。"
        }
        // A refusal's reason was already shown when the reply arrived.
        return reply
    }

    func finishSession() async {
        // The confirmation may have been open while the camera became busy: say why nothing happens.
        guard !sessionCommandsLocked else { if let reason = sessionWaitReason { error = reason }; return }
        isBusy = true
        await finishCurrentSession(leaving: false)
        isBusy = false
        updateIdleTimer()
        if !foreground { await setForeground(false) }
    }

    func markEvent(_ label: String) {
        if let controller { controller.addMarker(label); return }
        guard session?.state == .active, let id = session?.id else { return }
        var control = WireControl(.marker, sessionID: id); control.label = label; control.date = Date()
        // Connected: the camera stamps the marker and echoes the session (a refusal shows its reason).
        if connected { sendControl(control); return }
        session?.addMarker(label, sourcePTS: isLive ? cameraStatus?.analysis.latestPTS : nil, streamID: isLive ? cameraStatus?.analysis.streamID : nil)
        persistSession()
        if cameraOwnsSession { queueIntent(control) }
    }

    /// Mounted live-video views ask the camera for its low-resolution preview while visible.
    func previewVisible(_ visible: Bool) {
        previewViewers = max(0, previewViewers + (visible ? 1 : -1))
        if connected { sendPreviewDemand() }
    }
    func wakeCameraScreen() { if connected { sendControl(WireControl(.wake)) } }

    // MARK: Recording transfer and offline backfill (Phase 2)

    /// Pulls a camera-held recording into this display's session folder, resuming a partial copy.
    func transferRecording(_ session: CourtSession, _ recording: StoredRecording) {
        guard role == .server, connected, transfer.map({ $0.done || $0.error != nil }) ?? true else { return }
        do {
            let offset = try transferReceiver.expect(sessionID: session.id, filename: recording.filename, directory: storageDirectory)
            var request = WireControl(.transfer, sessionID: session.id)
            request.label = recording.filename; request.offset = offset
            transferRequest = request.id
            transfer = TransferReceiver.Progress(sessionID: session.id, filename: recording.filename, received: offset, total: 0, bytesPerSecond: 0)
            sendControl(request)
        } catch { self.error = error.localizedDescription }
    }
    func cancelTransfer() {
        if connected { sendControl(WireControl(.cancelTransfer)) }
        transferReceiver.cancel("已取消，已传部分会保留，可继续回传。")
    }
    private func transferProgressed(_ progress: TransferReceiver.Progress) {
        transfer = progress
        if progress.done { reloadHistory() }
    }

    // MARK: Per-shot clips (Phase 3)

    /// The connected camera cuts clips on request.
    var canFetchClips: Bool { role == .server && connected && cameraCapabilities.contains(WireHello.clips) }
    var clipsDirectory: URL { storageDirectory.appendingPathComponent(SessionStore.clipsFolder, isDirectory: true) }
    func clipURL(session: UUID, shot: UUID) -> URL {
        clipsDirectory.appendingPathComponent(session.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(ClipExport.filename(for: shot))
    }
    /// A clip of this shot already fetched to this device.
    func localClip(session: UUID, shot: UUID) -> URL? {
        let url = clipURL(session: session, shot: shot)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Asks the camera for a few seconds around `shot` (2 s before the hit to 1.5 s after the
    /// bounce, at most 10 s) and returns the saved clip, or nil with the reason in `clip`.
    /// One clip at a time; works while the camera records.
    func fetchClip(session: UUID, shot: TennisShotEvent) async -> URL? {
        if let local = localClip(session: session, shot: shot.id) { return local }
        guard canFetchClips, clip.map({ $0.progress.done || $0.progress.error != nil }) ?? true, transfer.map({ $0.done || $0.error != nil }) ?? true else { return nil }
        let window = ClipExport.window(for: shot)
        let url = clipURL(session: session, shot: shot.id), name = url.lastPathComponent
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try clipReceiver.expect(sessionID: session, filename: name, directory: url.deletingLastPathComponent(), resume: false)
        } catch { self.error = error.localizedDescription; return nil }
        var request = WireControl(.clip, sessionID: session)
        request.stream = shot.streamID; request.sourcePTS = window.start; request.endPTS = window.end; request.label = name
        clipRequest = request.id
        clip = (shot.id, TransferReceiver.Progress(sessionID: session, filename: name, received: 0, total: 0, bytesPerSecond: 0))
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            clipWaiter = continuation
            Task { [weak self] in
                // The camera may wait up to 4 s for the end of the window before it replies.
                let reply = await self?.request(request, timeout: 12)
                guard let self, self.clipRequest == request.id else { return }
                if reply == nil { self.clipReceiver.cancel("机位没有回应片段请求，请稍后再试。") }
            }
        }
    }
    func cancelClip() {
        guard let clip, !clip.progress.done, clip.progress.error == nil else { return }
        if connected { sendControl(WireControl(.cancelTransfer)) }
        clipReceiver.cancel("已取消。")
    }
    private func clipProgressed(_ progress: TransferReceiver.Progress) {
        guard let shot = clip?.shot else { return }
        clip = (shot, progress)
        guard progress.done || progress.error != nil else { return }
        clipRequest = nil
        let url = progress.done ? clipURL(session: progress.sessionID, shot: shot) : nil
        clipWaiter?.resume(returning: url); clipWaiter = nil
    }

    /// Re-analyses the local recording inside each analysis gap of a finished session.
    func backfillGaps(_ session: CourtSession) {
        guard backfill == nil, !(controller?.session?.id == session.id && hasActiveSession) else { return }
        guard let models = AnalysisModelLocator.directory else { error = "这台设备没有分析模型，无法离线补算。"; return }
        #if targetEnvironment(simulator)
        let configuration = TennisAnalysisConfiguration(modelDirectory: models, computeUnits: .cpuOnly)
        #else
        let configuration = TennisAnalysisConfiguration(modelDirectory: models)
        #endif
        let directory = storageDirectory, id = session.id
        backfill = (id, 0)
        Task { [weak self] in
            let result: Result<OfflineBackfill.Result, Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(try await OfflineBackfill.run(session: session, directory: directory, configuration: configuration) { fraction in
                        Task { @MainActor in if self?.backfill?.session == id { self?.backfill = (id, fraction) } }
                    })
                } catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.backfill = nil
            switch result {
            case .success(let filled):
                do {
                    let store = try SessionStore(directory: directory)
                    guard var latest = try store.loadAll(recoverUnfinished: false).first(where: { $0.id == id }) else { return }
                    latest.mergeRemoteTennisEvents(filled.events)
                    latest.markAnalysisGapsBackfilled(filled.filledGaps)
                    try store.save(latest)
                    if self.session?.id == id { self.session = latest }
                    self.notice = "离线补算完成：\(filled.filledGaps.count) 段，新增 \(filled.events.count) 个击球候选（标注「离线补算」）。"
                    self.reloadHistory()
                } catch { self.error = "保存补算结果失败：\(error.localizedDescription)" }
            case .failure(let error): self.error = "离线补算失败：\(error.localizedDescription)"
            }
        }
    }

    /// Why this saved session cannot be deleted right now, or nil when it can.
    func deletionBlocker(_ session: CourtSession) -> String? {
        let id = session.id
        if session.state == .active || session.state == .paused
            || (hasActiveSession && (self.session?.id == id || controller?.session?.id == id)) {
            return "记录进行中，结束后才能删除。"
        }
        if backfill?.session == id { return "正在离线补算这次记录，完成后才能删除。" }
        if let transfer, transfer.sessionID == id, !transfer.done, transfer.error == nil { return "录像正在回传，完成或取消后才能删除。" }
        if let clip, clip.progress.sessionID == id, !clip.progress.done, clip.progress.error == nil { return "正在取单拍片段，完成后才能删除。" }
        if let controller, controller.session?.id == id, controller.isBusy || controller.counters.saving { return "机位正在保存录像，稍后再删除。" }
        return nil
    }

    /// Deletes a saved session from this device only: its JSON, recordings with their timestamp
    /// logs and partial transfers, the detection and camera-status logs and fetched clips. A
    /// camera's own copy of a mirrored session is untouched.
    @discardableResult func deleteSession(_ session: CourtSession) -> Bool {
        if let reason = deletionBlocker(session) { error = reason; return false }
        guard let store else { error = "无法访问本机记录目录。"; return false }
        let id = session.id
        if let controller, !controller.forgetFinishedSession(id) { error = "机位正在保存录像，稍后再删除。"; return false }
        do { try store.delete(session) }
        catch { self.error = "删除记录失败：\(error.localizedDescription)"; reloadHistory(); return false }
        deletedSessions.insert(id)
        if self.session?.id == id { self.session = nil; dashboardEvents = []; mirrorDirty = false }
        if transfer?.sessionID == id { transfer = nil }
        history.removeAll { $0.id == id }
        notice = "已删除「\(session.title)」的录像、逐拍数据和标记（仅本机）。"
        reloadHistory()
        return true
    }

    /// Bytes of the recordings these sessions keep on this device.
    func localRecordingBytes(_ sessions: [CourtSession]) -> Int64 {
        Set(sessions.flatMap(\.recordingFilenames)).reduce(Int64(0)) { total, filename in
            let size = (try? FileManager.default.attributesOfItem(atPath: recordingURL(filename: filename).path))?[.size] as? NSNumber
            return total + (size?.int64Value ?? 0)
        }
    }

    /// What deleting this session removes, for the confirmation dialog.
    func deletionMessage(_ session: CourtSession) -> String {
        let bytes = localRecordingBytes([session])
        let recordings = bytes > 0 ? "本机录像（约 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))）" : "录像信息"
        var text = "将从这台设备删除「\(session.title)」的\(recordings)、逐拍数据和辅助标记，删除后无法恢复。"
        if session.capturedOn != nil, session.capturedOn != VideoImport.device, role != .camera { text += "机位上的原始记录不受影响。" }
        else { text += "只影响这台设备。" }
        return text
    }

    func reloadHistory() {
        guard let store else { return }
        do { history = try store.loadAll(recoverUnfinished: false) }
        catch { self.error = "读取历史记录失败：\(error.localizedDescription)" }
        clearedRecordings = StorageCleanup(store: store).clearedRecordings()
    }

    func sessionFileURL(_ session: CourtSession) -> URL {
        storageDirectory.appendingPathComponent(session.id.uuidString).appendingPathExtension("json")
    }

    func analysisFileURL(_ session: CourtSession) -> URL {
        storageDirectory.appendingPathComponent("\(session.id.uuidString)-analysis.jsonl")
    }

    func statusFileURL(_ session: CourtSession) -> URL { CameraStatusLog.url(directory: storageDirectory, session: session.id) }

    /// One line per camera status while a camera owns the open session (field-test record).
    private func logStatus(_ status: CameraStatus) {
        guard role == .server, cameraOwnsSession, hasActiveSession, let id = session?.id else { return }
        var line: [String: Any] = [
            "t": Date().timeIntervalSince1970, "connected": true, "session": session?.state.rawValue ?? "",
            "capturing": status.capturing, "recording": status.recording, "fps": status.fps,
            "captureDrops": status.captureDrops, "thermal": status.device.thermal, "lowPower": status.device.lowPowerMode,
            "screen": status.device.screen, "shed": status.shed, "previewing": status.previewing,
            "linkKBps": (linkStats.kilobytesPerSecond * 10).rounded() / 10, "previewFPS": (linkStats.previewFPS * 10).rounded() / 10]
        line["recordingSeconds"] = status.recordingSeconds
        line["battery"] = status.device.battery
        line["charging"] = status.device.charging
        line["pressure"] = status.device.pressure
        line["freeBytes"] = status.device.freeBytes
        line["shedReason"] = status.shedReason
        line["analysisDelay"] = analysisProgressGap
        line["linkPath"] = linkPath?.rawValue
        statusLog.append(line, session: id, directory: storageDirectory)
    }

    func recordingURL(filename: String) -> URL {
        // All loaded metadata is validated by SessionStore. Still avoid resolving arbitrary paths here.
        (try? store?.recordingURL(filename: filename)) ?? storageDirectory.appendingPathComponent("missing-recording")
    }

    // MARK: Display link

    private func startServer() {
        guard server == nil else { return }
        let generation = UUID(); serviceGeneration = generation
        let server = CourtServer()
        self.server = server
        // Keep the pairing secret across listener restarts (background, network change), so a
        // camera holding this ticket can come back; a new ticket only on explicit refresh or expiry.
        if ticket.map({ $0.expires.timeIntervalSinceNow < 600 }) ?? true {
            #if os(macOS)
            let name = Host.current().localizedName ?? "Zacks Court Mac"
            #else
            let name = "Zacks Court iPhone"
            #endif
            do { ticket = try PairingTicket(name: name, peerToPeer: peerToPeerEnabled) } catch { self.error = error.localizedDescription; self.server = nil; return }
            listeningPort = nil
        }
        serverStatus = "正在开启看板…"; analysisError = nil; tennisAnalysisError = nil
        let assembler = H264SampleAssembler(), preview = preview, traffic = traffic, receiver = transferReceiver, clips = clipReceiver
        receiver.onProgress = { [weak self] progress in Task { @MainActor in self?.transferProgressed(progress) } }
        clips.onProgress = { [weak self] progress in Task { @MainActor in self?.clipProgressed(progress) } }
        server.onPath = { [weak self] path, _ in
            Task { @MainActor in
                guard let self, self.serviceGeneration == generation else { return }
                self.linkPath = path
            }
        }
        server.onListening = { [weak self] ticket in
            Self.writeDiagnosticTicket(ticket)
            Task { @MainActor in
                guard let self, self.serviceGeneration == generation else { return }
                self.ticket = ticket; self.listeningPort = ticket.port
                self.addresses = LocalNetwork.ipv4Addresses()
                self.selectedAddress = ticket.host ?? ""
                do { self.pairingURL = try ticket.url() }
                catch { self.error = error.localizedDescription }
                self.serverStatus = self.connected ? "机位已连接" : "等待机位扫码连接"
            }
        }
        server.onConnected = { [weak self] in
            assembler.reset()
            Task { @MainActor in
                guard let self, self.serviceGeneration == generation else { return }
                self.connected = true; self.serverStatus = "正在确认机位…"
                self.sendHello()
            }
        }
        server.onPacket = { [weak self] packet in
            traffic.add(packet.payload.count, preview: packet.header.kind == WireKind.preview.rawValue)
            if packet.header.kind == WireKind.preview.rawValue {
                do { if let sample = try assembler.sample(from: packet) { preview.submit(sample) } }
                catch { assembler.reset() }
                return
            }
            if packet.header.kind == WireKind.file.rawValue {
                if packet.header.filename?.hasPrefix("clip-") == true { clips.receive(packet) } else { receiver.receive(packet) }
                return
            }
            Task { @MainActor in
                guard let self, self.serviceGeneration == generation else { return }
                self.receive(packet)
            }
        }
        server.onIncompatible = { [weak self] reason in
            Task { @MainActor in guard let self, self.serviceGeneration == generation else { return }; self.error = reason }
        }
        server.onDisconnected = { [weak self] reason in
            assembler.reset(); preview.clear()
            Task { @MainActor in
                guard let self, self.serviceGeneration == generation else { return }
                self.cameraLost(reason)
            }
        }
        server.onError = { [weak self] message in
            Task { @MainActor in guard let self, self.serviceGeneration == generation else { return }; self.error = message }
        }
        if let ticket { server.start(ticket: ticket, port: listeningPort) }
    }

    private func stopServer() async {
        guard let server else { return }
        self.server = nil; serviceGeneration = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in server.stop { continuation.resume() } }
        cameraLost("看板已停止监听")
        pairingURL = ""; addresses = []; selectedAddress = ""
    }

    private func cameraLost(_ reason: String) {
        // The link layer is role-agnostic; on the display the other end is always the camera.
        let reason = reason == CourtConnection.peerClosed ? "机位已断开" : reason
        let wasConnected = connected
        if wasConnected, role == .server, cameraOwnsSession, hasActiveSession, let id = session?.id {
            statusLog.append(["t": Date().timeIntervalSince1970, "connected": false, "reason": reason], session: id, directory: storageDirectory)
        }
        connected = false; cameraStatus = nil; lastStatusAt = nil
        displaySnapshot = nil
        preview.clear()
        for (id, _) in replyWaiters { resolveReply(id, nil) }
        if transferReceiver.isActive { transferReceiver.cancel("机位连接中断，已传部分会保留，重新连接后点「继续回传」。") }
        if clipReceiver.isActive { clipReceiver.cancel("机位连接中断，片段未取完。") }
        cameraCapabilities = []; linkPath = nil; hawkEyePending = nil
        if wasConnected {
            // After a normal finish the disconnect is not news: say the record is safe first.
            serverStatus = cameraOwnsSession && hasActiveSession ? "机位连接中断：\(reason) · 机位继续录像，重连后补齐"
                : finishedRecord != nil ? "记录已保存 · \(reason)" : reason
        }
        updateIdleTimer()
    }

    private func sendHello() {
        disagreements = 0; resyncAttempts = 0; nextResyncAt = .distantPast
        sendHandshake()
        // Intents made while the camera was away, replayed in order after it reconciled.
        let queued = pendingIntents; pendingIntents = []
        for intent in queued { sendControl(intent) }
        sendPreviewDemand()
    }

    /// The hello alone. The camera answers any hello by reconciling with the display's open session
    /// and re-sending its own session, full shot ledger and status, so it also repairs a mirror
    /// that drifted. Queued intents and preview demand are not part of it.
    private func sendHandshake() {
        #if os(macOS)
        let device = Host.current().localizedName ?? "Mac"
        #else
        let device = "iPhone 看板"
        #endif
        // An interrupted camera session goes too, so a camera that restarted again recovers it from disk.
        let open = hasControllableSession ? session?.withoutTennisEvents() : nil
        send(.hello, WireHello(role: .display, device: device, hardware: CameraIdentity.hardwareModel, app: CameraIdentity.appVersion, session: open))
    }

    /// Compares the camera's 1 Hz report of its session with the mirror. Messages arrive in order
    /// on one stream, so a disagreement that lasts three reports means a session update was lost
    /// (or the mirror went wrong): re-handshake, backing off 5 s → 15 s → 60 s, at most 5 times
    /// until the two agree again. A full re-handshake resends the whole ledger, so it stays rare.
    private func checkSessionAgreement(_ status: CameraStatus) {
        guard role == .server, connected, !isBusy, pendingCommand == nil, status.busy != true else { return }
        let agrees: Bool
        if let id = status.sessionID {
            // Older v2 cameras do not report the state: nothing to compare.
            guard let state = status.sessionState else { disagreements = 0; return }
            let open = state == .active || state == .paused || state == .interrupted
            if session?.id == id { agrees = session?.state == state }
            // A finished camera session need not be on screen; an open or interrupted one must be.
            else { agrees = !open && !hasActiveSession }
        } else {
            agrees = !hasActiveSession
        }
        guard !agrees else { disagreements = 0; resyncAttempts = 0; nextResyncAt = .distantPast; return }
        disagreements += 1
        guard disagreements >= 3, resyncAttempts < 5, Date() >= nextResyncAt else { return }
        let delays: [Double] = [5, 15, 60]
        nextResyncAt = Date().addingTimeInterval(delays[min(resyncAttempts, delays.count - 1)])
        resyncAttempts += 1; resyncRequests += 1; disagreements = 0
        sendHandshake()
        if resyncAttempts == 5 { error = "看板与机位的记录状态仍不一致，已停止自动对齐。请以机位为准，或重新连接机位。" }
    }

    private func receive(_ packet: StreamPacket) {
        do {
            switch packet.wireKind {
            case .hello:
                let hello = try packet.decode(WireHello.self)
                guard hello.role == .camera else { error = "连上来的设备不是机位：在那台设备上进入机位模式后重新扫码。"; server?.disconnectClient("这台看板只接受机位连接"); return }
                let model = CameraHardware.name(hello.hardware)
                deviceName = hello.device.contains(model) ? hello.device : hello.device + " · " + model
                cameraCapabilities = hello.capabilities ?? []
                serverStatus = "已连接机位"
            case .status:
                guard !packet.payload.isEmpty else { return }
                let status = try packet.decode(CameraStatus.self)
                cameraStatus = status; lastStatusAt = Date(); now = Date()
                if let pending = hawkEyePending, status.hawkEye == pending { hawkEyePending = nil }
                rebuildSnapshot()
                logStatus(status)
                checkSessionAgreement(status)
            case .session:
                adoptCameraSession(try packet.decode(CourtSession.self))
            case .analysis:
                apply(try packet.decode(WireAnalysis.self))
            case .control:
                let control = try packet.decode(WireControl.self)
                guard control.command == .reply, let request = control.replyTo else { return }
                if control.ok == false, let message = control.message {
                    if request == hawkEyeRequest { hawkEyePending = nil }
                    if request == transferRequest { transferReceiver.cancel(message) }
                    else if request == clipRequest { clipReceiver.cancel(message) }
                    else { error = message }
                }
                resolveReply(request, control)
            default: break
            }
        } catch { self.error = "机位发来的数据无法读取（\(error.localizedDescription)）：把两台设备更新到同一版本后重新连接。" }
    }

    /// The camera's copy of a session. The camera is authoritative for any session it owns; a
    /// different open session on the display is closed and kept in history (camera wins).
    private func adoptCameraSession(_ remote: CourtSession) {
        if deletedSessions.contains(remote.id) {
            guard remote.state == .active || remote.state == .paused else { return }
            deletedSessions.remove(remote.id)
        }
        let known = session?.id == remote.id
        if let local = session, local.id != remote.id {
            let localOpen = local.state == .active || local.state == .paused
            // An interrupted camera session is shown (to be resumed or finished) unless the
            // display has its own open one.
            let remoteOpen = remote.state == .active || remote.state == .paused || (remote.state == .interrupted && !localOpen)
            guard remoteOpen else {
                // A finished camera session we were not showing: keep it in history only.
                save(remote); reloadHistory(); return
            }
            if localOpen {
                var closed = local; closed.finish(); save(closed)
                notice = "机位已有进行中的记录「\(remote.title)」，看板已切换到这条记录；本机记录「\(local.title)」已结束并保存在历史记录中。"
            }
            pendingIntents = []
            session = remote
            dashboardEvents = []
        } else {
            var merged = remote
            merged.mergeRemoteTennisEvents(session?.tennisEvents ?? [])
            session = merged
        }
        mirrorDirty = true
        // A session new to this display is saved at once, like a display-started one used to be.
        if remote.state == .completed || remote.state == .interrupted || !known { persistSession(); reloadHistory() }
        presentRows(force: true)
        updateIdleTimer()
    }

    private func apply(_ message: WireAnalysis) {
        if message.resync == true { hawkEyeAlerts.markSeen(message.events) } else { raiseHawkEye(for: message.events) }
        noteChallenges(in: message.events, replay: message.resync != true)
        if let id = message.sessionID {
            guard session?.id == id else { return }
            if message.resync == true, message.part == 0 { session = session?.withoutTennisEvents() }
            session?.mergeRemoteTennisEvents(message.events, calibration: message.calibration, modelVersion: message.modelVersion)
            mirrorDirty = true
        } else {
            if message.resync == true { recentRows = [] }
            var byID = Dictionary(recentRows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for row in message.events { byID[row.id] = row }
            recentRows = Array(byID.values.sorted { $0.sourcePTS < $1.sourcePTS }.suffix(24))
        }
        presentRows(force: message.resync == true)
    }

    /// Shot rows reach the screen at most 4 times a second; the mirror ledger updates every message.
    private func presentRows(force: Bool = false) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard force || uptime - lastPresentation >= 0.25 else { return }
        lastPresentation = uptime
        dashboardEvents = hasActiveSession ? session?.tennisEvents ?? [] : recentRows
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        guard let status = cameraStatus, let stream = status.analysis.streamID, let calibration = status.analysis.calibration,
              let modelVersion = status.analysis.modelVersion, isLive else { displaySnapshot = nil; return }
        let rows = hasActiveSession ? Array((session?.tennisEvents ?? []).suffix(24)) : recentRows
        displaySnapshot = TennisAnalysisSnapshot(streamID: stream, pts: status.analysis.analyzedPTS ?? 0,
                                                 processedFrames: status.analysis.processedFrames,
                                                 inferenceMilliseconds: status.analysis.inferenceMilliseconds,
                                                 events: rows, calibration: calibration, modelVersion: modelVersion,
                                                 limitations: status.analysis.limitations)
    }

    private func queueIntent(_ control: WireControl) {
        pendingIntents.append(control)
        notice = "机位未连接：操作已在看板记录，机位重连后同步。机位上的录像以机位为准。"
    }

    private func sendControl(_ control: WireControl) { send(.control, control) }
    private func sendPreviewDemand() {
        var control = WireControl(.preview); control.enabled = previewViewers > 0
        sendControl(control)
    }
    private func send<T: Encodable>(_ kind: WireKind, _ body: T) {
        guard let server else { return }
        do { server.send(try StreamPacket.message(kind, body)) }
        catch { self.error = "无法编码发往机位的数据：\(error.localizedDescription)" }
    }

    /// Sends a command and waits for the camera's reply (or nil after `timeout`).
    private func request(_ control: WireControl, timeout: Double) async -> WireControl? {
        guard connected else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<WireControl?, Never>) in
            replyWaiters[control.id] = continuation
            sendControl(control)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolveReply(control.id, nil)
            }
        }
    }
    private func resolveReply(_ id: UUID, _ reply: WireControl?) { replyWaiters.removeValue(forKey: id)?.resume(returning: reply) }

    // MARK: Teardown

    /// Finishes the open session. Connected, the camera finishes it and echoes the completed copy.
    /// The finish button (`leaving == false`) never completes the mirror while the camera refuses
    /// or does not answer: the camera is still recording, so the display keeps showing that. Leaving
    /// the display role ends this display's copy whatever the camera answers, and queues nothing.
    private func finishCurrentSession(leaving: Bool) async {
        if role == .camera { return }
        let finishable = leaving ? hasActiveSession : hasControllableSession
        guard finishable, let id = session?.id else { persistSession(); reloadHistory(); return }
        if connected {
            // The camera seals analysis and closes the recording, then echoes the completed session.
            let reply = await sendSessionCommand(WireControl(.finish, sessionID: id), timeout: 30)
            let deadline = Date().addingTimeInterval(reply?.ok == true ? 5 : 0)
            while session?.state != .completed && session?.id == id && connected && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard session?.id == id else { persistSession(); reloadHistory(); return }
            // The camera holds no copy of this session (its status names another): nothing to wait for.
            let unknownToCamera = connected && reply?.ok == false && cameraStatus.map { $0.sessionID != id } == true
            if session?.state != .completed, connected, !leaving, !unknownToCamera {
                persistSession(); return
            }
        }
        if session?.state != .completed {
            session?.finish()
            if cameraOwnsSession, !leaving, !connected { queueIntent(WireControl(.finish, sessionID: id)) }
        }
        persistSession(); reloadHistory()
    }

    private func stopServices() async {
        await stopServer()
        statusLog.close()
        await camera.shutdown()
        preview.clear(); dashboardEvents = []; recentRows = []; displaySnapshot = nil
        cameraStatus = nil
        connected = false; deviceName = "尚未连接机位"
    }

    private func save(_ value: CourtSession) {
        do { try store?.save(value) } catch { self.error = "记录保存失败：\(error.localizedDescription)。检查存储空间后重试。" }
    }

    private func persistSession() {
        guard let session, let store else { return }
        do { try store.save(session); persisted = true; lastCheckpoint = Date(); mirrorDirty = false }
        catch { persisted = false; self.error = "记录保存失败：\(error.localizedDescription)。检查存储空间后重试。" }
    }

    private func tick() {
        now = Date()
        if role == .camera { camera.tickStandby() }
        if role == .server {
            linkStats = traffic.drain()
            if let at = lastStatusAt, now.timeIntervalSince(at) > 4 { displaySnapshot = nil }
            presentRows()
            if mirrorDirty, now.timeIntervalSince(lastCheckpoint) >= 1 { persistSession() }
            if hasActiveSession, !cameraOwnsSession, now.timeIntervalSince(lastCheckpoint) >= 5 { persistSession() }
        }
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = foreground && (role == .server || camera.streaming)
        #endif
    }

    /// Explicit local diagnostic opt-in (`--pairing-file PATH|@documents`). Atomically replaces the
    /// file with mode 0600; the pairing secret is never logged or printed.
    nonisolated private static func writeDiagnosticTicket(_ ticket: PairingTicket) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--pairing-file"), arguments.count > flag + 1 else { return }
        let path = arguments[flag + 1]
        let url = path == "@documents"
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dev-pairing.txt")
            : URL(fileURLWithPath: path)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".court-pair-\(UUID().uuidString)")
        guard let content = try? Data(ticket.url().utf8),
              FileManager.default.createFile(atPath: temporary.path, contents: content, attributes: [.posixPermissions: 0o600]) else { return }
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = rename(temporary.path, url.path)
    }
}

// MARK: Testing seams

extension WorkspaceModel {
    /// Tests and offscreen renders (`MacSnapshotTests`): act as a display without opening a listener,
    /// so nothing touches the network.
    func testingActAsDisplay() {
        guard role == nil else { return }
        role = .server
        serverStatus = "等待机位扫码连接"
    }
    /// Tests and offscreen renders: handle one message as if a connected camera had sent it.
    func testingReceiveFromCamera(_ packet: StreamPacket) {
        connected = true
        receive(packet)
    }
}

/// Bytes and preview frames received, summed on the network queue and drained once a second.
private final class TrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0, previews = 0, messages: UInt64 = 0
    private var since = ProcessInfo.processInfo.systemUptime
    func add(_ count: Int, preview: Bool) {
        lock.lock(); bytes += count; messages += 1; if preview { previews += 1 }; lock.unlock()
    }
    func drain() -> LinkStats {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime, interval = max(0.001, now - since)
        let stats = LinkStats(previewFPS: Double(previews) / interval, kilobytesPerSecond: Double(bytes) / 1024 / interval, messages: messages)
        bytes = 0; previews = 0; since = now
        return stats
    }
}
