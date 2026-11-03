"""Link TrackNet candidates into 2D tracks and split them at velocity kinks."""
import numpy as np

FPS = 60.0


def link(C, min_peak=0.3, max_gap=10):
    """C rows: frame, u, v, peak, mean, area, chosen. Returns list of tracks: arrays (frame,u,v,peak)."""
    by = {}
    for fi, u, v, pk, *_ in C:
        if pk >= min_peak:
            by.setdefault(int(fi), []).append((u, v, pk))
    active, done = [], []
    for f in range(int(C[:, 0].min()), int(C[:, 0].max()) + 1):
        cands = by.get(f, [])
        # predictions
        preds = []
        for tr in active:
            P = np.array(tr)
            gap = f - P[-1, 0]
            recent = P[P[:, 0] >= P[-1, 0] - 15][-8:]
            if len(recent) >= 4:
                t = recent[:, 0] - f
                cu = np.polyfit(t, recent[:, 1], 2); cv = np.polyfit(t, recent[:, 2], 2)
                pred = np.array([np.polyval(cu, 0), np.polyval(cv, 0)])
                gate = 16 + 5 * (gap - 1)
            elif len(recent) >= 2:
                vel = (recent[-1, 1:3] - recent[0, 1:3]) / max(1, recent[-1, 0] - recent[0, 0])
                pred = P[-1, 1:3] + vel * gap
                gate = 25 + 8 * (gap - 1)
            else:
                pred = P[-1, 1:3]; gate = 60 + 10 * (gap - 1)
            preds.append((pred, min(gate, 90)))
        pairs = []
        for i, (pred, gate) in enumerate(preds):
            for j, (u, v, pk) in enumerate(cands):
                d = np.hypot(u - pred[0], v - pred[1])
                if d < gate:
                    pairs.append((d / gate, i, j))
        pairs.sort()
        ti, cj = set(), set()
        for _, i, j in pairs:
            if i in ti or j in cj:
                continue
            ti.add(i); cj.add(j)
            u, v, pk = cands[j]; active[i].append((f, u, v, pk))
        for j, (u, v, pk) in enumerate(cands):
            if j not in cj:
                active.append([(f, u, v, pk)])
        keep = []
        for tr in active:
            (done if f - tr[-1][0] > max_gap else keep).append(tr)
        active = keep
    done += active
    out = []
    for tr in done:
        P = np.array(tr)
        if len(P) < 5:
            continue
        ext = np.hypot(np.ptp(P[:, 1]), np.ptp(P[:, 2]))
        if ext < 20:
            continue
        out.append(P)
    out.sort(key=lambda P: P[0, 0])
    return out


def kink_scores(P, win=0.15):
    t = P[:, 0] / FPS; n = len(P)
    sc = np.zeros(n)
    for k in range(n):
        L = (t <= t[k]) & (t >= t[k] - win); R = (t >= t[k]) & (t <= t[k] + win)
        if L.sum() < 4 or R.sum() < 4:
            continue
        vl = [np.polyval(np.polyder(np.polyfit(t[L] - t[k], P[L, c], 2)), 0) for c in (1, 2)]
        vr = [np.polyval(np.polyder(np.polyfit(t[R] - t[k], P[R, c], 2)), 0) for c in (1, 2)]
        sc[k] = np.hypot(vl[0] - vr[0], vl[1] - vr[1])
    return sc


def split(P, thresh=150.0, min_pts=5):
    """Split a track at local maxima of the kink score above thresh (px/s). Kink point goes to both sides."""
    sc = kink_scores(P)
    cuts = []
    for k in range(1, len(P) - 1):
        if sc[k] > thresh and sc[k] >= sc[max(0, k - 3):k + 4].max():
            if not cuts or k - cuts[-1] >= 3:
                cuts.append(k)
    segs, s0 = [], 0
    for k in cuts:
        if k - s0 + 1 >= min_pts:
            segs.append(P[s0:k + 1])
        s0 = k
    if len(P) - s0 >= min_pts:
        segs.append(P[s0:])
    return segs, sc
