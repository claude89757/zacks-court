import Foundation
import simd

/// What a Hawk-Eye challenge replays for one judged shot: the flight from the hit to the bounce (when
/// the chain gave a hit point), the ball's footprint, the uncertainty around it and the line it was
/// judged against. Pure geometry in the court frame of `TennisBounceEstimate` (x from the near-left
/// doubles sideline, y from the near baseline, z up, metres); views draw it through `HawkEyeCamera`.
/// The flight is the ballistic arc through the two estimated points, drawn for the replay only: it is
/// not a measured trajectory. The browser page mirrors this file in `app.js`.
public struct HawkEyeReplayScene: Equatable, Sendable {
    public var judgement: HawkEyeJudgement
    /// Centre of the ball at the bounce (z = ball radius).
    public var bounce: SIMD3<Double>
    public var sigmaX: Double?
    public var sigmaY: Double?
    /// Sampled flight from the hit to the bounce, then a short way on after it; nil without a hit point.
    public var flight: [SIMD3<Double>]?
    /// Index in `flight` of the bounce sample.
    public var bounceIndex: Int
    /// Point on the judged line's outer edge closest to the bounce, and the outward normal there.
    public var lineAnchor: SIMD3<Double>
    public var outward: SIMD3<Double>
    /// The hitter was on the near half (from the camera): the wide view looks from that end.
    public var fromNear: Bool

    public static let g = 9.80665
    static let samples = 36, afterSamples = 10, afterSeconds = 0.35

    public init?(event: TennisShotEvent) {
        guard let b = event.bounce, let j = b.hawkEye, let x = b.xMeters, let y = b.yMeters else { return nil }
        judgement = j; sigmaX = b.sigmaXMeters; sigmaY = b.sigmaYMeters
        bounce = SIMD3(x, y, HawkEye.ballRadius)
        (lineAnchor, outward) = Self.anchor(x: x, y: y, judgement: j, serverX: event.hit?.x)
        fromNear = event.hit.map { $0.y < HawkEye.netY } ?? (y > HawkEye.netY)
        flight = nil; bounceIndex = 0
        if let h = event.hit {
            let T = b.sourcePTS - event.sourcePTS
            if T > 0.15, T < 3 {
                let H = SIMD3(h.x, h.y, max(h.z, HawkEye.ballRadius))
                var v = (bounce - H) / T; v.z += 0.5 * Self.g * T
                var points = (0...Self.samples).map { i -> SIMD3<Double> in
                    let t = T * Double(i) / Double(Self.samples)
                    return H + v * t - SIMD3(0, 0, 0.5 * Self.g * t * t)
                }
                // after the bounce: a lower, slower arc (restitution and friction are rough guesses)
                let vb = SIMD3(v.x * 0.7, v.y * 0.7, -(v.z - Self.g * T) * 0.72)
                for i in 1...Self.afterSamples {
                    let t = Self.afterSeconds * Double(i) / Double(Self.afterSamples)
                    var p = bounce + vb * t - SIMD3(0, 0, 0.5 * Self.g * t * t)
                    p.z = max(p.z, HawkEye.ballRadius)
                    points.append(p)
                }
                flight = points; bounceIndex = Self.samples
            }
        }
    }

    /// The judged line's outer edge nearest the bounce and its outward normal, from the same rectangle
    /// `HawkEye.judge` used.
    static func anchor(x: Double, y: Double, judgement j: HawkEyeJudgement, serverX: Double?) -> (SIMD3<Double>, SIMD3<Double>) {
        let c = HawkEye.centreX, net = HawkEye.netY
        let far = y > net
        let half = j.serve || j.format == .singles ? HawkEye.singlesHalfWidth : c
        switch j.line {
        case .sideline:
            let right = x >= c
            return (SIMD3(right ? c + half : c - half, y, 0), SIMD3(right ? 1 : -1, 0, 0))
        case .centreLine:
            // the serve went into the other box: the centre line's far edge, facing that box
            let intoRight = x >= c
            return (SIMD3(intoRight ? c + HawkEye.centreLineHalfWidth : c - HawkEye.centreLineHalfWidth, y, 0), SIMD3(intoRight ? 1 : -1, 0, 0))
        case .baseline:
            return (SIMD3(x, far ? HawkEye.length : 0, 0), SIMD3(0, far ? 1 : -1, 0))
        case .serviceLine:
            return (SIMD3(x, far ? net + HawkEye.serviceFromNet : net - HawkEye.serviceFromNet, 0), SIMD3(0, far ? 1 : -1, 0))
        }
    }

    /// Footprint radius drawn: the same circle the call measured.
    public var markRadius: Double { HawkEye.ballRadius }
    /// Semi-axes of the uncertainty ellipse drawn around the mark (the call's margin along the line's
    /// normal, 2 sigma along the line).
    public var uncertainty: (x: Double, y: Double) {
        let k = HawkEye.sigmas, floor = HawkEye.minimumMargin
        let sx = sigmaX.map { max(floor, k * $0) } ?? HawkEye.defaultMargin
        let sy = sigmaY.map { max(floor, k * $0) } ?? HawkEye.defaultMargin
        return (sx, sy)
    }

    // MARK: Camera path

    /// The wide view: high behind the hitter's end, the whole court in frame.
    public var wideCamera: HawkEyeCamera {
        let y = fromNear ? -10.5 : HawkEye.length + 10.5
        return HawkEyeCamera(position: SIMD3(HawkEye.centreX, y, 7.5), target: SIMD3(HawkEye.centreX, HawkEye.netY, 0), fovDegrees: 46)
    }
    /// The close view: low, inside the court, looking out across the line at the mark, so the line runs
    /// across the picture and the gap (or overlap) between mark and line shows.
    public var closeCamera: HawkEyeCamera {
        let gap = abs(judgement.distanceM)
        let back = 1.1 + min(2.5, gap * 1.5), height = 0.55 + min(1.4, gap * 0.8)
        let along = SIMD3(-outward.y, outward.x, 0)
        let focus = (lineAnchor + SIMD3(bounce.x, bounce.y, 0)) / 2
        let position = focus - outward * back + along * (back * 0.35) + SIMD3(0, 0, height)
        return HawkEyeCamera(position: position, target: focus, fovDegrees: 34)
    }
}

/// A pinhole camera looking from `position` at `target`, z up. Projects court points to view points
/// (origin top-left, y down) for a view of `size`.
public struct HawkEyeCamera: Equatable, Sendable {
    public var position: SIMD3<Double>
    public var target: SIMD3<Double>
    public var fovDegrees: Double
    public init(position: SIMD3<Double>, target: SIMD3<Double>, fovDegrees: Double) {
        self.position = position; self.target = target; self.fovDegrees = fovDegrees
    }
    public static let near = 0.05

    /// Camera coordinates: x right, y up, z forward (depth).
    public func view(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        let d = p - position
        return SIMD3(simd_dot(d, right), simd_dot(d, up), simd_dot(d, forward))
    }
    /// Screen point of a camera-space point with depth above `near`.
    public func screen(_ c: SIMD3<Double>, width: Double, height: Double) -> SIMD2<Double> {
        let f = height / (2 * tan(fovDegrees * .pi / 360))
        return SIMD2(width / 2 + f * c.x / c.z, height / 2 - f * c.y / c.z)
    }
    public func project(_ p: SIMD3<Double>, width: Double, height: Double) -> SIMD2<Double>? {
        let c = view(p)
        return c.z > Self.near ? screen(c, width: width, height: height) : nil
    }
    /// A ground polygon clipped at the near plane, in screen points; empty when wholly behind.
    public func polygon(_ points: [SIMD3<Double>], width: Double, height: Double) -> [SIMD2<Double>] {
        let cs = points.map(view)
        var out = [SIMD3<Double>]()
        for i in cs.indices {
            let a = cs[i], b = cs[(i + 1) % cs.count]
            let ina = a.z > Self.near, inb = b.z > Self.near
            if ina { out.append(a) }
            if ina != inb {
                let t = (Self.near - a.z) / (b.z - a.z)
                out.append(a + (b - a) * t)
            }
        }
        return out.map { screen($0, width: width, height: height) }
    }
    /// Smoothstep blend between two cameras, `t` in 0…1.
    public static func blend(_ a: HawkEyeCamera, _ b: HawkEyeCamera, _ t: Double) -> HawkEyeCamera {
        let s = max(0, min(1, t)); let e = s * s * (3 - 2 * s)
        return HawkEyeCamera(position: a.position + (b.position - a.position) * e, target: a.target + (b.target - a.target) * e,
                             fovDegrees: a.fovDegrees + (b.fovDegrees - a.fovDegrees) * e)
    }
}

/// Painted court lines as ground rectangles (outer edges on the court dimensions, widths inward):
/// baselines 10 cm, every other line 5 cm, centre marks 10 cm long.
public enum HawkEyeCourtLines {
    public static func rectangles() -> [[SIMD3<Double>]] {
        let W = HawkEye.width, L = HawkEye.length, net = HawkEye.netY, c = HawkEye.centreX
        let s0 = c - HawkEye.singlesHalfWidth, s1 = c + HawkEye.singlesHalfWidth
        let svc = HawkEye.serviceFromNet, w = 0.05, base = 0.10
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [SIMD3<Double>] {
            [SIMD3(x0, y0, 0), SIMD3(x1, y0, 0), SIMD3(x1, y1, 0), SIMD3(x0, y1, 0)]
        }
        return [
            rect(0, 0, W, base), rect(0, L - base, W, L),                      // baselines
            rect(0, 0, w, L), rect(W - w, 0, W, L),                            // doubles sidelines
            rect(s0, 0, s0 + w, L), rect(s1 - w, 0, s1, L),                    // singles sidelines
            rect(s0, net - svc, s1, net - svc + w), rect(s0, net + svc - w, s1, net + svc),   // service lines
            rect(c - w / 2, net - svc, c + w / 2, net + svc),                  // centre service line
            rect(c - w / 2, base, c + w / 2, base + 0.10), rect(c - w / 2, L - base - 0.10, c + w / 2, L - base), // centre marks
        ]
    }
}
