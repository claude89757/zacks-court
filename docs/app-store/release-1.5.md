# 1.5 准备说明（不在本环境上传）

线上版本是 **1.4 (1)**，2026-11-14 已批准并自动发布。这一分支准备 **1.5 (1)**：`apps/iphone/project.yml` 的 `MARKETING_VERSION` 是 `1.5`，`CURRENT_PROJECT_VERSION` 是 `1`。1.4 已上架，不能再往 1.4 里塞构建。

源是远端 `main` `bd08d279fc1efd3f4fcdebad6200064d4c6cd11f`（PR #66），再并入已上线的六语 `9dd718df115aff6abec8fa1c00d58108d519a43f`。没有使用 Mac 上未推送的 `ebfb49bf`。

## 相对 1.4 用户能看到的变化

- 低机位、浅色场馆里，自动找场会用地面颜色避开屋顶白梁。浅色背景上的发球更容易被跟住。
- 手机只是轻度升温时，预览和人员检测保持全速。温度到「偏高」、相机有压力、开了低电量，或分析持续跟不上时，才降载。录像仍是 1080p60。
- 六种界面语言与 1.4 相同。没有支持的语言时用英语。球速仍是 km/h 的模型估计。出界语音仍是英文 “Out!”。
- 没有新权限。诊断包多记记录时的界内外开关、单双打和判定范围，仍只在用户自己导出时离开这台设备。

室内录像和参照软件对上了多少条，只写在验证记录里，不写进商店「新功能」。

## 归档

在新目录里、不设 `COURT_CODE_ONLY`、不设 `COURT_MODEL_SET`，运行 `./scripts/generate-ios.sh`。日志应写 `COURT_MODEL_SET=independent`，`scripts/reference-chain.sh status` 为 off。然后 Release Archive。

归档出来的 App 应是 `CourtModelSet` = `independent`，版本 1.5、构建号 1，两套自研模型都在，没有 `AnalysisModels`，二进制里 `LocalReferenceChain` 为 0，六个 `InfoPlist.strings` 和 `l10n.json` 都在。仓库里的 `Info.plist` 仍写 `sjia`，以归档产物为准。

本环境没有 Xcode，没有归档，没有上传，没有在 App Store Connect 建版本。
