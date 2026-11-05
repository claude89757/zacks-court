#!/usr/bin/env python3
"""ball-finetune-data.py VIDEO LABELS.json OUT.npz [--stride N] [--limit N]

Builds fine-tuning data for the ball detector from physical pseudo-labels (`ball-pseudo-labels.py`).

For every labelled frame n, the sample is the detector's own input window — the 8 frames ending at n, each
512x288 RGB — with the target being frame n's heatmap. The background is the same 48-frame median the live
lane warms up on. Frames are decoded once and kept only if some window needs them.

Output: frames (uint8 [F,288,512,3]), index (int32 per stored frame: its video frame number), background
(uint8 [288,512,3]), samples (int32 [S,9]: eight stored-frame positions and the label index - the last
window entry is the labelled frame), labels (float32 [L,3]: video frame, u, v in source pixels).
"""
import json, sys
import numpy as np
import cv2

W, H = 512, 288
WARMUP = 48
WINDOW = 8


def main(argv):
    args, stride, limit = [], 1, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--stride':
            stride = int(argv[i + 1]); i += 2; continue
        if a == '--limit':
            limit = int(argv[i + 1]); i += 2; continue
        args.append(a); i += 1
    if len(args) != 3:
        sys.exit(__doc__)
    video, labels_path, out_path = args
    labels = json.load(open(labels_path))['labels']
    # one label per frame: the last one wins, and labels closer than a stride are thinned
    by_frame = {}
    for L in labels:
        by_frame[int(L['frame'])] = (float(L['u']), float(L['v']))
    frames_sorted = sorted(by_frame)[::stride]
    if limit:
        frames_sorted = frames_sorted[:limit]
    label_frames = np.array(frames_sorted, dtype=np.int32)
    wanted = set()
    for n in frames_sorted:
        for k in range(n - WINDOW + 1, n + 1):
            if k >= 0:
                wanted.add(k)
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.exit('cannot open ' + video)
    stored, store_index, frames_list = {}, [], []
    background, warm = None, []
    n = 0
    limit_frame = max(wanted) + 1 if wanted else 0
    while True:
        ok, frame = cap.read()
        if not ok or n >= limit_frame:
            break
        small = cv2.cvtColor(cv2.resize(frame, (W, H), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
        if n < WARMUP:
            warm.append(small)
            if len(warm) == WARMUP:
                background = np.median(np.stack(warm), axis=0).astype(np.uint8)
                warm = []
        elif n in wanted:
            store_index.append(n)
            frames_list.append(small)
        n += 1
        if n % 5000 == 0:
            print(f'  decoded {n}', flush=True)
    if background is None:
        sys.exit('video shorter than the warm-up')
    position = {f: i for i, f in enumerate(store_index)}
    # every frame of the window gets its own label when the flight covers it: the model predicts one
    # heatmap per window frame, so supervising only the last one would leave the other seven untrained
    label_index = {}
    samples, kept_labels, window_labels = [], [], []
    for n in frames_sorted:
        window = [n - WINDOW + 1 + k for k in range(WINDOW)]
        if any(f not in position for f in window):
            continue
        indices = []
        for f in window:
            if f in by_frame and f not in label_index:
                label_index[f] = len(kept_labels)
                kept_labels.append([float(f), by_frame[f][0], by_frame[f][1]])
            indices.append(label_index.get(f, -1))
        samples.append([position[f] for f in window])
        window_labels.append(indices)
    np.savez_compressed(out_path, frames=np.stack(frames_list), index=np.array(store_index, dtype=np.int32),
                        background=background, samples=np.array(samples, dtype=np.int32),
                        window_labels=np.array(window_labels, dtype=np.int32),
                        labels=np.array(kept_labels, dtype=np.float32))
    print(json.dumps(dict(frames=len(store_index), samples=len(samples), labels=len(labels))))


if __name__ == '__main__':
    main(sys.argv[1:])
