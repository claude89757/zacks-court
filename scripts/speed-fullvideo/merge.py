"""Merge per-camera-segment shot files and re-match against the S家 rows.
usage: merge.py OUT.json SEG0/shots.json [SEG1/shots.json ...]"""
import sys, json
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from shots import match

shots, teacher = [], None
for k, p in enumerate(sys.argv[2:]):
    d = json.load(open(p))
    teacher = teacher or d["teacher"]
    for s in d["shots"]:
        s["segment"] = k
        shots.append(s)
shots.sort(key=lambda s: s["t_hit"])
m = match(shots, teacher)
json.dump(dict(shots=shots, teacher=teacher, match={str(k): v for k, v in m.items()}), open(sys.argv[1], "w"), indent=1, default=float)
print("shots", len(shots), "accepted", sum(1 for s in shots if s.get("accepted")), "matched rows", len(m))
