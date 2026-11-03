import Foundation

/// ITF court lines used by the automatic calibration, as painted-line centrelines in the court frame of
/// `IndependentCourt` (x lateral from the centre service line, y from the outer edge of the near baseline,
/// z up). Sidelines and service lines are 5 cm wide; the baseline width is a parameter (default 10 cm).
/// Same values and expressions as `court_lines(wb)` in `scripts/speed-fullvideo/camera.py`.
public enum IndependentCourtLine: String, Codable, Sendable, CaseIterable {
    case nearBaseline = "near_baseline", leftSingles = "left_singles", rightSingles = "right_singles"
    case leftDoubles = "left_doubles", rightDoubles = "right_doubles", nearService = "near_service"
    case centerService = "center_service", farService = "far_service", farBaseline = "far_baseline"

    /// Lines the camera is fitted to, in the prototype's order (`FIT_LINES`).
    public static let fitted: [Self] = [.nearBaseline, .leftSingles, .rightSingles, .leftDoubles, .rightDoubles, .nearService, .centerService]
    /// Far lines are checks only: the net band next to them gets mislabelled (`CHECK_LINES`).
    public static let checks: [Self] = [.farService, .farBaseline]
    /// The two transverse lines whose joint presence fixes focal length against distance.
    public var isNearTransverse: Bool { self == .nearBaseline || self == .nearService }
    /// Thin or distant lines get the smaller profile window and peak threshold.
    var isFar: Bool { self == .farService || self == .farBaseline || self == .centerService }

    /// Endpoints (x, y) at z = 0.
    public func endpoints(baselineWidth wb: Double = IndependentCourtModel.baselineWidth) -> (SIMD2<Double>, SIMD2<Double>) {
        let M = IndependentCourtModel.self
        let s = M.singlesHalfWidth - 0.025, d = IndependentCourt.doublesHalfWidth - 0.025
        let yb = wb / 2, yfb = IndependentCourt.length - wb / 2
        let ys = IndependentCourt.netY - M.serviceFromNet + 0.025, yfs = IndependentCourt.netY + M.serviceFromNet - 0.025
        let net = IndependentCourt.netY
        switch self {
        case .nearBaseline: return (SIMD2(-d, yb), SIMD2(d, yb))
        case .leftSingles: return (SIMD2(-s, 0), SIMD2(-s, net))
        case .rightSingles: return (SIMD2(s, 0), SIMD2(s, net))
        case .leftDoubles: return (SIMD2(-d, 0), SIMD2(-d, net))
        case .rightDoubles: return (SIMD2(d, 0), SIMD2(d, net))
        case .nearService: return (SIMD2(-s, ys), SIMD2(s, ys))
        case .centerService: return (SIMD2(0, ys), SIMD2(0, net))
        case .farService: return (SIMD2(-s, yfs), SIMD2(s, yfs))
        case .farBaseline: return (SIMD2(-d, yfb), SIMD2(d, yfb))
        }
    }
}

public enum IndependentCourtModel {
    public static let singlesHalfWidth = 4.115
    /// Net to service line, to the line's outer edge.
    public static let serviceFromNet = 6.40
    /// Net posts stand 0.914 m outside the doubles sidelines.
    public static let netPostOutside = 0.914
    public static let baselineWidth = 0.10

    static let s = singlesHalfWidth - 0.025, d = IndependentCourt.doublesHalfWidth - 0.025
    static let yNearBaseline = baselineWidth / 2, yFarBaseline = IndependentCourt.length - baselineWidth / 2
    static let yNearService = IndependentCourt.netY - serviceFromNet + 0.025
    static let yFarService = IndependentCourt.netY + serviceFromNet - 0.025

    /// Transverse labels (`Y_LABELS`) and longitudinal labels (`X_LABELS`) of the hypothesis search.
    static let yLabels: [(String, Double)] = [("near_baseline", yNearBaseline), ("near_service", yNearService),
                                              ("far_service", yFarService), ("far_baseline", yFarBaseline)]
    static let xLabels: [(String, Double)] = [("left_doubles", -d), ("left_singles", -s), ("center_service", 0.0),
                                              ("right_singles", s), ("right_doubles", d)]

    /// Coverage-scored model lines (`SCORE_LINES`): sidelines split at the net, far parts down-weighted.
    static let scoreLines: [(name: String, a: SIMD2<Double>, b: SIMD2<Double>, weight: Double)] = [
        ("near_baseline", SIMD2(-d, yNearBaseline), SIMD2(d, yNearBaseline), 1.0),
        ("near_service", SIMD2(-s, yNearService), SIMD2(s, yNearService), 1.0),
        ("center_service", SIMD2(0, yNearService), SIMD2(0, yFarService), 0.8),
        ("far_service", SIMD2(-s, yFarService), SIMD2(s, yFarService), 0.5),
        ("far_baseline", SIMD2(-d, yFarBaseline), SIMD2(d, yFarBaseline), 0.5),
        ("left_singles", SIMD2(-s, 0), SIMD2(-s, IndependentCourt.netY), 1.0),
        ("right_singles", SIMD2(s, 0), SIMD2(s, IndependentCourt.netY), 1.0),
        ("left_doubles", SIMD2(-d, 0), SIMD2(-d, IndependentCourt.netY), 1.0),
        ("right_doubles", SIMD2(d, 0), SIMD2(d, IndependentCourt.netY), 1.0),
        ("left_singles_far", SIMD2(-s, IndependentCourt.netY), SIMD2(-s, yFarBaseline), 0.5),
        ("right_singles_far", SIMD2(s, IndependentCourt.netY), SIMD2(s, yFarBaseline), 0.5),
        ("left_doubles_far", SIMD2(-d, IndependentCourt.netY), SIMD2(-d, yFarBaseline), 0.5),
        ("right_doubles_far", SIMD2(d, IndependentCourt.netY), SIMD2(d, yFarBaseline), 0.5),
    ]
    static let samplesPerScoreLine = 40
    /// 13 lines x 40 points, flattened line by line (`SCORE_PTS`).
    static let scorePoints: [SIMD2<Double>] = {
        let ts = NumPy.linspace(0.02, 0.98, samplesPerScoreLine)
        return scoreLines.flatMap { l in ts.map { t in SIMD2(l.a.x + (l.b.x - l.a.x) * t, l.a.y + (l.b.y - l.a.y) * t) } }
    }()

    /// The 12 reference points of the parity check (`court_evaluate.POINTS`): 4 doubles corners,
    /// 4 singles corners, 2 T points, 2 net-post bases.
    public static let referencePoints: [(name: String, point: SIMD3<Double>)] = [
        ("D_near_L", SIMD3(-d, yNearBaseline, 0)), ("D_near_R", SIMD3(d, yNearBaseline, 0)),
        ("D_far_L", SIMD3(-d, yFarBaseline, 0)), ("D_far_R", SIMD3(d, yFarBaseline, 0)),
        ("S_near_L", SIMD3(-s, yNearBaseline, 0)), ("S_near_R", SIMD3(s, yNearBaseline, 0)),
        ("S_far_L", SIMD3(-s, yFarBaseline, 0)), ("S_far_R", SIMD3(s, yFarBaseline, 0)),
        ("T_near", SIMD3(0, yNearService, 0)), ("T_far", SIMD3(0, yFarService, 0)),
        ("post_L", SIMD3(-(IndependentCourt.doublesHalfWidth + netPostOutside), IndependentCourt.netY, 0)),
        ("post_R", SIMD3(IndependentCourt.doublesHalfWidth + netPostOutside, IndependentCourt.netY, 0)),
    ]
}

/// Small NumPy-equivalent helpers. The calibration ranks hypotheses by scores that tie often, so the
/// order NumPy's default (unstable) argsort gives equal keys is reproduced rather than approximated.
enum NumPy {
    /// `np.linspace(a, b, n)`: i * step + a, last element exactly b.
    static func linspace(_ a: Double, _ b: Double, _ n: Int) -> [Double] {
        guard n > 1 else { return n == 1 ? [a] : [] }
        let step = (b - a) / Double(n - 1)
        var y = (0..<n).map { Double($0) * step + a }
        y[n - 1] = b
        return y
    }

    /// `np.arange(start, stop, step)` for a positive step.
    static func arange(_ start: Double, _ stop: Double, _ step: Double) -> [Double] {
        let len = ((stop - start) / step).rounded(.up)
        guard len.isFinite, len > 0 else { return [] }
        return (0..<Int(len)).map { start + Double($0) * step }
    }

    /// `np.argsort(v)` (default kind): NumPy's introsort, median-of-3 quicksort with insertion sort below
    /// 16 elements and heapsort past the depth limit (`npysort/quicksort.cpp`, `heapsort.cpp`).
    /// Checked against NumPy 2.5 on arm64 with tie-heavy keys.
    static func argsort(_ v: [Double]) -> [Int] {
        let num = v.count
        var a = Array(0..<num)
        guard num > 1 else { return a }
        @inline(__always) func less(_ x: Double, _ y: Double) -> Bool { x < y || (y != y && x == x) }
        var stack = [(Int, Int, Int)]()
        var pl = 0, pr = num - 1
        var cdepth = 2 * (Int.bitWidth - 1 - num.leadingZeroBitCount)
        while true {
            if cdepth < 0 {
                heapsort(&a, pl, pr - pl + 1, v, less)
            } else {
                while pr - pl > 15 {
                    let pm = pl + ((pr - pl) >> 1)
                    if less(v[a[pm]], v[a[pl]]) { a.swapAt(pm, pl) }
                    if less(v[a[pr]], v[a[pm]]) { a.swapAt(pr, pm) }
                    if less(v[a[pm]], v[a[pl]]) { a.swapAt(pm, pl) }
                    let vp = v[a[pm]]
                    var pi = pl, pj = pr - 1
                    a.swapAt(pm, pj)
                    while true {
                        repeat { pi += 1 } while less(v[a[pi]], vp)
                        repeat { pj -= 1 } while less(vp, v[a[pj]])
                        if pi >= pj { break }
                        a.swapAt(pi, pj)
                    }
                    a.swapAt(pi, pr - 1)
                    cdepth -= 1
                    if pi - pl < pr - pi { stack.append((pi + 1, pr, cdepth)); pr = pi - 1 }
                    else { stack.append((pl, pi - 1, cdepth)); pl = pi + 1 }
                }
                if pr > pl {
                    for pi in (pl + 1)...pr {
                        let vi = a[pi], vv = v[vi]
                        var pj = pi
                        while pj > pl && less(vv, v[a[pj - 1]]) { a[pj] = a[pj - 1]; pj -= 1 }
                        a[pj] = vi
                    }
                }
            }
            guard let top = stack.popLast() else { break }
            (pl, pr, cdepth) = top
        }
        return a
    }

    private static func heapsort(_ a: inout [Int], _ start: Int, _ count: Int, _ v: [Double], _ less: (Double, Double) -> Bool) {
        // 1-based heap over a[start ..< start + count]
        @inline(__always) func at(_ k: Int) -> Int { start + k - 1 }
        var n = count
        var l = n >> 1
        while l > 0 {
            let tmp = a[at(l)]
            var i = l, j = l << 1
            while j <= n {
                if j < n && less(v[a[at(j)]], v[a[at(j + 1)]]) { j += 1 }
                if less(v[tmp], v[a[at(j)]]) { a[at(i)] = a[at(j)]; i = j; j += j } else { break }
            }
            a[at(i)] = tmp
            l -= 1
        }
        while n > 1 {
            let tmp = a[at(n)]
            a[at(n)] = a[at(1)]
            n -= 1
            var i = 1, j = 2
            while j <= n {
                if j < n && less(v[a[at(j)]], v[a[at(j + 1)]]) { j += 1 }
                if less(v[tmp], v[a[at(j)]]) { a[at(i)] = a[at(j)]; i = j; j += j } else { break }
            }
            a[at(i)] = tmp
        }
    }

    /// Stable order by key (Python's `sorted`/`list.sort`).
    static func stableOrder(_ keys: [Double]) -> [Int] {
        keys.indices.sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }
    }

    /// NumPy's pairwise summation (`pairwise_sum_DOUBLE`), as used by `.sum()` along a contiguous axis.
    static func pairwiseSum(_ a: ArraySlice<Double>) -> Double {
        let n = a.count, b = a.startIndex
        if n < 8 {
            var res = 0.0
            for i in 0..<n { res += a[b + i] }
            return res
        } else if n <= 128 {
            var r = (0..<8).map { a[b + $0] }
            var i = 8
            while i < n - (n % 8) {
                for j in 0..<8 { r[j] += a[b + i + j] }
                i += 8
            }
            var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
            while i < n { res += a[b + i]; i += 1 }
            return res
        } else {
            var n2 = n / 2
            n2 -= n2 % 8
            return pairwiseSum(a[b..<(b + n2)]) + pairwiseSum(a[(b + n2)..<(b + n)])
        }
    }

    static func pairwiseSum(_ a: ArraySlice<Float>) -> Float {
        let n = a.count, b = a.startIndex
        if n < 8 {
            var res: Float = 0
            for i in 0..<n { res += a[b + i] }
            return res
        } else if n <= 128 {
            var r = (0..<8).map { a[b + $0] }
            var i = 8
            while i < n - (n % 8) {
                for j in 0..<8 { r[j] += a[b + i + j] }
                i += 8
            }
            var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
            while i < n { res += a[b + i]; i += 1 }
            return res
        } else {
            var n2 = n / 2
            n2 -= n2 % 8
            return pairwiseSum(a[b..<(b + n2)]) + pairwiseSum(a[(b + n2)..<(b + n)])
        }
    }

    /// NumPy's float remainder (sign of the divisor).
    static func remainder(_ a: Double, _ b: Double) -> Double {
        var m = fmod(a, b)
        if m != 0 && ((b < 0) != (m < 0)) { m += b }
        return m
    }

    /// `np.median` of a non-empty array.
    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
