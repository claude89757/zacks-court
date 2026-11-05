# App Review Notes（审核备注）

填到 App Store Connect →「App 审核信息」→「备注」。审核员看英文，下面先给英文，中文对照在后。不需要演示账号：App 没有登录。

## English (paste this)

Zacks Court records tennis from the side of the court and estimates each shot's speed, bounce point and stroke type on the device. The app is free, with no account, no server and no in-app purchase.

How to try it with one iPhone:
1. Open the app and choose "机位" (Camera). Hold the phone in landscape; the camera opens by itself. The camera role needs an iPhone 13 or later.
2. Tap "开始记录" (Start recording). The phone records at 1080p / 60 fps. Shot analysis appears only when a tennis court and a ball are in view: the app finds the court from its white lines, then reports each hit and bounce. Off court, the app keeps recording and shows "—" with a reason instead of a value. This is by design: it never shows a made-up number.
3. Tap "结束" (End), then open "历史记录" (History) to replay the session.

Away from a tennis court (version 1.1 and later): on the start page tap "导入视频分析" (Import a video). Choose "从相册选择" (from Photos) or "从文件选择" (from Files) and pick a landscape tennis video recorded at 60 fps, 720p or higher, 3 seconds to 10 minutes long, ideally filmed from behind or beside the court like the camera role. Tap "开始分析" (Start). The video runs through the same on-device analysis as the camera (a longer video takes a few minutes; stay on the page) and is saved as a record: tap "查看记录" (View record) to see each shot's estimated speed, bounce and stroke. The Photos picker is the system one; the app gets only the chosen video and asks for no photo-library permission.

With a second device: choose "看板" (Display) on a second iPhone, and pair by scanning the QR code shown under "连接" (Connect) on the camera. The two devices talk directly over the local network (TLS); no data leaves them. A browser on any device on the same Wi-Fi can also open the display from the camera's QR code (plain HTTP on the local network, stated in the app).

New in 1.2: the line-call replay adds a 3D view and a measuring scale. The "Out!" call and challenge verdicts now play short voice clips bundled in the app. The clips were generated with OpenAI's text-to-speech and play offline, and the settings say so ("语音由 AI 合成（OpenAI）", the voice is AI-generated). A record's "导出" (Export) menu adds "诊断包（不含录像）" (Diagnostic package, no video). It is a zip of the record's data and the camera's log, with no video and no pairing key, and it is sent only through the system share sheet when the user chooses to.

The app never connects to the internet: no analytics, no ads, no developer server.

Permissions: camera (recording and QR scanning), local network (connecting the two devices), add-only Photos access (saving a clip when the user taps "存到相册").

## 中文对照

Zacks Court 在场边录网球，在设备本机估计每一拍的球速、落点和动作类别。App 免费，没有账号、服务器或内购。

一台 iPhone 怎么试：
1. 打开 App，选「机位」，把手机横过来，相机会自动打开。机位需要 iPhone 13 或更新的机型。
2. 点「开始记录」，以 1080p / 60 帧录像。只有画面里有网球场和球时才有分析结果：App 从白线识别球场，再给出每次击球和落地。不在球场时照常录像，数值显示「—」并写明原因，这是设计如此，App 不编造数值。
3. 点「结束」，再到「历史记录」回看。

不在球场时（1.1 起）：启动页点「导入视频分析」，用「从相册选择」或「从文件选择」选一段横屏、60 帧/秒、720p 以上、3 秒到 10 分钟的网球视频，最好像机位那样从场边或底线后方拍。点「开始分析」，视频在本机走和机位相同的分析（视频长时要几分钟，期间留在这一页），存成一条记录，点「查看记录」看每一拍的球速估计、落点和动作。相册用的是系统选择器，App 只拿到选中的那段视频，不申请相册读取权限。

有第二台设备时：在另一台 iPhone 上选「看板」，扫机位「连接」页上的二维码配对。两台设备在局域网里直接连接（TLS），数据不出这两台设备。同一 Wi-Fi 下任何设备的浏览器也能扫机位上的二维码打开看板（局域网明文 HTTP，App 里有说明）。

1.2 新增：
- 界内外回放有 3D 视角和量尺。
- 出界的「Out!」和挑战结论改播 App 内置的短语音。语音由 OpenAI 的文字转语音生成，离线播放，设置里写明了「语音由 AI 合成（OpenAI）」。
- 记录的「导出」里新增「诊断包（不含录像）」：把这条记录的数据和机位日志打成 zip，不含录像和配对密钥，只在用户自己选择时通过系统分享面板发出。

App 不连互联网：没有统计、广告或开发者服务器。

权限：相机（录像和扫码）、本地网络（两台设备互连）、照片仅添加（用户点「存到相册」时保存片段）。
