#!/usr/bin/env python3
"""Automatic court keypoint labels from the geometric calibrator (no human labelling).

For each video, take windows of WINDOW_FRAMES full-resolution frames over WINDOW_SECONDS, build their
per-channel median, run `court-analyze court-calibrate` on it, and when it finds the court, project the
court keypoints with that camera onto every frame of the window that has not moved against the median
(phase correlation on a small grey picture). Players, balls and occluders stay in the frames, so the
labels cover points the line detector cannot see. Frames and labels go to OUT_DIR (keep it in .local/).

usage: labels.py --bin COURT_ANALYZE --out OUT_DIR --name NAME VIDEO [--every 20] [--max-windows 60]
"""
import argparse, json, os, subprocess, sys, tempfile
import numpy as np, cv2

W, H = 1920, 1080
TRAIN_W, TRAIN_H = 640, 360
WINDOW_FRAMES, WINDOW_SECONDS = 9, 4.0

S = 4.115 - 0.025          # singles sideline centreline
D = 5.485 - 0.025          # doubles sideline centreline (doubles half width 5.485 m)
L = 23.77
NET = L / 2
YB, YFB = 0.05, L - 0.05
YS, YFS = NET - 6.40 + 0.025, NET + 6.40 - 0.025
# 14 ground keypoints (x lateral, y from the near baseline): name, (x, y)
KEYPOINTS = [
    ("D_near_L", (-D, YB)), ("D_near_R", (D, YB)), ("D_far_L", (-D, YFB)), ("D_far_R", (D, YFB)),
    ("S_near_L", (-S, YB)), ("S_near_R", (S, YB)), ("S_far_L", (-S, YFB)), ("S_far_R", (S, YFB)),
    ("SV_near_L", (-S, YS)), ("SV_near_R", (S, YS)), ("SV_far_L", (-S, YFS)), ("SV_far_R", (S, YFS)),
    ("T_near", (0.0, YS)), ("T_far", (0.0, YFS)),
]


def rodrigues(r):
    R, _ = cv2.Rodrigues(np.asarray(r, dtype=np.float64))
    return R


def project(cam, pts):
    R = rodrigues(cam["rvec"]); t = np.asarray(cam["tvec"], dtype=np.float64)
    P = np.array([[x, y, 0.0] for x, y in pts]) @ R.T + t
    cx, cy = cam["principal"]
    z = P[:, 2]
    return np.stack([cam["f"] * P[:, 0] / z + cx, cam["f"] * P[:, 1] / z + cy], 1), z


def frame_at(video, t):
    cmd = ["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", video, "-frames:v", "1",
           "-vf", f"scale={W}:{H}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    if len(raw) != W * H * 3:
        return None
    return np.frombuffer(raw, np.uint8).reshape(H, W, 3)


def duration(video):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", video],
                         capture_output=True, text=True).stdout
    return float(out.strip())


def shift(a, b):
    ga = cv2.resize(cv2.cvtColor(a, cv2.COLOR_RGB2GRAY), (480, 270)).astype(np.float32)
    gb = cv2.resize(cv2.cvtColor(b, cv2.COLOR_RGB2GRAY), (480, 270)).astype(np.float32)
    (dx, dy), _ = cv2.phaseCorrelate(ga, gb)
    return float(np.hypot(dx, dy)) * 4.0   # full-resolution pixels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True); ap.add_argument("--out", required=True); ap.add_argument("--name", required=True)
    ap.add_argument("--every", type=float, default=20.0); ap.add_argument("--max-windows", type=int, default=60)
    ap.add_argument("--start", type=float, default=2.0)
    ap.add_argument("video")
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, "images"), exist_ok=True)
    total = duration(a.video)
    starts = list(np.arange(a.start, max(a.start, total - WINDOW_SECONDS - 0.5), a.every))
    if len(starts) > a.max_windows:
        starts = [starts[int(i)] for i in np.linspace(0, len(starts) - 1, a.max_windows)]
    records, found_windows = [], 0
    with tempfile.TemporaryDirectory() as tmp:
        for wi, t0 in enumerate(starts):
            times = [t0 + WINDOW_SECONDS * k / (WINDOW_FRAMES - 1) for k in range(WINDOW_FRAMES)]
            frames = [frame_at(a.video, t) for t in times]
            if any(f is None for f in frames):
                continue
            med = np.median(np.stack(frames), axis=0).astype(np.uint8)
            mpath = os.path.join(tmp, f"m{wi}.png"); cpath = os.path.join(tmp, f"c{wi}.json")
            cv2.imwrite(mpath, cv2.cvtColor(med, cv2.COLOR_RGB2BGR))
            subprocess.run([a.bin, "court-calibrate", mpath, cpath], capture_output=True)
            if not os.path.exists(cpath):
                continue
            cal = json.load(open(cpath))
            status = {"video": a.name, "window": wi, "t0": t0, "found": cal["found"], "refusals": cal["refusals"],
                      "rms": cal.get("fitRMS")}
            if not cal["found"]:
                records.append({"window": status}); continue
            found_windows += 1
            cam = cal["camera"]
            uv, z = project(cam, [p for _, p in KEYPOINTS])
            for k, (t, fr) in enumerate(zip(times, frames)):
                s = shift(med, fr)
                if s > 1.5:
                    continue
                stem = f"{a.name}-w{wi:03d}-f{k}"
                img = cv2.resize(fr, (TRAIN_W, TRAIN_H), interpolation=cv2.INTER_AREA)
                cv2.imwrite(os.path.join(a.out, "images", stem + ".jpg"), cv2.cvtColor(img, cv2.COLOR_RGB2BGR),
                            [cv2.IMWRITE_JPEG_QUALITY, 92])
                kps = []
                for (name, _), (u, v), zz in zip(KEYPOINTS, uv, z):
                    inside = zz > 0 and 0 <= u < W and 0 <= v < H
                    kps.append([float(u), float(v), 1 if inside else 0])
                records.append({"image": stem + ".jpg", "video": a.name, "window": wi, "t": t, "shift": s,
                                "camera": cam, "keypoints": kps, "status": status})
            print(f"{a.name} w{wi} t={t0:.0f}s found rms={cal.get('fitRMS'):.2f}", flush=True)
    with open(os.path.join(a.out, f"{a.name}.labels.json"), "w") as f:
        json.dump({"video": a.name, "keypoints": [n for n, _ in KEYPOINTS], "size": [W, H],
                   "train_size": [TRAIN_W, TRAIN_H], "records": records}, f)
    print(f"{a.name}: {found_windows}/{len(starts)} windows found, "
          f"{sum(1 for r in records if 'image' in r)} frames", flush=True)


if __name__ == "__main__":
    main()
