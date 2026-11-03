import Foundation

/// What the session directory holds, by kind, and the cleanups that keep it from growing:
/// removing recordings while keeping each record's shots and marks, clearing fetched clips,
/// diagnostic logs and leftovers. Works on one `SessionStore` directory; callers say which
/// records are in use so nothing being recorded, saved, transferred or analysed is touched.
public struct StorageUsage: Equatable, Sendable {
    /// Recordings (.mov) with their per-frame timestamp files, and how many recordings.
    public var recordings: Int64 = 0
    public var recordingCount = 0
    /// Per-shot clips fetched from a camera (`Clips/`).
    public var clips: Int64 = 0
    /// Detection and camera-status logs (`<id>-analysis.jsonl`, `<id>-status.jsonl`).
    public var logs: Int64 = 0
    /// Session JSON (shots, marks) and small settings files.
    public var data: Int64 = 0
    /// Files no record lists any more: interrupted transfers, recordings left by a crash, logs and
    /// clips of deleted records.
    public var leftovers: Int64 = 0
    public init() {}
    public var total: Int64 { recordings + clips + logs + data + leftovers }
}

/// A set of recordings to remove and what that frees.
public struct RecordingCleanupPlan: Equatable, Sendable {
    /// Recording filenames that will be removed (with their timestamp file).
    public var filenames: [String] = []
    public var bytes: Int64 = 0
    /// Records whose recordings go (all their local recordings, or the ones not shared with a kept record).
    public var sessions: [UUID] = []
    /// Records asked for but left alone because they are in use.
    public var skipped: [UUID] = []
    public init() {}
    public var isEmpty: Bool { filenames.isEmpty }
}

public final class StorageCleanup {
    public let store: SessionStore
    public init(store: SessionStore) { self.store = store }

    /// Recordings removed on purpose, so the history can say "录像已清理" instead of "missing".
    /// Kept beside the sessions in a non-UUID file, which `SessionStore.loadAll` ignores; the
    /// session JSON (also mirrored to displays) does not change.
    public static let ledgerName = "cleared-recordings.json"
    private var ledgerURL: URL { store.directory.appendingPathComponent(Self.ledgerName) }

    public func clearedRecordings() -> [String: Date] {
        guard let data = try? Data(contentsOf: ledgerURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }
    private func markCleared(_ names: [String], at date: Date) throws {
        var ledger = clearedRecordings()
        for name in names { ledger[name] = date }
        try JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
    }

    // MARK: Usage

    /// Sizes by kind. `inUse` records count normally; leftovers are only reported when
    /// `canJudgeLeftovers` (nothing is being recorded or received, whose files may run ahead of the JSON).
    public func usage(sessions: [CourtSession], canJudgeLeftovers: Bool) -> StorageUsage {
        var usage = StorageUsage()
        let fm = FileManager.default
        let listed = Set(sessions.flatMap(\.recordingFilenames))
        let ids = Set(sessions.map { $0.id.uuidString.lowercased() })
        let urls = (try? fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])) ?? []
        for url in urls {
            let name = url.lastPathComponent
            if name == SessionStore.clipsFolder { usage.clips += Self.size(of: url); continue }
            let bytes = Self.size(of: url)
            switch Self.kind(of: name, listed: listed, ids: ids) {
            case .recording: usage.recordings += bytes; if name.hasSuffix(".mov") { usage.recordingCount += 1 }
            case .log: usage.logs += bytes
            case .data: usage.data += bytes
            case .leftover: if canJudgeLeftovers { usage.leftovers += bytes } else { usage.data += bytes }
            }
        }
        return usage
    }

    enum Kind { case recording, log, data, leftover }
    static func kind(of name: String, listed: Set<String>, ids: Set<String>) -> Kind {
        let base = (name as NSString).deletingPathExtension
        if name.hasPrefix("."), name.hasSuffix(".part") { return .leftover }
        if name.hasSuffix(".mov") { return listed.contains(name) ? .recording : .leftover }
        if name.hasSuffix("-analysis.jsonl") || name.hasSuffix("-status.jsonl") {
            let id = String(name.prefix(36)).lowercased()
            return ids.contains(id) ? .log : .leftover
        }
        if name.hasSuffix(".jsonl") { return listed.contains(base + ".mov") ? .recording : .leftover }
        return .data
    }

    // MARK: Recordings

    /// Recordings of `targets` that can go. A file listed by a record outside `targets` (or one in
    /// use) stays, so a shared recording is never removed from under another record.
    public func planRecordings(of targets: [CourtSession], all: [CourtSession], inUse: Set<UUID>) -> RecordingCleanupPlan {
        var plan = RecordingCleanupPlan()
        let chosen = targets.filter { !inUse.contains($0.id) }
        plan.skipped = targets.filter { inUse.contains($0.id) }.map(\.id)
        let chosenIDs = Set(chosen.map(\.id))
        let kept = Set(all.filter { !chosenIDs.contains($0.id) }.flatMap(\.recordingFilenames))
        var names = Set<String>()
        for session in chosen {
            var any = false
            for name in Set(session.recordingFilenames) where !kept.contains(name) {
                guard let url = try? store.recordingURL(filename: name), FileManager.default.fileExists(atPath: url.path) else { continue }
                names.insert(name); any = true
            }
            if any { plan.sessions.append(session.id) }
        }
        plan.filenames = names.sorted()
        plan.bytes = names.reduce(Int64(0)) { total, name in
            guard let url = try? store.recordingURL(filename: name) else { return total }
            return total + Self.size(of: url) + Self.size(of: url.deletingPathExtension().appendingPathExtension("jsonl"))
        }
        return plan
    }

    /// Removes the planned recordings and their timestamp files and notes them as cleared. Shots,
    /// marks and logs stay. Returns the bytes freed.
    @discardableResult public func clearRecordings(_ plan: RecordingCleanupPlan, at date: Date = Date()) throws -> Int64 {
        guard !plan.isEmpty else { return 0 }
        var freed: Int64 = 0, removed: [String] = []
        defer { try? markCleared(removed, at: date) }
        for name in plan.filenames {
            let url = try store.recordingURL(filename: name)
            for file in [url, url.deletingPathExtension().appendingPathExtension("jsonl"),
                         store.directory.appendingPathComponent(".\(name).part")] {
                freed += Self.size(of: file)
                try Self.remove(file)
            }
            removed.append(name)
        }
        return freed
    }

    /// Completed records that ended more than `days` ago, for the retention setting.
    public static func olderThan(_ days: Int, in sessions: [CourtSession], now: Date = Date()) -> [CourtSession] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return sessions.filter { $0.state == .completed && ($0.endedAt ?? $0.startedAt) < cutoff }
    }

    // MARK: Clips, logs, leftovers

    /// Clears fetched clips (they can be fetched or cut again). Skips the records in `inUse`.
    @discardableResult public func clearClips(inUse: Set<UUID>) throws -> Int64 {
        let folder = store.directory.appendingPathComponent(SessionStore.clipsFolder, isDirectory: true)
        let busy = Set(inUse.map { $0.uuidString.lowercased() })
        var freed: Int64 = 0
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where !busy.contains(url.lastPathComponent.lowercased()) {
            freed += Self.size(of: url); try Self.remove(url)
        }
        return freed
    }

    /// Clears detection and camera-status logs of records not in use.
    @discardableResult public func clearLogs(inUse: Set<UUID>) throws -> Int64 {
        let busy = Set(inUse.map { $0.uuidString.lowercased() })
        var freed: Int64 = 0
        for url in (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            guard name.hasSuffix("-analysis.jsonl") || name.hasSuffix("-status.jsonl"), !busy.contains(String(name.prefix(36)).lowercased()) else { continue }
            freed += Self.size(of: url); try Self.remove(url)
        }
        return freed
    }

    /// Files no record lists. Only call when nothing is being recorded, saved or received.
    public func leftovers(sessions: [CourtSession]) -> [URL] {
        let listed = Set(sessions.flatMap(\.recordingFilenames))
        let ids = Set(sessions.map { $0.id.uuidString.lowercased() })
        var urls = ((try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { Self.kind(of: $0.lastPathComponent, listed: listed, ids: ids) == .leftover }
        let clips = store.directory.appendingPathComponent(SessionStore.clipsFolder, isDirectory: true)
        urls += ((try? FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil)) ?? [])
            .filter { !ids.contains($0.lastPathComponent.lowercased()) }
        return urls
    }
    public func leftoverBytes(sessions: [CourtSession]) -> Int64 { leftovers(sessions: sessions).reduce(0) { $0 + Self.size(of: $1) } }

    @discardableResult public func clearLeftovers(sessions: [CourtSession]) throws -> Int64 {
        var freed: Int64 = 0
        for url in leftovers(sessions: sessions) { freed += Self.size(of: url); try Self.remove(url) }
        return freed
    }

    // MARK: Free space

    /// Space the system will give to an important write on the volume holding `directory`.
    public static func freeBytes(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
    /// Recording is about 60 MB a minute (8 Mbps H.264 at 1080p60).
    public static let bytesPerRecordingMinute: Int64 = 60 << 20
    public static func recordingMinutes(freeBytes: Int64) -> Int { Int(max(0, freeBytes) / bytesPerRecordingMinute) }

    // MARK: Files

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
    static func remove(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {}
    }
}
