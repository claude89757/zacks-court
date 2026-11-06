#!/usr/bin/env python3
"""Pseudo-labels for TrackNet fine-tuning, from a replay trace (2026-11-07).

The trace keeps a candidate table per frame but nothing that says which candidate joined
which track, and track membership never leaves the engine's memory. So the labels are
reconstructed from the flights the engine accepted: inside an accepted flight's frame
range, take the candidates, fit a robust smooth path through them, and keep the frames
where exactly one candidate sits within `tolerance` of the path.

Usage:
  python3 scripts/tracknet-labels.py TRACE.json REPLAY.json OUT.jsonl [--rms 3] [--tolerance 4]

Output: one JSON object per line, {"t": seconds, "u": x, "v": y, "rms": px, "shot": index}.

Frames with no ball produce no line: a blank frame is not a negative example, it is a
frame where the ball may well be there and the model is expected to stay quiet.
"""
import json
import math
import sys


def load_trace(path):
    """Candidates per frame index, in the order the engine saw them."""
    with open(path) as f:
        events = json.load(f)
    frames = {}
    for event in events:
        if 'candidates' not in event:
            continue
        for value in event['candidates'].values():
            for c in value:
                frames.setdefault(int(c.get('decodeIndex', len(frames))), []).append((float(c['u']), float(c['v'])))
    return frames


def number(value, default):
    """The replay writes non-finite floats as the strings inf and nan."""
    try:
        result = float(value)
    except (TypeError, ValueError):
        return default
    return result if math.isfinite(result) else default


def fit_quadratic(points):
    """Least-squares v = a u^2 + b u + c, solved directly for three unknowns."""
    n = len(points)
    if n < 3:
        return None
    s = [[0.0] * 4 for _ in range(3)]
    for u, v in points:
        row = (u * u, u, 1.0)
        for i in range(3):
            for j in range(3):
                s[i][j] += row[i] * row[j]
            s[i][3] += row[i] * v
    a = [row[:] for row in s]
    for i in range(3):
        pivot = max(range(i, 3), key=lambda r: abs(a[r][i]))
        if abs(a[pivot][i]) < 1e-12:
            return None
        a[i], a[pivot] = a[pivot], a[i]
        for r in range(3):
            if r == i:
                continue
            f = a[r][i] / a[i][i]
            for k in range(i, 4):
                a[r][k] -= f * a[i][k]
    coef = [a[i][3] / a[i][i] for i in range(3)]
    return coef


def path_error(coef, u, v):
    if coef is None:
        return math.inf
    predicted = coef[0] * u * u + coef[1] * u + coef[2]
    return abs(predicted - v)


def labels_for_shot(frames, shot, rms, tolerance):
    first, last = shot.get('firstFrame'), shot.get('lastFrame')
    if first is None or last is None:
        return []
    window = [i for i in range(max(0, first), last + 1) if i in frames]
    pool = []
    for index in window:
        for u, v in frames[index]:
            pool.append((u, v))
    if len(pool) < 8:
        return []
    coef = fit_quadratic(pool)
    if coef is None:
        return []
    # drop the jumps: refit on what the first path explains, then keep frames with one candidate
    kept = [(u, v) for u, v in pool if path_error(coef, u, v) <= tolerance * 2]
    coef = fit_quadratic(kept) or coef
    out = []
    for index in window:
        near = [p for p in frames[index] if path_error(coef, p[0], p[1]) <= tolerance]
        if len(near) != 1:
            continue
        out.append({'frame': index, 'u': round(near[0][0], 2), 'v': round(near[0][1], 2), 'rms': round(rms, 2)})
    return out


def self_test():
    """A clean path plus one jump keeps the path frames and drops the jump."""
    frames = {}
    for i in range(10):
        frames[i] = [(100.0 + 20 * i, 300.0 - 2 * i)]
    frames[4].append((900.0, 100.0))          # a jump in one frame only
    shot = {'accepted': True, 'rmsPx': 2.0, 'firstFrame': 0, 'lastFrame': 9}
    rows = labels_for_shot(frames, shot, 2.0, 4.0)
    kept = {r['frame'] for r in rows}
    assert len(rows) == 9, rows           # the frame with the jump is dropped, not labelled
    assert 4 not in kept, 'the ambiguous frame must not be labelled'
    assert all(abs(r['u'] - (100 + 20 * r['frame'])) < 1e-6 for r in rows), rows
    assert labels_for_shot({}, shot, 2.0, 4.0) == []
    assert number('inf', 99) == 99 and number('nan', 99) == 99 and number(2.5, 99) == 2.5
    print('PASS: tracknet labels keep the fitted path, skip ambiguous frames, read inf/nan')
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == '--self-test':
        return self_test()
    if len(argv) < 4:
        print(__doc__)
        return 2
    trace, replay, out_path = argv[1], argv[2], argv[3]
    rms_limit = 3.0
    tolerance = 4.0
    for i, arg in enumerate(argv):
        if arg == '--rms' and i + 1 < len(argv):
            rms_limit = float(argv[i + 1])
        if arg == '--tolerance' and i + 1 < len(argv):
            tolerance = float(argv[i + 1])
    frames = load_trace(trace)
    with open(replay) as f:
        shots = json.load(f)['shots']
    written = 0
    with open(out_path, 'w') as out:
        for index, shot in enumerate(shots):
            if not shot.get('accepted') or number(shot.get('rmsPx'), 99) > rms_limit:
                continue
            for row in labels_for_shot(frames, shot, number(shot.get('rmsPx'), 99), tolerance):
                out.write(json.dumps({'t': round(row['frame'] / 60.0, 4), 'u': row['u'], 'v': row['v'],
                                      'rms': row['rms'], 'shot': index}) + '\n')
                written += 1
    print(f'labels {written} from {sum(1 for s in shots if s.get("accepted"))} accepted shots')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
