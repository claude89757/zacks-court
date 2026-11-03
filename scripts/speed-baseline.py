#!/usr/bin/env python3
"""Small, deliberately unqualified visual diagnostic against teacher software targets.

No ball tracking, physical speed measurement, automatic event detection, or model
promotion is implemented. NumPy/Pillow are the only nonstandard dependencies.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import io
import json
from pathlib import Path
import platform
import sys

import numpy as np
import PIL
from PIL import Image

SEED = 20261028
LAMBDAS = (1., 10., 100.)
OFFSETS = tuple(Fraction(1, 10) + Fraction(k, 5) for k in range(8))
REGIONS = ('global',) + tuple(f'grid{r}{c}' for r in range(3) for c in range(3))
MOTION_NAMES = tuple(f'motion_{r}_{s}' for r in REGIONS for s in ('mean_rate', 'p90_rate'))
APPEARANCE_NAMES = tuple(f'appearance_{r}_{s}' for r in REGIONS for s in ('mean', 'p90'))
LIMITATIONS = [
    'Teacher-window-conditioned visual signal diagnostic only; windows are located by teacher software events (oracle-event limitation), not automatic end-to-end detection.',
    'Targets are unreviewed teacher software pseudo-labels; differences are not physical accuracy, calibration, verified contact timing, or successful formal training.',
    'Global/grid image changes include players, camera motion and scene appearance; these are not ball trajectories or ball velocities.',
    'Only one declared source family per outer split; source/scene confounding and singles-to-doubles domain shift remain. Declared families do not prove independent filming sessions.',
    'Internal CV groups whole selected rallies and transitive overlapping windows within the one training source; it cannot estimate unseen-source performance.',
    'Only the preselected 80 review windows are covered; no conclusion covers all 223 events, unseen events, real phone capture or court accuracy.',
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def now():
    return datetime.now(timezone.utc).isoformat()


def components(samples):
    """Union of whole rally identity AND actual interval overlaps; input-order stable."""
    ordered = sorted(samples, key=lambda s: s['shot_id'])
    parent = list(range(len(ordered)))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(ordered):
        for j in range(i):
            b = ordered[j]
            same_source = a['source_sha256'] == b['source_sha256']
            rally = a['rally_group'] == b['rally_group']
            overlap = (a['window_start_pts_seconds'] < b['window_end_pts_seconds'] and
                       b['window_start_pts_seconds'] < a['window_end_pts_seconds'])
            if same_source and (rally or overlap):
                parent[root(i)] = root(j)
    members = defaultdict(list)
    for i, s in enumerate(ordered):
        members[root(i)].append(s['shot_id'])
    return {sid: 'component-' + digest(ids)[:20]
            for ids in members.values() for sid in ids}


def assert_split_isolation(samples, splits, groups):
    for key in ('source_sha256', 'source_family', 'rally_group', 'overlap_group'):
        seen = defaultdict(set)
        for sample in samples:
            seen[sample[key]].add(splits[sample['shot_id']])
        require(all(len(x) == 1 for x in seen.values()), f'{key} crosses outer split')
    seen = defaultdict(set)
    for sample in samples:
        seen[groups[sample['shot_id']]].add(splits[sample['shot_id']])
    require(all(len(x) == 1 for x in seen.values()), 'connected rally/window group crosses split')


def folds_for(samples, groups):
    ids = sorted({groups[s['shot_id']] for s in samples},
                 key=lambda g: digest([SEED, g]))
    require(len(ids) >= 3, 'At least three training components required')
    nfold = min(5, len(ids))
    assigned = {g: i % nfold for i, g in enumerate(ids)}
    return {s['shot_id']: assigned[groups[s['shot_id']]] for s in samples}


def regions(array):
    yield array
    for rows in np.array_split(array, 3, axis=0):
        yield from np.array_split(rows, 3, axis=1)


def stats(array):
    return np.array([v for r in regions(array) for v in (np.mean(r), np.quantile(r, .9))])


def select_pairs(frames):
    times = [Fraction(f['source_pts']) * Fraction(f['source_time_base']) for f in frames]
    require(len(times) >= 2 and all(b > a for a, b in zip(times, times[1:])), 'Non-increasing/missing actual PTS')
    pairs = []
    for offset in OFFSETS:
        candidates = [i for i in range(len(times) - 1) if times[i] >= times[0] + offset]
        require(candidates, 'Window cannot cover fixed relative pair offsets')
        i = candidates[0]
        dt = times[i+1] - times[i]
        require(0 < dt <= Fraction(1, 20), 'Selected adjacent pair has invalid/gapped actual dt')
        pairs.append((i, i+1, dt))
    require(len({a for a, _, _ in pairs}) == len(OFFSETS), 'Pair selection reused timestamps')
    return pairs


def load_gray(data, metadata):
    with Image.open(io.BytesIO(data)) as image:
        require(image.size == (metadata['width'], metadata['height']), 'Frame dimensions mismatch')
        image = image.convert('L')
        image.thumbnail((160, 90), Image.Resampling.BILINEAR)
        require(image.width >= 3 and image.height >= 3, 'Frame too small')
        return np.asarray(image, dtype=np.float64) / 255.


def feature_vector(record, names):
    # Explicit whitelist: no metadata, teacher event values, identity or targets.
    require(tuple(record.keys()) == names, 'Feature whitelist/order mismatch')
    x = np.array([record[n] for n in names], dtype=np.float64)
    require(np.isfinite(x).all(), 'Non-finite feature')
    return x


def extract(package, sample, blind):
    frames = blind['frames']
    expected_count = sample['extraction']['decoded_frame_count']
    require(len(frames) == expected_count, 'Frame count mismatch')
    require(digest([f['source_pts'] for f in frames]) == sample['extraction']['ffprobe_window_pts_sha256'], 'PTS digest mismatch')
    pairs = select_pairs(frames)
    needed = {0} | {i for a, b, _ in pairs for i in (a, b)}
    decoded = {}
    # Verify EVERY JPEG, including unused images; never silently discard samples.
    directory = package / 'samples' / sample['review_id']
    require({p.name for p in directory.glob('*.jpg')} == {f['filename'] for f in frames}, 'JPEG inventory mismatch')
    for i, frame in enumerate(frames):
        name = frame['filename']
        require(Path(name).name == name, 'Unsafe image path')
        data = (directory / name).read_bytes()
        require(hashlib.sha256(data).hexdigest() == frame['sha256'], 'JPEG digest mismatch')
        exact = Fraction(frame['source_pts']) * Fraction(frame['source_time_base'])
        require(exact == Fraction(frame['source_pts_seconds_rational']), 'Rational PTS mismatch')
        if i in needed:
            decoded[i] = load_gray(data, frame)
    motion = np.mean([stats(np.abs(decoded[b] - decoded[a]) / float(dt)) for a, b, dt in pairs], axis=0)
    appearance = stats(decoded[0])
    result = {'motion': dict(zip(MOTION_NAMES, motion.tolist())),
              'appearance': dict(zip(APPEARANCE_NAMES, appearance.tolist()))}
    for kind, names in [('motion', MOTION_NAMES), ('appearance', APPEARANCE_NAMES)]:
        feature_vector(result[kind], names)
    result['pair_audit_not_model_input'] = [
        {'frame_indices': [a, b], 'actual_dt_seconds': float(dt), 'actual_dt_rational': str(dt)}
        for a, b, dt in pairs]
    result['verified_frame_count'] = len(frames)
    return result


def fit_ridge(x, y, lam):
    require(np.isfinite(x).all() and np.isfinite(y).all(), 'Non-finite fit values')
    mean = x.mean(axis=0)
    scale = x.std(axis=0)
    scale = np.where(scale > 1e-12, scale, 1.)
    z = (x - mean) / scale
    intercept = float(y.mean())
    coef = np.linalg.solve(z.T @ z + lam * np.eye(x.shape[1]), z.T @ (y - intercept))
    return {'mean': mean, 'scale': scale, 'coef': coef, 'intercept': intercept, 'lambda': lam}


def predict(model, x):
    result = (x - model['mean']) / model['scale'] @ model['coef'] + model['intercept']
    require(np.isfinite(result).all(), 'Non-finite prediction')
    return result


def score(y, pred):
    difference = pred - y
    return {'sample_count': len(y), 'MAE_kmh': float(np.mean(np.abs(difference))),
            'medianAE_kmh': float(np.median(np.abs(difference))),
            'P95AE_kmh': float(np.quantile(np.abs(difference), .95)),
            'bias_kmh': float(np.mean(difference))}


def select_lambda(x, y, fold):
    records = []
    for lam in LAMBDAS:
        pred = np.empty_like(y)
        for f in sorted(set(fold)):
            train, valid = fold != f, fold == f
            pred[valid] = predict(fit_ridge(x[train], y[train], lam), x[valid])
        records.append({'lambda': lam, 'teacher_software_difference_grouped_cv': score(y, pred)})
    chosen = min(records, key=lambda r: (r['teacher_software_difference_grouped_cv']['MAE_kmh'], r['lambda']))['lambda']
    return chosen, records


def require_eligible(rows, diagnostic):
    if not diagnostic:
        require(all(r.get('training_eligible') is True and r.get('review', {}).get('status') == 'approved' for r in rows),
                'Formal fit refused: unreviewed/ineligible rows; only explicit --diagnostic-unreviewed permits this unqualified diagnostic')


def self_test():
    tests = []

    def check(name, fn):
        fn()
        tests.append(name)

    def linear():
        x = np.arange(60., dtype=float).reshape(30, 2)[:, :1]
        y = 3 * x[:, 0] + 7
        require(np.max(np.abs(predict(fit_ridge(x, y, 1e-10), x) - y)) < 1e-7, 'linear recovery failed')
    check('known_linear_ridge_recovery', linear)

    def whitelist():
        good = dict.fromkeys(MOTION_NAMES, 1.)
        feature_vector(good, MOTION_NAMES)
        try:
            feature_vector({**good, 'teacher_speed_kmh': 99.}, MOTION_NAMES)
        except ValueError:
            return
        raise AssertionError('leakage accepted')
    check('feature_whitelist_rejects_target_metadata', whitelist)

    def scaling():
        x = np.array([[0.], [2.]])
        m = fit_ridge(x, np.array([1., 3.]), 1.)
        predict(m, np.array([[1e9]]))
        require(m['mean'][0] == 1 and m['scale'][0] == 1, 'validation changed scaler')
    check('validation_never_fits_scaler', scaling)

    samples = [dict(shot_id=f'id-{i}', source_sha256='a', source_family='a',
                    rally_group=f'r-{i//2}', overlap_group=f'o-{i}',
                    window_start_pts_seconds=float(i), window_end_pts_seconds=float(i)+1.1) for i in range(6)]
    def group_order():
        a, b = components(samples), components(list(reversed(samples)))
        require(a == b and len(set(a.values())) == 1, 'transitive/order grouping failed')
    check('transitive_rally_overlap_and_shuffle_determinism', group_order)

    def split_refusal():
        try:
            assert_split_isolation(samples, {s['shot_id']: str(i % 2) for i, s in enumerate(samples)}, components(samples))
        except ValueError:
            return
        raise AssertionError('source overlap split accepted')
    check('source_rally_overlap_split_rejected', split_refusal)

    def default_refusal():
        row = {'training_eligible': False, 'review': {'status': 'pending'}}
        require_eligible([row], True)
        try:
            require_eligible([row], False)
        except ValueError:
            return
        raise AssertionError('unreviewed formal fit accepted')
    check('unreviewed_formal_fit_default_refusal', default_refusal)

    def time_test():
        frames = [{'source_pts': i, 'source_time_base': '1/50'} for i in range(100)]
        pairs = select_pairs(frames)
        require(all(dt == Fraction(1, 50) for _, _, dt in pairs), 'fake fps time used')
        frames[6]['source_pts'] = frames[5]['source_pts']
        try:
            select_pairs(frames)
        except ValueError:
            return
        raise AssertionError('duplicate PTS accepted')
    check('actual_pts_pair_timing_and_invalid_pts_refusal', time_test)

    def deterministic_cv():
        s = [dict(v, window_end_pts_seconds=float(i)+.5, rally_group=f'r{i}') for i, v in enumerate(samples)]
        g = components(s)
        require(folds_for(s, g) == folds_for(list(reversed(s)), g), 'shuffled folds differ')
    check('shuffled_cv_assignment_determinism', deterministic_cv)
    return {'passed': len(tests), 'failed': 0, 'skipped': 0, 'tests': tests}


def run(args):
    package, dataset, output = args.review_package.resolve(), args.dataset.resolve(), args.output.resolve()
    require(not output.exists(), 'Output exists; refusing to overwrite an experiment')
    output.mkdir(parents=True)
    started = now()
    try:
        tests = self_test()
        write_json(output / 'self-test.json', tests)
        manifest_path, shots_path = dataset / 'manifest.json', dataset / 'shots.jsonl'
        receipt_path, blind_path = package / 'audit/selection_receipt.json', package / 'blind-data.json'
        dm, receipt = json.loads(manifest_path.read_text()), json.loads(receipt_path.read_text())
        hashes = {str(p): sha(p) for p in (manifest_path, shots_path, receipt_path, blind_path)}
        require(receipt['status'] == 'complete', 'Incomplete review extraction')
        for p in (manifest_path, shots_path):
            require(hashes[str(p)] == receipt['dataset_sha256'][p.name], 'Dataset receipt digest mismatch')
        require(hashes[str(shots_path)] == dm['artifacts']['shots.jsonl']['sha256'], 'Dataset manifest digest mismatch')
        require(hashes[str(blind_path)] == receipt['artifacts']['blind-data.json'], 'Blind data digest mismatch')
        sources = {s['source_sha256']: s for s in dm['sources']}
        samples = sorted(receipt['samples'], key=lambda s: s['shot_id'])
        require(len(samples) == 80 and len({s['shot_id'] for s in samples}) == 80, 'Expected exactly 80 unique samples')
        splits = {s['shot_id']: sources[s['source_sha256']]['split'] for s in samples}
        require(Counter(splits.values()) == Counter(train=35, validation=45), 'Expected frozen 35/45 split')
        groups = components(samples)
        assert_split_isolation(samples, splits, groups)
        train_samples = [s for s in samples if splits[s['shot_id']] == 'train']
        folds = folds_for(train_samples, groups)
        # This frozen record MUST be durable before parsing any target row.
        protocol = {'schema_version': 1, 'created_at': started, 'script_sha256': sha(Path(__file__)),
                    'input_sha256': hashes, 'diagnostic_unreviewed': args.diagnostic_unreviewed,
                    'production': False, 'training_qualified': False, 'limitations': LIMITATIONS,
                    'features': {'gray': 'Pillow L /255; aspect-preserving bilinear thumbnail <=160x90',
                                 'pair_selection': 'For each fixed offset from first actual PTS, first frame at/after offset paired with its immediate actual-PTS successor; require 0<dt<=0.05s',
                                 'offsets_seconds_rational': [str(o) for o in OFFSETS],
                                 'motion': 'absolute grayscale pixel difference / actual dt; global plus 3x3 grid pixel mean/p90; arithmetic mean across eight pairs',
                                 'appearance': 'first decoded frame grayscale global plus 3x3 grid mean/p90',
                                 'motion_names': MOTION_NAMES, 'appearance_names': APPEARANCE_NAMES,
                                 'excluded': ['teacher fields', 'absolute PTS', 'source identity', 'filename', 'worksheet row', 'event duration', 'frame count', 'pair dt as standalone feature']},
                    'ridge_objective': 'sum((y-Xstandardized*w-intercept)^2) + lambda*sum(w^2); unpenalized mean-y intercept; population std fit on each training fold only',
                    'lambda_grid': LAMBDAS, 'cv_seed': SEED, 'cv_objective': 'pooled held-out grouped-CV MAE; tie chooses smaller lambda',
                    'cv_folds': folds, 'connected_groups': groups,
                    'split_ids': {name: sorted(sid for sid, split in splits.items() if split == name) for name in ('train', 'validation')},
                    'validation_policy': 'One frozen evaluation per specified estimator/control; no feature, split, lambda or seed changes after validation results',
                    'constant_baseline': 'training-target median', 'permutation_control': {'seed': SEED, 'count': 20, 'policy': 'Permute training labels only; reuse each estimator selected lambda, no validation selection'},
                    'metrics': ['teacher_software_difference MAE', 'medianAE', 'P95AE', 'bias', 'coverage', 'per-source'],
                    'confidence_intervals': 'None; 45 windows from one validation source do not establish independent-session uncertainty'}
        write_json(output / 'protocol.json', protocol)
        print('Protocol frozen; parsing targets only after protocol.json exists.', flush=True)
        rows = [json.loads(line) for line in shots_path.read_text().splitlines() if line]
        require_eligible(rows, args.diagnostic_unreviewed)
        by_id = {r['shot_id']: r for r in rows}
        require(len(by_id) == len(rows), 'Duplicate dataset shot identity')
        for s in samples:
            row = by_id[s['shot_id']]
            require(row['source_sha256'] == s['source_sha256'] and row['group_id'] == s['source_family'] and row['split'] == splits[s['shot_id']], 'Selection/dataset identity mismatch')
            require(row['context']['set'] == s['context']['set'] and row['context']['game'] == s['context']['game'] and row['context']['point'] == s['context']['point'], 'Rally identity mismatch')
            require(row['speed_target_valid'] is True and np.isfinite(row['speed_target_kmh']), 'Invalid teacher target; refusing full run without dropping rows')
        blind = json.loads(blind_path.read_text())
        require(blind['package_id'] == receipt['package_id'], 'Package identity mismatch')
        frames_by_id = {s['review_id']: s for s in blind['samples']}
        require(len(frames_by_id) == 80, 'Blind sample count mismatch')
        feature_rows = []
        with (output / 'features.jsonl').open('x') as f:
            for i, s in enumerate(samples):
                values = extract(package, s, frames_by_id[s['review_id']])
                rec = {'shot_id': s['shot_id'], 'review_id': s['review_id'], 'split': splits[s['shot_id']],
                       'identity_not_model_input': {'source_family': s['source_family'], 'connected_group': groups[s['shot_id']], 'rally_group': s['rally_group']}, **values}
                f.write(canonical(rec) + '\n')
                feature_rows.append(rec)
                if (i+1) % 10 == 0:
                    print(f'Verified/extracted {i+1}/80 windows, {sum(r["verified_frame_count"] for r in feature_rows)} JPEG digests.', flush=True)
        train_mask = np.array([r['split'] == 'train' for r in feature_rows])
        validation_mask = ~train_mask
        y_train = np.array([by_id[r['shot_id']]['speed_target_kmh'] for r in feature_rows if r['split'] == 'train'])
        fold = np.array([folds[r['shot_id']] for r in feature_rows if r['split'] == 'train'])
        models, all_predictions, cv = {}, {}, {}
        # Fit and freeze final estimators and all controls before materializing validation y.
        for kind, names in [('motion', MOTION_NAMES), ('appearance', APPEARANCE_NAMES)]:
            x = np.stack([feature_vector(r[kind], names) for r in feature_rows])
            lam, cv[kind] = select_lambda(x[train_mask], y_train, fold)
            model = fit_ridge(x[train_mask], y_train, lam)
            models[kind] = {'feature_names': names, **{k: v.tolist() if isinstance(v, np.ndarray) else v for k, v in model.items()}}
            all_predictions[kind] = predict(model, x[validation_mask])
            rng = np.random.default_rng(SEED)
            all_predictions[kind + '_permutations'] = [predict(fit_ridge(x[train_mask], rng.permutation(y_train), lam), x[validation_mask]) for _ in range(20)]
        all_predictions['train_median_constant'] = np.full(45, np.median(y_train))
        write_json(output / 'model.json', {'production': False, 'training_qualified': False, 'models': models, 'constant_training_median_kmh': float(np.median(y_train))})
        write_json(output / 'cv.json', {'teacher_software_difference_grouped_cv': cv})
        y_validation = np.array([by_id[r['shot_id']]['speed_target_kmh'] for r in feature_rows if r['split'] == 'validation'])
        metrics = {'production': False, 'training_qualified': False, 'diagnostic_unreviewed': True, 'limitations': LIMITATIONS,
                   'coverage': {'selected': 80, 'extracted': 80, 'rejected': 0, 'train': 35, 'validation': 45, 'verified_jpegs': sum(r['verified_frame_count'] for r in feature_rows), 'all_dataset_rows': len(rows)},
                   'training_connected_group_count': len(set(groups[s['shot_id']] for s in train_samples)),
                   'teacher_software_difference_validation': {}, 'teacher_software_difference_by_source': {}}
        val_rows = [r for r in feature_rows if r['split'] == 'validation']
        for name, pred in all_predictions.items():
            if name.endswith('_permutations'):
                records = [score(y_validation, p) for p in pred]
                metrics['teacher_software_difference_validation'][name] = {'runs': records, 'mean_MAE_kmh': float(np.mean([r['MAE_kmh'] for r in records])), 'min_MAE_kmh': min(r['MAE_kmh'] for r in records), 'max_MAE_kmh': max(r['MAE_kmh'] for r in records)}
            else:
                metrics['teacher_software_difference_validation'][name] = score(y_validation, pred)
                for source in sorted({r['identity_not_model_input']['source_family'] for r in val_rows}):
                    m = np.array([r['identity_not_model_input']['source_family'] == source for r in val_rows])
                    metrics['teacher_software_difference_by_source'].setdefault(source, {})[name] = score(y_validation[m], pred[m])
        baseline_mae = metrics['teacher_software_difference_validation']['train_median_constant']['MAE_kmh']
        metrics['better_than_constant_validation_MAE'] = {kind: metrics['teacher_software_difference_validation'][kind]['MAE_kmh'] < baseline_mae for kind in ('motion', 'appearance')}
        write_json(output / 'metrics.json', metrics)
        with (output / 'predictions.jsonl').open('x') as f:
            for i, row in enumerate(val_rows):
                f.write(canonical({'shot_id': row['shot_id'], 'review_id': row['review_id'], 'teacher_target_kmh': float(y_validation[i]),
                                   'predictions_kmh': {k: float(v[i]) for k, v in all_predictions.items() if not k.endswith('_permutations')}}) + '\n')
        # Reject concurrent input edits; leave failed-run artifacts for audit.
        require(all(sha(Path(p)) == h for p, h in hashes.items()), 'Input changed during run')
        artifacts = {p.name: {'sha256': sha(p), 'bytes': p.stat().st_size} for p in sorted(output.iterdir()) if p.is_file()}
        write_json(output / 'manifest.json', {'schema_version': 1, 'status': 'complete', 'started_at': started, 'completed_at': now(),
                                            'production': False, 'training_qualified': False, 'diagnostic_unreviewed': True,
                                            'script_sha256': sha(Path(__file__)), 'input_sha256': hashes, 'artifacts': artifacts,
                                            'runtime': {'python': sys.version, 'executable': sys.executable, 'platform': platform.platform(), 'numpy': np.__version__, 'Pillow': PIL.__version__}, 'self_tests': tests})
        print(json.dumps({'output': str(output), 'selected_lambdas': {k: v['lambda'] for k, v in models.items()}, 'metrics': metrics}, indent=2), flush=True)
    except Exception as exc:
        write_json(output / 'failure.json', {'status': 'blocked', 'error': str(exc), 'failed_at': now(), 'production': False, 'training_qualified': False, 'no_silent_row_drops': True})
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--diagnostic-unreviewed', action='store_true')
    parser.add_argument('--review-package', type=Path)
    parser.add_argument('--dataset', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps(self_test(), indent=2))
        return
    require(all((args.review_package, args.dataset, args.output)), '--review-package, --dataset and --output required')
    run(args)


if __name__ == '__main__':
    main()
