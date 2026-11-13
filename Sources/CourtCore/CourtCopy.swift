import Foundation

/// In-app copy for the six supported languages.
///
/// Simplified Chinese is the development language and the key of every entry. Until `activate()`,
/// `courtText` returns that key unchanged. That startup default is safe: the app activates before
/// it creates a session or a view, and tests that never activate keep asserting the old Chinese
/// sentences. It is not the locale fallback. After `activate()`, a preferred list with no supported
/// language (Spanish only, or an empty list) resolves to English, the store's primary locale.
/// A missing catalog entry still shows the Simplified Chinese source, which is a gap in the table,
/// not a locale choice.
///
/// en-US and en-GB share the `en` strings. Region still selects dates and decimal separators
/// (`en_GB` vs `en_US`). An unsupported preferred language (for example Spanish) stays Simplified
/// Chinese, the same screens the app showed before it was localized.
///
/// The spoken line call stays the recorded English "Out!" / "In." in every language. Those clips
/// are what Simplified Chinese already plays; this catalog does not invent new audio.
///
/// Wire and saved records keep stable text where a peer or a later reader compares it:
/// `TennisReason` match keys are not passed through `courtText`, and `CourtStored` only translates
/// the app's own fixed labels (demo title, default session name, the two marker names). Text the
/// user typed is left as they typed it.
public enum CourtLanguage: String, CaseIterable, Sendable, Equatable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case de
    case fr

    public var catalogKey: String { rawValue }
}

public struct CourtLocaleChoice: Equatable, Sendable {
    public var language: CourtLanguage
    /// `Locale` identifier (`zh_CN`, `en_GB`, `de_AT`). Dates and decimals use it.
    /// Simplified Chinese formatting does not: it keeps the previous `String(format:)` output.
    public var formatIdentifier: String

    public var formatLocale: Locale { Locale(identifier: formatIdentifier) }

    public static let simplifiedChinese = CourtLocaleChoice(language: .zhHans, formatIdentifier: "zh_CN")
    /// Store primary locale is en-US. Used only when the preferred list has no supported language.
    public static let english = CourtLocaleChoice(language: .en, formatIdentifier: "en_US")
}

public enum CourtLocale {
    /// `COURT_LANGUAGE` wins (screenshot and UI-test runs). Otherwise the first preferred language
    /// we have copy for. Simplified Chinese and Traditional Chinese stay explicit. If the list has
    /// no supported language at all, including an empty list, the result is English (`en_US`),
    /// matching the store's primary locale.
    public static func resolve(preferred: [String], environment: [String: String] = [:]) -> CourtLocaleChoice {
        if let forced = environment["COURT_LANGUAGE"], !forced.isEmpty, let choice = parse(forced) {
            return choice
        }
        for tag in preferred {
            if let choice = parse(tag) { return choice }
        }
        return .english
    }

    /// One BCP-47 tag. `nil` when this app has no strings for it.
    public static func parse(_ tag: String) -> CourtLocaleChoice? {
        let parts = tag.split { $0 == "-" || $0 == "_" }.map(String.init)
        guard let head = parts.first?.lowercased(), !head.isEmpty else { return nil }
        let region = parts.dropFirst().first { $0.count == 2 && $0.allSatisfy(\.isLetter) }?.uppercased()
        let script = parts.dropFirst().first { $0.count == 4 }?.lowercased()
        switch head {
        case "zh":
            let traditional = script == "hant" || region == "TW" || region == "HK" || region == "MO"
            if traditional {
                let id = region == "HK" ? "zh_HK" : (region == "MO" ? "zh_MO" : "zh_TW")
                return CourtLocaleChoice(language: .zhHant, formatIdentifier: id)
            }
            // Bare `zh`, zh-Hans, zh-CN, zh-SG: Simplified, matching the development language.
            let id = region == "SG" ? "zh_SG" : "zh_CN"
            return CourtLocaleChoice(language: .zhHans, formatIdentifier: id)
        case "en":
            let id = region == "GB" ? "en_GB" : (region.map { "en_\($0)" } ?? "en_US")
            return CourtLocaleChoice(language: .en, formatIdentifier: id)
        case "ja":
            return CourtLocaleChoice(language: .ja, formatIdentifier: region.map { "ja_\($0)" } ?? "ja_JP")
        case "de":
            return CourtLocaleChoice(language: .de, formatIdentifier: region.map { "de_\($0)" } ?? "de_DE")
        case "fr":
            return CourtLocaleChoice(language: .fr, formatIdentifier: region.map { "fr_\($0)" } ?? "fr_FR")
        default:
            return nil
        }
    }
}

public enum CourtCopy {
    /// Set by `activate()` at app launch. Until then the choice stays Simplified Chinese, so a
    /// string read during process startup is the canonical key and unit tests that never activate
    /// keep the wording they already assert. The app calls `activate()` before it builds a session
    /// or a view, so a user does not see that startup default.
    private static let state = LockedChoice()
    @TaskLocal private static var override: CourtLocaleChoice?

    public static var choice: CourtLocaleChoice { override ?? state.current ?? .simplifiedChinese }
    public static var language: CourtLanguage { choice.language }
    public static var formatLocale: Locale { choice.formatLocale }

    /// Reads the phone or Mac language, unless `COURT_LANGUAGE` is set.
    public static func activate(preferred: [String]? = nil, environment: [String: String]? = nil) {
        let choice = CourtLocale.resolve(
            preferred: preferred ?? Locale.preferredLanguages,
            environment: environment ?? ProcessInfo.processInfo.environment)
        state.set(choice)
        if !loaded { load() }
    }

    /// Runs `body` in another language without touching the process-wide choice. Safe next to tests
    /// that still expect Simplified Chinese.
    public static func withLanguage<T>(_ tag: String, _ body: () throws -> T) rethrows -> T {
        let choice = CourtLocale.parse(tag) ?? .english
        return try $override.withValue(choice, operation: body)
    }

    /// Clears `activate()` so a test can prove the pre-launch default again. Does not touch a
    /// `withLanguage` override on the current task.
    public static func resetActivationForTesting() {
        state.clear()
    }

    public static func text(_ source: String) -> String {
        if language == .zhHans { return source }
        if !loaded { load() }
        return table[source]?[language.catalogKey] ?? source
    }

    /// Replaces `%1$@`, `%2$@`, … in order. The arguments are already strings so Simplified Chinese
    /// stays byte-for-byte with the interpolation the call site used to write.
    public static func format(_ source: String, _ args: [String]) -> String {
        var result = text(source)
        for (index, arg) in args.enumerated() {
            result = result.replacingOccurrences(of: "%\(index + 1)$@", with: arg)
        }
        return result
    }

    /// `String(format:)` for a catalog key. Simplified Chinese formats the original pattern with the
    /// default locale, so existing sentences (and the tests that look for them) do not change.
    public static func printf(_ pattern: String, _ args: [CVarArg]) -> String {
        if language == .zhHans {
            return String(format: pattern, arguments: args)
        }
        return String(format: text(pattern), locale: formatLocale, arguments: args)
    }

    /// Fixed labels the app itself wrote into a session. Anything else, including a title the user
    /// typed, is returned unchanged.
    public static func stored(_ value: String) -> String {
        storedPhrases.contains(value) ? text(value) : value
    }

    public static let storedPhrases: Set<String> = [
        "示例记录 · 演示数据，非实测",
        "演示数据",
        "球场分析",
        "精彩",
        "待复核",
        "标记",
    ]

    /// Loads the catalog. Missing file: every lookup stays Simplified Chinese.
    public static func load(from data: Data) {
        loaded = true
        guard let parsed = try? JSONDecoder().decode(Catalog.self, from: data) else { return }
        table = parsed.strings
    }

    private struct Catalog: Decodable {
        var strings: [String: [String: String]]
    }

    private static var loaded = false
    private static var table: [String: [String: String]] = [:]

    private static func load() {
        loaded = true
        guard let root = WebDisplayResources.directory,
              let data = try? Data(contentsOf: root.appendingPathComponent("l10n.json")) else { return }
        load(from: data)
    }

    private final class LockedChoice: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CourtLocaleChoice?
        var current: CourtLocaleChoice? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ choice: CourtLocaleChoice) { lock.lock(); value = choice; lock.unlock() }
        func clear() { lock.lock(); value = nil; lock.unlock() }
    }
}

/// The Simplified Chinese source is the catalog key. See `CourtCopy`.
public func courtText(_ source: String) -> String { CourtCopy.text(source) }

public func courtFormat(_ source: String, _ args: String...) -> String { CourtCopy.format(source, args) }

public func courtPrintf(_ pattern: String, _ args: CVarArg...) -> String { CourtCopy.printf(pattern, args) }

public enum CourtMeasure {
    /// Whole numbers. Simplified Chinese matches `String(value)` (no grouping separator).
    public static func integer(_ value: Int) -> String {
        if CourtCopy.language == .zhHans { return String(value) }
        return decimal(NSNumber(value: value), fraction: 0, grouping: true)
    }

    /// A fixed number of fraction digits. Simplified Chinese matches `String(format:)` with a dot.
    public static func fixed(_ value: Double, places: Int) -> String {
        if CourtCopy.language == .zhHans { return String(format: "%.\(places)f", value) }
        return decimal(NSNumber(value: value), fraction: places, grouping: false)
    }

    /// Ball speed stays kilometres per hour. The unit symbol `km/h` is drawn separately.
    public static func speedKPH(_ value: Double) -> String { fixed(value, places: 0) }

    private static func decimal(_ number: NSNumber, fraction: Int, grouping: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.locale = CourtCopy.formatLocale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = fraction
        formatter.maximumFractionDigits = fraction
        formatter.roundingMode = .halfUp
        return formatter.string(from: number) ?? number.stringValue
    }
}
