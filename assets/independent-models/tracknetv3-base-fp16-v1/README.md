# TrackNetV3 base FP16 v1：独立球定位研究模型（神经网络引擎版）

此目录只保存版本清单、许可证和说明，不包含权重。权重与 [tracknetv3-base-v1](../tracknetv3-base-v1/README.md) 来自同一份作者发布的羽毛球 TrackNetV3 基础检查点（MIT），用 `scripts/convert-tracknet-fp16.py` 从同一份 torch.jit 跟踪文件转换为 **FP16 计算**的 Core ML ML Program，供实时链在神经网络引擎上运行。它是研究用球定位器，**不是合格球速模型**。

- 固定上游提交：`6eda442ada1740573f200f836d93edc9a541ee86`；MIT 原文保存在 `LICENSE`，复制或分发模型时须同时保留。
- 跟踪文件、转换脚本、对应 FP32 清单、转换报告与三份包文件的摘要都在 `manifest.json`。
- 输入输出接口与 FP32 版相同：`frames` float32 NCHW `[1,27,288,512]`（背景 RGB 在前，再八帧 RGB，除以 255），`heatmaps` float32 `[1,8,288,512]`，含 sigmoid。

## 与 FP32 的差别

只有计算精度不同，所以结果只能按容差对照，不能要求逐位一致。转换时在 Apple M4 Pro 上对 test.MOV 的 3 段画面（24 张热图）对照：

| 计算单元 | 每次推理（8 帧） | 与 FP32 CPU 的最大热图差 | 峰值位置 |
| --- | ---: | ---: | --- |
| 神经网络引擎 | 14 ms | ≤0.004 | 相同 |
| GPU | 46 ms | ≤0.004 | 相同 |
| CPU | 46 ms | ≤0.027 | 一处低分（0.09）弱峰换到另一处 |

FP32 版在 CPU 上为 133 ms；请求神经网络引擎时实际退回 CPU。这些数字不证明 iPhone 性能、网球定位精度或球速精度。

## 本机校验与暂存

```sh
python3 scripts/prepare-independent-ball-model.py verify \
  --source assets/independent-model-weights/tracknetv3-base-fp16-v1/TrackNetV3Base.mlpackage \
  --manifest assets/independent-models/tracknetv3-base-fp16-v1/manifest.json
```

`scripts/prepare-independent-app-models.sh` 同时校验并暂存 FP32 与 FP16 两个版本。
