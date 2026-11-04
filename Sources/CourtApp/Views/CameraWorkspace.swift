import SwiftUI
import CourtCore
import CoreImage.CIFilterBuiltins

@MainActor
struct CameraWorkspace: View {
    let model: WorkspaceModel
    var handedness: () -> Void = {}
    let leave: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var starting = false
    @State private var confirmStop = false
    @State private var confirmFinish = false
    @State private var selectedShot: UUID?
    @State private var title = ""
    @State private var section: CameraSection = .session
    @State private var showConnect = false
    /// History over the camera: the list, or one record's detail (「查看详情」 on the summary).
    @State private var history: HistoryTarget?
    struct HistoryTarget: Identifiable { let id = UUID(); var record: UUID? }
    @State private var pinchStart: Double?
    /// The setup tips on the 记录 page, until dismissed on this device (they stay in 设置).
    @AppStorage("court.camera.setupTipsDismissed") private var setupTipsDismissed = false

    private var camera: CameraModel { model.camera }
    private var controller: CameraSessionController? { model.camera.controller }

    /// The sidebar's pages. The page tabs, the connect button and warnings stay above them; the pages
    /// scroll. Leaving and capture sit on the picture. Connecting is not a page: it opens the full-screen
    /// connect page (docs/web-display.md).
    enum CameraSection: String, CaseIterable, Identifiable {
        case session, analysis, settings
        var id: String { rawValue }
        var title: String {
            switch self { case .session: return "记录"; case .analysis: return "分析"; case .settings: return "设置" }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width > geometry.size.height || geometry.size.width >= 700 {
                    // Landscape: no header row, so the sidebar keeps the phone's full height.
                    HStack(alignment: .top, spacing: 14) {
                        preview(showsLeave: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                        controls(showsLeave: true).frame(width: min(380, max(300, geometry.size.width * 0.40)))
                    }
                } else {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            // At accessibility sizes the label would take half the width; the icon keeps its name for VoiceOver.
                            leaveButton(iconOnly: dynamicTypeSize.isAccessibilitySize)
                            Text("机位").font(.headline)
                            Spacer(minLength: 0)
                        }
                        preview(showsLeave: false)
                        controls(showsLeave: false)
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }
        // Any touch postpones standby; it never blocks the touched control.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in camera.standby.noteActivity() })
        .overlay {
            if camera.standby.isDimmed {
                CameraStandbyOverlay(lines: camera.standbyLines, warning: camera.standbyWarning,
                                     minute: camera.standbyMinute) { camera.standby.wake() }
            }
        }
        #if os(iOS)
        .statusBarHidden(camera.standby.isDimmed)
        .persistentSystemOverlays(camera.standby.isDimmed ? .hidden : .automatic)
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showConnect) { CameraConnectView(model: model) { showConnect = false } }
        #else
        .sheet(isPresented: $showConnect) { CameraConnectView(model: model) { showConnect = false }.frame(minWidth: 720, minHeight: 480) }
        #endif
        // History opens over the camera without stopping capture or the session.
        .sheet(item: $history) { target in
            CourtHistory(model: model, open: target.record).task {
                // Reading history is activity: keep standby from dimming the screen meanwhile.
                while !Task.isCancelled {
                    camera.standby.noteActivity()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        .confirmationDialog("停止采集？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("停止采集", role: .destructive) { camera.stopByUser() }
        } message: { Text("进行中的记录会暂停，当前录像片段结束并保存在本机。") }
        .confirmationDialog("结束本次记录？", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("结束并保存", role: .destructive) { Task { await controller?.finish() } }
        } message: { Text("录像、逐拍分析与标记保存在这台机位上，连接的看板会同步完整清单。") }
    }

    private func leaveButton(iconOnly: Bool) -> some View {
        Button(action: leave) {
            if iconOnly { Label("切换模式", systemImage: "arrow.left").labelStyle(.iconOnly) }
            else { Label("切换模式", systemImage: "arrow.left") }
        }.buttonStyle(CourtButton())
    }

    /// At accessibility text sizes 开始采集 and 连接 move into the sidebar, which then scrolls as a whole
    /// so no control is cut off; leaving and stopping stay on the picture at every size.
    private var controlsOnPreview: Bool { !dynamicTypeSize.isAccessibilitySize }

    /// Fixed part (page tabs with 连接 in one row, errors, warnings) above the scrolling page, so a
    /// landscape phone keeps most of its height for the page. At accessibility text sizes the fixed
    /// part cannot fit, so everything scrolls together and no control is cut off.
    @ViewBuilder private func controls(showsLeave: Bool) -> some View {
        if !controlsOnPreview {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Controls first: the status can take several lines at these sizes. Leaving and
                    // stopping stay pinned on the picture: this sidebar can be thousands of points
                    // long, and the way out must never scroll away.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            if !camera.streaming { startCaptureButton }
                            connectButton(iconOnly: false)
                        }
                        // Narrow sidebar (iPhone SE landscape): one per row, so 「开始采集」 never breaks per character.
                        VStack(alignment: .leading, spacing: 8) {
                            if !camera.streaming { startCaptureButton }
                            connectButton(iconOnly: false)
                        }
                    }
                    notices
                    sectionPicker
                    CourtStatus(text: camera.displayStatus, active: camera.anyDisplayConnected).accessibilityIdentifier("court.camera.status")
                    page.background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
                }
            }.accessibilityIdentifier("court.camera.sidebar")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // One row: the three page tabs and 连接 (its label drops to the icon when narrow).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { sectionTabs; connectButton(iconOnly: false) }
                    HStack(spacing: 8) { sectionTabs; connectButton(iconOnly: true) }
                    VStack(spacing: 8) { connectButton(iconOnly: false); sectionPicker }
                }
                notices
                ScrollView { page }
                    .background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
                    .clipShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.card).strokeBorder(CourtStyle.border))
                    .accessibilityIdentifier("court.camera.sidebar")
            }
        }
    }

    /// Errors and warnings never hide behind a page: heavy load shedding, overheating, analysis falling
    /// behind, and notices (why the record paused, a transfer that stopped, backfill done).
    @ViewBuilder private var notices: some View {
        if let error = camera.error { CourtErrorBanner(text: error) { camera.error = nil } }
        if let error = controller?.error { CourtErrorBanner(text: error) { controller?.error = nil } }
        CourtBanners(model: model)
        // The camera's own notice may ask for a step (「重新开始采集后点「继续」」): it stays until closed.
        if let notice = controller?.notice { CourtNoticeBanner(text: notice) { controller?.notice = nil } }
        if let reason = controller?.shed.reason, (controller?.shed.level ?? 0) >= 2 { CourtNotice(text: reason, warning: true) }
        ForEach(camera.selfCheckWarnings, id: \.self) { CourtNotice(text: $0, warning: true) }
    }

    /// Connecting is optional (standalone works) but always one tap away: it opens the code a
    /// display scans, with the connection status and the App display's pairing below it.
    @ViewBuilder private func connectButton(iconOnly: Bool) -> some View {
        Button { showConnect = true } label: {
            let label = Label("连接", systemImage: camera.anyDisplayConnected ? "checkmark.circle" : "qrcode")
            if iconOnly { label.labelStyle(.iconOnly).frame(minWidth: 20) } else { label.fixedSize() }
        }.buttonStyle(CourtButton())
            .accessibilityLabel(camera.anyDisplayConnected ? "连接看板，已连接" : "连接看板")
            .accessibilityIdentifier("court.camera.connect")
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch section {
            case .session: sessionPage
            case .analysis: analysisPage
            case .settings: settingsPage
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Three tabs in a row, or a column when large text does not fit; each at least 44 pt tall.
    private var sectionPicker: some View {
        CourtSegment(options: CameraSection.allCases, selection: $section, title: \.title,
                     identifier: { "court.camera.section.\($0.rawValue)" })
            .accessibilityElement(children: .contain).accessibilityIdentifier("court.camera.sections")
    }
    /// The three tabs in one row only, for the fixed row beside 连接.
    private var sectionTabs: some View {
        CourtSegment(options: CameraSection.allCases, selection: $section, title: \.title,
                     identifier: { "court.camera.section.\($0.rawValue)" }, allowsColumn: false)
            .accessibilityElement(children: .contain).accessibilityIdentifier("court.camera.sections")
    }

    private func pageHeader(_ text: String) -> some View {
        Text(text).font(.headline).accessibilityAddTraits(.isHeader)
    }
    /// Why the control above is disabled, shown only while it is.
    private func disabledReason(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
    }
    /// Two buttons side by side, stacked when their labels do not fit.
    private func buttonPair<A: View, B: View>(@ViewBuilder _ first: () -> A, @ViewBuilder _ second: () -> B) -> some View {
        let a = first(), b = second()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { a; b }
            VStack(spacing: 10) { a; b }
        }
    }

    // MARK: Pages

    @ViewBuilder private var sessionPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            pageHeader(controller?.hasOpenSession == true ? "正在记录" : "本机记录")
            if let controller, controller.hasOpenSession || controller.session?.state == .interrupted, let session = controller.session {
                Text(session.title).font(.callout.weight(.medium))
                HStack(spacing: 10) {
                    CourtStatus(text: session.state.courtTitle, tone: session.state.courtTone)
                    Text(courtDuration(session.elapsed(at: model.now))).font(.system(.title2, design: .monospaced).weight(.medium)).monospacedDigit()
                }
                Label(controller.counters.recording ? "正在录像" : camera.streaming ? "当前未录像" : "开始采集后录像",
                      systemImage: controller.counters.recording ? "record.circle.fill" : "video.slash")
                    .font(.caption).foregroundStyle(controller.counters.recording ? CourtStyle.green : CourtStyle.muted)
                buttonPair {
                    Button { model.pauseOrResume() } label: {
                        Label(session.state == .active ? "暂停" : "继续", systemImage: session.state == .active ? "pause.fill" : "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(CourtButton(primary: true))
                } _: {
                    Button { confirmFinish = true } label: { Label("结束", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(CourtButton(destructive: true))
                }.disabled(controller.isBusy || controller.counters.saving)
                if controller.isBusy && !controller.counters.saving { disabledReason("正在等待上一个操作完成…") }
                buttonPair {
                    Button { model.markEvent("精彩") } label: { Label("精彩", systemImage: "bookmark").frame(maxWidth: .infinity) }.buttonStyle(CourtButton())
                } _: {
                    Button { model.markEvent("待复核") } label: { Label("待复核", systemImage: "bookmark").frame(maxWidth: .infinity) }.buttonStyle(CourtButton())
                }.disabled(session.state != .active)
                if session.state != .active {
                    disabledReason(session.state == .paused ? "暂停中不能标记，点「继续」后可标记。" : "记录进行中才能标记。")
                }
                // 挑战 and 界内外 on the camera itself: one phone at the baseline is enough.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { ChallengeButton(model: model); HawkEyeButton(model: model); Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 10) { ChallengeButton(model: model); HawkEyeButton(model: model) }
                }
            } else {
                if let summary = model.finishedRecord {
                    CourtSessionSummaryCard(summary: summary, viewDetails: { model.reloadHistory(); history = HistoryTarget(record: summary.sessionID) },
                                            dismiss: model.dismissFinishedRecord)
                }
                TextField("给这次上场起个名字", text: $title).courtField().submitLabel(.done)
                Button {
                    model.sessionTitle = title; model.startSession(); title = ""
                } label: { Label("开始记录", systemImage: "record.circle").frame(maxWidth: .infinity) }
                    // Only the next step is primary: 开始采集 until the picture runs, then 开始记录.
                    .buttonStyle(CourtButton(primary: camera.streaming)).disabled(controller == nil || controller?.isBusy == true)
                    .accessibilityIdentifier("court.camera.session.start")
                if controller == nil { disabledReason("机位还在准备，稍候即可开始记录。") }
                else if controller?.isBusy == true { disabledReason("正在等待上一个操作完成…") }
                if let free = StorageCleanup.freeBytes(at: model.storageDirectory),
                   StorageCleanup.recordingMinutes(freeBytes: free) < CourtStorageSheet.lowMinutes {
                    CourtNotice(text: "这台手机剩余空间约可录 \(StorageCleanup.recordingMinutes(freeBytes: free)) 分钟。可在「历史记录 › 管理存储空间」里清理较早的录像。", warning: true)
                        .accessibilityIdentifier("court.camera.lowStorage")
                }
                CourtNotice(text: camera.anyDisplayConnected ? "也可以在看板上开始记录；机位和看板看到的是同一条记录。" : "未连接看板也能单独记录，之后可在「历史记录」里回看。")
            }
            if controller?.counters.saving == true { ProgressView("正在保存录像…").font(.caption) }
            if let reason = controller?.shed.reason, (controller?.shed.level ?? 0) < 2 { CourtNotice(text: reason) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.camera.session")
        if showsSetupTips {
            Divider()
            setupTipsCard
        }
        Divider()
        VStack(alignment: .leading, spacing: 12) {
            pageHeader("采集与录像")
            let counters = controller?.counters
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                CourtMetric(title: "采集帧率", value: camera.streaming ? "\(counters?.fps ?? 0)" : "—", unit: "fps")
                CourtMetric(title: "相机丢帧", value: counters.map { "\($0.captureDrops)" } ?? "—", unit: "帧")
                CourtMetric(title: "本段录像", value: counters?.recordingSeconds.map(courtDuration) ?? "—", unit: "")
                CourtMetric(title: "分析落后", value: model.analysisProgressGap.map { String(format: "%.2f", $0) } ?? "—", unit: "s")
            }
            if CameraModel.isSupportedDevice && !CameraModel.isMeasuredDevice {
                CourtNotice(text: "这台 \(CameraHardware.name(CameraModel.hardware)) 还没做过负载实测。发热或分析跟不上时会自动降低预览与分析，录像始终保持 1080p60。")
                    .accessibilityIdentifier("court.camera.unmeasured")
            }
            Text("录像与分析都在这台机位上完成；网络只传逐拍数据和按需的低清预览。")
                .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        // History opens over the camera: capture and any open session keep running.
        VStack(alignment: .leading, spacing: 8) {
            Button { history = HistoryTarget() } label: {
                Label("历史记录", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
            }.buttonStyle(CourtButton()).accessibilityIdentifier("court.camera.history")
            Text("回看这台机位保存的录像与逐拍结果；采集和记录不会停。")
                .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// New users need the setup tips first: shown on 记录 until a session opens or the court is
    /// recognized, and until dismissed on this device. They stay in 设置 either way.
    private var showsSetupTips: Bool {
        guard !setupTipsDismissed, controller?.hasOpenSession != true else { return false }
        let calibrated = controller?.tennisAnalysis?.calibration.isAvailable == true
        return !calibrated
    }
    private var setupTipsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("架设机位", systemImage: "lightbulb").font(.headline).accessibilityAddTraits(.isHeader)
            setupTips
            Button { setupTipsDismissed = true } label: { Text("知道了").frame(maxWidth: .infinity) }
                .buttonStyle(CourtButton()).accessibilityIdentifier("court.camera.tips.dismiss")
            Text("关闭后可在「设置」页的「机位建议」里再看。").font(.caption).foregroundStyle(CourtStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
        .accessibilityElement(children: .contain).accessibilityIdentifier("court.camera.tips")
    }
    private var setupTips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("从底线后方拍到完整球场，让底线、边线、发球线和球网清楚可见。")
            Text("拉近到双打四个外角刚好都在画面内，球场越大越利于识别。")
            Text("固定横向机位后开始采集，开始记录前设好倍率；记录期间保持方向与倍率不变。球场会自动识别，不需要手动标定。")
            Text("长时间录制建议接上充电宝，并开启「引导式访问」防止误退出应用。")
        }.font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var analysisPage: some View {
        let events = controller?.dashboardEvents ?? []
        VStack(alignment: .leading, spacing: 12) {
            pageHeader("击球分析")
            Button(action: handedness) { Label("持拍手", systemImage: "hand.raised").frame(maxWidth: .infinity) }
                .buttonStyle(CourtButton()).accessibilityIdentifier("court.handedness.open")
            TennisAnalysisStatus(status: model.tennisAnalysisStatus, modelsAvailable: model.analysisModelsAvailable,
                                 calibration: model.tennisAnalysis?.calibration, error: nil,
                                 isLive: model.isLive, limitations: model.tennisAnalysis?.limitations ?? [],
                                 recognition: model.recognition, embedded: true)
        }
        Divider()
        VStack(alignment: .leading, spacing: 12) {
            pageHeader("最近击球")
            if events.isEmpty {
                CourtNotice(text: camera.streaming ? "正在积累连续画面，等待可用击球样本。" : "开始采集后在本机实时分析。")
            } else {
                LiveSpeedReadout(events: events, fontSize: 40)
                RecentShotRows(events: events, selected: $selectedShot, limit: 5)
            }
        }
    }

    @ViewBuilder private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            pageHeader("镜头倍率")
            HStack(spacing: 10) {
                Text(CameraZoomRange.title(camera.zoomFactor))
                    .font(.system(.title2, design: .monospaced).weight(.medium)).monospacedDigit()
                    .accessibilityIdentifier("court.camera.zoom.value")
                if camera.zoomLocked { Label("记录中锁定", systemImage: "lock.fill").font(.caption).foregroundStyle(CourtStyle.muted) }
            }
            Text(zoomHint).font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("court.camera.zoom.section")
        Divider()
        VStack(alignment: .leading, spacing: 12) {
            pageHeader("省电值守")
            Picker("无操作后黑屏", selection: Bindable(camera.standby).delay) {
                ForEach(CameraStandby.Delay.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).frame(minHeight: 44).accessibilityIdentifier("court.camera.standby-delay")
            Text("记录中、球场映射可用且无操作时自动黑屏并调暗屏幕，停止渲染实时预览以减少耗电；录像与分析不受影响。轻点屏幕唤醒 15 秒。")
                .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            if let remaining = camera.standby.peekRemaining {
                Text("\(remaining) 秒后回到省电值守").font(.caption).foregroundStyle(CourtStyle.green)
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
            pageHeader("机位建议")
            setupTips
            if setupTipsDismissed {
                CourtLinkButton(title: "在「记录」页重新显示", systemImage: "lightbulb") { setupTipsDismissed = false }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("court.camera.tips.settings")
    }

    private func preview(showsLeave: Bool) -> some View {
        ZStack {
            Color.black
            // In standby the preview layer is unmounted, not merely covered, so it stops rendering.
            if camera.streaming && !camera.standby.isDimmed {
                CameraPreview(session: camera.engine.session).aspectRatio(16.0 / 9, contentMode: .fit)
            }
            VStack(alignment: .leading, spacing: 8) {
                // Leaving and stopping sit on the picture so the sidebar keeps its height for the pages.
                HStack(spacing: 10) {
                    if showsLeave { leaveButton(iconOnly: true) }
                    // Decoration only: at accessibility sizes it would just show as 「CAM…」 beside the back arrow.
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("CAMERA / 01").font(.caption2.monospaced().bold()).lineLimit(1).layoutPriority(-1).accessibilityHidden(true)
                    }
                    Spacer(minLength: 4)
                    // A device that cannot capture does not claim the format it will never record.
                    Label(canCapture ? "1080p · 60 fps" : "不能采集", systemImage: canCapture ? "video" : "video.slash")
                        .font(.caption.weight(.semibold)).foregroundStyle(canCapture ? CourtStyle.green : CourtStyle.warning)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityIdentifier("court.camera.capture-format")
                    if controller?.counters.recording == true {
                        Label("REC", systemImage: "record.circle.fill").font(.caption.bold()).foregroundStyle(CourtStyle.recording)
                            .accessibilityElement(children: .ignore).accessibilityLabel("正在录像")
                    }
                    if camera.streaming { stopCaptureButton }
                }
                // Capped like the rest of the picture, so at accessibility sizes the two icons stay on
                // screen without pushing the picture away.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Spacer(minLength: 0)
                if !camera.streaming || camera.standby.isDimmed {
                    placeholder.frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                // Connection status lives on the preview so the sidebar keeps its height for controls
                // (in the scrolling sidebar at accessibility sizes, where it would cover the preview).
                // Zoom presets share the bottom row and go above the status when it is too long.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 8) { previewStatus; Spacer(minLength: 0); CameraZoomControl(camera: camera) }
                    VStack(alignment: .leading, spacing: 8) { CameraZoomControl(camera: camera); previewStatus }
                }
            }.padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            // Pinch to zoom, as in the system camera. The analysis restarts once, when the pinch ends.
            .gesture(MagnifyGesture()
                .onChanged { value in
                    if pinchStart == nil { pinchStart = camera.zoomFactor }
                    camera.previewZoom((pinchStart ?? 1) * value.magnification)
                }
                .onEnded { value in
                    camera.commitZoom((pinchStart ?? camera.zoomFactor) * value.magnification); pinchStart = nil
                }, isEnabled: camera.canZoom && !camera.standby.isDimmed)
            .clipShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.panel).strokeBorder(CourtStyle.border))
            .accessibilityElement(children: .contain).accessibilityIdentifier("court.camera.preview")
    }
    private var zoomHint: String {
        guard camera.showsZoom || camera.streaming else { return "开始采集后在预览上双指缩放或点倍率调整，设定保存在这台机位上。" }
        guard let range = camera.zoomRange else { return "这台设备的 1080p · 60 fps 格式不支持变焦。" }
        if camera.zoomLocked { return "正在记录：倍率已锁定，暂停后可调整。改倍率会让分析和球场识别重新开始。" }
        var text = "和系统相机一样：点倍率切换镜头，在倍率上左右拖动或双指缩放无级调节，范围 \(CameraZoomRange.title(range.minimum))–\(CameraZoomRange.title(range.maximum))。改倍率会让分析和球场识别重新开始。"
        if range.isUpscaled(range.maximum) {
            text += "超过所用镜头的 2 倍为数码放大（倍率显示为橙色），画面会变软，不利于识别球。"
        }
        return text
    }
    @ViewBuilder private var previewStatus: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            CourtStatus(text: camera.displayStatus, active: camera.anyDisplayConnected)
                .background(CourtStyle.scrim, in: Capsule())
                .accessibilityIdentifier("court.camera.status")
        }
    }
    /// The empty picture: what to do, with 开始采集 right there (no direction words: the layout turns).
    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "video").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(CourtStyle.green)
                .accessibilityHidden(true)
            Text("你的场边机位").font(.headline)
            if canCapture {
                Text(placeholderHint)
                    .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Label(CameraModel.unsupportedReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(CourtStyle.warning).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("court.camera.unsupported")
            }
            if controlsOnPreview && !camera.streaming { startCaptureButton.fixedSize() }
        }.multilineTextAlignment(.center)
            // Text on the picture is capped like the zoom presets, so it never pushes the picture off
            // screen; at accessibility sizes the sidebar repeats capture and status at full size.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
    private var placeholderHint: String {
        if camera.waitingForLandscape { return "把手机横过来，画面会自动打开" }
        return camera.error == nil && camera.opensAutomatically ? "横放并固定设备，画面会自动打开" : "横放并固定设备，然后点「开始采集」"
    }
    private var startCaptureButton: some View {
        Button {
            starting = true
            Task { await camera.start(); starting = false }
        } label: { Label(starting ? "正在开启相机…" : "开始采集", systemImage: "video.fill").frame(maxWidth: .infinity) }
            .buttonStyle(CourtButton(primary: canCapture)).disabled(!canCapture || starting || controller?.counters.saving == true)
    }
    /// A Mac or an iPhone older than the 13 can only fail to capture, so 开始采集 is disabled there and
    /// the picture says why. The simulator keeps it enabled for UI tests and layout demos; starting
    /// still fails with `CameraModel.unsupportedReason`.
    private var canCapture: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return CameraModel.isSupportedDevice
        #endif
    }
    /// On the picture while capturing: an icon with a confirmation, since stopping pauses the session.
    private var stopCaptureButton: some View {
        Button { confirmStop = true } label: { Label("停止采集", systemImage: "stop.fill").labelStyle(.iconOnly) }
            .buttonStyle(CourtButton(destructive: true))
    }
}

@MainActor
struct PairingSheet: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRefresh = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("让机位连到这台看板").font(.title.weight(.semibold))
                        Text("机位手机扫描这个二维码。两台设备连接同一 Wi-Fi 或个人热点即可；开启点对点直连时，两台设备只要都打开 Wi-Fi，不在同一网络也能连接。")
                            .font(.callout).foregroundStyle(CourtStyle.muted)
                    }
                    if let image = pairingQR(model.pairingURL) {
                        image.resizable().interpolation(.none).scaledToFit().frame(maxWidth: 260)
                            .padding(20).background(.white, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.panel))
                            .frame(maxWidth: .infinity).accessibilityLabel("机位配对二维码")
                    } else { ProgressView("正在准备配对码…").frame(maxWidth: .infinity, minHeight: 180) }
                    CourtStatus(text: model.connected ? "机位已连接" + (model.linkPath.map { " · \($0.title)" } ?? "") : model.serverStatus, tone: model.connected ? .live : .idle)
                    Toggle("允许点对点直连", isOn: Binding(get: { model.peerToPeerEnabled }, set: { model.setPeerToPeer($0) }))
                        .frame(minHeight: 44).disabled(model.connected || model.hasActiveSession)
                        .accessibilityIdentifier("court.pairing.peer-to-peer")
                    Text(model.peerToPeerEnabled
                         ? "不需要同一 Wi-Fi 或热点：两台设备都打开 Wi-Fi（不必连接任何网络）即可。更改后请让机位重新扫码。"
                         : "只通过同一 Wi-Fi 或个人热点连接。更改后请让机位重新扫码。")
                        .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
                    if model.addresses.isEmpty && !model.pairingURL.isEmpty {
                        CourtNotice(text: model.peerToPeerEnabled
                                    ? "这台看板没有连接 Wi-Fi 或热点，机位将通过点对点直连找到它。"
                                    : "这台看板没有连接 Wi-Fi 或热点。请连接网络，或开启点对点直连。", warning: !model.peerToPeerEnabled)
                    }
                    if model.addresses.count > 1 {
                        Picker("看板网络地址", selection: $model.selectedAddress) {
                            ForEach(model.addresses, id: \.self) { Text($0).tag($0) }
                        }.frame(minHeight: 44).disabled(model.connected || model.hasActiveSession)
                            .onChange(of: model.selectedAddress) { _, _ in model.updatePairingAddress() }
                    }
                    if !model.selectedAddress.isEmpty {
                        Text(model.selectedAddress).font(.callout.monospaced()).foregroundStyle(CourtStyle.green).textSelection(.enabled)
                    }
                    CourtNotice(text: "同一配对码在 12 小时内有效，看板退到后台再回来时机位会自动重连。网络或热点改变后，请刷新配对码；多个地址时，请选择与机位处于同一网络的地址。")
                    ViewThatFits(in: .horizontal) {
                        HStack { shareLink; refreshButton }
                        VStack(alignment: .leading, spacing: 12) { shareLink; refreshButton }
                    }
                    CourtNotice(text: "配对链接包含本次连接凭证，请只分享给你的机位设备。")
                    if let error = model.error { CourtErrorBanner(text: error) { model.error = nil } }
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }.background(CourtStyle.background)
                .navigationTitle("配对与连接")
                .confirmationDialog("刷新配对码？", isPresented: $confirmRefresh, titleVisibility: .visible) {
                    Button("刷新配对码", role: .destructive, action: model.refreshPairing)
                } message: { Text("旧二维码和配对链接立即作废，机位需要重新扫码才能再连接。") }
                .toolbar { ToolbarItem(placement: .confirmationAction) { CourtTextButton("完成") { dismiss() } } }
        }.tint(CourtStyle.green).preferredColorScheme(.dark)
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 560, minHeight: 640)
            #endif
    }
    private var shareLink: some View {
        ShareLink(item: model.pairingURL) { Label("分享配对链接", systemImage: "square.and.arrow.up") }
            .buttonStyle(CourtButton(primary: true)).disabled(model.pairingURL.isEmpty)
    }
    private var refreshButton: some View {
        Button { confirmRefresh = true } label: { Label("刷新配对码", systemImage: "arrow.clockwise") }
            .buttonStyle(CourtButton()).disabled(model.hasActiveSession || model.isSaving)
    }
}

/// The camera's connect page, full screen. The two kinds of display pair in opposite directions, so
/// the page first asks whether the other device has the App:
/// - no (any browser): the largest code the screen allows, which the display scans with its camera
///   or browser, with the typed fallback (address + PIN), the browser switch and refresh;
/// - yes (App display): the camera scans the code the display shows, or takes its link.
/// Only one direction is on screen at a time, so nobody scans the wrong code.
/// Keeps the camera from dimming while it is shown. Never screenshot it: the code carries the key.
@MainActor
struct CameraConnectView: View {
    enum Kind: String { case app, browser }
    let model: WorkspaceModel
    let close: () -> Void
    @State private var pairingText = ""
    @State private var scanning = false
    @State private var chosen: Kind?
    @State private var confirmUnpair = false
    @State private var confirmRefresh = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var camera: CameraModel { model.camera }
    /// The browser is the main way; a camera already paired with an App display opens on that.
    private var kind: Kind { chosen ?? (camera.ticket != nil ? .app : .browser) }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            let side = max(160, min(wide ? geometry.size.height - 40 : geometry.size.width - 40, 560))
            // The title, 完成 and (unless the text is too large) the choice stay put; everything else
            // scrolls. Landscape puts the code (or the scan) beside the details; at accessibility sizes
            // only the code stays beside them, since it must fit the screen whole, and the taller scan
            // steps join the scrolling column.
            let choiceFixed = !dynamicTypeSize.isAccessibilitySize
            if wide && (kind == .browser || choiceFixed) {
                HStack(alignment: .center, spacing: 28) {
                    primary(side: side)
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        if choiceFixed { choice }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if !choiceFixed { choice }
                                details
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }.accessibilityIdentifier("court.connect.scroll")
                    }.frame(maxWidth: 420)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) { header; if choiceFixed { choice } }
                        .frame(maxWidth: 560).padding(.horizontal, 20).padding(.top, 12)
                    ScrollView {
                        VStack(spacing: 20) {
                            if !choiceFixed { choice.frame(maxWidth: 560) }
                            primary(side: kind == .app ? 560 : side)
                            details.frame(maxWidth: 560, alignment: .leading)
                        }.padding(20).frame(maxWidth: .infinity)
                    }.accessibilityIdentifier("court.connect.scroll")
                }
            }
        }
        .background(CourtStyle.background.ignoresSafeArea())
        .tint(CourtStyle.green).preferredColorScheme(.dark)
        .task {
            // The camera's standby dims the screen; a dim code is hard to scan.
            while !Task.isCancelled {
                camera.standby.noteActivity()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        #if os(iOS)
        .sheet(isPresented: $scanning) { ScannerSheet(model: model) }
        #endif
        .confirmationDialog("断开 App 看板？", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("断开并删除配对", role: .destructive) { camera.unpair() }
        } message: {
            Text("这台机位会删除保存的配对，之后要重新扫看板的二维码或粘贴配对链接才能再连。录像和分析不受影响。")
        }
        .confirmationDialog("刷新浏览器配对？", isPresented: $confirmRefresh, titleVisibility: .visible) {
            Button("刷新并断开所有浏览器", role: .destructive) { camera.controller?.refreshWebCredentials() }
        } message: {
            Text("已连接的浏览器全部断开，旧二维码和配对码作废，需要重新扫码或输入新的配对码。")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("court.web.code")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("连接看板").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: close) { Text("完成").frame(minWidth: 44) }
                .buttonStyle(CourtButton(primary: true)).accessibilityIdentifier("court.web.code.close")
        }
    }

    /// The first choice: which way the code goes depends on whether the other device has the App.
    private var choice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("另一台设备装了 Zacks Court 吗？").font(.headline).accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choiceButton(.app); choiceButton(.browser) }
                VStack(spacing: 8) { choiceButton(.app); choiceButton(.browser) }
            }
        }.accessibilityElement(children: .contain)
    }
    private func choiceButton(_ item: Kind) -> some View {
        let selected = kind == item
        return Button { chosen = item } label: {
            // One line at normal sizes; wraps at accessibility sizes so the column never grows past the screen.
            Text(item == .app ? "装了 · App 看板" : "没装 · 用浏览器")
                .font(.callout.weight(.semibold)).multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? CourtStyle.background : Color.primary)
                .background(selected ? CourtStyle.green : CourtStyle.raised, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("court.connect.choice.\(item.rawValue)")
    }

    /// The big square: this camera's code for a browser, or the scan for an App display.
    @ViewBuilder private func primary(side: CGFloat) -> some View {
        switch kind {
        case .browser: code(side: side)
        case .app: scanPanel(side: side)
        }
    }

    // MARK: Browser display (the display scans this camera)

    private var listening: (url: String, addresses: [String], port: UInt16)? {
        guard camera.webDisplayEnabled, let controller = camera.controller, case .listening(let port) = controller.webState,
              let first = camera.webAddresses.first, let url = controller.webURL(address: first) else { return nil }
        return (url, camera.webAddresses, port)
    }

    @ViewBuilder private func code(side: CGFloat) -> some View {
        if let listening, let image = pairingQR(listening.url) {
            image.interpolation(.none).resizable().scaledToFit()
                .frame(width: side - 24, height: side - 24).padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
                .accessibilityLabel("让浏览器扫的机位二维码").accessibilityIdentifier("court.web.qr")
        } else {
            VStack(spacing: 12) {
                Image(systemName: "qrcode").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(CourtStyle.muted)
                    .accessibilityHidden(true)
                CourtNotice(text: codeUnavailableReason, warning: camera.webDisplayEnabled)
            }.padding(16).frame(width: side, height: side)
                .background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
        }
    }

    private var codeUnavailableReason: String {
        guard camera.webDisplayEnabled else { return "浏览器连接已关闭。打开「允许浏览器连接」后显示二维码。" }
        if case .listening = camera.controller?.webState, camera.webAddresses.isEmpty {
            return "没有可用的局域网地址：请连接 Wi-Fi 或打开本机个人热点。"
        }
        return camera.webStatus.isEmpty ? "正在准备二维码…" : camera.webStatus
    }

    @ViewBuilder private var details: some View {
        switch kind {
        case .browser: browserDetails
        case .app: appDetails
        }
    }

    private var browserDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用另一台设备的相机或浏览器扫这台机位的二维码，就能看数据、远程控制。安卓、iPhone、平板、电脑都可以，可以同时连多台；两台设备要连同一 Wi-Fi 或本机个人热点。")
                .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            statusLines
            if let listening {
                VStack(alignment: .leading, spacing: 6) {
                    Text("扫不了码时，在浏览器输入地址，再填配对码").font(.caption).foregroundStyle(CourtStyle.muted)
                    ForEach(listening.addresses, id: \.self) { address in
                        Text("http://\(address):\(listening.port)").font(.callout.monospaced()).textSelection(.enabled)
                    }
                    if let pin = camera.controller?.webCredentials?.pin {
                        Text("配对码 \(pin)").font(.largeTitle.monospacedDigit().weight(.semibold)).foregroundStyle(CourtStyle.green)
                            .accessibilityIdentifier("court.web.pin.large")
                    }
                }
                if camera.controller != nil {
                    // At accessibility sizes the long label would make a button taller than the page.
                    let large = dynamicTypeSize.isAccessibilitySize
                    Button { confirmRefresh = true } label: {
                        Label(large ? "刷新配对" : "刷新配对（断开所有浏览器）", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }.buttonStyle(CourtButton()).accessibilityIdentifier("court.web.refresh")
                        .accessibilityHint("断开所有浏览器")
                    if large { Text("会断开所有浏览器。").font(.caption).foregroundStyle(CourtStyle.muted) }
                }
            }
            Toggle("允许浏览器连接", isOn: Binding(get: { camera.webDisplayEnabled }, set: { camera.setWebDisplay($0) }))
                .frame(minHeight: 44).accessibilityIdentifier("court.web.enabled")
            Text("浏览器看板走明文 HTTP，同一网络里能抓包的人可以看到数据；需要加密时，在另一台设备装 Zacks Court 当 App 看板。")
                .font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Browsers and the App display, each on its own line, so the page answers "is anything connected?".
    private var statusLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let controller = camera.controller {
                CourtStatus(text: "浏览器看板 · " + camera.webStatus, active: controller.webClients > 0)
                    .accessibilityIdentifier("court.web.status")
            }
            if camera.ticket != nil {
                CourtStatus(text: "App 看板 · " + camera.status, active: camera.connected)
                    .accessibilityIdentifier("court.camera.link-status")
            }
        }
    }

    // MARK: App display (this camera scans the display)

    /// Where the code would be: the steps and the scan, so the eye lands on the right action.
    private func scanPanel(side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(CourtStyle.green)
                .accessibilityHidden(true)
            Text("这次由机位去扫看板的码").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 在另一台设备打开 Zacks Court，选「看板」。")
                Text("2. 点「连接机位」，看板会显示二维码。")
                #if os(iOS)
                Text("3. 在这台机位点「扫描看板的二维码」扫它。")
                #else
                Text("3. 在看板上分享配对链接，粘贴到配对链接输入框。")
                #endif
            }.font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            Button { scanning = true } label: {
                Label(camera.ticket == nil ? "扫描看板的二维码" : "重新扫码配对", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }.buttonStyle(CourtButton(primary: true)).accessibilityIdentifier("court.camera.scan")
            #endif
        }.padding(20).frame(maxWidth: side, alignment: .leading)
            .background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
    }

    private var appDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App 看板（iPhone / Mac）走 TLS 加密，可以把整段录像传过去。断线后机位继续录像和分析，自动重连并补发数据。")
                .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            statusLines
            if let ticket = camera.ticket {
                Text("已配对：" + ticket.name).font(.caption).foregroundStyle(CourtStyle.green)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { reconnectButton; unpairButton }
                    VStack(spacing: 10) { reconnectButton; unpairButton }
                }
            }
            Text("扫不了码时，粘贴看板分享的配对链接").font(.caption).foregroundStyle(CourtStyle.muted)
            TextField("粘贴 zackscourt:// 配对链接", text: $pairingText, axis: .vertical)
                .font(.caption.monospaced()).lineLimit(2...4)
                .courtURLInput().courtField()
                .accessibilityLabel("看板配对链接")
            Button { camera.pair(pairingText.trimmingCharacters(in: .whitespacesAndNewlines)); pairingText = "" } label: {
                Label("使用链接连接", systemImage: "link").frame(maxWidth: .infinity)
            }.buttonStyle(CourtButton()).disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error = camera.error { CourtErrorBanner(text: error) { camera.error = nil } }
        }
    }
    private var reconnectButton: some View {
        Button(action: camera.reconnect) { Label("重新连接", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
            .buttonStyle(CourtButton())
    }
    private var unpairButton: some View {
        Button { confirmUnpair = true } label: { Label("断开", systemImage: "xmark").frame(maxWidth: .infinity) }
            .buttonStyle(CourtButton()).accessibilityIdentifier("court.camera.unpair")
    }
}

private func pairingQR(_ value: String) -> Image? {
    guard !value.isEmpty else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8); filter.correctionLevel = "M"
    guard let output = filter.outputImage,
          let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return Image(decorative: cgImage, scale: 1)
}

extension View {
    @ViewBuilder func courtURLInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        #else
        self
        #endif
    }
}

#if os(iOS)
@MainActor
struct ScannerSheet: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("扫描看板的配对二维码").font(.headline).padding(.top, 20)
                QRScanner(onCode: { value in model.camera.pair(value); dismiss() }, onError: { error = $0 })
                    .clipShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.panel)).padding(.horizontal, 24)
                if let error { CourtNotice(text: error, warning: true).padding(.horizontal, 24) }
                Text("同一 Wi-Fi、个人热点，或看板开启点对点直连时两台设备打开 Wi-Fi 即可")
                    .font(.caption).foregroundStyle(CourtStyle.muted).padding(.bottom, 24)
            }.background(CourtStyle.background).navigationTitle("扫码连接")
                .toolbar { ToolbarItem(placement: .cancellationAction) { CourtTextButton("取消") { dismiss() } } }
        }.tint(CourtStyle.green).preferredColorScheme(.dark)
    }
}
#endif
