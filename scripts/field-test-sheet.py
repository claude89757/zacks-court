#!/usr/bin/env python3
"""Turn a saved Zacks Court session into a field-test reference sheet (CSV).

One row per shot the app recorded, in ledger order, split into blocks by the session's markers
(press 「待复核」 or 「精彩」 at the start of each block, see docs/field-test-plan.md). Each row names
the recording and the second inside it. Nobody labels shots by hand: ref_stroke is filled from the
block name when the block is a single-stroke drill (「正手」, 「发球近端」 ...), and the other reference
columns take instrument readings only (measured targets ref_x_m / ref_y_m; ref_speed_kph stays empty,
since field tests use no radar).
Then run scripts/field-test-report.py on the sheet.

    scripts/field-test-sheet.py SESSION.json --blocks "发球近端,发球远端,底线对拉" -o sheet.csv
    scripts/field-test-sheet.py --self-test

Standard library only. The sheet is written with a UTF-8 BOM so Numbers and Excel open it directly.
"""
import argparse
import csv
import io
import json
import sys

STROKES = {
    "groundstroke": "落地击球", "forehand": "正手", "backhand": "反手", "serve": "发球",
    "volley": "截击", "overhead": "高压", "feed": "喂球", "unknown": "待确认",
}
# Strokes a single-stroke drill block can stand for; the block name is then the stroke reference.
DRILL_STROKES = ["正手", "反手", "发球", "截击", "高压", "喂球"]
COLUMNS = [
    "block_no", "block", "shot_in_block", "shot_id", "recording", "recording_time",
    "app_stroke", "app_confidence", "app_speed_kph", "app_speed_reason",
    "app_x_m", "app_y_m", "app_bounce_reason", "origin",
    "ref_stroke", "ref_speed_kph", "ref_x_m", "ref_y_m", "note",
]


def marker_times(session):
    """Markers in event order with a source PTS. A marker replayed after a reconnect has no PTS;
    it is estimated from the nearest event of the same stream that has both a date and a PTS."""
    events = session.get("events") or []
    anchors = [e for e in events if e.get("sourcePTS") is not None and e.get("date") is not None]
    markers, estimated, unplaced = [], 0, 0
    for event in events:
        if event.get("kind") != "marker":
            continue
        pts, stream = event.get("sourcePTS"), event.get("streamID")
        if pts is None and event.get("date") is not None:
            same = [a for a in anchors if stream is None or a.get("streamID") == stream]
            if same:
                nearest = min(same, key=lambda a: abs(a["date"] - event["date"]))
                pts = nearest["sourcePTS"] + (event["date"] - nearest["date"])
                stream = stream or nearest.get("streamID")
                estimated += 1
        if pts is None:
            unplaced += 1
            continue
        markers.append({"pts": pts, "stream": stream, "label": event.get("label") or "标记"})
    return markers, estimated, unplaced


def stream_order(session):
    order = []
    for item in (session.get("recordings") or []) + (session.get("tennisEvents") or []):
        stream = item.get("streamID")
        if stream and stream not in order:
            order.append(stream)
    return order


def assign_blocks(session):
    """Block number per shot: markers count up within a stream; a new stream continues the block
    it started in. Source clocks are compared only within one stream."""
    markers, estimated, unplaced = marker_times(session)
    order = stream_order(session)
    by_stream = {s: sorted([m for m in markers if m["stream"] == s], key=lambda m: m["pts"]) for s in order}
    loose = [m for m in markers if m["stream"] not in by_stream]
    offset, base = {}, 0
    for stream in order:
        offset[stream] = base
        base += len(by_stream[stream])
    blocks = []
    for shot in session.get("tennisEvents") or []:
        stream = shot.get("streamID")
        if stream not in by_stream:
            blocks.append(0)
            continue
        passed = sum(1 for m in by_stream[stream] if m["pts"] <= shot["sourcePTS"])
        blocks.append(offset[stream] + passed)
    return blocks, base, estimated, unplaced + len(loose)


def recording_for(session, shot):
    for recording in session.get("recordings") or []:
        start = recording.get("firstPTS", 0)
        if recording.get("streamID") == shot.get("streamID") and start <= shot["sourcePTS"] <= start + recording.get("duration", 0):
            return recording["filename"], shot["sourcePTS"] - start
    return "", None


def clock(seconds):
    if seconds is None:
        return ""
    minutes, rest = divmod(max(0.0, seconds), 60)
    return f"{int(minutes)}:{rest:04.1f}"


def number(value, digits=1):
    return "" if value is None else f"{value:.{digits}f}"


def block_stroke(name):
    """The stroke a single-stroke drill block stands for, or "" for mixed blocks (「对拉」, 「网前」,
    「正反手」). The name must be one stroke plus at most a side: 「发球近端」, 「反手（远端）」."""
    core = name
    for word in ("近端", "远端", "（", "）", "(", ")", " "):
        core = core.replace(word, "")
    return core if core in DRILL_STROKES else ""


def build_rows(session, names):
    blocks, count, estimated, unplaced = assign_blocks(session)
    rows, seen = [], {}
    for shot, block in zip(session.get("tennisEvents") or [], blocks):
        seen[block] = seen.get(block, 0) + 1
        filename, seconds = recording_for(session, shot)
        bounce = shot.get("bounce") or {}
        stroke = shot.get("stroke", "unknown")
        name = "开场前" if block == 0 else (names[block - 1] if block - 1 < len(names) else f"第 {block} 段")
        rows.append({
            "block_no": block,
            "block": name,
            "shot_in_block": seen[block], "shot_id": shot.get("id", ""),
            "recording": filename, "recording_time": clock(seconds),
            "app_stroke": f"{STROKES.get(stroke, stroke)} ({stroke})",
            "app_confidence": number(shot.get("confidence"), 2),
            "app_speed_kph": number(shot.get("speedKPH")),
            "app_speed_reason": "" if shot.get("speedKPH") is not None else (shot.get("speedReason") or ""),
            "app_x_m": number(bounce.get("xMeters"), 2), "app_y_m": number(bounce.get("yMeters"), 2),
            "app_bounce_reason": "" if bounce.get("xMeters") is not None else (bounce.get("reason") or "无触地候选"),
            "origin": shot.get("origin") or "live",
            "ref_stroke": block_stroke(name) if block else "", "ref_speed_kph": "", "ref_x_m": "", "ref_y_m": "", "note": "",
        })
    return rows, {"shots": len(rows), "blocks": count, "estimated_markers": estimated, "unplaced_markers": unplaced}


def write_csv(rows, handle):
    writer = csv.DictWriter(handle, fieldnames=COLUMNS)
    writer.writeheader()
    writer.writerows(rows)


def self_test():
    a, b = "AAAA", "BBBB"
    session = {
        "events": [
            {"kind": "marker", "label": "待复核", "date": 100.0, "sourcePTS": 10.0, "streamID": a},
            {"kind": "pause", "date": 120.0, "sourcePTS": 30.0, "streamID": a},
            # Replayed after a reconnect: no PTS, estimated from the pause 5 s earlier.
            {"kind": "marker", "label": "待复核", "date": 125.0, "streamID": a},
            {"kind": "marker", "label": "待复核", "date": 300.0, "sourcePTS": 5.0, "streamID": b},
        ],
        "recordings": [
            {"filename": "a.mov", "firstPTS": 0.0, "duration": 60.0, "streamID": a},
            {"filename": "b.mov", "firstPTS": 0.0, "duration": 60.0, "streamID": b},
        ],
        "tennisEvents": [
            {"id": "s1", "streamID": a, "sourcePTS": 5.0, "stroke": "feed", "confidence": 0.5},
            {"id": "s2", "streamID": a, "sourcePTS": 12.0, "stroke": "serve", "confidence": 0.8, "speedKPH": 150.0,
             "bounce": {"sourcePTS": 12.6, "xMeters": 5.0, "yMeters": 18.0, "confidence": 0.6}},
            {"id": "s3", "streamID": a, "sourcePTS": 40.0, "stroke": "forehand", "confidence": 0.7, "speedReason": "飞行时长不在已支持范围"},
            # A new stream restarts its clock: PTS 2 is before that stream's first marker.
            {"id": "s4", "streamID": b, "sourcePTS": 2.0, "stroke": "backhand", "confidence": 0.6},
            {"id": "s5", "streamID": b, "sourcePTS": 8.0, "stroke": "volley", "confidence": 0.6},
        ],
    }
    rows, info = build_rows(session, ["发球", "对拉", "网前"])
    assert [r["block_no"] for r in rows] == [0, 1, 2, 2, 3], [r["block_no"] for r in rows]
    assert [r["block"] for r in rows] == ["开场前", "发球", "对拉", "对拉", "网前"]
    assert info == {"shots": 5, "blocks": 3, "estimated_markers": 1, "unplaced_markers": 0}, info
    assert rows[1]["recording"] == "a.mov" and rows[1]["recording_time"] == "0:12.0"
    assert rows[1]["app_speed_kph"] == "150.0" and rows[1]["app_x_m"] == "5.00"
    assert rows[2]["app_speed_kph"] == "" and rows[2]["app_speed_reason"] == "飞行时长不在已支持范围"
    assert rows[0]["app_bounce_reason"] == "无触地候选" and rows[0]["app_stroke"] == "喂球 (feed)"
    # drill blocks give the stroke reference; mixed blocks and the pre-start block stay empty
    assert [r["ref_stroke"] for r in rows] == ["", "发球", "", "", ""], [r["ref_stroke"] for r in rows]
    assert (block_stroke("发球近端"), block_stroke("截击"), block_stroke("正反手"), block_stroke("自由练习"), block_stroke("反手（远端）")) == ("发球", "截击", "", "", "反手")
    buffer = io.StringIO()
    write_csv(rows, buffer)
    back = list(csv.DictReader(io.StringIO(buffer.getvalue())))
    assert [r["shot_id"] for r in back] == ["s1", "s2", "s3", "s4", "s5"]
    empty, info = build_rows({"events": [], "recordings": [], "tennisEvents": []}, [])
    assert empty == [] and info["shots"] == 0
    print("PASS: field-test-sheet self-test (blocks per stream, replayed marker estimated, recording time, drill stroke reference, empty session)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("session", nargs="?", help="session JSON (Sessions/<id>.json)")
    parser.add_argument("--blocks", default="", help="comma-separated block names, in marker order")
    parser.add_argument("-o", "--output", help="CSV path (default: stdout)")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.session:
        parser.error("session JSON required")
    with open(args.session, encoding="utf-8") as handle:
        session = json.load(handle)
    names = [n.strip() for n in args.blocks.split(",") if n.strip()]
    rows, info = build_rows(session, names)
    if args.output:
        with open(args.output, "w", encoding="utf-8-sig", newline="") as handle:
            write_csv(rows, handle)
    else:
        write_csv(rows, sys.stdout)
    message = f"{info['shots']} 拍，{info['blocks']} 段（按标记切分）"
    if info["estimated_markers"]:
        message += f"；{info['estimated_markers']} 个标记没有机位时间，按最近事件估算"
    if info["unplaced_markers"]:
        message += f"；{info['unplaced_markers']} 个标记无法定位，未用于分段"
    if names and len(names) != info["blocks"]:
        message += f"；注意：给了 {len(names)} 个段名，会话里有 {info['blocks']} 个标记"
    print(message, file=sys.stderr)


if __name__ == "__main__":
    main()
