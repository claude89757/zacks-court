"""Frames (1/60 s units of real time) where person boxes are needed: around every junction and piece start.
usage: people_frames.py OUT.txt JUNCTIONS.pkl [JUNCTIONS.pkl ...]"""
import sys, pickle
fr = set()
for p in sys.argv[2:]:
    J = pickle.load(open(p, "rb")); pcs, L = J["pieces"], J["links"]
    has_pred = {l["b"] for l in L}
    for l in L:
        k = int(round(l["t"] * 60)); fr.update([k - 2, k])
    for i, Q in enumerate(pcs):
        if i not in has_pred:
            k = int(round(Q[0, 0])); fr.update([k - 12, k - 6, k - 3, k])
fr = sorted(f for f in fr if f >= 0)
open(sys.argv[1], "w").write("\n".join(map(str, fr)) + "\n")
print(len(fr), "frames")
