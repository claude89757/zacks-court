import SwiftUI
import CourtCore

/// Display-side view of the camera's 1 Hz status: capture, analysis delay, device load and link.
/// Unknown values show "—", never 0.
@MainActor
struct CameraStatusSummary: View {
    let model: WorkspaceModel
    /// Off inside the 「机位与分析」 card, whose header already carries the state.
    var showsStatusPill = true
    var body: some View {
        let status = model.connected ? model.cameraStatus : nil
        VStack(alignment: .leading, spacing: CourtStyle.Space.m) {
            if showsStatusPill {
                HStack {
                    CourtStatus(text: model.isLive ? "机位实时更新" : model.connected ? "已连接 · 机位未在采集" : "尚未连接机位", active: model.isLive)
                    Spacer()
                }
            }
            if model.connected { Text(model.deviceName).font(.callout).foregroundStyle(CourtStyle.muted) }
            CourtMetricGrid {
                CourtMetric(title: "机位采集", value: model.isLive ? "\(status?.fps ?? 0)" : "—", unit: "fps")
                CourtMetric(title: "相机丢帧", value: status.map { "\($0.captureDrops)" } ?? "—", unit: "帧")
                CourtMetric(title: "分析落后", value: model.analysisProgressGap.map { String(format: "%.2f", $0) } ?? "—", unit: "s")
                CourtMetric(title: "数据速率", value: model.connected ? String(format: "%.1f", model.linkStats.kilobytesPerSecond) : "—", unit: "KB/s")
                CourtMetric(title: "低清预览", value: status?.previewing == true ? String(format: "%.0f", model.linkStats.previewFPS) : "—", unit: "fps")
                CourtMetric(title: "机位电量", value: status?.device.battery.map { "\(Int(($0 * 100).rounded()))" } ?? "—",
                            unit: status?.device.charging == true ? "% 充电中" : "%")
                CourtMetric(title: "机位温度", value: status.map { Self.thermalTitle($0.device.thermal) } ?? "—", unit: "")
                CourtMetric(title: "负载保护", value: status.map { "L\($0.shed)" } ?? "—", unit: "")
                CourtMetric(title: "镜头倍率", value: status?.zoom.map(CameraZoomRange.title) ?? "—", unit: "")
            }
            if let status {
                ForEach(([status.shedReason].compactMap { $0 } + status.warnings), id: \.self) { warning in
                    CourtNotice(text: warning, warning: true)
                }
                if status.device.screen == "standby" {
                    Label("机位屏幕处于省电值守", systemImage: "moon").font(.caption).foregroundStyle(CourtStyle.muted)
                }
            }
            if model.connected, let path = model.linkPath {
                Label("连接方式：" + path.title, systemImage: path == .peerToPeer ? "dot.radiowaves.left.and.right" : "wifi")
                    .font(.caption).foregroundStyle(CourtStyle.muted)
            }
            Label(model.backupStatus, systemImage: "externaldrive.badge.checkmark").font(.caption).foregroundStyle(CourtStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.connected {
                Button { model.wakeCameraScreen() } label: { Label("唤醒机位屏幕", systemImage: "sun.max").frame(maxWidth: .infinity) }
                    .buttonStyle(CourtButton())
            }
            Text("分析落后 = 机位采集时钟 − 最后分析帧，两者来自机位同一时钟；网络延迟只影响看板显示，不影响分析。")
                .font(.caption2).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func thermalTitle(_ value: String) -> String {
        switch value {
        case "nominal": return "正常"
        case "fair": return "偏暖"
        case "serious": return "偏高"
        case "critical": return "过热"
        default: return "—"
        }
    }
}

/// The display's one-glance health of the camera and its analysis: OK, or what needs attention.
@MainActor
struct CameraHealth {
    let tone: CourtStatus.Tone
    let title: String
    /// Things to act on, each already saying what is wrong.
    let attention: [String]

    init(model: WorkspaceModel) {
        var items: [String] = []
        if model.connected {
            if let error = model.tennisAnalysisError { items.append(error) }
            else if !model.analysisModelsAvailable { items.append("分析模型尚未就绪，球速、落点和动作不会生成。") }
            if let error = model.analysisError { items.append(error) }
            if let status = model.cameraStatus {
                if let reason = status.shedReason { items.append(reason) }
                items.append(contentsOf: status.warnings)
                if status.device.thermal == "serious" || status.device.thermal == "critical" {
                    items.append("机位温度" + CameraStatusSummary.thermalTitle(status.device.thermal) + "，可能进入负载保护、暂停部分分析。")
                }
                if let free = status.device.freeBytes, StorageCleanup.recordingMinutes(freeBytes: free) < CourtStorageSheet.lowMinutes {
                    items.append("机位手机剩余空间约可录 \(StorageCleanup.recordingMinutes(freeBytes: free)) 分钟，可在机位的「历史记录 › 管理存储空间」里清理。")
                }
            }
            if model.isLive, model.recognition.rows.contains(where: { $0.id == "court.recognition.court" && $0.tone == .warning }) {
                items.append("球场映射未就绪：正在自动识别球场，识别出来前不画落点、不判界内外。")
            }
        }
        var seen = Set<String>()
        attention = items.filter { seen.insert($0).inserted }
        if !model.connected { tone = .idle; title = "未连接" }
        else if !attention.isEmpty { tone = .warning; title = "需要处理" }
        else if model.isLive { tone = .live; title = "正常" }
        else { tone = .idle; title = "等待采集" }
    }
}

/// 「机位与分析」 on the phone display: its state, four key values and the setup actions on top;
/// the full camera status, recognition rows and people overlay folded underneath. The Mac display
/// shows the same card in its side column.
@MainActor
struct CameraHealthCard<Actions: View>: View {
    @Bindable var model: WorkspaceModel
    @Binding var showPeople: Bool
    @ViewBuilder var actions: Actions
    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let health = CameraHealth(model: model)
        let status = model.connected ? model.cameraStatus : nil
        CourtPanel("机位与分析", accessory: { CourtStatus(text: health.title, tone: health.tone) }) {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: CourtStyle.Space.s))
                : AnyLayout(HStackLayout(alignment: .top, spacing: CourtStyle.Space.s))
            layout {
                value("电量", status?.device.battery.map { "\(Int(($0 * 100).rounded()))%" }, detail: status?.device.charging == true ? "充电中" : nil)
                value("温度", status.map { CameraStatusSummary.thermalTitle($0.device.thermal) })
                value("倍率", status?.zoom.map(CameraZoomRange.title))
                value("分析落后", model.analysisProgressGap.map { String(format: "%.1f s", $0) })
            }
            ForEach(health.attention, id: \.self) { CourtNotice(text: $0, warning: true) }
            actions
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: CourtStyle.Space.l) {
                    CameraStatusSummary(model: model, showsStatusPill: false)
                    Divider().overlay(CourtStyle.border)
                    TennisAnalysisStatus(status: model.tennisAnalysisStatus, modelsAvailable: model.analysisModelsAvailable,
                                         calibration: model.tennisAnalysis?.calibration, error: model.tennisAnalysisError,
                                         isLive: model.isLive, limitations: model.tennisAnalysis?.limitations ?? [],
                                         recognition: model.recognition, embedded: true)
                    Divider().overlay(CourtStyle.border)
                    VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                        Text("人员辅助检测").font(.subheadline.weight(.semibold))
                        Toggle("在画面上显示人员框与短时轨迹", isOn: $showPeople).font(.callout).frame(minHeight: 44)
                        if let analysis = model.analysis, model.isLive {
                            Text("当前检测 \(analysis.people.count) 人 · 图像内移动 \(analysis.people.filter(\.isMoving).count) 人")
                                .font(.caption).foregroundStyle(CourtStyle.muted)
                        } else { CourtNotice(text: "收到画面后提供辅助人员检测。") }
                        CourtNotice(text: "人员编号仅用于短时关联，图像脚点不是球的落点。")
                    }
                }.padding(.top, CourtStyle.Space.m)
            } label: {
                Text("详细状态").font(.callout.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("court.health.details")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.health")
    }

    private func value(_ title: String, _ value: String?, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(CourtStyle.muted).lineLimit(1)
            Text(value ?? "—").font(.callout.weight(.medium).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(value == nil ? CourtStyle.muted : .white)
            if let detail { Text(detail).font(.caption2).foregroundStyle(CourtStyle.muted).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CourtStyle.Space.s)
        .background(CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.field))
        .accessibilityElement(children: .combine)
    }
}
