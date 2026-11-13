import Foundation

/// Why a shot has no speed or no landing spot yet, in words a tennis player understands.
///
/// The engine keeps its own detailed wording in `speedReason` / `bounce.reason` for diagnostics
/// and for older v2 peers; this code travels next to it as an optional field. A peer that sends
/// only the old string is classified with `classify(_:)`, and a code this build does not know
/// decodes as `.other`, so neither direction breaks decoding.
public enum TennisReason: String, CaseIterable, Sendable {
    /// The result is still on its way (flight in progress, landing being located).
    case pending
    /// The ball itself was not seen clearly enough (too few track samples, no ball in the landing frames).
    case ballNotSeen
    /// A speed was computed but its checks failed, so it is not counted.
    case speedUnreliable
    /// No first bounce was seen before the next shot, the end of the record or the flight limit.
    case noBounceSeen
    /// The ball touched the net before the first bounce.
    case hitNet
    /// A landing was found but does not map onto the recognised court.
    case notOnCourt
    /// A landing spot is shown; it is a model estimate, not a line call.
    case estimate
    /// The camera shed load and skipped landing localization.
    case cameraCooling
    /// The landing queue was full and this shot was skipped.
    case cameraBusy
    /// Landing localization threw an error.
    case failed
    /// Anything this build does not recognise.
    case other

    /// Short wording for shot rows and the recognition panel. Same text on the App and in the browser.
    public var text: String {
        switch self {
        case .pending: return courtText("还在分析")
        case .ballNotSeen: return courtText("没看清球")
        case .speedUnreliable: return courtText("球速不可靠，未计入")
        case .noBounceSeen: return courtText("没看到球落地")
        case .hitNet: return courtText("球先碰网")
        case .notOnCourt: return courtText("落点不在已识别的球场上")
        case .estimate: return courtText("模型估计的落点")
        case .cameraCooling: return courtText("机位负载高，这拍未定位落点")
        case .cameraBusy: return courtText("机位忙不过来，这拍未定位落点")
        case .failed: return courtText("落点定位出错")
        case .other: return courtText("暂时无法给出")
        }
    }

    /// Still waiting for a result: left out of found / settled counts.
    public var isPending: Bool { self == .pending }

    /// Maps the engine's (and older peers') wording to a code. Every string the reference chain,
    /// its flight fit and `CameraSideAnalyzer` emit has an entry; see `TennisReasonTests`.
    public static func classify(_ detail: String) -> TennisReason {
        if let known = table[detail] { return known }
        if detail.hasPrefix("等待") { return .pending }
        if detail.hasPrefix("触地定位失败") { return .failed }
        return .other
    }

    static let table: [String: TennisReason] = [
        // Waiting (reference chain)
        courtText("等待首弹地及连续三维轨迹"): .pending,
        "等待独立队列触地定位": .pending,
        // Speed (reference chain)
        courtText("缺少击球轨迹样本"): .ballNotSeen,
        "需要至少四个连续击球轨迹样本": .ballNotSeen,
        "速度拟合时间跨度不足": .ballNotSeen,
        "弹地三维模型位置不可用": .ballNotSeen,
        "飞行时长不在已支持范围": .speedUnreliable,
        "源帧计数与时间戳不一致": .speedUnreliable,
        "三维轨迹拟合残差过大": .speedUnreliable,
        "模型速度超出支持范围": .speedUnreliable,
        "端点与轨迹速度不一致": .speedUnreliable,
        "端点与轨迹方向不一致": .speedUnreliable,
        "水平运动方向不一致": .speedUnreliable,
        // Flight ended without a first bounce (engine)
        courtText("下一段击球前没有可靠首弹地证据"): .noBounceSeen,
        "会话结束前没有可靠首弹地证据": .noBounceSeen,
        "超过已支持的飞行时间，未确认首弹地": .noBounceSeen,
        "首弹地前出现其他事件": .noBounceSeen,
        "无触地候选": .noBounceSeen,
        "首弹地前检测到触网候选": .hitNet,
        // Landing (engine and CameraSideAnalyzer)
        courtText("Focus球位置缺失、低分或存在竞争目标"): .ballNotSeen,
        "触地候选缺少受支持的球场映射": .notOnCourt,
        "模型弹地候选，未验证物理触地或判线精度": .estimate,
        "设备降载期间未做触地定位": .cameraCooling,
        "触地定位队列繁忙，未定位": .cameraBusy,
    ]
}

extension TennisReason: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TennisReason(rawValue: raw) ?? .other
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension TennisShotEvent {
    /// Why there is no usable speed; nil when the shot has one.
    var speedReasonKind: TennisReason? {
        guard validSpeedKPH == nil else { return nil }
        if let code = speedReasonCode ?? speedReason.map(TennisReason.classify) { return code }
        return endPTS == nil ? .pending : .other
    }

    /// Why there is no landing spot on the court map; nil when the shot has one.
    var placementReasonKind: TennisReason? {
        guard !hasCourtPlacement else { return nil }
        if let bounce {
            let kind = bounce.reasonKind ?? .other
            // A candidate without court coordinates did not map onto the court.
            return kind == .estimate ? .notOnCourt : kind
        }
        // No bounce yet: still in flight, or the flight ended without one.
        return speedReasonKind?.isPending == true ? .pending : .noBounceSeen
    }

    /// User wording for the missing speed, e.g. 「没看清球」; nil when the shot has a speed.
    var speedReasonText: String? { speedReasonKind?.text }
    /// User wording for the missing landing spot; nil when the shot has one.
    var placementReasonText: String? { placementReasonKind?.text }
}

public extension CodingUserInfoKey {
    /// When true, `TennisShotEvent` also encodes `speedReasonText` and `placementReasonText`,
    /// so the browser display shows the App's wording without its own table. Set by `WebWire.encoder`.
    static let courtDisplayText = CodingUserInfoKey(rawValue: "court.displayText")!
}
