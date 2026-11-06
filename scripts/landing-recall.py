#!/usr/bin/env python3
"""Does the ball detector have a candidate near a landing? (2026-11-07)

Projects ground points back to the image with the camera stored in a replay trace, and
measures the distance from each projected point to the nearest candidate around the bounce
time. Because the trace's world frame is not documented and my conversions contradicted each
other (docs/verification.md, 2026-11-07), the script picks the frame by self-check first: it
projects the landings the chain *did* detect, tries each candidate convention, and refuses to
report anything unless one of them reproduces those landings.

Usage:
  python3 scripts/landing-recall.py TRACE.json RUN.json [--teacher TEACHER.json] [--self-test]

TRACE is a `*.trace.json` from `court-analyze independent-live`, RUN an output of the same
run (or a replay), TEACHER a converted reference (rows with `anchor`, `bounce.x`, `bounce.y`,
the x in metres from the centre line). Without TEACHER only the self-check runs.
"""
import json
import math
import sys

BALL_RADIUS = 0.033
CENTRE_X = 5.485
NET_Y = 11.885


def rodrigues(r):
    theta = math.sqrt(sum(x * x for x in r))
    k = [x / theta for x in r] if theta > 1e-12 else [0, 0, 0]
    kx, ky, kz = k
    c, s = math.cos(theta), math.sin(theta)
    v = 1 - c
    return [[c + kx * kx * v, kx * ky * v - kz * s, kx * kz * v + ky * s],
            [ky * kx * v + kz * s, c + ky * ky * v, ky * kz * v - kx * s],
            [kz * kx * v - ky * s, kz * ky * v + kx * s, c + kz * kz * v]]


def cameras_from(trace):
    """(seconds, camera) in the order they took effect: the court recognition updates as it runs,
    so a single camera cannot describe a whole video (2026-11-07)."""
    out = []
    now = 0.0
    for event in trace:
        if 'candidates' in event:
            for value in event['candidates'].values():
                for c in value:
                    now = max(now, float(c.get('time') or 0))
        elif 'update' in event and isinstance(event['update'], dict):
            now = max(now, float(event['update'].get('now') or 0))
        elif 'camera' in event:
            for value in event['camera'].values():
                if value:
                    out.append((now, value))
    return out


def camera_at(cameras, t):
    """The camera in force at time t."""
    chosen = None
    for when, cam in cameras:
        if when <= t:
            chosen = cam
        else:
            break
    return chosen if chosen is not None else (cameras[0][1] if cameras else None)


def candidates_from(trace):
    """decode index -> [(u, v)], the same index the shots use for their frame range."""
    frames = {}
    for event in trace:
        if 'candidates' not in event:
            continue
        for value in event['candidates'].values():
            for c in value:
                frames.setdefault(int(c.get('decodeIndex', 0)), []).append((float(c['u']), float(c['v'])))
    return frames


def projector(cam, shift):
    """shift: metres subtracted from the court x to reach the camera's frame."""
    r = rodrigues(cam['rvec'])
    t, f = cam['tvec'], cam['f']
    cx, cy = cam['principal']

    def project(x_court, y):
        p = (x_court - shift, y, BALL_RADIUS)
        c = [sum(r[i][j] * p[j] for j in range(3)) + t[i] for i in range(3)]
        if c[2] == 0:
            return None
        return (f * c[0] / c[2] + cx, f * c[1] / c[2] + cy)
    return project


def nearest_candidate(frames, u, v, t0, t1):
    best = math.inf
    for index, points in frames.items():
        seconds = index / 60.0
        if not (t0 <= seconds <= t1):
            continue
        for cu, cv in points:
            d = math.hypot(cu - u, cv - v)
            if d < best:
                best = d
    return best


def self_check(frames, run, shift_of, cameras, window=0.35):
    """Fraction of the chain's own landings that have a candidate within 60 px."""
    hits, total = 0, 0
    for row in run:
        bounce = row.get('bounce') or {}
        if bounce.get('yMeters') is None or bounce.get('sourcePTS') is None:
            continue
        total += 1
        cam = camera_at(cameras, bounce['sourcePTS'])
        if cam is None:
            continue
        point = shift_of(cam, bounce['xMeters'], bounce['yMeters'])
        if point is None:
            continue
        t = bounce['sourcePTS']
        if nearest_candidate(frames, point[0], point[1], t - window, t + window) <= 60:
            hits += 1
    return hits, total


def pick_shift(cameras, frames, run):
    """The convention that reproduces the chain's own landings best, or None if none does."""
    best = None
    for shift in (0.0, CENTRE_X):
        def project(cam, x, y, shift=shift):
            return projector(cam, shift)(x, y)
        hits, total = self_check(frames, run, project, cameras)
        rate = hits / total if total else 0.0
        if best is None or rate > best[0]:
            best = (rate, shift, hits, total)
    return best


def teacher_recall(cameras, frames, run, teacher, shift, window=(0.2, 2.6)):
    """Reference landings whose projected point has a candidate within 60 px."""
    def project(cam, x, y):
        return projector(cam, shift)(x, y)
    covered = []
    for row in teacher:
        bounce = row.get('bounce') or {}
        if bounce.get('y') is None or bounce.get('y') >= NET_Y:
            continue
        cam = camera_at(cameras, row['anchor'])
        if cam is None:
            continue
        point = project(cam, bounce['x'] + CENTRE_X, bounce['y'])   # the export's x is from the centre line
        if point is None:
            continue
        t0, t1 = row['anchor'] + window[0], row['anchor'] + window[1]
        covered.append(nearest_candidate(frames, point[0], point[1], t0, t1))
    return covered


def self_test():
    """A camera straight above the court centre, so the arithmetic is checkable by hand."""
    cam = {'rvec': [0.0, math.pi, 0.0], 'tvec': [0.0, 0.0, 10.0], 'f': 500.0, 'principal': [960.0, 540.0]}
    project = projector(cam, CENTRE_X)
    u, v = project(CENTRE_X, 0.0)
    assert abs(u - 960.0) < 1e-6 and abs(v - 540.0) < 1e-6, (u, v)
    u, v = project(CENTRE_X + 1.0, 0.0)
    assert abs(u - 960.0) > 1.0
    assert pick_shift([(0.0, cam)], {0: [(960.0, 540.0)]},
                      [{'bounce': {'xMeters': CENTRE_X, 'yMeters': 0.0, 'sourcePTS': 0.0}}])[0] > 0.99
    assert camera_at([(0.0, cam), (10.0, {'z': 1})], 5.0) is cam
    assert camera_at([(0.0, cam), (10.0, {'z': 1})], 15.0) == {'z': 1}
    assert nearest_candidate({0: [(100.0, 100.0)]}, 100.0, 100.0, -1, 1) == 0.0
    assert nearest_candidate({0: [(100.0, 100.0)]}, 100.0, 100.0, 5, 6) == math.inf
    print('PASS: landing recall projects, self-selects the frame, and windows in time')
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == '--self-test':
        return self_test()
    if len(argv) < 3:
        print(__doc__)
        return 2
    with open(argv[1]) as f:
        trace = json.load(f)
    with open(argv[2]) as f:
        run = json.load(f)
    run = run['events'] if isinstance(run, dict) else run
    cameras = cameras_from(trace)
    if not cameras:
        print('no camera record in the trace')
        return 1
    frames = candidates_from(trace)
    rate, shift, hits, total = pick_shift(cameras, frames, run)
    print(f'self-check: {hits}/{total} of our own landings within 60 px at shift {shift}')
    if rate < 0.6:
        print(f'self-check failed ({rate:.0%}): no convention reproduces our own landings, not reporting')
        return 1
    if len(argv) > 3 and argv[3] == '--teacher':
        with open(argv[4]) as f:
            teacher = json.load(f)['teacher']
        distances = teacher_recall(cameras, frames, run, teacher, shift)
        inside = [d for d in distances if d <= 60]
        print(f'reference landings {len(distances)}, with a candidate within 60 px {len(inside)} '
              f'({100 * len(inside) / max(len(distances), 1):.0f}%)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
