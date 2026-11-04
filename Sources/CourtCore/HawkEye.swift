import Foundation

/// Line calls ("界内外") from a bounce estimate. The camera judges each bounce with the settings a display
/// sent and stores the call on the bounce; displays only show it. A call is a model estimate from one
/// camera, never an official ruling: a bounce whose footprint is within the uncertainty margin of the
/// line is "close", not in or out (docs/hawk-eye.md).
public enum HawkEyeFormat: String, Codable, CaseIterable, Sendable {
    case singles, doubles
    public var text: String { self == .singles ? "单打" : "双打" }
}

public struct HawkEyeSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var format: HawkEyeFormat
    /// Also judge bounces on the far half. Off by default: far bounces are seen at a grazing angle and
    /// their depth is several times less certain.
    public var farHalf: Bool
    public init(enabled: Bool = false, format: HawkEyeFormat = .singles, farHalf: Bool = false) {
        self.enabled = enabled; self.format = format; self.farHalf = farHalf
    }
    public static let off = HawkEyeSettings()
    public var coverageText: String { farHalf ? "全场" : "仅近端半场" }
}

public enum HawkEyeCall: String, Codable, Sendable {
    case `in`, out, close
    public var text: String {
        switch self { case .in: return "界内"; case .out: return "出界"; case .close: return "压线附近" }
    }
    public var shout: String {
        switch self { case .in: return "IN"; case .out: return "OUT"; case .close: return "CLOSE" }
    }
}

public enum HawkEyeLine: String, Codable, Sendable {
    case sideline, baseline, serviceLine, centreLine
    public var text: String {
        switch self {
        case .sideline: return "边线"; case .baseline: return "底线"
        case .serviceLine: return "发球线"; case .centreLine: return "中线"
        }
    }
    /// Painted width, inward from the outer edge the call measures from (baselines 10 cm, the rest 5 cm).
    public var paintedWidth: Double { self == .baseline ? 0.10 : 0.05 }
}

public struct HawkEyeJudgement: Codable, Equatable, Sendable {
    public var call: HawkEyeCall
    /// Signed distance of the ball's footprint from the outer edge of `line`, metres: positive when the
    /// whole footprint is beyond it (out), negative when it is inside by that much.
    public var distanceM: Double
    /// Uncertainty margin used: calls within ±margin of the line are `close`.
    public var marginM: Double
    public var line: HawkEyeLine
    public var format: HawkEyeFormat
    public var serve: Bool
    /// The bounce is on the far half (from the camera).
    public var farHalf: Bool
    public init(call: HawkEyeCall, distanceM: Double, marginM: Double, line: HawkEyeLine, format: HawkEyeFormat, serve: Bool, farHalf: Bool) {
        self.call = call; self.distanceM = distanceM; self.marginM = marginM; self.line = line; self.format = format
        self.serve = serve; self.farHalf = farHalf
    }
    /// The gap the eye sees between the footprint and the painted line, metres: out, beyond the line's
    /// outer edge (the call's distance); in, inside its inner edge (`distanceM` reaches the footprint's
    /// far side, so the gap is a ball and a line width less); 0 when an in footprint touches the line;
    /// nil for a close call.
    public var visibleGapM: Double? {
        switch call {
        case .out: return max(0, distanceM)
        case .in: return max(0, -distanceM - 2 * HawkEye.ballRadius - line.paintedWidth)
        case .close: return nil
        }
    }
    /// "出界 约 12 厘米 · 底线" style summary; close calls say how near the line the estimate fell.
    public var detailText: String {
        let cm = Int(((visibleGapM ?? 0) * 100).rounded())
        switch call {
        case .out: return "出界约 \(cm) 厘米 · \(line.text)"
        case .in: return cm == 0 ? "界内 · 球印压在\(line.text)上" : "界内 · 距\(line.text)约 \(cm) 厘米"
        case .close: return "离\(line.text)不到 \(Int((marginM * 100).rounded())) 厘米，无法判定"
        }
    }
}

public enum HawkEye {
    public static let netY = 11.885
    public static let length = 23.77
    public static let width = 10.97
    public static let centreX = 5.485
    public static let singlesHalfWidth = 4.115
    public static let serviceFromNet = 6.40
    public static let centreLineHalfWidth = 0.025
    public static let ballRadius = 0.033
    /// Smallest margin: the line's own painting and the ball's compression are a few centimetres.
    public static let minimumMargin = 0.03
    /// Margin in standard deviations of the bounce estimate along the line's normal.
    public static let sigmas = 2.0
    /// Margin when the chain gave no uncertainty.
    public static let defaultMargin = 0.15
    /// A server this close to the centre mark gives no service box (both boxes count).
    static let centreBand = 0.3

    /// The call for a bounce at court `x`, `y` (x from the near-left doubles sideline, y from the near
    /// baseline), with standard deviations `sigmaX`, `sigmaY` in metres. `serverX`: the serve's contact
    /// x, which picks the diagonal service box. nil when Hawk-Eye is off, the coordinates are unknown, or
    /// the bounce is on the far half and only the near half is judged.
    public static func judge(x: Double?, y: Double?, sigmaX: Double?, sigmaY: Double?, serve: Bool, serverX: Double?,
                             settings: HawkEyeSettings) -> HawkEyeJudgement? {
        guard settings.enabled, let x, let y, x.isFinite, y.isFinite else { return nil }
        let far = y > netY
        if far && !settings.farHalf { return nil }
        let cx = x - centreX
        var x0: Double, x1: Double, y0: Double, y1: Double
        var xLine0 = HawkEyeLine.sideline, xLine1 = HawkEyeLine.sideline
        let halfWidth = serve || settings.format == .singles ? singlesHalfWidth : centreX
        x0 = -halfWidth; x1 = halfWidth
        if serve {
            y0 = far ? netY : netY - serviceFromNet; y1 = far ? netY + serviceFromNet : netY
            if let serverX, abs(serverX - centreX) >= centreBand {
                // the diagonal box: always the other sign of x, from either end
                if serverX < centreX { x0 = -centreLineHalfWidth; xLine0 = .centreLine }
                else { x1 = centreLineHalfWidth; xLine1 = .centreLine }
            }
        } else {
            y0 = far ? netY : 0; y1 = far ? length : netY
        }
        // the net-side edge is never a line: a ball there is past the net
        let yNetIsLow = far
        let baseLine: HawkEyeLine = serve ? .serviceLine : .baseline
        var edges: [(d: Double, line: HawkEyeLine, alongX: Bool)] = [(x0 - cx, xLine0, true), (cx - x1, xLine1, true)]
        if yNetIsLow { edges.append((y - y1, baseLine, false)) } else { edges.append((y0 - y, baseLine, false)) }
        let dx = max(0, x0 - cx, cx - x1)
        let dy = max(0, edges.filter { !$0.alongX }.map(\.d).max() ?? 0)
        let outside: Double, nearest: (d: Double, line: HawkEyeLine, alongX: Bool), sigma: Double?
        if dx > 0 || dy > 0 {
            outside = hypot(dx, dy)
            nearest = edges.max { $0.d < $1.d }!
            sigma = dx > 0 && dy > 0 ? max(sigmaX ?? 0, sigmaY ?? 0) : (nearest.alongX ? sigmaX : sigmaY)
        } else {
            nearest = edges.max { $0.d < $1.d }!   // least negative: the closest line
            outside = nearest.d
            sigma = nearest.alongX ? sigmaX : sigmaY
        }
        let signed = outside - ballRadius
        let margin = sigma.map { max(minimumMargin, sigmas * $0) } ?? defaultMargin
        let call: HawkEyeCall = abs(signed) < margin ? .close : (signed > 0 ? .out : .in)
        return HawkEyeJudgement(call: call, distanceM: signed, marginM: margin, line: nearest.line, format: settings.format,
                                serve: serve, farHalf: far)
    }

    /// The call for one shot row. Serves read the contact's x for the box; other shots are judged
    /// against the half the ball bounced in.
    public static func judge(_ event: TennisShotEvent, settings: HawkEyeSettings) -> HawkEyeJudgement? {
        guard let b = event.bounce else { return nil }
        return judge(x: b.xMeters, y: b.yMeters, sigmaX: b.sigmaXMeters, sigmaY: b.sigmaYMeters,
                     serve: event.stroke == .serve, serverX: event.hit?.x, settings: settings)
    }

    /// Rows with their bounce's call set (or cleared) for `settings`. A bounce on the hitter's own half
    /// (a ball that did not cross the net) gets no call.
    public static func annotate(_ events: [TennisShotEvent], settings: HawkEyeSettings) -> [TennisShotEvent] {
        events.map { annotate($0, settings: settings) }
    }

    public static func annotate(_ event: TennisShotEvent, settings: HawkEyeSettings) -> TennisShotEvent {
        guard event.bounce != nil else { return event }
        var row = event
        var call = judge(event, settings: settings)
        if let hitY = event.hit?.y, let y = event.bounce?.yMeters, (hitY > netY) == (y > netY) { call = nil }
        row.bounce?.hawkEye = call
        return row
    }
}

/// A challenge of one shot (「挑战」): a player disputes a call, anyone taps 挑战 on a display or on the
/// camera, and the camera judges the shot again and stores the result on the row. Every screen that
/// receives the row with a new challenge plays the replay, and the record keeps it. Judged on demand
/// with both halves and the format of the time, whatever the line-call settings are; the stored
/// `bounce.hawkEye` (the call of its time) is never changed by a challenge. Still a model estimate.
public struct HawkEyeChallenge: Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var format: HawkEyeFormat
    /// nil when the shot cannot be judged; `reason` says why.
    public var judgement: HawkEyeJudgement?
    /// Why there is no judgement (user wording), or nil.
    public var reason: String?
    /// The bounce may still arrive (the shot is only a moment old); the camera updates the row.
    public var pending: Bool?
    public init(id: UUID = UUID(), date: Date = Date(), format: HawkEyeFormat, judgement: HawkEyeJudgement? = nil,
                reason: String? = nil, pending: Bool? = nil) {
        self.id = id; self.date = date; self.format = format; self.judgement = judgement
        self.reason = reason.map { String($0.prefix(120)) }; self.pending = pending
    }
    public static let pendingReason = "落点还在计算，稍等片刻"
    public static let noBounceReason = "这一拍没找到落点，无法判定界内外"
    public static let sameHalfReason = "这一拍没有过网，不判界内外"
}

/// Which challenge is newest: the camera's own screen opens the replay when it changes.
public struct HawkEyeChallengeRef: Equatable, Sendable {
    public var shot: UUID
    public var challenge: UUID
    public init(shot: UUID, challenge: UUID) { self.shot = shot; self.challenge = challenge }
}

extension TennisShotEvent {
    /// The call to show for this shot: a challenge's judgement, else the call of its time.
    public var lineCall: HawkEyeJudgement? { challenge?.judgement ?? bounce?.hawkEye }
}

extension HawkEye {
    /// How long after a shot its bounce may still arrive. A challenge of a newer shot without a bounce
    /// waits for it instead of judging an older shot (docs/hawk-eye.md §7).
    public static let challengeBounceWait = 3.0

    /// The shot a challenge without a named shot is about: the newest shot with a bounce, unless an even
    /// newer shot is still within `challengeBounceWait` of `latestPTS` (its bounce may be on its way;
    /// `latestPTS` nil means nothing is being analysed). With no bounce at all, the newest shot. nil
    /// without shots.
    public static func challengeTarget(_ rows: [TennisShotEvent], latestPTS: Double?) -> TennisShotEvent? {
        let sorted = rows.sorted { $0.sourcePTS < $1.sourcePTS }
        guard let last = sorted.last else { return nil }
        guard let bounced = sorted.last(where: { $0.bounce?.xMeters != nil && $0.bounce?.yMeters != nil }) else { return last }
        if last.id != bounced.id, let latestPTS, latestPTS - last.sourcePTS <= challengeBounceWait { return last }
        return bounced
    }

    /// The shot before `shot` that has a bounce: 「挑战上一拍」 when the picked shot is not the disputed one.
    public static func previousBounced(before shot: UUID, in rows: [TennisShotEvent]) -> TennisShotEvent? {
        let sorted = rows.sorted { $0.sourcePTS < $1.sourcePTS }
        guard let index = sorted.firstIndex(where: { $0.id == shot }) else { return nil }
        return sorted[..<index].last { $0.bounce?.xMeters != nil && $0.bounce?.yMeters != nil }
    }

    /// The challenge's result for the row as it is now. Both halves are judged; a ball that did not
    /// cross the net is not. Without a bounce the result is pending (it may still arrive) or refused.
    public static func judgeChallenge(_ challenge: HawkEyeChallenge, for event: TennisShotEvent, waiting: Bool) -> HawkEyeChallenge {
        var c = challenge
        c.judgement = nil; c.reason = nil; c.pending = nil
        guard let b = event.bounce, let x = b.xMeters, let y = b.yMeters, x.isFinite, y.isFinite else {
            if waiting { c.reason = HawkEyeChallenge.pendingReason; c.pending = true }
            else { c.reason = HawkEyeChallenge.noBounceReason }
            return c
        }
        if let hitY = event.hit?.y, (hitY > netY) == (y > netY) { c.reason = HawkEyeChallenge.sameHalfReason; return c }
        let settings = HawkEyeSettings(enabled: true, format: challenge.format, farHalf: true)
        c.judgement = judge(x: x, y: y, sigmaX: b.sigmaXMeters, sigmaY: b.sigmaYMeters, serve: event.stroke == .serve,
                            serverX: event.hit?.x, settings: settings)
        if c.judgement == nil { c.reason = HawkEyeChallenge.noBounceReason }
        return c
    }
}
