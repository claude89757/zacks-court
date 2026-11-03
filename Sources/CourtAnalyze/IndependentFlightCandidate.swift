import Foundation
import CryptoKit
import Darwin
import CourtCore

/// Replays a saved analyzer artifact. It does not reopen the source video, run
/// inference or establish the physical accuracy of its camera/event assumptions.
enum IndependentFlightCandidateCommand {
    struct AnalysisFile: Codable {
        let path: String
        let sha256: String
    }
    struct ProtocolInput: Codable {
        let schema: String
        let analysis: AnalysisFile
        let camera: IndependentBallisticCamera?
        let evidence: IndependentFlightIntervalEvidence?
        let configuration: IndependentBallisticConfiguration
    }
    private static let maximumProtocolBytes = 8 * 1024 * 1024
    private static let maximumAnalysisBytes = 256 * 1024 * 1024

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CourtError.message(message) }
    }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func boundedData(_ url: URL, maximum: Int) throws -> Data {
        var cursor = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            cursor.appendPathComponent(component)
            try require(try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                        "Symlink input is not accepted")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try require(attributes[.type] as? FileAttributeType == .typeRegular, "Input must be a regular file")
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        try require(size >= 0 && size <= maximum, "Input exceeds diagnostic byte bound")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        try require(bytes.count == size && bytes.count <= maximum, "Input changed length during bounded read")
        return bytes
    }

    static func run(_ args: [String]) throws {
        try require(args.count == 3, "Usage: court-analyze independent-flight-candidate PROTOCOL_JSON NEW_OUTPUT_DIRECTORY")
        let protocolURL = URL(fileURLWithPath: args[1]).standardizedFileURL
        let output = URL(fileURLWithPath: args[2]).standardizedFileURL
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: output.path), "Output exists; choose a new directory")
        let data = try boundedData(protocolURL, maximum: maximumProtocolBytes)
        let frozen = try JSONDecoder().decode(ProtocolInput.self, from: data)
        try require(frozen.schema == "independent-flight-candidate-v1", "Unsupported flight candidate protocol schema")
        let file = frozen.analysis
        try require(file.path.hasPrefix("/") && file.path.utf8.count <= 4096 && file.sha256.count == 64
                    && file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "Invalid saved analysis identity")
        let analysisURL = URL(fileURLWithPath: file.path).standardizedFileURL
        let analysisData = try boundedData(analysisURL, maximum: maximumAnalysisBytes)
        let analysisSHA = sha(analysisData)
        try require(analysisSHA == file.sha256, "Saved analysis SHA-256 mismatch")
        let result = try IndependentFlightCandidateBuilder.build(savedAnalysisJSON: analysisData,
            camera: frozen.camera, evidence: frozen.evidence, configuration: frozen.configuration)
        try require(try boundedData(analysisURL, maximum: maximumAnalysisBytes) == analysisData,
                    "Saved analysis changed during candidate diagnostic")
        try require(try boundedData(protocolURL, maximum: maximumProtocolBytes) == data,
                    "Protocol changed during candidate diagnostic")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report: [String: Any] = [
            "schema": "independent-flight-candidate-result-v1",
            "protocol_sha256": sha(data), "analysis_sha256": analysisSHA,
            "protocol": try JSONSerialization.jsonObject(with: encoder.encode(frozen)),
            "result": try JSONSerialization.jsonObject(with: encoder.encode(result)),
            "new_model_forwards": 0, "camera_fit_count": 0,
            "source_video_reverified": false, "speed_outputs": 0,
            "production": false, "physical_accuracy_validated": false
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let stage = output.deletingLastPathComponent().appendingPathComponent(".independent-flight-candidate-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let reportURL = stage.appendingPathComponent("report.json")
        try reportData.write(to: reportURL, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        let code = stage.path.withCString { from in
            output.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
        }
        try require(code == 0, "Cannot atomically publish new output directory (errno \(errno))")
        print("INDEPENDENT_FLIGHT_CANDIDATE_OK status=\(result.status.rawValue) selected_frames=\(result.selectedFrameIndices.count) raw_candidate=\(result.rawCandidate != nil) speeds=0 report_sha256=\(sha(reportData)) output=\(output.path)")
    }
}
