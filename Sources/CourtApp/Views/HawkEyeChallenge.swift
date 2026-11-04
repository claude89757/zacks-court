import SwiftUI
import simd
import CourtCore

/// Timing of a challenge replay, in seconds, modelled on the broadcast sequence: title, the flight to
/// the bounce, the zoom to the line, the mark, then the verdict.
struct HawkEyeReplayTiming {
    let hasFlight: Bool
    var title: Double { 1.0 }
    var flightEnd: Double { hasFlight ? title + 2.2 : title }
    var zoomEnd: Double { flightEnd + 1.4 }
    var markEnd: Double { zoomEnd + 0.5 }
    var total: Double { markEnd + 0.3 }

    struct Frame {
        var camera: HawkEyeCamera
        /// Samples of the flight drawn so far (0 … count), fractional for a smooth ball.
        var flightProgress: Double
        var markOpacity: Double
        var verdict: Bool
        var titleOpacity: Double
    }

    func frame(_ t: Double, scene: HawkEyeReplayScene) -> Frame {
        let flightCount = Double((scene.flight?.count ?? 1) - 1)
        let bounceAt = Double(scene.bounceIndex)
        var progress = 0.0
        if hasFlight {
            let f = max(0, min(1, (t - title) / (flightEnd - title)))
            // most of the time to the bounce, then the short way on
            progress = f < 0.85 ? bounceAt * (f / 0.85) : bounceAt + (flightCount - bounceAt) * ((f - 0.85) / 0.15)
        }
        let zoom = (t - flightEnd) / (zoomEnd - flightEnd)
        return Frame(camera: HawkEyeCamera.blend(scene.wideCamera, scene.closeCamera, zoom),
                     flightProgress: progress,
                     markOpacity: max(0, min(1, (t - zoomEnd) / (markEnd - zoomEnd))),
                     verdict: t >= markEnd,
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
            Text("CHALLENGE").font(.system(size: 44, weight: .heavy, design: .rounded)).tracking(4)
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

    private func verdict(_ j: HawkEyeJudgement, challenged: Bool) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 18) {
                Text(j.call.shout)
                    .font(.system(size: 60, weight: .heavy, design: .rounded))
                    .foregroundStyle(j.call == .out ? Color.white : CourtStyle.background)
                    .padding(.horizontal, 22).padding(.vertical, 4)
                    .background(CourtStyle.callColor(j.call), in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                VStack(alignment: .leading, spacing: 4) {
                    Text(j.call.text + (j.serve ? " · 发球" : "") + (challenged ? " · " + j.format.text + "边线" : "")).font(.title2.weight(.bold))
                    Text(j.detailText).font(.callout).foregroundStyle(CourtStyle.muted)
                    Text((j.farHalf ? "远端半场，误差较大 · " : "") + "模型估计，不是判罚 · 误差范围 ±\(Int((j.marginM * 100).rounded())) 厘米")
                        .font(.caption).foregroundStyle(CourtStyle.muted)
                }
            }
            .padding(18)
            .background(CourtStyle.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.card).strokeBorder(CourtStyle.callColor(j.call), lineWidth: 2))
            .padding(CourtStyle.Space.l)
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
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.3 : timing.markEnd))
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

/// Draws one frame of the replay: court, lines, net, the flight so far with the ball, the mark and its
/// uncertainty, in the frame's camera.
struct HawkEyeReplayPainter {
    let scene: HawkEyeReplayScene
    let frame: HawkEyeReplayTiming.Frame

    func paint(_ gc: inout GraphicsContext, size: CGSize) {
        let w = Double(size.width), h = Double(size.height), cam = frame.camera
        func path(_ points: [SIMD3<Double>]) -> Path? {
            let s = cam.polygon(points, width: w, height: h)
            guard s.count >= 3 else { return nil }
            var p = Path(); p.move(to: CGPoint(x: s[0].x, y: s[0].y))
            for q in s.dropFirst() { p.addLine(to: CGPoint(x: q.x, y: q.y)) }
            p.closeSubpath(); return p
        }
        gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(CourtStyle.background))
        let W = HawkEye.width, L = HawkEye.length
        if let p = path([SIMD3(-6, -8, 0), SIMD3(W + 6, -8, 0), SIMD3(W + 6, L + 8, 0), SIMD3(-6, L + 8, 0)]) {
            gc.fill(p, with: .color(CourtStyle.courtSurface.opacity(0.65)))
        }
        if let p = path([SIMD3(0, 0, 0), SIMD3(W, 0, 0), SIMD3(W, L, 0), SIMD3(0, L, 0)]) {
            gc.fill(p, with: .color(CourtStyle.courtSurface))
        }
        // uncertainty under the lines, so the lines stay readable
        if frame.markOpacity > 0 {
            let u = scene.uncertainty
            let ring = (0..<48).map { i -> SIMD3<Double> in
                let a = Double(i) / 48 * 2 * .pi
                return SIMD3(scene.bounce.x + u.x * cos(a), scene.bounce.y + u.y * sin(a), 0)
            }
            if let p = path(ring) {
                gc.fill(p, with: .color(CourtStyle.callColor(scene.judgement.call).opacity(0.16 * frame.markOpacity)))
                gc.stroke(p, with: .color(CourtStyle.callColor(scene.judgement.call).opacity(0.55 * frame.markOpacity)),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        for rect in HawkEyeCourtLines.rectangles() { if let p = path(rect) { gc.fill(p, with: .color(.white.opacity(0.92))) } }
        // the judged line, picked out once the zoom is done
        if frame.markOpacity > 0 {
            let a = scene.lineAnchor, n = scene.outward, along = SIMD3(-n.y, n.x, 0)
            let width = scene.judgement.line == .baseline ? 0.10 : 0.05
            let span: SIMD3<Double> = along * 1.2, inward: SIMD3<Double> = n * width
            let edge: [SIMD3<Double>] = [a - span, a + span, a + span - inward, a - span - inward]
            if let p = path(edge) { gc.stroke(p, with: .color(CourtStyle.green.opacity(0.8 * frame.markOpacity)), lineWidth: 1.5) }
        }
        let net = HawkEye.netY
        let post: Double = W + 0.9, middle: Double = W / 2
        let netShape: [SIMD3<Double>] = [SIMD3(-0.9, net, 0), SIMD3(post, net, 0), SIMD3(post, net, 1.07), SIMD3(middle, net, 0.914), SIMD3(-0.9, net, 1.07)]
        if let p = path(netShape) {
            gc.fill(p, with: .color(.white.opacity(0.10)))
            gc.stroke(p, with: .color(.white.opacity(0.55)), lineWidth: 1)
        }
        if let flight = scene.flight, frame.flightProgress > 0 {
            let n = min(Double(flight.count - 1), frame.flightProgress)
            let whole = Int(n)
            var pts = Array(flight[0...whole])
            if whole < flight.count - 1 { pts.append(flight[whole] + (flight[whole + 1] - flight[whole]) * (n - Double(whole))) }
            var trail = Path(), started = false
            for p in pts {
                guard let s = cam.project(p, width: w, height: h) else { started = false; continue }
                if started { trail.addLine(to: CGPoint(x: s.x, y: s.y)) } else { trail.move(to: CGPoint(x: s.x, y: s.y)); started = true }
            }
            gc.stroke(trail, with: .color(CourtStyle.green.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            if let ball = pts.last, frame.markOpacity < 1 {
                let c = cam.view(ball)
                if c.z > HawkEyeCamera.near {
                    let s = cam.screen(c, width: w, height: h)
                    let f = h / (2 * tan(cam.fovDegrees * .pi / 360))
                    let r = max(3, HawkEye.ballRadius * f / c.z)
                    gc.fill(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(red: 0.86, green: 0.95, blue: 0.25)))
                }
            }
        }
        if frame.markOpacity > 0 {
            let r = scene.markRadius
            let mark = (0..<32).map { i -> SIMD3<Double> in
                let a = Double(i) / 32 * 2 * .pi
                return SIMD3(scene.bounce.x + r * cos(a), scene.bounce.y + r * sin(a), 0)
            }
            if let p = path(mark) {
                gc.fill(p, with: .color(CourtStyle.callColor(scene.judgement.call).opacity(0.9 * frame.markOpacity)))
                gc.stroke(p, with: .color(.white.opacity(frame.markOpacity)), lineWidth: 1)
            }
        }
    }
}
