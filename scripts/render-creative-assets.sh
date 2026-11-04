#!/bin/zsh
# Renders the App Store creative asset (iOS 27+ product page header + search results): one universal
# 16:9 PNG per locale, 5244×2950, no alpha channel.
#
#   ./scripts/render-creative-assets.sh            # all locales in captions.json
#   GUIDES=1 ./scripts/render-creative-assets.sh   # also write *-guides.png with the 21:9 and 3:2 crops drawn
#
# Source: docs/app-store/creative-assets/source/ (universal.html + captions.json).
# Output: docs/app-store/creative-assets/<locale>/universal.png. Everything shown is demo data.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=docs/app-store/creative-assets/source
OUT=docs/app-store/creative-assets
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "Google Chrome is needed for headless rendering" >&2; exit 1; }

STAGE=$(mktemp -d)
PID=""
trap '[[ -n "$PID" ]] && kill $PID 2>/dev/null || true; rm -rf "$STAGE"' EXIT
cp "$SRC/universal.html" "$SRC/captions.json" "$STAGE/"
cp assets/brand/zacks-court-logo.svg "$STAGE/logo.svg"
(cd "$STAGE" && exec python3 -m http.server 8767 --bind 127.0.0.1 >/dev/null 2>&1) &
PID=$!
for _ in {1..50}; do curl -s -o /dev/null "http://127.0.0.1:8767/" && break; sleep 0.1; done

shoot() { # url out
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --virtual-time-budget=4000 --window-size=2622,1475 --screenshot="$2" "$1" >/dev/null 2>&1
}
for lang in $(python3 -c "import json;print(' '.join(json.load(open('$SRC/captions.json'))))"); do
  mkdir -p "$OUT/$lang"
  png="$OUT/$lang/universal.png"
  shoot "http://127.0.0.1:8767/universal.html?lang=$lang" "$STAGE/raw.png"
  # Apple refuses images with an alpha channel: round-trip through JPEG at top quality drops it.
  sips -s format jpeg -s formatOptions 100 "$STAGE/raw.png" --out "$STAGE/flat.jpg" >/dev/null
  sips -s format png "$STAGE/flat.jpg" --out "$png" >/dev/null
  info=$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$png" | awk '/pixelWidth|pixelHeight|hasAlpha/{printf "%s ", $2}')
  [[ "$info" == "5244 2950 no " ]] || { echo "$png is $info, expected 5244 2950 no" >&2; exit 1; }
  echo "$png"
  if [[ -n "${GUIDES:-}" ]]; then
    shoot "http://127.0.0.1:8767/universal.html?lang=$lang&guides=1" "$OUT/$lang/universal-guides.png"
  fi
done
