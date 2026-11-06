#!/usr/bin/env python3
"""Score one in-house run against one reference export, with the metrics this project uses.

    python3 scripts/score-run.py REF.json RUN.json [--format singles|doubles] [--json OUT] [--self-test]

REF is the reference analysis export in the local teacher shape:
    {"teacher": [{"anchor", "stroke", "speed", "result", "bounce": {"x", "y"}, "hit": {"x", "y", "z"}}, ...]}
with the reference's time already rebased onto the video the run analysed (the exports this project has seen
run two seconds behind the recording, so anchor = video time + 2). `result` is 界内/出界 for a judged shot and
anything else (下网, ...) for one with no line call. Coordinates are metres, x centred on the court's long
axis, y from the near baseline.

RUN is `court-analyze independent-live` or `independent-replay` output: {"events": [{"sourcePTS", "stroke",
"speedKPH", "bounce": {"xMeters", "yMeters"}, "hit": {...}}, ...]}.

The reference is a software reference, not truth: agreement with it says how close the two systems are, not
how accurate either one is.

  rows       reference rows matched to a run row (nearest within 0.3 s) out of all reference rows
  strokes    agreement where both sides name a class, next to the always-forehand baseline on the same pairs
  serves     precision, recall and F1 over the reference's serve rows
  speeds     pairs where both sides have a speed: mean absolute percentage error, within 20 percent, ratio
  bounces    our bounce against the reference's over the same pairs: median and mean absolute error
  near side  the reference's near-half line calls: rows found, judgements given, verdicts agreed, and why the
             rest have none (`no row`, `no bounce`, `same half`, `no call`), plus our calls with no reference

`HawkEye.judge` is ported here exactly as `pair.py` does it, so the two scorers agree. Standard library only.
"""
import argparse
import json
import math
import statistics
import sys

NET, LEN, CENTRE, SINGLES, SERVICE, CENTRE_LINE, BALL = 11.885, 23.77, 5.485, 4.115, 6.40, 0.025, 0.033
ROW_TOL, CALL_TOL = 0.3, 0.7
CALL = {'界内': 'in', '出界': 'out'}
CLASS = {'发球': 'serve', '正手': 'forehand', '反手': 'backhand', '正手 截击': 'volley', '反手 截击': 'volley'}


def judge(x, y, sx, sy, serve, server_x, fmt):
    """HawkEye.judge on a bounce in court coordinates (x from the near-left doubles sideline)."""
    if x is None or y is None or not (math.isfinite(x) and math.isfinite(y)):
        return None
    far = y > NET
    cx = x - CENTRE
    hw = SINGLES if (serve or fmt == 'singles') else CENTRE
    x0, x1, l0, l1 = -hw, hw, 'sideline', 'sideline'
    if serve:
        y0, y1 = (NET, NET + SERVICE) if far else (NET - SERVICE, NET)
        if server_x is not None and abs(server_x - CENTRE) >= 0.3:
            if server_x < CENTRE:
                x0, l0 = -CENTRE_LINE, 'centreLine'
            else:
                x1, l1 = CENTRE_LINE, 'centreLine'
    else:
        y0, y1 = (NET, LEN) if far else (0, NET)
    base = 'serviceLine' if serve else 'baseline'
    edges = [(x0 - cx, l0, True), (cx - x1, l1, True), ((y - y1) if far else (y0 - y), base, False)]
    dx = max(0, x0 - cx, cx - x1)
    dy = max(0, max(d for d, _, vertical in edges if not vertical))
    nearest = max(edges, key=lambda e: e[0])
    if dx > 0 or dy > 0:
        outside = math.hypot(dx, dy)
        sigma = max(sx or 0, sy or 0) if (dx > 0 and dy > 0) else (sx if nearest[2] else sy)
    else:
        outside = nearest[0]
        sigma = sx if nearest[2] else sy
    signed = outside - BALL
    margin = max(0.03, 2 * sigma) if sigma is not None else 0.15
    call = 'close' if abs(signed) < margin else ('out' if signed > 0 else 'in')
    return {'call': call, 'd': signed, 'margin': margin, 'line': nearest[1], 'far': far}


def annotate(event, fmt):
    """HawkEye.annotate for one row: the judgement, or why there is none."""
    b = event.get('bounce') or {}
    x, y = b.get('xMeters'), b.get('yMeters')
    if x is None or y is None:
        return None, 'no bounce'
    j = judge(x, y, b.get('sigmaXMeters'), b.get('sigmaYMeters'), event.get('stroke') == 'serve',
              (event.get('hit') or {}).get('x'), fmt)
    if j is None:
        return None, 'no bounce'
    hy = (event.get('hit') or {}).get('y')
    if hy is not None and (hy > NET) == (y > NET):
        return None, 'same half'
    return j, None


def read_events(path):
    with open(path) as f:
        d = json.load(f)
    rows = d['events'] if isinstance(d, dict) else d
    clean = []
    for row in rows:
        row = dict(row)
        for key in ('hit', 'bounce'):
            part = dict(row.get(key) or {})
            for field, value in list(part.items()):
                if isinstance(value, str) and field not in ('reason', 'reasonCode'):
                    part[field] = None
            row[key] = part
        clean.append(row)
    return clean


def nearest(rows, t, used, tol):
    best, distance = None, None
    for i, row in enumerate(rows):
        if i in used:
            continue
        d = abs((row.get('sourcePTS') or 0) - t)
        if d <= tol and (distance is None or d < distance):
            best, distance = i, d
    return best


def score(teacher, run, fmt):
    out = {}
    judged = [r for r in teacher if r.get('anchor') is not None]
    used, matched, known, agree, forehand = set(), 0, 0, 0, 0
    for row in judged:
        i = nearest(run, row['anchor'], used, ROW_TOL)
        if i is None:
            continue
        used.add(i)
        matched += 1
        want, got = CLASS.get(row.get('stroke')), run[i].get('stroke')
        if want and got in ('serve', 'forehand', 'backhand', 'volley'):
            known += 1
            agree += want == got
            forehand += got == 'forehand'
    out['rows'] = {'reference': len(judged), 'run': len(run), 'matched': matched,
                   'share': round(matched / len(judged), 4) if judged else None}
    out['strokes'] = {'both_known': known, 'agree': agree, 'agreement': round(agree / known, 4) if known else None,
                      'always_forehand': round(forehand / known, 4) if known else None}

    serves = [r for r in judged if r.get('stroke') == '发球']
    ours = [e for e in run if e.get('stroke') == 'serve']
    taken, hit = set(), 0
    for row in serves:
        i = nearest(ours, row['anchor'], taken, ROW_TOL)
        if i is not None:
            taken.add(i)
            hit += 1
    p = hit / len(ours) if ours else None
    r = hit / len(serves) if serves else None
    f1 = 2 * p * r / (p + r) if p and r else None
    out['serves'] = {'reference': len(serves), 'run': len(ours), 'matched': hit,
                     'precision': round(p, 4) if p else p, 'recall': round(r, 4) if r else r,
                     'f1': round(f1, 4) if f1 else f1}

    errors, ratios, dx, dy = [], [], [], []
    for row in judged:
        if row.get('speed') in (None, 0):
            continue
        i = nearest(run, row['anchor'], set(), ROW_TOL)
        if i is None or run[i].get('speedKPH') is None:
            continue
        errors.append(abs(run[i]['speedKPH'] - row['speed']) / row['speed'])
        ratios.append(run[i]['speedKPH'] / row['speed'])
        b, rb = run[i].get('bounce') or {}, row.get('bounce') or {}
        if b.get('xMeters') is not None and rb.get('x') is not None:
            dx.append(b['xMeters'] - CENTRE - rb['x'])
        if b.get('yMeters') is not None and rb.get('y') is not None:
            dy.append(b['yMeters'] - rb['y'])
    out['speeds'] = {'pairs': len(errors),
                     'mape': round(statistics.mean(errors), 4) if errors else None,
                     'median': round(statistics.median(errors), 4) if errors else None,
                     'within_20': sum(1 for e in errors if e <= 0.2),
                     'ratio_median': round(statistics.median(ratios), 4) if ratios else None}
    def spread(v):
        if not v:
            return None
        return {'median': round(statistics.median(v), 3),
                'mean_abs': round(sum(abs(a) for a in v) / len(v), 3), 'n': len(v)}
    out['bounces'] = {'x': spread(dx), 'y': spread(dy)}

    calls = [r for r in judged if r.get('result') in CALL
             and (r.get('bounce') or {}).get('y') is not None and r['bounce']['y'] < NET]
    used, verdicts, agree, reasons = set(), 0, 0, {}
    for row in calls:
        i = nearest(run, row['anchor'], used, CALL_TOL)
        if i is None:
            reasons['no row'] = reasons.get('no row', 0) + 1
            continue
        used.add(i)
        j, why = annotate(run[i], fmt)
        if j is None or j['far']:
            key = why or 'no call'
            reasons[key] = reasons.get(key, 0) + 1
            continue
        verdicts += 1
        agree += j['call'] == CALL[row['result']]
    extra = 0
    for i, row in enumerate(run):
        if i in used:
            continue
        j, _ = annotate(row, fmt)
        if j is not None and not j['far']:
            extra += 1
    out['near'] = {'reference': len(calls), 'judged': verdicts, 'agree': agree,
                   'agreement_of_judged': round(agree / verdicts, 4) if verdicts else None,
                   'coverage': round(verdicts / len(calls), 4) if calls else None,
                   'not_judged': reasons, 'unreferenced_calls': extra}
    return out


def report(s):
    rows, st, sv, sp, bo, nr = s['rows'], s['strokes'], s['serves'], s['speeds'], s['bounces'], s['near']
    def pct(v):
        return 'n/a' if v is None else f'{v * 100:.1f}%'
    def num(v, digits=2):
        return 'n/a' if v is None else f'{v:.{digits}f}'
    print(f"rows      : reference {rows['reference']}, run {rows['run']}, matched {rows['matched']} ({pct(rows['share'])})")
    if st['both_known']:
        print(f"strokes   : agree {st['agree']}/{st['both_known']} ({pct(st['agreement'])}); "
              f"always forehand {pct(st['always_forehand'])}")
    print(f"serves    : reference {sv['reference']}, run {sv['run']}, matched {sv['matched']}; "
          f"P {num(sv['precision'])} R {num(sv['recall'])} F1 {num(sv['f1'])}")
    if sp['pairs']:
        print(f"speeds    : {sp['pairs']} pairs, MAPE {pct(sp['mape'])}, median {pct(sp['median'])}, "
              f"within 20% {sp['within_20']}, ratio median {num(sp['ratio_median'], 3)}")
    else:
        print('speeds    : no pairs')
    for axis, key in (('x', 'x'), ('y', 'y')):
        b = bo[key]
        if b:
            print(f"bounces {axis} : {b['n']} pairs, median {num(b['median'])} m, mean absolute {num(b['mean_abs'])} m")
    print(f"near side : reference {nr['reference']}, judged {nr['judged']} ({pct(nr['coverage'])}), "
          f"agree {nr['agree']} ({pct(nr['agreement_of_judged'])} of judged), "
          f"unreferenced calls {nr['unreferenced_calls']}")
    if nr['not_judged']:
        print('            not judged: ' + ', '.join(f'{k} {v}' for k, v in sorted(nr['not_judged'].items())))


def self_test():
    teacher = [{'anchor': t, 'stroke': stroke, 'speed': speed, 'result': result,
                'bounce': {'x': bx, 'y': by}, 'hit': {'x': 0.0, 'y': hy, 'z': 1.0}}
               for t, stroke, speed, result, bx, by, hy in [
                   (1.0, '发球', 100.0, '界内', 0.0, 6.5, 24.0),
                   (5.0, '正手', 80.0, '出界', 4.5, 3.0, 24.0),
                   (9.0, '反手', None, '下网', 1.0, 16.0, 24.0)]]
    run = [{'sourcePTS': 1.1, 'stroke': 'serve', 'speedKPH': 110.0,
            'bounce': {'xMeters': CENTRE + 0.1, 'yMeters': 6.5}, 'hit': {'x': CENTRE, 'y': 24.0}},
           {'sourcePTS': 5.2, 'stroke': 'forehand', 'speedKPH': None,
            'bounce': {'xMeters': CENTRE + 4.5, 'yMeters': 3.0}, 'hit': {'x': CENTRE, 'y': 24.0}},
           {'sourcePTS': 12.0, 'stroke': 'backhand', 'speedKPH': None,
            'bounce': {'xMeters': CENTRE + 1.0, 'yMeters': 2.0}, 'hit': {'x': CENTRE, 'y': 24.0}}]
    s = score(teacher, run, 'singles')
    checks = [
        (s['rows']['matched'] == 2, 'two rows within the tolerance'),
        (s['strokes']['both_known'] == 2 and s['strokes']['agree'] == 2, 'both strokes agree'),
        (s['serves']['reference'] == 1 and s['serves']['matched'] == 1, 'the serve pairs'),
        (s['speeds']['pairs'] == 1 and abs(s['speeds']['mape'] - 0.1) < 1e-9, 'speed error is 10 percent'),
        (abs(s['bounces']['x']['median'] - 0.1) < 1e-9, 'bounce x is the centred difference'),
        (s['near']['reference'] == 2 and s['near']['judged'] == 2 and s['near']['agree'] == 2, 'both near calls agree'),
        (s['near']['unreferenced_calls'] == 1, 'the unpaired near row is an unreferenced call'),
    ]
    bad = [name for ok, name in checks if not ok]
    for ok, name in checks:
        print(('ok   ' if ok else 'FAIL ') + name)
    if bad:
        print('self-test failed: ' + ', '.join(bad))
        return 1
    print('self-test passed')
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description='Score an in-house run against a reference export.')
    ap.add_argument('teacher', nargs='?')
    ap.add_argument('run', nargs='?')
    ap.add_argument('--format', default='singles', choices=('singles', 'doubles'))
    ap.add_argument('--json')
    ap.add_argument('--self-test', action='store_true')
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.teacher or not args.run:
        ap.error('REF.json and RUN.json are required')
    with open(args.teacher) as f:
        d = json.load(f)
    teacher = d['teacher'] if isinstance(d, dict) else d
    s = score(teacher, read_events(args.run), args.format)
    report(s)
    if args.json:
        with open(args.json, 'w') as f:
            json.dump(s, f, ensure_ascii=False, indent=1)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
