#!/bin/zsh
# Renders the App Store screenshots (iPhone 6.9", 1320×2868) for every locale in captions.json.
#
#   ./scripts/render-store-screens.sh            # browser-display screens + all frames
#
# Inputs in docs/app-store/screenshots/source/:
#   frames.html     the template (one frame per ?frame=…&lang=…)
#   captions.json   big captions per locale
#   raw/app-*.png   app screens from testStoreScreens (Release, demo record; see docs/app-store/README.md)
#   web-demo.js     a fake camera socket that feeds the labelled demo record to the browser display
# The browser-display screens (raw/web-*.png) are rendered here from Sources/CourtCore/Web.
# Output: docs/app-store/screenshots/iphone-6.9/<locale>/<frame>.png. Everything shown is demo data.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
SRC=docs/app-store/screenshots/source
OUT=docs/app-store/screenshots/iphone-6.9
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "Google Chrome is needed for headless rendering" >&2; exit 1; }

STAGE=$(mktemp -d)
PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; rm -rf "$STAGE"' EXIT

shoot() { # url width height scale out [virtual-time-ms]
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=$4 \
    --virtual-time-budget=${6:-9000} --window-size=$2,$3 --screenshot="$5" "$1" >/dev/null 2>&1
}
serve() { # dir port
  (cd "$1" && exec python3 -m http.server $2 --bind 127.0.0.1 >/dev/null 2>&1) &
  PIDS+=($!)
  for _ in {1..50}; do curl -s -o /dev/null "http://127.0.0.1:$2/" && return; sleep 0.1; done
  echo "server on $2 did not start" >&2; exit 1
}

# App screenshots must already be real simulator captures in raw/<ui-language>/.
# This script renders the browser display itself (real DOM) per language and composites captions.
# It does not copy one language's pixels into another, and it does not draw a fake app UI.
python3 - "$SRC" <<'PY'
import json, sys
from pathlib import Path
src = Path(sys.argv[1])
captions = json.loads((src / "captions.json").read_text())
def ui(lang):
    return "en" if lang.startswith("en") else lang
missing = []
for lang in captions:
    folder = src / "raw" / ui(lang)
    for name in ("app-summary.png", "app-bounces.png", "app-shots.png"):
        if not (folder / name).is_file():
            missing.append(f"{lang} ({ui(lang)}): {name}")
if missing:
    print("Refusing to render. These real UI captures are not in docs/app-store/screenshots/source/raw/<language>/:", file=sys.stderr)
    for line in missing:
        print("  " + line, file=sys.stderr)
    print("Run scripts/capture-store-ui.sh on a Mac with Xcode. This machine has not captured them.", file=sys.stderr)
    sys.exit(2)
PY

# 1. Browser display with the demo record: the 20th shot is a forehand called out at the baseline.
mkdir -p "$STAGE/web" "$STAGE/demo"
cp Sources/CourtCore/Web/* "$STAGE/web/"
cp "$SRC/web-demo.js" "$STAGE/web/mock.js"
sed 's#<script type="module" src="app.js"></script>#<script src="mock.js"></script><script type="module" src="app.js"></script>#' \
  "$STAGE/web/index.html" > "$STAGE/web/demo.html"
swift run -q court-probe demo-session "$STAGE/demo" >/dev/null
python3 - "$STAGE" <<'PY'
import glob, json, sys
stage = sys.argv[1]
rows = json.load(open(glob.glob(stage + "/demo/*.json")[0]))["tennisEvents"][:20]
json.dump({"older": rows[:-1], "newest": rows[-1]}, open(stage + "/web/demo-rows.json", "w"))
PY
serve "$STAGE/web" 8765
WEB=http://127.0.0.1:8765/demo.html
# One real browser render per UI language. en-US and en-GB share en.
for ui in $(python3 -c "import json;langs=json.load(open('$SRC/captions.json'));print(' '.join(dict.fromkeys('en' if k.startswith('en') else k for k in langs)))"); do
  mkdir -p "$SRC/raw/$ui"
  shoot "$WEB?view=challenge&lang=$ui" 956 440 3 "$SRC/raw/$ui/web-challenge.png"
  shoot "$WEB?view=serve&lang=$ui" 956 440 3 "$SRC/raw/$ui/web-serve.png"
  shoot "$WEB?view=board&lang=$ui" 1180 820 2 "$SRC/raw/$ui/web-board-alert.png" 1800
done

# 2. The frames.
serve "$ROOT/$SRC" 8766
for lang in $(python3 -c "import json;print(' '.join(json.load(open('$SRC/captions.json'))))"); do
  mkdir -p "$OUT/$lang"
  for frame in $(python3 -c "import json;print(' '.join(json.load(open('$SRC/captions.json'))['$lang']['frames']))"); do
    shoot "http://127.0.0.1:8766/frames.html?frame=$frame&lang=$lang" 1320 2868 1 "$OUT/$lang/$frame.png" 4000
    size=$(sips -g pixelWidth -g pixelHeight "$OUT/$lang/$frame.png" | awk '/pixel/{printf "%s ", $2}')
    [[ "$size" == "1320 2868 " ]] || { echo "$lang/$frame is $size, expected 1320 2868" >&2; exit 1; }
    echo "$OUT/$lang/$frame.png"
  done
done
