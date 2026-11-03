import Foundation

/// Installed apps use a versioned local bundle. CLI tools may explicitly select a
/// model directory; there is no network download or silent substitute detector.
public enum AnalysisModelLocator {
    public static var directory: URL? {
        directory(in: .main, environment: ProcessInfo.processInfo.environment)
    }

    public static func directory(in bundle: Bundle, environment: [String: String], defaults: UserDefaults = .standard) -> URL? {
        // The independent experiment and code-only app must not inherit a private
        // runtime through an environment override intended for developer CLIs.
        let mode = bundle.object(forInfoDictionaryKey: "CourtModelSet") as? String
        guard mode != "independent" && mode != "code-only" else { return nil }
        // A build carrying both sets uses the S家 weights only while the user keeps S家 selected.
        if mode == "both" && CourtAnalysisBackend.current(defaults) != .sjia { return nil }
        if let path = environment["COURT_ANALYSIS_MODELS_DIR"], !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
        }
        guard let root = bundle.resourceURL else { return nil }
        let url = root.appendingPathComponent("AnalysisModels", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
    }
}
