import Foundation
import AVFoundation
import VideoToolbox

/// Camera-side media path shared by the real camera and the synthetic/file sources of `court-probe`.
///
/// A capture source calls `begin`, `submit` and `end` on `queue` (its serial capture queue).
/// Per frame the pipeline does constant-time work only: hand the frame to the analysis sink
/// (which copies what it needs), encode it at 8 Mbps while recording, and every 4th frame offer it
/// to the low-resolution preview lane, which scales and encodes on its own queue with at most one
/// frame in flight. Nothing here holds capture buffers beyond that one preview frame.
public final class CameraMediaPipeline: @unchecked Sendable {
    public struct Recording: Sendable {
        public let url: URL
        public let frames: Int
        public let duration: Double
        public let firstPTS: Double
        public let streamID: UUID
        public let owner: UUID?
    }
    public struct Counters: Sendable {
        public var delivered: UInt64 = 0
        public var captureDrops: UInt64 = 0
        /// Capture clock of the latest dropped frame, so warnings can stay recent.
        public var lastCaptureDropPTS: Double?
        public var encoded: UInt64 = 0
        public var recordedFrames = 0
        public var recordingSeconds: Double?
        public var previewSent: UInt64 = 0
        public var previewDropped: UInt64 = 0
        public var latestPTS: Double?
        public var fps = 0
        public var streamID: UUID?
        public var recording = false
        public var saving = false
    }
    public static let previewWidth = 640, previewHeight = 360, previewStride = 4

    public let queue: DispatchQueue
    /// Analysis sink, on `queue`. Must return promptly and must not retain the buffer.
    public var onFrame: ((CVPixelBuffer, Double, UUID) -> Void)?
    /// Preview packet ready, on the preview queue; return false when it could not be sent.
    public var onPreview: ((StreamPacket) -> Bool)?
    /// Capture run started (stream ID) or ended (nil), on `queue`.
    public var onCapture: ((UUID?) -> Void)?
    /// Every finished recording, on `queue`.
    public var onRecording: ((Result<Recording, Error>) -> Void)?
    public var onError: ((String) -> Void)?

    private let previewQueue = DispatchQueue(label: "court.camera.preview", qos: .utility)
    private let pending = DispatchGroup()
    private let lock = NSLock()
    private var counters = Counters()
    private var width = 0, height = 0, fps = 60
    private var running = false
    private struct ActiveRecording {
        let recorder: MovieRecorder
        let encoder: H264Encoder
        let owner: UUID?
        let stream: UUID
    }
    private var active: ActiveRecording?
    /// A recording requested before the first frame of the capture run; starts on `begin`.
    private var requested: (directory: URL, prefix: String, owner: UUID?)?
    private var recordingFirstPTS: Double?
    private var finishing = 0
    private var generation = UUID()
    // Preview lane state. `previewEnabled`/`previewBusy` are guarded by `lock`.
    private var previewEnabled = false
    private var previewBusy = false
    private var previewTransfer: VTPixelTransferSession?
    private var previewPool: CVPixelBufferPool?
    private var previewEncoder: H264Encoder?
    private var previewNeedsKeyframe = true
    private var frameIndex: UInt64 = 0
    /// Source frames per preview frame: 4 (15 fps) normally, 60 (1 fps) under light load shedding.
    private var previewEvery: UInt64 = UInt64(previewStride)
    // Live clip buffer (Phase 3): encoded frames of the latest recording, guarded by `ringLock`.
    // It belongs to one recorder, stays readable after that recording stops (so a request that
    // arrives before the session lists the finished file still finds it) and is replaced when the
    // next recording starts. It holds compressed samples only, never capture buffers.
    private struct RingSample { let sample: CMSampleBuffer; let pts: Double; let sync: Bool }
    private let ringLock = NSLock()
    private var ring: [RingSample] = []
    private var ringHead = 0
    private var ringSyncs: [Int] = []
    private var ringSyncHead = 0
    private weak var ringRecorder: MovieRecorder?
    private var ringStream: UUID?
    private var ringClosed = false
    /// Source PTS of the recording's first frame (the first sample the buffer took).
    private var ringFirstPTS = 0.0
    /// Seconds of the latest recording kept for live clips; set before capture starts.
    public var liveClipSeconds = ClipExport.liveWindowSeconds

    public init(queue: DispatchQueue) { self.queue = queue }

    public var currentCounters: Counters { lock.lock(); defer { lock.unlock() }; return counters }

    // MARK: Capture source side (on `queue`)

    /// Starts a capture run; returns its stream ID (also the analysis and recording stream).
    @discardableResult public func begin(width: Int, height: Int, fps: Int) -> UUID {
        dispatchPrecondition(condition: .onQueue(queue))
        if running { end() }
        let stream = UUID()
        self.width = width; self.height = height; self.fps = fps
        running = true; frameIndex = 0; generation = UUID()
        lock.lock()
        counters.delivered = 0; counters.captureDrops = 0; counters.lastCaptureDropPTS = nil; counters.encoded = 0
        counters.latestPTS = nil; counters.fps = fps; counters.streamID = stream
        lock.unlock()
        onCapture?(stream)
        if let requested { self.requested = nil; startRecordingOnQueue(directory: requested.directory, prefix: requested.prefix, owner: requested.owner) }
        return stream
    }

    public func submit(_ pixels: CVPixelBuffer, pts: CMTime, captureMetadata: CaptureFrameMetadata? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running, let stream = currentStream else { return }
        let seconds = pts.seconds
        onFrame?(pixels, seconds, stream)
        if let active { active.encoder.encode(pixels, pts: pts, captureDrops: currentCounters.captureDrops, captureMetadata: captureMetadata) }
        frameIndex += 1
        lock.lock()
        counters.delivered += 1; counters.latestPTS = seconds
        if let first = recordingFirstPTS, active != nil { counters.recordingSeconds = max(0, seconds - first) }
        let offerPreview = previewEnabled && !previewBusy && frameIndex % previewEvery == 0
        if offerPreview { previewBusy = true }
        lock.unlock()
        if offerPreview { preview(pixels, pts: pts) }
    }

    public func noteCaptureDrop() {
        lock.lock(); counters.captureDrops += 1; counters.lastCaptureDropPTS = counters.latestPTS; lock.unlock()
    }

    /// Capture run ended: the open recording is finished and the preview lane resets.
    public func end() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running else { return }
        running = false; requested = nil
        finishRecordingOnQueue()
        lock.lock(); counters.streamID = nil; lock.unlock()
        previewQueue.async { [self] in previewEncoder?.finish(); previewEncoder = nil; previewNeedsKeyframe = true }
        onCapture?(nil)
    }

    private var currentStream: UUID? { lock.lock(); defer { lock.unlock() }; return counters.streamID }

    // MARK: Controls (any thread)

    /// Starts an 8 Mbps recording of the capture into `directory`. Requested before the capture
    /// run's first frame, it starts with that frame.
    public func startRecording(directory: URL, prefix: String, owner: UUID?) {
        queue.async { [self] in startRecordingOnQueue(directory: directory, prefix: prefix, owner: owner) }
    }
    private func startRecordingOnQueue(directory: URL, prefix: String, owner: UUID?) {
        guard running, let stream = currentStream else { requested = (directory, prefix, owner); return }
        guard active == nil else { return }
        guard finishing == 0 else { onError?(courtText("录像未启动：上一段录像仍在保存，请稍后再继续。")); return }
        do {
            let recorder = try MovieRecorder(directory: directory, prefix: prefix)
            let encoder = try H264Encoder(width: width, height: height, fps: fps, streamID: stream)
            // Frames hold their own recorder, so samples drained after stop still reach the file
            // that is closing, never a newer one.
            encoder.onFrame = { [weak self, recorder] frame in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        try recorder.append(frame.sample, header: frame.packet.header)
                        self.keepForClips(frame.sample, sync: frame.packet.header.keyframe == true, recorder: recorder)
                        guard self.active?.recorder === recorder else { return }
                        self.lock.lock(); self.counters.encoded += 1; self.counters.recordedFrames = recorder.frames; self.lock.unlock()
                        if self.recordingFirstPTS == nil { self.recordingFirstPTS = recorder.firstPTS }
                    } catch {
                        if self.active?.recorder === recorder { self.finishRecordingOnQueue(failure: error) }
                    }
                }
            }
            encoder.onError = { [weak self, recorder] message in
                self?.queue.async { [weak self] in
                    guard let self, self.active?.recorder === recorder else { return }
                    self.finishRecordingOnQueue(failure: CourtError.message(message))
                }
            }
            active = ActiveRecording(recorder: recorder, encoder: encoder, owner: owner, stream: stream)
            recordingFirstPTS = nil
            ringLock.lock()
            ring = []; ringHead = 0; ringSyncs = []; ringSyncHead = 0
            ringRecorder = recorder; ringStream = stream; ringClosed = false
            ringLock.unlock()
            lock.lock(); counters.recording = true; counters.recordedFrames = 0; counters.recordingSeconds = 0; lock.unlock()
        } catch { onError?(error.localizedDescription) }
    }

    /// Finishes the open recording; `completion` runs on `queue` after every file is closed.
    public func stopRecording(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            requested = nil
            finishRecordingOnQueue()
            pending.notify(queue: queue) { completion?() }
        }
    }

    public func setPreview(_ enabled: Bool) {
        lock.lock(); let changed = previewEnabled != enabled; previewEnabled = enabled; lock.unlock()
        guard changed, !enabled else { return }
        previewQueue.async { [self] in previewEncoder?.finish(); previewEncoder = nil; previewNeedsKeyframe = true }
    }
    public var isPreviewing: Bool { lock.lock(); defer { lock.unlock() }; return previewEnabled }
    /// Preview rate in source frames per preview frame (minimum 1).
    public func setPreviewEvery(_ frames: Int) { lock.lock(); previewEvery = UInt64(max(1, frames)); lock.unlock() }

    // MARK: Live clips (Phase 3)

    /// Encoded frames of the latest recording that cover a clip window.
    public struct LiveClip: @unchecked Sendable {
        /// Source PTS of the recording's first frame and of the oldest/newest frame still in memory.
        public let recordingFirstPTS: Double
        public let oldestPTS: Double
        public let latestPTS: Double
        /// The recording has stopped; no newer frames will arrive.
        public let closed: Bool
        /// From the last keyframe at or before `from` through `to`; empty when not in memory.
        public let samples: [CMSampleBuffer]
    }

    /// The latest recording's frames for the source PTS window `from`…`to` of `stream`, or nil when
    /// that recording is of another stream or the window ends before it began. Any thread.
    public func liveClip(stream: UUID, from start: Double, to end: Double) -> LiveClip? {
        ringLock.lock()
        guard ringStream == stream, ringHead < ring.count else { ringLock.unlock(); return nil }
        let held = ring[ringHead...].map { $0.sample }
        let oldest = ring[ringHead].pts, latest = ring[ring.count - 1].pts, closed = ringClosed, firstPTS = ringFirstPTS
        ringLock.unlock()
        guard end > firstPTS else { return nil }
        // A window that begins before the recording starts at its first frame.
        let from = max(start, firstPTS)
        let samples = from + 0.05 >= oldest ? ClipExport.select(held, from: from, to: end) : []
        return LiveClip(recordingFirstPTS: firstPTS, oldestPTS: oldest, latestPTS: latest, closed: closed, samples: samples)
    }

    /// On `queue`, after the sample reached `recorder`'s file. Constant time per frame.
    private func keepForClips(_ sample: CMSampleBuffer, sync: Bool, recorder: MovieRecorder) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        ringLock.lock(); defer { ringLock.unlock() }
        guard ringRecorder === recorder, sync || ringHead < ring.count else { return }
        if ring.isEmpty { ringFirstPTS = pts }
        if sync { ringSyncs.append(ring.count) }
        ring.append(RingSample(sample: sample, pts: pts, sync: sync))
        // Keep the head on a keyframe: move it to the newest keyframe old enough to drop what precedes it.
        let cutoff = pts - liveClipSeconds
        while ringSyncHead + 1 < ringSyncs.count, ring[ringSyncs[ringSyncHead + 1]].pts <= cutoff {
            ringSyncHead += 1; ringHead = ringSyncs[ringSyncHead]
        }
        if ringHead >= 1_200 {
            let drop = ringHead
            ring.removeFirst(drop); ringHead = 0
            ringSyncs = ringSyncs[ringSyncHead...].map { $0 - drop }; ringSyncHead = 0
        }
    }

    // MARK: Recording internals (on `queue`)

    private func finishRecordingOnQueue(failure: Error? = nil) {
        guard let active else { return }
        self.active = nil
        // finish() drains VideoToolbox synchronously; its callbacks enqueue before the barrier below.
        active.encoder.finish()
        let recorder = active.recorder, owner = active.owner, stream = active.stream
        finishing += 1; pending.enter()
        lock.lock(); counters.recording = false; counters.saving = true; lock.unlock()
        queue.async { [self] in
            let firstPTS = recorder.firstPTS ?? 0
            recorder.finish { [self] result in
                queue.async { [self] in
                    ringLock.lock(); if ringRecorder === recorder { ringClosed = true }; ringLock.unlock()
                    finishing -= 1
                    lock.lock(); counters.saving = finishing > 0; counters.recordingSeconds = nil; lock.unlock()
                    let mapped: Result<Recording, Error> = failure.map { .failure($0) } ?? result.map {
                        Recording(url: $0.url, frames: $0.frames, duration: $0.duration, firstPTS: firstPTS, streamID: stream, owner: owner)
                    }
                    onRecording?(mapped)
                    pending.leave()
                }
            }
        }
    }

    // MARK: Preview lane

    private func preview(_ source: CVPixelBuffer, pts: CMTime) {
        let token = generation
        previewQueue.async { [self] in
            defer { lock.lock(); previewBusy = false; lock.unlock() }
            guard token == generation, isPreviewing else { return }
            do {
                let scaled = try scale(source)
                if previewEncoder == nil {
                    let encoder = try H264Encoder(width: Self.previewWidth, height: Self.previewHeight, fps: 60 / Self.previewStride,
                                                  bitrate: 900_000, kind: "preview", keyframeInterval: 2)
                    encoder.onFrame = { [weak self] frame in self?.previewQueue.async { self?.deliverPreview(frame) } }
                    previewEncoder = encoder; previewNeedsKeyframe = true
                }
                previewEncoder?.encode(scaled, pts: pts, forceKeyframe: previewNeedsKeyframe)
                previewNeedsKeyframe = false
            } catch {
                lock.lock(); counters.previewDropped += 1; lock.unlock()
            }
        }
    }
    private func deliverPreview(_ frame: EncodedFrame) {
        let sent = onPreview?(frame.packet) ?? false
        lock.lock()
        if sent { counters.previewSent += 1 } else { counters.previewDropped += 1 }
        lock.unlock()
        // A dropped delta frame breaks the decoder's chain until the next keyframe.
        if !sent { previewNeedsKeyframe = true }
    }
    private func scale(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        if previewTransfer == nil {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr, let session else {
                throw CourtError.message(courtText("无法创建预览缩放会话。"))
            }
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            previewTransfer = session
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: Self.previewWidth, kCVPixelBufferHeightKey: Self.previewHeight,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                          attributes as CFDictionary, &previewPool) == kCVReturnSuccess else {
                throw CourtError.message(courtText("无法创建预览缓冲池。"))
            }
        }
        var output: CVPixelBuffer?
        guard let previewPool, let previewTransfer,
              CVPixelBufferPoolCreatePixelBuffer(nil, previewPool, &output) == kCVReturnSuccess, let output,
              VTPixelTransferSessionTransferImage(previewTransfer, from: source, to: output) == noErr else {
            throw CourtError.message(courtText("预览缩放失败。"))
        }
        return output
    }
}
