# 独立测速阶段性交接（2026-10-29）

> 2026-10-29 更新：Codex 额度暂停后由 Claude 接手，整片逐拍球速原型与开发集结果见 [训练记录](speed-model-training.md) 末节和 `scripts/speed-fullvideo/`。

本阶段准备作为草稿 MR 交接研究基础。用户已授权先交接，再由其他智能体继续验收与迭代。**当前正式验收为0**，没有通过逐拍误差≤20%、覆盖率≥90%、事件precision≥95%的验收，也没有完成产品测速后端替换。尚缺未见的1080p60新拍摄与独立人审100拍；已向用户提出数据需求，本轮按阶段性MR收尾。

## 已有实现与使用边界

- `Sources/CourtCore/IndependentAnalysis/` 提供原生RGB预处理、固定MIT TrackNetV3、真实PTS解码、48帧过去背景、八帧推理、候选与过去关联。约45MB模型包使用Git LFS；独立资源构建不带S家模型，也不回退私有目录。
- 角色页「本地视频实验」调用共享分析器，选择60fps本地视频、设定起点/最长120秒、取消、原PTS单帧候选预览、保存/重试。报告独立存于Application Support的 `Zacks Court/IndependentRuns`，不复制视频，不写会话/历史；UI球速仍为「—」，缺触拍/触地与可信相机。
- `IndependentFlightCandidateBuilder.build(analysis:camera:evidence:configuration:)` 接typed分析结果；`build(savedAnalysisJSON:camera:evidence:configuration:)` 接保存报告。显式同源相机、实际区间与中断证据接同一六参数freefit，再计算观测区间均速；可选独立触拍窗的精确有理中点瞬时模长及窗内范围。范围含内部竖直顶点，只覆盖事件时间变化，不是物理置信区间。缺相机/端点保持unknown。
- CLI `independent-flight-candidate` 接保存报告，不读取/重验原视频、零ML、不拟相机；报告绑定协议/分析SHA，原子发布新目录且拒绝覆盖。raw条件值可能非空，公开相机/速度仍null，formal/human/production/physical/20%资格始终false。条件速度与事件/标定尚未接入App产品输出。

## 速度定义必须先分清

本地对 S家 App 两个版本的研究表明：一版导出取最终速度向量的模长并转km/h；另一版用端点位移/时间与重力项恢复区间初速度，随后存在机位/侧别修正、发球重算及其他覆写。两版本证据不是同一完整运行；各教师行的计算区间、起止时刻与状态未知。003导入App的版本记录也不能补成完整溯源，旧单打快照实际分析版本仍未知，不用后来研究的版本反填。（细节只在本地，见 docs/s-reference.local.md。）

因此不能把教师速度当路径平均，也不能把早期约0.27%的临时数值接近写成正式同口径误差。后续以独立触拍时间的瞬时速度作主要开发量，观测区间均速作辅助；不按更贴近教师的结果选择时刻、相机或定义。逐行writer未知限制同口径声明，不妨碍先开发明确条件的独立速度，或以后预注册标量软件基准。详细本地研究摘要见证据根目录下 `native-flight-candidate-20261029/teacher-speed-semantics.md`。

## 当前数值只证明软件和条件数学

source003/train007已是暴露开发数据。观测39..79的41点在每次调用中拟合一次，参数与原freefit一致；raw区间均速87.831894366km/h、首观测87.024664072km/h。新增独立弱触拍窗34..37的精确中点35.5为PTS233415/600，向前外推58.333ms，raw瞬时值87.09223691km/h，时间窗范围87.05731441..87.13609180km/h。原camera039转移 **failed strict8** 没有解决，这些值不能升级为合格物理速度或新教师误差。

另4个软件发球窗074/018/057/041始终全进分母：018/057疑似触网且短段预拒绝，074预测触地91.2445在冻结89..91外，041的61.6046虽在61..63内，软件锚仍比视觉触拍晚220–270ms，同拍映射未知。分母4、合格完整飞行0，不round、扩门或挑替代行挽救。

## 已执行与未执行的验证

合最新main前的完整 `swift test`：182项，175通过、7按需跳过、0失败，179.39秒，Builder11项在其中。跳过为实机看板、原生CoreML私有夹具、Pillow/JPEG私有夹具、freeflight私有输入、App模型真实视频私有运行、公开视频标定、真实模型TLS镜像。另有先前专用Release App模型/实际服务1项通过：168解码/120推理帧/15forward，第87帧PTS233450/600、原图候选(1395,465)，旧轨迹/摘要一致；不抵消本轮默认跳过。

实验空页、系统选片取消、实时模式隔离，在正常/最大辅助字号各3项通过。默认旧回归3个不同用例中1通过、2横屏断言失败，方向项复查仍失败；安装包/Runner均声明支持横屏，根因未知，不能认定为旧问题或本轮回归。字号已恢复large。没有验证SwiftUI选取真实视频到推理全链、文件提供器security-scoped授权，也未启动手机。

CLI已有Release编译和原三个实际报告重放通过；补充触拍窗使用Debug重放，不是性能比较。新工作树已基于main `73bae21`解决集成冲突；合并后完整Swift共192项，178通过、14跳过、0失败（169.825秒）。新增的7个跳过来自尚未在新树准备默认S家模型的检查，不算通过；整片离线上限新增后另跑共享视频服务7项，全部通过。其后又跟进main `97edfcf`（镜头/机型更新），完整203项：189通过、14跳过、0失败（193.685秒），整片新限额用例已包括。`court-check`退出0；iOS generic设备SDK的code-only编译成功，不证明资源或手机运行。

新树iPhone17Pro/iOS26.1模拟器首次正常字号5项：3通过、2失败；新空页检查因44pt几何值返回43.99999999999994而失败，增加远小于一像素的1e-6pt断言容差后单项重跑通过，产品44pt下限不变。另一个旧方向断言仍失败，根因未知。按最终不同用例计4通过、1失败；其中新实验3项最终正常字号均通过，最大辅助字号另3项全部通过，结束恢复large。未实测真实选片到推理或手机。随后使用原目录的已校验模型显式源恢复默认S家工程，未把此前14跳过改记通过。本树没有重做独立Mac App打包。运行日志与失败范围见 [验证记录](verification.md)。

MR #15为草稿。远端Actions run 40809184902未分配runner、没有执行steps，注释说明预算限制阻止启动；CI未运行，不能用本地通过替代远端状态，也没有改工作流绕过限制。

整片收尾时再合main `6892d8e`的机位模拟器矩阵/窄屏布局更新，只在verification尾部冲突，保留双方完整记录；独立分析源码与Release模型运行链未改。合并后编译并定向运行CameraZoomLayoutTests及IndependentVideoLabModelTests，共23项通过、0跳过/失败（0.296秒测试时间），没有再次全套Swift、SDK或UI。上文203项和UI/SDK结果绑定97edfcf阶段，不冒充新提交全面验证；主线自己的矩阵记录按其原作者范围保留。

## 接手顺序与分工

1. 先取得**本视频自身**的相机证据与误差/敏感性检查，替代failed camera039 transfer；保持内参、畸变、稳定裁区、米制尺度与设备历史的未知状态，不能用低残差认证相机。
2. 独立冻结触拍、触地与中断分段，在更广开发拍上评估瞬时触拍速度、缺失/拒绝及覆盖分母。先冻结规则再读教师标量，保存失败，不选择贴合标签的窗口。
3. 把明确条件的速度、事件与标定接到App，再验证真实选片、系统文件提供器、保存恢复、iPhone实际推理/负载与像素/PTS对应；先解决或隔离记录UI横屏失败。
4. 开发冻结后，另建独立最终验收：至少100拍、3会话、2条件，主要1080p60，独立人审并有可信参考与误差定义。全部候选拍入覆盖分母，无参考的拍不能计精度通过；不回收已暴露开发窗作最终留出。

Astra负责验收、数学与实验设计复核；sol负责实施、数据/训练工具与可复现实现。最终新树审查及下一轮地标标注曾尝试交接，但子智能体额度已用尽，任务未成功执行；不能记作已接手或审查通过。审查者的独立复算不等于人审或物理真值。两者应以冻结协议、完整失败清单及逐来源结果交接，不把软件一致性写成精度认证。

## 本机证据与可执行命令

历史私有证据根目录仍为原 checkout 的 `.local/speed-training`。新的managed worktree不自动携带原目录的 `.local` 私有数据，本次整片新证据另存当前worktree（见文末）；在同机可显式引用原目录，换机须另行提供原视频/报告/协议并核对摘要，不能把缺失数据写成验证通过。关键历史子目录为 `independent-video-lab-20261029`、`native-flight-candidate-20261029`、`serve-batch-events-20261029`、`serve-batch-review-20261029`、`serve-batch-freeflight-20261029`。协议含绝对路径，迁移需新协议、新摘要和变更记录，不能悄改冻结原件。

在接手checkout根目录构建/检查代码；具体已运行范围以上述收据为准，以下是接续检查入口：

```sh
swift build
swift test
swift run court-check
```

同机重放已有触拍协议到**新的**输出目录，不需要原视频或模型加载，但必须保留协议指向的原分析报告：

```sh
mkdir -p .local
swift run -c release court-analyze independent-flight-candidate \
  "$PWD/.local/speed-training/native-flight-candidate-20261029/protocol-contact-007-v2.json" \
  ".local/candidate-contact-review-$(date +%Y%m%d-%H%M%S)"
```

协议schema为 `independent-flight-candidate-v1`，含 `analysis: {path, sha256}`、可选 `camera` / `evidence` 及 `configuration`。分析路径须绝对；`camera.sourceID` / `evidence.sourceSHA256` 须绑定原视频SHA。evidence含 `interval`、`collisionFreeAssumption`、`interruptionWindows`，可选 `groundCandidateWindow`、`contactCandidateWindow`、`contactExtrapolationReason`；窗口用原始整数PTS/timebase和非空basis，不按标称fps反推。报告 `source_video_reverified=false`、`new_model_forwards=0`、`speed_outputs=0`。

需重新验证App资源/SDK时，先拉取LFS，使用独立资源构建；code-only优先排除两套模型，只能证明编译，不能证明分析：

```sh
git lfs install
git lfs pull
COURT_MODEL_SET=independent ./scripts/build-mac.sh
COURT_MODEL_SET=independent ./scripts/generate-ios.sh
```

生成的Xcode工程不入Git，具体SDK/UI运行按 [AGENTS.md](../AGENTS.md)；测试以准确通过/跳过/失败数追加 [verification.md](verification.md)。空实验页截图可公开；私有原帧、视频、逐拍数据、配对凭据不得进入 `docs/`、截图或Git。MR只提交研究源码、模型许可/LFS资源与合规文档，原目录的无关metadata等文件保持独立。

## 整片效果验证入口

用户追加要求用完整视频观察差距。新增 `court-analyze independent-full-video PROTOCOL_JSON STAGED_MODEL_DIRECTORY NEW_OUTPUT_DIRECTORY`，显式离线模式最多3600秒/216000帧，App交互默认仍120秒/7300帧。整片共用连续decoder/model/tracker，不分段重置背景；失败保留进度，不把部分结果算完成。协议含videoPath/sourceSHA256/expectedFrameCount/firstPTS/lastPTS/timescale。

source003完整747.4667秒（12分27.47秒）已完成单次连续Release运行，进程退出0：44848帧全部解码，48预热、44800推理帧、5600次CoreML，1个来源段、尾部未处理0。冻结的源码/二进制/模型清单摘要全部未变化，新增训练0。已推理帧中22973帧有候选（51.279%），21827帧无候选；无候选也包含空闲/不可见球，不能称48.7%漏检。1155个连续候选段的中位数8帧、最长264帧，227段至少32帧；这不是已确认同球身份或完整飞行。超时重置516次，起始来源重置1次。

**整片自动球速输出0，S家 App 软件参考127行，整体MAE/MAPE及正确同拍精确率均不可计算。现在不能用于独立自动测速，也未通过≤20%验收。** 本次使用固定MIT官方基础模型，不是已失败微调权重。此前单窗的条件87.09km/h不是本次整片自动输出，也没有消除相机资格问题。

Mac CPU离线处理墙钟3366.608秒（56分06.6秒，不含来源哈希和模型加载），约13.32帧/秒；模型调用累计1366.486秒。期间有并行Swift/Xcode构建，这是本次观测而非独占性能基准，更不证明iPhone实时能力。预先固定的12个均匀位置已有agent拼图复核，4处有候选、8处无输出，并查看4处原尺寸候选细节；未生成正确率标签或独立人审。

私有协议、冻结记录、原报告、75个10秒分箱、原帧抽查和回看页位于本worktree `.local/full-video-evaluation-20261029/`。原报告SHA-256为 `98e5faff56aec29226020c5a6821a4dff0d8a29201d100b1d7e5ca432cb9b28b`。`run-v1/summary.json`和`report-v1/metrics.json`是完成汇总；`report-v1/index.html`配合同源60fps展示代理支持逐帧、候选开关和全部127行参考跳转，浏览器已实测150秒跳转/下一帧/开关。代理只展示，模型输入为原始1080p视频。视频、页面内嵌逐帧结果及截图不得提交Git。换机可用 `python3 scripts/ball-full-video-report.py --run RUN_DIR --teachers SHOTS_JSONL --proxy-relative-url VIDEO_URL --output NEW_DIR` 重建到新目录，缺原报告/标签/代理不能宣称重现。下一步是可信相机、独立事件与活动球连续性，再接整片逐拍速度，而非继续拿局部条件数值代表整体精度。
