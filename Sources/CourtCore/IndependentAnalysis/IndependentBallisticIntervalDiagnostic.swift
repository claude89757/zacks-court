import Foundation
import CoreMedia

/// A caller-selected interval on the incoming, constant-gravity branch. An empty
/// collision list does not establish collision freedom: the assumption is explicit.
public struct IndependentBallisticIntervalRequest: Codable, Sendable {
    public let start: IndependentBallFrameTime
    public let end: IndependentBallFrameTime
    public let knownCollisionTimes: [IndependentBallFrameTime]
    public let collisionFreeAssumption: String
    /// Nil forbids extension beyond the original nonmissing observation envelope.
    public let extrapolationReason: String?
    public init(start: IndependentBallFrameTime, end: IndependentBallFrameTime,
                knownCollisionTimes: [IndependentBallFrameTime], collisionFreeAssumption: String,
                extrapolationReason: String? = nil) {
        self.start = start; self.end = end; self.knownCollisionTimes = knownCollisionTimes
        self.collisionFreeAssumption = collisionFreeAssumption; self.extrapolationReason = extrapolationReason
    }
    private enum CodingKeys: String, CodingKey { case start, end, knownCollisionTimes, collisionFreeAssumption, extrapolationReason }
    public init(from decoder: Decoder) throws {
        try IndependentBallisticDiagnostic.rejectQualifiedClaims(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(start: try c.decode(IndependentBallFrameTime.self, forKey: .start),
                  end: try c.decode(IndependentBallFrameTime.self, forKey: .end),
                  knownCollisionTimes: try c.decode([IndependentBallFrameTime].self, forKey: .knownCollisionTimes),
                  collisionFreeAssumption: try c.decode(String.self, forKey: .collisionFreeAssumption),
                  extrapolationReason: try c.decodeIfPresent(String.self, forKey: .extrapolationReason))
    }
}

/// Algebraic diagnostics only. Integration cannot qualify a camera, a fit, or a
/// physical speed, including when the numerical estimate is small.
public struct IndependentBallisticIntervalRawResult: Encodable, Sendable {
    public let status: String
    public let sourceID: String
    public let request: IndependentBallisticIntervalRequest
    public let contactTime: IndependentBallFrameTime
    public let observedStart: IndependentBallFrameTime, observedEnd: IndependentBallFrameTime
    public let gravityMetersPerSecondSquared: Double
    public let durationSeconds: Double
    public let rawStartVelocityMetersPerSecond: [Double], rawEndVelocityMetersPerSecond: [Double]
    public let rawStartSpeedMetersPerSecond: Double, rawEndSpeedMetersPerSecond: Double
    public let rawMeanPathSpeedMetersPerSecond: Double
    public let rawStartHeightMeters: Double, rawEndHeightMeters: Double
    public let didExtrapolate: Bool
    public let fitStatus: String
    public let fitAllResidualsWithinBound: Bool, fitAboveGroundAllObservations: Bool
    public let fitQualificationReasons: [String]
    public let rawIntervalQualityPassed: Bool
    public let intervalQualityReasons: [String]
    /// Sum of embedded quadrature differences, not a rigorous error bound.
    public let numericalEstimatedAbsoluteErrorMetersPerSecond: Double
    public let numericalFunctionEvaluations: Int
    public let assumptions: [String]
    public var physicalAccuracyValidated: Bool { false }
    public var nativeEndToEndSpeedAccepted: Bool { false }
    public var production: Bool { false }
    public var cameraQualified: Bool { false }
    public var human: Bool { false }
    public var formal: Bool { false }
    public var twentyPercentAcceptanceEligible: Bool { false }
    public var acceptedCamera: IndependentBallisticCamera? { nil }
    public var velocity: [Double]? { nil }
    public var speedKilometersPerHour: Double? { nil }
    private enum CodingKeys: String, CodingKey {
        case status, sourceID, request, contactTime, observedStart, observedEnd, gravityMetersPerSecondSquared, durationSeconds
        case rawStartVelocityMetersPerSecond, rawEndVelocityMetersPerSecond, rawStartSpeedMetersPerSecond, rawEndSpeedMetersPerSecond, rawMeanPathSpeedMetersPerSecond
        case rawStartHeightMeters, rawEndHeightMeters, didExtrapolate, fitStatus, fitAllResidualsWithinBound, fitAboveGroundAllObservations, fitQualificationReasons, rawIntervalQualityPassed, intervalQualityReasons
        case numericalEstimatedAbsoluteErrorMetersPerSecond, numericalFunctionEvaluations, assumptions
        case physicalAccuracyValidated, nativeEndToEndSpeedAccepted, production, cameraQualified, human, formal, twentyPercentAcceptanceEligible, acceptedCamera, velocity, speedKilometersPerHour
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status); try c.encode(sourceID, forKey: .sourceID); try c.encode(request, forKey: .request)
        try c.encode(contactTime, forKey: .contactTime); try c.encode(observedStart, forKey: .observedStart); try c.encode(observedEnd, forKey: .observedEnd)
        try c.encode(gravityMetersPerSecondSquared, forKey: .gravityMetersPerSecondSquared); try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(rawStartVelocityMetersPerSecond, forKey: .rawStartVelocityMetersPerSecond); try c.encode(rawEndVelocityMetersPerSecond, forKey: .rawEndVelocityMetersPerSecond)
        try c.encode(rawStartSpeedMetersPerSecond, forKey: .rawStartSpeedMetersPerSecond); try c.encode(rawEndSpeedMetersPerSecond, forKey: .rawEndSpeedMetersPerSecond); try c.encode(rawMeanPathSpeedMetersPerSecond, forKey: .rawMeanPathSpeedMetersPerSecond)
        try c.encode(rawStartHeightMeters, forKey: .rawStartHeightMeters); try c.encode(rawEndHeightMeters, forKey: .rawEndHeightMeters); try c.encode(didExtrapolate, forKey: .didExtrapolate)
        try c.encode(fitStatus, forKey: .fitStatus); try c.encode(fitAllResidualsWithinBound, forKey: .fitAllResidualsWithinBound); try c.encode(fitAboveGroundAllObservations, forKey: .fitAboveGroundAllObservations); try c.encode(fitQualificationReasons, forKey: .fitQualificationReasons)
        try c.encode(rawIntervalQualityPassed, forKey: .rawIntervalQualityPassed); try c.encode(intervalQualityReasons, forKey: .intervalQualityReasons)
        try c.encode(numericalEstimatedAbsoluteErrorMetersPerSecond, forKey: .numericalEstimatedAbsoluteErrorMetersPerSecond); try c.encode(numericalFunctionEvaluations, forKey: .numericalFunctionEvaluations); try c.encode(assumptions, forKey: .assumptions)
        for key in [CodingKeys.physicalAccuracyValidated, .nativeEndToEndSpeedAccepted, .production, .cameraQualified, .human, .formal, .twentyPercentAcceptanceEligible] { try c.encode(false, forKey: key) }
        for key in [CodingKeys.acceptedCamera, .velocity, .speedKilometersPerHour] { try c.encodeNil(forKey: key) }
    }
}

public enum IndependentBallisticIntervalDiagnostic {
    private static func require(_ value: Bool, _ reason: String) throws {
        if !value { throw IndependentBallisticError.invalid(reason) }
    }
    /// Public evaluation binds raw parameters to this exact input by fitting once.
    public static func evaluate(input: IndependentBallisticInput, request: IndependentBallisticIntervalRequest) throws -> (fit: IndependentBallisticResult, rawInterval: IndependentBallisticIntervalRawResult) {
        let fit = try IndependentBallisticDiagnostic.fit(input)
        return (fit, try evaluate(input: input, fit: fit, request: request))
    }
    // Trusted internal pairing is kept for arithmetic/failed-quality test fixtures;
    // callers outside CourtCore cannot relabel a foreign fit with another input.
    static func evaluate(input: IndependentBallisticInput, fit: IndependentBallisticResult,
                                request: IndependentBallisticIntervalRequest) throws -> IndependentBallisticIntervalRawResult {
        try input.validate()
        let observed = input.frames.filter { $0.originalPixel != nil }
        try require(fit.observedFrameIndices == observed.map(\.frameIndex) && fit.missingFrameIndices == input.frames.filter { $0.originalPixel == nil }.map(\.frameIndex), "Fit frame identities do not match all original observations")
        guard let raw = fit.rawMotion else { throw IndependentBallisticError.invalid("Fit has no raw motion") }
        try require(raw.contactParameters.count == 5 && raw.positionFirstObservedMeters.count == 3 && raw.velocityFirstObservedMetersPerSecond.count == 3 && raw.scaledFirstObservationParameters.count == 5, "Malformed raw motion dimensions")
        try require((raw.contactParameters + raw.positionFirstObservedMeters + raw.velocityFirstObservedMetersPerSecond + raw.scaledFirstObservationParameters + [raw.velocityFirstObservedNormMetersPerSecond]).allSatisfy(\.isFinite) && raw.velocityFirstObservedNormMetersPerSecond >= 0, "Nonfinite raw motion")
        func boundedReason(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.utf8.count <= 4096 }
        try require(boundedReason(request.collisionFreeAssumption) && request.knownCollisionTimes.count <= 4096, "Explicit bounded collision-free assumption required")
        if let reason = request.extrapolationReason { try require(boundedReason(reason), "Extrapolation requires an explicit bounded reason") }
        let start = try request.start.mediaTime(), end = try request.end.mediaTime(), contact = try input.contactTime.mediaTime()
        let first = try observed[0].time.mediaTime(), last = try observed[observed.count-1].time.mediaTime()
        try require(CMTimeCompare(start, end) < 0 && CMTimeCompare(end, contact) <= 0, "Require start < end <= contact; contact endpoint is the incoming left limit")
        // The fit uses EVERY original observation. A request cannot trim away an
        // observation in a different collision segment to salvage a bad fit.
        for stamp in request.knownCollisionTimes {
            let collision = try stamp.mediaTime()
            if CMTimeCompare(collision, contact) < 0 {
                try require(CMTimeCompare(start, collision) > 0 && CMTimeCompare(first, collision) > 0,
                            "Request or original observations cross/touch a known prior collision boundary")
            }
        }
        let outside = CMTimeCompare(start, first) < 0 || CMTimeCompare(end, last) > 0
        try require(!outside || request.extrapolationReason != nil, "Interval extends beyond original observed envelope; explicit extrapolation reason required")
        let dt = try IndependentBallisticInput.seconds(end, minus: start)
        let startOffset = try IndependentBallisticInput.seconds(start, minus: contact)
        let endOffset = try IndependentBallisticInput.seconds(end, minus: contact)
        try require(dt > 0, "Nonpositive or unrepresentable local duration")
        let p = raw.contactParameters, g = input.configuration.gravity
        // FMA never materializes an overflowing g*offset product. Splitting the
        // exact rational difference preserves sub-second low parts even when the
        // contact epoch is far away; normalizing g first would introduce amplified
        // quotient error near a cancellation/vertical apex.
        let startVz = try endpointVerticalVelocity(contactVz: p[4], gravity: g, time: start, contact: contact)
        let endVz = try endpointVerticalVelocity(contactVz: p[4], gravity: g, time: end, contact: contact)
        let numerical = try integrateMean(vx: p[2], vy: p[3], startVz: startVz, endVz: endVz)
        let startSpeed = hypot(hypot(p[2], p[3]), startVz), endSpeed = hypot(hypot(p[2], p[3]), endVz)
        let h = input.configuration.contactCenterHeight
        let startHeight = h.addingProduct(startOffset, 0.5*p[4] + 0.5*startVz)
        let endHeight = h.addingProduct(endOffset, 0.5*p[4] + 0.5*endVz)
        try require([startSpeed, endSpeed, startHeight, endHeight].allSatisfy(\.isFinite), "Nonfinite endpoint speed or height")
        var qualityReasons: [String] = []
        if fit.status != "unqualified_fixed_camera_motion_diagnostic" || !fit.allResidualsWithinBound || !fit.aboveGroundAllObservations { qualityReasons.append("Original fit quality was not passed; integration does not repair or qualify it.") }
        if p[4] > 0 { qualityReasons.append("Incoming contact vertical velocity is positive.") }
        if min(startHeight, endHeight) < h-1e-6 { qualityReasons.append("Interval endpoint center is below the assumed contact height.") }
        return .init(status: qualityReasons.isEmpty ? "unqualified_fixed_camera_interval_diagnostic" : "fixed_camera_interval_quality_rejected", sourceID: input.camera.sourceID, request: request, contactTime: input.contactTime,
                     observedStart: observed[0].time, observedEnd: observed[observed.count-1].time, gravityMetersPerSecondSquared: g, durationSeconds: dt,
                     rawStartVelocityMetersPerSecond: [p[2], p[3], startVz], rawEndVelocityMetersPerSecond: [p[2], p[3], endVz], rawStartSpeedMetersPerSecond: startSpeed, rawEndSpeedMetersPerSecond: endSpeed, rawMeanPathSpeedMetersPerSecond: numerical.mean,
                     rawStartHeightMeters: startHeight, rawEndHeightMeters: endHeight, didExtrapolate: outside, fitStatus: fit.status, fitAllResidualsWithinBound: fit.allResidualsWithinBound, fitAboveGroundAllObservations: fit.aboveGroundAllObservations, fitQualificationReasons: fit.qualificationReasons,
                     rawIntervalQualityPassed: qualityReasons.isEmpty, intervalQualityReasons: qualityReasons, numericalEstimatedAbsoluteErrorMetersPerSecond: numerical.error, numericalFunctionEvaluations: numerical.evaluations,
                     assumptions: [request.collisionFreeAssumption, "Incoming constant-gravity branch; no drag or spin; all times share the input source timeline.", "Endpoint at contact uses its incoming left limit; no collision crossing is permitted.", "Numerical quadrature differences are estimates, not rigorous bounds or physical accuracy evidence.", courtText("No S家 average-speed interval or physical truth is inferred.")])
    }

    private static func endpointVerticalVelocity(contactVz: Double, gravity: Double, time: CMTime, contact: CMTime) throws -> Double {
        let difference = CMTimeSubtract(time, contact)
        try require(difference.isNumeric && !difference.flags.contains(.hasBeenRounded), "Inexact endpoint rational subtraction")
        let denominator = Int64(difference.timescale), whole = difference.value/denominator, remainder = difference.value%denominator
        let radix: Int64 = 1<<32
        // Both integer components are exactly representable before their FMA.
        let wholeHigh = Double(whole/radix)*Double(radix), wholeLow = Double(whole%radix)
        let fractionalHigh = Double(remainder)/Double(denominator)
        let fractionalLow = Double(remainder).addingProduct(-Double(denominator), fractionalHigh)/Double(denominator)
        var velocity = contactVz
        for part in [wholeHigh, wholeLow, fractionalHigh, fractionalLow] {
            velocity = velocity.addingProduct(-gravity, part)
            try require(velocity.isFinite, "Nonfinite endpoint velocity")
        }
        return velocity
    }

    // Internal pure mathematics entry point also covers the constant-speed (g=0)
    // limit without weakening the public fit input's strictly positive gravity.
    static func integrateMean(vx: Double, vy: Double, startVz: Double, endVz: Double,
                              maximumEvaluations: Int = 4096) throws -> (mean: Double, error: Double, evaluations: Int) {
        try require([vx, vy, startVz, endVz].allSatisfy(\.isFinite), "Nonfinite velocity integral")
        let scale = max(abs(vx), abs(vy), abs(startVz), abs(endVz))
        if scale == 0 { return (0, 0, 0) }
        let x = vx/scale, y = vy/scale, a = startVz/scale, b = endVz/scale
        let horizontal = hypot(x, y)
        func restored(_ mean: Double, _ error: Double, _ count: Int) throws -> (Double, Double, Int) {
            let m = mean*scale, e = error*scale
            try require(m.isFinite && e.isFinite && m >= 0, "Nonfinite velocity integral result")
            return (m, e, count)
        }
        if startVz == endVz { return try restored(hypot(horizontal, a), 0, 0) }
        if horizontal == 0 {
            let aa = abs(a), bb = abs(b)
            let mean = a*b >= 0 ? 0.5*aa + 0.5*bb : 0.5*(aa*(aa/(aa+bb)) + bb*(bb/(aa+bb)))
            return try restored(mean, 0, 0)
        }
        let x8 = [0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363]
        let w8 = [0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763]
        let x16 = [0.09501250983763744, 0.2816035507792589, 0.4580167776572274, 0.6178762444026438, 0.7554044083550030, 0.8656312023878318, 0.9445750230732326, 0.9894009349916499]
        let w16 = [0.1894506104550685, 0.1826034150449236, 0.1691565193950025, 0.1495959888165767, 0.1246289712555339, 0.09515851168249278, 0.06225352393864789, 0.02715245941175409]
        var evaluations = 0
        struct Leaf { let lo: Double, hi: Double, value: Double, error: Double }
        func leaf(_ lo: Double, _ hi: Double) throws -> Leaf {
            try require(evaluations <= maximumEvaluations-24, "Velocity integral function-evaluation budget exhausted")
            let mid = lo + (hi-lo)*0.5, half = (hi-lo)*0.5
            try require(mid > lo && mid < hi, "Velocity integral subdivision midpoint is indistinguishable")
            func quadrature(_ nodes: [Double], _ weights: [Double]) -> Double {
                var sum = 0.0
                for (node, weight) in zip(nodes, weights) {
                    for u in [mid-half*node, mid+half*node] {
                        let z = (1-u)*a + u*b
                        sum += weight*hypot(horizontal, z); evaluations += 1
                    }
                }
                return sum*half
            }
            let coarse = quadrature(x8, w8), fine = quadrature(x16, w16)
            return .init(lo: lo, hi: hi, value: fine, error: abs(fine-coarse))
        }
        var leaves: [Leaf] = []
        if a*b < 0 {
            let apex = abs(a)/(abs(a)+abs(b))
            leaves = [try leaf(0, apex), try leaf(apex, 1)]
        } else { leaves = [try leaf(0, 1)] }
        while true {
            let mean = leaves.reduce(0) { $0+$1.value }, error = leaves.reduce(0) { $0+$1.error }
            // One GLOBAL budget, accumulated across all leaves. Embedded GL
            // differences can underestimate error and are never called bounds.
            let tolerance = 1e-10/scale + 1e-10*abs(mean)
            if error <= tolerance { return try restored(mean, error, evaluations) }
            let worst = leaves.indices.max { leaves[$0].error < leaves[$1].error }!
            let old = leaves.remove(at: worst), mid = old.lo+(old.hi-old.lo)*0.5
            try require(mid > old.lo && mid < old.hi, "Velocity integral subdivision midpoint is indistinguishable")
            let left = try leaf(old.lo, mid), right = try leaf(mid, old.hi)
            leaves += [left, right]
        }
    }
}
