import AVFoundation
import CoreImage
import CourtCore
import Foundation
import simd

/// `court-lock VIDEO OUT.json [--start S] [--duration D] [--scenarios a,b] [--seed N] [--latency K]
/// [--before] [--first N] [--retry N] [--motion PX|off] [--lookback S] [--tolerance PX] [--reference CAMERA.json] [--anyway]`
/// (`--before`: the search as it was before the motion check; `--anyway`: run without a steady solve,
/// to see only whether the court locks and how much the picture moves.)
///
/// How fast and how correctly the automatic court locks when the phone shakes while it is being set up.
/// A steady (tripod) video is warped by known camera rotations, which is exactly what a phone turning
/// on its mount does, so the camera that took every warped frame is known: the steady solve of the same
/// stretch, rotated. Scenarios:
/// - `steady`: no warp.
/// - `fixed`: one constant rotation from the start (checks that the warp itself keeps the court).
/// - `settle`: shaking for the first 8 s (hand-held mounting), then still at a new rotation.
/// - `bump`: still for 15 s, knocked for 2 s, then still at another rotation.
/// - `wobble`: a fixed rotation plus about 2 px of slow sway throughout (counted as still).
/// "Right" means within the tolerance of the rotated steady solve, not physical truth.
enum CourtLockCommand {
    struct Rotation { var pan = 0.0, tilt = 0.0, roll = 0.0 }   // radians, camera axes (x right, y down, z forward)

    struct Scenario {
        let name: String
        /// Rotation and stillness at `t` seconds into the stretch.
        let at: (Double) -> (Rotation, Bool)
    }

    struct Output: Encodable {
        let source: String, start: Double, duration: Double, seed: UInt64
        let reference: IndependentPinholeCamera?
        let referenceRefusals: [String]
        let scenarios: [String: IndependentCourtLockLab.Report]
    }

    static func run(_ args: [String]) throws {
        guard args.count >= 3 else { throw CourtError.message("Usage: court-lock VIDEO OUT.json [--start S] [--duration D] [--scenarios steady,fixed,settle,bump,wobble] [--seed N] [--latency K] [--before] [--first N] [--retry N] [--motion PX|off] [--lookback S] [--tolerance PX] [--reference CAMERA.json] [--anyway]") }
        let video = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let start = value("--start").flatMap(Double.init) ?? 0, duration = value("--duration").flatMap(Double.init) ?? 45
        let seed = value("--seed").flatMap(UInt64.init) ?? 1
        let names = (value("--scenarios") ?? "steady,fixed,settle,bump").split(separator: ",").map(String.init)
        var settings = args.contains("--before") ? IndependentCourtLockLab.Settings.before20261104() : IndependentCourtLockLab.Settings()
        if let v = value("--latency").flatMap(Double.init) { settings.latencyScale = v }
        if let v = value("--first").flatMap(Int.init) { settings.firstAttemptFrames = v }
        if let v = value("--retry").flatMap(Int.init) { settings.retryFrames = v }
        if let v = value("--tolerance").flatMap(Double.init) { settings.tolerancePixels = v }
        if let v = value("--motion") { settings.motionPixels = v == "off" ? nil : Double(v) }
        if let v = value("--lookback").flatMap(Double.init) { settings.motionLookback = v }

        // Reference: the steady solve of the first 20 s of the stretch (25 samples, 0.8 s apart).
        var reference: IndependentPinholeCamera?, refusals: [String] = []
        if let path = value("--reference") {
            reference = try JSONDecoder().decode(IndependentPinholeCamera.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            let solver = IndependentCourtMedianSolver()
            var next = start
            try decode(video, start: start, duration: 20.5) { pixels, pts in
                guard pts >= next, solver.count < 25 else { return }
                solver.add(pixels); next = pts + 0.8
            }
            let calibration = try solver.solve()
            reference = calibration.camera; refusals = calibration.refusals.map(\.rawValue)
        }
        if reference == nil, args.contains("--anyway") {
            // no steady solve: run anyway to see whether the court locks and how much the picture moves;
            // errors against this placeholder mean nothing
            reference = IndependentPinholeCamera.lookingAt(SIMD3(0, 9, 0), from: SIMD3(0, -6.5, 3.2), f: 1400)
            print("COURT_LOCK reference_refused=\(refusals.joined(separator: ",")) placeholder truth, errors meaningless")
        }
        guard let reference else {
            try write(Output(source: video.lastPathComponent, start: start, duration: duration, seed: seed, reference: nil,
                             referenceRefusals: refusals, scenarios: [:]), to: out)
            print("COURT_LOCK reference_refused=\(refusals.joined(separator: ","))"); return
        }

        var rng = SplitMix(seed: seed)
        let scenarios = names.map { scenario($0, rng: &rng) }
        let labs = scenarios.map { _ in IndependentCourtLockLab(settings: settings) }
        let warper = try Warper(f: reference.f)
        var index = 0
        try decode(video, start: start, duration: duration) { pixels, pts in
            defer { index += 1 }
            guard index % 12 == 0 else { return }          // full frames reach the court on person frames only
            for (scenario, lab) in zip(scenarios, labs) {
                let (rotation, still) = scenario.at(pts - start)
                let frame = rotation.isZero ? pixels : try warper.warp(pixels, rotation)
                lab.feed(frame, pts: pts - start, truth: rotated(reference, rotation), still: still)
            }
        }
        var reports: [String: IndependentCourtLockLab.Report] = [:]
        for (scenario, lab) in zip(scenarios, labs) {
            let report = lab.finish(); reports[scenario.name] = report
            for phase in report.phases where phase.still {
                let lock = phase.firstRight.map { String(format: "%.1f", $0 - phase.start) } ?? "never"
                print(String(format: "COURT_LOCK %@ still_from=%.1f lock_after=%@ right=%.1f wrong=%.1f none=%.1f solves=%d max_solve=%.2f",
                             scenario.name, phase.start, lock, phase.rightSeconds, phase.wrongSeconds, phase.noneSeconds,
                             report.solves, report.maxSolveSeconds))
            }
            let moved = report.motion.filter { $0[1] > (settings.motionPixels ?? .infinity) }.count
            print("COURT_LOCK \(scenario.name) events=\(report.events.map { String(format: "%@@%.1f", $0.kind, $0.pts) }.joined(separator: ",")) moving_frames=\(moved)/\(report.motion.count)")
            for phase in report.phases where !phase.still && phase.wrongSeconds > 0 {
                print(String(format: "COURT_LOCK %@ moving_from=%.1f wrong=%.1f", scenario.name, phase.start, phase.wrongSeconds))
            }
        }
        try write(Output(source: video.lastPathComponent, start: start, duration: duration, seed: seed, reference: reference,
                         referenceRefusals: [], scenarios: reports), to: out)
    }

    static func write(_ output: Output, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(output).write(to: url, options: .atomic)
    }

    // MARK: Scenarios

    static func scenario(_ name: String, rng: inout SplitMix) -> Scenario {
        let degree = Double.pi / 180
        func pose() -> Rotation {
            Rotation(pan: rng.sign() * rng.uniform(0.4, 0.9) * degree, tilt: rng.sign() * rng.uniform(0.3, 0.7) * degree,
                     roll: rng.sign() * rng.uniform(0.2, 0.5) * degree)
        }
        // Hand-held shake: three sinusoids per axis (0.5-3 Hz), fading out while easing into the new pose.
        func shake(from a: Rotation, to b: Rotation, t0: Double, t1: Double) -> (Double) -> Rotation {
            var waves: [[(Double, Double, Double)]] = []
            for amplitude in [1.2, 1.0, 0.5] {          // pan, tilt, roll in degrees
                waves.append((0..<3).map { _ in (amplitude * degree * rng.uniform(0.4, 1.0), rng.uniform(0.5, 3.0), rng.uniform(0, 2 * .pi)) })
            }
            return { t in
                let u = min(1, max(0, (t - t0) / (t1 - t0))), envelope = 1 - u * u
                func axis(_ i: Int) -> Double { waves[i].map { $0.0 * sin(2 * .pi * $0.1 * t + $0.2) }.reduce(0, +) * envelope }
                return Rotation(pan: a.pan + (b.pan - a.pan) * u + axis(0), tilt: a.tilt + (b.tilt - a.tilt) * u + axis(1),
                                roll: a.roll + (b.roll - a.roll) * u + axis(2))
            }
        }
        switch name {
        case "fixed":
            let p = pose(); return Scenario(name: name) { _ in (p, true) }
        case "settle":
            let p = pose(), s = shake(from: Rotation(), to: p, t0: 0, t1: 8)
            return Scenario(name: name) { t in t < 8 ? (s(t), false) : (p, true) }
        case "wobble":
            // a mount that never quite stops: about 2 px of slow sway on top of a fixed rotation
            let p = pose(), w = (0..<3).map { _ in (rng.uniform(0.03, 0.06) * degree, rng.uniform(0.3, 2.0), rng.uniform(0, 2 * .pi)) }
            return Scenario(name: name) { t in
                let a = w.map { $0.0 * sin(2 * .pi * $0.1 * t + $0.2) }
                return (Rotation(pan: p.pan + a[0], tilt: p.tilt + a[1], roll: p.roll + a[2]), true)
            }
        case "bump":
            let p = pose(), s = shake(from: Rotation(), to: p, t0: 15, t1: 17)
            return Scenario(name: name) { t in t < 15 ? (Rotation(), true) : t < 17 ? (s(t), false) : (p, true) }
        default:
            return Scenario(name: "steady") { _ in (Rotation(), true) }
        }
    }

    static func matrix(_ r: Rotation) -> simd_double3x3 {
        let (cp, sp, ct, st, cr, sr) = (cos(r.pan), sin(r.pan), cos(r.tilt), sin(r.tilt), cos(r.roll), sin(r.roll))
        let pan = simd_double3x3(rows: [SIMD3(cp, 0, sp), SIMD3(0, 1, 0), SIMD3(-sp, 0, cp)])
        let tilt = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, ct, -st), SIMD3(0, st, ct)])
        let roll = simd_double3x3(rows: [SIMD3(cr, -sr, 0), SIMD3(sr, cr, 0), SIMD3(0, 0, 1)])
        return roll * tilt * pan
    }

    /// The reference camera turned by `r` about its own centre.
    static func rotated(_ c: IndependentPinholeCamera, _ r: Rotation) -> IndependentPinholeCamera {
        guard !r.isZero else { return c }
        let d = matrix(r), R = d * c.rotation, t = d * c.translation, v = IndependentPinholeCamera.rotationVector(R)
        return IndependentPinholeCamera(f: c.f, rvec: [v.x, v.y, v.z], tvec: [t.x, t.y, t.z], principal: c.principal)
    }

    // MARK: Video

    static func decode(_ video: URL, start: Double, duration: Double, _ body: (CVPixelBuffer, Double) throws -> Void) throws {
        let asset = AVURLAsset(url: video)
        let semaphore = DispatchSemaphore(value: 0)
        var loaded: Result<(AVAssetTrack, CGAffineTransform), Error>?
        Task {
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CourtError.message("No video track") }
                loaded = .success((track, try await track.load(.preferredTransform)))
            } catch { loaded = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        let (track, transform) = try loaded!.get()
        guard transform == .identity else { throw CourtError.message("Rotated videos are not supported") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? CourtError.message("Cannot start video reader") }
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            try autoreleasepool { try body(pixels, pts) }
        }
        if reader.status == .failed { throw reader.error ?? CourtError.message("Video decode failed") }
    }

    /// Renders a frame as seen by the camera turned by a rotation: the homography K R K⁻¹, with the
    /// image edge extended so no dark border appears.
    final class Warper {
        let f: Double, width = 1920, height = 1080
        let context = CIContext(options: [.cacheIntermediates: false])
        var pool: CVPixelBufferPool?
        init(f: Double) throws {
            self.f = f
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                               kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                               kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
                throw CourtError.message("Cannot create warp pool")
            }
        }
        func warp(_ pixels: CVPixelBuffer, _ r: Rotation) throws -> CVPixelBuffer {
            let W = Double(width), H = Double(height), cx = W / 2, cy = H / 2
            let d = CourtLockCommand.matrix(r)
            func map(_ x: Double, _ y: Double) -> CGPoint {          // top-left pixel coordinates in, Core Image out
                let p = d * SIMD3((x - cx) / f, (y - cy) / f, 1)
                return CGPoint(x: p.x / p.z * f + cx, y: H - (p.y / p.z * f + cy))
            }
            let source = CIImage(cvPixelBuffer: pixels)
            guard let filter = CIFilter(name: "CIPerspectiveTransformWithExtent") else { throw CourtError.message("No perspective filter") }
            filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgRect: CGRect(x: 0, y: 0, width: W, height: H)), forKey: "inputExtent")
            filter.setValue(CIVector(cgPoint: map(0, 0)), forKey: "inputTopLeft")
            filter.setValue(CIVector(cgPoint: map(W, 0)), forKey: "inputTopRight")
            filter.setValue(CIVector(cgPoint: map(0, H)), forKey: "inputBottomLeft")
            filter.setValue(CIVector(cgPoint: map(W, H)), forKey: "inputBottomRight")
            guard let image = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: W, height: H)) else {
                throw CourtError.message("Warp failed")
            }
            var target: CVPixelBuffer?
            guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let target else {
                throw CourtError.message("Cannot allocate warp target")
            }
            CVBufferPropagateAttachments(pixels, target)
            context.render(image, to: target)
            return target
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * Double(next() >> 11) / Double(1 << 53) }
        mutating func sign() -> Double { next() & 1 == 0 ? 1 : -1 }
    }
}

extension CourtLockCommand.Rotation {
    var isZero: Bool { pan == 0 && tilt == 0 && roll == 0 }
}
