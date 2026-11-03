import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CourtCore
#if os(iOS)
import UIKit
#endif

/// 「导入视频」: analyse a tennis video from Photos or Files with the camera's in-house models and
/// save it as a record. Reachable from the start page, so it works without a court or a second device.
@MainActor struct VideoImportSheet: View {
    @State var model: VideoImportModel
    var openRecord: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFile = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CourtNotice(text: "不在球场也能试：选一段在球场拍的网球视频，App 用机位同一套自研模型逐拍估计球速、落点和动作，结果作为一条记录存进历史。这些都是模型估计，不是测量。")
                        .accessibilityIdentifier("court.import.notice")
                    if let reason = model.unavailableReason {
                        CourtNotice(text: reason, warning: true).accessibilityIdentifier("court.import.unavailable")
                    }
                    pickPanel
                    if model.isRunning, let progress = model.progress { progressPanel(progress) }
                    if let message = model.message, model.phase != .rejected {
                        CourtNotice(text: message, warning: true).accessibilityIdentifier("court.import.message")
                    }
                    if model.phase == .done, let session = model.result { resultPanel(session) }
                }
                .padding(22).frame(maxWidth: 850).frame(maxWidth: .infinity)
            }
            .background(CourtStyle.background)
            .navigationTitle("导入视频")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { model.close(); dismiss() }
                        .frame(minHeight: 44).accessibilityIdentifier("court.import.close")
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.movie], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let files): if let url = files.first { model.use(url, temporary: false) }
                case .failure(let error):
                    let value = error as NSError
                    if value.domain != NSCocoaErrorDomain || value.code != NSUserCancelledError { model.pickFailed("无法打开这个文件：\(error.localizedDescription)") }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                model.loadingFromPhotos()
                Task {
                    do {
                        if let movie = try await item.loadTransferable(type: PickedMovie.self) { model.use(movie.url, temporary: true) }
                        else { model.pickFailed("相册没有提供这段视频，请换一段或从「文件」选择。") }
                    } catch { model.pickFailed("无法从相册读取这段视频：\(error.localizedDescription)") }
                }
            }
        }
        .foregroundStyle(.white).tint(CourtStyle.green).preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.isRunning)
        .onChange(of: scenePhase) { _, phase in
            // Model inference cannot run in the background; stop cleanly instead of failing midway.
            if phase == .background { model.cancel(reason: "App 退到了后台，分析已停止，没有保存记录。请重新开始，并在分析完成前留在这一页。") }
        }
        .onChange(of: model.isRunning) { _, running in
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = running
            #endif
        }
        .onDisappear {
            // The owner closes the model when the sheet is really dismissed: the Files picker can
            // hide this view for a while on iPhone.
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 700, minHeight: 560)
        #endif
    }

    private var pickPanel: some View {
        CourtPanel("选择视频") {
            Text("横屏 16:9（720p 或更清晰）、60 帧/秒、3 秒到 10 分钟。镜头像机位那样从场边或底线后方拍下整片球场时，球速和落点最容易估计出来。")
                .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            PhotosPicker(selection: $photoItem, matching: .videos, preferredItemEncoding: .current) {
                Label("从相册选择", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(CourtButton()).disabled(!model.canPick)
            .accessibilityIdentifier("court.import.photos")
            Button { choosingFile = true } label: { Label("从文件选择", systemImage: "folder").frame(maxWidth: .infinity) }
                .buttonStyle(CourtButton()).disabled(!model.canPick)
                .accessibilityIdentifier("court.import.files")
            switch model.phase {
            case .loading: ProgressView("正在从相册读取视频…").accessibilityIdentifier("court.import.loading")
            case .inspecting: ProgressView("正在检查视频…").accessibilityIdentifier("court.import.loading")
            default: EmptyView()
            }
            if let info = model.info {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.filename).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(info.summary).font(.callout).foregroundStyle(CourtStyle.muted)
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("court.import.video")
            }
            if model.phase == .rejected, let reason = model.message {
                CourtNotice(text: reason, warning: true).accessibilityIdentifier("court.import.rejection")
            }
            if !model.isRunning {
                Button { model.start() } label: {
                    Label(model.phase == .done ? "再分析一次" : "开始分析", systemImage: "sparkle.magnifyingglass").frame(maxWidth: .infinity)
                }
                .buttonStyle(CourtButton(primary: true)).disabled(!model.canStart)
                .accessibilityIdentifier("court.import.start")
            }
        }
    }

    private func progressPanel(_ progress: VideoImportRun.Progress) -> some View {
        CourtPanel("正在分析") {
            ProgressView(value: progress.fraction).accessibilityIdentifier("court.import.progress")
            Text(Self.progressText(progress)).font(.callout).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("court.import.progressText")
            Text("视频越长分析越久。完成前请留在这一页，App 退到后台会停止分析。")
                .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            Button("取消") { model.cancel() }
                .buttonStyle(CourtButton()).accessibilityIdentifier("court.import.cancel")
        }
    }

    private func resultPanel(_ session: CourtSession) -> some View {
        let rows = session.tennisEvents ?? []
        let speeds = rows.filter { $0.speedKPH != nil }.count
        return CourtPanel("已存入历史记录") {
            CourtStatus(text: session.title, tone: .idle)
            Text(rows.isEmpty
                 ? "没有识别出击球：画面里可能看不清球或球场。记录和录像已保存，可以在历史里回看。"
                 : "共 \(rows.count) 拍，其中 \(speeds) 拍有球速估计；其余显示「—」并写明原因。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("court.import.result")
            Button { openRecord(session.id) } label: {
                Label("查看记录", systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(CourtButton(primary: true)).accessibilityIdentifier("court.import.openRecord")
        }
    }

    static func progressText(_ progress: VideoImportRun.Progress) -> String {
        switch progress.stage {
        case .loadingModel: return "正在载入自研模型…"
        case .saving: return "分析完成，正在保存记录…"
        case .analyzing:
            return String(format: "已分析 %.0f / %.0f 秒 · 已识别 %d 拍", progress.analyzedSeconds, progress.totalSeconds, progress.shots)
        }
    }
}
