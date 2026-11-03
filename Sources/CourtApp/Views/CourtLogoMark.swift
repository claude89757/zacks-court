import SwiftUI

/// The app icon drawn as a vector, for the brand spots inside the app: a ball's mark on the line, the
/// ball bouncing on. Same geometry as `assets/brand/zacks-court-logo.svg` (a 1024 square); the colours are
/// the artwork's own, not interface tokens. Decorative: hidden from VoiceOver.
struct CourtLogoMark: View {
    var size: CGFloat = 32

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 1024
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let all = CGRect(origin: .zero, size: canvas)
            context.fill(Path(all), with: .linearGradient(
                Gradient(colors: [Self.rgb(0x17331F), Self.rgb(0x07120C)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: canvas.height)))
            context.fill(Path(CGRect(x: 0, y: 648 * s, width: canvas.width, height: 70 * s)), with: .color(Self.ivory))
            let mark = CGRect(x: 260 * s, y: 618 * s, width: 340 * s, height: 92 * s)
            context.fill(Path(ellipseIn: mark), with: .radialGradient(
                Gradient(stops: [.init(color: Self.rgb(0xD4F77A), location: 0), .init(color: Self.lime.opacity(0.8), location: 0.72),
                                 .init(color: Self.lime.opacity(0), location: 1)]),
                center: CGPoint(x: mark.midX, y: mark.midY), startRadius: 0, endRadius: mark.width / 2))
            var into = Path(); into.move(to: p(110, 190)); into.addCurve(to: p(424, 630), control1: p(250, 300), control2: p(350, 470))
            context.stroke(into, with: .linearGradient(Gradient(colors: [Self.lime.opacity(0), Self.lime.opacity(0.75)]),
                                                         startPoint: p(110, 190), endPoint: p(424, 630)),
                           style: StrokeStyle(lineWidth: 40 * s, lineCap: .round))
            var away = Path(); away.move(to: p(436, 630)); away.addCurve(to: p(660, 380), control1: p(500, 500), control2: p(580, 420))
            context.stroke(away, with: .linearGradient(Gradient(colors: [Self.lime.opacity(0.75), Self.lime.opacity(0.15)]),
                                                         startPoint: p(436, 630), endPoint: p(660, 380)),
                           style: StrokeStyle(lineWidth: 40 * s, lineCap: .round))
            let ball = CGRect(x: 570 * s, y: 170 * s, width: 344 * s, height: 344 * s)
            context.fill(Path(ellipseIn: ball), with: .radialGradient(
                Gradient(stops: [.init(color: Self.rgb(0xE6FF96), location: 0), .init(color: Self.lime, location: 0.55),
                                 .init(color: Self.rgb(0x8DBE30), location: 1)]),
                center: p(694, 273), startRadius: 0, endRadius: 268 * s))
            var seams = Path()
            seams.move(to: p(630, 236)); seams.addCurve(to: p(640, 452), control1: p(708, 286), control2: p(712, 398))
            seams.move(to: p(854, 232)); seams.addCurve(to: p(846, 454), control1: p(776, 282), control2: p(772, 400))
            context.stroke(seams, with: .color(Self.ivory), style: StrokeStyle(lineWidth: 22 * s, lineCap: .round))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.224, style: .continuous))
        .accessibilityHidden(true)
    }

    private static let lime = rgb(0xC2F057)
    private static let ivory = rgb(0xF3EED9)
    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
