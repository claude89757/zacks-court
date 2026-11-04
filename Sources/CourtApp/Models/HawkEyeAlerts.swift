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

    /// Calls a challenge's verdict ("Out!" or "In.").
    func say(_ call: HawkEyeCall) { voice.say(call) }

    /// The voice the calls use (setting 「语音」).
    var callVoice: LineCallVoice {
        get { voice.voice }
        set { voice.voice = newValue }
    }

    /// Rows already on the display when it (re)connects: remembered, never announced.
    func markSeen(_ rows: [TennisShotEvent]) {
        for row in rows where row.bounce?.hawkEye != nil { announced.insert(row.id) }
    }
}

/// Calls "Out!" / "In." in English like an electronic line-calling system, in the chosen
/// `LineCallVoice`: plays that voice's recorded clips from CourtCore's `Web` folder (the browser display
/// plays the same files) and falls back to speech synthesis when a clip is missing. Only the chosen
/// voice's two clips are loaded. On iPhone it uses the playback audio category so the ring/silent
/// switch does not mute it, and ducks other audio while calling.
@MainActor final class HawkEyeVoice {
    /// The chosen voice; changing it drops the loaded clips so the next call loads the new ones.
    var voice = LineCallVoice.voice(id: nil) {
        didSet { if voice != oldValue { for player in players.values { player.pause() }; players = [:]; loaded = false } }
    }

    private lazy var synthesizer = AVSpeechSynthesizer()
    private var players: [HawkEyeCall: AVAudioPlayer] = [:]
    private var sessionReady = false
    private var loaded = false

    func sayOut() { say(.out) }

    func say(_ call: HawkEyeCall) {
        guard let words = LineCallVoice.words(call) else { return }
        prepare()
        guard let player = players[call] else { speak(words); return }
        // pause() rather than stop(): stop() drops the buffers prepareToPlay() filled.
        for other in players.values where other !== player { other.pause() }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        player.pause()
        player.currentTime = 0
        player.play()
    }

    /// Fallback when the recorded clip is not bundled.
    private func speak(_ text: String) {
        for player in players.values { player.pause() }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.1
        utterance.volume = 1
        synthesizer.speak(utterance)
    }

    private func prepare() {
        if !sessionReady {
            sessionReady = true
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
            try? session.setActive(true)
            #endif
        }
        // Loaded on the first call (and after a voice change), after the audio session is set, so opening
        // the app never touches the user's music; each clip is a few kilobytes, so this adds no audible delay.
        guard !loaded else { return }
        loaded = true
        guard let root = WebDisplayResources.directory else { return }
        for call in [HawkEyeCall.out, .in] {
            guard let name = voice.fileName(call),
                  let player = try? AVAudioPlayer(contentsOf: root.appendingPathComponent(name)) else { continue }
            player.prepareToPlay()
            players[call] = player
        }
    }
}
