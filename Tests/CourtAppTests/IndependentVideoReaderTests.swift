import XCTest
import AVFoundation
@testable import CourtCore

final class IndependentVideoReaderTests: XCTestCase {
    func testOwnedRGBFramesKeepSourcePTSAndMetadata() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let referenceTimings = try await decoderTimings(fixture)
        var saved: IndependentVideoFrame?
        do {
            let reader = try await IndependentVideoReader.open(video: fixture)
            XCTAssertEqual(reader.metadata.naturalWidth, 18)
            XCTAssertEqual(reader.metadata.naturalHeight, 12)
            XCTAssertGreaterThan(reader.metadata.nominalFPS, 0)
            XCTAssertEqual(reader.metadata.preferredTransform.a, 1)
            XCTAssertEqual(reader.metadata.preferredTransform.d, 1)
            XCTAssertEqual(reader.metadata.preferredTransform.b, 0)
            XCTAssertEqual(reader.metadata.sourceFormats.count, 1)
            XCTAssertEqual(reader.metadata.sourceFormats.first?.width, 18)
            XCTAssertEqual(reader.metadata.sourceFormats.first?.height, 12)
            XCTAssertEqual(reader.metadata.sourceFormats.first?.color.primaries,
                           kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            XCTAssertTrue(reader.metadata.decodingBoundary.contains("unverified"))
            var times: [CMTime] = []
            while let frame = try reader.next() {
                if saved == nil { saved = frame }
                XCTAssertEqual(frame.rgb.bytesPerRow, 18 * 3)
                XCTAssertEqual(frame.rgb.bytes.count, 18 * 12 * 3)
                XCTAssertEqual(frame.presentationTime.timescale, 600)
                if let previous = times.last { XCTAssertGreaterThan(CMTimeCompare(frame.presentationTime, previous), 0) }
                // Some decoder outputs have invalid duration/DTS even though
                // the writer supplied durations. Preserve exactly what it gave.
                let reference = referenceTimings[times.count]
                assertRawTime(frame.presentationTime, reference.pts)
                assertRawTime(frame.duration, reference.duration)
                assertRawTime(frame.decodeTime, reference.dts)
                assertPixels(frame.rgb, frameIndex: times.count)
                times.append(frame.presentationTime)
            }
            XCTAssertEqual(times.count, pts.count)
            for (actual, expected) in zip(times, pts) {
                XCTAssertEqual(CMTimeCompare(actual, CMTime(value: expected, timescale: 600)), 0)
            }
            XCTAssertNil(try reader.next())
            reader.cancel()
            XCTAssertNil(try reader.next())
        }
        // The reader and its decoder samples are gone. Later decoding must not
        // have overwritten a saved frame, and removing the asset must not do so.
        try FileManager.default.removeItem(at: fixture)
        assertPixels(try XCTUnwrap(saved).rgb, frameIndex: 0)
    }

    func testTrackSelectionAndExactHalfOpenPTSRange() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let full = try await IndependentVideoReader.open(video: fixture)
        let id = full.metadata.trackID
        full.cancel()
        for (start, duration, expected) in [(Int64(20), Int64(80), [Int64(20), 70]),
                                          (Int64(21), Int64(80), [Int64(70), 100])] {
            let range = CMTimeRange(start: CMTime(value: start, timescale: 600),
                                    duration: CMTime(value: duration, timescale: 600))
            let reader = try await IndependentVideoReader.open(video: fixture, trackID: id, timeRange: range)
            XCTAssertEqual(reader.metadata.trackID, id)
            var actual: [CMTime] = []
            while let frame = try reader.next() {
                XCTAssertGreaterThanOrEqual(CMTimeCompare(frame.presentationTime, range.start), 0)
                XCTAssertLessThan(CMTimeCompare(frame.presentationTime, CMTimeRangeGetEnd(range)), 0)
                actual.append(frame.presentationTime)
            }
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertEqual(reader.decodedSampleCount, 4)
            XCTAssertEqual(reader.discardedPrerollSampleCount, start == 20 ? 1 : 2)
            for (time, value) in zip(actual, expected) {
                XCTAssertEqual(CMTimeCompare(time, CMTime(value: value, timescale: 600)), 0)
            }
        }
    }

    func testCancellationAndResourceExhaustionAreErrorsNotEOF() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let cancelled = try await IndependentVideoReader.open(video: fixture)
        cancelled.cancel()
        for _ in 0..<2 {
            XCTAssertThrowsError(try cancelled.next()) { XCTAssertEqual($0 as? IndependentVideoReaderError, .cancelled) }
        }
        let limited = try await IndependentVideoReader.open(video: fixture,
            limits: .init(maximumDecodedFrames: 1))
        XCTAssertNotNil(try limited.next())
        for _ in 0..<2 {
            XCTAssertThrowsError(try limited.next()) { XCTAssertEqual($0 as? IndependentVideoReaderError, .resourceLimit) }
        }
    }

    func testCancellationDuringPrerollStopsBeforeNextSample() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let reader = try await IndependentVideoReader.open(video: fixture,
            timeRange: CMTimeRange(start: CMTime(value:70,timescale:600), duration: CMTime(value:30,timescale:600)))
        var checks = 0
        XCTAssertThrowsError(try reader.next(checkCancellation: {
            checks += 1
            if checks == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks,3)
        XCTAssertEqual(reader.decodedSampleCount,2)
        XCTAssertEqual(reader.discardedPrerollSampleCount,2)
        XCTAssertThrowsError(try reader.next()) { XCTAssertEqual($0 as? IndependentVideoReaderError,.cancelled) }
    }

    func testRejectsPreferredRotation() async throws {
        let fixture = try await makeFixture(transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 12, ty: 0))
        defer { try? FileManager.default.removeItem(at: fixture) }
        do {
            _ = try await IndependentVideoReader.open(video: fixture)
            XCTFail("Rotated track must not be silently normalized")
        } catch { XCTAssertEqual(error as? IndependentVideoReaderError, .unsupportedTransform) }
    }

    func testRejectsNonLocalMissingAndMalformedInputs() async throws {
        do {
            _ = try await IndependentVideoReader.open(video: URL(string: "https://example.invalid/video.mov")!)
            XCTFail("Network URLs are outside this reader's scope")
        } catch { XCTAssertEqual(error as? IndependentVideoReaderError, .localFileRequired) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        do {
            _ = try await IndependentVideoReader.open(video: missing)
            XCTFail("Missing local input must fail")
        } catch { XCTAssertEqual(error as? IndependentVideoReaderError, .fileUnavailable) }
        try Data("not a video".utf8).write(to: missing)
        defer { try? FileManager.default.removeItem(at: missing) }
        do {
            _ = try await IndependentVideoReader.open(video: missing)
            XCTFail("Malformed input must fail")
        } catch { /* Either AVFoundation loading error or no video track is a failure, never EOF. */ }
    }

    func testRejectsUnknownTrackDimensionsRangesAndInvalidLimits() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        do {
            _ = try await IndependentVideoReader.open(video: fixture, trackID: CMPersistentTrackID.max)
            XCTFail("Unknown track must fail")
        } catch { XCTAssertEqual(error as? IndependentVideoReaderError, .trackNotFound) }
        do {
            _ = try await IndependentVideoReader.open(video: fixture, limits: .init(maximumDimension: 8))
            XCTFail("Oversized input must fail before decoding")
        } catch { XCTAssertEqual(error as? IndependentVideoReaderError, .unsupportedDimensions) }
        do {
            _ = try await IndependentVideoReader.open(video: fixture, limits: .init(maximumDecodedFrames: 0))
            XCTFail("Invalid resource bounds must fail")
        } catch { XCTAssertEqual(error as? IndependentVideoReaderError, .resourceLimit) }
        for range in [CMTimeRange.invalid,
                      CMTimeRange(start: .zero, duration: .zero),
                      CMTimeRange(start: CMTime(value: -1, timescale: 600), duration: CMTime(value: 20, timescale: 600)),
                      CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))] {
            do {
                _ = try await IndependentVideoReader.open(video: fixture, timeRange: range)
                XCTFail("Invalid/out-of-track range must fail")
            } catch { XCTAssertEqual(error as? IndependentVideoReaderError, .invalidTimeRange) }
        }
    }

    func testPresentationTimelineRejectsInvalidDuplicateAndDecreasingPTS() throws {
        let previous = CMTime(value: 70, timescale: 600)
        try IndependentVideoReader.validatePresentationTime(CMTime(value: 71, timescale: 600), after: previous)
        for invalid in [CMTime.invalid, .indefinite, .positiveInfinity,
                        CMTime(value: 80, timescale: 600, flags: .valid, epoch: 1)] {
            XCTAssertThrowsError(try IndependentVideoReader.validatePresentationTime(invalid, after: previous)) {
                XCTAssertEqual($0 as? IndependentVideoReaderError, .invalidPresentationTime)
            }
        }
        for nonIncreasing in [previous, CMTime(value: 69, timescale: 600), CMTime(value: 7, timescale: 60)] {
            XCTAssertThrowsError(try IndependentVideoReader.validatePresentationTime(nonIncreasing, after: previous)) {
                XCTAssertEqual($0 as? IndependentVideoReaderError, .nonMonotonicPresentationTime)
            }
        }
    }

    private let pts: [Int64] = [0, 20, 70, 100]
    private let durations: [Int64] = [20, 50, 30, 30]

    private func assertRawTime(_ actual: CMTime, _ expected: CMTime,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.value, expected.value, file: file, line: line)
        XCTAssertEqual(actual.timescale, expected.timescale, file: file, line: line)
        XCTAssertEqual(actual.flags, expected.flags, file: file, line: line)
        XCTAssertEqual(actual.epoch, expected.epoch, file: file, line: line)
    }

    private func decoderTimings(_ url: URL) async throws -> [(pts: CMTime, duration: CMTime, dts: CMTime)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        let reader = try AVAssetReader(asset: asset)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result: [(CMTime, CMTime, CMTime)] = []
        while let sample = output.copyNextSampleBuffer() {
            result.append((CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample),
                           CMSampleBufferGetDecodeTimeStamp(sample)))
        }
        XCTAssertEqual(reader.status, .completed)
        return result
    }

    private func assertPixels(_ rgb: IndependentRGB8Buffer, frameIndex: Int,
                              file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(0, 0), (17, 0), (0, 11), (17, 11)] {
            let offset = y * rgb.bytesPerRow + x * 3
            XCTAssertEqual(Array(rgb.bytes[offset..<(offset + 3)]),
                           [UInt8(30 + frameIndex * 40 + y), UInt8(70 + x), UInt8(190 - frameIndex * 30)],
                           file: file, line: line)
        }
    }

    /// Uncompressed BGRA MOV avoids making lossy-encoder tolerances part of
    /// the channel-order and ownership assertions. Source rows are padded.
    private func makeFixture(transform: CGAffineTransform = .identity) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var firstBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 18, 12, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &firstBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(firstBuffer)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        var optionalFormat: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &optionalFormat), noErr)
        let format = try XCTUnwrap(optionalFormat)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.transform = transform
        input.mediaTimeScale = 600
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in pts.indices {
            // Do not reuse storage retained by AVAssetWriter: each source frame
            // owns its allocation until the writer is done with that sample.
            var optionalPixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 18, 12, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &optionalPixels), kCVReturnSuccess)
            let pixels = try XCTUnwrap(optionalPixels)
            CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            XCTAssertGreaterThan(stride, 18 * 4)
            for y in 0..<12 {
                for x in 0..<18 {
                    let offset = y * stride + x * 4
                    base[offset] = UInt8(190 - index * 30)
                    base[offset + 1] = UInt8(70 + x)
                    base[offset + 2] = UInt8(30 + index * 40 + y)
                    base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            var timing = CMSampleTimingInfo(duration: CMTime(value: durations[index], timescale: 600),
                presentationTimeStamp: CMTime(value: pts[index], timescale: 600), decodeTimeStamp: .invalid)
            var optionalSample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixels, formatDescription: format, sampleTiming: &timing,
                sampleBufferOut: &optionalSample), noErr)
            let sample = try XCTUnwrap(optionalSample)
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.isReadyForMoreMediaData, input.append(sample) else {
                throw FixtureFailure.writer(writer.error?.localizedDescription ?? "Writer not ready / sample rejected")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 130, timescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FixtureFailure.writer(writer.error?.localizedDescription ?? "Writer did not finish")
        }
        return url
    }

    private enum FixtureFailure: Error { case writer(String) }
}
