"""Run court_auto on cached medians, compare with reference cameras, write overlays and a summary.
usage: evaluate.py OUT_DIR name[:ref.json] ...   (medians/<name>.png must exist)"""
import sys, os, json, time, warnings
import numpy as np, cv2
warnings.filterwarnings("ignore")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import court_auto as ca
cam = ca.cam

d_, s_, YB, YFB, YS, YFS = ca.d_, ca.s_, ca.YB, ca.YFB, ca.YS, ca.YFS
POINTS = {
    "D_near_L": (-d_, YB, 0), "D_near_R": (d_, YB, 0), "D_far_L": (-d_, YFB, 0), "D_far_R": (d_, YFB, 0),
    "S_near_L": (-s_, YB, 0), "S_near_R": (s_, YB, 0), "S_far_L": (-s_, YFB, 0), "S_far_R": (s_, YFB, 0),
    "T_near": (0, YS, 0), "T_far": (0, YFS, 0),
    "post_L": (-(ca.DX + 0.914), ca.NET_Y, 0), "post_R": (ca.DX + 0.914, ca.NET_Y, 0),
}


def params(c):
    return np.r_[c["f"], c["rvec"], c["tvec"]]


def centre(p):
    R, _ = cv2.Rodrigues(np.asarray(p[1:4], float))
    return -R.T @ np.asarray(p[4:7], float)


def compare(pa, pr):
    X = np.array(list(POINTS.values()), float)
    A, B = cam.project(pa, X), cam.project(pr, X)
    d = np.linalg.norm(A - B, axis=1)
    inside = (B[:, 0] >= 0) & (B[:, 0] < ca.W) & (B[:, 1] >= 0) & (B[:, 1] < ca.H)
    return dict(per_point={k: round(float(v), 2) for k, v in zip(POINTS, d)},
                mean_all=float(d.mean()), max_all=float(d.max()),
                mean_in=float(d[inside].mean()) if inside.any() else None,
                max_in=float(d[inside].max()) if inside.any() else None, n_in=int(inside.sum()),
                df=float(pa[0] - pr[0]), dC=(centre(pa) - centre(pr)).tolist(),
                dC_norm=float(np.linalg.norm(centre(pa) - centre(pr))))


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    rows = []
    for spec in sys.argv[2:]:
        name, _, ref = spec.partition(":")
        img = cv2.imread(f"{HERE}/medians/{name}.png")
        t = time.time()
        res = ca.solve(img)
        res["timing"]["total_solve"] = time.time() - t
        row = dict(name=name, found=res["found"], reason=res.get("reason"), timing=res["timing"])
        p = None
        cm = res.get("camera") or res.get("rejected_camera")
        if cm is not None:
            p = params(cm)
            C = centre(p)
            row.update(f=float(p[0]), C=C.tolist(), fit_rms=res["fit_rms_px"], lines=len(res["lines_used"]),
                       used=res["lines_used"], checks=res["check_lines_rms_px"], margin=res.get("margin"),
                       rscore=res.get("refined_score"), f_sd=res.get("f_sd_px"), quality=res.get("quality"))
            json.dump(cm, open(f"{out}/{name}-{'camera' if res['found'] else 'rejected-camera'}.json", "w"), indent=1)
        pr = None
        if ref:
            pr = params(json.load(open(ref)))
            if p is not None:
                row["cmp"] = compare(p, pr)
        txt = [f"{name}: {'found' if res['found'] else 'NO COURT FOUND'} {res.get('reason') or ''}"]
        if p is not None:
            txt.append(f"f={p[0]:.1f}px  C=({C[0]:.2f}, {C[1]:.2f}, {C[2]:.2f}) m  rms={res['fit_rms_px']:.2f}px  lines={len(res['lines_used'])}")
        if "cmp" in row:
            txt.append(f"vs ref: mean {row['cmp']['mean_all']:.2f}px max {row['cmp']['max_all']:.2f}px  dC={row['cmp']['dC_norm']:.3f} m")
        ca.overlay(img, p, f"{out}/{name}-overlay.jpg", extra=pr, text=txt, rejected=not res["found"])
        json.dump(dict(row=row, log=res["log"]), open(f"{out}/{name}-result.json", "w"), indent=1, default=str)
        rows.append(row)
        print("\n".join(txt), "| t=%.2fs" % row["timing"]["total_solve"], flush=True)
    json.dump(rows, open(f"{out}/summary.json", "w"), indent=1, default=str)
