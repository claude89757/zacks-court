#!/bin/zsh
# Records the App Store preview video (iPhone 6.9", landscape 1920x886, 30 fps, silent audio track)
# from the demo record on a simulator: the full-screen speed board, then three line-call replays.
#
#   ./scripts/record-store-preview.sh <SIMULATOR_UDID> <OUT_DIR> [zh-Hans|zh-Hant|en|ja|de|fr]
#
# Records one language. Do not copy the file into another locale: the UI must be that language.
# Requires Xcode, a dedicated simulator, and ffmpeg. This script does not upload anything.
#
# Use a dedicated new iPhone 17 Pro Max simulator (booted ones are shared with other sessions).
# The record is made up by `court-probe demo-session` and titled 演示数据; the video says so in its
# corner. Writes <OUT_DIR>/preview-raw.mov, marks.txt, preview-1920x886.mp4 and frames/ (stills from each
# replay to compare with the app). It fails when the recording's timeline drifts from the clock or the
# picture freezes: the simulator recorder has silently done both on a busy Mac.
# Needs ffmpeg (with overlay; Homebrew's build has no drawtext) and Pillow for the caption.
set -euo pipefail
UDID=${1:?simulator UDID}
OUT=${2:?output folder}
LOCALE=${3:-zh-Hans}
case "$LOCALE" in
  zh-Hans) APPLE_LANG=zh-Hans; APPLE_LOCALE=zh_CN ;;
  zh-Hant) APPLE_LANG=zh-Hant; APPLE_LOCALE=zh_TW ;;
  en) APPLE_LANG=en; APPLE_LOCALE=en_US ;;
  ja) APPLE_LANG=ja; APPLE_LOCALE=ja_JP ;;
  de) APPLE_LANG=de; APPLE_LOCALE=de_DE ;;
  fr) APPLE_LANG=fr; APPLE_LOCALE=fr_FR ;;
  *) echo "Unknown locale $LOCALE" >&2; exit 2 ;;
esac
command -v xcodebuild >/dev/null || { echo "xcodebuild is required. This environment has not recorded a preview." >&2; exit 2; }
ROOT=${0:A:h:h}
DD="$ROOT/.local/dd-store-preview"
FONT=${COURT_PREVIEW_FONT:-/System/Library/Fonts/Hiragino Sans GB.ttc}
CAPTION=${COURT_PREVIEW_CAPTION:-画面为演示数据 · Demo data}
command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }
# Homebrew's python3 has no Pillow here; Xcode's /usr/bin/python3 does, so fall back to it.
PY=${COURT_PREVIEW_PYTHON:-python3}
"$PY" -c 'import PIL' 2>/dev/null || PY=/usr/bin/python3
"$PY" -c 'import PIL' 2>/dev/null || { echo "Pillow is required for the caption (python3 -m pip install pillow, or set COURT_PREVIEW_PYTHON)" >&2; exit 1; }
mkdir -p "$OUT"
OUT=${OUT:A}
cd "$ROOT"

# Release build without models: the video shows demo data only, and Release hides debug banners.
COURT_CODE_ONLY=1 ./scripts/generate-ios.sh >/dev/null
trap 'git -C "$ROOT" checkout -- apps/iphone/ZacksCourt/Info.plist 2>/dev/null || true' EXIT
xcodebuild build-for-testing -project apps/iphone/ZacksCourt.xcodeproj -scheme ZacksCourt -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO -quiet
APP=$(find "$DD/Build/Products/Release-iphonesimulator" -maxdepth 1 -name 'ZacksCourt.app' | head -1)
xcrun simctl spawn "$UDID" defaults write "Apple Global Domain" AppleLanguages -array "$APPLE_LANG"
xcrun simctl spawn "$UDID" defaults write "Apple Global Domain" AppleLocale -string "$APPLE_LOCALE"
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
xcrun simctl boot "$UDID" >/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" com.claude89757.zackscourt data)
mkdir -p "$DATA/Documents/Zacks Court/Sessions"
swift run -c release court-probe demo-session "$DATA/Documents/Zacks Court/Sessions" | tail -1

RAW="$OUT/preview-raw.mov"; LOG="$OUT/record.log"
rm -f "$RAW" "$OUT/marks.txt"
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$RAW" 2>"$LOG" &
REC=$!
for _ in {1..50}; do grep -q -i 'recording started' "$LOG" && break; sleep 0.1; done
START=$(python3 -c 'import time; print(time.time())')
TEST_RUNNER_COURT_UI_STORE_PREVIEW="$OUT" TEST_RUNNER_COURT_LANGUAGE="$LOCALE" xcodebuild test-without-building -project apps/iphone/ZacksCourt.xcodeproj -scheme ZacksCourt \
  -configuration Release -destination "id=$UDID" -derivedDataPath "$DD" \
  -only-testing:ZacksCourtUITests/WorkspaceUITests/testStorePreviewFlow -quiet || { kill -INT $REC; wait $REC || true; exit 1; }
STOP=$(python3 -c 'import time; print(time.time())')
kill -INT $REC; wait $REC || true
[[ -s "$OUT/marks.txt" ]] || { echo "The UI test wrote no marks.txt" >&2; exit 1; }

# Trim to the marks (15–30 s as Apple requires), turn the portrait framebuffer to landscape, scale to
# 1920x886, 30 fps, add the caption and a silent stereo track.
read -r FROM LENGTH < <(python3 - "$OUT/marks.txt" "$START" <<'PY'
import sys
marks = dict(line.split() for line in open(sys.argv[1]) if line.strip())
start = float(sys.argv[2])
a, b = float(marks["start"]) - start, float(marks["end"]) - start
length = min(30.0, max(15.0, b - a))
print(f"{max(0.0, a):.2f} {length:.2f}")
PY
)
# The caption is drawn by Pillow into a transparent PNG and overlaid: Homebrew's ffmpeg has no
# drawtext (no libfreetype), and overlay is a core filter.
CAP="$OUT/.caption.png"
"$PY" - "$CAP" "$CAPTION" "$FONT" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
path, text, font = sys.argv[1], sys.argv[2], sys.argv[3]
W, H = 1920, 886
image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
face = ImageFont.truetype(font, 26)
l, t, r, b = draw.textbbox((0, 0), text, font=face)
draw.text((W - (r - l) - 36 - l, H - (b - t) - 28 - t), text, font=face, fill=(255, 255, 255, 191))
image.save(path)
PY
# The trim is output-side on purpose: input-side -ss/-t on this VFR screen recording starts at the
# keyframe after FROM (≈2 s late here) and cuts the end off.
ffmpeg -y -loglevel error -i "$RAW" -i "$CAP" -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
  -filter_complex "[0:v]transpose=${COURT_PREVIEW_TRANSPOSE:-2},scale=1920:886,setsar=1,fps=30[base];[1:v]format=rgba[cap];[base][cap]overlay=0:0,format=yuv420p[v]" \
  -map "[v]" -map 2:a -ss "$FROM" -t "$LENGTH" -c:v libx264 -profile:v high -pix_fmt yuv420p -b:v 10M -c:a aac -b:a 128k -shortest \
  -movflags +faststart "$OUT/preview-1920x886.mp4"
ffprobe -v error -show_entries stream=codec_type,width,height,r_frame_rate:format=duration -of compact "$OUT/preview-1920x886.mp4"

# The recording must keep time with the clock: on a loaded Mac it once held 4 s for 31 s of app time.
RAWLEN=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$RAW")
python3 - "$RAWLEN" "$START" "$STOP" <<'PY' || exit 1
import sys
raw, start, stop = map(float, sys.argv[1:])
wall = stop - start
print(f"recording {raw:.1f} s for {wall:.1f} s of clock time")
if abs(raw - wall) > 0.1 * wall:
    sys.exit("The recording drifted from the clock; record again on a quieter Mac")
PY
# No frozen stretch after the speed board: a replay stuck on its title once went unnoticed (a stuck
# replay stays still for its whole 7 s). The board (first 3 s) and each verdict hold (2–4 s, longer for
# the first replay while the test waits for it) are still on purpose.
FREEZES=$(ffmpeg -hide_banner -nostats -i "$OUT/preview-1920x886.mp4" -vf "trim=start=3.3,freezedetect=n=0.002:d=5" -an -f null - 2>&1 | grep -c freeze_start || true)
[[ "$FREEZES" == 0 ]] || { echo "The picture froze $FREEZES time(s) after the speed board; record again" >&2; exit 1; }
# Stills through each replay (title, flight, bounce, overhead, verdict) to check against the app.
mkdir -p "$OUT/frames"   # ffmpeg -y overwrites; no rm of a glob, which zsh aborts on when frames/ is empty
python3 - "$OUT/marks.txt" <<'PY' | while read -r NAME AT; do
import sys
marks = dict(line.split() for line in open(sys.argv[1]) if line.strip())
start = float(marks["start"])
for key in sorted(k for k in marks if k.startswith("replay")):
    for offset in (0.4, 2.0, 3.4, 4.8, 6.2, 7.2):
        print(f"{key}-{offset:.1f} {float(marks[key]) - start + offset:.2f}")
PY
  ffmpeg -nostdin -y -loglevel error -i "$OUT/preview-1920x886.mp4" -vf "trim=start=$AT,setpts=PTS-STARTPTS" -frames:v 1 "$OUT/frames/$NAME.png"
done
ls "$OUT/frames" | wc -l | xargs echo "stills:"
