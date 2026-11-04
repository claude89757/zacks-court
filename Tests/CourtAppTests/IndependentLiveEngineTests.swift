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
        XCTAssertGreaterThan(engine.stats.batches, 0)
        try run(120..<132, moved)
        XCTAssertEqual(engine.stats.backgroundRebuilds, 1, "45 px away from the background's view")
        let resets = engine.stats.ballResets
        try run(132..<300, moved)
        XCTAssertEqual(engine.stats.backgroundRebuilds, 1, "the new background was taken from the new view")
        XCTAssertEqual(engine.stats.ballResets, resets)
    }

    /// The in-house rules need person boxes, so load shedding slows person frames instead of stopping
    /// them: 5 Hz normally, 3 Hz at L1 (people off), 2 Hz at L2 (bounces off too).
    func testLoadSheddingSlowsPersonFramesInsteadOfStoppingThem() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let staged = repository.appendingPathComponent(".local/IndependentModels/tracknetv3-base-fp16-v1")
        guard FileManager.default.fileExists(atPath: staged.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("Run scripts/prepare-independent-app-models.sh to stage the FP16 package")
        }
        let assets = try IndependentBallModelAssets.load(directory: staged, variant: .fp16)
        let camera = IndependentPinholeCamera.lookingAt(SIMD3(0, 11, 0), from: SIMD3(0.3, -6.4, 3.1), f: 1300)
        let frame = try nv12(y: 90, cb: 128, cr: 128)
        func personFrames(people: Bool, bounces: Bool) throws -> Int {
            let analyzer = CameraSideAnalyzer(configuration: nil, independent: .init(assets: assets, camera: camera, automaticCourt: false))
            let deadline = Date().addingTimeInterval(60)
            while !analyzer.currentMetrics.ready && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            XCTAssertTrue(analyzer.currentMetrics.ready)
            analyzer.isDetectingPeople = people; analyzer.isLocalizingBounces = bounces
            let stream = UUID()
            for k in 0..<120 { analyzer.submit(frame, pts: 10 + Double(k) / 60, streamID: stream) }
            let done = expectation(description: "finish")
            analyzer.finish { _, _ in done.fulfill() }
            wait(for: [done], timeout: 120)
            let m = analyzer.currentMetrics
            return m.copies + m.poolExhausted          // person frames attempted
        }
        XCTAssertEqual(try personFrames(people: true, bounces: true), 10)
        XCTAssertEqual(try personFrames(people: false, bounces: true), 6)
        XCTAssertEqual(try personFrames(people: false, bounces: false), 4)
    }
}
