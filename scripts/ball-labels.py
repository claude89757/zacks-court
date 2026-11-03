#!/usr/bin/env python3
"""Offline, prediction-free ball annotation packages (Python standard library).

build --review-package DIR --output NEWDIR [--samples sample-001,...]
      [--frame-indices 10,30,50,70,90,110]
validate --package DIR --labels labels.json --output NEWJSON
--self-test

All reviewer identities are self-reported. Agent candidates never become human
labels automatically. Unknown and occluded frames are never negative examples.
Coordinates refer to the copied decoded image, not source-video pixels.
"""
import argparse
import copy
import datetime
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile
import unittest

VERSION = 1
STATES = {'pending', 'visible', 'occluded', 'out_of_frame', 'absent', 'unknown'}
KINDS = {'human_self_reported', 'agent', 'agent_candidate', 'ui_test'}
BINDINGS = ('image_id', 'sample_id', 'frame_index', 'source_pts', 'source_time_base',
            'image_sha256', 'width', 'height')


class LabelError(ValueError):
    pass


def finite(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise LabelError(f'{name}: expected finite number')
    return value


def strict_load(path):
    def bad(value):
        raise LabelError('Non-finite JSON value: ' + value)
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise LabelError('Duplicate JSON key: ' + key)
            result[key] = value
        return result
    return json.loads(path.read_text(encoding='utf-8'), parse_constant=bad, object_pairs_hook=pairs)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def write_json(path, value):
    with path.open('x', encoding='utf-8') as handle:
        json.dump(value, handle, ensure_ascii=False, allow_nan=False, indent=2)
        handle.write('\n')
    path.chmod(0o600)


def image_size(path):
    """Read JPEG SOF or PNG IHDR dimensions without decoding image pixels."""
    data = path.read_bytes()
    if data.startswith(b'\x89PNG\r\n\x1a\n') and data[12:16] == b'IHDR':
        return struct.unpack('>II', data[16:24])
    if not data.startswith(b'\xff\xd8'):
        raise LabelError('Unsupported image format')
    i = 2
    sof = {0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf}
    while i < len(data):
        if data[i] != 0xff:
            raise LabelError('Malformed JPEG marker')
        while i < len(data) and data[i] == 0xff:
            i += 1
        if i >= len(data):
            break
        marker = data[i]
        i += 1
        if marker in {0xd8, 0xd9} or 0xd0 <= marker <= 0xd7:
            continue
        if i + 2 > len(data):
            break
        length = int.from_bytes(data[i:i+2], 'big')
        if length < 2 or i + length > len(data):
            break
        if marker in sof and length >= 8:
            height, width = struct.unpack('>HH', data[i+3:i+7])
            return width, height
        i += length
    raise LabelError('JPEG dimensions not found')


def safe_path(root, relative):
    if not isinstance(relative, str) or not relative:
        raise LabelError('Invalid image path')
    result = (root / relative).resolve()
    if not result.is_relative_to(root.resolve()):
        raise LabelError('Image path escapes package')
    return result


def verify_image(root, image):
    for key in BINDINGS:
        if key not in image:
            raise LabelError('Missing image binding: ' + key)
    if not isinstance(image['source_pts'], int) or isinstance(image['source_pts'], bool):
        raise LabelError('PTS must be an integer')
    try:
        base = Fraction(image['source_time_base'])
    except (ValueError, TypeError, ZeroDivisionError) as error:
        raise LabelError('Invalid PTS time base') from error
    if base <= 0:
        raise LabelError('PTS time base must be positive')
    if not isinstance(image['frame_index'], int) or isinstance(image['frame_index'], bool) or image['frame_index'] < 0:
        raise LabelError('Invalid frame index')
    for key in ('width', 'height'):
        if not isinstance(image[key], int) or isinstance(image[key], bool) or image[key] <= 0:
            raise LabelError('Invalid image dimensions')
    if not re.fullmatch('[a-f0-9]{64}', image['image_sha256']):
        raise LabelError('Invalid image SHA256')
    path = safe_path(root, image['image_path'])
    if sha(path) != image['image_sha256'] or image_size(path) != (image['width'], image['height']):
        raise LabelError('Image hash or dimensions mismatch')


def package_digest(package):
    return 'ball-labels-' + digest({k: v for k, v in package.items() if k != 'package_id'})[:32]


def load_package(path):
    root = path if path.is_dir() else path.parent
    package = strict_load(root / 'package.json')
    if package.get('schema_version') != VERSION or package.get('package_id') != package_digest(package):
        raise LabelError('Package identity mismatch')
    if not isinstance(package.get('images'), list) or not package['images']:
        raise LabelError('Package has no images')
    ids = set()
    targets = {image['image_id']: image for image in package['images']}
    target_ids = set(targets)
    for image in package['images'] + package.get('context_frames', []):
        if image['image_id'] in ids:
            raise LabelError('Duplicate image ID')
        ids.add(image['image_id'])
        verify_image(root, image)
        if image in package.get('context_frames', []):
            if image.get('target_image_id') not in target_ids:
                raise LabelError('Unknown context target')
            target = targets[image['target_image_id']]
            delta = image['frame_index'] - target['frame_index']
            if image['sample_id'] != target['sample_id'] or image['source_time_base'] != target['source_time_base'] or abs(delta) not in {1, 2}:
                raise LabelError('Context frame binding mismatch')
            if (image['source_pts'] - target['source_pts']) * delta <= 0:
                raise LabelError('Context PTS order mismatch')
    return package


def binding(image):
    return {key: image[key] for key in BINDINGS}


def empty_payload(package):
    return {'schema_version': VERSION, 'package_id': package['package_id'],
            'reviewer_kind': 'human_self_reported', 'reviewer_name': '',
            'reviewer_identity_verified': False, 'independent_review_verified': False,
            'labels': [{**binding(image), 'status': 'pending', 'x': None, 'y': None,
                        'uncertainty_px': None, 'target_identity': 'uncertain', 'notes': '',
                        'reviewed': False, 'reviewed_at': None, 'reviewer_kind': 'human_self_reported',
                        'origin_reviewer_kind': 'human_self_reported'} for image in package['images']]}


def validate_payload(package, payload):
    if not isinstance(payload, dict) or payload.get('schema_version') != VERSION:
        raise LabelError('Invalid label schema')
    if payload.get('package_id') != package['package_id']:
        raise LabelError('Wrong package ID; existing data must be preserved')
    if payload.get('reviewer_kind') not in KINDS or not isinstance(payload.get('reviewer_name'), str):
        raise LabelError('Invalid self-reported reviewer identity')
    if payload.get('reviewer_identity_verified', False) or payload.get('independent_review_verified', False):
        raise LabelError('Self-reported identity cannot assert independent verification')
    labels = payload.get('labels')
    if not isinstance(labels, list) or len(labels) != len(package['images']):
        raise LabelError('Labels must cover each package image exactly once')
    images = {image['image_id']: image for image in package['images']}
    seen, counts = set(), {name: 0 for name in STATES}
    positive, negative, reviewed, agent = 0, 0, 0, payload['reviewer_kind'] != 'human_self_reported'
    for label in labels:
        if not isinstance(label, dict):
            raise LabelError('Invalid label record')
        key = label.get('image_id')
        if key not in images or key in seen:
            raise LabelError('Unknown or duplicate image ID')
        seen.add(key)
        image = images[key]
        if any(type(label.get(k)) is not type(image[k]) or label.get(k) != image[k] for k in BINDINGS):
            raise LabelError('Frame hash/PTS/image binding mismatch')
        if label.get('reviewer_kind') not in KINDS or label.get('origin_reviewer_kind') not in KINDS:
            raise LabelError('Each label must preserve its self-reported reviewer kind and origin')
        status = label.get('status')
        if status not in STATES:
            raise LabelError('Invalid label status')
        counts[status] += 1
        if label.get('target_identity') not in {'confirmed', 'uncertain'}:
            raise LabelError('Invalid target identity')
        if not isinstance(label.get('notes'), str) or not isinstance(label.get('reviewed'), bool):
            raise LabelError('Invalid notes/reviewed value')
        if label.get('reviewed'):
            stamp = label.get('reviewed_at')
            try:
                timestamp = datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
                if timestamp.tzinfo is None:
                    raise ValueError()
            except (ValueError, AttributeError, TypeError) as error:
                raise LabelError('Reviewed labels require an explicit timestamp') from error
            if status == 'pending':
                raise LabelError('Pending cannot be reviewed')
            reviewed += 1
        elif label.get('reviewed_at') is not None:
            raise LabelError('Unreviewed labels cannot have a review timestamp')
        x, y, uncertainty = label.get('x'), label.get('y'), label.get('uncertainty_px')
        if status == 'visible':
            finite(x, 'x'); finite(y, 'y')
            if not 0 <= x < image['width'] or not 0 <= y < image['height']:
                raise LabelError('Coordinates outside image')
            if uncertainty is not None:
                finite(uncertainty, 'uncertainty_px')
                if not 0 <= uncertainty <= math.hypot(image['width'], image['height']):
                    raise LabelError('Uncertainty outside image scale')
        elif x is not None or y is not None or uncertainty is not None:
            raise LabelError('Non-visible states must keep coordinates/uncertainty null')
        eligible = (not agent and label['reviewer_kind'] == 'human_self_reported'
                    and label['origin_reviewer_kind'] == 'human_self_reported'
                    and bool(payload['reviewer_name'].strip()) and label['reviewed']
                    and label['target_identity'] == 'confirmed')
        positive += bool(eligible and status == 'visible' and uncertainty is not None)
        negative += bool(eligible and status == 'absent')
    return {'schema_version': VERSION, 'package_id': package['package_id'], 'valid': True,
            'total_images': len(labels), 'status_counts': counts, 'reviewed_count': reviewed,
            'reviewer_kind': payload['reviewer_kind'], 'reviewer_identity_verified': False,
            'independent_review_verified': False, 'formal_localization_eligible_count': positive,
            'formal_negative_eligible_count': negative, 'formal_eligible_count': positive + negative,
            'agent_candidate_count': sum(label['reviewer_kind'] in {'agent', 'agent_candidate'} or label['origin_reviewer_kind'] in {'agent', 'agent_candidate'} for label in labels),
            'ui_test_count': sum(label['reviewer_kind'] == 'ui_test' or label['origin_reviewer_kind'] == 'ui_test' for label in labels),
            'formal_eligible': positive + negative > 0,
            'limits': ['Human identity is self-reported, not independent verification.',
                       'Eligibility is a schema gate only, not proof of correct ball identity or physical accuracy.',
                       'Unknown, pending, occluded, and out-of-frame frames are never negative examples.',
                       'Agent candidates are never formal labels; imported reviewer kind is preserved.']}


def build(review, output, samples, indices):
    review, output = review.resolve(), output.absolute()
    if output.exists() or output.is_symlink():
        raise LabelError('Output exists; select a new directory')
    blind_path = review / 'blind-data.json'
    blind_sha = sha(blind_path)
    blind = strict_load(blind_path)
    receipt_path = review / 'audit' / 'selection_receipt.json'
    receipt = strict_load(receipt_path)
    if receipt.get('package_id') != blind.get('package_id') or receipt.get('status') != 'complete':
        raise LabelError('Review package audit identity mismatch')
    if receipt.get('artifacts', {}).get('blind-data.json') != blind_sha:
        raise LabelError('Review blind-data hash mismatch')
    by_sample = {sample['review_id']: sample for sample in blind['samples']}
    if len(by_sample) != len(blind['samples']) or len(set(samples)) != len(samples) or len(set(indices)) != len(indices):
        raise LabelError('Duplicate sample or frame selection')
    images, context_frames, mappings = [], [], []
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.ball-labels-', dir=output.parent))
    staging.chmod(0o700)
    try:
        (staging / 'images').mkdir()
        (staging / 'audit').mkdir(mode=0o700)
        for sample_id in samples:
            if sample_id not in by_sample:
                raise LabelError('Selected sample not found: ' + sample_id)
            frames = by_sample[sample_id]['frames']
            frame_map = {frame['window_frame_index']: frame for frame in frames}
            if len(frame_map) != len(frames):
                raise LabelError('Duplicate frame index in review package')
            previous_pts = None
            for frame in frames:
                pts, base = frame['source_pts'], Fraction(frame['source_time_base'])
                if not isinstance(pts, int) or isinstance(pts, bool) or base <= 0:
                    raise LabelError('Invalid source PTS')
                exact = Fraction(pts) * base
                if Fraction(frame['source_pts_seconds_rational']) != exact:
                    raise LabelError('Source rational PTS mismatch')
                finite(frame['source_pts_seconds'], 'source_pts_seconds')
                if abs(frame['source_pts_seconds'] - float(exact)) > 1e-9:
                    raise LabelError('Source PTS seconds mismatch')
                if previous_pts is not None and exact <= previous_pts:
                    raise LabelError('Source PTS is not strictly increasing')
                previous_pts = exact
            for index in indices:
                if index not in frame_map:
                    raise LabelError(f'{sample_id}: selected frame index unavailable: {index}')
                frame = frame_map[index]
                image_id = f'image-{len(images)+1:04d}'
                original = safe_path(review, f'samples/{sample_id}/{frame["filename"]}')
                record = {'image_id': image_id, 'sample_id': sample_id, 'frame_index': index,
                          'source_pts': frame['source_pts'], 'source_time_base': frame['source_time_base'],
                          'image_sha256': frame['sha256'], 'width': frame['width'], 'height': frame['height'],
                          'image_path': f'images/{image_id}.jpg'}
                verify_image(review, {**record, 'image_path': str(original.relative_to(review))})
                shutil.copyfile(original, staging / record['image_path'])
                (staging / record['image_path']).chmod(0o600)
                verify_image(staging, record)
                images.append(record)
                for offset in (-2, -1, 1, 2):
                    context_index = index + offset
                    if context_index not in frame_map:
                        continue
                    context = frame_map[context_index]
                    context_id = image_id + '-context-' + ('m' if offset < 0 else 'p') + str(abs(offset))
                    context_original = safe_path(review, f'samples/{sample_id}/{context["filename"]}')
                    context_record = {'image_id': context_id, 'target_image_id': image_id,
                                      'sample_id': sample_id, 'frame_index': context_index,
                                      'source_pts': context['source_pts'],
                                      'source_time_base': context['source_time_base'],
                                      'image_sha256': context['sha256'], 'width': context['width'],
                                      'height': context['height'], 'image_path': f'images/{context_id}.jpg'}
                    verify_image(review, {**context_record, 'image_path': str(context_original.relative_to(review))})
                    shutil.copyfile(context_original, staging / context_record['image_path'])
                    (staging / context_record['image_path']).chmod(0o600)
                    verify_image(staging, context_record)
                    context_frames.append(context_record)
                    mappings.append({'image_id': context_id,
                                     'original_relative_path': str(context_original.relative_to(review)),
                                     'source_frame_sha256': context['sha256']})
                mappings.append({'image_id': image_id, 'original_relative_path': str(original.relative_to(review)),
                                 'source_frame_sha256': frame['sha256']})
        package = {'schema_version': VERSION, 'coordinate_space': 'copied decoded image pixels; x right, y down; top-left origin',
                   'pts_semantics': blind['pts_semantics'], 'images': images, 'context_frames': context_frames,
                   'label_policy': 'No predictions; unknown coordinates null; human identity self-reported only'}
        package['package_id'] = package_digest(package)
        write_json(staging / 'package.json', package)
        write_json(staging / 'audit' / 'binding.json', {
            'original_review_package': str(review), 'original_package_id': blind['package_id'],
            'original_blind_data_sha256': blind_sha, 'original_receipt_sha256': sha(receipt_path),
            'selection': {'samples': samples, 'frame_indices': indices}, 'images': mappings,
            'generator_sha256': sha(Path(__file__)), 'ui_sha256': sha(Path(__file__).with_name('ball-labels-ui.html'))})
        if sha(blind_path) != blind_sha:
            raise LabelError('Blind package changed during build')
        template = Path(__file__).with_name('ball-labels-ui.html').read_text()
        html = template.replace('__PACKAGE_JSON__', canonical(package).replace('<', '\\u003c'))
        if '__PACKAGE_JSON__' in html:
            raise LabelError('UI template replacement failed')
        (staging / 'index.html').write_text(html, encoding='utf-8')
        (staging / 'index.html').chmod(0o600)
        # Exclusive destination claim prevents overwriting any existing package.
        output.mkdir(mode=0o700)
        for child in staging.iterdir():
            child.rename(output / child.name)
        staging.rmdir()
        return {'package_id': package['package_id'], 'images': len(images), 'samples': len(samples),
                'output': str(output), 'formal_labels_created': 0, 'readonly_context_frames': len(context_frames)}
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


class Tests(unittest.TestCase):
    def setUp(self):
        self.package = {'schema_version': 1, 'package_id': 'fixture', 'images': [
            {'image_id': f'image-{i}', 'sample_id': 'sample-001', 'frame_index': i,
             'source_pts': i * 10, 'source_time_base': '1/600', 'image_sha256': str(i)*64,
             'width': 1280, 'height': 720} for i in range(2)]}
        self.payload = empty_payload(self.package)

    def test_pending_default_null_and_not_negative(self):
        r = validate_payload(self.package, self.payload)
        self.assertEqual(r['formal_eligible_count'], 0)
        self.assertEqual(r['reviewed_count'], 0)
        self.assertTrue(all(x['x'] is None and x['target_identity']=='uncertain' for x in self.payload['labels']))

    def test_wrong_package_preserves_persistable_payload(self):
        original = canonical(self.payload)
        imported = copy.deepcopy(self.payload); imported['package_id'] = 'other'
        with self.assertRaises(LabelError): validate_payload(self.package, imported)
        self.assertEqual(canonical(self.payload), original)
        self.assertEqual(validate_payload(self.package, json.loads(original))['valid'], True)

    def test_unknown_and_occluded_never_negative(self):
        self.payload['reviewer_name'] = 'self-reported tester'
        for status in ('unknown', 'occluded', 'out_of_frame'):
            for x in self.payload['labels']:
                x.update(status=status, reviewed=True, reviewed_at='2026-10-29T00:00:00Z', target_identity='confirmed')
            self.assertEqual(validate_payload(self.package, self.payload)['formal_negative_eligible_count'], 0)
        self.payload['labels'][0]['x'] = 5
        with self.assertRaises(LabelError): validate_payload(self.package, self.payload)

    def test_visible_bounds_nan_and_uncertainty(self):
        x = self.payload['labels'][0]; x.update(status='visible', x=20, y=30, uncertainty_px=3)
        self.assertTrue(validate_payload(self.package, self.payload)['valid'])
        for key, value in [('x', float('nan')), ('x', 1280), ('y', -1), ('uncertainty_px', float('inf'))]:
            with self.subTest(key=key,value=value):
                bad = copy.deepcopy(self.payload); bad['labels'][0][key] = value
                with self.assertRaises(LabelError): validate_payload(self.package, bad)

    def test_duplicate_id_and_frame_hash_pts_mismatch(self):
        for key, value in [('image_id','image-1'), ('image_sha256','f'*64), ('source_pts',99), ('source_time_base','1/30')]:
            bad=copy.deepcopy(self.payload);bad['labels'][0][key]=value
            with self.assertRaises(LabelError): validate_payload(self.package,bad)

    def test_explicit_review_and_agent_not_promoted(self):
        self.payload['reviewer_name']='self-reported tester'
        for x in self.payload['labels']:
            x.update(status='visible', x=40, y=20, uncertainty_px=2, target_identity='confirmed')
        self.assertEqual(validate_payload(self.package,self.payload)['formal_eligible_count'],0)
        for x in self.payload['labels']: x.update(reviewed=True,reviewed_at='2026-10-29T00:00:00Z')
        self.assertEqual(validate_payload(self.package,self.payload)['formal_localization_eligible_count'],2)
        self.payload['reviewer_kind']='agent_candidate'
        for x in self.payload['labels']:
            x.update(reviewer_kind='agent_candidate',origin_reviewer_kind='agent_candidate')
        restored=json.loads(canonical(self.payload))
        self.assertEqual(restored['reviewer_kind'],'agent_candidate')
        self.assertEqual(validate_payload(self.package,restored)['formal_eligible_count'],0)
        restored['reviewer_kind']='human_self_reported'
        self.assertEqual(validate_payload(self.package,restored)['formal_eligible_count'],0)
        for x in restored['labels']:
            x.update(reviewer_kind='ui_test',origin_reviewer_kind='ui_test')
        self.assertEqual(validate_payload(self.package,restored)['formal_eligible_count'],0)
        self.assertEqual(validate_payload(self.package,restored)['ui_test_count'],2)

    def test_only_explicit_absent_is_negative(self):
        self.payload['reviewer_name'] = 'self-reported tester'
        for label in self.payload['labels']:
            label.update(status='absent', reviewed=True, reviewed_at='2026-10-29T00:00:00Z', target_identity='confirmed')
        self.assertEqual(validate_payload(self.package, self.payload)['formal_negative_eligible_count'], 2)
        for label in self.payload['labels']:
            label['status'] = 'out_of_frame'
        self.assertEqual(validate_payload(self.package, self.payload)['formal_negative_eligible_count'], 0)

    def test_copied_frame_hash_and_package_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image_path = root / 'frame.jpg'
            image_path.write_bytes(b'\x89PNG\r\n\x1a\n' + b'\0'*4 + b'IHDR' + struct.pack('>II', 1280, 720))
            image = {**self.package['images'][0], 'image_path': 'frame.jpg', 'image_sha256': sha(image_path)}
            package = {'schema_version': 1, 'images': [image]}
            package['package_id'] = package_digest(package)
            write_json(root / 'package.json', package)
            self.assertEqual(len(load_package(root)['images']), 1)
            image_path.write_bytes(image_path.read_bytes() + b'changed')
            with self.assertRaisesRegex(LabelError, 'hash'):
                load_package(root)

    def test_independent_identity_claim_rejected(self):
        self.payload['independent_review_verified']=True
        with self.assertRaises(LabelError): validate_payload(self.package,self.payload)

    def test_json_nan_and_duplicate_keys_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'input.json'
            for text in ('{"x":NaN}', '{"x":1,"x":2}'):
                path.write_text(text)
                with self.assertRaises(LabelError): strict_load(path)

    def test_ui_persistence_and_import_order_contract(self):
        html=Path(__file__).with_name('ball-labels-ui.html').read_text()
        self.assertIn("'ball-labels:v1:'+pkg.package_id",html)
        self.assertIn('validatePayload(candidate);',html)
        self.assertLess(html.index('validatePayload(candidate);'),html.index('payload=candidate;'))
        self.assertIn("payload.reviewer_kind",html)
        self.assertIn('localStorage.setItem(storageKey',html)
        self.assertIn('if(contextOffset!==0)',html)
        self.assertIn('上一张待标图',html)
        self.assertNotIn('localStorage.clear',html)
        self.assertNotIn('localStorage.removeItem',html)


def main():
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test',action='store_true')
    sub=parser.add_subparsers(dest='command')
    b=sub.add_parser('build');b.add_argument('--review-package',required=True,type=Path);b.add_argument('--output',required=True,type=Path)
    b.add_argument('--samples',default=','.join(f'sample-{i:03d}' for i in range(1,11)))
    b.add_argument('--frame-indices',default='10,30,50,70,90,110')
    v=sub.add_parser('validate');v.add_argument('--package',required=True,type=Path);v.add_argument('--labels',required=True,type=Path);v.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    if args.self_test:
        result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests))
        return 0 if result.wasSuccessful() else 1
    try:
        if args.command=='build':
            indices=[int(x.strip()) for x in args.frame_indices.split(',')]
            samples=[x.strip() for x in args.samples.split(',')]
            if not samples or not indices or any(i<0 for i in indices): raise LabelError('Invalid selection')
            report=build(args.review_package,args.output,samples,indices)
        elif args.command=='validate':
            if args.output.exists(): raise LabelError('Validation output exists; select a new JSON path')
            package=load_package(args.package);payload=strict_load(args.labels)
            report=validate_payload(package,payload)
            report['labels_sha256']=sha(args.labels)
            report['validated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
            write_json(args.output,report)
        else:
            parser.error('Choose build, validate, or --self-test')
        print(json.dumps(report,ensure_ascii=False,indent=2));return 0
    except (LabelError,OSError,ValueError,KeyError,TypeError,struct.error) as error:
        print('ball-labels: '+str(error),file=sys.stderr);return 2


if __name__=='__main__':
    sys.exit(main())
