import Foundation

/// Graded load shedding for the camera (docs/camera-side-analysis.md §7). It never lowers the
/// 1080p60 capture or recording; it trims preview, auxiliary detection and analysis instead.
///
/// | Level | Trigger | Effect |
/// | L1 | thermal fair, camera pressure fair, Low Power Mode, or analysis lag | preview 1 frame/s, person detection off (in-house: slower) |
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

    static func thermalLevel(_ thermal: String) -> Int { ["fair": 1, "serious": 2, "critical": 3][thermal] ?? 0 }
    static func pressureLevel(_ pressure: String?) -> Int {
        pressure.flatMap { ["fair": 1, "serious": 2, "critical": 3, "shutdown": 4][pressureName($0)] } ?? 0
    }

    public static func target(thermal: String, pressure: String?, lowPower: Bool) -> (level: Int, reason: String?) {
        let thermalLevel = Self.thermalLevel(thermal), pressureLevel = Self.pressureLevel(pressure)
        let level = max(thermalLevel, pressureLevel, lowPower ? 1 : 0)
        // Name the actual cause: heat and camera pressure need different next steps.
        let heat = thermalLevel >= pressureLevel
        let cause = heat ? courtText("机位温度偏高") : courtText("机位相机负载高")
        let fix = heat ? courtText("把机位移到阴凉处、避开阳光直射，取下手机壳。") : courtText("关掉机位上其他占用相机或耗电的 App。")
        switch level {
        case 4: return (4, courtFormat("相机负载达到上限，系统即将停止相机，记录将暂停：%1$@然后点「开始采集」，再点「继续」。", "\(fix)"))
        case 3: return (3, (heat ? courtText("机位过热") : courtText("机位相机负载过高")) + courtText("：实时分析暂停，录像继续；这段时间的拍次保持为空，结束后可在历史记录里离线补算。") + fix)
        case 2: return (2, cause + courtText("：预览关闭、暂不定位落点，动作与球速照常。") + fix)
        case 1: return (1, lowPower && thermalLevel < 1 && pressureLevel < 1 ? courtText("低电量模式：预览降为每秒 1 张，人员检测关闭。接上电源后可关闭低电量模式。")
                         : (heat ? courtText("机位偏暖") : courtText("机位相机负载偏高")) + courtText("：预览降为每秒 1 张，人员检测关闭；球速与落点照常。"))
        default: return (0, nil)
        }
    }

    /// The reason for a level raised by analysis lag. It names lag, not heat: cooling the phone is not the fix.
    public static func lagReason(level: Int) -> String? {
        switch level {
        case 1: return courtText("实时分析跟不上画面：预览降为每秒 1 张、人员检测减少，让分析追上；录像不受影响。关掉机位上其他 App 也有帮助。")
        case 2: return courtText("实时分析仍跟不上画面：预览关闭、辅助检测再减少，结果出得慢一些，部分落点可能为空；录像不受影响。关掉机位上其他 App 也有帮助。")
        default: return nil
        }
    }

    static func cause(thermal: String, pressure: String?, lowPower: Bool) -> Cause {
        let thermalLevel = Self.thermalLevel(thermal), pressureLevel = Self.pressureLevel(pressure)
        if pressureLevel > thermalLevel { return .pressure }
        return lowPower && thermalLevel < 1 ? .lowPower : .heat
    }

    static func reason(level: Int, cause: Cause) -> String? {
        guard (1...4).contains(level) else { return nil }
        let name = ["nominal", "fair", "serious", "critical", "shutdown"][level]
        switch cause {
        case .lag: return lagReason(level: level)
        case .pressure: return target(thermal: "nominal", pressure: name, lowPower: false).reason
        case .lowPower: return target(thermal: "nominal", pressure: nil, lowPower: true).reason
        case .heat: return target(thermal: name, pressure: nil, lowPower: false).reason
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
            // The level now holds for the other cause only (lag cleared while heat rose to it, or the reverse).
            let lagHolds = lagLevel >= level, deviceHolds = device.level >= level
            guard cause == .lag ? !lagHolds : !deviceHolds else { return false }
            cause = lagHolds ? .lag : deviceCause
            reason = cause == .lag ? Self.lagReason(level: level) : device.reason
            return true
        }
        guard let since = belowSince else { belowSince = now; return false }
        guard now - since >= Self.recoverySeconds else { return false }
        level -= 1; belowSince = level > target ? now : nil
        reason = cause.flatMap { Self.reason(level: level, cause: $0) }
        if level == 0 { reason = nil; cause = nil }
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
