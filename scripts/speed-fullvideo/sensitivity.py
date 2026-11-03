"""Summarise the perturbed-camera reruns. usage: sensitivity.py BASE_metrics.json SENS_DIR"""
import sys, json, glob
import numpy as np

base = json.load(open(sys.argv[1]))
runs = [json.load(open(p)) for p in sorted(glob.glob(f"{sys.argv[2]}/cam*/metrics.json"))]
print("camera  with_speed  MAPE   median  within20")
for k, r in enumerate(runs):
    m = r["metrics"]; p = m["primary"]
    print(f"cam{k}   {m['with_speed']:3d}        {100*p['mape']:5.1f}%  {100*p['median_rel']:5.1f}%  {p['within20']}")
# per-row spread for rows that have a speed in the base run
spread = []
for row in base["rows"]:
    if row["status"] != "speed":
        continue
    vals = [r["rows"][row["i"] - 1].get("pred") for r in runs]
    vals = [v for v in vals if v is not None]
    if len(vals) >= 5:
        spread.append((row["i"], row["pred"], min(vals), max(vals), (max(vals) - min(vals)) / row["pred"], len(vals)))
s = np.array([x[4] for x in spread])
print(f"rows with speed in base and >=5 perturbed runs: {len(spread)}; relative range median {100*np.median(s):.1f}%, P90 {100*np.quantile(s,.9):.1f}%, max {100*s.max():.1f}%")
json.dump(dict(per_camera=[r["metrics"] for r in runs], per_row=spread), open(f"{sys.argv[2]}/summary.json", "w"), indent=1, default=float)
