import SwiftUI

@MainActor
public struct CourtLiveVideoWindow: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    public init(model: WorkspaceModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(courtText("实时画面"), systemImage: "video").font(.headline)
                Spacer()
                CourtStatus(text: model.isLive ? courtText("正在接收") : model.connected ? courtText("等待机位开始采集") : courtText("等待机位连接"), tone: model.isLive ? .live : .idle)
                #if os(iOS)
                CourtTextButton(courtText("完成")) { dismiss() }
                #endif
            }
            ServerVideo(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(model.deviceName).lineLimit(2)
                Spacer()
                if model.isLive {
                    Text(courtPrintf("低清预览 · 有延迟 · %.0f fps", model.linkStats.previewFPS)).monospacedDigit()
                }
                Button { model.wakeCameraScreen() } label: { Label(courtText("唤醒机位屏幕"), systemImage: "sun.max") }
                    .buttonStyle(CourtButton()).disabled(!model.connected)
            }.font(.caption).foregroundStyle(CourtStyle.muted)
        }.padding(18).background(CourtStyle.background).foregroundStyle(.white).tint(CourtStyle.green)
            .preferredColorScheme(.dark).accessibilityIdentifier("court.live-video.window")
    }
}
