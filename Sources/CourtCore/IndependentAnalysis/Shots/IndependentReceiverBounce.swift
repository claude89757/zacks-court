import Foundation
import simd

/// A bounce in the magnified far half after a near serve. The ball can disappear between contact and
/// landing, leaving no complete flight to fit. Look for the ball falling into and rising out of the
/// same observed point, with continuing horizontal motion. Only that image point is mapped to ground.
enum IndependentReceiverBounce {
    typealias Landing = (t: Double, ground: SIMD3<Double>, samples: Int)
    private struct Side { let samples: Int; let velocity: SIMD2<Double> }

    static func find(in candidates: [IndependentShotCandidate], contact: Double, camera: IndependentProjector) -> Landing? {
        let window = candidates.filter { IndependentStrokeRules.Swing.flight.contains($0.time / 60 - contact) }
        var best: (point: IndependentShotCandidate, ground: SIMD3<Double>, before: Int, total: Int)?
        for point in window {
            let ground = camera.onPlaneZ(point.u, point.v, z: IndependentCourt.ballRadius)
            guard ground.y > IndependentCourt.netY + 1, ground.y < IndependentCourt.length + 2,
                  abs(ground.x) <= IndependentCourt.doublesHalfWidth + 2,
                  let before = side(-1, at: point, in: window),
                  let after = side(1, at: point, in: window, shortRebound: before.samples >= 5),
                  before.velocity.x * after.velocity.x >= -1.5,
                  simd_length(after.velocity) <= 1.35 * simd_length(before.velocity) + 1 else { continue }
            if let b = best {
                // Neighbouring samples can describe one bend. Two different bounces are ambiguous.
                guard abs(b.point.time - point.time) <= 6, hypot(b.point.u - point.u, b.point.v - point.v) < 30 else { return nil }
                if b.total > before.samples + after.samples || (b.total == before.samples + after.samples && b.point.v >= point.v) { continue }
            }
            best = (point, ground, before.samples, before.samples + after.samples)
        }
        return best.map { ($0.point.time / 60, $0.ground, $0.before + 1) }
    }

    private static func side(_ sign: Double, at point: IndependentShotCandidate, in window: [IndependentShotCandidate],
                             shortRebound: Bool = false) -> Side? {
        let neighbours = window.filter { (0.5...6.5).contains(sign * ($0.time - point.time)) }
        var best: Side?
        for seed in neighbours {
            let dt = seed.time - point.time, dy = seed.v - point.v
            guard abs(dt) >= 1.8, dy <= -3 else { continue }
            let velocity = SIMD2(seed.u - point.u, dy) / dt
            guard (1...18).contains(simd_length(velocity)), sign * velocity.y <= -0.9 else { continue }
            var frames = Set<Int>(), duration = 0.0, vertical = 0.0
            for q in neighbours where q.v < point.v + 0.75 {
                let offset = q.time - point.time, delta = SIMD2(q.u - point.u, q.v - point.v)
                guard simd_length(delta - offset * velocity) <= 2.75 else { continue }
                frames.insert(q.decodeIndex); duration = max(duration, abs(offset)); vertical = max(vertical, -delta.y)
            }
            let sustained = frames.count >= 3 && duration >= 3.8 && vertical >= 5
            let lastTwo = shortRebound && frames.count >= 2 && duration >= 1.8 && duration <= 3.2 && vertical >= 6
            if (sustained || lastTwo) && frames.count > (best?.samples ?? 0) {
                best = Side(samples: frames.count, velocity: velocity)
            }
        }
        return best
    }
}
