#!/usr/bin/env python3
"""Compare per-shot rows from two analysis chains, one reference against one or more runs.

    python3 compare_rows.py REF.json RUN.json [RUN2.json ...] [--window START END] [--tolerance 0.3] [--json]

Reads either format:
  * App per-shot JSON: {"events": [{"sourcePTS", "stroke", "speedKPH", ...}]}, written by
    `court-analyze` (S家 chain) and `court-analyze independent-live` (in-house lane);
  * S家 App teacher rows (exported by the S家 desktop app): [{"anchor", "speed", "stroke": "正手" ...}] or {"teacher": [...]}.
Several RUN files are merged (for a video analysed in segments).

Rows are paired one to one: each reference row, in time order, takes the nearest unused run row
within the tolerance. Stroke agreement is printed twice: over pairs where both sides named a class,
and over all pairs with a known reference class with a run abstention (unknown, groundstroke) counted
wrong, since abstaining alone can raise the first number. The reference is a software reference, not
truth; agreement with it says how close the run is, not how accurate.

Standard library only.
"""
import json
import statistics
import sys
from collections import Counter

CHINESE = {"发球": "serve", "正手": "forehand", "反手": "backhand", "截击": "volley", "高压": "overhead"}


def canonical_stroke(value):
    """Coarse class: serve, forehand, backhand, volley, overhead, feed, or unknown."""
    if not value:
        return "unknown"
    v = str(value).strip()
    if "截击" in v:
        return "volley"
    if v in CHINESE:
        return CHINESE[v]
    v = v.lower()
    return v if v in {"serve", "forehand", "backhand", "volley", "overhead", "feed"} else "unknown"


def load(path):
    data = json.load(open(path, encoding="utf-8"))
    if isinstance(data, dict) and "events" in data:
        rows = [(e["sourcePTS"], canonical_stroke(e.get("stroke")), e.get("speedKPH")) for e in data["events"]]
    else:
        items = data.get("teacher", data) if isinstance(data, dict) else data
        rows = [(t["anchor"], canonical_stroke(t.get("stroke")), t.get("speed")) for t in items]
    return [(float(t), s, float(v) if isinstance(v, (int, float)) and v > 0 else None) for t, s, v in rows]


def pair(ref, run, tolerance):
    used, pairs = set(), []
    for r in ref:
        best = None
        for j, s in enumerate(run):
            d = abs(s[0] - r[0])
            if j not in used and d <= tolerance and (best is None or d < best[0]):
                best = (d, j)
        if best:
            used.add(best[1])
            pairs.append((r, run[best[1]]))
    return pairs


def compare(ref, run, tolerance=0.3):
    pairs = pair(ref, run, tolerance)
    strokes = [(a[1], b[1]) for a, b in pairs if a[1] != "unknown" and b[1] != "unknown"]
    speeds = [(a[2], b[2]) for a, b in pairs if a[2] and b[2]]
    rel = [abs(b - a) / a for a, b in speeds]
    confusion = Counter(strokes)
    classes = sorted({c for c, _ in strokes} | {c for _, c in strokes})
    # What a run that always answered the reference's most common class would score on the same pairs.
    majority = Counter(a for a, _ in strokes).most_common(1)
    # Abstaining (unknown, groundstroke) shrinks `strokes` and can raise agreement with no gain, so also
    # score every matched pair whose reference class is known, counting a run abstention as wrong.
    ref_known = [(a[1], b[1]) for a, b in pairs if a[1] != "unknown"]
    majority_all = Counter(a for a, _ in ref_known).most_common(1)
    return {
        "reference_rows": len(ref),
        "run_rows": len(run),
        "matched": len(pairs),
        "recall_of_reference": len(pairs) / len(ref) if ref else None,
        "run_rows_unmatched": len(run) - len(pairs),
        "strokes": {
            "both_known": len(strokes),
            "agree": sum(1 for a, b in strokes if a == b),
            "agreement": sum(1 for a, b in strokes if a == b) / len(strokes) if strokes else None,
            "majority_class": majority[0][0] if majority else None,
            "majority_baseline": majority[0][1] / len(strokes) if majority else None,
            "run_unknown_on_matched": sum(1 for _, b in pairs if b[1] == "unknown"),
            "reference_known": len(ref_known),
            "agree_counting_abstain_wrong": sum(1 for a, b in ref_known if a == b) / len(ref_known) if ref_known else None,
            "majority_baseline_on_reference_known": majority_all[0][1] / len(ref_known) if majority_all else None,
            "per_class": {c: {"agree": confusion[(c, c)], "reference": sum(v for (a, _), v in confusion.items() if a == c)} for c in classes},
            "confusion": {f"{a}->{b}": n for (a, b), n in sorted(confusion.items())},
        },
        "speeds": {
            "reference_with_speed": sum(1 for r in ref if r[2]),
            "run_with_speed": sum(1 for r in run if r[2]),
            "both": len(speeds),
            "coverage_of_reference_speeds": len(speeds) / max(1, sum(1 for r in ref if r[2])),
            "mape": statistics.fmean(rel) if rel else None,
            "median_relative_error": statistics.median(rel) if rel else None,
            "within_20_percent": sum(1 for x in rel if x <= 0.2),
            "median_ratio_run_over_reference": statistics.median(b / a for a, b in speeds) if speeds else None,
        },
    }


def pct(x):
    return "—" if x is None else f"{100 * x:.1f}%"


def main(argv):
    args, window, tolerance, as_json = [], None, 0.3, False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--window":
            window = (float(argv[i + 1]), float(argv[i + 2])); i += 3; continue
        if a == "--tolerance":
            tolerance = float(argv[i + 1]); i += 2; continue
        if a == "--json":
            as_json = True; i += 1; continue
        args.append(a); i += 1
    if len(args) < 2:
        sys.exit(__doc__)
    ref = load(args[0])
    run = sorted((r for p in args[1:] for r in load(p)), key=lambda r: r[0])
    if window:
        ref = [r for r in ref if window[0] <= r[0] < window[1]]
        run = [r for r in run if window[0] <= r[0] < window[1]]
    m = compare(ref, run, tolerance)
    if as_json:
        print(json.dumps(m, ensure_ascii=False, indent=1)); return
    s, v = m["strokes"], m["speeds"]
    print(f"reference rows {m['reference_rows']} | run rows {m['run_rows']} | matched {m['matched']} "
          f"({pct(m['recall_of_reference'])} of reference) | run rows unmatched {m['run_rows_unmatched']}")
    print(f"strokes: both known {s['both_known']}, agree {s['agree']} ({pct(s['agreement'])}); "
          f"always '{s['majority_class']}' would agree {pct(s['majority_baseline'])}; run unknown on matched {s['run_unknown_on_matched']}; "
          + ", ".join(f"{c} {d['agree']}/{d['reference']}" for c, d in s["per_class"].items()))
    print(f"strokes, abstain counted wrong: {s['reference_known']} matched with a known reference class, agree "
          f"{pct(s['agree_counting_abstain_wrong'])}; always '{s['majority_class']}' on the same pairs {pct(s['majority_baseline_on_reference_known'])}")
    ratio = v["median_ratio_run_over_reference"]
    print(f"speeds: reference {v['reference_with_speed']}, run {v['run_with_speed']}, both {v['both']} "
          f"({pct(v['coverage_of_reference_speeds'])} of reference speeds); MAPE {pct(v['mape'])}, median {pct(v['median_relative_error'])}, "
          f"within 20% {v['within_20_percent']}, median ratio run/reference {'—' if ratio is None else f'{ratio:.2f}'}")


if __name__ == "__main__":
    main(sys.argv[1:])
