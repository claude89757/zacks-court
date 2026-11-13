import SwiftUI
import CourtCore

@MainActor
struct CourtShotBrowser: View {
    let model: WorkspaceModel
    let sessions: [CourtSession]
    let records: [TennisHistoryShot]
    @State private var query = TennisHistoryQuery()
    @State private var minimumSpeed = ""
    @State private var maximumSpeed = ""
    @State private var useDates = false
    @State private var firstDate = Calendar.current.startOfDay(for: Date())
    @State private var lastDate = Date()
    @State private var rows: [TennisHistoryShot] = []
    @State private var selected: UUID?
    @State private var playback: PlaybackItem?
    @State private var visibleCount = 100
    @State private var loading = true
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Re-run the query when records are deleted or backfilled, not only when a filter changes.
    private struct QueryKey: Equatable { let query: TennisHistoryQuery; let sessions: [String] }
    init(model: WorkspaceModel, sessions: [CourtSession]) {
        self.model = model; self.sessions = sessions
        records = TennisHistoryShot.index(sessions: sessions)
    }
    private var rangeError: String? {
        if !minimumSpeed.isEmpty && (Double(minimumSpeed).map { !$0.isFinite || $0 < 0 } ?? true) { return courtText("最低球速请输入大于或等于 0 的数字。") }
        if !maximumSpeed.isEmpty && (Double(maximumSpeed).map { !$0.isFinite || $0 < 0 } ?? true) { return courtText("最高球速请输入大于或等于 0 的数字。") }
        if let lower = Double(minimumSpeed), let upper = Double(maximumSpeed), lower > upper { return courtText("最低球速不能高于最高球速。") }
        if useDates && firstDate > lastDate { return courtText("开始日期不能晚于结束日期。") }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            filters
            if let rangeError { CourtNotice(text: rangeError, warning: true) }
            else if loading { ProgressView(courtText("正在查询本机数据…")) }
            else {
                let events = rows.map(\.event)
                let summary = TennisEventSummary(events: events)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : sizeClass == .compact ? 2 : 4), spacing: CourtStyle.Space.s) {
                    CourtMetric(title: courtText("匹配击球"), value: "\(summary.count)", unit: courtText("拍"))
                    CourtMetric(title: courtText("有效平均球速"), value: courtSpeed(summary.averageSpeed), unit: "km/h")
                    CourtMetric(title: courtText("最高球速"), value: courtSpeed(summary.maximumSpeed), unit: "km/h")
                    CourtMetric(title: courtText("有落点"), value: "\(summary.placementCount)", unit: courtText("拍"))
                }.accessibilityIdentifier("court.history.results")
                if rows.isEmpty {
                    ContentUnavailableView(courtText("没有匹配的击球"), systemImage: "magnifyingglass", description: Text(records.isEmpty ? courtText("本机还没有保存击球。完成一次记录后就能在这里查询。") : courtText("试试清除筛选，或扩大日期与球速范围。")))
                } else {
                    CourtPanel(courtText("查询结果")) {
                        Text(courtFormat("%1$@ 拍有球速，%2$@ 拍暂无球速；缺失值不按 0 计算。", "\(summary.speedCount)", "\(summary.count - summary.speedCount)"))
                            .font(.caption).foregroundStyle(CourtStyle.muted)
                        let layout = sizeClass == .compact ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                        layout {
                            if summary.speedCount > 0 {
                                TennisSpeedChart(events: events, xAxisTitle: courtText("查询结果序号")).frame(maxWidth: .infinity)
                            } else {
                                CourtNotice(text: courtText("这组查询结果没有可用球速，缺失值保留为空。可修改筛选条件查看其他拍次。"))
                                    .frame(maxWidth: .infinity)
                            }
                            VStack(spacing: 10) {
                                TennisCourtMap(events: events, selected: $selected).frame(height: 260)
                                CourtStrokeLegend(events: events, placementsOnly: true, symbols: true)
                            }
                        }
                        if let selected, let row = rows.first(where: { $0.event.id == selected }) {
                            historyShot(row)
                        }
                        Text(courtText("点击落点或逐拍记录，可互相定位。点击「回看」播放对应录像片段。"))
                            .font(.caption).foregroundStyle(CourtStyle.muted)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(rows.prefix(visibleCount)) { row in historyShot(row) }
                        if rows.count > visibleCount {
                            Button(courtFormat("再显示 100 拍（还有 %1$@ 拍）", "\(rows.count - visibleCount)")) { visibleCount += 100 }
                                .buttonStyle(CourtButton())
                        }
                    }
                }
            }
        }
        .onChange(of: minimumSpeed) { _, value in query.minimumSpeed = Double(value) }
        .onChange(of: maximumSpeed) { _, value in query.maximumSpeed = Double(value) }
        .onChange(of: useDates) { _, _ in updateDates() }
        .onChange(of: firstDate) { _, _ in updateDates() }
        .onChange(of: lastDate) { _, _ in updateDates() }
        .task(id: QueryKey(query: query, sessions: sessions.map { "\($0.id)-\($0.tennisEvents?.count ?? -1)" })) {
            loading = true
            let filter = query, index = records
            let matches = await Task.detached(priority: .userInitiated) { filter.results(in: index) }.value
            guard !Task.isCancelled else { return }
            rows = matches; selected = nil; visibleCount = 100; loading = false
        }
        .sheet(item: $playback) { item in RecordingPlayer(item: item) }
    }
    private var filters: some View {
        CourtPanel(courtText("查询球速与落点")) {
            TextField(courtText("搜索记录名称"), text: $query.text).courtField()
                .accessibilityIdentifier("court.history.search")
            CourtMetricGrid(minimum: 180) {
                filterMenu(courtText("动作"), selection: $query.stroke,
                           options: [(nil, courtText("所有动作"))] + TennisStrokeKind.allCases.map { (Optional($0), $0.courtTitle) })
                    .accessibilityIdentifier("court.history.stroke")
                filterMenu(courtText("数据"), selection: $query.availability,
                           options: [(.all, courtText("全部数据")), (.speed, courtText("有球速")), (.placement, courtText("有落点")),
                                     (.missingSpeed, courtText("缺少球速")), (.missingPlacement, courtText("缺少落点"))])
                    .accessibilityIdentifier("court.history.availability")
                filterMenu(courtText("排序"), selection: $query.order,
                           options: [(.newest, courtText("最近优先")), (.fastest, courtText("球速从高到低")), (.oldest, courtText("最早优先"))])
                    .accessibilityIdentifier("court.history.order")
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        speedField(courtText("最低 km/h"), text: $minimumSpeed).accessibilityLabel(courtText("最低球速"))
                        Text(courtText("至")).foregroundStyle(CourtStyle.muted)
                        speedField(courtText("最高 km/h"), text: $maximumSpeed).accessibilityLabel(courtText("最高球速"))
                    }
                    Toggle(courtText("限定记录日期"), isOn: $useDates).frame(minHeight: 44)
                    if useDates {
                        ViewThatFits(in: .horizontal) {
                            HStack { dateStart; dateEnd }
                            VStack(alignment: .leading) { dateStart; dateEnd }
                        }
                    }
                }.padding(.top, 8)
            } label: {
                Text(courtText("日期与球速区间")).font(.callout.weight(.medium)).foregroundStyle(.white).frame(minHeight: 44)
            }
            CourtLinkButton(title: courtText("清除筛选"), systemImage: "xmark.circle") {
                minimumSpeed = ""; maximumSpeed = ""; useDates = false; query = TennisHistoryQuery()
            }.disabled(!filtered).opacity(filtered ? 1 : 0.4).accessibilityIdentifier("court.history.clear")
        }
    }
    /// Any filter differs from the default query.
    private var filtered: Bool { query != TennisHistoryQuery() || !minimumSpeed.isEmpty || !maximumSpeed.isEmpty || useDates }
    private func speedField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .courtField()
    }
    /// A filter that reads as a control: its name and current value on a raised, 46-point tile.
    private func filterMenu<Value: Hashable>(_ title: String, selection: Binding<Value>, options: [(Value, String)]) -> some View {
        let current = options.first { $0.0 == selection.wrappedValue }?.1 ?? ""
        return Menu {
            Picker(title, selection: selection) {
                ForEach(options.indices, id: \.self) { index in Text(options[index].1).tag(options[index].0) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(CourtStyle.muted)
                    Text(current).font(.callout.weight(.semibold)).foregroundStyle(.white)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(CourtStyle.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.control).strokeBorder(CourtStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(title)
        .accessibilityValue(current)
    }
    private var dateStart: some View { DatePicker(courtText("从"), selection: $firstDate, displayedComponents: .date) }
    private var dateEnd: some View { DatePicker(courtText("至"), selection: $lastDate, displayedComponents: .date) }
    private func updateDates() {
        query.from = useDates ? Calendar.current.startOfDay(for: firstDate) : nil
        query.until = useDates ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: lastDate)) : nil
    }
    private func historyShot(_ row: TennisHistoryShot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { selected = selected == row.event.id ? nil : row.event.id } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 7) {
                            Text(courtFormat("第 %1$@ 拍", "\(row.ordinal)")).foregroundStyle(CourtStyle.muted)
                            CourtStrokeTag(kind: row.event.stroke)
                        }
                        Spacer()
                        Text(courtSpeed(row.event.validSpeedKPH) + " km/h").font(.title3.monospacedDigit())
                    }
                    Text(row.sessionTitle + " · " + row.sessionDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(CourtStyle.muted)
                    if row.event.hasCourtPlacement, let x = row.event.bounce?.xMeters, let y = row.event.bounce?.yMeters {
                        Text(courtPrintf("落点 · 约横 %.1f m / 纵 %.1f m（从近端左角起）", x, y)).font(.caption).foregroundStyle(CourtStyle.green)
                    } else { Text(courtText("落点：") + (row.event.placementReasonText ?? TennisReason.other.text)).font(.caption).foregroundStyle(CourtStyle.muted) }
                    if let reason = row.event.speedReasonText { Text(courtText("球速：") + reason).font(.caption).foregroundStyle(CourtStyle.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            let session = sessions.first(where: { $0.id == row.sessionID })
            HStack {
                if let recording = row.recording, let seconds = row.recordingSeconds,
                   FileManager.default.fileExists(atPath: model.recordingURL(filename: recording.filename).path) {
                    Button {
                        let url = model.recordingURL(filename: recording.filename)
                        playback = PlaybackItem(url: url, seconds: max(0, seconds - 2),
                                                export: .shot(row.event, session: session, recording: url, firstPTS: recording.firstPTS, duration: recording.duration))
                    } label: { Label(courtText("回看 · ") + courtDuration(seconds), systemImage: "play.circle") }
                        .buttonStyle(CourtButton())
                }
                if let session {
                    NavigationLink(courtText("记录详情"), value: session.id).buttonStyle(CourtButton())
                }
            }
            // Recording still on the camera: a clip fetched earlier, or one the camera can cut now.
            if let session, !model.shotReplay(session: session, shot: row.event).isLocalRecording {
                ShotReplayButton(model: model, session: session, shot: row.event) { playback = $0 }
            }
        }.padding(16).background(selected == row.event.id ? CourtStyle.selectedFill : CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.card).strokeBorder(selected == row.event.id ? CourtStyle.selectedStroke : CourtStyle.border))
            .id(row.event.id)
    }
}
