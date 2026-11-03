#!/usr/bin/env python3
"""Render an explicitly development-selected association example, no inference.

All six predeclared recipes remain in the source report. This video illustrates
full/threshold0.3 author-area vs offline beam, chosen after development metrics;
it is neither a held-out test nor a speed estimate. No oracle point is drawn.
"""
import argparse
from fractions import Fraction
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from PIL import Image, ImageDraw

HELPER = Path(__file__).with_name('ball-compare-view.py')
spec = importlib.util.spec_from_file_location('ball_media_helpers', HELPER)
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


def panel(source, point, text, color):
    point = media.finite_xy(point, source.size)
    image = source.resize((960, 540), Image.Resampling.LANCZOS)
    draw = ImageDraw.Draw(image)
    if point is not None:
        x, y = point[0]*960/source.width, point[1]*540/source.height
        draw.ellipse((x-10, y-10, x+10, y+10), outline=color, width=3)
    draw.rectangle((0, 0, 959, 34), fill='#101820')
    draw.text((10, 6), text + (' | NO OUTPUT' if point is None else ''), font=media.font(18), fill=color)
    return image


def frames(rows):
    for row in rows:
        source = media.open_verified(Path(row['image_path']), row['image_sha256'], (row['width'], row['height']))
        left = panel(source, row['author']['xy_original'], 'LARGEST AREA | threshold >0.3', media.CYAN)
        right = panel(source, row['selections']['offline_beam_cv']['xy_original'], 'OFFLINE BEAM CV | threshold >0.3', media.ORANGE)
        image = Image.new('RGB', (1920, 632), '#101820')
        image.paste(left, (0, 42)); image.paste(right, (960, 42))
        draw = ImageDraw.Draw(image)
        draw.text((12, 10), f"{row['sample_id']} frame {row['frame_index']:03d} | PTS {row['source_pts']} x {row['source_time_base']}", fill='white', font=media.font(20))
        draw.text((12, 599), 'Development-selected illustration; all recipes reported. Future context used. No interpolation or speed estimate.', fill='#c6d1dc', font=media.font(19))
        yield image


def build(run, output):
    completion = json.loads((run/'completion.json').read_text())
    if completion['status'] != 'complete' or completion['frames_sha256'] != media.sha(run/'frames.jsonl'):
        raise ValueError('Incomplete/changed association predictions')
    if completion['summary_sha256'] != media.sha(run/'summary.json'):
        raise ValueError('Changed association summary')
    selected = [json.loads(line) for line in (run/'frames.jsonl').read_text().splitlines()]
    selected = [row for row in selected if row['recipe'] == 'full-threshold-0.3']
    windows = sorted({row['sample_id'] for row in selected})
    if len(selected) != 480 or set(windows) != {'train-006', 'train-007', 'train-008', 'eval-002'}:
        raise ValueError('Expected four fixed complete windows')
    if output.exists(): raise ValueError('Output already exists')
    output.mkdir(parents=True)
    videos = []
    for window in windows:
        rows = sorted([row for row in selected if row['sample_id'] == window], key=lambda row: row['frame_index'])
        if [row['frame_index'] for row in rows] != list(range(120)):
            raise ValueError('Duplicate or missing original frames')
        times = [Fraction(row['source_pts'])*Fraction(row['source_time_base']) for row in rows]
        if not all(a < b for a, b in zip(times, times[1:])): raise ValueError('Nonmonotonic PTS')
        path = output/(window+'.mp4')
        receipt = media.encode_video(path, frames(rows), 15)
        receipt.update(window=window, source_time_span_seconds=float(times[-1]-times[0]),
                       source_interval_values=sorted({str(b-a) for a, b in zip(times, times[1:])}),
                       description='full threshold0.3 author largest area vs offline beam; development-selected, no speed')
        videos.append(receipt)
    report = {'production': False, 'accuracy': None, 'recipe': 'full-threshold-0.3',
              'selection': 'Illustration chosen after development metrics; all6x4 methods remain in original summary',
              'renderer_sha256': media.sha(Path(__file__)), 'helper_sha256': media.sha(HELPER),
              'predictions_sha256': completion['frames_sha256'], 'videos': videos}
    media.write_json(output/'video-receipt.json', report)
    print(json.dumps({'output': str(output), 'videos': len(videos), 'decoded_frames': sum(v['decoded_frame_count'] for v in videos)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True); parser.add_argument('--output', required=True)
    args = parser.parse_args()
    build(Path(args.run).resolve(), Path(args.output).resolve())
