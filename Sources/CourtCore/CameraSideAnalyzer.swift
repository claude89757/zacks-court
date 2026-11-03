import Foundation
import CoreVideo
import CoreML
import CoreImage
import Vision

/// Tennis analysis on the capturing device, fed directly from the capture callback.
///
/// The capture buffer is never retained: only frames the cadence reads (at 60 fps, 3 of every 6)
/// are copied into a bounded, analysis-owned pool; all other frames are PTS ticks. A full pool or
/// queue drops that frame and explicitly restarts the temporal run instead of pairing non-adjacent
/// frames. Bounce localization runs on its own lane with its own model runtime, at most one
/// job in flight, so its spikes cannot stall the ~10 Hz pair cadence.
///
/// Without a tennis configuration (no model bundle) it still runs the 1 Hz auxiliary person
/// detection. Load shedding can turn person detection and bounce localization off, widen the court
/// refresh interval, or stop admission entirely; resuming always restarts the temporal run.
public final class CameraSideAnalyzer: @unchecked Sendable {
    public struct Metrics: Codable, Sendable {
        public var ready = false
        public var loadSeconds: Double?
        public var loadError: String?
        public var submittedFrames = 0, warmupFrames = 0
        public var tickFrames = 0, pixelFrames = 0, copies = 0
        public var poolExhausted = 0, queueOverflows = 0
        public var restarts = 0, resyncs = 0, pixelMisses = 0, engineErrors = 0
        public var processedFrames = 0, pairs = 0, snapshots = 0, shots = 0
        public var pendingFrames = 0, maximumPendingFrames = 0
        public var latestSubmittedPTS: Double?, lastAnalyzedPTS: Double?
        public var analysisBusySeconds = 0.0, bounceBusySeconds = 0.0
        public var bounceRequests = 0, bounceRejectedBusy = 0, bounceResolved = 0, bounceDetached = 0, bounceErrors = 0
        public var probes = 0, probesSkippedBusy = 0, probeCandidates = 0
        public var pausedFrames = 0, bounceShed = 0, personSamples = 0
        public var tennisAvailable = false
        public var lastError: String?
        /// In-house live lane (zero for the S家 lane).
        public var inHouse = false, scaledFrames = 0, scaleFailures = 0, ballBatches = 0, ballResets = 0
        public var ballInferenceSeconds = 0.0, personSamplesLive = 0, personSecondsLive = 0.0, ballCandidates = 0, publishedShots = 0
        /// Automatic court (in-house lane): solves, their seconds on the utility queue, frames sampled, and
        /// how often the court was found, moved or lost.
        public var courtSolves = 0, courtSolveSeconds = 0.0, courtSamples = 0, courtFound = 0, courtMoved = 0, courtLost = 0
        public init() {}
    }
    /// Milliseconds since the previous drain.
    public struct Timings: Sendable {
        public var copy: [Double] = [], anchor: [Double] = [], pair: [Double] = []
        /// Submit (capture callback) to snapshot emission for pair frames.
        public var latency: [Double] = []
        public var bounce: [Double] = [], probe: [Double] = []
        /// In-house lane: capture-queue 512×288 scale per frame.
        public var scale: [Double] = []
        public init() {}
    }
    private struct Work: @unchecked Sendable {
        let pts: Double, streamID: UUID, pixels: CVPixelBuffer?, slot: Int?, restart: Bool, submitted: Double
        var small: [UInt8]? = nil, sourceWidth = 0, sourceHeight = 0
        var updateInterval: Double? = nil
    }

    private let worker = DispatchQueue(label: "court.camera-analysis", qos: .utility)
    private let bounceLane = DispatchQueue(label: "court.camera-bounce", qos: .utility)
    private let lock = NSLock()
    private let maximumBuffers: Int, maximumPending: Int
    private let probeInterval: Double?
    private let pairDelay: Int, sourceFPS: Double
    // Shared, guarded by lock.
    private var metrics = Metrics()
    private var timings = Timings()
    private var resyncRequested = false
    private var bounceInFlight = false
    private var closed = false
    private var snapshotHandler: ((TennisAnalysisSnapshot) -> Void)?
    private var updateHandler: (([TennisShotEvent]) -> Void)?
    private var peopleHandler: ((AnalysisSnapshot) -> Void)?
    private var admissionEnabled = true
    private var bounceEnabled = true
    private var personEnabled = true
    // Capture-queue confined (the caller's single serial capture queue).
    private var cadence: TennisFrameCadence
    private var restartNext = false
    private var pool: CVPixelBufferPool?
    private var poolFormat: OSType = 0, poolWidth = 0, poolHeight = 0
    private let liveConfiguration: IndependentLiveConfiguration?
    private let scaler = IndependentLiveFrameScaler()
    private var liveFrames = 0
    // Worker confined.
    private var engine: ReferenceLaneEngine?
    private var live: IndependentLiveEngine?
    private var ledger: [UUID: TennisShotEvent] = [:]
    private var probeAnchor: (pixels: CVPixelBuffer, pts: Double)?
    private var lastProbePTS = -Double.infinity
    private let tracker = PersonTracker(maximumMissingSeconds: 2.5)
    private var lastPersonPTS = -Double.infinity
    private var lastFrame: (pixels: CVPixelBuffer, streamID: UUID)?
    private static let ledgerLimit = 600
    // Bounce-lane confined.
    private var bounceRuntime: ReferenceBounceResolver?

    /// Called on the analysis worker queue; return promptly.
    public var onSnapshot: ((TennisAnalysisSnapshot) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return snapshotHandler }
        set { lock.lock(); snapshotHandler = newValue; lock.unlock() }
    }
    /// Late bounce results for rows that already left the engine's 24-row window (worker queue).
    public var onEventUpdate: (([TennisShotEvent]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return updateHandler }
        set { lock.lock(); updateHandler = newValue; lock.unlock() }
    }
    /// Auxiliary 1 Hz person detection (worker queue). Image coordinates only.
    public var onPeople: ((AnalysisSnapshot) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return peopleHandler }
        set { lock.lock(); peopleHandler = newValue; lock.unlock() }
    }
    /// L3 load shedding: stop admitting frames. Resuming restarts the temporal run.
    public var isAdmitting: Bool {
        get { lock.lock(); defer { lock.unlock() }; return admissionEnabled }
        set { lock.lock(); if admissionEnabled != newValue { admissionEnabled = newValue; resyncRequested = true }; lock.unlock() }
    }
    /// L2 load shedding: new bounce candidates are marked unknown instead of localized.
    public var isLocalizingBounces: Bool {
        get { lock.lock(); defer { lock.unlock() }; return bounceEnabled }
        set { lock.lock(); bounceEnabled = newValue; lock.unlock() }
    }
    /// L1 load shedding: auxiliary person detection off.
    public var isDetectingPeople: Bool {
        get { lock.lock(); defer { lock.unlock() }; return personEnabled }
        set { lock.lock(); personEnabled = newValue; lock.unlock() }
    }

    /// `loadProbeInterval` (source seconds) adds a measurement-only bounce job on recent frames,
    /// approximating one bounce per shot when no real court is in view. Probe results are discarded.
    /// `independent` selects the in-house live lane instead of the S家 models (never both).
    public init(configuration: TennisAnalysisConfiguration?, nominalFPS: Double = 60, maximumBuffers: Int = 18,
                maximumPendingFrames: Int = 240, loadProbeInterval: Double? = nil, independent: IndependentLiveConfiguration? = nil) {
        var configuration = independent == nil ? configuration : nil
        liveConfiguration = independent
        configuration?.defersBounceLocalization = true
        self.maximumBuffers = max(6, maximumBuffers)
        maximumPending = max(12, maximumPendingFrames)
        probeInterval = loadProbeInterval.flatMap { $0 > 0 ? $0 : nil }
        let fps = configuration?.nominalFPS ?? nominalFPS
        cadence = TennisFrameCadence(fps: fps)
        pairDelay = cadence.delay; sourceFPS = fps
        // Model loading and SHA-256 verification never run on the capture or main queue.
        worker.async { [self] in
            let start = ProcessInfo.processInfo.systemUptime
            if let independent {
                do {
                    live = try IndependentLiveEngine(configuration: independent)
                    lock.lock(); metrics.tennisAvailable = true; metrics.inHouse = true; lock.unlock()
                } catch {
                    lock.lock(); metrics.loadError = error.localizedDescription; lock.unlock()
                }
                lock.lock(); metrics.ready = true; metrics.loadSeconds = ProcessInfo.processInfo.systemUptime - start; lock.unlock()
                return
            }
            guard let configuration else {
                lock.lock(); metrics.ready = true; metrics.loadSeconds = 0; lock.unlock(); return
            }
            do {
                let engine = try ReferenceChain.laneEngine(configuration)
                let runtime = try ReferenceChain.bounceResolver(configuration)
                bounceLane.sync { bounceRuntime = runtime }
                self.engine = engine
                lock.lock(); metrics.ready = true; metrics.tennisAvailable = true
                metrics.loadSeconds = ProcessInfo.processInfo.systemUptime - start; lock.unlock()
            } catch {
                // Person detection still runs; tennis rows stay unknown with this reason.
                lock.lock(); metrics.loadError = error.localizedDescription; metrics.ready = true; lock.unlock()
            }
        }
    }

    public var currentMetrics: Metrics { lock.lock(); defer { lock.unlock() }; return metrics }
    public func drainTimings() -> Timings {
        lock.lock(); defer { lock.unlock() }
        let value = timings; timings = Timings(); return value
    }

    /// Call from the single serial capture callback queue. Never retains `pixelBuffer`.
    public func submit(_ pixelBuffer: CVPixelBuffer, pts: Double, streamID: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        metrics.submittedFrames += 1; metrics.latestSubmittedPTS = pts
        let ready = metrics.ready && !closed, admitting = admissionEnabled
        let resync = resyncRequested, pending = metrics.pendingFrames, shedPeople = !personEnabled, shedBounces = !bounceEnabled
        if ready && admitting { resyncRequested = false }
        if !ready { metrics.warmupFrames += 1 } else if !admitting { metrics.pausedFrames += 1 }
        if ready && admitting && resync { metrics.resyncs += 1 }
        lock.unlock()
        guard ready, admitting else { restartNext = true; return }
        if let liveConfiguration {
            // The in-house rules need person boxes, so shedding slows them instead of turning them off:
            // L1 3 Hz, L2 2 Hz with rule updates once a second (docs/model-replacement-design.md §3.4).
            let base = liveConfiguration.personInterval
            let interval = shedBounces ? max(base, 30) : shedPeople ? max(base, 20) : base
            submitInHouse(pixelBuffer, pts: pts, streamID: streamID, restart: restartNext || resync, now: now,
                          pending: pending, personInterval: interval, updateInterval: shedBounces ? max(1, liveConfiguration.updateInterval) : liveConfiguration.updateInterval)
            restartNext = false
            return
        }
        if restartNext || resync { cadence.restart(); restartNext = false }
        let restarted = cadence.advance(pts: pts, streamID: streamID)
        guard pending < maximumPending else {
            lock.lock(); metrics.queueOverflows += 1; lock.unlock()
            restartNext = true; return
        }
        var copy: CVPixelBuffer?
        var copyMilliseconds: Double?
        if cadence.needsPixels {
            let start = ProcessInfo.processInfo.systemUptime
            copy = makeCopy(pixelBuffer)
            guard copy != nil else {
                lock.lock(); metrics.poolExhausted += 1; lock.unlock()
                restartNext = true; return
            }
            copyMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        let work = Work(pts: pts, streamID: streamID, pixels: copy, slot: cadence.slot, restart: restarted, submitted: now)
        lock.lock()
        metrics.pendingFrames += 1; metrics.maximumPendingFrames = max(metrics.maximumPendingFrames, metrics.pendingFrames)
        if restarted { metrics.restarts += 1 }
        if let copyMilliseconds { metrics.copies += 1; timings.copy.append(copyMilliseconds) }
        lock.unlock()
        worker.async { [self] in process(work) }
    }

    /// In-house lane, capture queue: a constant-size vImage scale of every frame, plus a full-resolution
    /// pool copy on person frames (also the latest-frame source for previews and calibration).
    private func submitInHouse(_ pixelBuffer: CVPixelBuffer, pts: Double, streamID: UUID, restart: Bool, now: Double,
                               pending: Int, personInterval: Int, updateInterval: Double) {
        guard pending < maximumPending else {
            lock.lock(); metrics.queueOverflows += 1; lock.unlock()
            restartNext = true; return
        }
        let start = ProcessInfo.processInfo.systemUptime
        guard let small = scaler.scale(pixelBuffer) else {
            lock.lock(); metrics.scaleFailures += 1; metrics.lastError = "自研分析不支持这种像素格式"; lock.unlock(); return
        }
        let scaleMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        liveFrames += 1
        var copy: CVPixelBuffer?
        if liveFrames % personInterval == 1 || personInterval == 1 {
            copy = makeCopy(pixelBuffer)
            if copy == nil { lock.lock(); metrics.poolExhausted += 1; lock.unlock() }   // a missed person sample is not a break
        }
        var work = Work(pts: pts, streamID: streamID, pixels: copy, slot: copy == nil ? nil : 0, restart: restart, submitted: now,
                        small: small, sourceWidth: CVPixelBufferGetWidth(pixelBuffer), sourceHeight: CVPixelBufferGetHeight(pixelBuffer))
        work.updateInterval = updateInterval
        lock.lock()
        metrics.pendingFrames += 1; metrics.maximumPendingFrames = max(metrics.maximumPendingFrames, metrics.pendingFrames)
        metrics.scaledFrames += 1; timings.scale.append(scaleMilliseconds)
        if restart { metrics.restarts += 1 }
        if copy != nil { metrics.copies += 1 }
        lock.unlock()
        worker.async { [self] in process(work) }
    }

    /// Diagnostics for the in-house lane: ball candidates as they are found (analysis queue).
    public func observeIndependentCandidates(_ observer: @escaping ([IndependentShotCandidate]) -> Void) {
        worker.async { [self] in live?.candidateObserver = observer }
    }

    /// Diagnostics for the in-house lane: every input of the shot rules, in order (analysis queue), for
    /// replaying a run with changed rules (`IndependentLiveTrace.replay`).
    public func observeIndependentTrace(_ observer: @escaping (IndependentLiveTraceEvent) -> Void) {
        worker.async { [self] in live?.traceObserver = observer }
    }

    /// Fixes the in-house lane's camera from outside (tests, tools); the lane normally finds the court
    /// itself. Ball tracking continues; the shot rules use the new camera from the next update.
    public func setIndependentCamera(_ camera: IndependentPinholeCamera?) {
        worker.async { [self] in live?.camera = camera }
    }

    /// Segment boundary (pause, finish, capture stop). Already-admitted frames are analysed, the
    /// open row is concluded, and the bounce lane drains so late results for this segment land;
    /// then the final rows are delivered. The next admitted frame starts a new temporal run.
    public func seal(completion: @escaping @Sendable (TennisAnalysisSnapshot?, [TennisShotEvent]) -> Void) {
        worker.async { [self] in
            let final = engine?.finish() ?? live?.finish()
            if let final { merge(final) }
            engine?.reset(); probeAnchor = nil
            lock.lock(); resyncRequested = true; lock.unlock()
            bounceLane.async { [self] in
                worker.async { [self] in
                    let rows = final.map { snapshot in snapshot.events.compactMap { ledger[$0.id] } } ?? []
                    completion(final, rows)
                }
            }
        }
    }

    /// New hands without reloading models; the temporal run restarts. `restartCourt` (the framing changed)
    /// also drops the automatic court so it is searched for again in the new picture.
    public func reconfigure(near: TennisHandedness, far: TennisHandedness, restartCourt: Bool = false,
                            completion: (@Sendable (String?) -> Void)? = nil) {
        worker.async { [self] in
            var failure: String?
            do {
                try engine?.reconfigure(near: near, far: far)
                if restartCourt { live?.restartCourt() }
            } catch { failure = error.localizedDescription }
            probeAnchor = nil
            lock.lock(); resyncRequested = true; lock.unlock()
            completion?(failure)
        }
    }

    /// L2 load shedding widens the reference lane's court refreshes (minimum 2 s).
    public func setCourtRefreshInterval(_ seconds: Double) {
        worker.async { [self] in engine?.courtRefreshInterval = seconds }
    }

    /// Only a reference to the latest analysed frame, taken on the worker queue without encoding,
    /// so the browser preview can scale and encode it elsewhere (docs/web-display.md §6).
    public func latestFrameBuffer(streamID: UUID? = nil, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
        worker.async { [self] in
            guard let frame = lastFrame, streamID == nil || frame.streamID == streamID else { completion(nil); return }
            completion(frame.pixels)
        }
    }

    /// Test seam: queue a bounce job for a synthetic row on the latest analysed frame pair.
    func testingQueueBounce(for event: TennisShotEvent) {
        worker.async { [self] in
            guard let frame = lastFrame else { return }
            ledger[event.id] = event
            dispatch(TennisBounceRequest(eventID: event.id, streamID: event.streamID, pts: event.sourcePTS,
                                         first: frame.pixels, second: frame.pixels, courtScores: engine?.currentCourtScores))
        }
    }

    /// Stops admission, drains admitted frames and the bounce lane, then returns the full ledger.
    public func finish(completion: @escaping @Sendable ([TennisShotEvent], Metrics) -> Void) {
        lock.lock(); closed = true; lock.unlock()
        worker.async { [self] in
            if let final = engine?.finish() ?? live?.finish() { merge(final) }
            bounceLane.async { [self] in
                worker.async { [self] in
                    let events = ledger.values.sorted { $0.sourcePTS < $1.sourcePTS }
                    completion(events, currentMetrics)
                }
            }
        }
    }

    private func process(_ work: Work) {
        let start = ProcessInfo.processInfo.systemUptime
        // Person tracking handles stream changes and timestamp regressions itself.
        if work.restart { engine?.reset(); live?.restart(); probeAnchor = nil }
        let misses = engine?.pixelMisses ?? 0
        var snapshot: TennisAnalysisSnapshot?
        var failure: String?
        if let live, let small = work.small {
            if let interval = work.updateInterval { live.updateInterval = interval }
            do { snapshot = try autoreleasepool { try live.process(small: small, full: work.pixels, pts: work.pts, streamID: work.streamID,
                                                                    sourceWidth: work.sourceWidth, sourceHeight: work.sourceHeight) } }
            catch { live.restart(); failure = error.localizedDescription }
        } else if let engine {
            do { snapshot = try autoreleasepool { try engine.process(work.pixels, pts: work.pts, streamID: work.streamID) } }
            catch { engine.reset(); failure = error.localizedDescription }
        }
        let missed = (engine?.pixelMisses ?? 0) != misses
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if let snapshot { merge(snapshot) }
        for request in engine?.takeBounceRequests() ?? [] { dispatch(request) }
        trackProbe(work)
        if let pixels = work.pixels, work.slot == 0 {
            lastFrame = (pixels, work.streamID)
            detectPeople(pixels, pts: work.pts, streamID: work.streamID)
        }
        lock.lock()
        metrics.pendingFrames -= 1; metrics.processedFrames += 1; metrics.analysisBusySeconds += elapsed
        metrics.lastAnalyzedPTS = work.pts
        if work.pixels == nil { metrics.tickFrames += 1 } else { metrics.pixelFrames += 1 }
        if work.slot == 0 { timings.anchor.append(elapsed * 1000) }
        if let slot = work.slot, slot == pairDelay {
            metrics.pairs += 1; timings.pair.append(elapsed * 1000)
        }
        if snapshot != nil {
            metrics.snapshots += 1
            timings.latency.append((ProcessInfo.processInfo.systemUptime - work.submitted) * 1000)
        }
        if let failure { metrics.engineErrors += 1; metrics.lastError = failure; resyncRequested = true }
        if missed { metrics.pixelMisses += 1; resyncRequested = true }
        metrics.shots = ledger.count
        if let stats = live?.stats {
            metrics.ballBatches = stats.batches; metrics.ballResets = stats.ballResets; metrics.ballInferenceSeconds = stats.inferenceSeconds
            metrics.personSamplesLive = stats.personSamples; metrics.personSecondsLive = stats.personSeconds
            metrics.ballCandidates = stats.candidates; metrics.publishedShots = stats.published
            metrics.courtSolves = stats.courtSolves; metrics.courtSolveSeconds = stats.courtSolveSeconds; metrics.courtSamples = stats.courtSamples
            metrics.courtFound = stats.courtFound; metrics.courtMoved = stats.courtMoved; metrics.courtLost = stats.courtLost
        }
        let handler = snapshotHandler
        lock.unlock()
        if let snapshot { handler?(snapshot) }
    }

    private func merge(_ snapshot: TennisAnalysisSnapshot) {
        for event in snapshot.events { ledger[event.id] = event }
        if ledger.count > Self.ledgerLimit {
            for old in ledger.values.sorted(by: { $0.sourcePTS < $1.sourcePTS }).prefix(ledger.count - Self.ledgerLimit) {
                ledger.removeValue(forKey: old.id)
            }
        }
    }

    /// Worker queue, at most once per source second, on an analysis-owned copy.
    private func detectPeople(_ pixels: CVPixelBuffer, pts: Double, streamID: UUID) {
        lock.lock(); let enabled = personEnabled, handler = peopleHandler; lock.unlock()
        guard enabled, handler != nil, pts - lastPersonPTS >= 1 - 0.00001 else { return }
        lastPersonPTS = pts
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let request = VNDetectHumanRectanglesRequest(); request.upperBodyOnly = false
            #if targetEnvironment(simulator)
            try Self.configureCPUComputeDevices(for: request)
            #endif
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([request])
            let detections = (request.results ?? []).map { observation in
                let r = observation.boundingBox
                return PersonDetection(box: NormalizedBox(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height), confidence: Double(observation.confidence))
            }
            let snapshot = tracker.update(detections: detections, streamID: streamID, pts: pts,
                                          analysisMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
            lock.lock(); metrics.personSamples += 1; lock.unlock()
            handler?(snapshot)
        } catch {
            lock.lock(); metrics.lastError = "人体检测失败：\(error.localizedDescription)"; lock.unlock()
        }
    }

    /// Simulator runtimes can advertise a GPU/ANE route whose inference context cannot be created.
    private static func configureCPUComputeDevices(for request: VNRequest) throws {
        let supported = try request.supportedComputeStageDevices
        guard let mainCPU = supported[.main]?.first(where: { if case .cpu = $0 { return true }; return false }) else {
            throw CourtError.message("此模拟器的人体检测不支持 CPU 推理。")
        }
        request.setComputeDevice(mainCPU, for: .main)
        for (stage, devices) in supported where stage != .main {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) { request.setComputeDevice(cpu, for: stage) }
        }
    }

    private func trackProbe(_ work: Work) {
        guard let interval = probeInterval, let pixels = work.pixels, let slot = work.slot else { return }
        if slot == 0 { probeAnchor = (pixels, work.pts); return }
        guard slot == 1, let anchor = probeAnchor, work.pts - anchor.pts <= 1.5 / sourceFPS else { return }
        guard work.pts - lastProbePTS >= interval else { return }
        lock.lock(); let busy = bounceInFlight; if busy { metrics.probesSkippedBusy += 1 }; lock.unlock()
        guard !busy else { return }
        lastProbePTS = work.pts
        dispatch(TennisBounceRequest(eventID: nil, streamID: work.streamID, pts: anchor.pts, first: anchor.pixels,
                                     second: pixels, courtScores: engine?.currentCourtScores))
    }

    private func dispatch(_ request: TennisBounceRequest) {
        lock.lock()
        if request.eventID != nil, !bounceEnabled {
            metrics.bounceShed += 1; lock.unlock()
            if let id = request.eventID {
                applyBounce(id, .init(sourcePTS: request.pts, confidence: 0, reason: "设备降载期间未做触地定位"), nil, resolved: false)
            }
            return
        }
        if bounceInFlight {
            if request.eventID != nil { metrics.bounceRejectedBusy += 1 }
            lock.unlock()
            if let id = request.eventID {
                applyBounce(id, .init(sourcePTS: request.pts, confidence: 0, reason: "触地定位队列繁忙，未定位"), nil, resolved: false)
            }
            return
        }
        bounceInFlight = true
        if request.eventID == nil { metrics.probes += 1 } else { metrics.bounceRequests += 1 }
        lock.unlock()
        bounceLane.async { [self] in
            let start = ProcessInfo.processInfo.systemUptime
            var resolved: (estimate: TennisBounceEstimate, mapping: TennisCourtMapping?)?
            var failure: String?
            if let runtime = bounceRuntime {
                do {
                    resolved = try autoreleasepool { try runtime.resolve(request) }
                } catch { failure = error.localizedDescription }
            } else { failure = "触地定位模型未加载" }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            lock.lock()
            bounceInFlight = false; metrics.bounceBusySeconds += elapsed
            if request.eventID == nil {
                timings.probe.append(elapsed * 1000)
                if resolved?.estimate.imagePoint != nil { metrics.probeCandidates += 1 }
            } else { timings.bounce.append(elapsed * 1000) }
            if let failure { metrics.bounceErrors += 1; metrics.lastError = failure }
            lock.unlock()
            guard let id = request.eventID else { return }
            let estimate = resolved?.estimate ?? .init(sourcePTS: request.pts, confidence: 0, reason: "触地定位失败：\(failure ?? "未知错误")")
            let succeeded = resolved != nil
            worker.async { [self] in applyBounce(id, estimate, resolved?.mapping, resolved: succeeded) }
        }
    }

    /// Worker queue. The engine copy is updated when the row is still in its window; the ledger always is.
    private func applyBounce(_ id: UUID, _ estimate: TennisBounceEstimate, _ mapping: TennisCourtMapping?, resolved: Bool) {
        let snapshot = engine?.applyBounce(eventID: id, estimate: estimate, mapping: mapping)
        var detached: TennisShotEvent?
        if let snapshot { merge(snapshot) } else if var event = ledger[id] { event.bounce = estimate; ledger[id] = event; detached = event }
        lock.lock()
        if snapshot == nil { metrics.bounceDetached += 1 }
        if resolved { metrics.bounceResolved += 1 }
        let handler = snapshotHandler, update = updateHandler
        lock.unlock()
        if let snapshot { handler?(snapshot) } else if let detached { update?([detached]) }
    }

    /// Capture queue. Plane-wise copy into the bounded pool; nil when the pool is at its threshold.
    private func makeCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        if pool == nil || poolFormat != format || poolWidth != width || poolHeight != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created) == kCVReturnSuccess,
                  let created else { return nil }
            pool = created; poolFormat = format; poolWidth = width; poolHeight = height
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        let threshold = [kCVPixelBufferPoolAllocationThresholdKey: maximumBuffers] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, threshold, &output) == kCVReturnSuccess,
              let output else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []); CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        func copyRows(_ from: UnsafeMutableRawPointer, _ to: UnsafeMutableRawPointer, rows: Int, sourceStride: Int, targetStride: Int) {
            if sourceStride == targetStride { memcpy(to, from, sourceStride * rows); return }
            let count = min(sourceStride, targetStride)
            for row in 0..<rows { memcpy(to + row * targetStride, from + row * sourceStride, count) }
        }
        if CVPixelBufferIsPlanar(source) {
            guard CVPixelBufferGetPlaneCount(source) == CVPixelBufferGetPlaneCount(output) else { return nil }
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let to = CVPixelBufferGetBaseAddressOfPlane(output, plane) else { return nil }
                copyRows(from, to, rows: CVPixelBufferGetHeightOfPlane(source, plane),
                         sourceStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                         targetStride: CVPixelBufferGetBytesPerRowOfPlane(output, plane))
            }
        } else {
            guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(output) else { return nil }
            copyRows(from, to, rows: height, sourceStride: CVPixelBufferGetBytesPerRow(source),
                     targetStride: CVPixelBufferGetBytesPerRow(output))
        }
        CVBufferPropagateAttachments(source, output)
        return output
    }
}
