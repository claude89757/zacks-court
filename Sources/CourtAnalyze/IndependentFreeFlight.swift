import Foundation
import CryptoKit
import Darwin
import CourtCore

/// Explicit, offline fixed-camera algebraic diagnostic. Never opens capture or
/// changes the app's selected backend. Evidence is hashed before and after work.
enum IndependentFreeFlightCommand {
    struct Evidence: Codable {
        let path: String
        let sha256: String
        let role: String
    }
    struct ProtocolInput: Decodable {
        let schema: String
        let input: IndependentFreeFlightInput
        let evidence_files: [Evidence]
    }
    private static let maximumProtocolBytes = 8*1024*1024
    private static let maximumEvidenceBytes = 256*1024*1024
    private static let maximumTotalEvidenceBytes = 512*1024*1024
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CourtError.message(message) }
    }
    private static func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func boundedData(_ url: URL, maximum: Int) throws -> Data {
        // Reject symlinks in every component, including parent directories.
        var cursor = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            cursor.appendPathComponent(component)
            try require(try cursor.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true, "Symlink evidence is not accepted")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        try require(attributes[.type] as? FileAttributeType == .typeRegular, "Evidence must be a regular file")
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        try require(size >= 0 && size <= maximum, "Evidence exceeds diagnostic byte bound")
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount:maximum+1) ?? Data()
        try require(bytes.count == size && bytes.count <= maximum, "Evidence changed length during bounded read")
        return bytes
    }
    private static func rejectClaims(_ value: Any) throws {
        if let object = value as? [String:Any] {
            for (key, nested) in object {
                if ["qualified", "accepted", "cameraMeasured", "camera_measured", "human_annotation", "formal_review", "production", "human", "formal", "physicalAccuracyValidated", "cameraQualified", "nativeEndToEndSpeedAccepted", "twentyPercentAcceptanceEligible", "physical_accuracy_validated", "camera_qualified", "native_end_to_end_speed_accepted", "twenty_percent_acceptance_eligible", "speed_model_accepted"].contains(key) {
                    try require((nested as? NSNumber)?.objCType.pointee == 99 && (nested as? Bool) == false, "Diagnostic protocol cannot assert qualification: \(key)")
                }
                if ["acceptedCamera", "accepted_camera", "accepted_K", "accepted_velocity", "accepted_speed_kmh", "velocity", "speedKilometersPerHour", "speed_kmh"].contains(key) { try require(nested is NSNull, "Public accepted values must remain null: \(key)") }
                try rejectClaims(nested)
            }
        } else if let array = value as? [Any] { for item in array { try rejectClaims(item) } }
    }
    static func run(_ args: [String]) throws {
        try require(args.count == 3, "Usage: court-analyze independent-free-flight PROTOCOL_JSON NEW_OUTPUT_DIRECTORY")
        let protocolURL = URL(fileURLWithPath:args[1]).standardizedFileURL, output = URL(fileURLWithPath:args[2]).standardizedFileURL
        let fm = FileManager.default
        try require(!fm.fileExists(atPath:output.path), "Output exists; choose a new directory")
        let data = try boundedData(protocolURL,maximum:maximumProtocolBytes)
        try rejectClaims(JSONSerialization.jsonObject(with:data))
        let frozen = try JSONDecoder().decode(ProtocolInput.self,from:data)
        try require(frozen.schema == "independent-free-contact-flight-diagnostic-v1", "Unsupported diagnostic protocol schema")
        try require((1...64).contains(frozen.evidence_files.count), "Require 1...64 frozen evidence files")
        try require(Set(frozen.evidence_files.map(\.path)).count == frozen.evidence_files.count, "Duplicate evidence paths")
        var total = 0
        func checkEvidence() throws {
            total = 0
            for file in frozen.evidence_files {
                try require(file.path.hasPrefix("/") && !file.role.isEmpty && file.role.utf8.count <= 4096 && file.path.utf8.count <= 4096 && file.sha256.count == 64 && file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "Invalid evidence identity")
                let bytes = try boundedData(URL(fileURLWithPath:file.path),maximum:maximumEvidenceBytes)
                total += bytes.count
                try require(total <= maximumTotalEvidenceBytes && sha(bytes) == file.sha256, "Evidence hash mismatch or aggregate byte bound exceeded")
            }
        }
        try checkEvidence()
        let result = try IndependentFreeFlightDiagnostic.fit(frozen.input)
        try checkEvidence()
        try require(try boundedData(protocolURL,maximum:maximumProtocolBytes) == data, "Protocol changed during diagnostic")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let resultData = try encoder.encode(result)
        let report: [String:Any] = ["schema":"independent-free-contact-flight-result-v1", "protocol_sha256":sha(data), "evidence_files":try JSONSerialization.jsonObject(with:encoder.encode(frozen.evidence_files)), "input":try JSONSerialization.jsonObject(with:encoder.encode(frozen.input)), "diagnostic":try JSONSerialization.jsonObject(with:resultData), "new_model_loads":0,"camera_fit_count":0,"speed_outputs":0,"production":false,"physical_accuracy_validated":false]
        let reportData = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        let parent = output.deletingLastPathComponent(), stage = parent.appendingPathComponent(".independent-free-flight-\(UUID().uuidString)")
        try fm.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? fm.removeItem(at:stage) }
        try reportData.write(to:stage.appendingPathComponent("report.json"),options:.withoutOverwriting)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:stage.appendingPathComponent("report.json").path)
        // RENAME_EXCL publishes the entire directory atomically and cannot replace
        // another process's output between the existence check and publication.
        let code = stage.path.withCString { from in output.path.withCString { to in renamex_np(from,to,UInt32(RENAME_EXCL)) } }
        try require(code == 0, "Cannot atomically publish new output directory (errno \(errno))")
        print("INDEPENDENT_FREE_FLIGHT_OK observations=\(result.observedFrameIndices.count) missing=\(result.missingFrameIndices.count) speeds=0 status=\(result.status) report_sha256=\(sha(reportData)) output=\(output.path)")
    }
}
