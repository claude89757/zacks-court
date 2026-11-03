"""Far-court person crops from a camera: the image box of the far half (players up to 2.2 m tall),
split into a wide crop and three tighter ones. usage: far_crops.py CAMERA.json OUT.json"""
import sys, json
import numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from flight import Camera
cam = Camera(sys.argv[1])
X = np.array([[x, y, z] for x in (-7, 7) for y in (13, 29) for z in (0, 2.2)], float)
uv, _ = cam.project(X)
x0, y0 = np.floor(uv.min(0)).astype(int); x1, y1 = np.ceil(uv.max(0)).astype(int)
x0, y0 = max(0, x0 - 20), max(0, y0 - 20); x1, y1 = min(1920, x1 + 20), min(1080, y1 + 20)
w = x1 - x0; h = y1 - y0
crops = [[int(x0), int(y0), int(w), int(h)]]
tw = int(w * 0.42)
for k in range(3):
    cx = int(x0 + k * (w - tw) / 2)
    crops.append([cx, int(y0), tw, int(h)])
json.dump(crops, open(sys.argv[2], "w")); print(crops)
