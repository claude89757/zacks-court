# 地图：代码、数据、命令、视频

更新于 2026-10-30。路径如有变化以仓库为准，发现过时就顺手改掉。

## 目录

1. 代码
2. 私有数据（`.local/`，不进 Git）
3. 视频与分组
4. 常用命令
5. 打分口径

## 1. 代码

| 位置 | 内容 |
| --- | --- |
| `Sources/CourtCore/IndependentAnalysis/Live/IndependentLiveEngine.swift` | 实时链：vImage 缩放（NV12 BT.709）、48 帧中位数背景 + 8 帧一批的 FP16 TrackNetV3、Vision 人框（全画面 + 远端裁剪 + 姿态补框）、每 0.25 秒跑一次滑动窗口规则 |
| `…/Live/IndependentLiveCourt.swift` | 自动球场：取样、分带中位数、后台求解、单帧跟踪、每 60 秒复查、换相机或丢失（没有手动四角） |
| `…/Court/` | 标定器（Python 原型 `court_auto.py` 的逐项移植）：白线证据、Hough、合并线、2×2 搜索、闭式相机、亚像素精修 + LM |
| `…/Shots/` | v13 逐拍规则：`IndependentShotPipeline`（入口与转成行）、`IndependentBallEvents`（交汇点和触地）、`IndependentShotFlights`（人框、动作规则）、`IndependentFlightModel`（带阻力的飞行拟合）、`IndependentShotGeometry`（针孔相机）、`IndependentLiveShots`（滑动窗口、补算、冻结） |
| `…/IndependentBall*.swift` 等 | 更早的本地视频实验链（Codex 的工作），App 里的「本地视频实验」用它 |
| `…/Live/IndependentLiveTrace.swift` | 规则输入的记录与回放：`IndependentLiveTraceEvent`（球点批次、人框、相机变化、每次更新的时刻），`IndependentLiveTrace.replay` 用当前规则重放 |
| `Sources/CourtCore/CameraSideAnalyzer.swift` | 机位分析调度：选 S家 或自研、降载、取全分辨率副本 |
| `Sources/CourtCore/ReferenceChain.swift` | S家链的接口。实现和模型都只在本地（`.local/s-chain/`、`.local/s-models/`，不进 Git），`scripts/reference-chain.sh on` 链接进来；只在 `COURT_MODEL_SET=both` 或 `sjia` 构建里有，见 `docs/s-reference.md` |
| `Sources/CourtAnalyze/` | 命令行：`independent-live`、`independent-replay`、`independent-shots`、`court-calibrate`、`court-lock`、`independent-video`、`independent-full-video`，不带子命令时跑 S家链 |
| `scripts/speed-fullvideo/` | Python 原型链和工具：`court_auto.py`、`shots.py`、`strokes.py`、`report.py`（对 S家 App 老师打分）、`people.swift`、`pose.swift`、`far_crops.py`；README 里有最佳参数 |
| `scripts/prepare-independent-ball-model.py`、`prepare-independent-app-models.sh`、`convert-tracknet-fp16.py` | 模型包的冻结、校验、暂存和 FP16 转换 |
| `assets/independent-models/<id>/`、`assets/independent-model-weights/<id>/` | 自研模型的清单、许可和权重（LFS） |

## 2. 私有数据（`.local/speed-training/`）

`.local/` 只在主检出（仓库根目录的 `.local/`）里，git worktree 里没有。在 worktree 里工作时用主检出的绝对路径读，输出也写回那里或临时目录，不要复制进 worktree，以免误提交。

| 目录 | 内容 |
| --- | --- |
| `*-ref-20261029/` | App 的 S家链给 6 段视频生成的参照行，每段一个 `<视频>-*.json`（test-mov、0913-dsh、full-match、maozi-0918、1080、app-1026） |
| `takeover-test-20261029/v13-0/shots-final.json` | test.MOV：`teacher` 字段是 96 行 S家 App 老师行；`live/` 下是实时链输出（`auto.json` 未开姿态补框，`auto-pose.json` 开了） |
| `takeover-speed-20261029/` | double-test-003：S家 App 127 行；S家 App 锚点 = 导出时间 + 2.0 秒 |
| `independent-new-20261029/lane/`、`lane-pose/` | 新球场的实时链输出（固定相机；不开或开姿态补框） |
| `independent-new-20261029/1080-diag/` | 1080 诊断的中间结果（人框变体、姿态框） |
| `research-r1-20261029/` | 10-30 第一轮：`baseline/`（main 07e820a 四段视频的实时链输出，含 `run.log` 里的负载）、`trace-v13/`（同样的规则加 `*.trace.json`）、`replay*/`（各规则变体的回放），`final/`（提交代码的 1080 核对） |
| `serve-r1-20261102/` | 11-02 发球轮：`trace/`（test.MOV 实时链 v13 的输出和 `test-mov.trace.json`）、`v13-dev`/`v14-dev`（开发视频回放）、`v13-heldout`/`v14-heldout`（留出视频，v14 只跑过一次）、`protocol.md`（事先写好的上线规则）。1080、full_match、maozi、0913-dsh 的记录在 `research-r1-20261029/trace-v13/` |
| `serve-speed-r1-20261103/` | 11-03 发球球速轮（v16）：`protocol.md`（事先写好的上线规则、留出结果和计时修订）、`m15`（v15 开发回放）、`a1`（底线锚定的研究回放）、`anchor_eval.py`（底线 / 触地自检和对参照的比值）。v16 的开发和留出回放（与 v15 一前一后计时）没有留下，数字抄在 `docs/verification.md` 2026-11-03 |
| `court-cameras-20261029/` | 自动标定原型给出的相机（`maozi700`、`full900`、`v1080_100`、`dsh300`、`dsh1500`、`dsh2200`、`testA100`、`testB400` 等）；`*-rejected-camera.json` 是被拒绝的解，只用于诊断 |
| `ball-labels-*`、`dataset-combined-v1-*`、`ball-train-prep-*` 等 | Codex 留下的球点标注与训练准备，见 `docs/speed-model-training.md` |

Python 用 `.local/speed-training/tracknet-smoke-20261028/venv/bin/python`（numpy、cv2）。本 skill 的 `compare_rows.py` 只需要标准库。

## 3. 视频与分组

这些都是维护者的私有视频，不进 Git，本机位置各人不同，表里只写文件名。没有这些视频的开发者，用自己的 1080p60 打球视频按同样的规则分组（开发 / 留出，留出要换球场或换机位），参照行用 S家 App 导出或 S家链生成。

| 视频 | 文件 | 场地 / 机位 | 分组 | 参照 |
| --- | --- | --- | --- | --- |
| test.MOV | `test.MOV` | 单打，中途转过一次机位 | 开发（规则在此调过） | S家 App 96 行、S家 103 行 |
| double-test-003 | `double-test-003.MOV` | 双打，低机位（约 1.5 米） | 开发（交叉检查时调过） | S家 App 127 行 |
| 1080 | `1080.mov` | 与 full_match 同场同机位；广角，焦距约 1024 px | 开发（姿态补框在此选定） | S家 98 行 |
| full_match_video | `full_match_video.mov` | 与 1080 同场同机位，黄昏 | 开发（同机位） | S家 245 行 |
| maozi-0918 | `maozi-0918-szw.mov` | 室内蓝色场地 | 留出 | S家 173 行 |
| 0913-dsh | `0913-dsh.mov` | 夜场，37 分钟，机位慢慢偏 | 留出 | S家 406 行 |
| 过滤对拉 ×3 | `*过滤后的对拉*`（其中一段是 `10-26-2025-过滤后的对拉.MOV`） | S家 App 导出，画面上有 S家 的球速 | 额外参照（有剪辑） | 画面叠加的球速 |

维护者本机还有 `double-test-001/002`、`single-test.MOV` 和几段 mp4，还没评估过。它们可能是新的留出视频，先查规格（要求 1080p60），再用 S家链或 S家 App 生成参照。

## 4. 常用命令

```bash
swift build -c release --product court-analyze
BIN=$(swift build -c release --show-bin-path)/court-analyze
./scripts/prepare-independent-app-models.sh          # 暂存并校验 .local/IndependentModels/<id>
M=.local/IndependentModels/tracknetv3-base-fp16-v1

# 自研实时链（与 App 机位相同）；auto = 自动球场，或给一个相机 JSON 固定相机
$BIN independent-live VIDEO $M auto OUT.json [START [DURATION]] [--no-pose-fill] [--realtime]
# S家参照行（需要本地的 S家模型：放进 .local/s-models/，scripts/prepare-analysis-models.sh 校验并暂存到 .local/AnalysisModels）
$BIN VIDEO .local/AnalysisModels OUT.json
# 单独求解一张或多张中位图
$BIN court-calibrate MEDIAN.png [MORE.png …] OUT.json
# 自动识别球场的锁定评测：按已知相机转动晃动三脚架视频（steady/fixed/settle/bump/wobble），量锁定时间和对错；
# --before 是 11-04 之前的找法，--anyway 在没有稳定解的视频上只看锁没锁、画面动了多少
$BIN court-lock VIDEO OUT.json [--start S] [--duration D] [--scenarios settle,bump] [--seed N] [--before]
# 只改规则时：用实时链记下的输入重放（不跑球模型和 Vision），输出格式同上
$BIN independent-replay OUT.trace.json REPLAY.json
# 打分
python3 .claude/skills/inhouse-model-research/scripts/compare_rows.py REF.json RUN.json [RUN2.json …] [--window 起 止] [--json]
# 只看发球：精确率、召回、F1、有速覆盖、离散度；REF 可以是 S家行或 S家 App 老师行（test.MOV 的 shots-final.json）
python3 .claude/skills/inhouse-model-research/scripts/serve_score.py REF.json RUN.json [--tol 1.0] [--diag OUT.tsv]
```

- 默认情况下，`independent-live` 会等分析跟上再送下一帧，不丢帧，适合比较结果；加 `--realtime` 会按源视频时钟送帧，丢帧情况和实机一样。报告里有每帧缩放、每批推理、每次人员检测的毫秒数，还有球场何时找到、求解了几次。旁边的 `OUT.candidates.json` 是逐帧球点候选，可用来单独研究球检测。
- 只改规则时，不必每次重跑球模型：`independent-live` 还会写 `OUT.trace.json`（规则看到的全部输入：球点批次、人框、相机变化、每次更新的时刻），`independent-replay` 用当前代码的规则把它重放一遍，得到实时链会给出的行，另带每拍的完整结果（`shots`：击球者框、触拍点、拟合位置、远近端；v14 起还有 `startKind`、`crossesNet`、`serveBehindPx`）。规则不变时回放与实时链逐行相同（10-30 四段视频核对过）。1080 回放约 45 秒，full_match 约 100 秒；记录文件 5–15 MB。它只衡量规则改动，不衡量球检测或人员检测的改动。
- `court-analyze independent-shots` 读离线链的候选报告和人框 JSON（用法见 `Sources/CourtAnalyze/IndependentShots.swift` 顶部注释），用于和 Python 原型对照。
- 用 `swift test --filter IndependentLive` 等跑相关测试；完整的 `swift test` 约 4–5 分钟。

## 5. 打分口径

- `compare_rows.py` 默认在 0.3 秒内按最近的击球时刻一对一配对。对 S家 App 老师行用 `--tolerance 0.6`，配对数与 `scripts/speed-fullvideo/report.py` 一致（test.MOV 都是 86）。不过 report.py 的球速主指标还要求看到触地（`COURT_SPEED_REQUIRE_BOUNCE=1`），两边的球速数字不能直接互换。
- 只分析了一段的结果要加 `--window`：`independent-new-20261029/lane-pose/dsh-a.json` 只覆盖 0913-dsh 前约 900 秒，不加 `--window 0 900` 时检出率显示 30%，加了是 70%。
- 动作只按粗类比较：发球、正手、反手、截击、高压、喂球。哪一边是"未知"（包括「落地击球」）都不计入第一行的一致率，但会单列出来。同时打印"一律答多数类"的一致率作为基线，一致率不比它高，就说明规则在这段视频上没有信息量。
- 第二行把自研弃权算错：所有配上且 S家 有类别的拍做分母。自研多说「落地击球」只会让第一行变高、第二行变低（10-30 那轮的远端弃权就是这样），两行要一起看，再看自研说了正反手时对了多少。
- 多报：自研行数一般是 S家的 2.4–3 倍，所以"没配上的自研行"本身就是一个指标，不只是噪声。
- 自研和 S家之间的球速中位比只在两边都有速的拍上计算，样本很小，也有选择效应。要同时看各自全部有速拍的分布，再和"S家链 / S家 App ≈ 0.91"（test.MOV，38 行）放在一起看。
- 自研的击球时刻比 S家 系统性地早约 0.1 秒，配对数对窗口很敏感（maozi：0.15 秒 64 拍，0.3 秒 135 拍，0.5 秒 152 拍）。比较不同改动时固定同一个窗口；报告配对数时写明窗口。
- 这个"早"有一部分是 S家 晚：11-02 用视频音轨的击球声（扣掉声音传到机位的时间）当时间参照，S家 的发球时刻比击球声晚 0.09–0.23 秒（中位，五段视频），自研 v14 的发球行中位在 −0.14 到 +0.06 秒（各段近端、远端分开算）。广角机位上约一半的 S家 远端发球行落在过网时刻，S家 还会给同一次发球报 2–3 行。所以按 S家 时刻给远端发球配对时，时间偏差和配对数都不可靠。音频参照脚本（离线、只用作时间参照）在 `.local/speed-training/serve-r2-20261102/scripts/`（`audioref.py`，用法见同目录 README）。
- `compare_rows.py` 给多个 RUN 时会把它们合成一份（用来拼接分段结果），比较两个版本要分开跑。
- `independent-replay` 在 v15 之前写出的 JSON 里，`shots` 按发布顺序、`events` 按时间排序，两者下标对不上（每段 52–88 行错位）。v15 起两者一起按时间排。读旧输出时先把 `shots` 按 `tHit` 排序再按下标对应。
