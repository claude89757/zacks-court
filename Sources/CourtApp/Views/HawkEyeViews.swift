import SwiftUI
import CourtCore

extension CourtStyle {
    // Line calls. Each always ships with its word (OUT / IN / CLOSE and the Chinese call).
    static let callOut = recording
    static let callIn = green
    static let callClose = warning
    static func callColor(_ call: HawkEyeCall) -> Color {
        switch call { case .out: return callOut; case .in: return callIn; case .close: return callClose }
    }
}

/// 「界内外」 toggle: turning it on asks singles or doubles first (the lines differ); when on it opens
/// the settings. The camera makes the calls; until it echoes new settings the button says so.
@MainActor
struct HawkEyeButton: View {
    let model: WorkspaceModel
    var compact = false
    @State private var askFormat = false
    @State private var showSettings = false

    private var settings: HawkEyeSettings { model.hawkEyePending ?? model.hawkEyeSettings }
    private var title: String { settings.enabled ? "界内外 · " + settings.format.text : "界内外" }

    var body: some View {
        Button {
            if settings.enabled { showSettings = true }
            else if let reason = model.hawkEyeUnavailableReason { model.error = reason }
            else { askFormat = true }
        } label: {
            Label(title, systemImage: settings.enabled ? "eye.fill" : "eye")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(settings.enabled ? CourtStyle.background : Color.white)
                .background(settings.enabled ? CourtStyle.green : CourtStyle.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settings.enabled ? "界内外已开启，\(settings.format.text)，\(settings.coverageText)" : "开启界内外")
        .accessibilityIdentifier("court.hawkeye.toggle")
        .confirmationDialog("开启界内外：本场是单打还是双打？", isPresented: $askFormat, titleVisibility: .visible) {
            ForEach(HawkEyeFormat.allCases, id: \.self) { format in
                Button(format.text) { model.setHawkEye(HawkEyeSettings(enabled: true, format: format, farHalf: false)) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("单打和双打的边线不同。默认只判近端半场（远端看得斜，误差大），可在界内外设置里打开远端。")
        }
        .sheet(isPresented: $showSettings) { HawkEyeSettingsSheet(model: model) }
    }
}

@MainActor
struct HawkEyeSettingsSheet: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    private var settings: HawkEyeSettings { model.hawkEyePending ?? model.hawkEyeSettings }
    private func update(_ change: (inout HawkEyeSettings) -> Void) {
        var next = settings; change(&next); model.setHawkEye(next)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CourtSegment(options: HawkEyeFormat.allCases,
                                 selection: Binding(get: { settings.format }, set: { f in update { $0.format = f } }),
                                 title: \.text, identifier: { "court.hawkeye.format.\($0.rawValue)" })
                    Toggle("也判远端半场", isOn: Binding(get: { settings.farHalf }, set: { v in update { $0.farHalf = v } }))
                        .frame(minHeight: 44).accessibilityIdentifier("court.hawkeye.far")
                    Toggle("出界时语音播报 Out!", isOn: Binding(get: { model.hawkEyeSound }, set: { model.hawkEyeSound = $0 }))
                        .frame(minHeight: 44).accessibilityIdentifier("court.hawkeye.sound")
                } footer: {
                    Text(settings.farHalf ? "远端落点看得斜，误差是近端的几倍，远端的判定更常显示「压线附近」。"
                                          : "只判近端半场：远端的落点误差大，默认不判。")
                }
                if model.hawkEyePending != nil {
                    Section { Label("等待机位确认…", systemImage: "hourglass").foregroundStyle(CourtStyle.muted) }
                }
                Section {
                    Button("关闭界内外", role: .destructive) { update { $0.enabled = false }; dismiss() }
                        .frame(minHeight: 44).accessibilityIdentifier("court.hawkeye.off")
                } footer: {
                    Text("界内外是单机位模型估计，不是判罚。落点离线不到误差范围时显示「压线附近」，不报出界；只有明确出界才播报 Out!。")
                }
            }
            .navigationTitle("界内外")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }
}

/// The call of the newest judged shot: a large OUT / IN / CLOSE with the call in words and how far
/// from the line the estimate fell. Tapping it closes it.
@MainActor
struct HawkEyeCallBanner: View {
    let alert: HawkEyeAlert
    var large = false
    var onClose: () -> Void = {}

    var body: some View {
        let j = alert.judgement, color = CourtStyle.callColor(j.call)
        Button(action: onClose) {
            HStack(spacing: large ? 20 : 12) {
                Text(j.call.shout)
                    .font(.system(size: large ? 64 : 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(j.call == .out ? Color.white : CourtStyle.background)
                    .padding(.horizontal, large ? 22 : 14).padding(.vertical, large ? 6 : 2)
                    .background(color, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                    .lineLimit(1).fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text("界内外 · " + j.call.text + (j.serve ? " · 发球" : ""))
                        .font(large ? .title2.weight(.bold) : .headline)
                    Text(j.detailText).font(large ? .body : .caption).foregroundStyle(CourtStyle.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(large ? 18 : 12)
            .frame(maxWidth: large ? 760 : 520)
            .background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.card).strokeBorder(color, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("界内外：\(j.call.text)，\(j.detailText)")
        .accessibilityHint("轻点关闭")
        .accessibilityIdentifier("court.hawkeye.call")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct HawkEyeBannerOverlay: ViewModifier {
    let model: WorkspaceModel
    var large = false
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if model.role == .server, let alert = model.hawkEyeAlert {
                HawkEyeCallBanner(alert: alert, large: large) { model.dismissHawkEyeAlert() }
                    .padding(.horizontal, CourtStyle.Space.l).padding(.top, CourtStyle.Space.s)
            }
        }
        .animation(.spring(duration: 0.3), value: model.hawkEyeAlert?.id)
    }
}

extension View {
    /// The display's line-call banner on top of this view.
    func courtHawkEyeBanner(model: WorkspaceModel, large: Bool = false) -> some View {
        modifier(HawkEyeBannerOverlay(model: model, large: large))
    }
}
