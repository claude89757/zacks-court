import Foundation
import CoreML

public enum TennisHandedness: String, Codable, Sendable { case unknown, right, left }
public enum TennisStrokeKind: String, Codable, CaseIterable, Sendable {
    case groundstroke, forehand, backhand, serve, volley, overhead, feed, unknown
}
public struct TennisCourtCalibrationState: Codable, Equatable, Sendable {
    public var isAvailable: Bool
    public var landmarkCount: Int
    public var validationErrorMeters: Double?
    public var reason: String?
    public init(isAvailable: Bool = false, landmarkCount: Int = 0, validationErrorMeters: Double? = nil, reason: String? = "等待场地地标") {
        self.isAvailable = isAvailable; self.landmarkCount = landmarkCount; self.validationErrorMeters = validationErrorMeters; self.reason = reason
    }
}
public struct TennisBounceEstimate: Codable, Equatable, Sendable {
    public var sourcePTS: Double
    public var imagePoint: NormalizedPoint?
    /// Court surface: x=0 at near-left doubles sideline, y=0 at near baseline.
    /// x increases right to 10.97 m; y increases toward far baseline at 23.77 m.
    public var xMeters: Double?
    public var yMeters: Double?
    public var confidence: Double
    /// Engine wording, kept for diagnostics and for older peers. Users see `reasonKind.text`.
    public var reason: String?
    /// Typed reason (optional on the wire; older peers send only `reason`).
    public var reasonCode: TennisReason?
    /// Standard deviations of `xMeters`/`yMeters` from the chain's image noise and frame timing
    /// (optional; nil when the chain does not estimate them).
    public var sigmaXMeters: Double?
    public var sigmaYMeters: Double?
    /// Line call the camera made with the Hawk-Eye settings of the time (optional; nil when Hawk-Eye was
    /// off, the bounce was not judged, or from an older camera).
    public var hawkEye: HawkEyeJudgement?
    public init(sourcePTS: Double, imagePoint: NormalizedPoint? = nil, xMeters: Double? = nil, yMeters: Double? = nil, confidence: Double, reason: String? = nil) {
        self.sourcePTS = sourcePTS; self.imagePoint = imagePoint; self.xMeters = xMeters; self.yMeters = yMeters; self.confidence = confidence; self.reason = reason
        self.reasonCode = reason.map(TennisReason.classify)
    }
    /// The code when the peer sent one, else the legacy string classified.
    public var reasonKind: TennisReason? { reasonCode ?? reason.map(TennisReason.classify) }
}
/// A point in the court frame of `TennisBounceEstimate` plus height, metres.
public struct TennisCourtPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}
public struct TennisShotEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var streamID: UUID
    public var sourcePTS: Double
    public var endPTS: Double?
    public var stroke: TennisStrokeKind
    /// Model softmax score, not a calibrated physical accuracy probability.
    public var confidence: Double
    public var speedKPH: Double?
    /// Engine wording, kept for diagnostics and for older peers. Users see `speedReasonText`.
    public var speedReason: String?
    /// Typed reason (optional on the wire; older peers send only `speedReason`).
    public var speedReasonCode: TennisReason?
    public var bounce: TennisBounceEstimate?
    public var sampleCount: Int
    /// nil for live camera-side results; "offline" for rows filled in afterwards from the recording.
    public var origin: String?
    /// Fitted ball position at the hit (optional; the in-house chain only). Picks a serve's service box.
    public var hit: TennisCourtPoint?
    public init(id: UUID = UUID(), streamID: UUID, sourcePTS: Double, endPTS: Double? = nil, stroke: TennisStrokeKind, confidence: Double, speedKPH: Double? = nil, speedReason: String? = nil, bounce: TennisBounceEstimate? = nil, sampleCount: Int = 1) {
        self.id = id; self.streamID = streamID; self.sourcePTS = sourcePTS; self.endPTS = endPTS; self.stroke = stroke; self.confidence = confidence; self.speedKPH = speedKPH; self.speedReason = speedReason; self.bounce = bounce; self.sampleCount = sampleCount
        self.speedReasonCode = speedReason.map(TennisReason.classify)
    }
    /// Sets the engine wording and its typed reason together.
    public mutating func setSpeedReason(_ detail: String?) {
        speedReason = detail; speedReasonCode = detail.map(TennisReason.classify)
    }
}
public struct TennisAnalysisSnapshot: Codable, Sendable {
    public var streamID: UUID
    public var pts: Double
    public var processedFrames: Int
    public var inferenceMilliseconds: Double
    /// At most 24 recent stable-ID upserts. Later snapshots can fill speed/bounce on an existing event.
    public var events: [TennisShotEvent]
    public var calibration: TennisCourtCalibrationState
    public var modelVersion: String
    public var limitations: [String]
    public init(streamID: UUID, pts: Double, processedFrames: Int, inferenceMilliseconds: Double, events: [TennisShotEvent], calibration: TennisCourtCalibrationState, modelVersion: String, limitations: [String]) {
        self.streamID = streamID; self.pts = pts; self.processedFrames = processedFrames; self.inferenceMilliseconds = inferenceMilliseconds; self.events = events; self.calibration = calibration; self.modelVersion = modelVersion; self.limitations = limitations
    }
}
public struct TennisAnalysisConfiguration {
    public var modelDirectory: URL
    public var nominalFPS: Double
    /// Confirmed near-court hand only; the legacy parameter name is retained for callers.
    public var handedness: TennisHandedness
    public var nearHandedness: TennisHandedness {
        get { handedness }
        set { handedness = newValue }
    }
    public var farHandedness: TennisHandedness
    public var computeUnits: MLComputeUnits
    /// User-selected doubles outer corners, near-left → near-right → far-right → far-left.
    public var manualCourtCorners: [NormalizedPoint]?
    /// When true the engine never runs the bounce search inline; it queues `TennisBounceRequest`s
    /// for a separate lane so bounce spikes cannot stall the ~10 Hz pair cadence (camera-side analysis).
    public var defersBounceLocalization = false
    public init(modelDirectory: URL, nominalFPS: Double = 60, handedness: TennisHandedness = .right, computeUnits: MLComputeUnits = .all, manualCourtCorners: [NormalizedPoint]? = nil, farHandedness: TennisHandedness = .right) {
        self.modelDirectory = modelDirectory; self.nominalFPS = nominalFPS; self.handedness = handedness; self.computeUnits = computeUnits; self.manualCourtCorners = manualCourtCorners; self.farHandedness = farHandedness
    }
}
/// One deferred bounce localization. Holds two analysis-owned frame copies until the lane finishes.
/// `eventID == nil` marks a measurement load probe whose result is discarded.
public struct TennisBounceRequest: @unchecked Sendable {
    public let eventID: UUID?
    public let streamID: UUID
    public let pts: Double
    let first: CVPixelBuffer
    let second: CVPixelBuffer
    let courtScores: MLMultiArray?
}

// Explicit coding so the browser JSON can carry display text next to the stored fields;
// decoding stays synthesized (unknown keys such as the display text are ignored).
extension TennisShotEvent {
    enum CodingKeys: String, CodingKey {
        case id, streamID, sourcePTS, endPTS, stroke, confidence, speedKPH, speedReason, speedReasonCode, bounce, sampleCount, origin, hit
    }
    enum DisplayKeys: String, CodingKey { case speedReasonText, placementReasonText }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(sourcePTS, forKey: .sourcePTS)
        try container.encodeIfPresent(endPTS, forKey: .endPTS)
        try container.encode(stroke, forKey: .stroke)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(speedKPH, forKey: .speedKPH)
        try container.encodeIfPresent(speedReason, forKey: .speedReason)
        try container.encodeIfPresent(speedReasonCode, forKey: .speedReasonCode)
        try container.encodeIfPresent(bounce, forKey: .bounce)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(hit, forKey: .hit)
        guard encoder.userInfo[.courtDisplayText] as? Bool == true else { return }
        var display = encoder.container(keyedBy: DisplayKeys.self)
        try display.encodeIfPresent(speedReasonText, forKey: .speedReasonText)
        try display.encodeIfPresent(placementReasonText, forKey: .placementReasonText)
    }
}
