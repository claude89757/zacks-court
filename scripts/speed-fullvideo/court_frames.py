"""Clean court image: median of ~25 key frames spread over a time window (players drop out).

Key frames only (`-skip_frame nokey`), one ffmpeg pass, so a 20 s window costs ~20-40 decodes.
"""
import subprocess
import numpy as np

W, H = 1920, 1080


def keyframes(video, t0, dur=20.0, n=25):
    cmd = ["ffmpeg", "-loglevel", "error", "-skip_frame", "nokey", "-ss", f"{t0:.3f}", "-t", f"{dur:.3f}",
           "-i", video, "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "bgr24", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    F = np.frombuffer(raw, np.uint8)
    k = F.size // (W * H * 3)
    if k == 0:
        raise RuntimeError("no frames decoded")
    F = F[: k * W * H * 3].reshape(k, H, W, 3)
    if k > n:
        F = F[np.linspace(0, k - 1, n).round().astype(int)]
    return F


def median_frame(video, t0, dur=20.0, n=25):
    F = keyframes(video, t0, dur, n)
    return np.median(F, axis=0).astype(np.uint8), len(F)
