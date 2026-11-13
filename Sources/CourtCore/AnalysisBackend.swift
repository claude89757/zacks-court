import Foundation

/// Which analysis models the App uses. Saved per device. S家 is the reference model set a developer
/// keeps locally (never in Git); builds made with `COURT_MODEL_SET=both` carry it next to the in-house
/// set, and there S家 stays the default. In the in-house mode no code path may load the S家 weights:
/// the locator returns nil, so S家 live analysis and backfill are off.
public enum CourtAnalysisBackend: String, CaseIterable, Sendable, Codable {
    case sjia
    case independent

    public static let defaultsKey = "court.analysis.backend"

    public var title: String { self == .sjia ? courtText("S家模型") : courtText("自研模型") }

    /// The saved choice, or S家 when nothing (or something unknown) is saved. Installs saved before
    /// the rename stored `swing` for S家.
    public static func current(_ defaults: UserDefaults = .standard) -> CourtAnalysisBackend {
        guard let saved = defaults.string(forKey: defaultsKey) else { return .sjia }
        return saved == "swing" ? .sjia : Self(rawValue: saved) ?? .sjia
    }
    public static func save(_ backend: CourtAnalysisBackend, _ defaults: UserDefaults = .standard) {
        defaults.set(backend.rawValue, forKey: defaultsKey)
    }

    /// Model sets this build bundles (Info.plist `CourtModelSet`: independent, both, sjia, code-only;
    /// `swing` is the old name of sjia).
    public static func bundled(in bundle: Bundle = .main) -> [CourtAnalysisBackend] {
        switch bundle.object(forInfoDictionaryKey: "CourtModelSet") as? String {
        case "independent": return [.independent]
        case "code-only": return []
        case "both": return [.sjia, .independent]
        default: return [.sjia]
        }
    }

    /// The backend in effect: the saved choice when this build carries it, else the first bundled one.
    public static func effective(in bundle: Bundle = .main, defaults: UserDefaults = .standard) -> CourtAnalysisBackend? {
        let available = bundled(in: bundle)
        let chosen = current(defaults)
        return available.contains(chosen) ? chosen : available.first
    }
}
