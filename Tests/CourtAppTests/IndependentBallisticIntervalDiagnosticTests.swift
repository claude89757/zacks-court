import XCTest
@testable import CourtCore

final class IndependentBallisticIntervalDiagnosticTests: XCTestCase {
    private func time(_ ticks: Int64, base: Int64 = 0, denominator: Int32 = 1000) throws -> IndependentBallFrameTime {
        try .init(sourcePTS: base+ticks, timeBaseDenominator: denominator)
    }
    private func fixture(base: Int64 = 0, badQuality: Bool = false, vz: Double = -3) throws -> (IndependentBallisticInput, IndependentBallisticResult) {
        let camera = try IndependentBallisticCamera(sourceID: "interval-synthetic", width: 1920, height: 1080, rowMajorK: [1000,0,960,0,1000,540,0,0,1], rowMajorR: [1,0,0,0,1,0,0,0,1], t: [0,0,10], assumptions: ["Synthetic algebra fixture only"])
        let frames = try [Int64(0),500,1000].enumerated().map { index, tick in IndependentBallisticFrame(frameIndex: index, sourceID: camera.sourceID, time: try time(tick,base:base), originalPixel: .init(x: 960, y: 540)) }
        let input = try IndependentBallisticInput(camera: camera, frames: frames, contactTime: time(2000,base:base), configuration: .init(gravity: 2, residualBoundPixels: 3))
        let raw = IndependentBallisticRawMotion(contactParameters: [0,0,3,4,vz], positionFirstObservedMeters: [-6,-8,0.033-2*vz-4], velocityFirstObservedMetersPerSecond: [3,4,vz+4], velocityFirstObservedNormMetersPerSecond: hypot(5,vz+4), scaledFirstObservationParameters: [-6,-8,6,8,2*(vz+4)])
        let fit = IndependentBallisticResult(status: badQuality ? "fixed_camera_motion_quality_rejected" : "unqualified_fixed_camera_motion_diagnostic", rawMotion: raw, observedFrameIndices: [0,1,2], missingFrameIndices: [], reprojectionPixels: frames.map { $0.originalPixel! }, residualsPixels: [0,0,0], reprojectionRMSPixels: 0, reprojectionMaximumPixels: 0, minimumDepthMeters: 10, minimumHeightMeters: 0.033, scaledJacobianCondition: 2, allResidualsWithinBound: !badQuality, aboveGroundAllObservations: true, iterations: [], qualificationReasons: ["Synthetic original fit remains unqualified"])
        return (input,fit)
    }
    private func request(_ start: Int64 = 0, _ end: Int64 = 1000, base: Int64 = 0, collisions: [IndependentBallFrameTime] = [], reason: String? = nil) throws -> IndependentBallisticIntervalRequest {
        .init(start: try time(start,base:base), end: try time(end,base:base), knownCollisionTimes: collisions, collisionFreeAssumption: "Synthetic collision-free incoming branch; fixture only", extrapolationReason: reason)
    }
    func testGeneralPathMeanMatchesIndependentAnalyticIntegralAndIsNotDisplacement() throws {
        let (input,fit) = try fixture()
        let result = try IndependentBallisticIntervalDiagnostic.evaluate(input: input, fit: fit, request: request())
        // Independent analytic primitive for horizontal speed 5 and vz in [-1,1].
        let golden = 0.5*(sqrt(26)+25*asinh(0.2))
        XCTAssertEqual(result.rawMeanPathSpeedMetersPerSecond, golden, accuracy: 2e-12)
        XCTAssertGreaterThan(result.rawMeanPathSpeedMetersPerSecond, 5) // displacement / duration = 5
        XCTAssertEqual(result.rawStartVelocityMetersPerSecond, [3,4,1]); XCTAssertEqual(result.rawEndVelocityMetersPerSecond, [3,4,-1])
        XCTAssertEqual(result.rawStartSpeedMetersPerSecond, sqrt(26), accuracy: 1e-14)
        XCTAssertTrue(result.rawIntervalQualityPassed); XCTAssertFalse(result.didExtrapolate)
        XCTAssertLessThanOrEqual(result.numericalFunctionEvaluations,4096)
        XCTAssertNil(result.speedKilometersPerHour); XCTAssertFalse(result.physicalAccuracyValidated)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String:Any])
        for key in ["speedKilometersPerHour","acceptedCamera","velocity"] { XCTAssertTrue(json[key] is NSNull) }
        for key in ["production","human","formal","cameraQualified","physicalAccuracyValidated","nativeEndToEndSpeedAccepted","twentyPercentAcceptanceEligible"] { XCTAssertEqual(json[key] as? Bool,false) }
    }
    func testVerticalAndConstantLimitsNeverCancelPathLength() throws {
        for (a,b,expected) in [(3.0,1.0,2.0),(-1.0,-3.0,2.0),(1.0,-1.0,0.5),(0.0,-2.0,1.0)] {
            let n = try IndependentBallisticIntervalDiagnostic.integrateMean(vx:0,vy:0,startVz:a,endVz:b)
            XCTAssertEqual(n.mean,expected,accuracy:1e-14)
        }
        XCTAssertEqual(try IndependentBallisticIntervalDiagnostic.integrateMean(vx:3,vy:4,startVz:12,endVz:12).mean,13)
        XCTAssertEqual(try IndependentBallisticIntervalDiagnostic.integrateMean(vx:0,vy:0,startVz:0,endVz:0).mean,0)
        XCTAssertEqual(try IndependentBallisticIntervalDiagnostic.integrateMean(vx:3,vy:4,startVz:1,endVz:1-1e-14).mean,hypot(5,1),accuracy:1e-13)
    }
    func testTinyHorizontalSpeedAcrossApexAndNumericGolden() throws {
        let tiny = try IndependentBallisticIntervalDiagnostic.integrateMean(vx:1e-150,vy:0,startVz:1,endVz:-1)
        XCTAssertEqual(tiny.mean,0.5,accuracy:1e-12)
        // Independent high-resolution composite Simpson reference, not GL nodes.
        let n = 20000, h = 1.0/Double(n)
        func speed(_ u: Double) -> Double { sqrt(13 + pow(7-11*u,2)) }
        var sum = speed(0)+speed(1)
        for i in 1..<n { sum += (i.isMultiple(of:2) ? 2.0 : 4.0)*speed(Double(i)*h) }
        let actual = try IndependentBallisticIntervalDiagnostic.integrateMean(vx:2,vy:3,startVz:7,endVz:-4)
        XCTAssertEqual(actual.mean,sum*h/3,accuracy:2e-12)
    }
    func testHugeAbsoluteRationalPTSAndOneNanosecondDuration() throws {
        let base: Int64 = 1<<60
        let (input,fit) = try fixture(base:base)
        let ordinary = try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:request(base:base))
        XCTAssertEqual(ordinary.durationSeconds,1)
        let start = try IndependentBallFrameTime(sourcePTS:base,timeBaseDenominator:1_000_000_000)
        let end = try IndependentBallFrameTime(sourcePTS:base+1,timeBaseDenominator:1_000_000_000)
        let contact = try IndependentBallFrameTime(sourcePTS:base+2_000_000_000,timeBaseDenominator:1_000_000_000)
        let frames = try [Int64(0),500_000_000,1_000_000_000].enumerated().map { i,tick in IndependentBallisticFrame(frameIndex:i,sourceID:input.camera.sourceID,time:try .init(sourcePTS:base+tick,timeBaseDenominator:1_000_000_000),originalPixel:.init(x:960,y:540)) }
        let nanoInput = try IndependentBallisticInput(camera:input.camera,frames:frames,contactTime:contact,configuration:input.configuration)
        let r = try IndependentBallisticIntervalDiagnostic.evaluate(input:nanoInput,fit:fit,request:.init(start:start,end:end,knownCollisionTimes:[],collisionFreeAssumption:"Synthetic nanosecond interval"))
        XCTAssertEqual(r.durationSeconds,1e-9,accuracy:1e-24)
        XCTAssertEqual(r.rawStartVelocityMetersPerSecond[2],1,accuracy:1e-14)
        XCTAssertEqual(r.rawEndVelocityMetersPerSecond[2],1-2e-9,accuracy:1e-14)
    }
    func testFarContactEpochPreservesNanosecondApexVelocity() throws {
        let (original,fit) = try fixture(vz:-1e9)
        let frames = try [Int64(0),1,2].enumerated().map { i,tick in IndependentBallisticFrame(frameIndex:i,sourceID:original.camera.sourceID,time:try .init(sourcePTS:tick,timeBaseDenominator:1_000_000_000),originalPixel:.init(x:960,y:540)) }
        let input = try IndependentBallisticInput(camera:original.camera,frames:frames,contactTime:.init(sourcePTS:1_000_000_000_000_000_000,timeBaseDenominator:1_000_000_000),configuration:.init(gravity:1,residualBoundPixels:3))
        let request = IndependentBallisticIntervalRequest(start:frames[0].time,end:frames[1].time,knownCollisionTimes:[],collisionFreeAssumption:"Synthetic nanosecond interval near a far-epoch apex")
        let result = try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:request)
        XCTAssertEqual(result.durationSeconds,1e-9,accuracy:1e-24)
        XCTAssertEqual(result.rawStartVelocityMetersPerSecond[2],0,accuracy:1e-24)
        XCTAssertEqual(result.rawEndVelocityMetersPerSecond[2],-1e-9,accuracy:1e-24)
    }
    func testPublicEvaluationFitsItsOwnInputAndRetainsOriginalFit() throws {
        let (fixtureInput,_) = try fixture()
        let frames = fixtureInput.frames.map { frame -> IndependentBallisticFrame in
            let t = Double(frame.time.sourcePTS)/1000, d = t-2
            let x = 1+3*d, y = 2+4*d, z = 0.033-3*d-d*d+10
            return .init(frameIndex:frame.frameIndex,sourceID:frame.sourceID,time:frame.time,originalPixel:.init(x:960+1000*x/z,y:540+1000*y/z))
        }
        let input = try IndependentBallisticInput(camera:fixtureInput.camera,frames:frames,contactTime:fixtureInput.contactTime,configuration:fixtureInput.configuration)
        let evaluated = try IndependentBallisticIntervalDiagnostic.evaluate(input:input,request:request())
        XCTAssertEqual(evaluated.rawInterval.fitStatus,evaluated.fit.status)
        XCTAssertEqual(evaluated.rawInterval.rawStartVelocityMetersPerSecond[2],1,accuracy:1e-8)
        XCTAssertNil(evaluated.fit.speedKilometersPerHour); XCTAssertFalse(evaluated.rawInterval.production)
    }
    func testContactLeftLimitIsExtrapolationBeyondLastObservation() throws {
        let (input,fit) = try fixture()
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:request(0,2000)))
        let r = try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:request(0,2000,reason:"Explicit diagnostic extension to assumed contact"))
        XCTAssertTrue(r.didExtrapolate); XCTAssertEqual(r.rawEndVelocityMetersPerSecond[2],-3)
        XCTAssertEqual(r.rawEndHeightMeters,0.033,accuracy:1e-14)
        for (a,b) in [(1000,1000),(1000,0),(0,2001)] { XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:request(Int64(a),Int64(b),reason:"Explicit extension"))) }
    }
    func testCollisionCannotBeCrossedTouchedOrTrimmedOutOfOriginalFit() throws {
        let (input,fit) = try fixture()
        for (a,b,c) in [(0,1000,0),(500,1000,500),(750,1000,500),(-1000,-500,-750)] {
            XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:request(Int64(a),Int64(b),collisions:[time(Int64(c))],reason:"Cannot override collisions")))
        }
        XCTAssertNoThrow(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:request(collisions:[time(-1),time(2000),time(3000)])))
    }
    func testOriginalFitQualityAndUnphysicalBranchRemainRawFailures() throws {
        for (bad,vz) in [(true,-3.0),(false,1.0),(false,-0.1)] {
            let (input,fit) = try fixture(badQuality:bad,vz:vz)
            let result = try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:request())
            XCTAssertFalse(result.rawIntervalQualityPassed); XCTAssertEqual(result.status,"fixed_camera_interval_quality_rejected")
            XCTAssertEqual(result.fitStatus,fit.status); XCTAssertEqual(result.fitQualificationReasons,fit.qualificationReasons)
            XCTAssertFalse(result.nativeEndToEndSpeedAccepted)
        }
    }
    func testValidationBudgetAndNonfiniteRejections() throws {
        let (input,fit) = try fixture()
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:.init(start:time(0),end:time(1000),knownCollisionTimes:[],collisionFreeAssumption:" ")))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:request(0,2000,reason:" ")))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.integrateMean(vx:.nan,vy:0,startVz:0,endVz:1))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.integrateMean(vx:1,vy:0,startVz:1,endVz:-1,maximumEvaluations:23))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.integrateMean(vx:Double.greatestFiniteMagnitude,vy:Double.greatestFiniteMagnitude,startVz:0,endVz:0))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.integrateMean(vx:0.01,vy:0,startVz:7,endVz:-4,maximumEvaluations:48))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.integrateMean(vx:1e-10,vy:0,startVz:Double.leastNonzeroMagnitude,endVz:-1))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(fit)) as? [String:Any])
        object["observedFrameIndices"] = [0,1]
        let mismatched = try JSONDecoder().decode(IndependentBallisticResult.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:mismatched,request:request()))
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(fit)) as? [String:Any])
        var raw = malformed["rawMotion"] as! [String:Any]; raw["contactParameters"] = [0,0,3,4]; malformed["rawMotion"] = raw
        let malformedFit = try JSONDecoder().decode(IndependentBallisticResult.self,from:JSONSerialization.data(withJSONObject:malformed))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:malformedFit,request:request()))
        let enormousGravity = try IndependentBallisticInput(camera:input.camera,frames:input.frames,contactTime:input.contactTime,configuration:.init(gravity:Double.greatestFiniteMagnitude,residualBoundPixels:3))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.evaluate(input:enormousGravity,fit:fit,request:request()))
        let equivalent = IndependentBallisticIntervalRequest(start:try .init(sourcePTS:0,timeBaseDenominator:60),end:try .init(sourcePTS:60,timeBaseDenominator:60),knownCollisionTimes:[],collisionFreeAssumption:"Equivalent rational request")
        XCTAssertEqual(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:equivalent).durationSeconds,1)
        let overflowing = try JSONDecoder().decode(IndependentBallFrameTime.self,from:Data(#"{"sourcePTS":9223372036854775807,"timeBaseNumerator":2,"timeBaseDenominator":1}"#.utf8))
        XCTAssertThrowsError(try IndependentBallisticIntervalDiagnostic.evaluate(input:input,fit:fit,request:.init(start:overflowing,end:time(1000),knownCollisionTimes:[],collisionFreeAssumption:"Bad exact timestamp")))
        var requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(request())) as? [String:Any])
        requestObject["production"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(IndependentBallisticIntervalRequest.self,from:JSONSerialization.data(withJSONObject:requestObject)))
    }
}
