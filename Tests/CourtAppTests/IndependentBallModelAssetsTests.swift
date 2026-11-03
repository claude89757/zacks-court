import XCTest
import CryptoKit
@testable import CourtCore

final class IndependentBallModelAssetsTests: XCTestCase {
    private struct Fixture { let root: URL; let manifestSHA: String }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("independent-assets-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = repository.appendingPathComponent("assets/independent-models/tracknetv3-base-v1")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog.appendingPathComponent("manifest.json"))) as? [String:Any])
        for name in ["LICENSE", "README.md"] { try FileManager.default.copyItem(at: catalog.appendingPathComponent(name), to: root.appendingPathComponent(name)) }
        var records: [[String:Any]] = []
        for (name, text) in [("Manifest.json", "Synthetic package manifest, never executable Core ML"),
                             ("Data/com.apple.CoreML/model.mlmodel", "Synthetic model, never executable Core ML"),
                             ("Data/com.apple.CoreML/weights/weight.bin", "Synthetic weight bytes")] {
            let data = Data(text.utf8), file = root.appendingPathComponent(IndependentBallModelAssets.packageName+"/"+name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            records.append(["path":name,"bytes":data.count,"sha256":IndependentBallModelAssets.sha(data)])
        }
        manifest["package_files"] = records; manifest["package_bytes"] = records.reduce(0) { $0+($1["bytes"] as! Int) }
        let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try bytes.write(to: root.appendingPathComponent("manifest.json"))
        return .init(root: root, manifestSHA: IndependentBallModelAssets.sha(bytes))
    }
    func testControlledBytesAreVerifiedWithoutCompilingOrPredicting() throws {
        let f = try fixture()
        let assets = try IndependentBallModelAssets.verify(directory:f.root, expectedManifestSHA256:f.manifestSHA)
        XCTAssertEqual(assets.modelID,"tracknetv3-base-v1")
        XCTAssertEqual(assets.manifestSHA256,f.manifestSHA)
        XCTAssertEqual(assets.modelURL.lastPathComponent,"TrackNetV3Base.mlpackage")
        XCTAssertGreaterThan(assets.packageBytes,0)
        // The public trust root cannot be replaced by a synthetic manifest.
        XCTAssertThrowsError(try IndependentBallModelAssets.load(directory:f.root))
    }
    /// Each frozen conversion is pinned by the committed manifest, and identities cannot be swapped.
    func testFP16VariantIsPinnedSeparatelyFromFP32() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for variant in IndependentBallModelAssets.Variant.allCases {
            let manifest = try Data(contentsOf: repository.appendingPathComponent("assets/independent-models/\(variant.rawValue)/manifest.json"))
            XCTAssertEqual(IndependentBallModelAssets.sha(manifest), variant.reviewedManifestSHA256, variant.rawValue)
        }
        let f = try fixture()
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.root.appendingPathComponent("manifest.json"))) as? [String: Any])
        manifest["model_id"] = IndependentBallModelAssets.Variant.fp16.rawValue
        let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try bytes.write(to: f.root.appendingPathComponent("manifest.json"))
        let sha = IndependentBallModelAssets.sha(bytes)
        XCTAssertEqual(try IndependentBallModelAssets.verify(directory: f.root, expectedManifestSHA256: sha, modelIdentifier: "tracknetv3-base-fp16-v1").modelID,
                       "tracknetv3-base-fp16-v1")
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory: f.root, expectedManifestSHA256: sha), "an FP16 package is not the FP32 model")
        XCTAssertThrowsError(try IndependentBallModelAssets.load(directory: f.root, variant: .fp16), "the public FP16 pin cannot be replaced")
    }
    /// The staged FP16 package (scripts/prepare-independent-app-models.sh) verifies against its pin.
    func testStagedFP16PackageVerifies() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let staged = repository.appendingPathComponent(".local/IndependentModels/tracknetv3-base-fp16-v1")
        guard FileManager.default.fileExists(atPath: staged.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Run scripts/prepare-independent-app-models.sh to stage the FP16 package")
        }
        let assets = try IndependentBallModelAssets.load(directory: staged, variant: .fp16)
        XCTAssertEqual(assets.modelID, "tracknetv3-base-fp16-v1")
        XCTAssertEqual(assets.packageBytes, 22_707_243)
    }
    func testMissingChangedAndExtraPackageFilesAreRejected() throws {
        let f = try fixture()
        let weight = f.root.appendingPathComponent("TrackNetV3Base.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        let original = try Data(contentsOf:weight)
        var changed = original; changed[0] ^= 1; try changed.write(to:weight)
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory:f.root,expectedManifestSHA256:f.manifestSHA))
        try original.write(to:weight)
        let extra = f.root.appendingPathComponent("TrackNetV3Base.mlpackage/extra.txt")
        try Data([1]).write(to:extra)
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory:f.root,expectedManifestSHA256:f.manifestSHA))
        try FileManager.default.removeItem(at:extra); try FileManager.default.removeItem(at:weight)
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory:f.root,expectedManifestSHA256:f.manifestSHA))
    }
    func testSymlinksNoticeAndManifestTamperingAreRejected() throws {
        let f = try fixture()
        let weight = f.root.appendingPathComponent("TrackNetV3Base.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        let outside = f.root.appendingPathComponent("outside.bin")
        try FileManager.default.moveItem(at:weight,to:outside)
        try FileManager.default.createSymbolicLink(at:weight,withDestinationURL:outside)
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory:f.root,expectedManifestSHA256:f.manifestSHA))
        try FileManager.default.removeItem(at:weight); try FileManager.default.moveItem(at:outside,to:weight)
        try Data("changed licence".utf8).write(to:f.root.appendingPathComponent("LICENSE"))
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory:f.root,expectedManifestSHA256:f.manifestSHA))
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory:f.root,expectedManifestSHA256:String(repeating:"0",count:64)))
    }
    func testPrivateAnalysisDirectoryIsNotAnIndependentFallback() throws {
        let f = try fixture()
        let privateDirectory = f.root.appendingPathComponent("AnalysisModels")
        try FileManager.default.createDirectory(at:privateDirectory,withIntermediateDirectories:true)
        try Data("private resources must not be used".utf8).write(to:privateDirectory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try IndependentBallModelAssets.load(directory:privateDirectory))
        XCTAssertThrowsError(try IndependentBallModelAssets.load(directory:f.root.appendingPathComponent("IndependentModels/tracknetv3-base-v1")))
    }
    func testUserModelRootAndAncestorSymlinksAreRejected() throws {
        let f = try fixture()
        let alias = f.root.deletingLastPathComponent().appendingPathComponent("independent-root-alias-"+UUID().uuidString)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:f.root)
        defer { try? FileManager.default.removeItem(at:alias) }
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory:alias,expectedManifestSHA256:f.manifestSHA))
        let ancestor = f.root.deletingLastPathComponent().appendingPathComponent("independent-ancestor-alias-"+UUID().uuidString)
        try FileManager.default.createSymbolicLink(at:ancestor,withDestinationURL:f.root.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at:ancestor) }
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory:ancestor.appendingPathComponent(f.root.lastPathComponent),expectedManifestSHA256:f.manifestSHA))
    }
    func testChunkedHashAndVerificationHonorCancellation() throws {
        let f = try fixture(), file = f.root.appendingPathComponent("large.bin")
        let bytes = Data(repeating:123,count:3*1_048_576+17); try bytes.write(to:file)
        XCTAssertEqual(try IndependentBallModelAssets.shaFile(file,checkCancellation:{}),IndependentBallModelAssets.sha(bytes))
        var chunks = 0
        XCTAssertThrowsError(try IndependentBallModelAssets.shaFile(file,checkCancellation:{ chunks += 1; if chunks == 3 { throw CancellationError() } })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(chunks,3)
        XCTAssertThrowsError(try IndependentBallModelAssets.verify(directory:f.root,expectedManifestSHA256:f.manifestSHA,checkCancellation:{ throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
    }
}
