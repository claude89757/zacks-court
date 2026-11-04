import SwiftUI
import simd
import CourtCore

/// Timing of a challenge replay, in seconds, modelled on the broadcast sequence: title, the flight to
/// the bounce while the camera comes round beside it and stops, the footprint pressed in, the rise to a
/// shot from overhead that measures the gap, then the verdict. Mirrors `replayTiming` in app.js.
struct HawkEyeReplayTiming {
    let hasFlight: Bool
    var title: Double { 0.8 }
    /// The ball lands; the camera has come round beside the bounce and stands still.
    var landed: Double { title + (hasFlight ? 2.2 : 1.2) }
    /// The footprint is in and the ball has run on; the camera sets off for the overhead shot.
    var settled: Double { landed + 0.5 }
    var overhead: Double { settled + 1.4 }
    /// The gap is measured, the verdict shows and a challenge's call is spoken.
    var verdictAt: Double { overhead + 0.6 }
    var total: Double { verdictAt + 0.3 }

    struct Frame {
        /// Camera: opening view → beside the bounce (0…1), then → overhead (0…1).
        var approach: Double
        var zoom: Double
        /// Samples of the flight drawn so far (0 … count), fractional for a smooth ball.
        var flightProgress: Double
        var markOpacity: Double
        /// The flight and the ball, faded out on the way overhead so the gap is all that is left.
        var trailOpacity: Double
        /// The measuring bar drawn so far (0…1).
        var measure: Double
        var verdict: Bool
        var titleOpacity: Double
    }

    func frame(_ t: Double, scene: HawkEyeReplayScene) -> Frame {
        func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
        let count = Double((scene.flight?.count ?? 1) - 1), bounceAt = Double(scene.bounceIndex)
        var progress = 0.0
        if hasFlight {
            if t < landed {
                // slowing into the bounce: a third of the average speed as it lands
                let f = clamp((t - title) / (landed - title))
                progress = bounceAt * (0.35 * f + 0.65 * (1 - (1 - f) * (1 - f)))
            } else {
                // a beat on the mark, then picking up again as it runs on
                progress = bounceAt + (count - bounceAt) * pow(clamp((t - landed) / (settled - landed)), 1.6)
            }
        }
        return Frame(approach: clamp((t - title) / (landed - title)), zoom: clamp((t - settled) / (overhead - settled)),
                     flightProgress: progress, markOpacity: clamp((t - landed) / 0.4),
                     trailOpacity: 1 - clamp((t - settled) / ((overhead - settled) * 0.7)),
                     measure: clamp((t - overhead) / (verdictAt - overhead)), verdict: t >= verdictAt,
                     titleOpacity: t < title ? 1 : max(0, 1 - (t - title) / 0.3))
    }
}

/// 「挑战」 and 「界内外回放」: replays a shot the way a broadcast challenge does, then offers its video.
/// Opened on every screen when a challenge arrives (focused on that shot), or from 回放 to step through
/// the judged shots. The picture is drawn from the model's estimates; the verdict keeps the call's
/// three states and its distance, and a challenge says why when it cannot judge.
@MainActor
struct HawkEyeChallengeView: View {
    let model: WorkspaceModel
    var focus: HawkEyeChallengeRef?
    var close: () -> Void
    @State private var index: Int
    @State private var started = Date()
    @State private var playback: PlaybackItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: WorkspaceModel, focus: HawkEyeChallengeRef? = nil, close: @escaping () -> Void) {
        self.model = model; self.focus = focus; self.close = close
        let shots = Self.replayable(model.challengeEvents)
        let focused = focus.flatMap { f in shots.firstIndex { $0.shot.id == f.shot } }
        _index = State(initialValue: focused ?? max(0, shots.count - 1))
    }

    /// Shots with a call of their time or a challenge, numbered as in the record.
    static func replayable(_ events: [TennisShotEvent]) -> [(number: Int, shot: TennisShotEvent)] {
        events.enumerated().compactMap { i, e in e.lineCall == nil && e.challenge == nil ? nil : (i + 1, e) }
    }
    private var shots: [(number: Int, shot: TennisShotEvent)] { Self.replayable(model.challengeEvents) }
    private var current: (number: Int, shot: TennisShotEvent)? { shots.indices.contains(index) ? shots[index] : shots.last }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let current {
                if let judgement = current.shot.lineCall, let scene = HawkEyeReplayScene(event: current.shot, judgement: judgement) {
                    replay(scene, number: current.number, challenged: current.shot.challenge != nil)
                        .id(current.shot.id.uuidString + (current.shot.challenge?.id.uuidString ?? ""))
                        .task(id: speechKey(current.shot)) { await announce(current.shot, timing: HawkEyeReplayTiming(hasFlight: scene.flight != nil)) }
                } else {
                    unjudged(current.shot, number: current.number)
                }
                footer(current.shot)
            } else {
                Spacer()
                CourtNotice(text: "还没有判过界内外或挑战过的拍。点「挑战」判最近一拍；开启界内外后，判过的拍也会出现在这里。")
                    .padding(CourtStyle.Space.xl)
                Spacer()
            }
        }
        .background(CourtStyle.background.ignoresSafeArea())
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(item: $playback) { RecordingPlayer(item: $0) }
        .onChange(of: current?.shot.lineCall != nil) { _, judged in if judged { started = Date() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.hawkeye.challenge")
    }

    private var header: some View {
        HStack(spacing: CourtStyle.Space.s) {
            Text(current?.shot.challenge != nil ? "挑战" : "界内外回放").font(.headline)
            if let current { Text("第 \(current.number) 拍").font(.headline.monospacedDigit()).foregroundStyle(CourtStyle.muted) }
            Spacer(minLength: 8)
            iconButton("chevron.left", "上一个") { index = max(0, index - 1); started = Date() }
                .disabled(index <= 0)
            iconButton("chevron.right", "下一个") { index = min(shots.count - 1, index + 1); started = Date() }
                .disabled(index >= shots.count - 1)
            iconButton("arrow.counterclockwise", "重播") { started = Date() }
            iconButton("xmark", "关闭") { close() }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CourtStyle.Space.l).padding(.vertical, CourtStyle.Space.s)
    }

    private func iconButton(_ image: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image).frame(width: 44, height: 44).background(CourtStyle.raised, in: Circle()).contentShape(Circle())
        }.accessibilityLabel(label)
    }

    private func replay(_ scene: HawkEyeReplayScene, number: Int, challenged: Bool) -> some View {
        let timing = HawkEyeReplayTiming(hasFlight: scene.flight != nil)
        return TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? timing.total : context.date.timeIntervalSince(started)
            let frame = timing.frame(t, scene: scene)
            ZStack {
                Canvas { gc, size in HawkEyeReplayPainter(scene: scene, frame: frame).paint(&gc, size: size) }
                if frame.titleOpacity > 0 { titleCard(number: number, challenged: challenged).opacity(frame.titleOpacity) }
                if frame.verdict { verdict(scene.judgement, challenged: challenged).transition(.opacity) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(number) 拍\(challenged ? "挑战" : "界内外回放")：\(scene.judgement.call.text)，\(scene.judgement.detailText)")
        .accessibilityIdentifier("court.hawkeye.replay")
    }

    private func titleCard(number: Int, challenged: Bool) -> some View {
        VStack(spacing: 6) {
            Text(challenged ? "CHALLENGE" : "REPLAY").font(.system(size: 44, weight: .heavy, design: .rounded)).tracking(4)
            Text((challenged ? "挑战" : "界内外回放") + " · 第 \(number) 拍").font(.title3).foregroundStyle(CourtStyle.muted)
        }
        .padding(.horizontal, 32).padding(.vertical, 20)
        .background(CourtStyle.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
    }

    /// A challenge the camera could not judge (yet): the title card with the reason, and the way on.
    private func unjudged(_ shot: TennisShotEvent, number: Int) -> some View {
        let c = shot.challenge
        return VStack(spacing: CourtStyle.Space.l) {
            Spacer()
            Text("CHALLENGE").font(.system(size: 44, weight: .heavy, design: .rounded)).tracking(4)
            Text("挑战 · 第 \(number) 拍").font(.title3).foregroundStyle(CourtStyle.muted)
            HStack(spacing: 10) {
                if c?.pending == true { ProgressView().tint(.white) }
                Text(c?.reason ?? HawkEyeChallenge.noBounceReason).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            }
            if c?.pending != true { previousButton(shot) }
            Spacer()
        }
        .padding(CourtStyle.Space.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.hawkeye.unjudged")
    }

    /// The verdict across the top, compact, so the overhead shot below keeps the gap in view.
    private func verdict(_ j: HawkEyeJudgement, challenged: Bool) -> some View {
        VStack {
            HStack(spacing: 14) {
                Text(j.call.shout)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(j.call == .out ? Color.white : CourtStyle.background)
                    .padding(.horizontal, 16).padding(.vertical, 2)
                    .background(CourtStyle.callColor(j.call), in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                VStack(alignment: .leading, spacing: 2) {
                    Text((j.call == .close ? j.call.text + " · " : "") + j.detailText + (j.serve ? " · 发球" : "") + (challenged ? " · " + j.format.text + "边线" : ""))
                        .font(.headline)
                    Text((j.farHalf ? "远端半场，误差较大 · " : "") + "模型估计，不是判罚 · 误差范围 ±\(Int((j.marginM * 100).rounded())) 厘米")
                        .font(.caption).foregroundStyle(CourtStyle.muted)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(CourtStyle.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.card).strokeBorder(CourtStyle.callColor(j.call), lineWidth: 2))
            .padding(CourtStyle.Space.m)
            Spacer()
        }
    }

    /// 「不是这一拍？挑战上一拍」: the camera picked the newest shot, the disputed one may be earlier.
    @ViewBuilder private func previousButton(_ shot: TennisShotEvent) -> some View {
        if shot.challenge != nil, model.canChallenge, let previous = HawkEye.previousBounced(before: shot.id, in: model.challengeEvents) {
            Button { model.challenge(shot: previous.id) } label: {
                Label("不是这一拍？挑战上一拍", systemImage: "arrow.uturn.backward")
                    .font(.callout.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
                    .background(CourtStyle.raised, in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("court.hawkeye.challenge.previous")
        }
    }

    private func footer(_ shot: TennisShotEvent) -> some View {
        HStack(spacing: CourtStyle.Space.m) {
            ShotReplayButton(model: model, session: model.controller?.session ?? model.session, shot: shot) { playback = $0 }
                .frame(maxWidth: 360)
            if shot.lineCall != nil { previousButton(shot) }
            Spacer(minLength: 0)
            if shot.lineCall != nil {
                Text(shot.hit == nil ? "这条链没有击球点，只回放落点" : "轨迹按击球点和落点估算").font(.caption).foregroundStyle(CourtStyle.muted)
            }
        }
        .padding(.horizontal, CourtStyle.Space.l).padding(.bottom, CourtStyle.Space.m)
    }

    /// The verdict is called out once per challenge, when the replay reaches it.
    private func speechKey(_ shot: TennisShotEvent) -> String {
        (shot.challenge?.id.uuidString ?? "-") + (shot.lineCall != nil ? "+" : "")
    }
    private func announce(_ shot: TennisShotEvent, timing: HawkEyeReplayTiming) async {
        guard let c = shot.challenge, let j = c.judgement else { return }
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.3 : timing.verdictAt))
        guard !Task.isCancelled else { return }
        model.announceChallenge(c.id, call: j.call)
    }
}

/// Every screen shows a challenge when it arrives, above whatever it shows (the boards included).
private struct HawkEyeChallengeOverlay: ViewModifier {
    let model: WorkspaceModel
    func body(content: Content) -> some View {
        content
            .overlay {
                if let ref = model.presentedChallenge {
                    HawkEyeChallengeView(model: model, focus: ref) { model.presentedChallenge = nil }
                        .id(ref.challenge)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.presentedChallenge)
            .onChange(of: model.controller?.latestChallenge) { _, ref in model.noteCameraChallenge(ref) }
    }
}

extension View {
    /// The challenge replay over this view when a challenge arrives (any device's).
    func courtChallengeOverlay(model: WorkspaceModel) -> some View { modifier(HawkEyeChallengeOverlay(model: model)) }
}

/// 「挑战」: asks the camera to judge the newest shot again; every screen then plays it. When 界内外 is
/// off, the first challenge of a record asks for singles or doubles lines.
@MainActor
struct ChallengeButton: View {
    let model: WorkspaceModel
    var large = false
    @State private var askFormat = false

    var body: some View {
        Button {
            model.dismissHawkEyeAlert()
            if let reason = model.challengeUnavailableReason { model.error = reason }
            else if model.challengeFormat == nil { askFormat = true }
            else { model.challenge() }
        } label: {
            Label("挑战", systemImage: "flag.fill")
                .font(large ? .title3.weight(.bold) : .callout.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(CourtStyle.background)
                .background(CourtStyle.warning, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("挑战最近一拍")
        .accessibilityIdentifier("court.challenge")
        .confirmationDialog("挑战：按单打还是双打边线判？", isPresented: $askFormat, titleVisibility: .visible) {
            ForEach(HawkEyeFormat.allCases, id: \.self) { format in
                Button(format.text) { model.challenge(format: format) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("机位重新判最近一拍，所有屏幕一起播放回放。本场只问一次。")
        }
    }
}

/// Draws one frame of the replay in the frame's camera: sky and haze, court with surface grain, lines,
/// the net and its shadow, the flight as a tapered trail with the shaded ball and its shadow, then the
/// footprint, its uncertainty and the distance to the line. Mirrors `drawReplay` in app.js.
struct HawkEyeReplayPainter {
    let scene: HawkEyeReplayScene
    let frame: HawkEyeReplayTiming.Frame

    /// Replay palette (mirrors `RP` in app.js).
    enum Palette {
        static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
            Color(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
        }
        static let skyTop = rgb(0x04080c), skyHorizon = rgb(0x16242a), haze = rgb(0x1c2c2b)
        static let apronFar = rgb(0x10261f), apronNear = rgb(0x0b2019), runFar = rgb(0x1d4a3c), runNear = rgb(0x163b30)
        static let courtFar = rgb(0x2a6b57), courtNear = rgb(0x1f5747), line = rgb(0xf4f7f2), tape = rgb(0xe9efe9)
        static let ballLight = rgb(0xfbffd0), ball = rgb(0xdcf04a), ballDark = rgb(0x7f9a18), afterBounce = rgb(0xe8ffa8)
        static let post = [rgb(0x2a3532), rgb(0x9aa8a2), rgb(0x3c4a46)]
    }
    /// Light from high up, a little to the left and from behind the near end: sets the shadows.
    static let sun = simd_normalize(SIMD3<Double>(-0.45, 0.35, 1))
    static func shadow(_ p: SIMD3<Double>) -> SIMD3<Double> { let k = p.z / sun.z; return SIMD3(p.x - sun.x * k, p.y - sun.y * k, 0) }
    static func ellipse(_ c: SIMD3<Double>, _ a: Double, _ b: Double, _ dir: SIMD3<Double>, _ n: Int = 40) -> [SIMD3<Double>] {
        let d = simd_normalize(SIMD3(dir.x, dir.y, 0)), q = SIMD3(-d.y, d.x, 0)
        return (0..<n).map { i in let t = Double(i) / Double(n) * 2 * .pi; return c + d * (a * cos(t)) + q * (b * sin(t)) }
    }
    static func netTop(_ x: Double) -> Double {
        let left = -0.914, post = HawkEye.width + 0.914, m = HawkEye.width / 2
        return x <= m ? 1.07 + (0.914 - 1.07) * ((x - left) / (m - left)) : 0.914 + (1.07 - 0.914) * ((x - m) / (post - m))
    }
    /// Fixed specks on the surface round the bounce: they shrink with distance, so the ground reads as a plane.
    static func grain(_ focus: SIMD3<Double>) -> [SIMD3<Double>] {
        var seed = 7.0
        func rnd() -> Double { seed = (seed * 16807).truncatingRemainder(dividingBy: 2147483647); return seed / 2147483647 }
        return (0..<1600).map { _ in let x = focus.x + (rnd() - 0.5) * 7; return SIMD3(x, focus.y + (rnd() - 0.5) * 7, 0) }
    }

    func paint(_ gc: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width), h = Double(size.height), mark = frame.markOpacity, trail = frame.trailOpacity
        let cam = scene.camera(approach: frame.approach, zoom: frame.zoom, aspect: w / max(1, h))
        let W = HawkEye.width, L = HawkEye.length, net = HawkEye.netY, ballR = HawkEye.ballRadius
        let call = CourtStyle.callColor(scene.judgement.call)
        let f = h / (2 * tan(cam.fovDegrees * .pi / 360))
        func pt(_ s: SIMD2<Double>) -> CGPoint { CGPoint(x: s.x, y: s.y) }
        func project(_ p: SIMD3<Double>) -> CGPoint? { cam.project(p, width: w, height: h).map(pt) }
        func shape(_ points: [SIMD3<Double>]) -> Path? {
            let s = cam.polygon(points, width: w, height: h)
            guard s.count >= 3 else { return nil }
            var p = Path(); p.move(to: pt(s[0])); for q in s.dropFirst() { p.addLine(to: pt(q)) }
            p.closeSubpath(); return p
        }
        func vertical(_ y0: Double, _ stops: [Gradient.Stop]) -> GraphicsContext.Shading {
            .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: 0, y: y0), endPoint: CGPoint(x: 0, y: h))
        }
        // sky down to a hazy horizon
        let forward = simd_normalize(cam.target - cam.position)
        let flat = simd_length(SIMD2(forward.x, forward.y)) > 1e-6 ? simd_normalize(SIMD3(forward.x, forward.y, 0)) : SIMD3(0, 1, 0)
        let hy = max(0, min(h, project(cam.position + flat * 4000).map { Double($0.y) } ?? 0))
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [Palette.skyTop, Palette.skyHorizon]),
                                                                              startPoint: .zero, endPoint: CGPoint(x: 0, y: max(1, hy))))
        // the ground runs to the true horizon (a finite ground's far edge would tilt with the view), then
        // the run-off and the court
        gc.fill(Path(CGRect(x: 0, y: hy, width: w, height: max(0, h - hy))),
                with: vertical(hy, [.init(color: Palette.haze, location: 0), .init(color: Palette.apronFar, location: 0.18), .init(color: Palette.apronNear, location: 1)]))
        if let p = shape([SIMD3(-3.66, -6.4, 0), SIMD3(W + 3.66, -6.4, 0), SIMD3(W + 3.66, L + 6.4, 0), SIMD3(-3.66, L + 6.4, 0)]) {
            gc.fill(p, with: vertical(hy, [.init(color: Palette.runFar, location: 0), .init(color: Palette.runNear, location: 1)]))
        }
        if let p = shape([SIMD3(0, 0, 0), SIMD3(W, 0, 0), SIMD3(W, L, 0), SIMD3(0, L, 0)]) {
            gc.fill(p, with: .linearGradient(Gradient(colors: [Palette.courtFar, Palette.courtNear]), startPoint: CGPoint(x: 0, y: hy), endPoint: CGPoint(x: w * 0.3, y: h)))
        }
        var specks = Path()
        for p in Self.grain(scene.focus) {
            let q = cam.view(p); guard q.z >= 0.1 else { continue }
            let r = min(1.6, 0.006 * f / q.z); guard r >= 0.3 else { continue }
            let s = cam.screen(q, width: w, height: h); specks.addRect(CGRect(x: s.x, y: s.y, width: r, height: r * 0.6))
        }
        gc.fill(specks, with: .color(.white.opacity(0.05)))
        // where the footprint may lie, under the lines so they stay readable
        let footprint = scene.footprint, band = scene.band
        if mark > 0, let p = shape(Self.ellipse(scene.bounce, band.along, band.across, scene.along, 64)) {
            gc.fill(p, with: .color(call.opacity(0.16 * mark)))
            gc.stroke(p, with: .color(call.opacity(0.7 * mark)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }
        gc.drawLayer { layer in
            layer.addFilter(.shadow(color: .white.opacity(0.35), radius: 1.5))
            for rect in HawkEyeCourtLines.rectangles() { if let p = shape(rect) { layer.fill(p, with: .color(Palette.line)) } }
        }
        // the judged line's outer edge, the one the call measures from, picked out with the mark
        if mark > 0, let a = project(scene.lineFrom), let b = project(scene.lineTo) {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            gc.stroke(p, with: .color(CourtStyle.green.opacity(0.85 * mark)), lineWidth: 1.5)
        }
        // net: its shadow, the mesh, the top tape and the posts
        let left = -0.914, post = W + 0.914
        let xs = (0...20).map { left + (post - left) * Double($0) / 20 }
        if let p = shape([SIMD3(left, net, 0)] + xs.map { Self.shadow(SIMD3($0, net, Self.netTop($0))) } + [SIMD3(post, net, 0)]) {
            gc.fill(p, with: .color(.black.opacity(0.28)))
        }
        if let body = shape([SIMD3(left, net, 0), SIMD3(post, net, 0), SIMD3(post, net, 1.07), SIMD3(W / 2, net, 0.914), SIMD3(left, net, 1.07)]) {
            gc.fill(body, with: .color(Palette.rgb(0x080e0c, 0.35)))
            var mesh = Path()
            for x in stride(from: left, through: post, by: 0.08) {
                if let a = project(SIMD3(x, net, 0)), let b = project(SIMD3(x, net, 1.1)) { mesh.move(to: a); mesh.addLine(to: b) }
            }
            for z in stride(from: 0.05, to: 1.1, by: 0.08) {
                if let a = project(SIMD3(left, net, z)), let b = project(SIMD3(post, net, z)) { mesh.move(to: a); mesh.addLine(to: b) }
            }
            var clipped = gc; clipped.clip(to: body)
            clipped.stroke(mesh, with: .color(Palette.rgb(0xe6f0eb, 0.16)), lineWidth: 0.6)
        }
        if let p = shape(xs.map { SIMD3($0, net, Self.netTop($0)) } + xs.reversed().map { SIMD3($0, net, Self.netTop($0) - 0.06) }) {
            gc.fill(p, with: .color(Palette.tape))
        }
        for x in [left, post] {
            guard let p = shape([SIMD3(x - 0.04, net, 0), SIMD3(x + 0.04, net, 0), SIMD3(x + 0.04, net, 1.07), SIMD3(x - 0.04, net, 1.07)]) else { continue }
            if let a = project(SIMD3(x - 0.04, net, 0)), let b = project(SIMD3(x + 0.04, net, 0)) {
                gc.fill(p, with: .linearGradient(Gradient(colors: Palette.post), startPoint: CGPoint(x: a.x, y: 0), endPoint: CGPoint(x: b.x + 0.01, y: 0)))
            } else { gc.fill(p, with: .color(Palette.post[1])) }
        }
        // the footprint, pressed in as the mark appears
        if mark > 0 {
            let grow = 0.6 + 0.4 * sin(min(1, mark * 1.4) * .pi / 2)
            if let p = shape(Self.ellipse(scene.bounce, footprint.along * grow, footprint.across * grow, scene.along)) {
                gc.fill(p, with: .color(call.opacity(0.95 * mark)))
                gc.stroke(p, with: .color(.white.opacity(0.95 * mark)), lineWidth: 1.4)
            }
        }
        // the flight: a tapered comet, faded where it passes the camera; dimmer and dashed after the bounce (a guess)
        var ball: SIMD3<Double>?
        if let flight = scene.flight, frame.flightProgress > 0, trail > 0 {
            let n = min(Double(flight.count - 1), frame.flightProgress)
            let whole = Int(n)
            var pts = Array(flight[0...whole])
            if whole < flight.count - 1 { pts.append(flight[whole] + (flight[whole + 1] - flight[whole]) * (n - Double(whole))) }
            for i in 1..<max(1, pts.count) {
                let qa = cam.view(pts[i - 1]), qb = cam.view(pts[i])
                guard qa.z >= 0.3, qb.z >= 0.3 else { continue }
                let after = i > scene.bounceIndex, k = Double(i) / Double(max(1, pts.count - 1))
                let near = max(0, min(1, (qb.z - 0.8) / 2.5)), r = ballR * f / qb.z
                let alpha = trail * near * (after ? 0.45 : 0.25 + 0.7 * pow(k, 1.4))
                let width = after ? max(1, min(3, r * 0.5)) : max(2.5, min(7, r * 1.4)) * (0.45 + 0.55 * k)
                var seg = Path(); seg.move(to: pt(cam.screen(qa, width: w, height: h))); seg.addLine(to: pt(cam.screen(qb, width: w, height: h)))
                gc.stroke(seg, with: .color((after ? Palette.afterBounce : CourtStyle.green).opacity(alpha)),
                          style: StrokeStyle(lineWidth: width, lineCap: .round, dash: after ? [4, 5] : []))
            }
            if mark < 1 { ball = pts.last }
        }
        func drawBall(_ p: SIMD3<Double>, alpha: Double, squash: Double) {
            let lift = max(0, p.z - ballR), spread = 1 + lift * 0.6
            if let s = shape(Self.ellipse(Self.shadow(SIMD3(p.x, p.y, lift)), ballR * spread * 1.25, ballR * spread, Self.sun)) {
                gc.fill(s, with: .color(.black.opacity(max(0.12, 0.55 - lift * 0.12) * alpha)))
            }
            let q = cam.view(p); guard q.z >= 0.1 else { return }
            let s = cam.screen(q, width: w, height: h), r = max(5, ballR * f / q.z)
            let rect = CGRect(x: s.x - r * (2 - squash), y: s.y + r * (1 - squash) * 0.5 - r * squash, width: 2 * r * (2 - squash), height: 2 * r * squash)
            gc.drawLayer { layer in
                layer.opacity = alpha
                layer.addFilter(.shadow(color: Palette.rgb(0xd2ff5a, 0.55), radius: r * 0.6))
                layer.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(stops: [.init(color: Palette.ballLight, location: 0), .init(color: Palette.ball, location: 0.45), .init(color: Palette.ballDark, location: 1)]),
                    center: CGPoint(x: s.x - r * 0.35, y: s.y - r * 0.4), startRadius: r * 0.1, endRadius: r))
            }
            var seam = Path()
            for i in 0...12 {
                let a = 2.2 + (4.1 - 2.2) * Double(i) / 12
                let point = CGPoint(x: s.x + r * 0.9 + r * 0.75 * cos(a), y: s.y - r * 0.2 + r * 0.75 * sin(a))
                if i == 0 { seam.move(to: point) } else { seam.addLine(to: point) }
            }
            gc.stroke(seam, with: .color(.white.opacity(0.7 * alpha)), lineWidth: max(0.6, r * 0.12))
        }
        if let ball { drawBall(ball, alpha: trail, squash: 1) }
        if mark > 0, trail > 0 { drawBall(scene.bounce, alpha: 0.3 * mark * trail, squash: 1 - 0.12 * sin(min(1, mark * 1.4) * .pi)) }
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(Gradient(colors: [.black.opacity(0), .black.opacity(0.5)]),
                center: CGPoint(x: w / 2, y: h * 0.55), startRadius: h * 0.35, endRadius: max(w, h) * 0.65))
        if frame.measure > 0 { paintMeasure(&gc, cam: cam, w: w, h: h) }
    }

    /// The overhead shot's reading: a dimension bar beside the mark from the line to the footprint, as
    /// long as the gap the verdict states, with that number; an in footprint on the line says so; a close
    /// call labels its band instead of a number.
    func paintMeasure(_ gc: inout GraphicsContext, cam: HawkEyeCamera, w: Double, h: Double) {
        let m = frame.measure, j = scene.judgement
        func project(_ p: SIMD3<Double>) -> CGPoint? { cam.project(p, width: w, height: h).map { CGPoint(x: $0.x, y: $0.y) } }
        func label(_ string: String, right x: Double, y: Double, size: Double) {
            let text = gc.resolve(Text(string).font(.system(size: size, weight: .bold)).foregroundColor(.white))
            let tw = Double(text.measure(in: CGSize(width: w, height: h)).width)
            let left = max(8, x - tw - 18), box = CGRect(x: left, y: y - size * 0.85, width: tw + 18, height: size * 1.7)
            var tag = gc; tag.opacity = max(0, min(1, (m - 0.4) / 0.6))
            tag.fill(Path(roundedRect: box, cornerRadius: 8), with: .color(Palette.rgb(0x050807, 0.82)))
            tag.draw(text, at: CGPoint(x: left + 9, y: y), anchor: .leading)
        }
        let height = max(0.3, cam.position.z)
        let side = scene.along * max(scene.footprint.along + 0.07, 0.06 * height)
        if let gap = scene.measure {
            // drawn from the line toward the mark
            let (lineEnd, markEnd) = j.call == .out ? (gap.from, gap.to) : (gap.to, gap.from)
            guard let a0 = project(lineEnd), let b0 = project(markEnd), let a = project(lineEnd + side),
                  let bFull = project(markEnd + side) else { return }
            let b = CGPoint(x: a.x + (bFull.x - a.x) * m, y: a.y + (bFull.y - a.y) * m)
            var ext = Path(); ext.move(to: a0); ext.addLine(to: a); ext.move(to: b0); ext.addLine(to: bFull)
            gc.stroke(ext, with: .color(.white.opacity(0.75 * min(1, m * 3))), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let dx = bFull.x - a.x, dy = bFull.y - a.y, l = max(1, hypot(dx, dy)), nx = -dy / l * 7, ny = dx / l * 7
            var bar = Path(); bar.move(to: a); bar.addLine(to: b)
            for q in [a, b] { bar.move(to: CGPoint(x: q.x - nx, y: q.y - ny)); bar.addLine(to: CGPoint(x: q.x + nx, y: q.y + ny)) }
            gc.stroke(bar, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            label("\(Int((gap.metres * 100).rounded())) 厘米", right: Double(min(a.x, bFull.x)) - 12, y: Double(a.y + bFull.y) / 2, size: 20)
        } else if let p = project(scene.bounce + side) {
            let text = j.call == .close ? "误差 ±\(Int((j.marginM * 100).rounded())) 厘米" : "球印压线"
            label(text, right: Double(p.x) - 6, y: Double(p.y) - 30, size: 17)   // above the line it sits on
        }
    }
}
