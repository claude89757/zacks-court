import SwiftUI
import CourtCore

private enum WorkspaceSheet: Identifiable, Hashable {
    /// `record` is history opened on one record's detail (「查看详情」 on the end-of-record summary).
    case pairing, history, record(UUID), calibration, handedness, liveVideo, shots, independentVideo, importVideo
    var id: Self { self }
}

@MainActor
public struct CourtWorkspace: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sheet: WorkspaceSheet?
    @State private var focusedMetric: CourtMetricKind?
    @State private var confirmLeave = false
    @State private var confirmFinish = false
    @State private var showPeople = false
    /// Measured height of the 球速 / 落点 / 动作 shortcut row in the two-column landscape layout.
    @State private var shortcutRowHeight: CGFloat = 96
    @State private var clipPlayback: PlaybackItem?
    // Retain the feature owner until the parent sheet really dismisses. The
    // system file chooser can temporarily hide the experiment's own view.
    @State private var independentVideoModel: IndependentVideoLabModel?
    @State private var videoImportModel: VideoImportModel?

    public init(model: WorkspaceModel) { self.model = model }

    public var body: some View {
        GeometryReader { geometry in
            #if os(macOS)
            if model.role == .server {
                CourtDesktopDashboard(model: model, pairing: { sheet = .pairing }, history: { openHistory() }, openRecord: { openHistory($0) },
                                      calibration: {
                                          Task { await model.prepareCalibration(); if model.calibrationFrame != nil { sheet = .calibration } }
                                      }, handedness: { sheet = .handedness }, leave: leave, finish: { confirmFinish = true })
            } else if model.role == .camera {
                CameraWorkspace(model: model, calibrate: openCalibration, handedness: { sheet = .handedness }, leave: leave)
            } else { standardWorkspace(geometry: geometry) }
            #else
            if model.role == .camera {
                CameraWorkspace(model: model, calibrate: openCalibration, handedness: { sheet = .handedness }, leave: leave)
            } else { standardWorkspace(geometry: geometry) }
            #endif
        }
        .courtStatusBarScrim()
        .background(CourtStyle.background)
        .foregroundStyle(.white)
        .tint(CourtStyle.green)
        .preferredColorScheme(.dark)
        .sheet(item: $sheet, onDismiss: {
            independentVideoModel?.close()
            independentVideoModel = nil
            if sheet != .importVideo { videoImportModel?.close(); videoImportModel = nil }
        }) { destination in
            switch destination {
            case .pairing: PairingSheet(model: model)
            case .history: CourtHistory(model: model)
            case .record(let id): CourtHistory(model: model, open: id)
            case .calibration: CourtCalibrationSheet(model: model)
            case .handedness: CourtHandednessSheet(model: model)
            case .liveVideo: CourtLiveVideoWindow(model: model)
            case .shots: CourtShotListSheet(model: model)
            case .independentVideo:
                IndependentVideoLab(model: independentVideoModel ?? IndependentVideoLabModel())
            case .importVideo:
                VideoImportSheet(model: videoImportModel ?? makeVideoImportModel()) { id in sheet = .record(id) }
            }
        }
        .onChange(of: model.role) { _, role in
            if role != nil, sheet == .independentVideo {
                independentVideoModel?.close()
                sheet = nil
            }
        }
        .courtSessionFeedback(model: model)
        .courtHawkEyeBanner(model: model)
        // The three key-number tiles all open their metric the same way: full screen on the phone.
        #if os(iOS)
        .fullScreenCover(item: $focusedMetric) { metric in
            CourtMetricFocus(model: model, metric: metric)
        }
        #else
        .sheet(item: $focusedMetric) { metric in
            CourtMetricFocus(model: model, metric: metric)
        }
        #endif
        .confirmationDialog("结束当前任务并返回模式选择？", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("结束并返回", role: .destructive) { Task { await model.leaveRole() } }
        } message: { Text("会先结束记录、保存录像，再断开当前连接。") }
        .confirmationDialog("结束本次记录？", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("结束并保存", role: .destructive) { Task { await model.finishSession() } }
        } message: { Text("录像、逐拍结果和标记会保存在历史记录中。") }
        .disabled(model.isBusy)
        .overlay {
            if model.isBusy {
                ZStack {
                    CourtStyle.blockingScrim.ignoresSafeArea()
                    ProgressView("正在保存并关闭当前任务…")
                        .padding(CourtStyle.Space.xl).background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.panel))
                }
            }
        }
    }

    @ViewBuilder private func standardWorkspace(geometry: GeometryProxy) -> some View {
            // Every landscape phone from the iPhone SE (667 pt) up gets two columns; below 750 pt the
            // controls column narrows so the picture keeps about 340 pt.
            if model.role == .server, geometry.size.width >= 640,
               geometry.size.height < 600, !dynamicTypeSize.isAccessibilitySize {
                compactServerWorkspace(sidebarWidth: geometry.size.width >= 750 ? 300 : 280)
            } else if model.role == .server {
                serverPage(geometry: geometry)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            header.id("workspace-top")
                            CourtBanners(model: model)
                            if model.role == .camera {
                                CameraWorkspace(model: model, calibrate: openCalibration, handedness: { sheet = .handedness }, leave: leave)
                            } else {
                                roleSelection(wide: geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize)
                            }
                            footer
                        }
                        .frame(maxWidth: 1440)
                        .padding(geometry.size.width < 600 ? 18 : 32)
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("court.workspace.scroll")
                    .onChange(of: model.role) { _, _ in proxy.scrollTo("workspace-top", anchor: .top) }
                }
            }
    }

    /// At accessibility sizes the logo and history button take their own row above the brand name, which
    /// keeps the full width and may shrink a little instead of breaking 「ZACKS COURT」 letter by letter.
    @ScaledMetric(relativeTo: .title) private var logoSize: CGFloat = 36

    @ViewBuilder private var header: some View {
        let brand = Text("ZACKS COURT").font(.headline.weight(.bold)).tracking(2)
            .lineLimit(1).minimumScaleFactor(0.6)
            .accessibilityIdentifier("court.home.brand")
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                HStack(spacing: CourtStyle.Space.m) {
                    CourtLogoMark(size: min(logoSize, 64))
                    Spacer(minLength: CourtStyle.Space.s)
                    historyButton
                }
                brand
            }
        } else {
            HStack(spacing: CourtStyle.Space.m) {
                CourtLogoMark(size: min(logoSize, 64))
                VStack(alignment: .leading, spacing: CourtStyle.Space.xs) {
                    brand
                    Text("把每一次上场，留下来。").font(.caption).foregroundStyle(CourtStyle.muted)
                }
                Spacer(minLength: CourtStyle.Space.s)
                historyButton
            }
        }
    }

    private var historyButton: some View {
        CourtHistoryIconButton { openHistory() }
    }

    // A short landscape window needs independently scrolling controls so recording
    // an event never pushes the live picture off screen.
    private func compactServerWorkspace(sidebarWidth: CGFloat) -> some View {
        VStack(spacing: CourtStyle.Space.m) {
            // The portrait toolbar's back button and connection pill, so both orientations say the
            // connection state the same way; the pill opens pairing as well.
            HStack(spacing: CourtStyle.Space.m) {
                CourtIconButton(systemImage: "chevron.left", label: "切换模式", action: leave)
                connectionPill
                Spacer(minLength: 0)
                if !model.connected { pairingButton() }
                liveVideoButton()
                historyButton
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("court.server.header")
            HStack(alignment: .top, spacing: CourtStyle.Space.l) {
                GeometryReader { column in
                    ScrollView {
                        VStack(spacing: CourtStyle.Space.l) {
                            // The picture shrinks (keeping its aspect) so the speed, placement and
                            // stroke shortcuts are fully on the first screen. On a wide phone such as
                            // the Pro Max a full-width picture pushed them below the fold.
                            ServerVideo(model: model, showPeople: showPeople)
                                .frame(maxHeight: max(150, column.size.height - shortcutRowHeight - CourtStyle.Space.l))
                            analysisNavigation
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shortcutRowHeight = $0 }
                            Text(model.serverStatus).font(.caption).foregroundStyle(CourtStyle.muted)
                            if showsData { dataPanels }
                            if model.connected { healthCard }
                        }
                    }
                    .accessibilityIdentifier("court.preview.scroll")
                }
                ScrollView {
                    VStack(spacing: CourtStyle.Space.l) {
                        CourtBanners(model: model)
                        summaryCard
                        sessionPanel(inlineControls: true)
                    }
                    .animation(.default, value: model.notice)
                }
                .frame(width: sidebarWidth)
                .accessibilityIdentifier("court.workspace.scroll")
            }
        }
        .padding(CourtStyle.Space.l)
    }

    // MARK: Phone display (portrait, and iPad)

    /// Data first: one toolbar row, then the live picture with the key numbers, the record panel,
    /// the analysis panels and one folded 「机位与分析」 card. Without a camera the page is a
    /// single connect prompt. During a record the controls stay in a bar at the bottom.
    private func serverPage(geometry: GeometryProxy) -> some View {
        let wide = geometry.size.width >= 1050 && !dynamicTypeSize.isAccessibilitySize
        let barControls = model.hasControllableSession && !dynamicTypeSize.isAccessibilitySize
        return ScrollView {
            VStack(alignment: .leading, spacing: CourtStyle.Space.l) {
                summaryCard
                if !model.connected {
                    connectPrompt
                    if !model.shownEvents.isEmpty { analysisNavigation }
                    sessionPanel(inlineControls: !barControls)
                    if showsData { dataPanels }
                } else if wide {
                    HStack(alignment: .top, spacing: CourtStyle.Space.xl) {
                        VStack(spacing: CourtStyle.Space.l) { liveVideo; analysisNavigation; dataPanels; healthCard }
                            .frame(maxWidth: .infinity)
                        sessionPanel(inlineControls: !barControls).frame(width: 340)
                    }
                } else {
                    liveVideo
                    analysisNavigation
                    sessionPanel(inlineControls: !barControls)
                    dataPanels
                    healthCard
                }
            }
            .frame(maxWidth: 1440)
            .padding(.horizontal, geometry.size.width < 600 ? CourtStyle.Space.l : CourtStyle.Space.xxl)
            .padding(.vertical, CourtStyle.Space.m)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("court.workspace.scroll")
        // The toolbar, errors and notices stay in view while the page scrolls.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: CourtStyle.Space.s) {
                serverToolbar
                CourtBanners(model: model)
            }
            .animation(.default, value: model.notice)
            .padding(.horizontal, geometry.size.width < 600 ? CourtStyle.Space.l : CourtStyle.Space.xxl)
            .padding(.vertical, CourtStyle.Space.s)
            .background(CourtStyle.background)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if barControls, let session = model.session { sessionControlBar(session: session) }
        }
    }

    /// Back, the connection state (tap for pairing) and history, in one row.
    private var serverToolbar: some View {
        HStack(spacing: CourtStyle.Space.s) {
            CourtIconButton(systemImage: "chevron.left", label: "切换模式", action: leave)
            connectionPill
            Spacer(minLength: 0)
            if model.connected { HawkEyeButton(model: model).fixedSize() }
            historyButton
        }
        // The toolbar stays pinned, so at the largest text sizes it is capped (like the speed board's
        // labels) to keep the page below it usable; VoiceOver labels are unaffected.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.server.toolbar")
    }

    /// The connection state; tapping it opens pairing and connection.
    private var connectionPill: some View {
        Button { sheet = .pairing } label: {
            HStack(spacing: CourtStyle.Space.s) {
                CourtStatus(text: connectionTitle, tone: model.isLive ? .live : .idle)
                if !dynamicTypeSize.isAccessibilitySize { Image(systemName: "qrcode").font(.callout).foregroundStyle(CourtStyle.muted) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("配对与连接，" + connectionTitle)
            .accessibilityIdentifier("court.server.connection")
    }

    private var connectionTitle: String {
        model.isLive ? "机位实时" : model.connected ? "已连接 · 等待采集" : "未连接机位"
    }

    /// The only thing a display without a camera shows besides the record panel: no empty panels.
    private var connectPrompt: some View {
        CourtPanel {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 36, weight: .light)).foregroundStyle(CourtStyle.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                Text("连接机位").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("点「连接机位」显示这台看板的二维码，再在机位上点「连接」→「扫码连接 App 看板」。连上后，这里显示实时画面、球速、落点和逐拍记录。")
                    .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            Button { sheet = .pairing } label: {
                Label("连接机位", systemImage: "qrcode").frame(maxWidth: .infinity)
            }.buttonStyle(CourtButton(primary: true)).accessibilityIdentifier("court.server.connect")
            Text(model.serverStatus).font(.caption).foregroundStyle(CourtStyle.muted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.server.empty")
    }

    /// The live picture with a corner button for the larger picture.
    private var liveVideo: some View {
        ServerVideo(model: model, showPeople: showPeople)
            .overlay(alignment: .bottomTrailing) {
                Button { sheet = .liveVideo } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.callout.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(CourtStyle.scrim, in: Circle()).contentShape(Circle())
                }.buttonStyle(.plain).padding(CourtStyle.Space.s)
                    .accessibilityLabel("实时画面")
                    .accessibilityIdentifier("court.live-video.open")
            }
    }

    /// Analysis panels appear once there is a camera or data to show.
    private var showsData: Bool { model.connected || !model.shownEvents.isEmpty }

    private var healthCard: some View {
        CameraHealthCard(model: model, showPeople: $showPeople) {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: CourtStyle.Space.s))
                : AnyLayout(HStackLayout(spacing: CourtStyle.Space.s))
            layout {
                Button(action: openCalibration) { Label("标定球场", systemImage: "viewfinder").frame(maxWidth: .infinity) }
                    .buttonStyle(CourtButton()).disabled(!model.isLive || model.isBusy)
                    .accessibilityIdentifier("court.calibration.open")
                Button { sheet = .handedness } label: { Label("持拍手", systemImage: "hand.raised").frame(maxWidth: .infinity) }
                    .buttonStyle(CourtButton()).accessibilityIdentifier("court.handedness.open")
            }
            if !model.isLive {
                Text("收到实时画面后可标定球场。").font(.caption).foregroundStyle(CourtStyle.muted)
            }
        }
    }

    /// History, on the list or (from the end-of-record summary) on one record's detail.
    private func openHistory(_ record: UUID? = nil) {
        model.reloadHistory(); sheet = record.map { .record($0) } ?? .history
    }

    /// The record that just finished, until closed or another record starts.
    @ViewBuilder private var summaryCard: some View {
        if let summary = model.finishedRecord {
            CourtSessionSummaryCard(summary: summary, viewDetails: { openHistory(summary.sessionID) },
                                    dismiss: model.dismissFinishedRecord)
        }
    }

    private func openCalibration() {
        Task { await model.prepareCalibration(); if model.calibrationFrame != nil { sheet = .calibration } }
    }

    private func leave() {
        if model.hasActiveSession || model.camera.streaming || model.isRecording || model.isSaving {
            confirmLeave = true
        } else { Task { await model.leaveRole() } }
    }

    private func roleSelection(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Text("你的球场。\n你的视角。")
                    .font(.largeTitle.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text("连接场边机位，记录球速、落点与击球动作。")
                    .font(.body).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 16)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: wide ? 2 : 1)
            LazyVGrid(columns: columns, spacing: 18) {
                roleCard(.camera, title: "机位", subtitle: "留在场边，录像并实时分析", icon: "video", number: "01",
                         details: "用这台手机的后置摄像头录像，并在本机实时分析球速、落点与动作。录像和逐拍结果保存在机位上，没有看板也能单独记录。",
                         warning: CameraModel.isSupportedDevice ? nil : CameraModel.unsupportedReason)
                roleCard(.server, title: "看板", subtitle: "实时看数据，远程控制", icon: "viewfinder", number: "02",
                         details: "实时查看机位发来的球速、落点与动作，远程开始、暂停和结束记录。逐拍结果同步保存一份，方便回看。")
            }
            CourtPanel {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "wifi").foregroundStyle(CourtStyle.green).font(.title3)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("两台设备，一个球场").font(.headline)
                        Text("一台选择机位，点「连接」显示二维码；另一台设备（安卓、iPhone、平板或电脑都行）用相机或浏览器扫码就成了看板，两台设备连同一 Wi-Fi 或机位的个人热点。需要加密传输时，也可以在 iPhone 或 Mac 上选择「看板」，让机位扫它的二维码配对，开启点对点直连后不必在同一网络。机位需要 iPhone 13 或更新的 iPhone。断网时机位继续录像和分析，重连后自动补齐。")
                            .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if model.bundledBackends.count > 1 { analysisBackendPanel }
            CourtPanel {
                Button {
                    guard model.role == nil else { return }
                    videoImportModel = makeVideoImportModel()
                    sheet = .importVideo
                } label: {
                    Label("导入视频分析", systemImage: "film.stack").frame(maxWidth: .infinity)
                }.buttonStyle(CourtButton())
                    .accessibilityIdentifier("court.import.open")
                Text("不在球场也能试：从相册或文件选一段网球视频，用机位同一套模型逐拍分析，结果存进历史记录。")
                    .font(.callout).foregroundStyle(CourtStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if DEBUG
            // A developer tool: Debug builds (and the UI tests) only, never in an App Store build.
            CourtPanel {
                Button {
                    guard model.role == nil else { return }
                    independentVideoModel = IndependentVideoLabModel()
                    sheet = .independentVideo
                } label: {
                    Label("本地视频实验", systemImage: "film").frame(maxWidth: .infinity)
                }.buttonStyle(CourtButton())
                    .accessibilityIdentifier("court.independent.open")
                Text("实验功能：导入本机视频，逐帧查看自研模型找到的球和没找到球的帧。")
                    .font(.callout).foregroundStyle(CourtStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
            Button { openHistory() } label: {
                Label("查看历史记录", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
            }.buttonStyle(CourtButton())
        }
    }

    private func makeVideoImportModel() -> VideoImportModel {
        let value = VideoImportModel(storageDirectory: model.storageDirectory)
        value.onSaved = { [model] _ in model.reloadHistory() }
        return value
    }

    /// S家 / 自研 switch, for comparing the two chains during the beta.
    private var analysisBackendPanel: some View {
        CourtPanel("分析模型") {
            CourtSegment(options: model.bundledBackends,
                         selection: Binding(get: { model.analysisBackend }, set: { model.setAnalysisBackend($0) }),
                         title: \.title, identifier: { "court.analysis.backend.\($0.rawValue)" })
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("court.analysis.backend")
            Text(model.analysisBackend == .sjia
                 ? "S家模型（默认）：机位在记录中实时分析球速、落点与动作。"
                 : "自研模型：机位在记录中实时分析球速、落点与动作，球场从画面白线自动识别（约需 7 秒以上）。结果是模型估计，精度仍在和 S家对照；自研模式下不提供记录后的离线补算。")
                .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("court.analysis.backend.note")
        }
    }

    private func roleCard(_ role: WorkspaceRole, title: String, subtitle: String, icon: String, number: String, details: String, warning: String? = nil) -> some View {
        Button { model.selectRole(role) } label: {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(CourtStyle.green)
                        .frame(width: 44, height: 36, alignment: .leading).accessibilityHidden(true)
                    Spacer(); Text(number).font(.caption.monospaced()).foregroundStyle(CourtStyle.muted).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle).font(.subheadline).foregroundStyle(CourtStyle.green)
                    Text(details).font(.callout).foregroundStyle(CourtStyle.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    // Said before entering, so nobody sets up a camera that cannot capture.
                    if let warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(CourtStyle.warning)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    }
                }
                HStack { Text("进入模式").font(.callout.weight(.semibold)); Spacer(); Image(systemName: "arrow.up.right") }
                    .padding(.top, 8)
            }.padding(dynamicTypeSize.isAccessibilitySize ? CourtStyle.Space.l : 26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.panel).strokeBorder(CourtStyle.green.opacity(0.25)))
                .contentShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.panel))
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
            .accessibilityIdentifier("court.role.\(role.rawValue)")
    }

    private func pairingButton(fill: Bool = false) -> some View {
        Button { sheet = .pairing } label: {
            Label(model.connected ? "配对与连接" : "连接机位", systemImage: "qrcode").frame(maxWidth: fill ? .infinity : nil)
        }.buttonStyle(CourtButton(primary: !model.connected))
    }
    private func liveVideoButton(fill: Bool = false) -> some View {
        Button { sheet = .liveVideo } label: {
            Label("实时画面", systemImage: "video").frame(maxWidth: fill ? .infinity : nil)
        }.buttonStyle(CourtButton()).accessibilityIdentifier("court.live-video.open")
    }

    /// Starting a record, or the running record. On a phone in portrait the running record's
    /// buttons move to `sessionControlBar`; at accessibility sizes and in landscape they stay here.
    private func sessionPanel(inlineControls: Bool) -> some View {
        CourtPanel(model.hasControllableSession ? "正在记录" : nil) {
            if model.hasControllableSession, let session = model.session {
                // Name and clock side by side; at accessibility sizes (or a narrow column) the clock goes
                // under the name, so a long name never breaks a few letters per line.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: CourtStyle.Space.m) {
                        recordTitle(session)
                        Spacer(minLength: CourtStyle.Space.s)
                        recordClock(session)
                    }
                    VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
                        recordTitle(session)
                        recordClock(session)
                    }
                }
                Label(model.isRecording ? "机位正在录像" : model.cameraOwnsSession ? "机位当前未录像" : "等待机位加入 · 机位连接后开始录像与分析", systemImage: model.isRecording ? "record.circle.fill" : "video.slash")
                    .font(.caption).foregroundStyle(model.isRecording ? CourtStyle.green : CourtStyle.muted)
                if inlineControls {
                    // Pause and finish come before the markers, so a short landscape column shows them
                    // without scrolling.
                    let controlLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: CourtStyle.Space.s)) : AnyLayout(HStackLayout(spacing: CourtStyle.Space.s))
                    controlLayout {
                        Button(action: model.pauseOrResume) {
                            Label(session.state == .active ? "暂停" : "继续", systemImage: session.state == .active ? "pause.fill" : "play.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(CourtButton(primary: model.connected))
                        Button { confirmFinish = true } label: { Label("结束", systemImage: "stop.fill") }
                            .buttonStyle(CourtButton(destructive: true))
                    }.disabled(model.isSaving || model.sessionCommandsLocked)
                    if let reason = model.sessionWaitReason { ProgressView(reason).font(.caption) }
                    trainingMarkers(session: session)
                } else {
                    markerCount(session: session)
                }
                if session.state == .paused { CourtNotice(text: "暂停期间机位停止录像，这段时间的击球不计入本次记录；暂停中不能标记。") }
                if session.state == .interrupted { CourtNotice(text: "机位上的这次记录意外中断（机位曾重启）。点「继续」恢复录像，或点「结束」保存。", warning: true) }
            } else {
                // Return closes the keyboard so the start button beneath is visible again.
                TextField("给这次上场起个名字", text: $model.sessionTitle).courtField().submitLabel(.done)
                Button(action: model.startSession) {
                    Label(model.isSaving ? "正在保存…" : "开始记录", systemImage: "record.circle").frame(maxWidth: .infinity)
                }.buttonStyle(CourtButton(primary: model.connected)).disabled(model.isSaving || model.sessionCommandsLocked)
                if let reason = model.sessionWaitReason { ProgressView(reason).font(.caption) }
                CourtNotice(text: model.isLive ? "机位保存录像并实时分析，看板保存逐拍数据镜像；未知数据保持为空。" : "机位尚未采集。开始记录后，机位连接并采集时才会录像与分析。")
            }
            if model.isSaving { ProgressView("正在保存录像与记录…").font(.caption) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.session.panel")
    }

    private func recordTitle(_ session: CourtSession) -> some View {
        VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
            Text(session.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            CourtStatus(text: session.state.courtTitle, tone: session.state.courtTone)
        }
    }

    private func recordClock(_ session: CourtSession) -> some View {
        Text(courtDuration(session.elapsed(at: model.now))).font(.system(.title, design: .monospaced).weight(.medium)).monospacedDigit()
            .lineLimit(1).fixedSize()
    }

    /// The running record's controls, pinned above the home indicator: the same commands as the
    /// panel, each a request the camera confirms before the state changes.
    private func sessionControlBar(session: CourtSession) -> some View {
        VStack(spacing: CourtStyle.Space.s) {
            if let reason = model.sessionWaitReason { ProgressView(reason).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(spacing: CourtStyle.Space.s) {
                Button(action: model.pauseOrResume) {
                    Label(session.state == .active ? "暂停" : "继续", systemImage: session.state == .active ? "pause.fill" : "play.fill")
                }.buttonStyle(CourtBarButton(primary: model.connected))
                    .disabled(model.isSaving || model.sessionCommandsLocked)
                ForEach(["精彩", "待复核"], id: \.self) { label in
                    Button { model.markEvent(label) } label: { Label(label, systemImage: "bookmark") }
                        .buttonStyle(CourtBarButton()).disabled(session.state != .active)
                }
                Button { confirmFinish = true } label: { Label("结束", systemImage: "stop.fill") }
                    .buttonStyle(CourtBarButton(destructive: true))
                    .disabled(model.isSaving || model.sessionCommandsLocked)
            }
        }
        .padding(.horizontal, CourtStyle.Space.l).padding(.top, CourtStyle.Space.s).padding(.bottom, CourtStyle.Space.s)
        .background(CourtStyle.panel)
        .overlay(alignment: .top) { Rectangle().fill(CourtStyle.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.session.bar")
    }

    private func trainingMarkers(session: CourtSession) -> some View {
        VStack(alignment: .leading, spacing: CourtStyle.Space.m) {
            Text("辅助标记").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                      ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 110))], spacing: CourtStyle.Space.s) {
                ForEach(["精彩", "待复核"], id: \.self) { label in
                    Button { model.markEvent(label) } label: { Label(label, systemImage: "bookmark").frame(maxWidth: .infinity) }
                        .buttonStyle(CourtButton()).disabled(session.state != .active)
                }
            }
            markerCount(session: session)
        }
    }

    private func markerCount(session: CourtSession) -> some View {
        Text("已标记 \(session.events.filter { $0.kind == .marker }.count) 个时刻")
            .font(.caption).foregroundStyle(CourtStyle.muted)
    }

    /// Speed, placement, strokes and the shot list.
    private var dataPanels: some View {
        let finished = model.finishedRecordShots
        return TennisAnalysisOverview(events: finished?.events ?? (model.isLive ? model.tennisAnalysis?.events ?? [] : []),
                               emptyReason: model.isLive ? "正在积累连续画面，等待可用击球样本。" : "尚未收到实时画面，暂无击球分析。",
                               calibration: model.tennisAnalysis?.calibration,
                               sourceNote: finished.map { "上一次记录「\($0.title)」的结果，开始新记录后清空" }
                                   ?? (model.hasControllableSession ? "本次记录" : "未开始记录 · 最近几拍"),
                               shotAccessory: { event in AnyView(ShotReplayButton(model: model, session: model.session, shot: event) { clipPlayback = $0 }) },
                               shotNote: model.canFetchClips && model.cameraOwnsSession ? "点 ▶ 从机位取这一拍片段：" + ShotReplayButton.clipNote : nil,
                               allShotCount: model.shownEvents.count,
                               openAllShots: { sheet = .shots },
                               openSpeedBoard: { focusedMetric = .speed },
                               openPlacement: { focusedMetric = .placement })
            .sheet(item: $clipPlayback) { item in RecordingPlayer(item: item) }
    }

    private var analysisNavigation: some View {
        TennisAnalysisNavigation(events: model.shownEvents) { target in
            switch target {
            case .speed: focusedMetric = .speed
            case .placement: focusedMetric = .placement
            case .strokes: focusedMetric = .strokes
            }
        }
    }

    private var footer: some View {
        HStack { Text("ZC / 球场记录"); Spacer(); Text("视频与记录保存在本机") }
            .font(.caption2).foregroundStyle(CourtStyle.muted).padding(.vertical, CourtStyle.Space.s)
    }
}

@MainActor
struct ServerVideo: View {
    let model: WorkspaceModel
    var showPeople = false
    var body: some View {
        ZStack {
            VideoSurface(pipeline: model.preview)
                .onAppear { model.previewVisible(true) }
                .onDisappear { model.previewVisible(false) }
            if showPeople, let snapshot = model.analysis, model.isLive { PersonOverlay(snapshot: snapshot) }
            if !model.isLive {
                VStack(spacing: 12) {
                    Image(systemName: model.connected ? "video.badge.waveform" : "qrcode.viewfinder").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(CourtStyle.green)
                        .accessibilityHidden(true)
                    Text(model.connected ? "等待机位画面" : "尚未连接机位").font(.headline)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(model.connected ? "在机位上点「开始采集」" : "点「连接机位」显示二维码，再在机位上点「连接」扫码")
                        .font(.caption).foregroundStyle(CourtStyle.muted).lineLimit(2).minimumScaleFactor(0.7)
                }.multilineTextAlignment(.center).padding(20)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            VStack {
                HStack {
                    Text("COURT / LIVE").font(.caption2.monospaced().bold()).tracking(1).lineLimit(1).fixedSize().accessibilityHidden(true)
                    if model.isLive { Text("低清 · 有延迟").font(.caption2).foregroundStyle(CourtStyle.muted).lineLimit(1) }
                    Spacer()
                    if model.isRecording {
                        Label("REC", systemImage: "record.circle.fill").font(.caption.bold()).foregroundStyle(CourtStyle.recording)
                            .accessibilityLabel("正在录像")
                    }
                }
                Spacer()
            }.padding(16)
            // Labels on the picture stay small enough not to cover it; VoiceOver labels are unaffected.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }.aspectRatio(model.preview.aspectRatio, contentMode: .fit).background(.black)
            .clipShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.panel))
            .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.panel).strokeBorder(CourtStyle.border))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("court.server.preview")
    }
}
