import Foundation
import Observation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// Identity the camera reports in `hello` and stores in `CourtSession.capturedOn`.
public struct CameraIdentity: Sendable {
    public var device: String
    public var hardware: String
    public var app: String
    public init(device: String, hardware: String, app: String) { self.device = device; self.hardware = hardware; self.app = app }

    /// Hardware model identifier: iPhone18,2 on iPhone, Mac16,1 style on macOS.
    public static var hardwareModel: String {
        #if os(iOS) && !targetEnvironment(simulator)
        let key = "hw.machine"
        #elseif os(iOS)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "simulator"
        #else
        let key = "hw.model"
        #endif
        #if !(os(iOS) && targetEnvironment(simulator))
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname(key, &bytes, &size, nil, 0)
        return String(cString: bytes)
        #endif
    }
    public static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

/// Camera-side session authority (docs/camera-side-analysis.md §5).
///
/// The camera records and analyses; this controller owns the session, decides which shot rows
/// belong to it, persists it, and mirrors it to at most one display over `CameraLink`.
/// Display commands are requests: the camera applies them and echoes its own session copy.
/// Live analysis rows are sent as deltas; on every (re)connect the display gets the full ledger.
@MainActor @Observable
public final class CameraSessionController {
    public enum LinkState: Equatable, Sendable {
        case unpaired
        case connecting
        case waiting(String)
        case connected
        case failed(String)
    }

    public private(set) var session: CourtSession?
    public private(set) var linkState: LinkState = .unpaired
    /// Display name from its hello, while connected.
    public private(set) var displayName: String?
    /// Interface the display connection runs over (peer-to-peer Wi-Fi, LAN/hotspot, loopback).
    public private(set) var linkPath: LinkPath?
    public private(set) var ticket: PairingTicket?
    public private(set) var capturing = false
    public private(set) var streamID: UUID?
    /// Coalesced to at most 4 Hz; the session ledger itself is updated for every snapshot.
    public private(set) var tennisAnalysis: TennisAnalysisSnapshot?
    /// Session rows while a session is open, otherwise the latest rows outside any session.
    public private(set) var dashboardEvents: [TennisShotEvent] = []
    public private(set) var people: AnalysisSnapshot?
    public private(set) var nearHandedness: TennisHandedness = .right
    public private(set) var farHandedness: TennisHandedness = .right
    /// Line-call settings a display sent; every bounce is judged with the settings of its time.
    public private(set) var hawkEye = HawkEyeSettings.off
    /// The newest challenge (any device's): the camera's own screen plays it like a display does.
    public private(set) var latestChallenge: HawkEyeChallengeRef?
    public private(set) var counters = CameraMediaPipeline.Counters()
    public private(set) var metrics = CameraSideAnalyzer.Metrics()
    /// Pausing or finishing (recording stops, analysis seals). Displays see it in the next status
    /// at once, so their session buttons wait instead of sending commands the camera would refuse.
    public private(set) var isBusy = false { didSet { if isBusy != oldValue { sendStatus() } } }
    /// Incremented when the display asks to light up the camera screen.
    public private(set) var wakeRequests = 0
    public var error: String?
    public var notice: String?
    /// Load-shedding level and reason, set by the camera's load policy (Phase 2).
    public var shed: (level: Int, reason: String?) = (0, nil) { didSet { applyShed() } }
    /// The record this camera finished last (here or from a display), until another opens: the
    /// camera's 记录 page shows its summary card.
    public private(set) var finishedSessionID: UUID?
    public var hasOpenSession: Bool { session.map { $0.state == .active || $0.state == .paused } ?? false }

    @ObservationIgnored public let pipeline: CameraMediaPipeline
    @ObservationIgnored public let analyzer: CameraSideAnalyzer
    @ObservationIgnored public let storageDirectory: URL
    @ObservationIgnored public let identity: CameraIdentity
    @ObservationIgnored public var deviceState: () -> CameraDeviceState = { CameraDeviceState() }
    @ObservationIgnored public var extraWarnings: () -> [String] = { [] }
    @ObservationIgnored private let store: SessionStore?
    @ObservationIgnored private let journal: AnalysisJournal
    /// The camera's own 1 Hz record of each capture run (court, heat, load), shared in diagnostic packages.
    @ObservationIgnored public let captureLog: CameraCaptureLog
    @ObservationIgnored private var link: CameraLink?
    @ObservationIgnored private let previewSink = PreviewSink()
    @ObservationIgnored private var displayConnected = false
    @ObservationIgnored private var segmentStream: UUID?
    @ObservationIgnored private var segmentStartPTS = 0.0
    @ObservationIgnored private var recordingRequested = false
    @ObservationIgnored private var lastSent: [UUID: TennisShotEvent] = [:]
    @ObservationIgnored private var recentRows: [TennisShotEvent] = []
    @ObservationIgnored private var lastPresentation = -Double.infinity
    @ObservationIgnored private var lastSnapshotAt = -Double.infinity
    @ObservationIgnored private var lastJournalPTS = -Double.infinity
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var sessionChanged = false
    @ObservationIgnored private var lastSave = -Double.infinity
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var previewRequested = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var loadPolicy = CameraLoadPolicy()
    /// False when a caller drives `shed` itself (tests, measurement).
    @ObservationIgnored public var appliesLoadPolicy = true
    /// The one file being sent to the display (a recording or a clip); the link sends one at a time.
    @ObservationIgnored private var transferring: String?
    /// A clip being cut was cancelled before its first chunk.
    @ObservationIgnored private var clipCancelled = false
    /// Challenges by shot, so rows the analysis sends again keep (and re-judge) theirs.
    @ObservationIgnored private var challenges: [UUID: HawkEyeChallenge] = [:]
    private static let recentLimit = 24

    /// Browser displays (docs/web-display.md): the camera listens for them over HTTP + WebSocket.
    public enum WebState: Equatable, Sendable { case off, starting, listening(port: UInt16), failed(String) }
    public private(set) var webState: WebState = .off
    /// Browsers that authenticated and said hello.
    public private(set) var webClients = 0
    public private(set) var webCredentials: WebDisplayCredentials?
    /// Called when the credentials change (new token, or a new PIN after wrong guesses), to persist them.
    @ObservationIgnored public var onWebCredentials: ((WebDisplayCredentials?) -> Void)?
    @ObservationIgnored private var web: WebDisplayServer?
    @ObservationIgnored private var webJoined = Set<UUID>()
    @ObservationIgnored private var webPreviewDemand = false
    @ObservationIgnored private var webPreviewTask: Task<Void, Never>?
    @ObservationIgnored private let webPreviewEncoder = WebPreviewEncoder()
    @ObservationIgnored private var webClipJobs: [String: Task<Result<URL, Error>, Never>] = [:]
    /// A recording being downloaded by a browser (one file at a time, like the native transfer).
    @ObservationIgnored private var webDownload: String?
    /// The camera is reading a recording for a display or a browser (a transfer, a download or a
    /// clip being cut); storage cleanup waits until it is done.
    public var isReadingRecordings: Bool { transferring != nil || webDownload != nil || !webClipJobs.isEmpty }

    public init(storageDirectory: URL, configuration: TennisAnalysisConfiguration?, identity: CameraIdentity,
                pipeline: CameraMediaPipeline, analyzer: CameraSideAnalyzer? = nil) {
        self.storageDirectory = storageDirectory; self.identity = identity; self.pipeline = pipeline
        self.analyzer = analyzer ?? CameraSideAnalyzer(configuration: configuration)
        store = try? SessionStore(directory: storageDirectory)
        journal = AnalysisJournal(directory: storageDirectory)
        captureLog = CameraCaptureLog(storageDirectory: storageDirectory)
        if let configuration {
            nearHandedness = configuration.nearHandedness; farHandedness = configuration.farHandedness
        }
        if let data = try? Data(contentsOf: hawkEyeURL), let saved = try? JSONDecoder().decode(HawkEyeSettings.self, from: data) { hawkEye = saved }
        let analyzer = self.analyzer, sink = previewSink
        pipeline.onFrame = { pixels, pts, stream in analyzer.submit(pixels, pts: pts, streamID: stream) }
        pipeline.onPreview = { packet in sink.send(packet) }
        pipeline.onCapture = { [weak self] stream in Task { @MainActor in self?.captureChanged(stream) } }
        pipeline.onRecording = { [weak self] result in Task { @MainActor in self?.recordingFinished(result) } }
        pipeline.onError = { [weak self] message in Task { @MainActor in self?.error = message } }
        analyzer.onSnapshot = { [weak self] snapshot in Task { @MainActor in self?.handle(snapshot) } }
        analyzer.onEventUpdate = { [weak self] rows in Task { @MainActor in self?.handleLate(rows) } }
        analyzer.onPeople = { [weak self] snapshot in Task { @MainActor in self?.handlePeople(snapshot) } }
        journal.onError = { [weak self] message in Task { @MainActor in self?.error = "分析轨迹保存失败：\(message)" } }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    // MARK: Pairing

    public func pair(_ ticket: PairingTicket) {
        link?.stop(); previewSink.set(nil)
        self.ticket = ticket; displayConnected = false; displayName = nil
        let link = CameraLink(ticket: ticket)
        link.onState = { [weak self, weak link] state in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                switch state {
                case .connecting: if self.linkState != .connected { self.linkState = .connecting }
                case .connected: self.linkState = .connected
                case .waiting(let reason): self.linkState = .waiting(reason); self.linkPath = nil; self.displayLost()
                case .failed(let reason): self.linkState = .failed(reason); self.linkPath = nil; self.displayLost()
                case .stopped: break
                }
            }
        }
        link.onReady = { [weak self, weak link] in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                self.send(.hello, WireHello(role: .camera, device: self.identity.device, hardware: self.identity.hardware,
                                            app: self.identity.app, modelVersion: self.tennisAnalysis?.modelVersion,
                                            session: self.openSessionMetadata, capabilities: [WireHello.clips, WireHello.hawkEye, WireHello.challenge]))
            }
        }
        link.onPacket = { [weak self, weak link] packet in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                self.receive(packet)
            }
        }
        link.onPath = { [weak self, weak link] path, _ in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                self.linkPath = path
            }
        }
        self.link = link; previewSink.set(link); linkState = .connecting
        link.start()
    }

    public func unpair() {
        link?.stop(); link = nil; previewSink.set(nil); ticket = nil
        linkState = .unpaired; displayLost()
    }

    // MARK: Session commands (camera UI and display)

    public func startSession(title: String, kind: SessionKind = .training) {
        guard !hasOpenSession, !isBusy else { return }
        guard store != nil else { error = "记录目录不可用：检查存储空间后重新打开 App。"; return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var created = CourtSession(title: trimmed.isEmpty ? "球场分析" : String(trimmed.prefix(100)), kind: kind)
        created.setCapturedOn(identity.device)
        open(created)
    }

    public func pause(reason: String? = nil) async {
        guard session?.state == .active, !isBusy else { return }
        isBusy = true
        closeAnalysisGap()
        session?.pause(); persist(); sendSession()
        if let reason { notice = reason }
        await stopRecording()
        await seal()
        isBusy = false
    }

    public func resume() {
        guard let state = session?.state, state == .paused || state == .interrupted, !isBusy else { return }
        session?.resume()
        notice = nil  // The pause reason (what to do before 继续) is done with.
        beginSegment(); updateAnalysisGap(); persist(); sendSession(); ensureRecording()
    }

    public func finish() async {
        guard hasOpenSession || session?.state == .interrupted, !isBusy else { return }
        isBusy = true
        let wasActive = session?.state == .active
        closeAnalysisGap()
        await stopRecording()
        if wasActive { await seal() }
        session?.finish(); persist(); sendSession()
        if let session { sendResync(session); finishedSessionID = session.id }
        isBusy = false
    }

    public func addMarker(_ label: String, at date: Date = Date()) {
        guard session?.state == .active else { return }
        // A marker queued on a disconnected display keeps its time but has no reliable frame.
        let fresh = Date().timeIntervalSince(date) < 5
        session?.addMarker(label, at: date, sourcePTS: fresh ? pipeline.currentCounters.latestPTS : nil, streamID: fresh ? streamID : nil)
        persist(); sendSession()
    }

    public func setHandedness(near: TennisHandedness, far: TennisHandedness) {
        nearHandedness = near; farHandedness = far
        analyzer.reconfigure(near: near, far: far)
        tennisAnalysis = nil
        sendStatus()
    }

    private var hawkEyeURL: URL { storageDirectory.appendingPathComponent("hawk-eye.json") }

    /// Line-call settings from now on. Kept on disk so a camera restarted away from its display goes on
    /// judging the same way.
    public func setHawkEye(_ settings: HawkEyeSettings) {
        guard settings != hawkEye else { sendStatus(); return }
        hawkEye = settings
        if let data = try? JSONEncoder().encode(settings) { try? data.write(to: hawkEyeURL, options: .atomic) }
        sendStatus()
    }

    // MARK: Challenges

    /// Challenges a shot's line call (`shot`, or the newest when nil; docs/hawk-eye.md §7) and sends the
    /// row to every display. `format` also becomes the line-call format. Returns why it was refused.
    @discardableResult public func challenge(shot: UUID? = nil, format: HawkEyeFormat? = nil) -> String? {
        if let format, format != hawkEye.format {
            setHawkEye(HawkEyeSettings(enabled: hawkEye.enabled, format: format, farHalf: hawkEye.farHalf))
        }
        let rows = challengeRows
        let latest = capturing ? counters.latestPTS : nil
        guard let row = shot.map({ id in rows.first { $0.id == id } }) ?? HawkEye.challengeTarget(rows, latestPTS: latest) else {
            return shot == nil ? "还没有可以挑战的击球。" : "找不到这一拍，可能已不在当前记录里。"
        }
        challenges[row.id] = HawkEyeChallenge(format: hawkEye.format)
        publishChallenged(row)
        latestChallenge = HawkEyeChallengeRef(shot: row.id, challenge: challenges[row.id]!.id)
        if challenges[row.id]?.pending == true {
            // the bounce is on its way; if it never comes, say so instead of waiting for ever
            let id = row.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(HawkEye.challengeBounceWait + 1))
                self?.settleChallenge(id)
            }
        }
        return nil
    }

    /// Shots a challenge without a named shot picks from: the open record's, else the latest rows,
    /// else the record that just finished.
    private var challengeRows: [TennisShotEvent] {
        if hasOpenSession { return session?.tennisEvents ?? [] }
        if !recentRows.isEmpty { return recentRows }
        return session?.tennisEvents ?? []
    }

    /// Rows with the line call of their time and their challenge brought up to date, finite numbers only
    /// (every row reaches the record through here, and a NaN would stop it from saving).
    private func annotated(_ rows: [TennisShotEvent]) -> [TennisShotEvent] {
        HawkEye.annotate(rows.map(\.finiteOnly), settings: hawkEye).map { row in
            guard let c = challenges[row.id] else { return row.finiteOnly }
            var row = row
            let waiting = c.pending == true
            let judged = HawkEye.judgeChallenge(c, for: row, waiting: waiting)
            challenges[row.id] = judged; row.challenge = judged
            return row.finiteOnly
        }
    }

    /// Stores the challenged row (in the record or the latest rows) and sends it to every display.
    private func publishChallenged(_ base: TennisShotEvent, waiting: Bool? = nil) {
        guard var c = challenges[base.id] else { return }
        let latest = capturing ? counters.latestPTS : nil
        let waiting = waiting ?? latest.map { $0 - base.sourcePTS <= HawkEye.challengeBounceWait } ?? false
        c = HawkEye.judgeChallenge(c, for: base, waiting: waiting)
        challenges[base.id] = c
        var row = base; row.challenge = c; row = row.finiteOnly
        if let id = session?.id, session?.tennisEvents?.contains(where: { $0.id == row.id }) == true {
            session?.updateKnownTennisEvents([row]); dirty = true
            sendRows([row], sessionID: id)
            if hasOpenSession { dashboardEvents = session?.tennisEvents ?? [] }
        } else {
            mergeRecent([row]); sendRows([row], sessionID: nil)
            if !hasOpenSession { dashboardEvents = recentRows }
        }
    }

    /// A pending challenge whose bounce never came: no bounce, said once.
    private func settleChallenge(_ shot: UUID) {
        guard challenges[shot]?.pending == true else { return }
        let row = session?.tennisEvents?.first { $0.id == shot } ?? recentRows.first { $0.id == shot }
        guard let row else { return }
        publishChallenged(row, waiting: false)
    }

    /// Digital zoom the camera applies while capturing (nil without capture or zoom). Reported in status.
    public var zoomFactor: Double? { didSet { if zoomFactor != oldValue { sendStatus() } } }

    /// The camera's framing changed (zoom). The automatic court no longer matches the picture, so it is
    /// searched for again; the temporal run restarts so no trajectory bridges the change.
    public func framingChanged() {
        analyzer.reconfigure(near: nearHandedness, far: farHandedness, restartCourt: true)
        tennisAnalysis = nil
        sendStatus()
    }

    /// Older displays can still ask for manual corners or a calibration still; the court now
    /// always comes from automatic recognition, so they get this refusal instead of no answer.
    private let manualCourtRemoved = "此版本已去掉手动标定，球场由机位自动识别。请更新看板 App。"

    /// Leaving the camera role: finish the open session, then stop the link and tickers.
    public func shutdown() async {
        if hasOpenSession { await finish() }
        await stopRecording()
        await journal.flush()
        closed = true; ticker?.cancel(); ticker = nil
        captureLog.close(CameraLogLine(kind: .stop, t: Date().timeIntervalSince1970))
        link?.stop(); link = nil; previewSink.set(nil)
        stopWebDisplay()
    }

    // MARK: Capture and recording

    private func captureChanged(_ stream: UUID?) {
        if let stream {
            capturing = true; streamID = stream
            tennisAnalysis = nil; people = nil; recentRows = []
            if session?.state == .active { beginSegment(); ensureRecording() }
            if session == nil || !hasOpenSession { dashboardEvents = [] }
        } else {
            capturing = false; streamID = nil
            tennisAnalysis = nil
            if session?.state == .active { Task { await pause(reason: "采集已停止，记录已暂停。重新开始采集后点「继续」。") } }
            else { recordingRequested = false }
        }
        sendStatus()
    }

    /// While the session is active the camera records whenever it captures. Requested before
    /// capture starts, the pipeline begins the file with the capture's first frame.
    private func ensureRecording() {
        guard let id = session?.id, session?.state == .active, !recordingRequested else { return }
        recordingRequested = true
        pipeline.startRecording(directory: storageDirectory, prefix: "Court", owner: id)
    }

    private func stopRecording() async {
        recordingRequested = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pipeline.stopRecording { continuation.resume() }
        }
    }

    private func recordingFinished(_ result: Result<CameraMediaPipeline.Recording, Error>) {
        switch result {
        case .success(let clip):
            guard let owner = clip.owner else { return }
            let item = StoredRecording(filename: clip.url.lastPathComponent, frames: clip.frames, duration: clip.duration,
                                       firstPTS: clip.firstPTS, streamID: clip.streamID)
            do {
                if session?.id == owner { try session?.addRecording(item); persist(); sendSession() }
                else if var original = try store?.loadAll(recoverUnfinished: false).first(where: { $0.id == owner }) {
                    try original.addRecording(item); try store?.save(original)
                } else { throw CourtError.message("录像已保存，但找不到对应会话：\(clip.url.lastPathComponent)") }
            } catch { self.error = "关联录像失败：\(error.localizedDescription)" }
        case .failure(let error):
            self.error = "录像保存失败：\(error.localizedDescription)"
            recordingRequested = false
        }
    }

    // MARK: Analysis

    private func beginSegment() {
        segmentStream = streamID
        segmentStartPTS = pipeline.currentCounters.latestPTS ?? counters.latestPTS ?? 0
    }

    private func seal() async {
        let owner = session?.id, stream = segmentStream, minimum = segmentStartPTS
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<SealResult, Never>) in
            analyzer.seal { final, rows in continuation.resume(returning: SealResult(final: final, rows: rows)) }
        }
        guard var final = result.final, session?.id == owner, final.streamID == stream else { return }
        final.events = annotated(final.events)
        session?.recordTennisAnalysis(final, minimumPTS: minimum, completingPausedSegment: true)
        session?.updateKnownTennisEvents(annotated(result.rows))
        dashboardEvents = session?.tennisEvents ?? []
        dirty = true
        sendRows(session?.tennisEvents ?? [], sessionID: owner)
    }

    private func handle(_ raw: TennisAnalysisSnapshot) {
        guard raw.streamID == streamID else { return }
        var snapshot = raw
        snapshot.events = annotated(raw.events)
        lastSnapshotAt = ProcessInfo.processInfo.systemUptime
        if session?.state == .active, segmentStream == snapshot.streamID, let id = session?.id {
            session?.recordTennisAnalysis(snapshot, minimumPTS: segmentStartPTS)
            let known = Set((session?.tennisEvents ?? []).map(\.id))
            sendRows(snapshot.events.filter { known.contains($0.id) }, sessionID: id,
                     calibration: snapshot.calibration, modelVersion: snapshot.modelVersion)
            dirty = true
        } else {
            mergeRecent(snapshot.events)
            sendRows(snapshot.events, sessionID: nil, calibration: snapshot.calibration, modelVersion: snapshot.modelVersion)
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastPresentation >= 0.25 {
            lastPresentation = uptime
            tennisAnalysis = snapshot
            dashboardEvents = hasOpenSession ? session?.tennisEvents ?? [] : recentRows
        }
    }

    /// Late bounce results for rows already published.
    private func handleLate(_ raw: [TennisShotEvent]) {
        let rows = annotated(raw)
        if let id = session?.id {
            let changed = session?.updateKnownTennisEvents(rows) ?? []
            if !changed.isEmpty { dirty = true; sendRows(changed, sessionID: id) }
        }
        let recentIDs = Set(recentRows.map(\.id))
        let outside = rows.filter { recentIDs.contains($0.id) }
        if !outside.isEmpty { mergeRecent(outside); sendRows(outside, sessionID: nil) }
        dashboardEvents = hasOpenSession ? session?.tennisEvents ?? [] : recentRows
    }

    private func handlePeople(_ snapshot: AnalysisSnapshot) {
        guard snapshot.streamID == streamID else { return }
        people = snapshot
        guard session?.state == .active, let id = session?.id else { return }
        session?.recordAnalysis(snapshot); dirty = true; sessionChanged = true
        if snapshot.pts - lastJournalPTS >= 0.5 || snapshot.pts < lastJournalPTS {
            lastJournalPTS = snapshot.pts
            journal.append(snapshot, sessionID: id, elapsed: session?.elapsed() ?? 0)
        }
    }

    private func mergeRecent(_ rows: [TennisShotEvent]) {
        var byID = Dictionary(recentRows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for row in rows { byID[row.id] = row }
        recentRows = Array(byID.values.sorted { $0.sourcePTS < $1.sourcePTS }.suffix(Self.recentLimit))
    }

    private func sendRows(_ rows: [TennisShotEvent], sessionID: UUID?, calibration: TennisCourtCalibrationState? = nil, modelVersion: String? = nil) {
        let changed = rows.filter { lastSent[$0.id] != $0 }
        guard !changed.isEmpty else { return }
        for row in changed { lastSent[row.id] = row }
        if lastSent.count > 2000 {
            let keep = Set((session?.tennisEvents ?? []).map(\.id)).union(recentRows.map(\.id))
            lastSent = lastSent.filter { keep.contains($0.key) }
        }
        send(.analysis, WireAnalysis(sessionID: sessionID, events: changed,
                                     calibration: calibration ?? tennisAnalysis?.calibration,
                                     modelVersion: modelVersion ?? tennisAnalysis?.modelVersion))
    }

    // MARK: Display link

    private var openSessionMetadata: CourtSession? {
        guard let session, session.state != .completed else { return nil }
        return session.withoutTennisEvents()
    }

    private func receive(_ packet: StreamPacket) {
        switch packet.wireKind {
        case .hello:
            guard let hello = try? packet.decode(WireHello.self), hello.role == .display else {
                error = "看板发来的连接信息无效：在看板上刷新配对码后重新扫码。"; return
            }
            displayConnected = true; displayName = hello.device
            reconcile(with: hello.session)
            if let session { sendSession(); sendResync(session) }
            if !recentRows.isEmpty {
                var message = WireAnalysis(sessionID: nil, events: recentRows, calibration: tennisAnalysis?.calibration,
                                           modelVersion: tennisAnalysis?.modelVersion)
                message.resync = true; message.part = 0; message.parts = 1
                send(.analysis, message)
            }
            sendStatus()
        case .control:
            guard displayConnected, let control = try? packet.decode(WireControl.self) else { return }
            Task { await apply(control, from: .native) }
        default:
            break
        }
    }

    /// Hello from a display that may hold its own open session. The camera keeps any session it
    /// already has (it owns the recordings and analysis); otherwise it adopts the display's.
    private func reconcile(with remote: CourtSession?) {
        guard let remote, remote.state == .active || remote.state == .paused || remote.state == .interrupted else { return }
        if hasOpenSession {
            // The camera keeps its own open session. If it finished the display's one while apart,
            // send that completed copy first so the display's mirror gets the final rows and recordings.
            guard remote.id != session?.id,
                  let stored = try? store?.loadAll(recoverUnfinished: false).first(where: { $0.id == remote.id }),
                  stored.state == .completed else { return }
            sendSession(stored, to: .native); sendResync(stored, to: .native)
            return
        }
        // No session open here, so an unfinished file on disk is from before a restart: recover it to
        // interrupted, never resume it silently as active without recording.
        if let stored = try? store?.loadAll(recoverUnfinished: true).first(where: { $0.id == remote.id }) {
            // The camera ended or lost this session while apart; its copy is authoritative.
            if stored.state == .completed { sendSession(stored, to: .native); sendResync(stored, to: .native) }
            else { session = stored; dashboardEvents = stored.tennisEvents ?? [] }
            return
        }
        // An interrupted session this camera never stored belongs to another camera: never adopt it.
        guard remote.state != .interrupted else { return }
        adopt(remote)
    }

    private func adopt(_ remote: CourtSession) {
        var adopted = remote.withoutTennisEvents()
        adopted.setCapturedOn(identity.device)
        open(adopted)
    }

    private func open(_ value: CourtSession) {
        session = value; dashboardEvents = []; finishedSessionID = nil
        lastJournalPTS = -.infinity
        if value.state == .active { beginSegment() }
        persist(); sendSession(); ensureRecording()
    }

    private func apply(_ control: WireControl, from origin: Target) async {
        var ok = true, message: String?
        let matches = control.sessionID == nil || control.sessionID == session?.id
        let busy = "机位正忙，请稍后再试。"
        if case .web = origin, [.transfer, .clip, .cancelTransfer, .reply, .superseded].contains(control.command) {
            // Browsers fetch files over HTTP (`/api/*`), never through the control channel.
            reply(to: control, ok: false, message: "浏览器看板不支持这条命令。", origin); return
        }
        switch control.command {
        case .start:
            // A start that lands while the camera seals a pause or finish waits for the user to retry.
            if isBusy { ok = false; message = busy; break }
            guard let remote = control.session else {
                // A browser sends only a title; the camera creates the session itself.
                if let current = session, hasOpenSession {
                    ok = false; message = "机位已有进行中的记录「\(current.title)」。"
                } else {
                    startSession(title: control.label ?? "")
                    ok = hasOpenSession; if !ok { message = error ?? busy }
                }
                break
            }
            if let current = session, hasOpenSession, current.id != remote.id {
                ok = false; message = "机位已有进行中的记录「\(current.title)」，看板已切换到这条记录。"
                sendSession()
            } else if session?.id != remote.id || !hasOpenSession { adopt(remote) }
        // The reply says whether the state was reached: with two displays a command can arrive
        // while the camera is busy with the other one's, and must not report a silent no-op as done.
        // Pause, resume and finish are idempotent: a state already reached is success, so two
        // displays pressing the same button both see it done.
        case .pause:
            if !matches || session == nil { ok = false; message = "机位上的记录已经变化，请以机位显示为准。" }
            else if session?.state == .active {
                await pause()
                if session?.state == .active { ok = false; message = busy }
            } else if session?.state != .paused { ok = false; message = "机位没有进行中的记录。" }
        case .resume:
            if !matches || session == nil { ok = false; message = "机位上的记录已经变化，请以机位显示为准。" }
            else if session?.state == .paused || session?.state == .interrupted {
                resume()
                if session?.state != .active { ok = false; message = busy }
            } else if session?.state != .active { ok = false; message = "机位上的这次记录已结束。" }
        case .finish:
            if !matches || session == nil { ok = false; message = "机位上的记录已经变化，请以机位显示为准。" }
            else if session?.state != .completed {
                await finish()
                if session?.state != .completed { ok = false; message = busy }
            }
        case .marker:
            if !matches || session?.state != .active { ok = false; message = "机位没有进行中的记录，标记未保存。" }
            else { addMarker(control.label ?? "标记", at: control.date ?? Date()) }
        case .handedness:
            setHandedness(near: control.near ?? nearHandedness, far: control.far ?? farHandedness)
        case .hawkEye:
            if let settings = control.hawkEye { setHawkEye(settings) } else { ok = false; message = "界内外设置无效。" }
        case .challenge:
            if let refusal = challenge(shot: control.shot, format: control.format) { ok = false; message = refusal }
        case .corners:
            ok = false; message = manualCourtRemoved
        case .preview:
            previewRequested = control.enabled == true
            applyShed()
        case .still:
            ok = false; message = manualCourtRemoved
        case .wake:
            wakeRequests += 1
        case .transfer:
            startTransfer(control); return
        case .clip:
            startClip(control); return
        case .cancelTransfer:
            if transferring?.hasPrefix("clip-") == true { clipCancelled = true }
            link?.cancelFile(); return
        case .reply, .superseded:
            return
        }
        reply(to: control, ok: ok, message: message, origin)
    }

    private func reply(to request: WireControl, ok: Bool, message: String? = nil, _ origin: Target) {
        send(.control, WireControl.reply(to: request, ok: ok, message: message), to: origin)
    }

    private func displayLost() {
        guard displayConnected else { return }
        displayConnected = false; displayName = nil; previewRequested = false
        applyShed()
    }

    private func applyShed() {
        // L2+ turns preview off whatever the display asks; L1 slows it to 1 frame/s (docs §7).
        pipeline.setPreviewEvery(shed.level >= 1 ? 60 : CameraMediaPipeline.previewStride)
        pipeline.setPreview(previewRequested && displayConnected && shed.level < 2)
        updateAnalysisGap()
        analyzer.isDetectingPeople = shed.level < 1
        analyzer.isLocalizingBounces = shed.level < 2
        analyzer.isAdmitting = shed.level < 3
        analyzer.setCourtRefreshInterval(shed.level >= 2 ? 10 : 2)
    }

    /// L3 pauses live analysis while recording continues; the session marks that span so the
    /// rows there stay unknown, and offline backfill can fill them from the recording later.
    private func updateAnalysisGap() {
        guard session?.state == .active else { return }
        let open = session?.analysisGaps?.last.map { $0.endPTS == nil } ?? false
        let pts = pipeline.currentCounters.latestPTS ?? counters.latestPTS ?? segmentStartPTS
        if shed.level >= 3, !open {
            session?.openAnalysisGap(streamID: streamID, at: pts, reason: shed.reason ?? "设备过热，分析暂停")
            persist(); sendSession()
        } else if shed.level < 3, open {
            session?.closeAnalysisGap(at: pts)
            persist(); sendSession()
        }
    }
    private func closeAnalysisGap() {
        guard session?.analysisGaps?.last.map({ $0.endPTS == nil }) == true else { return }
        session?.closeAnalysisGap(at: pipeline.currentCounters.latestPTS ?? counters.latestPTS ?? segmentStartPTS)
    }

    /// Display asked for a recording. Refused while a session records, so live rows never queue
    /// behind gigabytes of video.
    private func startTransfer(_ request: WireControl) {
        func refuse(_ message: String) { reply(to: request, ok: false, message: message, .native) }
        guard session?.state != .active else { refuse("机位正在记录，暂停或结束后再回传录像。"); return }
        guard transferring == nil, webDownload == nil else { refuse("机位正在发送另一份文件，请稍后再回传。"); return }
        guard let id = request.sessionID, let name = request.label, let store else { refuse("回传请求无效。"); return }
        let owner = session?.id == id ? session : (try? store.loadAll(recoverUnfinished: false))?.first { $0.id == id }
        guard let owner, owner.recordings.contains(where: { $0.filename == name }),
              let url = try? store.recordingURL(filename: name), FileManager.default.fileExists(atPath: url.path) else {
            refuse("机位上找不到这段录像。"); return
        }
        let total = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let offset = min(max(0, request.offset ?? 0), total)
        transferring = name
        reply(to: request, ok: true, .native)
        Task { [weak self] in
            // Hash the whole file off the main actor; the display verifies it after the last chunk.
            let digest = await Task.detached(priority: .utility) { Result { try RecordingTransfer.sha256(of: url) } }.value
            guard let self else { return }
            guard case .success(let sha) = digest, let link = self.link else {
                self.transferring = nil
                if case .failure(let error) = digest { self.error = "回传前校验失败：\(error.localizedDescription)" }
                return
            }
            var header = StreamHeader(kind: WireKind.file.rawValue)
            header.sessionID = id; header.filename = name; header.total = total; header.sha256 = sha
            link.sendFile(url, header: header, offset: offset, total: total) { [weak self] failure in
                Task { @MainActor in
                    self?.transferring = nil
                    if let failure { self?.notice = "录像回传中断：\(failure)" }
                }
            }
        }
    }

    /// Cuts a short clip (Phase 3) and sends it like a recording, in small chunks so live rows stay
    /// close behind. Allowed while recording: the segment being recorded is cut from memory.
    private func startClip(_ request: WireControl) {
        func refuse(_ message: String) { reply(to: request, ok: false, message: message, .native) }
        guard transferring == nil else { refuse("机位正在发送另一份文件，请稍后再取片段。"); return }
        guard let id = request.sessionID, let stream = request.stream, let start = request.sourcePTS, let end = request.endPTS,
              let name = request.label, (try? ClipExport.validate(filename: name)) != nil,
              start.isFinite, end.isFinite, start >= 0, end > start, end - start <= ClipExport.maxSeconds + 0.001,
              let store else { refuse("片段请求无效。"); return }
        guard session?.id == id || ((try? store.loadAll(recoverUnfinished: false))?.contains { $0.id == id } ?? false) else {
            refuse("机位上找不到这条记录。"); return
        }
        transferring = name; clipCancelled = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CourtClips", isDirectory: true).appendingPathComponent(name)
        Task { [weak self] in
            guard let self else { return }
            let made = await self.makeClip(session: id, stream: stream, from: start, to: end, store: store, into: url)
            let clip: ClipExport.Result
            switch made {
            case .failure(let error):
                self.transferring = nil; refuse(error.localizedDescription); return
            case .success(let value): clip = value
            }
            let digest = await Task.detached(priority: .utility) { Result { try RecordingTransfer.sha256(of: clip.url) } }.value
            let total = ((try? FileManager.default.attributesOfItem(atPath: clip.url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            guard !self.clipCancelled, case .success(let sha) = digest, let link = self.link, self.linkState == .connected else {
                try? FileManager.default.removeItem(at: clip.url); self.transferring = nil
                if !self.clipCancelled { refuse("片段准备好了，但看板已断开或校验失败。") }
                return
            }
            var reply = WireControl.reply(to: request, ok: true)
            reply.sourcePTS = clip.startPTS; reply.endPTS = clip.startPTS + clip.duration; reply.offset = total
            self.send(.control, reply, to: .native)
            var header = StreamHeader(kind: WireKind.file.rawValue)
            header.sessionID = id; header.filename = name; header.total = total; header.sha256 = sha
            link.sendFile(clip.url, header: header, offset: 0, total: total,
                          chunkSize: ClipExport.chunkSize, backlogLimit: ClipExport.backlogLimit) { [weak self] _ in
                try? FileManager.default.removeItem(at: clip.url)
                Task { @MainActor in self?.transferring = nil }
            }
        }
    }

    /// The segment being recorded (or the latest one, until the next recording starts) comes from
    /// memory; anything older from its finished MOV.
    private func makeClip(session id: UUID, stream: UUID, from start: Double, to end: Double, store: SessionStore, into url: URL) async -> Result<ClipExport.Result, Error> {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if var live = pipeline.liveClip(stream: stream, from: start, to: end) {
                // The window may end a moment after the request: wait for those frames, briefly.
                var waited = 0.0
                while end > live.latestPTS, !live.closed, waited < ClipExport.maxWaitSeconds {
                    try await Task.sleep(for: .milliseconds(250)); waited += 0.25
                    guard let next = pipeline.liveClip(stream: stream, from: start, to: end) else { break }
                    live = next
                }
                if !live.samples.isEmpty { return .success(try await ClipExport.write(live.samples, to: url)) }
                if !live.closed {
                    throw CourtError.message("这一拍早于机位内存里最近 \(Int(pipeline.liveClipSeconds)) 秒的录像；暂停或结束本段录像后可以取片段。")
                }
            }
            let owner = session?.id == id ? session : (try store.loadAll(recoverUnfinished: false)).first { $0.id == id }
            guard let recording = owner?.recordings.first(where: { $0.streamID == stream && end > $0.firstPTS && start < $0.firstPTS + $0.duration }) else {
                throw CourtError.message("机位上没有这段时间的录像（可能还在保存，请稍后再试）。")
            }
            let source = try store.recordingURL(filename: recording.filename)
            guard FileManager.default.fileExists(atPath: source.path) else { throw CourtError.message("机位上的录像文件已不在。") }
            let from = max(0, start - recording.firstPTS), to = min(recording.duration, end - recording.firstPTS)
            return .success(try await ClipExport.cut(source, firstPTS: recording.firstPTS, from: from, to: to, into: url))
        } catch { return .failure(error) }
    }

    /// Where a message goes: every display, the native display only, or one browser.
    enum Target: Equatable { case everyone, native, web(UUID) }

    private func send<T: Encodable>(_ kind: WireKind, _ body: T, to target: Target = .everyone) {
        do {
            if target != .everyone, case .web(let client) = target {
                web?.send(try WebWire.envelope(kind.rawValue, body), to: client); return
            }
            if let link, linkState == .connected { link.send(try StreamPacket.message(kind, body)) }
            if target == .everyone, let web, !webJoined.isEmpty { web.broadcast(try WebWire.envelope(kind.rawValue, body)) }
        } catch { self.error = "无法编码发往看板的数据：\(error.localizedDescription)" }
    }
    private func sendSession(_ value: CourtSession? = nil, to target: Target = .everyone) {
        guard let value = value ?? session else { return }
        if value.id == session?.id, target == .everyone { sessionChanged = false }
        send(.session, value.withoutTennisEvents(), to: target)
    }
    private func sendResync(_ value: CourtSession, to target: Target = .everyone) {
        for message in WireAnalysis.resync(sessionID: value.id, events: value.tennisEvents ?? [],
                                           calibration: value.tennisCalibration ?? tennisAnalysis?.calibration,
                                           modelVersion: value.tennisModelVersion ?? tennisAnalysis?.modelVersion) {
            send(.analysis, message, to: target)
        }
        if target == .everyone { for row in value.tennisEvents ?? [] { lastSent[row.id] = row } }
    }

    public var status: CameraStatus {
        var status = CameraStatus()
        status.capturing = capturing; status.recording = counters.recording; status.saving = counters.saving
        status.fps = capturing ? counters.fps : 0; status.captureDrops = counters.captureDrops
        status.recordingSeconds = counters.recordingSeconds
        status.sessionID = session?.id
        var analysis = CameraAnalysisStatus()
        analysis.available = metrics.tennisAvailable
        analysis.reason = metrics.loadError ?? (metrics.ready ? nil : "正在加载分析模型…")
        analysis.streamID = streamID; analysis.latestPTS = counters.latestPTS; analysis.analyzedPTS = metrics.lastAnalyzedPTS
        analysis.processedFrames = metrics.processedFrames; analysis.pendingFrames = metrics.pendingFrames
        analysis.restarts = metrics.restarts
        analysis.inferenceMilliseconds = tennisAnalysis?.inferenceMilliseconds ?? 0
        analysis.calibration = tennisAnalysis?.calibration; analysis.modelVersion = tennisAnalysis?.modelVersion
        analysis.limitations = tennisAnalysis?.limitations ?? []
        analysis.court = metrics.court
        status.analysis = analysis
        status.device = deviceState()
        status.shed = shed.level; status.shedReason = shed.reason
        status.warnings = extraWarnings()
        status.near = nearHandedness; status.far = farHandedness
        status.zoom = capturing ? zoomFactor : nil
        status.hawkEye = hawkEye
        status.previewing = pipeline.isPreviewing
        status.people = people
        status.sessionState = session?.state
        status.busy = isBusy
        return status
    }
    private func sendStatus(_ current: CameraStatus? = nil) {
        let value = current ?? status
        if displayConnected { send(.status, value, to: .native) }
        if let web, !webJoined.isEmpty, let data = try? WebWire.envelope(WireKind.status.rawValue, value) { web.broadcast(data) }
    }

    // MARK: Browser displays (docs/web-display.md)

    /// Starts listening for browsers with these credentials (new ones when nil or expired).
    public func startWebDisplay(credentials: WebDisplayCredentials? = nil, webRoot: URL? = WebDisplayResources.directory,
                                port: UInt16? = WebDisplayServer.preferredPort) {
        stopWebDisplay(keepCredentials: true)
        let value = credentials.flatMap { $0.isValid() ? $0 : nil } ?? webCredentials.flatMap { $0.isValid() ? $0 : nil } ?? .make()
        if value != webCredentials { webCredentials = value; onWebCredentials?(value) }
        let server = WebDisplayServer(credentials: value, cameraName: identity.device, webRoot: webRoot)
        server.onListening = { [weak self, weak server] port in
            Task { @MainActor in guard let self, let server, self.web === server else { return }; self.webState = .listening(port: port) }
        }
        server.onFailure = { [weak self, weak server] reason in
            Task { @MainActor in guard let self, let server, self.web === server else { return }; self.webState = .failed(reason) }
        }
        server.onMessage = { [weak self, weak server] client, kind, data in
            Task { @MainActor in guard let self, let server, self.web === server else { return }; self.receiveWeb(client, kind: kind, data: data) }
        }
        server.onLeft = { [weak self, weak server] client in
            Task { @MainActor in
                guard let self, let server, self.web === server else { return }
                self.webJoined.remove(client); self.webClients = self.webJoined.count
            }
        }
        server.onPreviewDemand = { [weak self, weak server] demand in
            Task { @MainActor in guard let self, let server, self.web === server else { return }; self.setWebPreviewDemand(demand) }
        }
        server.onCredentials = { [weak self, weak server] value in
            Task { @MainActor in
                guard let self, let server, self.web === server else { return }
                self.webCredentials = value; self.onWebCredentials?(value)
            }
        }
        server.onHTTP = { [weak self] request in
            guard let self else { return .error(503, "机位已关闭。") }
            return await self.handleWebHTTP(request)
        }
        web = server
        // Without the page there is nothing to serve; never show a QR code that leads to a 503.
        guard webRoot != nil else { webState = .failed("浏览器看板资源缺失，请重新安装 App。"); return }
        webState = .starting
        server.start(port: port)
    }

    /// Stops listening and disconnects every browser. The credentials are forgotten unless kept.
    public func stopWebDisplay(keepCredentials: Bool = false) {
        web?.stop(); web = nil
        webJoined = []; webClients = 0; webState = .off
        setWebPreviewDemand(false)
        for job in webClipJobs.values { job.cancel() }
        webClipJobs = [:]
        try? FileManager.default.removeItem(at: Self.webClipDirectory)
        if !keepCredentials, webCredentials != nil { webCredentials = nil; onWebCredentials?(nil) }
    }

    /// New token and PIN: every browser is disconnected and must scan again.
    public func refreshWebCredentials() {
        let value = WebDisplayCredentials.make()
        webCredentials = value; onWebCredentials?(value)
        web?.update(credentials: value)
    }

    /// `http://<address>:<port>/#t=<token>` for the QR code; nil until listening.
    public func webURL(address: String) -> String? {
        guard case .listening(let port) = webState, let token = webCredentials?.token else { return nil }
        return "http://\(address):\(port)/#t=\(token)"
    }

    private func receiveWeb(_ client: UUID, kind: String, data: Data) {
        switch WireKind(rawValue: kind) {
        case .hello:
            guard let hello = try? WebWire.body(WireHello.self, from: data), hello.role == .display else { web?.disconnect(client); return }
            webJoined.insert(client); webClients = webJoined.count
            // Only this browser gets the catch-up; deltas then reach it with everyone else.
            send(.hello, WireHello(role: .camera, device: identity.device, hardware: identity.hardware, app: identity.app,
                                   modelVersion: tennisAnalysis?.modelVersion, session: openSessionMetadata,
                                   capabilities: [WireHello.clips, WireHello.hawkEye, WireHello.challenge, "web"]), to: .web(client))
            if let session { send(.session, session.withoutTennisEvents(), to: .web(client)); sendResync(session, to: .web(client)) }
            var recent = WireAnalysis(sessionID: nil, events: recentRows, calibration: tennisAnalysis?.calibration,
                                      modelVersion: tennisAnalysis?.modelVersion)
            recent.resync = true; recent.part = 0; recent.parts = 1
            send(.analysis, recent, to: .web(client))
            send(.status, status, to: .web(client))
        case .control:
            guard webJoined.contains(client), let control = try? WebWire.body(WireControl.self, from: data) else { return }
            Task { await apply(control, from: .web(client)) }
        default:
            break
        }
    }

    // MARK: Browser preview: JPEG frames from the analyzer's latest copy (docs/web-display.md §6)

    private func setWebPreviewDemand(_ demand: Bool) {
        webPreviewDemand = demand
        guard demand else { webPreviewTask?.cancel(); webPreviewTask = nil; return }
        guard webPreviewTask == nil else { return }
        webPreviewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = self.shed.level
                if level < 2, let stream = self.streamID, let web = self.web {
                    self.webPreviewEncoder.encodeLatest(from: self.analyzer, streamID: stream) { frame in
                        if let frame { web.broadcastPreview(frame) }
                    }
                }
                try? await Task.sleep(for: .milliseconds(level >= 1 ? 1000 : 200))
            }
        }
    }

    // MARK: Browser HTTP API (docs/web-display.md §7)

    static var webClipDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CourtClips", isDirectory: true).appendingPathComponent("web", isDirectory: true)
    }

    /// Stored sessions read off the main actor: an hour of shots is megabytes of JSON per session,
    /// and browsers ask again after every reconnect.
    private func storedSessions() async -> [CourtSession] {
        guard let store else { return [] }
        let box = StoreBox(store: store)
        return await Task.detached(priority: .utility) { (try? box.store.loadAll(recoverUnfinished: false)) ?? [] }.value
    }
    private func loadSession(_ id: UUID) async -> CourtSession? {
        if session?.id == id { return session }
        return await storedSessions().first { $0.id == id }
    }

    private func handleWebHTTP(_ request: WebHTTPRequest) async -> WebHTTPResponse {
        let encoder = WebWire.encoder
        switch request.path {
        case "/api/sessions":
            guard store != nil else { return .error(503, "机位的记录目录不可用：检查机位存储空间后重新打开 App。") }
            var all = await storedSessions()
            if let session { all.removeAll { $0.id == session.id }; all.append(session) }
            let rows = all.sorted { $0.startedAt > $1.startedAt }.map(WebSessionSummary.init)
            return (try? encoder.encode(rows)).map(WebHTTPResponse.json) ?? .error(500, "无法编码会话列表。")
        case "/api/session":
            guard let id = request.query["id"].flatMap(UUID.init(uuidString:)), let value = await loadSession(id) else { return .error(404, "机位上找不到这条记录。") }
            return (try? encoder.encode(WebSessionDetail(value, store: store))).map(WebHTTPResponse.json) ?? .error(500, "无法编码会话。")
        case "/api/clip":
            guard let id = request.query["session"].flatMap(UUID.init(uuidString:)),
                  let shotID = request.query["shot"].flatMap(UUID.init(uuidString:)),
                  let owner = await loadSession(id), let shot = owner.tennisEvents?.first(where: { $0.id == shotID }) else {
                return .error(404, "机位上找不到这一拍。")
            }
            switch await webClip(session: id, shot: shot) {
            case .success(let url): return .file(url, contentType: "video/mp4", downloadName: nil, onFinish: nil)
            case .failure(let error): return .error(409, error.localizedDescription)
            }
        case "/api/recording":
            guard let id = request.query["session"].flatMap(UUID.init(uuidString:)), let name = request.query["file"],
                  let owner = await loadSession(id), owner.recordings.contains(where: { $0.filename == name }),
                  let store, let url = try? store.recordingURL(filename: name), FileManager.default.fileExists(atPath: url.path) else {
                return .error(404, "机位上找不到这段录像。")
            }
            guard session?.state != .active else { return .error(409, "机位正在记录，暂停或结束后再下载录像。") }
            guard transferring == nil, webDownload == nil || webDownload == name else { return .error(409, "机位正在发送另一份录像，请稍后再下载。") }
            webDownload = name
            return .file(url, contentType: "video/quicktime", downloadName: name) { [weak self] in
                Task { @MainActor in if self?.webDownload == name { self?.webDownload = nil } }
            }
        default:
            return .error(404, "没有这个接口。")
        }
    }

    /// Cuts (or reuses) an `.mp4` clip for a shot. Concurrent requests for the same window share one cut.
    private func webClip(session id: UUID, shot: TennisShotEvent) async -> Result<URL, Error> {
        let window = ClipExport.window(for: shot)
        let name = "clip-\(shot.id.uuidString.lowercased())-\(Int(window.start * 1000))-\(Int(window.end * 1000)).mp4"
        let url = Self.webClipDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return .success(url) }
        if let job = webClipJobs[name] { return await job.value }
        guard let store else { return .failure(CourtError.message("会话目录不可用。")) }
        let job = Task { @MainActor [weak self] () -> Result<URL, Error> in
            guard let self else { return .failure(CourtError.message("机位已关闭。")) }
            let temporary = url.deletingPathExtension().appendingPathExtension("part.mp4")
            switch await self.makeClip(session: id, stream: shot.streamID, from: window.start, to: window.end, store: store, into: temporary) {
            case .failure(let error): return .failure(error)
            case .success(let clip):
                do {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: clip.url, to: url)
                    return .success(url)
                } catch { return .failure(error) }
            }
        }
        webClipJobs[name] = job
        let result = await job.value
        webClipJobs[name] = nil
        return result
    }

    /// Test seam: deliver one analysis snapshot as if the camera-side analyzer produced it.
    func testingDeliver(_ snapshot: TennisAnalysisSnapshot) { handle(snapshot) }
    /// Test seam: a late bounce update for rows already published.
    func testingDeliverLate(_ rows: [TennisShotEvent]) { handleLate(rows) }
    /// Test seam: hold the camera busy, as during a slow pause or finish.
    func testingSetBusy(_ value: Bool) { isBusy = value }

    /// Drops a finished session the user is deleting, so late bounce rows, the 1 s checkpoint or a
    /// display that connects later cannot write it back. Refused while the session is open, the
    /// camera is busy or a recording is still being saved (it would be linked to this session).
    @discardableResult public func forgetFinishedSession(_ id: UUID) -> Bool {
        guard session?.id == id else { return true }
        guard !hasOpenSession, !isBusy, !pipeline.currentCounters.saving else { return false }
        session = nil; dirty = false; sessionChanged = false; finishedSessionID = nil
        dashboardEvents = recentRows
        return true
    }

    // MARK: Persistence and ticking

    private func persist() {
        guard let session, let store else { return }
        do {
            try store.save(session); dirty = false; lastSave = ProcessInfo.processInfo.systemUptime
            if SaveFailure.isMessage(error) { error = nil }      // a later save got everything onto disk
        }
        catch { self.error = SaveFailure.message(error) }
    }

    private func tick() {
        guard !closed else { return }
        counters = pipeline.currentCounters
        metrics = analyzer.currentMetrics
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastSnapshotAt > 4 { tennisAnalysis = nil }
        if appliesLoadPolicy {
            let device = deviceState()
            if loadPolicy.update(thermal: device.thermal, pressure: device.pressure, lowPower: device.lowPowerMode, now: uptime) {
                shed = (loadPolicy.level, loadPolicy.reason)
                if loadPolicy.level >= 4, session?.state == .active {
                    Task { await pause(reason: loadPolicy.reason) }
                }
            }
        }
        if dirty, uptime - lastSave >= 1 { persist() }
        if sessionChanged { sendSession() }
        let current = status
        sendStatus(current)
        logCapture(current)
    }

    /// One capture-log line a second while capturing: a file per capture run, opened on the first
    /// second of capture and closed when capture stops (docs/camera-side-analysis.md §14).
    private func logCapture(_ status: CameraStatus, now: Date = Date()) {
        let t = now.timeIntervalSince1970
        guard capturing else {
            if captureLog.isOpen { captureLog.close(CameraLogLine(kind: .stop, t: t)) }
            return
        }
        if !captureLog.isOpen {
            var start = CameraLogLine(kind: .start, t: t)
            start.app = identity.app; start.hardware = identity.hardware
            start.system = ProcessInfo.processInfo.operatingSystemVersionString
            captureLog.open(start, now: now)
        }
        captureLog.append(CameraLogLine(status: status, t: t, shots: session?.tennisEvents?.count, display: displayConnected,
                                        browsers: webClients, linkPath: linkPath))
    }
}

private struct StoreBox: @unchecked Sendable { let store: SessionStore }
private struct SealResult: @unchecked Sendable { let final: TennisAnalysisSnapshot?; let rows: [TennisShotEvent] }

/// Lets the preview lane reach whichever link is current without touching the main actor.
private final class PreviewSink: @unchecked Sendable {
    private let lock = NSLock()
    private var link: CameraLink?
    func set(_ value: CameraLink?) { lock.lock(); link = value; lock.unlock() }
    func send(_ packet: StreamPacket) -> Bool {
        lock.lock(); let current = link; lock.unlock()
        return current?.sendPreview(packet) ?? false
    }
}

/// Person-detection samples at most every 0.5 s, appended to `<session>-analysis.jsonl`.
final class AnalysisJournal: @unchecked Sendable {
    private let queue = DispatchQueue(label: "court.analysis-journal", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private let directory: URL
    var onError: ((String) -> Void)?
    private var failed = Set<UUID>()
    private struct Entry: Encodable { let elapsed: Double; let snapshot: AnalysisSnapshot }
    init(directory: URL) { self.directory = directory }
    func append(_ snapshot: AnalysisSnapshot, sessionID: UUID, elapsed: Double) {
        lock.lock()
        guard !failed.contains(sessionID) else { lock.unlock(); return }
        guard pending < 16 else {
            failed.insert(sessionID); lock.unlock()
            onError?("磁盘写入积压，已停止本次轨迹日志。会话概要和视频仍独立保存。")
            return
        }
        pending += 1
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do {
                let url = directory.appendingPathComponent("\(sessionID.uuidString)-analysis.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CourtError.message("无法创建分析记录。") }
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                var data = try JSONEncoder().encode(Entry(elapsed: elapsed, snapshot: snapshot)); data.append(10)
                try handle.write(contentsOf: data)
            } catch {
                lock.lock(); let first = failed.insert(sessionID).inserted; lock.unlock()
                if first { onError?(error.localizedDescription) }
            }
        }
    }
    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
