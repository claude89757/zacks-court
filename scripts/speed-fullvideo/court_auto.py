"""Automatic tennis-court camera calibration without learned weights (prototype).

Pipeline (one solve):
  1. median of ~25 key frames over a window           (court_frames.py)
  2. white-line evidence: top-hat of min(B,G,R)        (half res for search, full res for refine)
  3. HoughLinesP segments -> merged lines; transverse (near-horizontal) vs longitudinal lines
     through the sideline vanishing point
  4. combinatorial search: 2 transverse x 2 longitudinal lines, labelled with ITF model lines ->
     homography -> closed-form pinhole (principal point fixed) -> plausibility gate -> score
     every model line by coverage on line evidence -> pick the court in front of the camera
  5. sub-pixel refinement of each predicted model line (lines.py refine) + LM (camera.py)
  6. confidence: per-line RMS, lines used, score margin; "no court found" when the checks fail

Court frame and camera JSON as in scripts/speed-fullvideo/camera.py (OpenCV world->camera).
"""
import os, sys, json, time
import numpy as np, cv2

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)   # camera.py and lines.py live next to this file
import camera as cam   # noqa: E402  (court model, projection, line residuals, LM)
import lines as ln     # noqa: E402  (sub-pixel line refinement)

W, H = 1920, 1080
SX, DX, NET_Y, SERV, LEN = cam.SX, cam.DX, cam.NET_Y, cam.SERV, cam.LEN
WB = 0.10
S_HALF = 0.5  # search resolution scale

# ---------------------------------------------------------------- court model for scoring
s_, d_ = SX - 0.025, DX - 0.025
YB, YFB = WB / 2, LEN - WB / 2
YS, YFS = NET_Y - SERV + 0.025, NET_Y + SERV - 0.025
Y_LABELS = {"near_baseline": YB, "near_service": YS, "far_service": YFS, "far_baseline": YFB}
X_LABELS = {"left_doubles": -d_, "left_singles": -s_, "center_service": 0.0, "right_singles": s_, "right_doubles": d_}
# (name, (x0, y0), (x1, y1), weight); sidelines split at the net, far parts are down-weighted
SCORE_LINES = [
    ("near_baseline", (-d_, YB), (d_, YB), 1.0),
    ("near_service", (-s_, YS), (s_, YS), 1.0),
    ("center_service", (0, YS), (0, YFS), 0.8),
    ("far_service", (-s_, YFS), (s_, YFS), 0.5),
    ("far_baseline", (-d_, YFB), (d_, YFB), 0.5),
    ("left_singles", (-s_, 0), (-s_, NET_Y), 1.0),
    ("right_singles", (s_, 0), (s_, NET_Y), 1.0),
    ("left_doubles", (-d_, 0), (-d_, NET_Y), 1.0),
    ("right_doubles", (d_, 0), (d_, NET_Y), 1.0),
    ("left_singles_far", (-s_, NET_Y), (-s_, YFB), 0.5),
    ("right_singles_far", (s_, NET_Y), (s_, YFB), 0.5),
    ("left_doubles_far", (-d_, NET_Y), (-d_, YFB), 0.5),
    ("right_doubles_far", (d_, NET_Y), (d_, YFB), 0.5),
]
NS = 40
_ts = np.linspace(0.02, 0.98, NS)
SCORE_PTS = np.concatenate([np.stack([x0 + (x1 - x0) * _ts, y0 + (y1 - y0) * _ts], 1)
                            for _, (x0, y0), (x1, y1), _ in SCORE_LINES])          # (L*NS, 2)
SCORE_W = np.array([w for *_, w in SCORE_LINES])
FIT_LINES = ["near_baseline", "left_singles", "right_singles", "left_doubles", "right_doubles",
             "near_service", "center_service"]
CHECK_LINES = ["far_service", "far_baseline"]


# ---------------------------------------------------------------- evidence
def tophat_min(img, k):
    mn = img.min(axis=2)
    return cv2.morphologyEx(mn, cv2.MORPH_TOPHAT, cv2.getStructuringElement(cv2.MORPH_RECT, (k, k)))


def evidence(img):
    small = cv2.resize(img, (int(W * S_HALF), int(H * S_HALF)), interpolation=cv2.INTER_AREA)
    th = tophat_min(small, 11).astype(np.float32)
    p = np.percentile(th, 99.5)
    thr = max(10.0, 0.3 * p)
    binary = (th > thr).astype(np.uint8)
    hit = cv2.dilate(binary, np.ones((5, 5), np.uint8))   # +-2 px at half res = +-4 px full res
    return th, binary, hit, thr


# ---------------------------------------------------------------- lines
def detect_lines(binary, min_len=25):
    segs = cv2.HoughLinesP(binary * 255, 1, np.pi / 360, threshold=25, minLineLength=min_len, maxLineGap=4)
    if segs is None:
        return []
    segs = np.asarray(segs).reshape(-1, 4).astype(float)
    L = np.hypot(segs[:, 2] - segs[:, 0], segs[:, 3] - segs[:, 1])
    order = np.argsort(-L)[:600]   # cap clutter: longest 600 segments
    clusters = []  # each: dict(pts list, wts, p, d, n)
    for i in order:
        x0, y0, x1, y1 = segs[i]
        d = np.array([x1 - x0, y1 - y0]) / L[i]
        for c in clusters:
            if abs(c["d"] @ d) < np.cos(np.radians(1.5)):
                continue
            if abs((np.array([x0, y0]) - c["p"]) @ c["n"]) < 2.5 and abs((np.array([x1, y1]) - c["p"]) @ c["n"]) < 2.5:
                c["pts"] += [(x0, y0), (x1, y1)]; c["w"] += [L[i], L[i]]; c["support"] += L[i]
                _fit(c)
                break
        else:
            c = dict(pts=[(x0, y0), (x1, y1)], w=[L[i], L[i]], support=L[i])
            _fit(c)
            clusters.append(c)
    out = []
    for c in clusters:
        P = np.array(c["pts"]); t = (P - c["p"]) @ c["d"]
        c["ends"] = [c["p"] + c["d"] * t.min(), c["p"] + c["d"] * t.max()]
        c["extent"] = float(t.max() - t.min())
        out.append(c)
    return out


def _fit(c):
    P = np.array(c["pts"]); w = np.array(c["w"])
    m = (P * w[:, None]).sum(0) / w.sum()
    C = ((P - m) * w[:, None]).T @ (P - m)
    ev, evec = np.linalg.eigh(C)
    d = evec[:, 1]
    if d[0] < 0 or (abs(d[0]) < 1e-9 and d[1] < 0):
        d = -d
    c["p"], c["d"], c["n"] = m, d, np.array([-d[1], d[0]])


def homog_line(c):
    p, n = c["p"], c["n"]
    return np.array([n[0], n[1], -(n @ p)])


def split_families(lines, min_support=30):
    trans, longi = [], []
    for c in lines:
        if c["support"] < min_support:
            continue
        ang = np.degrees(np.arctan2(c["d"][1], c["d"][0]))
        ang = (ang + 90) % 180 - 90
        (trans if abs(ang) < 15 else longi).append(c)
    return trans, longi


def vanishing_point(longi, tol_deg=1.0):
    """Sideline vanishing point: RANSAC over line pairs, support-weighted inliers."""
    if len(longi) < 2:
        return None, []
    longi = sorted(longi, key=lambda c: -c["support"])[:30]   # cap the O(n^3) RANSAC
    Ls = [homog_line(c) for c in longi]
    best = (0, None, [])
    for i in range(len(longi)):
        for j in range(i + 1, len(longi)):
            v = np.cross(Ls[i], Ls[j])
            if abs(v[2]) < 1e-9:
                continue
            v = v[:2] / v[2]
            inl, sc = [], 0.0
            for k, c in enumerate(longi):
                to = v - c["p"]; dist = np.linalg.norm(to)
                if dist < 1:
                    continue
                if abs(to @ c["n"]) / dist < np.sin(np.radians(tol_deg)) or abs(to @ c["n"]) < 1.5:
                    inl.append(k); sc += c["support"]
            if sc > best[0]:
                best = (sc, v, inl)
    return best[1], [longi[k] for k in best[2]]


def below_horizon(trans, longi, vp, margin=3.0):
    """Ground lines lie below the horizon: the line through the sideline vanishing point along the
    dominant transverse direction (support-weighted median angle of transverse lines below the VP)."""
    low = [c for c in trans if c["p"][1] > vp[1]]
    if low:
        ang = np.array([np.arctan2(c["d"][1], c["d"][0]) for c in low]); w = np.array([c["support"] for c in low])
        o = np.argsort(ang); cw = np.cumsum(w[o]); a = ang[o][np.searchsorted(cw, cw[-1] / 2)]
    else:
        a = 0.0
    hd = np.array([np.cos(a), np.sin(a)]); hn = np.array([-hd[1], hd[0]])
    if hn[1] < 0:
        hn = -hn                      # normal pointing down the image
    below = lambda P: (np.asarray(P) - vp) @ hn > margin
    t2 = [c for c in trans if below(c["ends"][0]) and below(c["ends"][1])]
    l2 = [c for c in longi if below(c["p"]) or below(c["ends"][0]) and below(c["ends"][1])]
    return t2, l2


# ---------------------------------------------------------------- homography search
def square_to_quad(q):
    """q: (N, 4, 2) image points for unit-square corners (0,0), (1,0), (1,1), (0,1). Returns (N, 3, 3)."""
    x0, y0 = q[:, 0, 0], q[:, 0, 1]; x1, y1 = q[:, 1, 0], q[:, 1, 1]
    x2, y2 = q[:, 2, 0], q[:, 2, 1]; x3, y3 = q[:, 3, 0], q[:, 3, 1]
    dx1, dx2, dx3 = x1 - x2, x3 - x2, x0 - x1 + x2 - x3
    dy1, dy2, dy3 = y1 - y2, y3 - y2, y0 - y1 + y2 - y3
    den = dx1 * dy2 - dx2 * dy1
    den = np.where(np.abs(den) < 1e-12, 1e-12, den)
    g = (dx3 * dy2 - dx2 * dy3) / den
    h = (dx1 * dy3 - dx3 * dy1) / den
    Hq = np.empty((len(q), 3, 3))
    Hq[:, 0] = np.stack([x1 - x0 + g * x1, x3 - x0 + h * x3, x0], 1)
    Hq[:, 1] = np.stack([y1 - y0 + g * y1, y3 - y0 + h * y3, y0], 1)
    Hq[:, 2] = np.stack([g, h, np.ones_like(g)], 1)
    return Hq


def pinhole_from_H(Hs, cx=W / 2, cy=H / 2, s=1000.0):
    """Closed-form f, R, t from world-plane->image homographies (full-res pixels), principal point fixed.
    Returns dict of arrays; 'ok' marks a consistent, non-mirrored camera with the court in front."""
    Nm = np.array([[1 / s, 0, -cx / s], [0, 1 / s, -cy / s], [0, 0, 1]])
    G = Nm[None] @ Hs
    g1, g2, g3 = G[:, :, 0], G[:, :, 1], G[:, :, 2]
    a1 = g1[:, 0] * g2[:, 0] + g1[:, 1] * g2[:, 1]; a0 = g1[:, 2] * g2[:, 2]
    b1 = g1[:, 0] ** 2 + g1[:, 1] ** 2 - g2[:, 0] ** 2 - g2[:, 1] ** 2; b0 = g1[:, 2] ** 2 - g2[:, 2] ** 2
    w = -(a1 * a0 + b1 * b0) / (a1 ** 2 + b1 ** 2 + 1e-30)
    ok = w > 0
    w = np.where(ok, w, 1.0)
    fp = 1 / np.sqrt(w)
    Kinv = np.zeros((len(Hs), 3, 3)); Kinv[:, 0, 0] = 1 / fp; Kinv[:, 1, 1] = 1 / fp; Kinv[:, 2, 2] = 1
    M = Kinv @ G
    r1, r2, t = M[:, :, 0], M[:, :, 1], M[:, :, 2]
    n1, n2 = np.linalg.norm(r1, axis=1), np.linalg.norm(r2, axis=1)
    cosang = np.abs((r1 * r2).sum(1)) / (n1 * n2)
    ratio = n1 / n2
    lam = 2 / (n1 + n2)
    r1n, r2n = r1 / n1[:, None], r2 / n2[:, None]
    r3 = np.cross(r1n, r2n)
    Rm = np.stack([r1n, r2n, r3], 2)
    U, _, Vt = np.linalg.svd(Rm)
    Rm = U @ Vt
    t = t * lam[:, None]
    # sign: court centre must be in front of the camera
    Xc = np.array([0, NET_Y, 0.0])
    depth = (Rm @ Xc)[:, 2] + t[:, 2]
    flip = depth < 0
    # flipping G's sign flips r1, r2 (r3 stays), t
    Fm = np.diag([-1, -1, 1.0])
    Rm = np.where(flip[:, None, None], Rm @ Fm, Rm)
    t = np.where(flip[:, None], -t, t)
    C = -np.einsum("nji,nj->ni", Rm, t)
    return dict(f=fp * s, R=Rm, t=t, C=C, cos=cosang, ratio=ratio, ok=ok)


def score_H(Hs, hit, chunk=4000):
    """Per-line coverage of the projected model lines on the dilated half-res evidence."""
    out_s, out_cov, out_vis = [], [], []
    Xh = np.c_[SCORE_PTS, np.ones(len(SCORE_PTS))]  # (P, 3)
    hh, ww = hit.shape
    Lc = len(SCORE_LINES)
    for k in range(0, len(Hs), chunk):
        Hc = Hs[k:k + chunk]
        P = np.einsum("nij,pj->npi", Hc, Xh)
        z = P[:, :, 2]
        u = P[:, :, 0] / np.where(np.abs(z) < 1e-12, 1e-12, z) * S_HALF
        v = P[:, :, 1] / np.where(np.abs(z) < 1e-12, 1e-12, z) * S_HALF
        vis = (z > 0) & (u >= 2) & (u < ww - 2) & (v >= 2) & (v < hh - 2)
        ui = np.clip(u.round().astype(int), 0, ww - 1); vi = np.clip(v.round().astype(int), 0, hh - 1)
        h = hit[vi, ui].astype(bool) & vis
        nvis = vis.reshape(len(Hc), Lc, NS).sum(2)
        nhit = h.reshape(len(Hc), Lc, NS).sum(2)
        cov = nhit / np.maximum(nvis, 1)
        valid = nvis >= 6
        contrib = np.where(valid, SCORE_W * (2 * cov - 1) * np.minimum(1, nvis / 20), 0)
        out_s.append(contrib.sum(1)); out_cov.append(cov); out_vis.append(nvis)
    return np.concatenate(out_s), np.concatenate(out_cov), np.concatenate(out_vis)


def search(trans, longi, hit, max_t=10, max_l=10):
    """Returns candidate list sorted by score (each with H, camera, labels)."""
    trans = sorted(trans, key=lambda c: -c["support"])[:max_t]
    longi = sorted(longi, key=lambda c: -c["support"])[:max_l]
    ref_y = 0.75 * H * S_HALF
    trans.sort(key=lambda c: -(c["p"][1] + (W * S_HALF / 2 - c["p"][0]) * c["d"][1] / c["d"][0]))  # lowest first
    def x_at(c, y):
        return c["p"][0] + (y - c["p"][1]) * c["d"][0] / c["d"][1]
    longi.sort(key=lambda c: x_at(c, ref_y))
    TL = np.array([homog_line(c) for c in trans]); LL = np.array([homog_line(c) for c in longi])
    if len(TL) < 2 or len(LL) < 2:
        return [], trans, longi
    X = np.cross(TL[:, None, :], LL[None, :, :])        # (T, L, 3) intersections (half-res)
    X = X[..., :2] / np.where(np.abs(X[..., 2:]) < 1e-12, 1e-12, X[..., 2:]) / S_HALF  # full-res
    ylab, xlab = list(Y_LABELS.items()), list(X_LABELS.items())
    rows = []
    for i in range(len(trans)):
        for j in range(i + 1, len(trans)):
            for a in range(4):
                for b in range(a + 1, 4):
                    for k in range(len(longi)):
                        for m in range(k + 1, len(longi)):
                            for c_ in range(5):
                                for d in range(c_ + 1, 5):
                                    rows.append((i, j, a, b, k, m, c_, d))
    R = np.array(rows)
    i, j, a, b, k, m, c_, d = R.T
    # unit square: (0,0)->(x_c, y_a) = T_i & L_k ; (1,0)->(x_d, y_a) = T_i & L_m ; (1,1)->T_j & L_m ; (0,1)->T_j & L_k
    q = np.stack([X[i, k], X[i, m], X[j, m], X[j, k]], 1)
    Hq = square_to_quad(q)
    yv = np.array([v for _, v in ylab]); xv = np.array([v for _, v in xlab])
    xa, xb, ya, yb = xv[c_], xv[d], yv[a], yv[b]
    Mw = np.zeros((len(R), 3, 3))
    Mw[:, 0, 0] = 1 / (xb - xa); Mw[:, 0, 2] = -xa / (xb - xa)
    Mw[:, 1, 1] = 1 / (yb - ya); Mw[:, 1, 2] = -ya / (yb - ya)
    Mw[:, 2, 2] = 1
    Hs = Hq @ Mw
    pc = pinhole_from_H(Hs)
    C = pc["C"]
    gate = (pc["ok"] & (pc["cos"] < 0.15) & (np.abs(pc["ratio"] - 1) < 0.15) & (pc["f"] > 500) & (pc["f"] < 3500)
            & (C[:, 2] > 0.4) & (C[:, 2] < 8) & (C[:, 1] < 1.5) & (C[:, 1] > -30) & (np.abs(C[:, 0]) < 12))
    idx = np.nonzero(gate)[0]
    if len(idx) == 0:
        return [], trans, longi
    sc, cov, nvis = score_H(Hs[idx], hit)
    order = idx[np.argsort(-sc)]
    sc_sorted = np.sort(sc)[::-1]
    cov_by = dict(zip(idx, cov)); vis_by = dict(zip(idx, nvis))
    cands = []
    for n, s in zip(order[:400], sc_sorted[:400]):
        cands.append(dict(H=Hs[n], f=float(pc["f"][n]), R=pc["R"][n], t=pc["t"][n], C=pc["C"][n], score=float(s),
                          cov=cov_by[n], nvis=vis_by[n],
                          labels=(ylab[R[n, 2]][0], ylab[R[n, 3]][0], xlab[R[n, 6]][0], xlab[R[n, 7]][0]),
                          lines=(int(R[n, 0]), int(R[n, 1]), int(R[n, 4]), int(R[n, 5]))))
    return cands, trans, longi, len(R), len(idx)


def distinct(cands, dC=0.5, df=0.05):
    out = []
    for c in cands:
        if all(np.linalg.norm(c["C"] - o["C"]) > dC or abs(c["f"] / o["f"] - 1) > df for o in out):
            out.append(c)
    return out


# ---------------------------------------------------------------- refinement
def params_of(c):
    rv, _ = cv2.Rodrigues(c["R"])
    return np.r_[c["f"], rv.ravel(), c["t"]]


def clip_segment(P0, P1, margin=12):
    """Clip a 2D segment to the image rectangle shrunk by margin (Liang-Barsky)."""
    x0, y0 = P0; dx, dy = P1[0] - x0, P1[1] - y0
    t0, t1 = 0.0, 1.0
    for p, q in ((-dx, x0 - margin), (dx, W - margin - x0), (-dy, y0 - margin), (dy, H - margin - y0)):
        if abs(p) < 1e-12:
            if q < 0:
                return None
            continue
        r = q / p
        if p < 0:
            t0 = max(t0, r)
        else:
            t1 = min(t1, r)
        if t0 > t1:
            return None
    return np.array([x0 + dx * t0, y0 + dy * t0]), np.array([x0 + dx * t1, y0 + dy * t1])


def predict_lines(params, names):
    model = cam.court_lines(WB)
    out = {}
    for n in names:
        (x0, y0), (x1, y1) = model[n]
        # visible part: sample, keep in-front points
        ts = np.linspace(0, 1, 60)
        X = np.stack([x0 + (x1 - x0) * ts, y0 + (y1 - y0) * ts, np.zeros_like(ts)], 1)
        R, _ = cv2.Rodrigues(params[1:4]); Zc = (X @ R.T + params[4:7])[:, 2]
        if (Zc > 0.5).sum() < 2:
            continue
        X = X[Zc > 0.5]
        P = cam.project(params, X[[0, -1]])
        seg = clip_segment(P[0], P[1])
        if seg is None or np.linalg.norm(seg[1] - seg[0]) < 30:
            continue
        out[n] = seg
    return out


def refine_lines(th_full, params, names, half, min_peak_scale=1.0):
    pred = predict_lines(params, names)
    res = {}
    for n, (a, b) in pred.items():
        far = n.startswith("far") or n == "center_service"
        mp = (20 if far else 35) * min_peak_scale
        try:
            r = ln.refine(th_full, a, b, half=half if not far else min(half, 6), min_peak=mp)
        except Exception:
            continue
        L = np.linalg.norm(b - a)
        dvec = (b - a) / L
        ang = np.degrees(np.arccos(min(1, abs(dvec @ np.array(r["direction"])))))
        off = abs((np.array(r["point"]) - a) @ np.array([-dvec[1], dvec[0]]))
        span = np.linalg.norm(np.array(r["ends"][1]) - np.array(r["ends"][0]))
        ok = (r["n"] >= max(8, 0.25 * L / 3) and r["rms"] < 2.0 and ang < 2.0 and off < half and span > 0.3 * L)
        r.update(pred_ends=[a.tolist(), b.tolist()], ok=bool(ok), dev_angle=float(ang), dev_off=float(off))
        res[n] = r
    return res


def lm_fit(params, img_lines, use):
    cam._MASKS.clear()
    x, r, J = cam.lm(lambda p: cam.line_residuals(p, img_lines, use, WB), params)
    per = {}
    for n in use:
        cam._MASKS.pop(n, None)
    cam._MASKS.clear()
    for n in img_lines:
        cam._MASKS.clear()
        rr = cam.line_residuals(x, img_lines, [n], WB)
        k = cam._MASKS[n].sum()
        per[n] = float(np.sqrt(np.mean((rr * np.sqrt(k / 10)) ** 2)))
    cam._MASKS.clear()
    rr_all = cam.line_residuals(x, img_lines, use, WB)
    cov = np.linalg.pinv(J.T @ J) * (r @ r) / max(1, len(r) - len(x))
    cam._MASKS.clear()
    return x, per, float(np.sqrt(cov[0, 0])), rr_all


TRANS_LINES = ("near_baseline", "near_service")


def refine_camera(th_full, params, log):
    """Three refine+LM passes; drop lines that disagree with the fit; returns params, info.
    Far lines are checks only: the net band sits next to them and gets mislabelled (tried as a
    fallback second transverse line; it produced confident wrong cameras)."""
    x = np.array(params, float)
    info = {}
    for it, half in enumerate((10, 6, 6)):
        rl = refine_lines(th_full, x, FIT_LINES + CHECK_LINES, half)
        use = [n for n in FIT_LINES if n in rl and rl[n]["ok"]]
        trans = [n for n in use if n in TRANS_LINES]
        longi = [n for n in use if n not in trans]
        if len(trans) < 1 or len(longi) < 2 or len(use) < 4:
            log.append(f"pass {it}: too few lines {use}")
            return None, dict(reason="too few refined lines", lines=use)
        img_lines = {n: rl[n] for n in rl if rl[n]["ok"]}
        x, per, fsd, _ = lm_fit(x, img_lines, use)
        # outlier lines: refit without them
        bad = [n for n in use if per[n] > 2.5]
        if bad and len(use) - len(bad) >= 4:
            use = [n for n in use if n not in bad]
            x, per, fsd, _ = lm_fit(x, {n: img_lines[n] for n in img_lines if n not in bad}, use)
        log.append(f"pass {it}: f={x[0]:.1f} use={use} per={ {k: round(v, 2) for k, v in per.items()} }")
        info = dict(use=use, per_line_rms_px=per, f_sd=fsd, refined={n: {k: rl[n][k] for k in ("rms", "n", "ok", "ends")} for n in rl},
                    dropped=bad, n_trans=sum(n in TRANS_LINES for n in use))
    return x, info


# ---------------------------------------------------------------- solve
def solve(img, log=None, debug=None):
    log = [] if log is None else log
    T = {}
    t0 = time.time()
    th, binary, hit, thr = evidence(img)
    th_full = ln.tophat(img)
    T["evidence"] = time.time() - t0
    t0 = time.time()
    lines = detect_lines(binary)
    trans, longi = split_families(lines)
    vp, longi_in = vanishing_point(longi)
    n_trans_all = len(trans)
    if vp is not None:
        trans, longi_in = below_horizon(trans, longi_in, vp)
    T["lines"] = time.time() - t0
    log.append(f"evidence thr={thr:.1f}; {len(lines)} merged lines, {n_trans_all} transverse ({len(trans)} below horizon), {len(longi)} longitudinal, "
               f"{len(longi_in)} through VP {None if vp is None else np.round(vp / S_HALF).tolist()}")
    t0 = time.time()
    sr = search(trans, longi_in, hit)
    cands = sr[0]
    T["search"] = time.time() - t0
    result = dict(found=False, timing=T, log=log)
    if debug is not None:
        debug.update(th=th, binary=binary, trans=sr[1], longi=sr[2], vp=vp, cands=cands)
    if not cands:
        result["reason"] = "no plausible line combination"
        return result
    log.append(f"hypotheses {sr[3]}, gated {sr[4]}")
    dc = distinct(cands)
    for c in dc[:5]:
        log.append(f"  cand score={c['score']:.2f} f={c['f']:.0f} C={np.round(c['C'], 2).tolist()} labels={c['labels']}")
    # refine the top distinct hypotheses; the refined fit decides
    t0 = time.time()
    tried = []
    for c in dc[:4]:
        sub = []
        x, info = refine_camera(th_full, params_of(c), sub)
        if x is None:
            log.append(f"  refine from score={c['score']:.2f}: failed ({info['reason']})")
            continue
        R, _ = cv2.Rodrigues(x[1:4]); C = -R.T @ x[4:7]
        per = info["per_line_rms_px"]
        fit_rms = float(np.sqrt(np.mean([per[n] ** 2 for n in info["use"]])))
        rs = float(score_H(H_of(x)[None], hit)[0][0])
        log.append(f"  refine from score={c['score']:.2f}: f={x[0]:.1f} C={np.round(C, 2).tolist()} lines={len(info['use'])} "
                   f"rms={fit_rms:.2f} refined score={rs:.2f}")
        tried.append(dict(x=x, info=info, C=C, fit_rms=fit_rms, rscore=rs, init=c, sub=sub))
    T["refine"] = time.time() - t0
    if not tried:
        result["reason"] = "refinement failed for every hypothesis"
        return result
    # quality: refined coverage score, lines used, residual
    for t in tried:
        t["q"] = (t["rscore"] + 0.3 * len(t["info"]["use"]) - 2.0 * max(0, t["fit_rms"] - 1.0)
                  + (2.0 if t["info"]["n_trans"] >= 2 else 0.0))
    tried.sort(key=lambda t: -t["q"])
    pick = tried[0]
    # court in front of the camera: a near-equal candidate whose camera is >4 m more central wins
    for t in tried[1:]:
        if t["q"] >= pick["q"] - 1.0 and abs(t["C"][0]) < abs(pick["C"][0]) - 4:
            log.append(f"  court-in-front rule: C={np.round(t['C'], 2).tolist()} over {np.round(pick['C'], 2).tolist()}")
            pick = t
    others = [t["q"] for t in tried if t is not pick and np.linalg.norm(t["C"] - pick["C"]) > 0.3]
    log.extend(pick["sub"])
    x, info, C, fit_rms = pick["x"], pick["info"], pick["C"], pick["fit_rms"]
    result.update(search_score=pick["init"]["score"], refined_score=pick["rscore"], quality=pick["q"],
                  margin=None if not others else pick["q"] - max(others),
                  init=dict(f=pick["init"]["f"], C=pick["init"]["C"].tolist(), labels=pick["init"]["labels"]))
    per = info["per_line_rms_px"]
    checks = {n: per[n] for n in CHECK_LINES if n in per}
    reasons = []
    if fit_rms > 1.5:
        reasons.append(f"fit RMS {fit_rms:.2f} px > 1.5")
    if info["n_trans"] < 2:
        reasons.append("only one transverse court line fitted (focal length and distance ambiguous; "
                       "near baseline and service line should both be in view)")
    if len(info["use"]) < 5:
        reasons.append(f"only {len(info['use'])} lines")
    if not (500 < x[0] < 3500):
        reasons.append("focal length implausible")
    if not (0.4 < C[2] < 8):
        reasons.append("camera height implausible")
    if info["f_sd"] > 3.0:
        reasons.append(f"focal length poorly determined (sd {info['f_sd']:.1f} px)")
    if pick["rscore"] < 4:
        reasons.append(f"refined coverage score {pick['rscore']:.2f} < 4")
    camkey = "rejected_camera" if reasons else "camera"   # a refused solve never exposes a usable camera
    result.update(found=not reasons, reason="; ".join(reasons) or None)
    result.update({camkey: dict(f=float(x[0]), rvec=x[1:4].tolist(), tvec=x[4:7].tolist(), principal=[W / 2, H / 2],
                              baseline_width_m=WB, camera_center_m=C.tolist())})
    result.update(fit_rms_px=fit_rms, lines_used=info["use"], per_line_rms_px=per, check_lines_rms_px=checks,
                  f_sd_px=info["f_sd"], dropped=info["dropped"],
                  quality=None if reasons else ("good" if len(info["use"]) == len(FIT_LINES) else "partial"))
    return result


def H_of(x):
    R, _ = cv2.Rodrigues(np.asarray(x[1:4], float))
    K = cam.K_of(x[0])
    return K @ np.c_[R[:, 0], R[:, 1], np.asarray(x[4:7], float)]


# ---------------------------------------------------------------- overlay
def overlay(img, params, path, color=(0, 0, 255), extra=None, text=None, rejected=False):
    """Red: accepted camera. Grey: a refused solve (shown only for diagnosis). Cyan: reference."""
    if rejected:
        color = (150, 150, 150)
    out = img.copy()
    def draw(p, col, th):
        R, _ = cv2.Rodrigues(np.asarray(p[1:4], float))
        model = cam.court_lines(WB)
        segs = [((-d_, YB), (d_, YB)), ((-d_, YFB), (d_, YFB)), ((-s_, YS), (s_, YS)), ((-s_, YFS), (s_, YFS)),
                ((0, YS), (0, YFS)), ((-s_, 0), (-s_, LEN)), ((s_, 0), (s_, LEN)), ((-d_, 0), (-d_, LEN)), ((d_, 0), (d_, LEN))]
        for (x0, y0), (x1, y1) in segs:
            ts = np.linspace(0, 1, 50)
            X = np.stack([x0 + (x1 - x0) * ts, y0 + (y1 - y0) * ts, np.zeros_like(ts)], 1)
            P = cam.project(np.asarray(p, float), X)
            cv2.polylines(out, [P.round().astype(np.int32).reshape(-1, 1, 2)], False, col, th, cv2.LINE_AA)
        # net posts and net top
        for sx in (-1, 1):
            X = np.array([[sx * (DX + 0.914), NET_Y, 0], [sx * (DX + 0.914), NET_Y, 1.07]])
            P = cam.project(np.asarray(p, float), X).round().astype(int)
            cv2.line(out, tuple(P[0]), tuple(P[1]), col, th, cv2.LINE_AA)
        X = np.array([[-(DX + 0.914), NET_Y, 1.07], [0, NET_Y, 0.914], [DX + 0.914, NET_Y, 1.07]])
        P = cam.project(np.asarray(p, float), X).round().astype(np.int32)
        cv2.polylines(out, [P.reshape(-1, 1, 2)], False, col, th, cv2.LINE_AA)
    if extra is not None:
        draw(extra, (255, 200, 0), 1)
    if params is not None:
        draw(params, color, 2)
    if text:
        for i, tline in enumerate(text):
            cv2.putText(out, tline, (20, 40 + 34 * i), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 5, cv2.LINE_AA)
            cv2.putText(out, tline, (20, 40 + 34 * i), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 255, 255), 2, cv2.LINE_AA)
    cv2.imwrite(path, out, [cv2.IMWRITE_JPEG_QUALITY, 88])


if __name__ == "__main__":
    # usage: court_auto.py VIDEO T0 OUT.json [DUR] [DEBUG.jpg]   or   court_auto.py --image MEDIAN.png OUT.json [DEBUG.jpg]
    from court_frames import median_frame
    a = sys.argv[1:]
    t_all = time.time()
    if a[0] == "--image":
        img = cv2.imread(a[1]); out, dbg = a[2], (a[3] if len(a) > 3 else None); tmed = 0.0; nfr = None
    else:
        video, t0, out = a[0], float(a[1]), a[2]
        dur = float(a[3]) if len(a) > 3 else 20.0
        dbg = a[4] if len(a) > 4 else None
        tm = time.time(); img, nfr = median_frame(video, t0, dur); tmed = time.time() - tm
    res = solve(img)
    res["timing"]["median"] = tmed
    res["timing"]["total"] = time.time() - t_all
    res["frames"] = nfr
    print("\n".join(res["log"]))
    cm = res.get("camera") or res.get("rejected_camera")
    print("found" if res["found"] else "NO COURT FOUND", res.get("reason"),
          "" if cm is None else f"f={cm['f']:.1f} C={np.round(cm['camera_center_m'], 3).tolist()} rms={res['fit_rms_px']:.2f}")
    print("timing", {k: round(v, 2) for k, v in res["timing"].items()})
    json.dump(res, open(out, "w"), indent=1, default=lambda o: o.tolist() if hasattr(o, "tolist") else str(o))
    if dbg:
        overlay(img, None if cm is None else np.r_[cm["f"], cm["rvec"], cm["tvec"]], dbg, rejected=not res["found"],
                text=["found" if res["found"] else "NO COURT FOUND: " + (res.get("reason") or "")])
