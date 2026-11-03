"""3D ballistic flight fitting through a calibrated pinhole camera.

Model: dv/dt = (0, 0, -g) - k |v| v  (quadratic drag, no spin), RK4 on a 1/120 s grid.
Unknowns per flight: position and velocity at the flight's reference frame (6 numbers).
Times are integer frame offsets from the reference frame (constant 60 fps source).
"""
import json
import numpy as np, cv2

G = 9.80665
K_DRAG = 0.0196   # 1/m : rho*Cd*A/(2m) with rho 1.2, Cd 0.55, d 6.7 cm, m 57.7 g
BALL_R = 0.033
FPS = 60.0
SUB = 2           # RK4 substeps per frame


class Camera:
    def __init__(self, path):
        c = json.load(open(path))
        self.f = c["f"]; self.rvec = np.array(c["rvec"]); self.tvec = np.array(c["tvec"])
        self.pp = np.array(c["principal"], float)
        self.R, _ = cv2.Rodrigues(self.rvec)
        self.C = -self.R.T @ self.tvec

    def project(self, X):
        X = np.asarray(X, float)
        sh = X.shape[:-1]
        Xc = X.reshape(-1, 3) @ self.R.T + self.tvec
        uv = Xc[:, :2] / Xc[:, 2:3] * self.f + self.pp
        return uv.reshape(*sh, 2), Xc[:, 2].reshape(sh)

    def ray(self, uv):
        uv = np.asarray(uv, float).reshape(-1, 2)
        d = np.c_[(uv - self.pp) / self.f, np.ones(len(uv))] @ self.R
        return d / np.linalg.norm(d, axis=1, keepdims=True)

    def on_plane_z(self, uv, z):
        d = self.ray(uv); s = (z - self.C[2]) / d[:, 2]
        return self.C + d * s[:, None]


def _deriv(s, k):
    """s: (...,6) or (...,7); the optional 7th column is an extra vertical acceleration (spin lift)."""
    v = s[..., 3:6]
    sp = np.sqrt((v * v).sum(-1, keepdims=True))
    a = -k * sp * v
    a[..., 2] -= G
    if s.shape[-1] == 7:
        a[..., 2] += s[..., 6]
        return np.concatenate([v, a, np.zeros_like(s[..., 6:7])], -1)
    return np.concatenate([v, a], -1)


def rk4_step(state, dt, k=K_DRAG):
    s = np.atleast_2d(state)
    k1 = _deriv(s, k); k2 = _deriv(s + dt / 2 * k1, k); k3 = _deriv(s + dt / 2 * k2, k); k4 = _deriv(s + dt * k3, k)
    return s + dt / 6 * (k1 + 2 * k2 + 2 * k3 + k4)


def simulate(state0, frames, k=K_DRAG):
    """state0 (B,D) at time 0; frames: offsets in 1/60 s units (may be fractional, any order/sign,
    so real PTS times of variable-frame-rate video are exact). Returns (B,N,D)."""
    state0 = np.atleast_2d(np.asarray(state0, float))
    steps = np.asarray(frames, float) * SUB          # offsets in RK4 grid steps
    B, Dm = state0.shape
    out = np.empty((B, len(steps), Dm))
    h = 1.0 / (FPS * SUB)
    for sign in (1, -1):
        m = (steps >= 0) if sign > 0 else (steps < 0)
        if not m.any():
            continue
        a = np.abs(steps[m])
        kf = np.floor(a + 1e-9).astype(int)
        n = int(kf.max())
        traj = np.empty((n + 1, B, Dm)); traj[0] = state0
        s = state0.copy()
        for i in range(1, n + 1):
            s = rk4_step(s, sign * h, k); traj[i] = s
        res = traj[kf]                                   # (M,B,D)
        rem = (a - kf) * h * sign
        nz = np.abs(rem) > 1e-12
        if nz.any():
            base = res[nz].reshape(-1, Dm)
            dt = np.repeat(rem[nz], B)[:, None]
            res[nz] = rk4_step(base, dt, k).reshape(int(nz.sum()), B, Dm)
        out[:, m] = np.transpose(res, (1, 0, 2))
    return out


def fit(cam, frames, uv, init, k=K_DRAG, iters=30, extra=None, huber=4.0):
    """LM on reprojection error with Huber weights. Returns state, per-point residual (px), rms."""
    frames = np.asarray(frames, float); uv = np.asarray(uv, float)
    x = np.array(init, float)

    def raw(X):
        S = simulate(X, frames, k)
        p, depth = cam.project(S[..., :3])
        r = (p - uv[None]).reshape(X.shape[0], -1)
        r[(depth <= 0.5).any(axis=1)] = 1e3
        if extra is not None:
            r = np.concatenate([r, np.stack([extra(xx) for xx in X])], 1)
        return r

    def weights(r):
        n = len(frames)
        e = np.linalg.norm(r[:2 * n].reshape(n, 2), axis=1)
        w = np.where(e < huber, 1.0, np.sqrt(huber / np.maximum(e, 1e-9)))
        return np.r_[np.repeat(w, 2), np.ones(len(r) - 2 * n)]

    lam = 1e-2
    r = raw(x[None])[0]; w = weights(r); cost = ((w * r) ** 2).sum()
    h = np.array([1e-4, 1e-4, 1e-4, 1e-3, 1e-3, 1e-3])
    for _ in range(iters):
        Xp = np.vstack([x] + [x + np.eye(6)[j] * h[j] for j in range(6)])
        R = raw(Xp)
        J = ((R[1:] - R[0]) / h[:, None]).T * w[:, None]
        rw = r * w
        A = J.T @ J; g = J.T @ rw
        improved = False
        for _ in range(8):
            dx = -np.linalg.solve(A + lam * (np.diag(np.diag(A)) + 1e-9 * np.eye(6)), g)
            xn = x + dx
            rn = raw(xn[None])[0]; cn = ((w * rn) ** 2).sum()
            if cn < cost:
                x, r = xn, rn; lam = max(lam / 4, 1e-7); improved = True
                w = weights(r); cost = ((w * r) ** 2).sum()
                break
            lam *= 5
        if not improved or np.max(np.abs(dx) / np.r_[1, 1, 1, 10, 10, 10]) < 1e-5:
            break
    n = len(frames)
    e = np.linalg.norm(r[:2 * n].reshape(n, 2), axis=1)
    return x, e, float(np.sqrt(np.mean(np.minimum(e, 3 * huber) ** 2)))


def on_plane_y(cam, uv, y):
    d = cam.ray(uv); s = (y - cam.C[1]) / d[:, 1]
    return cam.C + d * s[:, None], s


def initial_guesses(cam, frames, uv, ys0=(-1.5, 4, 10, 16, 22, 26), ys1=(-1.5, 2, 6, 11, 16, 21, 25)):
    """Depth hypotheses for the first and last observation (planes y = const)."""
    T = (frames[-1] - frames[0]) / FPS
    out = []
    for y0 in ys0:
        p0, s0 = on_plane_y(cam, uv[:1], y0)
        for y1 in ys1:
            p1, s1 = on_plane_y(cam, uv[-1:], y1)
            if s0[0] <= 0.5 or s1[0] <= 0.5:
                continue
            p0_, p1_ = p0[0], p1[0]
            if not (-0.2 < p0_[2] < 5 and -0.2 < p1_[2] < 5 and abs(p0_[0]) < 12 and abs(p1_[0]) < 12):
                continue
            v0 = (p1_ - p0_) / T; v0[2] += 0.5 * G * T
            sp = np.linalg.norm(v0)
            if not 1.5 < sp < 70:
                continue
            v0 *= 1 + 0.5 * K_DRAG * sp * T
            out.append(np.r_[p0_, v0])
    return out


def best_fit(cam, frames, uv, iters=25, **kw):
    frames = np.asarray(frames, float) - frames[0]
    best = None
    for g0 in initial_guesses(cam, frames, uv, **kw):
        x, e, rms = fit(cam, frames, uv, g0, iters=8)
        if best is None or rms < best[2]:
            best = (x, e, rms)
    if best is None:
        return None
    x, e, rms = fit(cam, frames, uv, best[0], iters=iters)
    return x, e, rms


def anchored_states(P_anchor, t_anchor_frames, V):
    """Ball at P_anchor (3,) at fractional frame time t_anchor_frames with velocities V (B,3).
    Returns (F0, states at integer frame F0)."""
    F0 = int(round(t_anchor_frames))
    V = np.atleast_2d(V)
    S = np.c_[np.repeat(P_anchor[None], len(V), 0), V]
    dt = (F0 - t_anchor_frames) / FPS
    if abs(dt) > 1e-9:
        S = rk4_step(S, dt)
    return F0, S


def fit_anchored(cam, frames, uv, P_anchor, t_anchor_frames, v_init, iters=30, huber=4.0):
    """Fit only the velocity at a fixed 3D anchor (e.g. a bounce on the ground)."""
    frames = np.asarray(frames, float); uv = np.asarray(uv, float)
    F0 = int(round(t_anchor_frames)); rel = frames - F0

    def raw(V):
        _, S0 = anchored_states(P_anchor, t_anchor_frames, V)
        S = simulate(S0, rel)
        p, depth = cam.project(S[..., :3])
        r = (p - uv[None]).reshape(V.shape[0], -1)
        r[(depth <= 0.5).any(axis=1)] = 1e3
        return r

    def weights(r):
        e = np.linalg.norm(r.reshape(-1, 2), axis=1)
        return np.repeat(np.where(e < huber, 1.0, np.sqrt(huber / np.maximum(e, 1e-9))), 2)

    x = np.array(v_init, float); lam = 1e-2
    r = raw(x[None])[0]; w = weights(r); cost = ((w * r) ** 2).sum()
    h = 1e-3
    for _ in range(iters):
        R = raw(np.vstack([x] + [x + np.eye(3)[j] * h for j in range(3)]))
        J = ((R[1:] - R[0]) / h).T * w[:, None]
        A = J.T @ J; g = J.T @ (r * w)
        improved = False
        for _ in range(8):
            dx = -np.linalg.solve(A + lam * (np.diag(np.diag(A)) + 1e-9 * np.eye(3)), g)
            rn = raw((x + dx)[None])[0]; cn = ((w * rn) ** 2).sum()
            if cn < cost:
                x = x + dx; r = rn; lam = max(lam / 4, 1e-7); improved = True
                w = weights(r); cost = ((w * r) ** 2).sum(); break
            lam *= 5
        if not improved or np.max(np.abs(dx)) < 1e-5:
            break
    e = np.linalg.norm(r.reshape(-1, 2), axis=1)
    return x, e, float(np.sqrt(np.mean(np.minimum(e, 3 * huber) ** 2)))


def best_anchored(cam, frames, uv, P_anchor, t_anchor_frames, before, top=3):
    """Grid over velocities at the anchor (one batched simulation), then LM from the best few.
    before=True: the observations precede the anchor (ball coming down to a bounce)."""
    frames = np.asarray(frames, float); uv = np.asarray(uv, float)
    F0 = int(round(t_anchor_frames)); rel = frames - F0
    th = np.radians(np.linspace(-40, 40, 9))
    hs = np.array([5, 9, 14, 20, 27, 35, 45.0])
    vzs = -np.array([0.5, 2, 4, 6, 9, 12.0]) if before else np.array([0.5, 2, 4, 6, 9.0])
    V = []
    for sgn in (1, -1):
        for a in th:
            for h in hs:
                for vz in vzs:
                    V.append([h * np.sin(a), sgn * h * np.cos(a), vz])
    V = np.array(V)
    _, S0 = anchored_states(P_anchor, t_anchor_frames, V)
    S = simulate(S0, rel)
    p, depth = cam.project(S[..., :3])
    e = np.linalg.norm(p - uv[None], axis=2)
    cost = np.minimum(e, 30).mean(axis=1) + 1e3 * (depth <= 0.5).any(axis=1)
    best = None
    for idx in np.argsort(cost)[:top]:
        x, ee, rms = fit_anchored(cam, frames, uv, P_anchor, t_anchor_frames, V[idx], iters=40)
        if best is None or rms < best[2]:
            best = (x, ee, rms)
    return best
