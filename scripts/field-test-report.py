#!/usr/bin/env python3
"""Compare a filled field-test sheet with its reference values (docs/field-test-plan.md).

Reads the CSV from scripts/field-test-sheet.py after the reference columns were filled:

- ref_stroke: 正手/反手/发球/截击/高压/喂球 (or the English names), filled by field-test-sheet.py from
  single-stroke drill block names; empty means no reference. Nobody labels shots by hand (user,
  2026-10-30); 「无」 (false detection) is still read from older sheets.
- ref_speed_kph: an independent speed reading for that shot, if there is one. Field tests use no radar
  (user, 2026-11-05), so this column is usually empty and only coverage is reported.
- ref_x_m / ref_y_m: independent landing position in court metres (x from the near-left doubles
  corner across, y from the near baseline toward the far one).
- Rows with an empty shot_id are real shots the app did not record (misses; older sheets only).
- --planned "正手=15,反手=15": the planned ball count per block. Detection is then the app's shot count
  per block against the plan, since misses are no longer added by hand.

Every figure is printed with its denominator; a missing value is never counted as 0. The app's
speed is a fitted estimate and a reference may measure something else, so the signed bias is shown
on its own and nothing is corrected.

    scripts/field-test-report.py sheet.csv [--planned "正手=15,反手=15"] [--json report.json]
    scripts/field-test-report.py --self-test
"""
import argparse
import csv
import io
import json
import math
import statistics
import sys

ALIASES = {
    "正手": "forehand", "反手": "backhand", "发球": "serve", "截击": "volley", "高压": "overhead",
    "喂球": "feed", "落地击球": "groundstroke", "待确认": "unknown", "未知": "unknown",
}
FALSE = {"无", "none", "误检", "false"}
NAMES = {"groundstroke": "落地击球", "forehand": "正手", "backhand": "反手", "serve": "发球",
         "volley": "截击", "overhead": "高压", "feed": "喂球", "unknown": "待确认"}


def stroke(value):
    """'正手 (forehand)', 'forehand' or '正手' -> 'forehand'; '' -> None."""
    text = (value or "").strip()
    if not text:
        return None
    if "(" in text and text.endswith(")"):
        text = text[text.rindex("(") + 1:-1].strip()
    lowered = text.lower()
    if lowered in FALSE or text in FALSE:
        return "none"
    return ALIASES.get(text, lowered)


def number(value):
    try:
        result = float((value or "").strip())
        return result if math.isfinite(result) else None
    except ValueError:
        return None


def percentile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))] if ordered else None


def share(part, whole):
    return {"n": part, "of": whole, "percent": round(100 * part / whole, 1) if whole else None}


def analyse(rows, planned=None):
    app = [r for r in rows if (r.get("shot_id") or "").strip()]
    missed = [r for r in rows if not (r.get("shot_id") or "").strip()]
    false = [r for r in app if stroke(r.get("ref_stroke")) == "none"]
    real_app = [r for r in app if stroke(r.get("ref_stroke")) != "none"]
    labelled = [r for r in real_app if stroke(r.get("ref_stroke"))]
    report = {"detection": {
        "app_shots": len(app), "false_detections": len(false), "missed_shots": len(missed),
        "real_shots": len(real_app) + len(missed),
        "recall": share(len(real_app), len(real_app) + len(missed)) if missed else None,
        "note": "召回率只在记录表里有漏检行时计算（旧记录表）；现在不逐拍补录，检出看每段 App 拍数与计划球数。"}}

    # Speed: app estimate minus independent reference, for shots with both.
    with_ref = [r for r in real_app if number(r.get("ref_speed_kph")) is not None]
    pairs = [(number(r["app_speed_kph"]), number(r["ref_speed_kph"])) for r in with_ref if number(r.get("app_speed_kph")) is not None]
    reasons = {}
    for r in with_ref:
        if number(r.get("app_speed_kph")) is None:
            reasons[r.get("app_speed_reason") or "未给原因"] = reasons.get(r.get("app_speed_reason") or "未给原因", 0) + 1
    errors = [a - b for a, b in pairs]
    report["speed"] = {
        "reference_shots": len(with_ref) + sum(1 for r in missed if number(r.get("ref_speed_kph")) is not None),
        "coverage": share(len(pairs), len(with_ref)),
        "unknown_reasons": reasons,
        "bias_kph": round(statistics.mean(errors), 1) if errors else None,
        "mae_kph": round(statistics.mean(abs(e) for e in errors), 1) if errors else None,
        "p95_abs_kph": round(percentile([abs(e) for e in errors], 0.95), 1) if errors else None,
        "max_abs_kph": round(max(abs(e) for e in errors), 1) if errors else None,
        "within_5": share(sum(1 for e in errors if abs(e) <= 5), len(errors)) if errors else None,
        "within_10": share(sum(1 for e in errors if abs(e) <= 10), len(errors)) if errors else None,
    }

    # Strokes: exact class, and coarse where 落地击球 covers 正手/反手 (no confirmed handedness).
    confusion, exact, coarse, unknown = {}, 0, 0, 0
    for r in labelled:
        predicted, truth = stroke(r.get("app_stroke")) or "unknown", stroke(r["ref_stroke"])
        confusion.setdefault(truth, {}).setdefault(predicted, 0)
        confusion[truth][predicted] += 1
        if predicted == "unknown":
            unknown += 1
        exact += predicted == truth
        coarse += predicted == truth or (predicted == "groundstroke" and truth in ("forehand", "backhand"))
    report["stroke"] = {
        "labelled_shots": len(labelled), "app_unknown": unknown,
        "exact": share(exact, len(labelled)) if labelled else None,
        "coarse": share(coarse, len(labelled)) if labelled else None,
        "confusion": confusion,
    }

    # Placement: distance between the app's court position and the independent one.
    placed_ref = [r for r in real_app if number(r.get("ref_x_m")) is not None and number(r.get("ref_y_m")) is not None]
    distances = [math.hypot(number(r["app_x_m"]) - number(r["ref_x_m"]), number(r["app_y_m"]) - number(r["ref_y_m"]))
                 for r in placed_ref if number(r.get("app_x_m")) is not None and number(r.get("app_y_m")) is not None]
    report["placement"] = {
        "reference_bounces": len(placed_ref),
        "coverage": share(len(distances), len(placed_ref)),
        "median_m": round(statistics.median(distances), 2) if distances else None,
        "p95_m": round(percentile(distances, 0.95), 2) if distances else None,
        "within_0_5_m": share(sum(1 for d in distances if d <= 0.5), len(distances)) if distances else None,
        "within_1_m": share(sum(1 for d in distances if d <= 1.0), len(distances)) if distances else None,
    }

    blocks = {}
    for r in real_app:
        key = r.get("block") or "—"
        block = blocks.setdefault(key, {"shots": 0, "speed_pairs": [], "labelled": 0, "exact": 0})
        block["shots"] += 1
        a, b = number(r.get("app_speed_kph")), number(r.get("ref_speed_kph"))
        if a is not None and b is not None:
            block["speed_pairs"].append(a - b)
        if stroke(r.get("ref_stroke")):
            block["labelled"] += 1
            block["exact"] += (stroke(r.get("app_stroke")) or "unknown") == stroke(r["ref_stroke"])
    planned = planned or {}
    for name in planned:
        blocks.setdefault(name, {"shots": 0, "speed_pairs": [], "labelled": 0, "exact": 0})
    report["blocks"] = {k: {"shots": v["shots"], "planned": planned.get(k),
                            "shots_of_planned": share(v["shots"], planned[k]) if planned.get(k) else None,
                            "speed_pairs": len(v["speed_pairs"]),
                            "speed_bias_kph": round(statistics.mean(v["speed_pairs"]), 1) if v["speed_pairs"] else None,
                            "stroke_exact": share(v["exact"], v["labelled"]) if v["labelled"] else None}
                        for k, v in blocks.items()}
    return report


def parse_planned(text_value):
    """「正手=15,反手=15」 -> {"正手": 15, "反手": 15}."""
    out = {}
    for item in (text_value or "").split(","):
        if "=" in item:
            name, count = item.split("=", 1)
            out[name.strip()] = int(count)
    return out


def text(report):
    def pct(value):
        return "—" if not value or not value["of"] else f"{value['n']}/{value['of']}（{value['percent']}%）"

    def val(value, unit=""):
        return "—" if value is None else f"{value}{unit}"
    d, s, k, p = report["detection"], report["speed"], report["stroke"], report["placement"]
    lines = [
        "# 球场实测对照（模型估计 vs 独立参考；不是精度认证）", "",
        f"检出：App 记录 {d['app_shots']} 拍，其中误检 {d['false_detections']}；补录漏检 {d['missed_shots']}；召回 {pct(d['recall'])}",
        "",
        f"球速：有参考 {s['reference_shots']} 拍，App 给出球速 {pct(s['coverage'])}",
        f"  偏差（App − 参考，有符号平均）{val(s['bias_kph'], ' km/h')}；平均绝对误差 {val(s['mae_kph'], ' km/h')}；"
        f"P95 {val(s['p95_abs_kph'], ' km/h')}；最大 {val(s['max_abs_kph'], ' km/h')}",
        f"  ±5 km/h 内 {pct(s['within_5'])}；±10 km/h 内 {pct(s['within_10'])}",
    ]
    if s["unknown_reasons"]:
        lines.append("  App 未给球速的原因：" + "；".join(f"{r} × {n}" for r, n in s["unknown_reasons"].items()))
    lines += ["", f"动作：已标注 {k['labelled_shots']} 拍；完全一致 {pct(k['exact'])}；"
                  f"按大类（落地击球覆盖正反手）一致 {pct(k['coarse'])}；App 判为待确认 {k['app_unknown']}"]
    for truth, row in sorted(k["confusion"].items()):
        lines.append(f"  参考 {NAMES.get(truth, truth)} → " + "，".join(f"{NAMES.get(a, a)} {n}" for a, n in sorted(row.items())))
    lines += ["", f"落点：有独立位置 {p['reference_bounces']} 个，App 给出位置 {pct(p['coverage'])}",
              f"  距离误差中位数 {val(p['median_m'], ' m')}；P95 {val(p['p95_m'], ' m')}；0.5 m 内 {pct(p['within_0_5_m'])}；1 m 内 {pct(p['within_1_m'])}",
              "", "分段："]
    for name, block in report["blocks"].items():
        plan = f"（计划 {block['planned']} 球，{pct(block['shots_of_planned'])}）" if block.get("planned") else ""
        lines.append(f"  {name}：{block['shots']} 拍{plan}；球速配对 {block['speed_pairs']}，偏差 {val(block['speed_bias_kph'], ' km/h')}；动作一致 {pct(block['stroke_exact'])}")
    return "\n".join(lines)


def self_test():
    sheet = io.StringIO()
    writer = csv.writer(sheet)
    writer.writerow(["block", "shot_id", "app_stroke", "app_speed_kph", "app_speed_reason", "app_x_m", "app_y_m",
                     "ref_stroke", "ref_speed_kph", "ref_x_m", "ref_y_m"])
    writer.writerow(["发球", "s1", "发球 (serve)", "150", "", "5.0", "18.0", "发球", "160", "5.3", "18.4"])
    writer.writerow(["发球", "s2", "发球 (serve)", "", "飞行时长不在已支持范围", "", "", "serve", "170", "", ""])
    writer.writerow(["发球", "s3", "发球 (serve)", "140", "", "", "", "发球", "146", "", ""])
    writer.writerow(["对拉", "s4", "落地击球 (groundstroke)", "100", "", "4.0", "20.0", "正手", "", "4.0", "21.0"])
    writer.writerow(["对拉", "s5", "反手 (backhand)", "", "", "", "", "正手", "", "", ""])
    writer.writerow(["对拉", "s6", "截击 (volley)", "", "", "", "", "无", "", "", ""])
    writer.writerow(["对拉", "", "", "", "", "", "", "反手", "", "", ""])
    report = analyse(list(csv.DictReader(io.StringIO(sheet.getvalue()))))
    d, s, k, p = report["detection"], report["speed"], report["stroke"], report["placement"]
    assert (d["app_shots"], d["false_detections"], d["missed_shots"], d["real_shots"]) == (6, 1, 1, 6), d
    assert d["recall"]["n"] == 5 and d["recall"]["of"] == 6
    assert s["reference_shots"] == 3 and s["coverage"] == {"n": 2, "of": 3, "percent": 66.7}, s
    assert s["bias_kph"] == -8.0 and s["mae_kph"] == 8.0 and s["max_abs_kph"] == 10.0, s
    assert s["within_5"]["n"] == 0 and s["within_10"]["n"] == 2
    assert s["unknown_reasons"] == {"飞行时长不在已支持范围": 1}
    assert k["labelled_shots"] == 5 and k["exact"]["n"] == 3 and k["coarse"]["n"] == 4, k
    assert k["confusion"]["forehand"] == {"groundstroke": 1, "backhand": 1}
    assert p["reference_bounces"] == 2 and p["coverage"]["n"] == 2 and p["median_m"] == 0.75, p
    assert report["blocks"]["发球"]["speed_bias_kph"] == -8.0
    # Nothing filled in yet: no figures, never zeros.
    empty = analyse([{"shot_id": "x", "app_stroke": "发球 (serve)", "app_speed_kph": "120"}])
    assert empty["speed"]["bias_kph"] is None and empty["speed"]["coverage"]["percent"] is None
    assert empty["stroke"]["exact"] is None and empty["placement"]["median_m"] is None
    assert "—" in text(empty) and "None" not in text(empty) and "0/0" not in text(analyse([]))
    # A drill sheet: references from block names, no miss rows -> no recall; detection per planned block.
    drill = [{"block": "正手", "shot_id": f"f{i}", "app_stroke": "正手 (forehand)", "ref_stroke": "正手"} for i in range(13)]
    plan = analyse(drill, parse_planned("正手=15, 反手=15"))
    assert plan["detection"]["recall"] is None
    assert plan["blocks"]["正手"]["shots_of_planned"] == {"n": 13, "of": 15, "percent": 86.7}
    assert plan["blocks"]["反手"]["shots"] == 0 and plan["blocks"]["反手"]["shots_of_planned"]["n"] == 0
    assert "计划 15 球" in text(plan)
    print("PASS: field-test-report self-test (detection, speed bias, coarse strokes, placement distance, empty sheet, planned drill blocks)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("sheet", nargs="?", help="filled CSV from field-test-sheet.py")
    parser.add_argument("--planned", default="", help='planned balls per block, e.g. "正手=15,反手=15"')
    parser.add_argument("--json", help="also write the figures as JSON")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.sheet:
        parser.error("sheet CSV required")
    with open(args.sheet, encoding="utf-8-sig", newline="") as handle:
        report = analyse(list(csv.DictReader(handle)), parse_planned(args.planned))
    print(text(report))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
