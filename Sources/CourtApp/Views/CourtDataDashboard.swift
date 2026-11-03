import SwiftUI
import Charts
import CourtCore

public enum CourtMetricKind: String, Identifiable {
    case speed, placement, strokes
    public var id: String { rawValue }
    var title: String {
        switch self { case .speed: return "球速"; case .placement: return "落点"; case .strokes: return "动作" }
    }
}

func courtSpeed(_ value: Double?) -> String {
    guard let value, value.isFinite, value > 0 else { return "—" }
    return String(format: "%.0f", value)
}

extension TennisStrokeKind {
    /// Secondary encoding for scatter marks so stroke identity never relies on color alone.
    var courtSymbol: BasicChartSymbolShape {
        switch self {
        case .forehand: return .circle
        case .backhand: return .square
        case .serve: return .triangle
        case .volley: return .diamond
        case .overhead: return .pentagon
        case .groundstroke: return .cross
        case .feed: return .plus
        case .unknown: return .asterisk
        }
    }
}

struct TennisSpeedChart: View {
    let events: [TennisShotEvent]
    var xAxisTitle = "拍次"
    private struct Point: Identifiable {
        let id: UUID
        let index: Int
        let speed: Double
        let kind: TennisStrokeKind
    }
    var body: some View {
        let points = events.enumerated().compactMap { index, event in
            event.validSpeedKPH.map { Point(id: event.id, index: index + 1, speed: $0, kind: event.stroke) }
        }
        if points.isEmpty {
            VStack(spacing: CourtStyle.Space.s) {
                Image(systemName: "chart.dots.scatter").font(.title3).foregroundStyle(CourtStyle.muted)
                Text("有效球速出现后，这里显示逐拍趋势").font(.caption).foregroundStyle(CourtStyle.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(CourtStyle.inset, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .accessibilityElement(children: .combine)
        } else {
            // Colors and shapes follow the stroke, never its rank in this result set.
            let kinds = TennisStrokeKind.allCases.filter { kind in points.contains { $0.kind == kind } }
            Chart(points) { point in
                PointMark(x: .value(xAxisTitle, point.index), y: .value("km/h", point.speed))
                    .foregroundStyle(by: .value("动作", point.kind.courtTitle))
                    .symbol(by: .value("动作", point.kind.courtTitle))
                    .symbolSize(60)
            }
            .chartForegroundStyleScale(domain: kinds.map(\.courtTitle), range: kinds.map(\.courtColor))
            .chartSymbolScale(domain: kinds.map(\.courtTitle), range: kinds.map(\.courtSymbol))
            .chartLegend(position: .bottom, alignment: .leading, spacing: CourtStyle.Space.s)
            .chartYScale(domain: 0...max(100, (points.map(\.speed).max() ?? 0) * 1.15))
            .chartXAxisLabel(xAxisTitle).chartYAxisLabel("km/h")
            .frame(height: 175).accessibilityLabel("逐拍球速趋势，仅包含有可用球速的拍次")
        }
    }
}

struct LiveSpeedReadout: View {
    let events: [TennisShotEvent]
    var fontSize: CGFloat = 100
    private var latest: TennisShotEvent? { events.last }
    var body: some View {
        let summary = TennisEventSummary(events: events)
        VStack(alignment: .leading, spacing: CourtStyle.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: CourtStyle.Space.s) {
                if let speed = summary.latestValidSpeed?.validSpeedKPH {
                    Text(courtSpeed(speed))
                        .font(.system(size: fontSize, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(CourtStyle.green).minimumScaleFactor(0.4).lineLimit(1)
                        .accessibilityIdentifier("court.speed.readout")
                } else {
                    // A full-size dash in brand green reads as a filled bar, not "no value".
                    Text("--")
                        .font(.system(size: fontSize * 0.5, weight: .light).monospacedDigit())
                        .foregroundStyle(CourtStyle.muted).lineLimit(1)
                        .accessibilityLabel("暂无有效球速")
                        .accessibilityIdentifier("court.speed.readout")
                }
                Text("km/h").font(.title3).foregroundStyle(CourtStyle.muted)
            }
            if let latest {
                Text("最近有效球速" + (summary.latestValidSpeed.map { " · " + $0.stroke.courtTitle } ?? " · 等待样本")).font(.callout)
                if latest.validSpeedKPH == nil {
                    Text("最近一拍暂无球速" + (summary.latestValidSpeed == nil ? "" : "，保留上一有效值")).font(.caption).foregroundStyle(CourtStyle.muted)
                    Text(latest.speedReasonText ?? "还在分析").font(.caption).foregroundStyle(CourtStyle.muted)
                }
            } else { Text("等待可用击球").font(.callout).foregroundStyle(CourtStyle.muted) }
            if summary.count > 0 {
                HStack(spacing: CourtStyle.Space.xl) {
                    Label("平均 " + courtSpeed(summary.averageSpeed), systemImage: "chart.bar")
                    Label("最高 " + courtSpeed(summary.maximumSpeed), systemImage: "arrow.up")
                }.font(.callout.monospacedDigit()).foregroundStyle(CourtStyle.muted)
                Text("\(summary.speedCount) / \(summary.count) 拍有球速 · 模型估算")
                    .font(.caption).foregroundStyle(CourtStyle.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Separate native Mac windows share the workspace; enlarging data never mounts
/// another video surface or starts another decoder/model pipeline.
@MainActor
public struct CourtMetricFocus: View {
    let model: WorkspaceModel
    let metric: CourtMetricKind
    @State private var showDetails = false
    @State private var scale = 1.0
    @State private var selected: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(model: WorkspaceModel, metric: CourtMetricKind) { self.model = model; self.metric = metric }
    /// Page padding: accessibility sizes give the width to the text.
    private var pagePadding: CGFloat { dynamicTypeSize.isAccessibilitySize ? CourtStyle.Space.l : CourtStyle.Space.xxl }
    /// Title and buttons in one row; when they do not fit (largest text) the buttons go above the
    /// title, so 「落点看板」 never breaks one character per line.
    private func focusHeader<Controls: View>(_ title: String, systemImage: String, @ViewBuilder controls: () -> Controls) -> some View {
        let controls = controls()
        return ViewThatFits(in: .horizontal) {
            HStack { Label(title, systemImage: systemImage).font(.headline); Spacer(); controls }
            VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                HStack { Spacer(); controls }
                Label(title, systemImage: systemImage).font(.headline).accessibilityAddTraits(.isHeader)
            }
        }.buttonStyle(.plain)
    }
    public var body: some View {
        switch metric {
        case .speed: speedBoard
        case .placement: placementFocus
        case .strokes: strokesFocus
        }
    }
    @ViewBuilder private var speedBoard: some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            CourtSpeedBoard(events: model.shownEvents, isLive: model.isLive, model: model)
                .windowFullScreenBehavior(.enabled)
        } else {
            CourtSpeedBoard(events: model.shownEvents, isLive: model.isLive, model: model)
        }
        #else
        CourtSpeedBoard(events: model.shownEvents, isLive: model.isLive, model: model)
        #endif
    }
    /// Stroke distribution full screen, opened from the 「动作」 tile like the other two metrics.
    private var strokesFocus: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CourtStyle.Space.xl) {
                focusHeader("动作分布", systemImage: "figure.tennis") {
                    #if os(iOS)
                    CourtTextButton("完成") { dismiss() }
                    #endif
                }
                CourtStatus(text: model.shownEventsStatus.text, tone: model.shownEventsStatus.tone)
                let events = model.shownEvents
                if events.isEmpty {
                    CourtNotice(text: "出现击球候选后，按动作类别统计拍数。")
                } else {
                    Text("\(events.count) 拍 · 最近一拍 " + (events.last?.stroke.courtTitle ?? "—")).font(.title2.monospacedDigit())
                    TennisStrokeDistribution(events: events)
                    Toggle("显示逐拍明细", isOn: $showDetails).frame(minHeight: 44)
                    if showDetails { RecentShotRows(events: events, selected: $selected) }
                }
            }.padding(pagePadding).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.background(CourtStyle.background).foregroundStyle(.white).tint(CourtStyle.green).preferredColorScheme(.dark)
            .accessibilityIdentifier("court.focus.\(metric.rawValue)")
    }
    private var placementFocus: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: CourtStyle.Space.xl) {
                    focusHeader("落点看板", systemImage: "scope") {
                        Button { scale = max(0.6, scale - 0.15) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .disabled(scale <= 0.6).accessibilityLabel("缩小球场图").help("缩小球场图")
                        Button { scale = min(1.6, scale + 0.15) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .disabled(scale >= 1.6).accessibilityLabel("放大球场图").help("放大球场图")
                        #if os(iOS)
                        CourtTextButton("完成") { dismiss() }
                        #endif
                    }
                    CourtStatus(text: model.shownEventsStatus.text, tone: model.shownEventsStatus.tone)
                    TennisCourtMap(events: model.shownEvents, selected: $selected)
                        .frame(height: min(850, max(250, geometry.size.height * 0.64 * scale)))
                    CourtStrokeLegend(events: model.shownEvents, placementsOnly: true, symbols: true)
                    Text("\(TennisEventSummary(events: model.shownEvents).placementCount) 拍有落点")
                        .font(.title2.monospacedDigit())
                    Text("点落点查看对应拍次（读屏：上下轻扫逐拍）；仅显示有位置依据的数据。")
                        .font(.caption).foregroundStyle(CourtStyle.muted)
                    Toggle("显示逐拍明细", isOn: $showDetails).frame(minHeight: 44)
                    if showDetails {
                        RecentShotRows(events: model.shownEvents, selected: $selected)
                    }
                }.padding(pagePadding).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }
        }.background(CourtStyle.background).foregroundStyle(.white).tint(CourtStyle.green).preferredColorScheme(.dark)
            .accessibilityIdentifier("court.focus.\(metric.rawValue)")
    }
}

struct RecentShotRows: View {
    let events: [TennisShotEvent]
    @Binding var selected: UUID?
    var limit = 12
    var body: some View {
        LazyVStack(spacing: CourtStyle.Space.s) {
            ForEach(Array(events.suffix(limit).reversed())) { event in
                Button { selected = selected == event.id ? nil : event.id } label: {
                    HStack {
                        CourtStrokeTag(kind: event.stroke)
                        Spacer()
                        Text(courtSpeed(event.validSpeedKPH) + " km/h").monospacedDigit()
                        Image(systemName: event.hasCourtPlacement ? "scope" : "minus").foregroundStyle(CourtStyle.muted)
                            .accessibilityLabel(event.hasCourtPlacement ? "有落点" : "暂无落点")
                    }.padding(CourtStyle.Space.m).frame(minHeight: 46)
                        .background(selected == event.id ? CourtStyle.selectedFill : CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                        .contentShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                }.buttonStyle(.plain)
            }
        }
    }
}

#if os(macOS)
/// The Mac display: a header row, errors and notices under it, then two columns at every window
/// width (the window is at least 760 pt wide): the data on the left; the picture, the record
/// controls and 「机位与分析」 on the right. Each column scrolls on its own, so the record controls
/// never scroll away behind the picture. Without a camera the data column is one connect prompt,
/// as on the iPhone.
@MainActor
struct CourtDesktopDashboard: View {
    let model: WorkspaceModel
    let pairing: () -> Void
    let history: () -> Void
    /// History opened on one record (「查看详情」 on the end-of-record summary).
    let openRecord: (UUID) -> Void
    let handedness: () -> Void
    let leave: () -> Void
    let finish: () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var selected: UUID?
    @State private var showPeople = false
    @State private var clipPlayback: PlaybackItem?
    @State private var showAllShots = false
    var body: some View {
        GeometryReader { geometry in
            let roomy = geometry.size.width >= 1050
            let sidebar: CGFloat = roomy ? 310 : 280
            let gap = roomy ? CourtStyle.Space.xl : CourtStyle.Space.l
            let padding = roomy ? CourtStyle.Space.xl : CourtStyle.Space.l
            VStack(alignment: .leading, spacing: CourtStyle.Space.l) {
                header
                // Errors and notices sit under the header, not at the end of a scrolling column.
                VStack(spacing: CourtStyle.Space.s) { CourtBanners(model: model) }
                    .animation(.default, value: model.notice)
                HStack(alignment: .top, spacing: gap) {
                    ScrollView {
                        dataColumn(wide: geometry.size.width - 2 * padding - gap - sidebar >= 700)
                    }.accessibilityIdentifier("court.workspace.scroll")
                    ScrollView { sideColumn }.frame(width: sidebar)
                }
            }.padding(padding)
        }.background(CourtStyle.background)
    }

    /// The same words as the iPhone display's connection pill.
    private var connectionTitle: String {
        model.isLive ? "机位实时" : model.connected ? "已连接 · 等待采集" : "未连接机位"
    }

    private var header: some View {
        HStack(spacing: CourtStyle.Space.m) {
            CourtLogoMark(size: 30)
            Text("球场工作台").font(.title2.weight(.semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
            CourtStatus(text: connectionTitle, tone: model.isLive ? .live : .idle)
            Spacer(minLength: 0)
            if model.connected {
                Button { openWindow(id: "court.live-video") } label: { Label("实时画面", systemImage: "video") }
                    .accessibilityIdentifier("court.live-video.open")
            }
            Button(action: history) { Label("历史记录", systemImage: "clock.arrow.circlepath") }
            // While no camera is connected the connect prompt carries the one primary button.
            Button(action: pairing) { Label(model.connected ? "配对与连接" : "连接机位", systemImage: "qrcode") }
            Menu { Button("切换模式", action: leave) } label: { Image(systemName: "ellipsis").frame(width: 24) }
                .accessibilityLabel("更多").help("切换设备角色")
        }.buttonStyle(CourtButton()).lineLimit(1)
    }

    // MARK: Data column

    private func dataColumn(wide: Bool) -> some View {
        VStack(spacing: CourtStyle.Space.l) {
            if let summary = model.finishedRecord {
                CourtSessionSummaryCard(summary: summary, viewDetails: { openRecord(summary.sessionID) },
                                        dismiss: model.dismissFinishedRecord)
            }
            if !model.connected { connectPrompt }
            if model.connected || !model.shownEvents.isEmpty {
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: CourtStyle.Space.l)) : AnyLayout(VStackLayout(spacing: CourtStyle.Space.l))
                // Fixed vertical size lets the two cards share one height side by side.
                layout {
                    speedCard
                    placementCard
                }.fixedSize(horizontal: false, vertical: true)
                shotsPanel
            }
        }
    }

    /// What a display without a camera shows instead of empty panels, with the one primary button.
    private var connectPrompt: some View {
        CourtPanel {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 36, weight: .light)).foregroundStyle(CourtStyle.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                Text("连接机位").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("点「连接机位」显示这台看板的二维码，再在机位上点「连接」→「扫码连接 App 看板」。连上后，这里显示实时画面、球速、落点和逐拍记录。")
                    .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: pairing) { Label("连接机位", systemImage: "qrcode").frame(maxWidth: .infinity) }
                .buttonStyle(CourtButton(primary: true)).accessibilityIdentifier("court.server.connect")
            Text(model.serverStatus).font(.caption).foregroundStyle(CourtStyle.muted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.server.empty")
    }

    private func cardLink(_ action: String, identifier: String, open: @escaping () -> Void) -> some View {
        CourtLinkButton(title: action, systemImage: "arrow.up.left.and.arrow.down.right", action: open)
            .accessibilityIdentifier(identifier)
    }
    private var speedCard: some View {
        CourtPanel("球速", fillHeight: true, accessory: {
            cardLink("打开测速牌", identifier: "court.speedboard.open") { openWindow(id: "court.speedboard") }
        }) {
            Button { openWindow(id: "court.speedboard") } label: {
                LiveSpeedReadout(events: model.shownEvents, fontSize: 88)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("点击打开大字测速牌")
                .accessibilityLabel("放大球速，打开测速牌")
                .accessibilityIdentifier("court.focus.speed.open")
            TennisSpeedChart(events: model.shownEvents)
        }
    }
    private var placementCard: some View {
        CourtPanel("落点分布", fillHeight: true, accessory: {
            cardLink("放大落点", identifier: "court.focus.placement.open") { openWindow(id: "court.placement") }
        }) {
            TennisCourtMap(events: model.shownEvents, selected: $selected).frame(height: 330)
            let mapped = TennisEventSummary(events: model.shownEvents).placementCount
            if mapped > 0 {
                CourtStrokeLegend(events: model.shownEvents, placementsOnly: true, symbols: true)
                Text("\(mapped) 拍有落点 · 点落点查看是哪一拍").font(.caption).foregroundStyle(CourtStyle.muted)
            } else {
                Text("出现击球后，落点会画在球场图上。").font(.caption).foregroundStyle(CourtStyle.muted)
            }
        }
    }

    /// The latest shots as the shared `TennisShotRow` (missing reason, ▶ per row), like the iPhone
    /// and the 「全部 N 拍」 list; selecting a shot also marks it on the court map.
    private var shotsPanel: some View {
        let events = model.shownEvents
        return CourtPanel("最近击球", accessory: {
            if events.count > TennisAnalysisOverview.liveRowLimit {
                CourtLinkButton(title: "全部 \(events.count) 拍", systemImage: "list.bullet") { showAllShots = true }
                    .accessibilityIdentifier("court.analysis.all-shots")
            }
        }) {
            if events.isEmpty {
                CourtNotice(text: model.isLive ? "出现击球候选后，逐拍列出动作、球速与落点。" : "机位开始采集后，逐拍球速与落点会实时显示在这里。")
            } else {
                VStack(alignment: .leading, spacing: CourtStyle.Space.xs) {
                    if let finished = model.finishedRecordShots {
                        Text("上一次记录「\(finished.title)」的结果，开始新记录后清空").font(.caption).foregroundStyle(CourtStyle.muted)
                    }
                    Text("\(events.count) 个击球候选 · 点一拍在球场图上标出并看详情").font(.caption).foregroundStyle(CourtStyle.muted)
                    if model.canFetchClips, model.cameraOwnsSession {
                        Label("点 ▶ 从机位取这一拍片段：" + ShotReplayButton.clipNote, systemImage: "play.circle")
                            .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A plain stack of a fixed few rows, as on the iPhone; the full list has its own scroll.
                VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                    ForEach(Array(events.suffix(TennisAnalysisOverview.liveRowLimit).reversed())) { event in
                        TennisShotRow(event: event, selected: $selected, accessory: { shot in
                            AnyView(ShotReplayButton(model: model, session: model.session, shot: shot) { clipPlayback = $0 })
                        })
                    }
                }.environment(\.courtCompactShotReplay, true)
            }
        }
        .sheet(item: $clipPlayback) { item in RecordingPlayer(item: item) }
        .sheet(isPresented: $showAllShots) { CourtShotListSheet(model: model) }
    }

    // MARK: Side column

    private var sideColumn: some View {
        VStack(spacing: CourtStyle.Space.l) {
            if model.connected { previewPanel }
            DesktopSessionControls(model: model, finish: finish)
            if model.connected {
                // The iPhone's 「机位与分析」 card: key values, what needs attention, setup actions, and
                // the full camera status, recognition and people detection folded underneath.
                CameraHealthCard(model: model, showPeople: $showPeople) {
                    Button(action: handedness) { Label("持拍手", systemImage: "hand.raised").frame(maxWidth: .infinity) }
                        .buttonStyle(CourtButton()).accessibilityIdentifier("court.handedness.open")
                }
            }
        }
    }

    private var previewPanel: some View {
        CourtPanel("实时画面", accessory: {
            Button { openWindow(id: "court.live-video") } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(CourtStyle.green)
                .accessibilityLabel("放大实时画面").help("在独立窗口中放大实时画面")
        }) {
            ServerVideo(model: model, showPeople: showPeople)
            Text(model.deviceName).font(.caption).foregroundStyle(CourtStyle.muted).lineLimit(2)
        }
    }
}

/// Starting a record, or the running one, with the same states and words as the iPhone's record panel.
@MainActor
private struct DesktopSessionControls: View {
    @Bindable var model: WorkspaceModel
    let finish: () -> Void
    var body: some View {
        CourtPanel(model.hasControllableSession ? "正在记录" : "准备记录") {
            if model.hasControllableSession, let session = model.session {
                Text(session.title).font(.headline)
                Text(courtDuration(session.elapsed(at: model.now))).font(.largeTitle.monospacedDigit())
                CourtStatus(text: session.state.courtTitle, tone: session.state.courtTone)
                Label(model.isRecording ? "机位正在录像" : model.cameraOwnsSession ? "机位当前未录像" : "等待机位加入 · 机位连接后开始录像与分析",
                      systemImage: model.isRecording ? "record.circle.fill" : "video.slash")
                    .font(.caption).foregroundStyle(model.isRecording ? CourtStyle.green : CourtStyle.muted)
                HStack {
                    Button(action: model.pauseOrResume) {
                        Label(session.state == .active ? "暂停" : "继续", systemImage: session.state == .active ? "pause.fill" : "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(CourtButton(primary: model.connected))
                    Button(action: finish) { Label("结束", systemImage: "stop.fill") }.buttonStyle(CourtButton(destructive: true))
                }.disabled(model.isSaving || model.sessionCommandsLocked)
                if let reason = model.sessionWaitReason { ProgressView(reason).font(.caption) }
                if session.state == .paused { CourtNotice(text: "暂停期间机位停止录像，这段时间的击球不计入本次记录；暂停中不能标记。") }
                if session.state == .interrupted { CourtNotice(text: "机位上的这次记录意外中断（机位曾重启）。点「继续」恢复录像，或点「结束」保存。", warning: true) }
                HStack {
                    ForEach(["精彩", "待复核"], id: \.self) { label in
                        Button { model.markEvent(label) } label: { Label(label, systemImage: "bookmark").frame(maxWidth: .infinity) }
                            .buttonStyle(CourtButton()).disabled(session.state != .active)
                    }
                }
                Text("已标记 \(session.events.filter { $0.kind == .marker }.count) 个时刻")
                    .font(.caption).foregroundStyle(CourtStyle.muted)
            } else {
                TextField("给这次上场起个名字", text: $model.sessionTitle).courtField()
                    .accessibilityLabel("记录名称")
                Button(action: model.startSession) { Label("开始记录", systemImage: "record.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(CourtButton(primary: model.connected)).disabled(model.isSaving || model.sessionCommandsLocked)
                if let reason = model.sessionWaitReason { ProgressView(reason).font(.caption) }
                CourtNotice(text: model.isLive ? "机位保存录像并实时分析，看板保存逐拍数据镜像；未知数据保持为空。" : "机位尚未采集。开始记录后，机位连接并采集时才会录像与分析。")
            }
            if model.isSaving { ProgressView("正在保存录像与记录…").font(.caption) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.session.panel")
    }
}
#endif
