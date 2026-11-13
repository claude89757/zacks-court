import Foundation

/// The automatic court as the camera saw it at one moment, for field diagnosis: whether a court is in
/// use, how much the picture moves, the solve in use (or the last refused one while searching) and how
/// long solves take on this device. Numbers only, no image. Sent in `status.analysis.court` (optional,
/// older peers ignore it) and written to the camera's capture log once a second.
public struct CameraCourtDiagnostics: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// A court found automatically is in use.
        case found
        /// No court yet, or it was lost: searching.
        case searching
        /// A court given from outside is used as is (no automatic court).
        case fixed
    }
    public enum Motion: String, Codable, Sendable { case still, drifting, shaking }

    public var state: State
    /// Picture motion over the last second (nil before there is anything to compare).
    public var motion: Motion?
    /// Apparent displacement over the last second, full-resolution pixels.
    public var motionPixels: Double?
    /// Lines and alignment of the solve in use, or of the last refused one while searching.
    public var lines: Int?
    public var rmsPixels: Double?
    public var quality: String?
    /// Refusal codes of the last refused solve while searching (`IndependentCourtCalibration.Refusal`).
    public var refusals: [String]?
    /// Camera of the court in use, or of the last refused solve while searching: focal length (px),
    /// height above the court and distance behind the near baseline (m).
    public var focalPixels: Double?
    public var heightMeters: Double?
    public var behindBaselineMeters: Double?
    /// Solves and tracking steps so far on this stream, with their total, longest and latest seconds.
    public var solves = 0
    public var solveSeconds = 0.0
    public var maxSolveSeconds = 0.0
    public var lastSolveSeconds: Double?
    public var found = 0, moved = 0, lost = 0, samples = 0
    /// A solve is running on the utility queue now.
    public var solving = false

    public init(state: State) { self.state = state }

    mutating func geometry(of camera: IndependentPinholeCamera?) {
        guard let camera else { return }
        let c = camera.centre
        focalPixels = camera.f.rounded()
        heightMeters = (c.z * 100).rounded() / 100
        behindBaselineMeters = (-c.y * 100).rounded() / 100
    }

    /// The same with every non-finite number dropped (unknown) or zeroed (totals). JSONEncoder refuses
    /// NaN, and this rides the 1 Hz status and the capture log, so one bad value would cost both.
    public var finiteOnly: CameraCourtDiagnostics {
        func known(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
        func total(_ v: Double) -> Double { v.isFinite ? v : 0 }
        var d = self
        d.motionPixels = known(motionPixels); d.rmsPixels = known(rmsPixels)
        d.focalPixels = known(focalPixels); d.heightMeters = known(heightMeters); d.behindBaselineMeters = known(behindBaselineMeters)
        d.solveSeconds = total(solveSeconds); d.maxSolveSeconds = total(maxSolveSeconds); d.lastSolveSeconds = known(lastSolveSeconds)
        return d
    }
}

/// The in-house lane's region poses since its analysis started: frames read, Vision requests and their
/// seconds, and frames on the poses' cadence passed over because the analysis was behind. The serve rules
/// time a contact only from poses read at least 8 times a second (`IndependentStrokeRules.Swing.densePeriod`),
/// so the rate a phone reaches decides how much of them it gets. Sent in `status.analysis.poses` (optional,
/// older peers ignore it) and written to the camera's capture log once a second.
public struct CameraPoseCounts: Codable, Equatable, Sendable {
    public var frames: Int
    public var requests: Int
    public var seconds: Double
    public var skippedBehind: Int
    public init(frames: Int = 0, requests: Int = 0, seconds: Double = 0, skippedBehind: Int = 0) {
        self.frames = frames; self.requests = requests; self.seconds = seconds.isFinite ? (seconds * 1000).rounded() / 1000 : 0
        self.skippedBehind = skippedBehind
    }
}

/// One line of the camera's capture log (`Diagnostics/capture-*.jsonl`): a `start` line when capture
/// begins (app, hardware and system), a `status` line every second while capturing, and a `stop` line.
/// Written on the camera, so a camera used alone keeps the record a display would otherwise keep.
public struct CameraLogLine: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case start, status, stop }
    public var kind: Kind
    /// Seconds since 1970.
    public var t: Double
    // start
    public var app: String?
    public var hardware: String?
    public var system: String?
    // status
    public var session: UUID?
    public var sessionState: SessionState?
    public var recording: Bool?
    public var fps: Int?
    public var captureDrops: UInt64?
    public var recordingSeconds: Double?
    public var zoom: Double?
    public var thermal: String?
    public var pressure: String?
    /// Exposure time (milliseconds) and ISO of the active camera; nil from older versions.
    public var exposureMs: Double?
    public var iso: Double?
    public var battery: Double?
    public var charging: Bool?
    public var lowPower: Bool?
    public var freeBytes: Int64?
    public var screen: String?
    public var shed: Int?
    public var shedReason: String?
    /// `heat`, `pressure`, `lowPower` or `lag` while shedding.
    public var shedCause: String?
    /// Capture clock minus analysis clock, seconds; frames waiting; analysis restarts so far.
    public var analysisDelay: Double?
    public var pendingFrames: Int?
    public var restarts: Int?
    public var analysisReason: String?
    public var court: CameraCourtDiagnostics?
    /// What the camera screen says about the court.
    public var courtText: String?
    /// Region poses so far (in-house lane, `CameraPoseCounts`); nil from older versions.
    public var poses: CameraPoseCounts?
    public var shots: Int?
    /// An App display is connected; browsers that joined.
    public var display: Bool?
    public var browsers: Int?
    public var linkPath: String?

    public init(kind: Kind, t: Double) { self.kind = kind; self.t = t }

    /// A `status` line from the camera's 1 Hz status.
    public init(status: CameraStatus, t: Double, shots: Int?, display: Bool, browsers: Int, linkPath: LinkPath?) {
        self.init(kind: .status, t: t)
        session = status.sessionID; sessionState = status.sessionState
        recording = status.recording; fps = status.fps; captureDrops = status.captureDrops
        recordingSeconds = status.recordingSeconds.map { ($0 * 10).rounded() / 10 }; zoom = status.zoom
        thermal = status.device.thermal; pressure = status.device.pressure; battery = status.device.battery
        charging = status.device.charging; lowPower = status.device.lowPowerMode; freeBytes = status.device.freeBytes
        screen = status.device.screen; exposureMs = status.device.exposureMs; iso = status.device.iso; shed = status.shed; shedReason = status.shedReason; shedCause = status.shedCause
        let a = status.analysis
        if let latest = a.latestPTS, let analyzed = a.analyzedPTS { analysisDelay = (max(0, latest - analyzed) * 100).rounded() / 100 }
        pendingFrames = a.pendingFrames; restarts = a.restarts; analysisReason = a.reason
        court = a.court; courtText = a.calibration?.reason; poses = a.poses
        self.shots = shots; self.display = display; self.browsers = browsers; self.linkPath = linkPath?.rawValue
    }
}

/// Writes the camera's capture logs: one file per capture run in `Diagnostics/`, so the time before a
/// record starts (mounting the phone, waiting for the court) is kept too. Lines are encoded and written
/// on a utility queue; a file removed meanwhile (the storage page clears logs) is started again.
/// Files older than `keepDays` are removed when a new one starts. Diagnostic only: failures are dropped.
public final class CameraCaptureLog: @unchecked Sendable {
    public static let keepDays = 14.0
    private let directory: URL
    private let queue = DispatchQueue(label: "court.capture-log", qos: .utility)
    private var handle: FileHandle?
    private var url: URL?
    private var header: CameraLogLine?
    /// Main actor: a file is open (or opening) for the current capture run.
    public private(set) var isOpen = false

    public init(storageDirectory: URL) { directory = DiagnosticBundle.folder(in: storageDirectory) }

    /// Starts a new file for a capture run, beginning with `start`.
    public func open(_ start: CameraLogLine, now: Date = Date()) {
        isOpen = true
        let directory = directory
        queue.async { [self] in
            try? handle?.close(); handle = nil
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.prune(directory, now: now)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
            var candidate = directory.appendingPathComponent("capture-\(formatter.string(from: now)).jsonl")
            var n = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("capture-\(formatter.string(from: now))-\(n).jsonl"); n += 1
            }
            url = candidate; header = start
            write(start)
        }
    }

    public func append(_ line: CameraLogLine) {
        guard isOpen else { return }
        queue.async { [self] in write(line) }
    }

    /// Ends the capture run's file with `stop`.
    public func close(_ stop: CameraLogLine? = nil) {
        guard isOpen else { return }
        isOpen = false
        queue.async { [self] in
            if let stop { write(stop) }
            try? handle?.close(); handle = nil; url = nil; header = nil
        }
    }

    /// Waits for queued lines (tests).
    public func flush() { queue.sync {} }

    private func write(_ line: CameraLogLine) {
        guard let url else { return }
        let fm = FileManager.default
        if handle != nil, !fm.fileExists(atPath: url.path) { try? handle?.close(); handle = nil }      // cleared meanwhile
        if handle == nil {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fresh = !fm.fileExists(atPath: url.path)
            if fresh { fm.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            if fresh, line.kind != .start, let header, let data = Self.encode(header) { try? handle?.write(contentsOf: data) }
        }
        if let data = Self.encode(line) { try? handle?.write(contentsOf: data) }
    }

    static func encode(_ line: CameraLogLine) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(line) else { return nil }
        data.append(10)
        return data
    }

    static func prune(_ directory: URL, now: Date) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-keepDays * 86_400)
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard url.lastPathComponent.hasPrefix("capture-"),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }
}

/// One record's diagnostic package: the record JSON, its logs, the camera's capture logs around it and
/// a readable summary, zipped into one file to share. No video (the recording is shared on its own),
/// no pairing secrets. Only what is already stored on this device.
public enum DiagnosticBundle {
    /// Folder of the camera's capture logs, inside the sessions directory.
    public static let folderName = "Diagnostics"
    public static func folder(in storageDirectory: URL) -> URL { storageDirectory.appendingPathComponent(folderName, isDirectory: true) }
    /// Capture logs from this long before a record starts are included (mounting, finding the court).
    public static let leadSeconds = 30.0 * 60

    /// A capture log file with its lines (unreadable lines skipped).
    public struct CaptureLog: Sendable {
        public var url: URL
        public var lines: [CameraLogLine]
        public var start: Double? { lines.first?.t }
        public var end: Double? { lines.last?.t }
    }

    public static func readLog(_ url: URL) -> CaptureLog? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        let lines = text.split(separator: "\n").compactMap { try? decoder.decode(CameraLogLine.self, from: Data($0.utf8)) }
        return lines.isEmpty ? nil : CaptureLog(url: url, lines: lines)
    }

    /// Capture logs overlapping the record, from `leadSeconds` before it starts to a minute after it ends.
    public static func captureLogs(for session: CourtSession, storageDirectory: URL, now: Date = Date()) -> [CaptureLog] {
        let from = session.startedAt.timeIntervalSince1970 - leadSeconds
        let to = (session.endedAt ?? now).timeIntervalSince1970 + 60
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(in: storageDirectory), includingPropertiesForKeys: Array(keys))) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "jsonl" }
            .filter { url in
                // Logs are kept 14 days: a file last written before the window, or begun after it, is not
                // read at all (two weeks of daily use is 100 MB and more). Slack for clocks and buffering.
                let values = try? url.resourceValues(forKeys: keys)
                if let modified = values?.contentModificationDate, modified.timeIntervalSince1970 < from - 120 { return false }
                if let created = values?.creationDate, created.timeIntervalSince1970 > to + 120 { return false }
                return true
            }
            .compactMap(readLog)
            .filter { log in
                guard let start = log.start, let end = log.end else { return false }
                return end >= from && start <= to
            }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    /// Writes `ZacksCourt-diagnostics-<time>.zip` into `folder` and returns it.
    public static func build(session: CourtSession, storageDirectory: URL, into folder: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmm"
        let name = "ZacksCourt-diagnostics-\(formatter.string(from: session.startedAt))"
        let staging = folder.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let id = session.id.uuidString
        for file in ["\(id).json", "\(id)-analysis.jsonl", "\(id)-status.jsonl"] {
            let source = storageDirectory.appendingPathComponent(file)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: staging.appendingPathComponent(file)) }
        }
        let logs = captureLogs(for: session, storageDirectory: storageDirectory, now: now)
        for log in logs { try fm.copyItem(at: log.url, to: staging.appendingPathComponent(log.url.lastPathComponent)) }
        try summary(session: session, logs: logs, now: now).write(to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let zip = folder.appendingPathComponent(name).appendingPathExtension("zip")
        try? fm.removeItem(at: zip)
        try zipDirectory(staging, to: zip)
        return zip
    }

    /// Zips a directory with the system's own archiver (`NSFileCoordinator` `.forUploading`).
    static func zipDirectory(_ directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [.forUploading], error: &coordinationError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: destination) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    // MARK: Summary

    /// A short readable report: what was recorded, how the court went and how the phone held up.
    public static func summary(session: CourtSession, logs: [CaptureLog], now: Date = Date()) -> String {
        var out: [String] = []
        let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "zh_CN"); dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let start = logs.flatMap(\.lines).first { $0.kind == .start }
        out.append(courtText("Zacks Court 诊断包"))
        let state = switch session.state { case .active: courtText("记录中"); case .paused: courtText("已暂停"); case .completed: courtText("已结束"); case .interrupted: courtText("中断") }
        out.append(courtFormat("记录：%1$@ · %2$@ 开始 · %3$@", "\(session.title)", "\(dateFormatter.string(from: session.startedAt))", "\(state)"))
        if let device = session.capturedOn { out.append(courtFormat("机位：%1$@", "\(device)")) }
        if let app = start?.app { out.append("App：\(app)") }
        if let hardware = start?.hardware { out.append(courtFormat("型号：%1$@%2$@", "\(hardware)", "\(start?.system.map { " · \($0)" } ?? "")")) }
        if let model = session.tennisModelVersion { out.append(courtFormat("分析模型：%1$@", "\(model)")) }
        out.append("")

        // shots
        let events = session.tennisEvents ?? []
        let serves = events.filter { $0.stroke == .serve }
        let calls = events.compactMap { $0.bounce?.hawkEye }
        let near = calls.filter { !$0.farHalf }
        func count(_ list: [HawkEyeJudgement], _ call: HawkEyeCall) -> Int { list.filter { $0.call == call }.count }
        out.append(courtText("逐拍"))
        out.append(courtFormat("- 击球 %1$@ 拍，有球速 %2$@ 拍，有落点 %3$@ 拍", "\(events.count)", "\(events.filter { $0.speedKPH != nil }.count)", "\(events.filter { $0.bounce?.xMeters != nil }.count)"))
        out.append(courtFormat("- 发球 %1$@ 拍，有球速 %2$@ 拍", "\(serves.count)", "\(serves.filter { $0.speedKPH != nil }.count)"))
        out.append(courtFormat("- 界内外：近端 %1$@ 个（界内 %2$@、出界 %3$@、压线附近 %4$@），远端 %5$@ 个", "\(near.count)", "\(count(near, .in))", "\(count(near, .out))", "\(count(near, .close))", "\(calls.count - near.count)"))
        let challenges = events.filter { $0.challenge != nil }.count
        if challenges > 0 { out.append(courtFormat("- 挑战 %1$@ 次", "\(challenges)")) }
        out.append("")

        // court
        out.append(courtText("球场识别"))
        if logs.isEmpty {
            out.append(courtText("- 没有机位采集日志（这台设备不是这次记录的机位，或机位用的是还不写采集日志的旧版本）。"))
        }
        for log in logs {
            let lines = log.lines.filter { $0.kind == .status }
            guard let first = log.start else { continue }
            let span = (log.end ?? first) - first
            var text = courtFormat("- 采集 %1$@，共 %2$@ 秒", "\(dateFormatter.string(from: Date(timeIntervalSince1970: first)))", "\(Int(span.rounded()))")
            if let foundAt = lines.first(where: { $0.court?.state == .found })?.t {
                // lines come once a second: the lock is known to the second
                let seconds = foundAt - first
                text += seconds < 1 ? courtText("：开始后 1 秒内认出球场") : courtFormat("：开始后约 %1$@ 秒认出球场", "\(Int(seconds.rounded()))")
            } else if lines.contains(where: { $0.court != nil }) {
                text += courtText("：一直没认出球场")
            } else {
                text += courtText("：没有球场识别数据（没有自研分析）")
            }
            out.append(text)
            let reasons = Dictionary(grouping: lines.compactMap { $0.court?.state == .searching ? $0.courtText : nil }, by: { $0 })
                .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(3)
            for (reason, seconds) in reasons { out.append(courtFormat("  · 「%1$@」%2$@ 秒", "\(reason)", "\(seconds)")) }
        }
        let inSession = logs.flatMap(\.lines).filter { $0.kind == .status && $0.session == session.id && $0.sessionState == .active }
        if !inSession.isEmpty {
            let withCourt = inSession.filter { $0.court?.state == .found || $0.court?.state == .fixed }.count
            out.append(courtFormat("- 记录中 %1$@ 秒，有球场 %2$@ 秒（%3$@）", "\(inSession.count)", "\(withCourt)", "\(percent(withCourt, inSession.count))"))
            let moving = inSession.compactMap(\.court?.motion)
            if !moving.isEmpty {
                let drift = moving.filter { $0 == .drifting }.count, shake = moving.filter { $0 == .shaking }.count
                out.append(courtFormat("- 画面：静止 %1$@，漂移 %2$@，晃动 %3$@", "\(percent(moving.count - drift - shake, moving.count))", "\(percent(drift, moving.count))", "\(percent(shake, moving.count))"))
            }
            let courts = inSession.compactMap(\.court)
            if let last = courts.last {
                out.append(courtFormat("- 丢失球场 %1$@ 次", "\(max(0, last.lost - (courts.first?.lost ?? 0)))"))
            }
            if let last = courts.last, last.solves > 0 {
                out.append(courtPrintf("- 求解和跟踪 %d 次，平均 %.2f 秒，最长 %.2f 秒（本次采集起，在这台设备上）", last.solves, last.solveSeconds / Double(last.solves), last.maxSolveSeconds))
            }
            if let c = courts.last(where: { $0.state == .found }), let h = c.heightMeters, let b = c.behindBaselineMeters {
                out.append(courtPrintf("- 机高约 %.1f 米，在近端底线后约 %.1f 米，焦距 %.0f 像素，%d 条线，对齐误差 %.2f 像素",
                                  h, b, c.focalPixels ?? 0, c.lines ?? 0, c.rmsPixels ?? 0))
            }
        }
        out.append("")

        // phone
        let status = logs.flatMap(\.lines).filter { $0.kind == .status }
        if !status.isEmpty {
            out.append(courtText("手机"))
            let order = ["nominal", "fair", "serious", "critical"]
            let hottest = status.compactMap(\.thermal).max { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            if let hottest { out.append(courtFormat("- 最高温度状态：%1$@", "\(hottest)")) }
            if let shed = status.compactMap(\.shed).max(), shed > 0 {
                // Why it shed, in the order first seen: heat and analysis lag need different fixes.
                var causes: [String] = []
                for line in status where (line.shed ?? 0) > 0 {
                    let name = line.shedCause.map { ["heat": courtText("发热"), "pressure": courtText("相机负载"), "lowPower": courtText("低电量模式"), "lag": courtText("分析落后")][$0] ?? $0 }
                    if let name, !causes.contains(name) { causes.append(name) }
                }
                let seconds = status.filter { ($0.shed ?? 0) > 0 }.count
                out.append(courtFormat("- 最高降载等级：L%1$@，降载 %2$@ 秒", "\(shed)", "\(seconds)") + (causes.isEmpty ? "" : courtFormat("（原因：%1$@）", "\(causes.joined(separator: "、"))")))
            }
            let delays = status.compactMap(\.analysisDelay).sorted()
            if !delays.isEmpty { out.append(courtPrintf("- 分析落后：中位 %.2f 秒，最多 %.2f 秒", delays[delays.count / 2], delays.last!)) }
            let drops = status.compactMap(\.captureDrops)
            if let lastDrop = drops.last, let firstDrop = drops.first { out.append(courtFormat("- 采集丢帧 %1$@ 帧", "\(lastDrop >= firstDrop ? lastDrop - firstDrop : lastDrop)")) }
            let batteries = status.compactMap(\.battery)
            if let a = batteries.first, let b = batteries.last { out.append(courtPrintf("- 电量 %.0f%% → %.0f%%", a * 100, b * 100)) }
            if let poses = poseReport(inSession) { out.append(poses) }
            if let exposure = exposureReport(inSession) { out.append(exposure) }
        }
        out.append("")
        out.append(courtText("文件：<记录ID>.json 是记录本身；capture-*.jsonl 是机位每秒的状态（球场识别、温度、负载、发球人姿态读了几次、曝光）；-analysis.jsonl 是辅助检测；-status.jsonl 是看板收到的机位状态。不含录像和配对密钥。"))
        return out.joined(separator: "\n") + "\n"
    }

    /// How often the server's arm was read while recording with a court: the mean rate, the seconds under
    /// the rate the serve rules need (`IndependentStrokeRules.Swing.densePeriod`), the seconds shed (no
    /// region poses then), the frames passed over while the analysis was behind, and a request's cost on
    /// this phone. Consecutive status lines only: a gap, a new run or a count that went back is skipped.
    /// nil without pose counts (the S家 lane, versions before them).
    static func poseReport(_ lines: [CameraLogLine]) -> String? {
        let need = 1 / IndependentStrokeRules.Swing.densePeriod
        var seconds = 0.0, counted = 0, frames = 0, sparse = 0, shed = 0, skipped = 0, requests = 0, spent = 0.0
        for (a, b) in zip(lines, lines.dropFirst()) {
            guard let pa = a.poses, let pb = b.poses, b.t - a.t > 0.5, b.t - a.t < 2.5,
                  pb.frames >= pa.frames, pb.requests >= pa.requests, pb.skippedBehind >= pa.skippedBehind,
                  b.court?.state == .found || b.court?.state == .fixed else { continue }
            let dt = b.t - a.t, read = pb.frames - pa.frames
            counted += 1; seconds += dt; frames += read
            if Double(read) / dt < need { sparse += 1 }
            if (b.shed ?? 0) > 0 { shed += 1 }
            skipped += pb.skippedBehind - pa.skippedBehind
            requests += pb.requests - pa.requests; spent += max(0, pb.seconds - pa.seconds)
        }
        guard counted > 0, seconds > 0 else { return nil }
        var text = courtPrintf("- 发球人姿态（发球识别和发球球速要每秒 %.0f 次以上）：记录中有球场的 %d 秒里平均每秒读 %.1f 次，不到 %.0f 次的 %d 秒（%@）",
                          need, Int(seconds.rounded()), Double(frames) / seconds, need, sparse, percent(sparse, counted))
        if shed > 0 { text += courtFormat("，其中降载 %1$@ 秒不读", "\(shed)") }
        if skipped > 0 { text += courtFormat("；分析落后时跳过 %1$@ 次", "\(skipped)") }
        if requests > 0 { text += courtPrintf("；每次请求约 %.0f 毫秒", spent / Double(requests) * 1000) }
        return text
    }

    /// The camera's exposure while recording, median and longest (ms), and the median ISO: auto exposure lengthens
    /// it at night, and a fast ball smears over more pixels.
    static func exposureReport(_ lines: [CameraLogLine]) -> String? {
        let ms = lines.compactMap(\.exposureMs).filter(\.isFinite).sorted(), iso = lines.compactMap(\.iso).filter(\.isFinite).sorted()
        guard let longest = ms.last else { return nil }
        var text = courtPrintf("- 曝光：记录中中位 %.1f 毫秒，最长 %.1f 毫秒", ms[ms.count / 2], longest)
        if !iso.isEmpty { text += courtPrintf("，ISO 中位 %.0f", iso[iso.count / 2]) }
        return text + courtText("（曝光越长，快球在画面里拖得越长）")
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        whole > 0 ? String(format: "%.0f%%", Double(part) / Double(whole) * 100) : "—"
    }
}
