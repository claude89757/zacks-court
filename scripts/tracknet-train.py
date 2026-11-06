#!/usr/bin/env python3
"""Fine-tune the ball detector on the labels the chain produces (2026-11-07).

Reads label lines from `scripts/tracknet-labels.py` ({"t", "u", "v"}), cuts nine frames ending at
each label's time, builds the 27-channel input the model expects (median background plus eight
frames, 288x512, values in 0..1) and a gaussian target at the labelled ball position, then trains
on the weighted binary cross entropy the model's authors use.

Frames are cached by decode index under `.local/tracknet-train-20261107/cache/` so a second epoch
does not decode the video again. Checkpoints go beside the cache.

Usage:
  python3 scripts/tracknet-train.py LABELS.jsonl VIDEO OUT.pt [--epochs 3] [--samples 60]

This is a development tool: it does not touch the shipped weights, and the training videos must not
include the held-out ones (docs/tracknet-finetune-protocol.md).
"""
import json
import os
import subprocess
import sys

import numpy as np

CACHE = os.path.expanduser('.local/tracknet-train-20261107/cache')
TRACKNET = '.local/speed-training/tracknet-smoke-20261028/TrackNetV3'
BASE = '.local/speed-training/tracknet-smoke-20261028/checkpoints/ckpts/TrackNet_best.pt'
WIDTH, HEIGHT, CHANNELS, SEQUENCE = 512, 288, 3, 8


def decode(video, start, count):
    """The `count` frames from `start` seconds, RGB, 288x512, float in 0..1."""
    out = subprocess.run(['ffmpeg', '-v', 'error', '-ss', f'{max(0.0, start):.3f}', '-i', video,
                          '-frames:v', str(count), '-vf', f'scale={WIDTH}:{HEIGHT}',
                          '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                         capture_output=True).stdout
    size = WIDTH * HEIGHT * CHANNELS
    frames = len(out) // size
    if frames == 0:
        return None
    return np.frombuffer(out[:frames * size], dtype=np.uint8).reshape(frames, HEIGHT, WIDTH, CHANNELS).astype(np.float32) / 255.0


def sample_at(video, t):
    """Background plus the eight frames ending at `t`, and the ball position in the heatmap frame."""
    block = decode(video, t - SEQUENCE / 60.0, SEQUENCE + 1)
    if block is None or len(block) < SEQUENCE + 1:
        return None
    background = np.median(block, axis=0)
    frames = block[-SEQUENCE:]
    stacked = np.concatenate([background.transpose(2, 0, 1)] +
                             [f.transpose(2, 0, 1) for f in frames], axis=0)
    return stacked.astype(np.float32)


def target_for(u, v, sigma=2.0):
    xs = np.arange(WIDTH, dtype=np.float32) - u * WIDTH / 1920.0
    ys = np.arange(HEIGHT, dtype=np.float32) - v * HEIGHT / 1080.0
    grid = np.exp(-(ys[:, None] ** 2 + xs[None, :] ** 2) / (2 * sigma * sigma))
    return (grid / grid.max()).astype(np.float32)


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    labels_path, video, out_path = argv[1], argv[2], argv[3]
    epochs = int(argv[argv.index('--epochs') + 1]) if '--epochs' in argv else 3
    limit = int(argv[argv.index('--samples') + 1]) if '--samples' in argv else 60
    os.makedirs(CACHE, exist_ok=True)
    sys.path.insert(0, TRACKNET)
    import torch
    from model import TrackNet

    pairs = [(labels_path, video)]
    if '--manifest' in argv:
        with open(argv[argv.index('--manifest') + 1]) as f:
            pairs = [(entry['labels'], entry['video']) for entry in json.load(f)]
    samples = []
    for labels_file, video_file in pairs:          # each label's time belongs to its own video
        with open(labels_file) as f:
            labels = [json.loads(line) for line in f][:limit]
        print(f'{len(labels)} labels from {os.path.basename(video_file)}')
        for row in labels:
            key = os.path.join(CACHE, f'{os.path.basename(video_file)}-{row["t"]:.4f}.npy')
            if os.path.exists(key):
                stacked = np.load(key)
            else:
                stacked = sample_at(video_file, row['t'])
                if stacked is None:
                    continue
                np.save(key, stacked)
            samples.append((stacked, target_for(row['u'], row['v'])))
    print(f'{len(samples)} samples with frames, {epochs} epochs')

    model = TrackNet(27, 8)
    checkpoint = torch.load(BASE, map_location='cpu', weights_only=True)
    model.load_state_dict(checkpoint['model'])
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-4)
    def loss_fn(probability, target):
        """Weighted BCE on the model's own sigmoid output: the ball covers a handful of pixels, so
        weight them up (2026-11-07). The model already ends in a sigmoid, so this takes
        probabilities rather than logits."""
        eps = 1e-7
        weight = 1.0 + 4.0 * (target > 0.05).to(probability.dtype)
        p = probability.clamp(eps, 1 - eps)
        term = -(target * p.log() + (1 - target) * (1 - p).log())
        return (weight * term).mean()

    history = []
    for epoch in range(epochs):
        model.train()
        total = 0.0
        for stacked, target in samples:
            x = torch.from_numpy(stacked).unsqueeze(0)
            y = torch.from_numpy(target).view(1, 1, HEIGHT, WIDTH)
            optimizer.zero_grad()
            prediction = model(x)
            if prediction.dim() == 5:
                prediction = prediction[:, -1]
            if prediction.shape[1] > 1:            # eight heatmaps, one per input frame
                prediction = prediction[:, -1:]
            prediction = prediction.reshape(1, 1, HEIGHT, WIDTH)
            loss = loss_fn(prediction, y)
            loss.backward()
            optimizer.step()
            total += float(loss.item())
        average = total / max(len(samples), 1)
        history.append(average)
        print(f'epoch {epoch + 1}: loss {average:.5f}')
    torch.save({'model': model.state_dict(), 'history': history, 'labels': labels_path}, out_path)
    print(f'saved {out_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
