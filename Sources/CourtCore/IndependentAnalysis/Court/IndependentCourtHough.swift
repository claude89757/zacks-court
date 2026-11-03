import Foundation

/// Line segments by the progressive probabilistic Hough transform (Matas, Galambos and Kittler 2000),
/// written to give the same segments, in the same order, as the call the prototype makes,
/// `cv2.HoughLinesP(binary, 1, pi/360, 25, minLineLength=25, maxLineGap=4)` in OpenCV 5.0
/// (`modules/imgproc/src/hough.cpp`, `HoughLinesProbabilistic`, Apache-2.0; see `Notices/OpenCV.txt`):
/// - points are visited in the order of OpenCV's fixed-seed multiply-with-carry generator
///   (`cv::RNG`, state 2^64 - 1, multiplier 4164903690), each removed from the pool when drawn;
/// - every visited point votes into a (360 angle x 3001 distance) accumulator with Float trigonometry
///   and round-half-even; a point whose best bin reaches the threshold starts a walk;
/// - the walk follows the winning angle in 16.16 fixed point in both directions until more than
///   `maxGap` consecutive empty pixels, clears the visited pixels, and removes their votes when the
///   segment is long enough.
/// The vote sum `x*cos + y*sin` is formed as one fused multiply-add, which matched OpenCV's arm64 build
/// on the cached medians (see `docs/verification.md`).
enum IndependentCourtHough {
    struct Segment: Equatable { var x0: Int, y0: Int, x1: Int, y1: Int }

    static func segments(_ image: [UInt8], width: Int, height: Int, threshold: Int = 25, minLength: Int = 25,
                         maxGap: Int = 4, fusedVotes: Bool = true) -> [Segment] {
        let theta = Float(Double.pi / 360)
        let numAngle = angleCount(theta: Double(theta))
        let numRho = Int((Double((width + height) * 2 + 1) / 1.0).rounded(.toNearestOrEven))
        let rhoOffset = (numRho - 1) / 2
        var trig = [Float](repeating: 0, count: numAngle * 2)
        for n in 0..<numAngle {
            trig[2 * n] = Float(cos(Double(n) * Double(theta)) * 1.0)
            trig[2 * n + 1] = Float(sin(Double(n) * Double(theta)) * 1.0)
        }
        var accum = [Int32](repeating: 0, count: numAngle * numRho)
        var mask = [UInt8](repeating: 0, count: width * height)
        var points = [(x: Int, y: Int)]()
        for y in 0..<height {
            for x in 0..<width where image[y * width + x] != 0 {
                mask[y * width + x] = 1
                points.append((x, y))
            }
        }
        @inline(__always) func rho(_ j: Int, _ i: Int, _ n: Int) -> Int {
            let v: Float = fusedVotes ? (Float(i) * trig[2 * n + 1]).addingProduct(Float(j), trig[2 * n])
                                      : Float(j) * trig[2 * n] + Float(i) * trig[2 * n + 1]
            return Int(v.rounded(.toNearestOrEven)) + rhoOffset
        }
        var rng = MultiplyWithCarry()
        var lines = [Segment]()
        let shift = 16
        var count = points.count
        while count > 0 {
            defer { count -= 1 }
            let idx = Int(rng.next() % UInt32(count))
            let point = points[idx]
            points[idx] = points[count - 1]
            let i = point.y, j = point.x
            if mask[i * width + j] == 0 { continue }
            var maxVal = threshold - 1, maxN = 0
            accum.withUnsafeMutableBufferPointer { acc in
                for n in 0..<numAngle {
                    let k = n * numRho + rho(j, i, n)
                    acc[k] += 1
                    let val = Int(acc[k])
                    if maxVal < val { maxVal = val; maxN = n }
                }
            }
            if maxVal < threshold { continue }
            let a = -trig[2 * maxN + 1], b = trig[2 * maxN]
            var x0 = j, y0 = i, dx0: Int, dy0: Int
            let xflag: Bool
            if abs(a) > abs(b) {
                xflag = true
                dx0 = a > 0 ? 1 : -1
                dy0 = Int((b * Float(1 << shift) / abs(a)).rounded(.toNearestOrEven))
                y0 = (y0 << shift) + (1 << (shift - 1))
            } else {
                xflag = false
                dy0 = b > 0 ? 1 : -1
                dx0 = Int((a * Float(1 << shift) / abs(b)).rounded(.toNearestOrEven))
                x0 = (x0 << shift) + (1 << (shift - 1))
            }
            var ends = [(x: j, y: i), (x: j, y: i)]
            for k in 0..<2 {
                var gap = 0, x = x0, y = y0
                let dx = k > 0 ? -dx0 : dx0, dy = k > 0 ? -dy0 : dy0
                while true {
                    let i1 = xflag ? y >> shift : y, j1 = xflag ? x : x >> shift
                    if j1 < 0 || j1 >= width || i1 < 0 || i1 >= height { break }
                    if mask[i1 * width + j1] != 0 { gap = 0; ends[k] = (j1, i1) }
                    else { gap += 1; if gap > maxGap { break } }
                    x += dx; y += dy
                }
            }
            let good = abs(ends[1].x - ends[0].x) >= minLength || abs(ends[1].y - ends[0].y) >= minLength
            for k in 0..<2 {
                var x = x0, y = y0
                let dx = k > 0 ? -dx0 : dx0, dy = k > 0 ? -dy0 : dy0
                while true {
                    let i1 = xflag ? y >> shift : y, j1 = xflag ? x : x >> shift
                    if mask[i1 * width + j1] != 0 {
                        if good {
                            accum.withUnsafeMutableBufferPointer { acc in
                                for n in 0..<numAngle { acc[n * numRho + rho(j1, i1, n)] -= 1 }
                            }
                        }
                        mask[i1 * width + j1] = 0
                    }
                    if i1 == ends[k].y && j1 == ends[k].x { break }
                    x += dx; y += dy
                }
            }
            if good { lines.append(Segment(x0: ends[0].x, y0: ends[0].y, x1: ends[1].x, y1: ends[1].y)) }
        }
        return lines
    }

    /// `computeNumangle(0, pi, theta)`.
    static func angleCount(theta: Double) -> Int {
        var n = Int((Double.pi / theta).rounded(.down)) + 1
        if n > 1 && abs(Double.pi - Double(n - 1) * theta) < theta / 2 { n -= 1 }
        return n
    }

    /// `cv::RNG`: multiply-with-carry, `uniform(0, n)` is `next() % n`.
    struct MultiplyWithCarry {
        var state: UInt64 = .max
        mutating func next() -> UInt32 {
            state = UInt64(UInt32(truncatingIfNeeded: state)) &* 4_164_903_690 &+ (state >> 32)
            return UInt32(truncatingIfNeeded: state)
        }
    }
}
