import Foundation
import CoreML

/// Errors at the independent tracking-model boundary. No result is fabricated on failure.
public struct IndependentBallModelError: Error, LocalizedError, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case unsupportedModelURL, missingModel, compilationFailed, loadingFailed, modelContract
        case inputCount, inputDataType, inputShape, inputStrides, inputNonFinite, inputRange
        case predictionFailed, missingOutput, outputDataType, outputShape, outputStrides, outputNonFinite, outputRange
    }
    public let code: Code
    public let feature: String
    public let detail: String
    public var errorDescription: String? { "\(code.rawValue) [\(feature)]: \(detail)" }
    public init(code: Code, feature: String, detail: String) {
        self.code = code; self.feature = feature; self.detail = detail
    }
}

public struct IndependentBallBoundingBox: Codable, Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
}

/// An unreviewed threshold candidate in the 512×288 heatmap, never a ball label or a speed.
public struct IndependentBallCandidate: Codable, Equatable, Sendable {
    public let centerX: Int, centerY: Int
    public let boundingBox: IndependentBallBoundingBox
    public let peakValue: Float
    public let componentPixelCount: Int
    public let thresholdPixelCount: Int
}

/// Owns its copied float values; neither the feature provider nor its tensor is retained.
public struct IndependentBallPrediction: Sendable {
    public let heatmaps: [Float]
    public let candidates: [IndependentBallCandidate?]
}

/// Explicit, synchronous CPU-only boundary for the independent MIT TrackNetV3 base.
/// Call on a dedicated serial analysis queue. It does no decoding, resizing, background
/// estimation, capture-buffer handling, temporal matching or speed estimation.
public final class IndependentBallModel {
    public static let inputShape = [1, 27, 288, 512]
    public static let outputShape = [1, 8, 288, 512]
    public static let inputStrides = [3_981_312, 147_456, 512, 1]
    public static let outputStrides = [1_179_648, 147_456, 512, 1]
    public static let inputCount = 3_981_312
    public static let outputCount = 1_179_648
    public static let frameCount = 8
    public static let width = 512
    public static let height = 288
    public static let candidateThreshold: Float = 0.5

    public let sourceModelURL: URL
    public let compiledModelURL: URL
    public let didCompileModel: Bool
    private let model: MLModel

    /// Accepts a caller-owned local .mlpackage or .mlmodelc, with no asset search or download.
    /// `.cpuOnly` (default) keeps offline runs bit-for-bit with the Python reference; the live chain
    /// passes `.all` with the FP16 package so Core ML can use the Neural Engine.
    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuOnly) throws {
        guard modelURL.isFileURL, ["mlpackage", "mlmodelc"].contains(modelURL.pathExtension.lowercased()) else {
            throw IndependentBallModelError(code: .unsupportedModelURL, feature: "model", detail: "Expected a local .mlpackage or .mlmodelc URL")
        }
        let source = modelURL.standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &directory), directory.boolValue else {
            throw IndependentBallModelError(code: .missingModel, feature: "model", detail: source.path)
        }
        sourceModelURL = source
        didCompileModel = source.pathExtension.lowercased() == "mlpackage"
        if didCompileModel {
            do { compiledModelURL = try MLModel.compileModel(at: source) }
            catch { throw IndependentBallModelError(code: .compilationFailed, feature: "model", detail: String(describing: error)) }
        } else { compiledModelURL = source }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        do { model = try MLModel(contentsOf: compiledModelURL, configuration: configuration) }
        catch { throw IndependentBallModelError(code: .loadingFailed, feature: "model", detail: String(describing: error)) }
        try Self.validateModelDescription(model.modelDescription)
    }

    public func predict(nchw values: [Float]) throws -> IndependentBallPrediction {
        try predict(Self.makeInputTensor(values: values))
    }

    public func predict(_ input: MLMultiArray) throws -> IndependentBallPrediction {
        try Self.validateInput(input)
        let output: MLFeatureProvider
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: ["frames": MLFeatureValue(multiArray: input)])
            output = try model.prediction(from: provider)
        } catch {
            throw IndependentBallModelError(code: .predictionFailed, feature: "heatmaps", detail: String(describing: error))
        }
        guard let heatmaps = output.featureValue(for: "heatmaps")?.multiArrayValue else {
            throw IndependentBallModelError(code: .missingOutput, feature: "heatmaps", detail: "Missing float32 output tensor")
        }
        return try Self.decodeOutput(heatmaps)
    }

    /// Allocates and copies into a new contiguous Core ML buffer. Caller storage is never aliased.
    public static func makeInputTensor(values: [Float]) throws -> MLMultiArray {
        guard values.count == inputCount else {
            throw IndependentBallModelError(code: .inputCount, feature: "frames", detail: "Expected \(inputCount) values, got \(values.count)")
        }
        try values.withUnsafeBufferPointer { try validateValues($0, input: true) }
        let tensor: MLMultiArray
        do { tensor = try MLMultiArray(shape: inputShape.map(NSNumber.init(value:)), dataType: .float32) }
        catch { throw IndependentBallModelError(code: .inputCount, feature: "frames", detail: "Cannot allocate input: \(error)") }
        values.withUnsafeBufferPointer { source in
            tensor.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: source.count)
        }
        return tensor
    }

    public static func validateInput(_ tensor: MLMultiArray) throws {
        try validateTensor(tensor, input: true)
    }

    public static func validateOutput(_ tensor: MLMultiArray) throws {
        try validateTensor(tensor, input: false)
    }

    public static func decodeOutput(_ tensor: MLMultiArray) throws -> IndependentBallPrediction {
        try validateOutput(tensor)
        let buffer = UnsafeBufferPointer(start: tensor.dataPointer.assumingMemoryBound(to: Float.self), count: outputCount)
        let values = Array(buffer)
        return IndependentBallPrediction(heatmaps: values, candidates: candidates(in: values))
    }

    private static func validateModelDescription(_ description: MLModelDescription) throws {
        for (name, shape, features) in [("frames", inputShape, description.inputDescriptionsByName),
                                         ("heatmaps", outputShape, description.outputDescriptionsByName)] {
            guard Set(features.keys) == [name], let feature = features[name], feature.type == .multiArray,
                  let constraint = feature.multiArrayConstraint, constraint.dataType == .float32,
                  constraint.shape.map(\.intValue) == shape else {
                throw IndependentBallModelError(code: .modelContract, feature: name, detail: "Expected exactly one float32 tensor with shape \(shape)")
            }
        }
    }

    private static func validateTensor(_ tensor: MLMultiArray, input: Bool) throws {
        let feature = input ? "frames" : "heatmaps"
        guard tensor.dataType == .float32 else {
            throw IndependentBallModelError(code: input ? .inputDataType : .outputDataType, feature: feature, detail: "Expected float32, got \(tensor.dataType.rawValue)")
        }
        let shape = input ? inputShape : outputShape
        guard tensor.shape.map(\.intValue) == shape else {
            throw IndependentBallModelError(code: input ? .inputShape : .outputShape, feature: feature, detail: "Expected \(shape), got \(tensor.shape)")
        }
        let strides = input ? inputStrides : outputStrides
        guard tensor.strides.map(\.intValue) == strides else {
            throw IndependentBallModelError(code: input ? .inputStrides : .outputStrides, feature: feature, detail: "Expected contiguous NCHW strides \(strides), got \(tensor.strides)")
        }
        let count = input ? inputCount : outputCount
        let buffer = UnsafeBufferPointer(start: tensor.dataPointer.assumingMemoryBound(to: Float.self), count: count)
        try validateValues(buffer, input: input)
    }

    private static func validateValues(_ values: UnsafeBufferPointer<Float>, input: Bool) throws {
        for (index, value) in values.enumerated() {
            guard value.isFinite else {
                throw IndependentBallModelError(code: input ? .inputNonFinite : .outputNonFinite,
                    feature: input ? "frames" : "heatmaps", detail: "Non-finite value at flat index \(index)")
            }
            guard (0...1).contains(value) else {
                throw IndependentBallModelError(code: input ? .inputRange : .outputRange,
                    feature: input ? "frames" : "heatmaps", detail: "Value outside [0,1] at flat index \(index)")
            }
        }
    }

    private static func candidates(in heatmaps: [Float]) -> [IndependentBallCandidate?] {
        let plane = width * height
        return (0..<frameCount).map { frame in
            let offset = frame * plane
            var mask = [UInt8](repeating: 0, count: plane)
            var total = 0
            for i in 0..<plane where heatmaps[offset + i] > candidateThreshold { mask[i] = 1; total += 1 }
            guard total > 0 else { return nil }
            var selected: IndependentBallCandidate?
            var selectedArea = -1
            var queue: [Int] = []
            for start in 0..<plane where mask[start] != 0 {
                queue.removeAll(keepingCapacity: true)
                queue.append(start); mask[start] = 0
                var head = 0, minX = width, minY = height, maxX = -1, maxY = -1
                var peak: Float = 0
                while head < queue.count {
                    let index = queue[head]; head += 1
                    let x = index % width, y = index / width
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    peak = max(peak, heatmaps[offset + index])
                    for ny in max(0, y - 1)...min(height - 1, y + 1) {
                        for nx in max(0, x - 1)...min(width - 1, x + 1) {
                            let neighbor = ny * width + nx
                            if mask[neighbor] != 0 { mask[neighbor] = 0; queue.append(neighbor) }
                        }
                    }
                }
                let box = IndependentBallBoundingBox(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
                let area = box.width * box.height
                // OpenCV RETR_EXTERNAL returns reverse raster discovery order. A later
                // component wins equal bbox areas, matching max(...), first contour tie.
                if area >= selectedArea {
                    let x = Int(Double(box.x) + Double(box.width) / 2)
                    let y = Int(Double(box.y) + Double(box.height) / 2)
                    selected = (x == 0 && y == 0) ? nil : IndependentBallCandidate(centerX: x, centerY: y,
                        boundingBox: box, peakValue: peak, componentPixelCount: queue.count, thresholdPixelCount: total)
                    selectedArea = area
                }
            }
            return selected
        }
    }
}
