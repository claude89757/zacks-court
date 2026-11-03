import Foundation

public extension TennisShotEvent {
    var validSpeedKPH: Double? {
        guard let speedKPH, speedKPH.isFinite, speedKPH > 0 else { return nil }
        return speedKPH
    }
    var hasCourtPlacement: Bool {
        guard let x = bounce?.xMeters, let y = bounce?.yMeters else { return false }
        return x.isFinite && y.isFinite
    }
}

public struct TennisEventSummary: Sendable {
    public let count: Int
    public let speedCount: Int
    public let placementCount: Int
    public let averageSpeed: Double?
    public let maximumSpeed: Double?
    public let latestValidSpeed: TennisShotEvent?
    public init(events: [TennisShotEvent]) {
        let speeds = events.compactMap(\.validSpeedKPH)
        count = events.count; speedCount = speeds.count
        placementCount = events.filter(\.hasCourtPlacement).count
        averageSpeed = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
        maximumSpeed = speeds.max()
        latestValidSpeed = events.last { $0.validSpeedKPH != nil }
    }
}

/// What a finished record leaves behind, for the summary card shown right after 结束. Built only
/// from the saved session: unknown speeds stay out of the top and average (never 0), and a session
/// saved without a shot ledger has no shot count at all rather than 0.
public struct CourtSessionSummary: Sendable, Equatable {
    public struct StrokeCount: Sendable, Equatable {
        public let kind: TennisStrokeKind
        public let count: Int
    }
    public let sessionID: UUID
    public let title: String
    public let duration: TimeInterval
    /// nil when the record has no shot ledger (older saves, or analysis never ran).
    public let shotCount: Int?
    /// Shots with a usable speed.
    public let speedCount: Int
    public let maximumSpeed: Double?
    public let averageSpeed: Double?
    /// Stroke counts in `TennisStrokeKind.allCases` order, kinds without shots left out.
    public let strokes: [StrokeCount]
    public let markerCount: Int

    public init(session: CourtSession, now: Date = Date()) {
        sessionID = session.id
        title = session.title
        duration = session.elapsed(at: session.endedAt ?? now)
        let events = session.tennisEvents ?? []
        let summary = TennisEventSummary(events: events)
        shotCount = session.tennisEvents.map(\.count)
        speedCount = summary.speedCount
        maximumSpeed = summary.maximumSpeed
        averageSpeed = summary.averageSpeed
        strokes = TennisStrokeKind.allCases.compactMap { kind in
            let count = events.filter { $0.stroke == kind }.count
            return count > 0 ? StrokeCount(kind: kind, count: count) : nil
        }
        markerCount = session.events.filter { $0.kind == .marker }.count
    }
}

/// Serve-only speed readout for the courtside board. Only serves with a usable speed count;
/// serves without one stay out of max/min/average and are never treated as 0.
public struct TennisServeSummary: Sendable {
    public struct Point: Identifiable, Sendable, Equatable {
        public let id: UUID
        /// 1-based position among all serves in the input, including serves without a speed.
        public let serveNumber: Int
        public let speedKPH: Double
    }
    /// Every row classified as a serve, in input order.
    public let serveCount: Int
    /// Serves with a usable speed, in input order.
    public let points: [Point]
    public let maximumSpeed: Double?
    public let minimumSpeed: Double?
    public let averageSpeed: Double?
    /// The newest serve with a usable speed; it stays shown until the next one.
    public let latest: Point?
    /// The newest serve row, which may have no speed yet.
    public let latestServe: TennisShotEvent?
    public init(events: [TennisShotEvent]) {
        let serves = events.filter { $0.stroke == .serve }
        serveCount = serves.count
        points = serves.enumerated().compactMap { index, event in
            event.validSpeedKPH.map { Point(id: event.id, serveNumber: index + 1, speedKPH: $0) }
        }
        let speeds = points.map(\.speedKPH)
        maximumSpeed = speeds.max(); minimumSpeed = speeds.min()
        averageSpeed = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
        latest = points.last; latestServe = serves.last
    }
    /// True when the newest serve has no usable speed, so the readout is holding an older value.
    public var isHoldingPreviousValue: Bool { latestServe.map { $0.validSpeedKPH == nil } ?? false }
}

/// Sequence within a session is authoritative; independent stream PTS clocks can restart.
public struct TennisHistoryShot: Identifiable, Sendable {
    public var id: String { sessionID.uuidString + ":" + event.id.uuidString }
    public let sessionID: UUID
    public let sessionTitle: String
    public let sessionDate: Date
    public let ordinal: Int
    public let event: TennisShotEvent
    public let recording: StoredRecording?
    public var recordingSeconds: Double? { recording.map { max(0, event.sourcePTS - $0.firstPTS) } }
    public static func index(sessions: [CourtSession]) -> [Self] {
        sessions.flatMap { session in
            (session.tennisEvents ?? []).enumerated().map { offset, event in
                Self(sessionID: session.id, sessionTitle: session.title, sessionDate: session.startedAt,
                     ordinal: offset + 1, event: event,
                     recording: session.recordings.first {
                         $0.streamID == event.streamID && event.sourcePTS >= $0.firstPTS && event.sourcePTS <= $0.firstPTS + $0.duration
                     })
            }
        }
    }
}

public struct TennisHistoryQuery: Sendable, Equatable {
    public enum Availability: String, CaseIterable, Sendable { case all, speed, placement, missingSpeed, missingPlacement }
    public enum Order: String, CaseIterable, Sendable { case newest, fastest, oldest }
    public var text = ""
    public var from: Date?
    public var until: Date?
    public var stroke: TennisStrokeKind?
    public var minimumSpeed: Double?
    public var maximumSpeed: Double?
    public var availability: Availability = .all
    public var order: Order = .newest
    public init() {}
    public func results(in shots: [TennisHistoryShot]) -> [TennisHistoryShot] {
        if let minimumSpeed, !minimumSpeed.isFinite || minimumSpeed < 0 { return [] }
        if let maximumSpeed, !maximumSpeed.isFinite || maximumSpeed < 0 { return [] }
        if let minimumSpeed, let maximumSpeed, minimumSpeed > maximumSpeed { return [] }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return shots.filter { row in
            if !text.isEmpty && !row.sessionTitle.localizedCaseInsensitiveContains(text) { return false }
            if let from, row.sessionDate < from { return false }
            if let until, row.sessionDate >= until { return false }
            if let stroke, row.event.stroke != stroke { return false }
            if minimumSpeed != nil || maximumSpeed != nil {
                guard let speed = row.event.validSpeedKPH else { return false }
                if let minimumSpeed, speed < minimumSpeed { return false }
                if let maximumSpeed, speed > maximumSpeed { return false }
            }
            switch availability {
            case .all: return true
            case .speed: return row.event.validSpeedKPH != nil
            case .placement: return row.event.hasCourtPlacement
            case .missingSpeed: return row.event.validSpeedKPH == nil
            case .missingPlacement: return !row.event.hasCourtPlacement
            }
        }.sorted { a, b in
            if order == .fastest, a.event.validSpeedKPH != b.event.validSpeedKPH {
                return (a.event.validSpeedKPH ?? -.infinity) > (b.event.validSpeedKPH ?? -.infinity)
            }
            if a.sessionDate != b.sessionDate { return order == .oldest ? a.sessionDate < b.sessionDate : a.sessionDate > b.sessionDate }
            if a.sessionID != b.sessionID { return a.sessionID.uuidString < b.sessionID.uuidString }
            return order == .oldest ? a.ordinal < b.ordinal : a.ordinal > b.ordinal
        }
    }
}
