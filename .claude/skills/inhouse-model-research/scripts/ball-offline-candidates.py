#!/usr/bin/env python3
"""ball-offline-candidates.py VIDEO MODEL.pt OUT.json [--limit N] [--start S] [--batch B]

Ball candidates from a TorchScript tracknetv3 module, on this Mac, over a whole video: the same detector
inputs the live lane builds (a 48-frame median background, then 8-frame batches at 512x288, bytes/255) and
the same candidate rule (threshold 0.3, 8-connected components, bbox centres mapped to source pixels,
sorted by peak, top 20 per frame).

Writes the flat `[{decodeIndex,time,u,v,peak}]` list `court-analyze independent-replay --candidates` takes,
so a model can be compared end to end (same camera, people and rules, different candidates).

The preprocessing here is cv2's downscale rather than vImage/Pillow, and the model runs in FP32 on the GPU
instead of FP16 on the Neural Engine: numbers are not bit-identical to a live run, and this is a research
tool, not the App's lane.
"""
import json, sys
import numpy as np
import cv2
import torch

W, H = 512, 288
WARMUP = 48
BATCH = 8
THRESHOLD = 0.3
TOPK = 20


def components(plane, threshold):
    mask = (plane > threshold).astype(np.uint8)
    if not mask.any():
        return []
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    if count <= 1:
        return []
    peaks = np.zeros(count, dtype=np.float32)
    np.maximum.at(peaks, labels, plane)
    out = []
    for i in range(1, count):
        x, y, w, h, _area = stats[i]
        out.append((float(peaks[i]), int(x + w // 2), int(y + h // 2), int(w * h)))
    out.sort(key=lambda c: (-c[0], -c[3]))
    return out[:TOPK]


def main(argv):
    args, limit, start, batch, times_path = [], None, 0, 4, None
    threshold = THRESHOLD
    i = 0
    if '--threshold' in argv:
        j = argv.index('--threshold')
        threshold = float(argv[j + 1])
        argv = argv[:j] + argv[j + 2:]
    if '--times' in argv:
        j = argv.index('--times')
        times_path = argv[j + 1]
        argv = argv[:j] + argv[j + 2:]
    while i < len(argv):
        a = argv[i]
        if a == '--limit':
            limit = int(argv[i + 1]); i += 2; continue
        if a == '--start':
            start = int(argv[i + 1]); i += 2; continue
        if a == '--batch':
            batch = int(argv[i + 1]); i += 2; continue
        args.append(a); i += 1
    if len(args) != 3:
        sys.exit(__doc__)
    video, model_path, out_path = args
    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    model = torch.jit.load(model_path, map_location=device).to(device).eval()
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.exit('cannot open ' + video)
    fps = cap.get(cv2.CAP_PROP_FPS) or 60.0
    times = None
    if times_path:
        # per-frame source timestamps: the engine's candidate time is PTS x 60, and variable frame rates
        # make frame index / nominal fps drift from it
        times = [float(line.strip().rstrip(',')) * 60.0 for line in open(times_path) if line.strip()]
    cap.set(cv2.CAP_PROP_POS_FRAMES, start)
    frames, background, batch_frames, batch_indices = [], None, [], []
    n, emitted, written = start, 0, []
    stop = start + limit if limit else None
    while True:
        ok, frame = cap.read()
        if not ok or (stop is not None and n >= stop):
            break
        small = cv2.resize(frame, (W, H), interpolation=cv2.INTER_AREA)
        rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
        if background is None:
            frames.append(rgb)
            if len(frames) == WARMUP:
                background = np.median(np.stack(frames), axis=0).astype(np.uint8)
                frames = []
            n += 1
            continue
        batch_frames.append(rgb); batch_indices.append(n)
        n += 1
        if len(batch_frames) == BATCH:
            written += infer(model, device, background, batch_frames, batch_indices, times, fps, threshold)
            emitted += 1
            batch_frames, batch_indices = [], []
            if emitted % 200 == 0:
                print(f'  {n} frames, {emitted} batches', flush=True)
    if batch_frames:
        while len(batch_frames) < BATCH:
            batch_frames.append(batch_frames[-1]); batch_indices.append(batch_indices[-1] + 1)
        written += infer(model, device, background, batch_frames, batch_indices, times, fps, threshold)
    written.sort(key=lambda c: c['time'])
    json.dump(written, open(out_path, 'w'))
    print(json.dumps(dict(frames=n - start, candidates=len(written), fps=fps, threshold=threshold, device=device)))


def infer(model, device, background, frames, indices, times, fps, threshold):
    tensor = np.concatenate([background[None], np.stack(frames)], axis=0)  # 9 x H x W x 3
    tensor = tensor.astype(np.float32) / 255.0
    tensor = np.transpose(tensor, (0, 3, 1, 2)).reshape(1, 27, H, W)
    with torch.no_grad():
        planes = model(torch.from_numpy(tensor).to(device))[0].float().cpu().numpy()
    out = []
    for k in range(planes.shape[0]):
        index = indices[k]
        t = times[index] if times and index < len(times) else index * 60.0 / fps
        for peak, x, y, _area in components(planes[k], threshold):
            out.append(dict(decodeIndex=index + 1, time=t,
                            u=int(x * 1920 / W), v=int(y * 1080 / H), peak=round(peak, 4)))
    return out


if __name__ == '__main__':
    main(sys.argv[1:])
