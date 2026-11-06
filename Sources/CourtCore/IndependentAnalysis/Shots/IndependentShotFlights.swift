import Foundation
import simd

/// A person box from Apple Vision, top-left pixels. `fromCrop` boxes cut by their crop's bottom edge
/// have unknown feet and are ignored.
public struct IndependentPersonBox: Sendable, Equatable, Codable {
    public var x0: Double, y0: Double, x1: Double, y1: Double
    public var confidence: Double
    public var fromCrop: Bool
    public var cropBottom: Double?
    public init(x0: Double, y0: Double, x1: Double, y1: Double, confidence: Double, fromCrop: Bool, cropBottom: Double?) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1; self.confidence = confidence; self.fromCrop = fromCrop; self.cropBottom = cropBottom
    }
    /// `people.swift` layout: [x0, y0, x1, y1, confidence, fromCrop(0/1), cropBottom?].
    public init?(array a: [Double]) {
        guard a.count >= 6 else { return nil }
        self.init(x0: a[0], y0: a[1], x1: a[2], y1: a[3], confidence: a[4], fromCrop: a[5] == 1, cropBottom: a.count > 6 ? a[6] : nil)
    }
    var width: Double { x1 - x0 }
    var height: Double { y1 - y0 }
    var centre: SIMD2<Double> { SIMD2((x0 + x1) / 2, (y0 + y1) / 2) }
}

/// Person boxes by frame (1/60 s units of presentation time, rounded).
public struct IndependentPeople: Sendable {
    public let byFrame: [Int: [IndependentPersonBox]]
    let keys: [Int]
    public init(_ byFrame: [Int: [IndependentPersonBox]]) { self.byFrame = byFrame; keys = byFrame.keys.sorted() }

    /// Drop crop-cut boxes, then non-maximum suppression (IoU >= 0.4) by confidence.
    static func clean(_ boxes: [IndependentPersonBox]) -> [IndependentPersonBox] {
        let keep = boxes.filter { b in
            !(b.fromCrop && (b.cropBottom.map { [$0] } ?? [720, 660]).contains { abs(b.y1 - $0) < 3 })
        }
        let sorted = IndependentBallEvents.stableSorted(keep) { $0.confidence > $1.confidence }
        var out = [IndependentPersonBox]()
        for b in sorted {
            var iou = 0.0
            for o in out {
                let ix = max(0, min(b.x1, o.x1) - max(b.x0, o.x0)), iy = max(0, min(b.y1, o.y1) - max(b.y0, o.y0))
                let inter = ix * iy, uni = b.width * b.height + o.width * o.height - inter
                iou = max(iou, inter / max(uni, 1))
            }
            if iou < 0.4 { out.append(b) }
        }
        return out
    }
    /// Boxes from the nearest detection frame within +-reach frames.
    func at(_ frame: Int, reach: Int = 6) -> [IndependentPersonBox] {
        guard !keys.isEmpty else { return [] }
        let i = lowerBound(frame)
        var best: Int?
        for j in [i - 1, i] where j >= 0 && j < keys.count && abs(keys[j] - frame) <= reach {
            if best == nil || abs(keys[j] - frame) < abs(best! - frame) { best = keys[j] }
        }
        return best.map { Self.clean(byFrame[$0] ?? []) } ?? []
    }
    func lowerBound(_ x: Int) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi { let m = (lo + hi) / 2; if keys[m] < x { lo = m + 1 } else { hi = m } }
        return lo
    }
}

/// One shot flight: hit to first bounce (or to the end of the chain), with the evidence used.
public struct IndependentShotFlight: Sendable {
    public enum HitKind: String, Sendable, Codable { case junction = "hit junction", afterToss = "after toss", firstObservation = "first observation" }
    var points: [IndependentTrackPoint]
    var tHit: Double                       // 1/60 s units
    var hitter: IndependentPersonBox?
    var bounce: (t: Double, ground: SIMD3<Double>)?
    var kind: HitKind
    var contact: SIMD2<Double>
    var incoming: [IndependentTrackPoint]?
    var hitterSide: String?
    /// A serve: contact depth (court y, metres) taken from the server's own baseline instead of the feet (v16).
    var serveDepth: Double?
    /// The flight leaves a serve toss: after a toss piece, or at a junction where a toss turns into a serve (v17).
    var fromToss = false
    /// Serve speed refits: the fitted flight must reach the ground in the receiver's service box (v17).
    var landingPrior = false
    /// Serve refits: the contact measured from the glued toss (v19), time in 1/60 s units and court position.
    var tossContact: (t: Double, P: SIMD3<Double>)?
    /// Serve refits: the last toss point trimmed from the flight (v21, 1/60 s units). The ball was still in
    /// the toss then, so the contact is not earlier.
    var tossEnd: Double?
    /// A chain start: the latest ball point of another piece in the 0.6 s before it, next to its first point
    /// (v21, 1/60 s units). The ball was still on its way there, so serve refits do not put the contact earlier.
    var seenBefore: Double?
    /// Serve speed refits (v21): the contact is not put before `tossEnd`, the incoming flight or `seenBefore`.
    /// Recognition refits leave it free.
    var contactBounded = false
    /// Serve recognition refits (v22): the contact is not put before the toss's end (a trimmed toss, or the
    /// toss a flight leaves). The ball on its way (`seenBefore`) is left to the speed refits.
    var tossBounded = false
}

/// Result per shot flight (field names follow `shots.py` for parity checks).
public struct IndependentShotResult: Sendable, Codable {
    public var hitKind: String
    public var hitterFound: Bool
    public var bounceFound: Bool
    public var contactUV: [Double]
    public var hitterBox: IndependentPersonBox?
    public var incoming: [[Double]]?
    public var hitterSide: String?
    public var tHit: Double               // seconds
    public var nObs: Int
    public var firstFrame: Int, lastFrame: Int
    public var hitterFeet: [Double]?
    public var bounceGround: [Double]?
    public var tBounce: Double?           // seconds
    public var rmsPx: Double?
    public var maxPx: Double?
    public var fitHit: [Double]?
    public var vInstKmh: Double?
    public var fitNetZ: Double?
    public var fitNetX: Double?
    /// The same endpoint with this model's drag inverted, for comparison only (2026-11-07).
    public var speedDragKmh: Double?
    public var endKind: String?
    public var intervalS: Double?
    public var speedKmh: Double?
    /// Hit-to-first-bounce speed (v23): the endpoint formula from the contact to the first ground contact past
    /// the net (the tracked bounce, else the fitted flight's), and that ground point's court y. Serves are
    /// shown with it, as S家 shows them.
    public var landSpeedKmh: Double?
    public var landY: Double?
    /// The definition of a shown serve speed (v23): "bounce" (hit to first bounce) or nil (hit to net).
    public var speedTo: String?
    public var droppedOutliers: Int?
    public var fallback: String?
    /// Fitted height (m) at the last ball observation: well below 0 means the flight ran through a bounce.
    public var zLastFit: Double?
    /// Fitted depth (m, court y) at the last ball observation (v17).
    public var yLastFit: Double?
    /// How far (m) the fitted flight climbs above the contact before its last observation (v22): a lob or a
    /// ball fed between points climbs, a serve hardly does.
    public var riseM: Double?
    /// The rise of the serve hypothesis refit that set `serveFit` (v22).
    public var serveRise: Double?
    /// Seen by a low camera (v22, `IndependentStrokeRules.lowCamera`).
    public var lowCamera: Bool?
    /// Serve refits: where the fitted flight first reaches the ground, court [x, y] in metres (v17).
    public var landing: [Double]?
    /// Ball observations after the fitted net crossing.
    public var pastNetCount: Int?
    /// What anchors a serve speed found by the serve refit (v16); nil for every other flight.
    public var speedAnchor: SpeedAnchor?
    public var reason: String?
    public var accepted = false
    public var segment = 0
    public var stroke: String?
    public var strokeReason: String?
    /// How the flight started, before `hitKind` is relabelled by the reach step (diagnostics, replay JSON).
    public var startKind: String?
    /// The fitted flight crosses the net plane before its end (serve and rally rules).
    public var crossesNet: Bool?
    /// Standard deviation (m) of `bounceGround` x and y: 2 px of image noise through the ground mapping
    /// plus half a frame of the ball's ground travel. Read by line calls only.
    public var bounceSigma: [Double]?
    /// Hitter's feet behind their own baseline in the image, in box heights (serve rule; positive: outside).
    public var serveBehindPx: Double?
    /// The flight leaves a serve toss (v17; `IndependentShotFlight.fromToss`).
    public var fromToss: Bool?
    /// Which serve refit gave the shown serve speed: "refit" (whole flight, v16) or "hypothesis" (v17).
    public var serveSpeedFrom: String?
    /// The flight's first `ServeSpeed.hypothesisSeconds`, refitted with the contact at the server's baseline,
    /// cross the net from a serve contact height (v17): serve evidence for a flight whose own fit failed.
    public var serveFit: Bool?
    /// The serve hypothesis held from the other end than the hitter box's (v18): on a low camera the near
    /// players' boxes cover the far court, and a far serve was given a near hitter.
    public var serveOtherEnd: Bool?
    /// Serve contact time (s) from a refit that trimmed a glued toss (v18); rows report it instead of `tHit`.
    public var contactT: Double?
    /// Speed shown to the user: accepted and anchored at a detected bounce (the frozen primary gate), or a
    /// serve speed anchored at the server's baseline that passed the serve checks (v16).
    public var reportedSpeedKmh: Double? { accepted && (bounceFound || speedAnchor == .serveBaseline || speedAnchor == .serveNet) ? speedKmh : nil }

    public enum SpeedAnchor: String, Sendable, Codable {
        /// A bounce found inside the serve's own track (the tracker did not split it), service box only.
        case serveBounce = "serve bounce"
        /// No bounce: contact at the server's baseline, flight well observed past the net.
        case serveBaseline = "serve baseline"
        /// Serve into the net (v18): contact at the server's baseline, the flight ends on the net plane.
        case serveNet = "serve net"
    }
}

enum IndependentShotFlights {
    static let fps = 60.0
    static let netY = IndependentCourt.netY

    // MARK: people helpers

    static func personNear(_ boxes: [IndependentPersonBox], _ uv: SIMD2<Double>) -> IndependentPersonBox? {
        var best: (Double, IndependentPersonBox)?
        for b in boxes {
            let w = b.width, h = b.height
            if b.x0 - w <= uv.x && uv.x <= b.x1 + w && b.y0 - 0.3 * h <= uv.y && uv.y <= b.y1 {
                let d = simd_length(uv - b.centre) / h
                if best == nil || d < best!.0 { best = (d, b) }
            }
        }
        return best?.1
    }
    /// A box under the point: horizontally within one width, the point at most one box height above its top.
    static func personBelow(_ boxes: [IndependentPersonBox], _ uv: SIMD2<Double>) -> IndependentPersonBox? {
        var best: (Double, IndependentPersonBox)?
        for b in boxes where b.x0 - b.width <= uv.x && uv.x <= b.x1 + b.width && b.y0 - b.height <= uv.y && uv.y <= b.y1 {
            let d = simd_length(uv - b.centre) / b.height
            if best == nil || d < best!.0 { best = (d, b) }
        }
        return best?.1
    }
    static func personNearest(_ boxes: [IndependentPersonBox], _ uv: SIMD2<Double>, maxHeights: Double = 2.5) -> IndependentPersonBox? {
        var best: (Double, IndependentPersonBox)?
        for b in boxes {
            let d = simd_length(uv - b.centre) / b.height
            if d <= maxHeights && (best == nil || d < best!.0) { best = (d, b) }
        }
        return best?.1
    }
    static func feet(_ b: IndependentPersonBox, _ cam: IndependentProjector) -> SIMD3<Double> {
        cam.onPlaneZ((b.x0 + b.x1) / 2, b.y1, z: 0)
    }
    static func sideBoxes(_ boxes: [IndependentPersonBox], _ cam: IndependentProjector, wantNear: Bool) -> [IndependentPersonBox] {
        boxes.filter { (feet($0, cam).y < netY) == wantNear }
    }
    static func sideBoxesNearTime(_ people: IndependentPeople, _ frame: Int, _ cam: IndependentProjector, wantNear: Bool, reach: Int = 30) -> [IndependentPersonBox] {
        let lo = people.lowerBound(frame - reach), hi = people.lowerBound(frame + reach + 1)
        let ks = IndependentBallEvents.stableSorted(Array(people.keys[lo..<hi])) { abs($0 - frame) < abs($1 - frame) }
        for k in ks {
            let c = sideBoxes(IndependentPeople.clean(people.byFrame[k] ?? []), cam, wantNear: wantNear)
            if !c.isEmpty { return c }
        }
        return []
    }
    /// Hitter for a flight with a known bounce: the opposite side; without one, the strict match only.
    static func chooseHitter(_ boxes: [IndependentPersonBox], _ uv: SIMD2<Double>, _ cam: IndependentProjector,
                             bounce: (t: Double, ground: SIMD3<Double>)?, people: IndependentPeople, frame: Int) -> IndependentPersonBox? {
        guard let bounce else { return personNear(boxes, uv) }
        let wantNear = bounce.ground.y > netY
        let cand = sideBoxes(boxes, cam, wantNear: wantNear)
        if let h = personNear(cand, uv) ?? personNearest(cand, uv, maxHeights: 6) { return h }
        return personNearest(sideBoxesNearTime(people, frame, cam, wantNear: wantNear), uv, maxHeights: 12)
    }
    /// Hitter side: nearest box within 1.5 box heights (+-6 frames), else the ball's image direction.
    static func inferSide(_ people: IndependentPeople, _ frame: Int, _ uv: SIMD2<Double>, _ pts: [IndependentTrackPoint], _ cam: IndependentProjector) -> String {
        var best: (Double, IndependentPersonBox)?
        for kk in (frame - 6)...(frame + 6) {
            for b in IndependentPeople.clean(people.byFrame[kk] ?? []) {
                let d = simd_length(uv - b.centre) / b.height
                if best == nil || d < best!.0 { best = (d, b) }
            }
        }
        if let best, best.0 < 1.5 { return sideBoxes([best.1], cam, wantNear: true).isEmpty ? "far" : "near" }
        return pts[pts.count - 1].v - pts[0].v > 0 ? "far" : "near"
    }
    static func chooseOnSide(_ people: IndependentPeople, _ frame: Int, _ uv: SIMD2<Double>, _ cam: IndependentProjector, wantNear: Bool) -> IndependentPersonBox? {
        let cand = sideBoxes(people.at(frame), cam, wantNear: wantNear)
        if let h = personNear(cand, uv) ?? personNearest(cand, uv, maxHeights: 6) { return h }
        return personNearest(sideBoxesNearTime(people, frame, cam, wantNear: wantNear), uv, maxHeights: 12)
    }
    /// Longest flight treated as a serve toss when it is dropped as a shot of its own.
    static let tossMaxSeconds = 1.2
    /// Frames a toss may run on past the start of the serve flight (v17). On far serves the tracker keeps a
    /// slowly falling candidate (the ball at contact, or the server's hand) for a few frames after the serve
    /// flight has started as its own piece, so the toss "ends" 0.03-0.1 s after the serve begins.
    static let tossOverlap = 9.0
    /// Frames the toss must have started before the serve flight, so an overlapping toss is a real toss.
    static let tossLead = 12.0
    /// A point of another piece this close (px) to a chain start, at most 0.6 s before it: the ball on its way (v21).
    static let seenBeforePx = 60.0
    /// A serve toss: >= 0.25 s, mostly vertical image motion, rising then falling inside the piece.
    static func isToss(_ P: [IndependentTrackPoint]?) -> Bool {
        guard let P, P.count >= 6, (P[P.count - 1].t - P[0].t) / fps >= 0.25 else { return false }
        let du = abs(P[P.count - 1].u - P[0].u)
        let vs = P.map(\.v), vr = vs.max()! - vs.min()!
        let i = vs.firstIndex(of: vs.min()!)!
        return vr > 20 && du <= 0.35 * vr && 1 <= i && i <= P.count - 2
    }

    // MARK: chains of pieces -> shot flights

    /// `tossEnds`: pieces that end where a toss turns into the serve (`IndependentBallEvents.tossCut`); they
    /// count as serve tosses even when the whole piece is not toss-shaped (the toss drifts sideways).
    static func flights(pieces pcs: [[IndependentTrackPoint]], junctions links: [IndependentJunction],
                        people: IndependentPeople, camera cam: IndependentProjector, tossEnds: Set<Int> = []) -> [IndependentShotFlight] {
        enum Kind { case bounce, hit, continuation }
        var kinds = [Kind](repeating: .continuation, count: links.count)
        var persons = [IndependentPersonBox?](repeating: nil, count: links.count)
        var pred = [Int: Int](), succ = [Int: Int](), tossJunctions = Set<Int>()
        for (n, l) in links.enumerated() { pred[l.b] = n; succ[l.a] = n }
        for (n, l) in links.enumerated() {
            if l.bounce { kinds[n] = .bounce; continue }
            let k = IndependentNumerics.pyRound(l.t * fps)
            var b = personNear(people.at(k), SIMD2(l.u, l.v))
            let serveTurn = IndependentBallEvents.tossThenServe(pcs[l.a], pcs[l.b])
            if serveTurn { tossJunctions.insert(n) }
            // the end of a serve toss: contact can be well above the server's box (racket arm out of it)
            if b == nil, isToss(pcs[l.a]) || tossEnds.contains(l.a) || serveTurn { b = personBelow(people.at(k), SIMD2(l.u, l.v)) }
            // an unseen hitter (near player below the frame): a sharp reversal is still a hit, and so is a
            // toss turning into a serve
            let reversal = IndependentBallEvents.turnDegrees(pcs[l.a], pcs[l.b]) >= 120 && pcs[l.a].count >= 6 && pcs[l.b].count >= 6
            kinds[n] = (b != nil || reversal || serveTurn) ? .hit : .continuation
            persons[n] = b
        }
        var jobs = [([Int], Int?, Int?)]()
        for i in pcs.indices where pred[i] == nil {
            var flight = [i], start: Int? = nil, j = i
            while true {
                let l = succ[j]
                if l == nil || kinds[l!] != .continuation {
                    jobs.append((flight, start, l))
                    guard let l else { break }
                    flight = [links[l].b]; start = l
                } else {
                    flight.append(links[l!].b)
                }
                j = links[l!].b
            }
        }
        var out = [IndependentShotFlight]()
        for (flight, start, end) in jobs {
            if let start, kinds[start] == .bounce { continue }   // post-bounce flight
            var pts = flight.flatMap { pcs[$0] }
            // a serve toss is the incoming flight of the serve, not a shot of its own: drop it when a hit
            // ends it, or when a flight starts right after it (within 0.6 s and 200 px of its last point)
            let tossShaped = isToss(pts) || (flight.count == 1 && tossEnds.contains(flight[0]))
                || (end.map { tossJunctions.contains($0) } ?? false)
            if start == nil, tossShaped, (pts[pts.count - 1].t - pts[0].t) / fps <= tossMaxSeconds {
                if let end, kinds[end] == .hit { continue }
                let e = pts[pts.count - 1]
                if end == nil, pcs.indices.contains(where: { pred[$0] == nil && e.t - tossOverlap < pcs[$0][0].t && pcs[$0][0].t <= e.t + 36
                                                              && pts[0].t + tossLead < pcs[$0][0].t
                                                              && simd_length(pcs[$0][0].uv - e.uv) < 200 }) { continue }
            }
            var bounce: (t: Double, ground: SIMD3<Double>)?
            if let end, kinds[end] == .bounce {
                pts = pts.filter { $0.t < links[end].t * fps }
                bounce = (links[end].t, links[end].ground!)
            }
            var tHit: Double, hitter: IndependentPersonBox?, kind: IndependentShotFlight.HitKind
            var contact: SIMD2<Double>, incoming: [IndependentTrackPoint]? = nil, seen: Double?
            if let start {
                let l = links[start]
                tHit = l.t * fps; hitter = persons[start]; kind = .junction
                if let h = hitter, let bounce, sideBoxes([h], cam, wantNear: bounce.ground.y > netY).isEmpty {
                    let f = IndependentNumerics.pyRound(tHit)
                    hitter = chooseHitter(people.at(f), SIMD2(l.u, l.v), cam, bounce: bounce, people: people, frame: f)
                }
                contact = SIMD2(l.u, l.v); incoming = pcs[l.a]
                pts = pts.filter { $0.t > tHit }
            } else {
                // a chain start: look for a serve toss that ended just before (<= 0.6 s, within 200 px)
                let t0 = pts[0].t, uv0 = pts[0].uv
                var toss: [IndependentTrackPoint]?
                for (q, Q) in pcs.enumerated() {
                    let e = Q[Q.count - 1]
                    if t0 - 36 <= e.t && e.t < t0 + tossOverlap && Q[0].t + tossLead < t0 && simd_length(e.uv - uv0) < 200
                        && (isToss(Q) || tossEnds.contains(q)) {
                        if toss == nil || e.t > toss![toss!.count - 1].t { toss = Q }
                    }
                }
                if let toss {
                    let e = toss[toss.count - 1]
                    tHit = (e.t + t0) / 2; kind = .afterToss; contact = e.uv; incoming = toss
                    let f = IndependentNumerics.pyRound(tHit)
                    hitter = chooseHitter(people.at(f), e.uv, cam, bounce: bounce, people: people, frame: f)
                } else {
                    tHit = t0; kind = .firstObservation; contact = uv0
                    seen = pcs.compactMap { (Q: [IndependentTrackPoint]) -> Double? in
                        Q.last(where: { (e: IndependentTrackPoint) -> Bool in
                            t0 - 36 <= e.t && e.t < t0 && simd_length(e.uv - uv0) < seenBeforePx })?.t }.max()
                    let f = IndependentNumerics.pyRound(t0)
                    hitter = chooseHitter(people.at(f), uv0, cam, bounce: bounce, people: people, frame: f)
                }
            }
            if pts.isEmpty { continue }
            let f = IndependentNumerics.pyRound(tHit)
            // ... or a toss glued to the flight's start (v22): the tracker joined the toss's fall to the serve
            let fromToss = kind == .afterToss || (start.map { tossJunctions.contains($0) } ?? false) || tossTrimmed(pts).count < pts.count
            let side = inferSide(people, f, contact, pts, cam)
            if hitter == nil || sideBoxes([hitter!], cam, wantNear: side == "near").isEmpty {
                hitter = chooseOnSide(people, f, contact, cam, wantNear: side == "near")
            }
            var flight = IndependentShotFlight(points: pts, tHit: tHit, hitter: hitter, bounce: bounce, kind: kind,
                                               contact: contact, incoming: incoming, hitterSide: side)
            flight.fromToss = fromToss; flight.seenBefore = seen
            out.append(flight)
        }
        return out
    }

    // MARK: shot fit and speed

    static let reachFrames = 48      // 0.8 s searched backwards for the hitter's depth (v17; was 0.4 s)
    static let hitSigma = 0.8

    /// Frame time at which the flight, extrapolated back from tHit, is at the hitter's depth, and the height there.
    static func reachTime(_ x: IndependentFlight.State, F0: Int, tHit: Double, depth y: Double) -> (Double?, Double) {
        let grid = (0...reachFrames).map { tHit - Double($0) }
        let S = IndependentFlight.simulate(x, grid.map { $0 - Double(F0) })
        if !S.allSatisfy(\.isFinite) { return (nil, 1e3) }
        let d = S.map { $0.p.y - y }
        if d[0] == 0 { return (tHit, S[0].p.z) }
        guard let k = d.indices.first(where: { IndependentNumerics.sign(d[$0]) != IndependentNumerics.sign(d[0]) }) else { return (nil, S[S.count - 1].p.y) }
        let den = d[k - 1] - d[k]
        let f = den != 0 ? d[k - 1] / den : 0
        return (grid[k - 1] - f, S[k - 1].p.z + f * (S[k].p.z - S[k - 1].p.z))
    }

    struct HitPrior { var t: Double; var y: Double; var sigma: Double }

    static let landingSteps = 40      // serve landing search: 3-frame steps after the hit (2 s)

    static func fitShot(_ cam: IndependentProjector, frames: [Double], uv: [SIMD2<Double>], F0: Int, x0: IndependentFlight.State,
                        hit: HitPrior?, bounce: (t: Double, P: SIMD3<Double>)?, iterations: Int, huber: Double = 4,
                        landing: ClosedRange<Double>? = nil, contact: (t: Double, P: SIMD3<Double>)? = nil,
                        notBefore: Double? = nil) -> (IndependentFlight.State, [Double], Double) {
        let rel = frames.map { $0 - Double(F0) }
        let ahead: [Double] = landing == nil ? [] : (0...landingSteps).map { (k: Int) -> Double in (hit?.t ?? Double(F0)) - Double(F0) + Double(3 * k) }
        let res: ([Double]) -> [Double] = { X in
            let x = IndependentFlight.State(X)
            var r = IndependentFlight.pixelResiduals(IndependentFlight.simulate(x, rel), uv, cam)
            if let hit {
                let (t, v) = reachTime(x, F0: F0, tHit: hit.t, depth: hit.y)
                r.append(t == nil ? 2.0 * (v - hit.y) / hit.sigma : 2.0 * max(0.0, 0.2 - v, v - 3.5) / 0.3)
                // serve speed refits (v21): the server's depth is not reached before the ball was last seen in the toss
                if let notBefore { r.append(t.map { 2.0 * max(0.0, notBefore - $0) / ServeSpeed.notBeforeSigma } ?? 0) }
            }
            if let bounce {
                let s = IndependentFlight.state(at: bounce.t, from: x, F0: F0)
                r += [2.0 * (s.p.x - bounce.P.x) / 0.1, 2.0 * (s.p.y - bounce.P.y) / 0.1, 2.0 * (s.p.z - bounce.P.z) / 0.03]
            }
            if let contact {
                let s = IndependentFlight.state(at: contact.t, from: x, F0: F0), d = ServeSpeed.contactSigma
                r += [2.0 * (s.p.x - contact.P.x) / d.x, 2.0 * (s.p.y - contact.P.y) / d.y, 2.0 * (s.p.z - contact.P.z) / d.z]
            }
            if let landing {
                // serve landing (v17): the fitted flight reaches the ground in the receiver's service box
                let L = IndependentFlight.simulate(x, ahead)
                var y = L[L.count - 1].p.y
                if let k = L.indices.first(where: { (k: Int) -> Bool in k > 0 && L[k].p.z <= IndependentCourt.ballRadius }) {
                    let a = L[k - 1].p, b = L[k].p, f = (a.z - IndependentCourt.ballRadius) / max(a.z - b.z, 1e-9)
                    y = a.y + f * (b.y - a.y)
                }
                r.append(2.0 * max(0.0, landing.lowerBound - y, y - landing.upperBound) / ServeSpeed.landingSigma)
            }
            return r
        }
        let (x, r) = IndependentFlight.levenbergMarquardt(x0: x0.array, steps: [1e-4, 1e-4, 1e-4, 1e-3, 1e-3, 1e-3],
                                                         stopScale: [1, 1, 1, 10, 10, 10], pointCount: uv.count,
                                                         iterations: iterations, huber: huber, residuals: res)
        let (e, rms) = IndependentFlight.errors(r, pointCount: uv.count, huber: huber)
        return (IndependentFlight.State(x), e, rms)
    }

    static func analyse(_ job: IndependentShotFlight, camera cam: IndependentProjector) -> IndependentShotResult {
        let frames = job.points.map(\.t), uv = job.points.map(\.uv)
        var res = IndependentShotResult(hitKind: job.kind.rawValue, hitterFound: job.hitter != nil, bounceFound: job.bounce != nil,
                                        contactUV: [job.contact.x, job.contact.y], hitterBox: job.hitter,
                                        incoming: job.incoming?.map { [$0.t, $0.u, $0.v] }, hitterSide: job.hitterSide,
                                        tHit: job.tHit / fps, nObs: frames.count, firstFrame: Int(frames[0]), lastFrame: Int(frames[frames.count - 1]))
        res.startKind = job.kind.rawValue
        if job.fromToss { res.fromToss = true }
        if frames.count < 8 { res.reason = "fewer than 8 ball observations between hit and bounce"; return res }
        var tHit = job.tHit
        var hit: HitPrior?
        if let h = job.hitter {
            let ft = feet(h, cam)
            hit = HitPrior(t: tHit, y: ft.y + 0.5 * (ft.y < netY ? 1 : -1), sigma: hitSigma)
            res.hitterFeet = [ft.x, ft.y, ft.z]
        }
        var landing: ClosedRange<Double>?
        if let d = job.serveDepth {
            hit = HitPrior(t: tHit, y: d, sigma: ServeSpeed.depthSigma)
            if job.bounce == nil, job.landingPrior {
                let m = ServeSpeed.landingMargin, box = IndependentCourtModel.serviceFromNet
                landing = d < netY ? (netY - m)...(netY + box + m) : (netY - box - m)...(netY + m)
            }
        }
        var bnc: (t: Double, P: SIMD3<Double>)?
        if let b = job.bounce {
            bnc = (b.t * fps, b.ground)
            res.bounceGround = [b.ground.x, b.ground.y, b.ground.z]; res.tBounce = b.t
        }
        if hit == nil && bnc == nil { res.reason = "no depth anchor (no bounce and no hitter found)"; return res }
        let F0 = IndependentNumerics.pyRound(tHit)
        var inits = [IndependentFlight.State]()
        if let bnc {
            let m = frames.indices.filter { frames[$0] < bnc.t }
            if m.count >= 4 {
                let fb = IndependentFlight.bestAnchored(cam, frames: m.map { frames[$0] }, uv: m.map { uv[$0] }, anchor: bnc.P, at: bnc.t, before: true)
                let (Fb, Sb) = IndependentFlight.anchoredState(bnc.P, at: bnc.t, velocity: fb.velocity)
                inits.append(IndependentFlight.simulate(Sb, [Double(F0 - Fb)])[0])
            }
        }
        if let hit {
            let tw = hit.y < netY ? 1.0 : -1.0
            let ys0 = [hit.y - 1, hit.y, hit.y + 1, hit.y + 2 * tw, hit.y + 4 * tw]
            let rel0 = frames.map { $0 - frames[0] }
            for g0 in IndependentFlight.initialGuesses(cam, frames: rel0, uv: uv, ys0: ys0) {
                inits.append(IndependentFlight.simulate(g0, [Double(F0) - frames[0]])[0])
            }
        }
        if inits.isEmpty { res.reason = "no initial flight hypothesis"; return res }
        var best: (IndependentFlight.State, [Double], Double)?
        // a contact measured from the toss (v19) replaces the depth prior: it fixes the time as well
        let contact = job.tossContact
        if contact != nil { hit = nil }
        // serve speed refits (v21): the contact is not before the ball's last observation in the toss (a trimmed
        // toss, a toss piece ending before the flight) or on its way to the flight's start. A hit junction's
        // incoming piece is not used: the junction can sit after the contact. In the speed refits (v26) it is,
        // when it is a toss: the ball falling over the server until then (the junction stays the upper bound).
        let tossIn: Double? = job.fromToss ? job.incoming?.last?.t : nil
        let junctionToss: Double? = job.kind == .junction && isToss(job.incoming) ? job.incoming?.last?.t : nil
        let notBefore: Double? = (job.contactBounded ? [job.tossEnd, tossIn ?? junctionToss, job.seenBefore] : job.tossBounded ? [job.tossEnd, tossIn] : [])
            .compactMap { $0 }.max()
            .map { min($0, job.tHit) }    // the reach is searched back from the hit: a later bound cannot be met
        for x0 in inits.prefix(12) {
            let f = fitShot(cam, frames: frames, uv: uv, F0: F0, x0: x0, hit: hit, bounce: bnc, iterations: 8, landing: landing, contact: contact, notBefore: notBefore)
            if best == nil || f.2 < best!.2 { best = f }
        }
        var (x, e, rms) = fitShot(cam, frames: frames, uv: uv, F0: F0, x0: best!.0, hit: hit, bounce: bnc, iterations: 60, landing: landing, contact: contact, notBefore: notBefore)
        if e.max()! > 15 && e.filter({ $0 <= 15 }).count >= 8 {
            let keep = e.indices.filter { e[$0] <= 15 }
            res.droppedOutliers = e.count - keep.count
            (x, e, rms) = fitShot(cam, frames: keep.map { frames[$0] }, uv: keep.map { uv[$0] }, F0: F0, x0: x, hit: hit, bounce: bnc, iterations: 60, landing: landing, contact: contact, notBefore: notBefore)
        }
        if rms > 4, let b = bnc, hit != nil {
            let f2 = fitShot(cam, frames: frames, uv: uv, F0: F0, x0: x, hit: nil, bounce: b, iterations: 60)
            if f2.2 <= 4 { (x, e, rms) = f2; res.fallback = "bounce only"; hit = nil }
        }
        res.rmsPx = rms; res.maxPx = e.max()
        if let hit {
            let (tr, _) = reachTime(x, F0: F0, tHit: hit.t, depth: hit.y)
            if let tr, tr.isFinite { tHit = max(tr, notBefore ?? -.infinity); res.tHit = tHit / fps; res.hitKind = "first observation (reach)" }
        }
        let P = IndependentFlight.state(at: tHit, from: x, F0: F0)
        res.fitHit = [P.p.x, P.p.y, P.p.z]; res.vInstKmh = simd_length(P.v) * 3.6
        let last = IndependentFlight.state(at: frames[frames.count - 1], from: x, F0: F0).p
        res.zLastFit = last.z; res.yLastFit = last.y
        if frames[frames.count - 1] > tHit {
            let grid = stride(from: tHit, through: frames[frames.count - 1], by: 2).map { $0 - Double(F0) }
            res.riseM = max(0, (IndependentFlight.simulate(x, grid).map(\.p.z).max() ?? P.p.z) - P.p.z)
        }
        if job.serveDepth != nil {
            let grid: [Double] = (0...150).map { (k: Int) -> Double in tHit + Double(k) - Double(F0) }
            let L = IndependentFlight.simulate(x, grid)
            if let k = L.indices.first(where: { (k: Int) -> Bool in k > 0 && L[k].p.z <= IndependentCourt.ballRadius }) {
                let a = L[k - 1].p, b = L[k].p, f = (a.z - IndependentCourt.ballRadius) / max(a.z - b.z, 1e-9)
                res.landing = [a.x + f * (b.x - a.x), a.y + f * (b.y - a.y)]
            }
        }
        // net crossing of the fitted flight
        let tEnd = bnc?.t ?? frames[frames.count - 1] + 18
        let f0 = Int(floor(tHit)), f1 = Int(ceil(tEnd))
        let fs = f1 >= f0 ? Array(f0...f1).map(Double.init) : []
        let S = IndependentFlight.simulate(x, fs.map { $0 - Double(F0) })
        let side0 = IndependentNumerics.sign(P.p.y - netY)
        var end: (kind: String, t: Double, P: SIMD3<Double>)?
        if let i = S.indices.first(where: { IndependentNumerics.sign(S[$0].p.y - netY) != side0 }) {
            var tNet: Double, PNet: SIMD3<Double>
            if i > 0 {
                let a = S[i - 1], b = S[i], fr = (netY - a.p.y) / (b.p.y - a.p.y)
                tNet = fs[i - 1] + fr; PNet = a.p + fr * (b.p - a.p)
            } else { tNet = fs[0]; PNet = S[0].p }
            if bnc == nil || tNet <= bnc!.t + 0.5 { end = ("net", tNet, PNet); res.fitNetZ = PNet.z; res.fitNetX = PNet.x; res.pastNetCount = frames.filter { $0 > tNet }.count }
        }
        if end == nil, let bnc { end = ("bounce", bnc.t, SIMD3(bnc.P.x, bnc.P.y, bnc.P.z)) }
        guard let end else { res.reason = "fitted flight does not reach the net"; return res }
        let T = (end.t - tHit) / fps
        if T <= 0.03 { res.reason = "hit-to-net interval too short"; return res }
        var v = (end.P - P.p) / T; v.z += 0.5 * IndependentFlight.g * T
        let speed = simd_length(v) * 3.6
        res.endKind = end.kind; res.intervalS = T; res.speedKmh = speed
        if let vd = IndependentFlight.initialVelocity(from: P.p, to: end.P, over: T) { res.speedDragKmh = simd_length(vd) * 3.6 }
        // S家's serve speed (v23): the same endpoint formula from the contact to the first bounce past the net,
        // the tracked bounce when there is one, else where the fitted flight reaches the ground
        if end.kind == "net" {
            var land: (t: Double, P: SIMD3<Double>)?
            if let bnc, IndependentNumerics.sign(bnc.P.y - netY) != side0 { land = (bnc.t, bnc.P) }
            else {
                let grid: [Double] = (0...150).map { (k: Int) -> Double in end.t + Double(k) - Double(F0) }
                let L = IndependentFlight.simulate(x, grid)
                if let k = L.indices.first(where: { (k: Int) -> Bool in k > 0 && L[k].p.z <= IndependentCourt.ballRadius }) {
                    let a = L[k - 1].p, b = L[k].p, f = (a.z - IndependentCourt.ballRadius) / max(a.z - b.z, 1e-9)
                    land = (grid[k - 1] + f + Double(F0), a + f * (b - a))
                }
            }
            if let land, IndependentNumerics.sign(land.P.y - netY) != side0 {
                let TL = (land.t - tHit) / fps
                var w = (land.P - P.p) / TL; w.z += 0.5 * IndependentFlight.g * TL
                res.landSpeedKmh = simd_length(w) * 3.6; res.landY = land.P.y
            }
        }
        let yEnd = end.kind == "bounce" ? end.P.y : (bnc?.P.y ?? S[S.count - 1].p.y)
        res.crossesNet = end.kind == "net" || IndependentNumerics.sign(P.p.y - netY) != IndependentNumerics.sign(yEnd - netY)
        if rms > 4 { res.reason = "flight fit RMS above 4 px" }
        else if IndependentNumerics.sign(P.p.y - netY) == IndependentNumerics.sign(yEnd - netY) { res.reason = "hit and bounce on the same side of the net" }
        else if !(20...250).contains(speed) { res.reason = "speed outside 20-250 km/h" }
        else { res.accepted = true }
        return res
    }

    // MARK: serve speed (v16)

    /// A serve without a bounce-anchored speed is refitted with its contact at the server's own baseline.
    /// Where that flight runs through the ground, the bounce the tracker did not split is searched in the
    /// receiver's service box; otherwise the baseline-anchored speed is shown only when the flight is
    /// well observed past the net. Constants were fixed on the dev videos (docs/verification.md, 2026-11-03).
    enum ServeSpeed {
        static let inside = 0.4            // contact depth inside the baseline, metres
        static let depthSigma = 0.3
        static let minPoints = 25
        static let minPastNet = 6          // observations after the fitted net crossing
        static let netBounceY = 1.5        // a tracked "bounce" this close to the net: the ball met the net (v18)
        static let tossScan = 60           // toss trim: leading points scanned (1 s)
        static let tossFall = 3.0          // toss: the ball falls at least this far after the apex, px
        static let tossDrift = 2.5         // toss: sideways image drift at most this, px per frame
        static let tossFrames = 6.0        // toss: at least this long, frames
        static let contactSpeed = 6.0      // contact: image speed after it at least this, px per frame
        static let contactRatio = 2.5      // contact: image speed after / before
        static let departPx = 6.0          // contact (v19): the ball this far off the toss parabola, px
        static let departRMS = 3.0         //   and this many times the toss residual
        static let tossPoints = 10         // toss contact (v19): at least this many toss points
        static let tossRMS = 3.0           //   fitted within this, px
        static let tossDepthMiss = 1.5     //   over the server's baseline within this, metres
        static let contactSigma = SIMD3(0.3, 0.3, 0.15)   // serve refits: the toss contact's weight, metres
        static let bounceRefitRMS = 6.0    // serve bounce refits (v20): accepted up to this RMS, px
        static let notBeforeSigma = 1.0    // serve speed refits (v21): contact before the ball's last earlier sighting, frames
        static let netLowZ = 0.15          // net anchor: above the bottom of the net
        static let netSearchPoints = 24    // net contact searched over the last points before the "bounce"
        static let netTopZ = 1.17          // net anchor height limit, metres (net 0.914 at the centre, 1.07 at the posts)
        static let groundZ = -0.3          // fitted height at the last observation below this: a missed bounce
        static let maxDepthMiss = 1.0      // fitted contact depth vs the baseline anchor, metres
        static let boxMargin = 1.0, sideMargin = 0.5
        static let hypothesisSeconds = 0.6  // serve hypothesis: flight seconds after the hit that are refitted (v17)
        static let hypothesisPoints = 10
        static let hypothesisShortSeconds = 0.4
        static let landingMargin = 0.5       // serve refits: landing allowed this far outside the service box, metres
        static let landingSigma = 0.3
        static let cleanRMS = 4.0           // hypothesis speed without points past the net: fit RMS (px) at most
        static let towardNet = 0.6          // ... and observed at least this share of the way from the contact to the net
        static let netSide = 0.3            // net drop (v24): on the server's side of the net within this, metres
    }

    /// Serve hypothesis (v17): the first `hypothesisSeconds` of the flight refitted with the contact at the
    /// server's baseline (a bounce in the service box searched where the refit runs underground). Returns the
    /// refit when it is accepted, crosses the net and has a serve contact (height and depth); nil otherwise.
    /// Glued tracks, outliers late in the flight and far serves first seen mid-court fail the whole-flight
    /// fit; their first half second is a clean serve flight.
    /// `landing`: fit with the service-box landing prior (for the speed; recognition fits without it).
    static func serveHypothesis(_ job: IndependentShotFlight, near: Bool, camera cam: IndependentProjector, landing: Bool = false) -> IndependentShotResult? {
        if let r = serveHypothesis(job, near: near, camera: cam, seconds: ServeSpeed.hypothesisSeconds, landing: landing) { return r }
        // a bounce or a glued piece late in the window: the first 0.4 s alone
        return serveHypothesis(job, near: near, camera: cam, seconds: ServeSpeed.hypothesisShortSeconds, landing: landing)
    }

    /// A serve into the net that the tracker did not split (v24): the ball flies to the net, drops at its
    /// foot and bounces there, all in one piece, so no window of it is one flight that crosses the net.
    /// `netJob` puts the drop's bounce (`netDrop`) in for the tracker's bounce and keeps the points up to it
    /// (all the net refit reads, so the live window's cache holds while the track grows); the net refit
    /// (`serveNetRefit`) gives the contact and the hit-to-net speed. Nil unless the contact is at serve height.
    static func netJob(_ job: IndependentShotFlight, near: Bool, camera cam: IndependentProjector) -> IndependentShotFlight? {
        var j = job
        if !(j.bounce.map { abs($0.ground.y - netY) <= ServeSpeed.netBounceY } ?? false) {
            guard let d = netDrop(tossFree(job).points, near: near, camera: cam) else { return nil }
            j.bounce = d
        }
        let tb = j.bounce!.t * fps
        j.points = job.points.filter { (p: IndependentTrackPoint) -> Bool in p.t <= tb }
        return j
    }

    static func serveNetHypothesis(_ job: IndependentShotFlight, near: Bool, camera cam: IndependentProjector) -> IndependentShotResult? {
        guard let r = serveNetRefit(job, near: near, camera: cam), let h = r.fitHit, IndependentStrokeRules.Serve.contactZ.contains(h[2]) else { return nil }
        return r
    }

    /// Where a serve met the net (v24), from the track alone: the ball's first bounce at the foot of the net,
    /// a lowest image point (falling at least `tossFall` px over the 6 points before, rising after) whose
    /// ground point lies within `netBounceY` of the net and on the server's side (within `netSide`), after at
    /// least `hypothesisPoints + 2` points of flight.
    static func netDrop(_ P: [IndependentTrackPoint], near: Bool, camera cam: IndependentProjector) -> (t: Double, ground: SIMD3<Double>)? {
        let first = ServeSpeed.hypothesisPoints + 2
        guard P.count >= first + 3 else { return nil }
        for k in first..<(P.count - 2) {
            guard P[k].v - P[max(0, k - 6)].v >= ServeSpeed.tossFall, P[k].v >= P[k - 1].v, P[k].v > P[k + 1].v, P[k].v > P[k + 2].v else { continue }
            let g = cam.onPlaneZ(P[k].u, P[k].v, z: IndependentCourt.ballRadius)
            guard g.x.isFinite, g.y.isFinite, abs(g.y - netY) <= ServeSpeed.netBounceY, abs(g.x) <= IndependentCourt.doublesHalfWidth,
                  near ? g.y <= netY + ServeSpeed.netSide : g.y >= netY - ServeSpeed.netSide else { continue }
            return (t: P[k].t / fps, ground: SIMD3(g.x, g.y, 0))
        }
        return nil
    }

    static func serveHypothesis(_ job: IndependentShotFlight, near: Bool, camera cam: IndependentProjector, seconds: Double,
                                landing: Bool) -> IndependentShotResult? {
        let job = tossFree(job, near: near, camera: cam)
        let cut = job.tHit + seconds * fps
        var base = job
        base.landingPrior = landing; base.contactBounded = landing; base.tossBounded = true
        base.points = job.points.filter { (p: IndependentTrackPoint) -> Bool in p.t <= cut }
        guard base.points.count >= ServeSpeed.hypothesisPoints else { return nil }
        let depth: Double = near ? ServeSpeed.inside : IndependentCourt.length - ServeSpeed.inside
        base.serveDepth = depth; base.bounce = nil
        var r = analyse(base, camera: cam)
        if let z = r.zLastFit, z < ServeSpeed.groundZ {
            guard let b = serveBounce(base, near: near, camera: cam) else { return nil }
            var jb = base
            jb.bounce = b; jb.points = base.points.filter { (p: IndependentTrackPoint) -> Bool in p.t < b.t * fps }
            guard jb.points.count >= 8 else { return nil }
            r = analyse(jb, camera: cam); r.speedAnchor = .serveBounce
        }
        guard r.accepted, r.crossesNet == true, let h = r.fitHit, IndependentStrokeRules.Serve.contactZ.contains(h[2]),
              abs(h[1] - depth) <= ServeSpeed.maxDepthMiss else { return nil }
        return r
    }

    /// The flight without a toss glued to its start (v18): the leading points hold the toss apex (the
    /// highest image point, the ball falling after it) with little sideways drift, and the image speed
    /// jumps at the contact: the 4 points after it at least `contactRatio` times as fast as the 4 before,
    /// and `contactSpeed` px per frame. Returns the points unchanged when no such contact is found.
    static func tossTrimmed(_ P: [IndependentTrackPoint]) -> [IndependentTrackPoint] {
        let W = 4, n = min(P.count - W, ServeSpeed.tossScan)
        guard n > W else { return P }
        func speed(_ a: Int, _ b: Int) -> Double {    // median px per frame over steps a+1...b
            var s = [Double]()
            for i in (a + 1)...b { s.append(simd_length(P[i].uv - P[i - 1].uv) / max(P[i].t - P[i - 1].t, 1)) }
            s.sort(); return s[s.count / 2]
        }
        var apex = 0
        for k in 1...n {
            if P[k - 1].v < P[apex].v { apex = k - 1 }
            guard k > W, apex < k - 1, P[k - 1].v - P[apex].v >= ServeSpeed.tossFall,
                  P[k - 1].t - P[0].t >= ServeSpeed.tossFrames,
                  abs(P[k - 1].u - P[0].u) <= ServeSpeed.tossDrift * (P[k - 1].t - P[0].t) else { continue }
            let before = speed(k - W, k - 1), after = speed(k - 1, k + W - 1)
            if after >= ServeSpeed.contactSpeed && after >= ServeSpeed.contactRatio * max(before, 1) { return Array(P[k...]) }
            if apex >= 1, leavesToss(P, k, W) { return Array(P[k...]) }
        }
        return P
    }

    /// The contact as the ball leaving the toss (v19): the points before `k` follow one toss in the image
    /// (height a parabola in time, sideways drift linear), and the `W` points from `k` all lie at least
    /// `departPx` (and `departRMS` times the toss residual) off it, further each point. Catches serves whose
    /// image speed hardly changes at the contact: far serves on a low camera.
    static func leavesToss(_ P: [IndependentTrackPoint], _ k: Int, _ W: Int) -> Bool {
        let t0 = P[0].t
        var A = [[Double]](repeating: [0, 0, 0], count: 3), bv = [0.0, 0, 0]
        var B = [[Double]](repeating: [0, 0], count: 2), bu = [0.0, 0]
        for p in P[0..<k] {
            let t = p.t - t0, pw = [1, t, t * t]
            for i in 0..<3 { for j in 0..<3 { A[i][j] += pw[i] * pw[j] }; bv[i] += pw[i] * p.v }
            for i in 0..<2 { for j in 0..<2 { B[i][j] += pw[i] * pw[j] }; bu[i] += pw[i] * p.u }
        }
        guard let cv = solve(A, bv), let cu = solve(B, bu) else { return false }
        func off(_ p: IndependentTrackPoint) -> Double {
            let t = p.t - t0
            return simd_length(SIMD2(cu[0] + cu[1] * t, cv[0] + cv[1] * t + cv[2] * t * t) - p.uv)
        }
        let rms = (P[0..<k].reduce(0.0) { (s: Double, p: IndependentTrackPoint) -> Double in s + off(p) * off(p) } / Double(k)).squareRoot()
        let r = P[k..<(k + W)].map(off)
        return r.allSatisfy { $0 > max(ServeSpeed.departPx, ServeSpeed.departRMS * rms) } && r[W - 1] > r[0]
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solve(_ M: [[Double]], _ y: [Double]) -> [Double]? {
        var A = M, b = y; let n = b.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[p][c]) > 1e-9 else { return nil }
            A.swapAt(c, p); b.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = A[r][c] / A[c][c]
                for j in c..<n { A[r][j] -= f * A[c][j] }
                b[r] -= f * b[c]
            }
        }
        return (0..<n).map { b[$0] / A[$0][$0] }
    }

    /// `job` with a glued toss trimmed (v18): points from the contact, the hit moved there. With `near` and
    /// a camera, the contact is also measured from the toss (v19, `tossContact`).
    static func tossFree(_ job: IndependentShotFlight, near: Bool? = nil, camera cam: IndependentProjector? = nil) -> IndependentShotFlight {
        let P = tossTrimmed(job.points)
        guard P.count < job.points.count else { return job }
        var j = job
        j.points = P; j.tHit = max(job.tHit, P[0].t - 0.5); j.tossEnd = job.points[job.points.count - P.count - 1].t
        if let near, let cam {
            j.tossContact = tossContact(Array(job.points[..<(job.points.count - P.count)]), at: j.tHit, near: near, camera: cam)
        }
        return j
    }

    /// The serve contact measured from the toss (v19): the toss points alone fitted as one free flight. A
    /// toss is slow and near vertical, so gravity's pull in the image sets its distance from the camera
    /// (the serve flight's own fit cannot: on a low camera it trades depth for speed). Kept when the toss
    /// fits cleanly, stands over the server's baseline and the contact is at serve height.
    static func tossContact(_ toss: [IndependentTrackPoint], at t: Double, near: Bool, camera cam: IndependentProjector) -> (t: Double, P: SIMD3<Double>)? {
        guard toss.count >= ServeSpeed.tossPoints else { return nil }
        let frames = toss.map(\.t), uv = toss.map(\.uv), base: Double = near ? 0 : IndependentCourt.length
        let F0 = IndependentNumerics.pyRound(frames[0])
        let ys = [base - 1, base, base + 1]
        var best: (IndependentFlight.State, [Double], Double)?
        for g in IndependentFlight.initialGuesses(cam, frames: frames.map { $0 - frames[0] }, uv: uv, ys0: ys, ys1: ys) {
            let x0 = IndependentFlight.simulate(g, [Double(F0) - frames[0]])[0]
            let f = fitShot(cam, frames: frames, uv: uv, F0: F0, x0: x0, hit: nil, bounce: nil, iterations: 60)
            if best == nil || f.2 < best!.2 { best = f }
        }
        guard let best, best.2 <= ServeSpeed.tossRMS else { return nil }
        let P = IndependentFlight.state(at: t, from: best.0, F0: F0).p
        guard abs(P.y - base) <= ServeSpeed.tossDepthMiss, IndependentStrokeRules.Serve.contactZ.contains(P.z) else { return nil }
        return (t, P)
    }

    /// A serve into the net (v18): the tracker's "bounce" lies next to the net, where the ball met the net
    /// (no single flight explains the track, so the serve's own fit fails). The flight before it is refitted
    /// with the contact at the server's baseline and its end on the net plane, where the camera ray of the
    /// ball at that moment meets the net. The net contact is the latest point that one flight still explains (after
    /// it the ball drops almost straight down); hit-to-net speed comes from the two anchors. When no candidate
    /// fits within 4 px, the best one within `bounceRefitRMS` is used (v24).
    static func serveNetRefit(_ job: IndependentShotFlight, near: Bool, camera cam: IndependentProjector) -> IndependentShotResult? {
        guard let b = job.bounce, abs(b.ground.y - netY) <= ServeSpeed.netBounceY else { return nil }
        let tb = b.t * fps
        let free = tossFree(job, near: near, camera: cam)
        let pre = free.points.filter { (p: IndependentTrackPoint) -> Bool in p.t <= tb }
        guard pre.count >= ServeSpeed.hypothesisPoints + 2 else { return nil }
        let depth: Double = near ? ServeSpeed.inside : IndependentCourt.length - ServeSpeed.inside
        let y = netY + (near ? 1 : -1) * 0.05
        // the ball meets the net before it drops to the ground there: each of the last points is a candidate
        let lo = max(ServeSpeed.hypothesisPoints, pre.count - ServeSpeed.netSearchPoints)
        var loose: IndependentShotResult?
        for k in stride(from: pre.count - 1, through: lo, by: -2) {
            let a = pre[k]
            let (P, sRay) = cam.onPlaneY(a.u, a.v, y: y)
            guard sRay > 0, P.z >= ServeSpeed.netLowZ, P.z <= ServeSpeed.netTopZ, abs(P.x) <= IndependentCourt.doublesHalfWidth else { continue }
            var base = free
            base.points = Array(pre[..<k]); base.serveDepth = depth; base.bounce = (a.t / fps, P)
            var r = analyse(base, camera: cam)
            // ... at serve height (v24): on a low camera a fit can trade the contact's height for depth
            guard let h = r.fitHit, abs(h[1] - depth) <= ServeSpeed.maxDepthMiss, IndependentStrokeRules.Serve.contactZ.contains(h[2]) else { continue }
            if !r.accepted {
                // anchored at both ends, a fit a little off the toss's last frames still holds (v24): kept as a fallback
                if r.reason == "flight fit RMS above 4 px", let e = r.rmsPx, e <= ServeSpeed.bounceRefitRMS, e < (loose?.rmsPx ?? .infinity) { loose = r }
                continue
            }
            r.speedAnchor = .serveNet; r.bounceFound = false; r.bounceGround = nil; r.tBounce = nil
            return r
        }
        guard var r = loose else { return nil }
        r.accepted = true; r.reason = nil
        r.speedAnchor = .serveNet; r.bounceFound = false; r.bounceGround = nil; r.tBounce = nil
        return r
    }

    /// A serve with a detected bounce, refitted with its contact at the server's baseline as well (v17): the
    /// shot's own fit takes the contact depth from the hitter box, which is wrong when the box is another
    /// player. Returns the refit when accepted with the contact near the baseline.
    static func serveBounceRefit(_ job: IndependentShotFlight, near: Bool, camera cam: IndependentProjector) -> IndependentShotResult? {
        guard job.bounce != nil else { return nil }
        let job = tossFree(job, near: near, camera: cam)
        var base = job
        let depth: Double = near ? ServeSpeed.inside : IndependentCourt.length - ServeSpeed.inside
        base.serveDepth = depth; base.contactBounded = true
        var r = analyse(base, camera: cam)
        // anchored at both ends (contact and bounce), the speed hardly depends on the fit's detail (v20)
        if !r.accepted, r.reason == "flight fit RMS above 4 px", (r.rmsPx ?? .infinity) <= ServeSpeed.bounceRefitRMS { r.accepted = true; r.reason = nil }
        guard r.accepted, let y = r.fitHit?[1], abs(y - depth) <= ServeSpeed.maxDepthMiss else { return nil }
        return r
    }

    /// Serve refit: the result carries `speedAnchor` when its speed may be shown, otherwise nil.
    static func serveSpeed(_ job: IndependentShotFlight, near: Bool, camera cam: IndependentProjector) -> IndependentShotResult? {
        let job = tossFree(job, near: near, camera: cam)
        var base = job
        let depth: Double = near ? ServeSpeed.inside : IndependentCourt.length - ServeSpeed.inside
        base.serveDepth = depth; base.bounce = nil; base.landingPrior = true; base.contactBounded = true
        var r = analyse(base, camera: cam)
        if job.bounce == nil, let z = r.zLastFit, z < ServeSpeed.groundZ {
            guard let b = serveBounce(base, near: near, camera: cam) else { return nil }
            var jb = base
            jb.bounce = b; jb.points = base.points.filter { (p: IndependentTrackPoint) -> Bool in p.t < b.t * fps }
            var rb = analyse(jb, camera: cam)
            guard rb.accepted else { return nil }
            rb.speedAnchor = .serveBounce
            return rb
        }
        guard r.accepted, r.nObs >= ServeSpeed.minPoints, (r.pastNetCount ?? 0) >= ServeSpeed.minPastNet,
              let z = r.zLastFit, z >= ServeSpeed.groundZ, let y = r.fitHit?[1], abs(y - depth) <= ServeSpeed.maxDepthMiss else { return nil }
        r.speedAnchor = .serveBaseline
        return r
    }

    /// A serve hypothesis refit whose speed may be shown: anchored at a service-box bounce, or observed
    /// past the net and not underground (the serve refit's baseline checks, with fewer points).
    static func hypothesisSpeedShown(_ r: IndependentShotResult) -> Bool {
        if r.speedAnchor == .serveBounce { return true }
        guard let z = r.zLastFit, z >= ServeSpeed.groundZ else { return false }
        if (r.pastNetCount ?? 0) >= ServeSpeed.minPastNet { return true }
        // lost before the net (a near serve going away from the camera): a clean fit seen most of the way there
        guard let y = r.yLastFit, let h = r.fitHit, (r.rmsPx ?? .infinity) <= ServeSpeed.cleanRMS else { return false }
        return abs(y - h[1]) >= ServeSpeed.towardNet * abs(netY - h[1])
    }

    /// A bounce in the receiver's service box inside one tracked piece: anchored fits before and after the
    /// candidate point (as `testBounce`), falling before and rising after; the lowest summed RMS wins.
    static func serveBounce(_ job: IndependentShotFlight, near: Bool, camera cam: IndependentProjector) -> (t: Double, ground: SIMD3<Double>)? {
        let pts = job.points
        guard pts.count >= 8 else { return nil }
        let box = IndependentCourtModel.serviceFromNet + ServeSpeed.boxMargin
        let yLo: Double = near ? netY : netY - box, yHi: Double = near ? netY + box : netY
        let xMax = IndependentCourtModel.singlesHalfWidth + ServeSpeed.sideMargin
        var best: (score: Double, t: Double, P: SIMD3<Double>)?
        for k in 4..<(pts.count - 3) {
            let p = pts[k]
            let Pg = cam.onPlaneZ(p.u, p.v, z: IndependentCourt.ballRadius)
            guard Pg.x.isFinite, Pg.y.isFinite, abs(Pg.x) <= xMax, yLo < Pg.y, Pg.y < yHi else { continue }
            let A = Array(pts[max(0, k - 24)...k]), B = Array(pts[k..<min(pts.count, k + 15)])
            let fa = IndependentFlight.bestAnchored(cam, frames: A.map(\.t), uv: A.map(\.uv), anchor: Pg, at: p.t, before: true)
            guard fa.rms <= 4, fa.velocity.z < 0 else { continue }
            let fb = IndependentFlight.bestAnchored(cam, frames: B.map(\.t), uv: B.map(\.uv), anchor: Pg, at: p.t, before: false)
            guard fb.rms <= 4, fb.velocity.z > 0 else { continue }
            let score: Double = fa.rms + fb.rms
            if best == nil || score < best!.score { best = (score, p.t, Pg) }
        }
        guard let best else { return nil }
        return (t: best.t / fps, ground: best.P)
    }

    /// Flights starting within 0.25 s of the previous kept one are duplicates: keep the one with more points.
    static func deduplicate(_ shots: [IndependentShotResult]) -> [IndependentShotResult] {
        deduplicate(shots) { (s: IndependentShotResult) -> IndependentShotResult in s }
    }

    static func deduplicate<T>(_ items: [T], result: (T) -> IndependentShotResult) -> [T] {
        var out = [T]()
        for item in IndependentBallEvents.stableSorted(items, by: { (a: T, b: T) -> Bool in result(a).tHit < result(b).tHit }) {
            let s = result(item)
            if let last = out.last, s.tHit - result(last).tHit < 0.25 {
                if s.nObs > result(last).nObs { out[out.count - 1] = item }
                continue
            }
            out.append(item)
        }
        return out
    }
}
