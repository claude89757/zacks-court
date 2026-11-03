import XCTest
@testable import CourtCore

final class IndependentBallTrackingTests: XCTestCase {
    func testStrictThresholdConnectivityAndNativeMapping() throws {
        var map = [Float](repeating: 0, count: 16)
        map[0] = 0.3; map[5] = 0.9; map[10] = 0.8; map[3] = 0.6
        let transform = try IndependentBallImageTransform(originalWidth: 1280, originalHeight: 720)
        let bank = try IndependentBallCandidateBank.extract(map, width: 4, height: 4, transform: transform)
        XCTAssertEqual(bank.totalComponents,2)
        XCTAssertEqual(bank.candidates[0].pixelArea,2)
        XCTAssertEqual(bank.candidates[0].box,[1,1,2,2])
        XCTAssertEqual(bank.candidates[0].originalXY,[640,360])
        XCTAssertEqual(bank.candidates[1].pixelArea,1)
    }
    func testUnknownHeatmapAndInvalidTransformsFail() throws {
        let transform = try IndependentBallImageTransform(originalWidth: 1280,originalHeight:720)
        XCTAssertThrowsError(try IndependentBallCandidateBank.extract([.nan],width:1,height:1,transform:transform))
        XCTAssertThrowsError(try IndependentBallCandidateBank.extract([Float](repeating:0,count:513),width:513,height:1,transform:transform))
        XCTAssertThrowsError(try IndependentBallCandidateBank.extract([Float](repeating:0,count:289),width:1,height:289,transform:transform))
        XCTAssertThrowsError(try IndependentBallImageTransform(originalWidth:1280,originalHeight:720,cropX:1000,cropWidth:400))
        XCTAssertThrowsError(try IndependentBallFrameTime(sourcePTS:1,timeBaseDenominator:0))
    }
    func testPastTrackerKeepsMissingEmptyAndResetsAtSourceGap() throws {
        let tracker = try IndependentCausalBallTracker(), transform = try IndependentBallImageTransform(originalWidth:1280,originalHeight:720)
        func point(_ x: Int) -> IndependentBallGridCandidate { .init(identifier:x,box:[min(511,x),100,1,1],originalXY:[x,100],equivalentXY:[Double(x),100],peak:0.9,mean:0.9,pixelArea:1) }
        func stamp(_ pts: Int64) throws -> IndependentBallFrameTime { try .init(sourcePTS:pts,timeBaseDenominator:60) }
        XCTAssertNotNil(try tracker.select(candidates:[point(100)],time:stamp(0),sourceID:"a",transform:transform).candidate)
        XCTAssertNil(try tracker.select(candidates:[],time:stamp(1),sourceID:"a",transform:transform).candidate)
        XCTAssertTrue(try tracker.select(candidates:[point(110)],time:stamp(2),sourceID:"a",transform:transform).linkedToPast)
        let gap = try tracker.select(candidates:[point(1100)],time:stamp(30),sourceID:"a",transform:transform)
        XCTAssertFalse(gap.linkedToPast); XCTAssertEqual(gap.resetReason,"source_gap")
        XCTAssertThrowsError(try tracker.select(candidates:[],time:stamp(30),sourceID:"a",transform:transform))
    }
    func testSourceChangeDoesNotStitchTrajectories() throws {
        let tracker = try IndependentCausalBallTracker(), transform = try IndependentBallImageTransform(originalWidth:1280,originalHeight:720)
        let point = IndependentBallGridCandidate(identifier:1,box:[1,1,1,1],originalXY:[1,1],equivalentXY:[1,1],peak:0.99,mean:0.99,pixelArea:1)
        _ = try tracker.select(candidates:[point],time:.init(sourcePTS:10,timeBaseDenominator:60),sourceID:"first",transform:transform)
        let next = try tracker.select(candidates:[point],time:.init(sourcePTS:1,timeBaseDenominator:60),sourceID:"second",transform:transform)
        XCTAssertFalse(next.linkedToPast); XCTAssertEqual(next.resetReason,"source_changed")
    }
    func testDecodedInvalidInputResetsRatherThanBridging() throws {
        let tracker = try IndependentCausalBallTracker(), transform = try IndependentBallImageTransform(originalWidth:1280,originalHeight:720)
        let point = IndependentBallGridCandidate(identifier:1,box:[1,1,1,1],originalXY:[1,1],equivalentXY:[1,1],peak:0.99,mean:0.99,pixelArea:1)
        _ = try tracker.select(candidates:[point],time:.init(sourcePTS:0,timeBaseDenominator:60),sourceID:"first",transform:transform)
        let invalid = try JSONDecoder().decode(IndependentBallFrameTime.self,from:Data(#"{"sourcePTS":1,"timeBaseNumerator":1,"timeBaseDenominator":0}"#.utf8))
        XCTAssertThrowsError(try tracker.select(candidates:[],time:invalid,sourceID:"first",transform:transform))
        let next = try tracker.select(candidates:[point],time:.init(sourcePTS:2,timeBaseDenominator:60),sourceID:"first",transform:transform)
        XCTAssertFalse(next.linkedToPast)
        let inconsistent = IndependentBallGridCandidate(identifier:1,box:[1,1,1,1],originalXY:[1,1],equivalentXY:[100,100],peak:0.99,mean:0.99,pixelArea:1)
        XCTAssertThrowsError(try tracker.select(candidates:[inconsistent],time:.init(sourcePTS:3,timeBaseDenominator:60),sourceID:"first",transform:transform))
        XCTAssertThrowsError(try IndependentBallImageTransform(originalWidth:Int.max,originalHeight:720,cropX:Int.max-1,cropWidth:1))
    }
    func testInvalidPublicCandidateAndCropCannotTrapOrMasquerade() throws {
        let bad = IndependentBallGridCandidate(identifier:1,box:[],originalXY:[1,1],equivalentXY:[1,1],peak:0.9,mean:0.9,pixelArea:1)
        XCTAssertEqual(bad.boxArea,0)
        let overflow = IndependentBallGridCandidate(identifier:1,box:[0,0,Int.max,Int.max],originalXY:[1,1],equivalentXY:[1,1],peak:0.9,mean:0.9,pixelArea:1)
        XCTAssertEqual(overflow.boxArea,0)
        XCTAssertThrowsError(try IndependentCausalBallTracker(nominalFramesPerSecond:Double.leastNonzeroMagnitude))
        let tracker = try IndependentCausalBallTracker(), roi = try IndependentBallImageTransform(originalWidth:1280,originalHeight:720,cropX:640,cropWidth:640)
        let outside = IndependentBallGridCandidate(identifier:1,box:[1,1,1,1],originalXY:[1,1],equivalentXY:[1,1],peak:0.9,mean:0.9,pixelArea:1)
        XCTAssertThrowsError(try tracker.select(candidates:[outside],time:.init(sourcePTS:0,timeBaseDenominator:60),sourceID:"a",transform:roi))
    }
}
