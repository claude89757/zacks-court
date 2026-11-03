import XCTest
@testable import CourtCore

final class IndependentFreeFlightDiagnosticTests: XCTestCase {
    private func camera(identity: Bool = false) throws -> IndependentBallisticCamera {
        try .init(sourceID:"free-flight-synthetic",width:1920,height:1080,
                  rowMajorK:[1164.814264659361,0,960,0,1164.814264659361,540,0,0,1],
                  rowMajorR:identity ? [1,0,0,0,1,0,0,0,1] : [0.9999485720544921,0.01007444773073966,0.001165653937790668,0.0008255998640870127,0.033692598964962,-0.9994319022123771,-0.010107998369930215,0.9993814658467038,0.033682548761141164],
                  t:identity ? [0,0,0] : [-5.689791368917111,1.75322016472111,6.251324074536921],assumptions:["Synthetic or previously assumed fixed camera; not physical calibration"])
    }
    private func fixture(base: Int64 = 0, short: Bool = false, missing: Set<Int> = [], noise: Double = 0,
                         bound: Double = 9, iterations: Int = 10, p0: [Double] = [7,0,2.5], v0: [Double] = [-5,18,1],
                         generatedGravity: Double = 9.81, identity: Bool = false) throws -> IndependentFreeFlightInput {
        let cam = try camera(identity:identity), denominator: Int32 = short ? 1_000_000_000 : 600
        var frames: [IndependentBallisticFrame] = []
        for index in 0...40 {
            let tick = Int64(index)*(short ? 250 : 10), time = Double(tick)/Double(denominator)
            let world = (0..<3).map { p0[$0]+v0[$0]*time+($0 == 2 ? -0.5*generatedGravity*time*time : 0) }
            let cc = (0..<3).map { row in (0..<3).reduce(cam.t[row]) { $0+cam.rowMajorR[row*3+$1]*world[$1] } }
            let h = (0..<3).map { row in (0..<3).reduce(0.0) { $0+cam.rowMajorK[row*3+$1]*cc[$1] } }
            let px = IndependentBallisticPixel(x:h[0]/h[2]+noise*sin(Double(index)*1.7),y:h[1]/h[2]+noise*cos(Double(index)*0.9))
            frames.append(.init(frameIndex:index,sourceID:cam.sourceID,time:try .init(sourcePTS:base+tick,timeBaseDenominator:denominator),originalPixel:missing.contains(index) ? nil : px,missingReason:missing.contains(index) ? "unknown, not interpolated" : nil))
        }
        return try .init(camera:cam,frames:frames,configuration:.init(residualBoundPixels:bound,maximumGaussNewtonIterations:iterations))
    }
    func testExactSixParametersAndFutureRootWithoutContactInput() throws {
        let r = try IndependentFreeFlightDiagnostic.fit(fixture()), m = try XCTUnwrap(r.rawMotion), root = try XCTUnwrap(r.futureDownwardGroundRoot)
        XCTAssertTrue(r.rawAlgebraicQualityPassed); XCTAssertTrue(r.converged); XCTAssertEqual(r.finalSystem?.rank,6)
        for (a,b) in zip(m.positionFirstObservedMeters,[7.0,0,2.5]) { XCTAssertEqual(a,b,accuracy:1e-9) }
        for (a,b) in zip(m.velocityFirstObservedMetersPerSecond,[-5.0,18,1]) { XCTAssertEqual(a,b,accuracy:1e-9) }
        XCTAssertEqual(root.secondsAfterFirstObserved,(1+sqrt(1+2*9.81*(2.5-0.033)))/9.81,accuracy:1e-10)
        XCTAssertEqual(root.positionMeters[2],0.033,accuracy:1e-10)
        XCTAssertGreaterThan(root.secondsAfterFirstObserved,try XCTUnwrap(r.observationSpanSeconds))
        XCTAssertLessThan(try XCTUnwrap(r.reprojectionRMSPixels),1e-9)
    }
    func testExactLargePTSAndUnknownFramesPreserved() throws {
        let r = try IndependentFreeFlightDiagnostic.fit(fixture(base:1<<60,missing:[2,7,36]))
        XCTAssertEqual(r.observedFrameIndices.count,38); XCTAssertEqual(r.missingFrameIndices,[2,7,36])
        XCTAssertEqual(r.firstObservedTime.sourcePTS,1<<60)
        XCTAssertEqual(try XCTUnwrap(r.rawMotion).velocityFirstObservedMetersPerSecond[1],18,accuracy:1e-9)
    }
    func testNoisyFitStillNullAcceptedOutputs() throws {
        let r = try IndependentFreeFlightDiagnostic.fit(fixture(noise:0.8))
        XCTAssertTrue(r.rawAlgebraicQualityPassed); XCTAssertGreaterThan(try XCTUnwrap(r.reprojectionRMSPixels),0.1)
        XCTAssertNil(r.acceptedCamera); XCTAssertNil(r.velocity); XCTAssertNil(r.speedKilometersPerHour)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(r)) as? [String:Any])
        for k in ["acceptedCamera","velocity","speedKilometersPerHour"] { XCTAssertTrue(j[k] is NSNull) }
        for k in ["formal","human","production","cameraQualified","physicalAccuracyValidated","nativeEndToEndSpeedAccepted","twentyPercentAcceptanceEligible"] { XCTAssertEqual(j[k] as? Bool,false) }
    }
    func testShortSpanAndConstantBearingExplicitRankFailure() throws {
        let short = try IndependentFreeFlightDiagnostic.fit(fixture(short:true))
        XCTAssertFalse(short.rawAlgebraicQualityPassed); XCTAssertNil(short.rawMotion); XCTAssertLessThan(try XCTUnwrap(short.initialSystem).rank,6)
        let constant = try IndependentFreeFlightDiagnostic.fit(fixture(p0:[0,0,10],v0:[0,0,0.5],identity:true))
        XCTAssertFalse(constant.rawAlgebraicQualityPassed); XCTAssertNil(constant.rawMotion); XCTAssertEqual(constant.initialSystem?.rank,4)
        XCTAssertFalse(constant.qualityReasons.isEmpty); _ = try JSONEncoder().encode(constant)
    }
    func testNegativeDepthCannotBecomeAccepted() throws {
        let r = try IndependentFreeFlightDiagnostic.fit(fixture(generatedGravity:-9.81))
        XCTAssertEqual(r.status,"rejected"); XCTAssertFalse(r.rawAlgebraicQualityPassed)
        XCTAssertTrue(r.qualityReasons.joined().contains("depth")); XCTAssertNil(r.futureDownwardGroundRoot)
    }
    func testObservedGroundPenetrationAndPastRootRejectedWithoutErasingRaw() throws {
        let r = try IndependentFreeFlightDiagnostic.fit(fixture(p0:[7,0,0.1],v0:[-5,18,-2]))
        XCTAssertNotNil(r.rawMotion); XCTAssertFalse(r.aboveGroundAllObservations); XCTAssertFalse(r.rawAlgebraicQualityPassed)
        XCTAssertNil(r.futureDownwardGroundRoot)
        XCTAssertTrue(r.qualityReasons.joined().contains("ground")); XCTAssertTrue(r.qualityReasons.joined().contains("future"))
    }
    func testHighResidualAndIterationLimitRemainRejected() throws {
        let r = try IndependentFreeFlightDiagnostic.fit(fixture(noise:0.8,bound:0.01))
        XCTAssertNotNil(r.rawMotion); XCTAssertFalse(r.allResidualsWithinBound); XCTAssertFalse(r.rawAlgebraicQualityPassed)
        let limited = try IndependentFreeFlightDiagnostic.fit(fixture(noise:0.8,iterations:1))
        XCTAssertFalse(limited.converged); XCTAssertFalse(limited.rawAlgebraicQualityPassed); XCTAssertEqual(limited.iterations.count,1)
    }
    func testNonfiniteObjectiveProducesSerializableFailure() throws {
        let r = try IndependentFreeFlightDiagnostic.fit(fixture(noise:0.8,bound:1e-200))
        XCTAssertFalse(r.rawAlgebraicQualityPassed); XCTAssertFalse(r.qualityReasons.isEmpty)
        _ = try JSONEncoder().encode(r)
    }
    func testDecodedUnsafeContactAndForeignClaimsRejected() throws {
        let input = try fixture(), source = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(input)) as? [String:Any])
        func rejected(_ modify: (inout [String:Any]) -> Void) throws {
            var j = source; modify(&j)
            XCTAssertThrowsError(try JSONDecoder().decode(IndependentFreeFlightInput.self,from:JSONSerialization.data(withJSONObject:j)))
        }
        try rejected { $0["contactTime"] = ["sourcePTS":500,"timeBaseNumerator":1,"timeBaseDenominator":600] }
        try rejected { $0["formal"] = true }
        try rejected { var c = $0["camera"] as! [String:Any]; c["cameraQualified"] = true; $0["camera"] = c }
        try rejected { var fs = $0["frames"] as! [[String:Any]]; fs[0]["sourceID"] = "foreign"; $0["frames"] = fs }
        try rejected { var fs = $0["frames"] as! [[String:Any]]; fs[1]["time"] = fs[0]["time"]; $0["frames"] = fs }
        XCTAssertThrowsError(try fixture(missing:Set(0..<10)))
    }
    /// Opt-in real artifacts remain in .local; skipped is not physical acceptance.
    func testFrozenThreeRealInputsAgainstPython() throws {
        guard let path = ProcessInfo.processInfo.environment["COURT_FREE_FLIGHT_PARITY_DIR"] else { throw XCTSkip("Requires private frozen real inputs; synthetic tests do not replace real parity") }
        struct Fixture: Decodable { struct Case: Decodable { let id:String; let input:IndependentFreeFlightInput; let position:[Double]; let velocity:[Double]; let rootSeconds:Double; let rms:Double; let condition:Double }; let cases:[Case] }
        let data = try Data(contentsOf:URL(fileURLWithPath:path).appendingPathComponent("swift-parity-fixtures.json")), fixtures = try JSONDecoder().decode(Fixture.self,from:data)
        XCTAssertEqual(fixtures.cases.count,3)
        for f in fixtures.cases {
            let r = try IndependentFreeFlightDiagnostic.fit(f.input), m = try XCTUnwrap(r.rawMotion)
            XCTAssertTrue(r.rawAlgebraicQualityPassed,f.id)
            for (a,b) in zip(m.positionFirstObservedMeters,f.position) { XCTAssertEqual(a,b,accuracy:1e-7,f.id) }
            for (a,b) in zip(m.velocityFirstObservedMetersPerSecond,f.velocity) { XCTAssertEqual(a,b,accuracy:1e-7,f.id) }
            XCTAssertEqual(try XCTUnwrap(r.futureDownwardGroundRoot).secondsAfterFirstObserved,f.rootSeconds,accuracy:1e-8,f.id)
            XCTAssertEqual(try XCTUnwrap(r.reprojectionRMSPixels),f.rms,accuracy:1e-8,f.id)
            XCTAssertEqual(try XCTUnwrap(r.finalSystem?.columnScaledCondition),f.condition,accuracy:1e-6,f.id)
            _ = try JSONEncoder().encode(r)
        }
    }
}
