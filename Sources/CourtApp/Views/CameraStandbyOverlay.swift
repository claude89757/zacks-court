import SwiftUI

/// Black standby screen for the recording camera. The preview layer is not mounted underneath,
/// so nothing is composited; text is dim, refreshed by the minute and shifted to avoid burn-in.
/// A tap anywhere only wakes the camera UI.
@MainActor
struct CameraStandbyOverlay: View {
    let lines: [String]
    let warning: String?
    let minute: Int
    let wake: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { Text($0) }
                if let warning { Text(warning).foregroundStyle(CourtStyle.warning.opacity(0.7)) }
                Text("轻点屏幕唤醒").padding(.top, 6)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color(white: 0.38))
            .padding(32)
            .offset(x: CGFloat(minute % 5) * 7, y: CGFloat(minute % 3) * 9)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: wake)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("省电值守中。" + lines.joined(separator: "，") + (warning.map { "，" + $0 } ?? ""))
        .accessibilityHint("轻点唤醒机位画面")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("court.camera.standby")
    }
}
