#!/usr/bin/env python3
"""Prepare and audit a bounded TrackNet point-label diagnostic; never promote a model.

Use the dedicated TrackNet smoke venv. `prepare` freezes a caller-provided split;
`forward-backward` computes gradients without an optimizer step. `fit` is an
    explicit, bounded engineering fit, gated on human labels unless the caller
supplies --diagnostic-agent-labels. No command reports accuracy or evaluates.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import platform
import random
import subprocess
import sys
import unittest

import numpy as np
from PIL import Image
import torch

REPO = Path(__file__).resolve().parents[1]
DEFAULT_BASE = REPO / '.local/speed-training/tracknet-smoke-20261028'
PIN = '6eda442ada1740573f200f836d93edc9a541ee86'
CHECKPOINT_SHA = 'df867641a02712b021f04548ff4b1208ddfdb47f629ab2094ceb978667e83b1a'
WIDTH, HEIGHT, LENGTH, SEED = 512, 288, 8, 20261029
STATUSES = {'visible', 'occluded', 'out_of_frame', 'absent', 'unknown'}


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


def write(path, value):
    with open(path, 'x') as f:
        json.dump(value, f, indent=2, sort_keys=True, allow_nan=False)
        f.write('\n')


def read(path):
    return json.loads(Path(path).read_text())


def resolve(path, base):
    value = Path(path).expanduser()
    return (base / value).resolve() if not value.is_absolute() else value.resolve()


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def runtime():
    import PIL
    return {'python': sys.version, 'executable': sys.executable, 'platform': platform.platform(),
            'torch': torch.__version__, 'numpy': np.__version__, 'Pillow': PIL.__version__,
            'pip_freeze': subprocess.check_output([sys.executable, '-m', 'pip', 'freeze'], text=True).splitlines()}


def check_source(source, checkpoint):
    require(source.is_dir(), 'missing pinned official source checkout')
    head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    require(head == PIN, 'official source commit does not match pin')
    require(not subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True).strip(),
            'official source checkout must remain clean')
    require(sha(checkpoint) == CHECKPOINT_SHA, 'checkpoint digest does not match official smoke download')
    return {'repo': str(source), 'commit': head, 'url': 'https://github.com/qaz812345/TrackNetV3',
            'checkpoint': str(checkpoint), 'checkpoint_sha256': CHECKPOINT_SHA,
            'license_sha256': sha(source / 'LICENSE'),
            'model_py_sha256': sha(source / 'model.py'), 'dataset_py_sha256': sha(source / 'dataset.py'),
            'metric_py_sha256': sha(source / 'utils/metric.py')}


def load_model(source, checkpoint):
    check_source(source, checkpoint)
    # Never fall back to unsafe pickle or permit arbitrary globals.
    ckpt = torch.load(checkpoint, map_location='cpu', weights_only=True)
    require(ckpt['param_dict']['seq_len'] == LENGTH and ckpt['param_dict']['bg_mode'] == 'concat',
            'this diagnostic requires the pinned 8-frame / background-concat architecture')
    sys.path.insert(0, str(source))
    from model import TrackNet
    model = TrackNet(in_dim=27, out_dim=8)
    model.load_state_dict(ckpt['model'], strict=True)
    for name, parameter in model.named_parameters():
        parameter.requires_grad_(name in {'predictor.weight', 'predictor.bias'})
    require(sum(p.numel() for p in model.parameters() if p.requires_grad) == 520,
            'unexpected predictor architecture')
    # Fixed BN running mean/variance, including during head fitting.
    model.eval()
    return model


def check_group(samples, key):
    partitions = defaultdict(set)
    for sample in samples:
        value = sample[key]
        # Rally and explicit overlap identities are scoped to the source.
        group = (sample['source_sha256'], value) if key in {'rally_group', 'overlap_group'} else value
        partitions[group].add(sample['split'])
    require(all(len(v) == 1 for v in partitions.values()), f'cross-split leakage in {key}')


def check_splits(samples):
    for key in ('source_sha256', 'source_family', 'rally_group', 'overlap_group'):
        check_group(samples,key)
    for i, a in enumerate(samples):
        for b in samples[:i]:
            if a['source_sha256'] == b['source_sha256'] and a['split'] != b['split']:
                # Redundant with source isolation, deliberately explicit for PTS overlap.
                require(a['last_time'] < b['first_time'] or b['last_time'] < a['first_time'],
                        'overlapping source PTS across splits')


def usable(label):
    return label is not None and label['target_identity'] == 'confirmed' and label['status'] in {'visible', 'absent'}


def check_labels(labels, frame_lookup, diagnostic):
    result = {}
    for label in labels:
        sample, index = label.get('sample_id'), label.get('frame_index')
        require(isinstance(sample, str) and integer(index), 'invalid label frame identity')
        key = (sample, index)
        require(key in frame_lookup and key not in result, f'unknown or duplicate label frame: {key}')
        frame = frame_lookup[key]
        require(label.get('status') in STATUSES, f'invalid status: {key}')
        require(label.get('target_identity') in {'confirmed', 'uncertain'}, f'invalid target identity: {key}')
        require(integer(label.get('source_pts')) and label['source_pts'] == frame['source_pts'], f'PTS mismatch: {key}')
        require(Fraction(label.get('timebase', label.get('source_time_base'))) == Fraction(frame['source_time_base']), f'timebase mismatch: {key}')
        require(label.get('image_sha256') == frame['sha256'], f'image hash mismatch: {key}')
        require(label.get('reviewer_kind') in {'agent', 'human'}, f'invalid reviewer kind: {key}')
        if not diagnostic:
            require(label['reviewer_kind'] == 'human' and label.get('human_confirmed') is True,
                    'formal fit/prepare rejects every non-human or unconfirmed label; '
                    'engineering use requires --diagnostic-agent-labels')
            require(label.get('formal_eligible') is not False, 'label explicitly excludes formal use')
        if label['status'] == 'visible':
            require(all(finite(label.get(k)) for k in ('x', 'y', 'uncertainty_px')), f'visible label needs finite point and uncertainty: {key}')
            require(0 <= label['x'] < frame['width'] and 0 <= label['y'] < frame['height'], f'point out of bounds: {key}')
            require(label['uncertainty_px'] > 0, f'uncertainty must be positive: {key}')
        else:
            require(label.get('x') is None and label.get('y') is None, f'non-visible label cannot have a point: {key}')
        result[key] = label
    return result


def target(label, width, height):
    heatmap = np.zeros((HEIGHT, WIDTH), dtype=np.float32)
    if not usable(label):
        return heatmap, 0., None
    if label['status'] == 'absent':
        return heatmap, 1., None
    x, y = label['x'] * WIDTH / width, label['y'] * HEIGHT / height
    sx, sy = max(1.5, label['uncertainty_px'] * WIDTH / width), max(1.5, label['uncertainty_px'] * HEIGHT / height)
    yy, xx = np.ogrid[:HEIGHT, :WIDTH]
    heatmap = np.exp(-.5 * (((xx-x)/sx)**2 + ((yy-y)/sy)**2)).astype(np.float32)
    return heatmap, 1., {'center_xy': [x, y], 'sigma_xy': [sx, sy]}


def masked_loss(prediction, targets, frame_mask):
    require(prediction.shape == targets.shape and frame_mask.shape == prediction.shape[:2], 'loss shape mismatch')
    denominator = frame_mask.sum() * prediction.shape[-1] * prediction.shape[-2]
    require(denominator.item() > 0, 'all-unknown/unsupervised batch rejected')
    # Unlabelled and uncertain frames contribute zero loss and zero gradient.
    # Exact author's utils/metric.py WBCELoss elementwise formula and clamps.
    per_pixel = -(torch.square(1-prediction) * targets * torch.log(torch.clamp(prediction, 1e-7, 1))
        + torch.square(prediction) * (1-targets) * torch.log(torch.clamp(1-prediction, 1e-7, 1)))
    return (per_pixel * frame_mask[..., None, None]).sum() / denominator


PROTOCOL = {'schema_version': 1, 'production': False, 'evaluation': False,
    'model': 'pinned official TrackNet, 27 input channels / 8 heatmaps',
    'supervision': 'only visible+confirmed Gaussian or explicit absent+confirmed zero; other/missing frames mask=0',
    'gaussian': 'sigma per axis = max(1.5, uncertainty_px * model_dimension / original_dimension)',
    'loss': 'author WBCELoss: -((1-p)^2*y*log(clamp(p,1e-7,1)) + p^2*(1-y)*log(clamp(1-p,1e-7,1))); mean over valid-frame pixels only',
    'trainable': ['predictor.weight', 'predictor.bias'], 'trainable_parameters': 520,
    'mode': 'full model eval; BatchNorm statistics fixed; only predictor gradients enabled',
    'background': 'fixed per-sample median over unique frames of caller-declared sequences; offline engineering limitation',
    'limits': ['badminton pretrained weights; no tennis accuracy claim', 'point labels are not speed labels or physical ground truth',
        'full-image WBCE includes background pixels; optimization loss is not localization accuracy',
        'no interpolation, InpaintNet, overlap ensemble, automatic split or full-video inference',
        'any scene touched here must be excluded from future final untouched holdout'],
    'seed': SEED, 'default_device': 'cpu', 'batch_size': 1, 'learning_rate': 1e-5, 'max_steps': 8,
    'sequence_order': 'eligible train sequences sorted by sample_id/start; first max_steps once each, no result-based selection'}


def prepare(args):
    config_path, labels_path = Path(args.config).resolve(), Path(args.labels).resolve()
    config = read(config_path)
    require(config.get('schema_version') == 1 and config.get('purpose') in {'diagnostic_train_only', 'human_training'}, 'invalid protocol purpose/schema')
    require(isinstance(config.get('split_policy'), str) and config['split_policy'].strip(), 'caller must declare split policy')
    require(config.get('samples'), 'no samples configured')
    provenance = check_source(Path(args.source).resolve(), Path(args.checkpoint).resolve())
    # Validate architecture and safe loading during preparation, without forward/backward.
    load_model(Path(provenance['repo']), Path(provenance['checkpoint']))
    samples, lookup, files, sample_ids = [], {}, {}, set()
    for item in config['samples']:
        sample = dict(item)
        sid = sample.get('sample_id')
        require(isinstance(sid, str) and sid not in sample_ids and Path(sid).name == sid, 'invalid/duplicate sample_id')
        sample_ids.add(sid)
        for key in ('source_sha256', 'source_family', 'rally_group', 'overlap_group', 'split'):
            require(isinstance(sample.get(key), str) and sample[key].strip(), f'missing {key}: {sid}')
        require(len(sample['source_sha256']) == 64 and all(c in '0123456789abcdef' for c in sample['source_sha256']), 'source_sha256 must be lower hex')
        require(sample['split'] in {'train', 'validation', 'test'}, 'invalid split')
        if config['purpose'] == 'diagnostic_train_only':
            require(sample['split'] == 'train', 'diagnostic_train_only cannot claim evaluation partitions')
        manifest = resolve(sample['frames_manifest'], config_path.parent)
        frame_doc = read(manifest)
        require(frame_doc.get('review_id') == sid, 'sample_id does not match frame manifest review_id')
        frame_map = {f['window_frame_index']: f for f in frame_doc['frames']}
        require(len(frame_map) == len(frame_doc['frames']), 'duplicate frame manifest index')
        starts = sample.get('sequence_starts')
        require(isinstance(starts, list) and starts and all(integer(s) and s >= 0 for s in starts), 'caller must specify sequence_starts')
        require(len(set(starts)) == len(starts), 'duplicate sequence starts')
        chosen = set()
        for start in starts:
            indices = list(range(start, start+LENGTH))
            require(all(i in frame_map for i in indices), 'incomplete sequence: no padding permitted')
            require(not any(frame_map[i].get('gap_before', False) for i in indices[1:]), 'sequence crosses a decoded PTS gap')
            require(all(Fraction(frame_map[b]['source_pts']) * Fraction(frame_map[b]['source_time_base']) > Fraction(frame_map[a]['source_pts']) * Fraction(frame_map[a]['source_time_base']) for a,b in zip(indices, indices[1:])), 'non-increasing PTS')
            chosen.update(indices)
        for index in sorted(chosen):
            frame = frame_map[index]
            require(Path(frame['filename']).name == frame['filename'], 'frame filename must be a basename')
            image = manifest.parent / frame['filename']
            require(sha(image) == frame['sha256'], 'source image digest mismatch')
            with Image.open(image) as im:
                require(im.size == (frame['width'], frame['height']), 'image geometry mismatch')
            lookup[(sid, index)] = frame
            files[str(image)] = frame['sha256']
        files[str(manifest)] = sha(manifest)
        times = [Fraction(frame_map[i]['source_pts']) * Fraction(frame_map[i]['source_time_base']) for i in chosen]
        sample.update(frames_manifest=str(manifest), frame_indices=sorted(chosen),
                      first_time=str(min(times)), last_time=str(max(times)))
        samples.append(sample)
    # Convert exact times only while checking split isolation; JSON freezes rationals.
    check_splits([{**s, 'first_time': Fraction(s['first_time']), 'last_time': Fraction(s['last_time'])} for s in samples])
    raw_labels = read(labels_path)
    labels = raw_labels.get('labels', raw_labels.get('records')) if isinstance(raw_labels, dict) else raw_labels
    require(isinstance(labels, list), 'labels must be a list or object containing labels')
    label_map = check_labels(labels, lookup, args.diagnostic_agent_labels)
    sequences = []
    for sample in samples:
        for start in sample['sequence_starts']:
            count = sum(usable(label_map.get((sample['sample_id'], i))) for i in range(start, start+LENGTH))
            sequences.append({'sample_id': sample['sample_id'], 'start': start, 'split': sample['split'], 'supervised_frames': count})
    sequences.sort(key=lambda s: (s['sample_id'], s['start']))
    require(any(s['split'] == 'train' and s['supervised_frames'] for s in sequences), 'all-unknown training set rejected')
    out = Path(args.output).resolve()
    require(not out.exists(), 'output must be a new directory')
    out.mkdir(parents=True)
    write(out/'config.json', config)
    write(out/'labels.json', labels)
    background_hashes = {}
    for sample in samples:
        folder = Path(sample['frames_manifest']).parent
        stack = np.stack([np.asarray(Image.open(folder / lookup[(sample['sample_id'], i)]['filename']).convert('RGB')) for i in sample['frame_indices']])
        background = np.median(stack, axis=0).astype(np.uint8)
        path = out / f"{sample['sample_id']}-background.npy"
        np.save(path, background, allow_pickle=False)
        background_hashes[path.name] = sha(path)
    receipt = {'created_at': datetime.now(timezone.utc).isoformat(), 'protocol': PROTOCOL,
        'source': provenance, 'runtime': runtime(), 'runner_sha256': sha(Path(__file__)),
        'config_sha256': sha(out/'config.json'), 'labels_sha256': sha(out/'labels.json'),
        'original_config': {'path': str(config_path), 'sha256': sha(config_path)},
        'original_labels': {'path': str(labels_path), 'sha256': sha(labels_path)},
        'source_files': files, 'backgrounds': background_hashes, 'samples': samples, 'sequences': sequences,
        'production': False, 'human_validated': not args.diagnostic_agent_labels,
        'diagnostic_agent_labels': args.diagnostic_agent_labels,
        'label_counts': dict(Counter(l['status'] for l in labels)),
        'labels_source_metadata': {k:v for k,v in raw_labels.items() if k not in {'labels','records'}} if isinstance(raw_labels,dict) else {},
        'supervised_output_channels': {str(offset): sum(usable(label_map.get((s['sample_id'], s['start']+offset))) for s in sequences) for offset in range(8)},
        'unsupervised_sequence_count': sum(s['supervised_frames']==0 for s in sequences),
        'final_holdout_eligible': False, 'no_evaluation_claim': True}
    write(out/'receipt.json', receipt)
    print(json.dumps({'prepared': str(out), 'sequence_count': len(sequences), 'supervised_sequences': sum(s['supervised_frames']>0 for s in sequences), 'production': False}))


def audit_prepared(path, diagnostic):
    path = Path(path).resolve()
    receipt = read(path/'receipt.json')
    require(receipt['runner_sha256'] == sha(Path(__file__)), 'runner changed since prepare; prepare a fresh run')
    require(receipt['protocol'] == PROTOCOL, 'protocol changed')
    require(receipt['runtime'] == runtime(), 'runtime changed since prepare')
    require(sha(path/'config.json') == receipt['config_sha256'] and sha(path/'labels.json') == receipt['labels_sha256'], 'frozen config/labels changed')
    for name, expected in receipt['backgrounds'].items():
        require(sha(path/name) == expected, 'frozen background changed')
    for name, expected in receipt['source_files'].items():
        require(sha(name) == expected, f'frozen input changed: {name}')
    check_source(Path(receipt['source']['repo']), Path(receipt['source']['checkpoint']))
    lookup = {}
    for sample in receipt['samples']:
        frames = {f['window_frame_index']: f for f in read(sample['frames_manifest'])['frames']}
        lookup.update({(sample['sample_id'], i): frames[i] for i in sample['frame_indices']})
    label_map = check_labels(read(path/'labels.json'), lookup, diagnostic)
    require(not receipt['diagnostic_agent_labels'] or diagnostic, 'diagnostic preparation requires explicit --diagnostic-agent-labels at execution')
    return path, receipt, lookup, label_map


def make_batch(prepared, receipt, lookup, labels, sequence):
    sample = next(s for s in receipt['samples'] if s['sample_id']==sequence['sample_id'])
    sys.path.insert(0, receipt['source']['repo'])
    from dataset import Shuttlecock_Trajectory_Dataset
    indices = list(range(sequence['start'], sequence['start']+LENGTH))
    folder = Path(sample['frames_manifest']).parent
    images = np.stack([np.asarray(Image.open(folder / lookup[(sample['sample_id'], i)]['filename']).convert('RGB')) for i in indices])
    background = np.load(prepared / f"{sample['sample_id']}-background.npy", allow_pickle=False)
    ds = Shuttlecock_Trajectory_Dataset(seq_len=8, sliding_step=8, data_mode='heatmap', bg_mode='concat', frame_arr=images, median=background, padding=False)
    _, inputs = ds[0]
    targets, masks, geometry = [], [], []
    for index in indices:
        frame = lookup[(sample['sample_id'], index)]
        t,m,g = target(labels.get((sample['sample_id'], index)), frame['width'], frame['height'])
        targets.append(t); masks.append(m); geometry.append(g)
    x = torch.from_numpy(inputs).float().unsqueeze(0)
    y = torch.from_numpy(np.stack(targets)).unsqueeze(0)
    mask = torch.tensor([masks], dtype=torch.float32)
    return x, y, mask, geometry, indices


def point_signals(prediction, geometry):
    values = []
    for offset, item in enumerate(geometry):
        if item is None:
            continue
        x,y = item['center_xy']
        grid = torch.tensor([[[[2*x/(WIDTH-1)-1, 2*y/(HEIGHT-1)-1]]]], dtype=torch.float32)
        value = torch.nn.functional.grid_sample(prediction[:,offset:offset+1].detach(), grid, align_corners=True).item()
        values.append({'output_channel':offset,'center_xy':item['center_xy'],'bilinear_prediction_at_label':value})
    return values


def nonpredictor_sha(model):
    h = hashlib.sha256()
    for name,tensor in sorted(model.state_dict().items()):
        if not name.startswith('predictor.'):
            h.update(canonical({'name':name,'shape':list(tensor.shape),'dtype':str(tensor.dtype)}).encode())
            h.update(tensor.detach().cpu().contiguous().numpy().tobytes())
    return h.hexdigest()


def run_batch(args):
    prepared, receipt, lookup, labels = audit_prepared(args.prepared, args.diagnostic_agent_labels)
    require(args.device == 'cpu', 'bounded diagnostic currently supports CPU only')
    require(args.learning_rate == PROTOCOL['learning_rate'], 'learning rate must match frozen protocol')
    require(1 <= args.max_steps <= 8, 'max-steps must be in 1...8')
    require(args.command == 'fit' or args.max_steps == 1, 'forward-backward is exactly one batch without update')
    planned = read(prepared/'config.json').get('planned_optimization', {})
    require(planned.get('seed',SEED) == SEED and planned.get('learning_rate',1e-5) == args.learning_rate,
            'caller optimization plan disagrees with fixed seed/lr')
    require(args.max_steps <= planned.get('maximum_optimizer_steps',8), 'step count exceeds caller plan')
    out = Path(args.output).resolve()
    require(not out.exists(), 'output must be a new directory')
    random.seed(SEED)
    np.random.seed(SEED)
    torch.manual_seed(SEED)
    torch.set_num_threads(4)
    torch.use_deterministic_algorithms(True)
    model = load_model(Path(receipt['source']['repo']), Path(receipt['source']['checkpoint']))
    eligible = [s for s in receipt['sequences'] if s['split']=='train' and s['supervised_frames']>0]
    selected = sorted(eligible, key=lambda s:(s['sample_id'],s['start']))[:args.max_steps]
    require(selected, 'all-unknown training set rejected')
    optimizer = torch.optim.Adam([p for p in model.parameters() if p.requires_grad], lr=args.learning_rate)
    bn_before = {n:b.clone() for n,b in model.named_buffers()}
    head_before = {n:p.detach().clone() for n,p in model.named_parameters() if p.requires_grad}
    frozen_before_sha = nonpredictor_sha(model)
    steps, channel_counts, actual_frames = [], Counter(), []
    import time
    start = time.perf_counter()
    for step_index,sequence in enumerate(selected):
        x,y,mask,geometry,indices = make_batch(prepared,receipt,lookup,labels,sequence)
        optimizer.zero_grad(set_to_none=True)
        prediction = model(x)
        prediction.retain_grad()
        loss = masked_loss(prediction,y,mask)
        require(torch.isfinite(loss).item(), 'nonfinite optimization loss')
        before_points = point_signals(prediction,geometry)
        loss.backward()
        for offset in range(8):
            if mask[0,offset] == 0:
                require(torch.count_nonzero(prediction.grad[0,offset]).item() == 0, 'unknown output received loss gradient')
            else:
                channel_counts[str(offset)] += 1
            frame = lookup[(sequence['sample_id'],indices[offset])]
            actual_frames.append({'sample_id':sequence['sample_id'],'frame_index':indices[offset],
                'step':step_index,'output_channel':offset,'supervised':bool(mask[0,offset].item()),
                'source_pts':frame['source_pts'],'timebase':frame['source_time_base'],'image_sha256':frame['sha256']})
        require(all(p.grad is None for p in model.parameters() if not p.requires_grad), 'frozen parameter received a gradient')
        grad_norm = math.sqrt(sum(float((p.grad.double()**2).sum()) for p in model.parameters() if p.requires_grad))
        require(math.isfinite(grad_norm) and grad_norm > 0, 'invalid predictor gradient')
        if args.command == 'fit':
            optimizer.step()
        with torch.no_grad():
            after = model(x)
            after_loss = masked_loss(after,y,mask).item()
        require(all(torch.equal(bn_before[n], b) for n,b in model.named_buffers()), 'frozen BatchNorm state changed')
        steps.append({'step':step_index,'sequence':sequence,'frame_indices':indices,'frame_mask':mask[0].tolist(),
            'target_geometry':geometry,'input_shape':list(x.shape),'output_shape':list(prediction.shape),
            'optimization_loss_before_step':loss.item(),'optimization_loss_after_same_batch':after_loss,
            'label_point_signals_before':before_points,'label_point_signals_after':point_signals(after,geometry),
            'predictor_gradient_norm':grad_norm})
    elapsed = time.perf_counter()-start
    frozen_after_sha = nonpredictor_sha(model)
    require(frozen_before_sha == frozen_after_sha, 'non-predictor model tensors changed')
    require(sha(receipt['source']['checkpoint']) == CHECKPOINT_SHA, 'official checkpoint changed')
    out.mkdir(parents=True)
    report = {'production': False, 'human_validated': not args.diagnostic_agent_labels,
        'no_evaluation_claim': True, 'command': args.command, 'optimizer_steps': len(steps) if args.command=='fit' else 0,
        'prepared_receipt_sha256': sha(prepared/'receipt.json'), 'config_sha256':receipt['config_sha256'],
        'steps':steps,'actual_frames':actual_frames,'actual_supervised_frames':sum(f['supervised'] for f in actual_frames),
        'actual_supervised_output_channels':{str(i):channel_counts[str(i)] for i in range(8)},
        'learning_rate': args.learning_rate,
        'device': args.device, 'seed': SEED, 'batch_size': 1, 'elapsed_seconds': elapsed,
        'trainable_parameters': 520, 'frozen_buffers_unchanged': True,
        'nonpredictor_state_sha256_before':frozen_before_sha,'nonpredictor_state_sha256_after':frozen_after_sha,
        'official_checkpoint_sha256_after':CHECKPOINT_SHA,
        'predictor_changed': any(not torch.equal(head_before[n], p) for n,p in model.named_parameters() if p.requires_grad),
        'accuracy': None, 'limitations': PROTOCOL['limits']}
    report['optimizer_mask_limit'] = 'Zero masked output-loss gradient does not imply zero predictor-row update after Adam momentum from an earlier supervised step.'
    if args.command == 'fit':
        # Save only a new diagnostic head artifact. Never overwrite official weights.
        torch.save({'production': False, 'human_validated': report['human_validated'],
                    'parent_sha256': CHECKPOINT_SHA, 'predictor': model.predictor.state_dict(),
                    'report': report}, out/'diagnostic-head.pt')
        torch.save({'production':False,'human_validated':report['human_validated'],
                    'parent_sha256':CHECKPOINT_SHA,'predictor':{k.removeprefix('predictor.'):v for k,v in head_before.items()}},out/'head-before.pt')
        report['head_before_sha256'] = sha(out/'head-before.pt')
        report['head_after_sha256'] = sha(out/'diagnostic-head.pt')
    write(out/'report.json', report)
    print(json.dumps(report))


class SelfTests(unittest.TestCase):
    def test_unknown_is_masked_not_zero_negative(self):
        pred = torch.full((1,2,3,3), .4, requires_grad=True)
        labels = torch.zeros_like(pred)
        loss = masked_loss(pred, labels, torch.tensor([[1.,0.]]))
        loss.backward()
        self.assertEqual(pred.grad[0,1].abs().sum().item(), 0.)
        self.assertGreater(pred.grad[0,0].abs().sum().item(), 0.)

    def test_pixel_scaling_and_sigma(self):
        heatmap, mask, geometry = target({'status':'visible','target_identity':'confirmed','x':640.,'y':360.,'uncertainty_px':5.},1280,720)
        self.assertEqual(geometry, {'center_xy':[256.,144.], 'sigma_xy':[2.,2.]})
        self.assertEqual(np.unravel_index(heatmap.argmax(), heatmap.shape), (144,256))
        self.assertEqual(mask, 1.)
        _, mask, _ = target({'status':'visible','target_identity':'uncertain'},1280,720)
        self.assertEqual(mask, 0.)

    def test_all_unknown_rejected(self):
        with self.assertRaisesRegex(ValueError, 'all-unknown'):
            masked_loss(torch.full((1,8,2,2),.5), torch.zeros((1,8,2,2)), torch.zeros((1,8)))

    def test_cross_source_and_rally_split_rejected(self):
        a = {'source_sha256':'a'*64,'source_family':'one','rally_group':'r1','overlap_group':'o1','split':'train','first_time':0,'last_time':1}
        with self.assertRaisesRegex(ValueError, 'source_sha256'):
            check_splits([a,{**a,'split':'test','rally_group':'r2','overlap_group':'o2'}])
        for key in ('source_family','rally_group','overlap_group'):
            b = {**a,'split':'validation'}
            with self.assertRaisesRegex(ValueError,key):
                check_group([a,b],key)

    def test_loss_matches_author_formula(self):
        p = torch.tensor([[[[.2,.7],[.8,.5]],[[.4,.3],[.6,.9]]]])
        y = torch.tensor([[[[0.,1.],[.4,0.]],[[1.,0.],[.7,1.]]]])
        sys.path.insert(0,str(DEFAULT_BASE/'TrackNetV3'))
        from utils.metric import WBCELoss
        self.assertTrue(torch.equal(masked_loss(p,y,torch.ones((1,2))), WBCELoss(p,y)))

    def test_formal_rejects_agent_and_unconfirmed_human(self):
        frame = {'source_pts':10,'source_time_base':'1/600','sha256':'a'*64,'width':1280,'height':720}
        label = {'sample_id':'s','frame_index':0,'source_pts':10,'source_time_base':'1/600','image_sha256':'a'*64,
                 'status':'unknown','target_identity':'uncertain','reviewer_kind':'agent','x':None,'y':None}
        for reviewer in ('agent','human'):
            with self.assertRaisesRegex(ValueError,'formal fit/prepare rejects'):
                check_labels([{**label,'reviewer_kind':reviewer}],{('s',0):frame},False)
        self.assertEqual(len(check_labels([{**label,'reviewer_kind':'human','human_confirmed':True}],{('s',0):frame},False)),1)

    def test_only_explicit_absence_is_negative(self):
        for status in ('unknown','occluded','out_of_frame'):
            heatmap,mask,_ = target({'status':status,'target_identity':'confirmed'},1280,720)
            self.assertEqual(mask,0.)
        heatmap,mask,_ = target({'status':'absent','target_identity':'confirmed'},1280,720)
        self.assertEqual(mask,1.)
        self.assertEqual(float(heatmap.sum()),0.)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    sub = parser.add_subparsers(dest='command')
    prep = sub.add_parser('prepare', help='freeze caller-provided labels, source grouping, inputs and runtime')
    prep.add_argument('--config', required=True)
    prep.add_argument('--labels', required=True)
    prep.add_argument('--output', required=True)
    prep.add_argument('--source', default=str(DEFAULT_BASE/'TrackNetV3'))
    prep.add_argument('--checkpoint', default=str(DEFAULT_BASE/'checkpoints/ckpts/TrackNet_best.pt'))
    prep.add_argument('--diagnostic-agent-labels', action='store_true')
    for name in ('audit','forward-backward','fit'):
        cmd = sub.add_parser(name)
        cmd.add_argument('--prepared', required=True)
        cmd.add_argument('--diagnostic-agent-labels', action='store_true')
        if name != 'audit':
            cmd.add_argument('--output', required=True)
            cmd.add_argument('--device', default='cpu', choices=['cpu'])
            cmd.add_argument('--learning-rate', type=float, default=1e-5)
            cmd.add_argument('--max-steps', type=int, default=1, help='at most 8 fixed eligible sequences; forward-backward permits 1 only')
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests))
        return 0 if result.wasSuccessful() else 1
    require(args.command is not None, 'choose a subcommand or --self-test')
    if args.command == 'prepare':
        prepare(args)
    elif args.command == 'audit':
        _,receipt,_,_ = audit_prepared(args.prepared,args.diagnostic_agent_labels)
        print(json.dumps({'audit':'passed','production':False,'sequences':len(receipt['sequences'])}))
    else:
        run_batch(args)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, FileNotFoundError) as error:
        print(f'ball-track-diagnostic: {error}', file=sys.stderr)
        sys.exit(2)
