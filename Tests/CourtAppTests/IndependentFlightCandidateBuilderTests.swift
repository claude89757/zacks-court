import XCTest
import CoreMedia
@testable import CourtCore

final class IndependentFlightCandidateBuilderTests: XCTestCase {
    private let source = String(repeating: "a", count: 64)
    private func time(_ tick: Int64, base: Int64 = 0) throws -> IndependentBallFrameTime {
        try .init(sourcePTS: base+tick, timeBaseDenominator: 600)
    }
    private func camera(source: String? = nil) throws -> IndependentBallisticCamera {
        try .init(sourceID: source ?? self.source, width: 1920, height: 1080,
            rowMajorK: [1164.814264659361,0,960,0,1164.814264659361,540,0,0,1],
            rowMajorR: [0.9999485720544921,0.01007444773073966,0.001165653937790668,0.0008255998640870127,0.033692598964962,-0.9994319022123771,-0.010107998369930215,0.9993814658467038,0.033682548761141164],
            t: [-5.689791368917111,1.75322016472111,6.251324074536921], assumptions: ["Synthetic test camera only"])
    }
    private func evidence(base: Int64 = 0, ground: ClosedRange<Int64>? = 480...520,
                          interruptions: [IndependentFlightEvidenceWindow] = []) throws -> IndependentFlightIntervalEvidence {
        try .init(sourceSHA256: source, interval: .init(start: time(0, base: base), end: time(400, base: base), basis: "Synthetic generated flight"),
                  collisionFreeAssumption: "Synthetic fixture has no collisions", interruptionWindows: interruptions,
                  groundCandidateWindow: ground.map { try .init(start: time($0.lowerBound, base: base), end: time($0.upperBound, base: base), basis: "Synthetic future ground window") })
    }
    /// Actual analyzer output types are encoded, then replayed through the public
    /// JSON entry point. No second inference or hand-built solver frames.
    private func analysis(base: Int64 = 0, missing: Set<Int> = [], segmentAt: Int? = nil,
                          resetAt: Int? = nil, gapAt: Int? = nil) throws -> Data {
        let c = try camera(), transform = try IndependentBallImageTransform(originalWidth: 1920, originalHeight: 1080)
        var frames: [IndependentLocalVideoFrameResult] = []
        for index in 0...40 {
            let t = Double(index)/60, tick = Int64(index*10 + ((gapAt.map { index >= $0 } ?? false) ? 10 : 0))
            let pts = try time(tick, base: base)
            let world = [7-5*t,18*t,2.5+t-0.5*9.81*t*t]
            let cc = (0..<3).map { row in (0..<3).reduce(c.t[row]) { $0+c.rowMajorR[row*3+$1]*world[$1] } }
            let h = (0..<3).map { row in (0..<3).reduce(0.0) { $0+c.rowMajorK[row*3+$1]*cc[$1] } }
            let xy = [Int((h[0]/h[2]).rounded()),Int((h[1]/h[2]).rounded())]
            let candidate = IndependentBallGridCandidate(identifier: 1, box: [200,100,1,1], originalXY: xy,
                equivalentXY: [Double(xy[0])*1280/1920,Double(xy[1])*720/1080], peak: 0.9, mean: 0.9, pixelArea: 1)
            let absent = missing.contains(index)
            let selection = IndependentBallTrackSelection(time: pts, candidate: absent ? nil : candidate,
                linkedToPast: index > 0, resetReason: resetAt == index ? "last_seen_timeout" : nil,
                missingReason: absent ? "no_candidate" : nil, incrementalCost: 0.1)
            frames.append(.init(decodeIndex: index, time: pts, presentationTime: .init(try pts.mediaTime()),
                duration: .init(CMTime(value: 10, timescale: 600)), decodeTime: .init(.invalid), transform: transform,
                segmentIndex: segmentAt.map { index >= $0 ? 1 : 0 } ?? 0, windowIndex: UInt64(index/8),
                state: absent ? .missing : .tracked, unavailableReason: absent ? "no_candidate" : nil,
                availableAt: .init(try pts.mediaTime()), sourceLookaheadSeconds: 0, selection: selection, candidateBank: nil))
        }
        struct Saved: Encodable {
            let backendID: String, sourceSHA256: String
            let width = 1920, height = 1080
            let nominalFPS = 60.0
            let frames: [IndependentLocalVideoFrameResult]
        }
        return try JSONEncoder().encode(Saved(backendID: IndependentLocalVideoResult.backendIdentifier, sourceSHA256: source, frames: frames))
    }
    private func build(_ json: Data, evidence: IndependentFlightIntervalEvidence? = nil) throws -> IndependentFlightCandidateResult {
        try IndependentFlightCandidateBuilder.build(savedAnalysisJSON: json, camera: camera(),
            evidence: evidence ?? self.evidence(), configuration: .init(residualBoundPixels: 9))
    }
    func testTrackedPixelsToRawIntervalAndPredictedGroundWithoutContactInput() throws {
        let result = try build(analysis()), raw = try XCTUnwrap(result.rawCandidate)
        XCTAssertEqual(result.status, .unqualifiedCandidate)
        XCTAssertEqual(result.selectedFrameIndices, Array(0...40))
        XCTAssertEqual(raw.durationSeconds, 2.0/3, accuracy: 1e-12)
        // Quantized tracker pixels need not reproduce unquantized parameters.
        XCTAssertEqual(raw.rawMeanPathSpeedMetersPerSecond, 18.9, accuracy: 0.5)
        XCTAssertEqual(raw.predictedGround.secondsAfterFirstObserved, 0.818, accuracy: 0.025)
        XCTAssertEqual(raw.groundCandidateWindowMatched, true)
        XCTAssertNil(result.speedKilometersPerHour); XCTAssertFalse(result.cameraQualified)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        for name in ["speedKilometersPerHour", "acceptedCamera", "velocity"] { XCTAssertTrue(json[name] is NSNull) }
        for name in ["physicalAccuracyValidated", "cameraQualified", "nativeEndToEndSpeedAccepted", "twentyPercentAcceptanceEligible", "formal", "human", "production"] {
            XCTAssertEqual(json[name] as? Bool, false)
        }
    }
    func testLargeExactSourcePTSAndMissingObservationsRemainBound() throws {
        let base: Int64 = 1<<60
        let result = try build(analysis(base: base, missing: [2,7,36]), evidence: evidence(base: base))
        XCTAssertEqual(result.status, .unqualifiedCandidate)
        XCTAssertEqual(result.fit?.missingFrameIndices, [2,7,36])
        XCTAssertEqual(result.rawCandidate?.predictionReferenceTime.sourcePTS, base)
        XCTAssertEqual(result.fit?.observedFrameIndices.count, 38)
    }
    func testMissingCameraAndIntervalReturnActionableUnknown() throws {
        let json = try analysis(), config = try IndependentBallisticConfiguration(residualBoundPixels: 9)
        let both = try IndependentFlightCandidateBuilder.build(savedAnalysisJSON: json, camera: nil, evidence: nil, configuration: config)
        XCTAssertEqual(both.status, .unknown)
        XCTAssertEqual(both.reasons, ["missing_explicit_camera", "missing_collision_free_interval_evidence"])
        XCTAssertNil(both.fit); XCTAssertNil(both.rawCandidate)
        let noCamera = try IndependentFlightCandidateBuilder.build(savedAnalysisJSON: json, camera: nil, evidence: evidence(), configuration: config)
        XCTAssertEqual(noCamera.reasons, ["missing_explicit_camera"])
    }
    func testForeignSourceAndDiscontinuitiesCannotBeCombined() throws {
        let foreign = try IndependentFlightCandidateBuilder.build(savedAnalysisJSON: analysis(), camera: camera(source: String(repeating: "b", count: 64)),
            evidence: evidence(), configuration: .init(residualBoundPixels: 9))
        XCTAssertEqual(foreign.reasons, ["source_binding_mismatch"])
        XCTAssertEqual(try build(analysis(segmentAt: 20)).reasons, ["source_segment_or_transform_changed"])
        XCTAssertEqual(try build(analysis(resetAt: 20)).reasons, ["tracker_reset_inside_interval"])
        // Keep the original requested end at 400: selected indices end at 39,
        // so the actual gap is tested before fitting instead of rebasing PTS.
        XCTAssertEqual(try build(analysis(gapAt: 20)).reasons, ["source_pts_gap"])
    }
    func testMissingEndpointAndTooFewActualCandidatesStayUnknown() throws {
        XCTAssertEqual(try build(analysis(missing: [0])).reasons, ["interval_endpoint_candidate_missing_no_extrapolation"])
        XCTAssertEqual(try build(analysis(missing: Set(1...10))).reasons, ["fewer_than_32_actual_ball_candidates"])
    }
    func testInterruptionAndStrictGroundWindowVetoWithoutRefitting() throws {
        let interruption = try IndependentFlightEvidenceWindow(start: time(200), end: time(210), basis: "Suspected net contact")
        let crossed = try build(analysis(), evidence: evidence(interruptions: [interruption]))
        XCTAssertEqual(crossed.reasons, ["interruption_overlaps_requested_interval"]); XCTAssertNil(crossed.fit)
        let after = try IndependentFlightEvidenceWindow(start: time(450), end: time(460), basis: "Possible net contact before ground")
        let predictedAcross = try build(analysis(), evidence: evidence(interruptions: [after]))
        XCTAssertEqual(predictedAcross.reasons, ["interruption_before_predicted_ground"])
        XCTAssertNotNil(predictedAcross.fit); XCTAssertNil(predictedAcross.rawCandidate)
        let wrong = try build(analysis(), evidence: evidence(ground: 410...420))
        XCTAssertEqual(wrong.reasons, ["predicted_ground_outside_supplied_window"])
        XCTAssertNil(wrong.rawCandidate)
        let without = try build(analysis(), evidence: evidence(ground: nil))
        XCTAssertNil(without.rawCandidate?.groundCandidateWindowMatched)
        XCTAssertEqual(wrong.fit?.rawMotion?.positionFirstObservedMeters, without.fit?.rawMotion?.positionFirstObservedMeters)
    }
    func testReplayedPresentationIdentityMustMatchExactPTS() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: analysis()) as? [String: Any])
        var frames = try XCTUnwrap(json["frames"] as? [[String: Any]])
        var pts = try XCTUnwrap(frames[20]["presentationTime"] as? [String: Any])
        pts["value"] = 201; frames[20]["presentationTime"] = pts; json["frames"] = frames
        XCTAssertThrowsError(try build(JSONSerialization.data(withJSONObject: json)))
    }
    func testContactMidpointUsesExactRationalTimeWithLargeSourcePTS() throws {
        let base: Int64 = 1<<60
        let contact = try IndependentFlightEvidenceWindow(start: time(-9, base: base), end: time(-4, base: base), basis: "Independent contact interval")
        let result = IndependentFlightCandidateBuilder.contactSpeed(window: contact, referenceTime: try time(0, base: base),
            velocity: [-5,18,1], gravity: 9.81, extrapolationReason: "Explicit short pre-observation extrapolation", interruptions: [])
        let raw = try XCTUnwrap(result.value)
        let expected = try IndependentBallFrameTime(sourcePTS: 2*base-13, timeBaseDenominator: 1200)
        XCTAssertEqual(CMTimeCompare(try raw.midpoint.mediaTime(), try expected.mediaTime()), 0)
        XCTAssertEqual(raw.rawMidpointSpeedKilometersPerHour, hypot(hypot(5,18), 1+9.81*13/1200)*3.6, accuracy: 1e-12)
        XCTAssertEqual(raw.midpointBackwardExtrapolationSeconds, 13.0/1200, accuracy: 1e-15)
        XCTAssertEqual(raw.maximumBackwardExtrapolationSeconds, 9.0/600, accuracy: 1e-15)
        XCTAssertTrue(result.reasons.isEmpty)
    }
    func testContactRangeIncludesInteriorVerticalApexMinimum() throws {
        let contact = try IndependentFlightEvidenceWindow(start: time(-120), end: time(-30), basis: "Synthetic contact-time uncertainty")
        let result = IndependentFlightCandidateBuilder.contactSpeed(window: contact, referenceTime: try time(0),
            velocity: [3,4,-1], gravity: 9.81, extrapolationReason: "Synthetic backwards extrapolation", interruptions: [])
        let raw = try XCTUnwrap(result.value)
        XCTAssertTrue(raw.minimumAtInteriorVerticalApex)
        XCTAssertEqual(raw.rawMinimumSpeedKilometersPerHour, 18, accuracy: 1e-12)
        XCTAssertEqual(raw.rawMaximumSpeedKilometersPerHour, hypot(5, -1+9.81*0.2)*3.6, accuracy: 1e-12)
        XCTAssertEqual(raw.rawMidpointSpeedKilometersPerHour, hypot(5, -1+9.81*0.125)*3.6, accuracy: 1e-12)
        XCTAssertLessThan(raw.rawMinimumSpeedKilometersPerHour, hypot(5, -1+9.81*0.05)*3.6)
    }
    func testContactFailuresPreserveObservedIntervalAndFit() throws {
        let base = try evidence(), contact = try IndependentFlightEvidenceWindow(start: time(-20), end: time(-10), basis: "Independent visual contact")
        func request(reason: String?, interruptions: [IndependentFlightEvidenceWindow] = []) -> IndependentFlightIntervalEvidence {
            .init(sourceSHA256: source, interval: base.interval, collisionFreeAssumption: base.collisionFreeAssumption,
                  interruptionWindows: interruptions, groundCandidateWindow: base.groundCandidateWindow,
                  contactCandidateWindow: contact, contactExtrapolationReason: reason)
        }
        let original = try build(analysis()), noReason = try build(analysis(), evidence: request(reason: nil))
        XCTAssertEqual(noReason.status, .unqualifiedCandidate)
        XCTAssertNil(noReason.rawCandidate?.rawContactSpeed)
        XCTAssertEqual(noReason.rawCandidate?.contactSpeedUnavailableReasons, ["contact_extrapolation_reason_required"])
        XCTAssertEqual(noReason.rawCandidate?.rawMeanPathSpeedMetersPerSecond, original.rawCandidate?.rawMeanPathSpeedMetersPerSecond)
        XCTAssertEqual(noReason.fit?.rawMotion?.velocityFirstObservedMetersPerSecond, original.fit?.rawMotion?.velocityFirstObservedMetersPerSecond)
        let obstruction = try IndependentFlightEvidenceWindow(start: time(-5), end: time(-1), basis: "Possible intervening racket contact")
        let collided = try build(analysis(), evidence: request(reason: "Allow backwards evaluation", interruptions: [obstruction]))
        XCTAssertNil(collided.rawCandidate?.rawContactSpeed)
        XCTAssertEqual(collided.rawCandidate?.contactSpeedUnavailableReasons, ["interruption_between_contact_and_first_observation"])
        XCTAssertEqual(collided.rawCandidate?.rawMeanPathSpeedMetersPerSecond, original.rawCandidate?.rawMeanPathSpeedMetersPerSecond)
        let later = try IndependentFlightEvidenceWindow(start: time(-10), end: time(1), basis: "Window crosses first observation")
        let rejected = IndependentFlightCandidateBuilder.contactSpeed(window: later, referenceTime: try time(0), velocity: [3,4,1],
            gravity: 9.81, extrapolationReason: "Explicit", interruptions: [])
        XCTAssertNil(rejected.value); XCTAssertEqual(rejected.reasons, ["contact_window_after_first_observation"])
    }
    func testAbsentContactIsBackwardCompatibleAndAtFirstNeedsNoExtrapolation() throws {
        let old = try evidence(), json = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(IndependentFlightIntervalEvidence.self, from: json)
        XCTAssertNil(decoded.contactCandidateWindow); XCTAssertNil(decoded.contactExtrapolationReason)
        let result = try build(analysis(), evidence: decoded)
        XCTAssertNil(result.rawCandidate?.rawContactSpeed)
        XCTAssertEqual(result.rawCandidate?.contactSpeedUnavailableReasons, [])
        let first = try time(0), contact = IndependentFlightEvidenceWindow(start: first, end: first, basis: "Exact synthetic contact at first observation")
        let atFirst = IndependentFlightCandidateBuilder.contactSpeed(window: contact, referenceTime: first, velocity: [3,4,0],
            gravity: 9.81, extrapolationReason: nil, interruptions: [])
        XCTAssertEqual(atFirst.value?.rawMidpointSpeedKilometersPerHour, 18)
        XCTAssertEqual(atFirst.value?.maximumBackwardExtrapolationSeconds, 0)
    }
}
