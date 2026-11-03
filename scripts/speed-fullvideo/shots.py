"""Stage 3: assemble shot flights from pieces/junctions, fit 3D, compute S家-like speed, match.

usage: shots.py junctions.pkl people.json camera.json teacher.jsonl OUT_DIR
"""
import os, sys, json, pickle
from multiprocessing import Pool
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from segment2d import local_poly
from flight import Camera, simulate, rk4_step, best_anchored, anchored_states, initial_guesses, G, BALL_R, FPS

NET_Y = 11.885
HIT_SIGMA = float(os.environ.get("COURT_SPEED_HIT_SIGMA", "0.8"))  # hitter-depth prior (m); v1 = 0.8
# v2 (tuned on test.MOV after its v1 result): first-observation hits get a "reach the hitter's depth"
# prior instead of a time-pinned one, and gross outliers (> 15 px) are dropped before a final refit.
V2 = os.environ.get("COURT_SPEED_V2") == "1"
REACH = 24  # frames (0.4 s) searched backwards from the first observation
# v3 (tuned on test.MOV after v1/v2): when the anchored fit misses (RMS > 4 px), refit with the bounce
# anchor alone, then trim up to 35% of the earliest points (toss or a missed event mixed in).
V3 = os.environ.get("COURT_SPEED_V3") == "1"
V3_TRIM = os.environ.get("COURT_SPEED_V3_TRIM", "1") == "1"  # v3b sets 0: trimming made errors worse
# v4: the hitter must stand on the side opposite the flight's bounce; without a bounce only the strict
# "ball next to the box" match is used (the loose nearest-box fallback picked the near player for far hits).
V4 = os.environ.get("COURT_SPEED_V4") == "1"
# v5 (tuned on test.MOV after v4): the hitter's side comes from the nearest person box (within 1.5 box
# heights of the contact pixel, +-6 frames), else from the ball's image direction over the whole flight
# (moving down the image = towards the camera = far hitter). The bounce side was wrong on 13 of 50 matched
# rows (pre-serve ball bounces, far-court junctions), so it no longer picks the side.
V5 = os.environ.get("COURT_SPEED_V5") == "1"
# reach prior for every hit kind, not only chain starts (junctions can also come late after occlusion)
REACH_ALL = os.environ.get("COURT_SPEED_REACH_ALL") == "1"
# events v2 (junctions.py COURT_EVENTS_V2=1): a non-bounce junction where the ball's image direction
# turns less than TURN_MIN degrees is a continuation, even with a person box nearby
EVENTS_V2 = os.environ.get("COURT_EVENTS_V2") == "1"
SECOND_BOUNCE = os.environ.get("COURT_EVENTS_SECOND_BOUNCE") == "1"  # honour second-chance bounces
TURN_MIN = float(os.environ.get("COURT_EVENTS_TURN_MIN", "50"))  # degrees
REVERSAL_HITS = os.environ.get("COURT_EVENTS_REVERSAL_HITS") == "1"
CAM_PATH = None
CROP_BOTTOMS = (720, 660)


# ---------- people ----------
def clean_boxes(boxes):
    keep = []
    for b in boxes:
        x0, y0, x1, y1, conf, src = b[:6]
        bottoms = (b[6],) if len(b) > 6 else CROP_BOTTOMS
        if src == 1 and any(abs(y1 - cb) < 3 for cb in bottoms):
            continue  # cut by a crop edge: feet unknown
        keep.append(b)
    keep.sort(key=lambda b: -b[4])
    out = []
    for b in keep:
        iou = 0
        for o in out:
            ix = max(0, min(b[2], o[2]) - max(b[0], o[0])); iy = max(0, min(b[3], o[3]) - max(b[1], o[1]))
            inter = ix * iy; uni = (b[2] - b[0]) * (b[3] - b[1]) + (o[2] - o[0]) * (o[3] - o[1]) - inter
            iou = max(iou, inter / max(uni, 1))
        if iou < 0.4:
            out.append(b)
    return out


def person_near(boxes, uv):
    best = None
    for b in boxes:
        x0, y0, x1, y1 = b[:4]; w, h = x1 - x0, y1 - y0
        if x0 - w <= uv[0] <= x1 + w and y0 - 0.3 * h <= uv[1] <= y1:
            d = np.hypot(uv[0] - (x0 + x1) / 2, uv[1] - (y0 + y1) / 2) / h
            if best is None or d < best[0]:
                best = (d, b)
    return None if best is None else best[1]


_KEYS = {}


def people_at(people, frame, reach=6):
    """Boxes from the nearest frame with person detections within +-reach frames (1/60 s units)."""
    keys = _KEYS.get(id(people))
    if keys is None:
        keys = np.array(sorted(int(k) for k in people)); _KEYS[id(people)] = keys
    if len(keys) == 0:
        return []
    i = int(np.searchsorted(keys, frame))
    best = None
    for j in (i - 1, i):
        if 0 <= j < len(keys) and abs(keys[j] - frame) <= reach and (best is None or abs(keys[j] - frame) < abs(best - frame)):
            best = int(keys[j])
    return [] if best is None else clean_boxes(people[str(best)])


def person_nearest(boxes, uv, max_heights=2.5):
    """Looser fallback: the box whose centre is nearest the pixel, within max_heights box heights."""
    best = None
    for b in boxes:
        h = b[3] - b[1]
        d = np.hypot(uv[0] - (b[0] + b[2]) / 2, uv[1] - (b[1] + b[3]) / 2) / h
        if d <= max_heights and (best is None or d < best[0]):
            best = (d, b)
    return None if best is None else best[1]


def is_toss(piece):
    """A serve toss: >= 0.25 s, mostly vertical image motion, rising then falling inside the piece."""
    if piece is None or len(piece) < 6:
        return False
    P = np.asarray(piece, float)
    if (P[-1, 0] - P[0, 0]) / 60.0 < 0.25:
        return False
    du = abs(P[-1, 1] - P[0, 1]); vr = P[:, 2].max() - P[:, 2].min()
    i = int(np.argmin(P[:, 2]))
    return vr > 20 and du <= 0.35 * vr and 1 <= i <= len(P) - 2


# ---------- fitting ----------
def state_at(state0, F0, t_frames, k=None):
    """State at fractional frame time t from a state at integer frame F0."""
    fl = int(np.floor(t_frames))
    S = simulate(np.atleast_2d(state0), [fl - F0])[:, 0]
    d = (t_frames - fl) / FPS
    return rk4_step(S, d) if d > 1e-9 else S


def reach_time(x, F0, hit):
    """Frame time at which the flight, extrapolated back from the first observation, is at the hitter's
    depth (y = prior), and the height there. None if not reached within REACH frames."""
    t0 = hit[0]; grid = t0 - np.arange(REACH + 1)
    S = simulate(np.atleast_2d(x), grid - F0)[0]
    if not np.all(np.isfinite(S)):
        return None, 1e3
    d = S[:, 1] - hit[1]
    k = np.where(np.sign(d) != np.sign(d[0]))[0]
    if d[0] == 0:
        return t0, S[0, 2]
    if not len(k):
        return None, S[-1, 1]
    k = k[0]; den = d[k - 1] - d[k]
    f = d[k - 1] / den if den != 0 else 0.0
    return grid[k - 1] - f, S[k - 1, 2] + f * (S[k, 2] - S[k - 1, 2])


def reach_residual(x, F0, hit):
    t, v = reach_time(x, F0, hit)
    if t is None:
        return 2.0 * (v - hit[1]) / hit[2]          # pull the farthest extrapolated point toward the depth
    return 2.0 * max(0.0, 0.2 - v, v - 3.5) / 0.3   # plausible contact height


def fit_shot(cam, frames, uv, F0, x0, hit=None, bounce=None, iters=40, huber=4.0):
    """6 unknowns (state at F0). hit=(t_frames, y_prior, sigma); bounce=(t_frames, P)."""
    frames = np.asarray(frames, float); rel = frames - F0

    def raw(X):
        S = simulate(X, rel)
        p, depth = cam.project(S[..., :3])
        r = (p - uv[None]).reshape(len(X), -1)
        r[(depth <= 0.5).any(axis=1)] = 1e3
        extra = []
        if hit is not None and len(hit) > 3 and hit[3] == "reach":
            extra.append(np.array([reach_residual(x, F0, hit) for x in X]))
        elif hit is not None:
            Sh = np.vstack([state_at(x, F0, hit[0]) for x in X])
            extra.append(2.0 * (Sh[:, 1] - hit[1]) / hit[2])
        if bounce is not None:
            Sb = np.vstack([state_at(x, F0, bounce[0]) for x in X])
            Pb = bounce[1]
            extra += [2.0 * (Sb[:, 0] - Pb[0]) / 0.1, 2.0 * (Sb[:, 1] - Pb[1]) / 0.1, 2.0 * (Sb[:, 2] - BALL_R) / 0.03]
        if extra:
            r = np.c_[r, np.stack(extra, 1)]
        return r

    n = len(frames)

    def weights(r):
        e = np.linalg.norm(r[:2 * n].reshape(n, 2), axis=1)
        w = np.where(e < huber, 1.0, np.sqrt(huber / np.maximum(e, 1e-9)))
        return np.r_[np.repeat(w, 2), np.ones(len(r) - 2 * n)]

    x = np.array(x0, float); lam = 1e-2
    r = raw(x[None])[0]; w = weights(r); cost = ((w * r) ** 2).sum()
    h = np.array([1e-4, 1e-4, 1e-4, 1e-3, 1e-3, 1e-3])
    for _ in range(iters):
        R = raw(np.vstack([x] + [x + np.eye(6)[j] * h[j] for j in range(6)]))
        J = ((R[1:] - R[0]) / h[:, None]).T * w[:, None]
        A = J.T @ J; g = J.T @ (r * w)
        improved = False
        for _ in range(8):
            dx = -np.linalg.solve(A + lam * (np.diag(np.diag(A)) + 1e-9 * np.eye(6)), g)
            rn = raw((x + dx)[None])[0]; cn = ((w * rn) ** 2).sum()
            if cn < cost:
                x = x + dx; r = rn; lam = max(lam / 4, 1e-7); improved = True
                w = weights(r); cost = ((w * r) ** 2).sum(); break
            lam *= 5
        if not improved or np.max(np.abs(dx) / np.r_[1, 1, 1, 10, 10, 10]) < 1e-5:
            break
    e = np.linalg.norm(r[:2 * n].reshape(n, 2), axis=1)
    return x, e, float(np.sqrt(np.mean(np.minimum(e, 3 * huber) ** 2)))


def analyse(job):
    cam = Camera(job["cam"])
    pts, t_hit, hitter, bounce, meta = job["pts"], job["t_hit"], job["hitter"], job["bounce"], job["meta"]
    frames = pts[:, 0].astype(float); uv = pts[:, 1:3]
    res = dict(meta, t_hit=t_hit / FPS, n_obs=len(pts), first_frame=int(frames[0]), last_frame=int(frames[-1]))
    if len(pts) < 8:
        res["reason"] = "fewer than 8 ball observations between hit and bounce"; return res
    hit = None
    if hitter is not None:
        feet = cam.on_plane_z(np.array([[(hitter[0] + hitter[2]) / 2, hitter[3]]]), 0.0)[0]
        toward = 1.0 if feet[1] < NET_Y else -1.0
        hit = (t_hit, feet[1] + 0.5 * toward, HIT_SIGMA)
        if V2 and (REACH_ALL or meta["hit_kind"] == "first observation"):
            hit = (t_hit, feet[1] + 0.5 * toward, HIT_SIGMA, "reach")
        res["hitter_feet"] = feet.tolist()
    bnc = None
    if bounce is not None:
        bnc = (bounce["t"] * FPS, np.array(bounce["ground"]))
        res["bounce_ground"] = bounce["ground"]; res["t_bounce"] = bounce["t"]
    if hit is None and bnc is None:
        res["reason"] = "no depth anchor (no bounce and no hitter found)"; return res
    F0 = int(round(t_hit))
    # initial state
    inits = []
    if bnc is not None:
        m = frames < bnc[0]
        if m.sum() >= 4:
            xb, eb, rb = best_anchored(cam, frames[m], uv[m], bnc[1], bnc[0], True)
            Fb, Sb = anchored_states(bnc[1], bnc[0], xb[None])
            inits.append(simulate(Sb, [F0 - Fb])[0, 0])
    if hit is not None:
        tw = 1.0 if hit[1] < NET_Y else -1.0
        ys0 = (hit[1] - 1, hit[1], hit[1] + 1) + ((hit[1] + 2 * tw, hit[1] + 4 * tw) if len(hit) > 3 else ())
        for g0 in initial_guesses(cam, frames - frames[0], uv, ys0=ys0):
            st = simulate(g0[None], [F0 - frames[0]])[0, 0]
            inits.append(st)
    if not inits:
        res["reason"] = "no initial flight hypothesis"; return res
    best = None
    for x0 in inits[:12]:
        x, e, rms = fit_shot(cam, frames, uv, F0, x0, hit, bnc, iters=8)
        if best is None or rms + 0.0 < best[2]:
            best = (x, e, rms)
    x, e, rms = fit_shot(cam, frames, uv, F0, best[0], hit, bnc, iters=60)
    if V2 and e.max() > 15 and (e <= 15).sum() >= 8:
        keep = e <= 15
        res["dropped_outliers"] = int((~keep).sum())
        x, e2, rms = fit_shot(cam, frames[keep], uv[keep], F0, x, hit, bnc, iters=60)
        e = e2
    if V3 and rms > 4:
        tries = []
        if bnc is not None and hit is not None:
            tries.append(("bounce only", 0, None))
        n0 = len(frames)
        for cut in (range(3, int(0.35 * n0) + 1, 3) if V3_TRIM else ()):
            if n0 - cut >= 8:
                tries.append(("trimmed start", cut, None if bnc is not None else hit))
        for label, cut, h in tries:
            fr2, uv2 = frames[cut:], uv[cut:]
            F2 = int(round(fr2[0])) if cut else F0
            x0 = simulate(x[None], [F2 - F0])[0, 0] if F2 != F0 else x
            x2, e2, r2 = fit_shot(cam, fr2, uv2, F2, x0, h, bnc, iters=60)
            if r2 <= 4:
                x, e, rms, F0 = x2, e2, r2, F2
                res["fallback"] = label; res["trimmed"] = cut
                if cut:
                    t_hit = float(fr2[0]); res["t_hit"] = t_hit / FPS; res["n_obs"] = len(fr2)
                hit = h
                break
    res["rms_px"] = rms; res["max_px"] = float(e.max())
    if hit is not None and len(hit) > 3:
        tr, _ = reach_time(x, F0, hit)
        if tr is not None and np.isfinite(tr):
            t_hit = tr; res["t_hit"] = t_hit / FPS; res["hit_kind"] = "first observation (reach)"
    P_hit = state_at(x, F0, t_hit)[0]
    res["fit_hit"] = P_hit[:3].tolist(); res["v_inst_kmh"] = float(np.linalg.norm(P_hit[3:6]) * 3.6)
    # net crossing of the fitted flight
    t_end = (bnc[0] if bnc is not None else frames[-1] + 18)
    fs = np.arange(int(np.floor(t_hit)), int(np.ceil(t_end)) + 1)
    S = simulate(x[None], fs - F0)[0]
    side0 = np.sign(P_hit[1] - NET_Y)
    cross = np.where(np.sign(S[:, 1] - NET_Y) != side0)[0]
    end = None
    if len(cross):
        i = cross[0]
        if i > 0:
            a, b = S[i - 1], S[i]; fr = (NET_Y - a[1]) / (b[1] - a[1])
            t_net = fs[i - 1] + fr; P_net = a[:3] + fr * (b[:3] - a[:3])
        else:
            t_net, P_net = fs[0], S[0, :3]
        if bnc is None or t_net <= bnc[0] + 0.5:
            end = ("net", t_net, P_net)
            res["fit_net_z"] = float(P_net[2])
    if end is None and bnc is not None:
        end = ("bounce", bnc[0], np.array([bnc[1][0], bnc[1][1], BALL_R]))
    if end is None:
        res["reason"] = "fitted flight does not reach the net"; return res
    T = (end[1] - t_hit) / FPS
    if T <= 0.03:
        res["reason"] = "hit-to-net interval too short"; return res
    v = (end[2] - P_hit[:3]) / T; v[2] += 0.5 * G * T
    res.update(end_kind=end[0], interval_s=T, speed_kmh=float(np.linalg.norm(v) * 3.6))
    y_end = end[2][1] if end[0] == "bounce" else (bnc[1][1] if bnc is not None else S[-1, 1])
    if rms > 4:
        res["reason"] = "flight fit RMS above 4 px"
    elif np.sign(P_hit[1] - NET_Y) == np.sign(y_end - NET_Y):
        res["reason"] = "hit and bounce on the same side of the net"
    elif not 20 <= res["speed_kmh"] <= 250:
        res["reason"] = "speed outside 20-250 km/h"
    else:
        res["accepted"] = True
    return res


def side_boxes(boxes, cam, want_near):
    """Boxes whose feet are on the wanted side of the net."""
    out = []
    for b in boxes:
        y = cam.on_plane_z(np.array([[(b[0] + b[2]) / 2, b[3]]]), 0.0)[0][1]
        if (y < NET_Y) == want_near:
            out.append(b)
    return out


def side_boxes_near_time(people, frame, cam, want_near, reach=30):
    """Side-consistent boxes from the closest detection frame within +-reach frames (singles: one
    player per side, so a nearby frame stands in for a frame where Vision missed that player)."""
    keys = _KEYS.get(id(people))
    if keys is None:
        keys = np.array(sorted(int(k) for k in people)); _KEYS[id(people)] = keys
    lo, hi = np.searchsorted(keys, frame - reach), np.searchsorted(keys, frame + reach + 1)
    for k in sorted(keys[lo:hi], key=lambda k: abs(k - frame)):
        c = side_boxes(clean_boxes(people[str(int(k))]), cam, want_near)
        if c:
            return c
    return []


def choose_hitter(boxes, uv, cam, bounce, people=None, frame=None):
    if not V4:
        return person_near(boxes, uv) or person_nearest(boxes, uv)
    if bounce is not None and cam is not None:
        want_near = bounce["ground"][1] > NET_Y
        cand = side_boxes(boxes, cam, want_near)
        h = person_near(cand, uv) or person_nearest(cand, uv, max_heights=6.0)
        if h is None and people is not None:
            cand = side_boxes_near_time(people, frame, cam, want_near)
            h = person_nearest(cand, uv, max_heights=12.0)
        return h
    return person_near(boxes, uv)


def infer_side(people, frame, uv, pts, cam):
    """'near' or 'far' for the hitter (v5)."""
    best = None
    for kk in range(frame - 6, frame + 7):
        for b in clean_boxes(people.get(str(kk), [])):
            h = b[3] - b[1]
            d = np.hypot(uv[0] - (b[0] + b[2]) / 2, uv[1] - (b[1] + b[3]) / 2) / h
            if best is None or d < best[0]:
                best = (d, b)
    if best is not None and best[0] < 1.5:
        return "near" if side_boxes([best[1]], cam, want_near=True) else "far"
    return "far" if pts[-1, 2] - pts[0, 2] > 0 else "near"


def choose_on_side(people, frame, uv, cam, want_near):
    cand = side_boxes(people_at(people, frame), cam, want_near)
    h = person_near(cand, uv) or person_nearest(cand, uv, max_heights=6.0)
    if h is None:
        h = person_nearest(side_boxes_near_time(people, frame, cam, want_near), uv, max_heights=12.0)
    return h


def turn_deg(A, B):
    """Angle between the image velocity at the end of A and at the start of B."""
    ua, va = local_poly(A, True); ub, vb = local_poly(B, False)
    ta, tb = A[-1, 0] / FPS, B[0, 0] / FPS
    da = np.array([np.polyval(np.polyder(ua), ta), np.polyval(np.polyder(va), ta)])
    db = np.array([np.polyval(np.polyder(ub), tb), np.polyval(np.polyder(vb), tb)])
    c = da @ db / max(np.linalg.norm(da) * np.linalg.norm(db), 1e-9)
    return float(np.degrees(np.arccos(np.clip(c, -1, 1))))


def build_jobs(J, people, cam=None):
    pcs, links = J["pieces"], J["links"]
    pred = {l["b"]: l for l in links}; succ = {l["a"]: l for l in links}
    for l in links:
        if l.get("bounce") and (SECOND_BOUNCE or not l.get("bounce_second_chance")):
            l["type"] = "B"
        else:
            k = int(round(l["t"] * FPS))
            b = person_near(people_at(people, k), l["uv"])
            reversal = False
            if EVENTS_V2:
                turn = turn_deg(pcs[l["a"]], pcs[l["b"]])
                if turn < TURN_MIN:
                    b = None  # a hit sends the ball back: the image direction must turn sharply
                # an unseen hitter (near player below the frame): a sharp reversal is still a hit
                reversal = REVERSAL_HITS and turn >= 120 and len(pcs[l["a"]]) >= 6 and len(pcs[l["b"]]) >= 6
            l["type"] = "H" if (b is not None or reversal) else "C"
            l["person"] = b
    jobs = []
    for i in range(len(pcs)):
        if i in pred:
            continue
        # walk the chain
        flight, start = [i], None
        j = i
        while True:
            l = succ.get(j)
            if l is None or l["type"] in "BH":
                jobs.append((flight, start, l))
                if l is None:
                    break
                flight, start = [l["b"]], l
            else:
                flight.append(l["b"])
            j = l["b"]
    out = []
    for flight, start, end in jobs:
        if start is not None and start["type"] == "B":
            continue  # post-bounce flight
        pts = np.vstack([pcs[p] for p in flight])
        if end is not None and end["type"] == "B":
            pts = pts[pts[:, 0] < end["t"] * FPS]
            bounce = dict(t=end["t"], ground=end["ground"])
        else:
            bounce = None
        incoming = None
        if start is not None:
            t_hit = start["t"] * FPS; hitter = start.get("person"); kind = "hit junction"
            if V4 and hitter is not None and bounce is not None and cam is not None:
                if not side_boxes([hitter], cam, want_near=bounce["ground"][1] > NET_Y):
                    hitter = choose_hitter(people_at(people, int(round(t_hit))), start["uv"], cam, bounce, people, int(round(t_hit)))
            contact_uv = list(start["uv"]); incoming = pcs[start["a"]][:, :3].tolist()
            pts = pts[pts[:, 0] > t_hit]
        else:
            # a chain start: look for a serve toss that ended just before (<= 0.6 s, within 200 px)
            t0, uv0 = float(pts[0, 0]), pts[0, 1:3]
            toss = None
            for q, Q in enumerate(pcs):
                if t0 - 36 <= Q[-1, 0] < t0 and np.hypot(*(Q[-1, 1:3] - uv0)) < 200 and is_toss(Q):
                    if toss is None or Q[-1, 0] > toss[-1, 0]:
                        toss = Q
            if toss is not None:
                t_hit = (float(toss[-1, 0]) + t0) / 2; kind = "after toss"
                contact_uv = toss[-1, 1:3].tolist(); incoming = toss[:, :3].tolist()
                boxes = people_at(people, int(round(t_hit)))
                hitter = choose_hitter(boxes, toss[-1, 1:3], cam, bounce, people, int(round(t_hit)))
            else:
                t_hit = t0; kind = "first observation"
                contact_uv = uv0.tolist()
                boxes = people_at(people, int(round(t0)))
                hitter = choose_hitter(boxes, uv0, cam, bounce, people, int(round(t0)))
        if len(pts) == 0:
            continue
        side = None
        if V5 and cam is not None:
            side = infer_side(people, int(round(t_hit)), contact_uv, pts, cam)
            if hitter is None or not side_boxes([hitter], cam, want_near=side == "near"):
                hitter = choose_on_side(people, int(round(t_hit)), contact_uv, cam, side == "near")
        out.append(dict(pts=pts[:, :3], t_hit=t_hit, hitter=hitter, bounce=bounce,
                        meta=dict(hit_kind=kind, hitter_found=hitter is not None, bounce_found=bounce is not None,
                                  contact_uv=contact_uv, hitter_box=hitter, incoming=incoming, hitter_side=side)))
    return out


def match(shots, teacher, window=0.6):
    pairs = []
    for i, s in enumerate(shots):
        for j, t in enumerate(teacher):
            d = abs(s["t_hit"] - t["anchor"])
            if d <= window:
                pairs.append((d, i, j))
    pairs.sort()
    si, tj, m = set(), set(), {}
    for d, i, j in pairs:
        if i in si or j in tj:
            continue
        si.add(i); tj.add(j); m[j] = i
    return m


if __name__ == "__main__":
    jpath, ppath, CAM_PATH, tpath, outdir = sys.argv[1:6]
    J = pickle.load(open(jpath, "rb")); people = json.load(open(ppath))
    jobs = build_jobs(J, people, Camera(CAM_PATH))
    for jb in jobs:
        jb["cam"] = CAM_PATH
    print("candidate shot flights", len(jobs), flush=True)
    with Pool(8) as pool:
        shots = pool.map(analyse, jobs, chunksize=2)
    shots = [s for s in shots if s is not None]
    # de-duplicate flights that start within 0.25 s (keep the one with more observations)
    shots.sort(key=lambda s: s["t_hit"])
    ded = []
    for s in shots:
        if ded and s["t_hit"] - ded[-1]["t_hit"] < 0.25:
            if s["n_obs"] > ded[-1]["n_obs"]:
                ded[-1] = s
            continue
        ded.append(s)
    shots = ded
    rows = [json.loads(l) for l in open(tpath)]
    rows = [r for r in rows if r["source_sha256"] == os.environ["COURT_SPEED_SOURCE_SHA256"]]
    teacher = []
    for r in rows:
        teacher.append(dict(anchor=r["timing"]["software_event_anchor_seconds"], speed=r["teacher_speed_kmh"],
                            stroke=r["stroke"], type=r["type"], result=r["result"], hit=r["teacher_hit"],
                            bounce=r["teacher_bounce"], export=r["timing"]["export_video_time_seconds"]))
    teacher.sort(key=lambda t: t["anchor"])
    m = match(shots, teacher)
    json.dump(dict(shots=shots, teacher=teacher, match={str(k): v for k, v in m.items()}),
              open(f"{outdir}/shots.json", "w"), indent=1, default=float)
    print("shots", len(shots), "accepted", sum(1 for s in shots if s.get("accepted")), "matched rows", len(m))
