import Foundation
import CourtCore

func courtBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

/// Storage cleanup on this device (the camera phone or a display): what is stored, and removing
/// recordings while keeping each record's shots and marks, fetched clips, logs and leftovers.
/// Nothing a record in use needs is touched; `deletionBlocker` decides "in use", as for deleting.
extension WorkspaceModel {
    /// Records that cleanup leaves alone right now.
    var storageInUse: Set<UUID> {
        var ids = Set(history.filter { deletionBlocker($0) != nil }.map(\.id))
        if let id = session?.id, hasActiveSession { ids.insert(id) }
        if let id = controller?.session?.id { ids.insert(id) }
        return ids
    }
    /// Why recordings cannot be cleared at all right now (the camera is sending one).
    var recordingCleanupBlocker: String? {
        controller?.isReadingRecordings == true ? "机位正在发送录像或剪片段，完成后再清理录像。" : nil
    }
    /// Leftovers are only judged when no file can be running ahead of its record.
    var canJudgeLeftovers: Bool {
        guard !hasActiveSession, backfill == nil, !isFetchingFile else { return false }
        if let controller, controller.isBusy || controller.counters.saving || controller.isReadingRecordings { return false }
        return true
    }

    func refreshStorage() {
        guard let cleanup = storageCleanup else { storageUsage = nil; return }
        storageUsage = cleanup.usage(sessions: history, canJudgeLeftovers: canJudgeLeftovers)
        storageFreeBytes = StorageCleanup.freeBytes(at: storageDirectory)
        clearedRecordings = cleanup.clearedRecordings()
    }

    /// Recordings of these records that clearing would remove, and the bytes it frees.
    func recordingCleanupPlan(_ targets: [CourtSession]) -> RecordingCleanupPlan {
        guard recordingCleanupBlocker == nil, let cleanup = storageCleanup else { return RecordingCleanupPlan() }
        return cleanup.planRecordings(of: targets, all: history, inUse: storageInUse)
    }
    /// Completed records whose recordings are on this device, optionally only those that ended more than `days` ago.
    func recordsWithRecordings(olderThan days: Int? = nil) -> [CourtSession] {
        let completed = history.filter { $0.state == .completed }
        return days.map { StorageCleanup.olderThan($0, in: completed) } ?? completed
    }

    @discardableResult func clearRecordings(_ plan: RecordingCleanupPlan, automatic: Bool = false) -> Int64 {
        guard !plan.isEmpty, let cleanup = storageCleanup else { return 0 }
        if let reason = recordingCleanupBlocker { error = reason; return 0 }
        do {
            let freed = try cleanup.clearRecordings(plan)
            let what = "\(plan.filenames.count) 段录像，释放 \(courtBytes(freed))"
            notice = automatic ? "已按「录像保留 \(recordingRetentionDays) 天」自动清理 \(what)。逐拍数据和标记保留。"
                               : "已清理 \(what)。逐拍数据和标记保留。"
            reloadHistory(); refreshStorage()
            return freed
        } catch {
            self.error = "清理录像失败：\(error.localizedDescription)"
            reloadHistory(); refreshStorage()
            return 0
        }
    }

    func clearClips() { clean("单拍片段") { try $0.clearClips(inUse: self.storageInUse) } }
    func clearLogs() { clean("诊断日志") { try $0.clearLogs(inUse: self.storageInUse) } }
    func clearLeftovers() {
        guard canJudgeLeftovers else { error = "正在记录、保存或传输文件，完成后再清理残留文件。"; return }
        clean("残留文件") { try $0.clearLeftovers(sessions: self.history) }
    }
    private func clean(_ what: String, _ action: (StorageCleanup) throws -> Int64) {
        guard let cleanup = storageCleanup else { return }
        do { notice = "已清理\(what)，释放 \(courtBytes(try action(cleanup)))。" }
        catch { self.error = "清理\(what)失败：\(error.localizedDescription)" }
        refreshStorage()
    }

    /// The retention setting: completed records older than the chosen days lose their recordings.
    /// Runs at launch and when the setting changes, never while a record is open.
    func applyRecordingRetention() {
        guard recordingRetentionDays > 0, !hasActiveSession else { return }
        let plan = recordingCleanupPlan(recordsWithRecordings(olderThan: recordingRetentionDays))
        if !plan.isEmpty { clearRecordings(plan, automatic: true) }
    }

    /// When this recording was cleared on purpose, if it was.
    func recordingCleared(_ filename: String) -> Date? { clearedRecordings[filename] }
}
