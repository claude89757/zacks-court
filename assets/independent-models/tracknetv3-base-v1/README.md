# TrackNetV3 base v1：独立球定位研究模型

此目录只保存版本清单、许可证和说明，不包含权重。模型来自作者发布的羽毛球 TrackNetV3 基础检查点，转换为 float32 Core ML ML Program。它是研究用球定位器，**不是合格球速模型**，不含击球识别、三维几何或速度估计。

- 固定上游提交：`6eda442ada1740573f200f836d93edc9a541ee86`。
- 作者代码与预训练检查点的 MIT 许可证原文保存在 `LICENSE`；复制或分发模型时须同时保留该许可证。
- 原始检查点、下载归档、源码、转换报告与最终三份包文件的摘要均在 `manifest.json`。
- 此目录不会自动下载、打包、发布或替换 App 的旧模型。必须显式提供本机模型包并选择新的暂存目录。

## 固定声明接口

输入 `frames` 是 float32 NCHW `[1,27,288,512]`：背景 RGB 在前，其后为八张真实连续帧的 RGB，除以 255。输出 `heatmaps` 是 float32 NTHW `[1,8,288,512]`，含 sigmoid。

算法版本为 `tracknetv3-rgb-native-median48-bicubic-v1`：同一窗口预先固定的 48 张原尺寸 RGB 图先逐像素取中位数、转 uint8；背景与八帧分别使用同一视野裁切，再以 BICUBIC 缩至 512×288。背景包含未来帧，**只适用于离线研究**。不能无验证地改用实时背景、其他缩放器、补帧或 InpaintNet。

转换参考流程实际使用 Pillow 11.3.0；旧开发数据准备曾使用 Pillow 13.0.0。算法名称不随软件包版本命名；两版本原始 RGB 预处理等价性尚未在本清单中证明。

部署目标声明为 iOS 17 / macOS 14，Core ML specification version 8。现有证据只覆盖这台 Mac 上 CPU float32 的转换一致性检查（8 段输入、64 张热图），不证明真实 iPhone 运行、其他设备性能、网球定位精度或球速精度。模型尚未完成正式验收，不能自动发布。

## 本机校验与暂存

```sh
python3 scripts/prepare-independent-ball-model.py verify \
  --source /absolute/TrackNetV3Base.mlpackage \
  --manifest assets/independent-models/tracknetv3-base-v1/manifest.json
python3 scripts/prepare-independent-ball-model.py stage \
  --source /absolute/TrackNetV3Base.mlpackage \
  --manifest assets/independent-models/tracknetv3-base-v1/manifest.json \
  --destination /absolute/new-staged-directory
python3 scripts/prepare-independent-ball-model.py --self-test
```

`verify` 只检查固定字节、完整文件集合、包内关系与声明契约，不编译或执行 Core ML。`stage` 复制许可证、清单、此说明与原模型包，生成 `receipt.json`，再以系统的原子“不覆盖”重命名发布新目录；已有目录、符号链接、LFS 指针、缺失或额外文件、额外空目录、大小或摘要错误均拒绝。工具不修改源包、Python 环境或默认 App 资源。

上游：[固定源码](https://github.com/qaz812345/TrackNetV3/tree/6eda442ada1740573f200f836d93edc9a541ee86)、[MIT 原文](https://github.com/qaz812345/TrackNetV3/blob/6eda442ada1740573f200f836d93edc9a541ee86/LICENSE)、[作者检查点入口](https://drive.google.com/file/d/1CfzE87a0f6LhBp0kniSl1-89zaLCZ8cA/view?usp=sharing)。
