"""Stage 1: smooth pieces, junctions between consecutive pieces, bounce test at each junction."""
import sys, json, pickle
from multiprocessing import Pool
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from flight import Camera, best_anchored, best_fit, BALL_R
from segment2d import split_track, kink

import os
CAM = os.environ["COURT_SPEED_CAMERA"]
# events v2 (tuned on test.MOV, checked on double-test-003): link across gaps up to 24 frames, store whether the two pieces at a junction fit one free flight
# (then the junction is not a hit), and give failed bounce tests a second, shorter-window chance.
V2 = os.environ.get("COURT_EVENTS_V2") == "1"
def pieces_of(tracks):
    out = []
    for P in tracks:
        for a, b in split_track(P):
            Q = P[a:b]
            if len(Q) >= 4:
                out.append(Q)
    out.sort(key=lambda Q: Q[0, 0])
    return out


def link_pieces(pcs, max_gap=15, max_miss=25.0, long_gap=None):
    """Best successor for each piece (one-to-one, smallest kink miss)."""
    starts = np.array([Q[0, 0] for Q in pcs])
    cand = []
    for i, A in enumerate(pcs):
        e = A[-1, 0]
        for j in np.where((starts > e - 3) & (starts <= e + (long_gap or max_gap)))[0]:
            if j == i:
                continue
            B = pcs[j]
            if B[-1, 0] <= e:
                continue
            t, uv, miss = kink(A, B)
            if miss < max_miss and A[-1, 0] - 4 <= t * 60 <= B[0, 0] + 4:
                cand.append((miss, i, int(j), t, uv.tolist()))
    cand.sort()
    used_a, used_b, links = set(), set(), []
    for miss, i, j, t, uv in cand:
        if i in used_a or j in used_b:
            continue
        used_a.add(i); used_b.add(j)
        links.append(dict(a=i, b=j, t=t, uv=uv, miss=miss))
    return links


def bounce_test(args):
    res = _bounce_core(args)
    if V2 and not res.get("bounce"):
        # one free flight through both pieces -> not an event (a tracking kink or a person nearby)
        A, B = args[0], args[1]
        Q = np.vstack([A[-20:], B[:15]])
        bf = best_fit(Camera(CAM), Q[:, 0], Q[:, 1:3]) if len(Q) >= 8 else None
        res["continuous_rms"] = None if bf is None else float(bf[2])
    return res


def _bounce_core(args):
    A, B, t, uv = args
    cam = Camera(CAM)
    Pg = cam.on_plane_z(np.array([uv]), BALL_R)[0]
    res = dict(ground=Pg.tolist())
    if not (-8 < Pg[1] < 32 and abs(Pg[0]) < 9):
        res["reason"] = "ground point outside court area"
        return res
    A = A[-25:]; B = B[:15]
    if len(A) < 4 or len(B) < 4:
        res["reason"] = "too few points"
        return res
    xa, ea, ra = best_anchored(cam, A[:, 0], A[:, 1:3], Pg, t * 60, True)
    xb, eb, rb = best_anchored(cam, B[:, 0], B[:, 1:3], Pg, t * 60, False)
    res.update(rms_before=ra, rms_after=rb, v_before=xa.tolist(), v_after=xb.tolist())
    res["bounce"] = bool(ra <= 4 and rb <= 4 and xa[2] < 0 < xb[2])
    if V2 and not res["bounce"] and len(B) >= 6:
        A2 = A[-15:]; B2 = B[:8]
        xa2, ea2, ra2 = best_anchored(cam, A2[:, 0], A2[:, 1:3], Pg, t * 60, True)
        xb2, eb2, rb2 = best_anchored(cam, B2[:, 0], B2[:, 1:3], Pg, t * 60, False)
        res.update(rms_before2=ra2, rms_after2=rb2)
        if ra2 <= 5.5 and rb2 <= 5.5 and xa2[2] < -1.0 and xb2[2] > 0.5:
            res["bounce"] = True; res["bounce_second_chance"] = True
    return res


if __name__ == "__main__":
    tracks = pickle.load(open(sys.argv[1], "rb"))
    pcs = pieces_of(tracks)
    links = link_pieces(pcs, long_gap=24 if V2 else None)
    print("pieces", len(pcs), "junctions", len(links), flush=True)
    jobs = [(pcs[L["a"]], pcs[L["b"]], L["t"], L["uv"]) for L in links]
    with Pool(8) as pool:
        tests = pool.map(bounce_test, jobs, chunksize=4)
    for L, r in zip(links, tests):
        L.update(r)
    pickle.dump(dict(pieces=pcs, links=links), open(sys.argv[2], "wb"))
    print("bounces", sum(1 for L in links if L.get("bounce")), flush=True)
