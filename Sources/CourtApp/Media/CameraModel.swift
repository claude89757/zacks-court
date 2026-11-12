import Foundation
import Observation
import AVFoundation
import CourtCore
#if os(iOS)
import UIKit
#endif

/// Camera role: capture (`CameraEngine`), the camera-side session authority
/// (`CameraSessionController`, created when the role is entered) and the standby screen.
@MainActor @Observable
final class CameraModel {
    var streaming = false
    var error: String?
    let engine = CameraEngine()
    let standby = CameraStandby()
    private(set) var controller: CameraSessionController?
    /// Minute counter for the standby screen's text; refreshed by the workspace ticker.
    var standbyMinute = 0
    @ObservationIgnored private var recordingSince: Date?
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var seenWakeRequests = 0
    #if os(iOS)
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationDevice: AVCaptureDevice?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var activeCaptureAngle: CGFloat?
    /// Watches the phone's physical orientation while the picture waits for it to be turned landscape.
    @ObservationIgnored private var waitCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var waitObservation: NSKeyValueObservation?
    @ObservationIgnored private var waitPoll: Task<Void, Never>?
    /// Capture stopped for a new orientation; it reopens once the engine reports it stopped.
    @ObservationIgnored private var reopenWhenStopped = false
    #endif
    /// The picture opens as soon as the phone is held landscape (it was portrait or flat).
    private(set) var waitingForLandscape = false

    static var hardware: String { CameraIdentity.hardwareModel }
    /// iPhone 13 and later (`CameraHardware`). The simulator reports a real model identifier but has
    /// no camera, so it never qualifies.
    static var isSupportedDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return CameraHardware.isSupported(hardware)
        #endif
    }
    /// Only Phase 0-measured models skip the "load not measured" note.
    static var isMeasuredDevice: Bool { CameraHardware.isMeasured(hardware) }
    /// Why this device cannot be the camera, in the words the user sees.
    static var unsupportedReason: String {
        #if targetEnvironment(simulator)
        return "模拟器没有相机，不能作为机位。"
        #elseif os(macOS)
        // A Mac's model identifier (Mac16,11) means nothing to the user; say what to do instead.
        return "Mac 不能作为机位：机位需要 iPhone 13 或更新的 iPhone。这台 Mac 可以选择「看板」。"
        #else
        return "该设备（\(CameraHardware.name(hardware))）不能作为机位：机位需要 iPhone 13 或更新的 iPhone。"
        #endif
    }

    init() {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        engine.onState = { [weak self] _, streaming in
            Task { @MainActor in
                guard let self else { return }
                self.streaming = streaming
                if !streaming { self.controller?.zoomFactor = nil }
                #if os(iOS)
                if !streaming { self.stopMonitoringRotation() }
                if streaming { self.stopWaitingForLandscape() }
                UIApplication.shared.isIdleTimerDisabled = streaming
                if !streaming, self.reopenWhenStopped {
                    self.reopenWhenStopped = false
                    Task { await self.autoStart() }
                }
                #endif
            }
        }
        engine.onError = { [weak self] message in Task { @MainActor in self?.error = message } }
        engine.onZoom = { [weak self] range, factor in
            Task { @MainActor in
                guard let self else { return }
                self.zoomRange = range; self.zoomFactor = factor
                self.controller?.zoomFactor = range == nil ? nil : factor
            }
        }
        engine.setZoom(committedZoom)
        if Self.zoomDemo {
            zoomRange = CameraZoomRange(formatMaximum: 135, displayMultiplier: 0.5, switchOvers: [2, 8])
            zoomFactor = zoomRange?.clamp(committedZoom) ?? 1
        }
    }

    // MARK: Zoom

    /// Zoom range of the running capture; nil before capture starts or when the camera cannot zoom.
    /// Set by the engine (and by layout tests); views only read it.
    var zoomRange: CameraZoomRange?
    /// Factor the camera applies, or applies at the next start.
    var zoomFactor = 1.0
    /// Remembered per device, like the other camera settings.
    @ObservationIgnored private var committedZoom = UserDefaults.standard.object(forKey: "court.camera.zoom") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(committedZoom, forKey: "court.camera.zoom") }
    }
    /// Zoom is set before recording or while paused; an active recording keeps one framing, so the
    /// court mapping and every trajectory in it refer to the same picture.
    var zoomLocked: Bool { controller?.session?.state == .active }
    /// UI tests only (`COURT_UI_ZOOM_DEMO=1` in the launch environment): show a triple camera's zoom
    /// presets without a camera, so their layout and gestures can be checked on simulators.
    /// Nothing is captured; the factor is saved like a real one.
    static let zoomDemo = ProcessInfo.processInfo.environment["COURT_UI_ZOOM_DEMO"] == "1"
    /// The zoom presets are on screen: while capturing, or in the UI-test demo.
    var showsZoom: Bool { (streaming || Self.zoomDemo) && zoomRange != nil }
    var canZoom: Bool { showsZoom && !zoomLocked }
    /// During a pinch: the camera follows the fingers; analysis restarts once, when the pinch ends.
    func previewZoom(_ factor: Double) {
        guard canZoom, let zoomRange else { return }
        let value = zoomRange.clamp(factor)
        zoomFactor = value; engine.setZoom(value)
    }
    func commitZoom(_ factor: Double) {
        guard showsZoom, let zoomRange else { return }
        // A recording that started mid-pinch (from a display) locks zoom, but the camera already
        // moved: keep that framing and still restart analysis and the court search for it.
        let value = zoomLocked ? zoomFactor : zoomRange.clamp(factor)
        if !zoomLocked { zoomFactor = value; engine.setZoom(value) }
        guard abs(value - committedZoom) > 0.001 else { return }
        committedZoom = value
        controller?.framingChanged()
    }

    // MARK: Role lifecycle

    func activate(storageDirectory: URL) {
        guard controller == nil else { return }
        let configuration = AnalysisModelLocator.directory.map { directory in
            #if targetEnvironment(simulator)
            return TennisAnalysisConfiguration(modelDirectory: directory, computeUnits: .cpuOnly)
            #else
            return TennisAnalysisConfiguration(modelDirectory: directory)
            #endif
        }
        #if os(iOS)
        let name = CameraHardware.name(Self.hardware) + " 机位"
        #else
        let name = (Host.current().localizedName ?? "Mac") + " 机位"
        #endif
        // 自研 selected (or the only bundled set): the in-house live lane replaces the S家 models.
        let analyzer = CourtAnalysisBackend.effective() == .independent
            ? CameraSideAnalyzer(configuration: nil, independent: .bundled()) : nil
        let controller = CameraSessionController(
            storageDirectory: storageDirectory, configuration: configuration,
            identity: CameraIdentity(device: name, hardware: Self.hardware, app: CameraIdentity.appVersion),
            pipeline: engine.pipeline, analyzer: analyzer)
        let engine = engine, standby = standby
        controller.deviceState = { Self.deviceState(pressure: engine.pressureLevel, exposure: engine.exposure, standby: standby.isDimmed) }
        controller.extraWarnings = { [weak self] in self?.selfCheckWarnings ?? [] }
        controller.onWebCredentials = { value in
            if let value { WebDisplayKeychain.save(value) } else { WebDisplayKeychain.delete() }
        }
        self.controller = controller
        if webDisplayEnabled { controller.startWebDisplay(credentials: WebDisplayKeychain.load()) }
    }

    // MARK: Browser display (docs/web-display.md)

    /// Remembered per device; on until the user turns it off (the main way to connect a display).
    var webDisplayEnabled = UserDefaults.standard.object(forKey: "court.web-display.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(webDisplayEnabled, forKey: "court.web-display.enabled") }
    }
    func setWebDisplay(_ enabled: Bool) {
        webDisplayEnabled = enabled
        if enabled { controller?.startWebDisplay(credentials: WebDisplayKeychain.load()) } else { controller?.stopWebDisplay() }
    }
    /// The listener can be dropped while the app is in the background; listen again on return.
    func resumeWebDisplay() {
        guard webDisplayEnabled, let controller else { return }
        switch controller.webState {
        case .listening, .starting: return
        case .off, .failed: controller.startWebDisplay(credentials: controller.webCredentials ?? WebDisplayKeychain.load())
        }
    }
    var webAddresses: [String] { LocalNetwork.ipv4Addresses() }
    var webStatus: String {
        guard let controller else { return "" }
        switch controller.webState {
        case .off: return "未开启"
        case .starting: return "正在开启…"
        case .failed(let reason): return "无法开启：" + reason
        case .listening:
            if webAddresses.isEmpty { return "没有可用的局域网地址：请连接 Wi-Fi 或打开个人热点" }
            return controller.webClients == 0 ? "等待浏览器连接" : "已连接 \(controller.webClients) 个浏览器"
        }
    }

    /// Any display at all: the App display or at least one browser.
    var anyDisplayConnected: Bool { connected || (controller?.webClients ?? 0) > 0 }
    /// One line for the preview: the App display first, then browsers, then standalone.
    var displayStatus: String {
        let browsers = controller?.webClients ?? 0
        switch controller?.linkState ?? .unpaired {
        case .connected:
            return browsers > 0 ? status + " · \(browsers) 个浏览器" : status
        case .unpaired:
            return browsers > 0 ? "已连接 \(browsers) 个浏览器看板" : "单机模式 · 未连接看板"
        default:
            return browsers > 0 ? status + " · \(browsers) 个浏览器" : status
        }
    }

    func shutdown() async {
        standby.teardown()
        lifecycle = UUID()
        #if os(iOS)
        stopMonitoringRotation(); stopWaitingForLandscape(); reopenWhenStopped = false
        #endif
        await controller?.shutdown()
        await engine.shutdown()
        controller = nil; streaming = false
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    /// iOS stops the camera in the background; the session pauses and resumes on the user's word.
    func suspendForBackground() async {
        standby.suspend()
        #if os(iOS)
        stopWaitingForLandscape(); reopenWhenStopped = false
        #endif
        guard streaming else { return }
        let wasRecording = controller?.session?.state == .active
        stop()
        guard wasRecording else { return }
        let reason = "应用进入后台，采集已停止，记录已暂停。回到 App 后画面会自动打开，再点「继续」接着记录。"
        await controller?.pause(reason: reason)
        if controller?.session?.state != .active { controller?.notice = reason }
    }

    // MARK: Pairing

    var ticket: PairingTicket? { controller?.ticket }
    var connected: Bool { controller?.linkState == .connected }
    var status: String {
        switch controller?.linkState ?? .unpaired {
        case .unpaired: return "单机模式 · 未连接看板"
        case .connecting: return "正在连接看板…"
        case .waiting(let reason): return "看板连接中断，正在重连（\(reason == CourtConnection.peerClosed ? "看板已断开" : reason)）· 录像与分析照常进行"
        case .connected: return "已连接看板" + (controller?.displayName.map { " · \($0)" } ?? "") + (controller?.linkPath.map { " · \($0.title)" } ?? "")
        case .failed(let reason): return reason
        }
    }
    func pair(_ value: String) {
        do {
            let parsed = try PairingTicket.parse(value)
            error = nil; controller?.pair(parsed)
        } catch { self.error = error.localizedDescription }
    }
    func reconnect() { if let ticket { error = nil; controller?.pair(ticket) } }
    func unpair() { controller?.unpair() }

    // MARK: Capture

    func start() async {
        guard !streaming else { return }
        autoStartWanted = true
        guard Self.isSupportedDevice else { error = Self.unsupportedReason; return }
        lifecycle = UUID()
        let token = lifecycle
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard token == lifecycle else { return }
        guard allowed else { error = "请在系统设置中允许 Zacks Court 使用相机。"; return }
        #if os(iOS)
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.interfaceOrientation
        guard orientation == .landscapeLeft || orientation == .landscapeRight else {
            error = "正在切换横屏。请将设备横放并固定后再开始采集。"
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            error = "没有可用的后置主摄像头。"; return
        }
        stopMonitoringRotation()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        let angle = Self.cardinalAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        // Held portrait or lying flat: the recording would be sideways. Like a camera app that only
        // films landscape, wait for the turn instead of asking for a second tap.
        guard angle == 0 || angle == 180 else { error = nil; waitForLandscape(device); return }
        stopWaitingForLandscape()
        rotationDevice = device; rotationCoordinator = coordinator; activeCaptureAngle = angle
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
            let nextAngle = Self.cardinalAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
            Task { @MainActor in
                guard let self, let active = self.activeCaptureAngle, active != nextAngle else { return }
                await self.orientationChanged()
            }
        }
        error = nil; engine.start(rotationAngle: angle)
        #else
        error = nil; engine.start()
        #endif
    }
    /// Measurement and autopilot runs: same device allowlist, landscape angle 0 without the
    /// physical-orientation check (the phone may lie flat on a desk).
    func startForMeasurement() async {
        guard !streaming else { return }
        guard Self.isSupportedDevice else { error = Self.unsupportedReason; return }
        guard await AVCaptureDevice.requestAccess(for: .video) else { error = "请在系统设置中允许 Zacks Court 使用相机。"; return }
        error = nil; engine.start(rotationAngle: 0)
    }
    /// The picture opens by itself when camera mode starts and when the app returns to the
    /// foreground, without the user tapping 开始采集. A session paused meanwhile stays paused.
    /// After the user taps 停止采集 it waits for them until they start again.
    private(set) var autoStartWanted = true
    /// The placeholder can promise the picture: it opens on its own on this device.
    var opensAutomatically: Bool { autoStartWanted && Self.isSupportedDevice && CameraAutopilot.requested == nil }
    func autoStart() async {
        guard autoStartWanted, !streaming, Self.isSupportedDevice, CameraAutopilot.requested == nil else { return }
        // Ask for the camera the moment camera mode opens, not after the phone is turned.
        let token = lifecycle
        guard await AVCaptureDevice.requestAccess(for: .video) else { error = "请在系统设置中允许 Zacks Court 使用相机。"; return }
        guard token == lifecycle, autoStartWanted, !streaming else { return }
        #if os(iOS)
        // Entering camera mode turns the screen to landscape; wait for it instead of reporting an error.
        func landscape() -> Bool {
            let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?.interfaceOrientation
            return orientation == .landscapeLeft || orientation == .landscapeRight
        }
        for _ in 0..<20 where !landscape() { try? await Task.sleep(for: .milliseconds(150)) }
        guard landscape(), autoStartWanted, !streaming, controller != nil else { return }
        #endif
        await start()
    }
    func stopByUser() { autoStartWanted = false; stop() }

    func stop() {
        lifecycle = UUID()
        #if os(iOS)
        stopMonitoringRotation(); stopWaitingForLandscape(); reopenWhenStopped = false
        #endif
        engine.stop()
    }

    #if os(iOS)
    /// The phone turned while capturing (flipped, picked up, or the mount slipped). The capture
    /// direction is fixed per stream, so capture restarts; a running record pauses and waits for 继续.
    private func orientationChanged() async {
        lifecycle = UUID(); stopMonitoringRotation()
        reopenWhenStopped = autoStartWanted
        let wasRecording = controller?.session?.state == .active
        engine.stop()
        guard wasRecording else { return }
        let reason = "手机方向已改变，记录已暂停。横放固定后画面会自动恢复，再点「继续」接着记录。"
        await controller?.pause(reason: reason)
        // Stopping capture may pause first with the generic reason; this one says what happened.
        if controller?.session?.state != .active { controller?.notice = reason }
    }
    /// Opens the picture once the phone is held landscape. Cancelled by 停止采集, background and leaving.
    private func waitForLandscape(_ device: AVCaptureDevice) {
        waitingForLandscape = true
        guard waitCoordinator == nil else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        waitCoordinator = coordinator
        let check: @MainActor (Bool) -> Void = { [weak self] fresh in
            guard let self, self.waitingForLandscape, let coordinator = self.waitCoordinator else { return }
            // Now and then read a new coordinator too, in case the observed one went stale.
            let reading = fresh ? AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil) : coordinator
            let angle = Self.cardinalAngle(reading.videoRotationAngleForHorizonLevelCapture)
            guard angle == 0 || angle == 180 else { return }
            self.stopWaitingForLandscape()
            Task { await self.autoStart() }
        }
        waitObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { _, _ in
            Task { @MainActor in check(false) }
        }
        // The observation is the fast path; a slow poll covers a missed change.
        waitPoll = Task { @MainActor in
            var polls = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                polls += 1
                check(polls % 5 == 0)
            }
        }
    }
    private func stopWaitingForLandscape() {
        waitingForLandscape = false
        waitObservation = nil; waitCoordinator = nil
        waitPoll?.cancel(); waitPoll = nil
    }
    #endif

    // MARK: Self-check and device state

    /// Short pre-recording health check on a measured device. It reports this run's anomalies;
    /// it never admits an unmeasured model.
    var selfCheckWarnings: [String] {
        guard let controller else { return [] }
        var warnings: [String] = []
        let metrics = controller.metrics
        if let failure = metrics.loadError { warnings.append("分析模型未能加载（\(failure)），本次只录像。") }
        else if streaming, metrics.ready, !metrics.tennisAvailable { warnings.append("分析模型不可用，本次只录像。") }
        if streaming, metrics.pictureMoving {
            warnings.append("画面在动：暂不记击球，录像照常。把机位架稳或靠住，画面停稳后自动继续。")
        }
        if streaming, let lag = controller.analysisLag, lag > CameraLoadPolicy.lagHighSeconds {
            warnings.append(Self.lagWarning(lag, shed: controller.shed.level, cause: controller.shedCause,
                                            thermal: ProcessInfo.processInfo.thermalState))
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { warnings.append("低电量模式已开启，可能影响实时分析：接上电源后在设置里关闭低电量模式。") }
        switch ProcessInfo.processInfo.thermalState {
        case .serious: warnings.append("机位温度偏高：把机位移到阴凉处、避开阳光直射，取下手机壳。")
        case .critical: warnings.append("机位过热：遮阳降温，必要时暂停记录。")
        default: break
        }
        // Only recent drops: one dropped frame early on must not keep a warning up for the whole record.
        if let latest = controller.counters.latestPTS, let drop = controller.counters.lastCaptureDropPTS, latest - drop <= 30 {
            warnings.append("最近 30 秒相机丢帧：关掉其他占用相机或耗电的 App，或让机位降温。")
        }
        return warnings
    }

    /// The camera page's analysis-lag line. It suggests cooling only when the phone is warm: lag on a
    /// cool phone comes from the work itself, and the camera sheds load for it on its own.
    nonisolated static func lagWarning(_ lag: Double, shed: Int, cause: CameraLoadPolicy.Cause?,
                                       thermal: ProcessInfo.ThermalState) -> String {
        let text = String(format: "实时分析落后 %.1f 秒：录像不受影响", lag)
        if cause == .lag, shed >= 2 { return text + "。" }     // the shedding notice beside it says what was cut
        if cause == .lag, shed == 1 { return text + "，机位已减少预览和人员检测来追赶。" }
        if [.fair, .serious, .critical].contains(thermal) { return text + "，让机位遮阳降温、关掉其他 App 可以缓解。" }
        return text + "；持续落后时机位会自动减少预览和人员检测。关掉机位上其他 App 也有帮助。"
    }

    nonisolated static func deviceState(pressure: String?, exposure: (ms: Double, iso: Double)?, standby: Bool) -> CameraDeviceState {
        var state = CameraDeviceState()
        #if os(iOS)
        let level = MainActor.assumeIsolated { UIDevice.current.batteryLevel }
        let battery = MainActor.assumeIsolated { UIDevice.current.batteryState }
        if level >= 0 { state.battery = Double(level) }
        if battery != .unknown { state.charging = battery == .charging || battery == .full }
        #endif
        state.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state.thermal = "nominal"
        case .fair: state.thermal = "fair"
        case .serious: state.thermal = "serious"
        case .critical: state.thermal = "critical"
        @unknown default: state.thermal = "unknown"
        }
        state.pressure = pressure
        state.exposureMs = exposure.map { ($0.ms * 100).rounded() / 100 }; state.iso = exposure.map { $0.iso.rounded() }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage { state.freeBytes = free }
        state.screen = standby ? "standby" : "live"
        return state
    }

    // MARK: Standby

    /// Standby applies while a session records and the court mapping is usable.
    /// Called once a second by the workspace.
    func tickStandby() {
        guard let controller else { standby.update(eligible: false); return }
        let calibrated = controller.tennisAnalysis?.calibration.isAvailable == true
            || !(controller.metrics.tennisAvailable)
        let recording = controller.session?.state == .active && streaming
        if recording && recordingSince == nil { recordingSince = Date() } else if !recording { recordingSince = nil }
        standby.update(eligible: recording && calibrated)
        if controller.wakeRequests != seenWakeRequests {
            seenWakeRequests = controller.wakeRequests
            standby.wake()
        }
        standby.tick()
        standbyMinute = Int(Date().timeIntervalSince(recordingSince ?? Date()) / 60)
    }
    var standbyLines: [String] {
        var lines = ["REC \(standbyMinute) 分"]
        if let controller {
            if controller.shed.level >= 3 { lines.append("分析：暂停（设备降载）") }
            else if controller.shed.level > 0 { lines.append("分析：降载") }
            else { lines.append(controller.metrics.tennisAvailable ? "分析：正常" : "分析：未运行") }
        }
        lines.append(anyDisplayConnected ? "已连接看板" : "未连接看板 · 本机录像继续")
        #if os(iOS)
        let level = UIDevice.current.batteryLevel
        if level >= 0 { lines.append("电量 \(Int((level * 100).rounded()))%") }
        #endif
        return lines
    }
    var standbyWarning: String? {
        #if os(iOS)
        let level = UIDevice.current.batteryLevel
        if level >= 0, level < 0.15, UIDevice.current.batteryState == .unplugged { return "电量低，请接上电源" }
        #endif
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "设备温度偏高"
        default:
            let drops = controller?.counters.captureDrops ?? 0
            return drops > 0 ? "相机丢帧 \(drops)" : nil
        }
    }

    #if os(iOS)
    nonisolated private static func cardinalAngle(_ angle: CGFloat) -> CGFloat {
        let normalized = (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return (normalized / 90).rounded().truncatingRemainder(dividingBy: 4) * 90
    }
    private func stopMonitoringRotation() {
        rotationObservation = nil; rotationCoordinator = nil; rotationDevice = nil; activeCaptureAngle = nil
    }
    #endif
}
