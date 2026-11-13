#!/usr/bin/env python3
"""Font discovery and recording-clock check for scripts/record-store-preview.sh.

font: print one installed font whose cmap contains every non-space character of
the caption. A missing preferred path is skipped. COURT_PREVIEW_FONT is an
override and must itself cover the caption.

timing: compare the raw recording's duration with the time the recorder process
was alive (start until the INT that stops it). The test process can keep running
after that INT; that tail is logged and is not part of the pass/fail window.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

PREVIEW_CAPTIONS = {
    "zh-Hans": "画面为演示数据，不是实测",
    "zh-Hant": "畫面為示範資料，不是實測",
    "en": "Demo data, not a measurement",
    "ja": "デモデータです。実測ではありません",
    "de": "Demodaten, keine Messung",
    "fr": "Données de démo, pas une mesure",
}

# Tried in order, and only when the file is actually installed.
PREFERRED_NAMES = (
    "Hiragino Sans GB.ttc",
    "PingFang.ttc",
    "Hiragino Sans CNS.ttc",
    "Hiragino Sans.ttc",
    "STHeiti Medium.ttc",
    "Hiragino Sans GB W3.ttc",
    "Arial Unicode.ttf",
    "NotoSansCJK-Regular.ttc",
    "NotoSansCJKjp-Regular.otf",
    "NotoSansCJKsc-Regular.otf",
    "wqy-microhei.ttc",
    "DroidSansFallbackFull.ttf",
    "DejaVuSans.ttf",
)


def needed_codes(text: str) -> set[int]:
    return {ord(ch) for ch in text if not ch.isspace()}


def _glyph_in_format(data: bytes, sub: int, code: int) -> bool:
    if sub + 2 > len(data):
        return False
    fmt = struct.unpack_from(">H", data, sub)[0]
    if fmt == 0 and sub + 6 + 256 <= len(data) and code < 256:
        return data[sub + 6 + code] != 0
    if fmt == 6 and sub + 10 <= len(data):
        first, count = struct.unpack_from(">HH", data, sub + 6)
        if code < first or code >= first + count:
            return False
        pos = sub + 10 + (code - first) * 2
        if pos + 2 > len(data):
            return False
        return struct.unpack_from(">H", data, pos)[0] != 0
    if fmt == 4 and sub + 14 <= len(data):
        seg_count = struct.unpack_from(">H", data, sub + 6)[0] // 2
        if seg_count <= 0 or seg_count > 20000:
            return False
        end_at = sub + 14
        start_at = end_at + seg_count * 2 + 2
        delta_at = start_at + seg_count * 2
        offset_at = delta_at + seg_count * 2
        if offset_at + seg_count * 2 > len(data):
            return False
        for index in range(seg_count):
            end = struct.unpack_from(">H", data, end_at + index * 2)[0]
            start = struct.unpack_from(">H", data, start_at + index * 2)[0]
            if code < start or code > end:
                continue
            delta = struct.unpack_from(">h", data, delta_at + index * 2)[0]
            range_offset = struct.unpack_from(">H", data, offset_at + index * 2)[0]
            if range_offset == 0:
                return ((code + delta) & 0xFFFF) != 0
            pos = offset_at + index * 2 + range_offset + (code - start) * 2
            if pos + 2 > len(data):
                return False
            glyph = struct.unpack_from(">H", data, pos)[0]
            if glyph == 0:
                return False
            return ((glyph + delta) & 0xFFFF) != 0
        return False
    if fmt == 12 and sub + 16 <= len(data):
        groups = struct.unpack_from(">I", data, sub + 12)[0]
        pos = sub + 16
        if groups > 100000 or pos + groups * 12 > len(data):
            return False
        for _ in range(groups):
            start, end, glyph = struct.unpack_from(">III", data, pos)
            pos += 12
            if start <= code <= end:
                return glyph + (code - start) != 0
        return False
    return False


def _cmap_offsets(data: bytes) -> list[int]:
    if len(data) < 12:
        return []
    fonts: list[int] = []
    if data[:4] == b"ttcf":
        count = struct.unpack_from(">I", data, 8)[0]
        if 12 + count * 4 > len(data) or count > 64:
            return []
        fonts = list(struct.unpack_from(f">{count}I", data, 12))
    else:
        fonts = [0]
    found: list[int] = []
    for origin in fonts:
        if origin + 12 > len(data):
            continue
        tables = struct.unpack_from(">H", data, origin + 4)[0]
        base = origin + 12
        if tables > 256 or base + tables * 16 > len(data):
            continue
        for index in range(tables):
            tag, _checksum, offset, _length = struct.unpack_from(">4sIII", data, base + index * 16)
            if tag == b"cmap" and offset + 4 <= len(data):
                found.append(offset)
    return found


def font_covers(path: Path, text: str) -> bool:
    try:
        data = path.read_bytes()
    except OSError:
        return False
    codes = needed_codes(text)
    if not codes:
        return True
    for cmap in _cmap_offsets(data):
        if cmap + 4 > len(data):
            continue
        subtables = struct.unpack_from(">H", data, cmap + 2)[0]
        if subtables > 64 or cmap + 4 + subtables * 8 > len(data):
            continue
        subs = []
        for index in range(subtables):
            _platform, _encoding, rel = struct.unpack_from(">HHI", data, cmap + 4 + index * 8)
            subs.append(cmap + rel)
        if all(any(_glyph_in_format(data, sub, code) for sub in subs) for code in codes):
            return True
    return False


def font_roots() -> list[Path]:
    return [
        Path("/System/Library/Fonts"),
        Path("/System/Library/Fonts/Supplemental"),
        Path("/Library/Fonts"),
        Path.home() / "Library/Fonts",
        Path("/usr/share/fonts"),
    ]


def _named(roots: list[Path], name: str) -> list[Path]:
    found: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        found.extend(path for path in root.rglob(name) if path.is_file())
    return found


def choose_font(text: str, override: str | None = None, roots: list[Path] | None = None) -> Path:
    if override:
        path = Path(override)
        if not path.is_file():
            raise SystemExit(f"COURT_PREVIEW_FONT is not a file: {path}")
        if not font_covers(path, text):
            raise SystemExit(f"COURT_PREVIEW_FONT does not cover this caption: {path}")
        return path
    search = roots if roots is not None else font_roots()
    for name in PREFERRED_NAMES:
        for path in _named(search, name):
            if font_covers(path, text):
                return path
    suffixes = {".ttf", ".ttc", ".otf"}
    for root in search:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if path.suffix.lower() not in suffixes or not path.is_file():
                continue
            if path.name in PREFERRED_NAMES:
                continue
            if font_covers(path, text):
                return path
    raise SystemExit("No installed font covers this caption. Set COURT_PREVIEW_FONT to one that does.")


def assess_clock(raw: float, alive: float, limit: float = 0.10) -> tuple[bool, float]:
    """True when the file length stays within `limit` of the recorder-alive window."""
    if alive <= 0:
        raise SystemExit("The recorder-alive window is empty")
    if raw <= 0:
        raise SystemExit("The raw recording has no duration")
    ratio = raw / alive
    return abs(raw - alive) <= limit * alive, ratio


def write_timing(path: Path, raw: float, start: float, alive_end: float, test_end: float, marks_path: Path) -> bool:
    alive = alive_end - start
    ok, ratio = assess_clock(raw, alive)
    lines = [
        f"raw_s {raw:.3f}",
        f"recorder_alive_s {alive:.3f}",
        f"test_exit_s {test_end - start:.3f}",
        f"ratio_raw_over_alive {ratio:.3f}",
        f"pass {str(ok).lower()}",
        "marks_offset_s",
    ]
    if marks_path.is_file():
        for line in marks_path.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2:
                lines.append(f"  {parts[0]} {float(parts[1]) - start:.3f}")
    path.write_text("\n".join(lines) + "\n")
    print(
        f"recording {raw:.1f} s for {alive:.1f} s of recorder time "
        f"(test process exited at {test_end - start:.1f} s, ratio {ratio:.2f})"
    )
    if not ok:
        print(
            "The recording drifted from the recorder clock; record again on a quieter Mac. "
            "The test-process exit is logged and is not the clock being checked.",
            file=sys.stderr,
        )
    return ok


def self_test() -> None:
    dejavu = Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
    cjk = Path("/usr/share/fonts/truetype/wqy/wqy-microhei.ttc")
    if not dejavu.is_file() or not cjk.is_file():
        raise SystemExit(f"self-test fonts missing: {dejavu} {cjk}")
    if not font_covers(dejavu, PREVIEW_CAPTIONS["en"]):
        raise SystemExit("DejaVu should cover the English caption")
    if font_covers(dejavu, PREVIEW_CAPTIONS["zh-Hans"]):
        raise SystemExit("DejaVu must not be treated as covering Chinese")
    for key in ("zh-Hans", "zh-Hant", "ja", "de", "fr", "en"):
        if not font_covers(cjk, PREVIEW_CAPTIONS[key]):
            raise SystemExit(f"wqy should cover the {key} caption")
    chosen = choose_font(PREVIEW_CAPTIONS["ja"], roots=[Path("/usr/share/fonts")])
    if not font_covers(chosen, PREVIEW_CAPTIONS["ja"]):
        raise SystemExit(f"choose_font returned a font that misses Japanese: {chosen}")
    if choose_font(PREVIEW_CAPTIONS["zh-Hant"], roots=[Path("/usr/share/fonts")]).name == "DejaVuSans.ttf":
        raise SystemExit("Traditional Chinese must not fall back to DejaVu")
    ok, ratio = assess_clock(48.0, 48.0)
    if not ok or abs(ratio - 1) > 0.001:
        raise SystemExit("a recording that matches recorder-alive time must pass")
    # The zh-Hans failure was raw ~48 s against a wall clock that still included tearDown (~83 s).
    slow_wall, _ = assess_clock(48.1, 83.4)
    if slow_wall:
        raise SystemExit("raw 48 s against an 83 s window must fail")
    kept, _ = assess_clock(48.1, 48.4)
    if not kept:
        raise SystemExit("the same 48 s file must pass when the recorder itself ran ~48 s")
    dropped, _ = assess_clock(26.0, 48.0)
    if dropped:
        raise SystemExit("a short file over a long recorder window must fail")
    print("store-preview-tools self-test passed")


def main(argv: list[str]) -> None:
    if "--self-test" in argv:
        self_test()
        return
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    font = sub.add_parser("font")
    font.add_argument("--caption", required=True)
    font.add_argument("--override", default="")
    caption = sub.add_parser("caption")
    caption.add_argument("--locale", required=True)
    timing = sub.add_parser("timing")
    timing.add_argument("--raw", type=float, required=True)
    timing.add_argument("--start", type=float, required=True)
    timing.add_argument("--alive-end", type=float, required=True)
    timing.add_argument("--test-end", type=float, required=True)
    timing.add_argument("--marks", type=Path, required=True)
    timing.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.cmd == "font":
        print(choose_font(args.caption, args.override or None))
        return
    if args.cmd == "caption":
        if args.locale not in PREVIEW_CAPTIONS:
            raise SystemExit(f"Unknown locale {args.locale}")
        print(PREVIEW_CAPTIONS[args.locale])
        return
    if not write_timing(args.out, args.raw, args.start, args.alive_end, args.test_end, args.marks):
        raise SystemExit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
