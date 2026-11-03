import Foundation

/// Graded load shedding for the camera (docs/camera-side-analysis.md §7). It never lowers the
/// 1080p60 capture or recording; it trims preview, auxiliary detection and analysis instead.
///
/// | Level | Trigger | Effect |
/// | L1 | thermal fair, camera pressure fair, or Low Power Mode | preview 1 frame/s, person detection off |
/// | L2 | serious | preview off, court refresh every 10 s, bounce localization off |
/// | L3 | critical | analysis paused, recording continues; the session records an analysis gap |
/// | L4 | camera pressure shutdown | the system is about to stop the camera; the session pauses |
///
/// Rising pressure applies at once. Falling pressure lowers one level after 60 s below the
/// current level, then needs another 60 s for the next step.
public struct CameraLoadPolicy: Sendable {
    public static let recoverySeconds = 60.0
    public private(set) var level = 0
    public private(set) var reason: String?
    private var belowSince: Double?

    public init() {}

    public static func target(thermal: String, pressure: String?, lowPower: Bool) -> (level: Int, reason: String?) {
        let thermalLevel = ["fair": 1, "serious": 2, "critical": 3][thermal] ?? 0
        let pressureLevel = pressure.flatMap { ["fair": 1, "serious": 2, "critical": 3, "shutdown": 4][$0] } ?? 0
        let level = max(thermalLevel, pressureLevel, lowPower ? 1 : 0)
        // Name the actual cause: heat and camera pressure need different next steps.
        let heat = thermalLevel >= pressureLevel
        let cause = heat ? "机位温度偏高" : "机位相机负载高"
        let fix = heat ? "把机位移到阴凉处、避开阳光直射，取下手机壳。" : "关掉机位上其他占用相机或耗电的 App。"
        switch level {
        case 4: return (4, "相机负载达到上限，系统即将停止相机，记录将暂停：\(fix)然后点「开始采集」，再点「继续」。")
        case 3: return (3, (heat ? "机位过热" : "机位相机负载过高") + "：实时分析暂停，录像继续；这段时间的拍次保持为空，结束后可在历史记录里离线补算。" + fix)
        case 2: return (2, cause + "：预览关闭、暂不定位落点，动作与球速照常。" + fix)
        case 1: return (1, lowPower && thermalLevel < 1 && pressureLevel < 1 ? "低电量模式：预览降为每秒 1 张，人员检测关闭。接上电源后可关闭低电量模式。"
                         : (heat ? "机位偏暖" : "机位相机负载偏高") + "：预览降为每秒 1 张，人员检测关闭；球速与落点照常。")
        default: return (0, nil)
        }
    }

    /// Returns true when the level changed.
    @discardableResult
    public mutating func update(thermal: String, pressure: String?, lowPower: Bool, now: Double) -> Bool {
        let target = Self.target(thermal: thermal, pressure: pressure, lowPower: lowPower)
        if target.level > level {
            level = target.level; reason = target.reason; belowSince = nil
            return true
        }
        guard target.level < level else { belowSince = nil; return false }
        guard let since = belowSince else { belowSince = now; return false }
        guard now - since >= Self.recoverySeconds else { return false }
        level -= 1; belowSince = level > target.level ? now : nil
        reason = Self.target(thermal: ["", "fair", "serious", "critical"][min(level, 3)], pressure: level == 4 ? "shutdown" : nil, lowPower: false).reason
        if level == 0 { reason = nil }
        return true
    }
}
