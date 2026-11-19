import XCTest
import CourtCore

/// Language choice, Simplified Chinese identity, and catalog lookup. These do not measure tennis.
final class CourtCopyTests: XCTestCase {
    func testSimplifiedChineseStaysByteForByte() {
        XCTAssertEqual(CourtCopy.language, .zhHans)
        XCTAssertEqual(courtText("历史记录"), "历史记录")
        XCTAssertEqual(courtFormat("第 %1$@ 拍", "7"), "第 7 拍")
        XCTAssertEqual(courtPrintf("机高约 %.1f 米", 3.1), "机高约 3.1 米")
        XCTAssertEqual(CourtMeasure.fixed(12.5, places: 1), "12.5")
        XCTAssertEqual(CourtMeasure.integer(149), "149")
        XCTAssertEqual(CourtCopy.stored("周四晚"), "周四晚")
        XCTAssertEqual(CourtCopy.stored("示例记录 · 演示数据，非实测"), "示例记录 · 演示数据，非实测")
    }

    func testPreferredLanguageAndOverride() {
        XCTAssertEqual(CourtLocale.resolve(preferred: ["en-GB"]).language, .en)
        XCTAssertEqual(CourtLocale.resolve(preferred: ["en-GB"]).formatIdentifier, "en_GB")
        XCTAssertEqual(CourtLocale.resolve(preferred: ["en-US"]).formatIdentifier, "en_US")
        XCTAssertEqual(CourtLocale.resolve(preferred: ["en"]).formatIdentifier, "en_US")
        XCTAssertEqual(CourtLocale.resolve(preferred: ["zh-Hant-HK"]).language, .zhHant)
        XCTAssertEqual(CourtLocale.resolve(preferred: ["zh-HK"]).formatIdentifier, "zh_HK")
        XCTAssertEqual(CourtLocale.resolve(preferred: ["zh-TW"]).formatIdentifier, "zh_TW")
        XCTAssertEqual(CourtLocale.resolve(preferred: ["zh-CN"]).language, .zhHans)
        XCTAssertEqual(CourtLocale.resolve(preferred: ["ja-JP"]).language, .ja)
        XCTAssertEqual(CourtLocale.resolve(preferred: ["de-AT"]).formatIdentifier, "de_AT")
        XCTAssertEqual(CourtLocale.resolve(preferred: ["fr-CA"]).formatIdentifier, "fr_CA")
        XCTAssertEqual(CourtLocale.resolve(preferred: ["es-MX", "fr-FR"]).language, .fr)
        XCTAssertEqual(CourtLocale.resolve(preferred: ["es-MX"]).language, .en)
        XCTAssertEqual(CourtLocale.resolve(preferred: ["es-MX"]).formatIdentifier, "en_US")
        XCTAssertEqual(CourtLocale.resolve(preferred: []).language, .en)
        XCTAssertEqual(CourtLocale.resolve(preferred: ["pt-BR", "zh-Hans"]).language, .zhHans)
        XCTAssertEqual(CourtLocale.resolve(preferred: ["es-ES", "zh-Hant-TW"]).language, .zhHant)
        XCTAssertEqual(CourtLocale.resolve(preferred: [], environment: ["COURT_LANGUAGE": "de"]).language, .de)
        XCTAssertEqual(CourtLocale.resolve(preferred: ["en"], environment: ["COURT_LANGUAGE": "zh-Hant"]).language, .zhHant)
    }

    func testCatalogTranslatesAndRestoresChinese() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CourtCore/Web/l10n.json"))
        CourtCopy.load(from: data)
        try CourtCopy.withLanguage("en") {
            XCTAssertEqual(courtText("历史记录"), "History")
            XCTAssertEqual(courtText("机位"), "Camera")
            XCTAssertEqual(courtText("出界"), "Out")
            XCTAssertNotEqual(CourtCopy.stored("演示数据"), "演示数据")
            XCTAssertEqual(CourtCopy.stored("我的训练"), "我的训练")
            let speed = CourtMeasure.fixed(149, places: 0)
            XCTAssertEqual(speed, "149")
        }
        try CourtCopy.withLanguage("de") {
            XCTAssertEqual(CourtMeasure.fixed(1.5, places: 1), "1,5")
            XCTAssertEqual(courtText("发球"), "Aufschlag")
        }
        try CourtCopy.withLanguage("ja") {
            XCTAssertEqual(courtText("看板"), "ディスプレイ")
        }
        try CourtCopy.withLanguage("fr") {
            XCTAssertEqual(courtText("界内"), "In")
        }
        try CourtCopy.withLanguage("zh-Hant") {
            XCTAssertEqual(courtText("历史记录"), "歷史記錄")
            XCTAssertEqual(courtText("机位"), "機位")
        }
        XCTAssertEqual(courtText("历史记录"), "历史记录", "Leaving a language must not change the Chinese default")
        XCTAssertEqual(CourtMeasure.fixed(1.5, places: 1), "1.5")
    }

    func testMissingEntryFallsBackToChinese() {
        CourtCopy.withLanguage("en") {
            XCTAssertEqual(courtText("这条不在词表里"), "这条不在词表里")
        }
    }

    /// Before `activate()`, copy stays Simplified Chinese even though an unsupported language list
    /// would resolve to English. `withLanguage` does not leak into that default.
    func testStartupStaysChineseUntilActivation() throws {
        XCTAssertEqual(CourtCopy.language, .zhHans)
        XCTAssertEqual(courtText("机位"), "机位")
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CourtCore/Web/l10n.json"))
        CourtCopy.load(from: data)
        try CourtCopy.withLanguage("es-MX") {
            XCTAssertEqual(CourtCopy.language, .en)
            XCTAssertEqual(courtText("历史记录"), "History")
            XCTAssertEqual(CourtCopy.stored("示例记录 · 演示数据，非实测"), "Sample record · demo data, not a measurement")
            XCTAssertEqual(CourtCopy.stored("演示数据"), "Demo data")
            XCTAssertEqual(CourtCopy.stored("精彩"), "Highlight")
            XCTAssertEqual(CourtCopy.stored("我的上场"), "我的上场")
        }
        XCTAssertEqual(CourtCopy.language, .zhHans)
        XCTAssertEqual(courtText("机位"), "机位")
        CourtCopy.activate(preferred: ["ko-KR"], environment: [:])
        XCTAssertEqual(CourtCopy.language, .en)
        CourtCopy.resetActivationForTesting()
        XCTAssertEqual(CourtCopy.language, .zhHans)
        XCTAssertEqual(courtText("机位"), "机位")
    }
}
