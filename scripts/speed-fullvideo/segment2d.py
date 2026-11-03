"""Split 2D ball tracks into smooth pieces and find the kink between consecutive pieces.

A point breaks the current piece when a local cubic fit of the recent points (<= 0.4 s)
mispredicts it by more than TOL px, and the next point also breaks. The kink between two
pieces is where their local polynomial extrapolations come closest in time.
"""
import numpy as np

FPS = 60.0
TOL = 5.0


def _predict(P, j, win=0.3, deg=2):
    t = P[:, 0] / FPS
    m = (t < t[j]) & (t >= t[j] - win)
    idx = np.where(m)[0]
    if len(idx) < 4:
        return None
    d = min(deg, len(idx) - 2)
    tt = t[idx] - t[j]
    pu = np.polyfit(tt, P[idx, 1], d); pv = np.polyfit(tt, P[idx, 2], d)
    return np.array([np.polyval(pu, 0), np.polyval(pv, 0)])


def split_track(P, tol=8.0, need=3, start_pts=5):
    """Pieces [a, b): a point breaks when the quadratic fit of the previous <=0.3 s misses it by
    more than tol (+2 px per missing frame); a cut needs `need` consecutive breaking points,
    each tested against the fit of the points before the first one."""
    n = len(P); pieces = []; a = 0; j = a + start_pts
    while j < n:
        k = 0
        while k < need and j + k < n:
            Q = np.vstack([P[a:j], P[j + k:j + k + 1]])
            pr = _predict(Q, len(Q) - 1)
            gap = P[j + k, 0] - P[j - 1, 0] - 1
            if pr is None or np.hypot(*(pr - P[j + k, 1:3])) <= tol + 2 * gap:
                break
            k += 1
        if k == need:
            pieces.append((a, j)); a = j; j = a + start_pts
        else:
            j += 1
    pieces.append((a, n))
    return [(x, y) for x, y in pieces if y - x >= 3]


def local_poly(P, at_end, n=8, deg=2):
    Q = P[-n:] if at_end else P[:n]
    t = Q[:, 0] / FPS
    d = min(deg, len(Q) - 2)
    return np.polyfit(t, Q[:, 1], d), np.polyfit(t, Q[:, 2], d)


def kink(A, B):
    """A ends, B starts. Returns (time_s, (u, v), miss_px) at the closest approach of extrapolations."""
    ua, va = local_poly(A, True); ub, vb = local_poly(B, False)
    t0, t1 = A[-1, 0] / FPS, B[0, 0] / FPS
    ts = np.linspace(t0 - 1 / FPS, t1 + 1 / FPS, max(5, int((t1 - t0) * FPS * 8) + 5))
    da = np.stack([np.polyval(ua, ts), np.polyval(va, ts)], 1)
    db = np.stack([np.polyval(ub, ts), np.polyval(vb, ts)], 1)
    d = np.linalg.norm(da - db, axis=1)
    i = int(np.argmin(d))
    return float(ts[i]), (da[i] + db[i]) / 2, float(d[i])
