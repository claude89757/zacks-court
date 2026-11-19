import XCTest
import CoreVideo
import simd
@testable import CourtCore

/// The in-house live lane's building blocks. Synthetic inputs only: these prove conversion, layout and
/// plumbing, not tennis accuracy.
final class IndependentLiveEngineTests: XCTestCase {
    private func nv12(width: Int = 1920, height: Int = 1080, y: UInt8, cb: UInt8, cr: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let b = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(b, []); defer { CVPixelBufferUnlockBaseAddress(b, []) }
        memset(CVPixelBufferGetBaseAddressOfPlane(b, 0), Int32(y), CVPixelBufferGetBytesPerRowOfPlane(b, 0) * height)
        let c = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(CVPixelBufferGetBytesPerRowOfPlane(b, 1) * height / 2) { c[i] = i % 2 == 0 ? cb : cr }
        return b
    }

    func testWallGapNeedsMovingModelSeedsAndFreshColouredPixels() throws {
        let w = IndependentLiveFrameScaler.width, h = IndependentLiveFrameScaler.height
        var background = [UInt8](repeating: 150, count: 3 * w * h)
        XCTAssertNil(IndependentBallGapRecovery(background: background))
        for i in (w * h / 2)..<(w * h) { background[3 * i] = 50 }
        var recovery = try XCTUnwrap(IndependentBallGapRecovery(background: background))
        func observe(_ t: Int, x: Int?, model: Bool = false) -> [SIMD2<Double>] {
            var frame = background
            if let x { frame[3 * (64 * w + x) + 2] = 115 }
            let points = model ? [SIMD2(Double(x!), 64)] : []
            return recovery.update(model: points, frame: frame, time: Double(t))
        }
        XCTAssertTrue(observe(0, x: 70).isEmpty)
        for i in 1...3 { XCTAssertTrue(observe(i, x: 70 + 3 * i, model: true).isEmpty) }
        XCTAssertEqual(observe(4, x: 82), [SIMD2(82, 64)])
        XCTAssertTrue(observe(5, x: 82).isEmpty, "a stationary yellow feature has no new motion")
        XCTAssertTrue(observe(6, x: nil).isEmpty, "prediction alone supplies no ball point")
        XCTAssertTrue(observe(10, x: 100).isEmpty, "a break requires fresh model observations")
    }

    func testReceiverCropReadsTheRequestedNV12PixelsAndAgreesWithSourceCoordinates() throws {
        let camera = IndependentPinholeCamera.lookingAt(SIMD3(0, 16, 1.4), from: SIMD3(0, -6, 1.4), f: 1010)
        let crop = try XCTUnwrap(IndependentLiveEngine.receiverCrop(camera, width: 1920, height: 1080))
        let projected = IndependentProjector(camera).project(SIMD3(0, 18.3, 0))
        XCTAssertTrue((crop.cropX..<crop.cropX + crop.cropWidth).contains(Int(projected.u)))
        XCTAssertTrue((crop.cropY..<crop.cropY + crop.cropHeight).contains(Int(projected.v)))
        XCTAssertEqual(crop.cropWidth * 9, crop.cropHeight * 16)
        let pixels = try nv12(y: 16, cb: 128, cr: 128)
        CVPixelBufferLockBaseAddress(pixels, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!, stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        for y in crop.cropY..<(crop.cropY + crop.cropHeight) { memset(luma + y * stride + crop.cropX, 235, crop.cropWidth) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let scaler = IndependentLiveFrameScaler()
        XCTAssertLessThan(try XCTUnwrap(scaler.scale(pixels)).first!, 5)
        let zoom = try XCTUnwrap(scaler.scale(pixels, crop: crop))
        XCTAssertGreaterThan(zoom.min()!, 248)
    }

    /// BT.709 video range: Y 16-235, Cb/Cr 16-240 around 128.
    func testNV12ScalesToBT709RGB() throws {
        let scaler = IndependentLiveFrameScaler()
        let grey = try XCTUnwrap(scaler.scale(try nv12(y: 126, cb: 128, cr: 128)))
        XCTAssertEqual(grey.count, 512 * 288 * 3)
        for v in [grey[0], grey[1], grey[2], grey[grey.count - 1]] { XCTAssertEqual(Double(v), (126 - 16) * 255 / 219, accuracy: 2) }
        let (y, cb, cr) = (100.0, 150.0, 90.0)
        let rgb = try XCTUnwrap(scaler.scale(try nv12(y: UInt8(y), cb: UInt8(cb), cr: UInt8(cr))))
        let yy = (y - 16) * 255 / 219, pb = (cb - 128) * 255 / 224, pr = (cr - 128) * 255 / 224
        let expected = [yy + 1.5748 * pr, yy - 0.1873 * pb - 0.4681 * pr, yy + 1.8556 * pb].map { min(255, max(0, $0)) }
        let centre = (144 * 512 + 256) * 3
        for c in 0..<3 { XCTAssertEqual(Double(rgb[centre + c]), expected[c], accuracy: 3, "channel \(c)") }
    }

    func testBGRAScalesToRGB() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let b = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(b, [])
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(CVPixelBufferGetBytesPerRow(b) * 720 / 4) { p[i * 4] = 10; p[i * 4 + 1] = 20; p[i * 4 + 2] = 30; p[i * 4 + 3] = 255 }
        CVPixelBufferUnlockBaseAddress(b, [])
        let rgb = try XCTUnwrap(IndependentLiveFrameScaler().scale(b))
        XCTAssertEqual(Array(rgb[0..<3]), [30, 20, 10])
        var other: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32ARGB, nil, &other)
        XCTAssertNil(IndependentLiveFrameScaler().scale(try XCTUnwrap(other)), "unsupported formats are refused, not guessed")
    }

    func testMedianAndTensorLayout() throws {
        let frames = [[UInt8]](repeating: [], count: 4).enumerated().map { k, _ in [UInt8](repeating: UInt8(10 * (k + 1)), count: 6) }
        XCTAssertEqual(IndependentLiveBallStage.median(frames), [UInt8](repeating: 25, count: 6), "even count: mean of the middle two")
        XCTAssertEqual(IndependentLiveBallStage.median(Array(frames.prefix(3)))[0], 20)
        let plane = 512 * 288
        var background = [UInt8](repeating: 0, count: plane * 3)
        background[0] = 255; background[1] = 51; background[2] = 102          // pixel 0: R, G, B
        let image = [UInt8](repeating: 255, count: plane * 3)
        let tensor = try IndependentLiveBallStage.tensor(background: background, frames: Array(repeating: image, count: 8))
        let p = tensor.dataPointer.assumingMemoryBound(to: Float.self)
        XCTAssertEqual(p[0], 1, accuracy: 1e-6); XCTAssertEqual(p[plane], 0.2, accuracy: 1e-6); XCTAssertEqual(p[2 * plane], 0.4, accuracy: 1e-6)
        XCTAssertEqual(p[3 * plane + 7], 1, accuracy: 1e-6)
        XCTAssertEqual(tensor.count, 27 * plane)
    }

    func testFarCropsCoverTheFarHalfInsideTheImage() {
        let camera = IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0), from: SIMD3(0.3, -6.4, 3.1), f: 1300)
        let crops = IndependentLivePeople.farCrops(camera, width: 1920, height: 1080)
        XCTAssertEqual(crops.count, 4)
        let far = IndependentProjector(camera).project(SIMD3(0, 23.77, 1.0))
        let wide = crops[0]
        XCTAssertTrue(wide.x <= far.u && far.u <= wide.x + wide.w && wide.y <= far.v && far.v <= wide.y + wide.h)
        for c in crops { XCTAssertTrue(c.x >= 0 && c.y >= 0 && c.x + c.w <= 1920.5 && c.y + c.h <= 1080.5) }
    }

    /// Runs the staged FP16 model over synthetic frames: warm-up, one batch, a rule update and finish.
    func testEngineRunsOnTheStagedFP16Model() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let staged = repository.appendingPathComponent(".local/IndependentModels/tracknetv3-base-fp16-v1")
        guard FileManager.default.fileExists(atPath: staged.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Run scripts/prepare-independent-app-models.sh to stage the FP16 package")
        }
        let camera = IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0), from: SIMD3(0.3, -6.4, 3.1), f: 1300)
        let engine = try IndependentLiveEngine(configuration: .init(assets: try IndependentBallModelAssets.load(directory: staged, variant: .fp16), camera: camera))
        let stream = UUID(), frame = [UInt8](repeating: 90, count: 512 * 288 * 3)
        var snapshots = 0
        for k in 0..<64 {
            if try engine.process(small: frame, full: nil, pts: 10 + Double(k) / 60, streamID: stream, sourceWidth: 1920, sourceHeight: 1080) != nil { snapshots += 1 }
        }
        XCTAssertEqual(engine.stats.batches, 2, "48 warm-up frames, then two 8-frame batches")
        XCTAssertGreaterThan(snapshots, 0)
        let final = try XCTUnwrap(engine.finish())
        XCTAssertEqual(final.modelVersion, engine.configuration.modelVersion)
        XCTAssertTrue(final.modelVersion.hasSuffix("+posefill"))
        XCTAssertTrue(final.calibration.isAvailable)
        // A gap of more than 1.5 frame periods starts a new warm-up.
        _ = try engine.process(small: frame, full: nil, pts: 20, streamID: stream, sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertGreaterThanOrEqual(engine.stats.ballResets, 1)
    }

    /// The ball model compares frames with a median background. Once the picture has moved away from
    /// the view that background was taken from (a hand-held phone), the background is built again
    /// instead of every lamp and line counting as different; a still picture keeps it.
    func testBackgroundIsRebuiltWhenThePictureMovesAwayFromIt() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let staged = repository.appendingPathComponent(".local/IndependentModels/tracknetv3-base-fp16-v1")
        guard FileManager.default.fileExists(atPath: staged.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Run scripts/prepare-independent-app-models.sh to stage the FP16 package")
        }
        func textured(shift: Int) throws -> CVPixelBuffer {
            let b = try nv12(y: 0, cb: 128, cr: 128)
            CVPixelBufferLockBaseAddress(b, []); defer { CVPixelBufferUnlockBaseAddress(b, []) }
            let row = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
            let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
            for r in 0..<1080 { for c in 0..<1920 {        // edges in both directions, moved diagonally
                y[r * row + c] = UInt8(126 + 50 * sin(Double(c + shift) / 37) + 50 * sin(Double(r + shift) / 37))
            } }
            return b
        }
        let engine = try IndependentLiveEngine(configuration: .init(assets: try IndependentBallModelAssets.load(directory: staged, variant: .fp16), automaticCourt: true))
        let still = try textured(shift: 0), moved = try textured(shift: 32)
        let measured = IndependentLiveCourt.motion(try XCTUnwrap(IndependentLiveCourt.thumbnail(still)), try XCTUnwrap(IndependentLiveCourt.thumbnail(moved)))
        XCTAssertGreaterThan(measured, IndependentLiveEngine.backgroundMovedPixels)
        let stream = UUID(), small = [UInt8](repeating: 90, count: 512 * 288 * 3)
        func run(_ frames: Range<Int>, _ full: CVPixelBuffer) throws {
            for k in frames {
                _ = try engine.process(small: small, full: k % 12 == 0 ? full : nil, pts: 10 + Double(k) / 60, streamID: stream,
                                       sourceWidth: 1920, sourceHeight: 1080)
            }
        }
        try run(0..<120, still)
        XCTAssertEqual(engine.stats.backgroundRebuilds, 0, "a still picture keeps its background")
        XCTAssertFalse(engine.stats.pictureMoving)
        XCTAssertGreaterThan(engine.stats.batches, 0)
        try run(120..<132, moved)
        XCTAssertEqual(engine.stats.backgroundRebuilds, 1, "45 px away from the background's view")
        XCTAssertTrue(engine.stats.pictureMoving, "shots are not counted while the picture moves")
        let resets = engine.stats.ballResets
        try run(132..<300, moved)
        XCTAssertEqual(engine.stats.backgroundRebuilds, 1, "the new background was taken from the new view")
        XCTAssertEqual(engine.stats.ballResets, resets)
        XCTAssertTrue(engine.stats.pictureMoving, "held for a few seconds after the last drop")
        try run(300..<420, moved)
        XCTAssertFalse(engine.stats.pictureMoving, "still again for longer than the hold")
    }

    /// During L1 recovery the 3 Hz person reads share the 10 Hz serve frames. L1 for power, pressure
    /// or lag and all L2 cases shed the extra reads. A source that outruns the worker does too.
    func testLoadSheddingSlowsPersonFramesInsteadOfStoppingThem() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let staged = repository.appendingPathComponent(".local/IndependentModels/tracknetv3-base-fp16-v1")
        guard FileManager.default.fileExists(atPath: staged.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Run scripts/prepare-independent-app-models.sh to stage the FP16 package")
        }
        let assets = try IndependentBallModelAssets.load(directory: staged, variant: .fp16)
        let camera = IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0), from: SIMD3(0.3, -6.4, 3.1), f: 1300)
        let frame = try nv12(y: 90, cb: 128, cr: 128)
        func samples(people: Bool, bounces: Bool, recovering: Bool = false, backlog: Bool = false) throws -> CameraSideAnalyzer.Metrics {
            let analyzer = CameraSideAnalyzer(configuration: nil, independent: .init(assets: assets, camera: camera, automaticCourt: false))
            let deadline = Date().addingTimeInterval(60)
            while !analyzer.currentMetrics.ready && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            XCTAssertTrue(analyzer.currentMetrics.ready)
            analyzer.preservesServeDetailAtL1 = recovering
            analyzer.isDetectingPeople = people; analyzer.isLocalizingBounces = bounces
            let stream = UUID()
            let resume = DispatchSemaphore(value: 0)
            if backlog {
                analyzer.observeIndependentTrace { event in
                    if case .newStream = event { _ = resume.wait(timeout: .now() + 10) }
                }
            }
            for k in 0..<120 {
                while !backlog && analyzer.currentMetrics.pendingFrames > 4 && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
                analyzer.submit(frame, pts: 10 + Double(k) / 60, streamID: stream)
            }
            resume.signal()
            let done = expectation(description: "finish")
            analyzer.finish { _, _ in done.fulfill() }
            wait(for: [done], timeout: 120)
            return analyzer.currentMetrics
        }
        let normal = try samples(people: true, bounces: true)
        XCTAssertEqual([normal.copies, normal.poseCopies, normal.poseFramesLive], [10, 10, 20])
        let recovery = try samples(people: false, bounces: true, recovering: true)
        XCTAssertEqual([recovery.copies, recovery.poseCopies, recovery.poseFramesLive], [6, 14, 20])
        let limited = try samples(people: false, bounces: true)
        XCTAssertEqual([limited.copies, limited.poseCopies, limited.poseFramesLive], [6, 0, 0])
        let serious = try samples(people: false, bounces: false, recovering: true)
        XCTAssertEqual([serious.copies, serious.poseCopies, serious.poseFramesLive], [4, 0, 0])
        let behind = try samples(people: false, bounces: true, recovering: true, backlog: true)
        XCTAssertGreaterThan(behind.poseSkippedBehind, 0)
        XCTAssertLessThan(behind.poseFramesLive, recovery.poseFramesLive)
        XCTAssertEqual(behind.copies, recovery.copies)
    }
}
