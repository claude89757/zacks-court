"""Refine painted court lines in the median frame to sub-pixel centerlines.

Each line starts from a rough pair of endpoints. Along the line every 3 px we take a
perpendicular profile of the white top-hat image, find the intensity-weighted centroid,
and fit a total-least-squares line with outlier rejection. Prints RMS and the quadratic
bend of the centroids (a lens-distortion check).
"""
import json, sys
import numpy as np, cv2

ROUGH = {
    "near_baseline":   [(20, 870), (1900, 871)],
    "left_singles":    [(158, 868), (655, 693)],
    "right_singles":   [(1702, 872), (1250, 693)],
    "left_doubles":    [(8, 836), (560, 693)],
    "right_doubles":   [(1912, 860), (1345, 693)],
    "near_service":    [(545, 734), (1345, 735)],
    "center_service":  [(946, 732), (952, 690)],
    "far_baseline":    [(700, 640), (1220, 640)],
    "far_service":     [(770, 653), (1150, 653)],
}


def tophat(img):
    mn = img.min(axis=2)
    th = cv2.morphologyEx(mn, cv2.MORPH_TOPHAT, cv2.getStructuringElement(cv2.MORPH_RECT, (21, 21)))
    return cv2.GaussianBlur(th.astype(np.float32), (3, 3), 0)


def sample(img, pts):
    return cv2.remap(img, pts[:, 0].astype(np.float32).reshape(-1, 1), pts[:, 1].astype(np.float32).reshape(-1, 1),
                     cv2.INTER_LINEAR).ravel()


def refine(th, p0, p1, half=10, step=3.0, min_peak=35):
    p0, p1 = np.array(p0, float), np.array(p1, float)
    for _ in range(3):
        d = p1 - p0; L = np.linalg.norm(d); u = d / L; n = np.array([-u[1], u[0]])
        ts = np.arange(0, L, step)
        offs = np.arange(-half, half + 0.25, 0.25)
        cents = []
        for t in ts:
            c = p0 + u * t
            prof = sample(th, c + offs[:, None] * n)
            pk = prof.max()
            if pk < min_peak:
                continue
            w = np.clip(prof - 0.4 * pk, 0, None)
            if w.sum() == 0:
                continue
            o = (w * offs).sum() / w.sum()
            cents.append(c + o * n)
        C = np.array(cents)
        keep = np.ones(len(C), bool)
        for _ in range(4):
            m = C[keep].mean(axis=0)
            _, _, vt = np.linalg.svd(C[keep] - m)
            dirv = vt[0]; nv = np.array([-dirv[1], dirv[0]])
            r = (C - m) @ nv
            s = 1.4826 * np.median(np.abs(r[keep])) + 0.05
            keep = np.abs(r) < 3 * s
        # project ends to the fitted line for the next pass
        tt = (C[keep] - m) @ dirv
        p0, p1 = m + dirv * tt.min(), m + dirv * tt.max()
    # bend: fit r = a t^2 + b t + c along the line
    tn = (tt - tt.mean()) / (tt.max() - tt.min() + 1e-9)
    coef = np.polyfit(tn, r[keep], 2)
    return dict(point=m.tolist(), direction=dirv.tolist(), normal=nv.tolist(),
                rms=float(np.sqrt(np.mean(r[keep] ** 2))), n=int(keep.sum()), rejected=int((~keep).sum()),
                bend_px=float(coef[0] / 4), ends=[p0.tolist(), p1.tolist()])


if __name__ == "__main__":
    # usage: lines.py MEDIAN.png OUT.json [ROUGH.json]  (ROUGH.json: {"line": [[x0, y0], [x1, y1]], ...};
    # the built-in ROUGH table is for the double-test-003 court)
    img = cv2.imread(sys.argv[1])
    rough = json.load(open(sys.argv[3])) if len(sys.argv) > 3 else ROUGH
    th = tophat(img)
    out = {}
    for name, (a, b) in rough.items():
        r = refine(th, a, b, half=6 if name.startswith("far") or name == "center_service" else 10,
                   min_peak=20 if name.startswith("far") else 35)
        out[name] = r
        print(f"{name:15s} n={r['n']:4d} rej={r['rejected']:3d} rms={r['rms']:.2f}px bend={r['bend_px']:+.2f}px ends={np.round(r['ends'],1).tolist()}")
    json.dump(out, open(sys.argv[2], "w"), indent=1)
