import Foundation
import simd

/// Ball flight with gravity and quadratic drag (no spin), integrated with RK4 on a 1/120 s grid, and
/// the robust Levenberg-Marquardt fits of `scripts/speed-fullvideo/flight.py`. Times are in 1/60 s
/// units of real presentation time ("frames"), so variable-frame-rate video stays exact.
public enum IndependentFlight {
    public static let g = 9.80665
    public static let drag = 0.0196       // 1/m: rho*Cd*A/(2m), rho 1.2, Cd 0.55, d 6.7 cm, m 57.7 g
    public static let fps = 60.0
    static let substeps = 2.0

    public struct State: Sendable, Equatable {
        public var p: SIMD3<Double>
        public var v: SIMD3<Double>
        public init(p: SIMD3<Double>, v: SIMD3<Double>) { self.p = p; self.v = v }
        init(_ x: [Double]) { p = SIMD3(x[0], x[1], x[2]); v = SIMD3(x[3], x[4], x[5]) }
        var array: [Double] { [p.x, p.y, p.z, v.x, v.y, v.z] }
        var isFinite: Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite && v.x.isFinite && v.y.isFinite && v.z.isFinite }
    }

    @inline(__always) static func derivative(_ s: State) -> State {
        let sp = simd_length(s.v)
        var a = -drag * sp * s.v
        a.z -= g
        return State(p: s.v, v: a)
    }

    @inline(__always) public static func rk4(_ s: State, _ dt: Double) -> State {
        let k1 = derivative(s)
        let k2 = derivative(State(p: s.p + dt / 2 * k1.p, v: s.v + dt / 2 * k1.v))
        let k3 = derivative(State(p: s.p + dt / 2 * k2.p, v: s.v + dt / 2 * k2.v))
        let k4 = derivative(State(p: s.p + dt * k3.p, v: s.v + dt * k3.v))
        return State(p: s.p + dt / 6 * (k1.p + 2 * k2.p + 2 * k3.p + k4.p),
                     v: s.v + dt / 6 * (k1.v + 2 * k2.v + 2 * k3.v + k4.v))
    }

    /// The velocity that, under this model's drag, carries the ball from `p0` to `p1` in `T` seconds.
    /// The closed form used for a reported speed, `(p1 - p0) / T + g T / 2`, is exact only without drag,
    /// and drag makes it understate the initial speed the longer the flight (2026-11-07, docs/verification.md).
    public static func initialVelocity(from p0: SIMD3<Double>, to p1: SIMD3<Double>, over T: Double,
                                       iterations: Int = 8) -> SIMD3<Double>? {
        guard T > 1e-3, p0.x.isFinite, p1.x.isFinite else { return nil }
        var v = (p1 - p0) / T
        v.z += 0.5 * g * T
        for _ in 0..<iterations {
            let f = simulate(State(p: p0, v: v), [T * fps])[0].p - p1
            if simd_length(f) < 1e-4 { return v }
            var cols = [SIMD3<Double>]()
            for j in 0..<3 {
                var vv = v
                vv[j] += 0.4
                cols.append((simulate(State(p: p0, v: vv), [T * fps])[0].p - p1 - f) / 0.4)
            }
            let J = simd_double3x3(columns: (cols[0], cols[1], cols[2]))
            guard J.determinant.magnitude > 1e-12 else { return nil }
            let d = J.inverse * (-f)
            guard d.x.isFinite, d.y.isFinite, d.z.isFinite else { return nil }
            v += simd_clamp(d, SIMD3(repeating: -25), SIMD3(repeating: 25))
        }
        return nil
    }

    /// States at offsets (1/60 s units, any sign, may be fractional) from `s0` at time 0.
    public static func simulate(_ s0: State, _ offsets: [Double]) -> [State] {
        var out = [State](repeating: s0, count: offsets.count)
        let h = 1.0 / (fps * substeps)
        for sign in [1.0, -1.0] {
            let idx = offsets.indices.filter { sign > 0 ? offsets[$0] >= 0 : offsets[$0] < 0 }
            if idx.isEmpty { continue }
            let a = idx.map { abs(offsets[$0] * substeps) }
            let kf = a.map { Int(floor($0 + 1e-9)) }
            let n = kf.max() ?? 0
            var traj = [State](); traj.reserveCapacity(n + 1); traj.append(s0)
            var s = s0
            if n > 0 { for _ in 1...n { s = rk4(s, sign * h); traj.append(s) } }
            for (m, i) in idx.enumerated() {
                let rem = (a[m] - Double(kf[m])) * h * sign
                let base = traj[kf[m]]
                out[i] = abs(rem) > 1e-12 ? rk4(base, rem) : base
            }
        }
        return out
    }

    /// State at a fractional frame time from a state at integer frame F0.
    static func state(at t: Double, from x: State, F0: Int) -> State {
        let fl = floor(t)
        let s = simulate(x, [fl - Double(F0)])[0]
        let d = (t - fl) / fps
        return d > 1e-9 ? rk4(s, d) : s
    }

    // MARK: Levenberg-Marquardt core

    /// Generic LM with forward-difference Jacobian and per-point Huber weights on the first `2n`
    /// residuals (extras weighted 1). Mirrors the numpy loops exactly (damping, retries, stop rule).
    static func levenbergMarquardt(x0: [Double], steps h: [Double], stopScale: [Double], pointCount n: Int,
                                   iterations: Int, huber: Double, residuals: ([Double]) -> [Double]) -> (x: [Double], r: [Double]) {
        let dim = x0.count
        func weights(_ r: [Double]) -> [Double] {
            var w = [Double](repeating: 1, count: r.count)
            for i in 0..<n {
                let e = (r[2*i] * r[2*i] + r[2*i+1] * r[2*i+1]).squareRoot()
                let wi = e < huber ? 1.0 : (huber / max(e, 1e-9)).squareRoot()
                w[2*i] = wi; w[2*i+1] = wi
            }
            return w
        }
        func cost(_ r: [Double], _ w: [Double]) -> Double {
            var c = 0.0; for i in r.indices { let q = w[i] * r[i]; c += q * q }; return c
        }
        var x = x0, lam = 1e-2
        var r = residuals(x), w = weights(r), c = cost(r, w)
        for _ in 0..<iterations {
            var J = [[Double]](repeating: [Double](repeating: 0, count: dim), count: r.count)
            for j in 0..<dim {
                var xp = x; xp[j] += h[j]
                let rp = residuals(xp)
                for i in r.indices { J[i][j] = (rp[i] - r[i]) / h[j] * w[i] }
            }
            var A = [[Double]](repeating: [Double](repeating: 0, count: dim), count: dim)
            var g = [Double](repeating: 0, count: dim)
            for i in r.indices {
                let rw = r[i] * w[i]
                for p in 0..<dim {
                    let jp = J[i][p]; if jp == 0 { continue }
                    g[p] += jp * rw
                    for q in 0..<dim { A[p][q] += jp * J[i][q] }
                }
            }
            var improved = false
            var dx = [Double](repeating: 0, count: dim)
            for _ in 0..<8 {
                var M = A
                for p in 0..<dim { M[p][p] += lam * (A[p][p] + 1e-9) }
                guard let step = IndependentNumerics.solve(M, g.map { -$0 }) else { lam *= 5; continue }
                dx = step
                let xn = zip(x, dx).map(+)
                let rn = residuals(xn)
                if cost(rn, w) < c {
                    x = xn; r = rn; lam = max(lam / 4, 1e-7); improved = true
                    w = weights(r); c = cost(r, w); break
                }
                lam *= 5
            }
            var small = true
            for j in 0..<dim where abs(dx[j]) / stopScale[j] >= 1e-5 { small = false }
            if !improved || small { break }
        }
        return (x, r)
    }

    /// Per-point pixel errors and the capped RMS (errors capped at 3 x huber).
    static func errors(_ r: [Double], pointCount n: Int, huber: Double) -> ([Double], Double) {
        var e = [Double](repeating: 0, count: n), s = 0.0
        for i in 0..<n {
            e[i] = (r[2*i] * r[2*i] + r[2*i+1] * r[2*i+1]).squareRoot()
            let q = min(e[i], 3 * huber); s += q * q
        }
        return (e, n > 0 ? (s / Double(n)).squareRoot() : 0)
    }

    /// Reprojection residuals of a simulated flight; every point becomes 1e3 when any is behind the camera.
    static func pixelResiduals(_ states: [State], _ uv: [SIMD2<Double>], _ cam: IndependentProjector) -> [Double] {
        var r = [Double](repeating: 0, count: 2 * uv.count)
        var behind = false
        for i in uv.indices {
            let q = cam.project(states[i].p)
            if q.depth <= 0.5 { behind = true }
            r[2*i] = q.u - uv[i].x; r[2*i+1] = q.v - uv[i].y
        }
        if behind { for i in r.indices { r[i] = 1e3 } }
        return r
    }

    // MARK: anchored fits (bounce test, bounce-anchored initial state)

    static func anchoredState(_ P: SIMD3<Double>, at t: Double, velocity V: SIMD3<Double>) -> (Int, State) {
        let F0 = IndependentNumerics.pyRound(t)
        var s = State(p: P, v: V)
        let dt = (Double(F0) - t) / fps
        if abs(dt) > 1e-9 { s = rk4(s, dt) }
        return (F0, s)
    }

    /// Fit only the velocity at a fixed 3D anchor (e.g. a bounce on the ground).
    static func fitAnchored(_ cam: IndependentProjector, frames: [Double], uv: [SIMD2<Double>], anchor P: SIMD3<Double>,
                            at t: Double, velocity v0: SIMD3<Double>, iterations: Int = 30, huber: Double = 4) -> (SIMD3<Double>, [Double], Double) {
        let F0 = Double(IndependentNumerics.pyRound(t))
        let rel = frames.map { $0 - F0 }
        let res: ([Double]) -> [Double] = { V in
            let (_, s0) = anchoredState(P, at: t, velocity: SIMD3(V[0], V[1], V[2]))
            return pixelResiduals(simulate(s0, rel), uv, cam)
        }
        let (x, r) = levenbergMarquardt(x0: [v0.x, v0.y, v0.z], steps: [1e-3, 1e-3, 1e-3], stopScale: [1, 1, 1],
                                        pointCount: uv.count, iterations: iterations, huber: huber, residuals: res)
        let (e, rms) = errors(r, pointCount: uv.count, huber: huber)
        return (SIMD3(x[0], x[1], x[2]), e, rms)
    }

    /// Grid over velocities at the anchor, then LM from the best three.
    /// before == true: the observations precede the anchor (ball coming down to a bounce).
    public static func bestAnchored(_ cam: IndependentProjector, frames: [Double], uv: [SIMD2<Double>], anchor P: SIMD3<Double>,
                                    at t: Double, before: Bool, top: Int = 3) -> (velocity: SIMD3<Double>, errors: [Double], rms: Double) {
        let F0 = Double(IndependentNumerics.pyRound(t))
        let rel = frames.map { $0 - F0 }
        let thetas: [Double] = (0..<9).map { (k: Int) -> Double in (-40.0 + Double(k) * 10.0) * Double.pi / 180 }
        let speeds: [Double] = [5, 9, 14, 20, 27, 35, 45]
        let vzs: [Double] = before ? [-0.5, -2, -4, -6, -9, -12] : [0.5, 2, 4, 6, 9]
        var grid = [SIMD3<Double>]()
        let signs: [Double] = [1, -1]
        for sgn in signs { for a in thetas { for h in speeds { for vz in vzs {
            let vx: Double = h * sin(a), vy: Double = sgn * h * cos(a)
            grid.append(SIMD3<Double>(vx, vy, vz))
        } } } }
        var costs = [(Double, Int)]()
        costs.reserveCapacity(grid.count)
        for (k, V) in grid.enumerated() {
            let (_, s0) = anchoredState(P, at: t, velocity: V)
            let S = simulate(s0, rel)
            var sum = 0.0, behind = false
            for i in uv.indices {
                let q = cam.project(S[i].p)
                if q.depth <= 0.5 { behind = true }
                let e = ((q.u - uv[i].x) * (q.u - uv[i].x) + (q.v - uv[i].y) * (q.v - uv[i].y)).squareRoot()
                sum += min(e, 30)
            }
            var cost = sum / Double(max(uv.count, 1)) + (behind ? 1e3 : 0)
            if !cost.isFinite { cost = .infinity }
            costs.append((cost, k))
        }
        costs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var best: (SIMD3<Double>, [Double], Double)?
        for (_, k) in costs.prefix(top) {
            let fit = fitAnchored(cam, frames: frames, uv: uv, anchor: P, at: t, velocity: grid[k], iterations: 40)
            if best == nil || fit.2 < best!.2 { best = fit }
        }
        // `fitAnchored` reports nothing when the anchor and the observations give no usable flight, which the
        // caller reads as a rejection: returning an infinite residual keeps that meaning instead of trapping
        // (2026-11-07, a piece with duplicated observations reached this on the tt video at a lower candidate
        // threshold and took the whole analysis down).
        return best ?? (SIMD3<Double>(0, 0, 0), [], .infinity)
    }

    /// The best flight leaving the anchor upwards: the rising part of `bestAnchored`'s velocity grid, and its LM
    /// refinements that stay rising. A tail of a few points after a bounce fits a falling flight about as well as
    /// a rising one and LM may settle on the falling one; this asks whether rising explains it. RMS in pixels.
    /// `along`: only flights whose court-length velocity has this sign (the incoming flight's, for a bounce).
    static func risingAnchoredRMS(_ cam: IndependentProjector, frames: [Double], uv: [SIMD2<Double>], anchor P: SIMD3<Double>,
                                  at t: Double, along: Double? = nil) -> Double {
        let F0 = Double(IndependentNumerics.pyRound(t))
        let rel = frames.map { $0 - F0 }
        var tried = [(rms: Double, velocity: SIMD3<Double>)]()
        let keeps = { (V: SIMD3<Double>) -> Bool in V.z > 0 && (along.map { V.y * $0 > 0 } ?? true) }
        let directions: [Double] = along.map { [$0 > 0 ? 1 : -1] } ?? [1, -1]     // signs of the court-length velocity
        for sgn in directions {
            for k in 0..<9 {
                let a = (-40.0 + Double(k) * 10.0) * Double.pi / 180
                for h in [5.0, 9, 14, 20, 27, 35, 45] {
                    for vz in [0.5, 2, 4, 6, 9] {
                        let V = SIMD3<Double>(h * sin(a), sgn * h * cos(a), vz)
                        let (_, s0) = anchoredState(P, at: t, velocity: V)
                        let rms = errors(pixelResiduals(simulate(s0, rel), uv, cam), pointCount: uv.count, huber: 4).1
                        if rms.isFinite { tried.append((rms, V)) }
                    }
                }
            }
        }
        tried.sort { $0.rms < $1.rms }
        var best = tried.first?.rms ?? .infinity
        for (_, V) in tried.prefix(3) {
            let fit = fitAnchored(cam, frames: frames, uv: uv, anchor: P, at: t, velocity: V, iterations: 40)
            if keeps(fit.0) { best = min(best, fit.2) }
        }
        return best
    }

    // MARK: free-flight initial guesses

    /// Depth hypotheses for the first and last observation (planes y = const). `frames` start at 0.
    static func initialGuesses(_ cam: IndependentProjector, frames: [Double], uv: [SIMD2<Double>],
                               ys0: [Double] = [-1.5, 4, 10, 16, 22, 26], ys1: [Double] = [-1.5, 2, 6, 11, 16, 21, 25]) -> [State] {
        let T = (frames.last! - frames.first!) / fps
        var out = [State]()
        for y0 in ys0 {
            let (p0, s0) = cam.onPlaneY(uv[0].x, uv[0].y, y: y0)
            for y1 in ys1 {
                let (p1, s1) = cam.onPlaneY(uv[uv.count - 1].x, uv[uv.count - 1].y, y: y1)
                if s0 <= 0.5 || s1 <= 0.5 { continue }
                if !(-0.2 < p0.z && p0.z < 5 && -0.2 < p1.z && p1.z < 5 && abs(p0.x) < 12 && abs(p1.x) < 12) { continue }
                var v0 = (p1 - p0) / T; v0.z += 0.5 * g * T
                let sp = simd_length(v0)
                if !(1.5 < sp && sp < 70) { continue }
                v0 *= 1 + 0.5 * drag * sp * T
                out.append(State(p: p0, v: v0))
            }
        }
        return out
    }
}
