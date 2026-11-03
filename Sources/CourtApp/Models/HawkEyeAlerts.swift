import Foundation
import AVFoundation
import CourtCore

/// The latest line call to show on a display: one per shot, raised when the camera's call first
/// arrives. A later revision of the same shot updates it silently.
struct HawkEyeAlert: Equatable, Identifiable {
    let id: UUID              // shot
    var judgement: HawkEyeJudgement
    var stroke: TennisStrokeKind
    var raisedAt: Date
}

/// Display bookkeeping for line calls: which shots were already announced, the banner on screen and
/// the "Out!" voice. Calls only reach a display from the camera; this never judges anything itself.
@MainActor final class HawkEyeAlerts {
    /// How long a call stays on screen.
    static let lifetime: Duration = .seconds(4)
    /// Calls older than this (by the row's own time against the newest row) are not announced: a
    /// display that reconnects should not shout past calls.
    static let staleSeconds = 8.0
    private var announced = Set<UUID>()
    private let voice = HawkEyeVoice()

    /// The alert to raise for these rows, if any: the newest unannounced call. `current` is updated in
    /// place when its shot's call changed. Returns (new alert or updated current, speak).
    func next(for rows: [TennisShotEvent], current: HawkEyeAlert?, soundOn: Bool) -> HawkEyeAlert? {
        var result = current
        let newest = rows.map(\.sourcePTS).max() ?? 0
        for row in rows.sorted(by: { $0.sourcePTS < $1.sourcePTS }) {
            guard let call = row.bounce?.hawkEye else { continue }
            if let c = result, c.id == row.id {
                result?.judgement = call; announced.insert(row.id); continue
            }
            guard !announced.contains(row.id) else { continue }
            announced.insert(row.id)
            guard newest - row.sourcePTS <= Self.staleSeconds else { continue }
            result = HawkEyeAlert(id: row.id, judgement: call, stroke: row.stroke, raisedAt: Date())
            if call.call == .out, soundOn { voice.sayOut() }
        }
        return result
    }

    /// Rows already on the display when it (re)connects: remembered, never announced.
    func markSeen(_ rows: [TennisShotEvent]) {
        for row in rows where row.bounce?.hawkEye != nil { announced.insert(row.id) }
    }
}

/// Speaks "Out!" in English like an electronic line-calling system. On iPhone it uses the playback
/// audio category so the ring/silent switch does not mute it, and ducks other audio while speaking.
@MainActor final class HawkEyeVoice {
    private let synthesizer = AVSpeechSynthesizer()
    private var prepared = false

    func sayOut() {
        prepare()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: "Out!")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.1
        utterance.volume = 1
        synthesizer.speak(utterance)
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        #endif
    }
}
