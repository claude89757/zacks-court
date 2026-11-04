# App Store 上架材料（iOS）

App Store Connect 里的记录：Zacks Court，App ID `6827224757`，Bundle ID `com.claude89757.zackscourt`，SKU `ZACKSCOURT-IOS`，主语言简体中文。用 `asc`（App Store Connect 命令行）读写，见文末。

## 1. 现状

**1.0 已上架，免费**：2026-11-03 过审，但付费 App 协议、税务和银行一直没生效，175 个地区都是 `CANNOT_SELL`。2026-11-04 用户决定先改免费，改价后 175 个地区全部 `AVAILABLE`。

**1.1 计划（2026-11-04 决定）：改成免费**，测速、界内外、录像这些基本功能全部免费；以后再规划收费的视频剪辑订阅（自动续期订阅，需要付费 App 协议、税务和银行）。**1.1 (5) 于 2026-11-04 提交审核**（提交 `361112b4`，`WAITING_FOR_REVIEW`，过审后自动发布；之前的 1.1 (2)、1.1 (3) 都在苹果开始审核前撤回换成了新构建）；同一个构建在 TestFlight 内测组可装，公测组在等 Beta 审核。见第 6 节。

| 项目 | 状态 |
| --- | --- |
| 构建 | 1.0 (1)，`COURT_MODEL_SET=independent`，只带两个 TrackNetV3（MIT），包内逐文件检查没有 S家模型；已关联 1.0 |
| 文字 | 中英文名称、副标题、描述、关键词、推广文本、隐私政策与技术支持网址；描述里不提其他平台（Android/安卓已删） |
| 截图 | 6.9 英寸（`APP_IPHONE_67`）中英各 5 张，示例数据并有标注；1.1 起换成带大字说明的新版（见第 3 步） |
| 价格 / 销售范围 | 免费（2026-11-04 起；之前中国 ¥18 为基准），全部 175 个地区 |
| 年龄分级 | 全部为无，4+ |
| 类别 | 体育，次类别健康健美（因此需要声明不是受监管医疗设备，已在网页声明「否」） |
| 版权 / 内容版权 | 「2026 Zacks Court」；不含第三方内容 |
| App 隐私 | 「未收集数据」，已发布（只能在网页上做，没有 API） |
| 审核信息 | 联系人由用户在网页填写；备注为 [review-notes.md](review-notes.md) 英文版；不需要登录；没有附演示视频 |
| 中国大陆 ICP 备案 | 没有备案（App 不连互联网），审核或上架被卡时再处理 |

用户本人要处理：在 2026-11-10 前续费开发者会员（免费 App 协议、证书和描述文件都到这天，过期后 App 会下架、不能上传）。以后做收费订阅前，再同意付费 App 协议、填写税务表格（W-8BEN 等）、等银行信息生效。

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

   **1.0 上架用的** 是 5 张记录详情和历史页的原样截图（顶部盖「示例画面 · 演示数据，非实测」），已从仓库删除，git 历史里还有。

   **1.1 起用带大字说明的 5 张**（2026-11-04，简体 [zh-Hans](screenshots/iphone-6.9/zh-Hans/)、繁体 [zh-Hant](screenshots/iphone-6.9/zh-Hant/)、美式英文 [en-US](screenshots/iphone-6.9/en-US/)、英式英文 [en-GB](screenshots/iphone-6.9/en-GB/)，各 1320×2868；en-GB 的大字与 en-US 相同）：
   1. 一台拍，一台看：场边机位 + 看板手机 + 浏览器看板的场景示意（球场、三脚架和机位画面是矢量插画，两块看板是真实界面）；
   2. 电子司线，喊出 Out!：浏览器看板的界内外回放（OUT）和 OUT / IN / CLOSE 三种结论的说明；
   3. 发球球速，大字看：浏览器看板的发球测速牌；
   4. 每一拍都能回看：App 记录详情的逐拍列表；
   5. 不用账号，数据只在你的设备上：App 记录详情的球场落点图。

   每张右下角写「画面为演示数据 / Screens show demo data」，数据全部来自 `court-probe demo-session` 编造的示例记录。文案不写「鹰眼」「Hawk-Eye」（注册商标）、「测速仪」「雷达」或任何精度承诺。App 界面只有中文，英文图的大字是英文、手机里仍是中文界面。

   重做：大字在 [screenshots/source/captions.json](screenshots/source/captions.json)，版式在 `screenshots/source/frames.html`，运行 `./scripts/render-store-screens.sh`（要 Google Chrome，无界面渲染）。浏览器看板的三张原图由脚本现场渲染：把 `Sources/CourtCore/Web` 的页面拷到临时目录，用 `screenshots/source/web-demo.js` 冒充机位、喂示例记录的前 20 拍（第 20 拍是底线出界）。App 的三张原图在 `screenshots/source/raw/app-*.png`，来自 `testStoreScreens`：建一个新的 iPhone 17 Pro Max 模拟器，装 Release 构建，用 `court-probe demo-session` 往 App 的 `Documents/Zacks Court/Sessions` 写示例记录，再用 `TEST_RUNNER_COURT_UI_STORE_SHOTS=<目录>` 跑 `-configuration Release` 的 `testStoreScreens`（Release 构建不显示演示横幅）；`03-detail-0/1/3` 分别是 `app-summary`、`app-bounces`、`app-shots`。上传时每种语言指向各自目录。
4. **填年龄分级问卷**：所有项选「无」，结果是 4+。
5. **出口合规**：`Info.plist` 里 `ITSAppUsesNonExemptEncryption` 是 `false`。App 只用系统自带的 TLS（Network.framework）和 HMAC 认证，属于豁免范围，6 号构建也是按「不使用非豁免加密」上传的。如果以后加了自己实现的加密算法，要改这一项。
6. **App 隐私标签**：选「不收集数据」（Data Not Collected）。依据：App 不连开发者服务器，没有统计、广告或追踪 SDK，`PrivacyInfo.xcprivacy` 里收集的数据类型为空。
7. **类别**：主类别「体育」，次类别「健康健美」。
8. **价格**：**1.1 起免费**（2026-11-04 决定）。原计划等 1.1 过审再改价，但付费 App 协议一直没生效，App 付费时连 1.1 版本都建不了，所以 2026-11-04 用户决定先改免费（1.0 随即在 175 个地区可下载），再建 1.1。命令：`asc pricing schedule create --app 6827224757 --free --base-territory CHN --start-date <当天>`。以后的视频剪辑订阅要另建订阅组和内购项目，并补上付费 App 协议、税务和银行。

   以下是 1.0 的记录：付费下载，中国区 ¥18、美区 $2.99（2026-11-03 决定），没有内购。已在 2026-11-03 设好：以 $2.99 为基准时中国区会自动换算成 ¥22，所以基准地区选了中国大陆、价格档 ¥18，美国区自动换算正好是 $2.99；两种基准下其他 172 个地区的价格完全相同。命令是 `asc pricing schedule create --app 6827224757 --base-territory CHN --price-point <¥18 档的 ID>`，价格档 ID 用 `asc pricing price-points --app 6827224757 --territory CHN --paginate` 查。销售范围已设为全部地区（`asc pricing availability create --app 6827224757 --all-territories --available true --available-in-new-territories true`）。
9. **中国大陆的备案**（2026-11-03 决定先不备案）：工信部的 APP 备案针对「从事互联网信息服务」的 App。这个 App 只在局域网里让设备互连，不连互联网、不连开发者服务器，按这个说法可以不备案。但苹果对中国区的执行可能更严，提交时 App 信息页可能要求填 ICP 备案号。被卡住时，先向审核说明是不联网的本地应用；不行就从销售范围里去掉中国大陆，或者办备案。以后加了任何联网功能（检查更新、统计等），都要先备案。
10. **付费 App 协议**：在 App Store Connect 的「协议、税务和银行业务」里确认付费 App 协议已生效、税务和银行信息已填，否则付费 App 不能销售。asc 和 API 都查不到这一项，要在网页上看。1.1 免费后暂时不需要，加订阅前必须办好。

## 3. 审核风险和建议

- **审核员没有网球场**。审核员很可能只有一台设备，也不在球场，分析功能看不出效果。[review-notes.md](review-notes.md) 写了单台 iPhone 怎么试，并建议附一段演示视频的链接（录屏，展示机位在真实球场上出逐拍结果）。这是最可能被拒（2.1 功能完整性）的地方。
- **首页的「本地视频实验」**。它写着「实验功能」，审核可能按 2.2（测试版、演示功能）来看，所以 Release 构建不显示它（`#if DEBUG`，2026-11-03），只在 Debug 构建和 UI 测试里出现。
- **不用「鹰眼」这个名字**。Hawk-Eye 是注册商标。这个功能原来叫「鹰眼」，2026-11-03 在 App、网页看板和文档里统一改名为「界内外」；商店文字写「界内外估计」，不写「鹰眼」或 Hawk-Eye。代码里的类型名 `HawkEye` 和无障碍标识 `court.hawkeye.*` 不显示给用户，没有改。
- **不提 S家（用任何名称）和 Mac 版**。商店文字里没有出现它们。只带自研模型的构建里，「S家」的切换面板不显示（只有一套模型时隐藏）。
- **说法要和功能一致**。球速、落点、动作和界内外都写成「估计」，不写「测量」「雷达」「判罚」；浏览器看板写明是明文 HTTP；机位需要 iPhone 13 及以后的机型。自研模式下没有离线补算，商店文字里也没有提。

## 4. 文件

| 文件 | 内容 |
| --- | --- |
| `metadata/app-info/{zh-Hans,zh-Hant,en-US,en-GB}.json` | 名称、副标题、隐私政策网址（zh-Hant、en-GB 从 1.1 起新增） |
| `metadata/version/1.0/zh-Hans.json`、`en-US.json` | 1.0 的描述、关键词、推广文本、技术支持网址 |
| `metadata/version/1.1/{zh-Hans,zh-Hant,en-US,en-GB}.json` | 1.1 的描述、关键词、推广文本、技术支持网址、新功能（「新功能」里的修复条目等主会话合入后补） |
| [privacy-policy.md](privacy-policy.md) | 中英文隐私政策，公开版在上面的隐私政策网址 |
| [review-notes.md](review-notes.md) | 给审核员的说明 |
| [testflight.md](testflight.md) | TestFlight 内测、公测的说明文字和 Beta 审核备注 |
| [creative-assets/source/](creative-assets/source/) | iOS 27 产品页标题和搜索结果的通用素材模板（`universal.html` + `captions.json`），`scripts/render-creative-assets.sh` 生成 `creative-assets/<语言>/universal.png`（约 9 MB，不进 Git） |

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

## 6. 搜索与曝光（1.1 起，2026-11-04）

做法按业界常见的 App Store 优化：名称、副标题、关键词三处的词会被索引，三处之间不重复；描述不参与搜索，但影响转化。

- **每个地区会索引两种语言**：美国区 en-US 加简体中文；中国大陆 zh-Hans 加英式英文 en-GB；香港、台湾 zh-Hant 加 en-GB；英国 en-GB。所以 en-US 和 en-GB 写成两套不同的词，等于在美国区多一套英文关键词、在中国区多一套英文关键词；zh-Hant 覆盖港台的繁体搜索。
- **用词**：名称和副标题放最常搜的「网球测速」「电子司线 / line calls」「发球球速」；关键词放其余的（落点、出界、教练、训练、正手反手、慢动作、复盘等），逗号分隔，不加空格，每种语言不超过 100 个字符。
- **不写的词**：鹰眼、Hawk-Eye（注册商标）、电子裁判、umpire、referee、雷达、测速仪、radar gun、任何竞品名称，以及名称和副标题里的「免费 / Free」（苹果不允许）。球速和界内外一律写「估计」。
- **推广文本**随时可改，不用提交新版本；名称、副标题、关键词只能随新版本改。
- **上线后**：在 App Store Connect 的「App 分析」里看「来源：App Store 搜索」的曝光和转化，一两周后按实际搜索词调整关键词。

### 创意素材：产品页标题和搜索结果（iOS 27 起，2026-11-04）

苹果 2026-10-05 起支持的可选素材，只对 iOS 27 / iPadOS 27 及以后的用户显示；不放时搜索结果显示截图，审核不受影响。规格见 [Creative assets specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications/)。

- **做法**：每种语言一张通用素材（16:9，5244×2950 PNG，不能有透明通道），同时用于产品页标题（裁成 21:9）和搜索结果（裁成 3:2）。文字和主体放在两种裁切都保留的中间区域（按居中裁切估算，没有在 App Store Connect 的预览工具里看过）。画面是一记 149 km/h 的发球、落点超出发球线 32 厘米判出界，标「模型估计」和演示数据；不写免费、价格、网址、©、竞品和第 6 节的禁用词。
- **已上传素材库**（2026-11-04，规格 `i5244x2950a0`，通用，可用于两种位置），状态 `PREPARE_FOR_SUBMISSION`：
  - zh-Hans `d2c00019-6ef2-8eb5-8022-a0e8be458eaf`（creative-1.1-zh-Hans）
  - zh-Hant `50400019-6ef2-8eb5-8025-5480b09ff30c`（creative-1.1-zh-Hant）
  - en-US 和 en-GB 共用 `82c00019-6ef2-8eb5-8000-fcbcfa78ef4d`（creative-1.1-en）
- **还没提交、没挂到版本上**：1.1 的审核提交（现在是 `361112b4`）还开着，同一平台同时只能有一个审核提交；也不能改正在审核的版本。接下来：
  1. 前提：1.1 的审核提交已关闭（过审或被拒，`asc review submissions list --app 6827224757`）。
  2. 单独提交素材审核：`asc review submissions-create --app 6827224757 --platform IOS`，把三张图逐个加进去（`asc review items add --submission <ID> --item-type appAssetLibraryImages --item-id <图片 ID>`），再 `asc review submissions-submit --id <ID> --confirm`。
  3. 前提：三张图都是 `APPROVED`（`asc asset-library images list --library-id 6827224757`），且 1.1 已上线。
  4. 挂到线上 1.1 的四个语言上，每个语言两种位置都用同一张图（creative assets 用 `DEFAULT_PROFILE`）：`asc localizations placements create --localization-id <本地化 ID> --image-id <图片 ID> --placement-type PRODUCT_PAGE_HEADER_ASSET`，再用 `APP_STORE_SEARCH_RESULTS_ASSET` 跑一遍。1.1 的本地化 ID：zh-Hans `ee27abea-f73b-4bf1-8b55-2f7dfd624285`、en-US `d24d0791-bd14-4112-b948-094e8d482661`、zh-Hant `b413f760-e9f5-4299-82e2-4bd8d4908b7f`、en-GB `b3ea238e-65ca-45c3-91f6-1aece2cac2ef`。苹果文档说线上版本换上已审过的素材不用提交新版本；如果命令行挂不上，就在网页上 1.1 版本页「标题和搜索结果」里「浏览素材」选图后点「发布」。
- 上线后再考虑（这次不做，免得多一道审核）：店内活动、自定义产品页、产品页优化（A/B 测试）、App 预览视频。新 App 刚上线流量小，A/B 测试和自定义产品页看不出差别。

### 预览视频（计划随 1.2 上传，2026-11-04）

商店页面可以放视频，App Store Connect 的规格（`asc asset-library specs`，2026-11-04 读取）：

| | App 预览视频（`APP_PREVIEW`） | 产品页标题视频（`PRODUCT_PAGE_HEADER_ASSET`，iOS 27 起） |
| --- | --- | --- |
| 位置 | 截图前面，进页面静音自动播放 | 产品页最上方 |
| 尺寸 | 1920×886 横屏或 886×1920 竖屏（6.9 英寸 iPhone） | 3840×1646 |
| 帧率 / 时长 | 最多 30 帧，15–30 秒 | 30 或 60 帧，5–30 秒 |
| 数量 | 每种语言最多 3 段 | 1 段 |
| 其他 | 必须有音轨（静音也行） | 不需要音轨 |

- 预览视频只能用 App 自己的画面（可以加字幕）。规则和截图一样：数据来自 `court-probe demo-session` 的示例记录，画面角上写「画面为演示数据 · Demo data」；不出现配对二维码、用户录像，不写「鹰眼」。
- 录法：`./scripts/record-store-preview.sh <新建的 iPhone 17 Pro Max 模拟器 UDID> <目录>`。脚本用 Release、不带模型打包，装进模拟器，写入示例记录，一边录屏一边跑 `testStorePreviewFlow`。流程是看板全屏测速牌 3 秒，然后点「回放」连看三拍界内外回放。脚本按测试写下的时间点剪成 15–30 秒，转成 1920×886、30 帧，加角标和静音音轨，输出 `preview-1920x886.mp4`。角标先用 Pillow 画成透明 PNG，再让 ffmpeg `overlay` 叠上（Homebrew 的 ffmpeg 没有 `drawtext`）；裁剪写在 `-i` 之后（输出侧），因为这段录屏是变帧率的，输入侧 `-ss` 会从关键帧算起、把结尾切掉。App 界面只有中文，四种语言先共用这一段。
- 上传：预览视频跟着版本一起审核，正在审核的版本加不进去，所以放到 1.2。命令：`asc video-previews upload --version-localization <1.2 的本地化 ID> --path <目录> --device-type IPHONE_69`，四种语言各传一次，再用 `asc video-previews set-poster-frame` 选封面帧（选回放判定那一帧）。
- 标题视频要 3840×1646，模拟器录屏的分辨率不够，暂不做。

### 1.1 发版记录（2026-11-04 已提交审核）

先决条件（只能由账户持有人在网页上做）：
- **付费 App 不能建新版本**：2026-11-04 试着建 1.1 版本时，App Store Connect 一直拒绝（`You cannot create a new version of the App in the current state`），版本页提示要先接受最新的付费 App 协议；用户点了同意后仍不行（银行还在处理、税表没填，协议没生效）。改成免费后马上就能建。
- **2026-11-10 前续费开发者会员**。协议、发布证书和描述文件都到这天为止，过期后不能上传。

实际顺序（App Store Connect 的改动不用逐步问用户，由顾问模型把关）：
1. `apps/iphone/project.yml` 的 `MARKETING_VERSION` 已改成 `1.1`；构建号现在是 `7`：1.1 (1) 于 2026-11-04 上传后，又合入了手持拍摄的球场识别（PR #9），重新打了 1.1 (2) 并提交审核；同日在苹果开始审核前撤回，换成带错球场修复（PR #13、#14）的 1.1 (3) 重新提交。之后每次合入 PR 都打一个新的 TestFlight 构建：1.1 (4)（PR #16 挑战）、1.1 (5)（PR #18 第一帧锁定球场）、1.1 (6)（3D 回放）、1.1 (7)（PR #22 相机压力触发降载）只进 TestFlight。同日晚上用户要求正式版也用最新代码：撤回 1.1 (3) 的提交 `a8434131`（苹果还没开始审），推送四种语言新增挑战和更快球场识别的「新功能」，关联 1.1 (5)，重新提交（`361112b4`）。
2. 确认 `scripts/reference-chain.sh status` 是 `off`，然后 `COURT_MODEL_SET=independent ./scripts/generate-ios.sh`，Release 归档并导出（手动签名，Apple Distribution 证书，描述文件「Zacks Court App Store 20261027」）。解开 IPA 逐个检查：只有两个 TrackNetV3，没有 `AnalysisModels`。然后上传。
3. 「新功能」已写完（2026-11-04，包括 PR #6 球场跟踪和 PR #7 去掉手动标定）。建 1.1 版本（`asc versions create --app 6827224757 --version 1.1 --release-type AFTER_APPROVAL`）。推送四种语言的文字，其中 zh-Hant、en-GB 是新增的本地化，如果 `metadata apply` 不新建本地化，先用 `asc localizations create` 建。
4. 截图：新版本会沿用 1.0 的 5 张旧截图，先删掉，再上传各语言目录里的新图。
5. TestFlight：内测组接收所有构建，1.1 (2) 处理完就能装；加进公测组并提交 Beta 审核（`asc builds add-groups --group <公测组> --submit --confirm`）。说明文字和 Beta 审核备注见 [testflight.md](testflight.md)。
6. 用户决定先改免费（`asc pricing schedule create --app 6827224757 --free --base-territory CHN`），然后才建得了 1.1 版本；接着按第 3、4 步推送文字、换截图，关联构建，更新审核备注，`asc review submit` 提交。
7. 技术支持站（zacks-court-site）的 `icon.png` 和 1.1 上线同时换成新图标。
