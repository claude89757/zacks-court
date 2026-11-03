"""Compact the native full-video report into frames.npz (per-frame state and all candidates).
usage: extract.py RUN_DIR/report.json OUT_DIR"""
import sys, json
import numpy as np

d = json.load(open(sys.argv[1]))
rows, cands = [], []
for i, f in enumerate(d["frames"]):
    assert f["presentationTime"]["timescale"] == 600
    sel = f.get("candidate")
    rows.append((i, f["presentationTime"]["value"], {"warmup": 0, "missing": 1, "tracked": 2}.get(f["state"], 3),
                 sel["originalXY"][0] if sel else -1, sel["originalXY"][1] if sel else -1, sel["peak"] if sel else 0))
    for c in (f.get("candidateBank") or {}).get("candidates", []):
        cands.append((i, c["originalXY"][0], c["originalXY"][1], c["peak"], c["mean"], c["pixelArea"],
                      1 if sel and c["identifier"] == sel["identifier"] else 0))
np.savez_compressed(f"{sys.argv[2]}/frames.npz", frames=np.array(rows, float), cands=np.array(cands, float))
print(len(rows), "frames", len(cands), "candidates")
