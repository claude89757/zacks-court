import SwiftUI
import CourtCore

/// The three key numbers under the live picture. Each tile opens the same kind of view: the
/// metric full screen (测速牌, 落点看板, 动作分布), closed with one button.
struct TennisAnalysisNavigation: View {
    enum Target: String { case speed, placement, strokes }
    let events: [TennisShotEvent]
    let open: (Target) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : Array(repeating: GridItem(.flexible(), spacing: CourtStyle.Space.s), count: 3), spacing: CourtStyle.Space.s) {
            shortcut("球速", value: courtSpeed(events.last { $0.validSpeedKPH != nil }?.validSpeedKPH), caption: "km/h · 最近有效", target: .speed)
            shortcut("落点", value: events.isEmpty ? "—" : "\(events.filter { $0.bounce?.courtPosition != nil }.count)", caption: "拍有落点", target: .placement)
            shortcut("动作", value: events.last?.stroke.courtTitle ?? "—", caption: "最近一拍", target: .strokes)
        }
    }
    private func shortcut(_ title: String, value: String, caption: String, target: Target) -> some View {
        Button { open(target) } label: {
            VStack(alignment: .leading, spacing: CourtStyle.Space.xs) {
                HStack(spacing: CourtStyle.Space.xs) {
                    Text(title).font(.caption).foregroundStyle(CourtStyle.muted)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2).foregroundStyle(CourtStyle.muted)
                }
                Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(value == "—" ? CourtStyle.muted : CourtStyle.green)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(caption).font(.caption2).foregroundStyle(CourtStyle.muted).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(CourtStyle.Space.m)
                .background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.card).strokeBorder(CourtStyle.border))
                .contentShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
        }.buttonStyle(.plain).accessibilityLabel("放大" + title + "，" + value + "，" + caption)
            .accessibilityIdentifier("court.analysis.\(target.rawValue).open")
    }
}

extension TennisStrokeKind {
    var courtTitle: String {
        switch self {
        case .groundstroke: return "落地击球"
        case .forehand: return "正手"
        case .backhand: return "反手"
        case .serve: return "发球"
        case .volley: return "截击"
        case .overhead: return "高压"
        case .feed: return "喂球"
        case .unknown: return "待确认"
        }
    }
    /// Categorical stroke colors, validated for the dark panel surface (#131A16):
    /// every adjacent pair clears ΔE 8 under color-vision deficiency, and the
    /// first three clear it for every pair. The brand green stays reserved for
    /// UI accents, so a mark is never mistaken for a selection or a button.
    var courtColor: Color {
        switch self {
        case .forehand: return Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
        case .backhand: return Color(red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255)
        case .serve: return Color(red: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255)
        case .volley: return Color(red: 0xC9 / 255, green: 0x85 / 255, blue: 0x00 / 255)
        case .overhead: return Color(red: 0xD5 / 255, green: 0x51 / 255, blue: 0x81 / 255)
        case .groundstroke: return Color(red: 0x90 / 255, green: 0x85 / 255, blue: 0xE9 / 255)
        case .feed, .unknown: return CourtStyle.muted
        }
    }
}

struct TennisAnalysisStatus: View {
    let status: String
    let modelsAvailable: Bool
    let calibration: TennisCourtCalibrationState?
    let error: String?
    let isLive: Bool
    var limitations: [String] = []
    var recognition: RecognitionStatus?
    /// Content without its own panel, for a column that already sits on a panel (the camera sidebar).
    var embedded = false
    var body: some View {
        Group {
            if embedded {
                VStack(alignment: .leading, spacing: 14) { content }
            } else {
                CourtPanel("分析状态") { content }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("court.analysis.status")
    }
    @ViewBuilder private var content: some View {
            CourtStatus(text: error == nil ? status : "分析暂不可用",
                        tone: error != nil || !modelsAvailable ? .warning : isLive ? .live : .idle)
            if !modelsAvailable {
                CourtNotice(text: "分析模型尚未就绪。可以采集与保存录像，球速、落点和动作不会生成占位结果。", warning: true)
            }
            if let error { CourtNotice(text: error, warning: true).textSelection(.enabled) }
            if let recognition {
                RecognitionRows(status: recognition)
            } else if let calibration {
                Label(calibration.isAvailable ? "球场映射可用" : "球场映射未就绪", systemImage: calibration.isAvailable ? "checkmark.viewfinder" : "viewfinder")
                    .font(.callout.weight(.medium)).foregroundStyle(calibration.isAvailable ? CourtStyle.green : CourtStyle.warning)
                if !calibration.isAvailable || (calibration.reason ?? "").isEmpty {
                    Text("\(calibration.landmarkCount) 个场地参考点").font(.caption).foregroundStyle(CourtStyle.muted)
                }
                if let reason = calibration.reason, !reason.isEmpty { CourtNotice(text: reason, warning: !calibration.isAvailable) }
            } else {
                CourtNotice(text: isLive ? "正在等待场地地标；缺少球场映射时不在球场图上绘制落点。" : "连接固定机位后检查球场地标与分析质量。")
            }
            DisclosureGroup("数据口径") {
                VStack(alignment: .leading, spacing: 8) {
                    CourtNotice(text: "球速与落点为模型估算，球场映射可用不等于物理测速已校准。分类模型分数不是准确率，不确定的动作保留为待确认。")
                    if let residual = calibration?.validationErrorMeters, residual.isFinite {
                        CourtNotice(text: String(format: "球场映射拟合残差 %.2f m；这不是球速或落点的实测误差。", residual))
                    }
                    ForEach(Array(Set(limitations)).sorted(), id: \.self) { CourtNotice(text: $0) }
                }.padding(.top, 8)
            }.font(.caption).tint(CourtStyle.green)
    }
}

struct TennisAnalysisOverview: View {
    let events: [TennisShotEvent]
    var emptyReason = "等待可用击球样本"
    var calibration: TennisCourtCalibrationState?
    var historical = false
    /// Where the shots come from when that is not obvious (「上一次记录「…」」, 「未开始记录 · 最近几拍」).
    var sourceNote: String?
    var configureHandedness: (() -> Void)?
    /// Per-shot control at the end of each row (replay of the recording or a camera clip), drawn
    /// as a 44-point icon.
    var shotAccessory: ((TennisShotEvent) -> AnyView)?
    /// Said once above the shot rows, e.g. what fetching a clip costs.
    var shotNote: String?
    var timeLabel: ((TennisShotEvent) -> String?)?
    /// Live only: shots in the whole record (the overview may hold only the latest ones) and the
    /// list that shows them all, offered once the inline list cannot.
    var allShotCount: Int?
    var openAllShots: (() -> Void)?
    /// Rows the live list draws inline. More go to `openAllShots`, a lazy list of its own.
    static let liveRowLimit = 8
    /// Full-screen views behind the speed and placement panels' header links.
    var openSpeedBoard: (() -> Void)?
    var openPlacement: (() -> Void)?
    @State private var selectedShot: UUID?
    // Persisted input order spans streams whose independent PTS clocks may restart.
    private var ordered: [TennisShotEvent] { events }
    private var speeds: [Double] { events.compactMap(\.speedKPH).filter { $0.isFinite && $0 > 0 } }
    private var latest: TennisShotEvent? { ordered.last }

    var body: some View {
        VStack(spacing: CourtStyle.Space.l) {
            if historical && events.isEmpty {
                // A saved record without shots: say so once, not in four empty panels.
                CourtPanel("击球分析") { CourtNotice(text: emptyReason) }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("court.analysis.empty")
            } else {
                speedPanel
                placementPanel
                strokePanel
                timelinePanel
            }
        }
    }

    private var speedPanel: some View {
        CourtPanel("球速", accessory: {
            if let openSpeedBoard {
                CourtLinkButton(title: "测速牌", systemImage: "arrow.up.left.and.arrow.down.right", action: openSpeedBoard)
                    .accessibilityIdentifier("court.speedboard.open")
            }
        }) {
            CourtMetricGrid {
                CourtMetric(title: "最近一拍", value: speedText(latest?.speedKPH), unit: "km/h")
                CourtMetric(title: "有效平均", value: speedText(speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)), unit: "km/h")
                CourtMetric(title: "最高估算", value: speedText(speeds.max()), unit: "km/h")
            }
            if events.isEmpty { CourtNotice(text: emptyReason) }
            else {
                if let sourceNote { Text(sourceNote).font(.caption).foregroundStyle(CourtStyle.muted) }
                Text("\(speeds.count) 拍有球速 · \(events.count - speeds.count) 拍暂无球速")
                    .font(.caption).foregroundStyle(CourtStyle.muted)
                if let reason = latest?.speedReasonText { CourtNotice(text: "最近一拍：" + reason) }
            }
            CourtNotice(text: "模型估算 · 未完成物理准确率验证。平均与最高仅统计有效值，缺失值不按 0 计算。")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("court.analysis.speed").id("court.analysis.speed")
    }

    private var placementPanel: some View {
        CourtPanel("球场落点", accessory: {
            if let openPlacement {
                CourtLinkButton(title: "放大", systemImage: "arrow.up.left.and.arrow.down.right", action: openPlacement)
                    .accessibilityIdentifier("court.focus.placement.open")
            }
        }) {
            TennisCourtMap(events: ordered, selected: $selectedShot)
                .frame(maxHeight: 420)
            let mapped = events.filter { $0.bounce?.courtPosition != nil }.count
            if events.isEmpty {
                Text(panelEmptyText("出现击球后，落点会画在球场图上。")).font(.caption).foregroundStyle(CourtStyle.muted)
            } else if mapped == 0 {
                CourtNotice(text: unavailableBounceReason)
            } else {
                CourtStrokeLegend(events: events, placementsOnly: true, symbols: true)
                Text("\(mapped) 拍有落点 · \(events.count - mapped) 拍暂无落点")
                    .font(.caption).foregroundStyle(CourtStyle.muted)
            }
            CourtNotice(text: "俯视参考图，上方为远端。只画模型估计的落点；没有落点的击球不画点。界内外只在打开「界内外」后给出，也是模型估计，不是判罚。")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("court.analysis.placement").id("court.analysis.placement")
    }

    /// Each panel says what it will show; the shared reason appears once, in the speed panel.
    private func panelEmptyText(_ live: String) -> String { historical ? "本次记录没有可用的击球候选。" : live }

    private var unavailableBounceReason: String {
        if let calibration, !calibration.isAvailable { return "还没识别出球场，暂不画落点。" }
        return latest?.placementReasonText.map { "最近一拍：" + $0 } ?? "还没有落点。"
    }

    private var strokePanel: some View {
        CourtPanel("动作类别", accessory: {
            if let configureHandedness {
                CourtLinkButton(title: "持拍手", systemImage: "hand.raised", action: configureHandedness)
                    .accessibilityIdentifier("court.handedness.open")
            }
        }) {
            if events.isEmpty {
                Text(panelEmptyText("出现击球候选后，按动作类别统计拍数。")).font(.caption).foregroundStyle(CourtStyle.muted)
            } else {
                TennisStrokeDistribution(events: events)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("court.analysis.strokes").id("court.analysis.strokes")
    }

    private var timelinePanel: some View {
        CourtPanel(historical ? "逐拍回看" : "最近击球", accessory: {
            if !historical, let openAllShots, (allShotCount ?? events.count) > Self.liveRowLimit {
                CourtLinkButton(title: "全部 \(allShotCount ?? events.count) 拍", systemImage: "list.bullet", action: openAllShots)
                    .accessibilityIdentifier("court.analysis.all-shots")
            }
        }) {
            if events.isEmpty {
                Text(panelEmptyText("出现击球候选后，逐拍列出动作、球速与落点。")).font(.caption).foregroundStyle(CourtStyle.muted)
            } else {
                VStack(alignment: .leading, spacing: CourtStyle.Space.xs) {
                    Text("\(events.count) 个击球候选 · 点一拍在球场图上标出并看详情").font(.caption).foregroundStyle(CourtStyle.muted)
                        .accessibilityIdentifier("court.analysis.shot-count")
                    if let shotNote {
                        Label(shotNote, systemImage: "play.circle").font(.caption).foregroundStyle(CourtStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Group {
                    if historical {
                        // A saved record can hold hundreds of shots and does not change while shown.
                        LazyVStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                            ForEach(ordered) { shotRow($0) }
                        }
                    } else {
                        // Not lazy: rows grow when selected. With a LazyVStack nested in the page scroll
                        // the simulator display froze (main thread busy) after a row was expanded during
                        // live data; a plain stack did not. So the page draws a fixed few rows whatever
                        // the record's length, and 「全部 N 拍」 opens a `List` with its own scroll.
                        VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                            ForEach(Array(ordered.suffix(Self.liveRowLimit).reversed())) { shotRow($0) }
                        }
                    }
                }
                .environment(\.courtCompactShotReplay, true)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("court.analysis.timeline")
    }

    private func shotRow(_ event: TennisShotEvent) -> some View {
        TennisShotRow(event: event, selected: $selectedShot, time: timeLabel?(event), accessory: shotAccessory)
    }
}

/// Stroke counts as labelled bars (color dot plus name; the bar length repeats the count).
struct TennisStrokeDistribution: View {
    let events: [TennisShotEvent]
    var body: some View {
        VStack(alignment: .leading, spacing: CourtStyle.Space.m) {
            ForEach(TennisStrokeKind.allCases, id: \.self) { kind in
                let count = events.filter { $0.stroke == kind }.count
                if count > 0 {
                    VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                        HStack {
                            CourtStrokeTag(kind: kind)
                            Spacer()
                            Text("\(count) 拍").font(.callout.monospacedDigit()).foregroundStyle(CourtStyle.muted)
                        }
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 3).fill(CourtStyle.raised)
                            RoundedRectangle(cornerRadius: 3).fill(kind.courtColor)
                                .frame(width: geometry.size.width * Double(count) / Double(max(1, events.count)))
                        }.frame(height: 6).accessibilityHidden(true)
                    }.accessibilityElement(children: .combine)
                }
            }
            CourtNotice(text: "来自动作模型的分类候选。落地击球尚未区分正反手时，保留原类别；待确认样本计入总数。")
        }
    }
}

/// One shot in a list: stroke, speed and whether it has a landing spot on one line, then the
/// replay icon, plus one plain line naming what is missing (「球速：没看清球」). Tapping the row
/// selects it on the court map and shows the model score and the engine's own wording.
struct TennisShotRow: View {
    let event: TennisShotEvent
    @Binding var selected: UUID?
    var time: String?
    var accessory: ((TennisShotEvent) -> AnyView)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var isSelected: Bool { selected == event.id }
    private var hasPlacement: Bool { event.bounce?.courtPosition != nil }
    /// Plain wording for what this shot lacks, or nil when it has both values.
    private var missing: String? {
        let parts = [event.speedReasonText.map { "球速：" + $0 }, event.placementReasonText.map { "落点：" + $0 }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
            HStack(spacing: CourtStyle.Space.xs) {
                Button { selected = isSelected ? nil : event.id } label: {
                    summary.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(spokenSummary)
                    .accessibilityHint(isSelected ? "收起" : "在球场图上标出这一拍，并显示详情")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                if let accessory { accessory(event) }
            }
            if let missing {
                Text(missing).font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, CourtStyle.Space.s).padding(.bottom, isSelected ? 0 : CourtStyle.Space.s)
                    .accessibilityHidden(true)
            }
            if isSelected { details }
        }
        .padding(.leading, CourtStyle.Space.m).padding(.trailing, CourtStyle.Space.xs).padding(.vertical, CourtStyle.Space.xs)
        .background(isSelected ? CourtStyle.selectedFill : CourtStyle.inset, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.control).strokeBorder(isSelected ? CourtStyle.selectedStroke : CourtStyle.border))
    }

    @ViewBuilder private var summary: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: CourtStyle.Space.xs))
            : AnyLayout(HStackLayout(spacing: CourtStyle.Space.s))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: CourtStyle.Space.s) {
                    CourtStrokeTag(kind: event.stroke, font: .callout.weight(.semibold))
                    if event.origin == "offline" { Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(CourtStyle.muted) }
                }
                if let time { Text(time).font(.caption.monospacedDigit()).foregroundStyle(CourtStyle.muted) }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: CourtStyle.Space.s) }
            HStack(spacing: CourtStyle.Space.s) {
                Text(speedText(event.speedKPH) + " km/h").font(.callout.monospacedDigit())
                    .foregroundStyle(event.speedKPH == nil ? CourtStyle.muted : .white)
                Image(systemName: hasPlacement ? "scope" : "circle.dashed").font(.callout)
                    .foregroundStyle(hasPlacement ? CourtStyle.green : CourtStyle.muted).frame(width: 22)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: CourtStyle.Space.xs) {
            if event.origin == "offline" { Label("离线补算", systemImage: "wand.and.stars") }
            if hasPlacement { Label("落点已标在球场图", systemImage: "scope").foregroundStyle(CourtStyle.green) }
            // Model score and the engine's own wording, for the selected shot only.
            Text(shotDetails(event)).font(.caption2)
        }.font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, CourtStyle.Space.s).padding(.trailing, CourtStyle.Space.s)
    }

    private var spokenSummary: String {
        var parts = [event.stroke.courtTitle]
        if let time { parts.append(time) }
        if event.origin == "offline" { parts.append("离线补算") }
        parts.append(event.speedReasonText.map { "暂无球速，" + $0 } ?? (speedText(event.speedKPH) + " 千米每小时"))
        parts.append(event.placementReasonText.map { "暂无落点，" + $0 } ?? (hasPlacement ? "落点已标在球场图" : "暂无落点"))
        return parts.joined(separator: "，")
    }
}

private func speedText(_ value: Double?) -> String {
    guard let value, value.isFinite, value > 0 else { return "—" }
    return String(format: "%.0f", value)
}
private func scoreText(_ value: Double) -> String { value.isFinite ? String(format: "%.2f", min(1, max(0, value))) : "—" }
/// The selected shot's details: the classifier score (not an accuracy) and the engine's wording.
private func shotDetails(_ event: TennisShotEvent) -> String {
    var parts = ["分类模型分数 \(scoreText(event.confidence)) · \(event.sampleCount) 个样本"]
    if event.validSpeedKPH == nil, let detail = event.speedReason { parts.append("球速：" + detail) }
    if !event.hasCourtPlacement, let detail = event.bounce?.reason { parts.append("落点：" + detail) }
    return parts.joined(separator: "\n")
}

extension TennisBounceEstimate {
    var courtPosition: CGPoint? {
        guard let xMeters, let yMeters, xMeters.isFinite, yMeters.isFinite else { return nil }
        return CGPoint(x: xMeters, y: yMeters)
    }
}

struct TennisCourtMap: View {
    let events: [TennisShotEvent]
    @Binding var selected: UUID?
    private let courtWidth = 10.97
    private let courtLength = 23.77
    /// Mark radius: large enough to read courtside; the selected shot gets a bigger mark and a ring.
    private let markRadius = 6.5, selectedRadius = 9.5
    /// Shots with a landing spot, numbered by their place in `events` (the same 「拍次」 as the scatter).
    private var placed: [(number: Int, event: TennisShotEvent)] {
        events.enumerated().compactMap { index, event in event.bounce?.courtPosition == nil ? nil : (index + 1, event) }
    }
    var body: some View {
        VStack(spacing: 8) {
            Text("远端").font(.caption2).foregroundStyle(CourtStyle.muted)
            Canvas { context, size in
                guard size.width > 36, size.height > 36 else { return }
                let margin = 18.0
                let scale = min((size.width - margin * 2) / courtWidth, (size.height - margin * 2) / courtLength)
                let width = courtWidth * scale, height = courtLength * scale
                let origin = CGPoint(x: (size.width - width) / 2, y: (size.height - height) / 2)
                func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + (courtLength - y) * scale) }
                let rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
                context.fill(Path(rect), with: .color(CourtStyle.courtSurface))
                var lines = Path(rect)
                for x in [1.37, 9.60] { lines.move(to: point(x, 0)); lines.addLine(to: point(x, courtLength)) }
                for y in [5.485, 18.285] { lines.move(to: point(1.37, y)); lines.addLine(to: point(9.60, y)) }
                lines.move(to: point(5.485, 5.485)); lines.addLine(to: point(5.485, 18.285))
                context.stroke(lines, with: .color(CourtStyle.courtLine), lineWidth: 1.2)
                var net = Path(); net.move(to: point(-0.3, courtLength / 2)); net.addLine(to: point(courtWidth + 0.3, courtLength / 2))
                context.stroke(net, with: .color(CourtStyle.courtNet), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                // The selected shot is drawn last so no other mark covers it.
                let marks = placed.map(\.event)
                let ordered = marks.filter { $0.id != selected } + marks.filter { $0.id == selected }
                for event in ordered {
                    guard let position = event.bounce?.courtPosition else { continue }
                    let center = point(position.x, position.y)
                    guard center.x >= 4, center.y >= 4, center.x <= size.width - 4, center.y <= size.height - 4 else { continue }
                    let isSelected = selected == event.id
                    // Stroke shape (as in the speed scatter) and color: identity never relies on color alone.
                    let mark = event.stroke.courtMarkPath(center: center, radius: isSelected ? selectedRadius : markRadius)
                    context.fill(mark, with: .color(event.stroke.courtColor.opacity(selected == nil || isSelected ? 0.95 : 0.35)))
                    context.stroke(mark, with: .color(isSelected ? .white : .black.opacity(0.45)), lineWidth: isSelected ? 2 : 0.8)
                }
            }.overlay {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onTapGesture { location in
                        let size = geometry.size
                        let scale = min((size.width - 36) / courtWidth, (size.height - 36) / courtLength)
                        guard scale > 0 else { return }
                        let origin = CGPoint(x: (size.width - courtWidth * scale) / 2, y: (size.height - courtLength * scale) / 2)
                        let closest = events.compactMap { event -> (UUID, Double)? in
                            guard let point = event.bounce?.courtPosition else { return nil }
                            let center = CGPoint(x: origin.x + point.x * scale, y: origin.y + (courtLength - point.y) * scale)
                            return (event.id, hypot(center.x - location.x, center.y - location.y))
                        }.min { $0.1 < $1.1 }
                        selected = closest.flatMap { $0.1 <= 24 ? $0.0 : nil }
                    }
                }
            }.aspectRatio(0.65, contentMode: .fit)
                .background(CourtStyle.inset, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            Text("近端").font(.caption2).foregroundStyle(CourtStyle.muted)
        }.frame(maxWidth: .infinity)
            // One element that VoiceOver steps through shot by shot (swipe up / down), selecting each
            // bounce the way a tap does, so the shot list and details follow.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("球场落点参考图，\(placed.count) 拍有落点")
            .accessibilityValue(spokenSelection)
            .accessibilityHint(placed.isEmpty ? "" : "上下轻扫切换上一拍、下一拍")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(1)
                case .decrement: step(-1)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("court.map")
    }

    private var spokenSelection: String {
        guard let selected, let entry = placed.first(where: { $0.event.id == selected }) else {
            return placed.isEmpty ? "" : "未选择"
        }
        return entry.event.courtMapSpokenDescription(number: entry.number)
    }

    /// Next (1) or previous (-1) shot with a landing spot; from no selection, the first or the latest.
    private func step(_ offset: Int) {
        guard !placed.isEmpty else { return }
        let current = placed.firstIndex { $0.event.id == selected }
        let next: Int
        if let current { next = min(max(current + offset, 0), placed.count - 1) } else { next = offset > 0 ? 0 : placed.count - 1 }
        selected = placed[next].event.id
    }
}
