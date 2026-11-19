import Foundation

/// Graded load shedding for the camera (docs/camera-side-analysis.md §7). It never lowers the
/// 1080p60 capture or recording; it trims preview, auxiliary detection and analysis instead.
///
/// | Level | Trigger | Effect |
/// | L0 | nominal or fair thermal state with no other demand | normal preview and analysis cadence |
/// | L1 | camera pressure fair, Low Power Mode, or sustained analysis lag | preview 1 frame/s, person detection off (in-house: slower) |
/// | L2 | serious, or analysis lag that L1 did not clear | preview off, court refresh every 10 s, bounce localization off |
/// | L3 | critical | analysis paused, recording continues; the session records an analysis gap |
/// | L4 | camera pressure shutdown | the system is about to stop the camera; the session pauses |
///
/// Rising heat or pressure applies at once. Analysis lag sheds one level after it stays above
/// `lagHighSeconds` for `lagSustainSeconds` without draining, and another level after a further
/// window; it never pauses analysis (L3), which could not clear lag and would leave lag unmeasurable.
/// Falling load lowers one level after 60 s below the current level, then needs another 60 s for
/// the next step; lag counts as fallen once it is below `lagLowSeconds`.
public struct CameraLoadPolicy: Sendable {
    /// What raised the current level. Recovery keeps naming it.
    public enum Cause: String, Codable, Sendable { case heat, pressure, lowPower, lag }

    public static let recoverySeconds = 60.0
    /// Analysis behind capture by more than this counts as lag; the camera page warns from the same point.
    public static let lagHighSeconds = 1.0
    /// Lag below this clears the lag demand (the band in between holds it, so the level does not chatter).
    public static let lagLowSeconds = 0.5
    /// Lag must stay high this long before each step.
    public static let lagSustainSeconds = 5.0
    /// Lag that shrank by at least this much over a window is draining: the current level keeps up.
    public static let lagDrainSeconds = 0.25
    /// The highest level lag asks for. L3 pauses analysis, which cannot make analysis catch up; past
    /// L2 the analyzer's own bounded queue restarts the temporal run instead of falling further behind.
    public static let maximumLagLevel = 2

    public private(set) var level = 0
    public private(set) var reason: String?
    public private(set) var cause: Cause?
    /// The level analysis lag asks for (0 when lag is low).
    public private(set) var lagLevel = 0
    private var belowSince: Double?
    /// Start of the current high-lag window, and the lag then.
    private var lagWindow: (since: Double, lag: Double)?

    public init() {}

    /// Camera pressure as a short level name. The camera reports AVFoundation's raw value
    /// (`AVCaptureSystemPressureLevelFair`, as seen on iPhone18,2); the short name (`fair`) is accepted too.
    public static func pressureName(_ raw: String) -> String {
        let prefix = "AVCaptureSystemPressureLevel"
        return (raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw).lowercased()
    }

    static func thermalLevel(_ thermal: String) -> Int { ["serious": 2, "critical": 3][thermal] ?? 0 }
    static func pressureLevel(_ pressure: String?) -> Int {
        pressure.flatMap { ["fair": 1, "serious": 2, "critical": 3, "shutdown": 4][pressureName($0)] } ?? 0
    }

    /// During the L1 recovery minute, resume serve observations as soon as the limiting signal clears.
    /// A steady fair thermal state already runs everything at L0.
    public func allowsServeDetailAtL1(on device: CameraDeviceState) -> Bool {
        guard level == 1, lagLevel == 0, !device.lowPowerMode,
              device.thermal == "fair" || device.thermal == "nominal" else { return false }
        return device.pressure.map { Self.pressureName($0) == "nominal" } ?? true
    }

    public static func target(thermal: String, pressure: String?, lowPower: Bool) -> (level: Int, reason: String?) {
        let thermalLevel = Self.thermalLevel(thermal), pressureLevel = Self.pressureLevel(pressure)
        let level = max(thermalLevel, pressureLevel, lowPower ? 1 : 0)
        // Name the actual cause: heat and camera pressure need different next steps.
        let source = Self.cause(thermal: thermal, pressure: pressure, lowPower: lowPower)
        let heat = source == .heat
        let cause = heat ? "机位温度偏高" : "机位相机负载高"
        let fix = heat ? "把机位移到阴凉处、避开阳光直射，取下手机壳。" : "关掉机位上其他占用相机或耗电的 App。"
        switch level {
        case 4: return (4, "相机负载达到上限，系统即将停止相机，记录将暂停：\(fix)然后点「开始采集」，再点「继续」。")
        case 3: return (3, (heat ? "机位过热" : "机位相机负载过高") + "：实时分析暂停，录像继续；这段时间的拍次保持为空，结束后可在历史记录里离线补算。" + fix)
        case 2: return (2, cause + "，预览关闭，部分击球可能缺少速度或落点。" + fix)
        case 1: return (1, source == .lowPower ? "低电量模式下，预览降为每秒 1 张，辅助检测减少。"
                         : "机位相机负载偏高，预览降为每秒 1 张，辅助检测减少。")
        default: return (0, nil)
        }
    }

    /// The reason for a level raised by analysis lag. It names lag, not heat: cooling the phone is not the fix.
    public static func lagReason(level: Int) -> String? {
        switch level {
        case 1: return "实时分析跟不上画面：预览降为每秒 1 张、人员检测减少，让分析追上；录像不受影响。关掉机位上其他 App 也有帮助。"
        case 2: return "实时分析仍跟不上画面：预览关闭、辅助检测再减少，结果出得慢一些，部分落点可能为空；录像不受影响。关掉机位上其他 App 也有帮助。"
        default: return nil
        }
    }

    static func cause(thermal: String, pressure: String?, lowPower: Bool) -> Cause {
        let thermalLevel = Self.thermalLevel(thermal), pressureLevel = Self.pressureLevel(pressure)
        if pressureLevel > thermalLevel { return .pressure }
        return lowPower && thermalLevel == 0 ? .lowPower : .heat
    }

    static func reason(level: Int, cause: Cause) -> String? {
        guard (1...4).contains(level) else { return nil }
        let name = ["nominal", "fair", "serious", "critical", "shutdown"][level]
        switch cause {
        case .lag: return lagReason(level: level)
        case .pressure: return target(thermal: "nominal", pressure: name, lowPower: false).reason
        case .lowPower: return target(thermal: "nominal", pressure: nil, lowPower: true).reason
        case .heat:
            if level == 1 { return "机位温度回落，预览暂为每秒 1 张，逐步恢复全速。" }
            return target(thermal: name, pressure: nil, lowPower: false).reason
        }
    }

    /// `analysisLag`: seconds the analysis is behind capture, nil when it cannot be measured (not
    /// capturing, models loading, analysis paused). Returns true when the level or its reason changed.
    @discardableResult
    public mutating func update(thermal: String, pressure: String?, lowPower: Bool, analysisLag: Double? = nil, now: Double) -> Bool {
        trackLag(analysisLag, now: now)
        let device = Self.target(thermal: thermal, pressure: pressure, lowPower: lowPower)
        let deviceCause = Self.cause(thermal: thermal, pressure: pressure, lowPower: lowPower)
        let target = max(device.level, lagLevel)
        if target > level {
            level = target; belowSince = nil
            cause = lagLevel > device.level ? .lag : deviceCause
            reason = cause == .lag ? Self.lagReason(level: level) : device.reason
            return true
        }
        guard target < level else {
            belowSince = nil
            guard level > 0 else { return false }
            let lagHolds = lagLevel >= level && (cause == .lag || device.level < level)
            let activeCause: Cause = lagHolds ? .lag : deviceCause
            guard activeCause != cause else { return false }
            cause = activeCause
            reason = cause == .lag ? Self.lagReason(level: level) : device.reason
            return true
        }
        guard let since = belowSince else { belowSince = now; return false }
        guard now - since >= Self.recoverySeconds else { return false }
        level -= 1; belowSince = level > target ? now : nil
        if level == 0 { cause = nil }
        else if level == device.level { cause = deviceCause }
        else if level == lagLevel { cause = .lag }
        reason = cause.flatMap { Self.reason(level: level, cause: $0) }
        return true
    }

    /// Lag as a Schmitt trigger with a sustain window: high (above `lagHighSeconds`) for a whole window
    /// without draining asks for one more level than now; low (below `lagLowSeconds`) or unmeasurable
    /// clears the demand; in between holds it.
    private mutating func trackLag(_ lag: Double?, now: Double) {
        guard let lag, lag >= Self.lagLowSeconds else { lagLevel = 0; lagWindow = nil; return }
        guard lag > Self.lagHighSeconds else { lagWindow = nil; return }
        guard let window = lagWindow else { lagWindow = (now, lag); return }
        guard now - window.since >= Self.lagSustainSeconds else { return }
        lagWindow = (now, lag)
        // Shrinking lag means the current level already lets analysis catch up.
        guard lag > window.lag - Self.lagDrainSeconds, level < Self.maximumLagLevel else { return }
        lagLevel = level + 1
    }
}
