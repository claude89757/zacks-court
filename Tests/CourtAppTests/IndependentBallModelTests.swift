#if os(macOS)
import XCTest
import Foundation
import CoreML
import CryptoKit
@testable import CourtCore

final class IndependentBallModelTests: XCTestCase {
    private func expectCode(_ code: IndependentBallModelError.Code, _ operation: () throws -> Void,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? IndependentBallModelError)?.code, code, file: file, line: line)
        }
    }

    private func zeros(_ shape: [Int], type: MLMultiArrayDataType = .float32) throws -> MLMultiArray {
        let tensor = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: type)
        if type == .float32 { tensor.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: tensor.count) }
        return tensor
    }

    func testInputBuilderCopiesAndPreservesBounds() throws {
        var values = [Float](repeating: 0, count: IndependentBallModel.inputCount)
        values[values.count - 1] = 1
        let tensor = try IndependentBallModel.makeInputTensor(values: values)
        values[0] = 0.75
        XCTAssertEqual(tensor.dataPointer.assumingMemoryBound(to: Float.self)[0], 0)
        XCTAssertEqual(tensor.dataPointer.assumingMemoryBound(to: Float.self)[tensor.count - 1], 1)
        XCTAssertEqual(tensor.strides.map(\.intValue), IndependentBallModel.inputStrides)
        try IndependentBallModel.validateInput(tensor)
    }

    func testInputRejectsCountDataTypeShapeAndStrides() throws {
        expectCode(.inputCount) { _ = try IndependentBallModel.makeInputTensor(values: []) }
        let wrongType = try zeros([1], type: .double)
        expectCode(.inputDataType) { try IndependentBallModel.validateInput(wrongType) }
        let wrongShape = try zeros([1])
        expectCode(.inputShape) { try IndependentBallModel.validateInput(wrongShape) }
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: IndependentBallModel.inputCount + 512)
        let padded = try MLMultiArray(dataPointer: pointer, shape: IndependentBallModel.inputShape.map(NSNumber.init(value:)),
            dataType: .float32, strides: [3_981_600, 147_456, 513, 1].map(NSNumber.init(value:)),
            deallocator: { $0.assumingMemoryBound(to: Float.self).deallocate() })
        expectCode(.inputStrides) { try IndependentBallModel.validateInput(padded) }
    }

    func testInputRejectsNonFiniteAndOutOfRange() throws {
        let tensor = try zeros(IndependentBallModel.inputShape)
        let p = tensor.dataPointer.assumingMemoryBound(to: Float.self)
        p[0] = .nan
        expectCode(.inputNonFinite) { try IndependentBallModel.validateInput(tensor) }
        p[0] = .infinity
        expectCode(.inputNonFinite) { try IndependentBallModel.validateInput(tensor) }
        p[0] = -0.0001
        expectCode(.inputRange) { try IndependentBallModel.validateInput(tensor) }
        p[0] = 1.0001
        expectCode(.inputRange) { try IndependentBallModel.validateInput(tensor) }
        p[0] = 0
        p[tensor.count - 1] = .nan
        expectCode(.inputNonFinite) { try IndependentBallModel.validateInput(tensor) }
    }

    func testOutputRejectsWrongContractAndNonFinite() throws {
        let wrongType = try zeros([1], type: .double)
        expectCode(.outputDataType) { try IndependentBallModel.validateOutput(wrongType) }
        let wrongShape = try zeros([8, 288, 512])
        expectCode(.outputShape) { try IndependentBallModel.validateOutput(wrongShape) }
        let tensor = try zeros(IndependentBallModel.outputShape)
        tensor.dataPointer.assumingMemoryBound(to: Float.self)[tensor.count - 1] = .infinity
        expectCode(.outputNonFinite) { _ = try IndependentBallModel.decodeOutput(tensor) }
        tensor.dataPointer.assumingMemoryBound(to: Float.self)[tensor.count - 1] = 1.01
        expectCode(.outputRange) { _ = try IndependentBallModel.decodeOutput(tensor) }
    }

    func testOutputCopiesAndStrictThresholdKeepsNoCandidateNil() throws {
        let tensor = try zeros(IndependentBallModel.outputShape)
        tensor.dataPointer.assumingMemoryBound(to: Float.self)[20 * 512 + 30] = 0.5
        let output = try IndependentBallModel.decodeOutput(tensor)
        XCTAssertEqual(output.heatmaps.count, IndependentBallModel.outputCount)
        XCTAssertEqual(output.candidates.count, 8)
        XCTAssertTrue(output.candidates.allSatisfy { $0 == nil })
        tensor.dataPointer.assumingMemoryBound(to: Float.self)[20 * 512 + 30] = 0.75
        XCTAssertEqual(output.heatmaps[20 * 512 + 30], 0.5)
    }

    func testLargestBoundingBoxConnectivityAndAuthorTieOrder() throws {
        let tensor = try zeros(IndependentBallModel.outputShape)
        let p = tensor.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = 288 * 512
        for y in 20..<23 { for x in 30..<34 { p[y * 512 + x] = 0.6 } }
        p[100 * 512 + 100] = 0.99
        p[plane + 20 * 512 + 10] = 0.8
        p[plane + 100 * 512 + 100] = 0.8
        p[2 * plane + 20 * 512 + 20] = 0.8
        p[2 * plane + 21 * 512 + 21] = 0.8
        p[3 * plane] = 1 // Author uses (0,0) as a no-output sentinel.
        let output = try IndependentBallModel.decodeOutput(tensor)
        let first = try XCTUnwrap(output.candidates[0])
        XCTAssertEqual(first.boundingBox, .init(x: 30, y: 20, width: 4, height: 3))
        XCTAssertEqual(first.centerX, 32); XCTAssertEqual(first.centerY, 21)
        XCTAssertEqual(first.componentPixelCount, 12); XCTAssertEqual(first.thresholdPixelCount, 13)
        XCTAssertEqual(output.candidates[1]?.centerX, 100)
        XCTAssertEqual(output.candidates[1]?.centerY, 100)
        XCTAssertEqual(output.candidates[2]?.boundingBox, .init(x: 20, y: 20, width: 2, height: 2))
        XCTAssertNil(output.candidates[3])
    }

    func testOnlyExplicitExistingLocalModelURLsAreAccepted() throws {
        expectCode(.unsupportedModelURL) { _ = try IndependentBallModel(modelURL: URL(string: "https://example.com/model.mlpackage")!) }
        expectCode(.unsupportedModelURL) { _ = try IndependentBallModel(modelURL: URL(fileURLWithPath: "/tmp/model.pt")) }
        expectCode(.missingModel) { _ = try IndependentBallModel(modelURL: URL(fileURLWithPath: "/tmp/\(UUID()).mlmodelc")) }
    }

    /// Explicit opt-in: the actual Swift MLModel compiles the package and generates each
    /// output. Python arrays are references only, never substituted for native outputs.
    func testRealNativeCoreMLParity() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["COURT_INDEPENDENT_BALL_MODEL_URL"],
              let fixturePath = environment["COURT_INDEPENDENT_BALL_FIXTURES"],
              let outputPath = environment["COURT_INDEPENDENT_BALL_PARITY_OUTPUT"] else {
            throw XCTSkip("Set COURT_INDEPENDENT_BALL_MODEL_URL, COURT_INDEPENDENT_BALL_FIXTURES and COURT_INDEPENDENT_BALL_PARITY_OUTPUT for actual native Core ML parity.")
        }
        let fixtureRoot = URL(fileURLWithPath: fixturePath)
        let outputRoot = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: outputRoot.path) else { throw failure("Parity output must be a new directory") }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        do {
            let manifestURL = fixtureRoot.appendingPathComponent("manifest.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let manifestSHA = try String(contentsOf: fixtureRoot.appendingPathComponent("manifest.sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard digest(manifestData) == manifestSHA else { throw failure("Fixture manifest digest mismatch") }
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
            guard manifest["source_report_sha256"] as? String == "6f54b8c3e7511fcf6f590119a4db312065acbedbdb30ac998e6d6f278357e1eb",
                  manifest["sequence_count"] as? Int == 8, manifest["heatmaps"] as? Int == 64 else { throw failure("Unexpected frozen fixture source") }
            let packageFiles = try XCTUnwrap(manifest["model_package_files"] as? [[String: Any]])
            let modelURL = URL(fileURLWithPath: modelPath)
            if modelURL.pathExtension == "mlpackage" {
                for entry in packageFiles {
                    let relative = try XCTUnwrap(entry["path"] as? String)
                    let components = relative.split(separator: "/").dropFirst()
                    guard !components.contains("..") else { throw failure("Invalid package path") }
                    let fileURL = modelURL.appendingPathComponent(components.joined(separator: "/"))
                    guard digest(try Data(contentsOf: fileURL)) == entry["sha256"] as? String else { throw failure("Model package digest mismatch") }
                }
            }
            let compileStarted = Date()
            let model = try IndependentBallModel(modelURL: modelURL)
            let compileAndLoadSeconds = Date().timeIntervalSince(compileStarted)
            guard model.didCompileModel else { throw failure("This parity run must exercise native MLModel.compileModel on .mlpackage") }
            let compiledReload = try IndependentBallModel(modelURL: model.compiledModelURL)
            XCTAssertFalse(compiledReload.didCompileModel)
            let compiledCopy = outputRoot.appendingPathComponent("TrackNetV3Base.mlmodelc")
            try FileManager.default.copyItem(at: model.compiledModelURL, to: compiledCopy)
            let cases = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
            var results: [[String: Any]] = []
            var globalMaximum: Double = 0, globalMeanSum: Double = 0
            var thresholdChanges = 0, candidateChanges = 0
            // Declared engineering numeric tolerance; unrelated to ball/shot accuracy.
            let tolerance = 0.00002
            for item in cases {
                let name = try XCTUnwrap(item["name"] as? String)
                let artifacts = try XCTUnwrap(item["artifacts"] as? [String: [String: Any]])
                let input = try readFixture(try XCTUnwrap(artifacts["input"]), root: fixtureRoot, count: IndependentBallModel.inputCount)
                let coreml = try readFixture(try XCTUnwrap(artifacts["coreml_heatmaps"]), root: fixtureRoot, count: IndependentBallModel.outputCount)
                let pytorch = try readFixture(try XCTUnwrap(artifacts["pytorch_heatmaps"]), root: fixtureRoot, count: IndependentBallModel.outputCount)
                let started = Date()
                let prediction = try model.predict(nchw: input)
                let nativeSeconds = Date().timeIntervalSince(started)
                let nativeData = rawLittleEndian(prediction.heatmaps)
                try nativeData.write(to: outputRoot.appendingPathComponent(name + "-native.f32le"), options: .atomic)
                let official = try XCTUnwrap(item["official_candidates"] as? [[String: Any]])
                var maximumCoreML: Double = 0, maximumPyTorch: Double = 0, sum: Double = 0, flips = 0, changes = 0
                for i in prediction.heatmaps.indices {
                    let value = prediction.heatmaps[i]
                    let diff = abs(Double(value) - Double(coreml[i]))
                    maximumCoreML = max(maximumCoreML, diff); sum += diff
                    maximumPyTorch = max(maximumPyTorch, abs(Double(value) - Double(pytorch[i])))
                    if (value > 0.5) != (coreml[i] > 0.5) { flips += 1 }
                }
                for i in 0..<8 {
                    let reference = try XCTUnwrap(official[i]["coreml"] as? [String: Any])
                    let expected = reference["center_xy_512x288"] as? [Int]
                    let candidate = prediction.candidates[i]
                    let actual = candidate.map { [$0.centerX, $0.centerY] }
                    let expectedBox = reference["bbox"] as? [Int]
                    let actualBox = candidate.map { [$0.boundingBox.x, $0.boundingBox.y, $0.boundingBox.width, $0.boundingBox.height] }
                    // Author's origin sentinel has a bbox but no candidate center.
                    if actual != expected || (expected != nil && actualBox != expectedBox) { changes += 1 }
                }
                let mean = sum / Double(prediction.heatmaps.count)
                globalMaximum = max(globalMaximum, maximumCoreML); globalMeanSum += mean
                thresholdChanges += flips; candidateChanges += changes
                let encodedCandidates: [Any] = prediction.candidates.map { candidate in
                    guard let candidate else { return NSNull() }
                    return ["center": [candidate.centerX, candidate.centerY],
                            "bbox": [candidate.boundingBox.x, candidate.boundingBox.y, candidate.boundingBox.width, candidate.boundingBox.height]]
                }
                results.append(["name": name, "native_output": name + "-native.f32le", "native_sha256": digest(nativeData),
                    "native_seconds": nativeSeconds, "max_absolute_error_vs_python_coreml": maximumCoreML,
                    "mean_absolute_error_vs_python_coreml": mean, "max_absolute_error_vs_pytorch": maximumPyTorch,
                    "threshold_flipped_pixels": flips, "candidate_changed_frames": changes, "candidates": encodedCandidates,
                    "passed": maximumCoreML <= tolerance && maximumPyTorch <= tolerance && flips == 0 && changes == 0])
            }
            let passed = results.allSatisfy { $0["passed"] as? Bool == true }
            let report: [String: Any] = ["status": passed ? "passed" : "failed", "production": false,
                "purpose": "Actual Swift Core ML numeric parity, not ball/shot/speed accuracy", "iphone_tested": false,
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "model_url": modelURL.path,
                "native_compile_performed": model.didCompileModel, "compiled_model_reloaded": !compiledReload.didCompileModel,
                "compiled_model_copy": compiledCopy.path, "compile_and_load_seconds": compileAndLoadSeconds,
                "compute_units": "CPU_ONLY", "fixture_manifest_sha256": manifestSHA, "numeric_absolute_tolerance": tolerance,
                "sequences": results.count, "heatmaps": results.count * 8, "max_absolute_error_vs_python_coreml": globalMaximum,
                "mean_absolute_error_vs_python_coreml": globalMeanSum / Double(results.count),
                "threshold_flipped_pixels": thresholdChanges, "candidate_changed_frames": candidateChanges, "cases": results]
            try writeJSON(report, to: outputRoot.appendingPathComponent("report.json"))
            XCTAssertTrue(passed, "Native parity failed; inspect \(outputRoot.path)/report.json")
        } catch {
            try? writeJSON(["status": "failed", "error": String(describing: error), "production": false], to: outputRoot.appendingPathComponent("failure.json"))
            throw error
        }
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func failure(_ message: String) -> Error { NSError(domain: "IndependentBallFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private func readFixture(_ artifact: [String: Any], root: URL, count: Int) throws -> [Float] {
        let name = try XCTUnwrap(artifact["path"] as? String)
        guard !name.contains("/"), !name.contains("..") else { throw failure("Invalid fixture path") }
        let data = try Data(contentsOf: root.appendingPathComponent(name), options: .mappedIfSafe)
        guard data.count == count * 4, artifact["bytes"] as? Int == data.count,
              artifact["dtype"] as? String == "float32", artifact["byte_order"] as? String == "little",
              digest(data) == artifact["sha256"] as? String else { throw failure("Fixture contract/digest mismatch: \(name)") }
        return data.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
    private func rawLittleEndian(_ values: [Float]) -> Data {
        let words = values.map { $0.bitPattern.littleEndian }
        return words.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
#endif
