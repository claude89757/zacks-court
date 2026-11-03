#if os(macOS)
import XCTest
import AVFoundation
import CourtCore
@testable import CourtApp

final class PreviewResponsivenessTests: XCTestCase {
    @MainActor func testPreviewViewsOwnIndependentBackingLayers() {
        let pipeline = PreviewPipeline()
        let embedded = VideoHostView(pipeline: pipeline)
        let expanded = VideoHostView(pipeline: pipeline)
        XCTAssertFalse(embedded.video === expanded.video, "A CALayer can only belong to one view/window")
        XCTAssertTrue(embedded.layer === embedded.video, "AppKit must resize the actual video backing layer")
        XCTAssertTrue(expanded.layer === expanded.video)
        embedded.detach(); expanded.detach()
    }
    /// A deliberately blocked UI thread used to hold all 60-fps preview work.
    /// The real encoder and renderer must now make progress independently.
    @MainActor func testPreviewEnqueuesVideoWhileMainThreadIsOccupied() throws {
        let pipeline = PreviewPipeline()
        let layer = AVSampleBufferDisplayLayer()
        pipeline.attach(layer)
        let completed = DispatchSemaphore(value: 0)
        let failures = LockedError()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var image: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, nil, &image) == kCVReturnSuccess,
                      let image else { throw CourtError.message("Unable to make test image") }
                CVPixelBufferLockBaseAddress(image, [])
                if let bytes = CVPixelBufferGetBaseAddress(image) { memset(bytes, 0, CVPixelBufferGetDataSize(image)) }
                CVPixelBufferUnlockBaseAddress(image, [])
                let encoder = try H264Encoder(width: 640, height: 360, fps: 30)
                encoder.onFrame = { frame in pipeline.submit(frame.sample) }
                encoder.onError = { message in failures.set(message) }
                for index in 0..<6 {
                    encoder.encode(image, pts: CMTime(value: Int64(index), timescale: 30), forceKeyframe: index == 0)
                }
                encoder.finish()
                let deadline = Date().addingTimeInterval(3)
                while pipeline.enqueuedFrames == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            } catch { failures.set(error.localizedDescription) }
            completed.signal()
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertNil(failures.value)
        XCTAssertGreaterThan(pipeline.enqueuedFrames, 0, "Preview must not depend on main-thread scheduling")
        pipeline.clear()
        pipeline.detach(layer)
    }
}

private final class LockedError: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    func set(_ value: String) { lock.lock(); message = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return message }
}
#endif
