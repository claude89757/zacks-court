import XCTest
import AVFoundation
import CoreMedia
import simd
@testable import CourtCore

final class CaptureFrameMetadataTests: XCTestCase {
    private let width = 320, height = 180
    private func matrixData(_ base: Float = 1) -> Data {
        // Each SIMD3 column occupies sixteen bytes. Poison padding must never become a value.
        let values: [Float] = [base, 2, 3, .nan, 4, 5, 6, .infinity, 7, 8, 9, -.infinity]
        return values.withUnsafeBytes { Data($0) }
    }
    private func observation(_ base: Float = 1) -> CaptureFrameMetadata.IntrinsicObservation {
        .from(attachment: matrixData(base) as CFData)
    }
    private func metadata(_ sequence: UInt64, _ pts: CMTime, intrinsic: CaptureFrameMetadata.IntrinsicObservation? = nil,
                          width: Int = 320, height: Int = 180) -> CaptureFrameMetadata {
        .init(captureSequence: sequence, sourcePTS: pts, deliveredWidth: width, deliveredHeight: height,
              intrinsic: intrinsic ?? observation(Float(sequence)), deliveryState: .enabled)
    }
    private func pixels() throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(image)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    private func sample() throws -> CMSampleBuffer {
        let image = try pixels()
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testNativePaddedMatrixAttachmentAndUnalignedStorage() throws {
        XCTAssertEqual(MemoryLayout<simd_float3x3>.size, 48)
        let expected: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let sample = try sample()
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, value: matrixData() as CFData, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let value = CaptureFrameMetadata.IntrinsicObservation.from(sampleBuffer: sample)
        XCTAssertEqual(value.status, .available); XCTAssertEqual(value.columnMajor9, expected)
        XCTAssertEqual(value.attachmentByteCount, 48)

        let storage = UnsafeMutableRawPointer.allocate(byteCount: 49, alignment: 16)
        defer { storage.deallocate() }
        matrixData().copyBytes(to: storage.advanced(by: 1).assumingMemoryBound(to: UInt8.self), count: 48)
        let unaligned = try XCTUnwrap(CFDataCreateWithBytesNoCopy(nil, storage.advanced(by: 1).assumingMemoryBound(to: UInt8.self), 48, kCFAllocatorNull))
        XCTAssertNotEqual(Int(bitPattern: CFDataGetBytePtr(unaligned)) % 16, 0)
        XCTAssertEqual(CaptureFrameMetadata.IntrinsicObservation.from(attachment: unaligned).columnMajor9, expected)
    }

    func testInvalidAttachmentsAndMissingNeverReusePreviousObservation() throws {
        let sample = try sample()
        XCTAssertEqual(CaptureFrameMetadata.IntrinsicObservation.from(sampleBuffer: sample).status, .missing)
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, value: matrixData() as CFData, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertEqual(CaptureFrameMetadata.IntrinsicObservation.from(sampleBuffer: sample).status, .available)
        CMRemoveAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix)
        XCTAssertEqual(CaptureFrameMetadata.IntrinsicObservation.from(sampleBuffer: sample).reason, .attachmentMissing)
        for length in [0, 35, 36, 47, 49] {
            let value = CaptureFrameMetadata.IntrinsicObservation.from(attachment: Data(repeating: 0, count: length) as CFData)
            XCTAssertEqual(value.status, .invalid); XCTAssertEqual(value.reason, .wrongByteCount)
            XCTAssertNil(value.columnMajor9); XCTAssertEqual(value.attachmentByteCount, length)
        }
        var data = matrixData()
        var nan = Float.nan
        withUnsafeBytes(of: &nan) { data.replaceSubrange(16..<20, with: $0) }
        XCTAssertEqual(CaptureFrameMetadata.IntrinsicObservation.from(attachment: data as CFData).reason, .nonFiniteMatrix)
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, value: "invalid" as CFString, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertEqual(CaptureFrameMetadata.IntrinsicObservation.from(sampleBuffer: sample).reason, .wrongAttachmentType)
        XCTAssertEqual(CaptureFrameMetadata.IntrinsicObservation.from(attachment: NSNumber(value: 123)).reason, .wrongAttachmentType)
    }

    func testExactCMTimeBindingRejectsMismatchedEpochFlagsScaleAndDimensions() {
        let pts = CMTime(value: 600, timescale: 600, flags: [.valid, .hasBeenRounded], epoch: 7)
        let value = metadata(10, pts)
        XCTAssertEqual(value.sourcePTS.value, 600); XCTAssertEqual(value.sourcePTS.timescale, 600)
        XCTAssertEqual(value.sourcePTS.epoch, 7); XCTAssertEqual(value.sourcePTS.flags, pts.flags.rawValue)
        func reason(_ m: CaptureFrameMetadata, _ time: CMTime = pts, _ w: Int = 320, _ encoderW: Int = 320) -> CaptureFrameMetadata.OmissionReason? {
            m.omissionReason(pts: time, deliveredWidth: w, deliveredHeight: 180, encoderWidth: encoderW, encoderHeight: 180)
        }
        XCTAssertNil(reason(value))
        XCTAssertEqual(reason(value, CMTime(value: 1, timescale: 1, flags: [.valid, .hasBeenRounded], epoch: 7)), .sourcePTSMismatch)
        XCTAssertEqual(reason(value, CMTime(value: 600, timescale: 600, flags: [.valid], epoch: 7)), .sourcePTSMismatch)
        XCTAssertEqual(reason(value, CMTime(value: 600, timescale: 600, flags: [.valid, .hasBeenRounded], epoch: 8)), .sourcePTSMismatch)
        XCTAssertEqual(reason(metadata(1, .invalid)), .invalidSourcePTS)
        XCTAssertEqual(reason(metadata(1, .indefinite)), .invalidSourcePTS)
        XCTAssertEqual(reason(metadata(1, .positiveInfinity)), .invalidSourcePTS)
        XCTAssertEqual(reason(metadata(1, CMTime(value: 1, timescale: 0, flags: .valid, epoch: 0))), .invalidSourcePTS)
        XCTAssertEqual(reason(metadata(1, CMTime(value: 1, timescale: 60, flags: CMTimeFlags(rawValue: 0x8000_0001), epoch: 0))), .invalidSourcePTS)
        XCTAssertEqual(reason(metadata(1, pts, width: 0)), .deliveredDimensionsMismatch)
        XCTAssertEqual(reason(value, pts, 640), .deliveredDimensionsMismatch)
        XCTAssertEqual(reason(value, pts, 320, 640), .encoderDimensionsMismatch)
    }

    func testValueAndDecodeSanitizeNonFiniteQueriesAndRejectCalibrationClaims() throws {
        let value = CaptureFrameMetadata(captureSequence: 1, sourcePTS: .zero, deliveredWidth: width, deliveredHeight: height,
            intrinsic: observation(), deliveryState: .disabled,
            connection: .init(rotationDegrees: .nan, mirrored: true, preferredStabilization: 2, activeStabilization: 1),
            device: .init(zoomFactor: .infinity, exposureDuration: .indefinite, iso: .nan, lensPosition: -.infinity))
        XCTAssertNil(value.connection.rotationDegrees); XCTAssertNil(value.device.zoomFactor)
        XCTAssertNil(value.device.exposureDuration); XCTAssertNil(value.device.iso); XCTAssertNil(value.device.lensPosition)
        XCTAssertEqual(value.device.observationTiming.rawValue, "callback_query_not_frame_locked")
        let bytes = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(CaptureFrameMetadata.self, from: bytes), value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var device = try XCTUnwrap(object["device"] as? [String: Any]); device["zoomFactor"] = "NaN"; device["iso"] = "Infinity"
        object["device"] = device
        var connection = try XCTUnwrap(object["connection"] as? [String: Any]); connection["rotationDegrees"] = "NaN"; object["connection"] = connection
        var intrinsic = try XCTUnwrap(object["intrinsic"] as? [String: Any]); intrinsic["columnMajor9"] = ["NaN", 2, 3, 4, 5, 6, 7, 8, 9]; object["intrinsic"] = intrinsic
        let decoder = JSONDecoder(); decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let sanitized = try decoder.decode(CaptureFrameMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(sanitized.device.zoomFactor); XCTAssertNil(sanitized.device.iso); XCTAssertNil(sanitized.connection.rotationDegrees)
        XCTAssertEqual(sanitized.intrinsic.status, .invalid); XCTAssertNil(sanitized.intrinsic.columnMajor9)
        XCTAssertNoThrow(try JSONEncoder().encode(sanitized))
        object["intrinsicPixelTransformVerified"] = true
        XCTAssertThrowsError(try decoder.decode(CaptureFrameMetadata.self, from: JSONSerialization.data(withJSONObject: object)))
        object["intrinsicPixelTransformVerified"] = false; object["schemaVersion"] = 2
        XCTAssertThrowsError(try decoder.decode(CaptureFrameMetadata.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testBoundedLogicalMatrixDecodeAndOldHeaderCompatibility() throws {
        struct LegacyHeader: Decodable { let version: Int; let kind: String; let sequence: UInt64?; let pts: Double? }
        let old = Data(#"{"version":2,"kind":"video","sequence":4,"pts":1}"#.utf8)
        let oldHeader = try JSONDecoder().decode(StreamHeader.self, from: old)
        XCTAssertNil(oldHeader.captureMetadata); XCTAssertNil(oldHeader.captureMetadataOmissionReason)
        var header = oldHeader; header.captureMetadata = metadata(900, CMTime(value: 600, timescale: 600))
        let bytes = try JSONEncoder().encode(header)
        XCTAssertEqual(try JSONDecoder().decode(StreamHeader.self, from: bytes).captureMetadata, header.captureMetadata)
        let legacy = try JSONDecoder().decode(LegacyHeader.self, from: bytes)
        XCTAssertEqual(legacy.version, 2); XCTAssertEqual(legacy.kind, "video"); XCTAssertEqual(legacy.sequence, 4)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(observation())) as? [String: Any])
        for count in [0, 8, 10, 1_000] {
            object["columnMajor9"] = Array(repeating: 1, count: count)
            let decoded = try JSONDecoder().decode(CaptureFrameMetadata.IntrinsicObservation.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.status, .invalid); XCTAssertNil(decoded.columnMajor9)
        }
    }

    private final class Headers: @unchecked Sendable {
        private let lock = NSLock()
        private var headers: [StreamHeader] = []
        private var errors: [String] = []
        func append(_ value: StreamHeader) { lock.lock(); defer { lock.unlock() }; headers.append(value) }
        func error(_ value: String) { lock.lock(); defer { lock.unlock() }; errors.append(value) }
        var values: [StreamHeader] { lock.lock(); defer { lock.unlock() }; return headers }
        var failures: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    }

    func testRealVideoToolboxContextsKeepEveryFrameAndRestartSeparate() throws {
        let pixels = try pixels()
        var streams = Set<UUID>()
        for run in 0..<2 {
            let headers = Headers()
            let encoder = try H264Encoder(width: width, height: height, fps: 60)
            streams.insert(encoder.streamID)
            encoder.onFrame = { headers.append($0.packet.header) }; encoder.onError = { headers.error($0) }
            for index in 0..<12 {
                let pts = CMTime(value: Int64(index), timescale: 60)
                let value: CaptureFrameMetadata? = index % 3 == 1 ? nil : metadata(UInt64(100 * run + index), pts, intrinsic: index % 3 == 2 ? .missing : nil)
                encoder.encode(pixels, pts: pts, captureMetadata: value)
            }
            encoder.finish()
            XCTAssertTrue(headers.failures.isEmpty, headers.failures.joined(separator: "; "))
            let frames = headers.values.sorted { $0.sequence! < $1.sequence! }
            XCTAssertEqual(frames.count, 12)
            for (index, frame) in frames.enumerated() {
                XCTAssertEqual(frame.streamID, encoder.streamID); XCTAssertEqual(frame.sequence, UInt64(index + 1))
                XCTAssertNil(frame.captureMetadataOmissionReason)
                if index % 3 == 1 { XCTAssertNil(frame.captureMetadata) }
                else {
                    XCTAssertEqual(frame.captureMetadata?.captureSequence, UInt64(100 * run + index))
                    XCTAssertEqual(frame.captureMetadata?.sourcePTS, .init(CMTime(value: Int64(index), timescale: 60)))
                    XCTAssertEqual(frame.captureMetadata?.intrinsic.status, index % 3 == 2 ? .missing : .available)
                    if index % 3 == 0 { XCTAssertEqual(frame.captureMetadata?.intrinsic.columnMajor9?.first, Float(100 * run + index)) }
                }
            }
        }
        XCTAssertEqual(streams.count, 2)
    }

    func testRealVideoToolboxOmitsBadMetadataWithoutLosingVideo() throws {
        let headers = Headers(), pixels = try pixels()
        let encoder = try H264Encoder(width: width, height: height, fps: 60)
        encoder.onFrame = { headers.append($0.packet.header) }; encoder.onError = { headers.error($0) }
        encoder.encode(pixels, pts: .zero, captureMetadata: metadata(1, .invalid))
        encoder.encode(pixels, pts: CMTime(value: 1, timescale: 60), captureMetadata: metadata(2, .zero))
        encoder.encode(pixels, pts: CMTime(value: 2, timescale: 60), captureMetadata: metadata(3, CMTime(value: 2, timescale: 60), width: 640))
        encoder.encode(pixels, pts: CMTime(value: 3, timescale: 60))
        encoder.finish()
        let frames = headers.values.sorted { $0.sequence! < $1.sequence! }
        XCTAssertEqual(frames.count, 4); XCTAssertTrue(headers.failures.isEmpty)
        XCTAssertEqual(frames.map(\.captureMetadataOmissionReason), [.invalidSourcePTS, .sourcePTSMismatch, .deliveredDimensionsMismatch, nil])
        XCTAssertTrue(frames.allSatisfy { $0.captureMetadata == nil })
    }

    func testPipelineRecordingSidecarAndPreviewAssociationAcrossCaptureRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("court-capture-metadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "court.test.capture-metadata")
        let pipeline = CameraMediaPipeline(queue: queue), pixels = try pixels()
        let preview = Headers()
        pipeline.onPreview = { preview.append($0.header); return true }
        pipeline.setPreviewEvery(1); pipeline.setPreview(true)
        var streamIDs = Set<UUID>()
        for run in 0..<2 {
            let saved = expectation(description: "saved run \(run)")
            let result = RecordingBox()
            pipeline.onRecording = { result.value = $0; saved.fulfill() }
            queue.sync { _ = streamIDs.insert(pipeline.begin(width: width, height: height, fps: 60)) }
            pipeline.startRecording(directory: root, prefix: "metadata", owner: nil)
            for index in 0..<8 {
                let pts = CMTime(value: Int64(index), timescale: 60)
                let value = index % 2 == 0 ? metadata(UInt64(run * 100 + index), pts) : nil
                queue.sync { pipeline.submit(pixels, pts: pts, captureMetadata: value) }
                Thread.sleep(forTimeInterval: 0.025)
            }
            queue.sync { pipeline.end() }
            wait(for: [saved], timeout: 10)
            let recording = try XCTUnwrap(result.value).get()
            XCTAssertEqual(recording.frames, 8)
            let sidecar = try Data(contentsOf: recording.url.deletingPathExtension().appendingPathExtension("jsonl"))
            let frames = try sidecar.split(separator: 10).map { try JSONDecoder().decode(StreamHeader.self, from: Data($0)) }
            XCTAssertEqual(frames.count, 8)
            for (index, frame) in frames.enumerated() {
                XCTAssertEqual(frame.streamID, recording.streamID)
                XCTAssertEqual(frame.captureMetadata?.captureSequence, index % 2 == 0 ? UInt64(run * 100 + index) : nil)
                XCTAssertNil(frame.captureMetadataOmissionReason)
                if index % 2 == 0 { XCTAssertEqual(frame.captureMetadata?.sourcePTS, .init(CMTime(value: Int64(index), timescale: 60))) }
            }
        }
        XCTAssertEqual(streamIDs.count, 2)
        XCTAssertFalse(preview.values.isEmpty)
        XCTAssertTrue(preview.values.allSatisfy { $0.captureMetadata == nil && $0.captureMetadataOmissionReason == nil })
        pipeline.setPreview(false)
    }
    private final class RecordingBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Result<CameraMediaPipeline.Recording, Error>?
        var value: Result<CameraMediaPipeline.Recording, Error>? {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); defer { lock.unlock() }; storage = newValue }
        }
    }
}
