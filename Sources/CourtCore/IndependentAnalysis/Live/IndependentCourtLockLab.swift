import CoreVideo
import Foundation

/// Offline evaluation of automatic court locking (`court-analyze court-lock`). Frames go through the
/// same `IndependentLiveCourt` as on the camera; each frame comes with the camera that truly took it
/// (known because the evaluation warps a steady video by known camera rotations), so every second can
/// be counted as no camera, a camera within `tolerancePixels`, or a wrong one. A solve is picked up
/// only after the stream has advanced by its measured seconds times `latencyScale`, and no samples are
/// taken meanwhile, as on the phone. "Right" means agreeing with the steady solve of the same video,
/// not physical truth.
public final class IndependentCourtLockLab {
    /// Defaults are the App's; `before20261104()` is the search as it was before the motion check.
    public struct Settings: Codable, Sendable {
        public var sampleInterval: Double, frames: Int, firstAttemptFrames: Int, retryFrames: Int
        public var latencyScale = 1.0
        public var tolerancePixels = 6.0
        /// Camera motion check threshold in pixels (nil: off).
        public var motionPixels: Double?
        public var motionLookback: Double
        public var shakePixels: Double, trackPixels: Double
        public var stillTrackInterval: Double?
        public var movingInterval: Double?
        public var predictTracking = true
        /// The court keypoint model used for full solves, by file name (nil: lines only).
        public var keypointModel: String?
        public init() {
            let o = IndependentLiveCourt.Options()
            sampleInterval = o.sampleInterval; frames = o.frames; firstAttemptFrames = o.firstAttemptFrames
            retryFrames = o.retryFrames; motionPixels = o.motionPixels; motionLookback = o.motionLookback
            shakePixels = o.shakePixels; trackPixels = o.trackPixels; stillTrackInterval = o.stillTrackInterval
            movingInterval = o.movingInterval; predictTracking = o.predictTracking
        }
        public static func before20261104() -> Self {
            var s = Self(); s.firstAttemptFrames = 9; s.retryFrames = 4; s.motionPixels = nil; s.stillTrackInterval = nil
            s.movingInterval = nil; s.predictTracking = false; return s
        }
    }

    public struct Event: Codable, Sendable {
        public let pts: Double, kind: String, errorPixels: Double, still: Bool
        /// The camera in use after the change (nil once lost), so a run can be drawn back onto the video.
        public var camera: IndependentPinholeCamera?
    }

    /// A stretch of the stream where the camera was either moving or still.
    public struct Phase: Codable, Sendable {
        public let start: Double, still: Bool
        public var end: Double
        /// First time a right camera was in use, if ever.
        public var firstRight: Double?
        public var rightSeconds = 0.0, wrongSeconds = 0.0, noneSeconds = 0.0
    }

    public struct Report: Codable, Sendable {
        public let settings: Settings
        public let events: [Event]
        public let phases: [Phase]
        public let launches: Int, solves: Int, samples: Int, solveSeconds: Double, maxSolveSeconds: Double
        /// [pts, measured displacement, true displacement over the same lookback] per measured frame.
        public let motion: [[Double]]
        /// Mean wall-clock milliseconds of one thumbnail plus one comparison (this machine).
        public let motionMilliseconds: Double
    }

    public let settings: Settings
    private let court: IndependentLiveCourt
    private var events: [Event] = []
    private var phases: [Phase] = []
    private var previous: (pts: Double, error: Double?)?
    private var maxSolve = 0.0
    private var truths: [(pts: Double, camera: IndependentPinholeCamera)] = []
    private var motion: [[Double]] = []
    private var motionCost = (seconds: 0.0, count: 0)
    private var lastThumbnail: IndependentLiveCourt.Thumbnail?

    public init(settings: Settings = Settings(), keypointModel: IndependentCourtKeypointModel? = nil) {
        self.settings = settings
        var o = IndependentLiveCourt.Options()
        o.sampleInterval = settings.sampleInterval; o.frames = settings.frames
        o.firstAttemptFrames = settings.firstAttemptFrames; o.retryFrames = settings.retryFrames
        o.simulatedLatencyScale = settings.latencyScale
        o.motionPixels = settings.motionPixels; o.motionLookback = settings.motionLookback
        o.shakePixels = settings.shakePixels; o.trackPixels = settings.trackPixels
        o.stillTrackInterval = settings.stillTrackInterval; o.movingInterval = settings.movingInterval
        o.predictTracking = settings.predictTracking
        court = IndependentLiveCourt(options: o, keypointModel: keypointModel)
    }

    /// One full-resolution frame, the camera that took it, and whether that camera is still.
    public func feed(_ pixels: CVPixelBuffer, pts: Double, truth: IndependentPinholeCamera, still: Bool) {
        if let previous { account(from: previous.pts, to: pts, error: previous.error) }
        if phases.last?.still != still { phases.append(Phase(start: pts, still: still, end: pts)) }
        let launches = court.stats.launches, solves = court.stats.solves, solveSeconds = court.stats.solveSeconds
        let measured = court.lastMotion
        if settings.motionPixels != nil {
            let began = ProcessInfo.processInfo.systemUptime
            if let t = IndependentLiveCourt.thumbnail(pixels) {
                if let last = lastThumbnail { _ = IndependentLiveCourt.motion(last, t) }
                lastThumbnail = t
            }
            motionCost.seconds += ProcessInfo.processInfo.systemUptime - began; motionCost.count += 1
        }
        let change = court.offer(pixels, pts: pts)
        truths.removeAll { pts - $0.pts > settings.motionLookback + 0.05 }
        if let m = court.lastMotion, m != measured || court.lastMotion != nil, let first = truths.first {
            motion.append([pts, m, IndependentLiveCourt.distance(first.camera, truth)])
        }
        truths.append((pts, truth))
        if court.stats.solves > solves { maxSolve = max(maxSolve, court.stats.solveSeconds - solveSeconds) }
        if court.stats.launches > launches { court.drain() }
        let error = court.camera.map { IndependentLiveCourt.distance($0, truth) }
        if let change {
            let kind: String
            switch change { case .found: kind = "found"; case .moved: kind = "moved"; case .lost: kind = "lost" }
            events.append(Event(pts: pts, kind: kind, errorPixels: error ?? .nan, still: still, camera: court.camera))
        }
        previous = (pts, error)
    }

    private func account(from a: Double, to b: Double, error: Double?) {
        guard !phases.isEmpty, b > a else { return }
        let dt = b - a
        var p = phases[phases.count - 1]
        if let error {
            if error <= settings.tolerancePixels { p.rightSeconds += dt; if p.firstRight == nil { p.firstRight = a } }
            else { p.wrongSeconds += dt }
        } else { p.noneSeconds += dt }
        p.end = b
        phases[phases.count - 1] = p
    }

    public func finish() -> Report {
        let s = court.stats
        return Report(settings: settings, events: events, phases: phases, launches: s.launches, solves: s.solves,
                      samples: s.samples, solveSeconds: s.solveSeconds, maxSolveSeconds: maxSolve, motion: motion,
                      motionMilliseconds: motionCost.count > 0 ? motionCost.seconds / Double(motionCost.count) * 1000 : 0)
    }

    /// Image positions of the court reference points; what `IndependentLiveCourt.distance` compares.
    public static func distance(_ a: IndependentPinholeCamera, _ b: IndependentPinholeCamera) -> Double {
        IndependentLiveCourt.distance(a, b)
    }
}

/// The reference camera of a steady stretch: the per-channel median of its frames, solved once.
public final class IndependentCourtMedianSolver {
    private var samples: [IndependentLiveCourt.Sample] = []
    public init() {}
    public var count: Int { samples.count }
    public func add(_ pixels: CVPixelBuffer) { if let s = IndependentLiveCourt.sample(pixels) { samples.append(s) } }
    public func solve() throws -> IndependentCourtCalibration {
        IndependentCourtCalibrator.calibrate(try IndependentLiveCourt.median(samples))
    }
}

extension IndependentCourtLockLab {
    /// One frame checked against a camera, as the live court's `fits` does on a median.
    public struct FrameFit: Codable, Sendable {
        public let fits: Bool, lines: Int, nearTransverse: Int, rms: Double?, movedPixels: Double?, seconds: Double
        public var refined: IndependentPinholeCamera? = nil
    }

    public static func fit(_ pixels: CVPixelBuffer, camera: IndependentPinholeCamera, movedPixels: Double) -> FrameFit? {
        let began = ProcessInfo.processInfo.systemUptime
        guard let sample = IndependentLiveCourt.sample(pixels), let image = try? IndependentLiveCourt.median([sample]) else { return nil }
        guard let refined = IndependentCourtCalibrator.refine(image, start: IndependentCourtCalibrator.parameters(camera)) else {
            return FrameFit(fits: false, lines: 0, nearTransverse: 0, rms: nil, movedPixels: nil, seconds: ProcessInfo.processInfo.systemUptime - began)
        }
        let used = refined.linesUsed
        let rms = used.isEmpty ? nil : (used.compactMap { refined.perLineRMS[$0.rawValue] }.map { $0 * $0 }.reduce(0, +) / Double(used.count)).squareRoot()
        let fits = IndependentLiveCourt.fits(camera, image, movedPixels: movedPixels)
        return FrameFit(fits: fits, lines: used.count, nearTransverse: used.filter(\.isNearTransverse).count, rms: rms,
                        movedPixels: IndependentLiveCourt.distance(refined.camera, camera), seconds: ProcessInfo.processInfo.systemUptime - began,
                        refined: refined.camera)
    }
}
