# 球速模型自训练：数据准备与首轮实验

目标是训练自己的球速估计链，先衡量与固定 S家 App 导出快照的差异，再用独立参考验证物理精度。已建立数据契约、去重和逐帧复核工具，并完成一轮未审伪标签上的画面特征诊断拟合和开源追踪器兼容性试跑。诊断拟合没有优于常量基线；尚无通过验收的替代模型。

> **2026-10-30 决定**：整个开发和训练流程不做人工标注（用户）。下文的人工盲审包、人工复核和"人工事件时间"等计划不再推进；标签和参考改为自动产生（物理拟合的伪标签、我们自己的离线老师、单一动作练习段、雷达等仪器读数），见 [自研替换设计](model-replacement-design.md) §5.2。以下内容作为历史记录保留。

当前阶段性交接见 [独立测速接手说明](independent-speed-handoff.md)。下文保留历轮实验及失败记录；速度定义以文末“教师语义纠正”与新的瞬时触拍候选为准，早期路径均值与教师标量接近的数值不能解释成同口径误差。

## 已冻结的数据与来源边界

2026-10-28 检查的 5 段主视频合计约 56.42 分钟。视频包逐项比对确认 `single-test.MOV` 的全部 18,125 个包与 `test.MOV` 的前 18,125 个包相同，包括内容 SHA-256、PTS、DTS、duration、size。两者必须属于同一个来源组；不能把它们分到训练和测试两侧。

扣除这份完整前缀后，按视频流 metadata 时长最多剩约 **51.38 分钟**，接近 60 fps 的部分最多约 **23.04 分钟**。其他文件未发现相同的完整起始包序列，不代表已排除中间剪辑、重新编码或同场景重复。

当前可绑定原片的历史导出为 96 拍。三份 XLSX 来自同一源片的不同快照/重复导出，不能累计为 288 拍。选择 2026-10-15 的单打当前导出表作为首份冻结快照，旧表只用于差异调查。

- 源视频 SHA-256：`5ed746a2734c5611e19b14c3a0b18c03aee9579c66a03c7416573df9b9abb652`。
- 导出 SHA-256：`6bc79297b76c36d2192df40b98ab8307a2e25d704a1d0dbb1f8f55e8d8ff3342`。
- 96 拍均有数值球速，但仍全部待审核。数值存在不等于标签正确或允许入训练池。
- 本轮安装的 S家 App 版本已记在本地；历史 XLSX 的实际分析版本未知，不能用当前安装版本回填。
- 历史丰富 JSON 绑定的 mounted XLSX 摘要与当前表不同，不能把那份 JSON 的版本、坐标或时间证据直接移植到当前表。

同日又通过 S家 App 正常界面导入 `double-test-003.MOV` 并完成本机处理。界面显示 134 次击球，实际 XLSX 导出 **127 行**，127 行均有数值速度；两个计数不是已确认的同一集合，不能推断漏了 7 拍。新源 SHA 为 `dd4d8897325de33f9bfb46f3d83eecba1c66fb2457d1ab2c07daf0f18d0bb13e`，新导出 SHA 为 `68b18ee429e58e17ecfa2c8eeaf25b0be50ae316329d634a1b4e20bff4710752`。

合并数据为 **223 条待审伪标签**：旧单打源分到训练组 96 条，新双打源分到验证组 127 条；共有 69 个带源身份的软件回合上下文。分组是待审阶段的显式安排，不表示已经完成泛化评估。用户确认三段双打视频的拍摄高度、设备、变焦没有记录，均保存为未知；本次选用的“围网支架”仅是 S家 App 的软件设置。

视频、导出、帧图和逐拍数据只写入忽略目录 `.local/speed-training/`，不提交 Git。审计工具仅保留必要技术字段，数据集不包含 XLSX 的 Player 身份列。

## 工具与复现

数据集、来源审计和盲审工具使用 Python 3 标准库；视频审计需要 `ffprobe`，逐帧复核素材需要 `ffmpeg`。诊断拟合脚本另需 NumPy、Pillow。所有输出选择新路径，工具拒绝覆盖已有产物。

### 视频来源审计

```sh
python3 scripts/speed-source-audit.py self-test
python3 scripts/speed-source-audit.py audit \
  --output .local/speed-training/source-audit.json \
  /absolute/test.MOV /absolute/single-test.MOV /absolute/other.MOV
```

逐视频保存文件摘要、流 metadata、包序列摘要、工具版本与完整命令。逐对只判断完整相同或完整起始前缀；`not_detected` 不等于独立拍摄。连接组建议仅用于防泄漏，不证明组间机位/场地独立。

包时间跨度可能包含容器预卷，不能与实际播放时长混称。工具不会按包序号推断解码后的画面帧序号。

### 构建冻结教师快照

```sh
python3 scripts/speed-dataset.py --self-test
python3 scripts/speed-dataset.py build INPUT_CONFIG.json \
  --output .local/speed-training/dataset-v1
```

配置的 `sources[]` 每项明确：

- `source`、`export`：路径和预期 SHA-256，错源即停止。
- `group_id`、`split`：按来源族/场景显式指定，同组不得跨 split；不得随机拆帧。先根据来源审计把前缀副本归到同组。
- `teacher`：名称、已知安装版本、实际推理版本、快照 ID、证据说明；未知版本填写 `unknown`。
- `anchor_offset_seconds`、`anchor_offset_basis`：软件时间映射和证据。当前表按历史 exporter 证据取 `Video Time + 2 秒`，仅用于找到待审窗口。

完整配置格式见脚本开头说明。输出：

- `manifest.json`：来源、教师、工具与产物摘要。
- `shots.jsonl`：每拍技术字段、软件事件锚点、教师伪标签和审核状态。
- `review.csv`：待审核登记表，不含教师球速和坐标；不是已完成的人工标签。
- `summary.json`：数值有效、待审、来源组和独立留出集的数量及准备状态。

工具不会把缺失补 0，也不会把教师置信度未知改成 1。速度值范围检查只检测异常数值，不证明物理正确。坐标单位、轴向和原点未明确核验前，禁止将 Hit/Bounce 坐标作米制几何真值。

### 生成离线盲审包

```sh
python3 scripts/speed-review.py --self-test
python3 scripts/speed-review.py build \
  --dataset .local/speed-training/dataset-v1 \
  --output .local/speed-training/review-v1 --count 40
```

直接在浏览器打开输出目录的 `index.html`，可选匿名样本、逐帧前后查看、填写触拍/触地区间、可见性和排除原因，再导出本地 `review.json`。页面不显示教师速度、XYZ 或类别，不连接外部服务；刷新前先导出，页面记录尚未自动合并回数据集。浏览器页面的“已复核”也不等于满足训练入池条件。

每张 JPEG 都绑定解码帧的原始整数 PTS、timebase 和图像 SHA，并与另一条 `ffprobe` 解码路径逐帧核对。时间窗口采用 `[ceil(start/timebase), ceil(end/timebase))` 整数半开区间：首轮批量抽帧曾发现秒式 `trim` 向较早 tick 取整，现已修正并有回归。窗口内帧数以实际解码为准，不强凑每拍 120 帧。

`audit/selection_receipt.json` 保存源片、worksheet 行、选样规则、回合/重叠组、软件锚点映射、工具版本与摘要。盲审者不要先看这份映射；它属于事后核对依据。固定窗口仍可能暗示软件锚点的大致位置，因此这是结果字段盲审，不是完全无时间先验的独立事件检测。

## 人工事件时间与教师输出分开

保存四种不同时间：导出 `Video Time`、加偏移后的软件事件锚点、人工触球 PTS 区间、人工首次触地 PTS 区间。未知区间保持为空，不统一减去一个经验延迟，也不按标称 fps 反推帧时间。

逐帧复核以真实解码帧的整数 PTS 与 timebase 为准，记录解码器、旋转/缩放和时间映射。FFmpeg 与 AVFoundation 的时间口径不能未经校验直接混用。复核图片只是原片的浏览副本，不提供新的物理参考。

先按完整回合选拍，每个非空回合先选 1 拍，再以冻结的哈希顺序补齐；另按实际可见情况登记遮挡、近远端、密集交换和窗口边界。首个单源包为 40 拍/32 回合；新增双打后，合并盲审包为 **80 拍/69 回合/9,597 帧**，保存于 `.local/speed-training/review-80-combined-20261028/`。选拍不读取教师球速、XYZ 或模型误差。界面先隐藏教师结果，避免用“速度像不像”来决定同拍对应。

预声明继续条件，均尚未通过：

1. 入训练池的每拍都有唯一同球/同拍绑定；歧义留出，不能强行匹配。
2. 首轮约 40 拍的场景复核中，至少 30 拍可确认身份并有可用视觉输入，覆盖至少 20 个回合；不能仅由一个场景的通过结果推定另一个场景可用。
3. 对 10 拍进行独立复核；至少 9 拍的触球区间相交或中点相差不超过两个实际帧间隔，身份分歧须解决。
4. 精确触球监督要求区间宽度不超过两个实际帧间隔；其他只可保留为弱标签。
5. 开头、中段和末段都完成源片对应验证；错源、时间漂移、非单调映射或重复身份阻断自动入池。

2026-10-28 的 Astra 智能体视觉初审覆盖固定前 10 个窗口，仍有 70 个未审；这不是人工审核。初审得到 6 个可见触球候选、4 个未知，没有确认首次触地。主智能体又复看其中 3 个窗口，但此前已看过初审意见，不能计为独立双审。部分触球发生在画面外；`sample-005` 有多次击球，后段可见截击不能直接作为目标事件。

初审记录冻结后才与软件锚点作事后对照：4 个锚点数值上落在候选区间内；`sample-005`、`sample-009` 的可见候选比锚点晚约 0.6 秒，目标身份保持未解决。不能据此统一移动标签，也不能把时间接近当作唯一同拍绑定通过。26 个球心候选只是智能体图像观察，未成为正式训练标签。223 行的训练资格仍全部为 false，人工审核数为 0。

## 第一训练实验的限定

首轮采用低容量模型，检查独立视觉特征是否包含拟合该教师快照的信号。不要以 96 拍从随机权重训练完整视频网络。

可考虑的输入为自己提取的球像素轨迹、真实帧时间差、可见性和人工球场参考。教师速度只作目标；教师 XYZ、速度向量、细化窗口、事件持续时间、结果和由它们推导的距离/时间比，不能作为首轮独立速度头的输入。

若使用人工事件窗口，结果名称必须注明“人工事件定位条件下的速度头”；若球追踪仍使用 S家模型，必须注明上游依赖，不能称完整独立替换。

先按完整回合及重叠窗口连通组冻结探索性训练/验证/测试，再做标准化和模型选择。整个 `test.MOV` 来源族只有一个会话，同会话留出不代表跨会话或跨场地泛化。新场景导出必须另行绑定、审校和冻结，不能因文件名不同就认定独立。

比较训练集速度中位数常量基线与小模型；增加标签置乱控制。报告实际拍数/回合数、覆盖率、MAE、偏差、中位绝对差和失败情况，名称为“对教师快照的软件差异”。仅在成功输出的拍上算误差不足以评价整条链路。

真实球速精度仍按 [球场实测方案](field-test-plan.md) 使用同步独立参考验证。与 S家 App 接近不等于物理正确，也不构成发布精度承诺。

## 2026-10-28：首轮诊断结果

为先排查粗粒度画面变化是否有用，显式允许在未审伪标签上进行一次**不具备训练资格的诊断拟合**。这不放宽上面的正式入池条件。`speed-baseline.py` 默认拒绝未审行，只有 `--diagnostic-unreviewed` 能运行本轮数据；所有模型和指标均标注 `production=false`、`training_qualified=false`。

```sh
# 使用具备 numpy、Pillow 的 Python；本轮精确版本保存在实验 manifest.json。
python3 scripts/speed-baseline.py --self-test
python3 scripts/speed-baseline.py --diagnostic-unreviewed \
  --dataset .local/speed-training/dataset-combined-v1-20261028 \
  --review-package .local/speed-training/review-80-combined-20261028 \
  --output .local/speed-training/baseline-diagnostic-reproduction
```

脚本目前针对冻结的 80 窗口、35/45 划分运行。运动特征是缩小灰度图上 8 对相邻帧的绝对差除以实际 PTS 间隔，再取全图和 3×3 网格统计，共 20 维；它包含人体和背景变化，**不是球轨迹，也不是光流**。另拟合首帧灰度统计作为静态外观对照。输入排除教师速度、XYZ、类别、结果、事件持续时间和来源身份；窗口本身仍由教师事件定位，因此不代表自动检测整条链路。

在解析任何目标行前保存实验协议；35 个训练窗口按 32 个回合/重叠连通组做 5 折选择，两个岭回归模型均选中 λ=100。标准化只拟合训练折；45 个验证窗口来自另一来源族。实现会在拟合前解析并检查验证目标的数值有效性，但验证目标不参与特征、标准化或超参数选择，不能宣称验证标签完全封存至评分时。一次冻结结果保存在 `.local/speed-training/baseline-diagnostic-20261028/`，没有看完验证结果后重新选择特征或裁剪预测。

对教师快照的软件差异，验证分母均为 45 个窗口，单位 km/h：

| 方法 | MAE | 中位绝对差 | 95 分位绝对差 | 有符号偏差 |
| --- | ---: | ---: | ---: | ---: |
| 固定输出训练目标中位数 | 20.91 | 17.52 | 48.44 | +13.89 |
| 画面变化 + 岭回归 | 23.78 | 21.77 | 48.64 | −20.11 |
| 静态外观 + 岭回归 | 272.59 | 274.78 | 307.98 | +272.59 |

80/80 个选中窗口完成提取，9,597 张 JPEG 的摘要与实际 PTS 通过核验，0 个窗口被丢弃。该覆盖率不包括其余 143 条伪标签或视频中的未检出事件。20 次训练标签置乱对照沿用已选 λ，其中 4 次运动模型优于真实标签运动模型；它只是探索性负对照，没有按相关回合置乱并重新选择 λ，不能给出正式置乱检验 p 值。

结论是这套粗粒度特征没有通过本轮诊断，静态外观在场景变化后尤其失效。不能由此推断视频测速不可行；下一步需要独立的网球点位/轨迹，而不是继续调这个小模型去迎合已看过的验证结果。这 45 个窗口已经用于探索，以后若据此改方案，最终确认需要新来源或另行冻结的独立测试集。

## 开源追踪器兼容性试跑

使用作者 [TrackNetV3 仓库](https://github.com/qaz812345/TrackNetV3) 的官方预训练权重，固定源码提交 `6eda442ada1740573f200f836d93edc9a541ee86`。该提交的 [LICENSE](https://github.com/qaz812345/TrackNetV3/blob/6eda442ada1740573f200f836d93edc9a541ee86/LICENSE) 明确代码和预训练权重均为 MIT；模型训练对象是羽毛球，不能把其原始表现当作网球表现。

在任务独立的 Python 3.12 环境，用 `weights_only=True` 和 strict 模式加载成功。`seq_len=8`、`bg_mode=concat`；`sample-006/007/008` 各前 16 帧，共 48 帧、6 次 CPU batch1 推理，得到 48 张热图。按作者原阈值 `>0.5` 和最大包围矩形面积轮廓规则，输出 21 个未审候选，27 帧无候选。没有补点或使用 InpaintNet。

次日完成独立智能体复核：48 个保存输出的索引、PTS、图像摘要和坐标回映复算一致；定向查看 8 帧时，`sample-007` 有候选落在可见抛球上，也有球可见却没有输出；`sample-008` 第 11/14 帧候选跳到了球拍附近，真实球还在天空中。主智能体又查看两张叠图，确认其中的正确定位和球拍误检例。这里的“独立”指复核推理实现，不是独立人工标签；8 帧定向抽查不能换算成识别准确率。试跑只覆盖抛球阶段，尚未检查击后的高速球。

这确认权重、依赖、输入输出和帧序可以接通，也暴露了直接移用的错误。背景中位图仅来自各自 16 帧窗口、包含未来帧，偏离作者整段视频背景方法；这不是因果实时检测，CPU 单批耗时也不能证明手机实时性能。来源、许可、依赖版本、权重摘要、逐帧 PTS 和输出保存在 `.local/speed-training/tracknet-smoke-20261028/`。

下一阶段建立可复核的网球点位集，包含球心、可见性、遮挡、击后模糊、远端小球，以及球拍/灯光/静止球负例；先冻结来源隔离的留出部分，再进行微调。模型候选不能自动当真值。二维追踪通过后仍须解决未知相机参数下的三维估计与独立速度参考，不能用球场地面单应性替代空中球的深度。

## 2026-10-29：点位标注与首次输出层学习检查

### 可恢复的球点标注页

新增 `scripts/ball-labels.py` 与 `scripts/ball-labels-ui.html`。默认从前 10 个匿名窗口各选帧索引 10、30、50、70、90、110，共 60 张待标图；每张另带前后各两张真实连续邻帧，合计 240 张只读上下文图。每张图核验 SHA、尺寸及原始 PTS。目标图间隔 20 帧，不能将它们冒充连续视频；界面明确区分“下一张待标图”和“原始邻帧”。

```sh
python3 scripts/ball-labels.py --self-test
python3 scripts/ball-labels.py build \
  --review-package .local/speed-training/review-80-combined-20261028 \
  --output .local/speed-training/ball-labels-new
python3 scripts/ball-labels.py validate \
  --package .local/speed-training/ball-labels-new \
  --labels /absolute/exported-labels.json \
  --output .local/speed-training/ball-label-validation-new.json
```

本轮用户空白包为 `.local/speed-training/ball-labels-60-v3-20261029/`，可在该目录运行 `python3 -m http.server 8918 --bind 127.0.0.1` 后打开本机地址。页面无教师字段和预测叠图；点击球心、填写不确定半径与目标身份后，需明确保存才记为已审。邻帧不能写标签。状态包括可见、遮挡、画外、无球和未知，只有明确“无球”可作零热图负例；未知、遮挡和画外均不自动作负例。

页面按包身份自动保存在浏览器 localStorage，并支持导出、校验后导入。换浏览器或清理站点数据仍可能丢失，因此需要导出备份。错误包、重复帧、哈希/PTS 不符、越界/非有限坐标拒绝导入；非可见状态清空坐标。标注者区分自报人工、agent 和 UI 测试，逐帧保存原类别，改顶层名称或类别不会把导入的 agent 候选自动变成人工标签。校验报告中的资格只是格式与自报审核门槛，不证明独立复核或物理正确。页面导出不会自动写回原 223 拍数据集，也不会自动开启训练。

### 智能体点位候选

Astra 对上述 60 张图实际查看，并用连续局部图检查部分网前小球，保存 33 张查看素材的收据。结果为 50 张可见球影：45 个当前目标球候选、5 个目标身份不确定；另 10 张未知。仅 45 个候选可进入显式的工程诊断，其他权重为 0；没有可靠无球负例。坐标是不确定半径约 5–9 像素的图像中心估计，不是瞬时三维球心，半径也不是经过校准的误差条。

这些记录均为 `reviewer_kind=agent`，正式资格为 false。初审者此前见过部分同场景画面与烟测例，不能宣称首次全盲或人工真值；点位身份也没有解决之前两拍的教师事件绑定歧义。种子位于 `.local/speed-training/ball-seed-20261029-astra/seed.json`，用户标注页保持全空，没有把 agent 点预填成人工答案。

### 有界工程学习检查

新增 `scripts/ball-track-diagnostic.py`，提供 `prepare`、`audit`、`forward-backward` 和 `fit`。默认拒绝 agent 标签，显式 `--diagnostic-agent-labels` 才可使用本轮种子。脚本只允许 CPU、固定学习率和最多 8 步；所有产物 `production=false`、`human_validated=false`，没有评估命令或精度输出。

```sh
BALL_DIAGNOSTIC_PYTHON=.local/speed-training/tracknet-smoke-20261028/venv/bin/python
"$BALL_DIAGNOSTIC_PYTHON" scripts/ball-track-diagnostic.py --self-test
"$BALL_DIAGNOSTIC_PYTHON" scripts/ball-track-diagnostic.py prepare \
  --config .local/speed-training/ball-train-prep-20261029/train-only-config-v2.json \
  --labels .local/speed-training/ball-seed-20261029-astra/seed.json \
  --output .local/speed-training/ball-prepared-new --diagnostic-agent-labels
"$BALL_DIAGNOSTIC_PYTHON" scripts/ball-track-diagnostic.py fit \
  --prepared .local/speed-training/ball-prepared-new \
  --output .local/speed-training/ball-fit-new \
  --max-steps 8 --diagnostic-agent-labels
```

训练输入仍是每段真实连续的 8 帧，不是把稀疏标注图拼成假时序。未标、未知、身份不明、遮挡及画外的输出帧全部 mask=0；仅明确可见同球点生成高斯热图。高斯宽度由原图不确定半径缩放，最小 1.5 个模型像素，这是项目自定义监督目标；只对 WBCE 损失公式沿用作者实现，不能称完整复现作者训练方法。背景为声明序列帧并集的中位图，包含未来帧，仍是离线条件。

执行前冻结来源、回合、重叠组、图像/标签/配置摘要和依赖版本。此工程练习把两个已看过的来源用于 train-only，不包含验证集；不能沿用之前球速任务的验证称呼。`double-test-001/002` 已登记为后续评估保留来源，但尚无标签，且都是 30 fps，也未排除重新编码或同场景依赖，不能称现成独立测试集。

本轮先完成一次不更新权重的前向/反向检查，再对按样本/起点排序的前 8 个可用序列各做一步 Adam（seed=20261029、学习率 1e-5）。只开放 `predictor` 的 520 个参数，全网络保持 eval，BatchNorm 固定。实际输入 64 帧、监督 **8 个候选点**，不是训练了全部 45 点；8 个输出通道各监督一次。每步梯度有限且非零，同批损失略降，标签处输出略升，这只是优化信号，不证明球心定位正确。

新输出层保存在 `.local/speed-training/ball-train-prep-20261029/fit-v2-8steps/diagnostic-head.pt`，它依赖原官方基础模型，不是完整独立模型，也不是可发布的 Core ML 包。安全重载后确认输出层发生变化；所有非 predictor 张量和 BatchNorm 状态、官方权重文件均未变。未知输出的损失梯度为零，但 Adam 的历史动量仍可能改变此前受过监督的输出行，因此不能声称当步无标签的参数行完全不动。

当前已打通标注契约、目标生成、遮罩、反传和派生权重保存。下一步效果实验仍需独立复核的点位、连续高速球/困难负例和预先冻结的评估集；本轮没有得到跟踪准确率、球速精度或手机运行结论。

## 2026-10-29：原始与 8 步微调的实际效果对照

在相同输入、固定背景和作者原阈值 `>0.5` 下，**8 步微调没有改变任何候选坐标或有无输出**。比较覆盖准备阶段的 60 个 8 帧序列（480 次帧输出），以及 `sample-006/007/008` 三段完整窗口（360 次帧输出）。两种范围有重复原图，合计 840 次帧输出不是 840 张独立图或独立试验。期间没有再训练或调阈值。

45 个 `visible+confirmed` 智能体候选点均来自准备序列范围；未知和身份不确定的 15 点没有当成负例。以下分母包括模型无输出的点，“≤10px”指 1280×720 复核图上的候选点距离，并非人工真值下的准确率：

| 候选点范围 | 原始有输出 | 微调有输出 | 原始 ≤10px | 微调 ≤10px | 微调后新增匹配 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 全部 45 点 | 34/45 | 34/45 | 32/45 | 32/45 | 0 |
| 参与 8 步监督的 8 点 | 6/8 | 6/8 | 5/8 | 5/8 | 0 |
| 未参与这 8 步监督的 37 点 | 28/37 | 28/37 | 27/37 | 27/37 | 0 |

全部点在 5/10/20 像素内的数量分别为 28/32/32，前后完全一致。45 点中有 11 个无输出，另 2 个输出距候选超过 20 像素。仅对 34 个有输出点计算的距离中位数为 2.91px、P90 为 6.38px；这两个数不能掩盖漏输出，也不能当作所有 45 点的误差。37 个未训点仍共享已见来源，其中 2 点还共享训练窗口/背景；没有独立留出集或真实无球负例，因此不报告真实精确率、误报率或物理测速精度。

完整窗口使用起点 0、8、…、112 的连续不重叠序列；准备序列的起点不同，因此两类结果分别保存，不混用点位统计。三段完整窗口的输出数分别为 79/120、71/120、66/120，前后相同；这些帧没有逐帧真值，输出比例不是召回率。热图数值有极小变化（最大绝对变化约 0.000356），没有改变离散候选。

固定 15 帧的智能体视觉复核看到靠近球的候选、可见球无输出以及误认球员三种情况。例如 `sample-006` 第 90 帧，候选落在远端球员头部/上身附近，与球心候选相距约 93 像素；两个模型都一样。两张原先不确定的帧仍保留不确定，没有根据模型输出把它们升格为真值。原始模型与安全重载的 `head-before` 在同一输入上的热图逐值完全相同，排除了本次模型替换路径造成的假差异；推理前后模型状态和权重文件摘要均未变。

复现工具为 `scripts/ball-track-compare.py`（需显式 `--exploratory-agent-label-comparison`），可视化工具为 `scripts/ball-compare-view.py`。比较产物在 `.local/speed-training/ball-compare-20261029/`，可直接看的 HTML 和三段 MP4 在 `.local/speed-training/ball-compare-view-20261029/`。每段视频 120 帧，15 fps 播放、8 秒；原片相邻 PTS 均严格为 1/60 秒，因此是 4 倍慢放。青圈在左侧表示原始模型，橙圈在右侧表示微调模型；无输出明确标记。准备序列静图和完整窗口补充静图分目录保存，原像素裁区不叠加 agent 点作真值。

```sh
BALL_DIAGNOSTIC_PYTHON=.local/speed-training/tracknet-smoke-20261028/venv/bin/python
"$BALL_DIAGNOSTIC_PYTHON" scripts/ball-track-compare.py --self-test
"$BALL_DIAGNOSTIC_PYTHON" scripts/ball-track-compare.py \
  --exploratory-agent-label-comparison --output .local/speed-training/ball-compare-new
# 对照页为纯本机静态文件；也可直接打开其中的 MP4。
python3 -m http.server 8919 --bind 127.0.0.1 \
  --directory .local/speed-training/ball-compare-view-20261029
```

这个结果支持保留“训练流程已接通”的结论，但不支持宣称效果改善。下一次学习实验需要扩大可靠的连续球轨迹与困难负例，在独立来源上冻结评价；当前检查仍只涉及二维球定位，没有训练新的球速头。

## 2026-10-29：连续帧、末端网络与固定裁区调优

本轮实际运行四组微调，并用未参加本轮训练的源文件作一次固定检查。结果是局部球定位改善，尚不支持高速追球或测速结论。新增工具为 `ball-tune-data.py`、`ball-track-tune.py`、`ball-tune-view.py`；全部私有素材和产物位于 `.local/speed-training/ball-tune-20261029/`，没有替换 App 内的模型。

### 数据与冻结条件

- 训练仅用 `double-test-003.MOV` 的旧 006/007/008 三个窗口，按原整数 PTS 重新抽取各 120 张 1920×1080 原尺寸图。每窗固定标注 0–15 和 64–95 帧，共 144 帧；Astra 实际逐帧查看，134 个可见且身份确认的球影候选、10 帧未知，没有用插值补标签。它们仍是 agent 候选，非人工真值。窗口选择受以前错误样例影响，不宣称盲选。
- 检查源固定为 `double-test-002.mp4`，从时长 20%（174.96 秒）后第一个解码 PTS 起取 120 张 1280×720 图，不因画面质量更换窗口。主智能体在看新模型输出前，实际查看同样 48 个预定目标帧并冻结标签：64–95 帧有 32 个连续可见球候选，0–15 帧为 16 个未知。画面是回合间慢速传球/弹跳，**32 帧属于同一短段，不是 32 个独立击球**。
- 训练源为 60 fps，检查源为 30 fps，保留真实时钟，不补帧。同一模型的八帧输入覆盖不同时间跨度，因此检查同时包含采样率差异。源文件 SHA 隔离已核验；未证明所有场景依赖均消除。`double-test-001.mp4` 本轮仍未抽图；002 在这次检查后属于开发数据。
- 四窗共 480 张图均核验 SHA、原尺寸、FFmpeg 与独立 ffprobe 的整数 PTS；训练原片与旧窗口 120 帧的身份逐一一致。每窗背景由预定均匀 48 帧的原片 RGB 中位数生成，再裁切/缩放，包含未来帧，属于离线条件。背景帧集合与 48 个标注帧集合不同。

四组均独立从固定官方原始权重开始：整图/中心 80% 裁区 × 输出层/最后解码块及输出层。裁区固定为原尺寸 `[0.1W,0.1H,0.9W,0.9H]`，再缩到 512×288，没有根据结果改变边界。输出层可训练 520 参数，末端解码方案可训练 148,232 参数；BatchNorm 运行统计保持固定。

每组固定 Adam、学习率 `1e-4`、seed `20261029`、CPU 4 线程、72 次更新，取末次权重，无提前停止或检查源选参。18 个候选八帧段中有一段全未知，实际 17 段按固定次序循环；每组累计 568 次有效帧监督，唯一可见候选仍只有 134 个。未知、身份不明、遮挡和画外输出权重为零。可见球在裁区外时训练不监督，评价仍保留在分母并计未匹配。本轮 134 个可见训练候选都在裁区内。

新损失将作者 WBCE 的正、负项在每个有效帧内分别按目标质量归一后平均；可见点仍使用高斯热图。这是项目自定义适配，不是作者完整训练方法复现。记录了全零输出参照，防止用大量背景像素掩盖球定位失败。没有明确无球负例，因此没有真实精确率或误报率分数。

### 同条件实际结果

每个模型均对四个完整窗口推理：480 个不同源帧 × 6 组 = 2,880 次帧输出。下表只对冻结的可见候选评分，未知不作负例，无输出保留在分母；距离统一换算到 1280×720 等效坐标。原尺寸指标另存报告，不与旧缩放图混比。

| 条件 | 训练 ≤10px / 134 | 训练无输出 | 训练有输出但 >20px | 检查 ≤10px / 32 | 检查无输出 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 原始模型，整图 | 59 | 56 | 19 | 21 | 11 |
| 输出层微调，整图 | 59 | 54 | 21 | 23 | 9 |
| 末端解码块与输出层微调，整图 | 62 | 50 | 22 | 31 | 1 |
| 原始模型，固定裁区 | 62 | 51 | 21 | 32 | 0 |
| 输出层微调，固定裁区 | 62 | 50 | 22 | 32 | 0 |
| 末端解码块与输出层微调，固定裁区 | 64 | 39 | 31 | 32 | 0 |

检查源六组均没有距候选 >20px 的输出。这里的 32/32 仅表示这段慢速传球的智能体候选一致性，不表示网球准确率 100%。整图末端微调把该片段的匹配从 21 提高到 31；固定裁区的原模型已经达到 32，因此本轮没有证明裁区上再训练的收益。训练窗的裁区末端微调虽然少漏 12 帧，但只多匹配 2 帧，远离候选的输出增加 10 帧，不能把更多输出直接称为更好。

官方基础权重未变，四组非训练参数及 BN 状态前后相同；派生参数使用 `weights_only=True` 安全重载，与训练后完整模型逐值一致。float32 特征缓存与原网络前向逐值一致，每组 17 次未命中/55 次命中。四组训练核分别约 8.75、19.07、7.98、18.78 秒，含全部对照推理的 run 约 184.94 秒；这是本机小样本计算耗时，不是手机性能结论。所有拟合结束后才解析检查标签，结束时再次核验冻结输入摘要。主智能体独立重算全部 2,880 行，表格、分母与产物摘要一致。

复现命令使用本轮冻结的私有协议；目标目录必须是新的目录，避免覆盖历史产物：

```sh
BALL_TUNE_PYTHON=.local/speed-training/tracknet-smoke-20261028/venv/bin/python
python3 scripts/ball-tune-data.py --self-test
"$BALL_TUNE_PYTHON" scripts/ball-track-tune.py --self-test
"$BALL_TUNE_PYTHON" scripts/ball-track-tune.py prepare \
  --protocol .local/speed-training/ball-tune-20261029/model/protocol-proposed-v1.json \
  --output .local/speed-training/ball-tune-prepared-new --diagnostic-agent-labels
"$BALL_TUNE_PYTHON" scripts/ball-track-tune.py run \
  --prepared .local/speed-training/ball-tune-prepared-new \
  --output .local/speed-training/ball-tune-run-new \
  --execute-frozen-protocol --diagnostic-agent-labels
```

本轮支持继续验证固定裁区及连续轨迹关联，并补充高速、不同机位的独立人审片段。当前训练仍集中在同一机位的三段发球窗口，时间相关性很强；三维轨迹、同拍教师绑定、物理速度参考和手机端性能均未解决，不能把上述点位匹配换算成球速误差改善。

本轮对照页在 `ball-tune-20261029/view/`，本机服务地址为 `http://127.0.0.1:8921/`。16 段同视野原始/微调视频均实际解码 120 帧、8 秒、1920×652；训练源按 15 fps 展示为 4 倍慢放，检查源为约 2 倍慢放。固定每窗第 0/10/64/72/80/88/95/110 帧，共 32 个源帧，生成四种配对的 128 张静图及 32 张六组核验图。默认展示整图末端解码方案，选择在结果之前已固定；所有组均可查看。

Astra 实际看完 32 张六组核验图，确认既有正确球候选，也有网前球仍漏掉、候选跳到球员头部或球拍的情况。例如训练 006 第 88/95 帧六组均存在错认；检查源第 88 帧三组整图均无输出、三组裁区均有输出。预定检查静帧没有直接展示整图微调从 21 到 31 的增益，该增益来自其余连续标签帧的完整统计，未为展示效果改选静帧。主智能体另看三个固定核验图及浏览器配对画面。未知标签和未标帧均未根据预测补标。

## 2026-10-29：整体 goal 启动后的关联、几何与 Core ML

目标是完整独立测速链在冻结验收集上逐拍相对误差均 ≤20%，有效速度覆盖率 ≥90%、逐拍匹配精确率 ≥95%，并完成原生集成。最终主集合至少 100 个独立人审击球、3 次独立拍摄、2 种机位/条件，真实 1080p60，覆盖发球、高速来回、远端小球和遮挡。以下工作是朝该目标推进的开发证据，尚未达到验收。

### 严格验收与当前缺口

新增 `scripts/speed-acceptance.py`：绑定 reference、完整 prediction 与 speed-blind matching 三份输入；同拍时间容差必须提前冻结，按原整数 PTS 精确检查，不能按速度相近匹配。正确匹配且有限速度的拍数除以全部预先合格参考拍数得到覆盖率；匹配精确率的分母包括完整计分区间内全部 accepted 事件，多报、错配、重复和歧义不会消失。明确预测为 0 时相对误差为 100%，未知保持 null；任一有效输出超过 20% 就不通过，不能用平均值掩盖。

正式验收需要独立人审及来源/会话关系、冻结与盲测记录、运行依赖/许可、实际 Core ML/原生链与设备证据。报告器使用显式绑定的外部审核索引核查制品，索引本身不证明人类身份、物理真值或许可；工具不会生成/批准该索引，也不会把 agent/UI 标签升成人审。

本次只读审计 Downloads 的 6 个相关视频和已有导出：5 个主视频 SHA 与旧记录相同，另 `test.mp4` 仅约 3.77 秒、720p30、来源关系未知。现有接近 60 fps 的两个来源族都已参与开发，`single-test` 仍是 `test` 的完整前缀。4 份教师 XLSX 仍只对应 223 条待审伪标签；新增的一条球点导出为 `ui_test`。可实证的独立 1080p60 最终来源和独立人审有效拍均为 0。001 本轮没有打开画面，但相邻项目的历史记录表明它曾被分析，且只有 30 fps，不能无条件当作全新主验收集。

最终审计在 `.local/speed-training/acceptance-audit-20261029/final-v5/`，`LATEST.json` 绑定最终脚本和制品摘要。20 项门槛均为 `incomplete`，误差与事件指标为 null；这表示未进行合格的最终测速测试。仍需至少三次未参与开发的原始 1080p60 拍摄及来源关系、独立审核资料，已向用户询问本机路径。

```sh
python3 scripts/speed-acceptance.py --self-test
python3 scripts/speed-acceptance.py audit --workspace "$PWD" \
  --downloads ~/Downloads --output .local/speed-training/acceptance-audit-new
```

### 多候选与轨迹关联

新增 `ball-track-associate.py`。预注册原始开源模型的 full/中心 80% ROI × 阈值 0.1/0.3/0.5 六组条件，每帧保留最高 peak 的最多 20 个连通候选；比较同阈值最大区域、最高 peak、仅用过去的恒速关联和含未来路径的 beam 关联。关联门控采用真实时间差；缺失保持 None，不插值，遇到断层或换窗口重置。模型八帧与背景仍包含未来信息，只有关联层的过去规则可称因果，不能称整个检测链实时。

现有 480 帧和 192 标签均明确转为开发材料。166 个可见 agent 候选点中，按 1280×720 等效坐标 ≤10px 统计：

| 条件 | 最大区域 | 最高 peak | 过去关联 | 离线 beam | 已保存候选框中心的 oracle |
| --- | ---: | ---: | ---: | ---: | ---: |
| full >0.1 | 71 | 104 | 105 | 89 | 131 |
| full >0.3 | 98 | 102 | 102 | 119 | 123 |
| full >0.5 | 80 | 80 | 81 | 81 | 81 |
| ROI >0.1 | 84 | 109 | 113 | 97 | 131 |
| ROI >0.3 | 103 | 102 | 86 | 86 | 110 |
| ROI >0.5 | 94 | 94 | 94 | 94 | 102 |

Oracle 依赖标签，只表示本轮 topK 框中心表示下的候选上限，不是算法成绩，也不是所有热图解码方法的绝对上限。六组全部保留；ROI >0.3 的关联发生退化，不能隐藏。

full >0.3 在三段 60 fps 开发窗口的 134 个可见候选中，最大区域匹配 66、无输出 23、>20px 偏离 45；离线 beam 为匹配 87、无输出 43、偏离 4。它以更多空值换取更少错认，并实际补回部分正确球。单段慢球的 32 点两者都匹配，不把该片段的贡献混作高速球改善。当前仍有大量漏检，关联不能补齐没有保留下来的候选。

产物在 `.local/speed-training/ball-association-20261029/`；0.5 两视野的 960 次最大区域输出与上一轮对应原模型逐点相同，基础权重和全部冻结输入未变。独立复算 72 个配方/开发子组/算法组合一致，逐窗统计、每帧候选和全部选择保留。`view/` 有六张预定 32 帧拼图，oracle 没有画成实际预测。`video/` 是开发统计之后选择 full >0.3 的最大区域/离线 beam 示例：四个完整窗口各 120 帧、8 秒、1920×632，全部实际解码；明确不是留出证明。生成脚本为 `ball-association-view.py`。

```sh
BALL_RESEARCH_PYTHON=.local/speed-training/tracknet-smoke-20261028/venv/bin/python
"$BALL_RESEARCH_PYTHON" scripts/ball-track-associate.py --self-test
"$BALL_RESEARCH_PYTHON" scripts/ball-track-associate.py prepare \
  --protocol .local/speed-training/ball-association-20261029/protocol-proposed-v1.json \
  --output .local/speed-training/ball-association-prepared-new
"$BALL_RESEARCH_PYTHON" scripts/ball-track-associate.py run \
  --prepared .local/speed-training/ball-association-prepared-new \
  --output .local/speed-training/ball-association-run-new --execute-frozen-protocol
```

### 独立三维数学模块

新增 `ball-flight-fit.py`，只接受明确的米制相机 K/R/t、已去畸变原像素、源 SHA 绑定、真实 PTS、身份确认且非插值的观测，以及静态机位和无碰撞分段声明。以射线约束初始化六参数，再优化固定重力的像素投影；记录正深度、地面检查、按时间跨度缩放的 Jacobian、收敛状态、局部噪声敏感性和深度起点族的一致性。详见 [几何设计](independent-speed-geometry.md)。

当前模块输出的 `speed_kmh` 始终为空；内部 `candidate_speed_kmh` 仅供数学诊断。未完成的相机、触球时刻及阻力/旋转模型误差不能由低重投影残差抵消，十个同族深度起点也不证明解唯一。未知身份、插值、错误时间基准或来源、原始畸变像素等会拒绝。

预注册的 202 个合成案例保存在 `.local/speed-training/independent-flight-20261029/`，初版和修订结果均保留；最终 `numerical-results-v2.json` 与脚本摘要一致。精确无噪声案例恢复生成初速；0.8 秒/49 点/2px 噪声的全部 100 次内部速度绝对差中位 2.354、P90 6.382、最大 11.554 km/h，其中 79 次仅数学诊断、21 次被门控拒绝。0.1 秒/7 点的 100 次全部拒绝；焦距错 10% 的单例仍可获得低画面残差而偏差约 7.712 km/h。以上都不是用户视频或 S家 App 精度测试。当前四个真实窗口均因缺少相机标定返回空值，没有生成真实球速。

```sh
"$BALL_RESEARCH_PYTHON" scripts/ball-flight-fit.py --self-test
"$BALL_RESEARCH_PYTHON" scripts/ball-flight-fit.py \
  --input /absolute/calibrated-flight-input.json --output /absolute/new-flight-diagnostic.json
```

### 开源基础网络的 Core ML 可移植性

新增 `ball-track-coreml.py`，使用新的隔离环境固定 coremltools 9.0、PyTorch 2.7.0、NumPy 1.26.4、Pillow 11.3.0、OpenCV 4.11.0.86，没有修改旧冻结环境。官方 MIT 基础模型转换为 FP32 MLProgram，静态输入 `[1,27,288,512]`、输出 `[1,8,288,512]`，最低目标 iOS 17/macOS 14。最终 `.mlpackage` 为 45,379,779 字节，保存在 `.local/speed-training/coreml-portability-20261029/attempt-03-isolated-float32/`，不是已经集成的测速模型。

Mac CPU_ONLY 实际运行四个旧开发窗口首八帧和四种预注册合成输入，共 64 张热图、9,437,184 个像素。主智能体独立从原始 npz 重算：最大绝对差 `8.106231689e-6`，平均绝对差 `1.754002112e-8`；阈值 0.1/0.3/0.5 均为 0 像素翻转、0 最大区域候选框变化。逐包文件 SHA、输入和转换脚本摘要复核通过。这是基础网络的数值比较，未检验完整关联或三维测速链。

共保留三次尝试：第一次 PyTorch 2.8 转换及预测完成，但安装版转换器只声明最高测试 2.7，警告未隐去；第二次 2.7 同进程在 one 案例原生退出 139，不能计通过；第三次把 Torch 参考计算与每次 Core ML 预测放到独立进程后完整通过。没有证据确定第二次崩溃的根因。旧运行环境、App 后端和打包资源未修改，尚未验证 iPhone 实机、最低系统实际运行或实时负载。

```sh
BALL_COREML_PYTHON=.local/speed-training/coreml-portability-20261029/venv/bin/python
"$BALL_COREML_PYTHON" scripts/ball-track-coreml.py --self-test
"$BALL_COREML_PYTHON" scripts/ball-track-coreml.py run \
  --output .local/speed-training/coreml-portability-new --precision float32
```

## 2026-10-29：Swift 原生预处理、模型与帧包诊断入口

新增 `Sources/CourtCore/IndependentAnalysis/` 三个共享模块：

- `IndependentBallPreprocessor` 接收明确像素格式、行宽和坐标空间的自有 RGB8 缓冲，执行整数 ROI、Pillow BICUBIC 等价缩放和背景+八帧的 NCHW 归一化。不解码、不计算背景，也不保留相机缓冲。
- `IndependentBallModel` 显式加载 `.mlpackage` 或 `.mlmodelc`，固定 CPU_ONLY，检查 Float32 类型、形状、连续 strides、数值范围及有限性；输出复制后的八张热图和可选的 >0.5 最大区域候选。初始化/输入/输出异常不会伪造结果。
- `IndependentBallCandidateBank` 提取 >0.3 的八连通分量并保留 topK20；`IndependentCausalBallTracker` 用原 PTS 差和过去两点作图像运动关联。换源、坐标变换、缺口或异常会重置，缺失保持 nil。它不推断球身份或物理速度。并列排序使用 raster seed，与 OpenCV 的版本相关 component ID 不总一致，是声明的新原生开发基线。

### 实际对照与版本核验

Swift/Mac 实际编译官方基础 `.mlpackage`，并重载 `.mlmodelc`；四组真实开发输入与四组合成输入，共 64 张热图、9,437,184 像素，与冻结 Python Core ML 输出逐字节一致，>0.5 的候选框也无变化。对 PyTorch 的最大数值差仍为前轮的 `8.1062e-6`，不能把该数字当球速误差。证据在 `.local/speed-training/native-ball-20261029/model-parity/`。

原生 RGB 缩放参考固定为 Pillow 11.3.0 / NumPy 1.26.4：25 个同 RGB 缩放案例字节差为 0，四个真实窗口 full/ROI 的 8 组完整 Float32 张量逐位一致。另查 Pillow 13 同 RGB 结果，这 25 例也一致，不能由此推定所有版本/所有图像相同。**JPEG 解码不等价**：ImageIO→显式 sRGB 与 Pillow RGB 在原尺寸最大字节差 15–39，缩放后 full/ROI 最大差 4–19，平均绝对差约 0.137–0.430 字节。因此，RGB→张量一致性没有证明 JPEG/视频→张量整链一致。证据在 `native-ball-20261029/preprocessing/`。

本轮同时核对旧实际收据：`ball-tune-20261029/model/prepared-v1/receipt.json` 的环境已经是 NumPy 2.5.4、Pillow 13.0.0、OpenCV 5.0.0、PyTorch 2.15.0；当前读取值相同。旧开发环境不是转换用的 11.3 环境，文档此前将其他诊断环境的 NumPy 2.3.5 沿用至该阶段的表述已更正。冻结制品没有重写，也未通过安装修改旧环境。

### 模型清单与暂存

`assets/independent-models/tracknetv3-base-v1/` 只有文本 manifest、上游 MIT 原文及说明，绑定三份 `.mlpackage` 文件的大小/SHA、原 checkpoint/源码/转换版本、输入输出和离线背景条件，不包含大型权重。`prepare-independent-ball-model.py` 以显式源路径核验并原子暂存到新目录，拒绝缺/多文件、空的额外目录、LFS 指针、symlink、路径穿越、SHA/大小/声明不符或覆盖既有路径；失败只清理本轮临时目录。

真实包已暂存到 `.local/speed-training/native-ball-20261029/staged-model/`，45,379,779 字节的三份文件及 MIT 原文复制后复核一致。清单明确是未通过精度/iPhone/球速验收的研究探测器；暂存不自动改变 App 默认模型。Pillow 缩放适配的完整 MIT-CMU 许可也已保存在 `Sources/CourtCore/Notices/Pillow.txt` 并作为共享资源打包。

```sh
python3 scripts/prepare-independent-ball-model.py --self-test
python3 scripts/prepare-independent-ball-model.py stage \
  --source .local/speed-training/coreml-portability-20261029/attempt-03-isolated-float32/TrackNetV3Base.mlpackage \
  --manifest assets/independent-models/tracknetv3-base-v1/manifest.json \
  --destination .local/independent-ball-new
```

### 原生帧包诊断

新增命令：

```sh
swift run -c release court-analyze independent-frames \
  /absolute/frame-manifest.json /absolute/staged-model /absolute/new-output.json
```

输入是背景+八帧组成的紧密 RGB8 文件，严格顺序为 background/frame0/…/frame7，总长 `9×width×height×3`。JSON 字段：`schema_version=1`、`source_sha256`、`source_window`、`nominal_fps`、`width/height`、相对的 `stack_file` 及 SHA、八个原始整数 `frame_pts`、`time_base_numerator/denominator`、可选的整数 `roi_xywh`，背景声明必须为 `offline_frozen_native_rgb_median48`。不要把稀疏选图拼成八帧时序，遇到非递增或超过名义帧周期 1.5 倍的间隔会拒绝。

命令校验帧包、模型字节和许可，在推理前后复核模型清单；输出保留真实 PTS、图像候选和原因，`speed_kmh=null`。它是 owned-RGB 适配器，**不读取原视频、不证明该帧包的来源声明或拍摄参数真实，也尚无触球事件/合格三维测速**。

四个真实开发窗口首八帧已执行整条原生链，共 32 帧；输入张量与冻结 Pillow 参考一致，输出热图与对应 Python Core ML 输出逐字节一致。该 32 帧的原生过去关联位置也与旧 Python causal 选择相同，不能推广成全局并列规则一致。六个负向 CLI 检查（错 hash、重复 PTS、路径穿越、不足八帧、非法 ROI、已有输出）均拒绝，未覆盖原结果。最终原生运行、源码和二进制快照在 `native-ball-20261029/cli/validated-current/`。

本轮 `swift test` 共 77 项，72 通过、5 跳过、0 失败；原生模型真实对照及私有预处理对照另外显式启用通过，跳过项不算通过。新三个共享文件的 iOS17 arm64 SDK 类型检查通过；Mac Release App 构建成功，Pillow 通知确实进入资源包，但默认模型仍为旧分析集合。尚未进行 iPhone 实际运行、独立采集链接入或完整球速验收；20% 逐拍目标保持未完成。

## 2026-10-29：原视频输入、过去背景与原生追踪

### 输入与时间边界

新增共享的 `IndependentVideoReader`，用 AVAssetReader 将显式本地视频转换为自有、紧密排列、未旋转 RGB8；逐行处理 BGRA 行距并重排通道，输出原 CMTime PTS/duration/DTS 和来源/解码颜色标签。缺失 duration/DTS 保持 invalid，非 identity preferredTransform 明确拒绝，颜色解码与 FFmpeg/Pillow 的等价性尚未建立。

测试实际发现：把 AVAssetReader 的 timeRange 起点设为源帧内部时，它会把该帧 PTS 裁成请求起点。因此实现从轨道起点顺序解码、按原 PTS 做半开区间筛选；每个样本单独释放临时对象，不保存前段画面。晚段存在顺序解码开销，报告分别保存总解码样本、丢弃前段样本和实际返回帧数；结束边界样本可能计入解码总数。不能用这些计数差额直接宣称丢帧。

新增 `IndependentBallWindowAssembler` 的 `prefix_median48_resized_rgb` 策略：先对48张真实连续过去帧执行既有 RGB 缩放，再逐字节求偶数中位数并向下取整，随后冻结背景；每8张后续真实帧输出一批。预热期间最多保留48张512×288 RGB，约21.23MB；背景就绪后只保留1张背景和至多7张待满帧。换源、尺寸/ROI改变、非单调或超过1.5名义周期的断层清空全部时序状态，尾部不补帧；调用方在段号变化时同时重置关联器。

**这是新的输入策略**，不同于历史“全窗口均匀48张原尺寸图先中位数、后缩放”。它只消除了背景对后续推理帧的依赖，八帧网络仍有最多7帧前视等待：60fps时约117ms、30fps时约233ms，另加实际处理耗时。逐条结果保存 `available_at_pts` 和实际等待时间，没有宣称零延迟实时推理。

### 原生视频命令与冻结协议

```sh
swift run -c release court-analyze independent-video \
  /absolute/video-protocol.json /absolute/staged-model /absolute/new-output-directory
```

协议字段为 `schema_version=1`、绝对 `video_path`、`source_sha256`、`source_window`、`nominal_fps`、`decode_start/decode_end`、48个 `expected_warmup_times`、完整八帧组的 `expected_inference_times`、可选整数 `roi_xywh` 和 `export_resized_rgb`。每个时间对象为原始整数 `{value,timescale}`。程序按有理时间逐帧核对，不能用按帧号生成的时间替代源 PTS；研究入口限制解码范围最多120秒、目标最多7200帧。

源视频与模型字节在运行前后都校验，结果先写本轮临时目录，成功后发布到新目录；已有结果不覆盖。输出含所有源 PTS、背景/张量/热图摘要、候选银行、过去关联位置、等待时间及 `speed_kmh=null`。可导出实际缩放RGB及首批浮点输入/输出以供独立核对。尚无触拍定位、可信标定或合格三维速度，因此没有公开速度值。

四个协议保存在 `.local/speed-training/native-video-20261029/protocols/`。每个原120帧开发窗口之前另取48个真实连续源帧预热；取帧清单在推理前冻结，原120帧不因热身而缩小。源 packet PTS 先与原窗口对齐，运行时再逐一验证实际解码 PTS；未读取保留的001来源、未产生新的正式验收数据。

### 实际数值与定位结果

四窗共672个实际返回源帧，其中192帧为预热、480帧为目标，分60个八帧组；全部原 PTS 与冻结清单一致。`ball-native-video-audit.py` 从实际导出的缩放RGB独立重算四张48帧中位背景及全部60个 NCHW 张量，均逐位相同。四窗首批共32张热图、4,718,592个像素与 Python Core ML CPU_ONLY 逐位相同；阈值0.1/0.3/0.5均零翻转。其余批次记录热图摘要，未导出全部热图来冒充已做Python逐像素对照。这些检查不证明 AVFoundation 和历史 FFmpeg/JPEG 解码相同。

仍使用此前192个agent候选（166可见、26未知），按1280×720等效距离计算，全部缺失保留在可见点分母中：

- eval-002：32/32在10px内，0缺失、0个>20px偏离；48候选中的16个未知另列。
- train-006：16/48在10px内，16缺失、16个>20px偏离。
- train-007：16/40在10px内，19缺失、5个>20px偏离；8个未知另列。
- train-008：31/46在10px内，15缺失、0个>20px偏离；2个未知另列。
- 合计95/166在10px内（57.23%），50缺失、21个>20px偏离。相同可见点范围的旧 full >0.3 / causal_cv 为102/166（61.45%）、44缺失、20个>20px偏离。

新路径没有改善此项开发指标。解码/色彩、背景及并列规则同时改变，不能把退化完全归因于某一因素；优先实验是固定解码和训练输入后比较过去背景，并针对误认/漏球适配训练。慢球检查的32点仍全匹配，不能代替高速或跨拍摄泛化，更不是32个独立击球。主智能体另从原始JSON独立重算全部166点，计数一致；所有速度指标仍为null。

`ball-native-video-view.py` 生成四段各120帧/8秒/15fps的私有对照视频，位于 `native-video-20261029/view/`。两侧均显示本次实际512RGB的放大图，左侧只叠加旧 causal_cv 点位，右侧为原生点位；标签明确agent候选、无速度、历史输入不同及慢放倍数。全部480帧完整解码检查通过，失败例保留，未把用户画面写入仓库截图。

### 内存与端侧边界

首次完整CLI的峰值RSS约2.3–2.5GB。分阶段独立进程复现表明：原FileHandle分块摘要缺少局部autoreleasepool，同一1.775GB源文件仅哈希就达到1.791GB RSS；每块读取/更新放入pool后降至14.4MB，源SHA相同。CLI已修复分块哈希及每个返回帧的临时对象释放，并保存修复前后的完整运行，不把原峰值归为模型推理需求。

两步修复后分别重跑相同四个冻结协议，未改权重、输入或关联参数。最终 `runs-v3/` 的四窗完整进程峰值RSS约480.7–543.7MB，672条输入记录、480条逐帧输出和全部60组背景/张量/热图摘要与初版一致。该峰值仍包括本机解码、RGB导出、JSON诊断与模型，不能等同手机推理占用。完整回放的墙钟约11.2–44.8秒，包含从源轨道起点解码至所选晚段的成本；不是固定实时吞吐。源码和不可变原生二进制摘要绑定在 `run-v3-receipt.json`，旧两次结果保留。

独立已编译模型的三次CPU预测约149/131/131ms，进程峰值RSS348.9MB；另一次 `.all` 请求输出摘要不同，未建立数值等价，也未测实际算子设备。均为M4 Pro Mac的少量诊断，含缓存影响，不证明iPhone、ANE、持续吞吐、温升或整体应用内存合格。诊断在 `.local/native-video/benchmark/`，完整视频结果和修复回放在 `native-video-20261029/`。

本轮共享代码已完成真实 iOS arm64 编译；生成工程仍打包旧21模型/213文件，Pillow notice实际进入App资源包。没有替换默认后端、安装或启动iPhone。最终独立人审验收集、事件/标定/三维测速和真实采集集成仍未完成，逐拍20%目标保持未完成。

## 2026-10-29：固定原生过去背景的两组训练

本轮新增 `scripts/ball-causal-tune.py`，固定前轮实际导出的 AVFoundation RGB、前48帧背景、全视野、原始PTS及 >0.3/top20/过去帧关联，只改变模型参数。仍为已看过的开发数据：三个1080p60窗口中134可见agent候选/10未知用于监督，另一720p30慢传球窗口32可见/16未知只作开发对照。48张预热图不作为训练目标，所有未标或未知的输出通道损失mask为0；它们的输入画面仍提供八帧上下文，不能声称完全不参与模型学习。没有新的独立测试或真人标签。

### 冻结与训练前核验

训练前先保存 `causal-tune-20261029/intent.json`，再生成、审查并冻结 `protocol-v1.json`；源、输入、旧helper、runner、运行环境、标签、序列、超参数与评价规则均绑定摘要。Astra发现初版只报告数值差、没有把它接入门槛，已在实际运行前修复并增加边界自检。实际训练前要求：

- 全60批 NCHW 输入摘要一致；首四批32张真实热图最大绝对差≤1e-5且 >0.3 无像素翻转。
- 全480帧完整有序候选银行和过去关联逐帧对应原生结果；peak/mean/代价容差1e-5，框、面积、raster ID、选点与空值必须一致。
- component identifier取分量实际最小前景线性索引+1，不把OpenCV版本相关label当原生raster seed。主智能体先用原生首32张原始热图直接验证新解码器/关联器，全部一致，再执行实验。

实际Torch2.15 CPU官方base通过上述门槛；首四批最大绝对差分别约2.62e-6、5.38e-6、4.52e-6、3.69e-6，0.1/0.3/0.5均无翻转。其余56批只有原生热图摘要和完整候选/关联对照，未伪造逐像素误差上界。Torch与CoreML浮点摘要不逐位相同，不妨碍已明确预算内的对齐。

### 固定运行

两组分别从相同MIT官方基础模型开始：`head_only`训练520参数，`decoder_head`训练末解码块与输出层共148,232参数。固定 CPU Float32、4线程/interop1、seed20261029、Adam 1e-4、72步、4096MiB冻结特征缓存、原 `balanced_wbce`。BN保持eval，运行缓冲及所有未训练state前后完全相同；decoder内BN affine属于允许训练参数，不能称全部BN state不变。

17个监督八帧组按冻结顺序循环，每fit共568次监督帧使用，但唯一可见训练候选仍为134个；其中102个各使用4次、32个各5次。缓存键绑定完整输入/背景摘要、背景策略、冻结前缀state、模式及dtype。每个17组首次与最终权重均实际核对缓存suffix与原完整forward逐位一致；每步检查未知输出梯度为0、有限loss/梯度和冻结参数；最终delta checkpoint用 `weights_only=True` 重载后完整模型state与实际训练结果相同。只保留第72步权重，没有按效果选中间checkpoint或追加ROI/阈值/seed。

两组训练核耗时约11.65秒/21.80秒，含输入核验、基线和三模型全部推理的进程墙钟约79.88秒、峰值RSS约6.65GB；这是M4 Pro上的训练研究进程，不是手机推理负载。官方模型和旧helper均未修改。两个派生delta权重、完整日志及1,440条逐帧输出在 `.local/speed-training/causal-tune-20261029/run-v1/`。

### 全量开发结果

所有匹配均按1280×720等效距离，分母包含无输出，未知不作负例：

- 官方base：≤10px为95/166，缺失50，>20px偏离21；训练侧63/134，慢球32/32。
- 输出层72步：≤10px为97/166，缺失48，>20px偏离21；训练侧65/134，慢球32/32。两点改善均来自train-008（31→33/46）；其他两训练窗口仍16/48、16/40。通过预先声明的开发改善规则，但幅度很小。
- 末解码块及输出层72步：≤10px为89/166，缺失38，>20px偏离39；训练侧57/134，慢球32/32。train-008改善到38/46，但train-007从16/40降至3/40；按冻结规则失败。减少无输出没有转化为更可靠的球点。

存储top20候选的oracle ≤10px分别为115、117、126/166，它使用标签选择最近候选，**不是算法成绩**，也不是所有解码方法的理论上限。decoder候选可恢复性增加而实际过去关联退化，提示候选排序/身份选择与错误峰抑制都需检查；不能把此结果简化为“加大模型即可解决”。两fit全量保留，未自动选择或发布模型，派生权重未转换、打包或替换App。

Astra另从1,440条逐帧输出和192条原候选独立重算计数，核验25个完成制品、700个冻结输入与权重重构，均一致。对保存热图中每模型24个可见训练帧分析：base的平均正项约2.519、全图平均负项仅1.97e-5；decoder为1.630和3.50e-5。远离候选点的最高分中位数从0.296升到0.354，超过0.3的帧由12增到16/24。相应logit解析梯度通过96个有限差分检查；没有重新神经前向或训练。它支持“全图负项平均可能稀释高分干扰物”的假设，但不能证明全部退化原因，也不能外推到未保存热图的帧。

下一项候选干预是保持正项、输入、72步及评价不变，仅把负项改成固定的全图与高分错误区域混合，排除已有高斯目标3σ区域后取top32负损失。该方案尚未执行，须另建冻结实验；本轮没有事后追加试验。独立审计与分析位于 `causal-tune-20261029/independent-run-audit.json` 和 `failure-analysis.json`。

`ball-causal-tune-view.py` 生成四段三列对照视频（base/head/decoder），各120帧、1920×600、15fps、8秒，输入RGB、背景、原PTS和关联规则完全相同。画面明确agent候选、无速度、最多7帧前视及慢放；未标/未知不补坐标。全部480帧完整解码通过，主智能体实际查看固定train-006第10帧错误追踪及eval-002第72帧的吻合，文件在 `causal-tune-20261029/view-run-v1/`。

```sh
BALL_DEV_PYTHON=.local/speed-training/tracknet-smoke-20261028/venv/bin/python
"$BALL_DEV_PYTHON" scripts/ball-causal-tune.py --self-test
"$BALL_DEV_PYTHON" scripts/ball-causal-tune.py propose \
  --runs-root .local/speed-training/native-video-20261029/runs-v3 \
  --native-protocols .local/speed-training/native-video-20261029/protocols \
  --old-manifest .local/speed-training/ball-tune-20261029/data/manifest.json \
  --train-labels .local/speed-training/ball-tune-20261029/visual-audit/train-agent-labels.json \
  --eval-labels .local/speed-training/ball-tune-20261029/root-audit/eval-labels.json \
  --intent .local/speed-training/causal-tune-20261029/intent.json \
  --intent-sha256 1988bae9255256bf64d9d21a56771f7934397c5230eb6d90ec35cbfeae0879ec \
  --output .local/speed-training/causal-tune-new-protocol.json --diagnostic-agent-labels
"$BALL_DEV_PYTHON" scripts/ball-causal-tune.py run \
  --protocol .local/speed-training/causal-tune-20261029/protocol-v1.json \
  --output .local/speed-training/causal-tune-new-run \
  --execute-frozen-protocol --diagnostic-agent-labels
```

重新propose会重新核验输入与工具；冻结后改文件会拒绝执行。以上重跑是相同开发诊断，不能产生新的独立证据。runner自检7项、查看工具自检4项均通过、0跳过/失败。本轮没有改Swift/默认后端，未重跑Swift/iOS/UI或实机；新派生权重尚无CoreML/原生数值验收。测速仍缺事件、标定、合格三维速度和独立人审验收集，所有速度指标为null。

### 来源缺口复核

额外检查Downloads中16个此前未记录视频的容器元数据，发现两段1920×1080/约59.94fps导出候选，但容器帧率不证明原始60fps采集。通过只读旧项目任务数据库和精确导出manifest，085b4649…文件SHA/大小及导出来源均绑定到single-test.MOV，再到test.MOV已知前缀族，不能新增独立会话。d3ceb4e4…（11.04秒）来源仍未知，未开画面或加入任何集；有WAL的数据库采用immutable只读，未命中不代表记录不存在。保留001没有打开。

当前223条 S家 App 击球伪标签的真人review列仍空，192球点仍全部agent；新增明确真人审核为0，合格未见最终1080p60来源仍为0。审计分别在 `causal-tune-20261029/data-availability.json` 与 `lineage-audit.json`，没有以导出文件数量替代独立拍摄会话数。

## 2026-10-29：单次高分负例实验及停止微调

根据上轮保存热图的负项稀释迹象，新增 `ball-hardnegative-tune.py`，只执行一个预先冻结的decoder_head实验。输入、背景、17批/568次监督、原始PTS、seed20261029、Adam1e-4、72步末权重、CPU Float32/threads4/interop1、缓存与BN策略全部不变，从官方base独立起步；没有继续旧decoder权重、重训对照、改ROI或阈值。唯一改变为：

```text
L_new = 0.5 L_pos + 0.25 L_neg_full + 0.25 mean_top32(q)
q = -p² (1-y) log(clamp(1-p, 1e-7, 1))
```

仅在已有confirmed-visible监督帧挖掘，候选像素严格位于既有目标高斯3σ椭圆之外；按q降序、热图raster索引升序稳定取32项，gather的q保留梯度。未知/未标整帧无挖掘、损失和输出梯度为0；这没有新增经过人审的无球标签。全部旧helper与制品冻结，协议绑定729个文件及7个依赖。新runner7项自检通过、Astra独立源码/摘要审查通过后，主智能体冻结protocol SHA `a04034b5…4003` 并实际执行。

**实际结果失败**：新模型≤10px仍89/166（训练57/134、慢球32/32），缺失39、>20px偏离38；旧decoder为89/166、缺失38、偏离39。只把一个偏离变为缺失，没有新增命中，也未超过head的97/166或base的95/166。分窗仍为train00616/48、0073/40、00838/46；该结果没有隐藏难窗。按提前冻结的规则，`stop_this_small_sample_micro_tuning_direction=true`：停止这组小样本损失/seed/阈值微调，后续转向新数据或其他有证据的机制，不能在同批数据上无限续跑。

实际新fit72步、568次监督、18,176个挖掘像素（每有效帧32），8个未知/未标输出出现均无挖掘；17个缓存首/末完整forward一致，冻结参数及BN运行缓冲不变，保存后重构完整state一致。训练核约26.38秒。Astra从新480条及旧1440条输出重新播放因果选择、重算全部selector/总体/分窗及未知分母，核验729绑定文件、60输入张量、checkpoint和所有挖掘索引均一致，没有再神经前向或优化。保存的每模型24个训练帧中，top32负项均值仅由0.03621降至0.03497，正项1.62968→1.63817；不能把局部负项下降称为整体改善。

新查看工具 `ball-hardnegative-view.py`4项自检通过。实际四列base/head/旧decoder/高分负例视频保留所有4窗，各2048×512、120帧、15fps、8秒；1920条唯一模型/来源/PTS、输入和模型摘要核验及全部480帧完整解码通过。主智能体实际查看固定train006第10帧和eval002第72帧。制品在 `.local/speed-training/hardnegative-20261029/{run-v1,view-run-v1}/`，独立检查在 `independent-run-audit.json`，没有覆盖旧实验或用户录像。

```sh
BALL_DEV_PYTHON=.local/speed-training/tracknet-smoke-20261028/venv/bin/python
"$BALL_DEV_PYTHON" scripts/ball-hardnegative-tune.py --self-test
"$BALL_DEV_PYTHON" scripts/ball-hardnegative-tune.py propose \
  --previous-run .local/speed-training/causal-tune-20261029/run-v1 \
  --failure-analysis .local/speed-training/causal-tune-20261029/failure-analysis.json \
  --intent .local/speed-training/hardnegative-20261029/intent.json \
  --intent-sha256 837c3cc38595dbf479d25109fc6922ac09b3c7806d763e5f05cb4c2858db99c6 \
  --output .local/speed-training/hardnegative-new-protocol.json --diagnostic-agent-labels
"$BALL_DEV_PYTHON" scripts/ball-hardnegative-tune.py run \
  --protocol .local/speed-training/hardnegative-20261029/protocol-v1.json \
  --output .local/speed-training/hardnegative-new-run \
  --execute-frozen-protocol --diagnostic-agent-labels
```

该命令仅供复现失败实验，不是建议继续搜索。新模型未转换/打包到App；本轮没有改Swift或重跑Swift/iOS/UI/手机。球速指标仍为null，正式独立验收增加0拍。与此同时完成了未知K的地面+离面条件标定数学验证、诊断工具和一次既有开发图条件试算，范围及未获资格的原因见 [几何文档](independent-speed-geometry.md)。

## 2026-10-29：网球预训练路线与事件证据

停止上述小样本微调后，另审阅作者仓库 WASB-SBDT 和 TrackNetV4，没有使用第三方移植项目的许可或指标替代作者证据。唯一选择做私有开发评估的是 [WASB作者网球权重入口](https://github.com/nttcom/WASB-SBDT/blob/923462cacdeb3353b84ddebdedb3f4b7a8553b0f/MODEL_ZOO.md)，源码固定commit `923462cacdeb3353b84ddebdedb3f4b7a8553b0f`。NTT代码及HRNet来源通知为MIT，但未找到明确覆盖外链checkpoint的单独许可声明，不能称权重商用/分发已获核准。TrackNetV4固定commit `cb7eea7988474771ceac7e880bbffc35bfa87bca` 的[官方结果页](https://github.com/TrackNetV4/TrackNetV4/blob/cb7eea7988474771ceac7e880bbffc35bfa87bca/docs/RESULT.md)权重链接仍为占位符，未选择第三方替代。

主智能体仅从WASB作者入口取得网球checkpoint，6,102,633字节、SHA `9d391239ab10c733f8e5bfadf16ab72838e7a8ebc88e8ae2038501c03d42b4bb`。先固定字节摘要，再 `torch.load(weights_only=True,map_location=cpu)` 检查：唯一顶层字段model_state_dict，428个state张量、1,488,250个state元素，全部有限、无module前缀。该数目包括缓冲，并非可训练参数量。来源审计、下载收据及schema清单保存在 `.local/speed-training/tennis-pretrain-20261029/`；未因此获得App发布资格。

该模型与现有V3输入不同：三个时间顺序RGB原图，经作者仿射与OpenCV INTER_LINEAR到512×288，再以Torch Float32逐通道`/255 → sub(mean) → div(std)`，拼9CHW；无中位背景。固定step3，三个logits输出分别对应三帧，sigmoid一次，最多等待两帧。作者解码严格p>0.5、8连通、概率加权质心与质量求和；上一帧可见时只接受原图距离<300px的候选，再取最大质量。不能复用V3的0.3/top20/框中心/速度关联并称其为作者基线，也不能把等效720坐标用于300px门限。

同时建立 `.local/speed-training/event-review-20261029/manifest.json` 和三个固定12帧联系表，绑定train006/007/008各120张1920原图及120张旧720图、真实PTS、同一003源和同一教师XLSX快照，共720张既有图。三个软件锚分别258.130005、389.029999、27.17秒，均由导出Video Time加2秒恢复；这仅说明软件事件锚对应关系，不能当作精确触拍时刻。所有触拍、首触地与真人复核字段保持未知，素材没有变成新会话或独立验收数据。

另查到当时 S家官方产品说明的搜索索引将球速描述为轨迹上的平均速度；直接读取页面只返回JavaScript启动页。它是产品口径旁证，不能认证已有教师快照每行的计算区间，也不能据此把击后初速直接配对或乘一个固定比例。当前003快照的实际推理版本未知；96拍旧test快照的App和推理版本均未知，后来研究的 S家 App 版本不能反填这两份快照。后续必须冻结速度的时间区间与分段证据；官方宣传精度不作为本项目验收结果。

### 一次固定WASB实际对照

新增 `scripts/ball-wasb-baseline.py`，最终SHA `a12869c81583177558c12cadd247c5be99dd90136ad66565c077ab32c52853d0`。主智能体冻结最终协议 `protocol-v3.json`（SHA `ad1a62d43c24f01c083821fbb8bbbae4781062607e3b6c929b463f5bb6b78458`）后执行一次完整评估：四个既有窗、480原尺寸JPEG、160个三帧forward、无训练/阈值/ROI/相位搜索。所有原图/PTS绑定、完整候选、缺失原因、可用时刻、输入与热图摘要保留；固定每窗start0另外保存完整input及3张概率图，共4个input/12张heatmap、28,311,552字节，供不重跑网络的独立复查。它读取已绑定JPEG，不是原生视频/机位采集链验收。

首次run-v1在构造阶段失败：普通YAML字典缺少官方配置所用的属性访问，0forward/0预测。修为保留全部配置值的递归属性/映射适配后，run-v2又被线程门拒绝，仍0forward/0预测：本机OpenCV4.11 GCD中请求1线程实际报告12；请求0禁用并行后报告1，[官方线程文档](https://docs.opencv.org/4.11.0/db/de0/group__core__utils.html)也说明GCD只支持非正请求。两次失败、各版冻结runner和协议全部保留，不计成检测或速度成绩，没有更改模型配置值或据预测调整参数。

最终版本完整自检12项通过、0失败/跳过，包括一次无权重官方构造测试（该项禁止checkpoint加载及forward）。Astra额外对24张纯合成热图、25,896个组件与6个跟踪边界案例同作者实现精确比较通过；环境未安装torchvision，额外的torchvision逐位归一化对照没有运行，不能算通过。作者源码、配置与许可通知未改；实际权重使用安全加载、strict零missing/extra，完整state摘要在载入后和480帧结束时均为 `433280b05faa426b74755524e4be53d133c9c00c98c38bfbb375ca6c543fcd83`。

实际完整进程退出0、墙钟30.67秒、峰值RSS约2.01GB，研究进程并非手机或CoreML性能证明。完整开发结果按等效1280×720计算、缺失进入可见候选分母：

- WASB作者基线：≤10px为84/166，缺失68，>20px偏离14；train006为15/48、007为20/40、008为17/46，720p30慢球仍32/32。
- 旧原生V3 base：95/166、缺失50、偏离21；过去背景输出层微调97/166、缺失48、偏离21。

新路线少7个明显偏离，但多18个缺失、少11个命中，不能称整体改善，也不据此改阈值再试。输入契约、背景/上下文、重采样与关联都不同，这是各自冻结开发链的比较，不是仅替换网络的单因素实验。三帧可用时刻最多等待2帧，旧V3最多7帧；处理延时另算。166点仍是agent候选、不是166拍；26未知和288未标帧不作无球真值或从报告删除。

没有生成独立球速、新人审或最终未见会话，未转换/打包WASB或修改默认App。仍需解决现场标定/畸变与事件定义、扩大合格数据及原生端侧验收；不得把该球点结果换算为与S家的速度误差。全部真实结果在 `.local/speed-training/tennis-pretrain-20261029/run-v3/`，此前两个失败目录仍原样保留。

Astra另从原始192候选独立重算指标、重放全部480原图坐标跟踪及PTS/channel/available_at，重解480JPEG并重算全部160输入张量SHA，均一致；固定4个input字节及12张真实概率图经作者解码后的完整bank精确对应。507文件与002/003实际源视频摘要均匹配，没有再加载模型或执行forward。当前完整候选库的标签oracle≤10px为85/166，只属于这次固定p>0.5候选库的标签选点诊断，不是算法分数或其他阈值的上界。state核验以实际运行的载入后/结束时完整摘要及代码门控为证，没有谎称另存并独立重构了最终state。

私有查看脚本生成四段1280×560双列视频，各120帧、15fps、8秒；背景同为原JPEG显示，左右叠真实旧V3与新WASB选点，原PTS、各自available_at及最多7/2帧前视明确标记。960条结果及全部480帧完整解码通过，原JPEG解码RGB与WASB执行摘要逐帧一致。主智能体实际查看固定train006第10帧的旧错点/新无输出，以及eval002第72帧的两者吻合；失败窗全部保留，没有oracle或插补。3项查看脚本自检通过、0失败/跳过，媒体与收据位于 `view-run-v3/`，没有进入README截图。

复现本次固定开发评估（新输出目录；不产生新的独立证据）：

```sh
.local/speed-training/coreml-portability-20261029/venv/bin/python \
  scripts/ball-wasb-baseline.py --self-test
.local/speed-training/coreml-portability-20261029/venv/bin/python \
  scripts/ball-wasb-baseline.py \
  --protocol .local/speed-training/tennis-pretrain-20261029/protocol-v3.json \
  --protocol-sha256 ad1a62d43c24f01c083821fbb8bbbae4781062607e3b6c929b463f5bb6b78458 \
  --output .local/speed-training/tennis-pretrain-new-run
```

## 2026-10-29：扩展连续标注与采集参数证据

上轮真实WASB对照和标定敏感性属于实际进展，但没有合格球速。本轮不再在旧三小窗上搜索损失/seed/阈值，转为扩大不同击球上下文，并记录未来本App采集的相机观测。

### 12个额外开发窗口

仅从已训练/暴露的source003原族选择，未打开001或将素材重命名为独立测试。使用旧review80的45个003窗口元数据，预先固定4个teacher serve、8个nonserve；按 `SHA256(rally_group+shot_id)` 字典顺序扫描，固定配额、不同source-bound软件rally/overlap及实际半开时间区间，排除旧train006/007/008及相互重叠。选择不使用教师速度/XYZ、预测误差或图像质量；类别只作选样分层，不认证真实动作。主智能体独立重放整个筛选并冻结三文件及依赖后才重新抽帧，没有失败替补。

实际以不变 `ball-tune-data.py` 提取12×120张1920×1080 JPEG，共1440张；源003、冻结文件和依赖前后摘要一致，全部图hash/尺寸/完整JPEG解码、原整数PTS逐项对应及1428个1/60s间隔通过，fresh ffprobe独立核对全12窗通过。数据清单SHA为 `c8745e6bfe62fc9e600bf4decbc0fb6c7099d14fd8f60701a88329f98e6e62cd`；数据、提案、冻结和实际命令/收据在 `.local/speed-training/expanded-tracking-20261029/`。旧工具的未来帧中位背景描述只作为历史metadata，没有用作新的因果训练输入。

每窗固定标注24..71连续48帧，补充旧监督较少覆盖的触拍与击后初段；1440帧全部保留，其余864帧没有点位标签，不作无球负例。sol实际完成计划576帧的开发候选复核：batch1为034/027两窗96帧（91可见/5未知），batch2为其余10窗480帧（422/58），合计513可见、63未知，计划内pending=0。颜色/帧差blob只是click提案；034最初锁到球拍的提案被拒绝，038多球、024前段目标不确定和遮挡均保留unknown。坐标仅来自实际查看后接受的图像球影中心，不插值；像素不确定半径是工程容差，不是校准置信度或真实球半径。

所有记录均为agent、非human、formal/training资格false，事件/球速真值为空；这次没有训练或加载模型。未知坐标保持null、未知不是无球。主智能体在读标签后固定抽看两窗各24/40/56/71共8个原图crop，点位均落在可见黄绿色球影；该非盲抽查不认证其余帧或独立同球身份，也不提升人审资格。两个批次、逐帧查看图与SHA/PTS、修正记录和Root抽查另存私有目录。下一次学习试验须先固定因果输入、来源隔离的开发对照与训练预算，不能把这513个候选或同一003来源当作最终验收证据。

### 事件范围与教师版本复核

主智能体实际查看原006/007/008各一张contact-1原尺寸crop组（每张34..41八帧），得到仅供后续复核的宽帧支持候选：006/007为34..37，008为34..38。原始整数PTS及图SHA在 `event-review-20261029/root-event-review.json`；它们不是曝光修正后的物理触拍时间边界，触拍真值、首次触地及无碰撞飞行段仍为空，未用软件锚或球速来选时刻。此前生成的15张crop不能因文件存在就全部算作已看；未完成的子任务审查不算独立复核。

重新核对原combined配置与manifest后纠正上轮文字版本混用：003快照的实际推理版本未知；旧test的96拍快照App/推理版本均未知。后来研究的 S家 App 是另外的版本，不能反填历史教师。当前官方平均速度文案也不认证这些逐行快照的实际计算区间。

### 记录未来采集参数

新增原生 `CaptureFrameMetadata` 并串接CameraEngine→媒体管线→已有每帧编码上下文→可选header/录像JSONL。iOS仅在支持时、startRunning之前启用系统内参附件；不改防抖或1080p60格式。每帧独立读当前附件，保存原CMTime/交付尺寸/连接状态及可用的设备查询值；Mac控制不可用时保持unsupported。SIMD矩阵按原生48字节安全复制，取9个column-major逻辑值，不按36字节连续Float或未对齐指针读。非法/错配元数据只省略并附原因，不丢视频；预览不附带，没有新增队列或相机缓冲持有。

99项完整Swift测试中94通过、5按需跳过、0失败，新增metadata8项在其中全部通过；真实VideoToolbox多帧/跨流、MOV/JSONL及预览nil关联有覆盖。`court-check`、Mac Release打包、XcodeBuildMCP模拟器compile-only及无签名iphoneos SDK构建均通过。UI未变，未跑UI用例；未启动相机或验证iPhone真实K附件、180°像素对应、防抖/畸变、发热或60fps负载。两项verified始终false，默认测速模型仍未替换。

另完成已知地面H、重力与触地约束的有界联合几何研究。精确场景一般可辨识，但压力试验短13帧8/8失败，低残差也不能认证接触和相机；未新增可公开测速的joint solver。详细假设、全部失败和原生参数边界见 [独立测速设计](independent-speed-geometry.md)。本轮正式验收新增0拍，与S家的球速误差仍无合格数值，原20%/90%/95%门槛保持不变。


## 2026-10-29：扩充全网络实验与原生时钟身份桥

新工具 `ball-expanded-tune.py` 接收外部SHA绑定索引，保持旧工具、协议及标注资格不变。15个训练窗合计647可见/73未知、88个有效八帧监督组，仍全部来自003一个来源族。新增test来源开发检查先按元数据哈希冻结2发球/4非发球窗，再实际复核固定24..71：246可见/42未知，共288条agent候选。test族早已暴露于粗测速基线；不是最终盲测，也不是288个独立击球。所有原图/PTS/查看凭据经过绑定，人工与正式资格仍false。

实验意图预先固定：官方权重初始化，CPU float32、4线程/interop1、seed20261029、Adam1e-5，全参数含BN affine训练，BN运行buffer冻结；完整forward、不缓存冻结前缀，88组逐epoch固定shuffle，1024步仅取末步。旧balanced WBCE/Gaussian、unknown及未标输出mask0、全视野、>0.3/top20和过去轨迹关联不变。数据量、学习率与可训练层同时变化，只能解释整个方案。对照为官方base和旧head72，不重训对照；开发门为新来源命中严格超过两个对照、wrong均不增加，旧slow保持32/32及0wrong。这些是定位门，不是20%球速门。runner预算含1024训练、990评估和176完整安全重载验证forward，共2190次Torch forward，不包含原生输入准备或探针。

实际新增12训练窗经原生CLI返回2016帧、1440目标，独立重算180个张量均一致。base在513个可见候选上396个≤10等效px、4个10–20px、59缺失、54个>20px；未知63另列。不能仅用454个有输出点作分母，也不能把定位距离换成球速误差。

### test.MOV时间轴修复

首次六进程因FFprobe名义60000/1001与AVFoundation实际59.879852294921875不符，在FPS guard拒绝。采用已绑定的AVF值后，第二次六进程又在首warmup的PTS guard拒绝。两次均保留原协议/日志/收据；模型加载与reader启动发生在guard前，零predict需由实际首差位置补证，不能仅从通用错误推断。

只读探针完整观察BGRA38029、FF decoded38028帧；38057个压缩payload SHA在FF packets与AV compressed之间逐个唯一相同。MOV编辑偏移575/600；相同压缩身份两种raw compressed/packet时间相差581/600。全源首帧存在额外边界行为，因此没有按ordinal或统一偏移盲改。选中六窗的1008个prefix/target逐条以FF decoded PTS→packet payload SHA→AV compressed→实际BGRA PTS/ordinal关联，全部唯一、连续、不插补。六个frame24还做精确PTS无JPEG RGB对照，MAE1.883–1.887/255、PSNR41.918–41.982dB，并非解码逐位一致。

以该身份ledger派生新manifest/标签，只绑定实际原生PTS，保留original_ffmpeg_source_pts；720张JPEG的路径/摘要、288条点位/unknown/不确定性/查看证据及资格逐值不变。原冻结文件没有覆盖。Astra独立重算1008身份桥、720图SHA及六份新协议，确认选中相同编码帧。v3原生CLI仍须对全部48+120实际返回PTS逐项验证，静态桥接不代替运行成功。全部制品在 `.local/speed-training/expanded-train-20261029/` 与 `expanded-devcheck-20261029/`。

### 执行与回放

使用既有tracknet-smoke venv；最终索引及protocol须在全部原生输入完成后冻结，未完成run不能由viewer发布视频：

```sh
.local/speed-training/tracknet-smoke-20261028/venv/bin/python scripts/ball-expanded-tune.py propose --input-index .local/speed-training/expanded-train-20261029/input-index-v1.json --output .local/speed-training/expanded-train-20261029/protocol-v1.json --diagnostic-agent-labels
.local/speed-training/tracknet-smoke-20261028/venv/bin/python scripts/ball-expanded-tune.py run --protocol .local/speed-training/expanded-train-20261029/protocol-v1.json --output .local/speed-training/expanded-train-20261029/run-v1 --execute-frozen-protocol --diagnostic-agent-labels
.local/speed-training/tracknet-smoke-20261028/venv/bin/python scripts/ball-expanded-tune-view.py --input-index .local/speed-training/expanded-train-20261029/input-index-v1.json --run .local/speed-training/expanded-train-20261029/run-v1 --output .local/speed-training/expanded-train-20261029/view-v1
```

viewer仅画causal selection与agent点，缺失/unknown保留，默认7个开发窗；每窗完整120帧以15fps播放8秒，注明近似慢放而非严格源时钟。发布前核验帧数并完整解码。训练工具7项、viewer5项合成自检均通过；这些不证明训练效果。没有新增人审/未见最终会话/合格球速，公开速度和S家误差仍为空；默认App模型未替换，20%/90%/95%完整目标保持未完成。


最终输入索引已冻结为 `632447754a3f1252fdb2d7609a6daf0dcf1d2d2eeda18ea57cf7fc99ff6acdfa`；protocol为 `4460b372f5adea0f560900bdd9a184e62d197536d6db76557e1d5fb757a74c12`，schedule为 `027b0f418d6bc34e80fada2ae61d339fb39c881cfd9f9477890a225255ded85a`。v3六窗实际全部成功，156.70秒，1008帧/720目标；原生时钟身份映射及输入重放均通过，失败两轮仍保留。全22窗共有2640目标、1056前置帧及1056条agent候选，6510个输入文件绑定；train134+513、slow32、sourcecheck246可见分别统计。模型11,341,000参数，既有Python3.12.14/Torch2.15.0/NumPy2.5.4环境不变。`propose`完成时0forward/0optimizer；run-v1已启动，须先通过原生base数值/候选门及旧四窗回归才能实际反传。训练是否完成与效果以该run的当前日志、failure/completion和最终report为准，不能把已启动当通过。


**后续实际预检与数值修复**：run-v1在330个base forward后因13帧peak/mean/关联代价超过旧1e-5标量门而停止，0optimizer/0fit。全2640帧/3345候选的结构、顺序、坐标及关联决定一致，22个首批原热图max≤8.762e-6、>.3翻转0；不能外推至其他批。固定3个失败涉及批次各做一次PythonCoreML及Torch复测（额外3+3forward），raw SHA分别重现原生与run-v1；018@80整批max差2.119e-5，其余两批≤5.097e-6，24张map阈值翻转0。没有根据球点分数或教师速度选新门。

Astra独立复算代价差与-log(peak)传播残差≤约1e-15；旧peak与cost共用1e-5并非传播界。新增 `ball-expanded-tune-numeric.py` 保留原runner/helpers与失败文件：输入、22首批raw门及全量候选结构/决策门不变；peak/mean/cost差完整诊断，有限/区间仍为硬门，selected cost增加Float32还原native peak后的log残差与均值定理检查。舍入余量固定64×Double.eps×scale，非把统一epsilon调大直至通过；none两侧必须2.5。旧训练、模型、阈值、标签及唯一1024步配置不变，未来实际CoreML/端侧/球速验收仍必需，不宣称全量map或scalar≤1e-5。wrapper8项字典自检通过，当前三工具合计20通过/0跳过/0失败，不重复累计。

最后一处Float32(.3)等值拒绝边界修正与protocol-v2生成交错，run-v2因此被协议一致性检查拒绝，未创建run目录、0forward/optimizer；保留日志。最终稳定wrapper SHA为cf42fea5b2acc284ba9b3aa80e5e115c44bdceb97fe33857bb4d72fae7d7075c，Astra最终静态review无剩余阻断；重新生成protocol-v3 SHAae2dc3884d339a0b29b069f26b31ce0392062ec22fa5006eef845b8def99c46d，和v2仅policy的Float32边界声明不同。input-index-v2 SHA6950fd416f5376bce9a275ee30fb8385be129cc72a0923ef63a6d356d869188f；intent-v2 SHA4c4a2b104f412ae6f02a85165d7bbad8f4ca5ca048172b8c265c97e77a6698a3。当前实际运行是run-v3，原两次运行及协议均未覆盖。是否进入fit、完成与分数仍以run-v3.log、training-steps/failure/completion/report为准，不能凭已启动宣称训练完成或20%达标。

```sh
.local/speed-training/tracknet-smoke-20261028/venv/bin/python scripts/ball-expanded-tune-numeric.py run --protocol .local/speed-training/expanded-train-20261029/protocol-v3.json --output .local/speed-training/expanded-train-20261029/run-v3 --execute-frozen-protocol --diagnostic-agent-labels
# 仅完成后运行；输出目录必须新建
.local/speed-training/tracknet-smoke-20261028/venv/bin/python scripts/ball-expanded-tune-view.py --input-index .local/speed-training/expanded-train-20261029/input-index-v2.json --run .local/speed-training/expanded-train-20261029/run-v3 --output .local/speed-training/expanded-train-20261029/view-v3
```


**单窗事件补证**：sol仅在devcheck-sample-080实际查看全部120JPEG上下文4grid及原像素连续crop8grid，合计12图，先于新模型结果。触拍支持34..37，原FF PTS205707..205737/600，身份映射后的实际AV PTS205713..205743/600；这是可见支持区间，非曝光/rolling修正后的物理瞬时触拍真值。68..73附近无法排除触网，首次触地及完整无碰撞区间均null；37..53短段仅保留探索性视觉候选，不作为已接受飞行标签。event-080-v1内保存双时钟、120原图SHA及实际view证据；全agent/human=false/formal=false/速度null，没有更改训练或开发标签，也未读取教师速度/XYZ/事件锚或模型预测。


**本轮完成结果**：run-v3实际1024步完成，训练及完整重载复验676.49秒；88组双模型176次forward逐位相同，safe weights_only全量重载一致，51个BN buffers与官方初始化相同。Astra独立从全部原始预测和标签重算：sourcecheck base162/246、head148/246、final10/246，final缺失83、wrong145；slow从两对照32/32跌到1/32、缺失2、wrong29。训练本身也退步：old63→27/134、new396→13/513；两项冻结开发门均失败。该run的completion仅表示实验执行完毕，不代表goal/模型通过。共7920条完整预测、1056唯一标签，647可见训练帧各暴露11–12次，累计7530监督；checkpoint SHAfe60e5cab0fcf25637082823b34e1b933a63f477ea9c52e596dfcddae6a4e4f8，完整状态SHA8dcd91853046469b43b6883c03e0baf1ba92f74dbc9d600689bdcef7957935b9。独立审计额外forward为0。失败权重未转换或激活到App。

七个默认开发窗已实际渲染，每个120帧/15fps/8秒，ffprobe计数与完整ffmpeg解码840帧全通过；viewer核验全部7920预测/1056标注及2640原图，回放在view-v3/，本机只读HTTP为 http://127.0.0.1:8920/index.html（仅loopback）。这是失败Gaussian候选与base/head对照，不含任何球速估计。App打开请求为queued，不当作已可见UI验收。

**有限失败诊断**：固定旧train006@64、新train034@40、sourcecheck080@40三批，base/final各一次，共额外6次Torch forward、0反传/optimizer，所有raw SHA重现原run；82个选中源/模型/输入摘要前后不变。两训练批16个visible目标中心映射正确，Gaussian argmax每轴≤0.5模型像素（不把二维距离误写≤0.5），mask均1。相同0.3阈值下平均激活面积分别从0.0487%→5.4665%、0.0214%→5.8764%、0.01865%→4.7184%；参考点概率上升，但背景均值、组件数及错误框中心同时增加。两训练批balanced loss从.55882→.04230和.61164→.04204，实际定位却恶化；Root实际查看三张固定概率色标PNG，确见大面积场景纹理激活。不是简单的未见来源过拟合，也未发现所查批次的坐标/通道/时间错位证据。

Astra从目标函数推导质量归一后的软Gaussian点态最优并非p=y，弱尾也可能被推过0.3；低代价激活细桥能拉偏组件框中心。这支持监督目标与定位行为冲突，不证明唯一根因。固定官方源码的_get_heatmap实际为radius2.5二值disk，不能被注释中的Gaussian一词代替。完整数学、6forward图与独立结果在failure-loss-review-v1.json、failure-probe-v1/及result-audit-v3.json；不靠改变阈值/ROI/seed挽救失败权重。

**disk 目标编码对照（现已完成，结果失败）**：新增ball-expanded-tune-disk.py，仅把目标编码换为固定官方binary disk2.5及其整数栅格中心，保留原浮点坐标；visible原点按本项目显式status生成裁剪disk，unknown仍mask0，不复制作者(0,0)无球sentinel。损失公式及质量归一、数据、所有训练超参/步数/初始化/BN、阈值/关联/成功门均不变；不是完整复现作者训练配方，也不称只有连续几何形状变化。15项自检全通过，其中8项复用已计入的numeric，新增7项，当前本轮唯一自检共27通过/0跳过/0失败；20个非原点合成案例逐位等官方函数，visible原点/unknown/接线/原损失identity另检。Astra一次代码/来源审查无阻断。

intent-disk-v1 SHA88ea6ff21ea361ec0d4c5c0bd2ed5b1e81d13be293943a77c58298bd2b527196，input-index-disk-v1 SHA43a8ea961b1d49150079128872ca03c5ef93145b6c9877940a8a3073655b1618，protocol-disk-v1 SHA8bbdc63f65f1fd60352c93f09cbfe6a38174a475e7155d7f3fdfbb65bbe09637。propose0forward/0optimizer；随后 disk-run-v1 已完成预检与 1024 步，实际结果见下节。该扩充实验族的 Gaussian 与 disk 两项累计 2048 步，早期 head/decoder 等小试验另有记录，不能称整个项目此前只训练一次。仍无独立人审、未见最终会话、合格三维球速或20%/90%/95%验收。

```sh
.local/speed-training/tracknet-smoke-20261028/venv/bin/python scripts/ball-expanded-tune-disk.py run --protocol .local/speed-training/expanded-train-20261029/protocol-disk-v1.json --output .local/speed-training/expanded-train-20261029/disk-run-v1 --execute-frozen-protocol --diagnostic-agent-labels
```


## 2026-10-29：disk 对照完成，质量门失败

`disk-run-v1/completion.json` 的 complete 表示固定实验执行完毕，`development_improvement=false`、`speed_model_accepted=false`。实际完成 1024 次完整训练 forward/backward 与 optimizer step，训练及完整重载复验 682.87 秒；另有 990 次评估与 176 次完整重载验证 forward，总预算 2190 次。88 组重放逐位一致，safe weights_only 全量重载一致，BN running buffers 前后相同；这些只验证执行与制品完整性。

来源开发集的 ≤10 等效像素命中为 base 162/246、旧 head 148/246、disk final 81/246。disk 缺失 43、10–20px 为 2、>20px 偏离 120；旧慢球由两个对照的 32/32、0 偏离降至 0/32、1 缺失、31 偏离。来源改善门与慢球回归门均失败。全部 7920 条预测、1056 条 agent 候选及失败报告保留，未按有输出点缩小分母，也未重选阈值、ROI、末步或 seed。checkpoint SHA256 为 `7771cf258c49541b9c16a2342b2cd039555a4428385a852ca454fefdf719852f`，报告为 `daeeb33650ff8e10f172a8d79d2136a79a9f3517a972e71ac63bfee29b6b9e30`；私有制品位于 `.local/speed-training/expanded-train-20261029/disk-run-v1/`。Gaussian 与 disk 失败均保留，两者都未转换或激活到 App；官方开源 base 继续作为独立球点开发基线。

## 2026-10-29：固定相机条件诊断原生化

在同一 event039 的原始 PTS 与触地帧 42 假设下，自由相机联合条件解对 manual41 与既有 native BASE40 球点分别给出首观测模长 10.2442560、37.7198083 m/s。native 缺失 frame36，不插补、不按人工距离筛球；这 27.4755523 m/s 的变化是输入与自由相机条件敏感性，不是 S家或物理误差。原 H8 的留出点 7.140843>6px 失败保持不变，不能因轨迹可拟合而移除。

随后另冻结一项只用 8 个 FIT 球场地面点的相机先验试算：fx=fy、主点 (960,540)、skew=0、零畸变均为假设，不读取球点来拟合相机；2 个可见 CHECK 点只评分，误差 2.725638/1.305307px 分别落在 6/4px 工程界内。所得条件 fx=fy=1164.814265px、相机高 1.548296m 未获现场标定。固定这一相机后，manual41 与 native40 的首观测速度模长原始值为 7.7190067、7.2196152 m/s，重投影 RMS 为 1.2954962、2.8720354px。低残差和较小输入差不能认证零畸变、触地时刻、无碰撞飞行或物理速度。制品在 `.local/speed-training/native-flight-sensitivity-20261029/` 和 `ground-camera-prior-20261029/`。

`IndependentBallisticDiagnostic` 已将这个固定相机、触地中心高度约束的五参数运动核心移入 Mac/iPhone 共享 `CourtCore`，新增离线命令：

```sh
swift run court-analyze independent-flight /absolute/protocol.json /absolute/new-output-directory
swift test --filter IndependentBallisticDiagnosticTests
```

协议 schema 为 `independent-fixed-camera-flight-diagnostic-v1`，包含来源/尺寸/row-major K/R/t 及假设、原图像素或明确缺失原因、整数有理 PTS、触地时间、固定重力/球心高度/残差工程界与最多 10 次 GN 配置，以及 SHA256 绑定的证据文件。求解器不重拟相机、不插补点、不加载模型；公开 `acceptedCamera`、`velocity`、`speedKilometersPerHour` 永远为 null，所有物理、人审、正式、生产及目标验收资格为 false。raw 字段只保存首个实际观测时刻的位置、速度与代数参数，不代表触拍初速、触地速度或整段平均速度。完整字段与限制见 [几何接口](independent-speed-geometry.md#14-共享-swift-固定相机诊断接口)。

已实际运行两个原生 CLI 案例，分别保留 41 点与 40 点/缺失36；52 个证据文件在运行前后校验，包含实际相机先验、agent 包、原生 Core ML 报告及 41 张源图。两例均与既有 Python 一样在 6 次 GN 停止，模长绝差分别 4.44e-15、1.78e-15 m/s，RMS 绝差分别 1.20e-14、3.55e-15px。还验证已有输出不覆盖、错误证据 hash 和嵌套资格声明拒绝。数值对照报告在 `.local/speed-training/native-ballistic-20261029/verification.json`，SHA256 `3e442e942af3589068ed03c312177d03420b69079de9facecaf8e32b75f80bea`。

新增 12 项定向 Swift 测试全部通过、0 跳过、0 失败，覆盖已知非单位相机/重力恢复、不规则有理 PTS 与缺点、正深度与质量拒绝、秩退化、非法输入及公开空值。完整 Swift 套件共 111 项：106 通过、5 按需跳过、0 失败；跳过的是实机看板、独立 Core ML 私有夹具、Pillow/JPEG 私有夹具、公开视频标定诊断与真实模型 TLS 镜像，未算作通过。这里的两次真实输入 CLI 数值对照单独计数，不属于 12 项合成/输入门控测试，也不补足跳过的检查。

本轮新增的正式验收拍数仍为 0。没有新增独立人审或最终未见会话，APE≤20%、覆盖率≥90%、事件 precision≥95% 均未验收；默认 App 的 S家私有分析链保持不变。


## 2026-10-29：显式区间路径平均速度与单拍条件开发对照

新增共享 `IndependentBallisticIntervalDiagnostic`，给固定相机运动结果提供明确起止 PTS 上的路径平均速度与起末速度。原 `rawMotion` 的速度模长仍对应首个实际观测时刻；新均值为 `(1/Δt)∫||v(t)||dt`，不是净位移模长除以时间，也不自动等于 S家 App 旧导出标量（后续语义纠正见文末）。`evaluate(input:request:)` 在内部对该输入拟合一次并返回 `(fit, rawInterval)`，绑定相同 source、相机、原 PTS 和重力，不能由外部配入另一来源的 fit。全部原非缺失观测参与拟合，原状态、质量标记和原因原样保留；积分成功不会修复坏拟合或认证物理速度。

离线命令保持 `independent-fixed-camera-flight-diagnostic-v1` / `independent-fixed-camera-flight-result-v1`：顶层可选 `interval`，含 `start`、`end`、`knownCollisionTimes`、`collisionFreeAssumption` 与可选 `extrapolationReason`，时间沿用整数有理 PTS。提供时另外输出 `rawInterval`；省略时旧结果路径不变。`start < end <= contactTime`，结束恰在触地时取入射左极限；超出原非缺失观测首末范围（包括最后观察到触地）必须显式解释外推。已知前碰撞是硬边界，起点及原首观察必须严格晚于它，不能靠外推许可或裁掉坏点越界。入射触地竖速为正或区间端点低于假设接触高度会保留 raw 并标质量失败；无 raw、非法时间/参数或积分不能收敛则拒绝。accepted 相机/速度/球速仍显式 null，物理、人审、正式、生产与目标验收资格全部 false。实现与完整数值边界见 [几何接口](independent-speed-geometry.md#15-显式区间的原生路径平均速度诊断)。

本次在既有 source003/train007 上冻结一个弱 agent 事件绑定的开发拍。输入38..82保留全部41个既有原生 BASE chosen candidate 及缺失38/80/81/82，实际观测包络39..79；不插补、不替换球点、不重新运行网络。读取教师数值之前先冻结主触地84及端点诊断83/85，起拍36亦为弱图像假设；每例都显式声明向观察包络外延伸。三次固定相机运动拟合各核验57个证据文件，运行后先冻结报告，再读取预先固定的 S家 App 第76行标量；没有根据误差选择最好触地帧。

主84的 raw 路径平均速度为82.0182469km/h、起末速度81.1530518/84.4769758km/h；83/85的平均值为90.5161182/74.8930728km/h，三例全保留。固定教师值82.242088km/h来自003旧快照，实际推理版本未知、逐行计算区间与时间定义未核准，不能假定为路径均速。主例的0.2238411km/h、约0.27%仅是临时绝对/相对数值差，**不是正式 APE、整体误差或物理精度**；formal APE、MAPE、coverage、matching precision均为null。

相机先验复用的 strict8 图像检查仍失败（两个远底线点未通过），没有放松或重拟相机。起拍/触地、名义场地尺度、零畸变、静态机位、无额外碰撞/触网、忽略阻力/旋转均未物理认证；主区间36..84也超出原生39..79。三个 raw 代数质量通过不消除这些限制。既有来源曾参与开发，不能称未见测试；accepted/public速度仍null，human/formal/production/20%资格仍false。本次新增0次相机拟合、0次模型forward、0次训练，只有3次固定相机运动拟合。

区间模块10项最终定向测试通过、0跳过/失败，覆盖解析/独立数值golden、竖直与常速极限、极小水平速跨顶点、巨大PTS/纳秒短区间、碰撞/外推、失败质量与资格空值。合成CLI兼容/积分/拒绝3项复测通过，旧无interval报告对象逐字段不变。Astra针对最终三文件只读审查无未解决阻断项，审查本身未运行测试。该阶段完整Swift套件共121项：116通过、5按需跳过、0失败；5项仍为实机看板、独立Core ML私有夹具、Pillow/JPEG私有夹具、公开视频标定和真实模型TLS镜像，不计作通过。另三次实际开发输入CLI及独立高精度mpmath积分对照，速度均值差均小于6e−15m/s，只证明本次积分数值对应关系。

私有证据：`.local/speed-training/native-interval-20261029/` 保存最终源码审查、定向/完整测试日志；`.local/speed-training/serve007-root-20261029/` 保存意图、原相机复用失败、三份协议/报告、教师读取前冻结及 `provisional-comparison.json`。没有新增合格物理真值、独立人审或最终未见会话；20%/90%/95%及完整默认App独立测速验收保持未完成。


## 2026-10-29：无人工触地时间的六参数原生诊断

新增 `IndependentFreeFlightInput` / `IndependentFreeFlightDiagnostic.fit(_:)`，以及 `court-analyze independent-free-flight PROTOCOL_JSON NEW_OUTPUT_DIRECTORY`。输入只含固定假设相机、原始同源帧和g/r/工程门，不接受contactTime/groundTime或教师速度/XYZ；至少32个实际非缺失观测，缺失条目仍完整保留。以首个实际观测为时间原点拟合三维位置/速度六参数，拟合后才用球心高度求未来下行地面交点。QR求解与单侧Jacobi奇异值诊断保留秩/条件数、深度、收敛、残差、穿地及无未来根等拒绝原因；最多10次GN，不做相机重拟合、删点、阈值搜索或私有模型推理。它输出首观测模长与浮点触地时差候选，不能直接称触拍初速或已确认同口径的教师速度；交点不转成四舍五入的“精确源PTS”。

Python冻结试验的三组真实输入007、039manual、039native得到有限rank6解；原生逐组复算的首观测raw模长为24.1735178、8.5478513、8.5647191m/s，预测地面frame约83.282588、41.347222、40.909516。007的视觉弱区间是83..85，039是41..43。**039native的40.909516仍在41..43之外，事件一致性检查失败保留**，不round到41，也不扩大事先门。007仍有strict8相机复用失败，三例共享的名义场地/焦距/主点/零畸变等相机假设、未知阻力/旋转和碰撞均未获得认证；释放触地约束后残差变小不证明更准确。本轮没有新增教师比较，原先单拍约0.27%临时差也不能拿来认证新六参数结果。

独立精确生成控制在约6e−15内恢复参数；41点/10微秒短轨控制秩5、条件约1.112e11而拒绝，恒定视线控制秩4并有零列而拒绝。已知米制相机与g一般可利用角曲率约束尺度，但并非只要g非零或点多就稳定可辨识。Python第一进程在零列退化控制处未完成批保存；只修零列失败处理/逐例持久化后按冻结恢复协议重放，原失败记录保留，每个真实输入实际数值计算两遍，不冒称一次执行或新初始化搜索。只读独立验证通过38项检查，包括原PTS/像素、SVD/Jacobian和80位触地根；没有另行重拟。

原生10项定向测试在显式启用私有夹具后全部通过、0跳过/失败，包含3组实际输入；另独立CLI执行3组，分别检查56/51/51个冻结证据文件。Python/Swift对照最大位置差1.60e−14m、速度分量差2.14e−14m/s、触地时差3.34e−16s、RMS差1.07e−14px，仅证明算术对应。首次编译因测试timescale误用Int64失败、修为Int32后运行通过，两份日志保留。定向私有输入和CLI分别产生3次真实运动拟合，不重复算作六个独立样本；新增模型forward/相机拟合/训练均0。accepted/public相机、速度、球速始终null；human/formal/production/物理准确率及20%资格false。

完整推导、精确/退化/实际结果和失败保存在 `.local/speed-training/free-contact-flight-20261029/{REPORT.md,NATIVE_REPORT.md,native-verification.json,native-code-freeze.json}`；接口详见 [几何文档](independent-speed-geometry.md#16-无需输入触地时刻的六参数原生诊断)。

## 2026-10-29：共享本地视频分析、独立模型打包与回归

新增 `IndependentBallModelAssets` 的固定清单/模型三文件/README/MIT许可字节核验与bundle locator；新增 `IndependentLocalVideoAnalyzer`，将CLI实际解码、48帧过去背景、八帧CoreML、候选银行和过去关联迁入共享库。`independent-frames` 与 `independent-video` 共用资源验证，后者保留旧冻结协议/期望PTS/报告与首input/heatmap导出适配，不再维护另一套轨迹算法。本阶段完成时App可调用typed async API，但尚未接入视频导入、独立backend选择、事件候选确认或完整独立测速UI；后续本地视频实验接入见下节，资源打包本身不证明界面功能。

共享请求实际读取文件PTS，不需调用者预列warmup/target时间；每个warmup、缺失、断层丢弃和不足8帧尾部均有原因。typed结果保留source SHA、模型/manifest SHA、backendID、轨道/原PTS、图像变换、segment/window、available-at与完整候选/银行。公开速度和资格仍null/false，没有自动事件或几何推断。默认实验限制nominal元数据60fps及120秒/7300帧，不认证物理时钟；CLI按旧协议明确声明fps保持原关联参数。非identity方向继续拒绝。文件哈希逐块autorelease并响应取消；CoreML及所有读帧/预测/状态在专用串行后台队列，单次run内存有界，取消也在每个丢弃的前导样本前检查，不跨队列抢读/cancel。

约45MB固定MIT模型已纳入 `assets/independent-model-weights/tracknetv3-base-v1/TrackNetV3Base.mlpackage` 的Git LFS；清单/许可仍在 `assets/independent-models/tracknetv3-base-v1/`。`COURT_MODEL_SET=independent` 的准备脚本按固定字节暂存到 `.local/IndependentModels/tracknetv3-base-v1/`，打包资源路径为 `IndependentModels/tracknetv3-base-v1/`，无运行时下载。该模式排除S家模型 `AnalysisModels`，`COURT_CODE_ONLY=1`优先排除两套；旧locator在independent/code-only模式拒绝private目录与环境变量回退。默认S家构建行为保持。Mac独立Release App、iOS设备SDK和模拟器SDK构建均完成；逐包确认不含AnalysisModels、模型三文件匹配原清单且无private资源receipt。这些是编译/资源检查，不是iPhone运行、负载或UI验收。

共享模块新增13项受控测试，根资源模式另4项；本轮先12项assets/编排测试全通过，再追加Reader全8项（7项已有回归+新增前导取消）和4项locator测试全通过，均0跳过/失败。受控预测器没有调用真实CoreML，不能替代实际模型重放。assets验证保留模型root/祖先/成员链接与额外文件拒绝，仅识别精确系统/var、/tmp别名；最终按relative组件遍历，避免Foundation枚举/private/var造成错位。独立审查发现的前导取消问题已修复；完整审查与验证记录见本轮私有目录及 [验证记录](verification.md)。

实际共享CLI回归先记录Debug尝试：21帧RGB缩放后、0forward/无发布结果时因已确认的未优化CPU瓶颈人为停止，退出143与partial目录保留；不是推理结果失败重选参数。随后冻结Release执行修订，仅改变优化构建，同一输入/模型/算法/门和45forward预算不变。train007、slow002、sourcecheck080三个既有实际视频窗口分别完成168解码/120输出/15forward，共504/360/45；原始输入前后不变，所有旧确定字段（原PTS/RGB、背景/tensor/heatmap摘要、完整selection/bank/过去关联）逐字段相同，只排除inference/wall计时。总回归通过，合格速度输出仍0、训练新增0；这些已暴露开发窗不是新的独立精度样本，也不是手机性能结果。

实际回归的冻结修订、三case与汇总位于 `.local/speed-training/independent-app-integration-20261029/{release-execution-amendment.json,regression-case-*.json,regression-result.json}`。最终完整默认Swift套件共148项：142通过、6按需跳过、0失败，170.28秒。六项跳过为实机看板、独立CoreML私有夹具、Pillow/JPEG私有夹具、freeflight私有实际输入、公开视频标定及真实模型TLS镜像。新增的freeflight私有输入默认未启用；它在显式env专用10项定向中通过另列，不计作默认全套通过，也不以定向结果抵消跳过。最终日志为本目录 `full-swift-test.log`，没有新增UI、iPhone实际运行或合格速度验收。


## 2026-10-29：本地视频实验入口与App模型实跑

角色页新增「本地视频实验」，由 `IndependentVideoLabModel` / `IndependentVideoLab` 调共享分析器：选择本机60fps视频、设定起点与最多120秒，展示取消进度、球点/缺失原因、原始有理PTS及对应原图单帧候选坐标。画面要求实际时间和尺寸精确匹配才画标记；支持重新分析、画面重试、报告保存失败后重试。报告独立保存在Application Support的 `Zacks Court/IndependentRuns`，不复制视频，不接入会话/历史。球速始终「—」，明确缺少触拍/触地事件与可信相机；独立构建仅含约45MB MIT基础模型，不启用实时机位独立测速。

受控模型测试累计22项通过、0失败/跳过（先同轮21项，后补1项本地化），包括取消等待、文件身份变化、过期预览/进度、精确时间与尺寸门、原子保存及重试。另有真实Release XCTest 1项通过、0失败/跳过：同一App模型和实际服务仅更换测试宿主Bundle，对既有source003/train007开发窗执行168解码/120推理帧/15forward；48预热、67跟踪、53缺失。第87帧实际时间233450/600、原图候选(1395,465)，全部168原时间、120候选/关联/缺失和15组背景/tensor/heatmap摘要与旧结果一致，训练新增0、速度输出0。证据为 `.local/speed-training/independent-video-lab-20261029/actual-vm-run/actual-frame-receipt.json` 及同目录上级 `real-service-external-audit.json`。

模拟器空页、系统选片取消与实时模式隔离三项，在正常字号及最大辅助字号各3通过、0失败/跳过。它们未选择真实视频并运行推理；实际服务测试也没有验证SwiftUI选片到推理全链、系统文件提供器的security-scoped授权或iPhone实际运行。此处不更新此前148项完整套件的历史计数，不把后续待跑检查写为通过；仍无独立人审、物理精度或完整端侧测速验收。

## 2026-10-29：四个软件发球窗的有界事件与飞行诊断

按既定顺序保留074/018/057/041四窗，均来自已暴露source003。agent图像观察冻结触拍、疑似触网与首触地候选区间，之后仅核对软件行身份/时间，不使用教师速度或XYZ。独立复核不等于人审；041视觉触拍19..22与软件行90锚35.2012相差220–270ms，同拍绑定保持未知，不能改选相邻软件行或按球速匹配。事件包和复核分别在 `.local/speed-training/serve-batch-events-20261029/events.json`、`serve-batch-review-20261029/independent-review.json`。

018/057分别最多27/23帧，且有疑似触网，按32实际观测门预先拒绝。074/041各执行一次固定未认证camera039的六参数原生诊断，保留原50/37球点及缺失，不输入触地时刻、不调相机或重试；新增模型forward、相机拟合和训练均0。074预测触地91.24450697超出原89..91区间0.24450697帧，失败保留，不round或扩门；041的61.60458346落在61..63内，仅为弱视觉一致性，未解决软件事件映射、相机转移与未知碰撞。

独立算术/来源复核239项通过、0失败；不是额外拟合或物理验证。分母始终4、实际诊断2、预先拒绝2、合格完整飞行0；accepted相机/速度/球速null，human/formal/physical/production/20%资格false，没有新增S家误差结论。冻结协议、逐例结果与限制见 `.local/speed-training/serve-batch-freeflight-20261029/{result.json,REPORT.md,verification.json}` 及 [几何记录](independent-speed-geometry.md#19-四个软件发球窗口的事件与无接触时刻诊断)。


## 2026-10-29：教师语义纠正、报告到条件速度与阶段性交接

本地对 S家 App 两个版本的研究表明：一版导出取最终速度向量的模长并转km/h；另一版以端点位移/时间加重力项恢复区间初速度，随后可能有机位/侧别修正、发球分支重算或其他覆写。两版本不是同一完整运行溯源，现有教师逐行的计算区间、起止时刻及状态仍未知。（细节只在本地，见 docs/s-reference.local.md。）旧文引用的产品“平均速度”措辞不能覆盖这些实际证据；此前路径均值与教师标量约0.27%的临时差仅作历史数值，不能称同口径误差。证据摘要在原工作区 `.local/speed-training/native-flight-candidate-20261029/teacher-speed-semantics.md`；后续以独立触拍时间瞬时速度为主要开发量，区间均速辅助，不选更贴教师的定义/时刻。

新增 `IndependentFlightCandidateBuilder.build(analysis:camera:evidence:configuration:)` 和 `build(savedAnalysisJSON:camera:evidence:configuration:)`，CLI为 `court-analyze independent-flight-candidate PROTOCOL_JSON NEW_OUTPUT_DIRECTORY`。直接从原候选/真实PTS构造显式区间，调用同一freefit；不换点、不拟相机，保存报告重放不读取或重验原视频、不跑ML。缺相机/端点返回unknown；可选 `contactCandidateWindow` 用精确有理中点计算同一拟合的瞬时模长，窗内范围另检查竖直顶点最小值；向首观测之前延伸需 `contactExtrapolationReason`，不跨声明中断。此范围只覆盖事件时间，不覆盖相机误差或物理模型。

007已暴露开发窗39..79的41点只在每次调用中拟合一次，参数与原freefit一致；条件观测区间均速87.831894366km/h、首观测87.024664072km/h。新增34..37触拍窗的精确中点35.5为PTS233415/600，向前外推58.333ms，条件瞬时值87.09223691km/h，时间窗范围87.05731441..87.13609180km/h。原039相机转移failed strict8未解决，不产生新教师误差；公开相机/速度null，human/formal/production/physical/20%资格false。三个原Release CLI重放及后补触拍候选Debug重放均保留；后者不是性能比较，全部新增ML为0。协议、结果与核对在 `.local/speed-training/native-flight-candidate-20261029/`。

最新完整Swift测试182项：175通过、7按需跳过、0失败，179.39秒；Builder11项在其中。跳过为实机看板、独立CoreML私有夹具、Pillow/JPEG私有夹具、freeflight私有输入、App模型真实视频私有运行、公开视频标定和真实模型TLS镜像。此前专用真实服务1项通过仍单列，不能抵消本轮默认跳过。实验UI正常/最大辅助字号各3项通过；默认旧回归3个不同用例中1通过、2横屏断言失败，方向项复查也失败，根因未知，不能归称已确定旧问题或本轮回归；字号恢复large。未启动手机，新合并main后的包SDK验证仍待补。

用户授权先提交阶段性草稿MR并交接。正式验收仍0，未见1080p60新拍摄及独立人审100拍仍缺；不宣称逐拍≤20%或产品替换完成。优先补本视频相机证据/敏感性、独立事件分段及更多开发拍瞬时速度，再接App与实机，最后冻结至少100拍/3会话/2条件的独立最终验收。数据、命令与Astra/sol分工见 [交接说明](independent-speed-handoff.md)。

## 2026-10-29：完整12分27秒开发视频的原生效果检查

按用户要求对source003整片进行一次连续Release推理。预先冻结原视频SHA、44848帧、首PTS0/600、末PTS448470/600、固定MIT TrackNetV3 base清单及原生源码/二进制；不分片重置、不训练、不选择片段。共享请求新增显式offlineFullVideo限额3600秒/216000帧，App交互默认仍120秒/7300帧。CLI为 `court-analyze independent-full-video PROTOCOL_JSON STAGED_MODEL_DIRECTORY NEW_OUTPUT_DIRECTORY`，只发布到新目录，保留进度与失败，不以部分处理算完成。

实际进程退出0，全部44848帧解码、48预热、44800帧推理、5600次CoreML，1个来源段、未处理尾帧0；执行冻结的16个文件摘要最终均未改变。22973帧有候选、21827帧无候选，候选输出率51.279%（分母为已推理帧），不是正确率或召回率。1155个连续候选段，中位8帧、最长264帧、227段至少32帧；只描述输出连续性，未确认活动球身份或完整飞行。来源初始化1次、last-seen超时重置516次，不能把这些直接当漏拍。

**独立自动球速0，保留该来源全部127行S家 App 软件参考，整体速度MAE/MAPE与正确同拍precision不可计算。当前尚不能用于独立自动测速。** 缺少自动触拍/触地分段、可信相机及独立同拍复核；不以教师值填空，也不将此前单窗条件87.092km/h混作整片速度。基础球模型能输出部分候选不等于测速链路已复刻，20%/90%/95%仍未验收，正式人审合格拍数0。

Mac CPU处理墙钟3366.608秒，不含来源哈希与模型加载，约13.32解码帧/秒；纯模型调用1366.486秒。部分时段并行进行Swift/Xcode构建，这只是本次离线观测，不能当独占基准或手机实时性能。预注册12个均匀时刻的原图/候选拼图由agent查看，4处有候选、8处无输出，并查看4处原尺寸候选细节；没有把它们升级为正确率标签或人审。无输出时球可能未在画面中，不能据此推漏检率。

stdlib脚本 `scripts/ball-full-video-report.py`从完整报告生成75个10秒分箱、全部参考行与逐帧候选视频回看，支持上一/下一帧、叠加开关、均匀抽查和参考锚跳转。真实浏览器已验证150秒跳转、下一帧至150.016667秒、候选开关；展示代理1280×720/60fps、44848帧不作为模型输入。私有证据在当前worktree `.local/full-video-evaluation-20261029/`，原报告SHA为 `98e5faff56aec29226020c5a6821a4dff0d8a29201d100b1d7e5ca432cb9b28b`。视频、原图、页面内逐帧数据和浏览器截图不入Git。

main 97edfcf合并后的完整Swift203项：189通过、14按需跳过、0失败（193.685秒）；court-check退出0、code-only iOS设备SDK编译成功。新实验UI三项最终正常/最大字号各通过，旧方向断言仍失败；正常空页初次44pt浮点几何误差已用1e-6pt断言容差修正并重跑，不改变产品触控下限。全部失败和跳过按原范围保留，未实测手机或真实系统文件提供器选片到推理。MR为研究草稿，下一轮先补同源相机与事件，再扩展逐拍速度、覆盖分母与独立验收。

## 2026-10-29：接手后的整片逐拍球速原型（开发集）

Codex 的 goal 因额度暂停后由 Claude 接手。没有重新推理，直接用上一节整片原生 TrackNetV3 候选（`run-v1/report.json`），写了离线 Python 原型 [scripts/speed-fullvideo](../scripts/speed-fullvideo/README.md)，第一次在 double-test-003 全片上**自动给出逐拍球速**并与 S家 App 的 127 行对照。速度口径、事件规则、放行门限和匹配规则在计算任何球速之前写入私有 `takeover-speed-20261029/protocol.md`，期间两处修订也在出数之前记录。该视频已用于训练，设计时看过 S家 App 行的时间和击球/落点坐标（未看球速），所以下列数字只是**开发集结果，不是验收**。

- **相机**：本视频 25 帧中值图上拟合 8 条白线中心（亚像素），针孔、主点居中、无畸变。f≈1155 px，相机在底线后 6.1 m、高 1.54 m。8 条拟合线残差 ≤0.8 px；未参与拟合的远端底线 1.4 px；网柱和网顶预测与画面相差约 2–3 px（agent 目视）。在发球人深度上，抛球竖直加速度为 9.1–9.9 m/s²，说明帧率与近处尺度自洽。底线宽按 5 cm 或 10 cm 只改 f 0.4%。这是 agent 做的开发标定，不是产品标定。
- **事件**：候选连成轨迹，再切成平滑段，取相邻段的交界点。
  - 触地：交界点两侧都能用「锚定在该地面点的飞行」解释，各自残差 ≤4 px。
  - 击球：不是触地、且靠近 Vision 人框的交界点。人框用整帧加四个远端裁剪检测。
- **飞行与速度**：重力加二次阻力（k=0.0196/m，不含旋转），有触地点就锚定，另加击球人脚点深度先验（σ 0.8 m）。速度按 S家的端点公式 `|(P_net−P_hit)/T + (0,0,gT/2)|`（击球到过网），瞬时速度另报，不互换。
- **匹配**：S家 App 导出时刻 +2.0 s（发球、远端回球、近端正手 3 行目视核对为触球瞬间），±0.6 s 内一对一，不按速度配对。

**v1 结果**（开发集）：

- **覆盖**：127 行中 111 行在 0.6 s 内有检测到的击球，40 行给出球速（覆盖 31%）。
- **误差（这 40 拍）**：MAE 10.5 km/h，MAPE 15.5%，中位 14.3%，P90 27.6%，P95 36.4%，最大 43.5%；27 拍在 20% 以内。平均比 S家 App 低 5.2 km/h，远端与近端击球方的 MAPE 分别为 14.8% 和 16.2%。
- **发球**：37 个只有 1 个出速。
- **未出速原因**：无深度锚点 30、拟合残差 >4 px 21、未检测到击球 16、拟合飞行不到网 10、观测不足 8 点 6、其他 4（击球与落点同侧 2、击球到过网太短 2）。
- **多报**：另有 25 个被放行的检测没有对应的 S家 App 行，未复核是多报还是 S家 App 漏记，所以放行输出的匹配率只有 40/65。

**按锚点类型拆开看**：有触地锚点的 24 拍 MAPE 12.3%、中位 10.9%，19 拍在 20% 以内；只有击球人约束、没找到触地的 16 拍 MAPE 20.3%，8 拍在 20% 以内。所以第一步应是找回更多触地（尤其远端），没有触地锚点的拍宁可不出数。另有两拍（#30、#70）匹配时差 0.3–0.4 s，可能配错了事件。

**深度问题集中在远端飞行**。不看 S家 App 也能看出：远端击球时，拟合出的击球点比 Vision 脚点近 2.4 m（中位）；和 S家 App 的击球坐标比，同样系统性偏近 3–9 m，导致球速偏低。单相机下远端飞行深度对 1–2 px 的偏差极敏感：一拍远端回球的起点从 19 m 改到 25 m，残差只从 2.2 px 升到 3.6 px，重力加触地锚也压不住。加入旋转升力项后残差反而更差，原因还没查明。

把脚点先验收紧到 0.3 m 做了一组对照（v2，看过 v1 误差后在开发集上调的）：MAPE 14.2%，中位 12.1%，但更多拍超出残差门限，覆盖降到 27%。没有把 v2 当成新口径。

**标定敏感性**：每条拟合线随机平移 ±2 px，重解 10 组相机，f 在 1113–1180 px 之间。每组都重跑全流程：同一拍球速的极差中位 5.3%、P90 6.1%、最大 7.4%；整体 MAPE 14.9–16.3%（一组因个别离群拍达 27.7%）。标定不是主要误差来源。

**下一步**：
1. 查明远端深度失配（阻力、旋转、检测偏差），或把脚点深度作为强约束，配合跨帧人员跟踪。
2. 专门检测发球：抛球段，以及发球姿势下的人员检测（Vision 在这一姿势常漏检）。
3. 近端击球、远端触地没拍到的拍：用对方回球人的位置约束远端。
4. 规则在开发集上冻结后搬到原生 Swift，并在新的 1080p60 拍摄素材上验收。20% 和 90% 的门槛仍按原 goal 定义，没有放宽。

## 2026-10-29：test.MOV 单打的动作类型与球速对齐（开发调参）

用户指定用下载目录中的单打视频 test.MOV（约 10 分 35 秒，S家 App 96 行）调测，只优化**动作类型**和**球速**两项与 S家 App 的对齐，并且只能用自研代码和可商用的开源模型（准备上架售卖）。本轮用到的模型：

- 球检测：原生 TrackNetV3（MIT，羽毛球基础权重）。
- 人员检测：Apple Vision 的人体矩形检测（系统框架）。

没有用到 S家模型。App 目前仍打包 S家模型，上架前必须由自研链路替换，本轮没有做这件事。

**证据口径**：
- test.MOV 属于 Codex 训练球模型时用过的单打来源。
- v1 规则在出数之前冻结，见私有 `takeover-test-20261029/protocol.md`。
- v2 之后的每一版都是看过 v1 逐行误差和 S家 App 标签后，在同一视频上调出来的，存在过拟合风险。
- 下面全部是**开发调参结果**，不是验收。

**原生运行**：
- `court-analyze independent-full-video` 新增可选字段 `allowNonSixtyNominalFPS`（test.MOV 标称 59.88 fps，逐帧仍用真实 PTS），帧数上限改为期望值 +200。
- 运行后的元数据检查失败时，报告另存为 `report-failed-checks.json` 再退出，避免一次长跑白费。
- test.MOV 的解码帧是 38,029 帧（PTS 0..381029），与协议按压缩样本写的 38,057 不一致。该报告照原样使用，不一致已记在协议修订里。

**相机**：拍摄中手机在 354.5–357.5 s 被转动过一次，所以分两段 A [0, 354) s、B [358, 结束]，各用本段中值图的白线拟合。
- 远端发球线不参与拟合：它的细化会吸到网带上。
- 拟合线残差 ≤0.75 px，留出的远端底线 1.2 px，两段的 f 与相机中心一致。

| 版本 | 改动 | 出速行 | MAPE | 中位 | P95 | 20% 内 | 有动作 | 动作一致 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| v1 | 冻结规则 | 20 | 10.3% | 8.1% | 26.7% | 17 | 48 | 30 |
| v2 | 首次观测前回溯到击球人深度、剔除离群点 | 19 | 10.6% | 8.2% | 27.1% | 16 | 49 | 28 |
| v3 | 锚定拟合失败时只用触地锚重拟合，并裁掉开头 | 29 | 14.5% | 10.9% | 38.4% | 23 | 47 | 29 |
| v3b | 同 v3，不裁开头 | 24 | 11.5% | 8.6% | 33.7% | 20 | 48 | 30 |
| v4 | 击球人必须站在落点对侧 | 24 | 11.3% | 8.2% | 33.7% | 20 | 25 | 20 |
| v5 | 按相机远端半场重新裁剪检测人员 | 27 | 13.6% | 10.8% | 38.5% | 22 | 57 | 40 |
| v6 | 击球方改由最近人框或球的画面走向判断 | 27 | 13.6% | 10.8% | 38.5% | 22 | 71 | 44 |
| v7 | 发球规则 v2 | 27 | 13.6% | 10.8% | 38.5% | 22 | 73 | 57 |
| v9 | v7 + v2 回溯 | 27 | 13.2% | 10.5% | 38.5% | 22 | 74 | 57 |
| **v9b** | 回溯用于所有击球（当前最好） | **27** | **12.1%** | **8.3%** | **38.0%** | **22** | **74** | **56** |

列的口径：
- 出速行、MAPE、中位、P95、20% 内：都按触地锚定门限（主口径）统计。
- 有动作、动作一致：都按 96 行统计；未检测到击球的行算未覆盖，不算一致。

v9b 的分项：
- **动作**：发球 24/26、正手 20/34、反手 12/22、截击 0/3（按匹配行计）；输出的 74 个动作中 76% 与 S家 App 一致。
- **球速**：非发球 21 拍 MAPE 11.8%、中位 7.8%，17 拍在 20% 内；发球 6 拍 MAPE 13.2%，5 拍在 20% 内。
- **未出速原因**：拟合残差 >4 px 22、无触地锚（门限）10、0.6 s 内未检测到击球 11、无深度锚 8、拟合飞行不到网 8、击球到过网太短 3、击球与落点同侧 3、无初始飞行假设 2、观测不足 8 点 1、速度超出 20–250 km/h 1。

**查到的原因**（agent 看画面确认）：
1. **近端球员常在画面下沿之外**，只露出头顶。这时看不到人，正反手无法判断，保持「—」。15 行近端击球因此没有动作，这是机位造成的，不是规则问题。
2. **远端人框原来几乎没检出**：旧裁剪是按 double-test 的球场写死的。改为由相机推出远端半场后分 4 块裁剪，A、B 两段几乎每个检测帧都有远端人框（1,619/1,622、848/850）。
3. **落点对侧推击球方不可靠**：50 个有触地的匹配行里错 13 个，原因是发球前拍球和远端伪触地。改为「1.5 个框高内的最近人框，否则看整段飞行在画面中向下还是向上」后，84 个匹配行中 81 个击球方与 S家 App 一致。
4. **发球**：
   - 原规则要求「之前 3 s 没有过网球」，但分与分之间的喂球让这条失效。
   - 测到两个区分特征：
     - 近端发球人站在底线上（−0.2…+0.3 m），而相持时站在底线后 1.3–2.5 m。
     - 发球触球点在人框顶上方，比例 ≥0.2 框高。
   - v2 规则：站在本方底线 −1.0…+0.8 m 内，且触球点在头顶上方（或看到抛球）。
   - 结果：发球由 11/26 升到 24/26。
5. **远端正反手翻转**：TrackNetV3 在远端球员身前常丢球，缺口达 57 帧，第一个看到的出球点已越过身体，检测到的击球比实际晚 0.2–0.5 s。看画面，翻转的几拍都是右手正手在画面左侧触球；远端发球也确认是右手。要修这一项需要更好的球检测，或用姿态判断挥拍侧，本轮没做。
6. **远端球速偏高**：拿到远端人框后，脚点深度先验在晚到的击球时刻把球压在人的深度上，速度被高估（例如 56→82 km/h，S家 App 66）。v9b 把「回溯到击球人深度」用于所有击球后，MAPE 回到 12.1%。

**多报**：
- 整片检测到 402 次击球，S家 App 只有 96 行，多出的主要是喂球、发球前拍球和热身球。
- 放行出速但没有 S家 App 行的有 33 个（未按触地门限）。
- 试过一个分分过滤（`points.py`：发球开分，之后双方交替且间隔 0.5–3 s）：
  - 多报由 318 降到 73，但匹配行从 84 降到 66。
  - 允许跳过一次漏检后，多报 132、匹配 72。
  - 两种都不划算，没有采用。要先把击球检测做准，才能可靠分分。

**与目标的差距**：
- 原 goal 是逐拍 20% 以内、覆盖 ≥90%；现在出速覆盖只有 27/96（28%）。
- 动作一致 56/96，其中近端不可见约 15 行。
- 门槛没有放宽。

**下一步**：
1. 在远端球员身前找回丢失的球，或用远端姿态判断挥拍侧；用 Vision 人体姿态（系统框架）即可，不引入新的模型授权。
2. 把击球检测做准后再做分分，去掉喂球和热身球的多报。
3. 规则冻结后搬到原生 Swift，并在新拍摄、带人工复核的单打素材上验收；验收素材不能是 test.MOV。

## 2026-10-29：用 double-test-003 交叉检查，并改进事件检测

用户允许使用下载目录中的其他素材。素材清点（只读元数据）：

- 有 S家 App 参考行的只有 test.MOV（96 行，单打）和 double-test-003（127 行，双打，相机高 1.54 m）。
- double-test-001 与 002 是 30 fps（002 为 720p），不符合 App 的 1080p60 要求，也没有 S家 App 行。
- single-test.MOV 是 test.MOV 的开头部分，不能当独立检查。
- 其余是几秒到几十秒的短片。

所以没有新的单打参考视频。double-test-003 是唯一能做交叉检查的视频：v1 速度设计时看过它，但 v2–v9b 的规则改动都没有在它上面调过。

**交叉检查结果**（double-test-003，127 行，主口径要求触地锚定）：

| 设置 | 出速行 | MAPE | 中位 | P95 | 20% 内 | 动作一致 | 发球 |
|---|---:|---:|---:|---:|---:|---:|---:|
| v1 | 23 | 11.9% | 9.0% | 24.1% | 18 | 39 | 3/24 |
| v9b（旧人框） | 26 | 13.3% | 11.3% | 34.1% | 20 | 48 | 1/24 |
| v9b + 按相机裁剪重新检测人员 | 24 | 12.2% | 8.5% | 33.6% | 19 | 48 | 4/25 |
| **v13**（v9b + 事件 v2） | **28** | 13.6% | 8.3% | 37.4% | 21 | **55** | 5/27 |

- 动作的改进能迁移到双打：39 → 55。
- 发球规则不能迁移：这台低机位相机下近端发球人常没检出，一半发球根本没检测到击球。
- 球速覆盖在两个视频上都只有约 20–28%。

**事件 v2**（`junctions.py` 与 `shots.py` 的 `COURT_EVENTS_V2=1`、`COURT_EVENTS_REVERSAL_HITS=1`）。先做了诊断：

- test.MOV 上没挂上触地的行里，35 行在 S家 App 落点像素 15 px 内其实有球的观测（double-test-003 为 38 行）。
- 原因主要有两种：
  - 球在远端人框附近经过时，一个平缓的拐点被当成击球，把飞行截断（例如第 2 行）。
  - 近端球员在画面外时，击球交界点附近没有人框，整段被当作触地后的飞行丢掉。

改动：
- 衔接允许 24 帧的缺口。
- 球的画面方向急转（≥120°，两侧各 ≥6 点）的非触地交界点即使没有人框也算击球。

试过但没有采用：
- 「两段能拟合成一条自由飞行就不算击球」：远端击球在画面上像一个高球的顶点，也能拟合。
- 「方向转弯小于 50° 不算击球」：test.MOV 出速 27 → 25。
- 「第二次机会的触地检验」：会把真击球标成触地，匹配行减少。
- 放宽 4 px 残差门限：被拒的有触地拟合里一半与 S家 App 接近，一半严重偏低，放宽会同时带进大误差。
- 「只用击球点与触地点两个事件算速度」：只有 34/96 行同时有两个事件，MAPE 21.5%。

v13 在 test.MOV 上与 v9b 持平：27 行出速，MAPE 12.2%，22 拍在 20% 以内；动作一致 56/96。匹配到击球的行从 85 增到 87。

**结论**：
- 剩下的覆盖缺口主要是：
  - 拟合残差 >4 px（23 行）；
  - 击球没有人框又没有触地（11 行）；
  - 触地没检测到（13 行）。
- 这些都受限于 TrackNetV3 羽毛球基础权重在网球上的漏检。继续调规则的收益已经很小。
- 默认参数仍能逐项复现 v1；v9b 也能复现。
