#!/usr/bin/env python3
"""Export frozen Core ML portability arrays as private Float32LE native fixtures.
No images are decoded or resized; no model conversion or prediction takes place.
"""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / '.local/speed-training/coreml-portability-20261029/attempt-03-isolated-float32'
REPORT_SHA = '6f54b8c3e7511fcf6f590119a4db312065acbedbdb30ac998e6d6f278357e1eb'


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def require(ok, message):
    if not ok:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output).resolve()
    require(not output.exists(), 'output must be new; preserve old fixtures')
    require(sha(SOURCE / 'report.json') == REPORT_SHA, 'frozen portability report changed')
    report = json.loads((SOURCE / 'report.json').read_text())
    require(report['status'] == 'completed' and report['summary']['heatmaps'] == 64, 'source run incomplete')
    versions = {p: importlib.metadata.version(p) for p in report['versions']}
    require(versions == report['versions'], 'use the existing frozen portability venv without changing it')
    package = SOURCE / 'TrackNetV3Base.mlpackage'
    for entry in report['package_files']:
        require(sha(SOURCE / entry['path']) == entry['sha256'], 'model package changed')
    registry = json.loads((SOURCE / 'cases.json').read_text())
    require(sha(SOURCE / 'cases.json') == report['cases_sha256'], 'source registry changed')
    output.mkdir(parents=True)
    rows = []
    for registered, result in zip(registry, report['runs']):
        name = registered['name']
        require(name == result['name'], 'source case order changed')
        path = SOURCE / result['arrays']
        require(sha(path) == result['arrays_sha256'], 'source arrays changed')
        artifacts = {}
        with np.load(path, allow_pickle=False) as saved:
            for key, filename in [('input', f'{name}-input.f32le'), ('coreml_heatmaps', f'{name}-coreml.f32le'),
                                  ('pytorch_heatmaps', f'{name}-pytorch.f32le')]:
                array = saved[key]
                expected = (1, 27, 288, 512) if key == 'input' else (1, 8, 288, 512)
                require(array.shape == expected and array.dtype == np.float32 and np.isfinite(array).all(), 'array contract mismatch')
                target = output / filename
                target.write_bytes(array.astype('<f4', copy=False).tobytes(order='C'))
                artifacts[key] = {'path': filename, 'sha256': sha(target), 'bytes': target.stat().st_size,
                                  'shape': list(array.shape), 'dtype': 'float32', 'byte_order': 'little', 'layout': 'C contiguous NCHW/NTHW'}
        rows.append({'name': name, 'kind': registered['metadata']['kind'], 'artifacts': artifacts,
                     'official_candidates': [{'offset': x['offset'], 'pytorch': x['pytorch'], 'coreml': x['coreml']}
                                             for x in result['frames']]})
    manifest = {'schema_version': 1, 'purpose': 'native Swift/Core ML numeric consistency, not tracking or speed accuracy',
                'production': False, 'iphone_tested': False, 'source_report_sha256': REPORT_SHA,
                'source_report': str(SOURCE / 'report.json'), 'source_registry_sha256': report['cases_sha256'],
                'source_versions': report['versions'], 'fixture_runtime': {'python': sys.version, 'platform': platform.platform(), 'versions': versions},
                'generator_sha256': sha(__file__), 'image_decoding_or_preprocessing': False,
                'model_url': str(package), 'model_package_files': report['package_files'],
                'input_shape': [1, 27, 288, 512], 'output_shape': [1, 8, 288, 512],
                'threshold': 0.5, 'threshold_operator': '>', 'sequence_count': len(rows), 'heatmaps': len(rows)*8,
                'cases': rows}
    encoded = json.dumps(manifest, indent=2, sort_keys=True, allow_nan=False) + '\n'
    (output / 'manifest.json').write_text(encoded)
    (output / 'manifest.sha256').write_text(sha(output / 'manifest.json') + '\n')
    print(json.dumps({'fixtures': str(output), 'cases': len(rows), 'heatmaps': len(rows)*8, 'manifest_sha256': sha(output/'manifest.json')}))


if __name__ == '__main__':
    main()
