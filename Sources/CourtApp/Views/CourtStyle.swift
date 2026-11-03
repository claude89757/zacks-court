import SwiftUI
import CourtCore

/// Design tokens shared by every Mac and iPhone surface. Views use these
/// instead of literal colors, radii or opacities so the two apps stay in step.
enum CourtStyle {
    // Brand and surfaces
    static let green = Color(red: 0.76, green: 0.94, blue: 0.35)
    static let background = Color(red: 0.035, green: 0.055, blue: 0.046)
    static let panel = Color(red: 0.075, green: 0.10, blue: 0.085)
    static let muted = Color(red: 0.60, green: 0.67, blue: 0.62)
    static let border = Color.white.opacity(0.09)
    /// Tiles, chips and secondary buttons that sit on a panel.
    static let raised = Color.white.opacity(0.05)
    /// Inputs, rows and plot backgrounds recessed into a panel.
    static let inset = Color.black.opacity(0.2)

    // Semantic colors. Each one always ships with an icon or a label.
    static let warning = Color.orange
    static let recording = Color.red
    /// Background of an error banner or another warning surface.
    static let warningFill = warning.opacity(0.08)

    // Selection
    /// A selected row or card (a shot in a list, a session in history).
    static let selectedFill = green.opacity(0.10)
    static let selectedStroke = green.opacity(0.5)
    /// The selected option of a `CourtSegment`, on its `raised` track.
    static let segmentSelected = Color.white.opacity(0.14)

    // Overlays
    /// Behind controls and text drawn on top of a video picture.
    static let scrim = Color.black.opacity(0.55)
    /// Covers the whole page while a blocking task (saving, closing) runs.
    static let blockingScrim = background.opacity(0.75)

    // Court diagram (the top-down placement map). The browser display uses the same values.
    static let courtSurface = Color(red: 0.055, green: 0.16, blue: 0.13)
    static let courtLine = Color.white.opacity(0.55)
    static let courtNet = Color.white.opacity(0.8)

    enum Radius {
        static let panel: CGFloat = 22
        static let card: CGFloat = 16
        static let control: CGFloat = 13
        static let field: CGFloat = 11
    }

    /// Spacing steps for stacks and padding. New layout uses only these.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}

struct CourtPanel<Accessory: View, Content: View>: View {
    var title: String?
    var eyebrow: String?
    var fillHeight = false
    var accessory: Accessory
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize
    /// `accessory` sits at the right of the title row: one `CourtLinkButton` or a 44-point icon button.
    init(_ title: String? = nil, eyebrow: String? = nil, fillHeight: Bool = false,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title; self.eyebrow = eyebrow; self.fillHeight = fillHeight
        self.accessory = accessory(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: CourtStyle.Space.l) {
            // Decorative English eyebrows repeat the Chinese title; VoiceOver skips them. Kept faint
            // so they never compete with the title or the data.
            if let eyebrow { Text(eyebrow).font(.caption2.weight(.medium)).tracking(1.5).foregroundStyle(CourtStyle.muted).accessibilityHidden(true) }
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .center, spacing: CourtStyle.Space.s) {
                    if let title { Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader) }
                    Spacer(minLength: CourtStyle.Space.s)
                    accessory
                }
                // The accessory brings its own 44-point height; the title row does not grow by it.
                .padding(.vertical, Accessory.self == EmptyView.self ? 0 : -CourtStyle.Space.s)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        // Accessibility sizes give the text the width: a phone keeps about six large characters per line.
        .padding(typeSize.isAccessibilitySize ? CourtStyle.Space.l : CourtStyle.Space.xl)
        .background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.panel).strokeBorder(CourtStyle.border))
    }
}

extension CourtPanel where Accessory == EmptyView {
    init(_ title: String? = nil, eyebrow: String? = nil, fillHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title, eyebrow: eyebrow, fillHeight: fillHeight, accessory: { EmptyView() }, content: content)
    }
}

/// One choice out of a few, as 44-point segments on a `raised` track: the speed board's modes and
/// the camera sidebar's pages. Falls back to a column when the labels do not fit (large text).
struct CourtSegment<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var spokenTitle: ((Option) -> String)?
    var identifier: (Option) -> String
    /// Stretch to the available width (equal segments) instead of hugging the labels.
    var fill = true
    /// Off when the caller picks the layout itself, e.g. a row inside its own `ViewThatFits`.
    var allowsColumn = true

    var body: some View {
        if allowsColumn {
            ViewThatFits(in: .horizontal) {
                track(HStackLayout(spacing: 2))
                // Not lazy: segments below the fold must exist for VoiceOver and UI tests.
                track(VStackLayout(spacing: 2), column: true)
            }
        } else {
            track(HStackLayout(spacing: 2))
        }
    }

    /// In the column a label wider than the screen (largest text, narrow phone) wraps or shrinks a
    /// little instead of pushing the page wider than the window.
    private func track(_ layout: some Layout, column: Bool = false) -> some View {
        AnyLayout(layout) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option)).font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(column ? 2 : 1).minimumScaleFactor(column ? 0.75 : 1)
                        .multilineTextAlignment(.center).fixedSize(horizontal: !column, vertical: true)
                        .padding(.horizontal, CourtStyle.Space.l)
                        .frame(maxWidth: fill ? .infinity : nil, minHeight: 44)
                        .foregroundStyle(selected ? Color.white : CourtStyle.muted)
                        .background(selected ? CourtStyle.segmentSelected : Color.clear,
                                    in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control - 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spokenTitle?(option) ?? title(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(identifier(option))
            }
        }
        .padding(3)
        .background(CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
    }
}

struct CourtButton: ButtonStyle {
    var primary = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 17).padding(.vertical, 12)
            .frame(minHeight: 46)
            .foregroundStyle(primary ? CourtStyle.background : destructive ? CourtStyle.warning : Color.white)
            .background(primary ? CourtStyle.green : CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.control).strokeBorder(primary ? Color.clear : CourtStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
    }
}

/// One button of a bottom control bar: icon above a short label, equal widths, at least 52 pt tall.
/// Same colors as `CourtButton`. Bars use it only at regular text sizes; accessibility sizes put
/// the same commands back into the page as `CourtButton`s.
struct CourtBarButton: ButtonStyle {
    var primary = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(CourtVerticalLabel())
            .font(.caption.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(primary ? CourtStyle.background : destructive ? CourtStyle.warning : Color.white)
            .background(primary ? CourtStyle.green : CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.control).strokeBorder(primary ? Color.clear : CourtStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
    }
}

private struct CourtVerticalLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: CourtStyle.Space.xs) {
            configuration.icon.font(.body)
            configuration.title
        }
    }
}

/// A text-only action inside a panel header, e.g. 「打开测速牌」. The whole
/// 44-point row is the hit target, not just the glyphs.
struct CourtLinkButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(CourtStyle.green)
    }
}

struct CourtStatus: View {
    /// live = data is flowing, idle = waiting on the user or the other device,
    /// warning = something needs attention.
    enum Tone { case live, idle, warning }
    var text: String
    var tone: Tone
    init(text: String, tone: Tone) { self.text = text; self.tone = tone }
    init(text: String, active: Bool = false) { self.init(text: text, tone: active ? .live : .idle) }
    private var color: Color {
        switch tone { case .live: return CourtStyle.green; case .idle: return CourtStyle.muted; case .warning: return CourtStyle.warning }
    }
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .background(CourtStyle.raised, in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct CourtMetric: View {
    let title: String
    let value: String
    var unit = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(CourtStyle.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title2.weight(.medium).monospacedDigit())
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(CourtStyle.muted) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .accessibilityElement(children: .combine)
    }
}

/// A grid of `CourtMetric` tiles: as many columns as fit at `minimum` width, one column at
/// accessibility text sizes, where two tiles side by side broke 「记录时长」 and 「km/h」 into
/// one or two characters per line.
struct CourtMetricGrid<Content: View>: View {
    var minimum: CGFloat = 130
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: minimum), spacing: CourtStyle.Space.s)],
                  alignment: .leading, spacing: CourtStyle.Space.s) { content }
    }
}

struct CourtNotice: View {
    let text: String
    var warning = false
    var body: some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
            .font(.caption).foregroundStyle(warning ? CourtStyle.warning : CourtStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CourtErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CourtNotice(text: text, warning: true).textSelection(.enabled)
            Button(action: dismiss) {
                Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("关闭错误提示")
        }
        .padding(.leading, 16).padding(.vertical, 6).padding(.trailing, 6)
        .background(CourtStyle.warningFill, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
    }
}

/// A neutral, dismissible line for a notice (record switched, backfill done, record deleted). Pinned
/// beside `CourtErrorBanner` on every surface; `WorkspaceModel` clears the notice after a reading time.
struct CourtNoticeBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: CourtStyle.Space.m) {
            CourtNotice(text: text).textSelection(.enabled)
            Button(action: dismiss) {
                Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(CourtStyle.muted).accessibilityLabel("关闭提示")
        }
        .padding(.leading, CourtStyle.Space.l).padding(.vertical, 6).padding(.trailing, 6)
        .background(CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.notice")
    }
}

/// The error and notice banners of a page, in one place so every surface stacks them the same way.
struct CourtBanners: View {
    let model: WorkspaceModel
    var body: some View {
        if let error = model.error { CourtErrorBanner(text: error) { model.error = nil } }
        if let notice = model.notice {
            CourtNoticeBanner(text: notice) { model.notice = nil }
                .transition(.opacity)
        }
    }
}

/// Colored dot plus the stroke name in text ink. Identity never relies on color alone.
struct CourtStrokeTag: View {
    let kind: TennisStrokeKind
    var font: Font = .callout
    /// The court map's legend shows the stroke's mark shape instead of a dot.
    var symbol = false
    var body: some View {
        HStack(spacing: 7) {
            if symbol { CourtStrokeMark(kind: kind, size: 12) } else { Circle().fill(kind.courtColor).frame(width: 8, height: 8) }
            Text(kind.courtTitle).font(font)
        }
    }
}

/// Legend for every chart or court map that colors marks by stroke.
struct CourtStrokeLegend: View {
    let events: [TennisShotEvent]
    var placementsOnly = false
    /// Show each stroke's mark shape (court map) instead of a dot.
    var symbols = false
    private var kinds: [TennisStrokeKind] {
        let present = Set(events.filter { !placementsOnly || $0.hasCourtPlacement }.map(\.stroke))
        return TennisStrokeKind.allCases.filter(present.contains)
    }
    var body: some View {
        if !kinds.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(kinds, id: \.self) { CourtStrokeTag(kind: $0, font: .caption, symbol: symbols).foregroundStyle(CourtStyle.muted) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("图例：" + kinds.map(\.courtTitle).joined(separator: "、"))
        }
    }
}

extension View {
    /// The dark input field used for every free-text entry on both platforms.
    func courtField() -> some View {
        textFieldStyle(.plain).padding(.horizontal, 13).padding(.vertical, 11).frame(minHeight: 44)
            .background(CourtStyle.inset, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.field).strokeBorder(CourtStyle.border))
    }

    /// Pages without a navigation bar otherwise scroll their content beneath
    /// the iPhone status bar text.
    @ViewBuilder func courtStatusBarScrim() -> some View {
        #if os(iOS)
        overlay(alignment: .top) {
            CourtStyle.background
                .ignoresSafeArea(edges: .top)
                .frame(height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }
}

func courtDuration(_ seconds: Double) -> String {
    let value = Int(max(0, seconds))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%02d:%02d", value / 60, value % 60)
}

extension SessionState {
    var courtTitle: String {
        switch self { case .active: return "进行中"; case .paused: return "已暂停"; case .completed: return "已完成"; case .interrupted: return "意外中断" }
    }
    var courtTone: CourtStatus.Tone {
        switch self { case .active, .completed: return .live; case .paused, .interrupted: return .warning }
    }
}

struct PersonOverlay: View {
    let snapshot: AnalysisSnapshot
    var body: some View {
        Canvas { context, size in
            for person in snapshot.people {
                let box = CGRect(x: person.box.x * size.width, y: person.box.y * size.height,
                                 width: person.box.width * size.width, height: person.box.height * size.height)
                let color = person.isMoving ? CourtStyle.green : Color.cyan
                context.stroke(Path(roundedRect: box, cornerRadius: 4), with: .color(color), lineWidth: 2)
                var trail = Path()
                for (i, point) in person.trail.enumerated() {
                    let position = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    if i == 0 { trail.move(to: position) } else { trail.addLine(to: position) }
                }
                context.stroke(trail, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                let label = Text(String(person.id.uuidString.prefix(4))).font(.caption2.monospaced().bold()).foregroundColor(color)
                context.draw(label, at: CGPoint(x: box.minX + 4, y: max(10, box.minY - 9)), anchor: .leading)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
