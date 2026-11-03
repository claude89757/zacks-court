#!/usr/bin/env python3
"""One frozen private WASB tennis CPU-FP32 development evaluation, never training.

--propose NEWJSON [--checkpoint PATH] writes a reviewable protocol without
loading weights or instantiating HRNet. Run only after externally freezing its
digest: --protocol JSON --protocol-sha256 HASH --output NEWDIRECTORY.
--self-test uses generated images/logits and mocked checkpoint loading only.
"""
import argparse
from collections import Counter
import copy
from fractions import Fraction
import hashlib
import io
import json
import math
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

import cv2
import numpy as np
from PIL import Image, __version__ as PIL_VERSION
import torch
import yaml


ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT/'.local/speed-training/tennis-pretrain-20261029'
PIN = '923462cacdeb3353b84ddebdedb3f4b7a8553b0f'
CHECKPOINT_SHA = '9d391239ab10c733f8e5bfadf16ab72838e7a8ebc88e8ae2038501c03d42b4bb'
CHECKPOINT_BYTES = 6102633
WINDOWS = ['train-006', 'train-007', 'train-008', 'eval-002']
SOURCE_HASHES = {'dd4d8897325de33f9bfb46f3d83eecba1c66fb2457d1ab2c07daf0f18d0bb13e',
                 '5c1d17a70834555c154058658145e2170e8feb4600ff8e80c03544db7ffaa5ed'}
MODEL_FILE = 'src/models/hrnet.py'
AFFINE_FILE = 'src/utils/image.py'
CONFIG_FILE = 'src/configs/model/wasb.yaml'
CORE_SHA = {MODEL_FILE: '862ce90279a44ad19dd0590e073a8089c1cf4bd79eca0930189dda9106fa83f5',
            AFFINE_FILE: '989e380db81405ac435d88515ccf4070b9c1d8f9b600334caaf2d04a5c02c9f2',
            CONFIG_FILE: 'cab434199852e2c6b50aeb9881c0032931d3d2b16492afade6eb8b8866ab07f0'}
POLICY = {'name': 'author_WASB_tennis_step3_CPU_float32_v1', 'frames_per_window': 120,
          'window_count': 4, 'triplet_step': 3, 'triplets_per_window': 40,
          'threshold_strictly_greater_than': .5, 'connectivity': 8,
          'tracker_distance_strictly_less_than_original_px': 300.,
          'candidate_score': 'foreground_probability_mass_float32_sum',
          'ties': 'first_OpenCV_component_label_under_strict_mass_comparison; version/thread dependent',
          'equivalent_size': [1280, 720], 'agent_hit_radius_equivalent_px': 10.,
          'agent_wrong_strictly_greater_than_equivalent_px': 20.,
          'maximum_lookahead_frames': 2, 'tensor_shape': [1, 9, 288, 512],
          'export_first_triplet_per_window': True,
          'rgb_mean': [.485, .456, .406], 'rgb_std': [.229, .224, .225],
          'all_candidates_retained': True, 'training': False, 'threshold_search': False}
LIMITS = ['Author-provided evaluation checkpoint only. External checkpoint commercial/redistribution licensing is not affirmatively cleared.',
          'This is an agent-labelled private development diagnostic, not independent human or physical accuracy, ball-speed validation, or App integration.',
          'All 480 target frames remain in the denominator; 26 unknown labels are not negatives and 288 unlabelled frames are not accuracy truth.',
          'Author CUDA/DataParallel wrapper is replaced by CPU FP32 execution; model, exact YAML, affine and author decoder/tracker arithmetic are retained.',
          'OpenCV component labels break exact mass ties. Their order is recorded, not claimed cross-version invariant.']


class Rejected(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise Rejected(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'duplicate_JSON_key')
        value[key] = item
    return value


def parse(data):
    return json.loads(data, object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(Rejected('nonfinite_JSON')))


def read_bound(spec, maximum=64*1024*1024):
    require(isinstance(spec, dict) and digest(spec.get('sha256')), 'invalid_file_binding')
    path = Path(spec['path'])
    require(path.is_absolute() and path.is_file(), 'bound_file_must_be_absolute_regular_file')
    before = path.stat()
    require(before.st_size <= maximum, 'bound_file_too_large')
    data = path.read_bytes(); after = path.stat()
    require((before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
            (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'bound_file_changed_during_read')
    require(sha(data) == spec['sha256'], 'bound_file_sha256_mismatch: '+str(path))
    if 'bytes' in spec:
        require(len(data) == spec['bytes'], 'bound_file_size_mismatch')
    return data


def bind(path):
    path = Path(path).resolve(); data = path.read_bytes()
    return {'path': str(path), 'bytes': len(data), 'sha256': sha(data)}


def opencv_parallel_framework():
    for line in cv2.getBuildInformation().splitlines():
        if line.strip().startswith('Parallel framework:'):
            return line.split(':', 1)[1].strip()
    raise Rejected('OpenCV_parallel_framework_not_reported')


def runtime():
    return {'python': platform.python_version(), 'numpy': np.__version__, 'torch': torch.__version__,
            'opencv': cv2.__version__, 'pillow': PIL_VERSION, 'pyyaml': yaml.__version__,
            'torch_threads': 4, 'torch_interop_threads': 1,
            'opencv_requested_threads': 0, 'opencv_threads': 1,
            'opencv_parallel_framework': opencv_parallel_framework(),
            'device': 'cpu', 'dtype': 'float32'}


def isolated_module(data, name, path):
    module = types.ModuleType(name); module.__file__ = str(path)
    exec(compile(data, str(path), 'exec'), module.__dict__)
    return module


class ConfigMapping(dict):
    """Read the same YAML mapping through both author access conventions."""
    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name) from None


def config_access(value):
    if isinstance(value, dict):
        return ConfigMapping({key: config_access(item) for key, item in value.items()})
    if isinstance(value, list):
        return [config_access(item) for item in value]
    return value


def source_inputs(protocol):
    audit = parse(read_bound(protocol['source_audit'], 2*1024*1024))
    source = protocol['official_source']; root = Path(source['path']).resolve()
    require(source['commit'] == PIN, 'wrong_official_commit')
    head = subprocess.run(['git', '-C', str(root), 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
    require(head == PIN, 'official_checkout_commit_changed')
    expected = audit['source_file_hashes']['WASB-SBDT']
    require(source['files'] == expected, 'official_file_list_differs_from_frozen_source_audit')
    require(all(expected.get(k) == v for k, v in CORE_SHA.items()), 'official_core_source_not_pinned_version')
    blobs, bindings = {}, []
    for relative, value in source['files'].items():
        path = (root/relative).resolve(); require(path.is_relative_to(root), 'unsafe_official_source_path')
        spec = {'path': str(path), 'sha256': value}; blobs[relative] = read_bound(spec, 2*1024*1024); bindings.append(spec)
    cfg = config_access(yaml.safe_load(blobs[CONFIG_FILE]))
    require(cfg['name'] == 'hrnet' and cfg['frames_in'] == cfg['frames_out'] == 3 and cfg['rgb_diff'] is False and
            cfg['out_scales'] == [0] and [cfg['inp_width'], cfg['inp_height'], cfg['out_width'], cfg['out_height']] == [512, 288, 512, 288],
            'unexpected_author_model_configuration')
    return blobs, cfg, bindings


def resolve_windows(manifest):
    require(manifest.get('independent_test_established') is False, 'this_runner_is_development_only')
    sources = {s['source_id']: s for s in manifest['sources']}
    require({s['source_sha256'] for s in sources.values()} == SOURCE_HASHES, 'unexpected_or_reserved_source_family')
    root = Path(manifest['data_root']).resolve()
    by_id = {w['window_id']: w for w in manifest['windows']}
    require(set(by_id) == set(WINDOWS) and len(manifest['windows']) == 4, 'fixed_four_development_windows_required')
    windows, image_bindings = [], []
    for identifier in WINDOWS:
        window = copy.deepcopy(by_id[identifier]); frames = window['frames']
        source = sources[window['source_id']]
        require(window['source_sha256'] == source['source_sha256'] and len(frames) == 120, 'window_source_or_count_mismatch')
        fps = Fraction(source['nominal_frame_rate']); previous = None
        require(fps > 0, 'invalid_nominal_fps')
        for index, frame in enumerate(frames):
            require(type(frame['frame_index']) is int and frame['frame_index'] == index and type(frame['source_pts']) is int, 'invalid_frame_index_or_pts')
            stamp = frame['source_pts']*Fraction(frame['source_time_base'])
            require(Fraction(frame['source_time_base']) > 0 and (previous is None or 0 < stamp-previous <= Fraction(3, 2)/fps),
                    'noncontinuous_source_window_no_padding_allowed')
            previous = stamp
            require(frame['width'] == window['width'] == source['width'] and frame['height'] == window['height'] == source['height'], 'frame_dimensions_not_original_source')
            path = (root/frame['image_path']).resolve()
            require(path.is_relative_to(root) and path.suffix.lower() in {'.jpg', '.jpeg'}, 'unsafe_or_non_JPEG_frame_path')
            frame['absolute_image_path'] = str(path)
            image_bindings.append({'path': str(path), 'sha256': frame['image_sha256']})
        windows.append(window)
    return windows, image_bindings


def read_labels(protocol, manifest, windows):
    train_bytes = read_bound(protocol['train_manifest'], 4*1024*1024)
    train_manifest = parse(train_bytes)
    require(train_manifest['manifest_subset'] == 'train_only' and
            train_manifest['parent_manifest_sha256'] == protocol['manifest']['sha256'], 'train_manifest_parent_mismatch')
    frames = {(w['window_id'], f['frame_index']): (w, f) for w in windows for f in w['frames']}
    labels = {}
    require(len(protocol['labels']) == 2, 'exact_two_agent_label_files_required')
    for spec in protocol['labels']:
        data = parse(read_bound(spec, 4*1024*1024))
        require(data['reviewer_kind'] == 'agent' and data['human_validated'] is False, 'only_frozen_agent_development_labels_supported')
        if 'source_train_manifest_sha256' in data:
            require(data['source_train_manifest_sha256'] == protocol['train_manifest']['sha256'], 'train_label_manifest_mismatch')
        if 'manifest_sha256' in data:
            require(data['manifest_sha256'] == protocol['manifest']['sha256'], 'eval_label_manifest_mismatch')
        for row in data['records']:
            key = (row['window_id'], row['frame_index'])
            require(key in frames and key not in labels and row['reviewer_kind'] == 'agent' and row['formal_eligible'] is False, 'invalid_duplicate_or_nonagent_label')
            window, frame = frames[key]
            require(row['source_pts'] == frame['source_pts'] and Fraction(row['source_time_base']) == Fraction(frame['source_time_base']) and
                    row['image_sha256'] == frame['image_sha256'], 'label_image_or_pts_binding_mismatch')
            if 'source_sha256' in row:
                require(row['source_sha256'] == window['source_sha256'], 'label_source_sha_mismatch')
            space = row['coordinate_space']
            dimensions = [space['width'], space['height']] if isinstance(space, dict) else [int(x) for x in space.split('x')]
            require(dimensions == [window['width'], window['height']], 'label_coordinate_space_mismatch')
            require(row['status'] in {'visible', 'unknown'}, 'unsupported_agent_label_status')
            if row['status'] == 'visible':
                require(row['target_identity'] == 'confirmed' and all(isinstance(row.get(k), (int, float)) and not isinstance(row[k], bool) and math.isfinite(row[k]) for k in ['x', 'y']), 'invalid_visible_agent_label')
                require(0 <= row['x'] < window['width'] and 0 <= row['y'] < window['height'], 'agent_label_outside_image')
            else:
                require(row['x'] is None and row['y'] is None, 'unknown_agent_coordinates_must_be_null')
            labels[key] = row
    require(len(labels) == 192 and sum(r['status'] == 'visible' for r in labels.values()) == 166, 'fixed_192_labels_166_visible_required')
    return labels


def affine_for(width, height, official):
    center = np.array([width/2., height/2.], dtype=np.float32)
    return (official.get_affine_transform(center, max(width, height)*1., 0, [512, 288]),
            official.get_affine_transform(center, max(width, height)*1., 0, [512, 288], inv=1))


def preprocess(rgb_frames, official):
    require(len(rgb_frames) == 3 and all(frame.dtype == np.uint8 and frame.ndim == 3 and frame.shape[2] == 3 for frame in rgb_frames), 'three_uint8_RGB_frames_required')
    shape = rgb_frames[0].shape; require(all(frame.shape == shape for frame in rgb_frames), 'triplet_dimensions_changed')
    trans, inverse = affine_for(shape[1], shape[0], official)
    mean = torch.tensor(POLICY['rgb_mean'], dtype=torch.float32)[:, None, None]
    std = torch.tensor(POLICY['rgb_std'], dtype=torch.float32)[:, None, None]
    tensors, hashes = [], []
    for rgb in rgb_frames:
        warped = cv2.warpAffine(rgb, trans, (512, 288), flags=cv2.INTER_LINEAR)
        hashes.append(sha(warped.tobytes(order='C')))
        tensor = torch.from_numpy(warped.transpose(2, 0, 1).copy()).to(dtype=torch.float32).div_(255.)
        tensors.append(tensor.sub_(mean).div_(std))
    tensor = torch.cat(tensors, dim=0).unsqueeze(0).contiguous()
    require(list(tensor.shape) == [1, 9, 288, 512] and tensor.dtype == torch.float32 and tensor.device.type == 'cpu' and bool(torch.isfinite(tensor).all()), 'invalid_preprocessed_tensor')
    return tensor, inverse, {'forward_affine': trans.tolist(), 'inverse_affine': inverse.tolist(),
                             'warped_RGB8_sha256': hashes, 'tensor_sha256': sha(tensor.numpy().tobytes(order='C')),
                             'tensor_storage': 'contiguous_CPU_float32_little_endian_NCHW', 'rgb_order': 'R0,G0,B0,R1,G1,B1,R2,G2,B2'}


def decode(heatmap, inverse):
    require(heatmap.dtype == np.float32 and heatmap.ndim == 2 and np.isfinite(heatmap).all() and np.all((heatmap >= 0) & (heatmap <= 1)), 'invalid_probability_heatmap')
    _, foreground = cv2.threshold(heatmap, .5, 1, cv2.THRESH_BINARY)
    count, component_labels = cv2.connectedComponents(foreground.astype(np.uint8), connectivity=8, ltype=cv2.CV_32S)
    bank = []
    for label in range(1, count):
        ys, xs = np.where(component_labels == label); weights = heatmap[ys, xs]
        mass = weights.sum()  # Author arithmetic: FLOAT32 sum; numerator uses integer coordinates.
        x, y = np.sum(np.array(xs)*weights)/np.sum(weights), np.sum(np.array(ys)*weights)/np.sum(weights)
        original = np.dot(inverse, np.array([x, y, 1.], dtype=np.float32))[:2]
        bank.append({'component_label': label, 'raster_seed_xy': [int(xs[0]), int(ys[0])], 'area_px': int(len(xs)),
                     'mass': float(mass), 'centroid_model_xy': [float(x), float(y)], 'original_xy': original.tolist()})
    return bank


class Tracker:
    def __init__(self):
        self.previous = None

    def select(self, bank):
        best = None
        for candidate in bank:
            distance = None if self.previous is None else float(np.linalg.norm(np.asarray(candidate['original_xy'])-self.previous))
            candidate['distance_from_previous_visible_original_px'] = distance
            candidate['eligible_under_300px_gate'] = distance is None or distance < 300.
            if candidate['eligible_under_300px_gate'] and (best is None or candidate['mass'] > best['mass']):
                best = candidate
        self.previous = None if best is None else np.asarray(best['original_xy'])
        return best


def state_digest(state):
    result = hashlib.sha256()
    for key in sorted(state):
        value = state[key]
        require(isinstance(key, str) and isinstance(value, torch.Tensor) and value.device.type == 'cpu' and value.layout == torch.strided, 'non_tensor_or_non_CPU_checkpoint_state')
        require(not value.is_complex(), 'complex_checkpoint_state_not_supported')
        require(not value.is_floating_point() or value.dtype == torch.float32, 'checkpoint_floating_state_not_float32')
        require(bool(torch.isfinite(value).all()), 'nonfinite_checkpoint_state')
        raw = value.detach().contiguous().reshape(-1).view(torch.uint8).numpy().tobytes()
        header = json.dumps([key, str(value.dtype), list(value.shape), len(raw)], separators=(',', ':')).encode()
        result.update(len(header).to_bytes(8, 'little')); result.update(header); result.update(raw)
    return result.hexdigest()


def strict_load(model, checkpoint_bytes):
    checkpoint = torch.load(io.BytesIO(checkpoint_bytes), weights_only=True, map_location='cpu')
    require(isinstance(checkpoint, dict) and set(checkpoint) == {'model_state_dict'}, 'unexpected_safe_checkpoint_schema')
    state = checkpoint['model_state_dict']; require(isinstance(state, dict) and bool(state), 'empty_or_invalid_model_state')
    full_sha = state_digest(state)
    loaded = model.load_state_dict(state, strict=True)
    require(not loaded.missing_keys and not loaded.unexpected_keys, 'strict_state_missing_or_unexpected_keys')
    return {'state_tensor_count': len(state), 'full_state_sha256': full_sha, 'missing_keys': [], 'unexpected_keys': [],
            'safe_load': 'torch.load(weights_only=True,map_location=cpu)', 'strict': True}


def model_state_check(model, expected_sha):
    try:
        observed = state_digest(model.state_dict())
        return {'sha256': observed, 'finite_and_matches_checkpoint': observed == expected_sha}
    except Exception as error:
        return {'sha256': None, 'finite_and_matches_checkpoint': False, 'error': type(error).__name__+': '+str(error)}


def infer_triplet(model, tensor):
    with torch.inference_mode():
        raw = model(tensor)
        require(isinstance(raw, dict) and set(raw) == {0}, 'model_output_must_be_dict_key_zero_only')
        logits = raw[0]
        require(isinstance(logits, torch.Tensor) and list(logits.shape) == [1, 3, 288, 512] and logits.dtype == torch.float32 and
                logits.device.type == 'cpu' and bool(torch.isfinite(logits).all()), 'invalid_nonfinite_or_non_CPU_FP32_logits')
        logits_hash = sha(logits.detach().contiguous().numpy().tobytes())
        probabilities = logits.sigmoid()  # Exactly one sigmoid, on logits only.
        require(bool(torch.isfinite(probabilities).all()), 'nonfinite_sigmoid_output')
        return probabilities[0].contiguous().numpy().copy(), logits_hash


def evaluation_row(prediction, label, width, height):
    if label is None:
        return {'label_status': 'unlabelled', 'is_accuracy_truth': False}
    if label['status'] == 'unknown':
        return {'label_status': 'unknown', 'is_accuracy_truth': False}
    if prediction is None:
        return {'label_status': 'agent_visible', 'category': 'miss', 'equivalent_error_px': None, 'is_independent_truth': False}
    error = float(np.linalg.norm((np.asarray(prediction)-np.array([label['x'], label['y']]))*np.array([1280./width, 720./height])))
    return {'label_status': 'agent_visible', 'category': 'hit_le10' if error <= 10 else ('wrong_gt20' if error > 20 else 'between10_and20'),
            'equivalent_error_px': error, 'is_independent_truth': False}


def export_float32(path, array, layout):
    require(array.dtype == np.float32 and sys.byteorder == 'little', 'evidence_requires_little_endian_float32')
    payload = array.tobytes(order='C')
    with path.open('xb') as handle:
        handle.write(payload)
    return {'path': str(path.resolve()), 'sha256': sha(payload), 'bytes': len(payload),
            'shape': list(array.shape), 'dtype': 'float32', 'byte_order': 'little', 'layout': layout}


def propose(checkpoint):
    data = ROOT/'.local/speed-training/ball-tune-20261029'
    audit_spec = bind(BASE/'source-audit/audit.json'); audit = parse(read_bound(audit_spec))
    source = BASE/'source-audit/WASB-SBDT'
    protocol = {'schema_version': 1, 'protocol_id': 'WASB-author-tennis-four-development-windows-v1',
                'runner_sha256': bind(__file__)['sha256'], 'source_audit': audit_spec,
                'official_source': {'path': str(source), 'commit': PIN, 'files': audit['source_file_hashes']['WASB-SBDT']},
                'checkpoint': dict(bind(checkpoint), state_key='model_state_dict'),
                'manifest': bind(data/'data/manifest.json'), 'train_manifest': bind(data/'data/train-manifest.json'),
                'labels': [bind(data/'visual-audit/train-agent-labels.json'), bind(data/'root-audit/eval-labels.json')],
                'window_ids': WINDOWS, 'runtime': runtime(), 'policy': POLICY, 'public_speed_kmh': None,
                'license_scope': 'author_checkpoint_private_evaluation_only_no_commercial_or_distribution_clearance'}
    require(protocol['checkpoint']['sha256'] == CHECKPOINT_SHA and protocol['checkpoint']['bytes'] == CHECKPOINT_BYTES, 'not_the_one_selected_author_tennis_checkpoint')
    source_inputs(protocol)
    manifest = parse(read_bound(protocol['manifest'])); windows, _ = resolve_windows(manifest)
    read_labels(protocol, manifest, windows)
    return protocol


def validate_protocol(protocol):
    require(type(protocol.get('schema_version')) is int and protocol['schema_version'] == 1, 'invalid_protocol_schema')
    require(protocol.get('runner_sha256') == bind(__file__)['sha256'], 'runner_changed_since_protocol_freeze')
    require(protocol['policy'] == POLICY and protocol['window_ids'] == WINDOWS and protocol['runtime'] == runtime(), 'policy_windows_or_dependencies_not_frozen_runtime')
    require(protocol.get('public_speed_kmh') is None and protocol.get('license_scope') == 'author_checkpoint_private_evaluation_only_no_commercial_or_distribution_clearance', 'unsupported_qualification_or_license_scope')
    require(protocol['checkpoint']['sha256'] == CHECKPOINT_SHA and protocol['checkpoint']['bytes'] == CHECKPOINT_BYTES and protocol['checkpoint']['state_key'] == 'model_state_dict', 'wrong_selected_checkpoint_binding')


def run(protocol, output):
    validate_protocol(protocol)
    blobs, config, source_bindings = source_inputs(protocol)
    manifest = parse(read_bound(protocol['manifest'], 4*1024*1024)); windows, images = resolve_windows(manifest)
    labels = read_labels(protocol, manifest, windows)
    bindings = [protocol['source_audit'], protocol['manifest'], protocol['train_manifest'], *protocol['labels'],
                protocol['checkpoint'], {'path': str(Path(__file__).resolve()), 'sha256': protocol['runner_sha256']}, *source_bindings, *images]
    # All 480 original JPEG bytes are verified before creating/loading a model.
    for spec in images:
        read_bound(spec)
    checkpoint_bytes = read_bound(protocol['checkpoint'])
    # GCD accepts nonpositive thread controls; 0 explicitly disables OpenCV
    # parallelism. Positive1 may still report the processor count on macOS.
    # https://docs.opencv.org/4.11.0/db/de0/group__core__utils.html
    torch.set_num_threads(4); torch.set_num_interop_threads(1); cv2.setNumThreads(0)
    require(torch.get_default_dtype() == torch.float32 and sys.byteorder == 'little', 'default_dtype_or_endianness_not_frozen')
    torch.manual_seed(0)
    model_module = isolated_module(blobs[MODEL_FILE], 'frozen_author_wasb_hrnet', protocol['official_source']['path']+'/'+MODEL_FILE)
    affine = isolated_module(blobs[AFFINE_FILE], 'frozen_author_wasb_affine', protocol['official_source']['path']+'/'+AFFINE_FILE)
    model = model_module.HRNet(config).to(device='cpu', dtype=torch.float32)
    state_info = strict_load(model, checkpoint_bytes); model.eval()
    require(all(not module.training for module in model.modules()) and all(p.device.type == 'cpu' and p.dtype == torch.float32 for p in model.parameters()), 'model_not_all_modules_CPU_FP32_eval')
    state_info['loaded_model_initial'] = model_state_check(model, state_info['full_state_sha256'])
    require(state_info['loaded_model_initial']['finite_and_matches_checkpoint'], 'loaded_model_state_differs_from_checkpoint')
    require(torch.get_num_threads() == 4 and torch.get_num_interop_threads() == 1 and cv2.getNumThreads() == 1, 'execution_thread_count_not_frozen')
    state_info['execution_threads'] = {'torch_reported': torch.get_num_threads(), 'torch_interop_reported': torch.get_num_interop_threads(),
                                        'opencv_requested_threads': 0, 'opencv_reported_threads': cv2.getNumThreads(),
                                        'opencv_parallel_framework': opencv_parallel_framework()}
    del checkpoint_bytes
    evidence_root = output/'first-triplets'; evidence_root.mkdir(exist_ok=False)
    counts, windows_summary, forward_calls = Counter(), [], 0
    started = time.monotonic()
    with (output/'frames.jsonl').open('x') as frame_log, (output/'triplets.jsonl').open('x') as triplet_log:
        for window in windows:
            tracker, local = Tracker(), Counter()
            for start in range(0, 120, 3):
                triplet = window['frames'][start:start+3]; batch_started = time.monotonic()
                batch = {'window_id': window['window_id'], 'start_frame_index': start, 'input_frame_indices': [f['frame_index'] for f in triplet],
                         'available_at_pts': triplet[2]['source_pts'], 'available_at_time_base': triplet[2]['source_time_base'],
                         'error': None, 'evidence_errors': [], 'exported_evidence': {'input_tensor': None, 'probability_heatmaps': []}}
                probabilities, inverse = None, None
                try:
                    rgbs, native_hashes = [], []
                    for frame in triplet:
                        raw = read_bound({'path': frame['absolute_image_path'], 'sha256': frame['image_sha256']})
                        with Image.open(io.BytesIO(raw)) as image:
                            require(image.format == 'JPEG' and image.size == (window['width'], window['height']), 'not_original_bound_JPEG_dimensions')
                            rgb = np.array(image.convert('RGB'), dtype=np.uint8)
                        native_hashes.append(sha(rgb.tobytes())); rgbs.append(rgb)
                    tensor, inverse, prep_info = preprocess(rgbs, affine)
                    batch.update(prep_info); batch['native_RGB8_sha256'] = native_hashes
                    if start == 0:
                        try:
                            artifact = export_float32(evidence_root/(window['window_id']+'-input-float32-nchw.bin'), tensor.numpy(), 'NCHW')
                            require(artifact['sha256'] == prep_info['tensor_sha256'], 'exported_input_tensor_hash_mismatch')
                            batch['exported_evidence']['input_tensor'] = artifact
                        except Exception as error:
                            batch['evidence_errors'].append(type(error).__name__+': '+str(error))
                    forward_calls += 1
                    probabilities, logits_hash = infer_triplet(model, tensor)
                    batch['logits_sha256'] = logits_hash; batch['all_heatmaps_sha256'] = sha(probabilities.tobytes())
                    if start == 0:
                        for channel in range(3):
                            try:
                                artifact = export_float32(evidence_root/(window['window_id']+'-probability-'+str(channel)+'-float32-hw.bin'), probabilities[channel], 'HW')
                                artifact['output_channel'] = channel; artifact['frame_index'] = triplet[channel]['frame_index']
                                batch['exported_evidence']['probability_heatmaps'].append(artifact)
                            except Exception as error:
                                batch['evidence_errors'].append(type(error).__name__+': '+str(error))
                    del tensor, rgbs
                except Exception as error:
                    batch['error'] = type(error).__name__+': '+str(error)
                for offset, frame in enumerate(triplet):
                    bank, selected, error = [], None, batch['error']
                    heatmap_hash = None
                    if probabilities is not None and error is None:
                        try:
                            heatmap_hash = sha(probabilities[offset].tobytes())
                            bank = decode(probabilities[offset], inverse); selected = tracker.select(bank)
                        except Exception as failure:
                            error = type(failure).__name__+': '+str(failure); tracker.previous = None
                    else:
                        tracker.previous = None
                    point = selected['original_xy'] if selected else None
                    evaluation = evaluation_row(point, labels.get((window['window_id'], frame['frame_index'])), window['width'], window['height'])
                    reason = None if selected else ('runtime_or_input_error' if error else ('no_component_strictly_above_half' if not bank else 'all_components_outside_300px_gate'))
                    row = {'window_id': window['window_id'], 'frame_index': frame['frame_index'], 'source_sha256': window['source_sha256'],
                           'source_pts': frame['source_pts'], 'source_time_base': frame['source_time_base'], 'image_sha256': frame['image_sha256'],
                           'width': window['width'], 'height': window['height'], 'triplet_start': start, 'output_channel': offset,
                           'available_at_pts': triplet[2]['source_pts'], 'available_at_time_base': triplet[2]['source_time_base'],
                           'lookahead_frames': 2-offset, 'lookahead_time_rational': str(triplet[2]['source_pts']*Fraction(triplet[2]['source_time_base'])-frame['source_pts']*Fraction(frame['source_time_base'])),
                           'heatmap_sha256': heatmap_hash, 'candidate_bank': bank, 'candidate_count': len(bank),
                           'selected_component_label': selected['component_label'] if selected else None, 'original_xy': point,
                           'equivalent_xy': [point[0]*1280/window['width'], point[1]*720/window['height']] if point else None,
                           'visible': selected is not None, 'missing_reason': reason, 'error': error, 'agent_evaluation': evaluation,
                           'public_speed_kmh': None, 'production': False}
                    frame_log.write(json.dumps(row, allow_nan=False)+'\n'); frame_log.flush()
                    local['frames'] += 1; local['selected' if selected else 'missing'] += 1
                    if error: local['runtime_error_frames'] += 1
                    local[evaluation.get('category', evaluation['label_status'])] += 1
                batch['wall_seconds'] = time.monotonic()-batch_started
                if batch['evidence_errors']: local['evidence_error_batches'] += 1
                triplet_log.write(json.dumps(batch, allow_nan=False)+'\n'); triplet_log.flush()
            windows_summary.append({'window_id': window['window_id'], 'tracker_reset': True, **dict(local)}); counts.update(local)
    state_info['loaded_model_final'] = model_state_check(model, state_info['full_state_sha256'])
    state_info['forward_calls_attempted'] = forward_calls
    state_info['target_frames_recorded'] = counts['frames']
    state_info['unchanged_after_evaluation'] = (state_info['loaded_model_final']['finite_and_matches_checkpoint'] and
                                                state_info['loaded_model_final']['sha256'] == state_info['loaded_model_initial']['sha256'])
    post = []
    for spec in bindings:
        try:
            read_bound(spec); post.append({'path': spec['path'], 'sha256': spec['sha256'], 'unchanged': True})
        except Exception as error:
            post.append({'path': spec['path'], 'unchanged': False, 'error': str(error)})
    require(counts['frames'] == 480 and sum(counts[k] for k in ['hit_le10', 'between10_and20', 'wrong_gt20', 'miss']) == 166 and counts['unknown'] == 26, 'complete_frame_or_agent_denominator_not_retained')
    integrity = all(item['unchanged'] for item in post)
    return {'schema_version': 1, 'status': 'development_evaluation_completed' if integrity and not counts['runtime_error_frames'] and not counts['evidence_error_batches'] and state_info['unchanged_after_evaluation'] else 'development_evaluation_has_errors',
            'production': False, 'public_speed_kmh': None, 'physical_accuracy_validated': False, 'independent_human_truth': False,
            'counts': dict(counts), 'windows': windows_summary, 'state_load': state_info,
            'runtime': runtime(), 'wall_seconds': time.monotonic()-started, 'input_bindings': bindings,
            'integrity_after': post, 'integrity_verified_before_and_after': integrity,
            'policy': POLICY, 'limits': LIMITS, 'frames_path': str(output/'frames.jsonl'), 'triplets_path': str(output/'triplets.jsonl')}


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = BASE/'source-audit/WASB-SBDT'
        data = read_bound({'path': str(root/AFFINE_FILE), 'sha256': CORE_SHA[AFFINE_FILE]})
        cls.affine = isolated_module(data, 'wasb_synthetic_test_affine', root/AFFINE_FILE)

    def test_official_affine_RGB_order_and_normalization(self):
        frames = [np.full((16, 16, 3), [255, 0, 0], dtype=np.uint8), np.full((16, 16, 3), [0, 255, 0], dtype=np.uint8),
                  np.full((16, 16, 3), [0, 0, 255], dtype=np.uint8)]
        tensor, inverse, info = preprocess(frames, self.affine)
        self.assertEqual(list(tensor.shape), [1, 9, 288, 512])
        for index in range(3):
            for channel in range(3):
                expected = (float(index == channel)-POLICY['rgb_mean'][channel])/POLICY['rgb_std'][channel]
                self.assertAlmostEqual(float(tensor[0, index*3+channel, 144, 256]), expected, places=6)
        affine, inv = affine_for(1920, 1080, self.affine)
        np.testing.assert_allclose(affine, [[512/1920, 0, 0], [0, 512/1920, 0]], atol=1e-12)
        np.testing.assert_allclose(inv @ np.array([256, 144, 1], dtype=np.float32), [960, 540], atol=1e-9)
        self.assertTrue(digest(info['tensor_sha256']))

    def test_strict_threshold_eight_connection_mass_and_inverse(self):
        hm = np.zeros((6, 6), dtype=np.float32); hm[0, 0] = .5; hm[1, 1] = .6; hm[2, 2] = .9; hm[5, 5] = .8
        bank = decode(hm, np.array([[2., 0, 10], [0, 3., 20]]))
        self.assertEqual(len(bank), 2); self.assertEqual(bank[0]['area_px'], 2)
        expected_x = float((np.array([1, 2])*np.array([.6, .9], np.float32)).sum()/np.array([.6, .9], np.float32).sum())
        self.assertAlmostEqual(bank[0]['centroid_model_xy'][0], expected_x)
        self.assertAlmostEqual(bank[0]['original_xy'][0], float(np.float32(expected_x))*2+10)
        self.assertAlmostEqual(bank[0]['mass'], float(np.float32(.6)+np.float32(.9)))

    def test_no_top20_and_tracker_strict_gate_ties_and_reset_after_missing(self):
        hm = np.zeros((20, 20), dtype=np.float32); hm[::3, ::3] = .75
        self.assertEqual(len(decode(hm, np.array([[1., 0, 0], [0, 1., 0]]))), 49)
        tracker = Tracker()
        def c(label, x, mass=1): return {'component_label': label, 'original_xy': [x, 0], 'mass': mass}
        self.assertEqual(tracker.select([c(1, 0), c(2, 1)])['component_label'], 1)
        self.assertIsNone(tracker.select([c(1, 300)]))
        self.assertEqual(tracker.select([c(1, 1000)])['original_xy'], [1000, 0])
        self.assertIsNone(Tracker().previous)

    def test_sigmoid_once_and_nonfinite_logits_rejected_without_neural_model(self):
        logits = torch.zeros((1, 3, 288, 512), dtype=torch.float32)
        fake = mock.Mock(return_value={0: logits})
        heatmaps, _ = infer_triplet(fake, torch.zeros((1, 9, 288, 512)))
        self.assertTrue(np.all(heatmaps == .5)); self.assertEqual(len(decode(heatmaps[0], np.eye(2, 3))), 0)
        logits[0, 0, 0, 0] = float('nan')
        with self.assertRaisesRegex(Rejected, 'invalid_nonfinite_or_non_CPU_FP32_logits'):
            infer_triplet(fake, torch.zeros((1, 9, 288, 512)))

    def test_safe_strict_checkpoint_contract_is_mocked_no_real_weights(self):
        state = {'a': torch.tensor([1.], dtype=torch.float32), 'counter': torch.tensor(0)}
        model = mock.Mock(); model.load_state_dict.return_value = types.SimpleNamespace(missing_keys=[], unexpected_keys=[])
        with mock.patch.object(torch, 'load', return_value={'model_state_dict': state}) as loader:
            result = strict_load(model, b'synthetic mocked checkpoint, not author bytes')
            self.assertEqual(loader.call_args.kwargs, {'weights_only': True, 'map_location': 'cpu'})
            self.assertTrue(model.load_state_dict.call_args.kwargs['strict']); self.assertEqual(result['missing_keys'], [])
        with self.assertRaisesRegex(Rejected, 'nonfinite_checkpoint_state'):
            state_digest({'a': torch.tensor([float('inf')])})
        with self.assertRaisesRegex(Rejected, 'complex_checkpoint_state_not_supported'):
            state_digest({'a': torch.tensor([1+2j])})
        model.load_state_dict.return_value = types.SimpleNamespace(missing_keys=['a'], unexpected_keys=[])
        with mock.patch.object(torch, 'load', return_value={'model_state_dict': state}), self.assertRaisesRegex(Rejected, 'strict_state_missing'):
            strict_load(model, b'not a real checkpoint')

    def test_loaded_model_state_hash_must_match_before_and_after_forward(self):
        state = {'weight': torch.tensor([1.], dtype=torch.float32), 'counter': torch.tensor(0)}
        expected = state_digest(state); model = mock.Mock(); model.state_dict.return_value = state
        self.assertTrue(model_state_check(model, expected)['finite_and_matches_checkpoint'])
        state['weight'][0] = 2.
        self.assertFalse(model_state_check(model, expected)['finite_and_matches_checkpoint'])
        state['weight'][0] = float('nan')
        self.assertFalse(model_state_check(model, expected)['finite_and_matches_checkpoint'])

    def test_agent_denominator_thresholds_unknown_and_missing(self):
        label = {'status': 'visible', 'x': 0, 'y': 0}
        self.assertEqual(evaluation_row([15, 0], label, 1920, 1080)['category'], 'hit_le10')
        self.assertEqual(evaluation_row([30, 0], label, 1920, 1080)['category'], 'between10_and20')
        self.assertEqual(evaluation_row([30.1, 0], label, 1920, 1080)['category'], 'wrong_gt20')
        self.assertEqual(evaluation_row(None, label, 1920, 1080)['category'], 'miss')
        self.assertFalse(evaluation_row([0, 0], {'status': 'unknown'}, 1920, 1080)['is_accuracy_truth'])

    def test_file_binding_change_and_duplicate_JSON_rejected(self):
        with tempfile.TemporaryDirectory(prefix='wasb-synthetic-binding-') as directory:
            path = Path(directory)/'input.json'; path.write_bytes(b'{}'); spec = bind(path); path.write_bytes(b'[]')
            with self.assertRaisesRegex(Rejected, 'sha256_mismatch'): read_bound(spec)
        with self.assertRaisesRegex(Rejected, 'duplicate_JSON_key'): parse(b'{"x":1,"x":2}')

    def test_recursive_config_access_preserves_all_yaml_values(self):
        source = read_bound({'path': str(BASE/'source-audit/WASB-SBDT'/CONFIG_FILE), 'sha256': CORE_SHA[CONFIG_FILE]})
        plain = yaml.safe_load(source); adapted = config_access(plain)
        self.assertEqual(adapted.MODEL.EXTRA.DECONV.NUM_DECONVS, plain['MODEL']['EXTRA']['DECONV']['NUM_DECONVS'])
        self.assertEqual(adapted['MODEL'].EXTRA.STAGE2['NUM_CHANNELS'], [16, 32])
        self.assertEqual(json.dumps(adapted, sort_keys=True), json.dumps(plain, sort_keys=True))
        nested = {'items_in_list': [{'child': {'value': 3}}, [True, None, 'kept']]}
        wrapped = config_access(nested)
        self.assertEqual(wrapped.items_in_list[0].child.value, 3)
        self.assertEqual(json.loads(json.dumps(wrapped)), nested)
        with self.assertRaises(AttributeError): _ = adapted.MISSING_FIELD

    def test_one_official_unweighted_constructor_no_checkpoint_or_forward(self):
        root = BASE/'source-audit/WASB-SBDT'
        code = read_bound({'path': str(root/MODEL_FILE), 'sha256': CORE_SHA[MODEL_FILE]})
        config = config_access(yaml.safe_load(read_bound({'path': str(root/CONFIG_FILE), 'sha256': CORE_SHA[CONFIG_FILE]})))
        module = isolated_module(code, 'official_wasb_constructor_contract_only', root/MODEL_FILE)
        with mock.patch.object(torch, 'load', side_effect=AssertionError('checkpoint loading forbidden in constructor test')) as loader, \
                mock.patch.object(module.HRNet, 'forward', side_effect=AssertionError('forward forbidden in constructor test')) as forward:
            model = module.HRNet(config)
            self.assertEqual(model.conv1.in_channels, 9)
            self.assertEqual(len(model.state_dict()), 428)
            self.assertEqual(sum(value.numel() for value in model.state_dict().values()), 1488250)
            loader.assert_not_called(); forward.assert_not_called()

    def test_opencv_disable_parallel_real_probe_no_model(self):
        previous = cv2.getNumThreads()
        try:
            cv2.setNumThreads(0)
            self.assertEqual(cv2.getNumThreads(), 1)
            self.assertEqual(runtime()['opencv_requested_threads'], 0)
            self.assertEqual(runtime()['opencv_parallel_framework'], opencv_parallel_framework())
            print(json.dumps({'opencv_version': cv2.__version__, 'parallel_framework': opencv_parallel_framework(),
                              'threads_before': previous, 'requested_threads': 0, 'reported_threads': cv2.getNumThreads()}))
        finally:
            cv2.setNumThreads(previous)

    def test_fixed_evidence_raw_bytes_hash_shape_and_no_overwrite(self):
        with tempfile.TemporaryDirectory(prefix='wasb-synthetic-evidence-') as directory:
            path = Path(directory)/'fixed-first-triplet.bin'
            values = np.arange(54, dtype=np.float32).reshape(1, 9, 2, 3); original = values.copy()
            artifact = export_float32(path, values, 'NCHW')
            self.assertEqual(artifact['shape'], [1, 9, 2, 3]); self.assertEqual(artifact['bytes'], 54*4)
            self.assertEqual(artifact['sha256'], sha(path.read_bytes()))
            np.testing.assert_array_equal(np.frombuffer(path.read_bytes(), dtype='<f4').reshape(1, 9, 2, 3), original)
            np.testing.assert_array_equal(values, original)
            with self.assertRaises(FileExistsError): export_float32(path, values, 'NCHW')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true'); parser.add_argument('--propose')
    parser.add_argument('--checkpoint', default=str(BASE/'checkpoints/wasb_tennis_best.pth.tar'))
    parser.add_argument('--protocol'); parser.add_argument('--protocol-sha256'); parser.add_argument('--output')
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests)).wasSuccessful() else 1
    if args.propose:
        destination = Path(args.propose)
        if destination.exists(): parser.error('Refusing to overwrite protocol')
        try:
            protocol = propose(args.checkpoint)
            with destination.open('x') as handle: json.dump(protocol, handle, indent=2, allow_nan=False); handle.write('\n')
        except Exception as error:
            print(json.dumps({'status': 'protocol_proposal_rejected', 'error': type(error).__name__+': '+str(error), 'weights_loaded': False, 'model_instantiated': False}))
            return 1
        print(json.dumps({'protocol': str(destination), 'sha256': bind(destination)['sha256'], 'weights_loaded': False, 'model_instantiated': False}))
        return 0
    if not args.protocol or not args.protocol_sha256 or not args.output:
        parser.error('--protocol, --protocol-sha256 and --output NEWDIRECTORY required')
    output = Path(args.output)
    if output.exists(): parser.error('Refusing to overwrite output directory')
    output.mkdir(parents=True, exist_ok=False)
    result = {'schema_version': 1, 'status': 'rejected', 'production': False, 'public_speed_kmh': None, 'limits': LIMITS}
    try:
        spec = {'path': str(Path(args.protocol).resolve()), 'sha256': args.protocol_sha256}
        protocol = parse(read_bound(spec, 2*1024*1024))
        result = run(protocol, output)
        read_bound(spec, 2*1024*1024)
        result['protocol_binding'] = spec
    except Exception as error:
        result['status'] = 'rejected'; result['error'] = type(error).__name__+': '+str(error)
        result['integrity_verified_before_and_after'] = False
    result['runner_sha256'] = bind(__file__)['sha256']
    with (output/'report.json').open('x') as handle: json.dump(result, handle, indent=2, allow_nan=False); handle.write('\n')
    print(json.dumps({'status': result['status'], 'counts': result.get('counts'), 'error': result.get('error'),
                      'public_speed_kmh': None, 'output': str(output)}))
    return 0 if result['status'] == 'development_evaluation_completed' else 1


if __name__ == '__main__':
    sys.exit(main())
