import Foundation

// RGB8 resampling is adapted from Pillow 11.3.0 src/libImaging/Resample.c:
// https://github.com/python-pillow/Pillow/blob/11.3.0/src/libImaging/Resample.c
// Half-pixel centers, widened downsample kernel, clipped/renormalized support,
// signed 22-bit coefficient rounding, horizontal then vertical UINT8 passes.
// Pillow/PIL MIT-CMU license (preserved for this adaptation):
// The Python Imaging Library (PIL) is
// Copyright © 1997-2011 by Secret Labs AB
// Copyright © 1995-2011 by Fredrik Lundh and contributors
// Pillow is the friendly PIL fork. It is
// Copyright © 2010 by Jeffrey A. Clark and contributors
// By obtaining, using, and/or copying this software and/or its associated
// documentation, you agree that you have read, understood, and will comply
// with the following terms and conditions:
// Permission to use, copy, modify and distribute this software and its
// documentation for any purpose and without fee is hereby granted,
// provided that the above copyright notice appears in all copies, and that
// both that copyright notice and this permission notice appear in supporting
// documentation, and that the name of Secret Labs AB or the author not be
// used in advertising or publicity pertaining to distribution of the software
// without specific, written prior permission.
// SECRET LABS AB AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS
// SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
// IN NO EVENT SHALL SECRET LABS AB OR THE AUTHOR BE LIABLE FOR ANY SPECIAL,
// INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
// LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
// OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
// PERFORMANCE OF THIS SOFTWARE.

public enum IndependentBallPreprocessingError: Error, Equatable {
    case unsupportedPixelFormat, unknownCoordinateSpace
    case invalidDimensions, invalidRowBytes, invalidByteCount, invalidROI
    case incorrectFrameCount, mismatchedFrameDimensions
}

/// Owned, interleaved, encoded RGB bytes. No alpha, YUV conversion, color
/// management, orientation correction or camera-buffer ownership is implicit.
public struct IndependentRGB8Buffer: Sendable {
    public enum PixelFormat: Sendable { case rgb8, bgra8, unknown }
    public enum CoordinateSpace: Sendable { case decodedTopLeftUnrotated, unknown }
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bytes: [UInt8]

    public init(width: Int, height: Int, bytesPerRow: Int, bytes: [UInt8],
                pixelFormat: PixelFormat, coordinateSpace: CoordinateSpace) throws {
        guard pixelFormat == .rgb8 else { throw IndependentBallPreprocessingError.unsupportedPixelFormat }
        guard coordinateSpace == .decodedTopLeftUnrotated else { throw IndependentBallPreprocessingError.unknownCoordinateSpace }
        // Bounded owned buffers for this offline module; checked before products.
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw IndependentBallPreprocessingError.invalidDimensions
        }
        guard bytesPerRow >= width * 3, bytesPerRow <= 4096 * 4 else {
            throw IndependentBallPreprocessingError.invalidRowBytes
        }
        guard bytes.count == bytesPerRow * height else { throw IndependentBallPreprocessingError.invalidByteCount }
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow; self.bytes = bytes
    }
}

/// Integer half-open crop in the decoded source image. Fractional/normalized
/// crops must be resolved and recorded by the caller, not silently rounded here.
public struct IndependentBallROI: Sendable, Equatable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Synchronous CPU work for an analysis/offline queue, never a capture callback.
/// The background is explicitly supplied: this class does not compute medians
/// or imply that an offline median containing future frames is causal.
public enum IndependentBallPreprocessor {
    public static let outputWidth = 512
    public static let outputHeight = 288
    public static let frameCount = 8
    public static let tensorShape = [1, 27, 288, 512]

    /// Contiguous Float32 NCHW: background RGB, then frame 0 RGB ... frame 7 RGB.
    /// Values are Float(byte) / Float(255), without mean/std or linear-light conversion.
    public static func makeTensor(background: IndependentRGB8Buffer,
                                  frames: [IndependentRGB8Buffer],
                                  roi: IndependentBallROI? = nil) throws -> [Float] {
        guard frames.count == frameCount else { throw IndependentBallPreprocessingError.incorrectFrameCount }
        guard frames.allSatisfy({ $0.width == background.width && $0.height == background.height }) else {
            throw IndependentBallPreprocessingError.mismatchedFrameDimensions
        }
        let plane = outputWidth * outputHeight
        var values = [Float](repeating: 0, count: 27 * plane)
        for (imageIndex, image) in ([background] + frames).enumerated() {
            let rgb = try resizeRGB8(image, roi: roi, outputWidth: outputWidth, outputHeight: outputHeight)
            for pixel in 0..<plane {
                for channel in 0..<3 {
                    values[(imageIndex * 3 + channel) * plane + pixel] = Float(rgb.bytes[pixel * 3 + channel]) / Float(255)
                }
            }
        }
        return values
    }

    /// Equivalent target: Image.fromarray(RGB8).crop(integerRect).resize(size,
    /// resample=BICUBIC, reducing_gap=None). Comparisons must start from the same
    /// RGB bytes; JPEG decoders/color handling are a separate numerical boundary.
    public static func resizeRGB8(_ image: IndependentRGB8Buffer,
                                  roi: IndependentBallROI? = nil,
                                  outputWidth: Int = 512, outputHeight: Int = 288) throws -> IndependentRGB8Buffer {
        guard (1...4096).contains(outputWidth), (1...4096).contains(outputHeight) else {
            throw IndependentBallPreprocessingError.invalidDimensions
        }
        let crop = roi ?? IndependentBallROI(x: 0, y: 0, width: image.width, height: image.height)
        // Subtractions, not x+width, avoid overflow on adversarial ROI input.
        guard crop.x >= 0, crop.y >= 0, crop.x < image.width, crop.y < image.height,
              crop.width > 0, crop.height > 0,
              crop.width <= image.width - crop.x, crop.height <= image.height - crop.y else {
            throw IndependentBallPreprocessingError.invalidROI
        }
        let horizontal = coefficients(inputSize: crop.width, outputSize: outputWidth)
        let vertical = coefficients(inputSize: crop.height, outputSize: outputHeight)
        // The intermediate must be 8-bit: a single floating two-dimensional
        // convolution is not numerically equivalent to Pillow's two passes.
        var intermediate = [UInt8](repeating: 0, count: outputWidth * crop.height * 3)
        for y in 0..<crop.height {
            for x in 0..<outputWidth {
                let weights = horizontal[x]
                for channel in 0..<3 {
                    var sum: Int64 = 1 << 21
                    for (offset, weight) in weights.values.enumerated() {
                        let index = (crop.y + y) * image.bytesPerRow + (crop.x + weights.start + offset) * 3 + channel
                        sum += Int64(image.bytes[index]) * weight
                    }
                    intermediate[(y * outputWidth + x) * 3 + channel] = clip(sum)
                }
            }
        }
        var output = [UInt8](repeating: 0, count: outputWidth * outputHeight * 3)
        for y in 0..<outputHeight {
            let weights = vertical[y]
            for x in 0..<outputWidth {
                for channel in 0..<3 {
                    var sum: Int64 = 1 << 21
                    for (offset, weight) in weights.values.enumerated() {
                        sum += Int64(intermediate[((weights.start + offset) * outputWidth + x) * 3 + channel]) * weight
                    }
                    output[(y * outputWidth + x) * 3 + channel] = clip(sum)
                }
            }
        }
        return try IndependentRGB8Buffer(width: outputWidth, height: outputHeight, bytesPerRow: outputWidth * 3,
                                         bytes: output, pixelFormat: .rgb8, coordinateSpace: .decodedTopLeftUnrotated)
    }

    private struct Coefficients { let start: Int; let values: [Int64] }

    private static func coefficients(inputSize: Int, outputSize: Int) -> [Coefficients] {
        if inputSize == outputSize {
            return (0..<inputSize).map { Coefficients(start: $0, values: [1 << 22]) }
        }
        let scale = Double(inputSize) / Double(outputSize)
        let filterScale = max(1, scale), support = 2 * filterScale
        let inverseScale = 1 / filterScale
        return (0..<outputSize).map { pixel in
            let center = (Double(pixel) + 0.5) * scale
            // Int(Double) truncates toward zero, matching the C casts (including
            // negative support edges), then support is clipped to the crop.
            let start = max(0, Int(center - support + 0.5))
            let end = min(inputSize, Int(center + support + 0.5))
            let raw = (start..<end).map { cubic((Double($0) - center + 0.5) * inverseScale) }
            let total = raw.reduce(0, +)
            let values = raw.map { weight -> Int64 in
                let normalized = total == 0 ? weight : weight / total
                let scaled = normalized * Double(1 << 22)
                return Int64(scaled + (normalized < 0 ? -0.5 : 0.5))
            }
            return Coefficients(start: start, values: values)
        }
    }

    private static func cubic(_ value: Double) -> Double {
        let x = abs(value)
        if x < 1 { return (1.5 * x - 2.5) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * -0.5 }
        return 0
    }

    private static func clip(_ value: Int64) -> UInt8 {
        UInt8(max(0, min(255, value >> 22)))
    }
}
