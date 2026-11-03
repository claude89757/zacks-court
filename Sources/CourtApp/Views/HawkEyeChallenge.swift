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

/// 「界内外回放」: replays the newest judged shot (or one picked with the arrows) the way a broadcast
/// Hawk-Eye challenge does, then offers the shot's video. The picture is drawn from the model's
/// estimates; the verdict keeps the call's three states and its distance.
@MainActor
struct HawkEyeChallengeView: View {
    let model: WorkspaceModel
    @State private var index: Int
    @State private var started = Date()
    @State private var playback: PlaybackItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: WorkspaceModel) {
        self.model = model
        _index = State(initialValue: max(0, Self.judged(model.shownEvents).count - 1))
    }

    static func judged(_ events: [TennisShotEvent]) -> [(number: Int, shot: TennisShotEvent)] {
        events.enumerated().compactMap { i, e in e.bounce?.hawkEye == nil ? nil : (i + 1, e) }
    }
    private var shots: [(number: Int, shot: TennisShotEvent)] { Self.judged(model.shownEvents) }
    private var current: (number: Int, shot: TennisShotEvent)? { shots.indices.contains(index) ? shots[index] : shots.last }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let current, let scene = HawkEyeReplayScene(event: current.shot) {
                replay(scene, number: current.number).id(current.shot.id)
                footer(current.shot)
            } else {
                Spacer()
                CourtNotice(text: "还没有判过界内外的拍。开启界内外后，近端（或全场）有落点的拍会出现在这里。")
                    .padding(CourtStyle.Space.xl)
                Spacer()
            }
        }
        .background(CourtStyle.background.ignoresSafeArea())
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(item: $playback) { RecordingPlayer(item: $0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.hawkeye.challenge")
    }

    private var header: some View {
        HStack(spacing: CourtStyle.Space.s) {
            Text("界内外回放").font(.headline)
            if let current { Text("#\(current.number)").font(.headline.monospacedDigit()).foregroundStyle(CourtStyle.muted) }
            Spacer(minLength: 8)
            iconButton("chevron.left", "上一个判定") { index = max(0, index - 1); started = Date() }
                .disabled(index <= 0)
            iconButton("chevron.right", "下一个判定") { index = min(shots.count - 1, index + 1); started = Date() }
                .disabled(index >= shots.count - 1)
            iconButton("arrow.counterclockwise", "重播") { started = Date() }
            iconButton("xmark", "关闭界内外回放") { dismiss() }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CourtStyle.Space.l).padding(.vertical, CourtStyle.Space.s)
    }

    private func iconButton(_ image: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image).frame(width: 44, height: 44).background(CourtStyle.raised, in: Circle()).contentShape(Circle())
        }.accessibilityLabel(label)
    }

    private func replay(_ scene: HawkEyeReplayScene, number: Int) -> some View {
        let timing = HawkEyeReplayTiming(hasFlight: scene.flight != nil)
        return TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? timing.total : context.date.timeIntervalSince(started)
            let frame = timing.frame(t, scene: scene)
            ZStack {
                Canvas { gc, size in HawkEyeReplayPainter(scene: scene, frame: frame).paint(&gc, size: size) }
                if frame.titleOpacity > 0 { titleCard(number: number).opacity(frame.titleOpacity) }
                if frame.verdict { verdict(scene.judgement).transition(.opacity) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(number) 拍界内外回放：\(scene.judgement.call.text)，\(scene.judgement.detailText)")
        .accessibilityIdentifier("court.hawkeye.replay")
    }

    private func titleCard(number: Int) -> some View {
        VStack(spacing: 6) {
            Text("CHALLENGE").font(.system(size: 44, weight: .heavy, design: .rounded)).tracking(4)
            Text("界内外回放 · 第 \(number) 拍").font(.title3).foregroundStyle(CourtStyle.muted)
        }
        .padding(.horizontal, 32).padding(.vertical, 20)
        .background(CourtStyle.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
    }

    private func verdict(_ j: HawkEyeJudgement) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 18) {
                Text(j.call.shout)
                    .font(.system(size: 60, weight: .heavy, design: .rounded))
                    .foregroundStyle(j.call == .out ? Color.white : CourtStyle.background)
                    .padding(.horizontal, 22).padding(.vertical, 4)
                    .background(CourtStyle.callColor(j.call), in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                VStack(alignment: .leading, spacing: 4) {
                    Text(j.call.text + (j.serve ? " · 发球" : "")).font(.title2.weight(.bold))
                    Text(j.detailText).font(.callout).foregroundStyle(CourtStyle.muted)
                    Text("模型估计，不是判罚 · 误差范围 ±\(Int((j.marginM * 100).rounded())) 厘米").font(.caption).foregroundStyle(CourtStyle.muted)
                }
            }
            .padding(18)
            .background(CourtStyle.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.card).strokeBorder(CourtStyle.callColor(j.call), lineWidth: 2))
            .padding(CourtStyle.Space.l)
        }
    }

    private func footer(_ shot: TennisShotEvent) -> some View {
        HStack(spacing: CourtStyle.Space.m) {
            ShotReplayButton(model: model, session: model.session, shot: shot) { playback = $0 }
                .frame(maxWidth: 360)
            Spacer(minLength: 0)
            if shot.hit == nil {
                Text("这条链没有击球点，只回放落点").font(.caption).foregroundStyle(CourtStyle.muted)
            } else {
                Text("轨迹按击球点和落点估算").font(.caption).foregroundStyle(CourtStyle.muted)
            }
        }
        .padding(.horizontal, CourtStyle.Space.l).padding(.bottom, CourtStyle.Space.m)
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
