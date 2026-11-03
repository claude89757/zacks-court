#!/usr/bin/env python3
"""Bounded, source-bound calibration sensitivity adapter; no flight fitting.

CLI: --input SOURCEJSON --protocol FROZENJSON --output NEWJSON
     [--expected-protocol-sha256 HASH], or --self-test.
The frozen sibling ball-camera-calibrate.py supplies all calibration geometry.
Every attempted sample is retained. Sample extrema describe generated cases,
not rigorous bounds, confidence intervals, qualified cameras or true speeds.
"""
import argparse
from collections import Counter
import copy
import hashlib
import json
import math
from pathlib import Path
import stat
import sys
import tempfile
import types
import unittest

import numpy as np


MODEL = 'uniform_bounded_declared_radii'
GROUND_POLICY = 'fit_ground_z_fixed_zero_ideal_plane'
MAX_BYTES = 4 * 1024 * 1024
HELPER_PATH = Path(__file__).resolve().with_name('ball-camera-calibrate.py')


class Rejected(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'duplicate_JSON_key')
        value[key] = item
    return value


def parse_json(data):
    return json.loads(data, object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(Rejected('nonfinite_JSON_input')))


def snapshot(path):
    path = Path(path).absolute()
    before = path.stat()
    require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= MAX_BYTES, 'invalid_frozen_file_size_or_type')
    data = path.read_bytes()
    after = path.stat()
    identity = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == identity,
            'frozen_file_changed_during_initial_read')
    return {'path': str(path), 'sha256': hashlib.sha256(data).hexdigest(),
            'bytes': len(data), '_identity': identity}, data


def verify_snapshots(frozen):
    checks = []
    for name, prior in frozen.items():
        try:
            current, _ = snapshot(prior['path'])
            valid = current['sha256'] == prior['sha256'] and current['_identity'] == prior['_identity']
            checks.append({'file': name, 'path': prior['path'], 'unchanged': valid,
                           'expected_sha256': prior['sha256'], 'observed_sha256': current['sha256']})
        except (OSError, Rejected) as error:
            checks.append({'file': name, 'path': prior['path'], 'unchanged': False, 'reason': str(error)})
    return checks


def load_helper(data, path):
    # Execute the exact bytes whose digest was checked, not a second import-time
    # read that might race with a helper revision. No pycache is written.
    module = types.ModuleType('frozen_camera_calibration_for_perturbation')
    module.__file__ = str(path)
    exec(compile(data, str(path), 'exec'), module.__dict__)
    require(callable(getattr(module, 'diagnose', None)) and callable(getattr(module, 'validate', None)),
            'calibration_helper_interface_missing')
    return module


def validate_protocol(protocol, document, input_sha, helper_sha):
    require(isinstance(protocol, dict), 'protocol_must_be_object')
    allowed = {'schema_version', 'protocol_id', 'input_sha256', 'calibration_helper_sha256', 'seed',
               'sample_count', 'model', 'ground_policy', 'shared_height_groups', 'systematic_height_scale_cases'}
    require(set(protocol) == allowed, 'protocol_fields_missing_or_unrecognized')
    require(type(protocol['schema_version']) is int and protocol['schema_version'] == 1, 'unsupported_protocol_schema')
    require(isinstance(protocol['protocol_id'], str) and 0 < len(protocol['protocol_id'].strip()) <= 256, 'invalid_protocol_id')
    require(digest(protocol['input_sha256']) and protocol['input_sha256'] == input_sha, 'frozen_input_sha256_mismatch')
    require(digest(protocol['calibration_helper_sha256']) and protocol['calibration_helper_sha256'] == helper_sha,
            'frozen_calibration_helper_sha256_mismatch')
    require(type(protocol['seed']) is int and 0 <= protocol['seed'] < 2**32, 'invalid_seed')
    require(type(protocol['sample_count']) is int and 1 <= protocol['sample_count'] <= 256, 'sample_count_must_be_1_through_256')
    require(protocol['model'] == MODEL, 'unsupported_perturbation_model')
    require(protocol['ground_policy'] == GROUND_POLICY, 'explicit_ideal_ground_plane_policy_required')
    by_id = {row['id']: row for row in document['landmarks']}
    groups, cases = protocol['shared_height_groups'], protocol['systematic_height_scale_cases']
    require(isinstance(groups, list) and len(groups) <= 16, 'invalid_shared_height_groups')
    require(isinstance(cases, list) and 1 <= len(cases) <= 8, 'one_through_eight_systematic_height_scale_cases_required')
    ids, grouped_landmarks = set(), set()
    for kind, entries in [('group', groups), ('scale_case', cases)]:
        for entry in entries:
            require(isinstance(entry, dict), 'systematic_entry_must_be_object')
            expected = {'id', 'landmark_ids', 'z_offset_radius_m' if kind == 'group' else 'height_scale'}
            require(set(entry) == expected, 'invalid_systematic_entry_fields')
            identifier = entry['id']
            require(isinstance(identifier, str) and 0 < len(identifier.strip()) <= 256 and identifier not in ids,
                    'duplicate_or_invalid_systematic_id')
            ids.add(identifier)
            targets = entry['landmark_ids']
            require(isinstance(targets, list) and 2 <= len(targets) <= len(by_id) and
                    all(isinstance(x, str) and x in by_id for x in targets), 'invalid_systematic_landmark_ids')
            require(len(set(targets)) == len(targets), 'duplicate_systematic_landmark_id')
            require(all(by_id[x]['role'] != 'fit_ground' and abs(by_id[x]['xyz_m'][2]) > 1e-9 for x in targets),
                    'systematic_height_targets_must_be_elevated_not_ground')
            if kind == 'group':
                radius = entry['z_offset_radius_m']
                require(finite(radius) and 0 <= radius <= 1e6, 'invalid_shared_height_radius')
                require(not grouped_landmarks.intersection(targets), 'overlapping_shared_height_groups_not_supported')
                grouped_landmarks.update(targets)
            else:
                scale = entry['height_scale']
                require(finite(scale) and 0 < scale <= 1e6 and scale != 1, 'nonidentity_positive_height_scale_required')
                require(sum(by_id[x]['role'] == 'fit_elevated' for x in targets) >= 2,
                        'common_scale_case_requires_two_fit_elevated_points')


def call_calibration(helper, document):
    try:
        result = helper.diagnose(document)
        require(isinstance(result, dict), 'calibration_helper_returned_non_object')
        require(result.get('camera') is None and result.get('speed_kmh') is None and
                result.get('production') is False and result.get('calibration_qualified') is False,
                'calibration_helper_qualification_contract_changed')
        require(result.get('status') in {'conditional_candidate', 'rejected'}, 'unknown_calibration_helper_status')
        candidate = result.get('camera_candidate')
        if candidate is not None:
            require(candidate['pixel_model'] == document['camera_context']['pixel_model'], 'pixel_model_was_changed')
        # Copy isolates the saved attempt from mutable caller/helper objects.
        return copy.deepcopy(result)
    except Exception as error:
        return {'schema_version': 1, 'status': 'rejected', 'camera': None, 'camera_candidate': None,
                'production': False, 'calibration_qualified': False, 'speed_kmh': None,
                'reasons': ['calibration_call_failed: '+str(error)]}


def perturb_document(document, protocol, rng):
    changed = copy.deepcopy(document)
    groups = [{'id': group['id'], 'landmark_ids': group['landmark_ids'][:],
               'z_offset_radius_m': group['z_offset_radius_m'],
               'sampled_shared_z_offset_m': float(rng.uniform(-1., 1.)*group['z_offset_radius_m'])}
              for group in protocol['shared_height_groups']]
    by_id = {identifier: group for group in groups for identifier in group['landmark_ids']}
    deltas = []
    for original, row in zip(document['landmarks'], changed['landmarks']):
        # Draw order is frozen: all shared group offsets in protocol order,
        # then uv(2), XYZ(3) per landmark in input order, including zero radii.
        uv_delta = rng.uniform(-1., 1., 2)*original['pixel_radius_px']
        xyz_delta = rng.uniform(-1., 1., 3)*np.asarray(original['xyz_radius_m'], dtype=float)
        if row['role'] == 'fit_ground':
            xyz_delta[2] = 0.
        group = by_id.get(row['id'])
        shared = group['sampled_shared_z_offset_m'] if group else 0.
        row['xy_px'] = (np.asarray(original['xy_px'])+uv_delta).tolist()
        row['xyz_m'] = (np.asarray(original['xyz_m'])+xyz_delta+np.array([0., 0., shared])).tolist()
        if row['role'] == 'fit_ground':
            row['xyz_m'][2] = 0.
        deltas.append({'id': row['id'], 'independent_uv_delta_px': uv_delta.tolist(),
                       'independent_xyz_delta_m': xyz_delta.tolist(), 'shared_height_group_id': group['id'] if group else None,
                       'shared_z_offset_m': shared, 'ground_z_radius_ignored_m': original['xyz_radius_m'][2] if row['role'] == 'fit_ground' else None,
                       'perturbed_xy_px': row['xy_px'][:], 'perturbed_xyz_m': row['xyz_m'][:]})
    return changed, {'independent_landmark_deltas': deltas, 'shared_height_terms': groups}


def sample_range(values):
    if not values:
        return {'count': 0, 'minimum': None, 'maximum': None}
    array = np.asarray(values, dtype=float)
    require(np.isfinite(array).all(), 'nonfinite_aggregate_value')
    return {'count': len(values), 'minimum': np.min(array, axis=0).tolist(), 'maximum': np.max(array, axis=0).tolist()}


def summarize(samples):
    candidates = [row for row in samples if row['calibration']['status'] == 'conditional_candidate']
    rejected = [row for row in samples if row['calibration']['status'] == 'rejected']
    cameras = [row['calibration']['camera_candidate'] for row in candidates]
    check_rms = [row['calibration'].get('reprojection', {}).get('held_out_check', {}).get('rms_px') for row in candidates]
    reasons = Counter(reason for row in rejected for reason in set(row['calibration'].get('reasons', [])))
    return {'attempted_count': len(samples), 'candidate_count': len(candidates), 'rejected_count': len(rejected),
            'rejection_fraction_all_attempts': len(rejected)/len(samples) if samples else None,
            'candidate_indices': [row['index'] for row in candidates], 'rejected_indices': [row['index'] for row in rejected],
            'rejection_reason_counts': dict(reasons),
            'candidate_conditioned_sample_ranges': {
                'K': sample_range([c['K'] for c in cameras]), 'R': sample_range([c['R'] for c in cameras]),
                't': sample_range([c['t'] for c in cameras]),
                'camera_center_m': sample_range([row['calibration']['geometry_diagnostics']['camera_center_m'] for row in candidates]),
                'held_out_check_rms_px': sample_range([v for v in check_rms if v is not None])},
            'range_semantics': 'Elementwise extrema of generated feasible candidates only; all rejected attempts remain in the denominator. Not a rigorous bound, true confidence interval, certified worst case, or selection rule.'}


def run_diagnostic(document, protocol, helper):
    # Structural validation does not require a successful geometric solve.
    # Thus rank/depth failures still get a complete N-attempt denominator.
    helper.validate(document)
    baseline = call_calibration(helper, copy.deepcopy(document))
    rng = np.random.Generator(np.random.PCG64(protocol['seed']))
    samples = []
    for index in range(protocol['sample_count']):
        changed, perturbation = perturb_document(document, protocol, rng)
        samples.append({'index': index, 'perturbation': perturbation,
                        'calibration': call_calibration(helper, changed)})
    systematic = []
    for index, case in enumerate(protocol['systematic_height_scale_cases']):
        changed = copy.deepcopy(document)
        changes = []
        for row in changed['landmarks']:
            if row['id'] in case['landmark_ids']:
                original = row['xyz_m'][2]
                row['xyz_m'][2] = original*case['height_scale']
                changes.append({'id': row['id'], 'original_xyz_m': next(x['xyz_m'][:] for x in document['landmarks'] if x['id'] == row['id']),
                                'perturbed_xyz_m': row['xyz_m'][:], 'xy_px_unchanged': row['xy_px'][:]})
        systematic.append({'index': index, 'id': case['id'], 'height_scale': case['height_scale'],
                           'changes': changes, 'calibration': call_calibration(helper, changed),
                           'semantics': 'Predeclared common multiplicative height error, with original pixels and no random jitter. Separate from the N random samples; never an independent per-point noise model.'})
    return {'schema_version': 1, 'status': 'conditional_sensitivity_completed', 'camera': None,
            'speed_kmh': None, 'production': False, 'calibration_qualified': False,
            'reasons': [], 'baseline': baseline, 'samples': samples, 'systematic_height_scale_cases': systematic,
            'summary': summarize(samples),
            'input_landmark_radii': [{key: copy.deepcopy(row[key]) for key in
                                      ['id', 'role', 'pixel_radius_px', 'xyz_radius_m', 'pixel_basis', 'xyz_basis']} for row in document['landmarks']],
            'input_binding': {key: copy.deepcopy(document['source'][key]) for key in
                              ['sha256', 'frame_image_sha256', 'frame_pts', 'frame_time_base', 'width', 'height', 'coordinate_space', 'frame_transform_id']},
            'protocol': copy.deepcopy(protocol),
            'sampling': {'generator': 'numpy.random.PCG64', 'numpy_version': np.__version__,
                         'independent_uv_distribution': 'Each coordinate independently uniform in [-pixel_radius_px,+pixel_radius_px]',
                         'independent_xyz_distribution': 'Each coordinate independently uniform in its declared +/-xyz_radius_m, except fit_ground z is fixed0',
                         'shared_height_distribution': 'One uniform shared offset per declared group per sample, added after independent XYZ perturbations',
                         'draw_order': 'All group terms in protocol order, then uv2/XYZ3 for each landmark in input order; zero-radius terms still consume draws',
                         'ground_policy': GROUND_POLICY, 'baseline_and_fixed_cases_in_random_denominator': False},
            'limits': ['Sampled ranges are not rigorous geometric bounds, empirical accuracy, or true statistical confidence intervals.',
                       'Ground remains an ideal plane at z=0; any declared ground-z radii are recorded but deliberately not propagated.',
                       'Uniform independent component errors are a declared diagnostic model, not an established error distribution. Unmodeled correlations remain unknown.',
                       'A shared-height term is a common systematic offset, never silently represented as independent point noise.',
                       'Unknown distortion, static/crop validity, source session identity, and human/physical qualification remain unresolved as in the input.',
                       'No best camera is selected. No flight, speed fit, video decoding, point creation, or App integration occurs.']}


def execute_files(input_path, protocol_path, expected_protocol_sha=None, helper_path=HELPER_PATH):
    frozen = {}
    result = {'schema_version': 1, 'status': 'rejected', 'camera': None, 'speed_kmh': None,
              'production': False, 'calibration_qualified': False, 'reasons': []}
    try:
        frozen['input'], input_bytes = snapshot(input_path)
        frozen['protocol'], protocol_bytes = snapshot(protocol_path)
        frozen['calibration_helper'], helper_bytes = snapshot(helper_path)
        frozen['adapter'], _ = snapshot(Path(__file__))
        if expected_protocol_sha is not None:
            require(digest(expected_protocol_sha) and expected_protocol_sha == frozen['protocol']['sha256'], 'expected_protocol_sha256_mismatch')
        document, protocol = parse_json(input_bytes), parse_json(protocol_bytes)
        # The trusted helper validates input shape before protocol IDs are read.
        require(isinstance(protocol, dict), 'protocol_must_be_object')
        require(digest(protocol.get('input_sha256')) and protocol['input_sha256'] == frozen['input']['sha256'],
                'frozen_input_sha256_mismatch')
        require(protocol.get('calibration_helper_sha256') == frozen['calibration_helper']['sha256'], 'frozen_calibration_helper_sha256_mismatch')
        helper = load_helper(helper_bytes, helper_path)
        helper.validate(document)
        validate_protocol(protocol, document, frozen['input']['sha256'], frozen['calibration_helper']['sha256'])
        before = verify_snapshots(frozen)
        require(all(row['unchanged'] for row in before), 'frozen_file_changed_before_sampling')
        result = run_diagnostic(document, protocol, helper)
        result['integrity_before'] = before
    except Exception as error:
        result['reasons'].append(str(error))
    after = verify_snapshots(frozen)
    result['integrity_after'] = after
    result['file_bindings'] = {name: {key: value for key, value in item.items() if key != '_identity'} for name, item in frozen.items()}
    result['external_protocol_digest_supplied'] = expected_protocol_sha is not None
    if any(not row['unchanged'] for row in after):
        result['status'] = 'integrity_rejected'
        result['reasons'].append('frozen_file_changed_during_run_results_not_admissible')
    result['integrity_verified_before_and_after'] = result.get('status') == 'conditional_sensitivity_completed' and all(row['unchanged'] for row in after)
    return result


def example_protocol(document_bytes, helper_bytes, sample_count=4):
    return {'schema_version': 1, 'protocol_id': 'synthetic-adapter-self-test-only',
            'input_sha256': hashlib.sha256(document_bytes).hexdigest(),
            'calibration_helper_sha256': hashlib.sha256(helper_bytes).hexdigest(),
            'seed': 20261029, 'sample_count': sample_count, 'model': MODEL, 'ground_policy': GROUND_POLICY,
            'shared_height_groups': [],
            'systematic_height_scale_cases': [{'id': 'synthetic-common-height-scale-risk',
                                               'landmark_ids': ['fit_elevated-0', 'fit_elevated-1'], 'height_scale': .8/1.07}]}


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helper_bytes = HELPER_PATH.read_bytes()
        cls.helper = load_helper(cls.helper_bytes, HELPER_PATH)

    def inputs(self, count=4):
        document, _ = self.helper.synthetic_document()
        encoded = json.dumps(document).encode()
        return document, example_protocol(encoded, self.helper_bytes, count)

    def test_zero_radii_exact_reproduction_and_determinism(self):
        document, protocol = self.inputs()
        first = run_diagnostic(document, protocol, self.helper)
        second = run_diagnostic(document, protocol, self.helper)
        self.assertEqual(first, second)
        for row in first['samples']:
            self.assertEqual(row['calibration']['camera_candidate'], first['baseline']['camera_candidate'])
            self.assertEqual(row['calibration']['reprojection'], first['baseline']['reprojection'])

    def test_bounded_independent_and_shared_terms_and_ideal_ground(self):
        document, protocol = self.inputs(8)
        for row in document['landmarks']:
            row['pixel_radius_px'] = 2.; row['xyz_radius_m'] = [.01, .02, .03]
        protocol['shared_height_groups'] = [{'id': 'shared-net', 'landmark_ids': ['fit_elevated-0', 'fit_elevated-1'], 'z_offset_radius_m': .04}]
        out = run_diagnostic(document, protocol, self.helper)
        original = {row['id']: row for row in document['landmarks']}
        for sample in out['samples']:
            group_value = sample['perturbation']['shared_height_terms'][0]['sampled_shared_z_offset_m']
            self.assertLessEqual(abs(group_value), .04)
            for row in sample['perturbation']['independent_landmark_deltas']:
                self.assertTrue(all(abs(x) <= 2 for x in row['independent_uv_delta_px']))
                self.assertTrue(all(abs(x) <= radius for x, radius in zip(row['independent_xyz_delta_m'], [.01, .02, .03])))
                if original[row['id']]['role'] == 'fit_ground':
                    self.assertEqual(row['perturbed_xyz_m'][2], 0)
                    self.assertEqual(row['ground_z_radius_ignored_m'], .03)
                elif row['id'].startswith('fit_elevated'):
                    self.assertEqual(row['shared_z_offset_m'], group_value)
                    self.assertAlmostEqual(row['perturbed_xyz_m'][2]-original[row['id']]['xyz_m'][2]-row['independent_xyz_delta_m'][2], group_value)

    def test_rejections_stay_in_denominator(self):
        document, protocol = self.inputs(3)
        off = [x for x in document['landmarks'] if x['role'] == 'fit_elevated']; off[1]['xy_px'] = off[0]['xy_px'][:]
        out = run_diagnostic(document, protocol, self.helper)
        self.assertEqual(out['summary']['attempted_count'], 3)
        self.assertEqual(out['summary']['rejected_count'], 3)
        self.assertEqual(out['summary']['rejection_fraction_all_attempts'], 1.)
        self.assertEqual(out['summary']['rejected_indices'], [0, 1, 2])
        self.assertEqual(out['summary']['candidate_conditioned_sample_ranges']['K']['count'], 0)

    def test_unknown_raw_and_systematic_height_risk_never_qualify(self):
        document, protocol = self.inputs(2); document['camera_context']['pixel_model'] = 'raw_unknown'
        out = run_diagnostic(document, protocol, self.helper)
        for result in [out['baseline']]+[s['calibration'] for s in out['samples']]+[s['calibration'] for s in out['systematic_height_scale_cases']]:
            self.assertIsNone(result['camera']); self.assertIsNone(result['speed_kmh'])
            self.assertFalse(result['calibration_qualified']); self.assertFalse(result['production'])
            self.assertEqual(result['camera_candidate']['pixel_model'], 'raw_unknown')
        wrong = out['systematic_height_scale_cases'][0]['calibration']
        self.assertLess(wrong['reprojection']['fit_elevated']['rms_px'], 1e-7)
        self.assertGreater(wrong['reprojection']['held_out_check']['rms_px'], 1.)

    def test_protocol_bounds_and_hash_mismatches(self):
        document, protocol = self.inputs()
        input_sha, helper_sha = protocol['input_sha256'], protocol['calibration_helper_sha256']
        for key, value, reason in [('sample_count', 257, 'sample_count_must_be_1_through_256'),
                                    ('sample_count', True, 'sample_count_must_be_1_through_256'),
                                    ('input_sha256', '0'*64, 'frozen_input_sha256_mismatch'),
                                    ('calibration_helper_sha256', '0'*64, 'frozen_calibration_helper_sha256_mismatch'),
                                    ('systematic_height_scale_cases', [], 'one_through_eight_systematic_height_scale_cases_required')]:
            changed = copy.deepcopy(protocol); changed[key] = value
            with self.subTest(reason=reason), self.assertRaisesRegex(Rejected, reason):
                validate_protocol(changed, document, input_sha, helper_sha)

    def test_shared_group_overlap_is_not_silently_independent(self):
        document, protocol = self.inputs()
        entry = {'id': 'a', 'landmark_ids': ['fit_elevated-0', 'fit_elevated-1'], 'z_offset_radius_m': .1}
        protocol['shared_height_groups'] = [entry, dict(entry, id='b')]
        with self.assertRaisesRegex(Rejected, 'overlapping_shared_height_groups_not_supported'):
            validate_protocol(protocol, document, protocol['input_sha256'], protocol['calibration_helper_sha256'])

    def test_frozen_file_change_after_sampling_rejects_whole_run(self):
        document, protocol = self.inputs(1)
        with tempfile.TemporaryDirectory(prefix='camera-perturb-synthetic-') as directory:
            source, spec = Path(directory)/'input.json', Path(directory)/'protocol.json'
            source.write_text(json.dumps(document)); spec.write_text(json.dumps(protocol))
            expected = hashlib.sha256(spec.read_bytes()).hexdigest()
            original = globals()['run_diagnostic']
            def mutate_after_run(*args):
                result = original(*args)
                source.write_text(source.read_text()+'\n')
                return result
            globals()['run_diagnostic'] = mutate_after_run
            try:
                out = execute_files(source, spec, expected)
            finally:
                globals()['run_diagnostic'] = original
            self.assertEqual(out['status'], 'integrity_rejected')
            self.assertEqual(len(out['samples']), 1)
            self.assertFalse(out['integrity_verified_before_and_after'])
            self.assertIsNone(out['camera']); self.assertFalse(out['calibration_qualified'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input'); parser.add_argument('--protocol'); parser.add_argument('--output')
    parser.add_argument('--expected-protocol-sha256'); parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests)).wasSuccessful() else 1
    if not args.input or not args.protocol or not args.output:
        parser.error('--input, --protocol and --output are required')
    output = Path(args.output)
    if output.exists():
        print('Refusing to overwrite output: '+str(output), file=sys.stderr)
        return 2
    result = execute_files(args.input, args.protocol, args.expected_protocol_sha256)
    try:
        with output.open('x') as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2, allow_nan=False); handle.write('\n')
    except (OSError, ValueError) as error:
        print('Cannot save new sensitivity diagnostic: '+str(error), file=sys.stderr)
        return 2
    print(json.dumps({'status': result['status'], 'camera': None, 'speed_kmh': None,
                      'calibration_qualified': False, 'summary': result.get('summary'),
                      'reasons': result['reasons'], 'output': str(output)}))
    return 0 if result['status'] == 'conditional_sensitivity_completed' else 1


if __name__ == '__main__':
    sys.exit(main())
