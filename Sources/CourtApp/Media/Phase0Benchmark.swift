#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit
import Darwin
import CourtCore

/// Phase 0 feasibility measurement for camera-side analysis (docs/camera-side-analysis.md).
///
/// Opt-in through the launch environment only, e.g. with `xcrun devicectl device process launch
/// --environment-variables '{"COURT_PHASE0":"1", ...}'`:
/// - `COURT_PHASE0_DURATION` seconds (default 1800)
/// - `COURT_PHASE0_SCREEN` `bright` (live preview) or `dark` (black, no preview layer)
/// - `COURT_PHASE0_BRIGHTNESS` screen brightness 0…1 (default 1.0 bright, 0.1 dark)
/// - `COURT_PHASE0_FOCUS_INTERVAL` source seconds between bounce load probes (default 1.5; 0 disables)
/// - `COURT_PHASE0_LABEL`, `COURT_PHASE0_KEEP_RECORDING=1`
/// - `COURT_PHASE0_BACKEND=independent` measures the in-house live lane (FP16 ball model, 5 Hz persons,
///   rule updates) with a fixed typical behind-baseline camera, so rules and far crops run; its rows are
///   load only, never results. Add `COURT_PHASE0_COURT=auto` on a court to find the court from the image
///   instead, as the App does (the rules only run once it is found).
///
/// Runs capture (1080p60) + 8 Mbps encode + local recording + camera-side analysis with no peer and
/// writes Documents/Phase0/<run>/ {meta.json, samples.jsonl, log.jsonl, summary.json}.
/// It measures software load and thermal behaviour only; it says nothing about analysis accuracy.
public struct Phase0Options: Codable, Sendable {
    public var duration: Double
    public var screen: String
    public var brightness: Double
    public var focusInterval: Double
    public var label: String
    public var keepRecording: Bool
    public var independent = false
    public var automaticCourt = false

    public static var requested: Phase0Options? {
        let env = ProcessInfo.processInfo.environment
        guard env["COURT_PHASE0"] == "1" else { return nil }
        let screen = env["COURT_PHASE0_SCREEN"] == "dark" ? "dark" : "bright"
        let label = (env["COURT_PHASE0_LABEL"] ?? screen).filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return Phase0Options(
            duration: Double(env["COURT_PHASE0_DURATION"] ?? "") ?? 1800,
            screen: screen,
            brightness: min(1, max(0, Double(env["COURT_PHASE0_BRIGHTNESS"] ?? "") ?? (screen == "dark" ? 0.1 : 1.0))),
            focusInterval: max(0, Double(env["COURT_PHASE0_FOCUS_INTERVAL"] ?? "") ?? 1.5),
            label: String(label.prefix(40)),
            keepRecording: env["COURT_PHASE0_KEEP_RECORDING"] == "1",
            independent: env["COURT_PHASE0_BACKEND"] == "independent",
            automaticCourt: env["COURT_PHASE0_COURT"] == "auto")
    }
}

/// Thread-safe drop-reason counter written from the camera queue.
private final class DropCounter: @unchecked Sendable {
    private let lock = NSLock(); private var counts: [String: Int] = [:]
    func add(_ reason: String) { lock.lock(); counts[reason, default: 0] += 1; lock.unlock() }
    var value: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}

@MainActor @Observable
final class Phase0Benchmark {
    let options: Phase0Options
    let engine = CameraEngine()
    private(set) var status = "准备中"
    private(set) var elapsed = 0.0
    private(set) var finished = false
    private(set) var overlay: [String] = []
    private(set) var minuteLine = ""
    private(set) var summaryLines: [String] = []
    @ObservationIgnored private var analyzer: CameraSideAnalyzer?
    @ObservationIgnored private var runDirectory: URL?
    @ObservationIgnored private var samplesFile: FileHandle?
    @ObservationIgnored private var logFile: FileHandle?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var originalBrightness: CGFloat?
    @ObservationIgnored private let drops = DropCounter()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startUptime = 0.0
    @ObservationIgnored private var previousSample: (uptime: Double, cpu: Double, busy: Double, bounce: Double)?
    @ObservationIgnored private var recording: (url: URL, frames: Int, duration: Double)?
    @ObservationIgnored private var recordingError: String?
    @ObservationIgnored private var stopReason: String?
    // Whole-run accumulators for the summary.
    @ObservationIgnored private var all = CameraSideAnalyzer.Timings()
    @ObservationIgnored private var thermalSeconds: [String: Int] = [:]
    @ObservationIgnored private var pressureSeconds: [String: Int] = [:]
    @ObservationIgnored private var firstReached: [String: Double] = [:]
    @ObservationIgnored private var maxLag = 0.0
    @ObservationIgnored private var maxUtilization = 0.0
    @ObservationIgnored private var peakMemory = 0.0
    @ObservationIgnored private var cpuTotal = 0.0
    @ObservationIgnored private var cpuSamples = 0
    @ObservationIgnored private var batteryStart: (level: Float, state: String)?
    @ObservationIgnored private var lastCounters: (delivered: UInt64, drops: UInt64, encoded: UInt64, recorded: Int) = (0, 0, 0, 0)

    init(options: Phase0Options) { self.options = options }

    func start() async {
        guard !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        UIApplication.shared.isIdleTimerDisabled = true
        do { try openRun() } catch { status = "无法创建测量目录：\(error.localizedDescription)"; finished = true; return }
        guard await AVCaptureDevice.requestAccess(for: .video) else { await stop(reason: "相机权限被拒绝"); return }
        let analyzer: CameraSideAnalyzer
        if options.independent {
            var live = IndependentLiveConfiguration.bundled()
            live.automaticCourt = options.automaticCourt
            if !options.automaticCourt { live.camera = .lookingAt(SIMD3(0, 11, 0), from: SIMD3(0, -6.4, 3.2), f: 1260) }   // load only
            status = "正在加载并校验自研模型…"
            analyzer = CameraSideAnalyzer(configuration: nil, independent: live)
        } else {
            guard let models = AnalysisModelLocator.directory else { await stop(reason: "App 内没有分析模型"); return }
            #if targetEnvironment(simulator)
            let configuration = TennisAnalysisConfiguration(modelDirectory: models, nominalFPS: 60, computeUnits: .cpuOnly)
            #else
            let configuration = TennisAnalysisConfiguration(modelDirectory: models, nominalFPS: 60)
            #endif
            status = "正在加载并校验模型…"
            analyzer = CameraSideAnalyzer(configuration: configuration,
                                          loadProbeInterval: options.focusInterval > 0 ? options.focusInterval : nil)
        }
        self.analyzer = analyzer
        while !analyzer.currentMetrics.ready {
            if let error = analyzer.currentMetrics.loadError { await stop(reason: "模型加载失败：\(error)"); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log("models-ready", ["loadSeconds": analyzer.currentMetrics.loadSeconds ?? 0])
        let stream = UUID(), drops = drops
        engine.onPixelFrame = { pixels, pts in analyzer.submit(pixels, pts: pts, streamID: stream) }
        engine.onCaptureDrop = { drops.add($0) }
        engine.onState = { [weak self] state, running in
            Task { @MainActor in self?.log("camera-state", ["state": state, "running": running]) }
        }
        engine.onError = { [weak self] message in
            Task { @MainActor in
                self?.log("camera-error", ["message": message])
                await self?.stop(reason: "相机中断：\(message)")
            }
        }
        engine.pipeline.onRecording = { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let value): self?.recording = (value.url, value.frames, value.duration)
                case .failure(let error): self?.recordingError = error.localizedDescription
                }
            }
        }
        applyBrightness(options.brightness)
        engine.start(rotationAngle: 0, standalone: true)
        if let runDirectory { engine.startLocalRecording(directory: runDirectory, prefix: "Phase0") }
        startUptime = ProcessInfo.processInfo.systemUptime
        batteryStart = (UIDevice.current.batteryLevel, Self.batteryState())
        status = "测量中"
        log("started", ["screen": options.screen, "brightness": options.brightness, "focusInterval": options.focusInterval])
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.finished else { return }
                await self.sample()
                if self.elapsed >= self.options.duration { await self.stop(reason: "到达设定时长"); return }
            }
        }
    }

    /// Scene left the foreground: the camera stops in the background, so the run ends here.
    func sceneChanged(active: Bool) {
        guard started, !finished else { return }
        if active { applyBrightness(options.brightness); log("scene-active", [:]) }
        else { restoreBrightness(); log("scene-inactive", [:]) }
    }

    func requestStop() { Task { await stop(reason: "用户长按提前结束") } }

    private func sample() async {
        guard let analyzer else { return }
        let counters = await withCheckedContinuation { continuation in
            engine.counters { continuation.resume(returning: ($0, $1, $2, $3)) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = now - startUptime
        // Locking would background the app and the system would stop the camera.
        if !UIApplication.shared.isIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = true; log("idle-timer-reasserted", [:]) }
        let metrics = analyzer.currentMetrics, timings = analyzer.drainTimings()
        all.copy += timings.copy; all.anchor += timings.anchor; all.pair += timings.pair
        all.latency += timings.latency; all.bounce += timings.bounce; all.probe += timings.probe
        let cpu = Self.cpuSeconds()
        var utilization = 0.0, bounceUtilization = 0.0, cores = 0.0
        if let previous = previousSample, now > previous.uptime {
            let wall = now - previous.uptime
            utilization = (metrics.analysisBusySeconds - previous.busy) / wall
            bounceUtilization = (metrics.bounceBusySeconds - previous.bounce) / wall
            cores = (cpu - previous.cpu) / wall
            cpuTotal += cores; cpuSamples += 1
        }
        previousSample = (now, cpu, metrics.analysisBusySeconds, metrics.bounceBusySeconds)
        let lag = max(0, (metrics.latestSubmittedPTS ?? 0) - (metrics.lastAnalyzedPTS ?? metrics.latestSubmittedPTS ?? 0))
        let memory = Self.footprintMB()
        maxLag = max(maxLag, lag); maxUtilization = max(maxUtilization, utilization); peakMemory = max(peakMemory, memory)
        let thermal = Self.thermalName(ProcessInfo.processInfo.thermalState)
        let pressure = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)?.systemPressureState
        let pressureLevel = pressure?.level.rawValue ?? "unavailable"
        thermalSeconds["thermal-\(thermal)", default: 0] += 1; pressureSeconds["pressure-\(pressureLevel)", default: 0] += 1
        for key in ["thermal-\(thermal)", "pressure-\(pressureLevel)"] where firstReached[key] == nil { firstReached[key] = elapsed }
        lastCounters = (counters.0, counters.1, counters.2, counters.3)
        let row: [String: Any] = [
            "t": round(elapsed * 10) / 10, "thermal": thermal, "pressure": pressureLevel,
            "pressureFactors": pressure.map { Int($0.factors.rawValue) } ?? -1,
            "battery": UIDevice.current.batteryLevel, "batteryState": Self.batteryState(),
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "brightness": Double(currentBrightness ?? -1),
            "delivered": counters.0, "captureDrops": counters.1, "encoded": counters.2, "recorded": counters.3,
            "pairs": metrics.pairs, "copies": metrics.copies, "restarts": metrics.restarts, "resyncs": metrics.resyncs,
            "pixelMisses": metrics.pixelMisses, "poolExhausted": metrics.poolExhausted, "queueOverflows": metrics.queueOverflows,
            "engineErrors": metrics.engineErrors, "pending": metrics.pendingFrames, "maxPending": metrics.maximumPendingFrames,
            "lagSeconds": round(lag * 1000) / 1000, "analysisUtilization": round(utilization * 1000) / 1000,
            "bounceUtilization": round(bounceUtilization * 1000) / 1000, "probes": metrics.probes,
            "probesSkippedBusy": metrics.probesSkippedBusy, "probeCandidates": metrics.probeCandidates, "bounceRequests": metrics.bounceRequests, "shots": metrics.shots,
            "pairP50": Self.percentile(timings.pair, 0.5), "pairMax": timings.pair.max() ?? 0,
            "latencyP50": Self.percentile(timings.latency, 0.5), "copyP50": Self.percentile(timings.copy, 0.5),
            "probeMs": timings.probe, "bounceMs": timings.bounce, "memoryMB": round(memory), "cpuCores": round(cores * 100) / 100,
            // in-house lane (zero for S家): per-frame scale, ball batches, person samples, published rows
            "inHouse": metrics.inHouse, "scaleP50": Self.percentile(timings.scale, 0.5), "scaleMax": timings.scale.max() ?? 0,
            "scaledFrames": metrics.scaledFrames, "ballBatches": metrics.ballBatches, "ballResets": metrics.ballResets,
            "ballInferenceSeconds": metrics.ballInferenceSeconds, "personSamplesLive": metrics.personSamplesLive,
            "personSecondsLive": metrics.personSecondsLive, "publishedShots": metrics.publishedShots,
            "courtSolves": metrics.courtSolves, "courtSolveSeconds": metrics.courtSolveSeconds, "courtFound": metrics.courtFound,
            "courtMoved": metrics.courtMoved, "courtLost": metrics.courtLost
        ]
        write(row, to: samplesFile)
        overlay = [
            String(format: "Phase 0 · %@ · %d:%02d / %d 分", options.screen, Int(elapsed) / 60, Int(elapsed) % 60, Int(options.duration / 60)),
            String(format: "帧对 p50 %.1f ms · 最大 %.0f ms · 分析占用 %.0f%%", Self.percentile(timings.pair, 0.5), timings.pair.max() ?? 0, utilization * 100),
            String(format: "滞后 %.2f s · 待处理 %d · 重置 %d · 缓冲满 %d", lag, metrics.pendingFrames, max(0, metrics.restarts - 1), metrics.poolExhausted),
            "采集 \(counters.0) 帧 · 丢帧 \(counters.1) · 录像 \(counters.3) 帧",
            "热状态 \(thermal) · 相机压力 \(pressureLevel) · 电量 \(Self.percent(UIDevice.current.batteryLevel)) · CPU \(String(format: "%.1f", cores)) 核"
        ]
        if Int(elapsed) % 60 == 0 || minuteLine.isEmpty {
            minuteLine = "测量中 \(Int(elapsed) / 60) 分 · 热状态 \(thermal) · 电量 \(Self.percent(UIDevice.current.batteryLevel))"
        }
    }

    private func stop(reason: String) async {
        guard !finished, stopReason == nil else { return }
        stopReason = reason
        loop?.cancel(); loop = nil
        status = "正在结束：\(reason)"
        log("stopping", ["reason": reason])
        if started, analyzer != nil { await sample() }
        // finish() closes admission; frames still arriving from the camera queue are ignored.
        var events: [TennisShotEvent] = []
        var metrics = analyzer?.currentMetrics
        if let analyzer {
            let result = await withCheckedContinuation { continuation in
                analyzer.finish { events, metrics in continuation.resume(returning: (events, metrics)) }
            }
            events = result.0; metrics = result.1
            let rest = analyzer.drainTimings()
            all.pair += rest.pair; all.anchor += rest.anchor; all.copy += rest.copy
            all.latency += rest.latency; all.bounce += rest.bounce; all.probe += rest.probe
        }
        await withCheckedContinuation { continuation in engine.finishLocalRecording { continuation.resume() } }
        await engine.shutdown()
        try? await Task.sleep(for: .milliseconds(200))
        let movie = recording?.url
        let gaps = await Task.detached { movie.flatMap { Self.recordingGaps($0) } }.value
        var recordingBytes: Int?
        if let recording {
            recordingBytes = (try? recording.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if !options.keepRecording { try? FileManager.default.removeItem(at: recording.url) }
        }
        restoreBrightness()
        UIApplication.shared.isIdleTimerDisabled = false
        writeSummary(reason: reason, metrics: metrics, shots: events.count, gaps: gaps, recordingBytes: recordingBytes)
        try? samplesFile?.close(); try? logFile?.close()
        finished = true; status = "测量完成：\(reason)"
    }

    private func writeSummary(reason: String, metrics: CameraSideAnalyzer.Metrics?, shots: Int,
                              gaps: (count: Int, maxMilliseconds: Double, frames: Int)?, recordingBytes: Int?) {
        func stats(_ values: [Double]) -> [String: Any] {
            ["count": values.count, "p50": Self.percentile(values, 0.5), "p95": Self.percentile(values, 0.95),
             "p99": Self.percentile(values, 0.99), "max": values.max() ?? 0,
             "mean": values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)]
        }
        let batteryEnd = UIDevice.current.batteryLevel
        let hours = max(elapsed, 1) / 3600
        let restarts = max(0, (metrics?.restarts ?? 0) - 1)
        let keepsUp = (metrics?.poolExhausted ?? 1) == 0 && (metrics?.queueOverflows ?? 1) == 0 &&
            (metrics?.pixelMisses ?? 1) == 0 && (metrics?.engineErrors ?? 1) == 0 && restarts == 0 && maxLag < 1
        let thermalOK = thermalSeconds["thermal-critical"] == nil &&
            pressureSeconds["pressure-critical"] == nil && pressureSeconds["pressure-shutdown"] == nil
        let m = metrics ?? CameraSideAnalyzer.Metrics()
        let optionsRow: [String: Any] = ["screen": options.screen, "brightness": options.brightness,
                                         "focusInterval": options.focusInterval, "duration": options.duration, "label": options.label]
        let timingRow: [String: Any] = ["pair": stats(all.pair), "anchor": stats(all.anchor), "copy": stats(all.copy),
                                        "pairLatency": stats(all.latency), "probe": stats(all.probe), "bounce": stats(all.bounce)]
        let captureRow: [String: Any] = ["delivered": lastCounters.delivered, "drops": lastCounters.drops,
                                         "dropReasons": drops.value, "encoded": lastCounters.encoded]
        var recordingRow: [String: Any] = ["frames": recording?.frames ?? 0, "durationSeconds": recording?.duration ?? 0,
                                           "bytes": recordingBytes ?? 0, "kept": options.keepRecording]
        recordingRow["error"] = recordingError ?? "none"
        recordingRow["ptsGapsOver1_8Frames"] = gaps?.count ?? -1
        recordingRow["maxGapMs"] = gaps?.maxMilliseconds ?? -1
        recordingRow["loggedFrames"] = gaps?.frames ?? -1
        var analysisRow: [String: Any] = ["pairs": m.pairs, "snapshots": m.snapshots, "shots": shots,
                                          "temporalRestartsAfterStart": restarts, "resyncs": m.resyncs, "pixelMisses": m.pixelMisses,
                                          "poolExhausted": m.poolExhausted, "queueOverflows": m.queueOverflows]
        analysisRow["engineErrors"] = m.engineErrors
        analysisRow["lastError"] = m.lastError ?? "none"
        analysisRow["maximumPendingFrames"] = m.maximumPendingFrames
        analysisRow["maxLagSeconds"] = maxLag
        analysisRow["maxAnalysisUtilization"] = maxUtilization
        analysisRow["meanAnalysisUtilization"] = elapsed > 0 ? m.analysisBusySeconds / elapsed : 0
        analysisRow["meanBounceUtilization"] = elapsed > 0 ? m.bounceBusySeconds / elapsed : 0
        analysisRow["probes"] = m.probes
        analysisRow["probesSkippedBusy"] = m.probesSkippedBusy
        analysisRow["probeCandidates"] = m.probeCandidates
        analysisRow["bounceRequests"] = m.bounceRequests
        analysisRow["bounceRejectedBusy"] = m.bounceRejectedBusy
        analysisRow["modelLoadSeconds"] = m.loadSeconds ?? 0
        let levels: [String: Int] = thermalSeconds.merging(pressureSeconds) { a, _ in a }
        let thermalRow: [String: Any] = ["secondsByLevel": levels, "firstReachedSeconds": firstReached,
                                         "endThermal": Self.thermalName(ProcessInfo.processInfo.thermalState)]
        let startLevel: Float = batteryStart?.level ?? -1
        let dropPerHour: Float = batteryStart == nil ? -1 : (startLevel - batteryEnd) / Float(hours)
        let powerRow: [String: Any] = ["batteryStart": startLevel, "batteryEnd": batteryEnd,
                                       "batteryStateStart": batteryStart?.state ?? "unknown", "batteryStateEnd": Self.batteryState(),
                                       "dropPerHour": dropPerHour, "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled]
        let meanCores: Double = cpuSamples > 0 ? cpuTotal / Double(cpuSamples) : 0
        let processRow: [String: Any] = ["peakMemoryMB": peakMemory, "meanCPUCores": meanCores]
        let gateRow: [String: Any] = ["keepsUp": keepsUp, "noCaptureDrops": lastCounters.drops == 0,
                                      "thermalNotCritical": thermalOK, "recordingContinuous": (gaps?.count ?? 1) == 0]
        var summary: [String: Any] = ["reason": reason, "elapsedSeconds": round(elapsed)]
        summary["options"] = optionsRow; summary["timingsMs"] = timingRow; summary["capture"] = captureRow
        summary["recording"] = recordingRow; summary["analysis"] = analysisRow; summary["thermal"] = thermalRow
        summary["power"] = powerRow; summary["process"] = processRow; summary["indicativeGate"] = gateRow
        if let runDirectory {
            summary["runDirectory"] = runDirectory.lastPathComponent
            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: runDirectory.appendingPathComponent("summary.json"), options: .atomic)
            }
        }
        summaryLines = [
            "结束原因：\(reason) · \(Int(elapsed / 60)) 分 \(Int(elapsed) % 60) 秒",
            String(format: "帧对 p50 %.1f / p95 %.1f / 最大 %.0f ms", Self.percentile(all.pair, 0.5), Self.percentile(all.pair, 0.95), all.pair.max() ?? 0),
            String(format: "触地探针 p50 %.0f / 最大 %.0f ms · %d 次", Self.percentile(all.probe, 0.5), all.probe.max() ?? 0, all.probe.count),
            "时序重置 \(restarts) · 缓冲满 \(metrics?.poolExhausted ?? 0) · 采集丢帧 \(lastCounters.drops) · 录像缺口 \(gaps?.count ?? -1)",
            "电量 \(Self.percent(batteryStart?.level ?? -1)) → \(Self.percent(batteryEnd)) · 结束热状态 \(Self.thermalName(ProcessInfo.processInfo.thermalState))"
        ]
    }

    // MARK: Files

    private func openRun() throws {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Phase0", isDirectory: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = base.appendingPathComponent("\(formatter.string(from: Date()))-\(options.label)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runDirectory = directory
        for name in ["samples.jsonl", "log.jsonl"] {
            guard FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil) else {
                throw CourtError.message("无法创建 \(name)")
            }
        }
        samplesFile = try FileHandle(forWritingTo: directory.appendingPathComponent("samples.jsonl"))
        logFile = try FileHandle(forWritingTo: directory.appendingPathComponent("log.jsonl"))
        var system = utsname(); uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let meta: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()), "machine": machine,
            "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "app": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?",
            "options": ["duration": options.duration, "screen": options.screen, "brightness": options.brightness,
                        "focusInterval": options.focusInterval, "label": options.label, "keepRecording": options.keepRecording],
            "capture": "1920x1080 60fps H.264 8Mbps local recording", "modelsPresent": AnalysisModelLocator.directory != nil,
            "thermalAtStart": Self.thermalName(ProcessInfo.processInfo.thermalState),
            "batteryAtStart": UIDevice.current.batteryLevel, "batteryStateAtStart": Self.batteryState(),
            "brightnessAtStart": Double(currentBrightness ?? -1), "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled
        ]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
    }

    private func log(_ event: String, _ fields: [String: Any]) {
        var row = fields; row["event"] = event
        row["t"] = startUptime > 0 ? round((ProcessInfo.processInfo.systemUptime - startUptime) * 10) / 10 : 0
        write(row, to: logFile)
    }

    private func write(_ row: [String: Any], to handle: FileHandle?) {
        guard let handle, JSONSerialization.isValidJSONObject(row),
              var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10); try? handle.write(contentsOf: data)
    }

    /// Scans the recorder's per-frame PTS log for gaps above 1.8 source frames.
    nonisolated private static func recordingGaps(_ movie: URL) -> (count: Int, maxMilliseconds: Double, frames: Int)? {
        let url = movie.deletingPathExtension().appendingPathExtension("jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var previous: Double?, gaps = 0, maximum = 0.0, frames = 0
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pts = object["pts"] as? Double else { continue }
            frames += 1
            if let previous { let gap = pts - previous; maximum = max(maximum, gap); if gap > 1.8 / 60 { gaps += 1 } }
            previous = pts
        }
        return (gaps, maximum * 1000, frames)
    }

    // MARK: Device state

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }
    private var currentBrightness: CGFloat? { screen?.brightness }
    private func applyBrightness(_ value: Double) {
        guard let screen else { return }
        if originalBrightness == nil { originalBrightness = screen.brightness }
        screen.brightness = CGFloat(value)
    }
    /// App-set brightness persists until lock, so every exit path restores it.
    private func restoreBrightness() {
        guard let original = originalBrightness, let screen else { return }
        screen.brightness = original; originalBrightness = nil
    }

    nonisolated private static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return (sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q + 0.5))] * 10).rounded() / 10
    }
    nonisolated private static func percent(_ level: Float) -> String { level < 0 ? "—" : "\(Int((level * 100).rounded()))%" }
    nonisolated private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious"; case .critical: "critical"; @unknown default: "unknown" }
    }
    private static func batteryState() -> String {
        switch UIDevice.current.batteryState { case .unplugged: "unplugged"; case .charging: "charging"; case .full: "full"; default: "unknown" }
    }
    nonisolated private static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 +
            Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
    nonisolated private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// Root view for a Phase 0 run. Bright mode shows the live preview; dark mode mounts no preview
/// layer at all and refreshes one dim line per minute. A 2-second long press ends the run early.
public struct Phase0Root: View {
    @State private var benchmark: Phase0Benchmark
    @Environment(\.scenePhase) private var scenePhase
    public init(options: Phase0Options) { _benchmark = State(initialValue: Phase0Benchmark(options: options)) }
    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if benchmark.finished {
                VStack(alignment: .leading, spacing: 8) {
                    Text(benchmark.status).font(.headline)
                    ForEach(benchmark.summaryLines, id: \.self) { Text($0).font(.caption.monospacedDigit()) }
                    Text("结果在 App 文稿的 Phase0 目录。").font(.caption).foregroundStyle(.secondary)
                }.padding(24).foregroundStyle(.white)
            } else if benchmark.options.screen == "bright" {
                CameraPreview(session: benchmark.engine.session).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 4) {
                    Text(benchmark.status).font(.caption.bold())
                    ForEach(benchmark.overlay, id: \.self) { Text($0).font(.caption2.monospacedDigit()) }
                }.padding(10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8)).padding(16)
                    .foregroundStyle(.white)
            } else {
                Text(benchmark.minuteLine.isEmpty ? benchmark.status : benchmark.minuteLine)
                    .font(.caption2.monospacedDigit()).foregroundStyle(Color(white: 0.35)).padding(24)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 2) { benchmark.requestStop() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .task { await benchmark.start() }
        .onChange(of: scenePhase) { _, phase in benchmark.sceneChanged(active: phase == .active) }
        .accessibilityIdentifier("court.phase0")
    }
}
#endif
