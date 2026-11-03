import Accelerate
import CoreVideo
import Foundation
import simd

/// Finds the court automatically while recording (docs/model-replacement-design.md §2.1, §3.4).
///
/// Full-resolution analysis-owned copies are sampled every `sampleInterval` seconds and kept as NV12
/// planes (3.1 MB each, half of an RGB copy). Their per-channel median is built in BGR, band by band,
/// like the prototype's `np.median` of decoded frames, and solved by `IndependentCourtCalibrator` on a
/// utility queue, so ball batches never wait; the result is picked up on the analysis queue with the
/// next frame.
/// - Motion: every full frame gives a 240×135 thumbnail that is compared with the one a second earlier.
///   Up to `motionPixels` the picture is still; up to `shakePixels` it drifts (a hand-held or loosely
///   propped phone); above that it shakes (the phone is being mounted, knocked or handled). While it
///   shakes no samples are kept, a solve in flight is ignored and a found camera is dropped, so a median
///   never mixes two poses and a knocked mount is not used with its old court.
/// - Searching: the first solve once `firstAttemptFrames` still samples are in (about 3 s), then after
///   every `retryFrames` new ones, over the last `frames` samples (the prototype used 25 over 20 s). A
///   sample that drifted from the window's first one restarts the window. While the picture drifts a
///   still window never comes, so single samples are solved (same gates).
/// - Tracking: a found camera is refined on single frames, every `sampleInterval` while the picture
///   drifts and every `stillTrackInterval` while it is still. A refinement that still fits the lines and
///   moved at most `trackPixels` replaces the camera when it moved more than `movedPixels`. While
///   drifting, `dropAfterMisfits` misses in a row drop the camera; while still a miss only brings the
///   re-check forward.
/// - Re-check: every `recheckInterval` seconds a fresh median of `recheckFrames` samples is solved
///   from scratch, so a camera that tracking led astray is replaced. A refusal keeps the current camera
///   if it still fits the lines; after `dropAfterMisfits` refusals in a row where it no longer fits, the
///   camera is dropped and the search starts again.
/// Calibration only: speeds and landing points stay model estimates.
final class IndependentLiveCourt {
    struct Options: Sendable {
        var sampleInterval = 0.8
        var frames = 25
        var firstAttemptFrames = 4
        var retryFrames = 2
        var recheckInterval = 60.0
        var recheckFrames = 15
        var movedPixels = 3.0
        var dropAfterMisfits = 2
        /// Offline evaluation only: a finished solve is picked up once the stream has advanced by its
        /// wall-clock seconds times this factor, as if it had run beside the stream. Nil in the App.
        var simulatedLatencyScale: Double?
        /// Camera motion check (nil: off). A 240×135 thumbnail of every full frame is compared with
        /// the one `motionLookback` seconds earlier; more than `motionPixels` of apparent displacement
        /// means the picture drifts (tracked, see `trackPixels`), more than `shakePixels` that it shakes.
        /// 4 px: a still camera measured at most 3.4 px over about 30 minutes of seven match videos, a
        /// real 8-16 px move at least 4.5 px nine times in ten (`court-analyze court-lock`, 2026-11-04).
        var motionPixels: Double? = 4
        /// Above this the phone is being knocked or handled, not drifting: the samples are dropped, a solve
        /// in flight is ignored and a found camera is dropped (unknown stays unknown) until the court is found
        /// again. 15 px: a hand-held phone filming a screen measured 3-7 px of drift and 18-27 px when
        /// handled or at clip cuts (iPhone recording, 2026-11-04).
        var shakePixels = 15.0
        /// A drifting mount is followed: every `sampleInterval` the current camera is refined on one frame
        /// and kept if it still fits and moved at most this much; `dropAfterMisfits` misses in a row drop it.
        var trackPixels = 25.0
        /// A slow drift can stay under `motionPixels`: while still, the found camera is also refined on one
        /// frame this often (nil: off). A miss here does not drop it; it brings the median re-check forward.
        var stillTrackInterval: Double? = 0.8
        var motionLookback = 1.0
        init() {}
    }

    /// What a finished solve changed, for the engine.
    enum Change: Equatable {
        /// First camera (or found again after it was lost).
        case found(IndependentPinholeCamera)
        /// The mount moved: a new camera replaces the current one.
        case moved(IndependentPinholeCamera)
        /// The current camera no longer fits and nothing replaced it.
        case lost
    }

    struct Stats: Sendable {
        var launches = 0, solves = 0, solveSeconds = 0.0, samples = 0, found = 0, moved = 0, lost = 0
    }

    static let width = IndependentCourtCalibrator.width, height = IndependentCourtCalibrator.height

    let options: Options
    private(set) var camera: IndependentPinholeCamera?
    /// The solve that gave `camera`, or the last refused one while searching.
    private(set) var latest: IndependentCourtCalibration?
    private(set) var stats = Stats()
    private var samples: [Sample] = []
    private var lastSample = -Double.infinity
    private var lastTrack = -Double.infinity
    private var windowRestarted = false
    private var newSamples = 0
    private var nextRecheck = Double.infinity
    private var misfits = 0
    private(set) var inFlight = false
    private var launchedAt = 0.0
    enum Motion: Sendable { case still, drifting, shaking }
    /// How much the picture moved over the last `motionLookback` seconds (motion check on).
    private(set) var motion = Motion.still
    var moving: Bool { motion != .still }
    /// Last measured displacement in full-resolution pixels, for evaluation.
    private(set) var lastMotion: Double?
    private var thumbnails: [(pts: Double, image: Thumbnail)] = []
    private var anchor: Thumbnail?
    private var movedSinceLaunch = false
    private let mailbox = Mailbox()
    private let queue = DispatchQueue(label: "court.independent.court-calibration", qos: .utility)

    init(options: Options = Options(), camera: IndependentPinholeCamera? = nil) {
        self.options = options
        self.camera = camera
        if camera != nil { nextRecheck = -.infinity }      // a camera given at start is verified first
    }

    var searching: Bool { camera == nil }

    /// A camera set from outside (fixed): kept, and re-checked from `pts` on.
    func adopt(_ camera: IndependentPinholeCamera?, pts: Double) {
        self.camera = camera; latest = nil; misfits = 0
        samples.removeAll(); newSamples = 0; resetMotion()
        nextRecheck = camera == nil ? .infinity : pts + options.recheckInterval
    }

    /// The framing changed (zoom): the old camera no longer matches the picture, so search again.
    func restart() {
        camera = nil; latest = nil; misfits = 0
        samples.removeAll(); newSamples = 0; lastSample = -.infinity; nextRecheck = .infinity; resetMotion()
    }

    /// Stream change or pause: the phone may have moved. Searching restarts its samples; a found camera
    /// is re-checked right away.
    func streamChanged(pts: Double) {
        samples.removeAll(); newSamples = 0; lastSample = -.infinity; resetMotion()
        if camera != nil { nextRecheck = pts }
    }

    /// Analysis queue, every frame: measures how much the picture moved, collects a finished solve or
    /// tracking step, then takes a sample when one is due. Never blocks on the solve.
    func offer(_ full: CVPixelBuffer?, pts: Double) -> Change? {
        var change: Change?
        var thumbnail: Thumbnail?
        if let full, options.motionPixels != nil, let t = Self.thumbnail(full) {
            thumbnail = t
            change = checkMotion(t, pts: pts)       // first, so a solve that saw a shake is ignored
        }
        let latency = options.simulatedLatencyScale, launched = launchedAt
        if let outcome = mailbox.take(if: { o in latency.map { pts >= launched + o.seconds * $0 } ?? true }) {
            inFlight = false
            if movedSinceLaunch { stats.solves += 1; stats.solveSeconds += outcome.seconds }
            else if let applied = apply(outcome, pts: pts) { change = applied }
            movedSinceLaunch = false
        }
        guard let full, !inFlight, motion != .shaking, pts - lastSample >= options.sampleInterval else { return change }
        if let current = camera, motion == .drifting || stillTrackDue(pts) {
            // follow the mount by refining the current camera on this frame
            guard let sample = Self.sample(full) else { return change }
            let still = motion == .still
            lastSample = pts; lastTrack = pts; stats.samples += 1; samples.removeAll(); anchor = nil
            launch([sample], current: current, track: true, trackWhileStill: still, pts: pts)
            return change
        }
        guard camera == nil || pts >= nextRecheck, let sample = Self.sample(full) else { return change }
        if let threshold = options.motionPixels, let thumbnail {
            // the window holds one pose only: a sample that moved away from the first one restarts it
            if samples.isEmpty || anchor == nil { anchor = thumbnail }
            else if let anchor, Self.motion(anchor, thumbnail) > threshold {
                samples.removeAll(); self.anchor = thumbnail; windowRestarted = true
            }
        }
        lastSample = pts; samples.append(sample); newSamples += 1; stats.samples += 1
        if samples.count > options.frames { samples.removeFirst(samples.count - options.frames) }
        if let current = camera {
            guard samples.count >= options.recheckFrames else { return change }
            launch(samples, current: current, track: false, pts: pts)
            lastTrack = pts
            samples.removeAll()          // a re-check holds no frames once its median is taken
        } else {
            // a drifting picture never gives a still window, nor does a drift just under the threshold that
            // keeps restarting it: solve what there is (gates unchanged)
            let needed = motion == .drifting || windowRestarted ? 1 : options.firstAttemptFrames
            let due = latest == nil || newSamples >= options.retryFrames
            if due && samples.count >= needed { launch(samples, current: nil, track: false, pts: pts) }
        }
        return change
    }

    private func resetMotion() { thumbnails.removeAll(); anchor = nil; motion = .still; lastMotion = nil; movedSinceLaunch = inFlight }

    /// Compares the thumbnail with the one `motionLookback` seconds earlier (or, when full frames come
    /// sparsely, the last one up to three lookbacks old). Shaking drops the samples, any solve in flight
    /// and a found camera (`.lost`); drifting only changes how the court is followed or searched. With
    /// nothing to compare, the picture counts as still, so the state can never stick.
    private func checkMotion(_ t: Thumbnail, pts: Double) -> Change? {
        guard let drift = options.motionPixels else { return nil }
        let previous = thumbnails.last
        thumbnails.removeAll { pts - $0.pts > options.motionLookback + 0.05 }
        defer { thumbnails.append((pts, t)) }
        guard let reference = thumbnails.first ?? previous.flatMap({ pts - $0.pts <= 3 * options.motionLookback ? $0 : nil }) else {
            motion = .still; lastMotion = nil; return nil
        }
        guard pts - reference.pts >= options.motionLookback * 0.5 else { return nil }
        let m = Self.motion(reference.image, t)
        lastMotion = m
        motion = m > options.shakePixels ? .shaking : m > drift ? .drifting : .still
        guard motion == .shaking else { return nil }
        samples.removeAll(); anchor = nil
        if inFlight { movedSinceLaunch = true }
        guard camera != nil else { return nil }
        camera = nil; latest = nil; misfits = 0; nextRecheck = .infinity; stats.lost += 1
        return .lost
    }

    /// Waits for a solve in flight (tests and the end of a file run).
    func drain() { queue.sync {} }

    /// While still, between re-checks, the found camera is refined every `stillTrackInterval`.
    private func stillTrackDue(_ pts: Double) -> Bool {
        guard motion == .still, options.motionPixels != nil, let every = options.stillTrackInterval else { return false }
        return pts < nextRecheck && pts - lastTrack >= every
    }

    private func launch(_ frames: [Sample], current: IndependentPinholeCamera?, track: Bool, trackWhileStill: Bool = false, pts: Double) {
        inFlight = true; newSamples = 0; windowRestarted = false; launchedAt = pts; stats.launches += 1
        let mailbox = mailbox, trackPixels = options.trackPixels
        queue.async {
            let began = ProcessInfo.processInfo.systemUptime
            var outcome = Outcome(calibration: IndependentCourtCalibration(), currentFits: nil, seconds: 0)
            if let image = try? Self.median(frames) {
                if track, let current {
                    outcome.track = true; outcome.trackWhileStill = trackWhileStill
                    outcome.tracked = Self.track(current, image, maxPixels: trackPixels)
                } else {
                    outcome.calibration = IndependentCourtCalibrator.calibrate(image)
                    if let current, !outcome.calibration.found { outcome.currentFits = Self.fits(current, image) }
                }
            } else if track { outcome.track = true; outcome.trackWhileStill = trackWhileStill }
            outcome.seconds = ProcessInfo.processInfo.systemUptime - began
            mailbox.put(outcome)
        }
    }

    private func apply(_ outcome: Outcome, pts: Double) -> Change? {
        stats.solves += 1; stats.solveSeconds += outcome.seconds
        if outcome.track {
            guard let current = camera else { return nil }        // dropped meanwhile
            if let tracked = outcome.tracked {
                misfits = 0
                guard Self.distance(tracked, current) > options.movedPixels else { return nil }
                camera = tracked; stats.moved += 1
                return .moved(tracked)
            }
            // still: one frame may be occluded or blurred, so the median re-check decides
            if outcome.trackWhileStill { nextRecheck = min(nextRecheck, pts); return nil }
            misfits += 1
            guard misfits >= options.dropAfterMisfits else { return nil }
            camera = nil; latest = nil; misfits = 0; nextRecheck = .infinity; stats.lost += 1
            return .lost
        }
        let calibration = outcome.calibration
        guard let current = camera else {
            latest = calibration
            guard let found = calibration.camera else { return nil }
            camera = found; misfits = 0; samples.removeAll(); lastTrack = pts
            nextRecheck = pts + options.recheckInterval; stats.found += 1
            return .found(found)
        }
        nextRecheck = pts + options.recheckInterval
        if let found = calibration.camera {
            misfits = 0
            guard Self.distance(found, current) > options.movedPixels else { return nil }
            camera = found; latest = calibration; stats.moved += 1
            return .moved(found)
        }
        if outcome.currentFits == true { misfits = 0; return nil }
        misfits += 1
        guard misfits >= options.dropAfterMisfits else { nextRecheck = pts; return nil }
        camera = nil; latest = calibration; misfits = 0; stats.lost += 1
        return .lost
    }

    /// The current camera refined on a new image when it still explains the court lines (the `fits`
    /// rules) and moved at most `maxPixels`; nil otherwise. Starting from the current camera, a move of
    /// 20 px converged on every frame of three match videos (`court-lock --fits --fit-pan`, 2026-11-04).
    static func track(_ camera: IndependentPinholeCamera, _ image: IndependentCourtImage, maxPixels: Double) -> IndependentPinholeCamera? {
        guard let refined = IndependentCourtCalibrator.refine(image, start: [camera.f] + camera.rvec + camera.tvec) else { return nil }
        let used = refined.linesUsed
        guard used.count >= 5, used.filter(\.isNearTransverse).count >= 2 else { return nil }
        let rms = (used.compactMap { refined.perLineRMS[$0.rawValue] }.map { $0 * $0 }.reduce(0, +) / Double(used.count)).squareRoot()
        guard rms <= 1.5, distance(refined.camera, camera) <= maxPixels else { return nil }
        return refined.camera
    }

    /// Largest image distance between the two cameras' court reference points.
    static func distance(_ a: IndependentPinholeCamera, _ b: IndependentPinholeCamera) -> Double {
        let pa = IndependentProjector(a), pb = IndependentProjector(b)
        return IndependentCourtModel.referencePoints.map { _, X in
            let u = pa.project(X), v = pb.project(X)
            return ((u.u - v.u) * (u.u - v.u) + (u.v - v.v) * (u.v - v.v)).squareRoot()
        }.max() ?? .infinity
    }

    /// The current camera still explains the court lines: refinement from it keeps at least five lines,
    /// both near transverse lines among them, at most 1.5 px RMS, and stays within `movedPixels`.
    static func fits(_ camera: IndependentPinholeCamera, _ image: IndependentCourtImage, movedPixels: Double = 3) -> Bool {
        guard let refined = IndependentCourtCalibrator.refine(image, start: [camera.f] + camera.rvec + camera.tvec) else { return false }
        let used = refined.linesUsed
        guard used.count >= 5, used.filter(\.isNearTransverse).count >= 2 else { return false }
        let rms = (used.compactMap { refined.perLineRMS[$0.rawValue] }.map { $0 * $0 }.reduce(0, +) / Double(used.count)).squareRoot()
        return rms <= 1.5 && distance(refined.camera, camera) <= movedPixels
    }

    // MARK: Motion

    /// Luma at 1/8 resolution, normalized to zero mean and unit deviation (so a global change of
    /// brightness is not motion).
    struct Thumbnail: Sendable {
        static let width = 240, height = 135, scale = 8.0
        let pixels: [Float]
    }

    static func thumbnail(_ pixels: CVPixelBuffer) -> Thumbnail? {
        guard CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height else { return nil }
        let tw = Thumbnail.width, th = Thumbnail.height
        var small = [UInt8](repeating: 0, count: tw * th)
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pixels)
        let ok: Bool = small.withUnsafeMutableBytes { out in
            var dst = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw)
            switch format {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                guard let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return false }
                var src = vImage_Buffer(data: y, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
                return vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            case kCVPixelFormatType_32BGRA:
                guard let base = CVPixelBufferGetBaseAddress(pixels) else { return false }
                var color = [UInt8](repeating: 0, count: tw * th * 4)
                return color.withUnsafeMutableBytes { c -> Bool in
                    var src = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                            rowBytes: CVPixelBufferGetBytesPerRow(pixels))
                    var mid = vImage_Buffer(data: c.baseAddress, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw * 4)
                    guard vImageScale_ARGB8888(&src, &mid, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
                    let p = c.bindMemory(to: UInt8.self), o = out.bindMemory(to: UInt8.self)
                    for i in 0 ..< tw * th { o[i] = p[i * 4 + 1] }          // green as luma
                    return true
                }
            default:
                return false
            }
        }
        guard ok else { return nil }
        var values = small.map(Float.init)
        let n = Float(values.count), mean = values.reduce(0, +) / n
        let sd = max(1, (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n).squareRoot())
        for i in values.indices { values[i] = (values[i] - mean) / sd }
        return Thumbnail(pixels: values)
    }

    /// Apparent displacement between two thumbnails in full-resolution pixels: the median normal flow
    /// |∂I/∂t| / |∇I| over the strongest edges (the top fifth of gradients, and clearly above flat-area
    /// noise), at 1/8 and at 1/16 resolution, whichever is larger (the coarser one keeps moves of 10-30 px
    /// within its linear range). Court lines and the background carry most strong edges, so players
    /// moving count little; small for a still camera, large when it moves.
    static func motion(_ a: Thumbnail, _ b: Thumbnail) -> Double {
        let w = Thumbnail.width, h = Thumbnail.height
        let fine = normalFlow(a.pixels, b.pixels, width: w, height: h)
        let coarse = normalFlow(halved(a.pixels, width: w, height: h), halved(b.pixels, width: w, height: h), width: w / 2, height: h / 2)
        return max(fine * Thumbnail.scale, coarse * Thumbnail.scale * 2)
    }

    private static func halved(_ p: [Float], width w: Int, height h: Int) -> [Float] {
        let hw = w / 2, hh = h / 2
        var out = [Float](repeating: 0, count: hw * hh)
        for y in 0 ..< hh { for x in 0 ..< hw {
            let i = 2 * y * w + 2 * x
            out[y * hw + x] = (p[i] + p[i + 1] + p[i + w] + p[i + w + 1]) * 0.25
        } }
        return out
    }

    /// Median normal flow in pixels of the given grid.
    private static func normalFlow(_ pa: [Float], _ pb: [Float], width w: Int, height h: Int) -> Double {
        var gradients: [Float] = [], ratios: [Float] = []
        gradients.reserveCapacity(w * h); ratios.reserveCapacity(w * h)
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                let i = y * w + x
                let gx = (pa[i + 1] - pa[i - 1] + pb[i + 1] - pb[i - 1]) * 0.25
                let gy = (pa[i + w] - pa[i - w] + pb[i + w] - pb[i - w]) * 0.25
                let g = (gx * gx + gy * gy).squareRoot()
                gradients.append(g); ratios.append(abs(pb[i] - pa[i]) / max(g, 1e-3))
            }
        }
        // 80th percentile of the gradients from a histogram (0-4 in steps of 1/128; a sort costs more)
        var histogram = [Int](repeating: 0, count: 513)
        for g in gradients { histogram[min(512, Int(g * 128))] += 1 }
        var below = 0, bin = 0
        while bin < 512, below + histogram[bin] <= gradients.count * 4 / 5 { below += histogram[bin]; bin += 1 }
        let cut = max(Float(bin) / 128, 0.2)
        var strong = zip(gradients, ratios).filter { $0.0 >= cut }.map(\.1)
        guard strong.count >= 20 else { return 0 }
        strong.sort()
        return Double(strong[strong.count / 2])
    }

    // MARK: Samples

    struct Sample: Sendable {
        let format: OSType
        /// NV12: Y (width × height) and interleaved CbCr (width × height / 2); 32BGRA: one plane.
        let planes: [[UInt8]]
    }

    struct Outcome: Sendable {
        var calibration: IndependentCourtCalibration
        var currentFits: Bool?
        var seconds: Double
        /// A tracking step: `tracked` is the refined camera, nil when it no longer fits.
        var track = false
        var tracked: IndependentPinholeCamera?
        /// Launched while the picture was still: a miss asks for a re-check instead of counting.
        var trackWhileStill = false
    }

    final class Mailbox: @unchecked Sendable {
        private let lock = NSLock(); private var outcome: Outcome?
        func put(_ o: Outcome) { lock.lock(); outcome = o; lock.unlock() }
        /// The finished outcome if there is one and `ready` accepts it; it stays in the box otherwise.
        func take(if ready: (Outcome) -> Bool = { _ in true }) -> Outcome? {
            lock.lock(); defer { lock.unlock() }
            guard let o = outcome, ready(o) else { return nil }
            outcome = nil; return o
        }
    }

    /// A tightly packed copy of a 1920×1080 NV12 or 32BGRA buffer; nil for other sizes or formats.
    static func sample(_ pixels: CVPixelBuffer) -> Sample? {
        let W = width, H = height
        guard CVPixelBufferGetWidth(pixels) == W, CVPixelBufferGetHeight(pixels) == H else { return nil }
        let format = CVPixelBufferGetPixelFormatType(pixels)
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        func packed(_ base: UnsafeMutableRawPointer, rowBytes: Int, bytesPerRow: Int, rows: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: bytesPerRow * rows)
            out.withUnsafeMutableBytes { o in
                for r in 0..<rows { memcpy(o.baseAddress! + r * bytesPerRow, base + r * rowBytes, bytesPerRow) }
            }
            return out
        }
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard CVPixelBufferGetPlaneCount(pixels) == 2, let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
                  let c = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) else { return nil }
            return Sample(format: format, planes: [packed(y, rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0), bytesPerRow: W, rows: H),
                                                   packed(c, rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 1), bytesPerRow: W, rows: H / 2)])
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
            return Sample(format: format, planes: [packed(base, rowBytes: CVPixelBufferGetBytesPerRow(pixels), bytesPerRow: W * 4, rows: H)])
        default:
            return nil
        }
    }

    /// Per-channel median in BGR of the samples, converted and reduced 72 rows at a time so only one
    /// band of every sample is ever held in BGR (1080 = 15 bands; band starts stay even for the chroma).
    static func median(_ samples: [Sample]) throws -> IndependentCourtImage {
        guard !samples.isEmpty else { throw IndependentCourtImage.ImageError.invalidDimensions }
        let W = width, H = height, band = 72
        var out = [[UInt8]](repeating: [UInt8](repeating: 0, count: W * H), count: 3)          // B, G, R
        var conversions: [OSType: vImage_YpCbCrToARGB] = [:]
        var interleaved = [UInt8](repeating: 0, count: W * band * 4)
        var s0 = [UInt8](repeating: 0, count: W * band), s1 = s0, s2 = s0, s3 = s0
        for r0 in stride(from: 0, to: H, by: band) {
            let rows = min(band, H - r0), count = rows * W
            var channels = [[[UInt8]]](repeating: [], count: 3)                                 // [channel][sample]
            for s in samples {
                let bgra = s.format == kCVPixelFormatType_32BGRA
                if !bgra, conversions[s.format] == nil { conversions[s.format] = IndependentLiveFrameScaler.conversion(for: s.format) }
                let ok = interleaved.withUnsafeMutableBytes { ip -> Bool in
                    if bgra {
                        return s.planes[0].withUnsafeBytes { memcpy(ip.baseAddress!, $0.baseAddress! + r0 * W * 4, count * 4); return true }
                    }
                    guard var conversion = conversions[s.format] else { return false }
                    var dst = vImage_Buffer(data: ip.baseAddress, height: vImagePixelCount(rows), width: vImagePixelCount(W), rowBytes: W * 4)
                    return s.planes[0].withUnsafeBytes { yp in s.planes[1].withUnsafeBytes { cp in
                        var y = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: yp.baseAddress! + r0 * W), height: vImagePixelCount(rows),
                                              width: vImagePixelCount(W), rowBytes: W)
                        var c = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: cp.baseAddress! + (r0 / 2) * W),
                                              height: vImagePixelCount(rows / 2), width: vImagePixelCount(W / 2), rowBytes: W)
                        var permute: [UInt8] = [0, 1, 2, 3]
                        return vImageConvert_420Yp8_CbCr8ToARGB8888(&y, &c, &dst, &conversion, &permute, 255,
                                                                    vImage_Flags(kvImageNoFlags)) == kvImageNoError
                    } }
                }
                guard ok else { throw IndependentCourtImage.ImageError.unsupportedPixelFormat }
                interleaved.withUnsafeMutableBytes { ip in
                    s0.withUnsafeMutableBytes { p0 in s1.withUnsafeMutableBytes { p1 in
                        s2.withUnsafeMutableBytes { p2 in s3.withUnsafeMutableBytes { p3 in
                            var src = vImage_Buffer(data: ip.baseAddress, height: vImagePixelCount(rows), width: vImagePixelCount(W), rowBytes: W * 4)
                            func plane(_ p: UnsafeMutableRawBufferPointer) -> vImage_Buffer {
                                vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(rows), width: vImagePixelCount(W), rowBytes: W)
                            }
                            var d0 = plane(p0), d1 = plane(p1), d2 = plane(p2), d3 = plane(p3)
                            _ = vImageConvert_ARGB8888toPlanar8(&src, &d0, &d1, &d2, &d3, vImage_Flags(kvImageNoFlags))
                        } }
                    } }
                }
                // byte order: BGRA → B, G, R, A; converted NV12 → A, R, G, B
                let split = [s0, s1, s2, s3], order = bgra ? [0, 1, 2] : [3, 2, 1]
                for c in 0..<3 { channels[c].append(Array(split[order[c]].prefix(count))) }
            }
            for c in 0..<3 {
                let m = IndependentCourtMedian.median(channels[c])
                out[c].replaceSubrange(r0 * W ..< r0 * W + count, with: m)
            }
        }
        return try IndependentCourtImage(width: W, height: H, blue: out[0], green: out[1], red: out[2])
    }
}
