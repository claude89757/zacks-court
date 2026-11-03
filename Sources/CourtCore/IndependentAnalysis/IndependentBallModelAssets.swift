import Foundation
import CryptoKit

public enum IndependentBallModelAssetsError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

/// The independent MIT artifact only. This locator never consults AnalysisModels,
/// environment-selected S家 directories, or a network/download service.
public struct IndependentBallModelAssets: Sendable {
    /// Frozen conversions of the same MIT TrackNetV3 checkpoint, each pinned by its reviewed manifest.
    public enum Variant: String, Sendable, CaseIterable {
        /// FP32 research conversion: offline analysis, bit-for-bit with the Python reference.
        case base = "tracknetv3-base-v1"
        /// FP16 compute for the Neural Engine (live chain); matches FP32 within a tolerance only.
        case fp16 = "tracknetv3-base-fp16-v1"
        public var reviewedManifestSHA256: String {
            switch self {
            case .base: return "7b5d238e50b2ac6475d69c362b97555d050e2572d1e9e6d4a2962b0b1bfc5282"
            case .fp16: return "69327a353791b2609f8600137c0db20d2a9ad1b3968d9320341925c1aa343329"
            }
        }
    }
    public static let modelIdentifier = Variant.base.rawValue
    public static let packageName = "TrackNetV3Base.mlpackage"
    public static let reviewedManifestSHA256 = Variant.base.reviewedManifestSHA256
    public let directory: URL
    public let modelURL: URL
    public let modelID: String
    public let manifestSHA256: String
    public let packageBytes: Int

    public static func bundled(in bundle: Bundle = .main, variant: Variant = .base) throws -> Self {
        guard let root = bundle.resourceURL else { throw IndependentBallModelAssetsError.invalid("Independent model bundle resources are unavailable") }
        return try load(directory: root.appendingPathComponent("IndependentModels/" + variant.rawValue, isDirectory: true), variant: variant)
    }
    /// Byte validation is synchronous; call on an analysis/background queue.
    public static func load(directory: URL, variant: Variant = .base) throws -> Self {
        try verify(directory: directory, expectedManifestSHA256: variant.reviewedManifestSHA256, modelIdentifier: variant.rawValue)
    }
    static func verify(directory: URL, expectedManifestSHA256: String, modelIdentifier: String = modelIdentifier,
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Self {
        func require(_ value: Bool, _ reason: String) throws {
            if !value { throw IndependentBallModelAssetsError.invalid(reason) }
        }
        try checkCancellation()
        try require(directory.isFileURL, "Independent model assets require a local directory")
        let root = try validatedRoot(directory)
        let manifestURL = try child("manifest.json", root: root)
        let manifest = try boundedData(manifestURL, maximum: 64*1024)
        let digest = sha(manifest)
        try require(digest == expectedManifestSHA256, "Independent model manifest differs from reviewed bytes")
        struct Catalog: Decodable {
            struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
            struct Notice: Decodable { let file: String; let bytes: Int; let sha256: String }
            let schema_version: Int, model_id: String, package_name: String, package_bytes: Int
            let package_files: [File]
            let license: Notice
            let documentation: Notice
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: manifest)
        try require(catalog.schema_version == 1 && catalog.model_id == modelIdentifier && catalog.package_name == packageName,
                    "Unsupported independent model identity")
        let expectedPaths = Set(["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"])
        try require(catalog.package_files.count == 3 && Set(catalog.package_files.map(\.path)) == expectedPaths,
                    "Independent model file set is incomplete or duplicated")
        let package = try child(packageName, root: root)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var actualFiles = Set<String>()
        let allowedDirectories: Set<String> = ["Data", "Data/com.apple.CoreML", "Data/com.apple.CoreML/weights"]
        // Carry relative names explicitly: Foundation may enumerate /private/var
        // even when the requested URL used /var. Never subtract absolute paths.
        var pendingDirectories = [""]
        while let relativeDirectory = pendingDirectories.popLast() {
            let parent = relativeDirectory.isEmpty ? package : try child(relativeDirectory, root: package)
            for entry in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys)) {
                try checkCancellation()
                let relative = relativeDirectory.isEmpty ? entry.lastPathComponent : relativeDirectory+"/"+entry.lastPathComponent
                let file = try child(relative, root: package)
                let values = try file.resourceValues(forKeys: keys)
                try require(values.isSymbolicLink != true, "Symlink independent model files are not accepted")
                if values.isDirectory == true {
                    try require(allowedDirectories.contains(relative), "Unexpected independent model directory: \(relative)")
                    pendingDirectories.append(relative)
                } else {
                    try require(values.isRegularFile == true, "Independent model entries must be ordinary files")
                    actualFiles.insert(relative)
                }
            }
        }
        try require(actualFiles == expectedPaths, "Independent model contains missing or extra files")
        var total = 0
        for file in catalog.package_files {
            try require(file.bytes > 0 && file.bytes <= 64*1024*1024 && validSHA(file.sha256), "Invalid independent model file metadata")
            let url = try child(file.path, root: package)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try require((attributes[.size] as? NSNumber)?.intValue == file.bytes, "Independent model file size differs from manifest")
            try require(try shaFile(url, checkCancellation: checkCancellation) == file.sha256, "Independent model file digest differs from manifest")
            total += file.bytes
        }
        try require(total == catalog.package_bytes, "Independent model aggregate size differs from manifest")
        try require(catalog.license.file == "LICENSE" && catalog.license.sha256 == "1eeb31683deba741bce99f5f33bb813293a23b4e6c8302d6f056a587a30cd497", "Independent model MIT notice identity differs")
        for notice in [catalog.license, catalog.documentation] {
            let bytes = try boundedData(try child(notice.file, root: root), maximum: 128*1024)
            try require(bytes.count == notice.bytes && sha(bytes) == notice.sha256, "Independent model licence/documentation differs from manifest")
        }
        try checkCancellation()
        return Self(directory: root, modelURL: package, modelID: catalog.model_id, manifestSHA256: digest, packageBytes: total)
    }
    static func validSHA(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Streaming, cancellable hashing; each chunk's autoreleased storage drains.
    static func shaFile(_ url: URL, checkCancellation: () throws -> Void) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            try checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            digest.update(data: data); return true
        }) { }
        try checkCancellation()
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size >= 0, size <= maximum else {
            throw IndependentBallModelAssetsError.invalid("Independent asset text must be a bounded ordinary file")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum+1) ?? Data()
        guard data.count == size else { throw IndependentBallModelAssetsError.invalid("Independent asset text changed during read") }
        return data
    }
    private static func validatedRoot(_ directory: URL) throws -> URL {
        let initial = directory.standardizedFileURL
        var cursor = URL(fileURLWithPath: "/")
        for component in initial.pathComponents.dropFirst() {
            cursor.appendPathComponent(component)
            let attributes = try FileManager.default.attributesOfItem(atPath: cursor.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)
                let systemAlias = (cursor.path == "/var" && ["private/var", "/private/var"].contains(destination))
                    || (cursor.path == "/tmp" && ["private/tmp", "/private/tmp"].contains(destination))
                guard systemAlias else { throw IndependentBallModelAssetsError.invalid("Symlink independent model roots/ancestors are not accepted") }
            }
        }
        return initial
    }
    private static func child(_ relative: String, root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw IndependentBallModelAssetsError.invalid("Invalid relative independent asset path")
        }
        var cursor = root
        for part in components {
            cursor.appendPathComponent(String(part))
            if try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw IndependentBallModelAssetsError.invalid("Symlink independent assets are not accepted")
            }
        }
        return cursor
    }
}
