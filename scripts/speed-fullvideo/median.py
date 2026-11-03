"""Median of 25 frames spread over the video (removes players) for court-line fitting.
usage: COURT_SPEED_VIDEO=... median.py FRAME_COUNT OUT.png"""
import sys
import numpy as np, cv2
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from grab import frame
n = int(sys.argv[1])
F = np.stack([frame(int(i)) for i in np.linspace(300, n - 150, 25)])
cv2.imwrite(sys.argv[2], np.median(F, axis=0).astype(np.uint8))
