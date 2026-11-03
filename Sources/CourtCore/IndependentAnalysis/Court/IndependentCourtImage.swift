import Accelerate
import CoreVideo
import Foundation

/// Owned 8-bit colour image in three planes (blue, green, red), the input of the court calibration.
/// Values are the encoded camera bytes; no colour management is applied.
public struct IndependentCourtImage: Sendable, Equatable {
    public enum ImageError: Error, Equatable { case invalidDimensions, invalidRowBytes, unsupportedPixelFormat, mismatchedFrames }

    public let width: Int, height: Int
    public internal(set) var blue: [UInt8], green: [UInt8], red: [UInt8]

    public init(width: Int, height: Int, blue: [UInt8], green: [UInt8], red: [UInt8]) throws {
        guard width > 0, height > 0, blue.count == width * height, green.count == blue.count, red.count == blue.count else {
            throw ImageError.invalidDimensions
        }
        self.width = width; self.height = height; self.blue = blue; self.green = green; self.red = red
    }

    /// Interleaved 4-byte pixels. `order` names the byte positions of blue, green and red
    /// (BGRA: (0, 1, 2); RGBA: (2, 1, 0); ARGB: (3, 2, 1)).
    public init(fourChannel bytes: UnsafeRawBufferPointer, width: Int, height: Int, rowBytes: Int,
                order: (blue: Int, green: Int, red: Int) = (0, 1, 2)) throws {
        guard width > 0, height > 0 else { throw ImageError.invalidDimensions }
        guard rowBytes >= width * 4, bytes.count >= rowBytes * (height - 1) + width * 4, let base = bytes.baseAddress else {
            throw ImageError.invalidRowBytes
        }
        var c0 = [UInt8](repeating: 0, count: width * height), c1 = c0, c2 = c0, c3 = c0
        c0.withUnsafeMutableBytes { p0 in c1.withUnsafeMutableBytes { p1 in
            c2.withUnsafeMutableBytes { p2 in c3.withUnsafeMutableBytes { p3 in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: rowBytes)
                func buf(_ p: UnsafeMutableRawBufferPointer) -> vImage_Buffer {
                    vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                }
                var d0 = buf(p0), d1 = buf(p1), d2 = buf(p2), d3 = buf(p3)
                _ = vImageConvert_ARGB8888toPlanar8(&src, &d0, &d1, &d2, &d3, vImage_Flags(kvImageNoFlags))
            } }
        } }
        let planes = [c0, c1, c2, c3]
        try self.init(width: width, height: height, blue: planes[order.blue], green: planes[order.green], red: planes[order.red])
    }

    /// Interleaved 3-byte pixels in R, G, B order.
    public init(rgb bytes: UnsafeRawBufferPointer, width: Int, height: Int, rowBytes: Int) throws {
        guard width > 0, height > 0 else { throw ImageError.invalidDimensions }
        guard rowBytes >= width * 3, bytes.count >= rowBytes * (height - 1) + width * 3 else { throw ImageError.invalidRowBytes }
        var r = [UInt8](repeating: 0, count: width * height), g = r, b = r
        for y in 0..<height {
            let row = y * rowBytes
            for x in 0..<width {
                let o = row + 3 * x, k = y * width + x
                r[k] = bytes[o]; g[k] = bytes[o + 1]; b[k] = bytes[o + 2]
            }
        }
        try self.init(width: width, height: height, blue: b, green: g, red: r)
    }

    /// A 32BGRA pixel buffer (the camera and `AVAssetReader` output format). The buffer is copied.
    public init(pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { throw ImageError.unsupportedPixelFormat }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw ImageError.invalidRowBytes }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer), rb = CVPixelBufferGetBytesPerRow(pixelBuffer)
        try self.init(fourChannel: UnsafeRawBufferPointer(start: base, count: rb * h), width: w, height: h, rowBytes: rb)
    }

    /// Per-pixel min(B, G, R).
    public var minimumPlane: [UInt8] { Self.minimum(blue, green, red) }

    static func minimum(_ a: [UInt8], _ b: [UInt8], _ c: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: a.count)
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in c.withUnsafeBufferPointer { pc in
            out.withUnsafeMutableBufferPointer { po in
                for i in 0..<po.count { po[i] = Swift.min(pa[i], Swift.min(pb[i], pc[i])) }
            }
        } } }
        return out
    }
}

/// Clean court image: per-pixel, per-channel median of a few frames spread over a time window, so moving
/// players drop out (`court_frames.median_frame`, which takes up to 25 key frames over 20 s).
///
/// Like the prototype this medians blue, green and red separately; the calibration then takes
/// min(B, G, R) of the median. A median of the min plane alone would use a third of the memory but is a
/// different image (min and median do not commute), so it is not offered. For an even count the two
/// middle values are averaged and truncated, as `np.median(...).astype(np.uint8)` does.
/// Memory: every frame is held as three full planes (6.2 MB per 1920x1080 frame), so the caller bounds N.
public enum IndependentCourtMedian {
    public static func median(of frames: [IndependentCourtImage]) throws -> IndependentCourtImage {
        guard let first = frames.first else { throw IndependentCourtImage.ImageError.invalidDimensions }
        guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw IndependentCourtImage.ImageError.mismatchedFrames
        }
        if frames.count == 1 { return first }
        return try IndependentCourtImage(width: first.width, height: first.height,
                                         blue: median(frames.map(\.blue)), green: median(frames.map(\.green)), red: median(frames.map(\.red)))
    }

    /// Median of N equally sized planes: a Batcher odd-even merge network over 16 pixels at a time,
    /// padded to a power of two with 255 so the padding sorts above every real value.
    static func median(_ planes: [[UInt8]]) -> [UInt8] {
        let n = planes.count, count = planes[0].count
        var p = 1
        while p < n { p <<= 1 }
        let network = comparators(p)
        let lo = (n - 1) / 2, hi = n / 2   // equal for odd n
        var out = [UInt8](repeating: 0, count: count)
        let lanes = UnsafeMutablePointer<SIMD16<UInt8>>.allocate(capacity: p)
        defer { lanes.deallocate() }
        out.withUnsafeMutableBufferPointer { dst in
            var i = 0
            while i < count {
                let m = Swift.min(16, count - i)
                for k in 0..<n {
                    planes[k].withUnsafeBufferPointer { src in
                        if m == 16 {
                            lanes[k] = UnsafeRawPointer(src.baseAddress! + i).loadUnaligned(as: SIMD16<UInt8>.self)
                        } else {
                            var v = SIMD16<UInt8>(repeating: 0)
                            for j in 0..<m { v[j] = src[i + j] }
                            lanes[k] = v
                        }
                    }
                }
                for k in n..<p { lanes[k] = SIMD16(repeating: 255) }
                for (a, b) in network {
                    let x = lanes[a], y = lanes[b]
                    lanes[a] = pointwiseMin(x, y); lanes[b] = pointwiseMax(x, y)
                }
                let v: SIMD16<UInt8>
                if lo == hi { v = lanes[lo] } else {
                    let a = lanes[lo], b = lanes[hi]
                    v = (a &>> 1) &+ (b &>> 1) &+ (a & b & 1)   // floor((a + b) / 2) without overflow
                }
                if m == 16 { UnsafeMutableRawPointer(dst.baseAddress! + i).storeBytes(of: v, as: SIMD16<UInt8>.self) }
                else { for j in 0..<m { dst[i + j] = v[j] } }
                i += 16
            }
        }
        return out
    }

    /// Batcher's odd-even merge sort for a power-of-two size.
    static func comparators(_ n: Int) -> [(Int, Int)] {
        var out = [(Int, Int)]()
        var p = 1
        while p < n {
            var k = p
            while k >= 1 {
                var j = k % p
                while j <= n - 1 - k {
                    for i in 0..<Swift.min(k, n - j - k) where (i + j) / (2 * p) == (i + j + k) / (2 * p) {
                        out.append((i + j, i + j + k))
                    }
                    j += 2 * k
                }
                k /= 2
            }
            p *= 2
        }
        return out
    }
}
