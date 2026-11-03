import Foundation

public enum SessionKind: String, Codable, CaseIterable, Sendable { case training, match }
public enum SessionState: String, Codable, Sendable { case active, paused, completed, interrupted }
public enum SessionEventKind: String, Codable, Sendable { case marker, point, pause, resume, finish, interruption }
public struct SessionEvent: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let kind: SessionEventKind
    public let date: Date
    public let elapsed: TimeInterval
    public let label: String?
    public let sourcePTS: Double?
    public let streamID: UUID?
}
public struct StoredRecording: Codable, Identifiable, Sendable {
    public var id: UUID
    public var filename: String
    public var frames: Int
    public var duration: Double
    public var firstPTS: Double
    public var streamID: UUID?
    public init(id: UUID = UUID(), filename: String, frames: Int, duration: Double, firstPTS: Double, streamID: UUID? = nil) {
        self.id = id; self.filename = filename; self.frames = frames; self.duration = duration; self.firstPTS = firstPTS; self.streamID = streamID
    }
}
/// A span where live analysis did not run (load shedding, model failure) while recording continued.
/// Shots inside it stay unknown unless offline backfill fills them from the recording.
public struct AnalysisGap: Codable, Equatable, Sendable {
    public var streamID: UUID?
    public var startPTS: Double
    public var endPTS: Double?
    public var reason: String
    public var backfilled: Bool?
    public init(streamID: UUID?, startPTS: Double, endPTS: Double? = nil, reason: String) {
        self.streamID = streamID; self.startPTS = startPTS; self.endPTS = endPTS; self.reason = reason
    }
}
public struct SessionAnalysisSummary: Codable, Sendable {
    public fileprivate(set) var analyzedFrames = 0
    public var analyzedSamples: Int { analyzedFrames }
    public fileprivate(set) var peakPeople = 0
    public fileprivate(set) var detectedPersonSamples = 0
    public fileprivate(set) var movingPersonSamples = 0
    public fileprivate(set) var totalAnalysisMilliseconds = 0.0
    /// Image occupancy, 12 columns × 8 rows, top-left origin. This is not calibrated court distance.
    public fileprivate(set) var heatmap = Array(repeating: 0, count: 96)
    public var averageAnalysisMilliseconds: Double { analyzedFrames > 0 ? totalAnalysisMilliseconds / Double(analyzedFrames) : 0 }
    public init() {}
}

public struct CourtSession: Codable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let kind: SessionKind
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var state: SessionState = .active
    public private(set) var events: [SessionEvent] = []
    public private(set) var analysis = SessionAnalysisSummary()
    public private(set) var recordings: [StoredRecording] = []
    public var recordingFilenames: [String] { recordings.map(\.filename) }
    private var accumulatedElapsed: TimeInterval = 0
    private var activeSince: Date?
    /// Optional fields keep pre-analysis sessions readable without fabricated shot facts.
    public private(set) var tennisEvents: [TennisShotEvent]?
    public private(set) var tennisModelVersion: String?
    public private(set) var tennisCalibration: TennisCourtCalibrationState?
    /// Display name of the camera device that recorded and analysed this session; nil for older records.
    public private(set) var capturedOn: String?
    public private(set) var analysisGaps: [AnalysisGap]?
    public init(id: UUID = UUID(), title: String, kind: SessionKind = .training, startedAt: Date = Date()) {
        self.id = id; self.title = title; self.kind = kind
        self.startedAt = startedAt; activeSince = startedAt
    }
    public mutating func recordTennisAnalysis(_ snapshot: TennisAnalysisSnapshot, minimumPTS: Double = 0, completingPausedSegment: Bool = false) {
        guard state == .active || (state == .paused && completingPausedSegment) else { return }
        var saved = tennisEvents ?? []
        var indices = Dictionary(saved.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for event in snapshot.events where event.streamID == snapshot.streamID && event.sourcePTS >= minimumPTS {
            if let index = indices[event.id] { saved[index] = event }
            else { indices[event.id] = saved.count; saved.append(event) }
        }
        tennisEvents = saved
        tennisModelVersion = snapshot.modelVersion
        tennisCalibration = snapshot.calibration
    }
    /// Camera-side late updates (e.g. a bounce result after pause) for rows already in the ledger,
    /// regardless of state. Returns the rows that actually changed.
    @discardableResult public mutating func updateKnownTennisEvents(_ events: [TennisShotEvent]) -> [TennisShotEvent] {
        guard var saved = tennisEvents, !saved.isEmpty else { return [] }
        let indices = Dictionary(saved.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var changed: [TennisShotEvent] = []
        for event in events { if let index = indices[event.id], saved[index] != event { saved[index] = event; changed.append(event) } }
        if !changed.isEmpty { tennisEvents = saved }
        return changed
    }
    /// Display-side mirror of the camera's ledger: stable-ID upsert that ignores state, stream and
    /// segment filters, because the camera already decided what belongs to the session.
    public mutating func mergeRemoteTennisEvents(_ events: [TennisShotEvent], calibration: TennisCourtCalibrationState? = nil, modelVersion: String? = nil) {
        var saved = tennisEvents ?? []
        var indices = Dictionary(saved.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for event in events {
            if let index = indices[event.id] { saved[index] = event } else { indices[event.id] = saved.count; saved.append(event) }
        }
        if tennisEvents != nil || !events.isEmpty { tennisEvents = saved.sorted { $0.sourcePTS < $1.sourcePTS } }
        if let calibration { tennisCalibration = calibration }
        if let modelVersion { tennisModelVersion = modelVersion }
    }
    /// Session metadata without the shot ledger, for frequent camera → display state messages.
    public func withoutTennisEvents() -> CourtSession { var copy = self; copy.tennisEvents = nil; return copy }
    public mutating func setCapturedOn(_ device: String) { capturedOn = String(device.prefix(80)) }
    public mutating func openAnalysisGap(streamID: UUID?, at pts: Double, reason: String) {
        guard pts.isFinite, analysisGaps?.last.map({ $0.endPTS != nil }) ?? true else { return }
        analysisGaps = (analysisGaps ?? []) + [AnalysisGap(streamID: streamID, startPTS: pts, reason: String(reason.prefix(200)))]
    }
    public mutating func closeAnalysisGap(at pts: Double) {
        guard var gaps = analysisGaps, let last = gaps.indices.last, gaps[last].endPTS == nil else { return }
        gaps[last].endPTS = pts.isFinite ? max(pts, gaps[last].startPTS) : gaps[last].startPTS
        analysisGaps = gaps
    }
    public mutating func markAnalysisGapsBackfilled(_ indices: [Int]) {
        for index in indices where analysisGaps?.indices.contains(index) == true { analysisGaps?[index].backfilled = true }
    }
    /// A finished record made from an imported video: its length is the video's, not how long the
    /// analysis took.
    public mutating func setImportedDuration(_ seconds: TimeInterval) {
        guard state == .completed, seconds.isFinite, seconds >= 0 else { return }
        accumulatedElapsed = seconds
    }
    public func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulatedElapsed + (state == .active ? max(0, date.timeIntervalSince(activeSince ?? date)) : 0)
    }
    public mutating func pause(at date: Date = Date()) {
        guard state == .active else { return }
        accumulatedElapsed = elapsed(at: date); activeSince = nil; state = .paused
        append(.pause, at: date)
    }
    public mutating func resume(at date: Date = Date()) {
        guard state == .paused || state == .interrupted else { return }
        state = .active; endedAt = nil; activeSince = date; append(.resume, at: date)
    }
    public mutating func finish(at date: Date = Date()) {
        guard state != .completed else { return }
        accumulatedElapsed = elapsed(at: date); activeSince = nil; state = .completed; endedAt = date
        append(.finish, at: date)
    }
    public mutating func addMarker(_ label: String, at date: Date = Date(), sourcePTS: Double? = nil, streamID: UUID? = nil) {
        guard state == .active else { return }; append(.marker, at: date, label: String(label.prefix(200)), sourcePTS: sourcePTS, streamID: streamID)
    }
    public mutating func recordAnalysis(_ snapshot: AnalysisSnapshot) {
        guard state == .active else { return }
        analysis.peakPeople = max(analysis.peakPeople, snapshot.people.count)
        analysis.analyzedFrames += 1; analysis.detectedPersonSamples += snapshot.people.count
        analysis.movingPersonSamples += snapshot.people.filter(\.isMoving).count
        analysis.totalAnalysisMilliseconds += snapshot.analysisMilliseconds
        // Count this sample, not the tracker's cumulative heatmap (which would double count).
        for person in snapshot.people {
            let x = min(11, max(0, Int(person.box.bottomCenter.x * 12)))
            let y = min(7, max(0, Int(person.box.bottomCenter.y * 8)))
            analysis.heatmap[y * 12 + x] += 1
        }
    }
    public mutating func addRecording(_ recording: StoredRecording) throws {
        try SessionStore.validateRecordingFilename(recording.filename)
        guard recording.frames >= 0, recording.duration.isFinite, recording.duration >= 0, recording.firstPTS.isFinite, recording.firstPTS >= 0 else {
            throw CourtError.message("录像时间信息无效。")
        }
        if !recordings.contains(where: { $0.id == recording.id }) { recordings.append(recording) }
    }
    /// Persist elapsed time at each checkpoint so an app crash never adds downtime to duration.
    fileprivate mutating func checkpoint(at date: Date) {
        if state == .active { accumulatedElapsed = elapsed(at: date); activeSince = date }
    }
    fileprivate mutating func recover() {
        guard state == .active || state == .paused else { return }
        state = .interrupted; activeSince = nil
        append(.interruption, at: Date(), label: "上次会话未正常结束")
    }
    private mutating func append(_ kind: SessionEventKind, at date: Date, label: String? = nil, sourcePTS: Double? = nil, streamID: UUID? = nil) {
        events.append(SessionEvent(kind: kind, date: date, elapsed: elapsed(at: date), label: label, sourcePTS: sourcePTS.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, streamID: streamID))
    }
}

/// Caller serializes access. Each session is an individually atomic JSON file; corrupt files fail visibly.
public final class SessionStore {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func save(_ session: CourtSession, at date: Date = Date()) throws {
        var checkpoint = session; checkpoint.checkpoint(at: date)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(checkpoint).write(to: sessionFileURL(id: session.id), options: .atomic)
    }
    public func loadAll(recoverUnfinished: Bool = true) throws -> [CourtSession] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var sessions: [CourtSession] = []
        for url in urls where url.pathExtension == "json" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            var session = try JSONDecoder().decode(CourtSession.self, from: Data(contentsOf: url))
            guard session.id.uuidString.lowercased() == url.deletingPathExtension().lastPathComponent.lowercased() else {
                throw CourtError.message("会话文件与记录编号不一致，原文件已保留。")
            }
            for recording in session.recordings {
                try Self.validateRecordingFilename(recording.filename)
                guard recording.frames >= 0, recording.duration.isFinite, recording.duration >= 0,
                      recording.firstPTS.isFinite, recording.firstPTS >= 0 else {
                    throw CourtError.message("已保存的录像时间信息无效，原文件已保留。")
                }
            }
            if recoverUnfinished, session.state == .active || session.state == .paused {
                session.recover(); try save(session)
            }
            sessions.append(session)
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }
    public func sessionFileURL(id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
    /// Per-shot clips fetched from a camera live in `Clips/<session id, lowercased>/`.
    public static let clipsFolder = "Clips"
    public func clipsDirectory(id: UUID) -> URL {
        directory.appendingPathComponent(Self.clipsFolder, isDirectory: true).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Every file this device keeps for one session: its JSON, each recording with the timestamp
    /// log `MovieRecorder` writes beside it and any partial transfer, the person-detection and
    /// camera-status logs, and fetched clips. Recordings another saved session also lists are kept.
    public func files(for session: CourtSession) -> [URL] {
        let id = session.id.uuidString
        var urls = [directory.appendingPathComponent("\(id)-analysis.jsonl"),
                    directory.appendingPathComponent("\(id)-status.jsonl"),
                    clipsDirectory(id: session.id)]
        let shared = recordingsListed(excluding: session.id)
        for filename in Set(session.recordingFilenames) where !shared.contains(filename) {
            guard (try? Self.validateRecordingFilename(filename)) != nil else { continue }
            let recording = directory.appendingPathComponent(filename)
            urls += [recording, recording.deletingPathExtension().appendingPathExtension("jsonl"),
                     directory.appendingPathComponent(".\(filename).part")]
        }
        return urls + [sessionFileURL(id: session.id)]
    }

    /// Deletes a saved session and its files from this device only. Recordings and logs go first
    /// and the JSON last, so a failure leaves the record in history and the delete can be retried.
    /// Files that are already missing are fine (for example a mirror whose recording stayed on the camera).
    public func delete(_ session: CourtSession) throws {
        // The saved copy may list recordings the caller's snapshot has not seen yet.
        let saved = (try? Data(contentsOf: sessionFileURL(id: session.id))).flatMap { try? JSONDecoder().decode(CourtSession.self, from: $0) }
        var urls = files(for: session)
        if let saved, saved.id == session.id { urls = Array(Set(urls).union(files(for: saved))) }
        let json = sessionFileURL(id: session.id)
        for url in urls where url != json { try Self.remove(url) }
        try Self.remove(json)
    }

    private static func remove(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {}
    }

    private func recordingsListed(excluding id: UUID) -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var names = Set<String>()
        for url in urls where url.pathExtension == "json" {
            guard let other = UUID(uuidString: url.deletingPathExtension().lastPathComponent), other != id,
                  let data = try? Data(contentsOf: url), let session = try? JSONDecoder().decode(CourtSession.self, from: data) else { continue }
            names.formUnion(session.recordingFilenames)
        }
        return names
    }

    public func recordingURL(filename: String) throws -> URL {
        try Self.validateRecordingFilename(filename)
        let url = directory.appendingPathComponent(filename)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink,
              // Compare paths, not URLs: whether a directory URL ends in "/" depends on whether the
              // folder existed when the URL was made, so equal folders can compare unequal.
              url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path
                == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CourtError.message("录像文件不能指向会话目录之外。")
        }
        return url
    }
    public static func validateRecordingFilename(_ filename: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"),
              !filename.contains(":"), !filename.contains("\0"), filename.utf8.count <= 255 else {
            throw CourtError.message("录像必须使用安全的相对文件名。")
        }
    }
}
