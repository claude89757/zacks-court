import SwiftUI
import CourtCore

/// Every shot of the running record, newest first. The page shows only the latest few rows in a
/// plain stack (see `TennisAnalysisOverview.liveRowLimit`); this `List` has its own scroll and
/// reuses its rows, so a two-hour record with hundreds of shots stays cheap while data arrives.
@MainActor
struct CourtShotListSheet: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var playback: PlaybackItem?

    var body: some View {
        let events = model.shownEvents
        NavigationStack {
            List {
                Section {
                    ForEach(events.reversed()) { event in
                        TennisShotRow(event: event, selected: $selected, accessory: { shot in
                            AnyView(ShotReplayButton(model: model, session: model.session, shot: shot) { playback = $0 })
                        })
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: CourtStyle.Space.xs, leading: CourtStyle.Space.l,
                                                  bottom: CourtStyle.Space.xs, trailing: CourtStyle.Space.l))
                    }
                } header: {
                    Text(events.isEmpty ? courtText("还没有击球候选。") : courtFormat("%1$@ 个击球候选，最新的在最上面。点一拍看详情。", "\(events.count)"))
                        .font(.caption).foregroundStyle(CourtStyle.muted).textCase(nil)
                        .accessibilityIdentifier("court.shots.count")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.courtCompactShotReplay, true)
            .background(CourtStyle.background)
            .navigationTitle(courtText("全部击球"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { CourtTextButton(courtText("完成")) { dismiss() } } }
            .accessibilityIdentifier("court.shots.list")
        }
        .tint(CourtStyle.green).preferredColorScheme(.dark)
        .sheet(item: $playback) { item in RecordingPlayer(item: item) }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 560)
        #endif
    }
}
