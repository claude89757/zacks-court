#!/usr/bin/env python3
"""Build native-resolution, PTS-bound continuous offline ball-development windows.

Python standard library plus local ffmpeg/ffprobe. No inference or annotation.
Usage: ball-tune-data.py build --config CONFIG.json --output NEW_DIRECTORY
       ball-tune-data.py --self-test

A window selects either an exact prior frames.json PTS sequence or the first
120 decoded presentation frames at/after an explicitly frozen elapsed time.
Images are not resized. Backgrounds are independently prepared downstream from
48 uniformly spaced frames in each window; their exact hashes are frozen here.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


class DataError(ValueError):
    pass


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda:handle.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()


def identity(path):
    s=path.stat()
    return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)


def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)


def digest(value):return hashlib.sha256(canonical(value).encode()).hexdigest()


def read_json(path):
    def reject(value):raise DataError('Nonfinite JSON value: '+value)
    return json.loads(path.read_text(),parse_constant=reject)


def write_json(path,value):
    with path.open('x',encoding='utf-8') as handle:handle.write(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
    path.chmod(0o600)


def run(command):
    result=subprocess.run(command,capture_output=True,text=True,timeout=180)
    if result.returncode:raise DataError('Command failed: '+result.stderr[-1500:])
    return result


def image_size(path):
    data=path.read_bytes()
    if data[:2]!=b'\xff\xd8':raise DataError('Expected extracted JPEG')
    i=2
    while i<len(data):
        if data[i]!=255:raise DataError('Malformed JPEG')
        while i<len(data) and data[i]==255:i+=1
        marker=data[i];i+=1
        if marker in {0xd8,0xd9} or 0xd0<=marker<=0xd7:continue
        length=int.from_bytes(data[i:i+2],'big')
        if marker in {0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf}:
            height,width=struct.unpack('>HH',data[i+3:i+7]);return width,height
        if length<2:raise DataError('Malformed JPEG segment')
        i+=length
    raise DataError('JPEG dimensions missing')


def fraction_string(value):return f'{value.numerator}/{value.denominator}'


def parse_showinfo(stderr,time_base):
    bases=re.findall(r'config in time_base:\s*(\d+/\d+)',stderr)
    if not bases or any(Fraction(base)!=Fraction(time_base) for base in bases):raise DataError('showinfo timebase mismatch')
    matches=re.findall(r'\bn:\s*(\d+)\s+pts:\s*(-?\d+)\s+pts_time:\s*(\S+).*?\bs:(\d+)x(\d+)',stderr)
    result=[]
    for n,pts,_,width,height in matches:
        if int(n)!=len(result):raise DataError('Non-contiguous extracted frame indices')
        exact=Fraction(int(pts))*Fraction(time_base)
        result.append({'frame_index':int(n),'source_pts':int(pts),'source_time_base':time_base,
                       'source_pts_seconds_rational':fraction_string(exact),'source_pts_seconds':float(exact),
                       'width':int(width),'height':int(height)})
    return result


def uniform_indices(count=120,n=48):
    if not 1<n<=count:raise DataError('Invalid uniform background selection')
    return [(i*(count-1))//(n-1) for i in range(n)]


def check_continuity(frames,expected_pts,nominal_rate):
    if len(frames)!=120 or [f['frame_index'] for f in frames]!=list(range(120)):raise DataError('Exactly120 contiguous decoded frames required')
    if [f['source_pts'] for f in frames]!=expected_pts:raise DataError('Independent ffprobe PTS crosscheck failed')
    base=Fraction(frames[0]['source_time_base']);deltas=[]
    for before,after in zip(frames,frames[1:]):
        delta=Fraction(after['source_pts']-before['source_pts'])*base
        if delta<=0:raise DataError('Non-increasing presentation PTS')
        deltas.append(delta)
    gaps=[i+1 for i,delta in enumerate(deltas) if delta>Fraction(3,2)/nominal_rate]
    if gaps:raise DataError('Temporal discontinuity in selected decoded frames; no replacement is automatic')
    return {'consecutive_decoded_frame_identity':True,'independent_ffprobe_pts_equal':True,
            'time_delta_values_rational':sorted({fraction_string(d) for d in deltas}),
            'large_gap_frame_indices':gaps,'large_gap_rule':'delta > 1.5 / nominal frame rate; ordinal adjacency independently checked',
            'eight_frame_sequences':[{'start':start,'indices':list(range(start,start+8)),
                                     'source_pts':[f['source_pts'] for f in frames[start:start+8]],
                                     'continuous':True} for start in range(0,120,8)]}


def probe_source(spec):
    path=Path(spec['path']).expanduser().resolve()
    before=identity(path);actual=sha(path)
    if identity(path)!=before or actual!=spec['expected_sha256']:raise DataError('Source SHA/stat mismatch')
    payload=json.loads(run(['ffprobe','-v','error','-select_streams','v:0','-show_streams','-show_format','-of','json',str(path)]).stdout)
    stream=payload['streams'][0]
    rotation=next((s['rotation'] for s in stream.get('side_data_list',[]) if 'rotation' in s),stream.get('tags',{}).get('rotate',0))
    rotation=float(rotation)
    if rotation%90!=0:raise DataError('Non-right-angle orientation needs explicit review')
    width,height=stream['width'],stream['height']
    oriented=(height,width) if abs(rotation)%180==90 else (width,height)
    return {'source_id':spec['source_id'],'source_path':str(path),'source_sha256':actual,
            'source_family':spec['source_family'],'source_bytes':before[2],'stream_index':stream['index'],
            'source_time_base':stream['time_base'],'source_start_pts':stream.get('start_pts',0),
            'duration_seconds':stream['duration'],'duration_rational':fraction_string(Fraction(stream['duration'])),
            'coded_width':width,'coded_height':height,'width':oriented[0],'height':oriented[1],
            'rotation_degrees':rotation,'nominal_frame_rate':stream['r_frame_rate'],
            'average_frame_rate':stream['avg_frame_rate'],'codec_name':stream['codec_name'],
            'pix_fmt':stream.get('pix_fmt'),'color_primaries':stream.get('color_primaries'),
            'color_transfer':stream.get('color_transfer'),'camera_device':'unknown','camera_height':'unknown',
            'camera_zoom':'unknown','capture_settings_basis':'user-confirmed lack of records',
            '_initial_identity':before}


def extract(source,spec,root):
    window=spec['window_id'];directory=root/window;directory.mkdir(mode=0o700)
    base=Fraction(source['source_time_base']);selection=spec['selection'];old_pts=None
    if selection['kind']=='prior_integer_pts_sequence':
        old_path=Path(selection['frames_manifest']).resolve();old=read_json(old_path)
        old_pts=[f['source_pts'] for f in old['frames']]
        if len(old_pts)!=120 or old['frames'][0]['source_time_base']!=source['source_time_base']:raise DataError('Old frame manifest shape mismatch')
        lower=old_pts[0]
        selection={**selection,'frames_manifest_sha256':sha(old_path),'first_integer_pts':lower}
    elif selection['kind']=='duration_fraction':
        fraction=Fraction(selection['fraction'])
        if not 0<=fraction<1:raise DataError('Invalid duration fraction')
        elapsed=Fraction(source['duration_rational'])*fraction
        lower=source['source_start_pts']+math.ceil(elapsed/base)
        selection={**selection,'target_elapsed_seconds_rational':fraction_string(elapsed),'target_lower_integer_pts':lower,
                   'replacement_policy':'none, including no-play content'}
    else:raise DataError('Unsupported frozen window selection')
    origin=Fraction(source['source_start_pts'])*base
    seek=max(origin,Fraction(lower)*base-Fraction(1,2))
    seek_us=math.floor(seek*1000000);seek_text=f'{seek_us//1000000}.{seek_us%1000000:06d}'
    # The extra decode budget does not define membership; only integer PTS and
    # first120 consecutive decoder outputs do. There is no fps conversion.
    upper=Fraction(lower)*base+12
    probe_command=['ffprobe','-v','error','-threads','2','-select_streams',str(source['stream_index']),
                   '-read_intervals',f'{seek_text}%{float(upper):.9f}','-show_frames',
                   '-show_entries','frame=pts,best_effort_timestamp','-of','json',source['source_path']]
    decoded=json.loads(run(probe_command).stdout)['frames']
    if any('pts' not in f for f in decoded):raise DataError('Decoded frame lacks integer source PTS')
    expected=[f['pts'] for f in decoded if f['pts']>=lower][:120]
    if len(expected)!=120:raise DataError('Insufficient decoded frames; do not replace selection automatically')
    if old_pts is not None and expected!=old_pts:raise DataError('Original full-resolution PTS differs from old120-frame identity')
    command=['ffmpeg','-nostdin','-hide_banner','-loglevel','info','-n','-threads','2','-filter_threads','1',
             '-copyts','-seek_timestamp','1','-ss',seek_text,'-t',f'{float(upper-seek):.9f}','-i',source['source_path'],
             '-map',f'0:{source["stream_index"]}','-an','-sn','-dn','-vf',f'trim=start_pts={lower},trim=end_frame=120,showinfo',
             '-fps_mode','passthrough','-q:v','2','-start_number','0',str(directory/'frame-%05d.jpg')]
    result=run(command);(root/'audit'/f'{window}-ffmpeg.log').write_text(result.stderr)
    frames=parse_showinfo(result.stderr,source['source_time_base'])
    continuity=check_continuity(frames,expected,Fraction(source['nominal_frame_rate']))
    files=sorted(directory.glob('frame-*.jpg'))
    if len(files)!=120:raise DataError('JPEG file count differs from decoded frame count')
    for frame,file in zip(frames,files):
        if file.name!=f'frame-{frame["frame_index"]:05d}.jpg':raise DataError('JPEG ordinal mismatch')
        if image_size(file)!=(source['width'],source['height']) or (frame['width'],frame['height'])!=(source['width'],source['height']):raise DataError('Native oriented image size mismatch')
        frame.update(image_path=f'{window}/{file.name}',image_sha256=sha(file));file.chmod(0o600)
    indices=uniform_indices()
    return {'window_id':window,'sample_id':window,'split':spec['split'],'source_id':source['source_id'],
            'source_sha256':source['source_sha256'],'source_family':source['source_family'],
            'rally_group':spec.get('rally_group','development-window:'+window),
            'overlap_group':spec.get('overlap_group','development-window:'+window),
            'rally_identity_basis':spec.get('rally_identity_basis','unknown; window ID is not a claim of independent rally'),
            'source_time_base':source['source_time_base'],'width':source['width'],'height':source['height'],
            'selection':selection,'frames':frames,'continuity':continuity,
            'background':{'method':'median','scope':'this window only; never shared across splits','indices':indices,
                          'image_sha256':[frames[i]['image_sha256'] for i in indices],
                          'includes_future_frames':True,'offline_only':True,
                          'prepare_rule':'Decode original-resolution RGB; per-pixel median of48 selected originals, cast uint8 once; crop/resize the same frozen background for full/ROI downstream'},
            'label_plan':{'indices':spec.get('label_indices',[]),'status':'unlabelled','reviewer_kind':None},
            'roi':{'normalized_xyxy':[0.1,0.1,0.9,0.9],'coordinate_space':'oriented full source image','selection_basis':'root-fixed center80 percent before predictions; same rule for all splits'},'roi_status':'root-fixed; not selected from model results',
            'first_frame_path':frames[0]['image_path'],'extraction':{'ffmpeg_command':command,'ffprobe_command':probe_command,
             'format':'JPEG q2; original oriented spatial resolution; decoder color conversion, no explicit HDR tone map',
             'no_scaling':True,'no_predictions':True,'no_fps_conversion':True}}


def build(config_path,output):
    if output.exists() or output.is_symlink():raise DataError('Output exists; choose a new directory')
    config=read_json(config_path);config_sha=sha(config_path)
    sources={s['source_id']:probe_source(s) for s in config['sources']}
    if len(sources)!=len(config['sources']):raise DataError('Duplicate source ID')
    windows=config['windows'];ids=[w['window_id'] for w in windows]
    if len(set(ids))!=len(ids) or any(not re.fullmatch('[a-zA-Z0-9-]+',x) for x in ids):raise DataError('Invalid or duplicate window IDs')
    split_sources={}
    for window in windows:
        if window['split'] not in {'train','eval'}:raise DataError('Split must be train or eval')
        source=sources[window['source_id']]
        key=source['source_sha256']
        if key in split_sources and split_sources[key]!=window['split']:raise DataError('Same source SHA crosses train/eval')
        split_sources[key]=window['split']
    output.parent.mkdir(parents=True,exist_ok=True)
    staging=Path(tempfile.mkdtemp(prefix='.ball-tune-',dir=output.parent));staging.chmod(0o700)
    (staging/'audit').mkdir(mode=0o700)
    try:
        extracted=[]
        for spec in windows:
            window=extract(sources[spec['source_id']],spec,staging);extracted.append(window)
            print(f"{window['window_id']}: 120 original-resolution frames, first PTS {window['frames'][0]['source_pts']}, {window['width']}x{window['height']}",flush=True)
        for source in sources.values():
            path=Path(source['source_path'])
            if identity(path)!=source['_initial_identity'] or sha(path)!=source['source_sha256'] or identity(path)!=source['_initial_identity']:raise DataError('Source changed during extraction')
            del source['_initial_identity']
        if sha(config_path)!=config_sha:raise DataError('Config changed during extraction')
        manifest={'schema_version':1,'config_sha256':config_sha,'generator_sha256':sha(Path(__file__)),
                  'sources':list(sources.values()),'windows':extracted,'data_root':str(output.resolve()),
                  'split_basis':'root-frozen train/eval source assignment; physical scene independence not verified',
                  'training_ready':False,'labels_created':0,'roi_confirmed':True,'independent_test_established':False,
                  'pts_semantics':'FFmpeg decoded presentation PTS in original stream time_base; independently crosschecked with ffprobe; not AVFoundation PTS',
                  'limitations':['All images are private original-resolution decoded frames; no inference or annotations.',
                                 'Only existing source frames are extracted; no interpolation, fps conversion, or source replacement.',
                                 'Background uses future frames from its own window, and is for offline development only.',
                                 'ROI is root-fixed normalized center80 percent, independent of model output.',
                                 'Capture height/device/zoom were not recorded and remain unknown.']}
        manifest['dataset_id']='ball-tune-'+digest({'config_sha256':config_sha,'window_frames':[[f['image_sha256'] for f in w['frames']] for w in extracted]})[:24]
        write_json(staging/'manifest.json',manifest)
        write_json(staging/'audit'/'config.json',config)
        output.mkdir(mode=0o700)
        for path in staging.iterdir():path.rename(output/path.name)
        staging.rmdir()
        return {'output':str(output.resolve()),'manifest_sha256':sha(output/'manifest.json'),'frames':sum(len(w['frames']) for w in extracted),
                'windows':[{'window_id':w['window_id'],'split':w['split'],'first_pts':w['frames'][0]['source_pts'],
                            'first_frame':str((output/w['first_frame_path']).resolve()),'width':w['width'],'height':w['height']} for w in extracted]}
    except Exception:
        shutil.rmtree(staging,ignore_errors=True);raise


class Tests(unittest.TestCase):
    def test_uniform_48_is_fixed_and_spans_window(self):
        values=uniform_indices();self.assertEqual(len(set(values)),48);self.assertEqual((values[0],values[-1]),(0,119))
        self.assertEqual(values,[(i*119)//47 for i in range(48)])
    def test_real_8_frame_sequences_accept_rational_30fps(self):
        pts=[round(i*1000000/30) for i in range(120)]
        frames=[{'frame_index':i,'source_pts':p,'source_time_base':'1/1000000'} for i,p in enumerate(pts)]
        result=check_continuity(frames,pts,Fraction(30));self.assertEqual(len(result['eight_frame_sequences']),15)
        self.assertTrue(all(len(s['indices'])==8 for s in result['eight_frame_sequences']))
    def test_missing_or_reordered_pts_rejected(self):
        pts=list(range(0,1200,10));frames=[{'frame_index':i,'source_pts':p,'source_time_base':'1/600'} for i,p in enumerate(pts)]
        with self.assertRaises(DataError):check_continuity(frames,pts[:-1],Fraction(60))
        frames[40]['source_pts']=frames[39]['source_pts']
        with self.assertRaises(DataError):check_continuity(frames,[f['source_pts'] for f in frames],Fraction(60))
    def test_temporal_gap_rejected(self):
        pts=[i*10+(100 if i>=50 else 0) for i in range(120)]
        frames=[{'frame_index':i,'source_pts':p,'source_time_base':'1/600'} for i,p in enumerate(pts)]
        with self.assertRaises(DataError):check_continuity(frames,pts,Fraction(60))
    def test_showinfo_preserves_integer_pts(self):
        log='config in time_base: 1/600, frame_rate:60/1\nn: 0 pts:154520 pts_time:257.533 s:1920x1080\nn: 1 pts:154530 pts_time:257.55 s:1920x1080'
        result=parse_showinfo(log,'1/600');self.assertEqual(result[0]['source_pts'],154520)
        self.assertEqual(result[0]['source_pts_seconds_rational'],'3863/15')
        with self.assertRaises(DataError):parse_showinfo(log,'1/30')


def main():
    p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter);p.add_argument('--self-test',action='store_true')
    sub=p.add_subparsers(dest='command');b=sub.add_parser('build');b.add_argument('--config',type=Path,required=True);b.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    if args.self_test:
        r=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests));return 0 if r.wasSuccessful() else 1
    if args.command!='build':p.error('Choose build or --self-test')
    try:print(json.dumps(build(args.config.resolve(),args.output.absolute()),ensure_ascii=False,indent=2));return 0
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:print('ball-tune-data: '+str(error),file=sys.stderr);return 2


if __name__=='__main__':sys.exit(main())
