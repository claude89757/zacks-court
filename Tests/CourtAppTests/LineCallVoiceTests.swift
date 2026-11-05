import Foundation
import XCTest
import CourtCore

/// The line-call voices are listed twice (LineCallVoice.swift for the app, VOICES in Web/app.js for the
/// browser display); both play the same clips from Web/. These keep the lists and the files in step.
final class LineCallVoiceTests: XCTestCase {
    private let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/CourtCore/Web", isDirectory: true)

    func testDefaultIsMaleAshAndUnknownIdsFallBack() {
        XCTAssertEqual(LineCallVoice.voice(id: nil).id, "ash")
        XCTAssertEqual(LineCallVoice.voice(id: "removed-voice").id, "ash")
        XCTAssertEqual(LineCallVoice.voice(id: nil).gender, .male)
        XCTAssertEqual(LineCallVoice.voice(id: "coral").gender, .female)
        XCTAssertEqual(Set(LineCallVoice.all.map(\.gender)), [.male, .female])
        XCTAssertEqual(Set(LineCallVoice.all.map(\.id)).count, LineCallVoice.all.count)
        XCTAssertNil(LineCallVoice.voice(id: "ash").fileName(.close))
        XCTAssertNil(LineCallVoice.words(.close))
    }

    func testBrowserListMatchesTheApp() throws {
        let script = try String(contentsOf: web.appendingPathComponent("app.js"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"\{ id: "([a-z]+)", name: "([^"]+)", gender: "(male|female)" \}"#)
        let found = pattern.matches(in: script, range: NSRange(script.startIndex..., in: script)).map { match in
            (1...3).map { String(script[Range(match.range(at: $0), in: script)!]) }
        }
        XCTAssertEqual(found, LineCallVoice.all.map { [$0.id, $0.name, $0.gender.rawValue] })
        XCTAssertTrue(script.contains(#"const DEFAULT_VOICE = "\#(LineCallVoice.defaultID)";"#))
    }

    func testEveryVoiceHasBothClips() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: web.path)
        let clips = files.filter { $0.hasPrefix("voice-") && $0.hasSuffix(".m4a") }
        try XCTSkipIf(clips.isEmpty, "No line-call clips in Sources/CourtCore/Web yet (scripts/generate-line-call-voices.py).")
        let expected = LineCallVoice.all.flatMap { voice in [HawkEyeCall.out, .in].compactMap { voice.fileName($0) } }
        XCTAssertEqual(Set(clips), Set(expected), "clips in Web/ and LineCallVoice.all disagree")
    }
}
