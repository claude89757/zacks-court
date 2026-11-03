import SwiftUI
import CourtCore

/// The record state the haptics follow: on the display the mirror changes only when the camera
/// echoes its session, so a change here is a confirmed change, never just a tap.
struct RecordFeedbackKey: Equatable {
    var id: UUID?
    var state: SessionState?
    var markers = 0
    /// Started within the last few seconds: a record joined later (a camera reconnecting with its
    /// running record) is not a start.
    var fresh = false

    init(_ session: CourtSession?, now: Date = Date()) {
        id = session?.id; state = session?.state
        markers = session?.events.reduce(0) { $0 + ($1.kind == .marker ? 1 : 0) } ?? 0
        fresh = session.map { abs(now.timeIntervalSince($0.startedAt)) < 10 } ?? false
    }

    /// What a change from `old` to `new` should feel like (iOS; Mac and older devices ignore it).
    static func feedback(from old: RecordFeedbackKey, to new: RecordFeedbackKey) -> SensoryFeedback? {
        guard let id = new.id, let state = new.state else { return nil }
        guard old.id == id else { return state == .active && new.fresh ? .impact(weight: .medium) : nil }
        if old.state != state {
            switch state {
            case .active: return .impact(weight: .medium)
            case .paused: return .impact(weight: .light)
            case .completed: return .impact(weight: .heavy)
            case .interrupted: return .warning
            }
        }
        return new.markers > old.markers ? .success : nil
    }
}

extension WorkspaceModel {
    /// The camera's own record on the camera, the mirrored one on a display.
    var recordFeedbackKey: RecordFeedbackKey { RecordFeedbackKey(controller?.session ?? session) }
}

private struct CourtSessionFeedback: ViewModifier {
    let model: WorkspaceModel
    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: model.recordFeedbackKey) { old, new in RecordFeedbackKey.feedback(from: old, to: new) }
            // Capture started or stopped on the camera (by the user, or when the camera opens itself).
            .sensoryFeedback(trigger: model.camera.streaming) { _, streaming in
                model.role == .camera ? .impact(weight: streaming ? .medium : .light) : nil
            }
    }
}

extension View {
    /// Haptics for confirmed record changes (start, pause, resume, finish, a marker) and for capture.
    func courtSessionFeedback(model: WorkspaceModel) -> some View { modifier(CourtSessionFeedback(model: model)) }
}
