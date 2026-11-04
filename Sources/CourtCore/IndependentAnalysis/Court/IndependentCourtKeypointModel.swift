import Accelerate
import CoreML
import Foundation

/// Court keypoint model (trained in this repository on labels the geometric calibrator produced, no
/// human labels and no pretrained weights; `scripts/court-keypoints/`). One 512×288 RGB picture in,
/// 14 heatmaps at 256×144 out. Its keypoints only add start cameras to `IndependentCourtCalibrator`,
/// which still fits the painted lines and applies every refusal check.
public final class IndependentCourtKeypointModel: @unchecked Sendable {
    public static let inputWidth = 512, inputHeight = 288
    public static let outputWidth = 256, outputHeight = 144
    /// A heatmap peak below this means the point is not seen.
    public static let peakThreshold: Float = 0.3

    public enum LoadError: Error { case unsupportedURL, contract(String) }

    private let model: MLModel
    private let lock = NSLock()

    /// A local .mlpackage (compiled on load) or .mlmodelc.
    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let ext = modelURL.pathExtension.lowercased()
        guard modelURL.isFileURL, ext == "mlpackage" || ext == "mlmodelc" else { throw LoadError.unsupportedURL }
        let compiled = ext == "mlpackage" ? try MLModel.compileModel(at: modelURL) : modelURL
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiled, configuration: configuration)
        let d = model.modelDescription
        guard d.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 3, Self.inputHeight, Self.inputWidth],
              d.outputDescriptionsByName["heatmaps"]?.multiArrayConstraint?.shape.map(\.intValue)
                == [1, IndependentCourtKeypoints.names.count, Self.outputHeight, Self.outputWidth] else {
            throw LoadError.contract("expected image [1,3,288,512] and heatmaps [1,14,144,256]")
        }
    }

    /// Keypoints of a 1920×1080 picture in full-resolution pixels; nil when the model fails.
    public func keypoints(_ image: IndependentCourtImage) -> IndependentCourtKeypoints? {
        guard let input = try? Self.input(image) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]),
              let out = try? model.prediction(from: provider), let heatmaps = out.featureValue(for: "heatmaps")?.multiArrayValue else {
            return nil
        }
        return Self.decode(heatmaps, fullWidth: Double(image.width))
    }

    /// RGB planes scaled to 512×288, values 0...1, NCHW float32.
    static func input(_ image: IndependentCourtImage) throws -> MLMultiArray {
        let w = inputWidth, h = inputHeight
        let tensor = try MLMultiArray(shape: [1, 3, NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
        let dst = tensor.dataPointer.assumingMemoryBound(to: Float.self)
        var small = [UInt8](repeating: 0, count: w * h)
        for (c, plane) in [image.red, image.green, image.blue].enumerated() {
            var plane = plane
            plane.withUnsafeMutableBytes { src in
                small.withUnsafeMutableBytes { out in
                    var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(image.height), width: vImagePixelCount(image.width), rowBytes: image.width)
                    var d = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    _ = vImageScale_Planar8(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
                }
            }
            let base = dst + c * w * h
            for i in 0..<(w * h) { base[i] = Float(small[i]) / 255 }
        }
        return tensor
    }

    /// Peak of each heatmap refined by the 3×3 weighted centre (as `decode` in train.py), in full-resolution pixels.
    static func decode(_ heatmaps: MLMultiArray, fullWidth: Double) -> IndependentCourtKeypoints {
        let K = IndependentCourtKeypoints.names.count, H = outputHeight, W = outputWidth
        let strides = heatmaps.strides.map(\.intValue)
        let isHalf = heatmaps.dataType == .float16
        func at(_ k: Int, _ y: Int, _ x: Int) -> Float {
            guard y >= 0, y < H, x >= 0, x < W else { return 0 }
            let i = k * strides[1] + y * strides[2] + x * strides[3]
            return isHalf ? Float(heatmaps.dataPointer.assumingMemoryBound(to: Float16.self)[i])
                          : heatmaps.dataPointer.assumingMemoryBound(to: Float.self)[i]
        }
        let outStride = Double(inputWidth / outputWidth), scale = fullWidth / Double(inputWidth)
        var pixels = [SIMD2<Double>?](repeating: nil, count: K)
        for k in 0..<K {
            var best: Float = -.infinity, by = 0, bx = 0
            for y in 0..<H { for x in 0..<W { let v = at(k, y, x); if v > best { best = v; by = y; bx = x } } }
            guard best >= peakThreshold else { continue }
            var s: Float = 0, sx: Float = 0, sy: Float = 0
            for dy in -1...1 { for dx in -1...1 {
                let v = max(0, at(k, by + dy, bx + dx)); s += v; sx += v * Float(dx); sy += v * Float(dy)
            } }
            let fx = Double(bx) + Double(s > 0 ? sx / s : 0), fy = Double(by) + Double(s > 0 ? sy / s : 0)
            let u = fx * outStride + (outStride - 1) / 2, v = fy * outStride + (outStride - 1) / 2
            pixels[k] = SIMD2(u * scale, v * scale)
        }
        return IndependentCourtKeypoints(pixels: pixels)
    }
}
