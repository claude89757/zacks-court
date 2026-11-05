import Foundation

/// Bounded-lag (live) form of the in-house shot chain. It re-runs the shot rules on a sliding window of
/// recent ball candidates and publishes a shot once its flight has settled: its last used observation is
/// older than `settleLag` (or its hit is older than `maxLag`). A shot keeps its identity by hit time and may be revised while it is still
/// well inside the window; after that it is frozen. Nothing is stitched across `reset()`.
public struct IndependentLiveShots: Sendable {
    public struct Options: Sendable {
        /// Seconds of past candidates re-analysed on every update.
        public var window = 6.0
        /// A shot is shown once its last observation is this many seconds old.
        public var settleLag = 0.6
        /// ... or once its hit is this many seconds old, settled or not (v17). A flight the tracker keeps
        /// chaining (through a missed bounce and the return) settled only after its hit had left the
        /// recomputed part of the window, and was never shown.
        public var maxLag = 2.0
        /// Shots whose hit is closer than this to the window start are not (re)computed: their incoming
        /// flight and hitter search would be cut.
        public var margin = 1.5
        public init() {}
    }

    public struct Published: Sendable {
        public var shot: IndependentShotResult
        /// Stream seconds when the shot was first published, and when a reported speed first appeared.
        public var firstPublished: Double
        public var speedPublished: Double?
        public var revisions = 0
        public var frozen = false
    }

    public let options: Options
    public private(set) var published: [Published] = []
    private var buffer: [IndependentShotCandidate] = []
    private var streamStart: Double?
    /// Index into `published` of the first shot after the last `reset()`: earlier shots are not history
    /// for the serve rules (no stitching across a break).
    private var historyStart = 0
    private var serveCache: IndependentShotPipeline.ServeRefitCache? = IndependentShotPipeline.ServeRefitCache()

    public init(options: Options = Options()) { self.options = options }

    /// New candidates, in presentation order (time in 1/60 s units, like the batch chain).
    public mutating func append(_ candidates: [IndependentShotCandidate]) {
        if streamStart == nil, let first = candidates.first { streamStart = first.time / 60 }
        buffer += candidates
    }

    /// A temporal break (stream change, dropped frames, camera moved): forget the candidates, keep what
    /// was published, and freeze it.
    public mutating func reset() {
        buffer.removeAll(); streamStart = nil; historyStart = published.count; serveCache = IndependentShotPipeline.ServeRefitCache()
        for i in published.indices { published[i].frozen = true }
    }

    /// Freeze everything published (the court was lost: later rules must not revise those shots), but
    /// keep the candidates for when it is found again.
    public mutating func freeze() {
        for i in published.indices { published[i].frozen = true }
    }

    /// While the court is not known: keep at most `seconds` of candidates before `now`. Flights cut by
    /// the trim are not treated as starting the stream.
    public mutating func trim(keeping seconds: Double, now: Double) {
        let start = now - seconds
        guard let first = buffer.first, first.time / 60 < start else { return }
        buffer.removeAll { $0.time / 60 < start }
        if let s = streamStart, s < start { streamStart = nil }
    }

    /// The court was just found: one pass over every kept candidate (longer than the window), as the
    /// offline chain would, then normal updates continue.
    @discardableResult
    public mutating func catchUp(now: Double, camera: IndependentPinholeCamera, people: IndependentPeople) -> [Int] {
        let first = min(buffer.first.map { $0.time / 60 } ?? now, streamStart ?? .infinity)
        return run(now: now, start: min(first, now - options.window), camera: camera, people: people)
    }

    /// Re-run the rules up to `now` (stream seconds). Returns the indices of `published` that are new or
    /// changed. `people` must answer for the window's frames.
    @discardableResult
    public mutating func update(now: Double, camera: IndependentPinholeCamera, people: IndependentPeople) -> [Int] {
        run(now: now, start: now - options.window, camera: camera, people: people)
    }

    private mutating func run(now: Double, start: Double, camera: IndependentPinholeCamera, people: IndependentPeople) -> [Int] {
        buffer.removeAll { $0.time / 60 < start }
        let begin = max(start, streamStart ?? start)
        let segment = IndependentShotPipeline.Segment(camera: camera, start: begin, end: now)
        // rally flights already published near or before the window start: serve rules need a few seconds of history
        let history: [IndependentShotResult] = published[historyStart...].map(\.shot)
        let returns = IndependentStrokeRules.serveReturns(
            history, like: Set(history.indices.filter { (i: Int) -> Bool in IndependentStrokeRules.isServeLike(history[i]) }))
        let prior: [Double] = history.indices.filter { (i: Int) -> Bool in
            history[i].tHit < begin + options.margin && IndependentStrokeRules.isRallyFlight(history[i]) && !returns.contains(i)
        }.map { (i: Int) -> Double in history[i].tHit }
        serveCache?.prune(before: start - 1)
        let shots = IndependentShotPipeline.run(candidates: buffer, segments: [segment], priorRally: prior, serveCache: &serveCache) { _, _ in people }
        // shots too close to the window start cannot be recomputed fairly (unless the stream began there)
        let earliest = (streamStart.map { $0 >= start } ?? false) ? begin : start + options.margin
        for i in published.indices where !published[i].frozen && published[i].shot.tHit < earliest { published[i].frozen = true }

        var changed = [Int]()
        for shot in shots where shot.tHit >= earliest
            && (Double(shot.lastFrame) / 60 < now - options.settleLag || shot.tHit < now - options.maxLag) {
            if let i = Self.match(shot, in: published, from: historyStart) {
                guard !published[i].frozen, !Self.same(published[i].shot, shot) else { continue }
                guard Self.replaces(published[i].shot, with: shot) else { continue }
                published[i].shot = shot; published[i].revisions += 1
                if published[i].speedPublished == nil, shot.reportedSpeedKmh != nil { published[i].speedPublished = now }
                changed.append(i)
            } else {
                published.append(Published(shot: shot, firstPublished: now, speedPublished: shot.reportedSpeedKmh == nil ? nil : now))
                changed.append(published.count - 1)
            }
        }
        return changed
    }

    /// The published shot a recomputed one revises (v19): the one since the last `reset()` whose flight
    /// starts at the same frame, else the nearest hit within 0.25 s. (The first hit within 0.25 s let a
    /// re-timed serve take over the shot before it, and the serve was then published twice.)
    static func match(_ shot: IndependentShotResult, in published: [Published], from start: Int) -> Int? {
        if let i = published[start...].lastIndex(where: { $0.shot.firstFrame == shot.firstFrame }) { return i }
        var best: (i: Int, d: Double)?
        for i in published.indices {
            let d = abs(published[i].shot.tHit - shot.tHit)
            if d < 0.25, best == nil || d < best!.d { best = (i, d) }
        }
        return best?.i
    }

    /// A recomputation may replace an existing row, except as a shorter, bounce-less version of a row that
    /// already found a bounce: with the same flight start a fragment (8 points) was published over the row
    /// that had the bounce (test.MOV 264.02, 2026-11-06) and the near-side call was lost.
    static func replaces(_ existing: IndependentShotResult, with shot: IndependentShotResult) -> Bool {
        !(existing.bounceFound && !shot.bounceFound && shot.nObs < existing.nObs)
    }

    static func same(_ a: IndependentShotResult, _ b: IndependentShotResult) -> Bool {
        a.tHit == b.tHit && a.stroke == b.stroke && a.reportedSpeedKmh == b.reportedSpeedKmh
            && a.bounceFound == b.bounceFound && a.reason == b.reason && a.nObs == b.nObs
            && a.bounceGround == b.bounceGround   // a moved bounce can change its line call
    }
}
