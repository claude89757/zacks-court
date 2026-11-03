#!/usr/bin/env python3
"""Bounded official TrackNetV3 -> Core ML portability and parity check.

Use a NEW isolated Python 3.12 venv (never mutate a frozen training venv):
  python -m pip install coremltools==9.0 torch==2.7.0 numpy==1.26.4 \
      Pillow==11.3.0 opencv-python-headless==4.11.0.86
  python scripts/ball-track-coreml.py --self-test
  python scripts/ball-track-coreml.py run --output .local/speed-training/coreml-new

The fixed base checkpoint is MIT badminton tracking, not a qualified tennis or
speed model. No training, S家 inference, app integration or device performance
claim. Real cases use only the specified OLD development review package. The
frozen development median background includes future frames; this is NOT causal inference.
Every attempt uses a new output directory, preserving failed receipts and logs.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import traceback
import unittest

import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / '.local/speed-training/tracknet-smoke-20261028'
DEVELOPMENT = ROOT / '.local/speed-training/ball-tune-20261029'
DATA_MANIFEST_SHA = '705e0ac15c68953893366e2add60303a5f2f26d3c6c3c9c0d21d234b134d87d6'
PREPARED_RECEIPT_SHA = '64322448f4820535657e01b4ca429dfbc3813e594ba6ce59823a9f783ddad161'
PIN = '6eda442ada1740573f200f836d93edc9a541ee86'
CHECKPOINT_SHA = 'df867641a02712b021f04548ff4b1208ddfdb47f629ab2094ceb978667e83b1a'
SOURCE_HASHES = {
    'LICENSE': '1eeb31683deba741bce99f5f33bb813293a23b4e6c8302d6f056a587a30cd497',
    'model.py': '04fd51ff88e58189474677dbf11f81e52b78df00226fb97ea0678b31ef7284e3',
    'dataset.py': 'c8cf51f8fd59e466f3a1916ba99b24ac8b487ff85f69362ee72758b6b1643f92',
    'test.py': '420511325901bf25d5a28b101b1db994c5d6e4ab00a74d30e600a2e4f8b1d204',
    'predict.py': 'ea338db0adc8d5ff89b0313b248d82c93b43ecb96cfefcc4ef44c542f462cf88',
}
VERSIONS = {'coremltools': '9.0', 'torch': '2.7.0', 'numpy': '1.26.4',
            'Pillow': '11.3.0', 'opencv-python-headless': '4.11.0.86'}
INPUT_SHAPE, OUTPUT_SHAPE = (1, 27, 288, 512), (1, 8, 288, 512)
CONTRACT = {
    'input': {'name': 'frames', 'shape': list(INPUT_SHAPE), 'dtype': 'float32',
              'range': [0, 1], 'layout': 'NCHW', 'channels':
              'median-background RGB, frame0 RGB, frame1 RGB, ..., frame7 RGB'},
    'output': {'name': 'heatmaps', 'shape': list(OUTPUT_SHAPE), 'dtype': 'float32',
               'range': [0, 1], 'layout': 'NTHW', 'activation': 'sigmoid'},
    'preprocessing': 'RGB uint8; median before resize, cast uint8; PIL resize (BICUBIC default); CHW concat; divide 255; cast float32',
    'postprocessing': 'strict >0.5 mask; OpenCV RETR_EXTERNAL/CHAIN_APPROX_SIMPLE; max boundingRect w*h, first contour wins tie; int(x+w/2), int(y+h/2)',
    'background_limit': 'real case frozen 48-frame development median includes future frames; noncausal test only',
    'format': 'mlprogram/.mlpackage', 'minimum_target': 'iOS17 / macOS14',
    'shape_policy': 'static batch1; 8 frames; no padding, interpolation or InpaintNet',
}
REFERENCES = [
    'https://github.com/qaz812345/TrackNetV3/tree/' + PIN,
    'https://github.com/qaz812345/TrackNetV3/blob/' + PIN + '/LICENSE',
    'https://pypi.org/project/coremltools/9.0/',
    'https://github.com/apple/coremltools/blob/9.0/coremltools/_deps/__init__.py',
    'https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html',
    'https://apple.github.io/coremltools/docs-guides/source/target-conversion-formats.html',
]


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write(path, value):
    with Path(path).open('x') as f:
        json.dump(value, f, indent=2, sort_keys=True, allow_nan=False)
        f.write('\n')


def check_source(source, checkpoint):
    require(subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == PIN,
            'official source commit mismatch')
    require(not subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip(),
            'official source checkout must be clean')
    for name, expected in SOURCE_HASHES.items():
        require(sha(source / name) == expected, f'official {name} digest mismatch')
    require(sha(checkpoint) == CHECKPOINT_SHA, 'official base checkpoint digest mismatch')
    return {'source': str(source), 'commit': PIN, 'source_sha256': SOURCE_HASHES,
            'checkpoint': str(checkpoint), 'checkpoint_sha256': CHECKPOINT_SHA,
            'license': 'MIT, explicitly covers pretrained model checkpoints'}


def preprocess(frames, frozen_background=None):
    """Exactly the author's frame_arr/concat numeric path without dataset imports."""
    require(frames.dtype == np.uint8 and frames.ndim == 4 and frames.shape[-1] == 3,
            'expected uint8 RGB frames')
    require(len(frames) >= 8 and len(frames) % 8 == 0, 'need complete 8-frame sequences')
    background = np.median(frames, axis=0).astype('uint8') if frozen_background is None else frozen_background
    require(background.dtype == np.uint8 and background.shape == frames.shape[1:], 'background contract mismatch')
    background = Image.fromarray(background)
    background = np.moveaxis(np.asarray(background.resize((512, 288))), -1, 0)
    result = []
    for start in range(0, len(frames), 8):
        channels = [background] + [np.moveaxis(np.asarray(Image.fromarray(f).resize((512, 288))), -1, 0)
                                   for f in frames[start:start + 8]]
        # Author concatenates into initial float64 empty array, then /=255.
        tensor = (np.concatenate(channels, axis=0).astype(np.float64) / 255.).astype(np.float32)
        result.append(np.ascontiguousarray(tensor[None]))
    return result


def candidate(heatmap):
    mask = (heatmap > 0.5).astype(np.uint8) * 255
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    boxes = [list(cv2.boundingRect(c)) for c in contours]
    bbox = max(boxes, key=lambda b: b[2] * b[3]) if boxes else None
    center = [int(bbox[0] + bbox[2] / 2), int(bbox[1] + bbox[3] / 2)] if bbox else None
    if center == [0, 0]:
        center = None
    return {'bbox': bbox, 'center_xy_512x288': center, 'contours': len(boxes),
            'threshold_pixels': int(np.count_nonzero(mask))}


def compare(reference, actual):
    require(tuple(reference.shape) == OUTPUT_SHAPE and tuple(actual.shape) == OUTPUT_SHAPE,
            'heatmap output shape mismatch')
    require(np.isfinite(reference).all() and np.isfinite(actual).all(), 'nonfinite heatmap')
    diff = np.abs(actual.astype(np.float64) - reference.astype(np.float64))
    frames = []
    for i, (a, b) in enumerate(zip(reference[0], actual[0])):
        ca, cb = candidate(a), candidate(b)
        frames.append({'offset': i, 'pytorch': ca, 'coreml': cb,
                       'candidate_equal': ca['center_xy_512x288'] == cb['center_xy_512x288'],
                       'bbox_equal': ca['bbox'] == cb['bbox'],
                       'threshold_flipped_pixels': int(np.count_nonzero((a > .5) != (b > .5))),
                       'max_absolute_error': float(diff[0, i].max())})
    return {'max_absolute_error': float(diff.max()), 'mean_absolute_error': float(diff.mean()),
            'rmse': float(np.sqrt(np.mean(diff ** 2))),
            'p99_absolute_error': float(np.quantile(diff, .99)),
            'pytorch_range': [float(reference.min()), float(reference.max())],
            'coreml_range': [float(actual.min()), float(actual.max())],
            'threshold_flipped_pixels': sum(f['threshold_flipped_pixels'] for f in frames),
            'candidate_changed_frames': sum(not f['candidate_equal'] for f in frames),
            'frames': frames}


def cases():
    yield 'zero', np.zeros(INPUT_SHAPE, dtype=np.float32), {'kind': 'all_zero_synthetic'}
    yield 'one', np.ones(INPUT_SHAPE, dtype=np.float32), {'kind': 'all_one_synthetic'}
    y, x = np.indices((288, 512))
    synthetic = np.stack([np.stack([(x * (c + 1) + y * 3 + i * 17) % 256 for c in range(3)], -1)
                          for i in range(8)]).astype(np.uint8)
    yield 'deterministic-pattern', preprocess(synthetic)[0], {'kind': 'deterministic_synthetic',
        'formula': '(x*(channel+1)+3*y+17*frame)%256, uint8 RGB; median of all 8'}
    rng = np.random.Generator(np.random.PCG64(20261029))
    random_rgb = rng.integers(0, 256, size=(8, 288, 512, 3), dtype=np.uint8)
    yield 'seeded-random', preprocess(random_rgb)[0], {'kind': 'seeded_synthetic',
        'seed': 20261029, 'generator': 'NumPy PCG64', 'range': 'uint8 inclusive 0..255; median of all 8'}
    # Fixed OLD 480-frame development package, never final holdout or Downloads.
    manifest_path = DEVELOPMENT / 'data/manifest.json'
    receipt_path = DEVELOPMENT / 'model/prepared-v1/receipt.json'
    require(sha(manifest_path) == DATA_MANIFEST_SHA, 'development manifest changed')
    require(sha(receipt_path) == PREPARED_RECEIPT_SHA, 'prepared receipt changed')
    manifest = json.loads(manifest_path.read_text())
    receipt = json.loads(receipt_path.read_text())
    windows = {w['window_id']: w for w in manifest['windows']}
    sources = {v['source_id']: v for v in manifest['sources']}
    for name in ['train-006', 'train-007', 'train-008', 'eval-002']:
        rows = windows[name]['frames'][:8]
        require([r['frame_index'] for r in rows] == list(range(8)), 'need first 8 real frames')
        continuity = receipt['windows'][name]['continuity']['eight_frame_sequences'][0]
        require(continuity['continuous'] and continuity['indices'] == list(range(8)), 'gapped input')
        require(continuity['source_pts'] == [r['source_pts'] for r in rows], 'PTS mismatch')
        images = []
        for row in rows:
            path = DEVELOPMENT / 'data' / row['image_path']
            require(path.resolve().parent == (DEVELOPMENT / 'data' / name).resolve(), 'frame outside window')
            require(sha(path) == row['image_sha256'] and receipt['files'][str(path)] == row['image_sha256'],
                    'real frame digest mismatch')
            with Image.open(path) as image:
                images.append(np.asarray(image.convert('RGB')))
        background = DEVELOPMENT / 'model/prepared-v1' / f'{name}-background.npy'
        require(sha(background) == receipt['backgrounds'][background.name], 'frozen background changed')
        tensor = preprocess(np.stack(images), np.load(background, allow_pickle=False))[0]
        yield name, tensor, {'kind': 'old_development_real_frames', 'label_usage': 'none',
            'manifest': str(manifest_path), 'manifest_sha256': DATA_MANIFEST_SHA,
            'source_sha256': windows[name]['source_sha256'],
            'source_nominal_frame_rate': sources[windows[name]['source_id']]['nominal_frame_rate'],
            'source_average_frame_rate': sources[windows[name]['source_id']]['average_frame_rate'],
            'prepared_receipt': str(receipt_path), 'prepared_receipt_sha256': PREPARED_RECEIPT_SHA,
            'output_frames': rows, 'background': str(background), 'background_sha256': sha(background),
            'background_rule': receipt['windows'][name]['background'],
            'background_uses_future_frames': True, 'human_validated': False}


def worker_call(output, command, arguments):
    log = output / (command + '-' + (arguments[-1] if command == 'predict-worker' else 'all') + '.log')
    with log.open('x') as f:
        completed = subprocess.run([sys.executable, str(Path(__file__).resolve()), command,
                                    '--output', str(output), *arguments], stdout=f, stderr=subprocess.STDOUT)
    require(completed.returncode == 0, f'{command} failed with exit {completed.returncode}; see {log.name}')


def reference_worker(output):
    """No Core ML import or prediction in the Torch reference process."""
    import torch
    require(importlib.metadata.version('torch') == VERSIONS['torch'], 'Torch worker version mismatch')
    source, checkpoint = BASE / 'TrackNetV3', BASE / 'checkpoints/ckpts/TrackNet_best.pt'
    check_source(source, checkpoint)
    torch.set_num_threads(4)
    sys.path.insert(0, str(source))
    from model import TrackNet
    ckpt = torch.load(checkpoint, map_location='cpu', weights_only=True)
    require(ckpt['param_dict']['seq_len'] == 8 and ckpt['param_dict']['bg_mode'] == 'concat',
            'checkpoint architecture mismatch')
    network = TrackNet(in_dim=27, out_dim=8).eval()
    network.load_state_dict(ckpt['model'], strict=True)
    parameters = sum(p.numel() for p in network.parameters())
    records = []
    for registered in json.loads((output / 'cases.json').read_text()):
        name = registered['name']
        path = output / registered['input']
        require(sha(path) == registered['input_sha256'], 'reference input changed')
        tensor = np.load(path, allow_pickle=False)
        print('PyTorch reference ' + name, flush=True)
        t0 = time.perf_counter()
        with torch.inference_mode():
            reference = network(torch.from_numpy(tensor)).numpy()
        elapsed = time.perf_counter() - t0
        artifact = output / f'{name}-reference.npz'
        np.savez_compressed(artifact, heatmaps=reference)
        records.append({'name': name, 'artifact': artifact.name, 'sha256': sha(artifact), 'seconds': elapsed})
    with torch.inference_mode():
        traced = torch.jit.trace(network, torch.zeros(INPUT_SHAPE), check_trace=True)
    traced.save(str(output / 'tracknet-traced.pt'))
    write(output / 'references.json', {'parameters': parameters, 'runs': records,
                                      'execution': 'PyTorch-only subprocess; Core ML never imported'})


def predict_worker(output, name):
    """One Core ML predict per isolated worker; no Torch tensor inference."""
    import coremltools as ct
    require(importlib.metadata.version('coremltools') == VERSIONS['coremltools'], 'Core ML worker version mismatch')
    registered = next(r for r in json.loads((output / 'cases.json').read_text()) if r['name'] == name)
    path = output / registered['input']
    require(sha(path) == registered['input_sha256'], 'prediction input changed')
    tensor = np.load(path, allow_pickle=False)
    model = ct.models.MLModel(str(output / 'TrackNetV3Base.mlpackage'), compute_units=ct.ComputeUnit.CPU_ONLY)
    t0 = time.perf_counter()
    actual = model.predict({'frames': tensor})['heatmaps']
    elapsed = time.perf_counter() - t0
    artifact = output / f'{name}-coreml.npz'
    np.savez_compressed(artifact, heatmaps=actual)
    write(output / f'{name}-coreml.json', {'name': name, 'artifact': artifact.name,
        'sha256': sha(artifact), 'seconds': elapsed, 'compute_units': 'CPU_ONLY',
        'execution': 'single Core ML prediction subprocess; no Torch tensor inference'})


def run(args):
    output = Path(args.output).resolve()
    require(not output.exists(), 'output already exists; preserve attempts with a NEW directory')
    output.mkdir(parents=True)
    report = {'schema': 1, 'started_utc': datetime.now(timezone.utc).isoformat(),
              'status': 'started', 'production': False, 'human_validated': False,
              'speed_model': False, 'app_integrated': False, 'iphone_tested': False,
              'references': REFERENCES, 'contract': CONTRACT, 'compute_precision': args.precision,
              'compute_units': 'CPU_ONLY', 'script_sha256': sha(__file__),
              'timing_limit': 'single Mac CPU execution, not live camera or iPhone performance',
              'versions': {}, 'runs': []}
    write(output / 'plan.json', report)
    shutil.copyfile(__file__, output / 'runner.py')
    try:
        for name, expected in VERSIONS.items():
            actual = importlib.metadata.version(name)
            report['versions'][name] = actual
            require(actual == expected, f'{name} must be pinned to {expected}, got {actual}')
        require(sys.version_info[:2] == (3, 12), 'requires isolated Python 3.12')
        report['runtime'] = {'python': sys.version, 'executable': sys.executable,
                             'platform': platform.platform(), 'machine': platform.machine(),
                             'pip_freeze': subprocess.check_output([sys.executable, '-m', 'pip', 'freeze'], text=True).splitlines()}
        source, checkpoint = BASE / 'TrackNetV3', BASE / 'checkpoints/ckpts/TrackNet_best.pt'
        report['provenance'] = check_source(source, checkpoint)
        shutil.copyfile(source / 'LICENSE', output / 'LICENSE.TrackNetV3.txt')
        registered_cases = []
        for name, tensor, metadata in cases():
            path = output / f'{name}-input.npy'
            np.save(path, tensor, allow_pickle=False)
            registered_cases.append({'name': name, 'input': path.name, 'input_sha256': sha(path), 'metadata': metadata})
        write(output / 'cases.json', registered_cases)
        report['cases_sha256'] = sha(output / 'cases.json')
        worker_call(output, 'reference-worker', [])
        references = json.loads((output / 'references.json').read_text())
        report['parameters'] = references['parameters']
        report['runtime_isolation'] = 'Torch-only reference subprocess; conversion parent; one Core ML-only prediction subprocess per case'
        report['runtime_isolation_basis'] = 'prior supported-version mixed inference process exited SIGSEGV; root cause unconfirmed'
        import coremltools as ct
        require(ct._deps._TORCH_MAX_VERSION == '2.7.0', 'released converter tested torch boundary changed')
        report['converter_tested_torch_maximum'] = ct._deps._TORCH_MAX_VERSION
        report['converter_dependency_source_sha256'] = sha(ct._deps.__file__)
        require(ct.target.iOS17 == ct.target.macOS14, 'deployment target equivalence changed')
        print('Trace complete; converting', flush=True)
        t0 = time.perf_counter()
        converted = ct.convert(str(output / 'tracknet-traced.pt'), source='pytorch', convert_to='mlprogram',
            minimum_deployment_target=ct.target.iOS17,
            inputs=[ct.TensorType(name='frames', shape=INPUT_SHAPE, dtype=np.float32)],
            outputs=[ct.TensorType(name='heatmaps', dtype=np.float32)],
            compute_precision=ct.precision.FLOAT32 if args.precision == 'float32' else ct.precision.FLOAT16,
            compute_units=ct.ComputeUnit.CPU_ONLY)
        converted.author = 'qaz812345; Core ML portability experiment by Zacks Court'
        converted.license = (source / 'LICENSE').read_text()
        converted.short_description = 'MIT TrackNetV3 badminton base, not a qualified tennis/speed model'
        converted.user_defined_metadata['source_commit'] = PIN
        converted.user_defined_metadata['checkpoint_sha256'] = CHECKPOINT_SHA
        converted.user_defined_metadata['contract'] = json.dumps(CONTRACT, sort_keys=True)
        converted.user_defined_metadata['production'] = 'false'
        package = output / 'TrackNetV3Base.mlpackage'
        converted.save(str(package))
        report['conversion_seconds'] = time.perf_counter() - t0
        report['specification_version'] = converted.get_spec().specificationVersion
        report['package_files'] = [{'path': str(p.relative_to(output)), 'bytes': p.stat().st_size, 'sha256': sha(p)}
                                   for p in sorted(package.rglob('*')) if p.is_file()]
        report['package_bytes'] = sum(p['bytes'] for p in report['package_files'])
        # Reload the saved artifact in isolated native workers; preserve every exit/log.
        reference_map = {r['name']: r for r in references['runs']}
        for registered in registered_cases:
            name, metadata = registered['name'], registered['metadata']
            input_path = output / registered['input']
            require(sha(input_path) == registered['input_sha256'], 'registered input changed')
            tensor = np.load(input_path, allow_pickle=False)
            print('Predicting ' + name, flush=True)
            require(tensor.shape == INPUT_SHAPE and tensor.dtype == np.float32, 'input contract mismatch')
            reference_row = reference_map[name]
            reference_path = output / reference_row['artifact']
            require(sha(reference_path) == reference_row['sha256'], 'reference output changed')
            with np.load(reference_path, allow_pickle=False) as saved:
                reference = saved['heatmaps']
            pt_seconds = reference_row['seconds']
            worker_call(output, 'predict-worker', ['--name', name])
            prediction = json.loads((output / f'{name}-coreml.json').read_text())
            prediction_path = output / prediction['artifact']
            require(sha(prediction_path) == prediction['sha256'], 'Core ML output changed')
            with np.load(prediction_path, allow_pickle=False) as saved:
                actual = saved['heatmaps']
            ml_seconds = prediction['seconds']
            artifact = output / f'{name}-arrays.npz'
            np.savez_compressed(artifact, input=tensor, pytorch_heatmaps=reference, coreml_heatmaps=actual)
            row = {'name': name, 'input_metadata': metadata, 'arrays': artifact.name,
                   'arrays_sha256': sha(artifact), 'pytorch_seconds': pt_seconds,
                   'coreml_seconds': ml_seconds, **compare(reference, actual)}
            report['runs'].append(row)
            write(output / f'{name}-comparison.json', row)
        report['status'] = 'completed'
        report['summary'] = {'sequences': len(report['runs']), 'heatmaps': len(report['runs']) * 8,
            'max_absolute_error': max(r['max_absolute_error'] for r in report['runs']),
            'threshold_flipped_pixels': sum(r['threshold_flipped_pixels'] for r in report['runs']),
            'candidate_changed_frames': sum(r['candidate_changed_frames'] for r in report['runs']),
            'interpretation': 'conversion consistency only; no ball accuracy, shot matching, speed, coverage or phone performance evaluation'}
        print(json.dumps(report['summary']), flush=True)
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = {'type': type(error).__name__, 'message': str(error), 'traceback': traceback.format_exc()}
        raise
    finally:
        report['finished_utc'] = datetime.now(timezone.utc).isoformat()
        write(output / 'report.json', report)


class Checks(unittest.TestCase):
    def test_strict_threshold_and_bbox(self):
        a = np.zeros((288, 512), np.float32)
        a[20, 30] = .5
        self.assertIsNone(candidate(a)['bbox'])
        a[20:23, 30:34] = .6
        a[100, 100] = .9
        self.assertEqual(candidate(a)['bbox'], [30, 20, 4, 3])
        self.assertEqual(candidate(a)['center_xy_512x288'], [32, 21])

    def test_preprocess_channel_order_and_scaling(self):
        frames = np.zeros((8, 288, 512, 3), np.uint8)
        for i in range(8):
            frames[i, :, :, :] = [i * 10, i * 10 + 1, i * 10 + 2]
        tensor = preprocess(frames)[0]
        self.assertEqual(tensor.shape, INPUT_SHAPE)
        np.testing.assert_allclose(tensor[0, :3, 0, 0], np.array([35, 36, 37]) / 255)
        np.testing.assert_allclose(tensor[0, -3:, 0, 0], np.array([70, 71, 72]) / 255)

    def test_candidate_change_and_nonfinite_rejected(self):
        a = np.zeros(OUTPUT_SHAPE, np.float32)
        b = a.copy()
        b[0, 0, 20, 30] = .6
        result = compare(a, b)
        self.assertEqual(result['candidate_changed_frames'], 1)
        self.assertEqual(result['threshold_flipped_pixels'], 1)
        b[0, 0, 0, 0] = np.nan
        with self.assertRaises(ValueError):
            compare(a, b)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--self-test', action='store_true')
    sub = p.add_subparsers(dest='command')
    r = sub.add_parser('run')
    r.add_argument('--output', required=True)
    r.add_argument('--precision', choices=['float32', 'float16'], default='float32')
    for command in ['reference-worker', 'predict-worker']:
        worker = sub.add_parser(command, help=argparse.SUPPRESS)
        worker.add_argument('--output', required=True)
        if command == 'predict-worker':
            worker.add_argument('--name', required=True)
    args = p.parse_args()
    if args.self_test:
        unittest.main(argv=[sys.argv[0]])
    elif args.command == 'run':
        run(args)
    elif args.command == 'reference-worker':
        reference_worker(Path(args.output).resolve())
    elif args.command == 'predict-worker':
        predict_worker(Path(args.output).resolve(), args.name)
    else:
        p.error('choose --self-test or run')


if __name__ == '__main__':
    main()
