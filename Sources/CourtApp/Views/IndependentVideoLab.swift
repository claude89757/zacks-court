import SwiftUI
import UniformTypeIdentifiers
import CourtCore

/// Local-only experiment sheet. It deliberately owns no WorkspaceModel/session.
@MainActor public struct IndependentVideoLab: View {
    @State private var model: IndependentVideoLabModel
    @State private var choosingVideo = false
    @Environment(\.dismiss) private var dismiss
    public init() { _model = State(initialValue: IndependentVideoLabModel()) }
    public init(model: IndependentVideoLabModel) { _model = State(initialValue: model) }
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    CourtNotice(text: "实验功能：查看独立模型的球点候选，暂不提供球速。")
                        .accessibilityIdentifier("court.independent.notice")
                    inputPanel
                    if model.isBusy { progressPanel }
                    if let error = model.error {
                        CourtErrorBanner(text: error) { model.clearError() }
                            .accessibilityIdentifier("court.independent.error")
                    }
                    if let result = model.result { resultPanel(result) }
                    CourtPanel {
                        CourtMetric(title: "球速", value: model.speedText, unit: "km/h")
                            .accessibilityIdentifier("court.independent.speed")
                        Text(model.speedReason).font(.callout).foregroundStyle(CourtStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("court.independent.speedReason")
                        CourtNotice(text: "只在本机保存分析报告，不复制视频。重新打开画面需重选原视频。")
                    }
                }
                .padding(22).frame(maxWidth: 850).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("court.independent.scroll")
            .background(CourtStyle.background)
            .navigationTitle("本地视频实验")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { model.close(); dismiss() }
                        .frame(minHeight: 44).accessibilityIdentifier("court.independent.close")
                }
            }
            .fileImporter(isPresented: $choosingVideo, allowedContentTypes: [.movie], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let files): if let url = files.first { model.selectVideo(url) }
                case .failure(let error):
                    let value = error as NSError
                    if value.domain != NSCocoaErrorDomain || value.code != NSUserCancelledError { model.reportImportFailure(error.localizedDescription) }
                }
            }
        }
        .foregroundStyle(.white).tint(CourtStyle.green).preferredColorScheme(.dark)
        .task { await model.prepare() }
        .onDisappear {
            // A full-screen system file picker can hide this view on iPhone.
            // Picking is disabled during a run; explicit Done always closes.
            if !choosingVideo { model.close() }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 750, minHeight: 600)
        #endif
    }
    private var inputPanel: some View {
        @Bindable var editable = model
        return CourtPanel("分析本机视频") {
            switch model.modelAvailability {
            case .checking: Text("正在检查独立模型…").font(.callout).accessibilityIdentifier("court.independent.modelStatus")
            case .available: CourtStatus(text: "独立模型可用", tone: .idle).accessibilityIdentifier("court.independent.modelStatus")
            case .unavailable(let reason): CourtNotice(text: reason, warning: true).accessibilityIdentifier("court.independent.modelStatus")
            }
            Button { choosingVideo = true } label: { Label("选择视频", systemImage: "folder") }
                .buttonStyle(CourtButton()).disabled(model.isBusy)
                .accessibilityIdentifier("court.independent.choose")
            if let filename = model.filename {
                Text(filename).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("court.independent.filename")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("起始位置（秒）").font(.callout)
                secondsField("起始位置", value: $editable.startSeconds, id: "court.independent.startSeconds")
                Text("分析时长（秒）").font(.callout)
                secondsField("分析时长", value: $editable.durationSeconds, id: "court.independent.durationSeconds")
                Text("需要60fps视频，每次最多120秒；实际帧时间以原视频为准。")
                    .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            }.disabled(model.isBusy)
            Button { model.start() } label: {
                Label(model.result == nil ? "开始分析" : "重新分析", systemImage: "sparkle.magnifyingglass")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(CourtButton(primary: true)).disabled(!model.canStart)
                .accessibilityIdentifier("court.independent.start")
        }
    }
    private func secondsField(_ title: String, value: Binding<Double>, id: String) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
            .courtField().accessibilityLabel(title).accessibilityIdentifier(id)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }
    private var progressPanel: some View {
        CourtPanel {
            ProgressView(value: model.progressFraction).accessibilityIdentifier("court.independent.progress")
            Text(model.progressText).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("court.independent.progressText")
            Button(model.phase == .cancelling ? "正在取消…" : "取消") { model.cancel() }
                .buttonStyle(CourtButton()).disabled(model.phase == .cancelling)
                .accessibilityIdentifier("court.independent.cancel")
        }
    }
    private func resultPanel(_ result: IndependentLocalVideoResult) -> some View {
        CourtPanel("逐帧结果") {
            Text("读取\(result.frames.count)帧 · 分析\(result.inferredFrames)帧")
                .font(.callout).accessibilityIdentifier("court.independent.result")
            saveStatus
            if let frame = model.selectedFrame {
                Text("解码帧索引 \(frame.decodeIndex) · 第\(model.selectedFrameIndex+1)/\(result.frames.count)帧")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("court.independent.frameIndex")
                Text(Self.frameStatus(frame)).font(.callout).foregroundStyle(CourtStyle.muted)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("court.independent.frameStatus")
                Text(Self.pts(frame)).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("court.independent.framePTS")
                if let image = model.displayedImage {
                    Image(decorative: image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { proxy in
                                if let point = model.overlayPoint {
                                    Circle().stroke(Color.white, lineWidth: 2)
                                        .background(CourtStyle.inset, in: Circle())
                                        .frame(width: 16, height: 16)
                                        .position(x: point.x/CGFloat(image.width)*proxy.size.width,
                                                  y: point.y/CGFloat(image.height)*proxy.size.height)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .background(CourtStyle.inset)
                        .accessibilityLabel("与原始时间精确对应的视频帧")
                        .accessibilityIdentifier("court.independent.frameImage")
                } else if model.isLoadingFrame {
                    ProgressView("正在读取这一帧…").frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    CourtNotice(text: model.frameError ?? "这一帧暂无可显示画面。", warning: model.frameError != nil)
                        .accessibilityIdentifier("court.independent.frameUnavailable")
                    Button(model.frameError == nil ? "读取此帧" : "重试画面") { model.selectFrame(index: model.selectedFrameIndex) }
                        .buttonStyle(CourtButton()).disabled(model.isBusy || model.isLoadingFrame)
                        .accessibilityIdentifier("court.independent.reloadFrame")
                }
                HStack(spacing: 8) {
                    Circle().stroke(Color.white, lineWidth: 2).background(CourtStyle.inset, in: Circle()).frame(width: 12, height: 12)
                    Text("球点候选").font(.caption)
                }.foregroundStyle(.white).accessibilityIdentifier("court.independent.legend")
                Text(Self.point(frame)).font(.callout.monospaced()).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("court.independent.framePoint")
                VStack(spacing: 10) {
                    Button { model.selectFrame(index: model.selectedFrameIndex-1) } label: { Label("上一帧", systemImage: "chevron.left").frame(maxWidth: .infinity) }
                        .buttonStyle(CourtButton()).disabled(model.selectedFrameIndex == 0)
                        .accessibilityIdentifier("court.independent.previous")
                    Button { model.selectFrame(index: model.selectedFrameIndex+1) } label: { Label("下一帧", systemImage: "chevron.right").frame(maxWidth: .infinity) }
                        .buttonStyle(CourtButton()).disabled(model.selectedFrameIndex+1 >= result.frames.count)
                        .accessibilityIdentifier("court.independent.next")
                }
            } else { CourtNotice(text: "所选时间段没有返回实际帧。") }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("独立基础模型 · \(result.modelID)")
                    Text("来源摘要 \(result.sourceSHA256)").textSelection(.enabled)
                    Text("候选未经事件、人审或物理精度确认；预热与不完整分组不产生球点。")
                }.font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            } label: { Text("分析来源与限制").frame(minHeight: 44) }
            .accessibilityIdentifier("court.independent.provenance")
        }
    }
    @ViewBuilder private var saveStatus: some View {
        if let error = model.saveError {
            CourtNotice(text: error, warning: true).accessibilityIdentifier("court.independent.saveStatus")
            Button("重试保存报告") { model.retrySave() }.buttonStyle(CourtButton()).disabled(model.isBusy)
                .accessibilityIdentifier("court.independent.retrySave")
        } else if model.savedDirectory != nil {
            CourtStatus(text: "分析报告已保存在本机", tone: .idle).accessibilityIdentifier("court.independent.saveStatus")
        } else { Text("报告尚未保存。").font(.caption).foregroundStyle(CourtStyle.muted).accessibilityIdentifier("court.independent.saveStatus") }
    }
    private static func frameStatus(_ frame: IndependentLocalVideoFrameResult) -> String {
        switch frame.state {
        case .warmup: return "准备背景 · 尚未推理球点"
        case .pendingWindow: return "等待完整八帧分组"
        case .incompleteWindow: return "分组不足或遇到断层 · 未推理球点"
        case .tracked: return "球点候选 · 未确认真实球身份"
        case .missing: return frame.selection?.missingReason == "association_rejected" ? "关联未通过 · 球点未知" : "未找到球点候选"
        }
    }
    private static func pts(_ frame: IndependentLocalVideoFrameResult) -> String {
        let t = frame.time
        let raw = frame.presentationTime
        return "原PTS \(t.sourcePTS) × \(t.timeBaseNumerator)/\(t.timeBaseDenominator) 秒\n原始刻度 \(raw.value)/\(raw.timescale) · epoch \(raw.epoch)"
    }
    private static func point(_ frame: IndependentLocalVideoFrameResult) -> String {
        guard let point = frame.candidate?.originalXY, point.count == 2 else { return "原图球点：—" }
        return "原图候选球点：x \(point[0])，y \(point[1]) 像素"
    }
}
