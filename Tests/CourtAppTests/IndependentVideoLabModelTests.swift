import XCTest
import AVFoundation
@testable import CourtApp
@testable import CourtCore

@MainActor final class IndependentVideoLabModelTests: XCTestCase {
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String:Int] = [:]
        private var callbacks: [@Sendable (IndependentLocalVideoProgress) -> Void] = []
        func add(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; values[key,default:0] += 1; return values[key]! }
        func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key,default:0] }
        func remember(_ callback: @escaping @Sendable (IndependentLocalVideoProgress) -> Void) { lock.lock(); callbacks.append(callback); lock.unlock() }
        func emitFirst() {
            lock.lock(); let callback = callbacks.first; lock.unlock()
            callback?(.init(phase:"decoding",decodedFrames:999,inferredFrames:999,fraction:0.9))
        }
    }
    private actor Gate<T: Sendable> {
        var continuation: CheckedContinuation<T, Error>?
        var started = false
        func wait() async throws -> T { started = true; return try await withCheckedThrowingContinuation { continuation = $0 } }
        func finish(_ value: T) { continuation?.resume(returning:value); continuation = nil }
    }
    private actor ImageGate {
        var pending: [Int64: CheckedContinuation<IndependentVideoLabImage, Error>] = [:]
        func wait(_ time: CMTime) async throws -> IndependentVideoLabImage {
            try await withCheckedThrowingContinuation { pending[time.value] = $0 }
        }
        func has(_ value: Int64) -> Bool { pending[value] != nil }
        func finish(_ value: Int64, _ image: IndependentVideoLabImage) { pending.removeValue(forKey:value)?.resume(returning:image) }
    }
    private struct Fixture: Sendable {
        let root: URL, video: URL
        let result: IndependentLocalVideoResult
        let image: IndependentVideoLabImage
    }
    private func fixture(trackCount: Int = 1, missingSecond: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-lab-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let video = root.appendingPathComponent("controlled.mov")
        let writer = try AVAssetWriter(outputURL:video,fileType:.mov)
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,18,12,kCVPixelFormatType_32BGRA,nil,&optional),kCVReturnSuccess)
        let pixels = try XCTUnwrap(optional)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixels,formatDescriptionOut:&format),noErr)
        let inputs = (0..<trackCount).map { _ -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType:.video,outputSettings:nil,sourceFormatHint:format)
            input.mediaTimeScale = 60; writer.add(input); return input
        }
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime:.zero)
        for i in 0..<2 {
            var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:60),presentationTimeStamp:CMTime(value:Int64(i),timescale:60),decodeTimeStamp:.invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixels,formatDescription:try XCTUnwrap(format),sampleTiming:&timing,sampleBufferOut:&sample),noErr)
            for input in inputs {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(1)) }
                XCTAssertTrue(input.append(try XCTUnwrap(sample)))
            }
        }
        for input in inputs { input.markAsFinished() }; writer.endSession(atSourceTime:CMTime(value:2,timescale:60)); await writer.finishWriting()
        XCTAssertEqual(writer.status,.completed)
        let reader = try await IndependentVideoReader.open(video:video)
        let metadata = reader.metadata; reader.cancel()
        let transform = try IndependentBallImageTransform(originalWidth:18,originalHeight:12)
        let frames = try (0..<2).map { i -> IndependentLocalVideoFrameResult in
            let time = try IndependentBallFrameTime(sourcePTS:Int64(i),timeBaseNumerator:2,timeBaseDenominator:120)
            let x = i == 0 ? 4 : 8
            let candidate = IndependentBallGridCandidate(identifier:i+1,box:[114,120,1,1],originalXY:[x,5],equivalentXY:[Double(x)*1280/18,300],peak:0.9,mean:0.9,pixelArea:1)
            let choice = IndependentBallTrackSelection(time:time,candidate:candidate,linkedToPast:i>0,resetReason:nil,missingReason:nil,incrementalCost:0.1)
            var row = IndependentLocalVideoFrameResult(decodeIndex:i,time:time,presentationTime:.init(CMTime(value:Int64(i),timescale:60)),duration:.init(CMTime(value:1,timescale:60)),decodeTime:.init(.invalid),transform:transform,segmentIndex:0,windowIndex:0,state:.tracked,unavailableReason:nil,availableAt:.init(CMTime(value:1,timescale:60)),sourceLookaheadSeconds:Double(1-i)/60,selection:choice,candidateBank:.init(candidates:[candidate],totalComponents:1,truncatedComponents:0))
            if missingSecond && i == 1 {
                row.state = .missing; row.unavailableReason = "no_candidate"
                row.selection = .init(time:time,candidate:nil,linkedToPast:false,resetReason:nil,missingReason:"no_candidate",incrementalCost:2.5)
                row.candidateBank = .init(candidates:[],totalComponents:0,truncatedComponents:0)
            }
            return row
        }
        let result = IndependentLocalVideoResult(sourceSHA256:String(repeating:"a",count:64),modelID:"controlled-ui-fixture",modelManifestSHA256:String(repeating:"b",count:64),metadata:metadata,frames:frames,windows:[],decodedSampleCount:2,discardedPrerollSampleCount:0,assemblerPeakRetainedRGBBytes:0,unflushedTailFrames:0,inferenceSeconds:0,wallSecondsExcludingSourceHashAndModelLoad:0)
        return .init(root:root,video:video,result:result,image:.init(image:try image(width:18,height:12),actualTime:.zero))
    }
    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    private func dependencies(_ fixture: Fixture, counters: Counters) -> IndependentVideoLabDependencies {
        .init(run:{ _, callback in counters.remember(callback); _ = counters.add("runs"); return fixture.result },
              inspect:{ try await IndependentVideoLabServices.inspect($0) },identity:{ try await IndependentVideoLabServices.identity($0) },
              image:{ _, time, _ in _ = counters.add("images"); return .init(image:fixture.image.image,actualTime:time) },
              persist:{ _, metadata, root in _ = counters.add("saves"); return root.appendingPathComponent(metadata.runID.uuidString) },
              startAccess:{ _ in _ = counters.add("starts"); return true }, stopAccess:{ _ in _ = counters.add("stops") })
    }
    private func model(_ fixture: Fixture, dependencies: IndependentVideoLabDependencies) async -> IndependentVideoLabModel {
        let model = IndependentVideoLabModel(reportsDirectory:fixture.root.appendingPathComponent("reports"),dependencies:dependencies)
        await model.prepare(); model.selectVideo(fixture.video); return model
    }
    private func eventually(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Controlled operation did not reach expected state")
    }
    func testModelProbeFailureDisablesStartBeforeVideoSelection() async throws {
        let f = try await fixture(), counts = Counters()
        var d = dependencies(f,counters:counts)
        d.probe = { throw IndependentVideoLabError(message:"当前安装包未包含可用的独立模型。") }
        let m = await model(f,dependencies:d)
        if case .unavailable(let message) = m.modelAvailability { XCTAssertTrue(message.contains("独立模型")) } else { XCTFail("Must show unavailable") }
        XCTAssertFalse(m.canStart); m.start(); XCTAssertFalse(m.isBusy)
        XCTAssertEqual(counts.count("runs"),0); XCTAssertEqual(counts.count("starts"),0)
        m.close()
    }
    func testCancellationWaitsForRunnerBeforeReleasingScopeOrAllowingRestart() async throws {
        let f = try await fixture(), counts = Counters(), gate = Gate<IndependentLocalVideoResult>()
        var d = dependencies(f,counters:counts); d.run = { _, _ in try await gate.wait() }
        let m = await model(f,dependencies:d); m.start()
        try await eventually { await gate.started }
        m.cancel(); m.start()
        XCTAssertEqual(m.phase,.cancelling); XCTAssertTrue(m.isBusy)
        XCTAssertEqual(counts.count("starts"),1); XCTAssertEqual(counts.count("stops"),0)
        await gate.finish(f.result); await m.waitUntilIdle()
        XCTAssertFalse(m.isBusy); XCTAssertEqual(m.phase,.cancelled); XCTAssertNil(m.result)
        XCTAssertEqual(counts.count("stops"),1); XCTAssertEqual(counts.count("saves"),0)
        m.close()
    }
    func testErrorsAndInvalidRangeNeverProduceSpeedOrResult() async throws {
        let f = try await fixture(), counts = Counters()
        var d = dependencies(f,counters:counts); d.run = { _, _ in throw IndependentVideoLabError(message:"受控读取失败") }
        let m = await model(f,dependencies:d)
        m.durationSeconds = 121; m.start(); XCTAssertFalse(m.isBusy); XCTAssertNotNil(m.error)
        m.durationSeconds = 10; m.start(); await m.waitUntilIdle()
        XCTAssertEqual(m.phase,.failed); XCTAssertNil(m.result); XCTAssertTrue(m.error?.contains("受控") == true)
        XCTAssertEqual(m.speedText,"—"); XCTAssertTrue(m.speedReason.contains("可信相机"))
        XCTAssertEqual(counts.count("starts"),counts.count("stops")); m.close()
    }
    func testExactPreviewPreservesNonunitTimeNumeratorAndOriginalCoordinates() async throws {
        let f = try await fixture(), counts = Counters()
        let m = await model(f,dependencies:dependencies(f,counters:counts)); m.start(); await m.waitUntilIdle()
        m.selectFrame(index:1); await m.waitUntilIdle()
        XCTAssertEqual(CMTimeCompare(try IndependentVideoLabModel.sourceTime(f.result.frames[1]),CMTime(value:1,timescale:60)),0)
        XCTAssertEqual(m.selectedFrame?.time.timeBaseNumerator,2)
        XCTAssertNotNil(m.displayedImage); XCTAssertEqual(m.overlayPoint,CGPoint(x:8,y:5))
        XCTAssertEqual(m.speedText,"—"); XCTAssertNil(m.result?.speedKilometersPerHour)
        XCTAssertEqual(counts.count("starts"),counts.count("stops")); m.close()
    }
    func testSaveFailureKeepsMemoryResultAndRetryUsesNoVideoScope() async throws {
        let f = try await fixture(), counts = Counters()
        var d = dependencies(f,counters:counts)
        d.persist = { _, metadata, root in
            if counts.add("saves") == 1 { throw IndependentVideoLabError(message:"Controlled disk failure") }
            return root.appendingPathComponent(metadata.runID.uuidString)
        }
        let m = await model(f,dependencies:d); m.start(); await m.waitUntilIdle()
        XCTAssertNotNil(m.result); XCTAssertNil(m.savedDirectory); XCTAssertNotNil(m.saveError)
        let accesses = counts.count("starts")
        m.retrySave(); await m.waitUntilIdle()
        XCTAssertNotNil(m.savedDirectory); XCTAssertNil(m.saveError); XCTAssertNotNil(m.result)
        XCTAssertEqual(counts.count("starts"),accesses); m.close()
    }
    func testSourceChangeDuringRunRejectsResultBeforeSaving() async throws {
        let f = try await fixture(), counts = Counters()
        var d = dependencies(f,counters:counts)
        d.run = { request, _ in
            let handle = try FileHandle(forWritingTo:request.videoURL); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf:Data([1])); return f.result
        }
        let m = await model(f,dependencies:d); m.start(); await m.waitUntilIdle()
        XCTAssertNil(m.result); XCTAssertTrue(m.error?.contains("变化") == true); XCTAssertEqual(counts.count("saves"),0)
        XCTAssertEqual(counts.count("starts"),counts.count("stops")); m.close()
    }
    func testSourceChangeBeforePreviewClearsImageAndDoesNotCallImageProvider() async throws {
        let f = try await fixture(), counts = Counters()
        let m = await model(f,dependencies:dependencies(f,counters:counts)); m.start(); await m.waitUntilIdle()
        let images = counts.count("images")
        let handle = try FileHandle(forWritingTo:f.video); try handle.seekToEnd(); try handle.write(contentsOf:Data([1])); try handle.close()
        m.selectFrame(index:1); await m.waitUntilIdle()
        XCTAssertNil(m.displayedImage); XCTAssertNil(m.overlayPoint); XCTAssertTrue(m.frameError?.contains("变化") == true)
        XCTAssertEqual(counts.count("images"),images); m.close()
    }
    func testInexactTimeOrWrongDimensionsNeverDrawOverlay() async throws {
        let f = try await fixture()
        let wrong = IndependentVideoLabImage(image:try image(width:19,height:12),actualTime:.zero)
        for wrongTime in [true,false] {
            let counts = Counters(); var d = dependencies(f,counters:counts)
            d.image = { _, time, _ in .init(image:wrongTime ? f.image.image : wrong.image,actualTime:wrongTime ? CMTimeAdd(time,CMTime(value:1,timescale:600)) : time) }
            let m = await model(f,dependencies:d); m.start(); await m.waitUntilIdle()
            XCTAssertNil(m.displayedImage); XCTAssertNil(m.overlayPoint); XCTAssertTrue(m.frameError?.contains("精确") == true)
            m.close()
        }
    }
    func testLatePreviewCannotOverwriteNewFrameAndEachLeaseWaitsForItsWorker() async throws {
        let f = try await fixture(), counts = Counters(), gate = ImageGate()
        var d = dependencies(f,counters:counts); d.image = { _, time, _ in try await gate.wait(time) }
        let m = await model(f,dependencies:d); m.start()
        try await eventually { await gate.has(0) }
        m.selectFrame(index:1)
        try await eventually { await gate.has(1) }
        XCTAssertEqual(counts.count("starts"),3); XCTAssertEqual(counts.count("stops"),1)
        await gate.finish(1,.init(image:f.image.image,actualTime:CMTime(value:1,timescale:60)))
        try await eventually { m.overlayPoint == CGPoint(x:8,y:5) }
        await gate.finish(0,f.image); await m.waitUntilIdle()
        XCTAssertEqual(m.selectedFrameIndex,1); XCTAssertEqual(m.overlayPoint,CGPoint(x:8,y:5))
        XCTAssertEqual(counts.count("starts"),counts.count("stops")); m.close()
    }
    func testCloseWaitsForImageWorkerBeforeStoppingItsScope() async throws {
        let f = try await fixture(), counts = Counters(), gate = ImageGate()
        var d = dependencies(f,counters:counts); d.image = { _, time, _ in try await gate.wait(time) }
        let m = await model(f,dependencies:d); m.start()
        try await eventually { await gate.has(0) }
        m.close()
        XCTAssertEqual(counts.count("starts"),2); XCTAssertEqual(counts.count("stops"),1)
        await gate.finish(0,f.image); await m.waitUntilIdle()
        XCTAssertEqual(counts.count("stops"),2); XCTAssertNil(m.displayedImage)
    }
    func testLateProgressFromPreviousRunCannotAffectNewRun() async throws {
        let f = try await fixture(), counts = Counters(), gate = Gate<IndependentLocalVideoResult>()
        var d = dependencies(f,counters:counts)
        d.run = { _, callback in
            counts.remember(callback)
            if counts.add("runs") == 1 { return f.result }
            return try await gate.wait()
        }
        let m = await model(f,dependencies:d); m.start(); await m.waitUntilIdle()
        m.selectVideo(f.video); m.start(); try await eventually { await gate.started }
        counts.emitFirst(); try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(m.progressFraction,0); XCTAssertFalse(m.progressText.contains("999"))
        await gate.finish(f.result); await m.waitUntilIdle(); m.close()
    }
    func testCloseCancelsProbeWithoutTouchingVideo() async throws {
        let f = try await fixture(), counts = Counters(), gate = Gate<Bool>()
        var d = dependencies(f,counters:counts); d.probe = { _ = try await gate.wait() }
        let m = IndependentVideoLabModel(reportsDirectory:f.root.appendingPathComponent("reports"),dependencies:d)
        let preparation = Task { await m.prepare() }
        try await eventually { await gate.started }
        m.close(); await gate.finish(true); await preparation.value; await m.waitUntilIdle()
        XCTAssertFalse(m.canStart); XCTAssertEqual(counts.count("starts"),0); XCTAssertEqual(counts.count("runs"),0)
    }
    func testUnscopedLocalFileDoesNotCallStopAccess() async throws {
        let f = try await fixture(), counts = Counters()
        var d = dependencies(f,counters:counts); d.startAccess = { _ in _ = counts.add("starts"); return false }
        let m = await model(f,dependencies:d); m.start(); await m.waitUntilIdle()
        XCTAssertNotNil(m.result); XCTAssertGreaterThanOrEqual(counts.count("starts"),2); XCTAssertEqual(counts.count("stops"),0); m.close()
    }
    func testSourceChangeDuringImageGenerationRejectsPreview() async throws {
        let f = try await fixture(), counts = Counters()
        var d = dependencies(f,counters:counts)
        d.image = { url, time, _ in
            let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf:Data([1]))
            return .init(image:f.image.image,actualTime:time)
        }
        let m = await model(f,dependencies:d); m.start(); await m.waitUntilIdle()
        XCTAssertNotNil(m.result); XCTAssertNil(m.displayedImage); XCTAssertNil(m.overlayPoint)
        XCTAssertTrue(m.frameError?.contains("变化") == true); m.close()
    }
    func testMultipleVideoTracksAreRejectedBeforeModelRunner() async throws {
        let f = try await fixture(trackCount:2), counts = Counters()
        let m = await model(f,dependencies:dependencies(f,counters:counts)); m.start(); await m.waitUntilIdle()
        XCTAssertNil(m.result); XCTAssertTrue(m.error?.contains("一路") == true); XCTAssertEqual(counts.count("runs"),0)
        XCTAssertEqual(counts.count("starts"),counts.count("stops")); m.close()
    }
    func testMissingCandidateRetainsUnknownSpeedAndNoOverlay() async throws {
        let f = try await fixture(missingSecond:true), counts = Counters()
        let m = await model(f,dependencies:dependencies(f,counters:counts)); m.start(); await m.waitUntilIdle()
        m.selectFrame(index:1); await m.waitUntilIdle()
        XCTAssertNotNil(m.displayedImage); XCTAssertNil(m.overlayPoint); XCTAssertEqual(m.selectedFrame?.state,.missing)
        XCTAssertNil(m.selectedFrame?.candidate); XCTAssertEqual(m.speedText,"—"); XCTAssertNil(m.result?.speedKilometersPerHour); m.close()
    }
    func testCancelledPrepareWaiterDoesNotCancelModelOwnedProbe() async throws {
        let f = try await fixture(), counts = Counters(), gate = Gate<Bool>()
        var d = dependencies(f,counters:counts)
        d.probe = { _ = try await gate.wait(); try Task.checkCancellation() }
        let m = IndependentVideoLabModel(reportsDirectory:f.root.appendingPathComponent("reports"),dependencies:d)
        let first = Task { await m.prepare() }
        try await eventually { await gate.started }
        let returningWaiter = Task { _ = counts.add("returningWaiter"); await m.prepare() }
        try await eventually { counts.count("returningWaiter") == 1 }
        first.cancel(); await gate.finish(true)
        await first.value; await returningWaiter.value; await m.waitUntilIdle()
        m.selectVideo(f.video)
        XCTAssertEqual(m.modelAvailability,.available); XCTAssertTrue(m.canStart); m.close()
    }
    func testCancelAfterInitialReportCommitKeepsSavedState() async throws {
        let f = try await fixture(), counts = Counters(), gate = Gate<Bool>()
        var d = dependencies(f,counters:counts)
        d.persist = { result, metadata, root in
            _ = counts.add("saves")
            let committed = try await IndependentVideoLabServices.persist(result,metadata:metadata,directory:root)
            _ = try await gate.wait(); return committed
        }
        let m = await model(f,dependencies:d); m.start()
        try await eventually { await gate.started }
        let root = f.root.appendingPathComponent("reports")
        let saved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first)
        m.cancel(); XCTAssertEqual(m.phase,.cancelling)
        await gate.finish(true); await m.waitUntilIdle()
        XCTAssertEqual(m.savedDirectory?.lastPathComponent,saved.lastPathComponent); XCTAssertTrue(FileManager.default.fileExists(atPath:saved.path)); XCTAssertNil(m.saveError); XCTAssertEqual(m.phase,.completed)
        XCTAssertTrue(m.progressText.contains("已保存")); XCTAssertEqual(counts.count("starts"),counts.count("stops"))
        m.retrySave(); await m.waitUntilIdle(); XCTAssertEqual(counts.count("saves"),1); m.close()
    }
    func testCancelAfterRetryReportCommitKeepsSavedState() async throws {
        let f = try await fixture(), counts = Counters(), gate = Gate<Bool>()
        var d = dependencies(f,counters:counts)
        d.persist = { result, metadata, root in
            if counts.add("saves") == 1 { throw IndependentVideoLabError(message:"Controlled first failure") }
            let committed = try await IndependentVideoLabServices.persist(result,metadata:metadata,directory:root)
            _ = try await gate.wait(); return committed
        }
        let m = await model(f,dependencies:d); m.start(); await m.waitUntilIdle()
        XCTAssertNotNil(m.saveError); m.retrySave()
        try await eventually { await gate.started }; m.cancel()
        await gate.finish(true); await m.waitUntilIdle()
        XCTAssertNotNil(m.savedDirectory); XCTAssertNil(m.saveError); XCTAssertEqual(m.phase,.completed)
        m.retrySave(); await m.waitUntilIdle(); XCTAssertEqual(counts.count("saves"),2); m.close()
    }
    func testSingleFrameExplicitReloadAfterSavingCancellationAndTransientImageFailure() async throws {
        let f = try await fixture(), counts = Counters(), gate = Gate<Bool>()
        let original = f.result
        let single = IndependentLocalVideoResult(sourceSHA256:original.sourceSHA256,modelID:original.modelID,modelManifestSHA256:original.modelManifestSHA256,metadata:original.metadata,frames:[original.frames[0]],windows:[],decodedSampleCount:1,discardedPrerollSampleCount:0,assemblerPeakRetainedRGBBytes:0,unflushedTailFrames:0,inferenceSeconds:0,wallSecondsExcludingSourceHashAndModelLoad:0)
        var d = dependencies(f,counters:counts)
        d.run = { _, _ in single }
        d.persist = { _, _, _ in _ = try await gate.wait(); try Task.checkCancellation(); throw CancellationError() }
        d.image = { _, time, _ in
            if counts.add("images") == 1 { throw IndependentVideoLabError(message:"Temporary image failure") }
            return .init(image:f.image.image,actualTime:time)
        }
        let m = await model(f,dependencies:d); m.start()
        try await eventually { await gate.started }
        m.cancel(); await gate.finish(true); await m.waitUntilIdle()
        XCTAssertEqual(m.result?.frames.count,1); XCTAssertEqual(m.selectedFrameIndex,0)
        XCTAssertFalse(m.isBusy); XCTAssertEqual(counts.count("images"),0); XCTAssertNil(m.displayedImage)
        // This is the explicit reloadFrame action; cancellation itself starts no preview.
        m.selectFrame(index:m.selectedFrameIndex); await m.waitUntilIdle()
        XCTAssertNotNil(m.frameError); XCTAssertNil(m.displayedImage); XCTAssertEqual(m.selectedFrameIndex,0)
        m.selectFrame(index:m.selectedFrameIndex); await m.waitUntilIdle()
        XCTAssertNotNil(m.displayedImage); XCTAssertNil(m.frameError); XCTAssertEqual(m.overlayPoint,CGPoint(x:4,y:5))
        XCTAssertEqual(m.selectedFrameIndex,0); XCTAssertEqual(counts.count("images"),2)
        XCTAssertEqual(counts.count("starts"),counts.count("stops")); m.close()
    }
    func testNonSixtyFPSAndOtherCoreFailuresGiveChineseNextSteps() async throws {
        let f = try await fixture()
        for (reason, message) in [
            ("Independent experimental mode requires nominal 60 fps track metadata", "当前实验需要60fps视频，请重新选择。"),
            ("Requested source interval exceeds experimental duration limit", "视频未能完成独立分析，请检查格式和所选时间段后重试。")
        ] {
            let counts = Counters(); var d = dependencies(f,counters:counts)
            d.run = { _, _ in throw IndependentLocalVideoError.invalid(reason) }
            let m = await model(f,dependencies:d); m.start(); await m.waitUntilIdle()
            XCTAssertEqual(m.error,message); XCTAssertEqual(m.phase,.failed)
            XCTAssertNil(m.result); XCTAssertEqual(m.speedText,"—"); XCTAssertEqual(counts.count("saves"),0)
            XCTAssertEqual(counts.count("starts"),counts.count("stops")); m.close()
        }
    }
    func testAtomicReportPermissionsNoSourcePathNoOverwriteAndCancellation() async throws {
        let f = try await fixture(), root = f.root.appendingPathComponent("real-reports")
        let metadata = IndependentVideoLabRunMetadata(runID:UUID(),filename:f.video.lastPathComponent,startedAt:Date(),completedAt:Date(),requestedStartSeconds:0,requestedDurationSeconds:10,sourceSHA256:f.result.sourceSHA256,modelID:f.result.modelID,modelManifestSHA256:f.result.modelManifestSHA256,backendID:f.result.backendID)
        let saved = try await IndependentVideoLabServices.persist(f.result,metadata:metadata,directory:root)
        let report = saved.appendingPathComponent("report.json"), run = saved.appendingPathComponent("run.json")
        let original = try Data(contentsOf:report)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:saved.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        for file in [report,run] { XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600) }
        let text = try String(contentsOf:run,encoding:.utf8)
        XCTAssertFalse(text.contains(f.video.path)); XCTAssertFalse(text.contains("file://"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:original) as? [String:Any])
        XCTAssertTrue(json["speedKilometersPerHour"] is NSNull); XCTAssertEqual(json["formal"] as? Bool,false)
        do { _ = try await IndependentVideoLabServices.persist(f.result,metadata:metadata,directory:root); XCTFail("Must not overwrite") } catch { }
        XCTAssertEqual(try Data(contentsOf:report),original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),[metadata.runID.uuidString])
        let cancelledRoot = f.root.appendingPathComponent("cancelled-reports")
        let task = Task { try await IndependentVideoLabServices.persist(f.result,metadata:metadata,directory:cancelledRoot) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled save must not publish") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:cancelledRoot.path))
    }
}
