#!/usr/bin/env python3
"""Private development replay of a completed expanded tracking experiment.

No inference, fitting, interpolation, speed calculation or oracle selection.
Reads original manifest JPEGs; existing agent annotations are references only.
"""
import argparse
from collections import Counter
from fractions import Fraction
from functools import lru_cache
import hashlib
import html
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from PIL import Image, ImageDraw, ImageFont, __version__ as pillow_version

HERE = Path(__file__).resolve()
MODELS = ('official_base', 'old_head72_delta', 'full_final1024')
COLORS = ('#39d9ec', '#ffab52', '#76e6ab')
SIZE = (1920, 600)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(4*1024*1024), b''):
            result.update(block)
    return result.hexdigest()


def read(path):
    return json.loads(Path(path).read_text(), parse_constant=lambda v: (_ for _ in ()).throw(ValueError('Nonfinite JSON: '+v)))


def resolve(path, base):
    return (base / Path(path).expanduser()).resolve()


def checked(path, expected):
    require(isinstance(expected, str) and len(expected) == 64 and sha(path) == expected,
            'SHA256 mismatch: '+str(path))
    return path


def pts(row):
    require(type(row['source_pts']) is int, 'Original source PTS must be integer')
    base = Fraction(row['source_time_base'])
    require(base > 0, 'Invalid source time base')
    return row['source_pts'] * base


def unqualified(doc):
    require(doc.get('production') is False and doc.get('formal_eligible') is False,
            'Expected development-only experiment')


def completed(root, index_path):
    require(not (root/'failure.json').exists(), 'Failed run cannot be rendered')
    completion = read(root/'completion.json')
    require(completion.get('status') == 'complete' and completion.get('steps') == 1024,
            'Need completed final1024 run')
    unqualified(completion)
    for name, expected in completion['files'].items():
        require(Path(name).name == name and name not in ('.', '..'), 'Invalid run artifact path')
        checked(root/name, expected)
    for name in ('protocol.json', 'receipt.json', 'report.json', 'predictions.jsonl'):
        require(name in completion['files'], 'Unregistered run artifact: '+name)
    protocol, receipt, report = [read(root/name) for name in ('protocol.json', 'receipt.json', 'report.json')]
    require(sha(root/'protocol.json') == completion['protocol_sha256'] == receipt['protocol_sha256'] == report['protocol_sha256'],
            'Protocol binding differs')
    require(Path(protocol['input_index']).resolve() == index_path, 'Run uses another input index')
    checked(index_path, protocol['input_index_sha256'])
    require(receipt['input_files'] == protocol['input_files'], 'Input receipts differ')
    for path, expected in protocol['input_files'].items():
        checked(Path(path), expected)
    require(protocol['comparison_models'] == list(MODELS), 'Comparison model list differs')
    require(report.get('all_inputs_unchanged_before_and_after') is True and
            report.get('same_native_rgb_background_tensor_across_models') is True, 'Missing completed input guarantees')
    unqualified(report)
    require(report['success']['speed_metrics'] is None, 'Speed metrics are unavailable')
    for model, key in zip(MODELS, ('base', 'old_head72', 'final1024')):
        evaluation = report['evaluations'][key]
        require(evaluation['model'] == model and evaluation['frame_count'] == 2640,
                'Incomplete model evaluation')
    return completion, protocol, report


def load_inputs(index_path, bound):
    index, base = read(index_path), index_path.parent
    require(index['schema_version'] == 1, 'Unsupported input index')
    def reference(ref):
        path = resolve(ref['path'], base)
        checked(path, ref['sha256'])
        require(bound.get(str(path)) == ref['sha256'], 'Input reference not bound to run: '+str(path))
        return path
    entries = {row['window_id']: row for row in index['windows']}
    require(len(entries) == len(index['windows']) == 22, 'Need22 unique windows')
    require(all(Path(name).name == name and name not in ('.', '..') for name in entries), 'Invalid window identifier')
    labels = {}
    for ref in index['label_files']:
        doc = read(reference(ref))
        rows = doc if isinstance(doc, list) else doc.get('records', doc.get('labels'))
        require(isinstance(rows, list), 'Missing labels list')
        for label in rows:
            key = (label['sample_id'], label['frame_index'])
            require(key not in labels and label['status'] in ('visible', 'unknown'), 'Invalid/duplicate label')
            labels[key] = label
    require(len(labels) == 1056, 'Expected1056 existing agent annotations')
    windows = {}
    for name, entry in entries.items():
        manifest = reference(entry['manifest'])
        matches = [w for w in read(manifest)['windows'] if w['window_id'] == name]
        require(len(matches) == 1, 'Missing/duplicate manifest window')
        window = matches[0]
        require(len(window['frames']) == 120, 'Need120 original target frames')
        for i, frame in enumerate(window['frames']):
            require(frame['frame_index'] == i, 'Frame order differs')
            path = resolve(frame['image_path'], manifest.parent)
            checked(path, frame['image_sha256'])
            require(bound.get(str(path)) == frame['image_sha256'], 'JPEG not bound to run')
            frame['_path'] = path
            pts(frame)
            label = labels.get((name, i))
            if label:
                require(label['image_sha256'] == frame['image_sha256'] and pts(label) == pts(frame), 'Label frame binding differs')
        windows[name] = window
    require(set(k[0] for k in labels) == set(entries), 'Unbound label window')
    return entries, windows, labels


def index_predictions(path, windows):
    rows = {}
    with path.open() as handle:
        for line in handle:
            row = json.loads(line)
            key = (row['model'], row['sample_id'], row['frame_index'])
            require(key not in rows and key[0] in MODELS and key[1] in windows and
                    type(key[2]) is int and 0 <= key[2] < 120, 'Invalid/duplicate prediction identity')
            window = windows[key[1]]
            require(row['source_sha256'] == window['source_sha256'] and pts(row) == pts(window['frames'][key[2]]),
                    'Prediction source/PTS binding differs')
            unqualified(row)
            require(row.get('speed_kmh', 'missing') is None, 'Speed unavailable')
            candidate = row['causal_selection']['candidate']
            if candidate is not None:
                require(candidate in row['candidate_bank']['candidates'], 'Selected point outside candidate bank')
            rows[key] = point(candidate['originalXY'], window) if candidate else None
    require(len(rows) == 7920, 'Need all7920 model/window/frame predictions from completed run')
    return rows


def point(value, window):
    require(isinstance(value, (list, tuple)) and len(value) == 2 and
            all(type(v) in (int, float) and math.isfinite(v) for v in value), 'Invalid point')
    require(0 <= value[0] < window['width'] and 0 <= value[1] < window['height'], 'Point outside original image')
    return value


def agent_point(label, window):
    if not label or label['status'] != 'visible':
        return None
    return point([label['x'], label['y']], window)


@lru_cache(maxsize=8)
def font(size):
    for name in ('/System/Library/Fonts/Supplemental/Arial.ttf', 'DejaVuSans.ttf'):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def presentation(name, i, source, window, selected, label):
    image = Image.new('RGB', SIZE, '#101820')
    draw = ImageDraw.Draw(image)
    frame = window['frames'][i]
    draw.text((12, 8), 'PYTHON DEVELOPMENT-ONLY | agent/reference tracking | SPEED UNAVAILABLE', font=font(24), fill='white')
    draw.text((12, 40), f"{name} | frame {i:03d}/119 | source PTS {frame['source_pts']} x {frame['source_time_base']} = {float(pts(frame)):.6f}s", font=font(21), fill='white')
    reference = agent_point(label, window)
    for col, (model, color) in enumerate(zip(MODELS, COLORS)):
        x = col*640
        draw.text((x+12, 79), model, font=font(23), fill=color)
        panel = source.resize((640, 360), Image.Resampling.LANCZOS)
        overlay = ImageDraw.Draw(panel)
        for value, square, ink in ((selected[model], False, color), (reference, True, '#ff79dc')):
            if value is None:
                continue
            px, py = value[0]*640/window['width'], value[1]*360/window['height']
            box = (px-7, py-7, px+7, py+7)
            if square:
                overlay.rectangle(box, outline=ink, width=2)
            else:
                overlay.ellipse(box, outline=ink, width=3)
        image.paste(panel, (x, 112))
        draw.text((x+12, 481), 'tracker: selected' if selected[model] is not None else 'tracker: UNKNOWN / no selection', font=font(21), fill=color)
    state = 'VISIBLE agent reference' if reference is not None else ('UNKNOWN reference (not negative)' if label else 'UNLABELLED (not negative)')
    draw.text((12, 514), 'Magenta square: '+state+' | circles: causal_selection only; no oracle', font=font(21), fill='#ff79dc')
    draw.text((12, 546), '120 original JPEG frames at 15fps / 8s; approx 0.25x at 60fps. Variable source PTS: not exact slow motion.', font=font(20), fill='white')
    draw.text((12, 573), '8-frame detector lookahead up to7 frames; agent development evidence only. No native full speed-pipeline or physical accuracy claim.', font=font(18), fill='#c6d1dc')
    return image


def encode(path, images):
    process = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-n', '-f', 'rawvideo',
        '-pixel_format', 'rgb24', '-video_size', '1920x600', '-framerate', '15', '-i', 'pipe:0', '-an',
        '-c:v', 'libx264', '-preset', 'fast', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(path)],
        stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    count = 0
    try:
        for image in images:
            require(image.size == SIZE, 'Unexpected render size')
            process.stdin.write(image.tobytes())
            count += 1
        process.stdin.close()
        error = process.stderr.read().decode()
        require(process.wait() == 0, 'ffmpeg encode failed: '+error[-1000:])
    except BaseException:
        process.kill(); process.wait()
        raise
    require(count == 120, 'Expected120 rendered frames')
    probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-count_frames', '-show_entries',
        'stream=nb_read_frames,width,height,duration,avg_frame_rate', '-of', 'json', str(path)], check=True, capture_output=True, text=True)
    stream = json.loads(probe.stdout)['streams'][0]
    require(int(stream['nb_read_frames']) == 120 and (stream['width'], stream['height']) == SIZE and
            Fraction(stream['avg_frame_rate']) == 15 and abs(float(stream['duration'])-8) < 1e-6, 'Decoded video shape/count/timing differs')
    decoded = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-xerror', '-i', str(path),
        '-map', '0:v:0', '-f', 'null', '-'], check=True, capture_output=True, text=True)
    require(not decoded.stderr.strip(), 'Full decode reported errors')
    path.chmod(0o600)
    return {'file': path.name, 'sha256': sha(path), 'encoded_frames': count, 'decoded_frames': 120,
            'ffprobe': stream, 'full_ffmpeg_decode': 'passed'}


def build(args):
    root, index_path, output = Path(args.run).resolve(), Path(args.input_index).resolve(), Path(args.output).absolute()
    require(not output.exists() and not output.is_symlink(), 'Choose a NEW output directory')
    require('.local' in output.parts or '.private.local' in output.parts, 'Private output must be under .local or .private.local')
    completion, protocol, report = completed(root, index_path)
    entries, windows, labels = load_inputs(index_path, protocol['input_files'])
    predictions = index_predictions(root/'predictions.jsonl', windows)
    selected = args.windows or [name for name, row in entries.items() if row['split'] in ('sourcecheck_dev', 'slow_dev')]
    require(selected and len(set(selected)) == len(selected) and all(n in windows for n in selected), 'Unknown/duplicate window selection')
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.expanded-view-', dir=output.parent)); temporary.chmod(0o700)
    published = False
    try:
        videos = []
        for name in selected:
            window = windows[name]
            def frames():
                for i, frame in enumerate(window['frames']):
                    checked(frame['_path'], frame['image_sha256'])
                    with Image.open(frame['_path']) as source:
                        source.load()
                        require(source.format == 'JPEG' and source.size == (window['width'], window['height']), 'Original JPEG dimensions/format differ')
                        yield presentation(name, i, source.convert('RGB'), window,
                            {m: predictions[(m, name, i)] for m in MODELS}, labels.get((name, i)))
            video = encode(temporary/(name+'.mp4'), frames())
            video.update(window_id=name, split=entries[name]['split'],
                label_counts=dict(Counter(labels[(name,i)]['status'] for i in range(120) if (name,i) in labels)),
                no_selection_counts={m: sum(predictions[(m,name,i)] is None for i in range(120)) for m in MODELS},
                source_frames=[{k: f[k] for k in ('frame_index', 'image_sha256', 'source_pts', 'source_time_base')} for f in window['frames']])
            videos.append(video)
            print('EXPANDED_VIEW_OK '+name+': 120 fully decoded frames / 15fps / 8s', flush=True)
        links = ''.join('<li><a href="'+html.escape(v['file'], quote=True)+'">'+html.escape(v['window_id'])+'</a> — '+html.escape(v['split'])+'</li>' for v in videos)
        page = '<!doctype html><meta charset="utf-8"><title>Private expanded development tracking</title><h1>Development-only agent/reference tracking</h1><p>Speed unavailable. Python algorithm comparison; no native full speed-pipeline or physical accuracy claim. Existing agent labels are not human truth; unknown is not negative.</p><p>All120 manifest JPEGs per window; 15fps /8s, approximately0.25x for60fps sources. Variable source PTS is shown; playback is not exact slow motion. Circles use causal_selection only. Magenta squares are visible agent references. No oracle overlay. Detector sees up to7 later frames.</p><p>Private local artifacts: do not copy source frames or screenshots into README.</p><p><a href="video-receipt.json">SHA256 and full decode receipt</a></p><ul>'+links+'</ul>'
        (temporary/'index.html').write_text(page)
        (temporary/'index.html').chmod(0o600)
        receipt = {'schema_version': 1, 'development_only': True, 'production': False, 'formal_eligible': False,
            'human_validated': False, 'speed_metrics': None, 'tool_sha256': sha(HERE), 'pillow_version': pillow_version,
            'input_index_sha256': sha(index_path), 'run_completion_sha256': sha(root/'completion.json'),
            'run_report_sha256': sha(root/'report.json'), 'protocol_sha256': completion['protocol_sha256'],
            'predictions_sha256': completion['files']['predictions.jsonl'], 'verified_prediction_rows': len(predictions),
            'agent_annotation_count': len(labels), 'verified_original_jpeg_count': 2640,
            'model_states': {key: value['model_state_sha256'] for key, value in report['evaluations'].items()},
            'models': list(MODELS), 'videos': videos,
            'total_rendered_frames': len(videos)*120, 'total_fully_decoded_frames': len(videos)*120,
            'html_sha256': sha(temporary/'index.html'), 'display_policy': 'Original manifest JPEGs scaled identically; causal selections and visible agent reference only; unknown/unlabelled never filled or treated as negative.',
            'ffmpeg_version': subprocess.run(['ffmpeg', '-version'], check=True, capture_output=True, text=True).stdout.splitlines()[0]}
        (temporary/'video-receipt.json').write_text(json.dumps(receipt, indent=2, allow_nan=False)+'\n')
        (temporary/'video-receipt.json').chmod(0o600)
        require(not output.exists(), 'Output appeared during rendering')
        temporary.rename(output); published = True
        print(json.dumps({'output': str(output), 'videos': len(videos), 'fully_decoded_frames': len(videos)*120}))
    finally:
        if not published:
            shutil.rmtree(temporary)


class SelfTests(unittest.TestCase):
    def test_unknown_is_not_a_reference_point(self):
        self.assertIsNone(agent_point({'status': 'unknown', 'x': 10, 'y': 10}, {'width': 20, 'height': 20}))
        self.assertIsNone(agent_point(None, {}))

    def test_synthetic_single_frame_only(self):
        window = {'width': 1280, 'height': 720, 'frames': [{'source_pts': 123, 'source_time_base': '1/600'}]}
        image = presentation('synthetic-self-test', 0, Image.new('RGB', (1280,720)), window,
                             {m: None for m in MODELS}, {'status': 'unknown'})
        self.assertEqual(image.size, SIZE)

    def test_incomplete_run_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root/'completion.json').write_text('{"status":"running"}')
            with self.assertRaises(ValueError):
                completed(root, root/'index.json')

    def test_hash_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'input'
            path.write_bytes(b'original')
            self.assertEqual(checked(path, sha(path)), path)
            with self.assertRaises(ValueError):
                checked(path, '0'*64)

    def test_bad_pts_and_point_rejected(self):
        with self.assertRaises(ValueError):
            pts({'source_pts': 1, 'source_time_base': '-1/60'})
        with self.assertRaises(ValueError):
            point([float('nan'), 0], {'width': 20, 'height': 20})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-index'); parser.add_argument('--run'); parser.add_argument('--output')
    parser.add_argument('--windows', nargs='+', help='Explicit window IDs; defaults to sourcecheck_dev and slow_dev')
    parser.add_argument('--self-test', action='store_true', help='Synthetic single-frame checks only; not video validation')
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)).wasSuccessful() else 1
    if not all((args.input_index, args.run, args.output)):
        parser.error('--input-index, --run and --output are required')
    try:
        build(args)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print('EXPANDED_VIEW_REFUSED: '+str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
