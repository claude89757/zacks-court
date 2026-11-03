import Foundation
import AVFoundation

/// Analyses a video someone picked (Photos or Files) the way the camera analyses its capture, so
/// people away from a court can try the analysis. The frames go through the camera's own
/// `CameraMediaPipeline` and `CameraSessionController` with the in-house live lane; the result is a
/// normal record in the sessions folder (History, filters, shot playback, clips).
///
/// The pipeline re-encodes the frames into the record's recording, as the camera does; the picked
/// file itself is never copied or kept. Frames are sent as fast as the analysis takes them (no frame
/// is dropped for being late), so the rows do not depend on how fast the device is.
public enum VideoImport {
    /// What the live lane needs: about 60 frames/s (it counts frames as 1/60 s), and a landscape 16:9
    /// picture at least 720 lines high (scaled to the camera's 1920×1080, which the automatic court
    /// finder expects).
    public static let frameRates: ClosedRange<Double> = 59...61
    public static let minimumHeight = 720.0
    public static let minimumSeconds = 3.0
    public static let maximumSeconds = 600.0
    /// `capturedOn` of imported records: they did not come from a live camera.
    public static let device = "导入的视频（非实时机位）"

    public struct Info: Sendable, Equatable {
        public var filename: String
        public var duration: Double
        /// Upright picture size (track size with its rotation applied).
        public var width: Int, height: Int
        public var frameRate: Double
        public init(filename: String, duration: Double, width: Int, height: Int, frameRate: Double) {
            self.filename = filename; self.duration = duration; self.width = width; self.height = height; self.frameRate = frameRate
        }
        /// One line for the picker page: 「1920×1080 · 60 帧/秒 · 0:42」.
        public var summary: String {
            let seconds = Int(duration.rounded())
            return "\(width)×\(height) · \(String(format: "%.0f", frameRate)) 帧/秒 · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
        }
    }

    /// Accepts or rejects a video by the rules above. The message says why, in words a user can act on.
    public static func check(filename: String, duration: Double, width: Double, height: Double, frameRate: Double) throws -> Info {
        guard duration.isFinite, duration > 0, width.isFinite, height.isFinite, width > 0, height > 0, frameRate.isFinite, frameRate > 0 else {
            throw CourtError.message("读不出这段视频的时长、尺寸或帧率，请换一段视频。")
        }
        guard width > height else {
            throw CourtError.message("需要横屏拍摄的视频（像机位那样横着拍整片球场），这段是竖屏。")
        }
        let aspect = width / height
        guard abs(aspect - 16.0 / 9.0) < 0.03 else {
            throw CourtError.message("需要 16:9 的横屏视频（例如 1920×1080），这段是 \(Int(width))×\(Int(height))。")
        }
        guard height >= minimumHeight else {
            throw CourtError.message("画面太小：需要 720p（1280×720）或更清晰的视频，这段是 \(Int(width))×\(Int(height))。")
        }
        guard frameRates.contains(frameRate) else {
            let rate = String(format: "%.0f", frameRate)
            let hint = frameRate > frameRates.upperBound ? "慢动作或高帧率视频请先导出为 60 帧/秒的常速视频。" : "请用 60 帧/秒拍摄（iPhone：设置 › 相机 › 录制视频 › 1080p 60 fps）。"
            throw CourtError.message("需要 60 帧/秒的视频，这段是 \(rate) 帧/秒。" + hint)
        }
        guard duration >= minimumSeconds else { throw CourtError.message("视频太短：至少需要 \(Int(minimumSeconds)) 秒。") }
        guard duration <= maximumSeconds else {
            throw CourtError.message("视频太长：一次最多分析 \(Int(maximumSeconds / 60)) 分钟，请先剪短再导入。")
        }
        return Info(filename: filename, duration: duration, width: Int(width.rounded()), height: Int(height.rounded()), frameRate: frameRate)
    }

    /// Reads the first video track and applies `check`.
    public static func inspect(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .video) }
        catch { throw CourtError.message("无法读取这段视频：\(error.localizedDescription)") }
        guard let track = tracks.first else { throw CourtError.message("这个文件里没有视频画面。") }
        let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let upright = CGRect(origin: .zero, size: size).applying(transform)
        return try check(filename: url.lastPathComponent, duration: duration, width: abs(upright.width), height: abs(upright.height),
                         frameRate: Double(rate))
    }

    /// Default title of an imported record: 「导入 · 文件名」 without the extension.
    public static func title(for filename: String) -> String {
        let name = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return "导入 · " + String((name.isEmpty ? "视频" : name).prefix(80))
    }
}

/// One import run. Create, `run`, then drop it; cancel by cancelling the calling task, which removes
/// the unfinished record and its recording.
@MainActor public final class VideoImportRun {
    public enum Stage: Sendable, Equatable { case loadingModel, analyzing, saving }
    public struct Progress: Sendable, Equatable {
        public var stage: Stage
        /// Source seconds the analysis has taken in, and the video's length.
        public var analyzedSeconds: Double, totalSeconds: Double
        public var shots: Int
        public var fraction: Double { totalSeconds > 0 ? min(1, max(0, analyzedSeconds / totalSeconds)) : 0 }
        public init(stage: Stage, analyzedSeconds: Double, totalSeconds: Double, shots: Int) {
            self.stage = stage; self.analyzedSeconds = analyzedSeconds; self.totalSeconds = totalSeconds; self.shots = shots
        }
    }

    private let storageDirectory: URL
    private let live: IndependentLiveConfiguration
    /// Frames the analysis may hold before the file waits; well below the lane's overflow limit.
    private let pendingLimit: Int

    public init(storageDirectory: URL, live: IndependentLiveConfiguration, pendingLimit: Int = 16) {
        self.storageDirectory = storageDirectory; self.live = live; self.pendingLimit = max(1, pendingLimit)
    }

    public func run(video: URL, info: VideoImport.Info, title: String,
                    progress: @escaping @MainActor (Progress) -> Void) async throws -> CourtSession {
        let pipeline = CameraMediaPipeline(queue: DispatchQueue(label: "court.video-import", qos: .userInitiated))
        let analyzer = CameraSideAnalyzer(configuration: nil, independent: live)
        let controller = CameraSessionController(storageDirectory: storageDirectory, configuration: nil,
                                                 identity: CameraIdentity(device: VideoImport.device, hardware: "video-import",
                                                                          app: CameraIdentity.appVersion),
                                                 pipeline: pipeline, analyzer: analyzer)
        // The thermal policy would quietly thin out the analysis (or pause the record); here the
        // frames simply wait for the analysis instead.
        controller.appliesLoadPolicy = false
        var report = Progress(stage: .loadingModel, analyzedSeconds: 0, totalSeconds: info.duration, shots: 0)
        progress(report)

        func discard() async {
            if controller.hasOpenSession || controller.isBusy {
                try? await Self.wait(seconds: 30) { !controller.isBusy }
                await controller.finish()
                // The closed recording joins the record a moment later; wait for it so the delete
                // below also removes it (and the record is not saved again afterwards).
                if pipeline.currentCounters.encoded > 0 {
                    try? await Self.wait(seconds: 20) { controller.session.map { !$0.recordings.isEmpty } ?? true }
                }
            }
            let session = controller.session
            await controller.shutdown()
            if let session, let store = try? SessionStore(directory: storageDirectory) { try? store.delete(session) }
        }

        // Model loading (and its checksum) runs on the analysis worker.
        do {
            try await Self.wait(seconds: 120, cancellable: true) { analyzer.currentMetrics.ready }
        } catch { await discard(); throw error }
        if let failure = analyzer.currentMetrics.loadError {
            await discard()
            throw CourtError.message("自研模型未能载入：\(failure)")
        }

        // The record opens before the first frame, so the recording starts with it.
        controller.startSession(title: title)
        guard controller.session != nil else {
            let reason = controller.error ?? "无法新建记录。"
            await discard(); throw CourtError.message(reason)
        }

        let source: FileFrameSource
        do { source = try await FileFrameSource(pipeline: pipeline, video: video, outputSize: (1920, 1080)) }
        catch { await discard(); throw error }
        let limit = pendingLimit
        source.isReady = { analyzer.currentMetrics.pendingFrames < limit }
        let finished = ImportFlag()
        source.onFinished = { failure in finished.set(failure) }
        source.start()

        let fps = max(1, source.nominalFPS)
        report.stage = .analyzing
        while !finished.isSet {
            if Task.isCancelled {
                source.stop()
                try? await Self.wait(seconds: 10) { finished.isSet }
                await discard()
                throw CancellationError()
            }
            let metrics = analyzer.currentMetrics
            report.analyzedSeconds = min(info.duration, Double(metrics.processedFrames) / fps)
            report.shots = controller.session?.tennisEvents?.count ?? controller.dashboardEvents.count
            progress(report)
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let failure = finished.failure {
            await discard()
            throw CourtError.message("视频读取中断：\(failure)")
        }

        // End of file ends the capture; the controller pauses the record, saves the recording and
        // seals the analysis, then the record is finished like any other.
        report.stage = .saving; report.analyzedSeconds = info.duration
        progress(report)
        do {
            try await Self.wait(seconds: 120) { controller.session?.state != .active && !controller.isBusy }
        } catch { await discard(); throw CourtError.message("分析结果保存超时，请重试。") }
        await controller.finish()
        // The recording reaches the record a moment after it is closed.
        try? await Self.wait(seconds: 20) { controller.session.map { !$0.recordings.isEmpty } ?? true }
        guard var session = controller.session, session.state == .completed else {
            let reason = controller.error ?? "记录未能保存。"
            await discard(); throw CourtError.message(reason)
        }
        report.shots = session.tennisEvents?.count ?? 0
        progress(report)
        await controller.shutdown()
        // The record lasts as long as the video, however long the analysis took.
        let recorded = session.recordings.map(\.duration).reduce(0, +)
        session.setImportedDuration(recorded > 0 ? recorded : info.duration)
        try? SessionStore(directory: storageDirectory).save(session)
        return session
    }

    /// Polls `condition` every 50 ms; throws on timeout (and on cancellation when `cancellable`).
    private static func wait(seconds: Double, cancellable: Bool = false, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if cancellable, Task.isCancelled { throw CancellationError() }
            guard Date() < deadline else { throw CourtError.message("等待超时。") }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

private final class ImportFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false; private var message: String?
    func set(_ failure: String?) { lock.lock(); if !done { done = true; message = failure }; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return message }
}
