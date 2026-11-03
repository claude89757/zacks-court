import Foundation
import CoreMedia

/// Inclusive source-PTS evidence window, not an exact physical event timestamp.
public struct IndependentFlightEvidenceWindow: Codable, Sendable {
    public let start: IndependentBallFrameTime
    public let end: IndependentBallFrameTime
    public let basis: String
    public init(start: IndependentBallFrameTime, end: IndependentBallFrameTime, basis: String) {
        self.start = start; self.end = end; self.basis = basis
    }
}

/// Evidence is explicitly bound to the original video. Neither an empty list of
/// interruptions nor a visual ground window proves collision freedom.
public struct IndependentFlightIntervalEvidence: Codable, Sendable {
    public let sourceSHA256: String
    public let interval: IndependentFlightEvidenceWindow
    public let collisionFreeAssumption: String
    /// Suspected net, racket or other interruptions, including uncertain windows.
    public let interruptionWindows: [IndependentFlightEvidenceWindow]
    /// Used only AFTER the unconstrained six-parameter fit. Never supplied to it.
    public let groundCandidateWindow: IndependentFlightEvidenceWindow?
    /// Independent visual contact evidence; never optimized against a speed label.
    public let contactCandidateWindow: IndependentFlightEvidenceWindow?
    /// Required if any part of the contact window precedes actual observations.
    public let contactExtrapolationReason: String?
    public init(sourceSHA256: String, interval: IndependentFlightEvidenceWindow,
                collisionFreeAssumption: String, interruptionWindows: [IndependentFlightEvidenceWindow],
                groundCandidateWindow: IndependentFlightEvidenceWindow? = nil,
                contactCandidateWindow: IndependentFlightEvidenceWindow? = nil,
                contactExtrapolationReason: String? = nil) {
        self.sourceSHA256 = sourceSHA256; self.interval = interval
        self.collisionFreeAssumption = collisionFreeAssumption; self.interruptionWindows = interruptionWindows
        self.groundCandidateWindow = groundCandidateWindow
        self.contactCandidateWindow = contactCandidateWindow; self.contactExtrapolationReason = contactExtrapolationReason
    }
}

public enum IndependentFlightCandidateStatus: String, Encodable, Sendable {
    case unknown, rejected, unqualifiedCandidate
}

/// Instantaneous speed of the SAME fitted free flight at the exact midpoint of
/// an independently supplied contact window. The range varies event time only;
/// it is not a confidence interval and excludes camera/model uncertainty.
public struct IndependentFlightRawContactSpeed: Encodable, Sendable {
    public let midpoint: IndependentBallFrameTime
    public let rawMidpointSpeedKilometersPerHour: Double
    public let rawMinimumSpeedKilometersPerHour: Double, rawMaximumSpeedKilometersPerHour: Double
    public let minimumAtInteriorVerticalApex: Bool
    public let midpointBackwardExtrapolationSeconds: Double
    public let maximumBackwardExtrapolationSeconds: Double
    public let extrapolationReason: String?
}

/// Conditional arithmetic on an assumed camera and gravity. This is neither a
/// shot speed nor a qualified measurement; the interval is exactly the request.
public struct IndependentFlightRawCandidate: Encodable, Sendable {
    public let start: IndependentBallFrameTime, end: IndependentBallFrameTime
    public let durationSeconds: Double
    public let rawMeanPathSpeedMetersPerSecond: Double
    public let rawStartSpeedMetersPerSecond: Double, rawEndSpeedMetersPerSecond: Double
    public let numericalEstimatedAbsoluteErrorMetersPerSecond: Double
    public let numericalFunctionEvaluations: Int
    public let predictedGround: IndependentFreeFlightGroundRoot
    public let predictionReferenceTime: IndependentBallFrameTime
    /// Nil means no independent visual window was supplied, never a match.
    public let groundCandidateWindowMatched: Bool?
    public let rawContactSpeed: IndependentFlightRawContactSpeed?
    /// Contact evaluation can be unavailable while the observed interval remains usable.
    public let contactSpeedUnavailableReasons: [String]
}

public struct IndependentFlightCandidateResult: Encodable, Sendable {
    public let sourceSHA256: String
    public let status: IndependentFlightCandidateStatus
    public let reasons: [String]
    public let evidence: IndependentFlightIntervalEvidence?
    public let selectedFrameIndices: [Int]
    public let fit: IndependentFreeFlightResult?
    public let rawCandidate: IndependentFlightRawCandidate?
    public var speedKilometersPerHour: Double? { nil }
    public var acceptedCamera: IndependentBallisticCamera? { nil }
    public var velocity: [Double]? { nil }
    public var cameraQualified: Bool { false }
    public var physicalAccuracyValidated: Bool { false }
    public var nativeEndToEndSpeedAccepted: Bool { false }
    public var twentyPercentAcceptanceEligible: Bool { false }
    public var formal: Bool { false }
    public var human: Bool { false }
    public var production: Bool { false }
    private enum Key: String, CodingKey {
        case sourceSHA256, status, reasons, evidence, selectedFrameIndices, fit, rawCandidate
        case speedKilometersPerHour, acceptedCamera, velocity, cameraQualified, physicalAccuracyValidated
        case nativeEndToEndSpeedAccepted, twentyPercentAcceptanceEligible, formal, human, production
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(sourceSHA256, forKey: .sourceSHA256); try c.encode(status, forKey: .status)
        try c.encode(reasons, forKey: .reasons); try c.encode(evidence, forKey: .evidence)
        try c.encode(selectedFrameIndices, forKey: .selectedFrameIndices); try c.encode(fit, forKey: .fit)
        try c.encode(rawCandidate, forKey: .rawCandidate)
        for key in [Key.speedKilometersPerHour, .acceptedCamera, .velocity] { try c.encodeNil(forKey: key) }
        for key in [Key.cameraQualified, .physicalAccuracyValidated, .nativeEndToEndSpeedAccepted,
                    .twentyPercentAcceptanceEligible, .formal, .human, .production] { try c.encode(false, forKey: key) }
    }
}

/// Bridges the actual analyzer output to the existing free-flight solver. No
/// candidate reselection, interpolation, event fitting, camera fitting or ML run.
public enum IndependentFlightCandidateBuilder {
    private struct Frame: Decodable {
        let decodeIndex: Int
        let time: IndependentBallFrameTime
        let presentationTime: IndependentLocalVideoTime
        let transform: IndependentBallImageTransform
        let segmentIndex: UInt64
        let state: IndependentLocalVideoFrameState
        let unavailableReason: String?
        let selection: IndependentBallTrackSelection?
        init(_ f: IndependentLocalVideoFrameResult) {
            decodeIndex = f.decodeIndex; time = f.time; presentationTime = f.presentationTime
            transform = f.transform; segmentIndex = f.segmentIndex; state = f.state
            unavailableReason = f.unavailableReason; selection = f.selection
        }
    }
    private struct SavedAnalysis: Decodable {
        let backendID: String, sourceSHA256: String
        let width: Int, height: Int
        let nominalFPS: Double
        let frames: [Frame]
    }

    public static func build(analysis: IndependentLocalVideoResult, camera: IndependentBallisticCamera?,
                             evidence: IndependentFlightIntervalEvidence?, configuration: IndependentBallisticConfiguration) throws -> IndependentFlightCandidateResult {
        try build(source: analysis.sourceSHA256, width: analysis.metadata.naturalWidth,
                  height: analysis.metadata.naturalHeight, nominalFPS: analysis.metadata.nominalFPS,
                  frames: analysis.frames.map(Frame.init), camera: camera, evidence: evidence, configuration: configuration)
    }

    /// Reuses a saved IndependentLocalVideoResult without decoding the video or
    /// running ML again. This is artifact replay, not independent source verification.
    public static func build(savedAnalysisJSON: Data, camera: IndependentBallisticCamera?,
                             evidence: IndependentFlightIntervalEvidence?, configuration: IndependentBallisticConfiguration) throws -> IndependentFlightCandidateResult {
        let saved = try JSONDecoder().decode(SavedAnalysis.self, from: savedAnalysisJSON)
        try require(saved.backendID == IndependentLocalVideoResult.backendIdentifier, "Unsupported saved analyzer backend")
        return try build(source: saved.sourceSHA256, width: saved.width, height: saved.height,
                         nominalFPS: saved.nominalFPS, frames: saved.frames, camera: camera, evidence: evidence, configuration: configuration)
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw IndependentBallisticError.invalid(reason) }
    }
    private static func bounded(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 4096
    }
    private static func window(_ w: IndependentFlightEvidenceWindow) throws -> (CMTime, CMTime) {
        let a = try w.start.mediaTime(), b = try w.end.mediaTime()
        try require(CMTimeCompare(a, b) <= 0 && bounded(w.basis), "Invalid evidence window or missing basis")
        return (a, b)
    }

    /// Internal pure post-fit evaluation also lets tests exercise an interior
    /// vertical apex without choosing real observations to obtain that result.
    static func contactSpeed(window contact: IndependentFlightEvidenceWindow?, referenceTime: IndependentBallFrameTime,
                             velocity: [Double], gravity: Double, extrapolationReason: String?,
                             interruptions: [IndependentFlightEvidenceWindow]) -> (value: IndependentFlightRawContactSpeed?, reasons: [String]) {
        guard let contact else { return (nil, []) }
        do {
            let (start, end) = try window(contact), reference = try referenceTime.mediaTime()
            guard CMTimeCompare(end, reference) <= 0 else { return (nil, ["contact_window_after_first_observation"]) }
            let outside = CMTimeCompare(start, reference) < 0
            if outside && extrapolationReason.map(bounded) != true { return (nil, ["contact_extrapolation_reason_required"]) }
            if let extrapolationReason, !bounded(extrapolationReason) { return (nil, ["invalid_contact_extrapolation_reason"]) }
            for interruption in interruptions {
                let (a, b) = try window(interruption)
                if CMTimeCompare(a, reference) <= 0 && CMTimeCompare(b, start) >= 0 {
                    return (nil, ["interruption_between_contact_and_first_observation"])
                }
            }
            try require(velocity.count == 3 && velocity.allSatisfy(\.isFinite) && gravity.isFinite && gravity > 0,
                        "Invalid contact velocity or gravity")
            // Halve the exact local rational difference before adding it to the
            // large source epoch. Neither Double seconds nor frame rounding is
            // used to construct the midpoint. Unrepresentable CMTimes stay unknown.
            let delta = CMTimeSubtract(end, start)
            try require(delta.isNumeric && !delta.flags.contains(.hasBeenRounded), "Inexact contact window duration")
            let half: CMTime
            if delta.value % 2 == 0 {
                half = CMTime(value: delta.value/2, timescale: delta.timescale)
            } else {
                let doubled = delta.timescale.multipliedReportingOverflow(by: 2)
                try require(!doubled.overflow && doubled.partialValue > 0, "Contact midpoint timescale overflow")
                half = CMTime(value: delta.value, timescale: doubled.partialValue)
            }
            let midpoint = CMTimeAdd(start, half)
            try require(midpoint.isNumeric && !midpoint.flags.contains(.hasBeenRounded), "Unrepresentable exact contact midpoint")
            let left = CMTimeSubtract(midpoint, start), right = CMTimeSubtract(end, midpoint)
            try require(left.isNumeric && right.isNumeric && !left.flags.contains(.hasBeenRounded) && !right.flags.contains(.hasBeenRounded)
                        && CMTimeCompare(left, right) == 0, "Inexact contact midpoint")
            let a = try IndependentBallisticInput.seconds(start, minus: reference)
            let b = try IndependentBallisticInput.seconds(end, minus: reference)
            let m = try IndependentBallisticInput.seconds(midpoint, minus: reference)
            let startVz = velocity[2].addingProduct(-gravity, a), endVz = velocity[2].addingProduct(-gravity, b)
            let midpointVz = velocity[2].addingProduct(-gravity, m), horizontal = hypot(velocity[0], velocity[1])
            let atStart = hypot(horizontal, startVz), atEnd = hypot(horizontal, endVz)
            // ||v|| is convex in time. Its minimum is horizontal speed if vz=0
            // lies inside the window; the maximum always occurs at an endpoint.
            let containsApex = startVz >= 0 && endVz <= 0
            let minimum = containsApex ? horizontal : min(atStart, atEnd)
            let maximum = max(atStart, atEnd), primary = hypot(horizontal, midpointVz)
            let speeds = [primary*3.6, minimum*3.6, maximum*3.6]
            try require((speeds + [a,b,m,startVz,endVz,midpointVz]).allSatisfy(\.isFinite), "Nonfinite contact speed evaluation")
            let raw = IndependentFlightRawContactSpeed(midpoint: try .init(sourcePTS: midpoint.value, timeBaseDenominator: midpoint.timescale),
                rawMidpointSpeedKilometersPerHour: speeds[0], rawMinimumSpeedKilometersPerHour: speeds[1],
                rawMaximumSpeedKilometersPerHour: speeds[2], minimumAtInteriorVerticalApex: startVz > 0 && endVz < 0,
                midpointBackwardExtrapolationSeconds: max(0, -m), maximumBackwardExtrapolationSeconds: max(0, -a),
                extrapolationReason: extrapolationReason)
            return (raw, [])
        } catch {
            return (nil, ["contact_speed_evaluation_unavailable: " + error.localizedDescription])
        }
    }
    private static func build(source: String, width: Int, height: Int, nominalFPS: Double, frames: [Frame],
                              camera: IndependentBallisticCamera?, evidence: IndependentFlightIntervalEvidence?,
                              configuration: IndependentBallisticConfiguration) throws -> IndependentFlightCandidateResult {
        try configuration.validate()
        try require(source.count == 64 && source.allSatisfy { $0.isHexDigit }, "Expected original source SHA-256")
        try require(width > 0 && height > 0 && nominalFPS.isFinite && nominalFPS > 0 && nominalFPS <= 240, "Invalid source metadata")
        try require(frames.count <= 7300, "Analyzer frame limit exceeded")
        var selected: [Frame] = []
        func result(_ status: IndependentFlightCandidateStatus, _ reasons: [String], fit: IndependentFreeFlightResult? = nil,
                    raw: IndependentFlightRawCandidate? = nil) -> IndependentFlightCandidateResult {
            .init(sourceSHA256: source, status: status, reasons: reasons, evidence: evidence,
                  selectedFrameIndices: selected.map(\.decodeIndex), fit: fit, rawCandidate: raw)
        }
        var missing: [String] = []
        if camera == nil { missing.append("missing_explicit_camera") }
        if evidence == nil { missing.append("missing_collision_free_interval_evidence") }
        guard let camera, let evidence else { return result(.unknown, missing) }
        try camera.validate()
        guard camera.sourceID == source && evidence.sourceSHA256 == source else { return result(.rejected, ["source_binding_mismatch"]) }
        guard camera.width == width && camera.height == height else { return result(.rejected, ["camera_source_dimensions_mismatch"]) }
        try require(bounded(evidence.collisionFreeAssumption) && evidence.interruptionWindows.count <= 4096, "Explicit bounded collision-free assumption required")
        let (start, end) = try window(evidence.interval)
        try require(CMTimeCompare(start, end) < 0, "Flight interval must have positive duration")
        let interruptions = try evidence.interruptionWindows.map(window)
        let ground = try evidence.groundCandidateWindow.map(window)
        if let ground { try require(CMTimeCompare(ground.0, end) >= 0, "Ground candidate window precedes flight interval end") }
        if interruptions.contains(where: { CMTimeCompare($0.0, end) <= 0 && CMTimeCompare($0.1, start) >= 0 }) {
            return result(.rejected, ["interruption_overlaps_requested_interval"])
        }
        var priorTime: CMTime?, priorIndex: Int?
        for f in frames {
            _ = try IndependentBallImageTransform(originalWidth: f.transform.originalWidth, originalHeight: f.transform.originalHeight,
                cropX: f.transform.cropX, cropY: f.transform.cropY, cropWidth: f.transform.cropWidth, cropHeight: f.transform.cropHeight)
            let time = try f.time.mediaTime(), presentation = f.presentationTime.mediaTime
            try require(presentation.isNumeric && presentation.epoch == 0 && !presentation.flags.contains(.hasBeenRounded)
                        && CMTimeCompare(time, presentation) == 0, "Source PTS/presentation identity mismatch")
            if let priorTime { try require(CMTimeCompare(time, priorTime) > 0, "Unordered source PTS") }
            if let priorIndex { try require(f.decodeIndex == priorIndex+1, "Source decode indices are not contiguous") }
            try require(f.decodeIndex >= 0 && f.transform.originalWidth == width && f.transform.originalHeight == height, "Invalid source frame identity/dimensions")
            priorTime = time; priorIndex = f.decodeIndex
            if CMTimeCompare(time, start) >= 0 && CMTimeCompare(time, end) <= 0 { selected.append(f) }
        }
        guard let first = selected.first, let last = selected.last,
              CMTimeCompare(try first.time.mediaTime(), start) == 0, CMTimeCompare(try last.time.mediaTime(), end) == 0 else {
            return result(.unknown, ["interval_endpoints_not_decoded_source_frames"])
        }
        guard (32...4096).contains(selected.count) else { return result(.unknown, ["requires_32_to_4096_source_frames"]) }
        var observations: [IndependentBallisticFrame] = []
        var previous: CMTime?
        for f in selected {
            let time = try f.time.mediaTime()
            guard f.segmentIndex == first.segmentIndex && f.transform == first.transform else { return result(.rejected, ["source_segment_or_transform_changed"]) }
            if let previous, try IndependentBallisticInput.seconds(time, minus: previous) > 1.5/nominalFPS {
                return result(.rejected, ["source_pts_gap"])
            }
            if f.decodeIndex != first.decodeIndex && f.selection?.resetReason != nil { return result(.rejected, ["tracker_reset_inside_interval"]) }
            if let selection = f.selection { try require(CMTimeCompare(try selection.time.mediaTime(), time) == 0, "Selection/source time mismatch") }
            let candidate = f.selection?.candidate
            try require((f.state == .tracked) == (candidate != nil), "Frame state/selected candidate mismatch")
            var pixel: IndependentBallisticPixel?
            if let candidate {
                try require(candidate.originalXY.count == 2, "Malformed original pixel candidate")
                try require(candidate.originalXY[0] >= f.transform.cropX && candidate.originalXY[0] < f.transform.cropX+f.transform.cropWidth
                            && candidate.originalXY[1] >= f.transform.cropY && candidate.originalXY[1] < f.transform.cropY+f.transform.cropHeight,
                            "Selected candidate is outside source crop")
                pixel = .init(x: Double(candidate.originalXY[0]), y: Double(candidate.originalXY[1]))
            }
            observations.append(.init(frameIndex: f.decodeIndex, sourceID: source, time: f.time, originalPixel: pixel,
                                      missingReason: pixel == nil ? (f.unavailableReason ?? f.selection?.missingReason ?? "source_candidate_unavailable") : nil))
            previous = time
        }
        guard observations.first?.originalPixel != nil && observations.last?.originalPixel != nil else {
            return result(.unknown, ["interval_endpoint_candidate_missing_no_extrapolation"])
        }
        guard observations.filter({ $0.originalPixel != nil }).count >= 32 else { return result(.unknown, ["fewer_than_32_actual_ball_candidates"]) }
        let input = try IndependentFreeFlightInput(camera: camera, frames: observations, configuration: configuration)
        let fit = try IndependentFreeFlightDiagnostic.fit(input)
        guard fit.rawAlgebraicQualityPassed, let motion = fit.rawMotion, let root = fit.futureDownwardGroundRoot else {
            return result(.rejected, ["free_flight_quality_rejected"] + fit.qualityReasons, fit: fit)
        }
        // Compare only relative rational differences, preserving large absolute
        // PTS. No rounding to a frame or expansion of the supplied event window.
        if let ground {
            let lower = try IndependentBallisticInput.seconds(ground.0, minus: start)
            let upper = try IndependentBallisticInput.seconds(ground.1, minus: start)
            guard root.secondsAfterFirstObserved >= lower && root.secondsAfterFirstObserved <= upper else {
                return result(.rejected, ["predicted_ground_outside_supplied_window"], fit: fit)
            }
        }
        for interruption in interruptions where CMTimeCompare(interruption.1, end) > 0 {
            let offset = try IndependentBallisticInput.seconds(interruption.0, minus: start)
            if offset <= root.secondsAfterFirstObserved { return result(.rejected, ["interruption_before_predicted_ground"], fit: fit) }
        }
        let duration = try IndependentBallisticInput.seconds(end, minus: start)
        let v = motion.velocityFirstObservedMetersPerSecond
        let endVz = v[2].addingProduct(-configuration.gravity, duration)
        let integral = try IndependentBallisticIntervalDiagnostic.integrateMean(vx: v[0], vy: v[1], startVz: v[2], endVz: endVz)
        let contact = contactSpeed(window: evidence.contactCandidateWindow, referenceTime: first.time, velocity: v,
            gravity: configuration.gravity, extrapolationReason: evidence.contactExtrapolationReason, interruptions: evidence.interruptionWindows)
        let raw = IndependentFlightRawCandidate(start: first.time, end: last.time, durationSeconds: duration,
            rawMeanPathSpeedMetersPerSecond: integral.mean, rawStartSpeedMetersPerSecond: hypot(hypot(v[0], v[1]), v[2]),
            rawEndSpeedMetersPerSecond: hypot(hypot(v[0], v[1]), endVz), numericalEstimatedAbsoluteErrorMetersPerSecond: integral.error,
            numericalFunctionEvaluations: integral.evaluations, predictedGround: root, predictionReferenceTime: first.time,
            groundCandidateWindowMatched: ground == nil ? nil : true, rawContactSpeed: contact.value,
            contactSpeedUnavailableReasons: contact.reasons)
        return result(.unqualifiedCandidate, ["assumed_camera_and_collision_freedom_not_physically_validated"], fit: fit, raw: raw)
    }
}
