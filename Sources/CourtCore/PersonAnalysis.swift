import Foundation

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
/// Normalized image coordinates, top-left origin. No court calibration or physical units.
public struct NormalizedBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var bottomCenter: NormalizedPoint { NormalizedPoint(x: x + width / 2, y: y + height) }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    fileprivate var valid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.001 && y + height <= 1.001
    }
}
public struct PersonDetection: Sendable {
    public let box: NormalizedBox
    public let confidence: Double
    public init(box: NormalizedBox, confidence: Double) { self.box = box; self.confidence = confidence }
}
public struct TrackPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let pts: Double
}
/// IDs only associate nearby image detections over a short period, never establish player identity.
public struct TrackedPerson: Codable, Identifiable, Sendable {
    public let id: UUID
    public let box: NormalizedBox
    public let confidence: Double
    public let trail: [TrackPoint]
    public let isMoving: Bool
}
public struct AnalysisSnapshot: Codable, Sendable {
    public let streamID: UUID
    public let pts: Double
    public let people: [TrackedPerson]
    public let analysisMilliseconds: Double
    public let sampleCount: Int
    public let heatmap: [Int]
    public init(streamID: UUID, pts: Double, people: [TrackedPerson], analysisMilliseconds: Double, sampleCount: Int, heatmap: [Int]) {
        self.streamID = streamID; self.pts = pts; self.people = people
        self.analysisMilliseconds = analysisMilliseconds; self.sampleCount = sampleCount; self.heatmap = heatmap
    }
}

/// Single-queue tracker. Greedy one-to-one association by overlap and foot-point proximity.
public final class PersonTracker {
    private struct Track {
        var id = UUID()
        var box: NormalizedBox
        var confidence: Double
        var trail: [TrackPoint]
        var lastPTS: Double
        var moving = false
    }
    public let maximumMissingSeconds: Double
    private var tracks: [Track] = []
    private var streamID: UUID?
    private var lastPTS: Double?
    private var samples = 0
    private var heatmap = Array(repeating: 0, count: 96)
    public init(maximumMissingSeconds: Double = 0.8) { self.maximumMissingSeconds = max(0.1, maximumMissingSeconds) }
    public func reset() { tracks = []; streamID = nil; lastPTS = nil; samples = 0; heatmap = Array(repeating: 0, count: 96) }
    public func update(detections: [PersonDetection], streamID: UUID, pts: Double, analysisMilliseconds: Double = 0) -> AnalysisSnapshot {
        if self.streamID != streamID || !pts.isFinite || pts < 0 || (lastPTS.map { pts <= $0 } ?? false) { reset() }
        self.streamID = streamID
        guard pts.isFinite, pts >= 0 else {
            return AnalysisSnapshot(streamID: streamID, pts: 0, people: [], analysisMilliseconds: 0, sampleCount: 0, heatmap: heatmap)
        }
        lastPTS = pts; samples += 1
        tracks.removeAll { pts - $0.lastPTS > maximumMissingSeconds }
        let detections = Array(detections.filter { $0.confidence.isFinite && $0.confidence >= 0.4 && $0.box.valid }.prefix(32))
        var pairs: [(Double, Int, Int)] = []
        for (i, track) in tracks.enumerated() {
            for (j, detection) in detections.enumerated() {
                let a = track.box.bottomCenter, b = detection.box.bottomCenter
                let distance = hypot(a.x - b.x, a.y - b.y)
                let intersection = track.box.rect.intersection(detection.box.rect)
                let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
                let union = track.box.width * track.box.height + detection.box.width * detection.box.height - intersectionArea
                let overlap = union > 0 ? intersectionArea / union : 0
                // A conservative gate reduces jumps; crossings can still swap identities.
                if distance < min(0.18, 0.055 + (pts - track.lastPTS) * 0.25) || overlap > 0.2 {
                    pairs.append((distance + (1 - overlap) * 0.06, i, j))
                }
            }
        }
        pairs.sort { $0.0 < $1.0 }
        var usedTracks = Set<Int>(), usedDetections = Set<Int>(), visible: [TrackedPerson] = []
        for (_, i, j) in pairs where !usedTracks.contains(i) && !usedDetections.contains(j) {
            usedTracks.insert(i); usedDetections.insert(j)
            let detection = detections[j], foot = detection.box.bottomCenter
            tracks[i].box = detection.box; tracks[i].confidence = detection.confidence; tracks[i].lastPTS = pts
            tracks[i].trail.append(TrackPoint(x: foot.x, y: foot.y, pts: pts))
            tracks[i].trail.removeAll { pts - $0.pts > 6 }
            if tracks[i].trail.count > 32 { tracks[i].trail.removeFirst(tracks[i].trail.count - 32) }
            // Windowed normalized-image displacement suppresses per-frame box jitter.
            if let reference = tracks[i].trail.last(where: { pts - $0.pts >= 0.4 && pts - $0.pts <= 1.2 }) {
                tracks[i].moving = hypot(foot.x - reference.x, foot.y - reference.y) / (pts - reference.pts) > 0.035
            } else { tracks[i].moving = false }
            visible.append(person(tracks[i]))
        }
        for (j, detection) in detections.enumerated() where !usedDetections.contains(j) {
            let foot = detection.box.bottomCenter
            let track = Track(box: detection.box, confidence: detection.confidence, trail: [TrackPoint(x: foot.x, y: foot.y, pts: pts)], lastPTS: pts)
            tracks.append(track); visible.append(person(track))
        }
        for person in visible {
            let foot = person.box.bottomCenter
            heatmap[min(7, Int(foot.y * 8)) * 12 + min(11, Int(foot.x * 12))] += 1
        }
        return AnalysisSnapshot(streamID: streamID, pts: pts, people: visible, analysisMilliseconds: analysisMilliseconds.isFinite ? max(0, analysisMilliseconds) : 0, sampleCount: samples, heatmap: heatmap)
    }
    private func person(_ track: Track) -> TrackedPerson {
        TrackedPerson(id: track.id, box: track.box, confidence: track.confidence, trail: track.trail, isMoving: track.moving)
    }
}
