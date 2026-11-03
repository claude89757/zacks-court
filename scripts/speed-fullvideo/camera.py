"""Pinhole camera from refined court lines (development calibration for one fixed-camera video).

Court frame: x lateral (m, 0 on the center service line), y along the court from the outer
edge of the near baseline (m), z up (m). Painted-line centerlines are used, with ITF widths:
sidelines/service lines 5 cm, baseline width W_B (unknown, default 10 cm).

Unknowns: focal length f (px), rotation (3), translation (3). Principal point fixed at the image
center, square pixels, no distortion (line bends measured < 2 px). Residual: perpendicular
distance from projected 3D sample points on each court line to the fitted image line.
"""
import json, sys
import numpy as np, cv2

W, H = 1920, 1080
SX, DX = 4.115, 5.485            # singles / doubles half widths to outer edge
NET_Y, SERV = 11.885, 6.40        # net, net-to-service-line distance (to outer edge)
LEN = 23.77


def court_lines(wb=0.10):
    s, d = SX - 0.025, DX - 0.025
    yb, yfb = wb / 2, LEN - wb / 2
    ys, yfs = NET_Y - SERV + 0.025, NET_Y + SERV - 0.025
    return {
        "near_baseline": [(-d, yb), (d, yb)],
        "left_singles": [(-s, 0), (-s, NET_Y)],
        "right_singles": [(s, 0), (s, NET_Y)],
        "left_doubles": [(-d, 0), (-d, NET_Y)],
        "right_doubles": [(d, 0), (d, NET_Y)],
        "near_service": [(-s, ys), (s, ys)],
        "center_service": [(0, ys), (0, NET_Y)],
        "far_service": [(-s, yfs), (s, yfs)],
        "far_baseline": [(-d, yfb), (d, yfb)],
    }


def K_of(f):
    return np.array([[f, 0, W / 2], [0, f, H / 2], [0, 0, 1.0]])


def K_full(params):
    K = K_of(params[0])
    if len(params) > 7:
        K[0, 2], K[1, 2] = params[7], params[8]
    return K


def project(params, X):
    rv, tv = params[1:4], params[4:7]
    p, _ = cv2.projectPoints(np.asarray(X, float).reshape(-1, 1, 3), rv, tv, K_full(params), None)
    return p.reshape(-1, 2)


_MASKS = {}


def line_residuals(params, img_lines, use, wb):
    """The visible sample set of each line is frozen on first use so the residual length is fixed."""
    model = court_lines(wb)
    res = []
    for name in use:
        L = img_lines[name]
        m, n = np.array(L["point"]), np.array(L["normal"])
        (x0, y0), (x1, y1) = model[name]
        # sample only the visible part: project, keep points inside the image span of the fitted segment
        ts = np.linspace(0, 1, 40)
        X = np.stack([x0 + (x1 - x0) * ts, y0 + (y1 - y0) * ts, np.zeros_like(ts)], 1)
        P = project(params, X)
        e0, e1 = np.array(L["ends"][0]), np.array(L["ends"][1])
        dv = (e1 - e0) / np.linalg.norm(e1 - e0)
        tt = (P - e0) @ dv
        if name not in _MASKS:
            inside = (tt > -5) & (tt < np.linalg.norm(e1 - e0) + 5)
            if inside.sum() < 5:
                inside[:] = True
            _MASKS[name] = inside
        inside = _MASKS[name]
        res.append(((P[inside] - m) @ n) / np.sqrt(inside.sum() / 10))
    return np.concatenate(res)


def lm(fun, x0, iters=60, lam=1e-3):
    x = np.array(x0, float)
    r = fun(x); cost = r @ r
    for _ in range(iters):
        J = np.empty((len(r), len(x)))
        for j in range(len(x)):
            h = 1e-6 * max(1, abs(x[j]))
            xp = x.copy(); xp[j] += h
            J[:, j] = (fun(xp) - r) / h
        A = J.T @ J; g = J.T @ r
        while True:
            dx = -np.linalg.solve(A + lam * np.diag(np.diag(A) + 1e-12), g)
            xn = x + dx; rn = fun(xn); cn = rn @ rn
            if cn < cost:
                x, r, cost = xn, rn, cn; lam = max(lam / 3, 1e-9); break
            lam *= 4
            if lam > 1e9:
                return x, r, J
        if np.max(np.abs(dx)) < 1e-10:
            break
    return x, r, J


def intersect(a, b):
    pa, da = np.array(a["point"]), np.array(a["direction"])
    pb, db = np.array(b["point"]), np.array(b["direction"])
    t = np.linalg.solve(np.stack([da, -db], 1), pb - pa)
    return pa + da * t[0]


def init(img_lines, wb):
    m = court_lines(wb)
    pairs = [("near_baseline", "left_singles", (-(SX - .025), wb / 2)), ("near_baseline", "right_singles", ((SX - .025), wb / 2)),
             ("near_service", "left_singles", (-(SX - .025), NET_Y - SERV + .025)),
             ("near_service", "right_singles", ((SX - .025), NET_Y - SERV + .025)),
             ("near_service", "center_service", (0, NET_Y - SERV + .025))]
    img = np.array([intersect(img_lines[a], img_lines[b]) for a, b, _ in pairs])
    obj = np.array([[x, y, 0] for _, _, (x, y) in pairs])
    best = None
    for f in np.arange(600, 3000, 20):
        ok, rv, tv = cv2.solvePnP(obj, img, K_of(f), None, flags=cv2.SOLVEPNP_IPPE)
        if not ok:
            continue
        e = np.linalg.norm(project(np.r_[f, rv.ravel(), tv.ravel()], obj) - img, axis=1).max()
        if best is None or e < best[0]:
            best = (e, np.r_[f, rv.ravel(), tv.ravel()])
    return best[1]


def camera_center(params):
    R, _ = cv2.Rodrigues(params[1:4])
    return (-R.T @ params[4:7])


if __name__ == "__main__":
    img_lines = json.load(open(sys.argv[1]))
    wb = float(sys.argv[3]) if len(sys.argv) > 3 else 0.10
    fit_use = ["near_baseline", "left_singles", "right_singles", "left_doubles", "right_doubles",
               "near_service", "center_service", "far_service"]
    import os
    fit_use = [n for n in fit_use if n not in os.environ.get("CAMERA_FIT_EXCLUDE", "").split(",")]
    print("fit lines:", fit_use)
    free_pp = len(sys.argv) > 4 and sys.argv[4] == "free-principal"
    x0 = init(img_lines, wb)
    if free_pp:
        x0 = np.r_[x0, W / 2, H / 2]
    x, r, J = lm(lambda p: line_residuals(p, img_lines, fit_use, wb), x0)
    per = {}
    for name in list(court_lines()):
        rr = line_residuals(x, img_lines, [name], wb) * np.sqrt(4)
        per[name] = float(np.sqrt(np.mean(rr ** 2)))
    C = camera_center(x)
    print("f=%.1f px  camera center x=%.3f y=%.3f z=%.3f m" % (x[0], *C))
    print("per-line RMS px:", {k: round(v, 2) for k, v in per.items()}, "(far_baseline is check only)")
    cov = np.linalg.pinv(J.T @ J) * (r @ r) / max(1, len(r) - len(x))
    print("f sd %.1f px, center sd" % np.sqrt(cov[0, 0]))
    # net checks
    for name, X in {"post_L_base": (-(DX + .914), NET_Y, 0), "post_L_top": (-(DX + .914), NET_Y, 1.07),
                    "post_R_base": ((DX + .914), NET_Y, 0), "post_R_top": ((DX + .914), NET_Y, 1.07),
                    "net_center_top": (0, NET_Y, 0.914), "center_mark": (0, wb / 2, 0)}.items():
        print(name, np.round(project(x, [X])[0], 1))
    pp = [float(x[7]), float(x[8])] if free_pp else [W / 2, H / 2]
    print("principal point", np.round(pp, 1))
    json.dump(dict(f=x[0], rvec=x[1:4].tolist(), tvec=x[4:7].tolist(), principal=pp,
                   baseline_width_m=wb, camera_center_m=C.tolist(), per_line_rms_px=per),
              open(sys.argv[2], "w"), indent=1)
