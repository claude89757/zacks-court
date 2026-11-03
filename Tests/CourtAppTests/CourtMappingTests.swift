#if os(macOS)
import XCTest
import CoreVideo
import CoreML
import AVFoundation
@testable import CourtCore

final class CourtMappingTests: XCTestCase {
    func testFrameCadenceAt25_30And60FPS() {
        XCTAssertEqual(TennisFrameCadence.pairing(fps:25).period,2)
        XCTAssertEqual(TennisFrameCadence.pairing(fps:25).delay,1)
        XCTAssertEqual(TennisFrameCadence.pairing(fps:30).period,3)
        XCTAssertEqual(TennisFrameCadence.pairing(fps:30).delay,1)
        XCTAssertEqual(TennisFrameCadence.pairing(fps:60).period,6)
        XCTAssertEqual(TennisFrameCadence.pairing(fps:60).delay,2)
        XCTAssertEqual(TennisFrameCadence.pairing(fps:29.97).period,3)
    }
    func testGroundMappingUsesKnownCourtSurfaceAndRejectsDegenerateBasis() throws {
        let image: [NormalizedPoint] = [.init(x:0.1,y:0.9),.init(x:0.9,y:0.9),.init(x:0.7,y:0.1),.init(x:0.3,y:0.1)]
        let world: [TennisSurfacePoint] = [.init(x:0,y:0),.init(x:10.97,y:0),.init(x:10.97,y:23.77),.init(x:0,y:23.77)]
        let h = try XCTUnwrap(TennisCourtMapping.solve(image:image,world:world))
        let mapping = TennisCourtMapping(coefficients:h,hull:image,state:.init(isAvailable:true))
        let near = try XCTUnwrap(mapping.project(.init(x:0.5,y:0.9)))
        XCTAssertEqual(near.x,5.485,accuracy:0.000001); XCTAssertEqual(near.y,0,accuracy:0.000001)
        XCTAssertNil(mapping.project(.init(x:0.01,y:0.99)))
        XCTAssertNil(TennisCourtMapping.solve(image:Array(repeating:.init(x:0,y:0),count:4),world:world))
    }
    func testBuildsWithoutTheReferenceChainRefuseItPlainly() {
        guard !ReferenceChain.isAvailable else { return }
        XCTAssertThrowsError(try ReferenceChain.makeEngine(configuration: .init(modelDirectory: URL(fileURLWithPath: "/does-not-exist"))))
    }
}
#endif
