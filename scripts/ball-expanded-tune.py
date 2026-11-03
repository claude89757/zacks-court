#!/usr/bin/env python3
"""One frozen expanded development experiment, with generic native-RGB inputs.

propose audits an external input-index without any model forward or fitting.
run requires the frozen protocol and explicit diagnostic-agent-label execution.
Self-tests use synthetic tensors only. No decoding, downloads or speed output.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import random
import sys
import tempfile
import time
import traceback
import unittest

sys.dont_write_bytecode = True
import numpy as np
import torch

HERE = Path(__file__).resolve()


def module(filename, name):
    spec = importlib.util.spec_from_file_location(name, HERE.with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


causal = module('ball-causal-tune.py', 'expanded_causal_helpers')
tune, native = causal.tune, causal.native
require = tune.require
FLAGS = {**causal.FLAGS, 'development_only': True, 'speed_kmh': None}
SEED, STEPS = 20261029, 1024
SPLITS = ('old_train', 'new_train', 'slow_dev', 'sourcecheck_dev')
TRAIN_SPLITS = ('old_train', 'new_train')
FIXED_TRAINING = {'seed': SEED, 'steps': STEPS, 'batch_size': 1, 'sequence_len': 8,
    'dtype': 'float32', 'device': 'cpu', 'threads': 4, 'interop_threads': 1,
    'optimizer': 'Adam', 'lr': 1e-5, 'betas': [.9, .999], 'eps': 1e-8, 'weight_decay': 0}


def digest(value):
    return hashlib.sha256(tune.canonical(value).encode()).hexdigest()


def write(path, value):
    causal.write(path, value)


def resolve(path, base):
    value = Path(path).expanduser()
    return (base / value).resolve() if not value.is_absolute() else value.resolve()


def fixed_schedule(eligible, steps=STEPS, seed=SEED):
    """Persistent Python Random; fresh lexical copy shuffled on each epoch."""
    ordered = sorted(eligible, key=lambda row: (row['sample_id'], row['start']))
    require(ordered and len({(r['sample_id'], r['start']) for r in ordered}) == len(ordered),
            'Empty or duplicate eligible groups')
    rng, result, epoch = random.Random(seed), [], 0
    while len(result) < steps:
        shuffled = list(ordered)
        rng.shuffle(shuffled)
        for item in shuffled:
            if len(result) == steps:
                break
            result.append({**item, 'epoch': epoch, 'step': len(result)})
        epoch += 1
    return result


def full_model():
    model = tune.factory('base')
    for parameter in model.parameters():
        parameter.requires_grad_(True)
    model.eval()
    return model


def model_contract(model):
    names = sorted(name for name, p in model.named_parameters() if p.requires_grad)
    all_names = sorted(name for name, _ in model.named_parameters())
    require(names == all_names, 'All network parameters must be trainable')
    require(all(p.dtype == torch.float32 and p.device.type == 'cpu' for p in model.parameters()),
            'CPU Float32 parameters required')
    affine, buffers = causal.bn_names(model)
    require(affine <= set(names), 'Every BN affine parameter must be trainable')
    return {'trainable_names': names, 'trainable_names_sha256': digest(names),
            'trainable_parameter_count': sum(p.numel() for p in model.parameters()),
            'bn_affine_names': sorted(affine), 'bn_buffer_names': sorted(buffers),
            'bn_policy': 'model.eval(); BN running buffers frozen; every affine parameter trainable',
            'forward': 'complete official model.forward every step; no prefix/suffix/feature cache'}


def validate_intent(intent):
    for key, expected in FIXED_TRAINING.items():
        require(intent['training'].get(key) == expected, 'Fixed training differs: ' + key)
    for flag in ('production', 'human_validated', 'formal_eligible'):
        require(intent.get(flag) is False, 'Intent qualification flag must remain false: ' + flag)
    require(intent.get('speed_metrics', 'missing') is None, 'Intent must not contain speed metrics')
    require(intent['init']['official_checkpoint_sha256'] == tune.BASE_SHA and
            intent['init']['source_commit'] == tune.PIN and intent['init']['prefix_cache'] is False,
            'Intent official initialization/cache policy differs')


def audit_native_window(run_parent, protocol_path, window, labels, manifest_sha):
    """Use unchanged native audit with this frozen window's explicit label plan.

    The legacy helper's only global sample restriction is restored even on error;
    no concurrent audit threads are used and no frozen helper file is changed.
    """
    indices = window['label_plan']['indices']
    require(isinstance(indices, list) and len(indices) == 48 and
            all(type(i) is int and 0 <= i < 120 for i in indices) and
            indices == sorted(set(indices)), 'Window must freeze48 unique sorted label indices')
    require(sorted(row['frame_index'] for row in labels) == indices, 'Labels differ from per-window plan')
    previous = native.LABEL_INDICES
    try:
        native.LABEL_INDICES = tuple(indices)
        return native.audit_run(run_parent, protocol_path, window, labels, manifest_sha)
    finally:
        native.LABEL_INDICES = previous


class Inputs:
    """Index-bound source windows; only one causal background per window resident."""
    def __init__(self, index_path):
        self.index_path = Path(index_path).resolve()
        self.base = self.index_path.parent
        self.files = {}
        self.record(self.index_path)
        self.index = native.load_json(self.index_path)
        require(self.index.get('schema_version') == 1, 'Unsupported index schema')
        self.intent_path = self.reference(self.index['intent'])
        self.intent = native.load_json(self.intent_path)
        validate_intent(self.intent)
        for ref in self.index.get('documents', []):
            self.reference(ref)
        self.old_head_path = self.reference(self.index['old_head_checkpoint'])
        self.regression_path = self.reference(self.index['old_regression_evaluation'])
        rows = []
        for ref in self.index['label_files']:
            doc = native.load_json(self.reference(ref))
            labels = tune.labels_list(doc)
            require(isinstance(labels, list), 'Label file needs records/labels list')
            rows.extend(labels)
        self.labels = {}
        for row in rows:
            key = (row['sample_id'], row['frame_index'])
            require(key not in self.labels, 'Duplicate sample/frame agent annotation')
            require(row.get('status') in ('visible', 'unknown'), 'Absent/unrecognized labels prohibited')
            if row['status'] == 'visible':
                require(row.get('target_identity') == 'confirmed', 'Visible identity must be confirmed')
                require(type(row.get('uncertainty_px')) in (int, float) and
                        math.isfinite(row['uncertainty_px']) and row['uncertainty_px'] > 0,
                        'Visible uncertainty missing/nonfinite')
            else:
                require(row.get('x') is None and row.get('y') is None, 'Unknown coordinates must be null')
                require(any(row.get(k) for k in ('reason', 'unknown_reason', 'notes', 'note', 'visibility_reason')),
                        'Unknown labels require an explicit reason')
            self.labels[key] = row
        entries = self.index['windows']
        require(len(entries) == 22 and len({r['window_id'] for r in entries}) == 22, 'Expected22 unique windows')
        require(Counter(r['split'] for r in entries) == {'old_train': 3, 'new_train': 12, 'slow_dev': 1,
                                                       'sourcecheck_dev': 6}, 'Window split counts differ')
        self.entries = {row['window_id']: row for row in entries}
        require(set(key[0] for key in self.labels) == set(self.entries), 'Unbound or unlabelled input windows')
        self.windows, self.roots, self.reports, self.backgrounds, self.audits = {}, {}, {}, {}, {}
        source_intervals, train_identities = {}, set()
        for name in sorted(self.entries):
            entry = self.entries[name]
            manifest_path = self.reference(entry['manifest'])
            manifests = native.load_json(manifest_path)['windows']
            matching = [row for row in manifests if row['window_id'] == name]
            require(len(matching) == 1, 'Window missing/duplicated in manifest: ' + name)
            window = matching[0]
            expected_indices = (list(range(16)) + list(range(64, 96)) if entry['split'] in ('old_train', 'slow_dev')
                                else list(range(24, 72)))
            require(window['label_plan']['indices'] == expected_indices, 'Frozen split label plan differs')
            require(window['sample_id'] == name and len(window['frames']) == 120, 'Need120 real target frames')
            require(isinstance(window.get('source_family'), str) and window['source_family'], 'Source family must be explicit')
            for index, frame in enumerate(window['frames']):
                require(frame['frame_index'] == index, 'Manifest frame index differs')
                require((frame['width'], frame['height']) == (window['width'], window['height']), 'Manifest frame dimensions differ')
                self.record(resolve(frame['image_path'], manifest_path.parent), frame['image_sha256'])
            protocol_path = self.reference(entry['protocol'])
            proto = native.load_json(protocol_path)
            video_path = resolve(proto['video_path'], protocol_path.parent)
            require('001' not in video_path.name, 'Source001 is excluded')
            self.record(video_path, window['source_sha256'])
            root_parent = resolve(entry['runs_root'], self.base)
            root = root_parent / name
            self.roots[name] = root
            labels = [row for (sample, _), row in self.labels.items() if sample == name]
            audited = audit_native_window(root_parent, protocol_path, window, labels, tune.sha(manifest_path))
            report = native.load_json(root / 'report.json')
            require(report.get('range_decoding_strategy') and
                    report.get('total_decoded_samples_including_preroll', 0) >= 168,
                    'Expected native-v3 decoding diagnostics')
            self.windows[name], self.reports[name], self.audits[name] = window, report, audited
            for relative in ('report.json', 'input-protocol.json', 'first-background.rgb',
                             'first-window.tensor.f32le', 'first-window.heatmaps.f32le'):
                self.record(root / relative)
            for row in report['decoded_inputs']:
                self.record(root / row['resized_rgb_file'], row['resized_rgb_sha256'])
            self.backgrounds[name] = native.prefix_median([self.rgb(name, index) for index in range(48)])
            require(native.sha_bytes(self.backgrounds[name].tobytes()) == audited['background_sha256'],
                    'Causal background audit differs')
            times = [native.stamp(row) for row in proto['expected_warmup_times'] + proto['expected_inference_times']]
            period = Fraction(1, 1) / Fraction(str(report['nominal_fps']))
            require(all(0 < float(b-a) <= float(period) * 1.5 for a, b in zip(times, times[1:])),
                    'Native input continuity gap')
            source_intervals.setdefault(window['source_sha256'], []).append((times[0], times[-1], name))
            if entry['split'] in TRAIN_SPLITS:
                for label in labels:
                    identity = (window['source_sha256'], native.manifest_time(label))
                    require(identity not in train_identities, 'Duplicate training source PTS')
                    train_identities.add(identity)
            if entry['split'] == 'sourcecheck_dev':
                require(entry.get('group') in ('serve', 'nonserve'), 'Sourcecheck group required')
        for intervals in source_intervals.values():
            ordered = sorted(intervals)
            require(all(a[1] < b[0] for a, b in zip(ordered, ordered[1:])),
                    'Target/pre-background source intervals overlap')
        source_sets = {split: {self.windows[name]['source_sha256'] for name, row in self.entries.items()
                              if row['split'] == split} for split in SPLITS}
        require(len(source_sets['old_train'] | source_sets['new_train']) == 1, 'Training must retain one003 source family')
        require(not ((source_sets['old_train'] | source_sets['new_train'] | source_sets['slow_dev']) &
                     source_sets['sourcecheck_dev']), 'Sourcecheck source hash overlaps train/slow')
        require(not (source_sets['old_train'] & source_sets['slow_dev']), 'Slow source overlaps training')
        require(len({self.windows[n].get('source_family') for n in self.entries if self.entries[n]['split'] in TRAIN_SPLITS}) == 1,
                'Training source-family identity differs')
        require(Counter(row.get('group') for row in entries if row['split'] == 'sourcecheck_dev') ==
                {'serve': 2, 'nonserve': 4}, 'Sourcecheck serve/nonserve split differs')
        self.counts = {split: dict(Counter(row['status'] for (sample, _), row in self.labels.items()
                                        if self.entries[sample]['split'] == split)) for split in SPLITS}
        require(self.counts['old_train'] == {'visible': 134, 'unknown': 10} and
                self.counts['new_train'] == {'visible': 513, 'unknown': 63} and
                self.counts['slow_dev'] == {'visible': 32, 'unknown': 16}, 'Frozen label counts differ')
        require(sum(self.counts['sourcecheck_dev'].values()) == 288 and len(self.labels) == 1056,
                'Sourcecheck288/all1056 annotations must freeze before model results')
        require(len({row['native_model_manifest_sha256'] for row in self.audits.values()}) == 1,
                'Native model manifests differ')
        self.eligible = []
        for name in sorted(self.entries):
            if self.entries[name]['split'] not in TRAIN_SPLITS:
                continue
            for start in range(0, 120, 8):
                count = sum(self.labels.get((name, index), {}).get('status') == 'visible'
                            for index in range(start, start + 8))
                if count:
                    self.eligible.append({'sample_id': name, 'start': start, 'supervised_frames': count})
        require(len(self.eligible) == 88 and sum(r['supervised_frames'] for r in self.eligible) == 647,
                'Expected88 groups/647 unique supervised training frames')
        require(Counter(self.entries[r['sample_id']]['split'] for r in self.eligible) ==
                {'old_train': 17, 'new_train': 71}, 'Eligible old17/new71 group counts differ')

    def record(self, path, expected=None):
        path = Path(path).resolve()
        if str(path) in self.files:
            require(expected is None or self.files[str(path)] == expected, 'Conflicting file hashes')
            return
        value = tune.sha(path)
        require(expected is None or value == native.valid_sha(expected), 'Frozen file hash differs: ' + str(path))
        self.files[str(path)] = value

    def reference(self, ref):
        path = resolve(ref['path'], self.base)
        self.record(path, ref['sha256'])
        return path

    def rgb(self, name, decode_index):
        row = self.reports[name]['decoded_inputs'][decode_index]
        return np.frombuffer(native.checked_bytes(self.roots[name], row['resized_rgb_file'], native.RGB_BYTES,
                                                  row['resized_rgb_sha256']), dtype=np.uint8).reshape(native.RGB_SHAPE)

    def tensor(self, name, start):
        require(start in range(0, 120, 8), 'Invalid tensor start')
        array = native.make_tensor(self.backgrounds[name], [self.rgb(name, 48+start+i) for i in range(8)])
        require(native.sha_bytes(array.tobytes()) == self.reports[name]['windows'][start//8]['tensor_sha256'],
                'Native tensor SHA differs')
        return torch.from_numpy(array)

    def targets(self, name, start):
        require(self.entries[name]['split'] in TRAIN_SPLITS, 'Development window cannot supply targets')
        window = self.windows[name]
        targets, masks, geometry = [], [], []
        for index in range(start, start+8):
            label = self.labels.get((name, index))
            target, mask, geo = tune.make_target(label, (0, 0, window['width'], window['height']))
            targets.append(target); masks.append(mask); geometry.append(geo)
        return torch.from_numpy(np.stack(targets))[None], torch.tensor([masks], dtype=torch.float32), geometry

    def verify_unchanged(self):
        for path, expected in self.files.items():
            require(tune.sha(path) == expected, 'Input changed during experiment: ' + path)


def proposal(index_path):
    inputs = Inputs(index_path)
    source = tune.source_check()
    model = full_model()  # Model construction/state audit only, NO forward or optimizer.
    contract = model_contract(model)
    dependencies = {str(path): tune.sha(path) for path in (HERE, causal.HERE,
        HERE.with_name('ball-track-tune.py'), HERE.with_name('ball-track-associate.py'),
        HERE.with_name('ball-native-video-audit.py'), tune.HELPER)}
    schedule = fixed_schedule(inputs.eligible)
    return {'schema_version': 1, **FLAGS, 'purpose': 'one expanded full-network diagnostic development fit',
        'input_index': str(inputs.index_path), 'input_index_sha256': tune.sha(inputs.index_path),
        'intent': inputs.intent, 'input_files': inputs.files, 'native_audits': inputs.audits,
        'label_counts': inputs.counts, 'dependencies': dependencies, 'official_source': source,
        'runtime': tune.runtime(), 'model_contract': contract, 'initial_model_state_sha256': tune.state_sha(model),
        'training': FIXED_TRAINING, 'eligible_groups': inputs.eligible, 'schedule': schedule,
        'schedule_sha256': digest(schedule), 'epochs': {'complete': 11, 'partial_groups': 56},
        'supervised_frame_occurrences': sum(row['supervised_frames'] for row in schedule),
        'comparison_models': ['official_base', 'old_head72_delta', 'full_final1024'],
        'selection': 'single final1024 checkpoint; no early stop, best selection or retrained controls',
        'loss': 'unchanged balanced_wbce/Gaussian; only confirmed visible; unknown/unlabelled output gradient0',
        'candidate': {'threshold': .3, 'operator': '>', 'top_k': 20, 'connectivity': 8,
                      'ordering': 'peak descending,bbox area descending,minimum raster index+1 ascending'},
        'pre_fit_gate': 'native base all2640 bank/selection structural parity; scalar atol1e-5; first22 raw batches maxabs<=1e-5 and strict>.3 maskflips0; legacy base/head old4 metrics exact',
        'license': {'source_license_path': str(Path(source['repo'])/'LICENSE'),
                    'source_license_sha256': source['license_sha256'], 'development_only': True,
                    'production_or_redistribution_authorization': False},
        'budget': {'fits': 1, 'optimizer_steps': 1024, 'full_training_forwards': 1024,
                   'full_training_backwards': 1024, 'checkpoint_verification_forwards': 176, 'all_real_model_forwards': 2190, 'evaluation_models': 3,
                   'evaluation_full_forwards': 990, 'evaluation_frames': 7920,
                   'synthetic_tests_are_not_model_training': True},
        'limitations': ['All labels are agent development annotations; no human/physical truth or formal eligibility.',
            '647 visible and73 unknown training records are one003 source family, not15 independent sources.',
            'Sourcecheck test.MOV family previously informed speed baselines; source-separated development only.',
            'Data volume, trainable layers and LR change together; this tests the whole proposal.',
            'Background/association use only past; eight-frame detector still sees up to7 later frames.',
            'Masked output gradient0 does not imply zero gradient through shared inputs/parameters.',
            'No speed/XYZ objectives, physical accuracy claims or automatic promotion.']}


def summary(points):
    result = native.summarize_points(points)
    total, visible = len(points), result['visible_denominator']
    hit = result['within_equivalent_px']['10']
    between = result['within_equivalent_px']['20'] - hit
    unknown = result['unknown_excluded_from_distance_denominator']
    require(visible == hit + between + result['wrong_over20_on_visible'] + result['missing_on_visible'],
            'Visible score ledger does not balance')
    require(total == visible + unknown, 'V+U must equal total')
    result.update(hit_within10=hit, between10exclusive20inclusive=between,
                  hit_over_all_label_candidates=native.rate(hit, total),
                  hit_over_all_label_candidates_interpretation='supported fraction lower bound; not certified recall',
                  unknown_without_output=unknown-result['selected_on_unknown_identity_unscored'])
    return result


def scoped_metrics(points, inputs):
    scopes = {'all_development': points}
    for split in SPLITS:
        scopes[split] = [r for r in points if inputs.entries[r['sample_id']]['split'] == split]
    scopes['all_train'] = [r for r in points if inputs.entries[r['sample_id']]['split'] in TRAIN_SPLITS]
    for group in ('serve', 'nonserve'):
        scopes['sourcecheck_' + group] = [r for r in scopes['sourcecheck_dev']
                                        if inputs.entries[r['sample_id']].get('group') == group]
    return {**{name: summary(rows) for name, rows in scopes.items()},
            'per_window': {name: summary([r for r in points if r['sample_id'] == name])
                           for name in sorted(inputs.entries)}}


def evaluate(model, name, inputs, out, stream, native_gate=False):
    started, before = time.perf_counter(), tune.state_sha(model)
    all_points = {'causal': [], 'author_max_area': [], 'oracle_topK_upper_bound': []}
    batches, failures = [], []
    for sample in sorted(inputs.entries):
        window, reference = inputs.windows[sample], inputs.reports[sample]
        gate = causal.CausalGate(reference['nominal_fps'])
        for start in range(0, 120, 8):
            with torch.inference_mode():
                maps = model(inputs.tensor(sample, start)).detach().numpy().astype('<f4', copy=False)
            require(maps.shape == native.HEATMAP_SHAPE and np.isfinite(maps).all(), 'Invalid predictions')
            batch = {'sample_id': sample, 'start': start, 'sha256': native.sha_bytes(maps.tobytes()),
                     'native_sha256': reference['windows'][start//8]['heatmaps_sha256'],
                     'raw_numeric_comparison': None}
            if native_gate and start == 0:
                raw = native.checked_bytes(inputs.roots[sample], reference['windows'][0]['heatmaps_file'],
                    math.prod(native.HEATMAP_SHAPE)*4, reference['windows'][0]['heatmaps_sha256'])
                native_maps = np.frombuffer(raw, dtype='<f4').reshape(native.HEATMAP_SHAPE)
                difference = float(np.abs(maps-native_maps).max())
                flips = int(np.count_nonzero((maps > np.float32(.3)) != (native_maps > np.float32(.3))))
                batch['raw_numeric_comparison'] = {'maxabs': difference, 'strict_03_mask_flips': flips}
                if not causal.native_numeric_budget(difference, flips):
                    failures.append({'sample_id': sample, 'start': start, 'numeric': batch['raw_numeric_comparison']})
            batches.append(batch)
            for offset in range(8):
                index, frame = start+offset, window['frames'][start+offset]
                bank, author = causal.candidate_bank(maps[0, offset], window['width'], window['height'])
                selected = gate.select(bank, native.manifest_time(frame), window['source_sha256'])
                if native_gate:
                    bank_check = causal.bank_alignment(bank, reference['frames'][index]['candidate_bank'])
                    select_check = causal.selection_alignment(selected, reference['frames'][index])
                    if not bank_check['passed'] or not select_check['passed']:
                        failures.append({'sample_id': sample, 'frame_index': index,
                                         'bank': bank_check, 'selection': select_check})
                label = inputs.labels.get((sample, index))
                oracle = None
                if label and label['status'] == 'visible' and bank['candidates']:
                    oracle = min(bank['candidates'], key=lambda row: (
                        math.hypot((row['originalXY'][0]-label['x'])*1280/window['width'],
                                   (row['originalXY'][1]-label['y'])*720/window['height']), row['identifier']))['originalXY']
                xy = selected['candidate']['originalXY'] if selected['candidate'] else None
                if label:
                    for selector, point in (('causal', xy), ('author_max_area', author), ('oracle_topK_upper_bound', oracle)):
                        all_points[selector].append(native.point_record(label, window, frame, point))
                stream.write(tune.canonical({**FLAGS, 'model': name, 'sample_id': sample, 'frame_index': index,
                    'source_sha256': window['source_sha256'], 'source_pts': frame['source_pts'],
                    'source_time_base': frame['source_time_base'], 'available_at_pts': reference['frames'][index]['available_at_pts'],
                    'source_lookahead_seconds': reference['frames'][index]['source_lookahead_seconds'],
                    'candidate_bank': bank, 'causal_selection': selected, 'author_max_area_xy': author,
                    'oracle_topK_upper_bound_xy': oracle, 'oracle_is_tracker': False})+'\n')
            stream.flush()
            print(f'EVALUATE {name} {sample} {start+8}/120', flush=True)
    require(before == tune.state_sha(model), 'Evaluation changed model state')
    report = {**FLAGS, 'model': name, 'model_state_sha256': before, 'seconds': time.perf_counter()-started,
        'frame_count': 2640, 'batch_count': 330, 'batch_heatmaps': batches,
        'metrics': {key: scoped_metrics(rows, inputs) for key, rows in all_points.items()}, 'points': all_points,
        'native_alignment': {'required': native_gate, 'passed': not failures if native_gate else None,
                             'failures': failures, 'raw_batches': 22 if native_gate else 0,
                             'unexported_raw_heatmaps': 'No numerical bound asserted; SHA difference alone is not failure'}}
    write(out/(name+'-evaluation.json'), report)
    return report


def old_head(inputs, expected_base_sha):
    checkpoint = torch.load(inputs.old_head_path, map_location='cpu', weights_only=True)
    require(checkpoint['parent_sha256'] == tune.BASE_SHA and checkpoint['mode'] == 'head_only', 'Old head provenance differs')
    require(checkpoint['initial_model_state_sha256'] == expected_base_sha, 'Old head base state differs')
    model = tune.factory('head_only')
    names = {name for name, parameter in model.named_parameters() if parameter.requires_grad}
    require(set(checkpoint['trainable_state']) == names, 'Old head delta names differ')
    state = model.state_dict()
    for name, value in checkpoint['trainable_state'].items():
        require(value.shape == state[name].shape and value.dtype == state[name].dtype and
                torch.isfinite(value).all().item(), 'Invalid old delta tensor')
        state[name] = value
    model.load_state_dict(state, strict=True)
    require(tune.state_sha(model) == checkpoint['final_model_state_sha256'], 'Old full head state differs')
    return model


def legacy_regression(inputs, base, head):
    frozen = native.load_json(inputs.regression_path)['evaluations']
    results = {}
    keys = ('label_candidates', 'visible_denominator', 'missing_on_visible', 'wrong_over20_on_visible',
            'within_equivalent_px', 'unknown_excluded_from_distance_denominator', 'selected_on_unknown_identity_unscored')
    for name, old_name, report in (('base', 'base', base), ('head', 'head_only', head)):
        for sample in sorted(inputs.entries):
            if inputs.entries[sample]['split'] not in ('old_train', 'slow_dev'):
                continue
            old = frozen[old_name]['metrics']['causal']['per_window'][sample]
            new = report['metrics']['causal']['per_window'][sample]
            require(all(new[k] == old[k] for k in keys), 'Frozen old regression changed: '+name+' '+sample)
            results[name+':'+sample] = {key: new[key] for key in keys}
    require(len(results) == 8, 'Expected8 legacy model/window metric regressions')
    return results


def train(model, inputs, protocol, protocol_sha, out):
    require(model_contract(model) == protocol['model_contract'], 'Full parameter contract drift')
    require(tune.state_sha(model) == protocol['initial_model_state_sha256'], 'Fit must start at official base')
    trainable = {name for name, _ in model.named_parameters()}
    _, buffers = causal.bn_names(model)
    initial = tune.state_sha(model)
    bn_before = tune.state_sha(model, lambda name: name in buffers)
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-5, betas=(.9, .999), eps=1e-8, weight_decay=0)
    started, total_loss, exposures = time.perf_counter(), 0., Counter()
    with (out/'training-steps.jsonl').open('x') as stream:
        for step, item in enumerate(protocol['schedule']):
            require(item['step'] == step, 'Schedule step mismatch')
            require(not model.training and all(not layer.training for layer in model.modules()
                    if isinstance(layer, torch.nn.modules.batchnorm._BatchNorm)), 'BN left eval mode')
            x = inputs.tensor(item['sample_id'], item['start'])
            y, mask, geometry = inputs.targets(item['sample_id'], item['start'])
            require(int(mask.sum().item()) == item['supervised_frames'], 'Schedule supervision differs')
            optimizer.zero_grad(set_to_none=True)
            prediction = model(x)  # Full official forward, without any frozen-feature route.
            prediction.retain_grad()
            loss, diagnostics = tune.balanced_wbce(prediction, y, mask)
            require(torch.isfinite(loss).item(), 'Nonfinite loss')
            loss.backward()
            masked = mask[0] == 0
            require(torch.count_nonzero(prediction.grad[0][masked]).item() == 0,
                    'Unknown/unlabelled output loss gradient nonzero')
            require(all(p.grad is not None and torch.isfinite(p.grad).all().item() for p in model.parameters()),
                    'Missing/nonfinite network parameter gradient')
            norm = math.sqrt(sum(float(p.grad.double().square().sum()) for p in model.parameters()))
            require(math.isfinite(norm) and norm > 0, 'Invalid network gradient norm')
            optimizer.step()
            require(all(torch.isfinite(p).all().item() for p in model.parameters()), 'Nonfinite network state')
            require(tune.state_sha(model, lambda name: name in buffers) == bn_before, 'BN running buffer changed')
            for offset in range(8):
                if mask[0, offset].item():
                    exposures[f"{item['sample_id']}:{item['start']+offset}"] += 1
            row = {'step': step+1, 'schedule': item, 'loss': diagnostics, 'gradient_norm': norm,
                'frame_mask': mask[0].tolist(), 'masked_output_gradient_zero': True,
                'every_network_parameter_gradient_present_finite': True, 'bn_buffers_unchanged': True,
                'full_forward': True, 'prefix_cache_used': False, 'elapsed_seconds': time.perf_counter()-started}
            stream.write(tune.canonical(row)+'\n'); stream.flush()
            total_loss += loss.item()
            if (step+1) % 16 == 0 or step == 0 or step+1 == STEPS:
                print(f'FIT full_network step={step+1}/{STEPS} loss={loss.item():.8f} elapsed={time.perf_counter()-started:.1f}s', flush=True)
    require(len(protocol['schedule']) == STEPS and len(exposures) == 647, 'Budget/exposure coverage differs')
    inputs.verify_unchanged()
    final = tune.state_sha(model)
    path = out/'full-final1024.pt'
    checkpoint = {'schema_version': 1, 'parent_sha256': tune.BASE_SHA, 'protocol_sha256': protocol_sha,
        'input_index_sha256': protocol['input_index_sha256'], 'steps': STEPS,
        'initial_model_state_sha256': initial, 'final_model_state_sha256': final,
        'model_state': {name: value.detach().cpu().clone() for name, value in model.state_dict().items()}}
    torch.save(checkpoint, path); path.chmod(0o600)
    loaded = torch.load(path, map_location='cpu', weights_only=True)
    require(loaded['parent_sha256'] == tune.BASE_SHA and loaded['protocol_sha256'] == protocol_sha and
            loaded['steps'] == STEPS, 'Saved checkpoint provenance differs')
    replay = full_model()
    state = replay.state_dict()
    require(set(loaded['model_state']) == set(state), 'Full checkpoint state names differ')
    for name, value in loaded['model_state'].items():
        require(value.shape == state[name].shape and value.dtype == state[name].dtype and
                torch.isfinite(value).all().item(), 'Full checkpoint tensor invalid')
    replay.load_state_dict(loaded['model_state'], strict=True)
    require(tune.state_sha(replay) == final, 'Safe complete checkpoint reload differs')
    require(tune.state_sha(replay, lambda name: name in buffers) == bn_before, 'Reload BN buffers differ')
    for item in inputs.eligible:
        x = inputs.tensor(item['sample_id'], item['start'])
        with torch.inference_mode():
            require(torch.equal(model(x), replay(x)), 'Safe checkpoint full-forward replay differs')
    inputs.verify_unchanged()
    report = {**FLAGS, 'steps': STEPS, 'training': FIXED_TRAINING, 'seconds': time.perf_counter()-started,
        'mean_training_loss': total_loss/STEPS, 'initial_model_state_sha256': initial,
        'final_model_state_sha256': final, 'bn_running_buffers_before': bn_before,
        'bn_running_buffers_after': tune.state_sha(replay, lambda name: name in buffers),
        'all_parameters_trainable': True, 'unknown_loss_gradient_zero_every_step': True,
        'unknown_inputs_or_shared_parameters_gradient_zero_claimed': False, 'prefix_cache_used': False,
        'safe_weights_only_complete_reload_identical': True, 'all88_full_forward_replay_exact': True,
        'supervised_occurrences': sum(exposures.values()), 'per_visible_frame_exposures': dict(sorted(exposures.items())),
        'checkpoint': path.name, 'checkpoint_sha256': tune.sha(path), 'selection': 'last step1024 only'}
    write(out/'training.json', report)
    return replay, report


def success(base, head, fitted):
    result = {}
    for scope in ('sourcecheck_dev', 'slow_dev'):
        old, prior, new = [r['metrics']['causal'][scope] for r in (base, head, fitted)]
        hit = new['hit_within10']; wrong = new['wrong_over20_on_visible']
        passed = (hit > max(old['hit_within10'], prior['hit_within10']) and
                  wrong <= min(old['wrong_over20_on_visible'], prior['wrong_over20_on_visible'])) if scope == 'sourcecheck_dev' else (
                  new['visible_denominator'] == 32 and hit == 32 and wrong == 0)
        result[scope] = {'passed': passed, 'base': old, 'old_head72': prior, 'final1024': new}
    return {**result, 'development_improvement': all(r['passed'] for r in result.values()),
            'automatic_promotion': False, 'speed_metrics': None}


def check_environment(protocol):
    require(tune.source_check() == protocol['official_source'], 'Official source/checkpoint drift')
    require(tune.runtime() == protocol['runtime'], 'Runtime environment drift')
    for path, expected in protocol['dependencies'].items():
        require(tune.sha(path) == expected, 'Runner/helper changed: '+path)


def execute(args):
    require(args.execute_frozen_protocol and args.diagnostic_agent_labels,
            'run requires --execute-frozen-protocol and --diagnostic-agent-labels')
    protocol_path = Path(args.protocol).resolve()
    protocol = native.load_json(protocol_path)
    require(protocol == proposal(protocol['input_index']), 'Frozen protocol/input/runtime drift; preserve old protocol')
    protocol_sha = tune.sha(protocol_path)
    inputs = Inputs(protocol['input_index'])
    out = Path(args.output).resolve()
    require(not out.exists(), 'Output exists; choose NEW directory')
    out.mkdir(parents=True); out.chmod(0o700)
    write(out/'protocol.json', protocol)
    write(out/'receipt.json', {**FLAGS, 'created_at': datetime.now(timezone.utc).isoformat(),
        'protocol_sha256': protocol_sha, 'runner_sha256': tune.sha(HERE), 'input_files': inputs.files,
        'training_started': False, 'budget': protocol['budget']})
    phase, training_started = 'prefit_base_native_parity', False
    try:
        torch.set_num_threads(4); torch.set_num_interop_threads(1)
        torch.set_default_dtype(torch.float32); torch.use_deterministic_algorithms(True); torch.manual_seed(SEED)
        with (out/'predictions.jsonl').open('x') as stream:
            model = full_model()
            base = evaluate(model, 'official_base', inputs, out, stream, native_gate=True)
            require(base['native_alignment']['passed'], 'PRE_FIT_NATIVE_GATE_FAILED; no fitting started')
            phase = 'prefit_old_head_and_regression'
            head_model = old_head(inputs, protocol['initial_model_state_sha256'])
            head = evaluate(head_model, 'old_head72_delta', inputs, out, stream)
            del head_model
            regressions = legacy_regression(inputs, base, head)
            write(out/'prefit-gates.json', {**FLAGS, 'native_parity_passed': True,
                'legacy_regression': regressions, 'training_started': False})
            inputs.verify_unchanged(); check_environment(protocol)
            phase, training_started = 'full_fit1024', True
            fitted_model, training = train(model, inputs, protocol, protocol_sha, out)
            del model
            phase = 'evaluate_final1024'
            fitted = evaluate(fitted_model, 'full_final1024', inputs, out, stream)
        phase = 'post_run_input_verification'
        inputs.verify_unchanged(); check_environment(protocol)
        report = {**FLAGS, 'protocol_sha256': protocol_sha, 'all_inputs_unchanged_before_and_after': True,
            'same_native_rgb_background_tensor_across_models': True, 'training': training,
            'evaluations': {'base': base, 'old_head72': head, 'final1024': fitted},
            'success': success(base, head, fitted), 'budget': protocol['budget'],
            'legacy_regression': regressions, 'license': protocol['license'], 'limitations': protocol['limitations']}
        write(out/'report.json', report)
        write(out/'completion.json', {**FLAGS, 'status': 'complete', 'steps': STEPS,
            'protocol_sha256': protocol_sha, 'budget': protocol['budget'],
            'development_improvement': report['success']['development_improvement'],
            'files': {p.name: tune.sha(p) for p in out.iterdir() if p.is_file()}})
        print(tune.canonical({'output': str(out), 'steps': STEPS,
                             'development_improvement': report['success']['development_improvement']}))
    except BaseException as error:
        write(out/'failure.json', {**FLAGS, 'status': 'failed', 'phase': phase,
            'training_started': training_started, 'error': str(error), 'traceback': traceback.format_exc(),
            'protocol_sha256': protocol_sha, 'partial_artifacts_preserved': True,
            'resumption_supported': False, 'resumption_note': 'No approximate resume; preserve partial artifacts and preregister infrastructure repair.',
            'files': {p.name: tune.sha(p) for p in out.iterdir() if p.is_file()}})
        raise


class SelfTests(unittest.TestCase):
    def test_schedule_is_fixed_epoch_shuffle_not_replacement(self):
        eligible = [{'sample_id': 'a', 'start': i*8, 'supervised_frames': 1} for i in range(88)]
        schedule = fixed_schedule(eligible)
        self.assertEqual(schedule, fixed_schedule(list(reversed(eligible))))
        self.assertEqual(len(schedule), 1024)
        self.assertNotEqual(schedule, fixed_schedule(eligible, seed=SEED+1))
        for epoch in range(11):
            self.assertEqual({r['start'] for r in schedule[epoch*88:(epoch+1)*88]}, {r['start'] for r in eligible})
        self.assertEqual(len(schedule[968:]), 56)
        self.assertEqual(len({r['start'] for r in schedule[968:]}), 56)

    def test_unknown_mask_loss_gradient_and_all_unknown_rejection(self):
        tune.SelfTests('test_unknown_gradient_and_zero_shortcut').test_unknown_gradient_and_zero_shortcut()

    def test_complete_synthetic_network_bn_affine_buffers_and_safe_reload(self):
        torch.manual_seed(SEED)
        model = torch.nn.Sequential(torch.nn.Conv2d(3, 4, 1), torch.nn.BatchNorm2d(4),
                                    torch.nn.Conv2d(4, 8, 1), torch.nn.Sigmoid()).float().eval()
        contract = model_contract(model)
        self.assertTrue(contract['bn_affine_names'])
        _, buffers = causal.bn_names(model)
        before = tune.state_sha(model, lambda name: name in buffers)
        optimizer = torch.optim.Adam(model.parameters(), lr=1e-5, betas=(.9, .999), eps=1e-8, weight_decay=0)
        p = model(torch.randn(1, 3, 8, 8)); p.retain_grad()
        target, mask = torch.ones_like(p)*.25, torch.tensor([[1., 0., 1., 0., 1., 0., 1., 0.]])
        loss, _ = tune.balanced_wbce(p, target, mask); loss.backward()
        self.assertEqual(torch.count_nonzero(p.grad[0][mask[0] == 0]).item(), 0)
        self.assertTrue(all(param.grad is not None and torch.isfinite(param.grad).all() for param in model.parameters()))
        optimizer.step()
        self.assertEqual(before, tune.state_sha(model, lambda name: name in buffers))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'state.pt'; torch.save({'model_state': model.state_dict()}, path)
            clone = torch.nn.Sequential(torch.nn.Conv2d(3, 4, 1), torch.nn.BatchNorm2d(4),
                                       torch.nn.Conv2d(4, 8, 1), torch.nn.Sigmoid()).float().eval()
            clone.load_state_dict(torch.load(path, map_location='cpu', weights_only=True)['model_state'], strict=True)
            self.assertEqual(tune.state_sha(model), tune.state_sha(clone))
            x = torch.randn(1, 3, 8, 8)
            with torch.inference_mode(): self.assertTrue(torch.equal(model(x), clone(x)))

    def test_ledger_retains_missing_and_unknown(self):
        points = [{'status': status, 'candidate_original_xy': xy,
                   'distance_1280x720_equivalent_px': distance} for status, xy, distance in (
            ('visible', [1, 2], 10), ('visible', [1, 2], 20), ('visible', [1, 2], 21),
            ('visible', None, None), ('unknown', [1, 2], None), ('unknown', None, None))]
        result = summary(points)
        self.assertEqual(result['visible_denominator'], 4)
        self.assertEqual(result['hit_within10'], 1)
        self.assertEqual(result['between10exclusive20inclusive'], 1)
        self.assertEqual(result['missing_on_visible'], 1)
        self.assertEqual(result['unknown_without_output'], 1)
        self.assertEqual(result['hit_over_all_label_candidates'], 1/6)

    def test_unchanged_raster_threshold_and_source_pts_gate(self):
        for name in ('test_raster_identifier_is_actual_minimum_not_component_label',
                     'test_strict_threshold_missing_denominator_and_unknown',
                     'test_original_pts_gap_and_duplicates_rejected',
                     'test_preregistered_numeric_budget_rejects_tiny_overrun_or_mask_flip'):
            getattr(causal.SelfTests(name), name)()

    def test_per_window_label_plan_restores_legacy_global_on_failure(self):
        previous, original = native.LABEL_INDICES, native.audit_run
        indices = list(range(24, 72))
        def synthetic_audit(*args):
            self.assertEqual(native.LABEL_INDICES, tuple(indices))
            raise ValueError('synthetic audit failure')
        native.audit_run = synthetic_audit
        try:
            with self.assertRaisesRegex(ValueError, 'synthetic audit failure'):
                audit_native_window(None, None, {'label_plan': {'indices': indices}},
                                    [{'frame_index': i} for i in indices], None)
            self.assertEqual(native.LABEL_INDICES, previous)
        finally:
            native.audit_run = original
            native.LABEL_INDICES = previous

    def test_file_hash_and_path_bindings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); p = root/'data'; p.write_bytes(b'abc')
            value = object.__new__(Inputs); value.files = {}; value.base = root
            self.assertEqual(value.reference({'path': 'data', 'sha256': tune.sha(p)}), p.resolve())
            p.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'Input changed'): value.verify_unchanged()
            with self.assertRaises(ValueError):
                native.checked_bytes(root, '../outside', 3, '0'*64)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    subs = parser.add_subparsers(dest='command')
    propose = subs.add_parser('propose')
    propose.add_argument('--input-index', required=True); propose.add_argument('--output', required=True)
    propose.add_argument('--diagnostic-agent-labels', action='store_true')
    run = subs.add_parser('run')
    run.add_argument('--protocol', required=True); run.add_argument('--output', required=True)
    run.add_argument('--execute-frozen-protocol', action='store_true')
    run.add_argument('--diagnostic-agent-labels', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        torch.set_num_threads(4)
        tests = unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(tests).wasSuccessful() else 1
    require(args.command, 'Choose propose/run or --self-test')
    if args.command == 'propose':
        require(args.diagnostic_agent_labels, 'propose requires --diagnostic-agent-labels')
        output = Path(args.output).resolve()
        require(not output.exists(), 'Protocol output exists; choose NEW file')
        protocol = proposal(args.input_index)
        output.parent.mkdir(parents=True, exist_ok=True); write(output, protocol)
        print(tune.canonical({'protocol': str(output), 'sha256': tune.sha(output), 'model_forwards': 0,
                              'optimizer_steps': 0, 'eligible_groups': 88, 'schedule_steps': STEPS}))
    else:
        execute(args)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError) as error:
        print('ball-expanded-tune: '+str(error), file=sys.stderr)
        raise SystemExit(2)
