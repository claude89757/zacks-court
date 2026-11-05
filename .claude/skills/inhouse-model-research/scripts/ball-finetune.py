#!/usr/bin/env python3
"""ball-finetune.py DATA.npz... OUT.pt [--init MODEL.pt] [--epochs 2] [--lr 2e-4] [--batch 2] [--limit N] [--sigma 2.5]

Fine-tunes the TorchScript tracknetv3 module on physical pseudo-labels (`ball-finetune-data.py`).

One sample is the detector's input window (background + 8 frames, 27x288x512, bytes/255) and the target is a
Gaussian heatmap of the labelled frame, which is the window's last frame. Batch norm stays in evaluation mode
(small batches would rewrite the statistics); everything else trains. Validation is every tenth sample,
reported as heatmap MSE and as recall of the argmax within 10 source pixels.

The result is a research artifact, not the App's model: it is FP32 TorchScript on this Mac, and the exported
Core ML package is a separate step.
"""
import json, sys
import numpy as np
import torch

W, H = 512, 288
SOURCE_W, SOURCE_H = 1920, 1080


def gaussian(uv, sigma):
    u = uv[0] * W / SOURCE_W
    v = uv[1] * H / SOURCE_H
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    d2 = (xx - u) ** 2 + (yy - v) ** 2
    return np.exp(-d2 / (2 * sigma * sigma)).astype(np.float32)


def load(path):
    d = np.load(path)
    out = dict(frames=d['frames'], background=d['background'], samples=d['samples'], labels=d['labels'])
    out['window_labels'] = d['window_labels'] if 'window_labels' in d else None
    return out


def targets(data, sample):
    """Gaussian heatmaps for every labelled frame of the window, and the mask of the labelled planes."""
    labels = data['window_labels'][sample]
    planes = np.zeros((8, H, W), dtype=np.float32)
    mask = np.zeros((8, 1, 1), dtype=np.float32)
    for k in range(8):
        index = int(labels[k])
        if index < 0:
            continue
        planes[k] = gaussian(data['labels'][index][1:], 2.5)
        mask[k] = 1.0
    return planes, mask


def sample_tensor(data, row):
    frames = data['frames'][row[:8]]
    tensor = np.concatenate([data['background'][None], frames], axis=0).astype(np.float32) / 255.0
    return torch.from_numpy(np.transpose(tensor, (0, 3, 1, 2)).reshape(1, 27, H, W))


def main(argv):
    args, epochs, lr, batch, limit, sigma, init = [], 2, 2e-4, 2, None, 2.5, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--init':
            init = argv[i + 1]; i += 2; continue
        if a == '--epochs':
            epochs = int(argv[i + 1]); i += 2; continue
        if a == '--lr':
            lr = float(argv[i + 1]); i += 2; continue
        if a == '--batch':
            batch = int(argv[i + 1]); i += 2; continue
        if a == '--limit':
            limit = int(argv[i + 1]); i += 2; continue
        if a == '--sigma':
            sigma = float(argv[i + 1]); i += 2; continue
        args.append(a); i += 1
    if len(args) < 2:
        sys.exit(__doc__)
    data_paths, out_path = args[:-1], args[-1]
    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    model = torch.jit.load(init or out_path, map_location=device).to(device)
    model.eval()  # frozen batch norm; gradients still flow to the parameters
    optimizer = torch.optim.Adam([p for p in model.parameters() if p.requires_grad], lr=lr)
    data = [load(p) for p in data_paths]
    rows = [(k, r) for k, d in enumerate(data) for r in range(len(d['samples']))]
    if limit:
        rows = rows[:limit]
    train = [r for n, r in enumerate(rows) if n % 10 != 9]
    valid = [r for n, r in enumerate(rows) if n % 10 == 9]
    print(json.dumps(dict(train=len(train), valid=len(valid), device=device, params=sum(p.numel() for p in model.parameters()))), flush=True)
    for epoch in range(epochs):
        model.eval()
        running, steps = 0.0, 0
        for start in range(0, len(train), batch):
            group = train[start:start + batch]
            x = torch.cat([sample_tensor(data[k], data[k]['samples'][r]) for k, r in group]).to(device)
            built = [targets(data[k], r) for k, r in group]
            target = torch.from_numpy(np.stack([b[0] for b in built])).to(device)
            mask = torch.from_numpy(np.stack([b[1] for b in built])).to(device)
            prediction = model(x)
            loss = ((((prediction - target) * mask) ** 2).sum()) / (mask.sum().clamp(min=1) * H * W)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            running += float(loss.item()); steps += 1
            if steps % 100 == 0:
                print(f'  epoch {epoch + 1} step {steps}/{len(train) // batch} loss {running / steps:.6f}', flush=True)
        # validation
        model.eval()
        total, hits, count = 0.0, 0, 0
        with torch.no_grad():
            for k, r in valid:
                row = data[k]['samples'][r]
                x = sample_tensor(data[k], row).to(device)
                plane, mask = targets(data[k], r)
                target = torch.from_numpy(plane).to(device)[None]
                prediction = model(x)
                total += float((((prediction - target) ** 2) * torch.from_numpy(mask).to(device)[None]).sum().item() / max(float(mask.sum()) * H * W, 1))
                for pos, index in enumerate(data[k]['window_labels'][r]):
                    if index is None or index < 0:
                        continue
                    flat = int(prediction[0, pos].argmax())
                    py, px = flat // W, flat % W
                    u = data[k]['labels'][int(index)][1] * W / SOURCE_W
                    v = data[k]['labels'][int(index)][2] * H / SOURCE_H
                    hits += ((px - u) ** 2 + (py - v) ** 2) ** 0.5 <= 10 * W / SOURCE_W
                    count += 1
        print(json.dumps(dict(epoch=epoch + 1, train_loss=round(running / max(steps, 1), 6),
                              valid_mse=round(total / max(count, 1), 6), valid_recall_10px=round(hits / max(count, 1), 3))), flush=True)
    torch.jit.save(model, out_path)
    print('saved', out_path)


if __name__ == '__main__':
    main(sys.argv[1:])
