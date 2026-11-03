import Foundation
import AVFoundation
import CoreImage

/// An explicitly labelled replay source for the camera media pipeline: decodes a local video,
/// keeps its original source PTS and feeds frames on a wall-clock schedule, as a camera would.
/// It is prerecorded validation input, never a live camera.
public final class FileFrameSource: @unchecked Sendable {
    public let pipeline: CameraMediaPipeline
    public let duration: Double
    public let nominalFPS: Double
    public var onFinished: ((String?) -> Void)?
    /// When set, frames go out as fast as this says the receiver is ready (checked on the pipeline
    /// queue) instead of on the source clock. Video import uses it so the analysis sees every frame
    /// however fast the device is; set it before `start()`.
    public var isReady: (() -> Bool)?
    public private(set) var readFrames: UInt64 = 0
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let transform: CGAffineTransform
    private let width: Int, height: Int
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var firstPTS: Double?, previousPTS: Double?
    private var wallStart: DispatchTime?
    private var ended = false

    /// `outputSize` scales every frame to exactly that size (video import: 1920×1080); otherwise the
    /// upright frame is scaled down to fit 1920×1080, keeping its shape.
    public init(pipeline: CameraMediaPipeline, video: URL, outputSize: (width: Int, height: Int)? = nil) async throws {
        self.pipeline = pipeline
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CourtError.message("回放文件没有视频轨道。") }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rate = Double(try await track.load(.nominalFrameRate))
        let duration = try await asset.load(.duration).seconds
        guard rate.isFinite, rate > 0, rate <= 120, duration.isFinite, duration > 0 else { throw CourtError.message("回放视频的帧率或时长无效。") }
        let displayed = CGRect(origin: .zero, size: size).applying(transform)
        guard displayed.width.isFinite, displayed.height.isFinite, displayed.width > 0, displayed.height > 0 else { throw CourtError.message("回放视频方向或尺寸无效。") }
        if let outputSize {
            width = max(2, outputSize.width / 2 * 2); height = max(2, outputSize.height / 2 * 2)
        } else {
            let scale = min(1, 1920 / max(displayed.width, displayed.height), 1080 / min(displayed.width, displayed.height))
            width = max(2, Int(displayed.width * scale) / 2 * 2)
            height = max(2, Int(displayed.height * scale) / 2 * 2)
        }
        self.asset = asset; self.track = track; self.transform = transform
        nominalFPS = rate; self.duration = duration
    }

    public func start() {
        pipeline.queue.async { [self] in
            do {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw CourtError.message("无法建立回放视频解码器。") }
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? CourtError.message("无法读取回放视频。") }
                self.reader = reader; self.output = output
                pipeline.begin(width: width, height: height, fps: max(1, Int(nominalFPS.rounded())))
                scheduleNext()
            } catch { finish(error.localizedDescription) }
        }
    }

    public func stop() { pipeline.queue.async { [self] in finish(nil) } }

    private func scheduleNext() {
        guard !ended else { return }
        guard let sample = output?.copyNextSampleBuffer() else {
            finish(reader?.status == .completed ? nil : reader?.error?.localizedDescription ?? "回放视频读取未完成。"); return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard pts.isFinite, pts >= 0, previousPTS.map({ pts > $0 }) ?? true else { finish("回放视频源时间戳无效或未递增。"); return }
        previousPTS = pts; readFrames += 1
        if firstPTS == nil { firstPTS = pts; wallStart = .now() }
        if isReady != nil { deliverWhenReady(sample); return }
        let deadline = (wallStart ?? .now()) + max(0, pts - (firstPTS ?? pts))
        pipeline.queue.asyncAfter(deadline: deadline) { [weak self] in self?.deliver(sample) }
    }

    private func deliverWhenReady(_ sample: CMSampleBuffer) {
        guard !ended else { return }
        if isReady?() ?? true { pipeline.queue.async { [weak self] in self?.deliver(sample) }; return }
        pipeline.queue.asyncAfter(deadline: .now() + .milliseconds(3)) { [weak self] in self?.deliverWhenReady(sample) }
    }

    private func deliver(_ sample: CMSampleBuffer) {
        guard !ended else { return }
        autoreleasepool {
            guard let image = CMSampleBufferGetImageBuffer(sample), let upright = render(image) else {
                finish("回放视频缺少图像缓冲。"); return
            }
            pipeline.submit(upright, pts: CMSampleBufferGetPresentationTimeStamp(sample))
            scheduleNext()
        }
    }

    private func render(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let source = CIImage(cvPixelBuffer: input), size = source.extent.size
        let displayed = CGRect(origin: .zero, size: size).applying(transform)
        // AV track matrices use top-left coordinates, Core Image bottom-left.
        // Conjugation preserves 90°/270° preferredTransform orientation.
        let rotation = CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c, d: transform.d,
            tx: transform.c * size.height + transform.tx - displayed.minX,
            ty: displayed.height - transform.d * size.height - transform.ty + displayed.minY)
        let upright = source.transformed(by: rotation)
        let normalized = upright.transformed(by: .init(translationX: -upright.extent.minX, y: -upright.extent.minY))
        let image = normalized.transformed(by: .init(scaleX: CGFloat(width) / normalized.extent.width, y: CGFloat(height) / normalized.extent.height))
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
              let result else { return nil }
        context.render(image, to: result, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        return result
    }

    private func finish(_ failure: String?) {
        guard !ended else { return }
        ended = true; reader?.cancelReading(); reader = nil; output = nil
        pipeline.end()
        onFinished?(failure)
    }
}
