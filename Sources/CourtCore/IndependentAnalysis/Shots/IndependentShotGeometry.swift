import Foundation
import simd

/// Court frame of the in-house shot chain: x lateral (m, 0 on the centre service line), y along the
/// court from the outer edge of the near baseline (m), z up (m). The App's `TennisBounceEstimate`
/// uses x from the near-left doubles sideline instead; convert with `courtX(fromCentred:)`.
public enum IndependentCourt {
    public static let netY = 11.885
    public static let length = 23.77
    public static let doublesHalfWidth = 5.485
    public static let ballRadius = 0.033
    public static func courtX(fromCentred x: Double) -> Double { x + doublesHalfWidth }
}

/// Pinhole camera, principal point fixed, square pixels, no distortion. Same model and JSON layout as
/// `scripts/speed-fullvideo/camera.py` (f, rvec as a Rodrigues vector, tvec, principal).
public struct IndependentPinholeCamera: Codable, Sendable, Hashable {
    public let f: Double
    public let rvec: [Double]
    public let tvec: [Double]
    public let principal: [Double]

    private enum CodingKeys: String, CodingKey { case f, rvec, tvec, principal }

    public init(f: Double, rvec: [Double], tvec: [Double], principal: [Double]) {
        self.f = f; self.rvec = rvec; self.tvec = tvec; self.principal = principal
    }

    public var rotation: simd_double3x3 { Self.rodrigues(SIMD3(rvec[0], rvec[1], rvec[2])) }
    public var translation: SIMD3<Double> { SIMD3(tvec[0], tvec[1], tvec[2]) }
    /// Camera centre in court coordinates.
    public var centre: SIMD3<Double> { -(rotation.transpose * translation) }

    /// Camera at `centre` looking at `target` (court coordinates, z up), image x to the right.
    public static func lookingAt(_ target: SIMD3<Double>, from centre: SIMD3<Double>, f: Double, width: Double = 1920, height: Double = 1080) -> Self {
        let z = simd_normalize(target - centre)
        let x = simd_normalize(simd_cross(z, SIMD3(0, 0, 1)))
        let y = simd_cross(z, x)
        let R = simd_double3x3(rows: [x, y, z])
        let r = rotationVector(R), t = -(R * centre)
        return Self(f: f, rvec: [r.x, r.y, r.z], tvec: [t.x, t.y, t.z], principal: [width / 2, height / 2])
    }

    /// Inverse Rodrigues (rotation angle below pi).
    public static func rotationVector(_ R: simd_double3x3) -> SIMD3<Double> {
        // simd is column-major: R[c][r] is row r, column c
        let tr = R[0][0] + R[1][1] + R[2][2]
        let theta = acos(min(1, max(-1, (tr - 1) / 2)))
        if theta < 1e-12 { return .zero }
        let axis = SIMD3(R[1][2] - R[2][1], R[2][0] - R[0][2], R[0][1] - R[1][0]) / (2 * sin(theta))
        return axis * theta
    }

    /// OpenCV's Rodrigues formula.
    public static func rodrigues(_ r: SIMD3<Double>) -> simd_double3x3 {
        let theta = simd_length(r)
        if theta < 1e-12 { return matrix_identity_double3x3 }
        let k = r / theta, c = cos(theta), s = sin(theta)
        let kx = simd_double3x3(rows: [SIMD3(0, -k.z, k.y), SIMD3(k.z, 0, -k.x), SIMD3(-k.y, k.x, 0)])
        let kk = simd_double3x3(rows: [SIMD3(k.x*k.x, k.x*k.y, k.x*k.z), SIMD3(k.y*k.x, k.y*k.y, k.y*k.z), SIMD3(k.z*k.x, k.z*k.y, k.z*k.z)])
        return c * matrix_identity_double3x3 + (1 - c) * kk + s * kx
    }
}

/// Precomputed projection for hot loops.
public struct IndependentProjector: Sendable {
    public let f: Double, cx: Double, cy: Double
    public let R: simd_double3x3, t: SIMD3<Double>, C: SIMD3<Double>
    public init(_ camera: IndependentPinholeCamera) {
        f = camera.f; cx = camera.principal[0]; cy = camera.principal[1]
        R = camera.rotation; t = camera.translation; C = camera.centre
    }
    /// Pixel and depth along the optical axis.
    @inline(__always) public func project(_ X: SIMD3<Double>) -> (u: Double, v: Double, depth: Double) {
        let p = R * X + t
        return (p.x / p.z * f + cx, p.y / p.z * f + cy, p.z)
    }
    @inline(__always) public func ray(_ u: Double, _ v: Double) -> SIMD3<Double> {
        let d = R.transpose * SIMD3((u - cx) / f, (v - cy) / f, 1)
        return d / simd_length(d)
    }
    public func onPlaneZ(_ u: Double, _ v: Double, z: Double) -> SIMD3<Double> {
        let d = ray(u, v); return C + d * ((z - C.z) / d.z)
    }
    /// Point on the plane y = const and the ray parameter (distance along the unit ray).
    public func onPlaneY(_ u: Double, _ v: Double, y: Double) -> (SIMD3<Double>, Double) {
        let d = ray(u, v); let s = (y - C.y) / d.y
        return (C + d * s, s)
    }
}

// MARK: - small numerics

enum IndependentNumerics {
    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a, y = b
        for col in 0..<n {
            var piv = col
            for r in (col + 1)..<max(col + 1, n) where abs(m[r][col]) > abs(m[piv][col]) { piv = r }
            if abs(m[piv][col]) < 1e-300 || !m[piv][col].isFinite { return nil }
            if piv != col { m.swapAt(piv, col); y.swapAt(piv, col) }
            for r in (col + 1)..<max(col + 1, n) {
                let f = m[r][col] / m[col][col]
                if f == 0 { continue }
                for c in col..<n { m[r][c] -= f * m[col][c] }
                y[r] -= f * y[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = y[r]
            for c in (r + 1)..<max(r + 1, n) { s -= m[r][c] * x[c] }
            x[r] = s / m[r][r]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Python's round(): half to even.
    @inline(__always) static func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }
    @inline(__always) static func sign(_ x: Double) -> Double { x > 0 ? 1 : (x < 0 ? -1 : 0) }
}

/// Least-squares polynomial of degree <= 2 in a centred, scaled variable (numerically stable for
/// absolute times); evaluates like numpy.polyfit/polyval.
struct IndependentPoly {
    let centre: Double, scale: Double
    let c: [Double]   // ascending powers of s = (t - centre) / scale

    init(t: [Double], y: [Double], degree: Int) {
        let n = t.count
        let mean = t.reduce(0, +) / Double(max(n, 1))
        let spread = t.map { abs($0 - mean) }.max() ?? 1
        centre = mean; scale = spread > 0 ? spread : 1
        let d = max(0, degree)
        let s = t.map { ($0 - mean) / (spread > 0 ? spread : 1) }
        var A = [[Double]](repeating: [Double](repeating: 0, count: d + 1), count: d + 1)
        var b = [Double](repeating: 0, count: d + 1)
        for i in 0..<n {
            var p = [Double](repeating: 1, count: 2 * d + 1)
            for k in 1..<(2 * d + 1) { p[k] = p[k - 1] * s[i] }
            for r in 0...d {
                b[r] += p[r] * y[i]
                for q in 0...d { A[r][q] += p[r + q] }
            }
        }
        c = IndependentNumerics.solve(A, b) ?? [Double](repeating: 0, count: d + 1)
    }
    func value(_ t: Double) -> Double {
        let s = (t - centre) / scale
        var v = 0.0
        for k in stride(from: c.count - 1, through: 0, by: -1) { v = v * s + c[k] }
        return v
    }
    func derivative(_ t: Double) -> Double {
        let s = (t - centre) / scale
        var v = 0.0
        for k in stride(from: c.count - 1, through: 1, by: -1) { v = v * s + Double(k) * c[k] }
        return v / scale
    }
}
