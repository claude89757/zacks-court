#if os(macOS)
import XCTest
import AVFoundation
@testable import CourtCore
@testable import CourtApp

/// Sharing from the player: readable names, a shot cut out of a local recording without
/// re-encoding, and no copies left behind. Saving to Photos needs a device and is not run here.
final class VideoExportTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("court-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); VideoExport.clearLeftovers() }

    func testShotNameSaysWhenWhichShotAndHowFast() throws {
        var session = CourtSession(title: "周六练习", startedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-03T06:22:00Z")))
        let stream = UUID()
        var serve = TennisShotEvent(streamID: stream, sourcePTS: 12, stroke: .serve, confidence: 0.9); serve.speedKPH = 151.6
        let forehand = TennisShotEvent(streamID: stream, sourcePTS: 5, stroke: .forehand, confidence: 0.8)
        session.recordTennisAnalysis(WorkspaceIntegrationTests.snapshot(stream, [serve, forehand]))
        let name = VideoExport.shotName(serve, session: session)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmm"
        XCTAssertEqual(name, "ZacksCourt-\(formatter.string(from: session.startedAt))-第2拍-发球-152kmh.mov", "Numbered by time, speed only when valid")
        XCTAssertEqual(VideoExport.shotName(forehand, session: session).hasSuffix("-第1拍-正手.mov"), true)
        XCTAssertEqual(VideoExport.shotName(forehand, session: nil), "ZacksCourt-正手.mov")
    }

    func testShotIsCutFromTheRecordingOnAKeyframe() async throws {
        let recording = root.appendingPathComponent("Court-test.mov")
        try await Self.writeMovie(recording, seconds: 6)
        let firstPTS = 100.0
        var shot = TennisShotEvent(streamID: UUID(), sourcePTS: firstPTS + 3, stroke: .backhand, confidence: 0.7)
        shot.bounce = TennisBounceEstimate(sourcePTS: firstPTS + 3.6, confidence: 0)
        let export = PlaybackExport.shot(shot, session: nil, recording: recording, firstPTS: firstPTS, duration: 6)
        let file = try await export.prepare()
        XCTAssertEqual(file.lastPathComponent, "ZacksCourt-反手.mov")
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, VideoExport.folder.standardizedFileURL)
        // 2 s before the hit to 3 s after it (the bounce + 1.5 s is earlier), from the keyframe at or before the start.
        let (frames, keyframeFirst) = try await Self.read(file)
        XCTAssertTrue(keyframeFirst)
        XCTAssertGreaterThanOrEqual(frames, 5 * 30 - 2)
        XCTAssertLessThanOrEqual(frames, 6 * 30)

        // A shot whose window is outside the recording is refused with a reason.
        let outside = PlaybackExport.shot(TennisShotEvent(streamID: UUID(), sourcePTS: firstPTS + 30, stroke: .serve, confidence: 0),
                                           session: nil, recording: recording, firstPTS: firstPTS, duration: 6)
        do { _ = try await outside.prepare(); XCTFail("No frames there") } catch {}
    }

    func testSharedFilesTakeNoSpaceAndDoNotPileUp() throws {
        let clip = root.appendingPathComponent("clip-x.mov")
        try Data(repeating: 7, count: 4096).write(to: clip)
        let first = try VideoExport.named(clip, "ZacksCourt-第1拍-正手.mov")
        XCTAssertNotEqual(first, clip)
        let inode = { (url: URL) in (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue }
        XCTAssertEqual(try inode(first), try inode(clip), "A hard link, not a copy")
        // The next export empties the folder first; the original stays.
        let second = try VideoExport.named(clip, "ZacksCourt-第2拍-反手.mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
        // A whole recording keeps its own name and is shared in place.
        let whole = PlaybackExport.recording(clip)
        XCTAssertEqual(whole.name, "clip-x.mov")
        XCTAssertEqual(try VideoExport.named(clip, whole.name), clip)
        VideoExport.clearLeftovers()
        XCTAssertFalse(FileManager.default.fileExists(atPath: VideoExport.folder.path))
    }

    /// A finished session with an 8 s synthetic recording and two shots, for checking share and
    /// save-to-Photos by hand in the simulator: COURT_EXPORT_FIXTURE=/dir writes it there; copy the
    /// files into the app's Documents/Zacks Court/Sessions.
    func testWriteSimulatorFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["COURT_EXPORT_FIXTURE"] else {
            throw XCTSkip("Set COURT_EXPORT_FIXTURE=/dir to write a session with a recording")
        }
        let store = try SessionStore(directory: URL(fileURLWithPath: path, isDirectory: true))
        let filename = "Court-20261103-090000-export.mov"
        try await Self.writeMovie(store.directory.appendingPathComponent(filename), seconds: 8)
        let stream = UUID()
        var session = CourtSession(title: "导出测试（合成画面）")
        var forehand = TennisShotEvent(streamID: stream, sourcePTS: 3, stroke: .forehand, confidence: 0.8); forehand.speedKPH = 96
        let serve = TennisShotEvent(streamID: stream, sourcePTS: 5.5, stroke: .serve, confidence: 0.8)
        session.recordTennisAnalysis(WorkspaceIntegrationTests.snapshot(stream, [forehand, serve]))
        try session.addRecording(StoredRecording(filename: filename, frames: 240, duration: 8, firstPTS: 0, streamID: stream))
        session.finish()
        try store.save(session)
    }

    /// A small H.264 movie at 30 fps with a keyframe every second and no B-frames, like the camera's recordings.
    static func writeMovie(_ url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAllowFrameReorderingKey: false],  // like the camera: no B-frames
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    static func read(_ url: URL) async throws -> (frames: Int, keyframeFirst: Bool) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); reader.startReading()
        var frames = 0, first = false
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            if frames == 0 { first = ClipExport.isSync(sample) }
            frames += 1
        }
        return (frames, first)
    }
}
#endif
