#!/usr/bin/env python3
"""Frozen exploratory comparison of official TrackNet and an agent-label diagnostic head.

This does not train, tune thresholds, measure tennis accuracy, or create a holdout.
Run with the task-local TrackNet venv. Outputs must use a new directory.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import platform
import subprocess
import sys
import time
import unittest

sys.dont_write_bytecode = True

import cv2
import numpy as np
from PIL import Image
import torch

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / '.local/speed-training/tracknet-smoke-20261028'
PREP = ROOT / '.local/speed-training/ball-train-prep-20261029'
PIN = '6eda442ada1740573f200f836d93edc9a541ee86'
BASE_SHA = 'df867641a02712b021f04548ff4b1208ddfdb47f629ab2094ceb978667e83b1a'
HEAD_SHA = 'b490f81fb8c17b6b52e606f0d21a9778e9c1bf178077a4b9fd1cae556fa44f84'
BEFORE_SHA = 'e7647a50cb3198ac34f94eeb3e076d2aadcdb9bd4e4404c46e3764c81e120fd0'
FIXED_SAMPLES = ('sample-006', 'sample-007', 'sample-008')
FIXED_HEATMAP_FRAMES = (10, 50, 70, 90, 110)
WIDTH, HEIGHT, LENGTH = 512, 288, 8


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):
            h.update(block)
    return h.hexdigest()


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    with open(path,'x') as f:
        json.dump(value,f,indent=2,sort_keys=True,allow_nan=False)
        f.write('\n')


def model_sha(model):
    h = hashlib.sha256()
    for name,tensor in sorted(model.state_dict().items()):
        h.update(canonical({'name':name,'shape':list(tensor.shape),'dtype':str(tensor.dtype)}).encode())
        h.update(tensor.detach().cpu().contiguous().numpy().tobytes())
    return h.hexdigest()


def prediction(heatmap, original_width, original_height):
    """Unchanged author >0.5, largest boundingRect-area contour, integer center/remap."""
    mask = (heatmap > .5).astype(np.uint8)*255
    contours,_ = cv2.findContours(mask.copy(),cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE)
    boxes = [cv2.boundingRect(c) for c in contours]
    bbox = max(boxes,key=lambda b:b[2]*b[3]) if boxes else None
    candidate = None
    if bbox:
        cx,cy = int(bbox[0]+bbox[2]/2),int(bbox[1]+bbox[3]/2)
        if cx != 0 or cy != 0:
            candidate = [int(cx*original_width/WIDTH),int(cy*original_height/HEIGHT)]
    return {'peak':float(heatmap.max()),'mean':float(heatmap.mean()),'threshold':.5,'operator':'>',
        'bbox_512x288':list(bbox) if bbox else None,'candidate_xy_original':candidate,
        'visible':candidate is not None,'threshold_pixels':int(np.count_nonzero(mask)),
        'contour_count':len(contours)}


def distance(candidate,label):
    return None if candidate is None else math.hypot(candidate[0]-label['x'],candidate[1]-label['y'])


def agreement(pred,label):
    d = distance(pred['candidate_xy_original'],label)
    return {**pred,'distance_px':d,'within_px':{str(r):d is not None and d<=r for r in (5,10,20)},
            'within_uncertainty_radius':d is not None and d<=label['uncertainty_px']}


def group_metrics(points,model):
    n = len(points)
    values = [p[model]['distance_px'] for p in points if p[model]['distance_px'] is not None]
    counts = {str(r):sum(p[model]['within_px'][str(r)] for p in points) for r in (5,10,20)}
    return {'denominator_all_comparable_points':n,'output_count':len(values),'no_output_count':n-len(values),
        'output_coverage':len(values)/n if n else None,
        'conditional_distance_output_n':len(values),
        'conditional_distance_median_px':float(np.median(values)) if values else None,
        'conditional_distance_p90_px':float(np.percentile(values,90)) if values else None,
        'within_px_counts':counts,'within_px_fraction_of_all':{k:v/n if n else None for k,v in counts.items()},
        'uncertainty_radius_agreement_count':sum(p[model]['within_uncertainty_radius'] for p in points),
        'uncertainty_radius_agreement_fraction_of_all':sum(p[model]['within_uncertainty_radius'] for p in points)/n if n else None}


def paired_metrics(points):
    transitions = {}
    for radius in (5,10,20):
        k = str(radius)
        count = Counter((p['base']['within_px'][k],p['adapted']['within_px'][k]) for p in points)
        transitions[k] = {'denominator_all_comparable_points':len(points),'miss_to_hit':count[(False,True)],
            'hit_to_miss':count[(True,False)],'unchanged_hit':count[(True,True)],'unchanged_miss':count[(False,False)],
            'unchanged':count[(True,True)]+count[(False,False)]}
    both = [p for p in points if p['base']['distance_px'] is not None and p['adapted']['distance_px'] is not None]
    delta = [p['adapted']['distance_px']-p['base']['distance_px'] for p in both]
    return {'within_px_transitions':transitions,'both_output_distance_change_n':len(both),
        'both_output_distance_change_median_px':float(np.median(delta)) if delta else None,
        'distance_improved_count':sum(d<0 for d in delta),'distance_worsened_count':sum(d>0 for d in delta),
        'distance_unchanged_count':sum(d==0 for d in delta),
        'output_gained':sum(not p['base']['visible'] and p['adapted']['visible'] for p in points),
        'output_lost':sum(p['base']['visible'] and not p['adapted']['visible'] for p in points),
        'candidate_coordinate_changed_both_output':sum(p['base']['candidate_xy_original']!=p['adapted']['candidate_xy_original'] for p in both)}


def source_frame_key(sample,frame):
    return sample['source_sha256'],Fraction(frame['source_pts'])*Fraction(frame['source_time_base'])


def overlap_flags(sample,frame,training):
    key = (sample['sample_id'],frame['window_frame_index'])
    physical = source_frame_key(sample,frame)
    return {'trained_supervised_point':key in training['supervised'],
        'same_window_as_training':sample['sample_id'] in training['windows'],
        'same_source_as_training':sample['source_sha256'] in training['sources'],
        'same_rally_as_training':(sample['source_sha256'],sample['rally_group']) in training['rallies'],
        'same_declared_overlap_group_as_training':(sample['source_sha256'],sample['overlap_group']) in training['overlap_groups'],
        'training_input_source_frame_overlap':physical in training['input_frames'],
        'training_supervised_source_frame_overlap':physical in training['supervised_frames'],
        'training_background_source_frame_overlap':physical in training['background_frames'],
        'independent_holdout':False}


def freeze(args):
    out = Path(args.output).resolve()
    require(not out.exists(),'output directory exists; refusing overwrite')
    prepared,head,fit_report = Path(args.prepared).resolve(),Path(args.head).resolve(),Path(args.fit_report).resolve()
    receipt = read(prepared/'receipt.json')
    fit = read(fit_report)
    source = Path(receipt['source']['repo'])
    checkpoint = Path(receipt['source']['checkpoint'])
    before = head.parent/'head-before.pt'
    require(sha(checkpoint)==BASE_SHA and sha(head)==HEAD_SHA and sha(before)==BEFORE_SHA,'model file digest mismatch')
    require(fit['head_after_sha256']==HEAD_SHA and fit['head_before_sha256']==BEFORE_SHA,'fit artifact hashes disagree')
    require(fit['optimizer_steps']==8 and fit['production'] is False and fit['human_validated'] is False,'unexpected diagnostic head provenance')
    require(fit['prepared_receipt_sha256']==sha(prepared/'receipt.json'),'fit/prepared receipt mismatch')
    require(sha(prepared/'config.json')==receipt['config_sha256'] and sha(prepared/'labels.json')==receipt['labels_sha256'],'frozen input digest mismatch')
    require(subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()==PIN,'source pin changed')
    require(not subprocess.check_output(['git','-C',str(source),'status','--porcelain'],text=True).strip(),'official checkout modified')
    for name,key in [('model.py','model_py_sha256'),('dataset.py','dataset_py_sha256'),('utils/metric.py','metric_py_sha256')]:
        require(sha(source/name)==receipt['source'][key],'official implementation hash changed')
    samples = {s['sample_id']:s for s in receipt['samples']}
    manifests,files = {},{}
    for sid,sample in samples.items():
        manifest = Path(sample['frames_manifest'])
        require(sha(manifest)==receipt['source_files'][str(manifest)],'frames manifest changed')
        manifests[sid] = {f['window_frame_index']:f for f in read(manifest)['frames']}
        require(read(manifest)['review_id']==sid,'sample manifest identity mismatch')
        background = prepared/f'{sid}-background.npy'
        require(sha(background)==receipt['backgrounds'][background.name],'background changed')
        files[str(manifest)] = sha(manifest)
        files[str(background)] = sha(background)
    plan = [{'scope':'prepared_sequence','sample_id':s['sample_id'],'start':s['start']} for s in receipt['sequences']]
    require(len(plan)==60,'expected exactly 60 frozen prepared sequences')
    plan.sort(key=lambda s:(s['sample_id'],s['start']))
    for sid in FIXED_SAMPLES:
        require(sorted(manifests[sid])==list(range(120)),'full windows must be exactly 120 contiguous indexed frames')
        plan.extend({'scope':'full_window','sample_id':sid,'start':start} for start in range(0,120,8))
    for item in plan:
        sample,frames = samples[item['sample_id']],manifests[item['sample_id']]
        indices = range(item['start'],item['start']+LENGTH)
        require(all(i in frames for i in indices),'incomplete sequence; padding forbidden')
        require(not any(frames[i].get('gap_before',False) for i in list(indices)[1:]),'sequence crosses a PTS gap')
        for index in indices:
            frame = frames[index]
            image = Path(sample['frames_manifest']).parent/frame['filename']
            require(image.name==frame['filename'],'image filename must be basename')
            if str(image) not in files:
                require(sha(image)==frame['sha256'],'image changed')
                files[str(image)] = frame['sha256']
    labels = read(prepared/'labels.json')
    eligible = [l for l in labels if l['status']=='visible' and l['target_identity']=='confirmed']
    require(len(eligible)==45,'expected exactly 45 visible confirmed candidate labels')
    require(all(l['reviewer_kind']=='agent' and l.get('formal_eligible') is False for l in eligible),'expected explicit unvalidated agent labels')
    for label in eligible:
        frame = manifests[label['sample_id']][label['frame_index']]
        require(label['image_sha256']==frame['sha256'] and label['source_pts']==frame['source_pts'],'label identity changed')
        require(Fraction(label.get('timebase',label.get('source_time_base')))==Fraction(frame['source_time_base']),'label PTS timebase changed')
    supervised = {(f['sample_id'],f['frame_index']) for f in fit['actual_frames'] if f['supervised']}
    require(len(supervised)==8,'expected eight supervised training points')
    windows = {f['sample_id'] for f in fit['actual_frames']}
    training = {'supervised':supervised,'windows':windows,
        'sources':{samples[s]['source_sha256'] for s in windows},
        'rallies':{(samples[s]['source_sha256'],samples[s]['rally_group']) for s in windows},
        'overlap_groups':{(samples[s]['source_sha256'],samples[s]['overlap_group']) for s in windows},
        'input_frames':{source_frame_key(samples[f['sample_id']],manifests[f['sample_id']][f['frame_index']]) for f in fit['actual_frames']},
        'supervised_frames':{source_frame_key(samples[sid],manifests[sid][index]) for sid,index in supervised},
        'background_frames':{source_frame_key(samples[sid],manifests[sid][i]) for sid in windows for i in samples[sid]['frame_indices']}}
    out.mkdir(parents=True)
    write(out/'input-files.json',files)
    protocol = {'schema_version':1,'frozen_at':datetime.now(timezone.utc).isoformat(),
        'purpose':'exploratory agent-label comparison; not accuracy evaluation','production':False,'human_validated':False,
        'runner_sha256':sha(Path(__file__)),'input_files_sha256':sha(out/'input-files.json'),
        'prepared':str(prepared),'prepared_receipt_sha256':sha(prepared/'receipt.json'),
        'fit_report':str(fit_report),'fit_report_sha256':sha(fit_report),'base_checkpoint':str(checkpoint),'base_sha256':BASE_SHA,
        'adapted_head':str(head),'head_sha256':HEAD_SHA,'before_head':str(before),'before_head_sha256':BEFORE_SHA,
        'official_source':str(source),'official_commit':PIN,'frame_sequence_plan':plan,
        'threshold':.5,'threshold_operator':'>','coordinate_rule':'author maximum boundingRect area contour; integer center then integer rescale',
        'input_rule':'unmodified author dataset, RGB/PIL resize to512x288, median background first, divide255',
        'background_rule':'reuse exact prepared fixed same-window median of 48 selected frames for both scopes; includes future frames; offline only',
        'prepared_rule':'60 declared 8-frame sequences =480 model-input frame occurrences; 45 visible+confirmed points only; 8 trained /37 other points',
        'full_window_rule':'3x120 frames; disjoint sequence starts0,8,...112; independent reporting; output-channel context differs from prepared and prior16-frame smoke',
        'denominator_rule':'within5/10/20 and uncertainty counts use all comparable points; no output is a miss; distances median/P90 only over actual outputs with explicit n',
        'paired_transitions':'fixed5/10/20 miss_to_hit/hit_to_miss/unchanged; total group denominator',
        'negative_controls':['head-before safe reload, same representative batch, exact tensor equality','constant no-output reference has coverage/hits0 and conditional distance null'],
        'fixed_full_window_heatmap_frames':list(FIXED_HEATMAP_FRAMES),'device':'cpu','threads':4,'batch_size':1,
        'runtime':{'python':sys.version,'torch':torch.__version__,'numpy':np.__version__,'opencv':cv2.__version__,'platform':platform.platform()},
        'limitations':['agent candidates are not human truth','unknown/uncertain labels excluded, never negative examples',
            'untrained points share observed sources/window/rally/background context; no independent holdout',
            'no true negatives: no precision or false-positive rate','badminton pretrained model; no tennis accuracy claim',
            'no training, threshold tuning, interpolation, InpaintNet or overlap ensemble','CPU tool elapsed is not live camera performance']}
    write(out/'protocol.json',protocol)
    return out,receipt,fit,samples,manifests,eligible,training,protocol


def models(protocol):
    sys.path.insert(0,protocol['official_source'])
    from model import TrackNet
    parent = torch.load(protocol['base_checkpoint'],map_location='cpu',weights_only=True)
    require(parent['param_dict']['seq_len']==8 and parent['param_dict']['bg_mode']=='concat','architecture changed')
    head = torch.load(protocol['adapted_head'],map_location='cpu',weights_only=True)
    before = torch.load(protocol['before_head'],map_location='cpu',weights_only=True)
    require(head['parent_sha256']==BASE_SHA and head['production'] is False and head['human_validated'] is False,'invalid derived head flags')
    require(all(torch.equal(v,parent['model']['predictor.'+k]) for k,v in before['predictor'].items()),'head-before is not official head')
    loaded = []
    for replacement in (None,head['predictor'],before['predictor']):
        model = TrackNet(in_dim=27,out_dim=8)
        model.load_state_dict(parent['model'],strict=True)
        if replacement is not None:
            model.predictor.load_state_dict(replacement,strict=True)
        model.eval()
        model.requires_grad_(False)
        loaded.append(model)
    return loaded


def frame_summary(records):
    n = len(records)
    return {'frame_occurrences':n,'base_output_count':sum(r['base']['visible'] for r in records),
        'adapted_output_count':sum(r['adapted']['visible'] for r in records),
        'base_no_output_count':sum(not r['base']['visible'] for r in records),
        'adapted_no_output_count':sum(not r['adapted']['visible'] for r in records),
        'output_presence_changed':sum(r['base']['visible']!=r['adapted']['visible'] for r in records),
        'candidate_changed_including_presence':sum(r['base']['candidate_xy_original']!=r['adapted']['candidate_xy_original'] for r in records),
        'candidate_coordinate_changed_both_output':sum(r['base']['visible'] and r['adapted']['visible'] and r['base']['candidate_xy_original']!=r['adapted']['candidate_xy_original'] for r in records),
        'heatmap_max_abs_delta':max((r['heatmap_delta']['max_abs'] for r in records),default=None),
        'heatmap_mean_abs_delta':float(np.mean([r['heatmap_delta']['mean_abs'] for r in records])) if n else None,
        'peak_delta_mean_signed':float(np.mean([r['heatmap_delta']['peak_signed'] for r in records])) if n else None,
        'mean_delta_mean_signed':float(np.mean([r['heatmap_delta']['mean_signed'] for r in records])) if n else None}


def run(args):
    out,receipt,fit,samples,manifests,labels,training,protocol = freeze(args)
    # protocol.json exists before any model is instantiated or forward is called.
    protocol_sha = sha(out/'protocol.json')
    torch.set_num_threads(4)
    torch.manual_seed(20261029)
    torch.use_deterministic_algorithms(True)
    base,adapted,control = models(protocol)
    before_hashes = {name:model_sha(m) for name,m in [('base',base),('adapted',adapted),('head_before_control',control)]}
    from dataset import Shuttlecock_Trajectory_Dataset
    records,lookup,runtimes = [],{},[]
    control_result = None
    start_time = time.perf_counter()
    heatmaps = out/'heatmaps'
    heatmaps.mkdir()
    with open(out/'frames.jsonl','x') as stream:
        for ordinal,item in enumerate(protocol['frame_sequence_plan']):
            sid,start = item['sample_id'],item['start']
            sample,frames = samples[sid],manifests[sid]
            indices = list(range(start,start+8))
            folder = Path(sample['frames_manifest']).parent
            images = np.stack([np.asarray(Image.open(folder/frames[i]['filename']).convert('RGB')) for i in indices])
            background = np.load(Path(protocol['prepared'])/f'{sid}-background.npy',allow_pickle=False)
            dataset = Shuttlecock_Trajectory_Dataset(seq_len=8,sliding_step=8,data_mode='heatmap',bg_mode='concat',frame_arr=images,median=background,padding=False)
            _,inp = dataset[0]
            x = torch.from_numpy(inp).float().unsqueeze(0)
            started = time.perf_counter()
            with torch.inference_mode():
                b = base(x)
                a = adapted(x)
                if ordinal == 0:
                    c = control(x)
                    require(torch.equal(b,c),'head-before identity control failed')
                    control_result = {'scope':item['scope'],'sample_id':sid,'sequence_start':start,
                        'exact_heatmap_equality':True,'max_abs_delta':float((b-c).abs().max()),
                        'head_before_equals_official_tensors':True}
            elapsed = time.perf_counter()-started
            runtimes.append({**item,'pair_forward_seconds':elapsed})
            b,a = b.numpy()[0],a.numpy()[0]
            for offset,index in enumerate(indices):
                frame = frames[index]
                bp,ap = prediction(b[offset],frame['width'],frame['height']),prediction(a[offset],frame['width'],frame['height'])
                delta = a[offset]-b[offset]
                record = {'scope':item['scope'],'sample_id':sid,'sequence_start':start,'output_offset':offset,
                    'input_frame_indices':indices,'frame_index':index,'source_pts':frame['source_pts'],
                    'source_time_base':frame['source_time_base'],'source_pts_seconds_rational':frame['source_pts_seconds_rational'],
                    'image_sha256':frame['sha256'],'image_path':str(folder/frame['filename']),
                    'width':frame['width'],'height':frame['height'],'base':bp,'adapted':ap,
                    'heatmap_delta':{'max_abs':float(np.abs(delta).max()),'mean_abs':float(np.abs(delta).mean()),
                        'peak_signed':ap['peak']-bp['peak'],'mean_signed':ap['mean']-bp['mean']},
                    'training_overlap':overlap_flags(sample,frame,training)}
                stream.write(canonical(record)+'\n')
                records.append(record)
                key = (item['scope'],sid,index)
                require(key not in lookup,'ambiguous duplicated output for one scope/frame')
                lookup[key] = record
                if item['scope']=='full_window' and index in FIXED_HEATMAP_FRAMES:
                    np.savez_compressed(heatmaps/f'{sid}-frame-{index:05d}.npz',base=b[offset],adapted=a[offset])
            if ordinal%15==0:
                print(f'paired sequences {ordinal+1}/{len(protocol["frame_sequence_plan"])}',flush=True)
    pairs = []
    for label in sorted(labels,key=lambda l:(l['sample_id'],l['frame_index'])):
        record = lookup[('prepared_sequence',label['sample_id'],label['frame_index'])]
        pairs.append({**record,'label':label,'base':agreement(record['base'],label),'adapted':agreement(record['adapted'],label)})
    require(len(pairs)==45 and sum(p['training_overlap']['trained_supervised_point'] for p in pairs)==8,'8/37 point partition changed')
    write(out/'label-pairs.json',{'scope':'prepared_sequence','production':False,'human_validated':False,'points':pairs})
    groups = {'all_45':pairs,'trained_supervised_8':[p for p in pairs if p['training_overlap']['trained_supervised_point']],
        'untrained_points_37':[p for p in pairs if not p['training_overlap']['trained_supervised_point']]}
    summaries = {name:{'base':group_metrics(points,'base'),'adapted':group_metrics(points,'adapted'),'paired':paired_metrics(points)} for name,points in groups.items()}
    empty_ref = {}
    for name,points in groups.items():
        empty = [{**p,'base':agreement({'candidate_xy_original':None,'visible':False},p['label'])} for p in points]
        empty_ref[name] = group_metrics(empty,'base')
    after_hashes = {name:model_sha(m) for name,m in [('base',base),('adapted',adapted),('head_before_control',control)]}
    require(before_hashes==after_hashes,'model state changed during inference')
    for path,expected in [(protocol['base_checkpoint'],BASE_SHA),(protocol['adapted_head'],HEAD_SHA),(protocol['before_head'],BEFORE_SHA)]:
        require(sha(path)==expected,'checkpoint file changed during inference')
    summary = {'schema_version':1,'production':False,'human_validated':False,'accuracy':None,
        'scope':'exploratory agent-candidate agreement; no independent holdout','protocol_sha256':protocol_sha,
        'point_groups':summaries,'controls':{'head_before_identity':control_result,'constant_no_output_reference':empty_ref},
        'prepared_sequence_frames':frame_summary([r for r in records if r['scope']=='prepared_sequence']),
        'full_window_frames':frame_summary([r for r in records if r['scope']=='full_window']),
        'full_window_by_sample':{sid:frame_summary([r for r in records if r['scope']=='full_window' and r['sample_id']==sid]) for sid in FIXED_SAMPLES},
        'training_overlap_point_counts':{flag:sum(p['training_overlap'][flag] for p in pairs) for flag in pairs[0]['training_overlap']},
        'model_state_sha256_before':before_hashes,'model_state_sha256_after':after_hashes,
        'checkpoint_files_unchanged':True,'optimizer_steps':0,'pair_sequence_runs':runtimes,
        'elapsed_inference_and_record_seconds':time.perf_counter()-start_time,'limitations':protocol['limitations']}
    write(out/'summary.json',summary)
    write(out/'artifact-receipt.json',{'protocol_sha256':protocol_sha,'runner_sha256':sha(Path(__file__)),
        'frames_sha256':sha(out/'frames.jsonl'),'label_pairs_sha256':sha(out/'label-pairs.json'),'summary_sha256':sha(out/'summary.json'),
        'fixed_heatmap_files':{p.name:sha(p) for p in sorted(heatmaps.glob('*.npz'))}})
    print(canonical({'output':str(out),'point_counts':{k:len(v) for k,v in groups.items()},
        'prepared_frames':summary['prepared_sequence_frames'],'full_window_frames':summary['full_window_frames']}),flush=True)


class SelfTests(unittest.TestCase):
    def test_author_threshold_and_remap(self):
        heatmap = np.zeros((288,512),dtype=np.float32)
        heatmap[100,200] = .5
        self.assertIsNone(prediction(heatmap,1280,720)['candidate_xy_original'])
        heatmap[100,200] = .50001
        self.assertEqual(prediction(heatmap,1280,720)['candidate_xy_original'],[500,250])

    def test_distance_and_no_output_denominator(self):
        label = {'x':0,'y':0,'uncertainty_px':5}
        self.assertEqual(distance([3,4],label),5.)
        self.assertIsNone(distance(None,label))
        points = [{'base':agreement({'candidate_xy_original':c,'visible':c is not None},label)} for c in ([3,4],None)]
        result = group_metrics(points,'base')
        self.assertEqual(result['denominator_all_comparable_points'],2)
        self.assertEqual(result['within_px_fraction_of_all']['5'],.5)
        self.assertEqual(result['conditional_distance_output_n'],1)
        self.assertEqual(result['conditional_distance_median_px'],5.)

    def test_paired_transition_counts(self):
        label = {'x':0,'y':0,'uncertainty_px':5}
        pair = lambda b,a:{'base':agreement({'candidate_xy_original':b,'visible':b is not None},label),'adapted':agreement({'candidate_xy_original':a,'visible':a is not None},label)}
        result = paired_metrics([pair(None,[1,1]),pair([1,1],None),pair([1,1],[1,1]),pair(None,None)])
        self.assertEqual(result['within_px_transitions']['5'],{'denominator_all_comparable_points':4,'miss_to_hit':1,'hit_to_miss':1,'unchanged_hit':1,'unchanged_miss':1,'unchanged':2})

    def test_group_context_is_not_training_point_or_holdout(self):
        sample = {'sample_id':'other-window','source_sha256':'a','rally_group':'r','overlap_group':'o'}
        frame = {'window_frame_index':10,'source_pts':60,'source_time_base':'1/60'}
        training = {'supervised':{('original-window',10)},'windows':{'original-window'},'sources':{'a'},'rallies':{('a','r')},'overlap_groups':{('a','o')},'input_frames':{('a',Fraction(1))},'supervised_frames':set(),'background_frames':{('a',Fraction(1))}}
        flags = overlap_flags(sample,frame,training)
        self.assertFalse(flags['trained_supervised_point'])
        self.assertTrue(flags['same_rally_as_training'])
        self.assertTrue(flags['training_input_source_frame_overlap'])
        self.assertFalse(flags['independent_holdout'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--self-test',action='store_true')
    p.add_argument('--prepared',default=str(PREP/'prepared-v2'))
    p.add_argument('--head',default=str(PREP/'fit-v2-8steps/diagnostic-head.pt'))
    p.add_argument('--fit-report',default=str(PREP/'fit-v2-8steps/report.json'))
    p.add_argument('--output',default=str(ROOT/'.local/speed-training/ball-compare-20261029'))
    p.add_argument('--exploratory-agent-label-comparison',action='store_true',help='required acknowledgment of unvalidated candidate labels and shared context')
    args = p.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests))
        return 0 if result.wasSuccessful() else 1
    require(args.exploratory_agent_label_comparison,'requires explicit --exploratory-agent-label-comparison')
    run(args)
    return 0


if __name__=='__main__':
    try:
        sys.exit(main())
    except (ValueError,KeyError,FileNotFoundError) as error:
        print(f'ball-track-compare: {error}',file=sys.stderr)
        sys.exit(2)
