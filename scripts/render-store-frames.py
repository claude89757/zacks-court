#!/usr/bin/env python3
"""Compose 1320×2868 store frames from real screenshots. Does not open a browser.

The phone picture is a PNG captured from the app (scripts/capture-store-ui.sh).
Captions and the demo disclaimer come from docs/app-store/screenshots/source/captions.json.
A missing screenshot is reported and that frame is not drawn. Nothing here is a measurement.

    python3 scripts/render-store-frames.py --self-test
    python3 scripts/render-store-frames.py            # needs raw/<language>/*.png
    COURT_STORE_RAW=/path/to/raw python3 scripts/render-store-frames.py

en-US and en-GB both use the English captures in raw/en/.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
CAPTIONS = ROOT / "docs/app-store/screenshots/source/captions.json"
DEFAULT_RAW = ROOT / "docs/app-store/screenshots/source/raw"
OUT = ROOT / "docs/app-store/screenshots/iphone-6.9"
W, H = 1320, 2868

# Which captured screen each marketing frame uses. These names are what
# testStoreScreens writes. Web-only pictures are not invented.
FRAME_SHOT = {
    "01-scene": "00-home.png",
    "04-replay": "01-history.png",
    "05-private": "03-detail-0.png",
    "03-serve-speed": "02-query.png",
    "02-line-calls": "03-detail-3.png",
}

INK = (255, 255, 255)
MUTED = (181, 195, 186)
BG = (11, 25, 18)
BEZEL = (38, 43, 40)


def ui_language(locale: str) -> str:
    return "en" if locale.startswith("en") else locale


def load_font(size: int) -> ImageFont.FreeTypeFont:
    candidates = [
        os.environ.get("COURT_FRAME_FONT") or "",
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        if path and Path(path).is_file():
            return ImageFont.truetype(path, size)
    raise SystemExit("No font found for store frames. Set COURT_FRAME_FONT.")


def wrap(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, width: int) -> list[str]:
    lines: list[str] = []
    for paragraph in text.replace("[", "").replace("]", "").split("\n"):
        current = ""
        pieces = list(paragraph) if any("\u4e00" <= ch <= "\u9fff" for ch in paragraph) else paragraph.split(" ")
        gap = "" if pieces and len(pieces[0]) == 1 and any("\u4e00" <= ch <= "\u9fff" for ch in paragraph) else " "
        for word in pieces:
            trial = word if not current else current + gap + word
            if draw.textlength(trial, font=font) <= width:
                current = trial
            else:
                if current:
                    lines.append(current)
                current = word
        if current:
            lines.append(current)
    return lines or [""]


def paste_screen(canvas: Image.Image, shot: Path, top: int) -> None:
    screen = Image.open(shot).convert("RGB")
    bezel = 18
    inner_w = 1000
    inner_h = round(inner_w * screen.height / screen.width)
    max_h = H - top - 220
    if inner_h > max_h:
        inner_h = max_h
        inner_w = round(inner_h * screen.width / screen.height)
    x = (W - inner_w) // 2
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        (x - bezel, top - bezel, x + inner_w + bezel, top + inner_h + bezel),
        radius=48,
        fill=BEZEL,
    )
    canvas.paste(screen.resize((inner_w, inner_h), Image.Resampling.LANCZOS), (x, top))


def render_frame(locale: str, frame_id: str, caption: dict, shot: Path, dest: Path) -> None:
    image = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(image)
    title_font = load_font(92 if locale.startswith("en") else 100)
    body_font = load_font(42)
    demo_font = load_font(28)
    title = wrap(draw, caption["title"], title_font, W - 160)
    y = 140
    for line in title:
        # Bracketed words in the source are the emphasis; the brackets are not drawn.
        draw.text((80, y), line, font=title_font, fill=INK)
        y += 118
    y += 10
    for line in wrap(draw, caption.get("sub", ""), body_font, W - 160):
        draw.text((80, y), line, font=body_font, fill=MUTED)
        y += 56
    paste_screen(image, shot, y + 48)
    demo = caption.get("_demo") or ""
    tw = draw.textlength(demo, font=demo_font)
    draw.text((W - tw - 64, H - 72), demo, font=demo_font, fill=MUTED)
    dest.parent.mkdir(parents=True, exist_ok=True)
    image.save(dest, "PNG")


def raw_root() -> Path:
    return Path(os.environ.get("COURT_STORE_RAW") or DEFAULT_RAW)


def compose(captions: dict, root: Path, out: Path) -> tuple[list[str], list[str]]:
    made: list[str] = []
    missing: list[str] = []
    for locale, pack in captions.items():
        language = ui_language(locale)
        frames = pack.get("frames") or {}
        demo = pack.get("demo") or ""
        for frame_id, shot_name in FRAME_SHOT.items():
            if frame_id not in frames:
                continue
            shot = root / language / shot_name
            dest = out / locale / f"{frame_id}.png"
            if not shot.is_file():
                missing.append(f"{locale} {frame_id}: missing {shot}")
                continue
            caption = dict(frames[frame_id])
            caption["_demo"] = demo
            render_frame(locale, frame_id, caption, shot, dest)
            made.append(f"{dest}  <=  {shot}")
    return made, missing


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "raw" / "en"
        root.mkdir(parents=True)
        fixture = Image.new("RGB", (400, 800), (180, 40, 40))
        d = ImageDraw.Draw(fixture)
        d.text((16, 40), "FIXTURE NOT A CAPTURE", font=load_font(28), fill=(255, 255, 255))
        for name in FRAME_SHOT.values():
            fixture.save(root / name)
        captions = {
            "en-US": {
                "demo": "Demo data, not a measurement",
                "frames": {
                    key: {"title": "Layout [check]", "sub": "Not an app screenshot."}
                    for key in FRAME_SHOT
                },
            }
        }
        out = Path(tmp) / "out"
        made, missing = compose(captions, Path(tmp) / "raw", out)
        if missing or len(made) != len(FRAME_SHOT):
            raise SystemExit(f"self-test did not draw every frame: {missing}")
        image = Image.open(out / "en-US" / "01-scene.png")
        if image.size != (W, H):
            raise SystemExit(f"self-test size {image.size}")
    empty = Path(tempfile.mkdtemp())
    made, missing = compose({"en-US": {"demo": "x", "frames": {"01-scene": {"title": "t", "sub": "s"}}}}, empty, empty / "o")
    if made or not missing:
        raise SystemExit("self-test should refuse a missing screenshot")
    print("render-store-frames self-test passed")


def main(argv: list[str]) -> None:
    if "--self-test" in argv:
        self_test()
        return
    if not CAPTIONS.is_file():
        raise SystemExit(f"Missing {CAPTIONS}")
    captions = json.loads(CAPTIONS.read_text())
    made, missing = compose(captions, raw_root(), OUT)
    report = OUT / "SOURCES.txt"
    lines = ["Each frame is a real screenshot pasted into a caption frame.", "Missing files were not replaced with a drawing.", ""]
    lines += made or ["(none produced)"]
    lines.append("")
    lines += missing
    report.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    if made:
        report.write_text("\n".join(lines) + "\n")
    if not made:
        raise SystemExit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
