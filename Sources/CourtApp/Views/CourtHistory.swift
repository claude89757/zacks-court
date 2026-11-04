import SwiftUI
import AVKit
import CourtCore

@MainActor
struct CourtHistory: View {
    let model: WorkspaceModel
    enum Mode: Hashable { case sessions, shots }
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.sessions
    @State private var path: [UUID] = []
    @State private var pendingDelete: CourtSession?
    @State private var storedBytes: Int64 = 0
    @State private var showStorage = false
    @Environment(\.dynamicTypeSize) private var typeSize
    /// `open` pushes that record's detail at once (「查看详情」 on the end-of-record summary).
    init(model: WorkspaceModel, open: UUID? = nil) {
        self.model = model; self.openRecord = open
    }
    private let openRecord: UUID?
    /// `openRecord` is pushed once, after the list has loaded, so going back lands on the list.
    @State private var openedRecord = false
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if mode == .sessions { sessionList } else { shotBrowser }
            }
            .background(CourtStyle.background).navigationTitle("历史记录")
            .toolbar { ToolbarItem(placement: .confirmationAction) { CourtTextButton("完成") { dismiss() } } }
            .navigationDestination(for: UUID.self) { id in
                if let session = model.history.first(where: { $0.id == id }) {
                    SessionDetail(model: model, session: session)
                } else {
                    ContentUnavailableView("这条记录已删除", systemImage: "trash", description: Text("返回历史记录查看其他记录。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(CourtStyle.background)
                }
            }
            .task {
                model.reloadHistory()
                if let openRecord, !openedRecord { openedRecord = true; path = [openRecord] }
            }
            .task(id: model.history.map(\.id)) {
                storedBytes = model.localRecordingBytes(model.history)
                model.storageFreeBytes = StorageCleanup.freeBytes(at: model.storageDirectory)
            }
            .sheet(isPresented: $showStorage) { CourtStorageSheet(model: model) }
            .courtDeleteConfirmation(model: model, session: $pendingDelete)
        }.tint(CourtStyle.green).preferredColorScheme(.dark)
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 850, minHeight: 650)
            #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode == .sessions ? "这台设备保存的记录。点开一条可回看录像、逐拍球速估算与落点候选。" : "在本机所有记录里查询逐拍球速估算与落点候选。")
                .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            CourtSegment(options: [Mode.sessions, .shots], selection: $mode,
                         title: { $0 == .sessions ? "按记录查看" : "球速与落点查询" },
                         identifier: { $0 == .sessions ? "court.history.mode.sessions" : "court.history.mode.shots" })
                .accessibilityElement(children: .contain).accessibilityIdentifier("court.history.mode")
            CourtBanners(model: model)
        }
    }

    private var shotBrowser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                CourtShotBrowser(model: model, sessions: model.history)
            }.padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("court.history.query.scroll")
    }

    /// A `List`, so rows can be swiped to delete on iPhone (and right-clicked on Mac).
    private var sessionList: some View {
        List {
            Group {
                // Leading like the rows below; a wide Mac window would otherwise centre it.
                header.frame(maxWidth: .infinity, alignment: .leading)
                if model.history.isEmpty {
                    emptyState
                } else {
                    storageRow
                    ForEach(model.history) { session in
                        Button { path.append(session.id) } label: { historyRow(session) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if model.deletionBlocker(session) == nil {
                                    // No destructive role: that animates the row away before the user confirms.
                                    Button { pendingDelete = session } label: { Label("删除", systemImage: "trash") }
                                        .tint(CourtStyle.warning)
                                }
                            }
                            .contextMenu {
                                Button { pendingDelete = session } label: { Label("删除这次记录…", systemImage: "trash") }
                                    .disabled(model.deletionBlocker(session) != nil)
                            }
                    }
                }
            }
            .frame(maxWidth: 900).frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 24))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 18, for: .scrollContent)
        .accessibilityIdentifier("court.history.list")
    }

    /// The storage line opens 「存储空间」; it turns into a warning when little recording time is left.
    private var storageRow: some View {
        let minutes = model.storageFreeBytes.map(StorageCleanup.recordingMinutes(freeBytes:))
        let low = minutes.map { $0 < CourtStorageSheet.lowMinutes } ?? false
        return Button { showStorage = true } label: {
            HStack(spacing: 8) {
                Image(systemName: low ? "exclamationmark.triangle" : "internaldrive").accessibilityHidden(true)
                Text(storageSummary + (low ? "；剩余空间约可录 \(minutes ?? 0) 分钟" : "")).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("管理存储空间").foregroundStyle(CourtStyle.green)
                Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
            }
            .font(.caption).foregroundStyle(low ? CourtStyle.warning : CourtStyle.muted)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("court.history.storage")
    }

    private var storageSummary: String {
        let count = "本机 \(model.history.count) 条记录"
        guard storedBytes > 0 else { return count + " · 没有本机录像" }
        #if os(iOS)
        let hint = "；向左轻扫一条可删除"
        #else
        let hint = "；右键点按一条可删除"
        #endif
        return count + " · 录像约 " + ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file) + hint
    }

    private var emptyState: some View {
        CourtPanel {
            Image(systemName: "rectangle.stack").font(.largeTitle.weight(.ultraLight)).foregroundStyle(CourtStyle.green)
                .accessibilityHidden(true)
            Text("还没有历史记录").font(.headline)
            Text("在机位或看板开始一次记录（或在启动页导入一段视频），结束后会出现在这里，可以回看录像、逐拍球速估算与落点候选。记录只保存在这台设备上。")
                .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("court.history.empty")
    }

    private func historyRow(_ session: CourtSession) -> some View {
        let events = session.tennisEvents
        let summary = TennisEventSummary(events: events ?? [])
        let recording = recordingState(session)
        // At accessibility sizes the decorative icon and chevron give their width to the text.
        let compact = typeSize.isAccessibilitySize
        return HStack(alignment: .top, spacing: 14) {
            if !compact {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title3).foregroundStyle(CourtStyle.green).frame(width: 46, height: 46)
                    .background(CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(session.title).font(.headline).foregroundStyle(.white)
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + courtDuration(session.elapsed(at: session.endedAt ?? model.now)))
                    .font(.caption.monospacedDigit()).foregroundStyle(CourtStyle.muted)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { rowFacts(events: events, summary: summary, recording: recording, fixed: true) }
                    VStack(alignment: .leading, spacing: 5) { rowFacts(events: events, summary: summary, recording: recording, fixed: false) }
                }.font(.caption)
                if session.state != .completed {
                    Label(session.state.courtTitle, systemImage: session.state == .interrupted ? "exclamationmark.triangle" : "record.circle")
                        .font(.caption).foregroundStyle(session.state.courtTone == .warning ? CourtStyle.warning : CourtStyle.green)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(CourtStyle.muted).padding(.top, 16)
                    .accessibilityHidden(true)
            }
        }.padding(16).background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.card).strokeBorder(CourtStyle.border))
            .contentShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .accessibilityElement(children: .combine)
    }

    /// Shot count and top speed on one line, where the recording is on another when space is short.
    @ViewBuilder private func rowFacts(events: [TennisShotEvent]?, summary: TennisEventSummary, recording: (text: String, icon: String), fixed: Bool) -> some View {
        Text((events.map { "\($0.count) 拍" } ?? "— 拍") + " · 最高 " + courtSpeed(summary.maximumSpeed) + " km/h")
            .foregroundStyle(.white).fixedSize(horizontal: fixed, vertical: !fixed)
        HStack(spacing: 5) {
            Image(systemName: recording.icon).accessibilityHidden(true)
            Text(recording.text)
        }.foregroundStyle(CourtStyle.muted).fixedSize(horizontal: fixed, vertical: !fixed)
    }

    private func recordingState(_ session: CourtSession) -> (text: String, icon: String) {
        guard !session.recordings.isEmpty else { return ("无录像", "video.slash") }
        let local = session.recordings.filter { FileManager.default.fileExists(atPath: model.recordingURL(filename: $0.filename).path) }.count
        if local == session.recordings.count { return (local > 1 ? "录像 \(local) 段" : "有录像", "film") }
        if local > 0 { return ("本机录像 \(local)/\(session.recordings.count) 段", "film") }
        if session.recordings.allSatisfy({ model.recordingCleared($0.filename) != nil }) { return ("录像已清理", "film.stack") }
        return (session.capturedOn != nil && model.role != .camera ? "录像在机位" : "录像不在本机", "iphone")
    }
}

extension View {
    /// The one confirmation every delete path goes through: it says what goes and that only this device is affected.
    func courtDeleteConfirmation(model: WorkspaceModel, session: Binding<CourtSession?>, deleted: @escaping () -> Void = {}) -> some View {
        confirmationDialog("删除这次记录？", isPresented: Binding(get: { session.wrappedValue != nil }, set: { if !$0 { session.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: session.wrappedValue) { target in
            Button("删除记录", role: .destructive) {
                if model.deleteSession(target) { deleted() }
                session.wrappedValue = nil
            }
            Button("取消", role: .cancel) { session.wrappedValue = nil }
        } message: { target in
            Text(model.deletionMessage(target))
        }
    }
}

struct PlaybackItem: Identifiable {
    var id: URL { url }
    let url: URL
    var seconds = 0.0
    /// What the player offers to share or save; nil shows no export buttons.
    var export: PlaybackExport?
}

@MainActor
struct SessionDetail: View {
    let model: WorkspaceModel
    private let snapshot: CourtSession
    @Environment(\.dismiss) private var dismiss
    @State private var playback: PlaybackItem?
    @State private var pendingDelete: CourtSession?
    @State private var pendingClear: RecordingCleanupPlan?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    init(model: WorkspaceModel, session: CourtSession) { self.model = model; snapshot = session }
    /// The latest saved copy, so transfer and backfill results appear without reopening.
    private var session: CourtSession { model.history.first { $0.id == snapshot.id } ?? snapshot }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CourtStyle.Space.l) {
                // Backfill, transfer and clip results land here too, not only in the list.
                CourtBanners(model: model)
                CourtPanel(session.title) {
                    Text(session.startedAt.formatted(date: .long, time: .shortened))
                        .font(.callout).foregroundStyle(CourtStyle.muted)
                    CourtStatus(text: session.state.courtTitle, tone: session.state.courtTone)
                    CourtMetricGrid {
                        CourtMetric(title: "记录时长", value: courtDuration(session.elapsed(at: session.endedAt ?? model.now)))
                        CourtMetric(title: "击球", value: session.tennisEvents.map { "\($0.count)" } ?? "—", unit: "拍")
                    }
                    if session.state == .interrupted { CourtNotice(text: "这次记录意外中断，已保留中断前保存的数据。", warning: true) }
                    if let version = session.tennisModelVersion { Text("分析模型 " + version).font(.caption).foregroundStyle(CourtStyle.muted).textSelection(.enabled) }
                    if let camera = session.capturedOn { Text("机位：" + camera).font(.caption).foregroundStyle(CourtStyle.muted) }
                    analysisGaps
                }
                TennisAnalysisOverview(events: session.tennisEvents ?? [],
                                       emptyReason: session.tennisEvents == nil ? "这份历史记录未包含击球分析，原有录像与标记仍可回看。" : "本次没有保存可用的击球分析事件。",
                                       calibration: session.tennisCalibration, historical: true,
                                       shotAccessory: { event in AnyView(ShotReplayButton(model: model, session: session, shot: event) { playback = $0 }) },
                                       timeLabel: shotTimeLabel)
                CourtPanel("录像片段") {
                    if session.recordings.isEmpty {
                        CourtNotice(text: "本次没有已保存的录像片段。可能尚未接收画面，或录像未成功完成。")
                    } else {
                        ForEach(session.recordings) { recording in recordingRow(recording) }
                    }
                }
                CourtPanel("辅助标记与记录状态") {
                    if session.events.isEmpty { CourtNotice(text: "本次没有事件记录。") }
                    else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(session.events) { event in eventRow(event) }
                        }
                    }
                }
                manage
            }.padding(dynamicTypeSize.isAccessibilitySize ? CourtStyle.Space.l : CourtStyle.Space.xl).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("court.history.detail.scroll")
            .background(CourtStyle.background).navigationTitle("记录详情")
            .sheet(item: $playback) { item in RecordingPlayer(item: item) }
            .courtDeleteConfirmation(model: model, session: $pendingDelete) { dismiss() }
            .confirmationDialog("只删这次记录的录像？", isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }),
                                titleVisibility: .visible, presenting: pendingClear) { plan in
                Button("删除录像（\(courtBytes(plan.bytes))）", role: .destructive) { model.clearRecordings(plan); pendingClear = nil }
                Button("取消", role: .cancel) { pendingClear = nil }
            } message: { _ in
                Text("只删这台设备上的视频文件，逐拍数据、球速、落点和标记都保留；之后不能再回看视频或离线补算。删除后无法恢复。")
            }
    }

    @ViewBuilder private var analysisGaps: some View {
        if let gaps = session.analysisGaps, !gaps.isEmpty {
            let pending = OfflineBackfill.pendingGaps(in: session, directory: model.storageDirectory)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                    let span = gap.endPTS.map { courtDuration(max(0, $0 - gap.startPTS)) } ?? "至结束"
                    CourtNotice(text: "分析暂停 \(span)：\(gap.reason)" + (gap.backfilled == true ? " · 已离线补算" : " · 该区间拍次保持为空"),
                                warning: gap.backfilled != true)
                }
                if let running = model.backfill, running.session == session.id {
                    ProgressView(value: running.fraction) { Text("正在离线补算…").font(.caption) }
                } else if !pending.isEmpty {
                    let blocked = backfillBlocker
                    Button { model.backfillGaps(session) } label: {
                        Label("离线补算暂停区间（\(pending.count) 段）", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }.buttonStyle(CourtButton()).disabled(blocked != nil)
                        .accessibilityIdentifier("court.history.backfill")
                    Text(blocked ?? "用同一套模型分析本机录像中的暂停区间，结果标注「离线补算」，不覆盖实时结果。建议接上电源。")
                        .font(.caption2).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
                } else if gaps.contains(where: { $0.backfilled != true }) {
                    Text("暂停区间的录像不在这台设备上，回传录像到本机后可离线补算。")
                        .font(.caption2).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Why offline backfill cannot start, in the order the button checks it.
    private var backfillBlocker: String? {
        if !model.backfillModelsAvailable {
            return model.analysisBackend == .independent ? "自研模型还不支持离线补算。" : "这台设备没有分析模型，无法离线补算。"
        }
        switch session.state {
        case .active, .paused: return "结束记录后可补算。"
        case .interrupted: return "这次记录意外中断，在机位上结束并保存后可补算。"
        case .completed: break
        }
        if model.backfill != nil { return "正在补算另一条记录，完成后可补算这一条。" }
        return nil
    }

    /// Exports for diagnostics and deleting, at the end of the page.
    private var manage: some View {
        CourtPanel("管理这次记录") {
            let blocker = model.deletionBlocker(session)
            let plan = model.recordingCleanupPlan([session])
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { exportMenu; clearRecordingsButton(plan); deleteButton(blocker) }
                VStack(alignment: .leading, spacing: 10) { exportMenu; clearRecordingsButton(plan); deleteButton(blocker) }
            }
            Text(blocker ?? "「只删录像」释放视频占的空间，保留逐拍数据和标记；「删除这次记录」把录像、逐拍数据和辅助标记一起删掉。")
                .font(.caption2).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func clearRecordingsButton(_ plan: RecordingCleanupPlan) -> some View {
        if !plan.isEmpty {
            Button { pendingClear = plan } label: { Label("只删录像（\(courtBytes(plan.bytes))）", systemImage: "film.stack") }
                .buttonStyle(CourtButton()).accessibilityIdentifier("court.history.clearRecordings")
        }
    }

    private func deleteButton(_ blocker: String?) -> some View {
        Button { pendingDelete = session } label: { Label("删除这次记录", systemImage: "trash") }
            .buttonStyle(CourtButton(destructive: true)).disabled(blocker != nil)
            .accessibilityIdentifier("court.history.delete")
    }

    private var exportMenu: some View {
        let json = model.sessionFileURL(session), analysis = model.analysisFileURL(session), status = model.statusFileURL(session)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        return Menu {
            // One file to send back from a field test: record, logs, the camera's capture logs, a summary.
            if exists(json) {
                ShareLink(item: DiagnosticPackage(session: session, storageDirectory: model.storageDirectory),
                          preview: SharePreview("Zacks Court 诊断包")) {
                    Label("诊断包（不含录像）", systemImage: "stethoscope")
                }
            }
            if exists(json) { ShareLink(item: json) { Label("记录 JSON", systemImage: "doc.text") } }
            if exists(analysis) { ShareLink(item: analysis) { Label("辅助检测日志", systemImage: "point.topleft.down.to.point.bottomright.curvepath") } }
            // Display only: the camera's 1 Hz status as this display received it.
            if exists(status) { ShareLink(item: status) { Label("机位状态记录", systemImage: "thermometer.medium") } }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button).buttonStyle(CourtButton())
        #if os(macOS)
        .fixedSize()
        #endif
        .disabled(!exists(json))
        .accessibilityIdentifier("court.history.export")
    }

    private func recordingRow(_ recording: StoredRecording) -> some View {
        let url = model.recordingURL(filename: recording.filename)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "film").foregroundStyle(CourtStyle.green).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(recording.filename).font(.callout).textSelection(.enabled).lineLimit(3)
                    Text("\(courtDuration(recording.duration)) · \(recording.frames) 帧").font(.caption).foregroundStyle(CourtStyle.muted)
                }
            }
            if exists {
                HStack(spacing: 10) {
                    Button { playback = PlaybackItem(url: url, export: .recording(url)) } label: { Label("播放", systemImage: "play.fill") }.buttonStyle(CourtButton(primary: true))
                    ShareLink(item: url) { Label("分享录像", systemImage: "square.and.arrow.up") }.buttonStyle(CourtButton())
                }
            } else if let camera = session.capturedOn, model.role != .camera {
                // Mirrored from a camera: the file stays there until it is transferred.
                CourtNotice(text: "录像保存在机位设备「\(camera)」上。可在机位上回看，或回传到本机后在这里播放。")
                transferControls(recording)
            } else if let cleared = model.recordingCleared(recording.filename) {
                CourtNotice(text: "录像已于 \(cleared.formatted(date: .abbreviated, time: .omitted)) 清理，逐拍数据和标记保留。")
            } else { CourtNotice(text: "录像文件已不在原位置。", warning: true) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(CourtStyle.inset, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
    }

    @ViewBuilder private func transferControls(_ recording: StoredRecording) -> some View {
        let megabytes = { (bytes: Int64) in String(format: "%.0f", Double(bytes) / 1_048_576) }
        if let transfer = model.transfer, transfer.filename == recording.filename, !transfer.done, transfer.error == nil {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(transfer.received), total: Double(max(1, transfer.total)))
                Text(transfer.total > 0
                     ? "已传 \(megabytes(transfer.received)) / \(megabytes(transfer.total)) MB · \(String(format: "%.1f", transfer.bytesPerSecond / 1_048_576)) MB/s"
                     : "等待机位开始发送…")
                    .font(.caption.monospacedDigit()).foregroundStyle(CourtStyle.muted)
                Button(role: .destructive) { model.cancelTransfer() } label: { Label("取消回传", systemImage: "xmark") }
                    .buttonStyle(CourtButton())
            }
        } else {
            if let failure = model.transfer?.error, model.transfer?.filename == recording.filename {
                CourtNotice(text: failure, warning: true)
            }
            Button { model.transferRecording(session, recording) } label: {
                Label(model.transfer?.filename == recording.filename ? "继续回传" : "传到本机", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }.buttonStyle(CourtButton(primary: true)).disabled(!model.connected || (model.transfer.map { !$0.done && $0.error == nil } ?? false))
            if !model.connected {
                Text("机位在线并连接到这台看板时可以回传。").font(.caption2).foregroundStyle(CourtStyle.muted)
            } else if model.cameraStatus?.device.charging == false {
                Text("建议先给机位接上电源：录像约 60 MB/分钟，回传需要几分钟，机位记录中不能回传。").font(.caption2).foregroundStyle(CourtStyle.muted)
            }
        }
    }

    private func eventRow(_ event: SessionEvent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(courtDuration(event.elapsed)).font(.caption.monospaced()).foregroundStyle(CourtStyle.green).frame(minWidth: 46, alignment: .leading).padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(eventTitle(event)).font(.callout)
                if let item = eventPlayback(event) {
                    Button { playback = item } label: { Label("回看这个时刻", systemImage: "play.circle") }
                        .buttonStyle(CourtButton()).font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider().overlay(CourtStyle.border) }
    }
    private func eventTitle(_ event: SessionEvent) -> String {
        switch event.kind {
        case .marker: return event.label ?? "辅助标记"
        case .point: return "旧版手动记录"
        case .pause: return "暂停记录"
        case .resume: return "继续记录"
        case .finish: return "结束并保存"
        case .interruption: return event.label ?? "记录中断"
        }
    }
    private func eventPlayback(_ event: SessionEvent) -> PlaybackItem? {
        guard let pts = event.sourcePTS,
              let recording = session.recordings.first(where: { $0.streamID == event.streamID && pts >= $0.firstPTS && pts <= $0.firstPTS + $0.duration }) else { return nil }
        let url = model.recordingURL(filename: recording.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // A marked moment exports as the 10 s around it, not the whole recording.
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmm"
        let label = (event.label ?? eventTitle(event)).replacingOccurrences(of: "/", with: "-")
        let name = "ZacksCourt-\(formatter.string(from: session.startedAt))-\(label)-\(courtDuration(event.elapsed).replacingOccurrences(of: ":", with: "."))" + ".mov"
        let export = PlaybackExport(source: .cut(recording: url, firstPTS: recording.firstPTS, duration: recording.duration, start: pts - 6, end: pts + 4),
                                    name: name, what: "这一段")
        return PlaybackItem(url: url, seconds: max(0, pts - recording.firstPTS - 2), export: export)
    }

    private func shotTimeLabel(_ event: TennisShotEvent) -> String? {
        guard let index = session.recordings.firstIndex(where: { $0.streamID == event.streamID && event.sourcePTS >= $0.firstPTS && event.sourcePTS <= $0.firstPTS + $0.duration }) else { return nil }
        return "片段 \(index + 1) · " + courtDuration(event.sourcePTS - session.recordings[index].firstPTS)
    }
}

@MainActor
struct RecordingPlayer: View {
    let item: PlaybackItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(macOS)
                CourtMoviePlayer(player: player).aspectRatio(16.0 / 9, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                VideoPlayer(player: player).aspectRatio(16.0 / 9, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
                if let export = item.export { PlaybackExportBar(export: export).padding(.horizontal, 20).padding(.top, 16) }
                Text(item.export?.name ?? item.url.lastPathComponent).font(.caption).foregroundStyle(CourtStyle.muted).padding(20).textSelection(.enabled)
            }.background(.black).navigationTitle("录像回放")
                .toolbar { ToolbarItem(placement: .confirmationAction) { CourtTextButton("完成") { dismiss() } } }
                .task {
                    let player = AVPlayer(url: item.url); self.player = player
                    if item.seconds > 0 { await player.seek(to: CMTime(seconds: item.seconds, preferredTimescale: 600)) }
                    player.play()
                }
                .onDisappear { player?.pause(); player = nil }
        }.preferredColorScheme(.dark).tint(CourtStyle.green)
            #if os(macOS)
            .frame(minWidth: 720, idealWidth: 1000, minHeight: 480)
            #endif
    }
}

/// Share and save under the player. A shot inside a local recording is cut out when the player
/// opens (a few seconds, no re-encoding), so the share button is ready by the time it is tapped.
@MainActor
struct PlaybackExportBar: View {
    let export: PlaybackExport
    @State private var file: URL?
    @State private var failure: String?
    @State private var saving = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(CourtStyle.warning).fixedSize(horizontal: false, vertical: true) }
            else if saved { Text("已存到相册").font(.caption).foregroundStyle(CourtStyle.green) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            do { file = try await export.prepare() } catch { failure = "准备视频失败：" + error.localizedDescription }
        }
    }

    @ViewBuilder private var buttons: some View {
        if let file {
            ShareLink(item: file) { Label("分享" + export.what, systemImage: "square.and.arrow.up") }
                .buttonStyle(CourtButton(primary: true)).accessibilityIdentifier("court.player.share")
            #if os(iOS)
            Button { save(file) } label: {
                Label(saving ? "正在存入…" : "存到相册", systemImage: saved ? "checkmark" : "photo.on.rectangle")
            }.buttonStyle(CourtButton()).disabled(saving || saved).accessibilityIdentifier("court.player.save")
            #else
            Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Label("在访达中显示", systemImage: "folder") }
                .buttonStyle(CourtButton()).accessibilityIdentifier("court.player.reveal")
            #endif
        } else if failure == nil {
            HStack(spacing: 8) { ProgressView(); Text("正在准备" + export.what + "…").font(.caption).foregroundStyle(CourtStyle.muted) }
                .frame(minHeight: 44)
        }
    }

    #if os(iOS)
    private func save(_ url: URL) {
        saving = true; failure = nil
        Task {
            do { try await VideoExport.saveToPhotos(url); saved = true }
            catch { failure = error.localizedDescription }
            saving = false
        }
    }
    #endif
}

#if os(macOS)
/// Direct AVKit ownership also makes its framework dependency explicit in the
/// SwiftPM executable. SwiftUI's indirect VideoPlayer superclass can otherwise
/// fail to resolve AVPlayerView when first opening playback in a release app.
private struct CourtMoviePlayer: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}
#endif
