import CourtCore
import CryptoKit
import Foundation
import ImageIO

/// court-analyze court-calibrate MEDIAN.png [MORE.png ...] OUT.json [--trace TRACE.json] [--starts STARTS.json]
///
/// Runs `IndependentCourtCalibrator` on a median image (PNG or any ImageIO format, 8-bit, decoded bytes
/// used as stored, no colour management) and writes the calibration. With several images it first takes
/// their per-channel median (`IndependentCourtMedian`) and reports that time as `medianSeconds`. Used to check the Swift port against
/// `scripts/speed-fullvideo/court_auto.py`; a found court is a calibration, not evidence of speed or
/// landing accuracy. `--trace` writes every stage (segments, merged lines, hypotheses, refinements) and
/// hashes of the evidence planes in the layout of the Python parity dump. `--starts` refines from each
/// start vector (f, rvec, tvec) in a JSON array and adds the results to the trace.
enum CourtCalibrateCommand {
    static func run(_ allArgs: [String]) throws {
        var args = Array(allArgs.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
        }
        let tracePath = option("--trace"), startsPath = option("--starts")
        guard args.count >= 2 else {
            throw CourtError.message("Usage: court-analyze court-calibrate MEDIAN.png [MORE.png ...] OUT.json [--trace TRACE.json] [--starts STARTS.json]")
        }
        let out = URL(fileURLWithPath: args[args.count - 1])
        for path in [out.path] + [tracePath].compactMap({ $0 }) where FileManager.default.fileExists(atPath: path) {
            throw CourtError.message("Output already exists; choose a new output path: \(path)")
        }
        let loadBegan = ProcessInfo.processInfo.systemUptime
        let frames = try args.dropLast().map { try loadImage(URL(fileURLWithPath: $0)) }
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadBegan
        let medianBegan = ProcessInfo.processInfo.systemUptime
        let image = try IndependentCourtMedian.median(of: frames)
        let medianSeconds = frames.count > 1 ? ProcessInfo.processInfo.systemUptime - medianBegan : 0
        var trace: IndependentCourtCalibrator.Trace? = tracePath == nil ? nil : .init()
        let result = IndependentCourtCalibrator.calibrate(image, trace: &trace)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(Report(result, imageLoadSeconds: loadSeconds, frames: frames.count, medianSeconds: medianSeconds)).write(to: out, options: .withoutOverwriting)
        if let tracePath, let trace {
            var dump = traceDictionary(trace, image: image, result: result)
            if let startsPath {
                let starts = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: URL(fileURLWithPath: startsPath)))
                dump["refine_from_starts"] = starts.map { s -> Any in
                    guard let r = IndependentCourtCalibrator.refine(image, start: s) else { return ["failed": true] }
                    return ["x": [r.camera.f] + r.camera.rvec + r.camera.tvec, "use": r.linesUsed.map(\.rawValue),
                            "per": r.perLineRMS, "f_sd": r.focalLengthSD] as [String: Any]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: sanitize(dump), options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: tracePath), options: .withoutOverwriting)
        }
        let c = result.camera ?? result.rejectedCamera
        let C = result.cameraCentre
        print("COURT_CALIBRATION found=\(result.found) quality=\(result.quality?.rawValue ?? "-")"
              + " refusals=\(result.refusals.map(\.rawValue).joined(separator: ","))"
              + (c.map { String(format: " f=%.1f", $0.f) } ?? "")
              + (C.map { String(format: " C=(%.2f,%.2f,%.2f)", $0.x, $0.y, $0.z) } ?? "")
              + (result.fitRMS.map { String(format: " rms=%.2f", $0) } ?? "")
              + String(format: " seconds=%.3f", result.timings.total))
    }

    struct Report: Encodable {
        let found: Bool, quality: String?, refusals: [String], refusalMessages: [String]
        let camera: IndependentPinholeCamera?, rejectedCamera: IndependentPinholeCamera?
        let cameraCentre: [Double]?, fitRMS: Double?, linesUsed: [String], perLineRMS: [String: Double], checkLineRMS: [String: Double]
        let focalLengthSD: Double?, searchScore: Double?, refinedScore: Double?, rankScore: Double?, margin: Double?
        let evidenceThreshold: Float?, referencePixels: [String: [Double]]?
        let timings: IndependentCourtCalibration.Timings, counts: IndependentCourtCalibration.Counts
        let imageLoadSeconds: Double, frames: Int, medianSeconds: Double
        let calibrationOnly = "Camera calibration from court lines; says nothing about speed or landing accuracy."
        init(_ r: IndependentCourtCalibration, imageLoadSeconds: Double, frames: Int, medianSeconds: Double) {
            found = r.found; quality = r.quality?.rawValue; refusals = r.refusals.map(\.rawValue); refusalMessages = r.refusals.map(\.message)
            camera = r.camera; rejectedCamera = r.rejectedCamera
            cameraCentre = r.cameraCentre.map { [$0.x, $0.y, $0.z] }
            fitRMS = r.fitRMS; linesUsed = r.linesUsed.map(\.rawValue); perLineRMS = r.perLineRMS; checkLineRMS = r.checkLineRMS
            focalLengthSD = r.focalLengthSD; searchScore = r.searchScore; refinedScore = r.refinedScore; rankScore = r.rankScore; margin = r.margin
            evidenceThreshold = r.evidenceThreshold
            referencePixels = r.referencePixels()?.mapValues { [$0.x, $0.y] }
            timings = r.timings; counts = r.counts
            self.imageLoadSeconds = imageLoadSeconds; self.frames = frames; self.medianSeconds = medianSeconds
        }
    }

    /// Decoded 8-bit samples as stored in the file (no colour conversion), as `cv2.imread` returns them.
    static func loadImage(_ url: URL) throws -> IndependentCourtImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let data = cg.dataProvider?.data, let base = CFDataGetBytePtr(data) else {
            throw CourtError.message("Cannot decode image \(url.lastPathComponent)")
        }
        guard cg.bitsPerComponent == 8 else { throw CourtError.message("Only 8-bit images are supported") }
        let raw = UnsafeRawBufferPointer(start: base, count: CFDataGetLength(data))
        let w = cg.width, h = cg.height, rb = cg.bytesPerRow
        let little = cg.bitmapInfo.contains(.byteOrder32Little)
        switch (cg.bitsPerPixel, cg.alphaInfo) {
        case (24, .none):
            return try IndependentCourtImage(rgb: raw, width: w, height: h, rowBytes: rb)
        case (32, .noneSkipLast), (32, .last), (32, .premultipliedLast):
            return try IndependentCourtImage(fourChannel: raw, width: w, height: h, rowBytes: rb, order: little ? (1, 2, 3) : (2, 1, 0))
        case (32, .noneSkipFirst), (32, .first), (32, .premultipliedFirst):
            return try IndependentCourtImage(fourChannel: raw, width: w, height: h, rowBytes: rb, order: little ? (0, 1, 2) : (3, 2, 1))
        case (8, .none):
            var plane = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { plane[y * w + x] = raw[y * rb + x] } }
            return try IndependentCourtImage(width: w, height: h, blue: plane, green: plane, red: plane)
        default:
            throw CourtError.message("Unsupported pixel layout: \(cg.bitsPerPixel) bpp, alpha \(cg.alphaInfo.rawValue)")
        }
    }

    static func hash(_ bytes: [UInt8]) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined().prefix(16).description }
    static func hash(_ floats: [Float]) -> String { floats.withUnsafeBytes { hash(Array($0)) } }

    static func traceDictionary(_ t: IndependentCourtCalibrator.Trace, image: IndependentCourtImage, result: IndependentCourtCalibration) -> [String: Any] {
        let ev = IndependentCourtEvidence(image)
        var bgr = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for i in 0..<(image.width * image.height) { bgr[3 * i] = image.blue[i]; bgr[3 * i + 1] = image.green[i]; bgr[3 * i + 2] = image.red[i] }
        func pair(_ v: SIMD2<Double>) -> [Double] { [v.x, v.y] }
        func hyp(_ c: IndependentCourtHypothesis) -> [String: Any] {
            let r = IndependentPinholeCamera.rotationVector(c.rotation)
            return ["score": c.score, "f": c.f, "C": [c.centre.x, c.centre.y, c.centre.z], "labels": c.labels, "lines": c.lines,
                    "params": [c.f, r.x, r.y, r.z, c.translation.x, c.translation.y, c.translation.z]]
        }
        return [
            "min_hash": hash(image.minimumPlane), "bgr_hash": hash(bgr), "th_hash": hash(ev.halfTopHat), "binary_hash": hash(ev.binary),
            "hit_hash": hash(ev.hit), "thf_hash": hash(ev.fullTopHat), "binary_count": ev.binary.reduce(0) { $0 + Int($1) },
            "thr": Double(ev.threshold),
            "segments": t.segments.map { [$0.x, $0.y, $0.z, $0.w] },
            "lines": t.lines.map { ["p": pair($0.point), "d": pair($0.direction), "support": $0.support, "ends": [pair($0.start), pair($0.end)],
                                    "npts": 2 * $0.segments] as [String: Any] },
            "trans": t.transverse, "longi": t.longitudinal, "vp": t.vanishingPoint.map(pair) as Any, "longi_in": t.throughVanishingPoint,
            "trans_below": t.transverseBelow, "longi_below": t.longitudinalBelow,
            "search_trans": t.searchTransverse, "search_longi": t.searchLongitudinal,
            "hypotheses": result.counts.hypotheses, "gated": result.counts.gated,
            "cands": t.candidates.prefix(40).map(hyp), "distinct": t.distinct.map(hyp),
            "tries": t.attempts.map { a -> [String: Any] in
                a.result == nil ? ["start": a.start, "failed": a.failure ?? ""]
                    : ["start": a.start, "x": a.result!, "use": a.linesUsed.map(\.rawValue), "per": a.perLineRMS, "f_sd": a.focalLengthSD,
                       "n_trans": a.nearTransverse, "dropped": a.dropped.map(\.rawValue), "rscore": a.refinedScore, "fit_rms": a.fitRMS]
            },
            "timing": ["evidence": result.timings.evidence, "lines": result.timings.lines, "search": result.timings.search,
                       "refine": result.timings.refine, "total": result.timings.total],
        ]
    }

    /// JSONSerialization rejects NaN and infinity.
    static func sanitize(_ v: Any) -> Any {
        switch v {
        case let d as Double: return d.isFinite ? d : String(d)
        case let a as [Any]: return a.map(sanitize)
        case let m as [String: Any]: return m.mapValues(sanitize)
        default: return v
        }
    }
}
