import Foundation

/// A voice for the line calls ("Out!" for a clear out, "Out!" / "In." for a challenge verdict). Each
/// voice is two recorded clips, `voice-<id>-out.m4a` and `voice-<id>-in.m4a`, in CourtCore's `Web`
/// folder, so the app and the browser display play the same files. The clips are AI-generated
/// (OpenAI gpt-4o-mini-tts, provenance in docs/hawk-eye.md), not a human recording, and the settings
/// say so. The browser display keeps its own copy of this list in `Web/app.js` (`VOICES`); a test
/// checks the two agree and every clip exists.
public struct LineCallVoice: Identifiable, Hashable, Sendable {
    public enum Gender: String, Sendable, CaseIterable {
        case male, female
        public var text: String { self == .male ? courtText("男声") : courtText("女声") }
    }

    public let id: String
    public let name: String
    public let gender: Gender

    /// More voices (Onyx, Marin, Nova, Sage) follow once their clips are generated.
    public static let all: [LineCallVoice] = [
        LineCallVoice(id: "ash", name: "Ash", gender: .male),
        LineCallVoice(id: "cedar", name: "Cedar", gender: .male),
        LineCallVoice(id: "verse", name: "Verse", gender: .male),
        LineCallVoice(id: "coral", name: "Coral", gender: .female),
    ]
    public static let defaultID = "ash"

    /// The voice with this id; an unknown or missing id (a removed voice, an older setting) is the default.
    public static func voice(id: String?) -> LineCallVoice {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }

    /// The clip's file name in the web resource folder; a close call is shown, never said.
    public func fileName(_ call: HawkEyeCall) -> String? {
        switch call {
        case .out: "voice-\(id)-out.m4a"
        case .in: "voice-\(id)-in.m4a"
        case .close: nil
        }
    }

    /// What the clip says, for the speech-synthesis fallback when the clip is missing.
    public static func words(_ call: HawkEyeCall) -> String? {
        switch call {
        case .out: "Out!"
        case .in: "In."
        case .close: nil
        }
    }
}
