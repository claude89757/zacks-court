import Foundation
import simd

/// A painted line refined to its sub-pixel centreline (`lines.refine`), full-resolution pixels.
public struct IndependentCourtRefinedLine: Sendable, Codable, Equatable {
    public let point: SIMD2<Double>, direction: SIMD2<Double>, normal: SIMD2<Double>
    public let rms: Double
    public let samples: Int, rejected: Int
    public let start: SIMD2<Double>, end: SIMD2<Double>
    /// Passed the agreement checks against the predicted line (`refine_lines` ok).
    public internal(set) var ok = false
}

enum IndependentCourtRefine {
    // MARK: sub-pixel profiles

    /// `cv2.remap(..., INTER_LINEAR)` of a Float image at one point, as OpenCV 5.0 computes it: Float
    /// coordinates, floor and fraction, two fused lerps along x then one along y, zero outside.
    @inline(__always) static func sample(_ img: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int, _ x: Double, _ y: Double) -> Float {
        let sx = Float(x), sy = Float(y)
        let fx0 = sx.rounded(.down), fy0 = sy.rounded(.down)
        guard fx0.isFinite, fy0.isFinite, abs(fx0) < 1e9, abs(fy0) < 1e9 else { return 0 }
        let ix = Int(fx0), iy = Int(fy0)
        let fx = sx - fx0, fy = sy - fy0
        let p00: Float, p01: Float, p10: Float, p11: Float
        if ix >= 0 && ix < w - 1 && iy >= 0 && iy < h - 1 {
            let o = iy * w + ix
            p00 = img[o]; p01 = img[o + 1]; p10 = img[o + w]; p11 = img[o + w + 1]
        } else {
            if ix + 1 < 0 || ix + 1 >= w + 1 || iy + 1 < 0 || iy + 1 >= h + 1 { return 0 }
            func px(_ yy: Int, _ xx: Int) -> Float { xx >= 0 && xx < w && yy >= 0 && yy < h ? img[yy * w + xx] : 0 }
            p00 = px(iy, ix); p01 = px(iy, ix + 1); p10 = px(iy + 1, ix); p11 = px(iy + 1, ix + 1)
        }
        let v0 = p00.addingProduct(fx, p01 - p00), v1 = p10.addingProduct(fx, p11 - p10)
        return v0.addingProduct(fy, v1 - v0)
    }

    /// Centreline of a painted line near the rough segment p0-p1 (`lines.refine`): every 3 px a
    /// perpendicular profile (+-half px in 0.25 px steps); the centroid of the part above 40% of the peak;
    /// a total-least-squares line with 4 rounds of 3 x MAD rejection; three passes, ends re-projected.
    static func refine(_ th: [Float], width w: Int, height h: Int, from a: SIMD2<Double>, to b: SIMD2<Double>,
                       half: Double = 10, step: Double = 3, minPeak: Double = 35) -> IndependentCourtRefinedLine? {
        var p0 = a, p1 = b
        var m = SIMD2<Double>.zero, dirv = SIMD2<Double>.zero, nv = SIMD2<Double>.zero
        var r = [Double](), keep = [Bool]()
        let offs = NumPy.arange(-half, half + 0.25, 0.25)
        var prof = [Float](repeating: 0, count: offs.count), wts = [Float](repeating: 0, count: offs.count)
        var wo = [Double](repeating: 0, count: offs.count)
        for _ in 0..<3 {
            let d = p1 - p0, L = IndependentCourtLines.norm(d)
            guard L > 0, L.isFinite else { return nil }
            let u = d / L, n = SIMD2(-u.y, u.x)
            var cents = [SIMD2<Double>]()
            th.withUnsafeBufferPointer { img in
                for t in NumPy.arange(0, L, step) {
                    let c = SIMD2(p0.x + u.x * t, p0.y + u.y * t)
                    var pk = -Float.infinity
                    for (k, o) in offs.enumerated() {
                        prof[k] = sample(img, w, h, c.x + o * n.x, c.y + o * n.y)
                        pk = max(pk, prof[k])
                    }
                    if Double(pk) < minPeak { continue }
                    let cut = Float(0.4) * pk
                    for k in prof.indices { wts[k] = max(prof[k] - cut, 0) }
                    let ws = NumPy.pairwiseSum(wts[...])
                    if ws == 0 { continue }
                    for k in offs.indices { wo[k] = Double(wts[k]) * offs[k] }
                    let o = NumPy.pairwiseSum(wo[...]) / Double(ws)
                    cents.append(SIMD2(c.x + o * n.x, c.y + o * n.y))
                }
            }
            guard cents.count >= 2 else { return nil }
            keep = [Bool](repeating: true, count: cents.count)
            for _ in 0..<4 {
                let kept = cents.indices.filter { keep[$0] }
                guard kept.count >= 2 else { return nil }
                var sx = 0.0, sy = 0.0
                for k in kept { sx += cents[k].x; sy += cents[k].y }
                m = SIMD2(sx / Double(kept.count), sy / Double(kept.count))
                dirv = principalDirection(kept.map { cents[$0] - m })
                nv = SIMD2(-dirv.y, dirv.x)
                r = cents.map { IndependentCourtLines.dot($0 - m, nv) }
                let s = 1.4826 * NumPy.median(kept.map { abs(r[$0]) }) + 0.05
                keep = r.map { abs($0) < 3 * s }
            }
            let tt = cents.indices.filter { keep[$0] }.map { IndependentCourtLines.dot(cents[$0] - m, dirv) }
            guard let lo = tt.min(), let hi = tt.max() else { return nil }
            p0 = m + dirv * lo; p1 = m + dirv * hi
        }
        let kr = r.indices.filter { keep[$0] }.map { r[$0] * r[$0] }
        let n = kr.count
        return IndependentCourtRefinedLine(point: m, direction: dirv, normal: nv, rms: (NumPy.pairwiseSum(kr[...]) / Double(n)).squareRoot(),
                                           samples: n, rejected: keep.count - n, start: p0, end: p1)
    }

    /// First right singular vector of centred points, with the sign LAPACK's `dgesdd` gives it (as NumPy's
    /// `svd` returns it): Householder QR of the n x 2 matrix, then the 2 x 2 triangular SVD of `dlasv2`.
    /// Checked against NumPy (Accelerate LAPACK) on 5000 random line-like point sets, same sign every time.
    static func principalDirection(_ c: [SIMD2<Double>]) -> SIMD2<Double> {
        let alpha = c[0].x
        var xs = 0.0
        for k in 1..<c.count { xs += c[k].x * c[k].x }
        let xnorm = xs.squareRoot()
        var col2 = c.map(\.y)
        let F: Double
        if xnorm == 0 { F = alpha } else {
            let beta = -copysign(hypot(alpha, xnorm), alpha)
            let tau = (beta - alpha) / beta, scale = 1 / (alpha - beta)
            var wdot = col2[0]
            for k in 1..<c.count { wdot += c[k].x * scale * col2[k] }
            col2[0] -= tau * wdot
            for k in 1..<c.count { col2[k] -= tau * wdot * (c[k].x * scale) }
            F = beta
        }
        let G = col2[0], a2 = col2.count > 1 ? col2[1] : 0
        var x2 = 0.0
        for k in 2..<max(2, col2.count) { x2 += col2[k] * col2[k] }
        let H = x2 == 0 ? a2 : -copysign(hypot(a2, x2.squareRoot()), a2)
        let sv = dlasv2(F, G, H)
        let v = SIMD2(sv.csr, sv.snr)
        return sv.ssmax < 0 ? -v : v
    }

    /// LAPACK `dlasv2`: SVD of the upper triangular [[f, g], [0, h]].
    static func dlasv2(_ f: Double, _ g: Double, _ h: Double) -> (ssmin: Double, ssmax: Double, snr: Double, csr: Double, snl: Double, csl: Double) {
        let eps = Double.ulpOfOne / 2
        var ft = f, fa = abs(ft), ht = h, ha = abs(h)
        var pmax = 1
        let swap = ha > fa
        if swap { pmax = 3; swap2(&ft, &ht); swap2(&fa, &ha) }
        let gt = g, ga = abs(gt)
        var ssmin: Double, ssmax: Double, clt: Double, crt: Double, slt: Double, srt: Double
        if ga == 0 {
            ssmin = ha; ssmax = fa; clt = 1; crt = 1; slt = 0; srt = 0
        } else {
            var gasmal = true
            ssmin = 0; ssmax = 0; clt = 1; crt = 1; slt = 0; srt = 0
            if ga > fa {
                pmax = 2
                if fa / ga < eps {
                    gasmal = false
                    ssmax = ga
                    ssmin = ha > 1 ? fa / (ga / ha) : (fa / ga) * ha
                    clt = 1; slt = ht / gt; srt = 1; crt = ft / gt
                }
            }
            if gasmal {
                let d = fa - ha
                var l = d == fa ? 1 : d / fa
                let mm0 = gt / ft
                var t = 2 - l
                let mm = mm0 * mm0, tt = t * t
                let s = (tt + mm).squareRoot()
                let r = l == 0 ? abs(mm0) : (l * l + mm).squareRoot()
                let a = 0.5 * (s + r)
                ssmin = ha / a; ssmax = fa * a
                if mm == 0 {
                    t = l == 0 ? copysign(2, ft) * copysign(1, gt) : gt / copysign(d, ft) + mm0 / t
                } else {
                    t = (mm0 / (s + t) + mm0 / (r + l)) * (1 + a)
                }
                l = (t * t + 4).squareRoot()
                crt = 2 / l; srt = t / l
                clt = (crt + srt * mm0) / a
                slt = (ht / ft) * srt / a
            }
        }
        let csl: Double, snl: Double, csr: Double, snr: Double
        if swap { csl = srt; snl = crt; csr = slt; snr = clt } else { csl = clt; snl = slt; csr = crt; snr = srt }
        let tsign: Double
        switch pmax {
        case 1: tsign = copysign(1, csr) * copysign(1, csl) * copysign(1, f)
        case 2: tsign = copysign(1, snr) * copysign(1, csl) * copysign(1, g)
        default: tsign = copysign(1, snr) * copysign(1, snl) * copysign(1, h)
        }
        ssmax = copysign(ssmax, tsign)
        ssmin = copysign(ssmin, tsign * copysign(1, f) * copysign(1, h))
        return (ssmin, ssmax, snr, csr, snl, csl)
    }

    @inline(__always) private static func swap2(_ a: inout Double, _ b: inout Double) { let t = a; a = b; b = t }

    // MARK: camera

    /// OpenCV's Rodrigues vector to matrix (row-major).
    static func rodrigues(_ r: SIMD3<Double>) -> [Double] {
        let theta = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        if theta < Double.ulpOfOne { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        let c = cos(theta), s = sin(theta), c1 = 1 - c, it = 1 / theta
        let x = r.x * it, y = r.y * it, z = r.z * it
        let rrt = [x * x, x * y, x * z, x * y, y * y, y * z, x * z, y * z, z * z]
        let rx = [0, -z, y, z, 0, -x, -y, x, 0]
        let eye: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        return (0..<9).map { c * eye[$0] + c1 * rrt[$0] + s * rx[$0] }
    }

    /// `cv2.projectPoints` without distortion; params = f, rvec, tvec and optionally the horizontal
    /// principal coordinate as an 8th value (otherwise `cx`); principal point (cx, cy).
    struct Projection {
        let f: Double, R: [Double], t: SIMD3<Double>, cx: Double, cy: Double
        init(_ p: [Double], cx: Double, cy: Double) {
            f = p[0]; R = rodrigues(SIMD3(p[1], p[2], p[3])); t = SIMD3(p[4], p[5], p[6])
            self.cx = p.count > 7 ? p[7] : cx; self.cy = cy
        }
        @inline(__always) func depth(_ X: SIMD3<Double>) -> Double { R[6] * X.x + R[7] * X.y + R[8] * X.z + t.z }
        @inline(__always) func callAsFunction(_ X: SIMD3<Double>) -> SIMD2<Double> {
            let x = R[0] * X.x + R[1] * X.y + R[2] * X.z + t.x
            let y = R[3] * X.x + R[4] * X.y + R[5] * X.z + t.y
            let z = R[6] * X.x + R[7] * X.y + R[8] * X.z + t.z
            let iz = z != 0 ? 1 / z : 1
            return SIMD2(x * iz * f + cx, y * iz * f + cy)
        }
    }

    /// Visible part of each model line under the camera, clipped to the image shrunk by 12 px; lines
    /// shorter than 30 px are left out (`predict_lines`).
    static func predict(_ params: [Double], _ names: [IndependentCourtLine], width: Int, height: Int,
                        baselineWidth wb: Double) -> [(IndependentCourtLine, SIMD2<Double>, SIMD2<Double>)] {
        let P = Projection(params, cx: Double(width) / 2, cy: Double(height) / 2)
        let ts = NumPy.linspace(0, 1, 60)
        var out = [(IndependentCourtLine, SIMD2<Double>, SIMD2<Double>)]()
        for name in names {
            let (a, b) = name.endpoints(baselineWidth: wb)
            let X = ts.map { SIMD3(a.x + (b.x - a.x) * $0, a.y + (b.y - a.y) * $0, 0) }.filter { P.depth($0) > 0.5 }
            guard X.count >= 2, let seg = clip(P(X[0]), P(X[X.count - 1]), width: Double(width), height: Double(height)),
                  IndependentCourtLines.norm(seg.1 - seg.0) >= 30 else { continue }
            out.append((name, seg.0, seg.1))
        }
        return out
    }

    /// Liang-Barsky clip to the image shrunk by `margin` (`clip_segment`).
    static func clip(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, width W: Double, height H: Double, margin: Double = 12)
        -> (SIMD2<Double>, SIMD2<Double>)? {
        let x0 = p0.x, y0 = p0.y, dx = p1.x - x0, dy = p1.y - y0
        var t0 = 0.0, t1 = 1.0
        for (p, q) in [(-dx, x0 - margin), (dx, W - margin - x0), (-dy, y0 - margin), (dy, H - margin - y0)] {
            if abs(p) < 1e-12 { if q < 0 { return nil }; continue }
            let r = q / p
            if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
            if t0 > t1 { return nil }
        }
        return (SIMD2(x0 + dx * t0, y0 + dy * t0), SIMD2(x0 + dx * t1, y0 + dy * t1))
    }

    /// Refine every predicted line and check it against the prediction (`refine_lines`): enough samples,
    /// RMS < 2 px, within 2 degrees and `half` px of the prediction, spanning > 30% of it.
    static func refineLines(_ th: [Float], width: Int, height: Int, params: [Double], names: [IndependentCourtLine],
                            half: Double, baselineWidth wb: Double) -> [(IndependentCourtLine, IndependentCourtRefinedLine)] {
        var out = [(IndependentCourtLine, IndependentCourtRefinedLine)]()
        for (name, a, b) in predict(params, names, width: width, height: height, baselineWidth: wb) {
            let far = name.isFar
            guard var r = refine(th, width: width, height: height, from: a, to: b, half: far ? min(half, 6) : half,
                                 minPeak: far ? 20 : 35) else { continue }
            let L = IndependentCourtLines.norm(b - a), dvec = (b - a) / L
            let ang = acos(min(1, abs(IndependentCourtLines.dot(dvec, r.direction)))) * (180 / Double.pi)
            let off = abs(IndependentCourtLines.dot(r.point - a, SIMD2(-dvec.y, dvec.x)))
            let span = IndependentCourtLines.norm(r.end - r.start)
            r.ok = Double(r.samples) >= max(8, 0.25 * L / 3) && r.rms < 2.0 && ang < 2.0 && off < half && span > 0.3 * L
            out.append((name, r))
        }
        return out
    }

    // MARK: least squares

    /// Perpendicular distances of 40 projected samples per model line to the refined image lines
    /// (`camera.line_residuals`). The samples inside each fitted segment (+-5 px) are chosen at the first
    /// evaluation and then kept, so the residual length is fixed during one fit; each line is scaled by
    /// 1/sqrt(samples / 10).
    struct LineResiduals {
        let lines: [(IndependentCourtLine, IndependentCourtRefinedLine)]
        let width: Int, height: Int, baselineWidth: Double
        var masks: [IndependentCourtLine: [Bool]] = [:]
        static let ts = NumPy.linspace(0, 1, 40)

        mutating func callAsFunction(_ x: [Double]) -> [Double] {
            let P = Projection(x, cx: Double(width) / 2, cy: Double(height) / 2)
            var res = [Double]()
            for (name, L) in lines {
                let (a, b) = name.endpoints(baselineWidth: baselineWidth)
                let pts = Self.ts.map { P(SIMD3(a.x + (b.x - a.x) * $0, a.y + (b.y - a.y) * $0, 0)) }
                if masks[name] == nil {
                    let span = IndependentCourtLines.norm(L.end - L.start), dv = (L.end - L.start) / span
                    var inside = pts.map { p -> Bool in let t = IndependentCourtLines.dot(p - L.start, dv); return t > -5 && t < span + 5 }
                    if inside.filter({ $0 }).count < 5 { inside = [Bool](repeating: true, count: pts.count) }
                    masks[name] = inside
                }
                let inside = masks[name]!
                let scale = (Double(inside.filter { $0 }.count) / 10).squareRoot()
                for (p, keep) in zip(pts, inside) where keep { res.append(IndependentCourtLines.dot(p - L.point, L.normal) / scale) }
            }
            return res
        }
    }

    static func sumSquares(_ r: [Double]) -> Double { var s = 0.0; for v in r { s += v * v }; return s }

    /// Levenberg-Marquardt with forward differences (`camera.lm`): h = 1e-6 max(1, |x|), lambda from 1e-3,
    /// /3 on success, x4 on failure (gives up past 1e9), stops when max |dx| < 1e-10 or after 60 iterations.
    /// Returns J from the start of the last iteration, as the prototype does.
    static func levenbergMarquardt(_ fun: inout LineResiduals, _ x0: [Double], iterations: Int = 60, lambda lam0: Double = 1e-3)
        -> (x: [Double], r: [Double], J: [[Double]]) {
        var x = x0, lam = lam0
        var r = fun(x), cost = sumSquares(r)
        var J = [[Double]]()
        let n = x.count
        for _ in 0..<iterations {
            J = [[Double]](repeating: [Double](repeating: 0, count: n), count: r.count)
            for j in 0..<n {
                let h = 1e-6 * max(1, abs(x[j]))
                var xp = x; xp[j] += h
                let rp = fun(xp)
                for i in r.indices { J[i][j] = (rp[i] - r[i]) / h }
            }
            var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n), g = [Double](repeating: 0, count: n)
            for a in 0..<n {
                for b in 0..<n { var s = 0.0; for i in r.indices { s += J[i][a] * J[i][b] }; A[a][b] = s }
                var s = 0.0; for i in r.indices { s += J[i][a] * r[i] }; g[a] = s
            }
            var dx = [Double](repeating: 0, count: n)
            while true {
                var M = A
                for k in 0..<n { M[k][k] += lam * (A[k][k] + 1e-12) }
                guard let step = IndependentNumerics.solve(M, g) else { lam *= 4; if lam > 1e9 { return (x, r, J) }; continue }
                dx = step.map { -$0 }
                let xn = zip(x, dx).map { $0 + $1 }
                let rn = fun(xn), cn = sumSquares(rn)
                if cn < cost { x = xn; r = rn; cost = cn; lam = max(lam / 3, 1e-9); break }
                lam *= 4
                if lam > 1e9 { return (x, r, J) }
            }
            if dx.map({ abs($0) }).max()! < 1e-10 { break }
        }
        return (x, r, J)
    }

    struct Fit { var x: [Double], perLine: [(IndependentCourtLine, Double)], fSD: Double }

    /// One fit (`lm_fit`): LM on `use`, then per-line RMS (raw px) for every refined line with masks
    /// recomputed at the solution, and the focal-length standard deviation from (J^T J)^-1 r.r / (m - n),
    /// n = 7 parameters, or 8 when the horizontal principal coordinate is free.
    static func fit(_ x0: [Double], lines: [(IndependentCourtLine, IndependentCourtRefinedLine)], use: [IndependentCourtLine],
                    width: Int, height: Int, baselineWidth wb: Double) -> Fit {
        let byName = Dictionary(lines.map { ($0.0, $0) }, uniquingKeysWith: { a, _ in a })
        var fun = LineResiduals(lines: use.compactMap { byName[$0] }, width: width, height: height, baselineWidth: wb)
        let (x, r, J) = levenbergMarquardt(&fun, x0)
        var per = [(IndependentCourtLine, Double)]()
        for l in lines {
            var one = LineResiduals(lines: [l], width: width, height: height, baselineWidth: wb)
            let rr = one(x)
            let k = Double(one.masks[l.0]!.filter { $0 }.count)
            let raw = rr.map { $0 * (k / 10).squareRoot() }
            per.append((l.0, (sumSquares(raw) / Double(raw.count)).squareRoot()))
        }
        let n = x.count
        var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for a in 0..<n { for b in 0..<n { var s = 0.0; for i in J.indices { s += J[i][a] * J[i][b] }; A[a][b] = s } }
        let variance = sumSquares(r) / Double(max(1, r.count - n))
        let fSD = (inverseDiagonal0(A) * variance).squareRoot()
        return Fit(x: x, perLine: per, fSD: fSD.isFinite ? fSD : .infinity)
    }

    /// (A^-1)[0][0] of a symmetric positive semi-definite matrix, after equilibration.
    static func inverseDiagonal0(_ A: [[Double]]) -> Double {
        let n = A.count
        let s = (0..<n).map { A[$0][$0] > 0 ? 1 / A[$0][$0].squareRoot() : 1 }
        let B = (0..<n).map { i in (0..<n).map { j in A[i][j] * s[i] * s[j] } }
        var e0 = [Double](repeating: 0, count: n); e0[0] = 1
        guard let col = IndependentNumerics.solve(B, e0) else { return .infinity }
        return col[0] * s[0] * s[0]
    }
}
