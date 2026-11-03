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
    static func manual(corners: [NormalizedPoint]) throws -> TennisCourtMapping {
        guard corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw CourtError.message("手动场地标定需要四个有效归一化角点。")
        }
        let cross = corners.indices.map { i in
            let a = corners[i], b = corners[(i+1)%4], c = corners[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        guard cross.allSatisfy({ $0 < -1e-8 }), polygonArea(corners) >= 0.02,
              corners[0].x < corners[1].x, corners[3].x < corners[2].x,
              corners[0].y + corners[1].y > corners[2].y + corners[3].y else {
            throw CourtError.message("请按近左、近右、远右、远左依次标记双打外侧四角，不能交叉或重合。")
        }
        let world: [TennisSurfacePoint] = [.init(x:0,y:0),.init(x:10.97,y:0),.init(x:10.97,y:23.77),.init(x:0,y:23.77)]
        guard let h = solve(image:corners,world:world) else { throw CourtError.message("四角不能形成有效的球场平面。") }
        return .init(coefficients:h,hull:corners,state:.init(isAvailable:true,landmarkCount:4,validationErrorMeters:nil,reason:"用户四角标定；精度未独立验证，移动机位后需重标"))
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

/// User-marked court corners (doubles outer corners, near-left → near-right → far-right → far-left).
public enum ManualCourtCorners {
    /// Invalid user corners always fail rather than silently reverting to automatic calibration.
    public static func validate(_ corners: [NormalizedPoint]) throws {
        _ = try TennisCourtMapping.manual(corners: corners)
    }
}
