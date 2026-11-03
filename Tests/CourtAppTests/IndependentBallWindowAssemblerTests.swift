import XCTest
@testable import CourtCore

final class IndependentBallWindowAssemblerTests: XCTestCase {
    private func image(_ rgb: [UInt8] = [20, 40, 60], width: Int = 1, height: Int = 1) throws -> IndependentRGB8Buffer {
        try .init(width: width, height: height, bytesPerRow: width * 3,
                  bytes: (0..<(width * height)).flatMap { _ in rgb },
                  pixelFormat: .rgb8, coordinateSpace: .decodedTopLeftUnrotated)
    }

    private func time(_ pts: Int64, denominator: Int32 = 60) throws -> IndependentBallFrameTime {
        try .init(sourcePTS: pts, timeBaseDenominator: denominator)
    }

    private func append(_ assembler: IndependentBallWindowAssembler, _ pts: Int64,
                        image: IndependentRGB8Buffer, source: String = "source",
                        roi: IndependentBallROI? = nil) throws -> IndependentBallPreparedWindow? {
        try assembler.append(image: image, time: time(pts), sourceID: source, roi: roi)
    }

    func testRealEvenMedianFrozenPastBackgroundAndCompleteNonoverlappingWindows() throws {
        let assembler = try IndependentBallWindowAssembler()
        for i in 0..<48 {
            // Unsorted samples; middle values are 23/24, 231/232 and 10/11.
            let sample = try image([UInt8((i * 17) % 48), UInt8(255 - i), UInt8(i < 24 ? 10 : 11)])
            XCTAssertNil(try append(assembler, Int64(i), image: sample))
            XCTAssertEqual(assembler.state.warmupFrameCount, i + 1)
            XCTAssertEqual(assembler.state.retainedImageCount, i == 47 ? 1 : i + 1)
        }
        XCTAssertTrue(assembler.state.backgroundReady)
        let future = try image([250, 250, 250])
        for i in 48..<55 {
            XCTAssertNil(try append(assembler, Int64(i), image: future))
            XCTAssertEqual(assembler.state.pendingFrameCount, i - 47)
        }
        let first = try XCTUnwrap(append(assembler, 55, image: future))
        XCTAssertEqual(first.frames.count, 8)
        XCTAssertEqual(first.times.map(\.sourcePTS), Array(Int64(48)...55))
        XCTAssertEqual(first.backgroundTimes.map(\.sourcePTS), Array(Int64(0)...47))
        XCTAssertEqual(first.backgroundStrategy, "prefix_median48_resized_rgb")
        XCTAssertEqual(first.lookaheadFrames, 7)
        XCTAssertEqual(first.windowIndex, 0)
        XCTAssertEqual(first.segmentIndex, 0)
        XCTAssertEqual(first.sourceID, "source")
        XCTAssertEqual(first.background.width, 512)
        XCTAssertEqual(first.background.height, 288)
        XCTAssertEqual(first.background.bytesPerRow, 512 * 3)
        XCTAssertEqual(Array(first.background.bytes.prefix(3)), [23, 231, 10])
        XCTAssertTrue(first.background.bytes.enumerated().allSatisfy { $0.element == [23, 231, 10][$0.offset % 3] })
        XCTAssertTrue(first.frames.allSatisfy { $0.bytes.allSatisfy { $0 == 250 } })
        XCTAssertEqual(assembler.state.pendingFrameCount, 0)
        XCTAssertEqual(assembler.state.retainedImageCount, 1)
        XCTAssertEqual(assembler.state.retainedImageBytes, IndependentBallWindowAssembler.resizedImageBytes)

        let changed = try image([0, 0, 0])
        var second: IndependentBallPreparedWindow?
        for i in 56..<64 { second = try append(assembler, Int64(i), image: changed) }
        XCTAssertEqual(second?.windowIndex, 1)
        XCTAssertEqual(second?.times.map(\.sourcePTS), Array(Int64(56)...63))
        XCTAssertEqual(second?.background.bytes, first.background.bytes)
        for i in 64..<71 { XCTAssertNil(try append(assembler, Int64(i), image: changed)) }
        XCTAssertEqual(assembler.state.pendingFrameCount, 7) // No tail padding.
        XCTAssertEqual(assembler.state.retainedImageCount, 8)
        XCTAssertEqual(assembler.state.retainedImageBytes, 8 * 512 * 288 * 3)
        assembler.reset()
        XCTAssertEqual(assembler.state.retainedImageCount, 0)
        XCTAssertEqual(assembler.state.warmupFrameCount, 0)
        XCTAssertEqual(assembler.state.lastResetReason, "explicit_reset")
        XCTAssertEqual(first.frames.first?.bytes.first, 250) // Result owns its data.
    }

    func testResizeBeforeMedianAndOriginalROIMapping() throws {
        let assembler = try IndependentBallWindowAssembler()
        let roi = IndependentBallROI(x: 1, y: 0, width: 2, height: 1)
        let dark = try image([0, 0, 0], width: 3)
        let striped = try IndependentRGB8Buffer(width: 3, height: 1, bytesPerRow: 9,
            bytes: [19, 19, 19, 255, 255, 255, 0, 0, 0],
            pixelFormat: .rgb8, coordinateSpace: .decodedTopLeftUnrotated)
        let resizedDark = try IndependentBallPreprocessor.resizeRGB8(dark, roi: roi)
        let resizedStripe = try IndependentBallPreprocessor.resizeRGB8(striped, roi: roi)
        for i in 0..<48 { XCTAssertNil(try append(assembler, Int64(i), image: i % 2 == 0 ? dark : striped, roi: roi)) }
        var result: IndependentBallPreparedWindow?
        for i in 48..<56 { result = try append(assembler, Int64(i), image: striped, roi: roi) }
        let prepared = try XCTUnwrap(result)
        let expected = zip(resizedDark.bytes, resizedStripe.bytes).map { pair in UInt8((Int(pair.0) + Int(pair.1)) / 2) }
        XCTAssertEqual(prepared.background.bytes, expected)
        XCTAssertEqual(prepared.frames[0].bytes, resizedStripe.bytes)
        XCTAssertEqual(prepared.transform.originalWidth, 3)
        XCTAssertEqual(prepared.transform.originalHeight, 1)
        XCTAssertEqual(prepared.transform.cropX, 1)
        XCTAssertEqual(prepared.transform.cropWidth, 2)
        XCTAssertEqual(prepared.transform.original(0, 0, width: 512, height: 288), [1, 0])
        XCTAssertEqual(prepared.transform.original(511, 287, width: 512, height: 288), [2, 0])
        let nativeMedian = try IndependentRGB8Buffer(width: 3, height: 1, bytesPerRow: 9,
            bytes: [9, 9, 9, 127, 127, 127, 0, 0, 0],
            pixelFormat: .rgb8, coordinateSpace: .decodedTopLeftUnrotated)
        XCTAssertNotEqual(prepared.background.bytes, try IndependentBallPreprocessor.resizeRGB8(nativeMedian, roi: roi).bytes)
    }

    func testGapDropsFrozenBackgroundAndPartialWindowWithoutFabrication() throws {
        let assembler = try IndependentBallWindowAssembler()
        let sample = try image()
        for i in 0..<51 { XCTAssertNil(try append(assembler, Int64(i), image: sample)) }
        XCTAssertTrue(assembler.state.backgroundReady)
        XCTAssertEqual(assembler.state.pendingFrameCount, 3)
        XCTAssertNil(try append(assembler, 52, image: sample)) // Missing source frame 51.
        XCTAssertEqual(assembler.state.lastResetReason, "source_gap")
        XCTAssertEqual(assembler.state.segmentIndex, 1)
        XCTAssertFalse(assembler.state.backgroundReady)
        XCTAssertEqual(assembler.state.warmupFrameCount, 1)
        XCTAssertEqual(assembler.state.pendingFrameCount, 0)
        XCTAssertEqual(assembler.state.retainedImageCount, 1)
    }

    func testSourceDimensionsAndROIChangesRestartWarmup() throws {
        let assembler = try IndependentBallWindowAssembler()
        let sample = try image(width: 3, height: 2)
        XCTAssertNil(try append(assembler, 100, image: sample))
        XCTAssertNil(try append(assembler, 101, image: sample))
        XCTAssertNil(try append(assembler, 0, image: sample, source: "second"))
        XCTAssertEqual(assembler.state.lastResetReason, "source_changed")
        XCTAssertEqual(assembler.state.warmupFrameCount, 1)
        let smaller = try image(width: 2, height: 2)
        XCTAssertNil(try append(assembler, 1, image: smaller, source: "second"))
        XCTAssertEqual(assembler.state.lastResetReason, "dimensions_changed")
        XCTAssertEqual(assembler.state.warmupFrameCount, 1)
        let roi = IndependentBallROI(x: 1, y: 0, width: 1, height: 2)
        XCTAssertNil(try append(assembler, 2, image: smaller, source: "second", roi: roi))
        XCTAssertEqual(assembler.state.lastResetReason, "roi_changed")
        XCTAssertEqual(assembler.state.warmupFrameCount, 1)
        XCTAssertNil(try append(assembler, 3, image: smaller, source: "second"))
        XCTAssertEqual(assembler.state.lastResetReason, "roi_changed")
        XCTAssertEqual(assembler.state.segmentIndex, 4)
        // Changing nil to explicit full-image ROI still changes the source contract.
        XCTAssertNil(try append(assembler, 4, image: smaller, source: "second",
            roi: .init(x: 0, y: 0, width: 2, height: 2)))
        XCTAssertEqual(assembler.state.segmentIndex, 5)
        XCTAssertEqual(assembler.state.retainedImageCount, 1)
    }

    func testContinuityThresholdUsesExactOriginalTimeBase() throws {
        let assembler = try IndependentBallWindowAssembler(), sample = try image()
        XCTAssertNil(try assembler.append(image: sample, time: time(0, denominator: 120), sourceID: "source"))
        // Exactly 1.5 nominal periods is continuous; more than that resets.
        XCTAssertNil(try assembler.append(image: sample, time: time(3, denominator: 120), sourceID: "source"))
        XCTAssertEqual(assembler.state.warmupFrameCount, 2)
        XCTAssertEqual(assembler.state.segmentIndex, 0)
        XCTAssertNil(try assembler.append(image: sample, time: time(7, denominator: 120), sourceID: "source"))
        XCTAssertEqual(assembler.state.warmupFrameCount, 1)
        XCTAssertEqual(assembler.state.lastResetReason, "source_gap")
    }

    func testInvalidInputsThrowAndResetAllTemporalState() throws {
        let assembler = try IndependentBallWindowAssembler(), sample = try image()
        XCTAssertNil(try append(assembler, 0, image: sample))
        XCTAssertThrowsError(try append(assembler, 0, image: sample)) { error in
            XCTAssertEqual(error as? IndependentBallWindowAssemblyError, .nonMonotonicTimestamp)
        }
        XCTAssertEqual(assembler.state.lastResetReason, "non_monotonic_timestamp")
        XCTAssertEqual(assembler.state.retainedImageCount, 0)
        XCTAssertNil(try append(assembler, 10, image: sample))
        XCTAssertThrowsError(try append(assembler, 9, image: sample))
        XCTAssertEqual(assembler.state.warmupFrameCount, 0)

        let invalid = try JSONDecoder().decode(IndependentBallFrameTime.self,
            from: Data(#"{"sourcePTS":1,"timeBaseNumerator":1,"timeBaseDenominator":0}"#.utf8))
        XCTAssertNil(try append(assembler, 0, image: sample))
        XCTAssertThrowsError(try assembler.append(image: sample, time: invalid, sourceID: "source"))
        XCTAssertEqual(assembler.state.retainedImageBytes, 0)
        XCTAssertEqual(assembler.state.lastResetReason, "invalid_input")
        for source in ["", " \n\t"] {
            XCTAssertNil(try append(assembler, 0, image: sample))
            XCTAssertThrowsError(try append(assembler, 1, image: sample, source: source))
            XCTAssertEqual(assembler.state.warmupFrameCount, 0)
        }
        for roi in [IndependentBallROI(x: Int.max, y: 0, width: 1, height: 1),
                    IndependentBallROI(x: 0, y: 0, width: 0, height: 1)] {
            XCTAssertNil(try append(assembler, 0, image: sample))
            XCTAssertThrowsError(try append(assembler, 1, image: sample, roi: roi))
            XCTAssertEqual(assembler.state.retainedImageCount, 0)
        }
        XCTAssertNil(try append(assembler, -1, image: sample)) // Negative numeric PTS is valid.
        XCTAssertEqual(assembler.state.warmupFrameCount, 1)
    }

    func testConfigurationAndOwnedBufferInvariants() throws {
        for fps in [Double.nan, .infinity, -.infinity, 0, -1, 0.5, 241, .leastNonzeroMagnitude] {
            XCTAssertThrowsError(try IndependentBallWindowAssembler(nominalFramesPerSecond: fps))
        }
        XCTAssertNoThrow(try IndependentBallWindowAssembler(nominalFramesPerSecond: 1))
        XCTAssertNoThrow(try IndependentBallWindowAssembler(nominalFramesPerSecond: 240))
        XCTAssertThrowsError(try IndependentRGB8Buffer(width: 1, height: 1, bytesPerRow: 3,
            bytes: [0, 0], pixelFormat: .rgb8, coordinateSpace: .decodedTopLeftUnrotated))
        XCTAssertThrowsError(try IndependentRGB8Buffer(width: 1, height: 1, bytesPerRow: 4,
            bytes: [0, 0, 0, 0], pixelFormat: .bgra8, coordinateSpace: .decodedTopLeftUnrotated))
        let assembler = try IndependentBallWindowAssembler()
        var bytes: [UInt8] = [12, 34, 56, 99] // A padded owned source row.
        let padded = try IndependentRGB8Buffer(width: 1, height: 1, bytesPerRow: 4, bytes: bytes,
            pixelFormat: .rgb8, coordinateSpace: .decodedTopLeftUnrotated)
        bytes[0] = 255
        XCTAssertEqual(padded.bytes[0], 12)
        XCTAssertNil(try append(assembler, 0, image: padded))
        XCTAssertEqual(assembler.state.retainedImageBytes, 512 * 288 * 3)
        assembler.reset(reason: "analysis_queue_discontinuity")
        XCTAssertEqual(assembler.state.lastResetReason, "analysis_queue_discontinuity")
        XCTAssertEqual(assembler.state.retainedImageBytes, 0)
    }
}
