"""Grab frames from the source video at exact frame indices and tile them with labels.
usage: grab.py OUT.jpg COLS SCALE crop(x0,y0,x1,y1|full) idx[:label] ...
Frame index i has PTS i*10/600 s (constant 60 fps, first PTS 0)."""
import sys, subprocess, numpy as np, cv2
import os
V = os.environ["COURT_SPEED_VIDEO"]  # source video (constant 60 fps, first PTS 0)
def frame(i):
    t = i / 60.0
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-ss", f"{max(0,t-1):.4f}", "-i", V, "-ss", f"{min(1,t):.4f}",
                          "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "bgr24", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(1080, 1920, 3).copy()
if __name__ == "__main__":
    out, cols, scale, crop = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
    tiles = []
    for spec in sys.argv[5:]:
        idx, _, label = spec.partition(":")
        img = frame(int(idx))
        if crop != "full":
            x0, y0, x1, y1 = map(int, crop.split(",")); img = img[y0:y1, x0:x1]
        img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        cv2.putText(img, label or idx, (8, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2)
        tiles.append(img)
    while len(tiles) % cols: tiles.append(np.zeros_like(tiles[0]))
    rows = [np.hstack(tiles[r:r + cols]) for r in range(0, len(tiles), cols)]
    cv2.imwrite(out, np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 85])
