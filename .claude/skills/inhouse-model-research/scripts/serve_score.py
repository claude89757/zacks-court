#!/usr/bin/env python3
"""Serve scoring: one in-house run (App row JSON, live or replay) against S家 rows or S家 App teacher rows.

    python3 serve_score.py REF.json RUN.json [--tol 1.0] [--diag OUT.tsv] [--window START END]

Serve precision P = run serve rows paired with a reference serve / run serve rows; recall R = reference
serves paired with a run serve row; F1. Pairing is one-to-one by nearest time within --tol (rows of any type).
ss_P/ss_R/ss_F1 (2026-11-03): serve calls paired only with reference serves (the recognition score of the
align-r3 protocol); ss_speed_share: reference serves with a speed that got a paired run serve speed.
cov / spread / ratio_med: reference serves with a speed whose paired run row has a speed; spread is the median
|log r - median log r| (scale-free). ss_*: the same, pairing reference serves only with run serve rows.
--diag writes one line per reference serve (and per false serve call) with the run row's shot fields.
Standard library only. Serve timestamps differ by up to ~0.7 s between chains (far serves), so the
2026-11-02 serve round used --tol 1.0 as the primary window and also reported 0.3.
"""
import json, math, statistics, sys

def canon(s):
    if not s: return "unknown"
    s = str(s)
    if s in ("serve", "发球"): return "serve"
    return s

def load(p):
    d = json.load(open(p))
    if "teacher" in d:   # S家 App rows
        return [dict(t=float(x["anchor"]), s=canon(x.get("stroke")), v=x.get("speed") if (x.get("speed") or 0) > 0 else None, shot=None, reason=None)
                for x in d["teacher"]]
    ev = d["events"]
    shots = d.get("shots")
    rows = []
    for i, e in enumerate(ev):
        sp = e.get("speedKPH")
        rows.append(dict(t=float(e["sourcePTS"]), s=canon(e.get("stroke")), v=sp if isinstance(sp, (int, float)) and sp > 0 else None,
                         shot=shots[i] if shots and i < len(shots) else None, reason=e.get("speedReason")))
    return rows

def pair(ref, run, tol):
    used, out = set(), {}
    for i, r in enumerate(ref):
        best = None
        for j, s in enumerate(run):
            d = abs(s["t"] - r["t"])
            if j not in used and d <= tol and (best is None or d < best[0]): best = (d, j)
        if best: used.add(best[1]); out[i] = best[1]
    return out

def main():
    a = sys.argv[1:]
    tol = 1.0; diag = None; win = None
    if "--tol" in a: k = a.index("--tol"); tol = float(a[k+1]); del a[k:k+2]
    if "--diag" in a: k = a.index("--diag"); diag = a[k+1]; del a[k:k+2]
    if "--window" in a: k = a.index("--window"); win = (float(a[k+1]), float(a[k+2])); del a[k:k+3]
    ref, run = load(a[0]), load(a[1])
    if win:
        ref = [r for r in ref if win[0] <= r["t"] < win[1]]; run = [r for r in run if win[0] <= r["t"] < win[1]]
    P = pair(ref, run, tol)
    inv = {j: i for i, j in P.items()}
    rs = [i for i, r in enumerate(ref) if r["s"] == "serve"]
    det = [i for i in rs if i in P]
    called = [i for i in det if run[P[i]]["s"] == "serve"]
    runserve = [j for j, r in enumerate(run) if r["s"] == "serve"]
    tp = [j for j in runserve if j in inv and ref[inv[j]]["s"] == "serve"]
    onrow = [j for j in runserve if j in inv]
    rsv = [i for i in rs if ref[i]["v"]]
    cov = [i for i in rsv if i in P and run[P[i]]["v"]]
    ratios = [run[P[i]]["v"] / ref[i]["v"] for i in cov]
    errs = [abs(x - 1) for x in ratios]
    runserve_v = [run[j]["v"] for j in runserve if run[j]["v"]]
    P_ = len(tp) / len(runserve) if runserve else 0; R_ = len(called) / len(rs) if rs else 0
    F1 = 2 * P_ * R_ / (P_ + R_) if P_ + R_ else 0
    lr = [math.log(x) for x in ratios]
    spread = round(statistics.median([abs(x - statistics.median(lr)) for x in lr]), 3) if lr else None
    out = dict(P=round(P_, 2), R=round(R_, 2), F1=round(F1, 2), cov=f"{len(cov)}/{len(rsv)}", spread=spread,
               ref_serves=len(rs), detected=len(det), called_serve=len(called),
               run_serve_rows=len(runserve), run_serve_on_ref_row=len(onrow), run_serve_true=len(tp),
               ref_serve_speeds=len(rsv), speed_cov=len(cov),
               ratio_med=round(statistics.median(ratios), 3) if ratios else None,
               mape=round(100 * statistics.mean(errs), 1) if errs else None,
               within10=sum(e <= 0.10 for e in errs), within20=sum(e <= 0.20 for e in errs),
               run_serve_speeds=len(runserve_v), run_serve_speed_med=round(statistics.median(runserve_v), 1) if runserve_v else None,
               ref_serve_speed_med=round(statistics.median([ref[i]["v"] for i in rsv]), 1) if rsv else None)
    # serve-to-serve pairs: the reference serve and the in-house serve call
    rsr = [r for r in ref if r["s"] == "serve"]; usr = [r for r in run if r["s"] == "serve"]
    SP = pair(rsr, usr, tol)
    sv = [(rsr[i]["v"], usr[j]["v"]) for i, j in SP.items() if rsr[i]["v"]]
    both = [(a, b) for a, b in sv if b]
    rr = [b / a for a, b in both]
    lr2 = [math.log(x) for x in rr]
    out["ss_pairs"] = len(SP); out["ss_cov"] = f"{len(both)}/{sum(1 for r in rsr if r['v'])}"
    # serve-to-serve recognition: a reference serve and a run serve call within --tol, one-to-one, ignoring
    # rows of other types (rows near a serve cannot steal the pairing as they can in P/R/F1 above)
    sP = len(SP) / len(usr) if usr else 0; sR = len(SP) / len(rsr) if rsr else 0
    out["ss_P"] = round(sP, 2); out["ss_R"] = round(sR, 2); out["ss_F1"] = round(2 * sP * sR / (sP + sR), 2) if sP + sR else 0
    # speed coverage over reference serves with a speed: a paired run serve call with a speed
    out["ss_speed_share"] = round(len(both) / sum(1 for r in rsr if r['v']), 2) if any(r['v'] for r in rsr) else None
    out["ss_w20"] = sum(abs(x - 1) <= 0.20 for x in rr) if rr else 0
    out["ss_ratio"] = round(statistics.median(rr), 3) if rr else None
    out["ss_spread"] = round(statistics.median([abs(x - statistics.median(lr2)) for x in lr2]), 3) if lr2 else None
    out["ss_w15"] = sum(abs(math.log(x) - statistics.median(lr2)) <= math.log(1.15) for x in rr) if rr else 0
    out["ss_mape"] = round(100 * statistics.mean([abs(x - 1) for x in rr]), 1) if rr else None
    print(json.dumps(out))
    if diag:
        with open(diag, "w") as f:
            f.write("t\tref\tref_v\trun_t\trun_stroke\trun_v\thitKind\tside\tbounce\tnObs\treason\tstrokeReason\tfitHitZ\n")
            for i in rs:
                r = ref[i]
                if i in P:
                    x = run[P[i]]; s = x["shot"] or {}
                    fh = s.get("fitHit")
                    f.write(f"{r['t']:.2f}\tserve\t{r['v'] or ''}\t{x['t']:.2f}\t{x['s']}\t{x['v'] or ''}\t{s.get('hitKind')}\t{s.get('hitterSide')}\t{s.get('bounceFound')}\t{s.get('nObs')}\t{s.get('reason')}\t{s.get('strokeReason')}\t{fh[2] if fh else ''}\n")
                else:
                    f.write(f"{r['t']:.2f}\tserve\t{r['v'] or ''}\t\tMISSED\n")
            for j in runserve:
                if j in inv and ref[inv[j]]["s"] == "serve": continue
                x = run[j]; s = x["shot"] or {}
                f.write(f"\tFP:{ref[inv[j]]['s'] if j in inv else 'none'}\t\t{x['t']:.2f}\tserve\t{x['v'] or ''}\t{s.get('hitKind')}\t{s.get('hitterSide')}\t{s.get('bounceFound')}\t{s.get('nObs')}\t{s.get('reason')}\t\t\n")

main()
