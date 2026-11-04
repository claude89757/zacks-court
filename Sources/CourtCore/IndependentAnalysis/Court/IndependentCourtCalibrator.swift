import Foundation
import simd

/// Result of one automatic court calibration. `camera` is nil whenever any refusal applies; a refused
/// solve keeps its camera only as `rejectedCamera`, for diagnosis, never for analysis.
public struct IndependentCourtCalibration: Sendable, Codable {
    public enum Quality: String, Sendable, Codable {
        /// All seven fitted lines (near baseline, both service lines' near parts, four sidelines) agree.
        case good
        /// Found with fewer lines (part of the court out of view); the App asks to adjust the mount.
        case partial
    }

    /// Why no camera was returned. Several can apply at once.
    public enum Refusal: String, Sendable, Codable, CaseIterable {
        case unsupportedImage = "unsupported_image"
        /// No 2 x 2 line combination gave a plausible camera.
        case noPlausibleCombination = "no_plausible_line_combination"
        /// Every candidate lost too many lines in sub-pixel refinement.
        case refinementFailed = "refinement_failed"
        case fitResidualHigh = "fit_rms_high"
        /// Near baseline and near service line were not both fitted: focal length and distance trade off.
        case onlyOneTransverseLine = "only_one_transverse_line"
        case tooFewLines = "too_few_lines"
        case focalLengthImplausible = "focal_length_implausible"
        case cameraHeightImplausible = "camera_height_implausible"
        case focalLengthUnstable = "focal_length_unstable"
        case coverageLow = "coverage_low"

        /// Short Chinese text for the camera screen.
        public var message: String {
            switch self {
            case .unsupportedImage: return "需要 1920×1080 的画面"
            case .noPlausibleCombination: return "未识别到球场：画面里没有足够的球场白线"
            case .refinementFailed: return "未识别到球场：球场白线无法精确对齐"
            case .fitResidualHigh: return "球场线对不齐，请调整机位"
            case .onlyOneTransverseLine: return "近端底线和发球线都要在画面里"
            case .tooFewLines: return "看到的球场线太少，请让整个半场进入画面"
            case .focalLengthImplausible: return "相机参数不合理，请调整机位"
            case .cameraHeightImplausible: return "机位高度不合理，请调整机位"
            case .focalLengthUnstable: return "相机距离无法确定，近端底线和发球线都要在画面里"
            case .coverageLow: return "球场线覆盖不足，请调整机位"
            }
        }
    }

    /// Seconds per stage, named as in the prototype's timing dictionary.
    public struct Timings: Sendable, Codable {
        public var evidence = 0.0, lines = 0.0, search = 0.0, refine = 0.0, total = 0.0
    }

    /// Stage counts for diagnosis.
    public struct Counts: Sendable, Codable {
        public var segments = 0, mergedLines = 0, transverse = 0, transverseBelowHorizon = 0, longitudinal = 0
        public var throughVanishingPoint = 0, hypotheses = 0, gated = 0, refined = 0
    }

    public internal(set) var camera: IndependentPinholeCamera?
    public internal(set) var rejectedCamera: IndependentPinholeCamera?
    public internal(set) var quality: Quality?
    public internal(set) var refusals: [Refusal] = []
    public internal(set) var fitRMS: Double?
    public internal(set) var linesUsed: [IndependentCourtLine] = []
    public internal(set) var perLineRMS: [String: Double] = [:]
    /// RMS of the far service line and far baseline under the camera; checks only, not fitted.
    public internal(set) var checkLineRMS: [String: Double] = [:]
    public internal(set) var focalLengthSD: Double?
    public internal(set) var searchScore: Double?
    public internal(set) var refinedScore: Double?
    /// The ranking score of the chosen refinement and its margin over the next distinct camera.
    public internal(set) var rankScore: Double?
    public internal(set) var margin: Double?
    public internal(set) var evidenceThreshold: Float?
    /// Horizontal principal coordinate minus the image centre, px, when the camera was found only with
    /// it free (a phone filming a screen, or a cropped video); nil for the usual centred fit.
    public internal(set) var principalOffset: Double?
    public internal(set) var timings = Timings()
    public internal(set) var counts = Counts()

    public var found: Bool { camera != nil }
    /// Camera centre in court coordinates (accepted or rejected solve).
    public var cameraCentre: SIMD3<Double>? { (camera ?? rejectedCamera)?.centre }
    /// Projection of the 12 reference points (doubles and singles corners, T points, net-post bases).
    public func referencePixels() -> [String: SIMD2<Double>]? {
        guard let cam = camera ?? rejectedCamera else { return nil }
        let P = IndependentProjector(cam)
        return Dictionary(uniqueKeysWithValues: IndependentCourtModel.referencePoints.map { n, X in
            let p = P.project(X); return (n, SIMD2(p.u, p.v))
        })
    }
}

/// Automatic court calibration from a median frame, with no learned weights (port of
/// `scripts/speed-fullvideo/court_auto.py`):
/// 1. white-line evidence: top-hat of min(B, G, R) (`IndependentCourtEvidence`);
/// 2. Hough segments merged into lines; transverse lines, and longitudinal lines through the sideline
///    vanishing point; only lines below the horizon;
/// 3. every 2 transverse x 2 longitudinal lines with ITF labels gives a homography and a closed-form
///    pinhole camera (principal point at the image centre); plausible cameras are ranked by how well all
///    model lines cover the evidence;
/// 4. the 4 best distinct cameras are refined: sub-pixel line profiles and a 7-parameter LM, 3 passes;
/// 5. the best refinement is checked and refused with reasons when it is not trustworthy;
/// 6. when it is refused only because the lines do not fit tightly enough (or the focal length is
///    unstable), the candidates are refined again with the horizontal principal coordinate free and
///    checked by the same gates. One ground plane fixes only two of f, cx, cy; with cy at the image centre
///    the other two are determined (moving cy by 30 px moves cx by about 1 px and f by about 1%). A
///    camera filmed straight on matches the centred fit within a pixel or two; a phone filming a screen
///    whose picture is off-centre, or a cropped video, does not, and is found here instead.
/// Calibration only: it says nothing about speed or landing accuracy.
public enum IndependentCourtCalibrator {
    public struct Options: Sendable {
        public var maxSegments = 600
        public var vanishingPointLines = 30
        public var maxTransverse = 10, maxLongitudinal = 10
        public var refinedCandidates = 4
        public var passes: [Double] = [10, 6, 6]
        public var baselineWidth = IndependentCourtModel.baselineWidth
        /// Largest |cx - centre| accepted in stage 6; nil turns stage 6 off.
        public var freePrincipalPixels: Double? = 200
        public init() {}
    }

    /// Internal record of each stage, for the parity CLI and tests.
    public struct Trace: Sendable {
        public var segments: [SIMD4<Int>] = []
        public var lines: [IndependentCourtImageLine] = []
        public var transverse: [Int] = [], longitudinal: [Int] = [], throughVanishingPoint: [Int] = []
        public var vanishingPoint: SIMD2<Double>?
        public var transverseBelow: [Int] = [], longitudinalBelow: [Int] = []
        public var searchTransverse: [Int] = [], searchLongitudinal: [Int] = []
        public var candidates: [IndependentCourtHypothesis] = []
        public var distinct: [IndependentCourtHypothesis] = []
        public var attempts: [Attempt] = []
        public init() {}
    }

    public struct Attempt: Sendable {
        public let start: [Double]
        public let result: [Double]?
        public let linesUsed: [IndependentCourtLine]
        public let perLineRMS: [String: Double]
        public let focalLengthSD: Double
        public let fitRMS: Double
        public let refinedScore: Double
        public let nearTransverse: Int
        public let dropped: [IndependentCourtLine]
        public let failure: String?
    }

    public static let width = 1920, height = 1080

    public static func calibrate(_ image: IndependentCourtImage, options: Options = Options()) -> IndependentCourtCalibration {
        var trace: Trace?
        return calibrate(image, options: options, trace: &trace)
    }

    /// Pass a non-nil `trace` to record every stage.
    public static func calibrate(_ image: IndependentCourtImage, options: Options = Options(), trace: inout Trace?) -> IndependentCourtCalibration {
        let began = ProcessInfo.processInfo.systemUptime
        var out = IndependentCourtCalibration()
        guard image.width == width, image.height == height else {
            out.refusals = [.unsupportedImage]; return out
        }
        var clock = began
        func lap() -> Double { let now = ProcessInfo.processInfo.systemUptime; defer { clock = now }; return now - clock }
        let evidence = IndependentCourtEvidence(image)
        out.evidenceThreshold = evidence.threshold
        out.timings.evidence = lap()

        let segs = IndependentCourtHough.segments(evidence.binary, width: evidence.halfWidth, height: evidence.halfHeight)
        let lines = IndependentCourtLines.merge(segs, maxSegments: options.maxSegments)
        var (trans, longi) = IndependentCourtLines.families(lines)
        let (vp, longiVP) = IndependentCourtLines.vanishingPoint(longi, cap: options.vanishingPointLines)
        var longiIn = longiVP
        out.counts.segments = segs.count; out.counts.mergedLines = lines.count
        out.counts.transverse = trans.count; out.counts.longitudinal = longi.count; out.counts.throughVanishingPoint = longiIn.count
        if trace != nil {
            trace!.segments = segs.map { SIMD4($0.x0, $0.y0, $0.x1, $0.y1) }
            trace!.lines = lines; trace!.transverse = trans.map(\.id); trace!.longitudinal = longi.map(\.id)
            trace!.vanishingPoint = vp; trace!.throughVanishingPoint = longiIn.map(\.id)
        }
        if let vp { (trans, longiIn) = IndependentCourtLines.belowHorizon(trans, longiIn, vp: vp) }
        out.counts.transverseBelowHorizon = trans.count
        longi = longiIn
        trace?.transverseBelow = trans.map(\.id); trace?.longitudinalBelow = longi.map(\.id)
        out.timings.lines = lap()

        let search = IndependentCourtSearch.run(transverse: trans, longitudinal: longi, hit: evidence.hit,
                                                halfWidth: evidence.halfWidth, halfHeight: evidence.halfHeight,
                                                maxTransverse: options.maxTransverse, maxLongitudinal: options.maxLongitudinal)
        out.counts.hypotheses = search.hypotheses; out.counts.gated = search.gated
        out.timings.search = lap()
        let distinct = IndependentCourtSearch.distinct(search.candidates)
        if trace != nil {
            trace!.searchTransverse = search.transverse.map(\.id); trace!.searchLongitudinal = search.longitudinal.map(\.id)
            trace!.candidates = search.candidates; trace!.distinct = Array(distinct.prefix(6))
        }
        func finish() -> IndependentCourtCalibration {
            out.timings.total = ProcessInfo.processInfo.systemUptime - began
            return out
        }
        guard !search.candidates.isEmpty else { out.refusals = [.noPlausibleCombination]; return finish() }

        struct Tried { var x: [Double]; var fit: RefinedCamera; var C: SIMD3<Double>; var fitRMS: Double; var rscore: Double; var q: Double; var start: IndependentCourtHypothesis }
        func attempt(_ c: IndependentCourtHypothesis, from start: [Double]) -> Tried? {
            guard let rc = refineCamera(evidence, start: start, options: options) else {
                trace?.attempts.append(Attempt(start: start, result: nil, linesUsed: [], perLineRMS: [:], focalLengthSD: .nan, fitRMS: .nan,
                                               refinedScore: .nan, nearTransverse: 0, dropped: [], failure: "too few refined lines"))
                return nil
            }
            let fitRMS = (rc.use.map { pow(rc.per[$0.rawValue]!, 2) }.reduce(0, +) / Double(rc.use.count)).squareRoot()
            let H = IndependentCourtSearch.homography(f: rc.x[0], R: rotation(rc.x), t: SIMD3(rc.x[4], rc.x[5], rc.x[6]),
                                                      cx: principalX(rc.x), cy: Double(height) / 2)
            let rs = IndependentCourtSearch.score(H, hit: evidence.hit, width: evidence.halfWidth, height: evidence.halfHeight)
            let nTrans = rc.use.filter(\.isNearTransverse).count
            let q = rs + 0.3 * Double(rc.use.count) - 2.0 * max(0, fitRMS - 1.0) + (nTrans >= 2 ? 2.0 : 0.0)
            trace?.attempts.append(Attempt(start: start, result: rc.x, linesUsed: rc.use, perLineRMS: rc.per, focalLengthSD: rc.fSD,
                                           fitRMS: fitRMS, refinedScore: rs, nearTransverse: nTrans, dropped: rc.dropped, failure: nil))
            return Tried(x: rc.x, fit: rc, C: centre(rc.x), fitRMS: fitRMS, rscore: rs, q: q, start: c)
        }
        /// Rank the refinements, pick one and list the reasons to refuse it.
        func judge(_ all: [Tried]) -> (pick: Tried, margin: Double?, reasons: [IndependentCourtCalibration.Refusal]) {
            let tried = NumPy.stableOrder(all.map { -$0.q }).map { all[$0] }
            var pick = 0
            // court in front of the camera: a near-equal candidate whose camera is > 4 m more central wins
            for k in 1..<max(1, tried.count) where tried[k].q >= tried[pick].q - 1.0 && abs(tried[k].C.x) < abs(tried[pick].C.x) - 4 {
                pick = k
            }
            let p = tried[pick]
            let others = tried.indices.filter { $0 != pick && simd_length(tried[$0].C - p.C) > 0.3 }.map { tried[$0].q }
            let x = p.x, use = p.fit.use
            var reasons = [IndependentCourtCalibration.Refusal]()
            if p.fitRMS > 1.5 { reasons.append(.fitResidualHigh) }
            if p.fit.use.filter(\.isNearTransverse).count < 2 { reasons.append(.onlyOneTransverseLine) }
            if use.count < 5 { reasons.append(.tooFewLines) }
            if !(500 < x[0] && x[0] < 3500) { reasons.append(.focalLengthImplausible) }
            if !(0.4 < p.C.z && p.C.z < 8) { reasons.append(.cameraHeightImplausible) }
            if p.fit.fSD > 3.0 { reasons.append(.focalLengthUnstable) }
            if p.rscore < 4 { reasons.append(.coverageLow) }
            return (p, others.max().map { p.q - $0 }, reasons)
        }

        let tried = distinct.prefix(options.refinedCandidates).compactMap { attempt($0, from: $0.parameters) }
        out.counts.refined = tried.count
        guard !tried.isEmpty else { out.timings.refine = lap(); out.refusals = [.refinementFailed]; return finish() }
        var (p, margin, reasons) = judge(tried)
        // stage 6: only the fit itself failed; try again with the horizontal principal coordinate free
        if let limit = options.freePrincipalPixels, reasons.contains(where: { $0 == .fitResidualHigh || $0 == .focalLengthUnstable }) {
            let free = tried.compactMap { t in attempt(t.start, from: Array(t.x.prefix(7)) + [Double(width) / 2]) }
                .filter { abs(principalX($0.x) - Double(width) / 2) <= limit }
            if !free.isEmpty {
                let second = judge(free)
                if second.reasons.isEmpty {
                    (p, margin, reasons) = second
                    out.principalOffset = principalX(p.x) - Double(width) / 2
                }
            }
        }
        out.timings.refine = lap()
        out.searchScore = p.start.score; out.refinedScore = p.rscore; out.rankScore = p.q
        out.margin = margin
        let x = p.x, use = p.fit.use
        let cam = camera(x)
        if reasons.isEmpty { out.camera = cam } else { out.rejectedCamera = cam }
        out.refusals = reasons
        out.fitRMS = p.fitRMS; out.linesUsed = use; out.perLineRMS = p.fit.per
        out.checkLineRMS = p.fit.per.filter { k, _ in IndependentCourtLine.checks.map(\.rawValue).contains(k) }
        out.focalLengthSD = p.fit.fSD
        out.quality = reasons.isEmpty ? (use.count == IndependentCourtLine.fitted.count ? .good : .partial) : nil
        return finish()
    }

    struct RefinedCamera { var x: [Double]; var use: [IndependentCourtLine]; var per: [String: Double]; var fSD: Double; var dropped: [IndependentCourtLine] }

    /// Three refine + LM passes from a start vector; lines with RMS > 2.5 px are dropped and the camera
    /// refitted when at least 4 lines remain (`refine_camera`). Nil when too few lines refine.
    static func refineCamera(_ ev: IndependentCourtEvidence, start: [Double], options: Options) -> RefinedCamera? {
        var x = start
        var result: RefinedCamera?
        for half in options.passes {
            let rl = IndependentCourtRefine.refineLines(ev.fullTopHat, width: ev.width, height: ev.height, params: x,
                                                        names: IndependentCourtLine.fitted + IndependentCourtLine.checks,
                                                        half: half, baselineWidth: options.baselineWidth)
            let okNames = Set(rl.filter { $0.1.ok }.map(\.0))
            var use = IndependentCourtLine.fitted.filter { okNames.contains($0) }
            let nT = use.filter(\.isNearTransverse).count
            if nT < 1 || use.count - nT < 2 || use.count < 4 { return nil }
            var imgLines = rl.filter { $0.1.ok }
            var fit = IndependentCourtRefine.fit(x, lines: imgLines, use: use, width: ev.width, height: ev.height, baselineWidth: options.baselineWidth)
            let per = Dictionary(fit.perLine.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
            let bad = use.filter { per[$0]! > 2.5 }
            if !bad.isEmpty && use.count - bad.count >= 4 {
                use = use.filter { !bad.contains($0) }
                imgLines = imgLines.filter { !bad.contains($0.0) }
                fit = IndependentCourtRefine.fit(fit.x, lines: imgLines, use: use, width: ev.width, height: ev.height, baselineWidth: options.baselineWidth)
            }
            x = fit.x
            result = RefinedCamera(x: x, use: use, per: Dictionary(fit.perLine.map { ($0.0.rawValue, $0.1) }, uniquingKeysWith: { a, _ in a }),
                                   fSD: fit.fSD, dropped: bad)
        }
        return result
    }

    /// Refine from an explicit start vector (f, rvec, tvec, and optionally cx; see `parameters(_:)`): the
    /// parity check's entry into stage 5, and the live tracker's.
    public static func refine(_ image: IndependentCourtImage, start: [Double], options: Options = Options())
        -> (camera: IndependentPinholeCamera, linesUsed: [IndependentCourtLine], perLineRMS: [String: Double], focalLengthSD: Double)? {
        guard image.width == width, image.height == height, start.count == 7 || start.count == 8 else { return nil }
        let ev = IndependentCourtEvidence(image)
        guard let rc = refineCamera(ev, start: start, options: options) else { return nil }
        return (camera(rc.x), rc.use, rc.per, rc.fSD)
    }

    static func rotation(_ x: [Double]) -> simd_double3x3 {
        let R = IndependentCourtRefine.rodrigues(SIMD3(x[1], x[2], x[3]))
        return simd_double3x3(rows: [SIMD3(R[0], R[1], R[2]), SIMD3(R[3], R[4], R[5]), SIMD3(R[6], R[7], R[8])])
    }

    static func centre(_ x: [Double]) -> SIMD3<Double> { -(rotation(x).transpose * SIMD3(x[4], x[5], x[6])) }

    static func camera(_ x: [Double]) -> IndependentPinholeCamera {
        IndependentPinholeCamera(f: x[0], rvec: Array(x[1...3]), tvec: Array(x[4...6]), principal: [principalX(x), Double(height) / 2])
    }

    /// Horizontal principal coordinate of a parameter vector: the 8th value when present, else the centre.
    static func principalX(_ x: [Double]) -> Double { x.count > 7 ? x[7] : Double(width) / 2 }

    /// Start vector (f, rvec, tvec[, cx]) that refines from `camera`; cx is added only when it is off-centre.
    public static func parameters(_ camera: IndependentPinholeCamera) -> [Double] {
        let base = [camera.f] + camera.rvec + camera.tvec
        return camera.principal[0] == Double(width) / 2 ? base : base + [camera.principal[0]]
    }
}
