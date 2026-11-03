# 独立球速：静态标定、二维轨迹与三维物理拟合

2026-10-29，设计、数值审查及共享 Swift 固定相机诊断；尚未接入 App，也未通过真实球速验收。

文档保留**已标定相机条件下的离线六参数飞行拟合器**设计：从独立球心像素、整数 PTS 和相机标定恢复单次无碰撞飞行段的三维位置与速度，条件不足就返回空值。未知相机参数不能由四个球场角点无条件补齐；低重投影误差也不能单独证明三维速度可信。本设计不把空中球通过地面单应性后的移动距离当作球速。

它是可审计的数学基线，不是完整物理模型。阻力、旋转、触球定位及真实标定误差尚未解决；第一版的数值输出须标为 `conditional_ballistic_estimate` 或内部诊断。另已实现已知触地约束下的共享 Swift **五参数固定相机诊断**，接口与实际数值对照见第 13–14 节；它不认证假设相机，也不替代六参数飞行的完整验收。完整项目状态见 [球速模型训练记录](speed-model-training.md)。

## 现有代码的边界

| 现有入口 | 已有能力 | 不能据此推定的能力 |
| --- | --- | --- |
| `Sources/CourtCore/TennisRuntime/TennisCourtMapping.swift` | 图像到双打场地平面的单应性（手动四角） | 相机内参、畸变、相机高度及空中球三维坐标 |
| S家链（本地的 `.local/s-chain/`，不进 Git，见 [s-reference.md](s-reference.md)） | 对照用：S家模型给出的球位置和测速 | 独立于 S家权重的测速链 |

四角标定的米制场地坐标约定可复用，但 `TennisCourtMapping` 不是完整的 `CameraCalibration`。现有 `validationErrorMeters` 是地标内部一致性；不要把它用作球速误差保证。新模块不读取 S家的 XYZ、速度、细化窗口或教师事件时间作为几何真值。若上游球心/地标仍来自现有模型，必须在来源字段中声明，不能把整个链称为独立替换。

## 1. 相机参数先于空中三维恢复

固定世界坐标为：近左双打外角 `(0,0,0)`，x 向右，y 向远端，z 向上，单位米；外场宽 10.97、长 23.77。网在 y=11.885，标准中央网高 0.914 米，柱处 1.07 米。实地是否标准、线的外缘/中心、网带与柱顶的像素定义必须另记，不用标准尺寸掩盖实地差异。[ITF 场地定义](https://www.itftennis.com/en/about-us/organisation/tennis-glossary/)

采用世界到相机变换，避免把平移向量误当相机位置：

```text
Xc = R Xw + t
C  = -Rᵀ t
uv = distort_and_project(K, Xc),  Xc.z > 0
K  = [[fx, skew, cx], [0, fy, cy], [0, 0, 1]]
```

完整输入须明确原始解码尺寸、方向、镜像、裁切/缩放、镜头畸变模型及适用的静态机位区间。若像素做仿射变换 A，内参同步变为 `K' = A K`；简单 crop/resize 的主点也要减去裁区原点再缩放。第一版可只接收已去畸变像素，但必须绑定去畸变后的 K 与图像变换，不能把畸变未知默认为零。[OpenCV 投影与畸变约定](https://docs.opencv.org/4.13.0/d9/d0c/group__calib3d.html)

### 已知 K：推荐的首个可运行分支

1. 用同镜头、同分辨率、同变焦/稳定模式的独立标定获得 K 与畸变；合成测试可以显式提供精确 K。
2. 标注有语义的球场地标，含近端、远端与内场线交点。至少四个非共线点才能定平面 H；实际建议不少于八个且保留未用于拟合的地标作检查。点位数多不等于空间分布好。
3. 从 H 分解或平面 PnP 得到 R、t 的候选，对每个候选检查正深度、相机在地面之上、场地朝向与未参与拟合的地标/网高。保留多个近似等优解时，不强行取第一解。
4. 把地标点击误差、K 与畸变的不确定性传播到姿态及最终速度。固定相机连续多张重复画面可降点击噪声，但不产生新的几何视角。

OpenCV 的平面 IPPE 分支显式产生两组位姿候选；其官方代码可用作实现参考，不能仅因 `solvePnP` 成功就认为解唯一。[官方 PnP 文档](https://docs.opencv.org/4.13.0/d5/d1f/calib3d_solvePnP.html)、[实现](https://github.com/opencv/opencv/blob/4.13.0/modules/calib3d/src/solvepnp.cpp)

### 未知 K：当前历史视频不能跳过的门槛

已知平面场地给出 `H = K [r1 r2 t]`。H 有八个自由度，一般 K 有五个自由度；旋转列的正交与等长仅给出两个内参约束。单一平面视角不能恢复任意未知 K、畸变和姿态。多张相同固定视角不会改变这个事实；张正友标定利用的是平面在不同朝向下的观察。[原始标定论文](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/tr98-71.pdf)

一种后续探索分支是**显式固定**零 skew、方像素、已知主点与已知/已处理畸变，只估一个焦距 f。令 H 的前两列在减去主点后的分量为 `(a_i,b_i,c_i)`，则：

```text
(a1*a2 + b1*b2)/f² + c1*c2 = 0
(a1²+b1²-a2²-b2²)/f² + c1²-c2² = 0
```

可联合求 `1/f²`，但必须为正、两式相容、远离退化；平面正对相机等情况可完全失去焦距信息。中心主点不是历史裁剪/电子防抖视频的已知事实。应在预先声明的主点、畸变与焦距范围内检查速度变化，不能只选一个看起来合理的相机高度。

真实已知的非共面点（例如实测网柱对应位置/高度）、额外标定图或可信相机内参可提供补充约束。网带弯曲、柱顶高于网线、单打支柱、遮挡与像素语义必须处理。不能把全网带都设成相同高度，也不能把球员“典型身高”当精确尺子。

**第一版决定：只接受明确提供的完整标定，不从现有未知参数视频硬拟合相机。** 缺标定时保留 2D 轨迹和原因，`speed_kmh=null`。

## 2. 可实现的单段物理拟合

设首个可靠观测的时间为 `t_ref`，严格使用 `τ_i=(PTS_i−PTS_ref)×timebase`。拟合未知量只有 `θ=(p0_x,p0_y,p0_z,v0_x,v0_y,v0_z)`：

```text
g = (0, 0, -9.80665) m/s²
p(τ) = p0 + v0 τ + 0.5 g τ²
v(τ) = v0 + g τ
speed_at_ref_kmh = 3.6 * ||v0||
```

单段不得跨触拍、触地、触网或身份切换。接触时刻不确定就只拟合明确接触之后、下一事件之前的观测；拟合不能自动证明触球发生。没有独立触球区间时，结果名称是“首可靠观测时速度”，不是“击后初速”。若触球为时间区间 `[a,b]`，可在明确模型假设下计算 `v(a−t_ref)..v(b−t_ref)` 的速度范围，同时报告外推时间；不把区间中点悄悄变为精确时间。

### 初始化：射线约束的线性最小二乘

对已去畸变点 `u_i=(x_i,y_i,1)`，归一化世界射线为 `d_i = normalize(Rᵀ K⁻¹ u_i)`；令 `Q_i=I−d_i d_iᵀ`，则：

```text
Q_i (p0 + τ_i v0) = Q_i (C − 0.5 g τ_i²)
A_i = [Q_i, τ_i Q_i]
```

堆叠后用 QR/SVD 求六参数，不求显式正规方程逆。这是初始化，不是最终像素误差最优解：射线空间残差与远近位置的像素误差权重不同，噪声也进入了 A。

### 优化：原像素空间残差

对每个真实观测，定义 `r_i = L_i⁻¹ (π(p(τ_i))−u_i)`，其中 `L_i L_iᵀ=Σ_i` 是像素球心误差协方差；不确定性是保守半径而非统计标准差时，不得冒称高斯置信区间。优化 `Σ ρ(||r_i||²)`，使用固定的 Huber 等稳健损失；保留所有原观测与权重变化记录。少数错点可降权，不能为了漂亮结果删掉困难整拍并从覆盖分母消失。

建议显式多初值、正深度与合理运动状态检查，返回所有近似等优的物理解。初值可来自线性解及预先声明的深度/位置扰动，不能来自教师速度。地面与相机深度是物理约束；不能把球限制在球场矩形内，因为合法空中/出界轨迹都可能超出边界。

球心在触地瞬间约为一个球半径高，不严格为 z=0。第一版无碰撞段可不使用触地点；后续引入 bounce 约束时要明确是接触点还是球心及半径近似。禁止把一段跨弹跳轨迹硬拟合成一个抛物线。

### 何时可以辨识

已知 K、R、t、米制尺度、可信时钟与固定 g 时，多时刻射线在一般几何位置可以约束六参数；仍须实际检验 Jacobian 的秩和灵敏度。至少三个点的六个标量约束只是计数，既不保证解存在唯一，也不代表有噪声时可用。

如果同时自由估计 g，变换 `p'(t)=C+s(p(t)−C)`、`v'=s v`、`g'=s g` 对所有 s>0 投影相同，绝对速度存在尺度族。即使固定 g，重力曲率在短窗口中低于像素误差、射线几乎重合、运动/重力接近视线方向，仍可能病态。不能用预测平滑或轨迹“像抛物线”代替可辨识检查。

## 3. 接口建议

以下是跨 Python/Swift 可序列化的概念契约，不声称 App 已实现。矩阵为 row-major，全部数值有限；PTS 是整数、有理 timebase 保留到最后一步；像素坐标原点为左上，x 右、y 下。

```text
CameraCalibration
  id, source_hash, frame_transform_id, valid_pts_interval
  image_width, image_height
  K[3,3], R_world_to_camera[3,3], t_world_to_camera_m[3]
  world_axes = court_near_left_x_right_y_far_z_up_m
  distortion_model, coefficients, points_are_undistorted
  intrinsic_basis = measured | synthetic_exact | declared_assumption
  landmark_ids_and_pixel_world_pairs, fit_and_check_landmark_ids
  uncertainty_spec, alternative_calibrations[], static_camera_evidence

BallObservation
  track_id, source_pts, timebase_num, timebase_den, image_sha256
  frame_transform_id, x_px?, y_px?, uncertainty_px_or_covariance?
  status, target_identity, provenance = human | agent | model
  is_interpolated = false

FlightSegment
  id, observations[], no_collision_interval
  hit_interval?, bounce_interval?, event_identity_status
  segmentation_basis, clock_basis, source_group

FitPolicy
  version, gravity_m_s2, model = ballistic_no_drag
  fixed_optimizer_and_robust_loss, seed, multistart_spec
  min_observations, min_span_seconds, parameter_scales
  residual_limit, sensitivity_limit, camera_perturbation_spec

FlightFitResult
  state = rejected | diagnostic_only | conditional_estimate
  speed_kmh?, speed_time_definition, t_ref_pts
  diagnostic_fit = {p0_m, v0_m_s, speed_at_ref_kmh, trajectory[]}
  uncertainty_kind, speed_sensitivity_interval_kmh?
  reprojection_errors_px[], per_point_weights[], alternative_solutions[]
  jacobian_rank, scaled_condition, perturbation_failures
  observed_count, unknown_count, coverage_denominator
  rejection_reasons[], calibration_id, input_policy_hashes
  physical_accuracy_validated = false
```

`diagnostic_fit` 允许内部检查失败解，但 UI 速度字段必须独立受门控。球心 `unknown/uncertain` 不作为 `(0,0)`；插值/平滑后的展示点不能伪装成独立观测增加拟合样本量。观测归一化坐标若用于传输，必须同时保存所属尺寸和反变换。

推荐函数边界为 `validateCalibration`、`segmentTracks`、`fitBallisticFlight`、`assessSensitivity`；后续可将校准器单独作为工具，避免一个函数同时猜相机、挑球、选触球和输出速度。独立相机/像素条件变更应使当前段失效，不能跨变焦、镜头切换、稳定裁区漂移或时钟断层拼接。

## 4. 第一版拒绝与诊断门控

以下数值是**待冻结的工程建议，不是经过真实精度校准的阈值**。实现应保存实际 policy；文档与代码不一致时不得默认为已经执行了全部门控。

| 检查 | 初始建议 | 失败处理 |
| --- | --- | --- |
| 来源/时间/变换 | source、image hash、坐标尺寸一致；PTS 严格递增；时间单位明确 | `invalid_input_or_clock` |
| 标定 | K 合法，R 正交且 det=+1，完整畸变/图像变换；静态适用区间内 | `missing_or_invalid_calibration` |
| 同球同段 | 身份确认；没有跨击/弹跳/网碰证据；无伪造连续插值 | `ambiguous_identity_or_segment` |
| 数据量预筛 | 至少 8 个有效点、跨度至少 0.2s | `insufficient_observation_span`；满足也不保证可辨识 |
| 物理可行性 | 所有球点正相机深度、无明确穿地；边界检查有误差容限 | `nonphysical_solution` |
| 残差 | 预注册误差模型；例如加权二维 RMS≤3，并检查连续偏差和最大残差 | `poor_projection_fit`；像素低残差不是充分条件 |
| 局部秩/条件 | 按 p/10m、v/30m·s⁻¹ 等固定尺度求 J；秩 6、条件数≤10⁶仅作数值预筛 | `ill_conditioned_geometry` |
| 多解 | 建议至少 10 个预注册物理初值；相近代价物理解速度不一致 | `multiple_plausible_speeds` |
| 敏感性 | 像素、相机、时间与段端点扰动，含连续小块留出；速度区间总宽/中点≤0.20作为初始诊断条件 | `unstable_speed` |
| 缺误差依据 | 相机/像素范围不可说明，或只有模型自报高分 | 保留 `diagnostic_only`，对外速度 null |

J 条件数依赖参数单位，因此必须报告缩放。线性局部协方差近似 `(JᵀΣ⁻¹J)⁻¹` 只描述当前模型/标定附近的局部敏感性；不能覆盖错误运动模型或另一局部解。多初值不保证找全全局解；应增加沿深度/速度的 profile 检查和合成反例。短段即使通过 min_span，也要做完整敏感性检查。

时间扰动依据曝光时间/PTS 含义和触球区间，不随机修改已知精确的合成时钟。未知曝光与滚动快门可引入相关像素/时间误差，不能仅依靠独立高斯抖动宣称区间可靠。留块后若不可辨识，计入失败而非只汇总剩下的成功拟合。

阻力/旋转不应在缺数据时全部变成自由参数。下一阶段可比较固定阻力范围的 `dv/dt=g−k||v||v`、再引入受约束 Magnus 项；跨模型速度差也应进入敏感性范围。当前无阻力模型的低残差不能证明这些力可以忽略。

## 5. 本轮实际数值检查

只使用原创新写的 NumPy 合成脚本，没有读取任何真实片、教师字段或球速标签。脚本与完整结果在忽略目录：

```text
.local/speed-training/independent-geometry-20261029/geometry_numeric_check.py
.local/speed-training/independent-geometry-20261029/results.json
```

执行环境 NumPy 2.5.4、seed=20261029。相机 C=(5.485,−7,3)m，朝向 (5.485,11.885,0)，K 的 fx=fy=1400px、主点(960,540)；p0=(3,1,1.5)m、v0=(2,22,4)m/s，初速 **80.8197996km/h**。初始化为射线线性解，有限差分阻尼像素优化；该检查特意未用拒绝器过滤坏解，以显露失败，不能视作产品拟合实现。

| 合成条件 | 实际结果 | 证明范围 |
| --- | --- | --- |
| 精确 K/时钟/球心，0.8s、49点 | 速度 80.8197996；二维 RMS约8.44×10⁻¹⁴px | 同模型无噪声代数闭环 |
| 同条件，每坐标σ=2px，100次 | 速度绝差中位0.968、P90 2.488km/h；二维RMS中位2.699px | 这一个几何与噪声设定的敏感性 |
| 精确球心，0.1s、7点 | 仍可数值恢复原速度 | 无噪声可解不代表稳定 |
| 0.1s、7点，每坐标σ=2px，100次 | 绝差中位50.912、P90 113.427km/h；二维RMS中位2.162px；28次相机深度非正 | 低像素残差仍可严重错速，必须拒绝短段病态解 |
| 自由缩放三维轨迹与重力，s=0.5/1/2 | 40.410/80.820/161.640km/h，像素差≤2.28×10⁻¹³ | 不固定物理尺度/重力时的精确歧义 |
| 将空中球射线直接交地面，取最初两帧地面距离/时间 | 324.686km/h，对应真实初速80.820 | 地面 H 不能直接测速 |
| 合成二次阻力 k=0.012m⁻¹，却拟合无阻力 | 80.230km/h，二维RMS仅0.177px | 低残差不能证明运动模型正确；k只是测试常数 |
| 正对地面的相机，(f,h)=(1000px,20m)/(1500px,30m) | 四角及任意地面投影完全相同；示例2m高球投影相差约(−4.931,21.597)px | 单平面未知 K 的具体反例 |

0.1s 情形的局部速度标准差近似为123.205km/h，0.8s为1.427km/h（固定相机，假设每坐标σ=2px）；它们不是现实可信区间。表中 Monte Carlo 数值不应成为真实误差承诺，也不应先筛掉负深度后报告“成功样本精度”。

复现：

```sh
.local/speed-training/tracknet-smoke-20261028/venv/bin/python \
  .local/speed-training/independent-geometry-20261029/geometry_numeric_check.py
```

实际数学模块还应加入以下独立回归：坐标轴/镜像及 crop-resize 等价性；错误 fps 与整数 PTS；相机 K/姿态/畸变扰动；纯视线运动；全轨迹近直线；重复点和掉帧；跨 bounce/击球；球员误检混入；同等投影多解；真实存在但 ROI 外的球。全未标、全未知、标定缺失都必须返回空速度。本轮表格没有声称这些后续用例已经运行。

## 6. 文献与代码能提供什么

2025 CVsports 论文 **Where Is The Ball** 以三阶段 LSTM 和规范化表示恢复三维，明确假设相机参数已知、序列首尾在地面；真实 TrackNet 网球没有完整三维真值，其落点评价依赖触地点标注与标定。它支持研究合成训练先验，但不能直接把当前半空开始的短段当作已满足输入条件，也不能借用其网球展示认定本项目速度精度。[原论文，方法、数据与限制](https://arxiv.org/html/2506.05763v1)

截至本次核查，作者网站的 Code / Simulation 仍标注 coming soon，链接指向 GitHub 首页；没有从该官方入口取得可固定版本的训练代码、权重或许可。arXiv 论文的许可链接为 CC BY 4.0，仅确认论文许可；不替未来代码、模拟器、权重及视频数据授予许可。本轮没有下载或集成这些材料。[作者项目页](https://where-is-the-ball.github.io/)、[论文与许可入口](https://arxiv.org/abs/2506.05763)

OpenCV 4.13.0 的投影/PnP 文档及 `solvepnp.cpp` 已核查；仓库许可证为 Apache 2.0。若后续直接引入其实现，保留版本与许可通知并审查相关第三方组件；目前仅用于数学/接口参考，未添加 App 依赖。[官方许可证](https://github.com/opencv/opencv/blob/4.13.0/LICENSE)

合成训练应在几何基线之后：随机化相机、焦距、畸变、轨迹、阻力、旋转、噪声与缺测模式，按相机/轨迹族分组留出；保存真实生成参数。学习器可以提供初始化或高度先验，但最终仍需回投影与可辨识门控。模拟轨迹不能填入真实训练集作已观测球心，更不能成为真实物理精度的评估参考。

## 7. 真实数据缺口与验收

现有 144 个训练和 48 个检查标注均为 agent 候选；检查源仅有一段慢速传球连续32点。它们缺少足以验证独立球速的相机标定、唯一触拍事件、长且可靠的击后连续轨迹及同步独立速度参考。`double-test-002` 已被本轮查看，后续属于开发数据；`double-test-001` 继续保留，本次几何审查未读取它。

首轮真实采集至少补齐：同镜头/同模式的内参与畸变；有误差记录的球场/非共面地标；实际 PTS、曝光/滚动快门与稳定模式；确认同球的触拍时间区间和首弹前连续轨迹；独立参考的测量时间定义与误差。雷达若只给视线方向分量，须处理方向/余弦问题；多相机若作参考，须有独立同步、标定与重建误差。都不能直接用软件报出的速度替代物理参考。

本项目主目标的真实验收为：独立人审至少100拍、3个会话、2种机位，主要1080p60，覆盖发球/高速/远端/遮挡；每个有效输出的 APE≤20%，覆盖率≥90%，事件 precision≥95%，并验证实际 Core ML/App 链。全部候选拍都进入覆盖分母，拒绝不能从分母删除；无独立参考的拍不能计为精度通过，重复帧不是独立拍。报告同时给失败/未知与来源分组结果，不能用平均误差掩盖超过上限的个别输出。

本轮只建立几何方案、明确拒绝边界并运行合成数值检查；真实验收贡献为 **0 拍**，不改变任何现有标签的正式资格，也不修改 App 的模型或速度展示。

## 8. 同轮数学模块最终契约复审

随后实现的 `scripts/ball-flight-fit.py` 已完成第二版审查，SHA-256 为 `53ae97fc77e5c309069ceaa08ba4c6a2e568d148c0a0247aad7aec76652992c5`。它是 NumPy 离线诊断工具，公开 `speed_kmh` **始终为 null**，内部 `fit.candidate_speed_kmh` 仅用于数学检查。本节记录已执行实现，与前文尚待实现的完整敏感性方案分开。

Astra 实际重跑 10 项自检，10 通过、0 失败、0 跳过；另重放 11 个输入反例。此前四项问题均已修复：全体身份不确定、全体插值点均因有效点不足拒绝；`1/0` timebase 与非对象观测均返回结构化拒绝，无异常逃出。缺身份/插值来源、字符串内参、非上三角 K、布尔图像宽度，以及相机/观测来源 SHA 不匹配也正确拒绝。调用方提供的 source SHA 绑定只约束输入一致性，不独立认证相机标定。

实现使用 `(p0,v0*T)` 参数缩放，报告优化终止原因与梯度范数；选中解未收敛则拒绝。局部协方差改由 J 的 SVD 直接构造，避免伪逆 `JᵀJ` 截断弱方向。十个深度缩放初值仍属于同一初始化族，代码已明确不把一致结果当作全局唯一性证明；小步长终止也不证明物理模型正确。

主实现的独立合成试验使用另一组相机与轨迹，不能与第 5 节的 Astra 数值例混合。`independent-flight-20261029/numerical-results-v2.json` 保留 202 个案例；审查核对代码/协议摘要，并由逐条结果重算计数与误差汇总。0.8s/49点、2px 噪声的100次中，79次为 `diagnostic_only`、21次拒绝；全部100个已拟合候选的绝对速度误差中位2.354、P90 6.382、最大11.554km/h。0.1s/7点的100次全部预拒绝。错误焦距加10%的示例仍为 `diagnostic_only`，其误差7.712km/h，说明局部像素噪声门没有覆盖相机误差；全部202个公开速度仍为空。

四个现有真实窗口的拒绝记录均为 `missing_camera_calibration`，候选和公开速度数量均为0；这是输入门控证据，不是四次物理精度测试。上游二维关联或利用标签选出的候选框中心 oracle 结果不补足相机/三维真值，也不能替代本门控。

最终机器审查保存在 `.local/speed-training/independent-geometry-20261029/final-review.json`。结论仅为“允许继续有界数学诊断”，没有阻断该范围的未修复问题；相机/触球时刻/阻力旋转不确定性、独立真实验收与 App 集成都仍未通过。第 4 节建议的稳健损失、完整多初值/留块/相机扰动不是本次已运行能力。

## 9. 2026-10-29：地面加离面点的条件标定分支

前述第一版飞行输入要求保持不变；另新增一个条件相机诊断分支，用于补齐“地标到K/R/t”的数学接口。它不自动成为飞行器的有效相机，也不认证历史视频的未知参数。

### 可辨识条件与合成验证

地面H确定后，写 `P=[h1,h2,q,h3]`。对完整XYZ明确且Z≠0的离面点，令 `a=H[X,Y,1]ᵀ`，观测为 `(u,v)`，则：

```text
Z [1,0,-u] q = u*a3-a1
Z [0,1,-v] q = v*a3-a2
```

单点只给秩2、沿其成像射线仍有一维自由度；两个不同成像射线的点一般给秩3，可解q后恢复一般K/R/t，无须固定中心主点或零skew。地面点本身还须充分分布并确定H；同射线、零高度、有限相机退化或不正深度均拒绝。共享图像归一化和尺度，随后RQ统一全局符号、K正对角、右手R及正深度。相机投影/RQ约定依据[OpenCV官方文档](https://docs.opencv.org/4.13.0/d9/d0c/group__calib3d.html)；上述地面+两点秩推导是本项目明确推导及独立DLT检查，不能归称OpenCV直接给出的结论。

Astra固定场景完成308个合成标定案例：精确10地面+2离面恢复一般K（含非零skew与偏心主点）；每组100个2px像素噪声、2px加2cm高度噪声及低高度反例全部保留。普通离面高度投影约65.5px，2px噪声下离面留出RMS中位4.01px/P95 7.78px；仅1px高度投影时，100例中30例正深度拒绝，其余70例fx误差中位−76.6%，拟合残差仍可能较小。另20例RQ与独立OpenCV分解核对通过。

系统性高度错误尤其危险：真值1.07m误填0.914m，生成飞行的内部速度候选83.93→97.95km/h（+16.7%）；误填0.800m则111.69km/h（+33.1%），地标和飞行重投影仍近零。固定重力不能排除此种相机高度尺度族。规范中的网线支撑高度、中央高度及柱顶像素语义不同，现场安装是否符合仍需证据；[ITF规则第1条](https://www.itftennis.com/media/7221/2026-rules-of-tennis-english.pdf)提供规范，不能证明现场测量。

预先指定的前20个普通像素噪声案例另传播到精确合成飞行，20个内部候选APE中位2.44%、P95 8.21%、最大10.66%；其中17个diagnostic_only、3个被现有拟合器拒绝，拒绝没有删掉。它排除了真实球点、时钟、空气阻力/旋转和畸变误差，不代表20%目标通过。全部23次合成飞行公开速度均null。脚本、冻结协议、逐案结果和推导在 `.local/speed-training/hardnegative-20261029/calibration-study/`。

### 条件相机工具

`scripts/ball-camera-calibrate.py` 实现规范化地面DLT、离面第三列SVD和一般RQ；至少4个有效地面点、2个离面点，`check`不参与求解。它保留H/第三列的谱与条件数，检查有限M、右手R、正焦距、相机在地面上方及全部地标正深度；pose阶段失败暂只给原因，不保留每个失败数值。

输入JSON包含：

- `source`：源SHA、图像SHA/可选本地图像路径、width/height、明确未旋转坐标空间、变换ID、整数帧PTS及有理timebase。可选图像只核摘要与尺寸；视频SHA和帧PTS关系仍须外部来源证据。
- `world`：metres、z向上及既有球场坐标轴。
- `camera_context`：`pixel_model=undistorted_pinhole|raw_unknown`、畸变依据/可选范围、静态声明及依据、有理时间的半开有效区间（必须包含该帧）。
- `landmarks`：唯一ID、`fit_ground|fit_elevated|check`、原像素/XYZ、各自basis（synthetic_exact/declared_assumption/measured_unverified）、像素半径及XYZ各轴半径。radius为调用方声明，未传播，也不是统计置信区间。

输出只有 `camera_candidate`；顶层 `camera=null`、`speed_kmh=null`、`calibration_qualified=false`始终保持。raw_unknown原样保留；basis字符串、小残差、静态声明都不能自行认证。它列出未知畸变/无范围、未传播误差、缺离面检查、检查超过声明半径等原因，不自动调用旧flight/App。11项自检通过、0跳过/失败；另10个真实CLI场景均符合预期（含有意拒绝与已有输出不覆盖），不等于10个真实相机标定。

```sh
BALL_DEV_PYTHON=.local/speed-training/tracknet-smoke-20261028/venv/bin/python
"$BALL_DEV_PYTHON" scripts/ball-camera-calibrate.py --self-test
"$BALL_DEV_PYTHON" scripts/ball-camera-calibrate.py \
  --input /absolute/source-bound-landmarks.json --output /absolute/new-camera-diagnostic.json
```

### 一次已有开发图的条件试算

主智能体查看原train006第0帧及两块局部图后，先冻结输入 `calibration-tool/visual-survey/real-dev-input-v1.json`（SHA0f6f74c0…0020），再执行新工具一次，没有按相机结果调整点位或使用教师速度。四个地面交点由明确白线范围/方向假设下的像素线拟合求交；球场尺寸取规范假设。两个高点XY由同一H反投影柱脚、Z取1.07m假设，误差相关，**不是两个已实测XYZ**。三个未参与求解的检查点仍是同帧agent/规范假设，不是独立物理真值。

本次得到条件K约fx1146/fy1105、条件相机中心高度约1.586m；这些仅是该假设模型的结果，原始拍摄设备、高度、变焦记录仍保持未知。四点地面拟合RMS近0、离面拟合RMS1.21px，但检查RMS10.33px、最大15.91px，超过预先声明的10px半径；最大偏差出现在近端baseline中心标记。尚有raw_unknown畸变、H/柱脚/尺寸相关误差未传播，静态区间也未证明；有效区间仅绑定该帧。

结果明确为未获资格的conditional_candidate，顶层camera/速度均null。没有喂给飞行拟合器、没有得到真实球速或与S家的新误差。下一步需要完善地标语义/畸变与误差传播，独立检查，及触球/无碰撞分段；不能凭看似合理的高度或低拟合残差跳过这些条件。

## 10. 2026-10-29：真实开发帧的条件敏感性检查

新增 `scripts/ball-camera-perturb.py`，调用冻结的条件标定器，不修改地标或自动选择相机。主智能体在执行前冻结输入SHA、helperSHA、seed20261029、128次样本及3个固定高度比例案例；实际协议SHA为 `382be0af60f736d27c8910719721ef26e8b01703d1e8d8cf65ba3a41a678ba80`。输入仍为上一节同一train006第0帧，不增加独立相机、视频或拍摄会话。

该分布是显式声明的敏感性模型：像素每坐标独立均匀±10px，故欧氏位移可达√2×10px；各XYZ沿用输入声明半径。两个假定支撑点在各自独立高度±0.1m之外，再加同一个±0.1m偏差，总高度扰动边界为±0.2m。地面拟合点保持理想Z=0，输入地面Z半径只记录、不传播。同一H推导柱脚XY的相关性、畸变、时钟和真实尺寸误差并未因此解决，均匀分布也不是经现场测定的误差分布。

实际128/128得到代数候选、0代数拒绝；生成候选的相机高度范围1.0848–2.4221m，三个未参与拟合的假定检查点RMS范围3.744–88.418px。仅2个随机案例的最大检查误差≤原声明10px，但没有据此选出“最佳相机”。共同高度−10%/+10%及把0.914m当支撑高度三个固定案例保持拟合离面RMS约1.2104px，相机高度却变为1.4272/1.7444/1.3546m；低拟合残差不能认证尺寸假设。

这些范围只描述生成的条件样本，不是置信区间、严格界限或真实精度。128随机案例、原始基线及3个固定案例共132个保存结果全部保持 `raw_unknown`、`calibration_qualified=false`、公开camera与速度为null；没有运行飞行拟合。原helper的未传播完整不确定性原因保持原样，adapter只覆盖明示的点与共享高度扰动。

7项纯合成自检全部通过、0失败/跳过。Astra另独立核对128个PCG64索引、1,152个地标扰动、3个固定案例、全部摘要极值与132个保存相机的投影/中心；只重算投影，没有重新拟合。输入、原图、协议、helper及adapter前后摘要不变。完整结果、冻结记录和审查在 `.local/speed-training/calibration-uncertainty-20261029/`。该结果进一步说明当前地标假设不足以支持合格测速，未增加任何通过20%验收的击球。

### 与教师的速度定义

当时 S家官方产品说明的搜索索引将球速称为轨迹上的平均速度；直接页面读取只得到JavaScript启动页。该产品措辞不能认证教师字段；第20节已依据分版本导出证据纠正，不能继续据此假定教师为路径均速。003快照的实际推理版本未知；96拍旧test快照的App与推理版本均未知，不得用后来研究的版本反填。现有冻结飞行工具内部 `fit.candidate_speed_kmh` 是首可靠观测参考时刻的速度模长，不是整段平均速度。以上合成误差只对同一定义的合成速度计算，没有证明与S家字段同口径。后续必须明确分段及输出定义，不能把当前内部数值直接拿来验收，也不能乘一个固定经验系数“校准”。

## 11. 2026-10-29：已知触地与重力能否补未知相机

本轮只研究一个有界问题：已知米制地面H、静态无畸变针孔相机、同球无碰撞重力飞行的精确PTS，以及一次真实确认的接触高度r和时刻tb，是否能补足第三投影列q。答案是**一般非退化情形可解，但不是普遍保证**；这不是已经在旧视频上取得标定。

令 `H=[h1 h2 h3]`、`P=[h1 h2 q h3]`。定重力下的齐次成像向量是 `a+b*t+c*t²`；不是普通像素x/y分别对t拟合二次曲线。计时观测的2N×9线性设计在rank8时，只剩共同尺度α，且 `q=-2*α*c/g`。令w为H逆矩阵的第三行，则接触高度约束给出：

```text
1/α = w·(a+b*tb+c*tb²) + (2*r/g)*(w·c)
M = [h1 h2 q]
X0 = inverse(M) * (α*a-h3)
V0 = inverse(M) * α*b
```

分母、相机矩阵、深度与设计秩仍须检查。只有重力而没有接触约束时，改变共同尺度可得到同像、同重力但不同高度/速度的族。恒定像点等退化在接触约束之后仍多解。相机在竖直飞行平面内可令像轨迹共线，但共线本身不必导致rank下降；共同多项式因子、相机位于抛物线延拓上或恒定射线才需要按实际nullspace进一步判定，不能用“共线/残差小”代替可辨识检查。

Astra固定另一组一般K（skew74px、主点1031/467）、49帧/0.8s的合成场景，精确恢复相机中心最大误差约7.64e-14m、K约2.06e-11px；另实际构造rank6恒定像点的三相机反例。预先冻结的24次轻扰动（每坐标±0.5px、接触时刻±8333µs，像素/时间/共同扰动各8次）全部有条件代数解。仅错接触时间的8例仍有约1e-12px残差，但相机高偏差−2.72至+3.73cm，证明重投影不能验证接触身份或时刻。

主智能体另独立推导并用不同相机/轨迹精确复算：49帧恢复P最大误差9.52e-13、速度分量约4.09e-14m/s；共同尺度乘0.8/1.2仍同像同重力，但末端Z分别0.8/−0.5333m，不满足已知地面接触。首次结果写盘因NumPy布尔序列化失败，原脚本/局部结果保留，修复仅为布尔转换与新输出路径，数值未改。该检查不包含噪声或真实录像。

随后另冻结一次且仅一次24例压力试验，原研究四文件不改：A为完整49帧/每坐标±2px；B为完整49帧/±10px；C为同真轨迹最后13帧/±2px；三组均加接触时刻±1/60s。A和B各8/8得到条件解，首观测时刻速度模长APE中位/最大分别0.94%/2.52%、2.24%/6.38%；但B的K最大元素误差中位577px、最大883px，相机高绝对误差可达0.978m。C的8例全部因非正深度被拒绝，主速度误差保持null，没有当0或删出分母。保存的C无效代数参数甚至可在RMS2.687px时对应异常巨大速度，不能救回为有效结果。

这里的APE仅对相同定义的合成首观测速度，不是S家误差。48个扰动及精确/退化/主智能体控制全部公开camera/速度为null、formal=false，未跑真实录像、教师或模型；未改变旧拟合器。真实H误差、畸变、误认、曝光、阻力/旋转和事件区间并未覆盖。结果支持保留数学初始化路线，但短轨与一般K的敏感性尚不足以新增可公开测速的joint solver。本轮不继续追加更好看的例子，先补追踪数据及真实采集参数。

完整推导、冻结协议、逐例结果和原脚本在 `.local/speed-training/joint-camera-flight-20261029/`；压力试验在 `stress-v1/`，主智能体独立精确复核在 `root-check/`。

## 12. 原生每帧相机观测记录

为让后续本App采集素材保留更多证据，新增 `CaptureFrameMetadata`：原始CMTime的value/timescale/epoch/flags、交付尺寸、当前样本K附件、连接方向/镜像/防抖状态及可用的设备查询值。iOS在支持时于startRunning前开启intrinsic delivery；不改防抖以强行取得K，Mac不调用不可用的控制API。依据为[Apple启用契约](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled)及本地SDK头文件。

CoreMedia附件是column-major `matrix_float3x3`；本机布局为48字节、每列SIMD3 stride16。实现把准确48字节CFData复制进对齐的局部矩阵，只取9个逻辑Float，不把padding当数值，也不对原始可能未对齐的Data指针作矩阵load。缺失、错误类型、长度错误及非有限逻辑值逐帧记录原因，不缓存上一K，不自行对180°旋转再变换K。

元数据是小值类型，经现有每帧编码FrameContext写进可选 `StreamHeader.captureMetadata`，随实际写入录像的帧进入原JSONL；没有新增队列、PTS字典或保留相机sample/pixel buffer。源时间/尺寸不匹配时只省略元数据并写受控原因，视频帧照常处理；预览默认不附带。旧v2/旧sidecar可继续没有这些字段。

这只保存观测，不是标定：设备曝光/ISO/zoom/镜头位置是回调时查询，并非证明与该帧曝光锁定；K与旋转/裁切/防抖后的像素对应、真实附件投递及60fps负载仍待实机验证。`intrinsicPixelTransformVerified`和`undistortedPinholeVerified`始终false，未接入球速或把旧视频的未知参数补成已知。


## 13. 真实开发输入：自由相机敏感性与固定先验相机

本轮使用既有 event039 的原图像素与原始 PTS：first=97310/600，假设 contact=97730/600（frame42，相对首观测 0.7s）；g=9.81m/s²、触地球心高 r=0.033m。manual41 为 agent 原像素候选，native BASE40 为实际 `new-train/runs/expanded-sample-039/report.json` 的既有 chosen candidate.originalXY，覆盖 frame0..40，缺失36。不插补、不替换候选、不按人工距离过滤，没有新模型 forward 或教师值。

先前允许相机第三列自由的 H8 联合代数条件解，manual41 首观测速度模长为 10.2442560253m/s，native40 为 37.7198083062m/s；各自二维 RMS 仅 0.557388、2.737843px。27.4755522809m/s 的差异说明该输入/相机模型敏感，不能作为两种输入的物理或 S家误差。原 H8 的近端底线中心留出点误差 7.140843>6px 失败照常保留，全部 accepted 相机/速度均为 null。

另冻结一项独立于球点的相机先验试算：8 个 FIT 地面球场点参与 OpenCV 一次相机拟合，2 个可见 CHECK 点不参与；另外 2 个不可见 CHECK 点保持未知。声明 fx=fy、fx>0、主点 (960,540)、skew=0、径向与切向畸变为零；这些是假设，不是历史设备/镜头元数据。没有拟合球点或根据运动结果选择相机。所得 raw fx=fy=1164.814264659361px、相机中心高 1.5482959639764162m，地面 FIT RMS 1.998325px；两个可见留出点误差 2.725638/1.305307px，分别在先声明的 6/4px 工程半径内。这些是同一帧 agent 与名义场地尺寸条件下的留出检查，不能称独立现场标定；也不追溯修复原 H8 的失败。

随后固定同一 K/R/t，只对两组球点各拟合一次五参数运动。manual41 的首观测 raw 模长为 7.719006741993999m/s、RMS 1.295496207426332px；native40 为 7.219615153239933m/s、RMS 2.872035383084572px。每点误差分别均在 9/15 原像素工程界内，观测中心未穿假设地面。两例均 6 次 GN 停止。这里只报告相同固定相机下的条件代数结果；不能因输入差变小而认定更准确，也不是触拍初速、触地速度或整段平均值。

原始畸变、静态机位、名义球场尺寸、触地 frame42、起始触拍缺失、完整无碰撞/触网区间、阻力/旋转、来源族曾用于训练及独立物理参考缺失等限制全部保留。ground-camera-prior 的验证仅证明公式/文件一致性；正式相机、速度及 20% 资格仍为 null/false。完整私有协议和结果位于 `.local/speed-training/native-flight-sensitivity-20261029/` 与 `.local/speed-training/ground-camera-prior-20261029/`。

## 14. 共享 Swift 固定相机诊断接口

`Sources/CourtCore/IndependentAnalysis/IndependentBallisticDiagnostic.swift` 提供 public Sendable/Codable 值类型，Mac/iPhone 可直接调用 `IndependentBallisticDiagnostic.fit(_:)`。它只接受显式固定相机，输出开发诊断；未接入 `CameraSideAnalyzer`、机位采集或默认 App 后端。CLI 不打开相机、不加载模型：

```sh
swift run court-analyze independent-flight /absolute/protocol.json /absolute/new-output-directory
```

协议顶层 `schema` 必须为 `independent-fixed-camera-flight-diagnostic-v1`，必要字段如下：

- `input.camera`：同一个 `sourceID`、原图 `width/height`、一维 row-major `rowMajorK`/`rowMajorR`（各 9 项）、`t`（3 项）与非空 `assumptions`。约定为 camera=R×world+t，K×camera 按第三分量除成像素；不把 t 当相机位置。K 必须有限、上三角、正 fx/fy、底行 (0,0,1)；R 正交且 det=+1。
- `input.frames`：3..4096 个按 `frameIndex` 和精确时间递增的同源条目，至少 3 个实际观测。每条有 `sourceID`、`time`（`sourcePTS`、正 `timeBaseNumerator/timeBaseDenominator`），以及在原图范围内的 `originalPixel: {x,y}`，或非空 `missingReason`；两者不能矛盾。缺点保留，不插补；调用方须提供原始观测与来源证据。
- `input.contactTime`：与帧时间同格式，严格晚于所有输入帧。先用无舍入、无溢出的 CMTime 差，再转 Double；不相减巨大绝对 Double 时间。跨来源、重复有理时间、无效时间、越界像素等输入被拒绝，Codable 解码同样校验。
- `input.configuration`：`gravity`（正有限）、`contactCenterHeight`（非负有限）、`residualBoundPixels`（正有限的径向工程残差界）、`maximumGaussNewtonIterations`（1..10）、`maximumScaledJacobianCondition`（1..1e6）。工程界不是统计 sigma、置信区间或球的物理半径；不增设经验速度范围筛选。
- `evidence_files`：1..64 个不同的绝对路径，各含 `path`、小写 SHA256 `sha256`、非空 `role`。协议最多 8MiB，每个引用文件最多 256MiB、总计 512MiB，须为普通文件且路径不含符号链接。协议和引用文件在求解前后都核验；输出目录必须新建，完整 `report.json` 以排他原子目录发布，已有输出不覆盖。

运动公开 raw 参数为 `[xb,yb,vx,vy,vzb]`，以 dt=t−contactTime：

```text
X = xb + vx*dt
Y = yb + vy*dt
Z = r + vzb*dt - 0.5*g*dt²
```

内部为对照冻结 Python 的缩放坐标 `[x0,y0,vx*T,vy*T,vz0*T]`，T 为 contact−首个实际观测。初值用单位成像射线的线性五参数最小二乘，随后按原像素重投影与解析 Jacobian 做最多 10 次 full-step Gauss–Newton。使用列主元 Householder QR 解最小二乘；列缩放 Jacobian 的 Gram/Jacobi 只诊断条件数，不用正规方程求解。无稳健损失/阈值搜索、多初值、相机再拟合或教师初始化。单步模长<1e−10停止；SSE 增加超过 1e−9×max(1,SSE) 则拒绝且不重试。非有限值、秩不足、病态、≤0.1m 相机深度或触地约束失败均拒绝；有限 raw 结果超残差界或穿地则保留 raw 并标质量失败。

`rawMotion` 明确保存首个**实际观测时刻**的位置/速度/模长、触地中心参数和缩放坐标。它是未合格代数诊断，不能作为公开测速。`acceptedCamera`、`velocity`、`speedKilometersPerHour` 始终显式 null；`physicalAccuracyValidated`、`cameraQualified`、`human`、`formal`、`production`、`nativeEndToEndSpeedAccepted`、`twentyPercentAcceptanceEligible` 始终 false。即使数值质量通过也不能提升这些字段；输入中的资格为真或 accepted 值非空会被拒绝。失败指标保持 null，不补 0。

实际两个 CLI 案例分别输出 41 点/0 缺失与 40 点/缺失36，并绑定 52 个运行前后不变的证据文件（相机先验、agent 包及补点、实际原生 Core ML 报告、41 张原图及实现）。原生 raw 模长为 7.7190067419939945、7.219615153239935m/s，与 Python 绝差 4.44e−15、1.78e−15m/s；RMS 绝差 1.20e−14、3.55e−15px，均为 6 次 GN。已有输出、错误证据 hash 与嵌套非法资格声明的 CLI 拒绝也已验证。完整数值对照在 `.local/speed-training/native-ballistic-20261029/verification.json`，SHA256 `3e442e942af3589068ed03c312177d03420b69079de9facecaf8e32b75f80bea`。

新增 `IndependentBallisticDiagnosticTests` 的 12 项定向测试：12 通过、0 跳过、0 失败，覆盖独立生成的非单位相机/非零 skew 与重力轨迹、不规则有理 PTS/巨大绝对时间、缺失、噪声、质量拒绝、负深度、短时跨度/秩退化、非法 K/R/来源/PTS、非有限派生值与公开空值语义。完整 Swift 共 111 项：106 通过、5 按需跳过、0 失败；5 项分别为实机看板、原生 Core ML 私有夹具、Pillow/JPEG 私有夹具、公开视频标定、真实模型 TLS 镜像。两次真实输入 CLI 数值对照单独计数，不把跳过当通过。

本轮仅证明固定相机运动核心的原生数学与 Python 对应关系，没有新增合格物理速度、人审或最终未见会话。逐拍 APE≤20%、覆盖率≥90%、事件 precision≥95% 及默认 App 完整独立测速链仍未验收。


## 15. 显式区间的原生路径平均速度诊断

`IndependentBallisticIntervalDiagnostic.swift` 新增 public `evaluate(input:request:)`，自行调用同一输入的固定相机拟合一次，返回 `(fit, rawInterval)`；接收外部 `(input, fit)` 的配对入口不公开，避免同索引的另一来源/相机/重力结果被重标为本输入。sourceID、原非缺失观测时间包络、contactTime与重力均继承已验证输入；全部原非缺失观测仍参与拟合，不因请求区间而裁剪。原 `fit.status`、质量标记与资格原因保留，积分成功不会把原质量失败升为通过。

沿用第14节同一个 v1 输入/输出 schema，不改名。顶层增加可选 `interval`；省略时 CLI 原求解和报告路径不变，提供时在原 `diagnostic` 之外增加 `interval` 与 `rawInterval`。请求字段为：

- `start`、`end`：与源帧相同时间线的 `sourcePTS`、正 `timeBaseNumerator/timeBaseDenominator`；严格 `start < end <= contactTime`。contact端点是触地前入射速度左极限，不含碰撞后的速度。
- `knownCollisionTimes`：同格式的已知碰撞时间列表。起点及原始首个非缺失观察须严格晚于每个已知前碰撞；起点恰等于边界也保守拒绝。碰撞不能靠外推许可跨过，也不能裁掉碰撞前的原观测后挽救拟合。空列表不证明没有未知碰撞。
- `collisionFreeAssumption`：必需的非空有界说明，明确同一入射无额外碰撞支仍是假设；它不会认证碰撞自由。
- `extrapolationReason`：可选非空有界说明，省略即禁止超出全部实际非缺失观测的首末包络。结束在最后观察之后的contact同样属于外推；声明许可只解释包络外延伸，不覆盖碰撞禁令。

在固定重力模型下：

```text
v(t) = [vx, vy, vzb - g*(t - tb)]
rawMeanPathSpeed = (1/(end-start)) * integral(start..end, ||v(t)|| dt)
```

`rawMotion.velocityFirstObservedNormMetersPerSecond` 仍是首个实际观测时刻的瞬时模长。新 `rawInterval` 另外记录明确区间、duration、原观测包络、重力、起末速度向量/模长、高度、平均路径速度及 `didExtrapolate`。路径均值不是 `||p(end)-p(start)||/Δt`；竖直上升再下降也累计两段路程，不能让有符号位移相抵。这里没有读取教师或推断教师区间。

时间先做无舍入的精确CMTime差，端点偏移拆为整数秒高/低部与带除法残差补偿的有理小数部，再直接FMA计算竖速，避免巨大触地偏移吞掉短区间差，以及先归一化重力引入的取消误差。积分在归一化 `[0,1]` 上缩放速度分量，避免原函数差分消减与先积距离再除微小时间；常速与水平速0有独立极限分支，跨顶点按绝对竖速积分。其余采用8/16点Gauss–Legendre自适应，所有叶区间的差累计到一个全局绝对/相对容差，实际函数求值上限4096；预算耗尽、中点不可区分或非有限值均拒绝。输出的 quadrature difference 只是数值估计，**不是严格浮点误差界或物理误差界**。公开输入仍要求g>0，g=0只在内部数学极限测试覆盖。

若原拟合质量失败、入射触地竖速为正、区间任一端点球心低于假设接触高度，有限raw可以保留但 `rawIntervalQualityPassed=false`；无raw/非法尺寸、非有限参数、不同原观测索引、非法时间或不能积分则拒绝。独立编码的 `rawInterval` 同样显式输出 `acceptedCamera`、`velocity`、`speedKilometersPerHour=null`，以及 `physicalAccuracyValidated`、`cameraQualified`、`human`、`formal`、`production`、`nativeEndToEndSpeedAccepted`、`twentyPercentAcceptanceEligible=false`。raw代数质量通过始终不等于物理或产品验收。

### 单拍条件开发对照与验证范围

实际对照使用已暴露source003/train007，38..82保留全部41个原生BASE候选，缺失38/80/81/82，非缺失包络39..79；没有新模型forward、相机拟合或训练。主触地84、另两个端点诊断83/85及弱起拍36在读取教师速度前冻结，三个协议全部执行并保留，不能按教师接近程度挑最好者。三个平均路径速度依次为82.0182469、90.5161182、74.8930728km/h；主84起末速度81.1530518/84.4769758km/h。固定 S家 App 导出第76行标量82.242088km/h在原生报告冻结后读取，主例临时绝对差0.2238411km/h、相对差约0.27%。

这些数值不是正式APE或总体误差：同相机strict8图像复用检查仍失败；起拍36、触地84/83/85都是弱agent图像假设；区间超出native39..79，需要显式外推；名义尺度、静态/畸变、额外碰撞、阻力/旋转未认证。003快照的实际推理版本未知，该旧标量的计算区间及时间定义未知，后续证据也不支持把它当路径均速（见第20节）。三个raw代数质量通过不消除上述限制，formal APE/MAPE/coverage/matching precision全null，已接受速度null、人审/正式/生产/20%资格false。

最终新增10项定向测试全部通过、0跳过/失败；覆盖独立解析与复合Simpson golden、竖直/常速、极小水平速跨顶点、巨大PTS、距触地1e9秒时的1ns顶点区间、边界/碰撞/外推、原失败及资格空值。3项合成CLI复测通过（legacy对象不变、解析均值对照、无许可外推拒绝）；三次实际开发输入CLI与独立高精度mpmath均值差小于6e−15m/s。该阶段完整Swift套件121项：116通过、5按需跳过、0失败，未把设备/私有模型等跳过项算通过。Astra最终只读代码审查无未解决阻断，审查本身未执行测试。源码、审查和测试日志在 `.local/speed-training/native-interval-20261029/`，三份实际协议、冻结/失败检查及对照在 `.local/speed-training/serve007-root-20261029/`。本轮只验证诊断软件与条件数值，没有新增合格物理真值、独立最终会话或默认App测速后端。


## 16. 无需输入触地时刻的六参数原生诊断

`IndependentFreeFlightDiagnostic.swift` 提供 `IndependentFreeFlightInput` 与 public `fit(_:)`；`court-analyze independent-free-flight PROTOCOL_JSON NEW_OUTPUT_DIRECTORY` 使用独立 `independent-free-contact-flight-diagnostic-v1` / `independent-free-contact-flight-result-v1` schema。它不改变第14/15节固定contact的接口。输入包含同一 `IndependentBallisticCamera`、原帧及 `IndependentBallisticConfiguration`，没有contactTime；解码明确拒绝contactTime/groundTime及教师速度/XYZ。32..4096个源条目且至少32个实际观测，原PTS/像素/缺失原因全保留。

以首个实际观测为原点τ=0，拟合六个参数：

```text
p(τ) = [x0, y0, z0] + [vx, vy, vz0]*τ - [0, 0, 0.5*g*τ²]
v(τ) = [vx, vy, vz0 - g*τ]
```

固定假设K/R/t和g，由成像射线线性初始化六列系统，再对原像素重投影作最多10次full-step GN；精确CMTime局部相减后才转Double。按观测跨度T缩放为 `[x0,y0,z0,vx*T,vy*T,vz0*T]`，QR求解；单侧Jacobi奇异值诊断不平方条件数。原生门明确覆盖秩/条件、正深度、非有限目标、目标增加、未收敛、高残差和观测穿地。相机与重力可一般性约束角曲率中的米制尺度，但短跨度、小曲率或恒定视线仍可能不可辨识，不能用“有g/点多”代替条件检查。没有根据弱触地候选固定高度/时间来减少六参数。

拟合后再解 `Z(τ)=contactCenterHeight`，输出未来下行根与超出最后实际观察的外推时长；根是相对首观测的浮点秒数，不是观测事件，也不round成精确有理PTS。`rawMotion`的模长仍对应首观测，既不是触拍初速，也未确认与旧教师标量同口径。未来根/有限代数质量与视觉事件一致性各自保留，公开 `acceptedCamera`、`velocity`、`speedKilometersPerHour`显式null，物理、人审、正式、生产及20%资格false。

### 实际输入、控制与失败保留

三组已有开发输入007、039manual、039native原生首观测raw模长为24.1735178、8.5478513、8.5647191m/s，未来地面frame分别约83.282588、41.347222、40.909516；007以首观测39为原点，039以0为原点。007的弱视觉支持83..85，039为41..43；**039native的40.909516在支持外0.090484帧，事件一致性失败保留，不round到41、不扩容差**。039两输入模长差约0.0168678m/s只说明该相机假设下的有限输入敏感性，不能认证噪声、相机或速度。007的strict8相机复用失败、039名义场地/居中主点/方形像素/零畸变先验、未证无碰撞及阻力/旋转等限制均保留。本轮没有新增教师比较。

独立精确41点控制恢复参数约6e−15；41点/10微秒控制因秩5、条件约1.112e11拒绝，恒定视线控制秩4/零列拒绝。Python首进程在最后零列控制触发异常、未完成批保存；技术恢复只改零列失败处理和立即逐例持久化，原失败/恢复冻结留存，三个真实输入各实际初始化/拟合两次，不称仅执行一次或多个初始化搜索。只读独立验证38项通过，包含源/输入、原PTS/观测、SVD、有限差分Jacobian、驻点和80位触地根；没有新增独立拟合或物理真值。

原生10项定向测试在显式启用三组私有输入后10通过/0跳过/失败；另三次CLI分别核验56/51/51个证据文件。Python/Swift最大位置差1.60e−14m、速度分量差2.14e−14m/s、地面时差3.34e−16s、RMS差1.07e−14px。首次测试编译因Int64/Int32 timescale声明失败、修该声明后执行成功；日志保留。实际三组输入在定向parity测试和CLI各拟合一次，均没有新模型forward/相机拟合/训练。证据以 `.local/speed-training/free-contact-flight-20261029/{REPORT.md,NATIVE_REPORT.md,native-verification.json,native-code-freeze.json}` 为准；默认全套不启用该私有夹具时会跳过，不能把定向通过替代默认执行。

## 17. 可复用本地视频分析与独立资源边界

`IndependentBallModelAssets` 只定位/验证 `IndependentModels/tracknetv3-base-v1/{manifest.json,LICENSE,README.md,TrackNetV3Base.mlpackage}`；固定manifest SHA、完整三文件集合、各字节与MIT通知都须通过，不读取S家模型目录或运行时下载。约45MB原包在 `assets/independent-model-weights/tracknetv3-base-v1/` 走Git LFS，文本清单/许可在 `assets/independent-models/tracknetv3-base-v1/`。`COURT_MODEL_SET=independent` 打包该集合并排除AnalysisModels；code-only排除两套，旧模型locator在两种模式下都拒绝private环境覆盖/资源回退。Mac、iOS设备SDK、iOS模拟器SDK独立构建及三bundle模型字节/无private资源检查通过，仍不证明真实设备推理。

`IndependentLocalVideoAnalyzer.run(request:assets:observers:progress:)` 与CLI共用实际reader→window→CoreML→bank/tracker，不另写第二套算法。typed请求实际读源PTS，可选track/range/ROI，默认nominal元数据60fps与120秒/7300帧上限；CLI显式保留旧declared FPS关联参数及冻结预期时间核查。结果保留每个预热、缺失、断层舍弃及不足8帧尾部原因，包含source/model/backendID、原CMTime、图像变换、窗口/段和available-at。已接受相机/速度/球速字段始终null，物理/人审/正式/生产等资格false，尚不产生事件或几何速度；第14..16节需要的固定相机、分段/事件与原像素绑定仍由调用者提供。

哈希按块autorelease/取消，CoreML和模型状态只在专用串行后台队列创建、执行和释放，取消在每个前导丢弃样本前也检查，不在另一队列抢读/取消reader。非identity方向继续拒绝。13项新增共享/取消测试与4项资源模式测试通过；另复用7项已有reader测试，不重复当新增。App后续已接入第18节的「本地视频实验」导入与候选浏览；事件确认及完整独立测速UI仍未接入，资源集合选择不会自动替换原机位分析，独立构建保持private模型不可用。

共享CLI实际回归的三个冻结开发窗train007/slow002/sourcecheck080共504解码/360输出/45forward，所有旧确定字段（包括PTS/RGB、背景/tensor/heatmap摘要、完整selection/bank/关联）逐字段相同，仅排除计时字段。最初Debug尝试在21个RGB缩放、0forward时因确认的未优化CPU瓶颈人为停止，退出143/partial证据保留；随后冻结Release优化构建修订，不改输入/算法/参数/预算。该回归通过只证明共享实现兼容；没有新球速验收或训练。意图/修订/三case及汇总在 `.local/speed-training/independent-app-integration-20261029/`，最终完整默认Swift套件148项，142通过、6按需跳过、0失败（170.28秒）；新增跳过为未启用的freeflight私有实际输入，显式env定向10项通过另列，不能计入默认通过。详情见本轮验证记录。


## 18. App本地视频实验的候选与空值边界

角色选择页以 `IndependentVideoLabModel` / `IndependentVideoLab` 调用共享本地视频分析器，接受本机60fps视频、起点与最多120秒，保留真实PTS、预热/缺失与原图单帧坐标；时间/尺寸不精确时不叠加候选。支持取消、重新分析、画面与报告保存重试。独立资源构建仅带约45MB MIT TrackNet；报告保存在Application Support的 `Zacks Court/IndependentRuns`，不复制视频，不写入会话/历史。当前没有触拍/触地事件或可信相机，所以不调用第14..16节生成产品速度，界面球速始终「—」并给原因。

22项受控模型测试累计通过（21项同轮、后补1项本地化），另1项真实Release XCTest使用同App模型/服务，仅换测试宿主Bundle：旧source003/train007窗168解码/120推理帧/15forward；第87帧PTS233450/600、原图(1395,465)精确对应，全部旧轨迹与张量摘要一致。模拟器空页、选片取消、实时模式隔离在正常/最大辅助字号各3项通过。证据位于 `.local/speed-training/independent-video-lab-20261029/`；尚未证明SwiftUI选择真实视频至推理全链、系统文件提供器授权或手机推理，更不证明几何与球速精度。

## 19. 四个软件发球窗口的事件与无接触时刻诊断

四窗074/018/057/041保留既定顺序和全部分母，来自已暴露source003。agent图像事件候选先冻结，再核对软件行身份与时间；不读取教师速度/XYZ，不称人审或正式事件。074弱触拍35..37、触地89..91；041触拍19..22、触地61..63。041软件行90锚35.2012晚于视觉触拍220–270ms，同拍身份未知，不能用该锚替代接触时刻、换相邻行或做教师速度误差比较。018/057的疑似触网候选分别63..66/63..67，触网前最多27/23帧，低于32观测门，预先拒绝，不跨网外推真实落地。

074与041各用一次既有Release `independent-free-flight`，固定未认证camera039，输入原生50/37实际点，分别保留缺失38/23；不输入contactTime，不重拟相机、扩帧、替换候选或重试。两个raw代数质量通过，预测未来下行地面frame91.24450697/61.60458346。074超出冻结89..91支持0.24450697帧，事件一致性失败照录，不round、不扩门；041在61..63内仅说明弱候选一致，不能解决软件同拍映射。相机跨时段复用、名义尺度/畸变、无碰撞与阻力旋转均未认证。

独立标准库复核239项通过、0失败，核对证据摘要、原点/PTS、投影/残差、下行根及空值资格，不是新增拟合或物理验证；秩/条件仍为原生报告值。分母4、拟合2、预先拒绝2、合格完整飞行0；新增模型forward/相机拟合/训练0，公开相机/速度/球速null，human/formal/physical/production/20%资格false，没有新增S家误差结论。私有原始事件、复核和结果分别在 `.local/speed-training/serve-batch-events-20261029/events.json`、`serve-batch-review-20261029/independent-review.json`、`serve-batch-freeflight-20261029/{result.json,REPORT.md,verification.json}`。


## 20. 保存分析报告到条件瞬时触拍速度

`IndependentFlightCandidateBuilder` 的typed `analysis:` 与 `savedAnalysisJSON:` 两入口把同一原生候选、原PTS和显式证据送入既有六参数freefit，不重选点、不插值、不拟相机。CLI `court-analyze independent-flight-candidate PROTOCOL_JSON NEW_OUTPUT_DIRECTORY` 绑定保存报告路径/SHA，重放不重验原视频、零ML。缺相机/区间端点保持unknown；结果保留实际观测区间的路径均速，并以可选 `contactCandidateWindow` 的精确有理中点计算同一拟合的瞬时速度。触拍窗不得晚于首观测；向前外推须显式理由且不能跨声明中断。窗内速度范围检查两端和内部竖直顶点，不是物理置信区间。

速度定义纠正：本地对 S家 App 两个版本的研究表明，一版导出取最终速度向量模长；另一版从端点恢复区间初速度，且存在后处理/覆写。逐行计算区间与起止时刻未知，两版本不能拼成完整同一运行。早期“教师平均速度”及约0.27%接近不构成同口径证据；今后主要开发量为独立触拍时间的瞬时模长，均速作辅助，不按教师值择优。分版本来源只在本地，见原工作区 `.local/speed-training/native-flight-candidate-20261029/teacher-speed-semantics.md`。

007实际观测39..79的41点重放参数与原freefit一致；条件均速87.831894366km/h，首观测87.024664072km/h。触拍34..37的中点35.5（PTS233415/600）向前外推58.333ms，条件值87.09223691km/h，窗内87.05731441..87.13609180；相机039转移failed strict8及物理限制全部保留。公开速度/相机null，formal/human/production/physical/20%资格false，没有新同口径误差。

Builder11项包含在最新完整Swift182项中：175通过、7按需跳过、0失败，179.39秒。实验UI正常/最大字号各3项通过；默认旧回归3项中1通过、2横屏断言失败，方向复查失败，根因未知。未启动手机，合并最新main后的SDK验证待补。研究草稿MR的下一步是本视频相机证据与敏感性、独立事件分段和更多开发拍、App/实机链，最后独立冻结100拍/3会话/2条件；正式验收仍0。可执行命令与数据边界见 [交接说明](independent-speed-handoff.md)。
