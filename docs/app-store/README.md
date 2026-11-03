# App Store 上架材料（iOS 1.0）

App Store Connect 里的记录：Zacks Court，App ID `6827224757`，Bundle ID `com.claude89757.zackscourt`，SKU `ZACKSCOURT-IOS`，主语言简体中文。用 `asc`（App Store Connect 命令行）读写，见文末。

## 1. 现状

**2026-11-03 已提交审核**，状态 `WAITING_FOR_REVIEW`（提交 ID `21769708-ee46-428b-956f-11fc2079fd47`）。

| 项目 | 状态 |
| --- | --- |
| 构建 | 1.0 (1)，`COURT_MODEL_SET=independent`，只带两个 TrackNetV3（MIT），包内逐文件检查没有 S家模型；已关联 1.0 |
| 文字 | 中英文名称、副标题、描述、关键词、推广文本、隐私政策与技术支持网址；描述里不提其他平台（Android/安卓已删） |
| 截图 | 6.9 英寸（`APP_IPHONE_67`）中英各 5 张，示例数据并有标注 |
| 价格 / 销售范围 | 中国 ¥18 为基准（美国自动 $2.99），全部 175 个地区 |
| 年龄分级 | 全部为无，4+ |
| 类别 | 体育，次类别健康健美（因此需要声明不是受监管医疗设备，已在网页声明「否」） |
| 版权 / 内容版权 | 「2026 Zacks Court」；不含第三方内容 |
| App 隐私 | 「未收集数据」，已发布（只能在网页上做，没有 API） |
| 审核信息 | 联系人由用户在网页填写；备注为 [review-notes.md](review-notes.md) 英文版；不需要登录；没有附演示视频 |
| 中国大陆 ICP 备案 | 没有备案（App 不连互联网），审核或上架被卡时再处理 |

开卖前还要用户本人处理：在「商务」页同意新版付费 App 协议、填写税务表格（W-8BEN 等）、在 2026-11-10 前续费开发者会员（协议和证书都到这天）。

## 2. 提交前必须做的事

1. **用自研模型重新构建**。上架版只能带自研模型（`COURT_MODEL_SET=independent`，见 AGENTS.md），不能带 S家 的权重。6 号构建是用哪一套打的没有记录，而且之后代码改了很多，所以要重新出一个 1.0 的构建。`apps/iphone/project.yml` 已改成 `MARKETING_VERSION` `1.0`、`CURRENT_PROJECT_VERSION` `1`（`asc builds next-build-number --version 1.0` 返回 1）。用 `COURT_MODEL_SET=independent ./scripts/generate-ios.sh` 生成工程，以 Release 归档上传。
2. **隐私政策和技术支持页**（已完成，2026-11-03）。放在公开仓库 [claude89757/zacks-court-site](https://github.com/claude89757/zacks-court-site) 的 GitHub Pages 上，仓库里只有这两页：
   - 技术支持：https://claude89757.github.io/zacks-court-site/ （设备要求、常见问题；反馈走该仓库的 GitHub Issues，不公开邮箱）
   - 隐私政策：https://claude89757.github.io/zacks-court-site/privacy.html （内容和 [privacy-policy.md](privacy-policy.md) 相同，改政策时两边一起改）

   网址已写进 `metadata/app-info/*.json` 的 `privacyPolicyUrl` 和 `metadata/version/1.0/*.json` 的 `supportUrl`。
3. **截图**。1.0 只支持 iPhone（2026-11-03 决定，`TARGETED_DEVICE_FAMILY` 为 `1`），只要 6.9 英寸 iPhone 的截图（1320×2868 或 1290×2796，3–10 张），不需要 iPad 截图。截图规则（AGENTS.md）：不能出现配对二维码、用户录像和来源不明的视频画面。建议的画面：
   - 机位横屏，对着真实球场（自己拍的球场，没有可辨认的路人）；
   - 看板首屏：球速 / 落点 / 动作三个数字和最近几拍；
   - 场边测速牌（球速、发球两种）；
   - 球场落点图；
   - 界内外估计的卡片；
   - 历史记录和单拍回看。
   合成画面或演示数据的截图要在图上注明是示例，不能让人以为是实测。

   **已准备 5 张**（2026-11-03，[screenshots/iphone-6.9/](screenshots/iphone-6.9/)，1320×2868，无透明通道）：记录详情的球速、球场落点、动作类别、逐拍回看，以及历史记录。画面来自 iPhone 17 Pro Max 模拟器上的 Release 构建（自研模型），数据是 `court-probe demo-session` 编造的示例记录，顶部盖了「示例画面 · 演示数据，非实测」的标签，记录标题也写着演示数据。没有首页：模拟器上首页会显示「模拟器没有相机」，真机上不会出现。机位横屏对着真实球场、看板和测速牌这几张要等真机实拍再补。重做的步骤：建一个新模拟器，装 Release 构建，用 `court-probe demo-session` 往 App 的 `Documents/Zacks Court/Sessions` 写示例记录，再用 `TEST_RUNNER_COURT_UI_STORE_SHOTS=<目录>` 跑 `testStoreScreens`，选图后给顶部盖标签。
4. **填年龄分级问卷**：所有项选「无」，结果是 4+。
5. **出口合规**：`Info.plist` 里 `ITSAppUsesNonExemptEncryption` 是 `false`。App 只用系统自带的 TLS（Network.framework）和 HMAC 认证，属于豁免范围，6 号构建也是按「不使用非豁免加密」上传的。如果以后加了自己实现的加密算法，要改这一项。
6. **App 隐私标签**：选「不收集数据」（Data Not Collected）。依据：App 不连开发者服务器，没有统计、广告或追踪 SDK，`PrivacyInfo.xcprivacy` 里收集的数据类型为空。
7. **类别**：主类别「体育」，次类别「健康健美」。
8. **价格**：付费下载，中国区 ¥18、美区 $2.99（2026-11-03 决定），没有内购。已在 2026-11-03 设好：以 $2.99 为基准时中国区会自动换算成 ¥22，所以基准地区选了中国大陆、价格档 ¥18，美国区自动换算正好是 $2.99；两种基准下其他 172 个地区的价格完全相同。命令是 `asc pricing schedule create --app 6827224757 --base-territory CHN --price-point <¥18 档的 ID>`，价格档 ID 用 `asc pricing price-points --app 6827224757 --territory CHN --paginate` 查。销售范围已设为全部地区（`asc pricing availability create --app 6827224757 --all-territories --available true --available-in-new-territories true`）。
9. **中国大陆的备案**（2026-11-03 决定先不备案）：工信部的 APP 备案针对「从事互联网信息服务」的 App。这个 App 只在局域网里让设备互连，不连互联网、不连开发者服务器，按这个说法可以不备案。但苹果对中国区的执行可能更严，提交时 App 信息页可能要求填 ICP 备案号。被卡住时，先向审核说明是不联网的本地应用；不行就从销售范围里去掉中国大陆，或者办备案。以后加了任何联网功能（检查更新、统计等），都要先备案。
10. **付费 App 协议**：在 App Store Connect 的「协议、税务和银行业务」里确认付费 App 协议已生效、税务和银行信息已填，否则付费 App 不能销售。asc 和 API 都查不到这一项，要在网页上看。

## 3. 审核风险和建议

- **审核员没有网球场**。审核员很可能只有一台设备，也不在球场，分析功能看不出效果。[review-notes.md](review-notes.md) 写了单台 iPhone 怎么试，并建议附一段演示视频的链接（录屏，展示机位在真实球场上出逐拍结果）。这是最可能被拒（2.1 功能完整性）的地方。
- **首页的「本地视频实验」**。它写着「实验功能」，审核可能按 2.2（测试版、演示功能）来看，所以 Release 构建不显示它（`#if DEBUG`，2026-11-03），只在 Debug 构建和 UI 测试里出现。
- **不用「鹰眼」这个名字**。Hawk-Eye 是注册商标。这个功能原来叫「鹰眼」，2026-11-03 在 App、网页看板和文档里统一改名为「界内外」；商店文字写「界内外估计」，不写「鹰眼」或 Hawk-Eye。代码里的类型名 `HawkEye` 和无障碍标识 `court.hawkeye.*` 不显示给用户，没有改。
- **不提 S家（用任何名称）和 Mac 版**。商店文字里没有出现它们。只带自研模型的构建里，「S家」的切换面板不显示（只有一套模型时隐藏）。
- **说法要和功能一致**。球速、落点、动作和界内外都写成「估计」，不写「测量」「雷达」「判罚」；浏览器看板写明是明文 HTTP；机位需要 iPhone 13 及以后的机型。自研模式下没有离线补算，商店文字里也没有提。

## 4. 文件

| 文件 | 内容 |
| --- | --- |
| `metadata/app-info/zh-Hans.json`、`en-US.json` | 名称、副标题、隐私政策网址 |
| `metadata/version/1.0/zh-Hans.json`、`en-US.json` | 描述、关键词、推广文本、技术支持网址（1.0 不需要「新功能」） |
| [privacy-policy.md](privacy-policy.md) | 中英文隐私政策，公开版在上面的隐私政策网址 |
| [review-notes.md](review-notes.md) | 给审核员的说明 |

`metadata/` 用的是 `asc metadata` 的目录格式，已通过 `asc metadata validate`（离线检查字段和长度）。

## 5. 用 asc 推送（会修改 App Store Connect，推送前先确认）

```sh
asc metadata validate --dir docs/app-store/metadata
asc metadata plan  --app 6827224757 --version 1.0 --dir docs/app-store/metadata   # 只生成变更计划，不修改
asc metadata approve --review-dir .asc/metadata/review --all                  # 看过计划后批准
asc metadata apply --app 6827224757 --version 1.0 --dir docs/app-store/metadata --review-dir .asc/metadata/review --confirm
asc age-rating edit --app 6827224757 …          # 年龄分级（所有项为无）
asc builds upload --app 6827224757 --ipa ZacksCourt.ipa
asc status --app 6827224757                     # 发布状态总览
```

网络慢时设 `ASC_TIMEOUT=120s`。2026-11-03 跑 `asc validate` 两次都超时了，所以提交前的完整检查还没跑过。
