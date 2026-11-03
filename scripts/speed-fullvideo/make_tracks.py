"""Link candidates into 2D tracks. usage: make_tracks.py WORK/frames.npz OUT/tracks.pkl [T0 T1]

Linking runs on decode order; afterwards each point's time column becomes the frame's real
presentation time in 1/60 s units (PTS/10 at timescale 600), so variable frame rate is exact.
Optional T0 T1 (seconds) keep only candidates in that presentation-time range."""
import sys, pickle
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from tracks import link
z = np.load(sys.argv[1]); C = z["cands"]; pts = z["frames"][:, 1]
if len(sys.argv) > 4:
    t = pts[C[:, 0].astype(int)] / 600.0
    C = C[(t >= float(sys.argv[3])) & (t < float(sys.argv[4]))]
T = link(C)
for P in T:
    P[:, 0] = pts[P[:, 0].astype(int)] / 10.0
pickle.dump(T, open(sys.argv[2], "wb"))
print(len(T), "tracks")
