import Foundation
import simd

/// Court keypoints predicted on one picture, used only as extra start cameras for the line refinement.
/// The calibrator still decides: a start from keypoints is refined against the painted lines and passes
/// the same refusal checks as one from the line search, so a wrong keypoint costs time, not a wrong court.
public struct IndependentCourtKeypoints: Sendable, Equatable {
    /// Ground points in the court frame of `IndependentCourtModel`, in the order the keypoint model
    /// outputs them (`scripts/court-keypoints/labels.py`).
    public static let names = ["D_near_L", "D_near_R", "D_far_L", "D_far_R", "S_near_L", "S_near_R", "S_far_L", "S_far_R",
                               "SV_near_L", "SV_near_R", "SV_far_L", "SV_far_R", "T_near", "T_far"]
    public static let court: [SIMD2<Double>] = {
        let M = IndependentCourtModel.self
        let s = M.s, d = M.d, yb = M.yNearBaseline, yfb = M.yFarBaseline, ys = M.yNearService, yfs = M.yFarService
        return [SIMD2(-d, yb), SIMD2(d, yb), SIMD2(-d, yfb), SIMD2(d, yfb), SIMD2(-s, yb), SIMD2(s, yb), SIMD2(-s, yfb), SIMD2(s, yfb),
                SIMD2(-s, ys), SIMD2(s, ys), SIMD2(-s, yfs), SIMD2(s, yfs), SIMD2(0, ys), SIMD2(0, yfs)]
    }()

    /// Full-resolution pixel of each keypoint, nil when the model does not see it.
    public var pixels: [SIMD2<Double>?]

    public init(pixels: [SIMD2<Double>?]) {
        precondition(pixels.count == Self.names.count)
        self.pixels = pixels
    }

    /// Start cameras from these keypoints: a least-squares homography of all seen points, and when more
    /// than five are seen, the fits that leave out the single worst point. Each start must pass the same
    /// closed-form camera gates as a line-search hypothesis. At most `limit`, best agreement first.
    func hypotheses(limit: Int = 2) -> [(homography: [Double], camera: IndependentCourtSearch.Pinhole, error: Double)] {
        let seen = pixels.indices.filter { pixels[$0] != nil }
        guard seen.count >= 4 else { return [] }
        var sets = [seen]
        if seen.count > 5 { sets += seen.map { drop in seen.filter { $0 != drop } } }
        let W = Double(IndependentCourtCalibrator.width), H = Double(IndependentCourtCalibrator.height)
        var out = [(homography: [Double], camera: IndependentCourtSearch.Pinhole, error: Double)]()
        for set in sets {
            guard let h = Self.homography(court: set.map { Self.court[$0] }, pixels: set.map { pixels[$0]! }),
                  let p = IndependentCourtSearch.pinhole(h, cx: W / 2, cy: H / 2), IndependentCourtSearch.passes(p) else { continue }
            let errors = set.map { i -> Double in
                let c = Self.court[i], v = SIMD3(h[0] * c.x + h[1] * c.y + h[2], h[3] * c.x + h[4] * c.y + h[5], h[6] * c.x + h[7] * c.y + h[8])
                return simd_length(SIMD2(v.x / v.z, v.y / v.z) - pixels[i]!)
            }
            out.append((h, p, errors.sorted()[errors.count / 2]))
        }
        out.sort { $0.error < $1.error }
        var kept = [(homography: [Double], camera: IndependentCourtSearch.Pinhole, error: Double)]()
        for c in out where kept.allSatisfy({ simd_length($0.camera.C - c.camera.C) > 0.3 }) {
            kept.append(c)
            if kept.count == limit { break }
        }
        return kept
    }

    /// Court plane (x, y, 1) to pixels from at least 4 pairs: normalised DLT with h33 = 1, least squares.
    static func homography(court: [SIMD2<Double>], pixels: [SIMD2<Double>]) -> [Double]? {
        guard court.count >= 4, court.count == pixels.count else { return nil }
        func normaliser(_ p: [SIMD2<Double>]) -> (simd_double3x3, [SIMD2<Double>]) {
            let m = p.reduce(.zero, +) / Double(p.count)
            let d = p.map { simd_length($0 - m) }.reduce(0, +) / Double(p.count)
            let s = d > 1e-9 ? 2.0.squareRoot() / d : 1
            let T = simd_double3x3(rows: [SIMD3(s, 0, -s * m.x), SIMD3(0, s, -s * m.y), SIMD3(0, 0, 1)])
            return (T, p.map { ($0 - m) * s })
        }
        let (Tc, c) = normaliser(court), (Tp, q) = normaliser(pixels)
        // A h = b with 8 unknowns; normal equations solved by Gaussian elimination with pivoting
        var M = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        func add(_ row: [Double], _ rhs: Double) {
            for i in 0..<8 { for j in 0..<8 { M[i][j] += row[i] * row[j] }; M[i][8] += row[i] * rhs }
        }
        for (a, b) in zip(c, q) {
            add([a.x, a.y, 1, 0, 0, 0, -a.x * b.x, -a.y * b.x], b.x)
            add([0, 0, 0, a.x, a.y, 1, -a.x * b.y, -a.y * b.y], b.y)
        }
        for col in 0..<8 {
            guard let piv = (col..<8).max(by: { abs(M[$0][col]) < abs(M[$1][col]) }), abs(M[piv][col]) > 1e-12 else { return nil }
            M.swapAt(col, piv)
            for r in 0..<8 where r != col {
                let k = M[r][col] / M[col][col]
                if k != 0 { for j in col...8 { M[r][j] -= k * M[col][j] } }
            }
        }
        let h = (0..<8).map { M[$0][8] / M[$0][$0] }
        let Hn = simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], 1)])
        let Hm = Tp.inverse * Hn * Tc
        let s = Hm[2][2]
        guard abs(s) > 1e-12 else { return nil }
        // simd is column-major: Hm[c][r]
        return [Hm[0][0], Hm[1][0], Hm[2][0], Hm[0][1], Hm[1][1], Hm[2][1], Hm[0][2], Hm[1][2], Hm[2][2]].map { $0 / s }
    }
}
