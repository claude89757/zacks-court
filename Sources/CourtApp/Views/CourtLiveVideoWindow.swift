import SwiftUI

@MainActor
public struct CourtLiveVideoWindow: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    public init(model: WorkspaceModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("实时画面", systemImage: "video").font(.headline)
                Spacer()
                CourtStatus(text: model.isLive ? "正在接收" : model.connected ? "等待机位开始采集" : "等待机位连接", tone: model.isLive ? .live : .idle)
                #if os(iOS)
                CourtTextButton("完成") { dismiss() }
                #endif
            }
            ServerVideo(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(model.deviceName).lineLimit(2)
                Spacer()
                if model.isLive {
                    Text(String(format: "低清预览 · 有延迟 · %.0f fps", model.linkStats.previewFPS)).monospacedDigit()
                }
                Button { model.wakeCameraScreen() } label: { Label("唤醒机位屏幕", systemImage: "sun.max") }
                    .buttonStyle(CourtButton()).disabled(!model.connected)
            }.font(.caption).foregroundStyle(CourtStyle.muted)
        }.padding(18).background(CourtStyle.background).foregroundStyle(.white).tint(CourtStyle.green)
            .preferredColorScheme(.dark).accessibilityIdentifier("court.live-video.window")
    }
}
