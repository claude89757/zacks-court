import SwiftUI
import Charts
import CourtCore
#if os(macOS)
import AppKit
#endif

/// What the courtside board reads out. 「球速」 is the default and shows only the last
/// usable speed; 「发球」 adds serve-only statistics and a trend line. Labels on the board are
/// kept to numbers and short English abbreviations; VoiceOver gets full Chinese.
enum CourtSpeedBoardMode: String, CaseIterable, Identifiable {
    case all, serve
    var id: String { rawValue }
    var title: String { self == .all ? courtText("球速") : courtText("发球") }
    var spokenTitle: String { self == .all ? courtText("全部球速") : courtText("发球球速") }
}

/// A courtside readout: the last usable measurement stays visible until another
/// usable measurement arrives. It shares data with the dashboard, not its layout.
@MainActor
struct CourtSpeedBoard: View {
    let events: [TennisShotEvent]
    let isLive: Bool
    /// The display workspace: Hawk-Eye button and line-call banner. nil in layout tests.
    var model: WorkspaceModel? = nil
    /// Remembered per device, like the rest of the board's display choices.
    @AppStorage("court.speedboard.mode") private var modeValue = CourtSpeedBoardMode.all.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var challenge = false

    private var mode: CourtSpeedBoardMode { CourtSpeedBoardMode(rawValue: modeValue) ?? .all }
    private var hasData: Bool {
        mode == .all ? events.contains { $0.validSpeedKPH != nil } : TennisServeSummary(events: events).latest != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let inset = min(48, max(16, geometry.size.width * 0.035))
            VStack(spacing: 8) {
                header
                switch mode {
                case .all: AllSpeedReadout(events: events)
                case .serve: ServeSpeedReadout(summary: TennisServeSummary(events: events))
                }
            }
            .padding(inset)
        }
        .overlay(alignment: .bottom) {
            if let model, let alert = model.hawkEyeAlert {
                HawkEyeCallBanner(alert: alert, large: true) { model.dismissHawkEyeAlert() }
                    .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .animation(.spring(duration: 0.3), value: model?.hawkEyeAlert?.id)
        #if os(iOS)
        .fullScreenCover(isPresented: $challenge) { if let model { HawkEyeChallengeView(model: model) { challenge = false } } }
        #else
        .sheet(isPresented: $challenge) { if let model { HawkEyeChallengeView(model: model) { challenge = false }.frame(minWidth: 760, minHeight: 520) } }
        #endif
        .modifier(OptionalChallengeOverlay(model: model))
        .background(CourtStyle.background.ignoresSafeArea())
        .foregroundStyle(.white).preferredColorScheme(.dark)
        // The readout uses fixed, window-scaled sizes. Capping the surrounding labels at the second
        // accessibility size keeps them very large while the number keeps most of the board.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.focus.speed")
    }

    /// The mode switch doubles as the title. One row when it fits; at large text the live
    /// word goes first (the dot stays, VoiceOver still reads it), and only then does the
    /// switch move to its own row, so the readout keeps its share of the board.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                modePicker.fixedSize()
                Spacer(minLength: 8)
                liveStatus
                challengeButton
                hawkEyeButton
                closeButton
            }
            HStack(spacing: 14) {
                modePicker.fixedSize()
                Spacer(minLength: 8)
                liveDot
                challengeButton
                hawkEyeButton
                closeButton
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Spacer(minLength: 8)
                    liveStatus
                    challengeButton
                    hawkEyeButton
                    closeButton
                }
                modePicker
            }
        }.buttonStyle(.plain)
    }
    private var liveText: String { isLive ? courtText("实时") : hasData ? courtText("已停止") : "等待" }
    private var liveStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(isLive ? CourtStyle.green : CourtStyle.muted).frame(width: 7, height: 7)
            Text(liveText).font(.callout).foregroundStyle(CourtStyle.muted).lineLimit(1).fixedSize()
        }.accessibilityElement(children: .combine)
    }
    private var liveDot: some View {
        Circle().fill(isLive ? CourtStyle.green : CourtStyle.muted).frame(width: 7, height: 7)
            .accessibilityElement().accessibilityLabel(liveText)
    }
    /// 「挑战」 while the camera can take one; 「回放」 (step through judged and challenged shots) once a
    /// shot was judged or challenged.
    @ViewBuilder private var challengeButton: some View {
        if let model {
            if model.canChallenge { ChallengeButton(model: model).fixedSize() }
            if events.contains(where: { $0.lineCall != nil || $0.challenge != nil }) {
                Button { model.dismissHawkEyeAlert(); challenge = true } label: {
                    Label(courtText("回放"), systemImage: "play.rectangle.on.rectangle")
                        .font(.callout.weight(.semibold)).lineLimit(1)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(CourtStyle.raised, in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).fixedSize()
                .accessibilityLabel(courtText("界内外回放"))
                .accessibilityIdentifier("court.speedboard.challenge")
            }
        }
    }
    @ViewBuilder private var hawkEyeButton: some View {
        if let model, model.canUseHawkEye { HawkEyeButton(model: model).fixedSize() }
    }
    @ViewBuilder private var closeButton: some View {
        #if os(macOS)
        SpeedBoardFullScreenButton().frame(width: 44, height: 44)
        #else
        Button { dismiss() } label: {
            Image(systemName: "xmark").frame(width: 44, height: 44)
                .background(CourtStyle.raised, in: Circle()).contentShape(Circle())
        }.accessibilityLabel(courtText("关闭测速牌"))
        #endif
    }
    /// Two 44-point segments; a system segmented control is shorter than the touch minimum.
    private var modePicker: some View {
        CourtSegment(options: CourtSpeedBoardMode.allCases,
                     selection: Binding(get: { mode }, set: { modeValue = $0.rawValue }),
                     title: \.title, spokenTitle: \.spokenTitle,
                     identifier: { "court.speedboard.mode.\($0.rawValue)" })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(courtText("测速牌显示内容"))
            .accessibilityIdentifier("court.speedboard.mode")
    }
}

/// 「球速」: the last usable speed of any stroke fills the board; one caption line below it.
private struct AllSpeedReadout: View {
    let events: [TennisShotEvent]
    private var latestIndex: Int? { events.lastIndex { $0.validSpeedKPH != nil } }
    private var latest: TennisShotEvent? { latestIndex.map { events[$0] } }
    /// The shot's position in the rows shown, like the serve number in 「发球」.
    private var shotNumber: Int? { latestIndex.map { $0 + 1 } }
    private var measurementStatus: String {
        guard let latest, let shotNumber else { return courtText("等待有效击球") }
        if events.last?.validSpeedKPH == nil { return courtFormat("#%1$@ · 本拍暂无球速 · 保留上一有效值", "\(shotNumber)") }
        return courtFormat("#%1$@ · 最近有效球速 · ", "\(shotNumber)") + latest.stroke.courtTitle
    }
    var body: some View {
        VStack(spacing: 6) {
            SpeedHero(speed: latest?.validSpeedKPH, shot: latest?.id, label: courtText("最近有效球速"),
                      value: latest?.validSpeedKPH.map { courtSpeed($0) + courtFormat(" 千米每小时，第 %1$@ 拍", "\(shotNumber ?? 0)") } ?? courtText("等待有效击球"))
            SpeedBoardFooter(status: measurementStatus)
        }
    }
}

/// Size of the large number for a readout area. The digits are sized by their cap height, not the
/// line box, so they fill the area; the width always allows three digits, so a 96 never looks larger
/// than a 156 and the size does not jump between readings. The unit goes beside the number when
/// that leaves the digits larger, otherwise underneath.
struct SpeedHeroLayout: Equatable {
    /// SF Pro Condensed bold, monospaced digits, per point of font size (measured). Condensed digits
    /// are about 30 % taller than the rounded ones in the same width, and most boards are width-bound.
    static let capHeight: CGFloat = 0.705
    static let digitAdvance: CGFloat = 0.502
    /// Ascender above the cap height and descender below the baseline, trimmed from the line box.
    static let aboveCap: CGFloat = 0.262, belowBaseline: CGFloat = 0.211
    /// "km/h" in SF Pro medium, width per point of its font size.
    static let unitAdvance: CGFloat = 2.18
    static let digits: CGFloat = 3
    /// Room for the brief 4 % lift of a new reading.
    static let fill: CGFloat = 0.92

    let size: CGFloat
    let unitSize: CGFloat
    let unitBelow: Bool

    static func unitSize(for size: CGFloat) -> CGFloat { min(44, max(16, size * 0.09)) }
    static func gap(for size: CGFloat) -> CGFloat { max(6, size * 0.035) }

    init(_ area: CGSize) {
        let height: CGFloat = max(1, area.height * Self.fill), width: CGFloat = max(1, area.width * 0.98)
        // Beside: the widest size whose digits, gap and unit fit the width (the unit's size is clamped,
        // so search rather than solve).
        var low: CGFloat = 1, high: CGFloat = height / Self.capHeight
        for _ in 0..<24 {
            let mid: CGFloat = (low + high) / 2
            let needed: CGFloat = Self.digits * Self.digitAdvance * mid + Self.gap(for: mid) + Self.unitAdvance * Self.unitSize(for: mid)
            if needed <= width { low = mid } else { high = mid }
        }
        let beside: CGFloat = low
        // Below: the unit line and a gap come off the height.
        var below: CGFloat = min(height / Self.capHeight, width / (Self.digits * Self.digitAdvance))
        for _ in 0..<3 {
            let unitLine: CGFloat = Self.unitSize(for: below) * 1.25 + Self.gap(for: below)
            below = min((height - unitLine) / Self.capHeight, width / (Self.digits * Self.digitAdvance))
        }
        unitBelow = below > beside * 1.04
        size = max(24, unitBelow ? below : beside)
        unitSize = Self.unitSize(for: size)
    }
}

/// The large number, sized to fill whatever area it is given. It is one accessibility element covering
/// the whole area (the UI tests measure that area), read as `label` and `value`.
private struct SpeedHero: View {
    let speed: Double?
    let shot: UUID?
    let label: String
    let value: String
    var body: some View {
        GeometryReader { area in
            let layout = SpeedHeroLayout(area.size)
            SpeedFigure(speed: speed, layout: layout, shot: shot)
                .frame(width: area.size.width, height: area.size.height)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(value)
                .accessibilityIdentifier("court.speedboard.readout")
        }
    }
}

/// The large number with its unit. A missing value is a thin muted placeholder at reading
/// scale: a heavy green dash at this size reads as a solid bar, not "no reading yet".
/// A new reading (keyed on its shot, so a repeat of the same speed still counts) rolls the digits
/// and lights up briefly, with a light tap on iOS. Reduce Motion keeps only the brief highlight.
private struct SpeedFigure: View {
    let speed: Double?
    let layout: SpeedHeroLayout
    /// The shot the reading belongs to.
    var shot: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if speed == nil {
                // The thin placeholder sits at reading scale with its unit, not at the full size.
                HStack(alignment: .firstTextBaseline, spacing: SpeedHeroLayout.gap(for: layout.size)) { number; unit }
            } else if layout.unitBelow {
                VStack(alignment: .trailing, spacing: SpeedHeroLayout.gap(for: layout.size)) { number; unit }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: SpeedHeroLayout.gap(for: layout.size)) { number; unit }
            }
        }
        // Only on the board, and only for a usable reading: a light tap someone holding the phone
        // courtside can feel without looking.
        .sensoryFeedback(trigger: shot) { _, new in new == nil ? nil : .impact(weight: .light, intensity: 0.5) }
    }

    /// The digits' frame is trimmed to their cap height, so layout and centering follow the glyphs.
    private var trim: EdgeInsets {
        let size: CGFloat = layout.size
        return EdgeInsets(top: -size * SpeedHeroLayout.aboveCap, leading: 0, bottom: -size * SpeedHeroLayout.belowBaseline, trailing: 0)
    }

    @ViewBuilder private var number: some View {
        let size: CGFloat = layout.size
        if let speed {
            Text(courtSpeed(speed))
                .font(.system(size: size, weight: .bold).width(.condensed).monospacedDigit())
                .foregroundStyle(CourtStyle.green)
                .contentTransition(reduceMotion ? .identity : .numericText(value: speed))
                .animation(reduceMotion ? nil : .snappy, value: shot)
                .lineLimit(1).fixedSize()
                .padding(trim)
                .phaseAnimator([false, true], trigger: shot) { content, lit in
                    content
                        .scaleEffect(lit && !reduceMotion ? 1.04 : 1)
                        .shadow(color: CourtStyle.green.opacity(lit ? 0.55 : 0), radius: lit ? size * 0.12 : 0)
                        .background(CourtStyle.selectedFill.opacity(lit ? 1 : 0),
                                    in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card).inset(by: -size * 0.06))
                } animation: { lit in lit ? .easeOut(duration: 0.12) : .easeIn(duration: 0.7) }
                .accessibilityIdentifier("court.speedboard.value")
        } else {
            Text("--")
                .font(.system(size: size * 0.45, weight: .ultraLight).monospacedDigit())
                .foregroundStyle(CourtStyle.muted)
                .lineLimit(1).fixedSize()
                .accessibilityIdentifier("court.speedboard.value")
        }
    }

    private var unit: some View {
        Text("km/h")
            .font(.system(size: layout.unitSize, weight: .medium))
            .foregroundStyle(speed == nil ? CourtStyle.muted : .white.opacity(0.85)).fixedSize()
    }
}

/// The caption line under the number: what the number is, and that it is an estimate.
private struct SpeedBoardFooter: View {
    let status: String
    var spoken: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(status)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityLabel(spoken ?? status)
                .accessibilityIdentifier("court.speedboard.status")
            Spacer(minLength: 8)
            Text(courtText("模型估算")).fixedSize()
                .accessibilityLabel(courtText("模型估算，不是测量"))
        }.font(.footnote).foregroundStyle(CourtStyle.muted)
    }
}

/// 「发球」: the current serve speed fills the board like 「球速」. Statistics are one line and the trend
/// is a thin strip under it: beside each other on a wide board, stacked on a tall one, and the strip
/// is dropped on a short board.
private struct ServeSpeedReadout: View {
    let summary: TennisServeSummary
    /// The statistics never drop below the reader's text size (capped at accessibility2 by the board).
    @ScaledMetric(relativeTo: .callout) private var minimumStatSize: CGFloat = 16

    /// Short on-board label: the serve number, plus a marker while an older value is held.
    private var status: String {
        guard let latest = summary.latest else { return summary.serveCount == 0 ? courtText("等待发球") : courtText("无有效球速") }
        return summary.isHoldingPreviousValue ? courtFormat("#%1$@ · 本发无速", "\(latest.serveNumber)") : "#\(latest.serveNumber)"
    }
    /// Full sentence for VoiceOver; the board itself stays mostly numbers.
    private var spokenStatus: String {
        guard let latest = summary.latest else {
            return summary.serveCount == 0 ? courtText("等待有效发球") : courtFormat("已识别 %1$@ 个发球，暂无有效球速", "\(summary.serveCount)")
        }
        let count = courtFormat("本场 %1$@ 个发球，%2$@ 个有球速", "\(summary.serveCount)", "\(summary.points.count)")
        if summary.isHoldingPreviousValue { return courtFormat("最新一发暂无球速，保留第 %1$@ 个发球的有效值，", "\(latest.serveNumber)") + count }
        return courtFormat("第 %1$@ 个发球，", "\(latest.serveNumber)") + count
    }

    var body: some View {
        GeometryReader { geometry in
            let width: CGFloat = geometry.size.width, height: CGFloat = geometry.size.height
            let layout = ServeBandLayout(width: width, height: height)
            VStack(spacing: 6) {
                hero
                Group {
                    if layout.sideBySide {
                        HStack(spacing: 16) {
                            stats(size: max(layout.statSize, minimumStatSize)).fixedSize()
                            Spacer(minLength: 8)
                            if layout.showsTrend { trend.frame(width: width * 0.32, height: layout.trendHeight) }
                        }
                    } else {
                        VStack(spacing: 6) {
                            stats(size: max(layout.statSize, minimumStatSize)).frame(maxWidth: .infinity)
                            if layout.showsTrend { trend.frame(height: layout.trendHeight) }
                        }
                    }
                }
                SpeedBoardFooter(status: status, spoken: spokenStatus)
            }
        }
    }

    private var hero: some View {
        SpeedHero(speed: summary.latest?.speedKPH, shot: summary.latest?.id, label: courtText("当前发球球速"),
                  value: summary.latest.map { courtSpeed($0.speedKPH) + courtText(" 千米每小时，") + spokenStatus } ?? spokenStatus)
    }

    /// MAX / AVG / MIN on one line: labels muted, values in body ink. Unknown stays 「—」, never 0.
    private func stats(size: CGFloat) -> some View {
        let items: [(title: String, spoken: String, value: Double?)] = [
            ("MAX", courtText("最高"), summary.maximumSpeed), ("AVG", courtText("平均"), summary.averageSpeed), ("MIN", courtText("最低"), summary.minimumSpeed)
        ]
        return HStack(alignment: .firstTextBaseline, spacing: size * 0.9) {
            ForEach(items, id: \.title) { (item: (title: String, spoken: String, value: Double?)) in
                HStack(alignment: .firstTextBaseline, spacing: size * 0.3) {
                    Text(item.title).font(.system(size: size * 0.6, weight: .medium)).foregroundStyle(CourtStyle.muted)
                    Text(courtSpeed(item.value))
                        .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(item.value == nil ? CourtStyle.muted : .white)
                }
            }
        }
        .lineLimit(1).minimumScaleFactor(0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.map { (item: (title: String, spoken: String, value: Double?)) -> String in
            courtFormat("发球%1$@ ", "\(item.spoken)") + (item.value.map { courtSpeed($0) + courtText(" 千米每小时") } ?? courtText("暂无"))
        }.joined(separator: "，"))
        .accessibilityIdentifier("court.speedboard.serve.stats")
    }

    private var trend: some View {
        ServeTrendChart(points: summary.points, average: summary.averageSpeed)
    }
}

/// Where the serve statistics and trend go, from the readout's size.
struct ServeBandLayout: Equatable {
    let sideBySide: Bool
    let showsTrend: Bool
    let trendHeight: CGFloat
    let statSize: CGFloat
    init(width: CGFloat, height: CGFloat) {
        sideBySide = width >= 560 && width >= height
        // Below this a strip of a few dots says little from courtside; the number keeps the room.
        showsTrend = height >= 280 && width >= 280
        trendHeight = min(84, max(36, height * 0.09))
        statSize = min(30, max(15, min(height, width) * 0.04))
    }
}

/// A thin strip of serve speeds in serve order, without axes: earlier serves faint, the current one
/// in the accent (the same value as the large number), the average dashed. The key sits beside it.
struct ServeTrendChart: View {
    let points: [TennisServeSummary.Point]
    let average: Double?
    /// Enough history to see a trend without crowding the strip.
    static let visibleLimit = 30

    var body: some View {
        let shown = Array(points.suffix(Self.visibleLimit))
        HStack(spacing: 10) {
            if shown.isEmpty {
                Rectangle().fill(CourtStyle.inset).frame(height: 1).frame(maxWidth: .infinity)
            } else {
                plot(shown)
                key(shown: shown)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(courtText("发球球速趋势"))
        .accessibilityValue(shown.isEmpty ? courtText("暂无有效发球球速") : courtFormat("最近 %1$@ 个有效发球，", "\(shown.count)") + shown.suffix(5).map { courtSpeed($0.speedKPH) }.joined(separator: "、") + courtText(" 千米每小时"))
        .accessibilityIdentifier("court.speedboard.serve.chart")
    }

    private func key(shown: [TennisServeSummary.Point]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) { Circle().fill(CourtStyle.green).frame(width: 7, height: 7); Text("NOW") }
            if average != nil {
                HStack(spacing: 5) {
                    Path { $0.move(to: .init(x: 0, y: 1)); $0.addLine(to: .init(x: 12, y: 1)) }
                        .stroke(CourtStyle.muted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).frame(width: 12, height: 2)
                    Text("AVG")
                }
            }
            if points.count > shown.count { Text("LAST \(shown.count)") }
        }
        .font(.caption2).foregroundStyle(CourtStyle.muted).lineLimit(1).fixedSize()
    }

    private func plot(_ shown: [TennisServeSummary.Point]) -> some View {
        let speeds: [Double] = shown.map(\.speedKPH)
        let low: Double = max(0, (speeds.min() ?? 0) - 5)
        let high: Double = (speeds.max() ?? 100) + 5
        let first: Int = shown.first?.serveNumber ?? 1, last: Int = shown.last?.serveNumber ?? 1
        let lastID = shown.last?.id
        return Chart {
            if let average {
                RuleMark(y: .value(courtText("平均"), average))
                    .foregroundStyle(CourtStyle.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            ForEach(shown) { (point: TennisServeSummary.Point) in
                LineMark(x: .value(courtText("发球序号"), point.serveNumber), y: .value("km/h", point.speedKPH))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                PointMark(x: .value(courtText("发球序号"), point.serveNumber), y: .value("km/h", point.speedKPH))
                    .foregroundStyle(point.id == lastID ? CourtStyle.green : Color.white.opacity(0.6))
                    .symbolSize(point.id == lastID ? 70 : 14)
            }
        }
        // Half a serve of room each side keeps the current point inside the strip.
        .chartXScale(domain: Double(first) - 0.5 ... Double(last) + 0.5)
        .chartYScale(domain: low...high)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

#if os(macOS)
@MainActor
private struct SpeedBoardFullScreenButton: NSViewRepresentable {
    func makeNSView(context: Context) -> ToggleButton {
        let button = ToggleButton()
        button.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        button.contentTintColor = .white
        button.isBordered = false
        button.title = ""
        button.target = button
        button.action = #selector(ToggleButton.toggle)
        button.toolTip = courtText("切换全屏测速牌")
        button.setAccessibilityLabel(courtText("切换全屏"))
        return button
    }
    func updateNSView(_ view: ToggleButton, context: Context) {}

    final class ToggleButton: NSButton {
        @objc func toggle() {
            prepareWindow()
            window?.toggleFullScreen(self)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            prepareWindow()
        }
        private func prepareWindow() {
            // A single SwiftUI Window scene can reset its auxiliary role during
            // transitions. Reapply the primary behavior before either direction.
            guard let window else { return }
            window.collectionBehavior.remove([.fullScreenAuxiliary, .fullScreenNone])
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
    }
}
#endif

/// The challenge overlay when the board has a model (the Mac's board window and the full-screen board).
private struct OptionalChallengeOverlay: ViewModifier {
    let model: WorkspaceModel?
    func body(content: Content) -> some View {
        if let model { content.courtChallengeOverlay(model: model) } else { content }
    }
}
