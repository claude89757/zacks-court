import Foundation
import simd

/// A labelled 2 x 2 line hypothesis with its closed-form camera (`court_auto.search` row).
public struct IndependentCourtHypothesis: Sendable {
    /// Court plane (x, y, 1) to full-resolution pixels, row-major.
    public let homography: [Double]
    public let f: Double
    public let rotation: simd_double3x3, translation: SIMD3<Double>, centre: SIMD3<Double>
    /// Coverage score of all model lines on the dilated evidence.
    public let score: Double
    /// ITF labels of the two transverse lines, then the two longitudinal lines.
    public let labels: [String]
    /// Indices into the sorted transverse (two) and longitudinal (two) search lines.
    public let lines: [Int]

    /// Start vector for refinement: f, Rodrigues vector, translation.
    var parameters: [Double] {
        let r = IndependentPinholeCamera.rotationVector(rotation)
        return [f, r.x, r.y, r.z, translation.x, translation.y, translation.z]
    }
}

enum IndependentCourtSearch {
    typealias Line = IndependentCourtImageLine
    static let halfScale = 0.5

    struct Result {
        var candidates: [IndependentCourtHypothesis] = []
        var transverse: [Line] = [], longitudinal: [Line] = []
        var hypotheses = 0, gated = 0
    }

    // MARK: homography and closed-form camera

    /// Row-major 3x3 product with sequential sums.
    @inline(__always) static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var o = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { o[3 * r + c] = a[3 * r] * b[c] + a[3 * r + 1] * b[3 + c] + a[3 * r + 2] * b[6 + c] } }
        return o
    }

    /// Homography taking the unit square (0,0), (1,0), (1,1), (0,1) to the quad q (`square_to_quad`).
    static func squareToQuad(_ q: [SIMD2<Double>]) -> [Double] {
        let x0 = q[0].x, y0 = q[0].y, x1 = q[1].x, y1 = q[1].y, x2 = q[2].x, y2 = q[2].y, x3 = q[3].x, y3 = q[3].y
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var den = dx1 * dy2 - dx2 * dy1
        if abs(den) < 1e-12 { den = 1e-12 }
        let g = (dx3 * dy2 - dx2 * dy3) / den
        let h = (dx1 * dy3 - dx3 * dy1) / den
        return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
                y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
                g, h, 1]
    }

    struct Pinhole { var f: Double, R: simd_double3x3, t: SIMD3<Double>, C: SIMD3<Double>, cos: Double, ratio: Double, ok: Bool }

    /// Closed-form f, R, t from a court-plane homography with the principal point fixed (`pinhole_from_H`).
    /// Returns nil when a gate that does not need the rotation already fails (`passGate` false).
    static func pinhole(_ H: [Double], cx: Double, cy: Double, s: Double = 1000, gateOnly: Bool = true) -> Pinhole? {
        let Nm: [Double] = [1 / s, 0, -cx / s, 0, 1 / s, -cy / s, 0, 0, 1]
        let G = mul(Nm, H)
        let g1 = SIMD3(G[0], G[3], G[6]), g2 = SIMD3(G[1], G[4], G[7]), g3 = SIMD3(G[2], G[5], G[8])
        let a1 = g1.x * g2.x + g1.y * g2.y, a0 = g1.z * g2.z
        let b1 = g1.x * g1.x + g1.y * g1.y - g2.x * g2.x - g2.y * g2.y, b0 = g1.z * g1.z - g2.z * g2.z
        var w = -(a1 * a0 + b1 * b0) / (a1 * a1 + b1 * b1 + 1e-30)
        let ok = w > 0
        if !ok { w = 1 }
        let fp = 1 / w.squareRoot()
        let k = 1 / fp
        let r1 = SIMD3(k * g1.x, k * g1.y, g1.z), r2 = SIMD3(k * g2.x, k * g2.y, g2.z)
        var t = SIMD3(k * g3.x, k * g3.y, g3.z)
        let n1 = (r1.x * r1.x + r1.y * r1.y + r1.z * r1.z).squareRoot(), n2 = (r2.x * r2.x + r2.y * r2.y + r2.z * r2.z).squareRoot()
        let cosang = abs(r1.x * r2.x + r1.y * r2.y + r1.z * r2.z) / (n1 * n2)
        let ratio = n1 / n2, lam = 2 / (n1 + n2)
        let f = fp * s
        if gateOnly && !(ok && cosang < 0.15 && abs(ratio - 1) < 0.15 && f > 500 && f < 3500) { return nil }
        let r1n = r1 / n1, r2n = r2 / n2
        let r3 = SIMD3(r1n.y * r2n.z - r1n.z * r2n.y, r1n.z * r2n.x - r1n.x * r2n.z, r1n.x * r2n.y - r1n.y * r2n.x)
        var R = polar(simd_double3x3(columns: (r1n, r2n, r3)))
        t = t * lam
        let depth = R[1][2] * IndependentCourt.netY + t.z   // (R @ (0, netY, 0)).z + t.z
        if depth < 0 {
            R = simd_double3x3(columns: (-R[0], -R[1], R[2]))
            t = -t
        }
        let C = -(R.transpose * t)
        return Pinhole(f: f, R: R, t: t, C: C, cos: cosang, ratio: ratio, ok: ok)
    }

    /// Nearest rotation (the orthogonal polar factor U V^T of the SVD) by Newton's iteration.
    static func polar(_ m: simd_double3x3) -> simd_double3x3 {
        var x = m
        for _ in 0..<30 {
            let next = 0.5 * (x + x.inverse.transpose)
            let d = next - x
            x = next
            let e = max(simd_length(d[0]), max(simd_length(d[1]), simd_length(d[2])))
            if e < 1e-15 { break }
        }
        return x
    }

    static func passes(_ p: Pinhole) -> Bool {
        p.ok && p.cos < 0.15 && abs(p.ratio - 1) < 0.15 && p.f > 500 && p.f < 3500
            && p.C.z > 0.4 && p.C.z < 8 && p.C.y < 1.5 && p.C.y > -30 && abs(p.C.x) < 12
    }

    /// Homography of a camera (`H_of`): K [r1 r2 t].
    static func homography(f: Double, R: simd_double3x3, t: SIMD3<Double>, cx: Double, cy: Double) -> [Double] {
        let K: [Double] = [f, 0, cx, 0, f, cy, 0, 0, 1]
        let B: [Double] = [R[0][0], R[1][0], t.x, R[0][1], R[1][1], t.y, R[0][2], R[1][2], t.z]
        return mul(K, B)
    }

    // MARK: coverage score

    /// Per-line coverage of the projected model lines on the dilated half-resolution evidence (`score_H`):
    /// a line with at least 6 visible samples adds weight x (2 coverage - 1) x min(1, visible / 20).
    static func score(_ H: [Double], hit: [UInt8], width hw: Int, height hh: Int) -> Double {
        let pts = IndependentCourtModel.scorePoints, lines = IndependentCourtModel.scoreLines
        let ns = IndependentCourtModel.samplesPerScoreLine
        var contrib = [Double](repeating: 0, count: lines.count)
        for (l, line) in lines.enumerated() {
            var nvis = 0, nhit = 0
            for s in 0..<ns {
                let p = pts[l * ns + s]
                let px = H[0] * p.x + H[1] * p.y + H[2], py = H[3] * p.x + H[4] * p.y + H[5], z = H[6] * p.x + H[7] * p.y + H[8]
                let zz = abs(z) < 1e-12 ? 1e-12 : z
                let u = px / zz * halfScale, v = py / zz * halfScale
                guard z > 0, u >= 2, u < Double(hw - 2), v >= 2, v < Double(hh - 2) else { continue }
                nvis += 1
                let ui = min(max(IndependentNumerics.pyRound(u), 0), hw - 1), vi = min(max(IndependentNumerics.pyRound(v), 0), hh - 1)
                if hit[vi * hw + ui] != 0 { nhit += 1 }
            }
            let cov = Double(nhit) / Double(max(nvis, 1))
            contrib[l] = nvis >= 6 ? line.weight * (2 * cov - 1) * min(1, Double(nvis) / 20) : 0
        }
        return NumPy.pairwiseSum(contrib[...])
    }

    // MARK: search

    /// 2 transverse x 2 longitudinal lines, each labelled with two ITF lines, give a homography and a
    /// closed-form camera; plausible cameras are ranked by coverage (`search`).
    static func run(transverse trans0: [Line], longitudinal longi0: [Line], hit: [UInt8], halfWidth hw: Int, halfHeight hh: Int,
                    maxTransverse: Int = 10, maxLongitudinal: Int = 10, keep: Int = 400) -> Result {
        let W = Double(hw) / halfScale, Hh = Double(hh) / halfScale
        var trans = Array(IndependentCourtLines.bySupport(trans0).prefix(maxTransverse))
        var longi = Array(IndependentCourtLines.bySupport(longi0).prefix(maxLongitudinal))
        let refY = 0.75 * Hh * halfScale, midX = W * halfScale / 2
        trans = NumPy.stableOrder(trans.map { -($0.point.y + (midX - $0.point.x) * $0.direction.y / $0.direction.x) }).map { trans[$0] }
        longi = NumPy.stableOrder(longi.map { $0.point.x + (refY - $0.point.y) * $0.direction.x / $0.direction.y }).map { longi[$0] }
        var result = Result(transverse: trans, longitudinal: longi)
        guard trans.count >= 2, longi.count >= 2 else { return result }
        let TL = trans.map(\.homogeneous), LL = longi.map(\.homogeneous)
        var X = [[SIMD2<Double>]](repeating: [], count: TL.count)
        for i in TL.indices {
            X[i] = LL.map { l in
                let v = IndependentCourtLines.cross(TL[i], l)
                let z = abs(v.z) < 1e-12 ? 1e-12 : v.z
                return SIMD2(v.x / z / halfScale, v.y / z / halfScale)
            }
        }
        let yv = IndependentCourtModel.yLabels.map(\.1), xv = IndependentCourtModel.xLabels.map(\.1)
        let cx = W / 2, cy = Hh / 2
        var gatedH = [[Double]](), gatedP = [Pinhole](), gatedRow = [[Int]]()
        var rows = 0
        for i in 0..<trans.count { for j in (i + 1)..<max(i + 1, trans.count) {
            for a in 0..<4 { for b in (a + 1)..<4 {
                for k in 0..<longi.count { for m in (k + 1)..<max(k + 1, longi.count) {
                    let Hq = squareToQuad([X[i][k], X[i][m], X[j][m], X[j][k]])
                    for c in 0..<5 { for d in (c + 1)..<5 {
                        rows += 1
                        let xa = xv[c], xb = xv[d], ya = yv[a], yb = yv[b]
                        let Mw: [Double] = [1 / (xb - xa), 0, -xa / (xb - xa), 0, 1 / (yb - ya), -ya / (yb - ya), 0, 0, 1]
                        let Hs = mul(Hq, Mw)
                        guard let p = pinhole(Hs, cx: cx, cy: cy), passes(p) else { continue }
                        gatedH.append(Hs); gatedP.append(p); gatedRow.append([i, j, a, b, k, m, c, d])
                    } }
                } }
            } }
        } }
        result.hypotheses = rows; result.gated = gatedH.count
        guard !gatedH.isEmpty else { return result }
        let scores = gatedH.map { score($0, hit: hit, width: hw, height: hh) }
        let order = NumPy.argsort(scores.map { -$0 })
        let sortedScores = scores.sorted(by: >)
        let ylab = IndependentCourtModel.yLabels.map(\.0), xlab = IndependentCourtModel.xLabels.map(\.0)
        for (n, s) in zip(order.prefix(keep), sortedScores.prefix(keep)) {
            let p = gatedP[n], r = gatedRow[n]
            result.candidates.append(IndependentCourtHypothesis(homography: gatedH[n], f: p.f, rotation: p.R, translation: p.t, centre: p.C,
                                                                score: s, labels: [ylab[r[2]], ylab[r[3]], xlab[r[6]], xlab[r[7]]],
                                                                lines: [r[0], r[1], r[4], r[5]]))
        }
        return result
    }

    /// Greedy de-duplication: a hypothesis is new when its camera centre is > 0.5 m or its focal length
    /// > 5% from every kept one (`distinct`).
    static func distinct(_ cands: [IndependentCourtHypothesis], dC: Double = 0.5, df: Double = 0.05) -> [IndependentCourtHypothesis] {
        var out = [IndependentCourtHypothesis]()
        for c in cands where out.allSatisfy({ simd_length(c.centre - $0.centre) > dC || abs(c.f / $0.f - 1) > df }) {
            out.append(c)
        }
        return out
    }
}
