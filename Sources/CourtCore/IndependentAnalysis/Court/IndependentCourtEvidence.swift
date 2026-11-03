import Accelerate
import Foundation

/// White-line evidence of a median frame (`court_auto.evidence` and `lines.tophat`).
///
/// - Search, at half resolution: 2x2 box average of each channel (OpenCV `INTER_AREA` at exactly 2x is
///   `(a+b+c+d+2)>>2`), min(B, G, R), white top-hat with an 11x11 square, threshold at
///   max(10, 0.3 x the 99.5th percentile), and a 5x5 dilation as the coverage mask.
/// - Refinement, at full resolution: min(B, G, R), 21x21 top-hat, 3x3 Gaussian ([1/4, 1/2, 1/4],
///   reflect-101 border) as Float.
/// Erosion and dilation use vImage min/max filters, which ignore out-of-image pixels like OpenCV's default
/// morphology border.
public struct IndependentCourtEvidence: Sendable {
    public let width: Int, height: Int
    public var halfWidth: Int { width / 2 }
    public var halfHeight: Int { height / 2 }
    /// Half-resolution top-hat of min(B, G, R).
    public let halfTopHat: [UInt8]
    /// 0/1: half-resolution top-hat above `threshold`.
    public let binary: [UInt8]
    /// 0/1: `binary` dilated by 5x5 (+-2 px at half resolution, +-4 px at full resolution).
    public let hit: [UInt8]
    public let threshold: Float
    /// Full-resolution, blurred top-hat used for sub-pixel line profiles.
    public let fullTopHat: [Float]

    public init(_ image: IndependentCourtImage) {
        width = image.width; height = image.height
        let hw = width / 2, hh = height / 2
        let small = IndependentCourtImage.minimum(Self.halve(image.blue, width, height), Self.halve(image.green, width, height),
                                                  Self.halve(image.red, width, height))
        halfTopHat = Self.topHat(small, hw, hh, kernel: 11)
        let p = Self.percentile995(halfTopHat)
        let scaled = Float(0.3) * p
        threshold = scaled > 10 ? scaled : 10
        let thr = threshold
        binary = halfTopHat.map { Float($0) > thr ? 1 : 0 }
        hit = Self.morphology(binary, hw, hh, kernel: 5, dilate: true)
        let full = Self.topHat(image.minimumPlane, width, height, kernel: 21)
        fullTopHat = Self.blur3(full, width, height)
    }

    /// 2x2 box average with OpenCV's rounding (`ResizeAreaFastVec`, scale 2): (a + b + c + d + 2) >> 2.
    static func halve(_ src: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        let hw = w / 2, hh = h / 2
        var out = [UInt8](repeating: 0, count: hw * hh)
        src.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { o in
            for y in 0..<hh {
                let r0 = 2 * y * w, r1 = r0 + w, ro = y * hw
                for x in 0..<hw {
                    let a = Int(s[r0 + 2 * x]) + Int(s[r0 + 2 * x + 1]) + Int(s[r1 + 2 * x]) + Int(s[r1 + 2 * x + 1])
                    o[ro + x] = UInt8((a + 2) >> 2)
                }
            }
        } }
        return out
    }

    static func morphology(_ src: [UInt8], _ w: Int, _ h: Int, kernel k: Int, dilate: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { o in
            var sb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress!), height: vImagePixelCount(h),
                                   width: vImagePixelCount(w), rowBytes: w)
            var ob = vImage_Buffer(data: o.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            let kk = vImagePixelCount(k)
            let err = dilate ? vImageMax_Planar8(&sb, &ob, nil, 0, 0, kk, kk, vImage_Flags(kvImageNoFlags))
                             : vImageMin_Planar8(&sb, &ob, nil, 0, 0, kk, kk, vImage_Flags(kvImageNoFlags))
            precondition(err == kvImageNoError, "vImage morphology failed: \(err)")
        } }
        return out
    }

    /// White top-hat: src - dilate(erode(src)) with a k x k square.
    static func topHat(_ src: [UInt8], _ w: Int, _ h: Int, kernel k: Int) -> [UInt8] {
        let opened = morphology(morphology(src, w, h, kernel: k, dilate: false), w, h, kernel: k, dilate: true)
        var out = src
        for i in out.indices { out[i] = src[i] &- opened[i] }   // opened <= src
        return out
    }

    /// `np.percentile(x, 99.5)` (linear interpolation) of uint8 values held as float32, via a histogram.
    static func percentile995(_ v: [UInt8]) -> Float {
        var hist = [Int](repeating: 0, count: 256)
        for x in v { hist[Int(x)] += 1 }
        let index = 0.995 * Double(v.count - 1)
        let below = Int(index.rounded(.down))
        func value(at rank: Int) -> Float {
            var c = 0
            for (k, n) in hist.enumerated() { c += n; if c > rank { return Float(k) } }
            return 255
        }
        let a = value(at: below), b = value(at: Swift.min(below + 1, v.count - 1))
        let gamma = Float(index - Double(below))
        let diff = b - a
        return gamma >= 0.5 ? b - diff * (1 - gamma) : a + diff * gamma
    }

    /// `cv2.GaussianBlur(src.astype(float32), (3, 3), 0)`: separable [1/4, 1/2, 1/4], reflect-101 border.
    /// Every intermediate is a multiple of 1/16 below 256, so the result is exact in Float.
    static func blur3(_ src: [UInt8], _ w: Int, _ h: Int) -> [Float] {
        var rows = [Float](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { s in rows.withUnsafeMutableBufferPointer { r in
            for y in 0..<h {
                let o = y * w
                for x in 0..<w {
                    let xl = x == 0 ? (w > 1 ? 1 : 0) : x - 1, xr = x == w - 1 ? (w > 1 ? w - 2 : 0) : x + 1
                    r[o + x] = 0.25 * Float(s[o + xl]) + 0.5 * Float(s[o + x]) + 0.25 * Float(s[o + xr])
                }
            }
        } }
        var out = [Float](repeating: 0, count: w * h)
        rows.withUnsafeBufferPointer { r in out.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                let yu = y == 0 ? (h > 1 ? 1 : 0) : y - 1, yd = y == h - 1 ? (h > 1 ? h - 2 : 0) : y + 1
                let a = yu * w, b = y * w, c = yd * w
                for x in 0..<w { o[b + x] = 0.25 * r[a + x] + 0.5 * r[b + x] + 0.25 * r[c + x] }
            }
        } }
        return out
    }
}
