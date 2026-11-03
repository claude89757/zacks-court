import XCTest
import AVFoundation
@testable import CourtCore

final class IndependentLocalVideoAnalyzerTests: XCTestCase {
    private func frame(_ value: Int64) throws -> IndependentVideoFrame {
        let rgb = try IndependentRGB8Buffer(width:1,height:1,bytesPerRow:3,bytes:[20,40,60],pixelFormat:.rgb8,coordinateSpace:.decodedTopLeftUnrotated)
        return .init(rgb:rgb,presentationTime:CMTime(value:value,timescale:60),duration:CMTime(value:1,timescale:60),decodeTime:.invalid,
            decodedColor:.init(primaries:nil,transferFunction:nil,yCbCrMatrix:nil,fullRangeVideo:nil))
    }
    private func heatmaps() -> [Float] {
        var maps = [Float](repeating:0,count:IndependentBallModel.outputCount)
        for i in 0..<8 where i != 2 { maps[i*512*288+100*512+200] = 0.9 }
        return maps
    }
    func testActualPTSWholeWindowMissingWarmupAndTailAreRetained() throws {
        var predictions = 0
        let run = try IndependentLocalVideoAccumulator(source:"synthetic",nominalFPS:60,roi:nil,maximumFrames:100,predict:{ input in
            predictions += 1; XCTAssertEqual(input.count,IndependentBallModel.inputCount); return self.heatmaps()
        })
        let base: Int64 = 1<<60
        for i in 0..<59 { try autoreleasepool { try run.append(frame(base+Int64(i))) } }
        try run.finish()
        XCTAssertEqual(predictions,1); XCTAssertEqual(run.frames.count,59); XCTAssertEqual(run.windows.count,1)
        XCTAssertEqual(run.frames.prefix(48).filter { $0.state == .warmup }.count,48)
        XCTAssertEqual(run.frames[48].time.sourcePTS,base+48)
        XCTAssertEqual(run.frames[48].presentationTime.value,base+48)
        XCTAssertEqual(run.frames[48].availableAt?.value,base+55)
        XCTAssertEqual(run.frames[48].sourceLookaheadSeconds ?? -1,7.0/60,accuracy:1e-15)
        XCTAssertEqual(run.frames[50].state,.missing); XCTAssertNil(run.frames[50].candidate)
        XCTAssertNotNil(run.frames[50].candidateBank); XCTAssertNotNil(run.frames[50].unavailableReason)
        XCTAssertEqual(run.frames[56...58].filter { $0.state == .incompleteWindow }.count,3)
        XCTAssertTrue(run.frames[56...58].allSatisfy { $0.unavailableReason == "incomplete_eight_frame_tail" && $0.selection == nil })
        XCTAssertEqual(run.windows[0].decodeIndices,Array(48..<56))
        XCTAssertEqual(run.windows[0].backgroundTimes.map(\.sourcePTS),(0..<48).map { base+Int64($0) })
        XCTAssertLessThanOrEqual(run.peakRetainedBytes,48*IndependentBallWindowAssembler.resizedImageBytes)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(run.frames[48])) as? [String:Any])
        for key in ["acceptedCamera","velocity","speedKilometersPerHour"] { XCTAssertTrue(row[key] is NSNull) }
        for key in ["physicalAccuracyValidated","cameraQualified","human","formal","production","nativeEndToEndSpeedAccepted","twentyPercentAcceptanceEligible"] { XCTAssertEqual(row[key] as? Bool,false) }
    }
    func testGapAbandonsIncompleteWindowAndStartsFreshWarmup() throws {
        let run = try IndependentLocalVideoAccumulator(source:"synthetic",nominalFPS:60,roi:nil,maximumFrames:100,predict:{ _ in self.heatmaps() })
        for i in 0..<59 { try autoreleasepool { try run.append(frame(Int64(i))) } }
        for i in 70..<74 { try autoreleasepool { try run.append(frame(Int64(i))) } }
        try run.finish()
        XCTAssertEqual(run.windows.count,1)
        XCTAssertTrue(run.frames[56...58].allSatisfy { $0.state == .incompleteWindow && $0.unavailableReason == "incomplete_window_discarded_source_gap" })
        XCTAssertTrue(run.frames[59...62].allSatisfy { $0.state == .warmup && $0.segmentIndex == 1 && $0.unavailableReason == "insufficient_48_frame_background" })
    }
    func testShortVideoAndFrameLimitDoNotInventPredictions() throws {
        var predictions = 0
        let run = try IndependentLocalVideoAccumulator(source:"synthetic",nominalFPS:60,roi:nil,maximumFrames:3,predict:{ _ in predictions += 1; return [] })
        for i in 0..<3 { try run.append(frame(Int64(i))) }
        XCTAssertThrowsError(try run.append(frame(3)))
        try run.finish()
        XCTAssertEqual(predictions,0); XCTAssertTrue(run.windows.isEmpty)
        XCTAssertTrue(run.frames.allSatisfy { $0.unavailableReason == "insufficient_48_frame_background" && $0.candidate == nil })
        XCTAssertThrowsError(try run.append(frame(4)))
    }
    func testCancellationStopsBeforePredictionAndAfterPredictionWithoutPublishingAWindow() throws {
        let cancellation = IndependentLocalVideoCancellation()
        var predictions = 0
        let run = try IndependentLocalVideoAccumulator(source:"synthetic",nominalFPS:60,roi:nil,maximumFrames:100,predict:{ _ in predictions += 1; cancellation.cancel(); return self.heatmaps() },checkCancellation:cancellation.check)
        for i in 0..<55 { try autoreleasepool { try run.append(frame(Int64(i))) } }
        XCTAssertThrowsError(try run.append(frame(55))) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(predictions,1); XCTAssertTrue(run.windows.isEmpty)
        let before = IndependentLocalVideoCancellation(); before.cancel()
        let stopped = try IndependentLocalVideoAccumulator(source:"synthetic",nominalFPS:60,roi:nil,maximumFrames:100,predict:{ _ in XCTFail("Cancelled run must not predict"); return [] },checkCancellation:before.check)
        XCTAssertThrowsError(try stopped.append(frame(0))) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(stopped.frames.isEmpty)
    }
    @MainActor func testPreCancelledPublicRunDoesNotTouchMissingAssetsOrVideo() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assets = IndependentBallModelAssets(directory:missing,modelURL:missing.appendingPathComponent("TrackNetV3Base.mlpackage"),modelID:"test-only",manifestSHA256:"",packageBytes:0)
        // Inherits MainActor: it cannot run before cancel() while this method is
        // still synchronous. No asset verification, Core ML load or prediction.
        let task = Task { try await IndependentLocalVideoAnalyzer.run(request:.init(videoURL:missing),assets:assets) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled public run must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testInvalidRequestAndPredictorOutputAreErrors() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to:file); defer { try? FileManager.default.removeItem(at:file) }
        XCTAssertNoThrow(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:file)))
        XCTAssertThrowsError(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:URL(string:"https://example.invalid/video.mov")!)))
        XCTAssertThrowsError(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:file,expectedSourceSHA256:"bad")))
        XCTAssertThrowsError(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:file,maximumFrames:7301)))
        XCTAssertThrowsError(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:file,maximumDurationSeconds:121)))
        XCTAssertThrowsError(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:file,expectedNominalFPS:.nan)))
        let run = try IndependentLocalVideoAccumulator(source:"synthetic",nominalFPS:60,roi:nil,maximumFrames:100,predict:{ _ in [] })
        for i in 0..<55 { try autoreleasepool { try run.append(frame(Int64(i))) } }
        XCTAssertThrowsError(try run.append(frame(55)))
        XCTAssertTrue(run.windows.isEmpty)
    }
    func testWholeVideoLimitRequiresExplicitOfflineOptIn() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to:file); defer { try? FileManager.default.removeItem(at:file) }
        XCTAssertThrowsError(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:file,maximumFrames:44848,maximumDurationSeconds:748)))
        XCTAssertNoThrow(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:file,maximumFrames:44848,maximumDurationSeconds:748,limitMode:.offlineFullVideo)))
        XCTAssertThrowsError(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:file,maximumFrames:216001,maximumDurationSeconds:748,limitMode:.offlineFullVideo)))
        XCTAssertThrowsError(try IndependentLocalVideoAnalyzer.validate(.init(videoURL:file,maximumFrames:44848,maximumDurationSeconds:3601,limitMode:.offlineFullVideo)))
    }

}
