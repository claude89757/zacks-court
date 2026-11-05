import Foundation
import Accelerate
import CoreML
import CoreVideo
import Vision

/// The in-house live lane (docs/model-replacement-design.md §3.4): every frame is scaled to 512×288 RGB
/// on the capture queue; on the analysis queue a 48-frame median background is followed by 8-frame
/// TrackNetV3 batches (FP16, Neural Engine), the ball candidates feed `IndependentLiveShots`, and person
/// boxes come from Apple Vision on full-resolution copies (full frame plus far-court crops). Results are
/// model estimates. Nothing here holds a camera buffer.
public struct IndependentLiveConfiguration: Sendable {
    /// Verifies and returns the FP16 model; called on the analysis queue (hashing never runs on the
    /// main or capture queue).
    public var loadAssets: @Sendable () throws -> IndependentBallModelAssets
    public var computeUnits: MLComputeUnits
    /// Camera of the court; nil until the court is found (ball points are still tracked).
    public var camera: IndependentPinholeCamera?
    /// Find the court from the image (`IndependentLiveCourt`) and re-check it while recording. Off for
    /// file comparisons that pass a fixed camera.
    public var automaticCourt: Bool
    /// Full-resolution person detection every this many frames (12 = 5 Hz at 60 fps; the rules look
    /// for a box within ±6 frames of a hit).
    public var personInterval: Int
    /// Seconds between rule updates.
    public var updateInterval: Double
    /// Add Vision body-pose boxes on the full frame where the rectangle detector found nobody (near
    /// players whose feet leave the frame are the common case). On by default.
    public var poseFill = true
    public init(loadAssets: @escaping @Sendable () throws -> IndependentBallModelAssets, computeUnits: MLComputeUnits = .all,
                camera: IndependentPinholeCamera? = nil, automaticCourt: Bool = true, personInterval: Int = 12, updateInterval: Double = 0.25) {
        self.loadAssets = loadAssets; self.computeUnits = computeUnits; self.camera = camera; self.automaticCourt = automaticCourt
        self.personInterval = max(1, personInterval); self.updateInterval = max(0.05, updateInterval)
    }
    /// Already verified assets (tests and CLIs).
    public init(assets: IndependentBallModelAssets, computeUnits: MLComputeUnits = .all, camera: IndependentPinholeCamera? = nil,
                automaticCourt: Bool = true, personInterval: Int = 12, updateInterval: Double = 0.25) {
        self.init(loadAssets: { assets }, computeUnits: computeUnits, camera: camera, automaticCourt: automaticCourt,
                  personInterval: personInterval, updateInterval: updateInterval)
    }
    /// The FP16 model bundled with the App.
    public static func bundled(_ bundle: Bundle = .main) -> Self {
        Self(loadAssets: { try IndependentBallModelAssets.bundled(in: bundle, variant: .fp16) })
    }

    static let baseVersion = "independent-tracknetv3-fp16+" + IndependentShotPipeline.rulesVersion + "-live"
    /// Written into every snapshot; names the person stage too, since it changes the rows.
    public var modelVersion: String { Self.baseVersion + (poseFill ? "+posefill" : "") }
    public static let limitations = [
        "自研模型估计：球速只在看到球落地时给出，其余显示「—」并附原因；空中球不按地面换算。",
        "动作类型要看得到击球人；按右手持拍判断正反手。",
        "球场由画面白线自动识别，记录中定时复查；识别出球场前的击球在识别后补算（最多 30 秒）。",
    ]
}

// MARK: - Capture queue: frame → 512×288 RGB8

/// Scales a camera frame (420v/420f NV12 or 32BGRA) to 512×288 packed RGB8 with vImage. Confined to the
/// capture queue; the buffer is only read while locked and never retained.
public final class IndependentLiveFrameScaler {
    public static let width = IndependentBallPreprocessor.outputWidth, height = IndependentBallPreprocessor.outputHeight
    private var conversion = vImage_YpCbCrToARGB()
    private var conversionKey: OSType = 0
    private var y = [UInt8](repeating: 0, count: width * height)
    private var cbcr = [UInt8](repeating: 0, count: width * height / 2)
    private var argb = [UInt8](repeating: 0, count: width * height * 4)

    public init() {}

    /// Packed RGB8 (row stride 512×3), or nil for an unsupported format.
    public func scale(_ pixels: CVPixelBuffer) -> [UInt8]? {
        let format = CVPixelBufferGetPixelFormatType(pixels)
        CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let W = Self.width, H = Self.height
        var rgb = [UInt8](repeating: 0, count: W * H * 3)
        let flags = vImage_Flags(kvImageHighQualityResampling)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard CVPixelBufferGetPlaneCount(pixels) == 2, let yBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
                  let cBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1), prepareConversion(format) else { return nil }
            var srcY = vImage_Buffer(data: yBase, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixels, 0)),
                                     width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixels, 0)), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
            var srcC = vImage_Buffer(data: cBase, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixels, 1)),
                                     width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixels, 1)), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 1))
            let ok = y.withUnsafeMutableBytes { yp in cbcr.withUnsafeMutableBytes { cp in argb.withUnsafeMutableBytes { ap in rgb.withUnsafeMutableBytes { rp -> Bool in
                var dstY = vImage_Buffer(data: yp.baseAddress, height: vImagePixelCount(H), width: vImagePixelCount(W), rowBytes: W)
                var dstC = vImage_Buffer(data: cp.baseAddress, height: vImagePixelCount(H / 2), width: vImagePixelCount(W / 2), rowBytes: W)
                var dstA = vImage_Buffer(data: ap.baseAddress, height: vImagePixelCount(H), width: vImagePixelCount(W), rowBytes: W * 4)
                var dstR = vImage_Buffer(data: rp.baseAddress, height: vImagePixelCount(H), width: vImagePixelCount(W), rowBytes: W * 3)
                guard vImageScale_Planar8(&srcY, &dstY, nil, flags) == kvImageNoError,
                      vImageScale_CbCr8(&srcC, &dstC, nil, flags) == kvImageNoError else { return false }
                var permute: [UInt8] = [0, 1, 2, 3]
                guard vImageConvert_420Yp8_CbCr8ToARGB8888(&dstY, &dstC, &dstA, &conversion, &permute, 255, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
                return vImageConvert_ARGB8888toRGB888(&dstA, &dstR, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            } } } }
            return ok ? rgb : nil
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
            var src = vImage_Buffer(data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pixels)),
                                    width: vImagePixelCount(CVPixelBufferGetWidth(pixels)), rowBytes: CVPixelBufferGetBytesPerRow(pixels))
            let ok = argb.withUnsafeMutableBytes { ap in rgb.withUnsafeMutableBytes { rp -> Bool in
                var small = vImage_Buffer(data: ap.baseAddress, height: vImagePixelCount(H), width: vImagePixelCount(W), rowBytes: W * 4)
                var dstR = vImage_Buffer(data: rp.baseAddress, height: vImagePixelCount(H), width: vImagePixelCount(W), rowBytes: W * 3)
                guard vImageScale_ARGB8888(&src, &small, nil, flags) == kvImageNoError else { return false }
                return vImageConvert_BGRA8888toRGB888(&small, &dstR, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            } }
            return ok ? rgb : nil
        default:
            return nil
        }
    }

    private func prepareConversion(_ format: OSType) -> Bool {
        if conversionKey == format { return true }
        guard let made = Self.conversion(for: format) else { return false }
        conversion = made; conversionKey = format
        return true
    }

    /// NV12 → ARGB8888 with BT.709 (iPhone 1080p video), video or full range.
    static func conversion(for format: OSType) -> vImage_YpCbCrToARGB? {
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        var range = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var conversion = vImage_YpCbCrToARGB()
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range, &conversion,
                                                            kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        return conversion
    }
}

// MARK: - Analysis queue: background, batches, candidates

/// 48-frame median background, then non-overlapping 8-frame batches through the ball model. A gap of
/// more than 1.5 frame periods, a stream change or a size change starts a new warm-up.
final class IndependentLiveBallStage {
    static let warmup = IndependentBallWindowAssembler.warmupFrameCount, batch = IndependentBallWindowAssembler.windowFrameCount
    private let model: IndependentBallModel
    private let maximumInterval: Double
    private var warmupFrames: [[UInt8]] = []
    private var background: [UInt8]?
    private var pending: [[UInt8]] = [], pendingTimes: [Double] = [], pendingIndices: [Int] = []
    private var lastPTS: Double?, streamID: UUID?
    private var frameIndex = 0
    private(set) var resets = 0, batches = 0, inferenceSeconds = 0.0
    var backgroundReady: Bool { background != nil }

    init(model: IndependentBallModel, nominalFPS: Double = 60) { self.model = model; maximumInterval = 1.5 / nominalFPS }

    func reset() { warmupFrames.removeAll(); background = nil; pending.removeAll(); pendingTimes.removeAll(); pendingIndices.removeAll(); lastPTS = nil; resets += 1 }

    /// Returns true when the frame broke continuity (the caller resets the shot chain too).
    @discardableResult
    func append(rgb: [UInt8], pts: Double, streamID: UUID, sourceWidth: Int, sourceHeight: Int,
                emit: ([IndependentShotCandidate]) -> Void) throws -> Bool {
        var broke = false
        if self.streamID != streamID || (lastPTS.map { pts <= $0 || pts - $0 > maximumInterval } ?? false) {
            if self.streamID != nil { broke = true }
            reset(); self.streamID = streamID
        }
        lastPTS = pts; frameIndex += 1
        guard let background else {
            warmupFrames.append(rgb)
            if warmupFrames.count == Self.warmup { self.background = Self.median(warmupFrames); warmupFrames.removeAll() }
            return broke
        }
        pending.append(rgb); pendingTimes.append(pts); pendingIndices.append(frameIndex)
        guard pending.count == Self.batch else { return broke }
        let start = ProcessInfo.processInfo.systemUptime
        let tensor = try Self.tensor(background: background, frames: pending)
        let prediction = try autoreleasepool { try model.predict(tensor) }
        inferenceSeconds += ProcessInfo.processInfo.systemUptime - start; batches += 1
        let transform = try IndependentBallImageTransform(originalWidth: sourceWidth, originalHeight: sourceHeight)
        let plane = IndependentLiveFrameScaler.width * IndependentLiveFrameScaler.height
        var out = [IndependentShotCandidate]()
        for k in 0..<Self.batch {
            let bank = try IndependentBallCandidateBank.extract(Array(prediction.heatmaps[(k * plane)..<((k + 1) * plane)]), transform: transform)
            for c in bank.candidates where c.originalXY.count == 2 {
                out.append(IndependentShotCandidate(decodeIndex: pendingIndices[k], time: pendingTimes[k] * 60,
                                                    u: Double(c.originalXY[0]), v: Double(c.originalXY[1]), peak: Double(c.peak)))
            }
        }
        pending.removeAll(); pendingTimes.removeAll(); pendingIndices.removeAll()
        emit(out)
        return broke
    }

    /// Per-byte median of the warm-up frames (even count: mean of the two middle values, truncated).
    static func median(_ frames: [[UInt8]]) -> [UInt8] {
        let n = frames.count, count = frames[0].count
        var out = [UInt8](repeating: 0, count: count)
        var column = [UInt8](repeating: 0, count: n)
        for i in 0..<count {
            for k in 0..<n { column[k] = frames[k][i] }
            column.sort()
            out[i] = n % 2 == 1 ? column[n / 2] : UInt8((Int(column[n / 2 - 1]) + Int(column[n / 2])) / 2)
        }
        return out
    }

    /// Float32 NCHW [1,27,288,512]: background RGB, then the 8 frames, each byte / 255.
    static func tensor(background: [UInt8], frames: [[UInt8]]) throws -> MLMultiArray {
        let tensor = try MLMultiArray(shape: IndependentBallModel.inputShape.map(NSNumber.init(value:)), dataType: .float32)
        let p = tensor.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = IndependentLiveFrameScaler.width * IndependentLiveFrameScaler.height
        var scale: Float = 1 / 255
        for (k, image) in ([background] + frames).enumerated() {
            image.withUnsafeBufferPointer { src in
                for c in 0..<3 {
                    let dst = p + (k * 3 + c) * plane
                    vDSP_vfltu8(src.baseAddress! + c, 3, dst, 1, vDSP_Length(plane))
                    vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(plane))
                }
            }
        }
        return tensor
    }
}

// MARK: - Analysis queue: person boxes

/// Rolling Vision person boxes by frame (1/60 s units), in the `people.swift` layout: the full frame plus
/// far-court crops derived from the camera.
final class IndependentLivePeople {
    /// Covers the catch-up after the court is found (`IndependentLiveEngine.pendingSeconds`).
    static let retainedSeconds = 32
    private var byFrame: [Int: [IndependentPersonBox]] = [:]
    private(set) var samples = 0, seconds = 0.0, poseAdded = 0
    let poseFill: Bool
    init(poseFill: Bool) { self.poseFill = poseFill }

    var people: IndependentPeople { IndependentPeople(byFrame) }
    func reset() { byFrame.removeAll() }

    /// Returns the frame (1/60 s units) and the boxes stored for it.
    @discardableResult
    func detect(_ pixels: CVPixelBuffer, pts: Double, camera: IndependentPinholeCamera?) -> (frame: Int, boxes: [IndependentPersonBox]) {
        let start = ProcessInfo.processInfo.systemUptime
        let W = Double(CVPixelBufferGetWidth(pixels)), H = Double(CVPixelBufferGetHeight(pixels))
        var regions = [(x: 0.0, y: 0.0, w: W, h: H)]
        if let camera { regions += Self.farCrops(camera, width: W, height: H) }
        var boxes = [IndependentPersonBox]()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        let pose = VNDetectHumanBodyPoseRequest()
        for (i, r) in regions.enumerated() {
            let request = VNDetectHumanRectanglesRequest(); request.upperBodyOnly = false
            if i > 0 { request.regionOfInterest = CGRect(x: r.x / W, y: 1 - (r.y + r.h) / H, width: r.w / W, height: r.h / H) }
            guard (try? handler.perform(i == 0 && poseFill ? [request, pose] : [request])) != nil else { continue }
            for o in request.results ?? [] {
                // Normalized to the whole image (origin bottom-left) even with a region of interest; checked against
                // CGImage crops on test.MOV frames (same box within 2 px).
                let b = o.boundingBox
                boxes.append(IndependentPersonBox(x0: b.minX * W, y0: (1 - b.maxY) * H, x1: b.maxX * W, y1: (1 - b.minY) * H,
                                                  confidence: Double(o.confidence), fromCrop: i > 0, cropBottom: r.y + r.h))
            }
        }
        if poseFill {
            let extra = (pose.results ?? []).compactMap { Self.poseBox($0, width: W, height: H) }
                .filter { p in !boxes.contains { Self.overlaps($0, p) } }
            boxes += extra; poseAdded += extra.count
        }
        let frame = Int((pts * 60).rounded())
        Self.store(boxes, frame: frame, in: &byFrame)
        samples += 1; seconds += ProcessInfo.processInfo.systemUptime - start
        return (frame, boxes)
    }

    /// Keeps the latest `retainedSeconds` of boxes (shared with the trace replay).
    static func store(_ boxes: [IndependentPersonBox], frame: Int, in byFrame: inout [Int: [IndependentPersonBox]]) {
        byFrame[frame] = boxes
        byFrame = byFrame.filter { $0.key >= frame - 60 * retainedSeconds }
    }

    /// A person box from a body pose: joints above 0.2 confidence (at least 6), the feet at the lower ankle
    /// when one is seen, padded like a rectangle-detector box. Nil for poses under 20 px tall.
    static func poseBox(_ o: VNHumanBodyPoseObservation, width W: Double, height H: Double) -> IndependentPersonBox? {
        guard let points = try? o.recognizedPoints(.all) else { return nil }
        let good = points.values.filter { $0.confidence > 0.2 }
        guard good.count >= 6 else { return nil }
        let xs = good.map { Double($0.location.x) * W }, ys = good.map { (1 - Double($0.location.y)) * H }
        let ankles = [VNHumanBodyPoseObservation.JointName.leftAnkle, .rightAnkle].compactMap { points[$0] }.filter { $0.confidence > 0.2 }
        let y1 = ankles.isEmpty ? ys.max()! : ankles.map { (1 - Double($0.location.y)) * H }.max()!
        let y0 = ys.min()!, h = y1 - y0
        guard h > 20 else { return nil }
        return IndependentPersonBox(x0: xs.min()! - 0.1 * h, y0: y0 - 0.12 * h, x1: xs.max()! + 0.1 * h, y1: y1 + 0.03 * h,
                                    confidence: Double(o.confidence), fromCrop: false, cropBottom: H)
    }

    /// The pose box is already covered: IoU above 0.1, or either centre inside the other box.
    static func overlaps(_ a: IndependentPersonBox, _ p: IndependentPersonBox) -> Bool {
        let ix = max(0, min(a.x1, p.x1) - max(a.x0, p.x0)), iy = max(0, min(a.y1, p.y1) - max(a.y0, p.y0))
        let inter = ix * iy, union = a.width * a.height + p.width * p.height - inter
        if union > 0, inter / union > 0.1 { return true }
        let (cx, cy) = ((p.x0 + p.x1) / 2, (p.y0 + p.y1) / 2), (bx, by) = ((a.x0 + a.x1) / 2, (a.y0 + a.y1) / 2)
        return (a.x0...a.x1).contains(cx) && (a.y0...a.y1).contains(cy) || (p.x0...p.x1).contains(bx) && (p.y0...p.y1).contains(by)
    }

    /// `scripts/speed-fullvideo/far_crops.py`: the image box of the far half (players up to 2.2 m), a wide
    /// crop and three tighter ones (42 % of the width each).
    static func farCrops(_ camera: IndependentPinholeCamera, width W: Double, height H: Double) -> [(x: Double, y: Double, w: Double, h: Double)] {
        let cam = IndependentProjector(camera)
        var u = [Double](), v = [Double]()
        for x in [-7.0, 7.0] { for y in [13.0, 29.0] { for z in [0.0, 2.2] {
            let q = cam.project(SIMD3(x, y, z)); guard q.depth > 0 else { continue }; u.append(q.u); v.append(q.v)
        } } }
        guard let u0 = u.min(), let u1 = u.max(), let v0 = v.min(), let v1 = v.max() else { return [] }
        let x0: Double = max(0, floor(u0) - 20), y0: Double = max(0, floor(v0) - 20)
        let x1: Double = min(W, ceil(u1) + 20), y1: Double = min(H, ceil(v1) + 20)
        let w = x1 - x0, h = y1 - y0
        guard w > 16, h > 16 else { return [] }
        let tw: Double = (w * 0.42).rounded(.down)
        var crops: [(x: Double, y: Double, w: Double, h: Double)] = [(x0, y0, w, h)]
        for k in 0..<3 {
            let x: Double = (x0 + Double(k) * (w - tw) / 2).rounded(.down)
            crops.append((x, y0, tw, h))
        }
        return crops
    }
}

// MARK: - Analysis queue: the lane

/// Confined to one serial analysis queue.
public final class IndependentLiveEngine {
    public private(set) var configuration: IndependentLiveConfiguration
    private let ball: IndependentLiveBallStage
    private let personsStage: IndependentLivePeople
    private var shots = IndependentLiveShots()
    private var ids: [Int: UUID] = [:]           // published index -> stable row id
    private var streamID: UUID?
    private var lastUpdate = -Double.infinity, lastPTS = 0.0
    private var processed = 0
    public private(set) var candidates = 0
    private let court: IndependentLiveCourt?
    private var catchUpPending = false
    /// Last frame time at which the picture was moving: candidates from before it are never caught up.
    private var movedUntil = -Double.infinity
    /// The view the ball model's median background was taken from (motion thumbnail of the first full
    /// frame after it was built). The model finds the ball as what differs from that background, so
    /// once the phone has turned away from it every lamp, line and ball lying on the court differs
    /// too and long false flights follow (a hand-held phone filming a screen, 2026-11-05: 57 of 57 rows,
    /// analysis 10 s behind). Then the background is built again and nothing is stitched across.
    private var backgroundView: IndependentLiveCourt.Thumbnail?
    /// Displacement from the background's view that rebuilds it, in the court module's motion measure
    /// (`IndependentLiveCourt.motion`, median normal flow; it reads real moves smaller: a 23 px diagonal
    /// move of a test pattern reads about 5). A still tripod reads at most 3.4 a second apart; on
    /// double-test-003 (12 minutes, tripod) 6 never fired and all 589 rows stayed the same.
    static let backgroundMovedPixels = 6.0
    /// How often the background was rebuilt because the picture moved.
    public private(set) var backgroundRebuilds = 0
    /// Last frame time at which ball positions were dropped because the picture moved: discarded while
    /// moving with no court, or a background rebuilt.
    private var pictureMovedAt = -Double.infinity
    /// Seconds `pictureMoving` stays on after the last drop. A hand-held phone reads still and moving
    /// in alternate seconds (2026-11-05 log), and a rebuilt background needs about a second of warm-up
    /// before shots count again, so a shorter hold would flash on and off.
    static let movingHoldSeconds = 3.0
    /// The picture moved within the last `movingHoldSeconds`: shots are not being counted now.
    public var pictureMoving: Bool { lastPTS - pictureMovedAt <= Self.movingHoldSeconds }
    /// Seconds of candidates kept while the court is unknown, analysed once it is found.
    static let pendingSeconds = 30.0
    /// Diagnostics: every batch of ball candidates (analysis queue).
    public var candidateObserver: (([IndependentShotCandidate]) -> Void)?
    /// Diagnostics: every input of the shot rules, in order (analysis queue), for `IndependentLiveTrace.replay`.
    public var traceObserver: ((IndependentLiveTraceEvent) -> Void)?

    public init(configuration: IndependentLiveConfiguration) throws {
        self.configuration = configuration
        court = configuration.automaticCourt ? IndependentLiveCourt(camera: configuration.camera) : nil
        personsStage = IndependentLivePeople(poseFill: configuration.poseFill)
        ball = IndependentLiveBallStage(model: try IndependentBallModel(modelURL: try configuration.loadAssets().modelURL, computeUnits: configuration.computeUnits))
    }

    /// Seconds between rule updates (L2 load shedding slows them to once a second).
    public var updateInterval: Double {
        get { configuration.updateInterval }
        set { configuration.updateInterval = max(0.05, newValue) }
    }

    /// Setting a camera from outside (fixed) replaces the automatic one until it is re-checked.
    public var camera: IndependentPinholeCamera? {
        get { configuration.camera }
        set { court?.adopt(newValue, pts: lastPTS); use(newValue) }
    }

    private func use(_ camera: IndependentPinholeCamera?) {
        let wasKnown = configuration.camera != nil
        configuration.camera = camera
        traceObserver?(.camera(camera))
        if camera == nil { shots.freeze(); traceObserver?(.freeze) } else if !wasKnown { catchUpPending = true }
    }

    /// The framing changed (zoom): the automatic court is dropped and searched for again. Without the
    /// automatic court (a fixed camera) nothing changes.
    public func restartCourt() {
        guard let court else { return }
        court.restart(); use(nil)
    }

    /// The court solve in use (nil while searching, for a fixed camera, or with automatic court off).
    public var courtCalibration: IndependentCourtCalibration? { configuration.camera == nil ? nil : court?.latest }

    /// Stream change, pause or a dropped frame: new warm-up, nothing stitched across.
    public func restart() {
        ball.reset(); shots.reset(); personsStage.reset(); lastUpdate = -.infinity
        traceObserver?(.reset); traceObserver?(.peopleReset)
    }

    /// One frame: `small` is the 512×288 RGB8 copy; `full` is a full-resolution analysis-owned copy on
    /// person frames (or nil). Returns a snapshot when rows changed or on each update.
    public func process(small: [UInt8], full: CVPixelBuffer?, pts: Double, streamID: UUID,
                        sourceWidth: Int, sourceHeight: Int) throws -> TennisAnalysisSnapshot? {
        processed += 1; lastPTS = pts
        if self.streamID != streamID {
            self.streamID = streamID; ids.removeAll(); shots = IndependentLiveShots(); movedUntil = -.infinity
            pictureMovedAt = -.infinity
            traceObserver?(.newStream)
            court?.streamChanged(pts: pts)
            if configuration.camera != nil { catchUpPending = false }
        }
        if let court, let change = court.offer(full, pts: pts) {
            switch change {
            case .found(let camera), .moved(let camera): use(camera)
            case .lost: use(nil)
            }
        }
        if full != nil, let view = court?.frameThumbnail { checkBackground(view) }
        if full != nil, let court, court.moving, configuration.camera == nil {
            // ball positions seen while the phone moves and no court is known belong to no single pose:
            // never caught up later (a court being tracked keeps them)
            movedUntil = pts; pictureMovedAt = pts; shots.trim(keeping: 0, now: pts); traceObserver?(.discard(before: pts))
        }
        if let full {
            let found = personsStage.detect(full, pts: pts, camera: configuration.camera)
            traceObserver?(.people(frame: found.frame, boxes: found.boxes))
        }
        let broke = try ball.append(rgb: small, pts: pts, streamID: streamID, sourceWidth: sourceWidth, sourceHeight: sourceHeight) { batch in
            candidates += batch.count
            candidateObserver?(batch)
            traceObserver?(.candidates(batch))
            shots.append(batch)
            if batch.contains(where: { $0.time / 60 < movedUntil }) {        // a batch late from the moving frames
                shots.trim(keeping: 0, now: movedUntil); traceObserver?(.discard(before: movedUntil))
            }
        }
        if broke { shots.reset(); personsStage.reset(); traceObserver?(.reset); traceObserver?(.peopleReset) }
        guard pts - lastUpdate >= configuration.updateInterval else { return nil }
        lastUpdate = pts
        return update(now: pts)
    }

    /// Full frames with a motion thumbnail: remembers the view of a fresh background and, when the
    /// picture has moved more than `backgroundMovedPixels` from it, starts a new warm-up. While the phone
    /// keeps moving this repeats and no shot is found: unknown stays empty rather than counting false
    /// flights. Rows already published stay as they are (frozen).
    private func checkBackground(_ view: IndependentLiveCourt.Thumbnail) {
        guard ball.backgroundReady else { backgroundView = nil; return }
        guard let reference = backgroundView else { backgroundView = view; return }
        guard IndependentLiveCourt.motion(reference, view) > Self.backgroundMovedPixels else { return }
        ball.reset(); shots.reset(); backgroundView = nil; backgroundRebuilds += 1; pictureMovedAt = lastPTS
        traceObserver?(.reset)
    }

    /// End of a segment: settle every remaining shot.
    public func finish() -> TennisAnalysisSnapshot? {
        guard streamID != nil else { return nil }
        let snapshot = update(now: lastPTS + shots.options.settleLag + 0.05)
        restart()
        return snapshot
    }

    private func update(now: Double) -> TennisAnalysisSnapshot? {
        guard let camera = configuration.camera, let streamID else {
            shots.trim(keeping: Self.pendingSeconds, now: now)
            traceObserver?(.trim(now: now))
            return snapshot(events: [])
        }
        let start = ProcessInfo.processInfo.systemUptime
        traceObserver?(catchUpPending ? .catchUp(now: now) : .update(now: now))
        let changed = catchUpPending ? shots.catchUp(now: now, camera: camera, people: personsStage.people)
                                     : shots.update(now: now, camera: camera, people: personsStage.people)
        catchUpPending = false
        var rows = [TennisShotEvent]()
        for i in changed {
            var row = IndependentShotPipeline.rows(from: [shots.published[i].shot], streamID: streamID)[0]
            if let id = ids[i] { row.id = id } else { ids[i] = row.id }
            rows.append(row)
        }
        return snapshot(events: rows, milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    private func snapshot(events: [TennisShotEvent], milliseconds: Double = 0) -> TennisAnalysisSnapshot? {
        guard let streamID else { return nil }
        return TennisAnalysisSnapshot(streamID: streamID, pts: lastPTS, processedFrames: processed, inferenceMilliseconds: milliseconds,
                                      events: events, calibration: courtState, modelVersion: configuration.modelVersion,
                                      limitations: IndependentLiveConfiguration.limitations)
    }

    /// What the camera screen says about the court. Unknown stays unknown: no camera, no mapping.
    var courtState: TennisCourtCalibrationState {
        guard configuration.camera != nil else {
            // A slight sway is normal (a phone hung on a fence): it is searched frame by frame, and the
            // reason shown is what the last frame lacked. Only a real shake is named.
            let refusal = court?.latest?.refusals.first?.message
            if court?.shaking == true, refusal == nil {
                return TennisCourtCalibrationState(isAvailable: false, landmarkCount: 0, validationErrorMeters: nil,
                                                   reason: "正在识别球场 · 画面晃动较大，逐帧识别中")
            }
            return TennisCourtCalibrationState(isAvailable: false, landmarkCount: 0, validationErrorMeters: nil,
                                               reason: refusal.map { "正在识别球场 · " + $0 } ?? "正在识别球场")
        }
        guard let solve = courtCalibration else {
            return TennisCourtCalibrationState(isAvailable: true, landmarkCount: 0, validationErrorMeters: nil, reason: "使用给定的球场位置")
        }
        var text = "自动识别 · \(solve.linesUsed.count) 条球场线"
        if let rms = solve.fitRMS { text += String(format: " · 对齐误差 %.1f 像素", rms) }
        if solve.quality == .partial { text += " · 部分球场线不在画面里，建议调整机位" }
        return TennisCourtCalibrationState(isAvailable: true, landmarkCount: solve.linesUsed.count, validationErrorMeters: nil, reason: text)
    }

    public struct Stats: Sendable {
        public var batches: Int, inferenceSeconds: Double, personSamples: Int, personSeconds: Double, ballResets: Int, published: Int, candidates: Int
        public var courtSolves = 0, courtSolveSeconds = 0.0, courtSamples = 0, courtFound = 0, courtMoved = 0, courtLost = 0
        /// Ball backgrounds rebuilt because the picture moved away from them (counted in `ballResets` too).
        public var backgroundRebuilds = 0
        /// The picture moved within the last few seconds, so shots are not being counted (`pictureMoving`).
        public var pictureMoving = false
        /// The court right now, for the camera's field log (nil with neither automatic nor given court).
        public var court: CameraCourtDiagnostics?
    }
    public var stats: Stats {
        var s = Stats(batches: ball.batches, inferenceSeconds: ball.inferenceSeconds, personSamples: personsStage.samples, personSeconds: personsStage.seconds,
                      ballResets: ball.resets, published: shots.published.count, candidates: candidates)
        s.backgroundRebuilds = backgroundRebuilds; s.pictureMoving = pictureMoving
        if let c = court?.stats {
            s.courtSolves = c.solves; s.courtSolveSeconds = c.solveSeconds; s.courtSamples = c.samples
            s.courtFound = c.found; s.courtMoved = c.moved; s.courtLost = c.lost
        }
        if let court { s.court = court.diagnostics }
        else if let camera = configuration.camera {
            var fixed = CameraCourtDiagnostics(state: .fixed); fixed.geometry(of: camera); s.court = fixed
        }
        return s
    }

    /// Waits for a court solve in flight (file runs and tests).
    public func drainCourt() { court?.drain() }
}
