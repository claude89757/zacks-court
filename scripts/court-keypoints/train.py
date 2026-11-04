#!/usr/bin/env python3
"""Train the court keypoint heatmap net on labels from labels.py (no human labelling, no pretrained weights).

usage: train.py --data DATA_DIR --out OUT_DIR --holdout NAME[,NAME...] [--epochs 40]

Videos named in --holdout are never trained on (hold out whole courts, not single clips). The net sees
512x288 RGB and predicts 14 heatmaps at 256x144. Augmentation warps the frame with a random homography
(pan, tilt, roll, zoom, shift: hand-held framings and partial courts), flips it left-right with the
keypoint names swapped, and changes colour, blur, noise and adds occluders; labels move with the warp.
"""
import argparse, glob, json, math, os, random, time
import numpy as np, cv2, torch, torch.nn as nn, torch.nn.functional as F

cv2.setNumThreads(0)

IN_W, IN_H = 512, 288
OUT_S = 2
OUT_W, OUT_H = IN_W // OUT_S, IN_H // OUT_S
SRC_W, SRC_H = 640, 360            # stored training frames
FULL_W = 1920
SIGMA = 2.0
NK = 14
# left-right swap of keypoint indices (see labels.KEYPOINTS)
FLIP = [1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 12, 13]


def conv(i, o, s=1):
    return nn.Sequential(nn.Conv2d(i, o, 3, s, 1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True))


class Block(nn.Module):
    def __init__(self, i, o, s):
        super().__init__(); self.a = conv(i, o, s); self.b = conv(o, o)
        self.skip = None if (i == o and s == 1) else nn.Sequential(nn.Conv2d(i, o, 1, s, bias=False), nn.BatchNorm2d(o))

    def forward(self, x):
        y = self.b(self.a(x))
        return F.relu(y + (x if self.skip is None else self.skip(x)))


class CourtNet(nn.Module):
    """Small encoder-decoder (stride 32 down, back up to stride 2) with skip connections."""
    def __init__(self, w=(24, 32, 64, 96, 128, 192)):
        super().__init__()
        self.stem = conv(3, w[0], 2)                                   # /2
        self.e1 = Block(w[0], w[1], 2)                                  # /4
        self.e2 = nn.Sequential(Block(w[1], w[2], 2), Block(w[2], w[2], 1))   # /8
        self.e3 = nn.Sequential(Block(w[2], w[3], 2), Block(w[3], w[3], 1))   # /16
        self.e4 = nn.Sequential(Block(w[3], w[4], 2), Block(w[4], w[4], 1), Block(w[4], w[4], 1))  # /32
        self.ctx = nn.Sequential(conv(w[4], w[5]), nn.Conv2d(w[5], w[4], 1), nn.ReLU(inplace=True))
        self.d3 = conv(w[4] + w[3], w[3]); self.d2 = conv(w[3] + w[2], w[2])
        self.d1 = conv(w[2] + w[1], w[1]); self.d0 = conv(w[1] + w[0], w[0])
        self.head = nn.Conv2d(w[0], NK, 1)

    def forward(self, x):
        s0 = self.stem(x); s1 = self.e1(s0); s2 = self.e2(s1); s3 = self.e3(s2); s4 = self.ctx(self.e4(s3))
        up = lambda a, b: torch.cat([F.interpolate(a, scale_factor=2.0, mode="bilinear", align_corners=False), b], 1)
        y = self.d3(up(s4, s3)); y = self.d2(up(y, s2)); y = self.d1(up(y, s1)); y = self.d0(up(y, s0))
        return self.head(y)


def quiet_worker(_):
    cv2.setNumThreads(0)


def load_records(data, names=None):
    recs = []
    for path in sorted(glob.glob(os.path.join(data, "*.labels.json"))):
        d = json.load(open(path))
        if names is not None and d["video"] not in names:
            continue
        for r in d["records"]:
            if "image" in r:
                recs.append({"image": os.path.join(data, "images", r["image"]), "video": d["video"],
                             "kp": np.array(r["keypoints"], dtype=np.float64)})
    return recs


def random_homography(rng, strong):
    """Homography on SRC (640x360) pixels: rotate the camera about its centre, zoom and shift."""
    f = rng.uniform(450, 1200) / 3.0          # focal length in SRC pixels (full-res 450..1200 / 3)
    cx, cy = SRC_W / 2, SRC_H / 2
    K = np.array([[f, 0, cx], [0, f, cy], [0, 0, 1.0]])
    amp = 1.0 if strong else 0.3
    pan, tilt, roll = (math.radians(rng.uniform(-8, 8) * amp), math.radians(rng.uniform(-6, 6) * amp),
                       math.radians(rng.uniform(-4, 4) * amp))
    Rx = cv2.Rodrigues(np.array([tilt, 0, 0.0]))[0]; Ry = cv2.Rodrigues(np.array([0, pan, 0.0]))[0]
    Rz = cv2.Rodrigues(np.array([0, 0, roll]))[0]
    Hr = K @ (Rz @ Rx @ Ry) @ np.linalg.inv(K)
    z = math.exp(rng.uniform(math.log(0.75), math.log(1.6 if strong else 1.2)))
    tx, ty = rng.uniform(-0.15, 0.15) * SRC_W * amp, rng.uniform(-0.12, 0.12) * SRC_H * amp
    Z = np.array([[z, 0, (1 - z) * cx + tx], [0, z, (1 - z) * cy + ty], [0, 0, 1.0]])
    S = np.diag([IN_W / SRC_W, IN_H / SRC_H, 1.0])
    return S @ Z @ Hr


class Data(torch.utils.data.Dataset):
    def __init__(self, recs, train):
        self.recs, self.train = recs, train
        yy, xx = np.mgrid[0:OUT_H, 0:OUT_W]
        self.grid = (xx.astype(np.float32), yy.astype(np.float32))

    def __len__(self):
        return len(self.recs)

    def __getitem__(self, i):
        rng = random.Random() if self.train else random.Random(i)
        r = self.recs[i]
        img = cv2.cvtColor(cv2.imread(r["image"]), cv2.COLOR_BGR2RGB)
        kp = r["kp"].copy()
        uv = kp[:, :2] * (SRC_W / FULL_W)
        if self.train:
            H = random_homography(rng, strong=rng.random() < 0.6) if rng.random() < 0.85 else np.diag([IN_W / SRC_W, IN_H / SRC_H, 1.0])
        else:
            H = np.diag([IN_W / SRC_W, IN_H / SRC_H, 1.0])
        img = cv2.warpPerspective(img, H, (IN_W, IN_H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT,
                                  borderValue=tuple(int(rng.uniform(0, 255)) for _ in range(3)))
        p = np.c_[uv, np.ones(len(uv))] @ H.T
        uv = p[:, :2] / p[:, 2:3]
        vis = (kp[:, 2] > 0) & (p[:, 2] > 0) & (uv[:, 0] >= 0) & (uv[:, 0] < IN_W) & (uv[:, 1] >= 0) & (uv[:, 1] < IN_H)
        if self.train and rng.random() < 0.5:
            img = img[:, ::-1].copy(); uv[:, 0] = IN_W - 1 - uv[:, 0]
            uv, vis = uv[FLIP], vis[FLIP]
        if self.train:
            img = self.photometric(img, rng)
        x = torch.from_numpy(img.astype(np.float32) / 255.0).permute(2, 0, 1)
        g = (uv / OUT_S - (OUT_S - 1) / (2 * OUT_S)).astype(np.float32)   # output-pixel centres
        hm = np.zeros((NK, OUT_H, OUT_W), np.float32)
        for k in range(NK):
            if vis[k]:
                hm[k] = np.exp(-((self.grid[0] - g[k, 0]) ** 2 + (self.grid[1] - g[k, 1]) ** 2) / (2 * SIGMA ** 2))
        return x, torch.from_numpy(hm), torch.from_numpy(np.c_[uv, vis].astype(np.float32))

    @staticmethod
    def photometric(img, rng):
        img = img.astype(np.float32)
        if rng.random() < 0.5:          # hue / saturation change (court colours vary)
            hsv = cv2.cvtColor(img.astype(np.uint8), cv2.COLOR_RGB2HSV).astype(np.float32)
            hsv[..., 0] = (hsv[..., 0] + rng.uniform(-40, 40)) % 180
            hsv[..., 1] *= rng.uniform(0.5, 1.4)
            img = cv2.cvtColor(np.clip(hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2RGB).astype(np.float32)
        img = img * rng.uniform(0.5, 1.4) + rng.uniform(-40, 40)          # exposure
        if rng.random() < 0.3:
            g = img.mean(2, keepdims=True); img = g + (img - g) * rng.uniform(0, 0.6)
        img = np.clip(img, 0, 255).astype(np.uint8)
        if rng.random() < 0.3:          # motion blur
            k = rng.choice([3, 5, 7, 9]); ker = np.zeros((k, k), np.float32)
            ang = rng.uniform(0, math.pi); c = k // 2
            for t in np.linspace(-c, c, 2 * k):
                ker[int(round(c + t * math.sin(ang))), int(round(c + t * math.cos(ang)))] = 1
            img = cv2.filter2D(img, -1, ker / ker.sum())
        elif rng.random() < 0.3:
            img = cv2.GaussianBlur(img, (0, 0), rng.uniform(0.5, 1.5))
        for _ in range(rng.randint(0, 4)):     # occluders (people, posts, nets)
            w, h = int(rng.uniform(8, 70)), int(rng.uniform(20, 140))
            x0, y0 = rng.randint(0, IN_W - 1), rng.randint(0, IN_H - 1)
            img[y0:y0 + h, x0:x0 + w] = [rng.randint(0, 255) for _ in range(3)]
        if rng.random() < 0.3:
            img = np.clip(img.astype(np.float32) + np.random.normal(0, rng.uniform(2, 10), img.shape), 0, 255).astype(np.uint8)
        if rng.random() < 0.3:
            ok, enc = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, rng.randint(30, 80)])
            img = cv2.imdecode(enc, cv2.IMREAD_UNCHANGED)
        return img


def decode(hm):
    """Peak of each heatmap with a 3x3 weighted centre; returns (B, K, 3): u, v in input pixels, peak."""
    B, K, h, w = hm.shape
    flat = hm.reshape(B, K, -1)
    peak, idx = flat.max(-1)
    ys, xs = (idx // w).float(), (idx % w).float()
    pad = F.pad(hm, (1, 1, 1, 1))
    out = torch.zeros(B, K, 3)
    for b in range(B):
        for k in range(K):
            y, x = int(ys[b, k]), int(xs[b, k])
            patch = pad[b, k, y:y + 3, x:x + 3].clamp(min=0)
            s = patch.sum() + 1e-6
            dy = (patch.sum(1) * torch.tensor([-1.0, 0, 1], device=patch.device)).sum() / s
            dx = (patch.sum(0) * torch.tensor([-1.0, 0, 1], device=patch.device)).sum() / s
            out[b, k, 0] = (x + dx) * OUT_S + (OUT_S - 1) / 2
            out[b, k, 1] = (y + dy) * OUT_S + (OUT_S - 1) / 2
            out[b, k, 2] = peak[b, k]
    return out


def evaluate(net, loader, dev):
    net.eval(); errs = []; fp = 0; fn = 0; n = 0
    with torch.no_grad():
        for x, hm, kp in loader:
            pred = decode(net(x.to(dev)).cpu())
            for b in range(len(x)):
                for k in range(NK):
                    v = kp[b, k, 2] > 0; hit = pred[b, k, 2] > 0.3; n += 1
                    if v and hit:
                        errs.append(float(torch.hypot(pred[b, k, 0] - kp[b, k, 0], pred[b, k, 1] - kp[b, k, 1])))
                    elif v and not hit:
                        fn += 1
                    elif hit and not v:
                        fp += 1
    e = np.array(errs) * (FULL_W / IN_W) if errs else np.array([np.nan])   # full-resolution pixels
    return {"median_px": float(np.median(e)), "p90_px": float(np.percentile(e, 90)), "within8": float((e < 8).mean()),
            "missed": fn / max(1, n), "false": fp / max(1, n), "n": len(errs)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--holdout", default=""); ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--batch", type=int, default=16); ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    hold = set(filter(None, a.holdout.split(",")))
    allr = load_records(a.data)
    train = [r for r in allr if r["video"] not in hold]; test = [r for r in allr if r["video"] in hold]
    print(f"train {len(train)} frames from {len({r['video'] for r in train})} videos; held out {len(test)} frames from {sorted(hold)}", flush=True)
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    net = CourtNet().to(dev)
    print("parameters", sum(p.numel() for p in net.parameters()), flush=True)
    tl = torch.utils.data.DataLoader(Data(train, True), batch_size=a.batch, shuffle=True, num_workers=a.workers,
                                     drop_last=True, persistent_workers=True, timeout=300,
                                     worker_init_fn=quiet_worker)
    vl = torch.utils.data.DataLoader(Data(test, False), batch_size=32, num_workers=4) if test else None
    opt = torch.optim.AdamW(net.parameters(), lr=a.lr, weight_decay=1e-4)
    steps = a.epochs * len(tl)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=steps, pct_start=0.1)
    log = []
    for ep in range(a.epochs):
        net.train(); t0 = time.time(); tot = 0
        for x, hm, _ in tl:
            x, hm = x.to(dev), hm.to(dev)
            out = net(x)
            w = 1 + 20 * hm                       # weight the peaks: most pixels are background
            loss = (w * (out - hm) ** 2).mean()
            opt.zero_grad(); loss.backward(); opt.step(); sched.step(); tot += float(loss.detach())
        rec = {"epoch": ep, "loss": tot / len(tl), "seconds": time.time() - t0}
        if vl is not None and (ep % 5 == 4 or ep == a.epochs - 1):
            rec["heldout"] = evaluate(net, vl, dev)
        print(json.dumps(rec), flush=True); log.append(rec)
        torch.save(net.state_dict(), os.path.join(a.out, "court-net.pt"))
    json.dump(log, open(os.path.join(a.out, "train-log.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
