#!/usr/bin/env python3
"""ball-pseudo-labels.py TRACE.json REPLAY.json OUT.json [--min-rms 3] [--fps 60]

Pseudo-labels for ball detection from our own physical fits (no manual labels, as the project requires).

For every accepted flight in a replay that has both a fitted contact and a fitted landing and a small fit
residual, the ballistic trajectory through those two points is rebuilt and projected into the image for each
frame between them. The result is a list of (frame, time, u, v, near) labels plus a self-check: the distance
from each label to the nearest model candidate of that frame, which validates the projection and gives a first
detection number.

Inputs: the live trace (for the pinhole camera; rvec/tvec in OpenCV convention) and the replay JSON written by
`court-analyze independent-replay` (events + shots arrays, same order). Output: JSON with the labels, per-shot
records and a summary. Read-only; nothing is downloaded.
"""
import json, math, sys

G = 9.81
NET_Y = 11.885
BALL_R = 0.033


def rodrigues(rvec):
    rx, ry, rz = rvec
    th = math.sqrt(rx * rx + ry * ry + rz * rz)
    if th < 1e-12:
        return [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    k = [v / th for v in rvec]
    c, s = math.cos(th), math.sin(th)
    v = 1 - c
    x, y, z = k
    return [
        [c + x * x * v, x * y * v - z * s, x * z * v + y * s],
        [y * x * v + z * s, c + y * y * v, y * z * v - x * s],
        [z * x * v - y * s, z * y * v + x * s, c + z * z * v],
    ]


def cameras(trace):
    """(time, camera) for every camera event in the trace, in order."""
    out, now = [], 0.0
    for e in trace:
        if not isinstance(e, dict):
            continue
        if 'update' in e and isinstance(e['update'], dict):
            now = e['update'].get('now', now)
        if 'camera' in e:
            c = e['camera']
            if isinstance(c, dict) and '_0' in c:
                c = c['_0']
            R = rodrigues(c['rvec'])
            # camera centre: C = -R^T t
            t = c['tvec']
            C = [-sum(R[j][i] * t[j] for j in range(3)) for i in range(3)]
            out.append((now, dict(f=c['f'], cx=c['principal'][0], cy=c['principal'][1], R=R, t=t, C=C)))
    return out


def camera_at(cams, t):
    if not cams:
        return None
    best = cams[0]
    for c in cams:
        if c[0] <= t + 1e-6:
            best = c
        else:
            break
    return best[1]


def project(cam, X, Y, Z):
    R, t = cam['R'], cam['t']
    p = [sum(R[i][j] * (X if j == 0 else Y if j == 1 else Z) for j in range(3)) + t[i] for i in range(3)]
    if p[2] <= 1e-6:
        return None
    return (p[0] / p[2] * cam['f'] + cam['cx'], p[1] / p[2] * cam['f'] + cam['cy'], p[2])


def finite(v):
    return isinstance(v, (int, float)) and math.isfinite(v)


def main(argv):
    args, min_rms, fps = [], 3.0, 60.0
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--min-rms':
            min_rms = float(argv[i + 1]); i += 2; continue
        if a == '--fps':
            fps = float(argv[i + 1]); i += 2; continue
        args.append(a); i += 1
    if len(args) != 3:
        sys.exit(__doc__)
    trace_path, replay_path, out_path = args
    trace = json.load(open(trace_path))
    run = json.load(open(replay_path))
    cams = cameras(trace)
    if not cams:
        sys.exit('no camera event in the trace')
    events, shots = run['events'], run['shots']
    # candidates per frame, for the self-check
    by_frame = {}
    for e in trace:
        if isinstance(e, dict) and 'candidates' in e:
            c = e['candidates']
            batches = list(c.values()) if isinstance(c, dict) else [c]
            for b in batches:
                for cand in b or []:
                    by_frame.setdefault(int(cand['time']), []).append((cand['u'], cand['v']))   # time is in frames
    labels, used, skipped = [], 0, {}
    for i, (e, s) in enumerate(zip(events, shots)):
        if not s.get('accepted') or not s.get('bounceFound'):
            continue
        rms = s.get('rmsPx')
        h, b = s.get('fitHit'), s.get('bounceGround')
        th, tb = s.get('tHit'), s.get('tBounce')
        if not (finite(rms) and rms <= min_rms and h and b and finite(th) and finite(tb)):
            skipped['fit or landing'] = skipped.get('fit or landing', 0) + 1; continue
        if not all(finite(v) for v in h[:3] + b[:3]):
            skipped['non-finite point'] = skipped.get('non-finite point', 0) + 1; continue
        dt = tb - th
        if not (0.10 <= dt <= 3.0) or not (0.3 <= h[2] <= 4.0):
            skipped['duration or contact height'] = skipped.get('duration or contact height', 0) + 1; continue
        cam = camera_at(cams, th)
        if cam is None:
            continue
        vx, vy = (b[0] - h[0]) / dt, (b[1] - h[1]) / dt
        vz = (b[2] - h[2] + 0.5 * G * dt * dt) / dt
        used += 1
        for k in range(int(math.ceil((th + 0.03) * fps)), int(math.floor((tb - 0.03) * fps)) + 1):
            t = k / fps
            tau = t - th
            X = h[0] + vx * tau
            Y = h[1] + vy * tau
            Z = h[2] + vz * tau - 0.5 * G * tau * tau
            if Z < BALL_R * 0.5:
                continue
            p = project(cam, X, Y, Z)
            if p is None:
                continue
            u, v, _ = p
            if not (0 <= u < 1920 and 0 <= v < 1080):
                continue
            labels.append(dict(frame=k, time=round(t, 4), u=round(u, 2), v=round(v, 2), near=Y < NET_Y, shot=i))
    # the engine's candidates carry a constant frame latency (a 3-frame input stack): find the shift that puts
    # them on the labels, then emit the labels in the candidates' frame index
    def distances(shift):
        out = []
        for L in labels:
            cands = by_frame.get(L['frame'] + shift, [])
            if cands:
                out.append(min(math.hypot(c[0] - L['u'], c[1] - L['v']) for c in cands))
        return out
    shift, best = 0, None
    for k in range(-5, 3):
        d = sorted(distances(k))
        if d and (best is None or d[len(d) // 2] < best):
            best, shift = d[len(d) // 2], k
    for L in labels:
        L['frame'] += shift
        L['frameShift'] = shift
    errs, hit = [], 0
    by_half = {True: [], False: []}
    for L in labels:
        cands = by_frame.get(L['frame'], [])
        if not cands:
            continue
        d = min(math.hypot(c[0] - L['u'], c[1] - L['v']) for c in cands)
        errs.append(d)
        by_half[L['near']].append(d)
        hit += d <= 10
    errs.sort()
    halves = {}
    for near, key in ((True, 'near'), (False, 'far')):
        d = sorted(by_half[near])
        halves[key] = dict(
            frames=len(d),
            share_within_10px=round(sum(1 for x in d if x <= 10) / len(d), 3) if d else None,
            median_distance_px=round(d[len(d) // 2], 2) if d else None,
        )
    summary = dict(
        shots_used=used,
        frames=len(labels),
        near_frames=sum(1 for L in labels if L['near']),
        far_frames=sum(1 for L in labels if not L['near']),
        frames_with_candidates=len(errs),
        nearest_candidate_within_10px=hit,
        share_within_10px=round(hit / len(errs), 3) if errs else None,
        frame_shift=shift,
        median_distance_px=round(errs[len(errs) // 2], 2) if errs else None,
        p90_distance_px=round(errs[int(len(errs) * 0.9)], 2) if errs else None,
        skipped=skipped,
        halves=halves,
    )
    json.dump(dict(summary=summary, labels=labels), open(out_path, 'w'), ensure_ascii=False)
    print(json.dumps(summary, ensure_ascii=False))


def self_test():
    """Projection round trip: a world point becomes a pixel and the pixel's ray returns the point."""
    import math
    cam = dict(f=1156.0, cx=960.0, cy=540.0,
               R=rodrigues([1.536, 0.008, -0.007]), t=[-0.20, 1.74, 6.05], C=[0, 0, 0])
    for X, Y, Z in ((0.0, 20.0, 1.2), (3.0, 3.0, 0.4), (-2.5, 12.0, 2.0)):
        p = project(cam, X, Y, Z)
        assert p is not None
        u, v, _ = p
        # invert manually: d = R^T (u, v, 1)/f, then the point on the plane Z
        R = cam['R']
        q = [(u - cam['cx']) / cam['f'], (v - cam['cy']) / cam['f'], 1.0]
        d = [sum(R[j][i] * q[j] for j in range(3)) for i in range(3)]
        # camera centre C = -R^T t
        C = [-sum(R[j][i] * cam['t'][j] for j in range(3)) for i in range(3)]
        s = (Z - C[2]) / d[2]
        back = [C[i] + d[i] * s for i in range(3)]
        err = math.dist(back, (X, Y, Z))
        assert err < 1e-9, (back, (X, Y, Z), err)
    print('self-test: projection round trip ok')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    else:
        main(sys.argv[1:])
