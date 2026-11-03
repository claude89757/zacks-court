import XCTest
@testable import CourtCore

final class IndependentBallisticDiagnosticTests: XCTestCase {
    private let rotation = [1.0,0,0, 0,cos(0.4),-sin(0.4), 0,sin(0.4),cos(0.4)]
    private func camera(r: [Double]? = nil, t: [Double] = [1,2,12]) throws -> IndependentBallisticCamera {
        try .init(sourceID:"synthetic-source",width:1920,height:1080,rowMajorK:[1100,7,960,0,1050,540,0,0,1],rowMajorR:r ?? rotation,t:t,assumptions:["Synthetic known camera; fixture only, no physical qualification"])
    }
    private func synthetic(base: Int64 = 0, missing: Set<Int> = [], noise: Double = 0, bound: Double = 3, verticalContactVelocity: Double = -7, customCamera: IndependentBallisticCamera? = nil) throws -> IndependentBallisticInput {
        let c = try customCamera ?? camera(), contactTicks: Int64 = 4800
        let ticks: [Int64] = [0,120,270,450,660,900,1170,1470,1800,2160,2550,2970,3420,3900,4320]
        // Independent world-space generator: contact x=1,y=2; velocity at
        // contact=(-3,2,-7). Integrate backwards under known gravity.
        var frames: [IndependentBallisticFrame] = []
        for (index,tick) in ticks.enumerated() {
            let dt = Double(tick-contactTicks)/6000
            let world = [1-3*dt,2+2*dt,0.033+verticalContactVelocity*dt-4.905*dt*dt]
            let xc = (0..<3).map { row in (0..<3).reduce(c.t[row]) { $0+c.rowMajorR[row*3+$1]*world[$1] } }
            let h = (0..<3).map { row in (0..<3).reduce(0.0) { $0+c.rowMajorK[row*3+$1]*xc[$1] } }
            let p = IndependentBallisticPixel(x:h[0]/h[2]+noise*sin(Double(index)*1.7),y:h[1]/h[2]+noise*cos(Double(index)*0.9))
            frames.append(.init(frameIndex:index,sourceID:c.sourceID,time:try .init(sourcePTS:base+tick,timeBaseDenominator:6000),originalPixel:missing.contains(index) ? nil : p,missingReason:missing.contains(index) ? "no original point" : nil))
        }
        return try .init(camera:c,frames:frames,contactTime:.init(sourcePTS:base+contactTicks,timeBaseDenominator:6000),configuration:.init(residualBoundPixels:bound))
    }
    func testExactNonidentityCameraRecoversKnownGravityTrajectory() throws {
        let result = try IndependentBallisticDiagnostic.fit(synthetic())
        let raw = try XCTUnwrap(result.rawMotion)
        XCTAssertEqual(result.status,"unqualified_fixed_camera_motion_diagnostic")
        for (actual,expected) in zip(raw.contactParameters,[1.0,2,-3,2,-7]) { XCTAssertEqual(actual,expected,accuracy:1e-8) }
        for (actual,expected) in zip(raw.positionFirstObservedMeters,[3.4,0.4,2.4938]) { XCTAssertEqual(actual,expected,accuracy:1e-8) }
        for (actual,expected) in zip(raw.velocityFirstObservedMetersPerSecond,[-3.0,2,0.848]) { XCTAssertEqual(actual,expected,accuracy:1e-8) }
        XCTAssertLessThan(try XCTUnwrap(result.reprojectionRMSPixels),1e-9)
        XCTAssertLessThanOrEqual(result.iterations.count,10)
        XCTAssertTrue(result.aboveGroundAllObservations)
    }
    func testIrregularRationalPTSAndMissingPointsNeverInterpolate() throws {
        // Huge absolute times lose these sub-second differences as Double;
        // subtracting exact CMTime before conversion must preserve this solution.
        let result = try IndependentBallisticDiagnostic.fit(synthetic(base:1<<60,missing:[2,7,11]))
        let raw = try XCTUnwrap(result.rawMotion)
        XCTAssertEqual(result.missingFrameIndices,[2,7,11]); XCTAssertEqual(result.observedFrameIndices.count,12)
        XCTAssertEqual(result.reprojectionPixels.count,12)
        XCTAssertEqual(raw.velocityFirstObservedMetersPerSecond[2],0.848,accuracy:1e-8)
        XCTAssertEqual(raw.contactParameters[0],1,accuracy:1e-8)
    }
    func testNoisyProjectionKeepsRawDiagnosticButPublicValuesNull() throws {
        let result = try IndependentBallisticDiagnostic.fit(synthetic(noise:0.8))
        XCTAssertNotNil(result.rawMotion); XCTAssertTrue(result.allResidualsWithinBound)
        XCTAssertGreaterThan(try XCTUnwrap(result.reprojectionRMSPixels),0.1)
        XCTAssertGreaterThan(try XCTUnwrap(result.minimumDepthMeters),0.1)
        XCTAssertNil(result.acceptedCamera); XCTAssertNil(result.velocity); XCTAssertNil(result.speedKilometersPerHour)
        XCTAssertFalse(result.physicalAccuracyValidated); XCTAssertFalse(result.cameraQualified)
        XCTAssertFalse(result.human); XCTAssertFalse(result.formal); XCTAssertFalse(result.production)
        XCTAssertFalse(result.nativeEndToEndSpeedAccepted); XCTAssertFalse(result.twentyPercentAcceptanceEligible)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(result)) as? [String:Any])
        XCTAssertTrue(json["acceptedCamera"] is NSNull); XCTAssertTrue(json["velocity"] is NSNull); XCTAssertTrue(json["speedKilometersPerHour"] is NSNull)
        let roundTrip = try JSONDecoder().decode(IndependentBallisticResult.self,from:JSONEncoder().encode(result))
        XCTAssertFalse(roundTrip.production); XCTAssertNil(roundTrip.speedKilometersPerHour)
    }
    func testResidualBoundIsQualityCheckAndDoesNotEraseFiniteParameters() throws {
        let result = try IndependentBallisticDiagnostic.fit(synthetic(noise:2,bound:0.01))
        XCTAssertNotNil(result.rawMotion); XCTAssertFalse(result.allResidualsWithinBound)
        XCTAssertEqual(result.status,"fixed_camera_motion_quality_rejected"); XCTAssertNil(result.speedKilometersPerHour)
    }
    func testGroundPenetrationPreservesRawButRejectsQuality() throws {
        let result = try IndependentBallisticDiagnostic.fit(synthetic(verticalContactVelocity:-1))
        XCTAssertNotNil(result.rawMotion)
        XCTAssertFalse(result.aboveGroundAllObservations)
        XCTAssertEqual(result.status,"fixed_camera_motion_quality_rejected")
        XCTAssertLessThan(try XCTUnwrap(result.minimumHeightMeters),0.033)
        XCTAssertNil(result.speedKilometersPerHour); XCTAssertFalse(result.physicalAccuracyValidated)
    }

    func testRankDeficientConstantRayRejected() throws {
        let c = try camera(), times = try (0..<8).map { try IndependentBallFrameTime(sourcePTS:Int64($0),timeBaseDenominator:60) }
        let frames = times.enumerated().map { IndependentBallisticFrame(frameIndex:$0.offset,sourceID:c.sourceID,time:$0.element,originalPixel:.init(x:960,y:540)) }
        let result = try IndependentBallisticDiagnostic.fit(.init(camera:c,frames:frames,contactTime:.init(sourcePTS:10,timeBaseDenominator:60),configuration:.init(residualBoundPixels:3)))
        XCTAssertEqual(result.status,"rejected"); XCTAssertNil(result.rawMotion); XCTAssertNil(result.reprojectionRMSPixels)
    }
    func testVanishingTimeSpanRejectedByConditionOrRank() throws {
        let input = try synthetic(), times = try input.frames.indices.map { try IndependentBallFrameTime(sourcePTS:Int64($0),timeBaseDenominator:1_000_000_000) }
        let frames = zip(input.frames,times).map { IndependentBallisticFrame(frameIndex:$0.0.frameIndex,sourceID:$0.0.sourceID,time:$0.1,originalPixel:$0.0.originalPixel) }
        let result = try IndependentBallisticDiagnostic.fit(.init(camera:input.camera,frames:frames,contactTime:.init(sourcePTS:800_000_000,timeBaseDenominator:1_000_000_000),configuration:input.configuration))
        XCTAssertEqual(result.status,"rejected"); XCTAssertNil(result.rawMotion)
    }
    func testNegativeDepthRejected() throws {
        // A camera translated behind the generated trajectory still has a
        // mathematically valid R. The solver must reject its negative depth.
        let input = try synthetic(), c = try camera(t:[1,2,-12])
        let result = try IndependentBallisticDiagnostic.fit(.init(camera:c,frames:input.frames,contactTime:input.contactTime,configuration:input.configuration))
        XCTAssertEqual(result.status,"rejected"); XCTAssertNil(result.rawMotion)
    }
    func testInvalidCameraAndConfigurationRejectedIncludingDecodedValues() throws {
        let c = try camera()
        for k in [[-1.0,0,960,0,1,540,0,0,1],[1,0,960,0,1,540,0.1,0,1],[Double.nan,0,960,0,1,540,0,0,1]] {
            XCTAssertThrowsError(try IndependentBallisticCamera(sourceID:c.sourceID,width:c.width,height:c.height,rowMajorK:k,rowMajorR:c.rowMajorR,t:c.t,assumptions:c.assumptions))
        }
        XCTAssertThrowsError(try camera(r:[1,0,0,0,1,0,0,0,-1]))
        XCTAssertThrowsError(try camera(r:[1,0,0,0,2,0,0,0,1]))
        XCTAssertThrowsError(try IndependentBallisticConfiguration(residualBoundPixels:.nan))
        XCTAssertThrowsError(try IndependentBallisticConfiguration(residualBoundPixels:3,maximumGaussNewtonIterations:11))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(c)) as? [String:Any]); object["rowMajorR"] = [1,0,0,0,1,0,0,0,-1]
        XCTAssertThrowsError(try JSONDecoder().decode(IndependentBallisticCamera.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    func testDecodedInputRejectsForeignDuplicateOutOfBoundsAndUnsafeClaims() throws {
        let input = try synthetic(), bytes = try JSONEncoder().encode(input)
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        func rejected(_ mutate: (inout [String:Any]) -> Void) throws {
            var object = source; mutate(&object)
            XCTAssertThrowsError(try JSONDecoder().decode(IndependentBallisticInput.self,from:JSONSerialization.data(withJSONObject:object)))
        }
        try rejected { $0["production"] = true }
        try rejected { $0["acceptedCamera"] = ["qualified":true] }
        try rejected { o in var c = o["camera"] as! [String:Any]; c["cameraQualified"] = true; o["camera"] = c }
        try rejected { o in var f = o["frames"] as! [[String:Any]]; f[0]["qualified"] = true; o["frames"] = f }
        try rejected { o in var f = o["frames"] as! [[String:Any]]; f[2]["sourceID"] = "foreign"; o["frames"] = f }
        try rejected { o in var f = o["frames"] as! [[String:Any]]; f[2]["frameIndex"] = 1; o["frames"] = f }
        try rejected { o in var f = o["frames"] as! [[String:Any]]; f[2]["time"] = f[1]["time"]; o["frames"] = f }
        try rejected { o in var f = o["frames"] as! [[String:Any]]; f[2]["originalPixel"] = ["x":1920,"y":2]; o["frames"] = f }
        try rejected { o in var f = o["frames"] as! [[String:Any]]; f[2].removeValue(forKey:"originalPixel"); o["frames"] = f }
        try rejected { o in var f = o["frames"] as! [[String:Any]]; f[2]["time"] = ["sourcePTS":Int64.max,"timeBaseNumerator":2,"timeBaseDenominator":1]; o["frames"] = f }
        try rejected { $0["contactTime"] = ["sourcePTS":1,"timeBaseNumerator":1,"timeBaseDenominator":6000] }
    }
    func testFiniteExtremeAssumptionsProduceSerializableRejection() throws {
        let input = try synthetic()
        let config = try IndependentBallisticConfiguration(gravity:Double.greatestFiniteMagnitude,contactCenterHeight:0.033,residualBoundPixels:Double.leastNonzeroMagnitude)
        let result = try IndependentBallisticDiagnostic.fit(.init(camera:input.camera,frames:input.frames,contactTime:input.contactTime,configuration:config))
        XCTAssertEqual(result.status,"rejected"); XCTAssertNil(result.rawMotion)
        XCTAssertNoThrow(try JSONEncoder().encode(result))
        XCTAssertTrue(result.iterations.allSatisfy { $0.weightedSSEBefore.isFinite && $0.weightedSSEAfter.isFinite && $0.scaledStepNorm.isFinite })
        // Finite linear/Jacobian entries and steps, but squared residuals
        // overflow. The objective guard must reject before recording Inf.
        let objectiveOverflow = try IndependentBallisticDiagnostic.fit(synthetic(noise:0.8,bound:1e-200))
        XCTAssertEqual(objectiveOverflow.status,"rejected")
        XCTAssertTrue(objectiveOverflow.qualificationReasons.contains { $0.contains("objective") })
        XCTAssertTrue(objectiveOverflow.iterations.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(objectiveOverflow))
    }
    func testEquivalentRationalDuplicateAndOverflowingDifferenceRejected() throws {
        let input = try synthetic()
        var f = input.frames
        f[1] = .init(frameIndex:1,sourceID:input.camera.sourceID,time:try .init(sourcePTS:0,timeBaseDenominator:3000),originalPixel:f[1].originalPixel)
        XCTAssertThrowsError(try IndependentBallisticInput(camera:input.camera,frames:f,contactTime:input.contactTime,configuration:input.configuration))
        XCTAssertThrowsError(try IndependentBallisticInput.seconds(.init(value:Int64.max,timescale:1),minus:.init(value:Int64.min,timescale:1)))
    }
}
