import SwiftUI
import CourtCore

/// A square icon button on a `raised` tile (history, back). It grows with the text size so it stays
/// as easy to find as the text beside it; the cap keeps it from crowding a phone's toolbar.
struct CourtIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 20
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: min(glyph, 32), weight: .medium))
                .frame(width: min(max(side, 44), 68), height: min(max(side, 44), 68))
                .background(CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// 历史记录 as an icon button (home, display toolbar, landscape header).
struct CourtHistoryIconButton: View {
    let action: () -> Void
    var body: some View { CourtIconButton(systemImage: "clock.arrow.circlepath", label: "历史记录", action: action) }
}

/// A text-only button (a sheet's 完成 / 取消, a small 取消 beside progress) whose 44-point hit area
/// is inside the button: a `.frame` outside a `Button` grows its layout, not the area that takes the tap.
struct CourtTextButton: View {
    let title: String
    var font: Font?
    let action: () -> Void
    init(_ title: String, font: Font? = nil, action: @escaping () -> Void) {
        self.title = title; self.font = font; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(font).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
    }
}

// MARK: Stroke marks

extension TennisStrokeKind {
    /// The court map's mark: the same shape as the speed scatter (`courtSymbol`), drawn here so the
    /// cross, plus and star have area and the browser page can copy the same geometry.
    func courtMarkPath(center c: CGPoint, radius r: CGFloat) -> Path {
        func polygon(_ count: Int, rotation: Double, radius: CGFloat) -> [CGPoint] {
            (0..<count).map { index in
                let angle = rotation + Double(index) * 2 * .pi / Double(count)
                return CGPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
            }
        }
        var path = Path()
        switch self {
        case .forehand:
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        case .backhand:
            let side = r * 1.75
            path.addRect(CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side))
        case .serve:
            path.addLines(polygon(3, rotation: -.pi / 2, radius: r * 1.2).map { CGPoint(x: $0.x, y: $0.y + r * 0.2) }); path.closeSubpath()
        case .volley:
            path.addLines(polygon(4, rotation: -.pi / 2, radius: r * 1.25)); path.closeSubpath()
        case .overhead:
            path.addLines(polygon(5, rotation: -.pi / 2, radius: r * 1.15)); path.closeSubpath()
        case .groundstroke, .feed:
            // A thick cross (×) or plus (+) with area, so it fills and reads at a glance.
            // One 12-point outline (not two rectangles), so its border has no lines across the middle.
            let arm = r * 1.15, half = r * 0.38
            var plus = Path()
            plus.addLines([CGPoint(x: c.x - half, y: c.y - arm), CGPoint(x: c.x + half, y: c.y - arm), CGPoint(x: c.x + half, y: c.y - half),
                           CGPoint(x: c.x + arm, y: c.y - half), CGPoint(x: c.x + arm, y: c.y + half), CGPoint(x: c.x + half, y: c.y + half),
                           CGPoint(x: c.x + half, y: c.y + arm), CGPoint(x: c.x - half, y: c.y + arm), CGPoint(x: c.x - half, y: c.y + half),
                           CGPoint(x: c.x - arm, y: c.y + half), CGPoint(x: c.x - arm, y: c.y - half), CGPoint(x: c.x - half, y: c.y - half)])
            plus.closeSubpath()
            // The cross is the plus turned 45° about the center.
            path = self == .feed ? plus
                : plus.applying(CGAffineTransform(translationX: c.x, y: c.y).rotated(by: .pi / 4).translatedBy(x: -c.x, y: -c.y))
        case .unknown:
            // Five-pointed star.
            let outer = polygon(5, rotation: -.pi / 2, radius: r * 1.3)
            let inner = polygon(5, rotation: -.pi / 2 + .pi / 5, radius: r * 0.55)
            path.addLines((0..<5).flatMap { [outer[$0], inner[$0]] }); path.closeSubpath()
        }
        return path
    }
}

/// The stroke's mark as a view, for legends next to the court map.
struct CourtStrokeMark: View {
    let kind: TennisStrokeKind
    var size: CGFloat = 10
    var body: some View {
        Canvas { context, canvas in
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            context.fill(kind.courtMarkPath(center: center, radius: min(canvas.width, canvas.height) / 2 * 0.78), with: .color(kind.courtColor))
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

// MARK: Court map wording

extension TennisShotEvent {
    /// What VoiceOver says for one bounce on the court map: shot number, stroke, speed when known and
    /// roughly where it landed. Placement is a model estimate, so it is rounded and said with 「约」.
    func courtMapSpokenDescription(number: Int) -> String {
        var parts = ["第 \(number) 拍", stroke.courtTitle]
        if let speed = validSpeedKPH { parts.append("约 " + courtSpeed(speed) + " 千米每小时") } else { parts.append("暂无球速") }
        if let position = bounce?.courtPosition {
            parts.append(Self.courtZone(x: position.x, y: position.y))
            parts.append(String(format: "约横 %.1f 米、纵 %.1f 米", position.x, position.y))
        }
        return parts.joined(separator: "，")
    }

    /// Half and area of the court, from the near baseline (y = 0) to the far one (23.77 m).
    static func courtZone(x: Double, y: Double) -> String {
        let length = 23.77, width = 10.97, net = length / 2, serviceDepth = 6.40
        let inside = x >= 0 && x <= width && y >= 0 && y <= length
        guard inside else { return "场外" }
        let half = y < net ? "近端半场" : "远端半场"
        let fromNet = abs(y - net)
        let singles = x >= 1.37 && x <= width - 1.37
        let area = !singles ? "双打边线区" : fromNet <= serviceDepth ? "发球区" : "后场"
        return half + area
    }
}
