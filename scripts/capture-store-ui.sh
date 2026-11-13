#!/bin/zsh
# Captures real iPhone simulator screenshots of Zacks Court for each UI language.
#
#   ./scripts/capture-store-ui.sh <SIMULATOR_UDID>
#
# Writes docs/app-store/screenshots/source/raw/<language>/*.png by running the Release
# UI test testStoreScreens. The demo record is court-probe demo-session (labelled demo
# data, not a measurement). Languages: zh-Hans, zh-Hant, en, ja, de, fr.
# en-US and en-GB store listings share the en captures.
#
# This does not draw UI, does not upload, and does not create an App Store version.
# It needs Xcode, a booted-capable iPhone simulator, and the shared Swift package.
# Without xcodebuild it exits 2 and records nothing.
set -euo pipefail
UDID=${1:?simulator UDID}
ROOT=${0:A:h:h}
RAW="$ROOT/docs/app-store/screenshots/source/raw"
command -v xcodebuild >/dev/null || {
  echo "xcodebuild is not available. No simulator screenshot was taken." >&2
  echo "On a Mac with Xcode: $0 <iPhone simulator UDID>" >&2
  exit 2
}
cd "$ROOT"
COURT_CODE_ONLY=1 ./scripts/generate-ios.sh >/dev/null
trap 'git -C "$ROOT" checkout -- apps/iphone/ZacksCourt/Info.plist 2>/dev/null || true' EXIT
DD="$ROOT/.local/dd-store-ui"
xcodebuild build-for-testing -project apps/iphone/ZacksCourt.xcodeproj -scheme ZacksCourt -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO -quiet
APP=$(find "$DD/Build/Products/Release-iphonesimulator" -maxdepth 1 -name 'ZacksCourt.app' | head -1)
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" com.claude89757.zackscourt data)
mkdir -p "$DATA/Documents/Zacks Court/Sessions"
swift run -c release court-probe demo-session "$DATA/Documents/Zacks Court/Sessions" | tail -1

lang_pair() {
  case "$1" in
    zh-Hans) echo "zh-Hans zh_CN" ;;
    zh-Hant) echo "zh-Hant zh_TW" ;;
    en) echo "en en_US" ;;
    ja) echo "ja ja_JP" ;;
    de) echo "de de_DE" ;;
    fr) echo "fr fr_FR" ;;
  esac
}
for lang in zh-Hans zh-Hant en ja de fr; do
  read -r apple locale < <(lang_pair "$lang")
  xcrun simctl spawn "$UDID" defaults write "Apple Global Domain" AppleLanguages -array "$apple"
  xcrun simctl spawn "$UDID" defaults write "Apple Global Domain" AppleLocale -string "$locale"
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl boot "$UDID" >/dev/null
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  out="$RAW/$lang"
  rm -rf "$out"
  mkdir -p "$out"
  TEST_RUNNER_COURT_UI_STORE_SHOTS="$out" TEST_RUNNER_COURT_LANGUAGE="$lang" \
    xcodebuild test-without-building -project apps/iphone/ZacksCourt.xcodeproj -scheme ZacksCourt \
    -configuration Release -destination "id=$UDID" -derivedDataPath "$DD" \
    -only-testing:ZacksCourtUITests/WorkspaceUITests/testStoreScreens -quiet
  echo "captured $lang -> $out"
done
echo "Screenshots are simulator captures of demo data, not a device recording and not a measurement."
