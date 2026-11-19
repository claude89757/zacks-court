import SwiftUI
import CourtCore

/// 「存储空间」: what this device holds and how to free it. Recordings are by far the largest
/// (about 60 MB a minute); clearing them keeps every record's shots, speeds, placements and marks.
/// Same page on the camera phone and on a display; it only ever touches this device.
@MainActor
struct CourtStorageSheet: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var pending: Pending?

    struct Pending: Identifiable {
        let id = UUID()
        let title: String
        let plan: RecordingCleanupPlan
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CourtStyle.Space.l) {
                    CourtBanners(model: model)
                    overview
                    recordings
                    retention
                    others
                    Text(model.role == .camera
                         ? courtText("只影响这台机位手机。清理后，看板和浏览器也取不到这些录像和片段了。")
                         : courtText("只影响这台设备。机位上的录像不受影响，需要时可以再回传。"))
                        .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(CourtStyle.Space.xl).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .background(CourtStyle.background)
            .navigationTitle(courtText("存储空间"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { CourtTextButton(courtText("完成")) { dismiss() } } }
            .accessibilityIdentifier("court.storage.sheet")
            .task { model.reloadHistory(); model.refreshStorage() }
            .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible, presenting: pending) { item in
                Button(courtFormat("清理 %1$@ 段录像", "\(item.plan.filenames.count)"), role: .destructive) { model.clearRecordings(item.plan); pending = nil }
                    .accessibilityIdentifier("court.storage.confirm")
                Button(courtText("取消"), role: .cancel) { pending = nil }
            } message: { item in
                Text(courtFormat("将释放约 %1$@，涉及 %2$@ 条记录。只删视频文件，逐拍数据、球速、落点和标记都保留；之后这些记录不能再回看视频或离线补算。删除后无法恢复。", "\(courtBytes(item.plan.bytes))", "\(item.plan.sessions.count)"))
            }
        }
        .tint(CourtStyle.green).preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 600)
        #endif
    }

    private var usage: StorageUsage { model.storageUsage ?? StorageUsage() }

    private var overview: some View {
        CourtPanel(courtText("本机存储")) {
            CourtMetricGrid {
                CourtMetric(title: courtText("Zacks Court 占用"), value: courtBytes(usage.total))
                CourtMetric(title: courtText("设备剩余"), value: model.storageFreeBytes.map(courtBytes) ?? "—")
            }
            if let free = model.storageFreeBytes {
                let minutes = StorageCleanup.recordingMinutes(freeBytes: free)
                CourtNotice(text: courtFormat("剩余空间约可录 %1$@ 分钟（1080p60 约 60 MB/分钟）。", "\(minutes)") + (minutes < Self.lowMinutes ? courtText("空间不多了，建议清理较早的录像。") : ""),
                            warning: minutes < Self.lowMinutes)
                    .accessibilityIdentifier("court.storage.free")
            }
        }
    }
    /// Below this many minutes of recording left, the page and the history header warn.
    static let lowMinutes = 30

    private var recordings: some View {
        CourtPanel(courtText("录像")) {
            row(title: courtText("录像"), detail: usage.recordingCount > 0 ? courtFormat("%1$@ 段", "\(usage.recordingCount)") : courtText("没有本机录像"), bytes: usage.recordings)
            Text(courtText("清理录像只删视频文件，记录里的逐拍数据、球速、落点和标记都保留。清理后这些记录不能再回看视频或离线补算。"))
                .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            if let blocker = model.recordingCleanupBlocker { CourtNotice(text: blocker, warning: true) }
            VStack(alignment: .leading, spacing: 10) {
                clearButton(courtText("30 天前的录像"), days: 30, id: "court.storage.recordings.30")
                clearButton(courtText("7 天前的录像"), days: 7, id: "court.storage.recordings.7")
                clearButton(courtText("所有已结束记录的录像"), days: nil, id: "court.storage.recordings.all")
            }
            if !model.storageInUse.isEmpty {
                Text(courtText("进行中、正在保存、回传或补算的记录不会被清理。")).font(.caption2).foregroundStyle(CourtStyle.muted)
            }
        }
    }

    private func clearButton(_ what: String, days: Int?, id: String) -> some View {
        let plan = model.recordingCleanupPlan(model.recordsWithRecordings(olderThan: days))
        return Button {
            pending = Pending(title: courtFormat("清理%1$@？", "\(what)"), plan: plan)
        } label: {
            Label(plan.isEmpty ? courtFormat("清理%1$@（没有）", "\(what)") : courtFormat("清理%1$@（约 %2$@）", "\(what)", "\(courtBytes(plan.bytes))"), systemImage: "film.stack")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(CourtButton()).disabled(plan.isEmpty).accessibilityIdentifier(id)
    }

    private var retention: some View {
        CourtPanel(courtText("自动清理录像")) {
            CourtSegment(options: [0, 30, 7], selection: Binding(get: { model.recordingRetentionDays }, set: { model.recordingRetentionDays = $0 }),
                         title: { $0 == 0 ? courtText("不自动清理") : courtFormat("保留 %1$@ 天", "\($0)") },
                         identifier: { "court.storage.retention.\($0)" })
            Text(model.recordingRetentionDays == 0
                 ? courtText("默认不自动清理。选择天数后，每次打开 App 时，结束超过这些天的记录只删录像，保留逐拍数据和标记。")
                 : courtFormat("每次打开 App 时，结束超过 %1$@ 天的记录只删录像，保留逐拍数据和标记。进行中的记录不受影响。", "\(model.recordingRetentionDays)"))
                .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var others: some View {
        CourtPanel(courtText("其他数据")) {
            cleanRow(title: courtText("单拍片段"), detail: courtText("从机位取来的击球片段，需要时可以再取"), bytes: usage.clips, id: "court.storage.clips") { model.clearClips() }
            cleanRow(title: courtText("诊断日志"), detail: courtText("辅助检测、机位状态和机位采集日志，只用于排查问题"), bytes: usage.logs, id: "court.storage.logs") { model.clearLogs() }
            if model.canJudgeLeftovers {
                cleanRow(title: courtText("残留文件"), detail: courtText("中断的回传、已删除记录留下的文件"), bytes: usage.leftovers, id: "court.storage.leftovers") { model.clearLeftovers() }
            } else {
                row(title: courtText("残留文件"), detail: courtText("正在记录、保存或传输时不统计"), bytes: nil)
            }
            row(title: courtText("记录数据"), detail: courtText("逐拍数据和标记，删除记录时一起删除"), bytes: usage.data)
        }
    }

    private func row(title: String, detail: String, bytes: Int64?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(bytes.map(courtBytes) ?? "—").font(.callout.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func cleanRow(title: String, detail: String, bytes: Int64, id: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row(title: title, detail: detail, bytes: bytes)
            Button(action: action) { Label(courtFormat("清理%1$@", "\(title)"), systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(CourtButton()).disabled(bytes == 0).accessibilityIdentifier(id)
        }
    }
}
