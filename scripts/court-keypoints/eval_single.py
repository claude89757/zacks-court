#!/usr/bin/env python3
"""Single-frame court calibration with and without the keypoint model.

For every window of LABELS (from labels.py) the middle frame is calibrated alone, once on lines only
and once with --keypoint-model. A found camera is "right" when the 12 reference points it projects
(inside the picture) are within TOL px of those of the window's median camera, "wrong" otherwise.
Windows whose median found nothing count only as found / not found (no reference).

usage: eval_single.py --bin COURT_ANALYZE --model MODEL.mlpackage --labels X.labels.json --video VIDEO --out OUT.json
"""
import argparse, json, os, subprocess, tempfile
import numpy as np, cv2

W, H = 1920, 1080
TOL = 6.0


def frame_at(video, t):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", video, "-frames:v", "1", "-vf", f"scale={W}:{H}",
                          "-f", "rawvideo", "-pix_fmt", "bgr24", "-"], capture_output=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(H, W, 3) if len(raw) == W * H * 3 else None


def ref_points(cam):
    s, d, L = 4.115 - 0.025, 5.485 - 0.025, 23.77
    yb, yfb, ys, yfs = 0.05, L - 0.05, L / 2 - 6.4 + 0.025, L / 2 + 6.4 - 0.025
    P = np.array([[-d, yb], [d, yb], [-d, yfb], [d, yfb], [-s, yb], [s, yb], [-s, yfb], [s, yfb], [0, ys], [0, yfs],
                  [-(5.485 + 0.914), L / 2], [5.485 + 0.914, L / 2]])
    R, _ = cv2.Rodrigues(np.array(cam["rvec"], float)); t = np.array(cam["tvec"], float)
    X = np.c_[P, np.zeros(len(P))] @ R.T + t
    cx, cy = cam["principal"]
    return np.c_[cam["f"] * X[:, 0] / X[:, 2] + cx, cam["f"] * X[:, 1] / X[:, 2] + cy], X[:, 2]


def error(a, b):
    pa, za = ref_points(a); pb, zb = ref_points(b)
    m = (za > 0) & (zb > 0) & (pb[:, 0] >= 0) & (pb[:, 0] < W) & (pb[:, 1] >= 0) & (pb[:, 1] < H)
    return float(np.max(np.linalg.norm(pa[m] - pb[m], axis=1))) if m.any() else float("inf")


def main():
    ap = argparse.ArgumentParser()
    for k in ("--bin", "--model", "--labels", "--video", "--out"):
        ap.add_argument(k, required=True)
    a = ap.parse_args()
    d = json.load(open(a.labels))
    windows = {}
    for r in d["records"]:
        if isinstance(r.get("window"), dict):
            windows[r["window"]["window"]] = (r["window"]["t0"], None)
        elif "image" in r:
            windows.setdefault(r["window"], (r["status"]["t0"], r["camera"]))
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for wi, (t0, ref) in sorted(windows.items()):
            fr = frame_at(a.video, t0 + 2.0)
            if fr is None:
                continue
            png = os.path.join(tmp, f"{wi}.png"); cv2.imwrite(png, fr)
            row = {"window": wi, "t": t0 + 2.0, "reference": ref is not None}
            for mode in ("lines", "model"):
                out = os.path.join(tmp, f"{wi}-{mode}.json")
                cmd = [a.bin, "court-calibrate", png, out] + (["--keypoint-model", a.model] if mode == "model" else [])
                subprocess.run(cmd, capture_output=True)
                c = json.load(open(out))
                row[mode] = {"found": c["found"], "refusals": c["refusals"], "seconds": c["timings"]["total"],
                             "fromKeypoints": c.get("startedFromKeypoints"), "keypointSeconds": c.get("keypointSeconds"),
                             "camera": c.get("camera")}
                if c["found"] and ref is not None:
                    row[mode]["error"] = error(c["camera"], ref)
            rows.append(row)
            print(wi, {m: (row[m]["found"], round(row[m].get("error", -1), 1)) for m in ("lines", "model")}, flush=True)
    summary = {}
    for mode in ("lines", "model"):
        withref = [r for r in rows if r["reference"]]
        right = sum(1 for r in withref if r[mode]["found"] and r[mode]["error"] <= TOL)
        wrong = sum(1 for r in withref if r[mode]["found"] and r[mode]["error"] > TOL)
        summary[mode] = {"windows": len(rows), "found": sum(r[mode]["found"] for r in rows),
                         "withReference": len(withref), "right": right, "wrong": wrong,
                         "noReferenceFound": sum(1 for r in rows if not r["reference"] and r[mode]["found"])}
    json.dump({"video": d["video"], "summary": summary, "rows": rows}, open(a.out, "w"), indent=1)
    print(d["video"], json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
