# 1.4 准备说明（不发布）

线上版本是 **1.3 (1)**。本分支只准备下一版，**没有**上传 IPA、**没有**在 App Store Connect 新建版本、**没有**提交审核、**没有**发布，也**没有**改主语言。主语言已由父助手设为 en-US，这里不再调用 ASC。

建议的营销版本是 **1.4 (1)**：`apps/iphone/project.yml` 的 `MARKETING_VERSION` 是 `1.4`，`CURRENT_PROJECT_VERSION` 是 `1`。1.3 已上架，不能再往 1.3 里塞构建。归档前由有证书的 Mac 用只读的 `asc builds next-build-number --version 1.4` 核对构建号仍是 1；本环境没有执行这条命令。

## 这一版相对 1.3 的用户可见变化

- App 与浏览器看板的界面、错误提示和权限用途文字可以是简体中文、繁体中文、英语、日语、德语、法语。en-US 与 en-GB 共用英语界面。
- 启动前（尚未 `activate()`）文案仍是简体中文键，测试和启动顺序靠这个。App 在创建会话和界面之前就激活语言。
- 激活之后按用户的语言列表选第一项支持的语言。简体、繁体仍按标签明确分开。列表里没有任何支持的语言时用英语（en-US），与商店主语言一致。词表缺一条时仍显示简体中文原文，那是缺译，不是语言回退。
- 球速仍是 km/h，不换算成 mph。简体中文的数字格式与原来的 `String(format:)` 相同。其他语言用该地区的小数点。
- 司线语音仍是已录好的英文 “Out!” / “In.”。设置里的说明被翻译，没有新的语音文件，也没有新的网络服务。
- 局域网、个人热点、点对点的连接方式没有变，没有新权限。权限弹窗的三句用途文字按系统语言显示。

日语、德语、法语的商店长描述在父助手处，本仓库只放了「新功能」草稿（`metadata/version/1.4/`），没有上传。

## 必须在 Mac 上做、这里没有做的事

本环境没有 Xcode，**没有**编译 iOS，**没有**录屏，**没有**生成新的商店截图。

1. 用一份干净检出（不要用那台未推送 ahead 12 的 Mac mini 工程）生成工程：`COURT_CODE_ONLY=1 ./scripts/generate-ios.sh`，确认 `scripts/reference-chain.sh status` 为 off。
2. `./scripts/capture-store-ui.sh <新建的 iPhone 模拟器 UDID>` 为六种界面语言各跑一遍 `testStoreScreens`。原图在 `docs/app-store/screenshots/source/raw/<语言>/`。en-US 与 en-GB 共用 `raw/en/`。
3. 宣传帧用 `python3 scripts/render-store-frames.py`（Pillow，不打开浏览器）。它只贴 `capture-store-ui.sh` 写下的真实截图，缺图就停。`render-store-screens.sh` 仍要 Chrome，这轮不要用它来补画面。
4. 预览视频每种语言单独录，不要复制文件：`./scripts/record-store-preview.sh <UDID> <目录> <语言>`。
5. 创意素材模板不再画 149 km/h 和 OUT 卡片。没有真实界面截图时不要把它当成 App 截图上传。

## 相对已发布 1.3 源的代码

PR #62 已合并。合并提交是 `52f5c39e4abf89be26d48ea322f2554ceaa11984`，PR 头是 `61889a7117ea181b2b2e1794d78cfded243cbb42`（版本号与 1.3 商店说明）。该提交是当前 main 的祖先。

main 在它之后还有：机位每秒记录区域姿态次数（PR #63）、跟到地面的来球可以落地（PR #64）、采集日志里的曝光和 ISO。这些会改变同一段录像的发球/落点估计，**没有回退**。1.4 的「新功能」应同时写明界面语言和「同一段录像的结果可能与 1.3 不同」。
