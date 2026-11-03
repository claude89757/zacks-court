import Foundation

struct TennisSurfacePoint { let x: Double, y: Double }

/// Image → court-surface homography (metres, doubles court origin at the near-left corner).
struct TennisCourtMapping {
    let coefficients: [Double]
    let hull: [NormalizedPoint]
    let state: TennisCourtCalibrationState
    func project(_ p: NormalizedPoint) -> TennisSurfacePoint? {
        guard p.x.isFinite, p.y.isFinite, (0...1).contains(p.x), (0...1).contains(p.y), hull.count >= 3 else { return nil }
        let crosses = hull.indices.map { i in let a = hull[i], b = hull[(i + 1) % hull.count]; return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) }
        guard crosses.allSatisfy({ $0 >= -1e-10 }) || crosses.allSatisfy({ $0 <= 1e-10 }) else { return nil }
        return Self.project(p, coefficients)
    }
    static func project(_ p: NormalizedPoint, _ h: [Double]) -> TennisSurfacePoint? {
        let denominator = h[6] * p.x + h[7] * p.y + 1
        guard denominator.isFinite, abs(denominator) > 1e-10 else { return nil }
        let x = (h[0] * p.x + h[1] * p.y + h[2]) / denominator, y = (h[3] * p.x + h[4] * p.y + h[5]) / denominator
        return x.isFinite && y.isFinite ? .init(x: x, y: y) : nil
    }
    static func solve(image: [NormalizedPoint], world: [TennisSurfacePoint]) -> [Double]? {
        guard image.count == 4, world.count == 4 else { return nil }
        var matrix: [[Double]] = []
        for (p,q) in zip(image, world) {
            matrix.append([p.x,p.y,1,0,0,0,-q.x*p.x,-q.x*p.y,q.x])
            matrix.append([0,0,0,p.x,p.y,1,-q.y*p.x,-q.y*p.y,q.y])
        }
        for c in 0..<8 {
            let pivot = (c..<8).max { abs(matrix[$0][c]) < abs(matrix[$1][c]) }!
            guard abs(matrix[pivot][c]) > 1e-10 else { return nil }
            if pivot != c { matrix.swapAt(pivot, c) }
            let divisor = matrix[c][c]; for j in c...8 { matrix[c][j] /= divisor }
            for row in 0..<8 where row != c {
                let factor = matrix[row][c]; for j in c...8 { matrix[row][j] -= factor * matrix[c][j] }
            }
        }
        let h = (0..<8).map { matrix[$0][8] }; return h.allSatisfy(\.isFinite) ? h : nil
    }
    static func convexHull(_ points: [NormalizedPoint]) -> [NormalizedPoint] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        func half(_ input: [NormalizedPoint]) -> [NormalizedPoint] {
            var out: [NormalizedPoint] = []
            for p in input {
                while out.count >= 2 {
                    let a = out[out.count - 2], b = out[out.count - 1]
                    if (b.x-a.x)*(p.y-b.y)-(b.y-a.y)*(p.x-b.x) > 1e-12 { break }; out.removeLast()
                }; out.append(p)
            }; return out
        }
        return Array(half(sorted).dropLast()) + Array(half(sorted.reversed()).dropLast())
    }
    static func polygonArea(_ p: [NormalizedPoint]) -> Double {
        abs(p.indices.reduce(0.0) { s,i in let a = p[i],b = p[(i+1)%p.count]; return s + a.x*b.y - b.x*a.y }) / 2
    }
}
