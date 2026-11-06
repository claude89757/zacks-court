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
    /// The judged line's outer edge round the anchor (at most 1.2 m each way, never past the line's ends).
    public var lineFrom: SIMD3<Double>
    public var lineTo: SIMD3<Double>
    /// The hitter was on the near half (from the camera): the wide view looks from that end.
    public var fromNear: Bool

    public static let g = 9.80665
    static let samples = 36, afterSamples = 10, afterSeconds = 0.35

    /// `judgement`: the call to replay (a challenge's), else the call of its time.
    public init?(event: TennisShotEvent, judgement: HawkEyeJudgement? = nil) {
        guard let b = event.bounce, let j = judgement ?? event.lineCall, let x = b.xMeters, let y = b.yMeters else { return nil }
        self.judgement = j; sigmaX = b.sigmaXMeters; sigmaY = b.sigmaYMeters
        bounce = SIMD3(x, y, HawkEye.ballRadius)
        (lineAnchor, outward, lineFrom, lineTo) = Self.anchor(x: x, y: y, judgement: j, serverX: event.hit?.x)
        fromNear = event.hit.map { $0.y < HawkEye.netY } ?? (y > HawkEye.netY)
        flight = nil; bounceIndex = 0
        if let h = event.hit, HawkEye.plausibleHit(xCentred: h.x - HawkEye.centreX, y: h.y, z: h.z) {
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

    /// The judged line's outer edge nearest the bounce, its outward normal, and the stretch of that edge
    /// to pick out, from the same rectangle `HawkEye.judge` used. The anchor is clamped to the line's
    /// ends, so past a corner it is the corner.
    static func anchor(x: Double, y: Double, judgement j: HawkEyeJudgement, serverX: Double?)
        -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        let c = HawkEye.centreX, net = HawkEye.netY, L = HawkEye.length, s = HawkEye.singlesHalfWidth
        let far = y > net
        let half = j.serve || j.format == .singles ? s : c
        // the half (rally) or service box the call was made in
        let y0 = j.serve ? (far ? net : net - HawkEye.serviceFromNet) : (far ? net : 0)
        let y1 = j.serve ? (far ? net + HawkEye.serviceFromNet : net) : (far ? L : net)
        // a serve with a known server went to one box (the right one from a server left of centre, from
        // either end); judged against the centre line, that box's outer edge faces the other box
        let rightBox: Bool? = j.serve
            ? serverX.flatMap { abs($0 - c) >= HawkEye.centreBand ? $0 < c : nil } ?? (j.line == .centreLine ? x < c : nil)
            : nil
        let x0 = rightBox == true ? c - HawkEye.centreLineHalfWidth : c - half
        let x1 = rightBox == false ? c + HawkEye.centreLineHalfWidth : c + half
        func clampY(_ v: Double) -> Double { min(max(v, y0), y1) }
        func clampX(_ v: Double) -> Double { min(max(v, x0), x1) }
        let anchor: SIMD3<Double>, outward: SIMD3<Double>, low: SIMD3<Double>, high: SIMD3<Double>
        switch j.line {
        case .sideline:
            let right = x >= c, ex = right ? c + half : c - half
            anchor = SIMD3(ex, clampY(y), 0); outward = SIMD3(right ? 1 : -1, 0, 0)
            low = SIMD3(ex, y0, 0); high = SIMD3(ex, y1, 0)
        case .centreLine:
            let right = rightBox ?? (x < c), ex = right ? c - HawkEye.centreLineHalfWidth : c + HawkEye.centreLineHalfWidth
            anchor = SIMD3(ex, clampY(y), 0); outward = SIMD3(right ? -1 : 1, 0, 0)
            low = SIMD3(ex, y0, 0); high = SIMD3(ex, y1, 0)
        case .baseline, .serviceLine:
            let ey = j.line == .baseline ? (far ? L : 0) : (far ? net + HawkEye.serviceFromNet : net - HawkEye.serviceFromNet)
            anchor = SIMD3(clampX(x), ey, 0); outward = SIMD3(0, far ? 1 : -1, 0)
            low = SIMD3(x0, ey, 0); high = SIMD3(x1, ey, 0)
        }
        func toward(_ end: SIMD3<Double>) -> SIMD3<Double> {
            let d = end - anchor, l = simd_length(d)
            return l > 1.2 ? anchor + d * (1.2 / l) : end
        }
        return (anchor, outward, toward(low), toward(high))
    }

    /// Footprint radius drawn: the same circle the call measured.
    public var markRadius: Double { HawkEye.ballRadius }
    /// Where the footprint may lie, drawn round it: the call's margin either side of the centre along the
    /// line's normal, plus the ball's radius, so the band reaches the line exactly when the call is close
    /// on the out side; along the line it only covers the footprint (that error does not move the call).
    public var band: (along: Double, across: Double) {
        (footprint.along + 0.02, judgement.marginM + HawkEye.ballRadius)
    }

    /// The gap the closing shot measures, in the court frame, and its length: out, from the line's outer
    /// edge to the footprint's nearest point; in, from the footprint's outer point to the line's inner
    /// edge. Its length is `HawkEyeJudgement.visibleGapM`, the number the verdict shows. nil for a close
    /// call and for an in footprint that touches the line.
    public var measure: (from: SIMD3<Double>, to: SIMD3<Double>, metres: Double)? {
        guard let gap = judgement.visibleGapM, gap > 0.004 else { return nil }
        let ground = SIMD3(bounce.x, bounce.y, 0), R = HawkEye.ballRadius
        if judgement.call == .out {
            let d = ground - lineAnchor, l = simd_length(d)
            let dir = l > 1e-9 ? d / l : outward
            return (lineAnchor, ground - dir * R, gap)
        }
        return (ground + outward * R, lineAnchor - outward * judgement.line.paintedWidth, gap)
    }

    // MARK: Cameras (mirrored in app.js `replayScene` / `replayCamera`)

    /// Along the judged line (outward turned a quarter left).
    public var along: SIMD3<Double> { SIMD3(-outward.y, outward.x, 0) }
    /// Horizontal direction the ball travelled to the bounce (outward without a flight).
    public var travel: SIMD3<Double> {
        guard let start = flight?.first else { return outward }
        let d = SIMD3(bounce.x - start.x, bounce.y - start.y, 0)
        return simd_length(d) > 1e-6 ? simd_normalize(d) : outward
    }
    /// Midway between the mark and the judged line.
    public var focus: SIMD3<Double> { (lineAnchor + SIMD3(bounce.x, bounce.y, 0)) / 2 }
    /// The footprint keeps the ball radius across the line (the distance the call measured) and skids
    /// only along it, longer the more the ball travelled along the line.
    public var footprint: (along: Double, across: Double) {
        (HawkEye.ballRadius * (1 + 0.9 * abs(simd_dot(travel, along))), HawkEye.ballRadius)
    }
    /// Horizontal unit beside the flight, on the court's side of the bounce.
    var beside: SIMD3<Double> {
        let t = travel
        var b = SIMD3(-t.y, t.x, 0)
        if simd_dot(b, SIMD3(HawkEye.centreX - bounce.x, HawkEye.netY - bounce.y, 0)) < 0 { b = -b }
        return b
    }

    /// The wide view without a flight: high behind the end the hitter was likely at, a little to the
    /// side away from the bounce, the whole court in frame.
    public var wideCamera: HawkEyeCamera {
        let y = fromNear ? -10.5 : HawkEye.length + 10.5, side: Double = bounce.x >= HawkEye.centreX ? 1 : -1
        return HawkEyeCamera(position: SIMD3(HawkEye.centreX - side * 2, y, 7.5), target: SIMD3(HawkEye.centreX, HawkEye.netY, 0), fovDegrees: 46)
    }
    /// The opening view: raised behind the hitter and well off to the side of the flight, so the arc and
    /// its clearance over the net read as a curve rather than a line; hit and bounce both in frame.
    public var openingCamera: HawkEyeCamera {
        guard let start = flight?.first else { return wideCamera }
        let hit = SIMD3(start.x, start.y, 0), ground = SIMD3(bounce.x, bounce.y, 0)
        return HawkEyeCamera(position: hit - travel * 9 + beside * 6 + SIMD3(0, 0, 5.5),
                             target: hit + (ground - hit) * 0.55 + SIMD3(0, 0, 0.5), fovDegrees: 50)
    }
    /// A three-quarter view beside the bounce, on the court's side of the flight: where the camera
    /// settles as the ball lands.
    public var chaseCamera: HawkEyeCamera {
        let ground = SIMD3(bounce.x, bounce.y, 0)
        return HawkEyeCamera(position: ground - travel * 3.2 + beside * 3.8 + SIMD3(0, 0, 1.9), target: ground + SIMD3(0, 0, 0.2), fovDegrees: 40)
    }
    static let measureTilt = 12.0, measureFov = 34.0
    /// The closing shot: nearly overhead (tilted 12° so the out side is up), the line across the picture,
    /// high enough that the line, the footprint and its band fill about half the height, centred a
    /// little below the middle so a verdict across the top leaves them clear. `aspect`: width / height.
    public func measureCamera(aspect: Double) -> HawkEyeCamera {
        let t = tan(Self.measureFov * .pi / 360), ground = SIMD3(bounce.x, bounce.y, 0)
        let p = simd_dot(ground - lineAnchor, outward), reach = band.across
        let lo = min(-judgement.line.paintedWidth, p - reach), hi = max(0, p + reach)
        let wide = 2 * (footprint.along + 0.1) + 0.3   // the bar beside the mark and its label
        let height = min(9, max(1.0, (hi - lo) / (1.1 * t), wide / (1.2 * max(0.3, aspect) * t)))
        let centre = ground + outward * ((lo + hi) / 2 - p)
        let target = centre + outward * (0.2 * height * t)
        return HawkEyeCamera(position: target - outward * (height * tan(Self.measureTilt * .pi / 180)) + SIMD3(0, 0, height),
                             target: target, fovDegrees: Self.measureFov)
    }
    /// The camera on the way: `approach` (0…1) from the opening view to the bounce, then `zoom` (0…1)
    /// from there to the closing shot, each eased to a stop at both ends, so the camera stands still as
    /// the ball lands and again over the gap.
    public func camera(approach: Double, zoom: Double, aspect: Double) -> HawkEyeCamera {
        func ease(_ f: Double) -> Double { let c = max(0, min(1, f)); return c * c * c * (c * (c * 6 - 15) + 10) }
        func blend(_ a: HawkEyeCamera, _ b: HawkEyeCamera, _ e: Double) -> HawkEyeCamera {
            HawkEyeCamera(position: a.position + (b.position - a.position) * e, target: a.target + (b.target - a.target) * e,
                          fovDegrees: a.fovDegrees + (b.fovDegrees - a.fovDegrees) * e)
        }
        let chase = Self.fitted(chaseCamera, aspect: aspect)
        return zoom > 0 ? blend(chase, measureCamera(aspect: aspect), ease(zoom)) : blend(Self.fitted(openingCamera, aspect: aspect), chase, ease(approach))
    }
    /// The opening and beside views are framed for 16:9: a wider screen narrows the vertical field and a
    /// taller one widens it (within limits), so the court keeps about the same width on screen.
    static func fitted(_ camera: HawkEyeCamera, aspect: Double) -> HawkEyeCamera {
        let k = min(1.5, max(0.72, (16.0 / 9) / max(0.1, aspect)))
        var c = camera
        c.fovDegrees = 2 * atan(tan(camera.fovDegrees * .pi / 360) * k) * 180 / .pi
        return c
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
