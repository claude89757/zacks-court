import Foundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo

/// Clearly labelled synthetic 1920×1080 frames at 60 fps for loopback tests and `court-probe`.
/// It drives a `CameraMediaPipeline` the way the camera does; it never produces tennis facts.
public final class SyntheticFrameSource: @unchecked Sendable {
    public let pipeline: CameraMediaPipeline
    public var onFinished: (() -> Void)?
    private let seconds: Double?
    private let startPTS: Int64
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var count: Int64 = 0
    private static let fps: Int64 = 60

    /// `seconds == nil` runs until `stop()`. Source PTS starts at `startPTS` seconds.
    public init(pipeline: CameraMediaPipeline, seconds: Double? = nil, startPTS: Int64 = 2000) {
        self.pipeline = pipeline; self.seconds = seconds; self.startPTS = startPTS
    }

    public func start() {
        pipeline.queue.async { [self] in
            guard timer == nil else { return }
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey: 1080,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attributes as CFDictionary, &pool)
            count = 0
            pipeline.begin(width: 1920, height: 1080, fps: Int(Self.fps))
            let timer = DispatchSource.makeTimerSource(queue: pipeline.queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / Self.fps)), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }

    public func stop() {
        pipeline.queue.async { [self] in
            guard let timer else { return }
            timer.cancel(); self.timer = nil
            pipeline.end()
        }
    }

    private func tick() {
        if let seconds, Double(count) >= seconds * Double(Self.fps) {
            timer?.cancel(); timer = nil; pipeline.end(); onFinished?(); return
        }
        guard let pool else { return }
        var image: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &image) == kCVReturnSuccess, let image else { pipeline.noteCaptureDrop(); return }
        draw(into: image, frame: Int(count))
        pipeline.submit(image, pts: CMTime(value: startPTS * Self.fps + count, timescale: CMTimeScale(Self.fps)))
        count += 1
    }

    private func draw(into image: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(image), width: 1920, height: 1080, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(image), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.setFillColor(CGColor(red: 0.04, green: 0.13, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        context.setFillColor(CGColor(red: 0.75, green: 0.94, blue: 0.33, alpha: 1))
        let x = 120 + (frame * 11) % 1680
        context.fillEllipse(in: CGRect(x: x, y: 400 + Int(150 * sin(Double(frame) / 15)), width: 70, height: 70))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 38, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SYNTHETIC VIDEO / 1080p60 / FRAME \(frame)", attributes: attributes))
        context.textPosition = CGPoint(x: 80, y: 950); CTLineDraw(line, context)
    }
}
