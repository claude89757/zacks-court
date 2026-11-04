#!/bin/zsh
# Records the App Store preview video (iPhone 6.9", landscape 1920x886, 30 fps, silent audio track)
# from the demo record on a simulator: the full-screen speed board, then three line-call replays.
#
#   ./scripts/record-store-preview.sh <SIMULATOR_UDID> <OUT_DIR>
#
# Use a dedicated new iPhone 17 Pro Max simulator (booted ones are shared with other sessions).
# The record is made up by `court-probe demo-session` and titled 演示数据; the video says so in its
# corner. Writes <OUT_DIR>/preview-raw.mov, marks.txt and preview-1920x886.mp4.
# Needs ffmpeg (with overlay; Homebrew's build has no drawtext) and Pillow for the caption.
set -euo pipefail
UDID=${1:?simulator UDID}
OUT=${2:?output folder}
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
TEST_RUNNER_COURT_UI_STORE_PREVIEW="$OUT" xcodebuild test-without-building -project apps/iphone/ZacksCourt.xcodeproj -scheme ZacksCourt \
  -configuration Release -destination "id=$UDID" -derivedDataPath "$DD" \
  -only-testing:ZacksCourtUITests/WorkspaceUITests/testStorePreviewFlow -quiet || { kill -INT $REC; wait $REC || true; exit 1; }
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
