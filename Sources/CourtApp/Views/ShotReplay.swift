import SwiftUI
import CourtCore

/// How one shot can be replayed on this device (Phase 3 adds clips cut by the camera).
enum ShotReplay: Equatable {
    /// The session's recording is on this device: play it from 2 s before the hit.
    case recording(URL, seconds: Double, firstPTS: Double, duration: Double)
    /// A clip of this shot was already fetched.
    case clip(URL)
    /// The connected camera can cut a clip now.
    case fetchable
    case fetching(String)
    /// The last fetch of this shot failed; it can be retried.
    case failed(String)
    case unavailable

    var isLocalRecording: Bool { if case .recording = self { return true } else { return false } }
}

extension WorkspaceModel {
    func shotReplay(session: CourtSession?, shot: TennisShotEvent) -> ShotReplay {
        guard let session else { return .unavailable }
        if let recording = session.recordings.first(where: { $0.streamID == shot.streamID && shot.sourcePTS >= $0.firstPTS && shot.sourcePTS <= $0.firstPTS + $0.duration }) {
            let url = recordingURL(filename: recording.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return .recording(url, seconds: max(0, shot.sourcePTS - recording.firstPTS - 2), firstPTS: recording.firstPTS, duration: recording.duration)
            }
        }
        if let local = localClip(session: session.id, shot: shot.id) { return .clip(local) }
        // Only a camera-held session can be cut, and only by the camera this display is connected to.
        guard role == .server, session.capturedOn != nil, canFetchClips else { return .unavailable }
        if let clip, clip.shot == shot.id {
            if let error = clip.progress.error { return .failed(error) }
            if !clip.progress.done {
                let kb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
                return .fetching(clip.progress.total > 0 ? "正在取片段 \(kb(clip.progress.received)) / \(kb(clip.progress.total)) MB" : "机位正在剪片段…")
            }
        }
        return .fetchable
    }
    /// A clip or a recording transfer is in flight; the link sends one file at a time.
    var isFetchingFile: Bool {
        clip.map { !$0.progress.done && $0.progress.error == nil } == true || transfer.map { !$0.done && $0.error == nil } == true
    }
}

extension EnvironmentValues {
    /// Shot lists set this so each row ends in a 44-point icon instead of a full-width button and caption.
    @Entry var courtCompactShotReplay = false
}

/// Per-shot replay control: plays the local recording or clip, or asks the camera for a clip.
/// In a shot list (`courtCompactShotReplay`) it is one 44-point ▶ icon; the list explains the
/// clip size once instead of under every shot.
@MainActor
struct ShotReplayButton: View {
    let model: WorkspaceModel
    let session: CourtSession?
    let shot: TennisShotEvent
    let play: (PlaybackItem) -> Void
    @Environment(\.courtCompactShotReplay) private var compact

    var body: some View {
        let state = model.shotReplay(session: session, shot: shot)
        if state != .unavailable {
            if compact { compactBody(state) } else { fullBody(state) }
        }
    }

    private func fullBody(_ state: ShotReplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { activate(state) } label: { Label(title(state), systemImage: icon(state)).frame(maxWidth: .infinity) }
                .buttonStyle(CourtButton()).disabled(disabled(state))
                .accessibilityIdentifier("court.shot.replay")
            switch state {
            case .fetching(let text):
                HStack {
                    Text(text).font(.caption.monospacedDigit()).foregroundStyle(CourtStyle.muted)
                    Spacer()
                    CourtTextButton("取消", font: .caption) { model.cancelClip() }
                }
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(CourtStyle.muted)
            case .fetchable:
                Text(Self.clipNote).font(.caption2).foregroundStyle(CourtStyle.muted)
            default: EmptyView()
            }
        }
    }

    /// Said once above a shot list whose rows can fetch clips.
    static let clipNote = "机位剪出击球前后几秒，不重新编码，约 5 MB。"

    /// The icon alone. While a clip is on its way the icon becomes a spinner that cancels; a failed
    /// fetch shows a retry icon in the warning color, with the reason read out by VoiceOver.
    @ViewBuilder private func compactBody(_ state: ShotReplay) -> some View {
        switch state {
        case .fetching(let text):
            Button { model.cancelClip() } label: {
                ProgressView().frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(text + "，点按取消")
                .accessibilityIdentifier("court.shot.replay")
        default:
            Button { activate(state) } label: {
                HStack(spacing: CourtStyle.Space.xs) {
                    if stateIsFailure(state) { Text("未取到").font(.caption).foregroundStyle(CourtStyle.warning) }
                    Image(systemName: compactIcon(state)).font(.title2)
                        .foregroundStyle(stateIsFailure(state) ? CourtStyle.warning : CourtStyle.green)
                        .frame(width: 44, height: 44)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(disabled(state))
                .accessibilityLabel(title(state))
                .accessibilityHint(hint(state))
                .accessibilityIdentifier("court.shot.replay")
        }
    }
    private func compactIcon(_ state: ShotReplay) -> String {
        if case .failed = state { return "arrow.clockwise.circle" }
        return "play.circle"
    }
    private func stateIsFailure(_ state: ShotReplay) -> Bool { if case .failed = state { return true } else { return false } }
    private func hint(_ state: ShotReplay) -> String {
        switch state {
        case .failed(let reason): return reason
        case .fetchable: return Self.clipNote
        default: return ""
        }
    }

    private func title(_ state: ShotReplay) -> String {
        switch state {
        case .recording, .clip: return "回看这一拍"
        case .fetching: return "正在取片段…"
        case .failed: return "重试取片段"
        default: return "从机位取这一拍片段"
        }
    }
    private func icon(_ state: ShotReplay) -> String {
        switch state {
        case .recording, .clip: return "play.circle"
        case .fetching: return "hourglass"
        default: return "arrow.down.circle"
        }
    }
    private func disabled(_ state: ShotReplay) -> Bool {
        switch state {
        case .recording, .clip: return false
        case .fetching: return true
        default: return model.isFetchingFile
        }
    }
    private func activate(_ state: ShotReplay) {
        switch state {
        case .recording(let url, let seconds, let firstPTS, let duration):
            play(PlaybackItem(url: url, seconds: seconds, export: .shot(shot, session: session, recording: url, firstPTS: firstPTS, duration: duration)))
        case .clip(let url): play(PlaybackItem(url: url, export: .shot(shot, session: session, source: .file(url))))
        case .fetchable, .failed:
            guard let session else { return }
            Task {
                if let url = await model.fetchClip(session: session.id, shot: shot) {
                    play(PlaybackItem(url: url, export: .shot(shot, session: session, source: .file(url))))
                }
            }
        default: break
        }
    }

}
