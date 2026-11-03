import Foundation

/// A merged image line at half resolution (`court_auto.detect_lines` cluster).
public struct IndependentCourtImageLine: Sendable, Codable, Equatable {
    /// Creation order, used to refer to lines across stages.
    public let id: Int
    public internal(set) var point: SIMD2<Double>, direction: SIMD2<Double>, normal: SIMD2<Double>
    /// Sum of the lengths of the merged segments.
    public internal(set) var support: Double
    public internal(set) var start: SIMD2<Double> = .zero, end: SIMD2<Double> = .zero
    public internal(set) var segments = 0
    var points: [SIMD2<Double>] = [], weights: [Double] = []

    private enum CodingKeys: String, CodingKey { case id, point, direction, normal, support, start, end, segments }

    /// Homogeneous line (n, -n.p).
    var homogeneous: SIMD3<Double> { SIMD3(normal.x, normal.y, -(normal.x * point.x + normal.y * point.y)) }

    /// Weighted centroid and principal direction (`_fit`), direction with x >= 0.
    mutating func fit() {
        var ws = 0.0, mx = 0.0, my = 0.0
        for (p, w) in zip(points, weights) { mx += p.x * w; my += p.y * w; ws += w }
        let m = SIMD2(mx / ws, my / ws)
        var a = 0.0, b = 0.0, c = 0.0
        for (p, w) in zip(points, weights) {
            let dx = p.x - m.x, dy = p.y - m.y
            a += dx * w * dx; b += dx * w * dy; c += dy * w * dy
        }
        var d = IndependentCourtLines.principalEigenvector(a, b, c)
        if d.x < 0 || (abs(d.x) < 1e-9 && d.y < 0) { d = -d }
        point = m; direction = d; normal = SIMD2(-d.y, d.x)
    }
}

enum IndependentCourtLines {
    static func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
    static func norm(_ a: SIMD2<Double>) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }
    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    /// Unit eigenvector of the larger eigenvalue of [[a, b], [b, c]].
    static func principalEigenvector(_ a: Double, _ b: Double, _ c: Double) -> SIMD2<Double> {
        let half = (a - c) / 2
        let lam = (a + c) / 2 + (half * half + b * b).squareRoot()
        var v: SIMD2<Double>
        if b == 0 { v = a >= c ? SIMD2(1, 0) : SIMD2(0, 1) }
        else if a >= c { v = SIMD2(lam - c, b) } else { v = SIMD2(b, lam - a) }
        return v / norm(v)
    }

    /// Longest `maxSegments` segments merged greedily into lines: same direction within 1.5 degrees and
    /// both endpoints within 2.5 px of the line, refitting after every merge.
    static func merge(_ segs: [IndependentCourtHough.Segment], maxSegments: Int = 600) -> [IndependentCourtImageLine] {
        let lengths = segs.map { hypot(Double($0.x1 - $0.x0), Double($0.y1 - $0.y0)) }
        let order = NumPy.argsort(lengths.map { -$0 }).prefix(maxSegments)
        let cosTol = cos(1.5 * (Double.pi / 180))
        var clusters = [IndependentCourtImageLine]()
        for i in order {
            let s = segs[i], L = lengths[i]
            let a = SIMD2(Double(s.x0), Double(s.y0)), b = SIMD2(Double(s.x1), Double(s.y1))
            let d = SIMD2((b.x - a.x) / L, (b.y - a.y) / L)
            var merged = false
            for k in clusters.indices {
                let c = clusters[k]
                if abs(dot(c.direction, d)) < cosTol { continue }
                if abs(dot(a - c.point, c.normal)) < 2.5 && abs(dot(b - c.point, c.normal)) < 2.5 {
                    clusters[k].points += [a, b]; clusters[k].weights += [L, L]; clusters[k].support += L
                    clusters[k].segments += 1
                    clusters[k].fit()
                    merged = true
                    break
                }
            }
            if !merged {
                var c = IndependentCourtImageLine(id: clusters.count, point: .zero, direction: .zero, normal: .zero, support: L)
                c.points = [a, b]; c.weights = [L, L]; c.segments = 1
                c.fit()
                clusters.append(c)
            }
        }
        for k in clusters.indices {
            let c = clusters[k]
            let ts = c.points.map { dot($0 - c.point, c.direction) }
            let lo = ts.min() ?? 0, hi = ts.max() ?? 0
            clusters[k].start = c.point + c.direction * lo
            clusters[k].end = c.point + c.direction * hi
        }
        return clusters
    }

    /// Transverse (within 15 degrees of horizontal) and longitudinal lines with support >= 30.
    static func families(_ lines: [IndependentCourtImageLine], minSupport: Double = 30)
        -> (transverse: [IndependentCourtImageLine], longitudinal: [IndependentCourtImageLine]) {
        var t = [IndependentCourtImageLine](), l = [IndependentCourtImageLine]()
        for c in lines where c.support >= minSupport {
            var ang = atan2(c.direction.y, c.direction.x) * (180 / Double.pi)
            ang = NumPy.remainder(ang + 90, 180) - 90
            if abs(ang) < 15 { t.append(c) } else { l.append(c) }
        }
        return (t, l)
    }

    /// Lines in decreasing support, ties in input order (Python's stable sort).
    static func bySupport(_ lines: [IndependentCourtImageLine]) -> [IndependentCourtImageLine] {
        NumPy.stableOrder(lines.map { -$0.support }).map { lines[$0] }
    }

    /// Sideline vanishing point: every pair of the 30 best-supported longitudinal lines proposes the point;
    /// lines pointing at it within 1 degree (or 1.5 px) vote with their support; the first best wins.
    static func vanishingPoint(_ longitudinal: [IndependentCourtImageLine], tolDeg: Double = 1.0, cap: Int = 30)
        -> (point: SIMD2<Double>?, inliers: [IndependentCourtImageLine]) {
        guard longitudinal.count >= 2 else { return (nil, []) }
        let longi = Array(bySupport(longitudinal).prefix(cap))
        let hl = longi.map(\.homogeneous)
        let sinTol = sin(tolDeg * (Double.pi / 180))
        var best = (score: 0.0, point: SIMD2<Double>?.none, inliers: [Int]())
        for i in longi.indices {
            for j in (i + 1)..<max(i + 1, longi.count) {
                let v3 = cross(hl[i], hl[j])
                if abs(v3.z) < 1e-9 { continue }
                let v = SIMD2(v3.x / v3.z, v3.y / v3.z)
                var inl = [Int](), sc = 0.0
                for (k, c) in longi.enumerated() {
                    let to = v - c.point, dist = norm(to)
                    if dist < 1 { continue }
                    let off = abs(dot(to, c.normal))
                    if off / dist < sinTol || off < 1.5 { inl.append(k); sc += c.support }
                }
                if sc > best.score { best = (sc, v, inl) }
            }
        }
        return (best.point, best.inliers.map { longi[$0] })
    }

    /// Ground lines lie below the horizon, taken through the vanishing point along the support-weighted
    /// median direction of the transverse lines below it.
    static func belowHorizon(_ trans: [IndependentCourtImageLine], _ longi: [IndependentCourtImageLine], vp: SIMD2<Double>,
                             margin: Double = 3.0) -> ([IndependentCourtImageLine], [IndependentCourtImageLine]) {
        let low = trans.filter { $0.point.y > vp.y }
        var a = 0.0
        if !low.isEmpty {
            let ang = low.map { atan2($0.direction.y, $0.direction.x) }
            let o = NumPy.argsort(ang)
            var cw = [Double](), acc = 0.0
            for k in o { acc += low[k].support; cw.append(acc) }
            let half = cw[cw.count - 1] / 2
            let pos = cw.firstIndex { $0 >= half } ?? cw.count - 1
            a = ang[o[pos]]
        }
        let hd = SIMD2(cos(a), sin(a))
        var hn = SIMD2(-hd.y, hd.x)
        if hn.y < 0 { hn = -hn }
        func below(_ p: SIMD2<Double>) -> Bool { dot(p - vp, hn) > margin }
        let t2 = trans.filter { below($0.start) && below($0.end) }
        let l2 = longi.filter { below($0.point) || (below($0.start) && below($0.end)) }
        return (t2, l2)
    }
}
