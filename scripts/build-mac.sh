#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# independent (default): in-house models only, no S家 resources.
# both: S家 and in-house sets, switchable in the App; sjia: S家 only. Both need the S家 models you
# keep locally in .local/s-models (never in Git, see scripts/prepare-analysis-models.sh).
COURT_MODEL_SET=${COURT_MODEL_SET:-independent}
[ "$COURT_MODEL_SET" = swing ] && COURT_MODEL_SET=sjia  # old name
case "$COURT_MODEL_SET" in
    independent)
        COURT_INDEPENDENT_MODELS=$(scripts/prepare-independent-app-models.sh)
        COURT_APP="$PWD/build/Zacks Court.app"
        ;;
    both)
        COURT_MODELS=$(scripts/prepare-analysis-models.sh)
        COURT_INDEPENDENT_MODELS=$(scripts/prepare-independent-app-models.sh)
        COURT_APP="$PWD/build/both/Zacks Court.app"
        ;;
    sjia)
        COURT_MODELS=$(scripts/prepare-analysis-models.sh)
        COURT_APP="$PWD/build/sjia/Zacks Court.app"
        ;;
    *) echo "COURT_MODEL_SET must be independent, both or sjia" >&2; exit 1 ;;
esac
# The S家 reference chain is linked in only for builds that carry S家 models (docs/s-reference.md).
if [ "$COURT_MODEL_SET" = independent ]; then scripts/reference-chain.sh off; else scripts/reference-chain.sh on; fi
swift build -c release --product CourtMac
COURT_BIN=$(swift build -c release --show-bin-path)
mkdir -p "$COURT_APP/Contents/MacOS"
mkdir -p "$COURT_APP/Contents/Resources"
cp "$COURT_BIN/CourtMac" "$COURT_APP/Contents/MacOS/CourtMac"
if [ "$COURT_MODEL_SET" = independent ] && nm "$COURT_APP/Contents/MacOS/CourtMac" | grep -q LocalReferenceChain; then
    echo "默认构建里出现了 S家参照链，停止打包。" >&2; exit 1
fi
cp assets/brand/ZacksCourt.icns "$COURT_APP/Contents/Resources/ZacksCourt.icns"
rm -rf "$COURT_APP/Contents/Resources/AnalysisModels" "$COURT_APP/Contents/Resources/IndependentModels"
if [ "$COURT_MODEL_SET" != independent ]; then
    ditto "$COURT_MODELS" "$COURT_APP/Contents/Resources/AnalysisModels"
fi
if [ "$COURT_MODEL_SET" != sjia ]; then
    ditto "$COURT_INDEPENDENT_MODELS" "$COURT_APP/Contents/Resources/IndependentModels"
fi
# Browser display page (docs/web-display.md); the app reports it missing rather than crashing.
test -f "$COURT_BIN/ZacksCourt_CourtCore.bundle/Contents/Resources/Web/index.html" || { echo "缺少浏览器看板资源包" >&2; exit 1; }
rm -rf "$COURT_APP/Contents/Resources/ZacksCourt_CourtCore.bundle"
ditto "$COURT_BIN/ZacksCourt_CourtCore.bundle" "$COURT_APP/Contents/Resources/ZacksCourt_CourtCore.bundle"
cat > "$COURT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.claude89757.zackscourt.mac</string>
<key>CFBundleName</key><string>Zacks Court</string>
<key>CFBundleExecutable</key><string>CourtMac</string>
<key>CFBundleIconFile</key><string>ZacksCourt.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>在摄像头模式采集球场视频，传给配对的服务端。</string>
<key>NSLocalNetworkUsageDescription</key><string>在局域网、个人热点或点对点 Wi-Fi 中，连接另一台运行 Zacks Court 的设备，或让同一网络里的浏览器打开看板，传输逐拍分析数据、低清预览与录像片段。</string>
<key>NSBonjourServices</key><array><string>_zackscourt._tcp</string></array>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>zackscourt</string></array></dict></array>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :CourtModelSet string $COURT_MODEL_SET" "$COURT_APP/Contents/Info.plist"
codesign --force --sign - "$COURT_APP"
printf '%s\n' "$COURT_APP"
