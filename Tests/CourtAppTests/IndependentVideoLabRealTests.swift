import XCTest
import AVFoundation
import CryptoKit
@testable import CourtApp
@testable import CourtCore

/// Opt-in, one frozen actual run. The only substitution is the host model bundle:
/// all analysis, identity, exact-frame generation, persistence and scopes stay live.
@MainActor final class IndependentVideoLabRealTests: XCTestCase {
    func testPrivateRealVideoRunsAndPersistsExactFrame() async throws {
        let env = ProcessInfo.processInfo.environment
        let required = ["COURT_LAB_REAL_VIDEO", "COURT_LAB_REAL_BUNDLE", "COURT_LAB_REAL_OUTPUT", "COURT_LAB_REAL_START", "COURT_LAB_REAL_DURATION", "COURT_LAB_REAL_FRAME_INDEX"]
        guard required.allSatisfy({ env[$0].map { !$0.isEmpty } == true }) else {
            throw XCTSkip("Set COURT_LAB_REAL_VIDEO/BUNDLE/OUTPUT/START/DURATION/FRAME_INDEX for one frozen actual App-model run; controlled tests do not replace it.")
        }
        guard let start = Double(env["COURT_LAB_REAL_START"]!), start.isFinite, start >= 0,
              let duration = Double(env["COURT_LAB_REAL_DURATION"]!), duration.isFinite, duration > 0, duration <= 120,
              let frameIndex = Int(env["COURT_LAB_REAL_FRAME_INDEX"]!), frameIndex >= 0 else {
            throw IndependentVideoLabError(message:"Invalid frozen real-run time range/frame index")
        }
        let videoPath = env["COURT_LAB_REAL_VIDEO"]!, bundlePath = env["COURT_LAB_REAL_BUNDLE"]!, outputPath = env["COURT_LAB_REAL_OUTPUT"]!
        guard [videoPath,bundlePath,outputPath].allSatisfy({ $0.hasPrefix("/") }) else {
            throw IndependentVideoLabError(message:"Real-run paths must be explicit absolute local paths")
        }
        let video = URL(fileURLWithPath:videoPath), output = URL(fileURLWithPath:outputPath,isDirectory:true)
        guard !FileManager.default.fileExists(atPath:output.path) else { throw IndependentVideoLabError(message:"Real-run output already exists; choose a new directory") }
        let bundle = try XCTUnwrap(Bundle(url:URL(fileURLWithPath:bundlePath,isDirectory:true)))
        guard bundle.object(forInfoDictionaryKey:"CourtModelSet") as? String == "independent" else {
            throw IndependentVideoLabError(message:"Real run requires an actual independent App resource bundle")
        }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var dependencies = IndependentVideoLabDependencies.live
        dependencies.probe = { try await IndependentVideoLabServices.probe(bundle:bundle) }
        dependencies.run = { request, progress in try await IndependentVideoLabServices.run(request,progress:progress,bundle:bundle) }
        let model = IndependentVideoLabModel(reportsDirectory:output.appendingPathComponent("IndependentRuns",isDirectory:true),dependencies:dependencies)
        defer { model.close() }
        await model.prepare()
        XCTAssertEqual(model.modelAvailability,.available)
        guard model.modelAvailability == .available else { return }
        model.selectVideo(video); model.startSeconds = start; model.durationSeconds = duration
        model.start(); await model.waitUntilIdle()
        let result = try XCTUnwrap(model.result,model.error ?? "Actual analysis did not return a result")
        let saved = try XCTUnwrap(model.savedDirectory,model.saveError ?? "Actual report was not saved")
        XCTAssertEqual(model.phase,.completed); XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.speedText,"—"); XCTAssertNil(result.speedKilometersPerHour)
        XCTAssertFalse(result.physicalAccuracyValidated); XCTAssertFalse(result.human); XCTAssertFalse(result.formal); XCTAssertFalse(result.production)
        XCTAssertEqual(result.modelID,IndependentBallModelAssets.modelIdentifier)
        XCTAssertEqual(result.modelManifestSHA256,IndependentBallModelAssets.reviewedManifestSHA256)
        XCTAssertEqual(result.backendID,IndependentLocalVideoResult.backendIdentifier)
        XCTAssertEqual(result.sourceSHA256.count,64)
        XCTAssertGreaterThan(result.windows.count,0)
        XCTAssertEqual(result.inferredFrames,result.windows.count*8)
        XCTAssertEqual(result.frames.filter { $0.selection != nil }.count,result.inferredFrames)
        XCTAssertTrue(result.frames.prefix(48).allSatisfy { $0.state == .warmup })
        for window in result.windows {
            XCTAssertEqual(window.decodeIndices.count,8); XCTAssertEqual(window.backgroundTimes.count,48); XCTAssertEqual(window.lookaheadFrames,7)
            for index in window.decodeIndices {
                guard result.frames.indices.contains(index) else { XCTFail("Window references a nonexistent actual frame"); continue }
                XCTAssertEqual(result.frames[index].windowIndex,window.windowIndex)
                XCTAssertEqual(result.frames[index].segmentIndex,window.segmentIndex)
                XCTAssertEqual(result.frames[index].availableAt,window.availableAt)
            }
        }
        XCTAssertEqual(result.frames.map(\.decodeIndex),Array(result.frames.indices))
        XCTAssertFalse(result.frames.contains { $0.state == .pendingWindow })
        var previous: CMTime?
        var counts: [String:Int] = [:]
        for frame in result.frames {
            counts[frame.state.rawValue,default:0] += 1
            let pts = try IndependentVideoLabModel.sourceTime(frame)
            if let previous { XCTAssertGreaterThan(CMTimeCompare(pts,previous),0) }; previous = pts
            switch frame.state {
            case .warmup, .incompleteWindow:
                XCTAssertNil(frame.selection); XCTAssertNil(frame.candidate); XCTAssertNotNil(frame.unavailableReason)
            case .missing:
                XCTAssertNotNil(frame.selection); XCTAssertNil(frame.candidate); XCTAssertNotNil(frame.candidateBank); XCTAssertNotNil(frame.unavailableReason)
            case .tracked:
                let point = try XCTUnwrap(frame.candidate?.originalXY)
                XCTAssertEqual(point.count,2)
                if point.count == 2 {
                    XCTAssertTrue((0..<result.metadata.naturalWidth).contains(point[0]))
                    XCTAssertTrue((0..<result.metadata.naturalHeight).contains(point[1]))
                }
                XCTAssertEqual(frame.selection?.time,frame.time)
            case .pendingWindow: XCTFail("Finished result cannot contain pending predictions")
            }
            XCTAssertNil(frame.speedKilometersPerHour); XCTAssertFalse(frame.formal); XCTAssertFalse(frame.physicalAccuracyValidated)
        }
        XCTAssertEqual(counts.values.reduce(0,+),result.frames.count)
        guard result.frames.indices.contains(frameIndex) else { XCTFail("Frozen preview index is outside actual source frames"); return }
        model.selectFrame(index:frameIndex); await model.waitUntilIdle()
        let frame = result.frames[frameIndex], requested = try IndependentVideoLabModel.sourceTime(frame)
        var actual: IndependentVideoLabImage?
        var sourceStable = false
        // An independent read by the SAME live image service exposes its actualTime
        // for the receipt. It adds no model forward and acquires its own scope.
        let accessed = dependencies.startAccess(video)
        do {
            defer { if accessed { dependencies.stopAccess(video) } }
            let before = try await dependencies.identity(video)
            actual = try await dependencies.image(video,requested,result.metadata.trackID)
            sourceStable = try await dependencies.identity(video) == before
        } catch {
            // Persist an explicit failed image-gate receipt before failing below;
            // an edit-list offset or nearest-frame fallback is never substituted.
            actual = nil
        }
        let exactTime = actual.map { $0.actualTime.isNumeric && CMTimeCompare($0.actualTime,requested) == 0 } ?? false
        let exactDimensions = actual.map { $0.image.width == result.metadata.naturalWidth && $0.image.height == result.metadata.naturalHeight } ?? false
        let reportURL = saved.appendingPathComponent("report.json"), metadataURL = saved.appendingPathComponent("run.json")
        let data = try await IndependentVideoLabServices.background { () async throws -> SavedData in
            let report = try Data(contentsOf:reportURL), run = try Data(contentsOf:metadataURL)
            let directoryMode = (try FileManager.default.attributesOfItem(atPath:saved.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let reportMode = (try FileManager.default.attributesOfItem(atPath:reportURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let runMode = (try FileManager.default.attributesOfItem(atPath:metadataURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            return .init(report:report,run:run,reportSHA:Self.sha(report),runSHA:Self.sha(run),directoryMode:directoryMode,reportMode:reportMode,runMode:runMode)
        }
        XCTAssertEqual(data.directoryMode,0o700); XCTAssertEqual(data.reportMode,0o600); XCTAssertEqual(data.runMode,0o600)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:data.report) as? [String:Any])
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with:data.run) as? [String:Any])
        XCTAssertEqual(report["sourceSHA256"] as? String,result.sourceSHA256)
        XCTAssertEqual(report["modelID"] as? String,result.modelID); XCTAssertEqual(report["backendID"] as? String,result.backendID)
        XCTAssertEqual(metadata["filename"] as? String,video.lastPathComponent)
        XCTAssertEqual(metadata["sourceSHA256"] as? String,result.sourceSHA256)
        for key in ["human","formal","production","physicalAccuracyValidated"] { XCTAssertEqual(metadata[key] as? Bool,false) }
        for key in ["acceptedCamera","velocity","speedKilometersPerHour"] { XCTAssertTrue(report[key] is NSNull) }
        for key in ["human","formal","production","cameraQualified","physicalAccuracyValidated","nativeEndToEndSpeedAccepted","twentyPercentAcceptanceEligible"] { XCTAssertEqual(report[key] as? Bool,false) }
        for bytes in [data.report,data.run] {
            let text = try XCTUnwrap(String(data:bytes,encoding:.utf8))
            XCTAssertFalse(text.contains(video.path)); XCTAssertFalse(text.contains("file://"))
        }
        let receipt = Receipt(sourceFilename:video.lastPathComponent,sourceSHA256:result.sourceSHA256,modelID:result.modelID,modelManifestSHA256:result.modelManifestSHA256,backendID:result.backendID,
            requestedStartSeconds:start,requestedDurationSeconds:duration,decodedFrames:result.frames.count,inferredFrames:result.inferredFrames,modelWindows:result.windows.count,frameStates:counts,
            selectedFrameIndex:frameIndex,selectedPTS:frame.presentationTime,observedImageTime:actual.map { .init($0.actualTime) },imageTimeExact:exactTime,imageDimensionsExact:exactDimensions,
            sourceIdentityStable:sourceStable,modelDisplayedImage:model.displayedImage != nil,markerDisplayed:model.overlayPoint != nil,selectedCandidate:frame.candidate?.originalXY,
            reportSHA256:data.reportSHA,runDataSHA256:data.runSHA)
        try await IndependentVideoLabServices.background {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            let file = output.appendingPathComponent("actual-frame-receipt.json")
            try encoder.encode(receipt).write(to:file,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        XCTAssertTrue(sourceStable); XCTAssertTrue(exactTime,"Actual source time must match exactly; no edit-list offset adjustment")
        XCTAssertTrue(exactDimensions); XCTAssertNotNil(model.displayedImage,model.frameError ?? "Exact model preview unavailable")
        if let point = frame.candidate?.originalXY, point.count == 2 {
            XCTAssertEqual(model.overlayPoint,CGPoint(x:CGFloat(point[0]),y:CGFloat(point[1])))
        } else { XCTAssertNil(model.overlayPoint) }
        model.close(); await model.waitUntilIdle()
    }
    private struct SavedData: Sendable {
        let report: Data, run: Data
        let reportSHA: String, runSHA: String
        let directoryMode: Int, reportMode: Int, runMode: Int
    }
    private struct Receipt: Encodable, Sendable {
        let sourceFilename: String, sourceSHA256: String, modelID: String, modelManifestSHA256: String, backendID: String
        let requestedStartSeconds: Double, requestedDurationSeconds: Double
        let decodedFrames: Int, inferredFrames: Int, modelWindows: Int
        let frameStates: [String:Int]
        let selectedFrameIndex: Int
        let selectedPTS: IndependentLocalVideoTime
        let observedImageTime: IndependentLocalVideoTime?
        let imageTimeExact: Bool, imageDimensionsExact: Bool, sourceIdentityStable: Bool, modelDisplayedImage: Bool, markerDisplayed: Bool
        let selectedCandidate: [Int]?
        let reportSHA256: String, runDataSHA256: String
        let human = false, formal = false, production = false, physicalAccuracyValidated = false
        let speedOutputs = 0, newTrainingSteps = 0
    }
    nonisolated private static func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}
