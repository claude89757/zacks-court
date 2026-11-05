# AGENTS.md

面向在本仓库工作的贡献者与编码智能体。用户向的介绍见 [README.md](README.md)。

## 项目一句话

同一个原生 SwiftUI App 运行于 Mac 与 iPhone：场边的**机位**手机以 1080p60 采集，在本机录像并用 Core ML 实时推理动作类别、球速估计与落点候选，是会话、录像与逐拍结果的权威副本；另一台 Mac 或 iPhone 做**看板**，经 TLS（协议 v2，同一 Wi-Fi、热点或点对点直连）收到逐拍数据、机位状态、按需低清预览和按需单拍片段，保存镜像并远程控制。设计见 [docs/camera-side-analysis.md](docs/camera-side-analysis.md)。安卓、平板或任何电脑也可以用**浏览器看板**：机位开 HTTP + WebSocket 服务，浏览器扫码或输入地址与配对码连过来，见 [docs/web-display.md](docs/web-display.md)。没有账号、云服务或计分。

## 核心功能（用户 2026-11-04）

App 只有三项核心功能，研究、打磨和验收都围绕它们：

1. **发球识别与发球球速**：近端、远端两边的发球都识别、都测速。球速是击球到第一落点的端点速度（重力修正，和 S家 App 的定义一致）；没看到可信的轨迹时写「—」。
2. **近端界内外**：只判机位一侧的半场，发球判对角发球区，对拉判单打或双打边线与底线；落点在误差范围内写「压线附近」。
3. **录像与导出**：机位 1080p60 本机录像；整段录像和单拍片段都能分享、存到相册，导出原始画面（不叠加数据、不重新编码）。

对拉的动作类别、对拉球速、远端界内外、App 看板与浏览器看板、测速牌等都保留并照常维护（不回退、不删），但不为它们安排新的研究或功能。新提议如果不服务这三项，先问用户。

**以后的亮点是双机位联动**（用户 2026-11-05）：两台机位手机一起拍同一片球场，值得以后迭代，现在不排期，开工前先和用户定方案。**不用雷达**（用户 2026-11-03 决定、2026-11-05 确认）：球场实测和评估都不靠雷达测速枪，不要再把雷达写进计划。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| `Sources/CourtCore` | 平台无关核心：协议 v2（`Wire`、`WireMessages`）、配对与 TLS 连接（`CourtServer`、自动重连的 `CameraLink`、点对点选项与 `LinkPath`）、H.264 编解码、会话与持久化、录像；机位端 `CameraMediaPipeline`（录像/预览/分析分流）、`CameraSideAnalyzer`（选帧器与独立触地定位队列）、`CameraSessionController`（机位会话权威）、`CameraLoadPolicy`（分级降载）、`RecordingTransfer`、`OfflineBackfill`、`ClipExport`（单拍片段，不重新编码）、`CameraDiagnostics`（机位采集日志与记录的诊断包）；浏览器看板服务端 `WebDisplayServer`（HTTP/1.1 + WebSocket、令牌/配对码认证、`/api/*`）与 `WebDisplay`（凭据、JSON 信封、帧格式），页面在 `Web/`（SwiftPM 资源，无构建步骤）；人员检测、S家链接口 `ReferenceChain`（实现只在本地，见下文「分析模型」）、历史查询；测试用的 `SyntheticFrameSource`、`FileFrameSource` |
| `Sources/CourtApp` | 共享 SwiftUI 界面与媒体层：`Views/`、`Models/`（`WorkspaceModel` 看板镜像与角色外观、`RecognitionStatus` 识别状态、`CameraStandby` 值守屏、`CameraAutopilot` 开发用实机自检）、`Media/`（相机采集、`CameraModel`、预览、扫码、Phase 0 测量） |
| `Sources/CourtMac` | Mac App 入口与辅助窗口（测速牌、落点看板、实时画面） |
| `apps/iphone` | iOS 入口、XcodeGen 规格 `project.yml`、资源目录、UI 测试 `ZacksCourtUITests` |
| `Sources/CourtProbe` | `court-probe`：v2 自检（错误密钥 + 机位↔看板回环），以及把合成画面或本地视频当作机位、连到已配对 App 的模拟机位；`web` 模式让这台 Mac 当机位、开浏览器看板 |
| `Sources/CourtAnalyze` | `court-analyze`：用同一流式引擎离线分析本地视频 |
| `Tests/CourtCoreTests` | `court-check` 可执行检查（协议 v2、配对、会话、人员检测、机位媒体管线的真实编解码） |
| `Tests/CourtAppTests` | `swift test`：浏览器看板（`WebDisplayTests`，测试扮演浏览器）、模型/几何/轨迹门控、机位端分析、识别状态、值守屏、机位↔看板 TLS 集成（采用、镜像、断线补发、冲突、后台）、降载、回传、离线补算、单拍片段、连接方式与点对点设置、历史查询、预览响应、现场诊断（采集日志、诊断包）；可选的实机看板测试 |
| `scripts/` | 构建、模型准备、iOS 工程生成、UI 验收、图标导出；球场实测的记录表生成与对照（`field-test-sheet.py`、`field-test-report.py`，只用 Python 标准库） |
| `assets/` | 分析模型集合与品牌素材 |
| `docs/` | 设计、验证记录、实机清单、研究记录、README 图片 |

## 环境

macOS 14+、完整 Xcode（命令行开发目录指向 `/Applications/Xcode.app/Contents/Developer`）、XcodeGen、Python 3、Git LFS（自研球检测模型以 LFS 对象存放）。iPhone 运行需要 iOS 17+、开发签名、信任设备并开启开发者模式。生成的 Xcode 工程不进入 Git，每次修改 `project.yml` 后重新运行 `./scripts/generate-ios.sh`。

## 构建

```sh
swift build                      # 共享包与 Mac 可执行文件（不打包模型）
./scripts/build-mac.sh           # Mac Release App：build/Zacks Court.app（临时签名，非公证包），默认只带自研模型
./scripts/generate-ios.sh        # 校验模型并生成 apps/iphone/ZacksCourt.xcodeproj，scheme 为 ZacksCourt，默认只带自研模型
```

换一台 Mac 时克隆仓库并执行 `git lfs install && git lfs pull` 取得 `assets/independent-model-weights` 中的自研模型（没有 LFS 时只会得到指针文件，准备脚本会明确提示），装好上述工具后依次运行 `build-mac.sh`、`generate-ios.sh`、`swift test` 即可；不需要 S家模型或其他相邻工程。旧的 `CourtCamera` 工程名与独立手机页面已被统一入口取代。

## 分析模型

- **S家资料只在本地，不进 Git**（用户 2026-11-03，仓库开源）：S家是本项目对照的一款商用网球分析 App。它的模型、导出的逐拍参照行、研究笔记都只放在各人自己的电脑上：模型放 `.local/s-models/`，研究笔记放 `docs/s-reference.local.md`（`*.local.md` 与 `assets/analysis-models/` 都被 `.gitignore` 忽略）。公开的代码、文档和提交信息里只用「S家」这个名字，不写它的产品名、版本号、内部模型名或研究方法；参照数据本身也不提交，只提交对照后的汇总分数。没有这些本地文件也能开发和打分，见 README 的「参照 S家做研究」。
- **S家链的代码也只在本地**（用户 2026-11-04，避免上架包和公开仓库里有对应 S家的代码）：运行 S家模型的引擎、模型加载、触地定位、球场地标映射和它们的测试放在 `.local/s-chain/`，公开代码里只有接口 `ReferenceChain`（运行时按类名找本地实现，找不到就明确报不可用）。`scripts/reference-chain.sh on|off` 把它链接进 `Sources/CourtCore/Reference/`、`Tests/CourtAppTests/Reference/`（都被忽略）；`both`/`sjia` 构建自动 `on`，默认构建自动 `off`，`build-mac.sh` 打包默认版时检查二进制里没有 S家链。不要把这些代码搬回公开目录，也不要在公开代码里写 S家的模型名或内部处理细节。上架或归档前确认 `scripts/reference-chain.sh status` 是 `off`。
- `scripts/prepare-analysis-models.sh` 校验并暂存本地的 S家模型（21 个编译模型、213 个文件，逐文件比对 manifest 里的大小与 SHA-256，manifest 本身的摘要固定在脚本里），通过后暂存到 `.local/AnalysisModels`，再打入 Mac 与 iOS App 的 `AnalysisModels` 资源目录。默认来源 `.local/s-models/`；在 git worktree 里找不到时用主仓库的 `.local/s-models/`；也可以用 `COURT_ANALYSIS_MODELS_SOURCE=/path` 或 `scripts/prepare-analysis-models.sh <源> <目标>` 指定。任何文件缺失或不一致都会让构建失败。运行时不下载模型。
- `COURT_CODE_ONLY=1 ./scripts/generate-ios.sh` 生成不含模型的工程，供无模型环境检查编译。该模式即使本地有模型也会排除，App 显示模型缺失、不做动作分类、测速和落点分析；它不能证明任何分析能力。
- `COURT_MODEL_SET` 选择打包的模型集：`independent`（默认，上架版本只用这一种）只带自研；`both` 带 S家与自研两套，App 启动页可切换，默认 S家，选择按设备保存（`CourtAnalysisBackend`，旧版本存的 `swing` 读作 S家）；`sjia` 只带 S家（旧名 `swing` 照样认）。`both` 与 `sjia` 都需要本地的 S家模型和 S家链代码；Mac 输出分别为 `build/Zacks Court.app`、`build/both/`、`build/sjia/`。选自研时 `AnalysisModelLocator` 返回空，任何路径都不加载 S家权重。各模型的替代方案与阶段见 [docs/model-replacement-design.md](docs/model-replacement-design.md)。
- `COURT_MODEL_SET=independent` 为 Mac/iOS 构建选择自研资源，排除 S家 `AnalysisModels`。`scripts/prepare-independent-app-models.sh` 从 `assets/independent-model-weights/` 校验并暂存两个固定的 MIT TrackNetV3 包：`tracknetv3-base-v1`（FP32，约45MB，离线分析，与 Python 逐位一致）和 `tracknetv3-base-fp16-v1`（FP16，约23MB，机位实时链在神经网络引擎上用，只按容差与 FP32 对照）；清单/许可在 `assets/independent-models/<id>/`，`IndependentBallModelAssets.Variant` 分别固定两个清单摘要。可用 `COURT_INDEPENDENT_MODEL_SOURCE` 显式指定 FP32 的同一固定字节源包，不下载模型。机位选自研时 `CameraSideAnalyzer(independent:)` 跑实时链（`IndependentLiveEngine`）；实时链用 `IndependentLiveCourt` 自动识别球场（`IndependentCourtCalibrator`，无学习权重），记录中每分钟复查；`court-analyze independent-live VIDEO MODEL_DIR auto|CAMERA.json OUT.json` 用本地视频按 NV12 模拟机位跑同一条链（旁边另写 `OUT.trace.json`，记下规则的全部输入；只改规则时用 `court-analyze independent-replay OUT.trace.json NEW.json` 重放，不必重跑模型，规则不变时与实时链逐行相同），`court-analyze court-calibrate MEDIAN.png… OUT.json` 单独求解中位图，`court-analyze court-lock VIDEO OUT.json` 把三脚架视频按已知的相机转动晃动后量自动识别多久锁定、锁得对不对。模型 `.bin/.mlmodel` 使用 Git LFS。
- 资源选择不等于启用独立测速后端，也不认证精度。`CourtModelSet` 标识资源模式，独立与 code-only 模式不得通过环境变量回退加载私有模型；`COURT_CODE_ONLY=1` 优先排除两套资源。旧目录中的原研究 README 与 manifest 保持固定摘要，当前原生预处理/集成状态另记在 `docs/speed-model-training.md`。
- 自研模型的开发和训练不安排人工标注（用户 2026-10-30）：训练标签和评估参考都要自动产生（物理拟合的伪标签、我们自己的离线老师、单一动作练习段、量好坐标的标记这类实测读数），不要计划人工标注，也不要问谁来标注。
- 研究、对比或改进自研模型（对齐并超越 S家）时，先读项目 skill [.claude/skills/inhouse-model-research/SKILL.md](.claude/skills/inhouse-model-research/SKILL.md)：目标、打分脚本 `compare_rows.py`、开发 / 留出视频分组，以及记录差距和已试方法的 `references/frontier.md`（每轮研究结束后更新）。
- S家 App 的版本会更新，引用参照数据时写清是哪一天、哪台机器上的 S家 App 导出的，App 里的 S家链（本地模型）和 S家 App 的输出也不能混称。

## 测试与验证

```sh
swift run court-check            # 协议 v2 与版本不一致、配对、会话持久化、人员追踪、机位媒体管线（1080p 录像 + 640×360 预览编码→分包→解码）
swift test                       # 模型/几何/轨迹门控、机位端分析、机位↔看板 TLS 集成、降载、回传、离线补算、单拍片段、连接方式、历史查询
swift run court-probe            # 错误密钥拒绝 + v2 回环：看板开始的会话由机位采用，180 帧 1080p60 机位录像完整解码，低清预览在看板解码

# iPhone 模拟器 UI 验收：正常字号与系统最大辅助字号两轮，结束后恢复原字号
xcrun simctl list devices available
./scripts/test-ios-ui.sh <SIMULATOR_UDID>
```

`test-ios-ui.sh` 运行 `testOrientationTrainingAndBackgroundRecovery`、`testAnalysisSectionsHaveNoPlaceholderMeasurements`、`testLargeTextControlsRemainReachable`，结果与截图写入 `.local/ui-validation-*`，并在模拟器中留下以 `UI-QA` 开头的记录。其余 UI 用例（机位横屏、实时画面、全屏测速牌、角色截图）用 `xcodebuild test -only-testing:ZacksCourtUITests/WorkspaceUITests/<用例>` 单独运行。

需要显式启用的检查：

| 变量 | 作用 |
| --- | --- |
| `COURT_ANALYSIS_MODELS_DIR` + `COURT_TEST_VIDEO` | `swift test --filter WorkspaceIntegrationTests/testRealTennisVideoAnalysedOnCameraMirrorsToDisplay`：本机进程内的机位用真实模型分析网球视频，经 TLS 镜像到看板并保存 |
| `COURT_DEVICE_DISPLAY=1`（Mac）+ `COURT_AUTOPILOT=1`（iPhone，`devicectl … --environment-variables` 启动） | 实机自检：`swift test --filter DeviceValidationTests` 让这台 Mac 做看板，把配对票据写入 `.local/device-run-*/pairing.txt`（0600，不打印内容）；用 `devicectl device copy to --domain-type appDataContainer` 把它拷到 App 的 `Documents/autopilot-pairing.txt`，再启动 iPhone。机位读取后立即删除票据，录制一段（`COURT_AUTOPILOT_SECONDS`，默认 90 秒）后结束；记录中看板取一段 5 秒片段，结束后回传首段录像并校验，报告里记下连接方式。机位数据写入 `Documents/Autopilot/`，不进入用户历史。只是一次室内运行，不证明发热、续航或精度 |
| `COURT_UI_LIVE_VIDEO=1`（或 `TEST_RUNNER_COURT_UI_LIVE_VIDEO=1`） | `testAutomaticCourtOnLiveVideo`：需要外部发送真实视频，验证自动识别球场与分析 |
| `COURT_UI_ZOOM_DEMO=1`（App 启动环境，`testCameraZoomPresetsFitAndRespond` 自己设置） | 模拟器没有相机：机位显示三摄的倍率预设而不采集，用来检查各屏幕尺寸上倍率按钮的位置、44 pt 与点按/拖动；不证明真实镜头、帧率或画质 |
| `TEST_RUNNER_COURT_UI_STORE_SHOTS=<目录>` | `testStoreScreens`：先用 `court-probe demo-session` 写入示例记录，再走历史记录和记录详情，每屏存成 PNG 到该目录（上架截图的原图）；可加 `-configuration Release` 用上架配置跑 |
| `COURT_UI_SAVED_HISTORY=1`（或 `TEST_RUNNER_…`） | `testSavedRealShotPlayback`：需要已保存的真实视频记录，验证逐拍回看 |
| `COURT_HAWKEYE_COMPARE="RUN.json\|TEACHER.json\|singles;…"` | `swift test --filter HawkEyeReferenceComparisonTests`：回放结果（或 `court-probe live` 的输出）的界内外判法和 S家 App 导出的界内/出界逐拍对照，近端、远端分开；一致只说明两个软件结论相同 |
| `COURT_PHASE0=1`（`devicectl … --environment-variables` 启动） | iPhone 上的机位端分析可行性测量：采集 + 编码 + 本机录像 + 分析同时运行并逐秒记录，用法与参数见 [docs/camera-side-analysis.md](docs/camera-side-analysis.md) 第 11 节；只测负载与发热，不证明精度 |

用本地网球视频验证同一流式引擎：

```sh
swift run court-analyze /absolute/tennis.mp4 .local/AnalysisModels .local/analysis-result.json
# 把本地视频当作机位（按来源时钟送帧，在这台 Mac 上分析），连到已配对的看板 App；不是实机相机
swift run court-probe file /private/path/pairing.txt /absolute/tennis.mp4
# 合成画面的模拟机位（标注为合成，不产生网球数据）
swift run court-probe stream /private/path/pairing.txt 30
# 这台 Mac 当机位并开浏览器看板（不带视频时为合成画面），一直运行到手动停止；二维码地址与配对码
# 写入 .local/probe-web-*/web-pairing.txt（0600），不打印。COURT_WEB_ROOT 指向源码目录时改页面后刷新即可
COURT_WEB_ROOT=$PWD/Sources/CourtCore/Web swift run court-probe web /absolute/tennis.mp4
# 不接看板：这台 Mac 当机位按原速回放视频，自己开会话、界内外全场开，写出逐拍行和每个判法的延迟（Mac 回放，不是 iPhone）。
# COURT_PROBE_INDEPENDENT 指向暂存的 FP16 模型目录时，file/web/live 三种模式都改用自研实时链
COURT_PROBE_INDEPENDENT=$PWD/.local/IndependentModels/tracknetv3-base-fp16-v1 swift run -c release court-probe live /absolute/tennis.mp4 .local/live.json singles
# 截图用：往一个 App 的 Sessions 目录写一条编造的示例记录（标题和机位都写明「演示数据」，不是测量）
swift run court-probe demo-session "$(xcrun simctl get_app_container <UDID> com.claude89757.zackscourt data)/Documents/Zacks Court/Sessions"
```

球场实测按 [docs/field-test-plan.md](docs/field-test-plan.md) 执行：会话 JSON 生成带空参考列的记录表，填好后出对照报告。两个脚本都有自检：

```sh
python3 scripts/field-test-sheet.py --self-test
python3 scripts/field-test-report.py --self-test
```

### 证据口径

- 合成视频、公开示例视频、翻拍屏幕和模拟器测试只证明软件流程，不等于真实手机、热点或球场效果通过。不得据此宣称测速、落点或分类精度。
- 与 S家输出接近只说明软件对应关系，不等于物理真值。精度结论需要实拍与独立参考，清单见 [docs/device-validation.md](docs/device-validation.md)。
- 报告测试结果时写清跑了什么、几项通过/跳过/失败；跳过的项不算通过，过时或未运行的用例要明说。

## 产品不变量

- **不做计分**。旧版存档中的手动比分只作兼容读取，不提供入口。
- **未知保持为空**：缺少证据的球速、落点、类别显示「—」并附原因，统计只算有效值，从不按 0 计入。
- **采集固定 1920×1080 / 60 fps**：不支持时明确拒绝，不提供 30 fps 选项，也不自动降帧或降分辨率；降载（发热、相机负载、低电量模式，或分析持续落后）只削减预览、人员检测、触地定位与分析（`CameraLoadPolicy`）；分析落后最多降到 L2，从不暂停分析。
- **球场只靠自动识别**（用户 2026-11-04）：没有手动四角标定，也不要加回来；识别不了时写明原因、请用户调整机位。旧看板发来的 `corners` / `still` 命令仍能解码，机位回执拒绝并说明已去掉手动标定。
- **变焦与系统相机一致，记录中锁定**：三摄虚拟设备 0.5×–25× 无级变焦（`CameraZoomRange`），只在倍率变化时换镜头，帧始终 1080p60；会话 `active` 时锁定，一次录像只用一个镜头；改倍率经 `framingChanged()` 重启时序分析并重新识别球场。
- **机位画面默认打开**：进入机位模式和回到前台时自动开始采集，不需要点「开始采集」；手机竖着拿或平放时不报错，等手机横过来就自动打开（`CameraModel.waitForLandscape`）。采集中手机转向会重开采集换成新方向，在记录的会话随之暂停。用户点「停止采集」后等用户再开。重开采集不会继续已暂停的会话。
- **机位支持 iPhone 13 及更新机型**（2026-10-29 用户要求）：`CameraHardware.isSupported` 按型号代号放行 iPhone14,x 及以上（含 iPhone SE 第 3 代与以后的新机型），模拟器、Mac 与更早的 iPhone 拒绝。只有 `CameraHardware.measured`（目前 iPhone18,2）做过 Phase 0 负载实测；其他机型在机位页提示未实测，靠同一套降载保护。新机型实测后加入 `measured`，并在 `names` 里补上型号名。
- **估计不是测量**：界面与文档始终把球速、落点称为模型估计或候选；空中球不按地面单应性换算速度。
- **持拍手**：近端、远端及换流后的默认值均为右手；未知或缺少击球者关系时只显示「落地击球」。
- **分析不阻塞采集，也不占采集缓冲**：采集回调只做常数时间工作；分析只复制需要的帧到自有缓冲池，绝不持有相机缓冲；预览缩放编码在独立队列且最多 1 帧在途。分析积压或缓冲池满时重置时序状态，不跨流或跨断层拼接轨迹；自研链的画面离开球背景的视角（手持、机位被碰，`IndependentLiveEngine.backgroundMovedPixels`）时重建背景，同样不拼接，画面一直在动就不记击球，机位页和看板写明「画面在动，暂不记击球」（`pictureMoving`，最后一次丢弃后保持 3 秒）。网球分析的界面更新至多每秒 4 次，完整结果仍逐拍写入会话。
- **机位是会话权威，断流不暂停**：断线时机位继续录像和分析，重连后全量补发逐拍清单；看板的操作是请求，以机位回发的会话为准，冲突时机位优先。机位连接时看板（含浏览器）不在本地改会话状态：等机位回执与回发，被拒就保持原样；机位每秒在 `status` 里报会话状态与 `busy`，看板据此锁按钮并在不一致时自动对齐（`SessionSyncTests`）。机位的相机中断、方向改变、退后台或停止采集时会话暂停；看板退后台只暂停没有机位加入的本地会话。
- **数据优先于画面**：控制面消息总是先发；低清预览只在发送积压小于 64 KB 时发，录像回传只在机位未在记录时进行。单拍片段是唯一在记录中发送的文件：每块 256 KB、积压不超过 512 KB，实时逐拍数据最多排在一块后面，发送期间预览暂停；一次只发一个文件。片段只剪已编码的帧，不重新编码，内存里只保留最近一段录像约 30 秒的压缩样本。
- **浏览器看板是连接方向的例外**：App 看板监听、机位连过去；浏览器不能监听也不会 TLS-PSK，所以机位监听浏览器（默认开启，是主推方式；侧栏顶部「连接」打开全屏连接页，开关与 App 看板扫码配对都在那一页）。走明文 HTTP：令牌只放在二维码 URL 的 `#` 后、以 HMAC 挑战应答证明，`/api/*` 用每连接访问码；这比 TLS-PSK 弱，界面与 README 必须照实说明。浏览器发来的控制命令与 App 看板走同一个 `apply`，回执只回发起者；浏览器不能用 `transfer`/`clip` 命令，文件一律走 HTTP，录像下载在记录中拒绝。浏览器预览取分析器已复制的最新帧，在独立队列编 JPEG，不碰相机缓冲。
- **新功能按能力协商**：协议 v2 内新增的命令只发给在 `hello.capabilities` 里声明支持的对端（目前机位声明 `clips`），新字段一律可选，旧 v2 版本照常解码。
- **点对点直连可关闭**：看板默认在点对点 Wi-Fi 上监听（票据 `peerToPeer`），设置随设备保存；早期票据没有该标记，按关闭处理。点对点 Bonjour 尝试有 3 秒 `.waiting` 宽限，其他连接仍立即失败并退避。
- 数据只存本机；配对链接含临时密钥，不写入日志、截图或提交。看板在机位拥有的会话进行中把机位每秒状态写入 `<会话ID>-status.jsonl`（诊断记录，不含画面；断线时写一行 `connected: false`），会话本身仍以机位为准。机位自己在采集时每秒写 `Sessions/Diagnostics/capture-*.jsonl`（球场识别、温度、负载，不含画面，保留 14 天，不分有没有看板）；记录详情「导出 › 诊断包（不含录像）」把记录 JSON、日志、前后的采集日志和中文摘要打成一个 zip，用户自己选择分享到哪里。球场实测的问题先要诊断包和录像，不凭描述猜（见 [docs/camera-side-analysis.md](docs/camera-side-analysis.md) 第 14 节）。

## 界面约定

- 两个平台共用 `Sources/CourtApp/Views`。颜色、圆角、表面层级、状态语气等一律使用 `CourtStyle` 令牌和共享组件，规则见 [docs/design-system.md](docs/design-system.md)。
- **UI 测试按可见文字和 `court.*` 无障碍标识查找控件**。修改按钮、标题、状态文案或标识时，同步修改 `apps/iphone/ZacksCourtUITests/WorkspaceUITests.swift` 并重跑相关用例。
- 交互控件至少 44pt；以最大辅助字号检查不出现逐字换行或控件不可达。
- 动作类别颜色经色觉差异校验；新增图表须带图例，文字使用正文色而不是系列色。

## 应用图标

图标是矢量的「球印压线」（2026-11-04 起，替换了 1.0 的 3D 吉祥物）：源文件 `assets/brand/zacks-court-logo.svg`，用 Chrome 渲染成 1024×1024 的满版母图 `assets/brand/zacks-court-logo-master.png`。iPhone/iPad 使用 `apps/iphone/ZacksCourt/Assets.xcassets` 中无透明通道的图标，Mac 使用带透明圆角边缘的 `assets/brand/ZacksCourt.icns`。修改 SVG 后运行：

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1024,1024 --screenshot=$PWD/assets/brand/zacks-court-logo-master.png file://$PWD/assets/brand/zacks-court-logo.svg
swift scripts/prepare-app-icons.swift
```

商店截图（带大字说明，中英各 5 张）用 `./scripts/render-store-screens.sh` 生成，见 [docs/app-store/README.md](docs/app-store/README.md) 第 3 步。

## 文档要求

- 行为、界面或流程变化时同步更新 [README.md](README.md)；README 的截图位于 `docs/images/`，界面明显变化后重新截取。配对二维码、用户录像和来源不明的视频画面不得进入截图。
- 每一轮验证在 [docs/verification.md](docs/verification.md) 追加带日期的小节：环境、跑了什么、结果、没有验证什么。
- 产品范围或分析链路变化时更新 [docs/unified-app.md](docs/unified-app.md)。

## Git 约定

- 不提交：`.local/`、`build/`、生成的 `*.xcodeproj`、录像（`*.mov`/`*.mp4`）、逐帧 `*.jsonl`、配对文件、签名证书与描述文件（见 `.gitignore`）。
- `assets/independent-model-weights/` 下的 `.bin/.mlmodel` 走 Git LFS（见 `.gitattributes`），推送与克隆计入 GitHub LFS 存储和流量额度。S家模型和 `*.local.md` 绝不提交。
- 提交信息用英文祈使句标题，正文说明动机与验证范围。
- **合入门槛是本机检查，不等 CI**（用户 2026-11-03）：提 PR 前在本机跑 `swift build`、`swift run court-check`、`swift test`，改到 iOS 界面或工程时再跑 `COURT_CODE_ONLY=1 ./scripts/generate-ios.sh` 加模拟器 SDK 编译（之后还原 `Info.plist`）；全部通过、在 `docs/verification.md` 写好记录后直接合入。只跑和改动相关的检查，不为一次改动补一大套新测试。
- CI（`.github/workflows/build.yml`）只能手动触发（私有仓库的 macOS 分钟按 10 倍计费，每次 PR 自动跑会很快用完额度），只做无模型的 `swift build`、`court-check`、`swift test`，不编译 iOS，也不验证任何分析能力。发版前或换 Xcode 后可以手动跑一次复核。
