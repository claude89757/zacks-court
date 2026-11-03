"""Per-row table and metrics against the 127 S家 rows. usage: report.py shots.json OUT.md OUT_metrics.json"""
import os, sys, json
import numpy as np

# COURT_SPEED_REQUIRE_BOUNCE=1: a speed is only given when the flight was anchored at a detected bounce
REQUIRE_BOUNCE = os.environ.get("COURT_SPEED_REQUIRE_BOUNCE") == "1"

d = json.load(open(sys.argv[1]))
shots, teacher, m = d["shots"], d["teacher"], {int(k): v for k, v in d["match"].items()}
rows, errs, errs_inst = [], [], []
reasons = {}
for j, t in enumerate(teacher):
    s = shots[m[j]] if j in m else None
    r = dict(i=j + 1, anchor=t["anchor"], stroke=t["stroke"], type=t["type"], result=t["result"], ref=t["speed"],
             side="far" if t["hit"]["y"] > 11.885 else "near")
    if s is None:
        r["status"] = "missed"; reasons["no detected hit within 0.6 s"] = reasons.get("no detected hit within 0.6 s", 0) + 1
    else:
        r["dt"] = s["t_hit"] - t["anchor"]; r["hit_kind"] = s["hit_kind"]
        r["stroke_pred"] = s.get("stroke")
        if s.get("accepted") and REQUIRE_BOUNCE and not s["bounce_found"]:
            r["status"] = "no speed"; r["reason"] = "no bounce anchor (gate)"
            r["ungated_pred"] = s["speed_kmh"]
            reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
        elif s.get("accepted"):
            r["status"] = "speed"; r["pred"] = s["speed_kmh"]; r["inst"] = s.get("v_inst_kmh")
            r["rel"] = abs(s["speed_kmh"] - t["speed"]) / t["speed"]; r["end"] = s["end_kind"]
            r["rel_inst"] = abs(s["v_inst_kmh"] - t["speed"]) / t["speed"]
            errs.append((s["speed_kmh"], t["speed"])); errs_inst.append((s["v_inst_kmh"], t["speed"]))
            r["fit_hit"] = s["fit_hit"]; r["teacher_hit"] = t["hit"]
            r["bounce_ground"] = s.get("bounce_ground"); r["teacher_bounce"] = t["bounce"]
            r["interval"] = s["interval_s"]; r["rms"] = s["rms_px"]; r["anchors"] = ("B" if s["bounce_found"] else "") + ("H" if s["hitter_found"] else "")
        else:
            r["status"] = "no speed"; r["reason"] = s.get("reason", "?")
            reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
    rows.append(r)


def stats(pairs):
    if not pairs:
        return {}
    p = np.array(pairs); ae = np.abs(p[:, 0] - p[:, 1]); re = ae / p[:, 1]
    return dict(n=len(p), mae_kmh=float(ae.mean()), mape=float(re.mean()), median_rel=float(np.median(re)),
                p90_rel=float(np.quantile(re, .9)), p95_rel=float(np.quantile(re, .95)), max_rel=float(re.max()),
                within20=int((re <= 0.2).sum()), bias_kmh=float((p[:, 0] - p[:, 1]).mean()))


matched_ids = set(m.values())
# stroke agreement on matched rows
st = [(r["stroke"], r.get("stroke_pred")) for r in rows if r["status"] != "missed"]
classes = sorted({a for a, _ in st})
conf = {a: {} for a in classes}
for a, b in st:
    conf[a][b or "—"] = conf[a].get(b or "—", 0) + 1
coarse = lambda x: None if x is None else ("发球" if x == "发球" else ("正手" if x.startswith("正手") else "反手"))
stroke_metrics = dict(matched_rows=len(st), with_stroke=sum(1 for _, b in st if b),
                      exact=sum(1 for a, b in st if b == a), coarse=sum(1 for a, b in st if b and coarse(a) == coarse(b)),
                      exact_of_all_rows=sum(1 for a, b in st if b == a) / len(teacher), confusion=conf)
ungated = [(r["ungated_pred"], r["ref"]) for r in rows if "ungated_pred" in r] + [(r["pred"], r["ref"]) for r in rows if r["status"] == "speed"]
extra = [s for i, s in enumerate(shots) if i not in matched_ids and s.get("accepted")]
M = dict(rows=len(teacher), detected_hits=len(shots), matched=len(m), with_speed=len(errs),
         coverage=len(errs) / len(teacher), primary=stats(errs), secondary_instantaneous=stats(errs_inst),
         unmatched_accepted_detections=len(extra), no_speed_reasons=reasons, strokes=stroke_metrics,
         ungated_all_accepted=stats(ungated))
for side in ("near", "far"):
    M[f"primary_{side}_hitter"] = stats([(r["pred"], r["ref"]) for r in rows if r["status"] == "speed" and r["side"] == side])
for kind in ("发球",):
    M["primary_serves"] = stats([(r["pred"], r["ref"]) for r in rows if r["status"] == "speed" and r["stroke"] == kind])
M["primary_non_serves"] = stats([(r["pred"], r["ref"]) for r in rows if r["status"] == "speed" and r["stroke"] != "发球"])
json.dump(dict(metrics=M, rows=rows), open(sys.argv[3], "w"), indent=1, ensure_ascii=False, default=float)

L = ["| # | 时刻 s | S家动作 | 自研动作 | 击球方 | S家 km/h | 自研 km/h | 相对误差 | 说明 |", "|---:|---:|---|---|---|---:|---:|---:|---|"]
for r in rows:
    if r["status"] == "speed":
        L.append(f"| {r['i']} | {r['anchor']:.2f} | {r['stroke']} | {r.get('stroke_pred') or '—'} | {'远端' if r['side']=='far' else '近端'} | {r['ref']:.1f} | {r['pred']:.1f} | {100*r['rel']:.0f}% | 锚点 {r['anchors']}，终点 {'过网' if r['end']=='net' else '落地'} |")
    elif r["status"] == "no speed":
        L.append(f"| {r['i']} | {r['anchor']:.2f} | {r['stroke']} | {r.get('stroke_pred') or '—'} | {'远端' if r['side']=='far' else '近端'} | {r['ref']:.1f} | — | — | {r['reason']} |")
    else:
        L.append(f"| {r['i']} | {r['anchor']:.2f} | {r['stroke']} | — | {'远端' if r['side']=='far' else '近端'} | {r['ref']:.1f} | — | — | 未检测到击球 |")
open(sys.argv[2], "w").write("\n".join(L) + "\n")
print(json.dumps(M, indent=1, ensure_ascii=False, default=float))
