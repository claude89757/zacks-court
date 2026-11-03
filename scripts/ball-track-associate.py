#!/usr/bin/env python3
"""Pre-registered multi-component and pixel-motion association development experiment.

No training, physical speed, interpolation, semantic object classifier, or holdout.
`causal` describes association only: detector inputs and background include future
frames. Oracle candidate agreement is a recoverability upper bound, not a tracker.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
import time
import unittest

sys.dont_write_bytecode=True
import cv2
import numpy as np
import torch

ROOT=Path(__file__).resolve().parents[1]
TUNE=Path(__file__).with_name('ball-track-tune.py')
OLD=ROOT/'.local/speed-training/ball-tune-20261029'
PREP=OLD/'model/prepared-v1'
OLD_RUN=OLD/'model/run-v1'
DEST=ROOT/'.local/speed-training/ball-association-20261029'
FIXED=(0,10,64,72,80,88,95,110)
SELECTORS=('author_largest_area','peak_only','causal_cv','offline_beam_cv')
PARAMS={'top_k':20,'thresholds':[.1,.3,.5],'beam_width':32,'missing_cost':2.5,
    'position_sigma_base':8.,'position_sigma_per_second':800.,'max_displacement_base':8.,
    'max_displacement_per_second':3000.,'max_prediction_residual_sigma':3.,'max_last_seen_age_seconds':.20,
    'source_gap_nominal_period_factor':1.5,'near_stationary_radius_equivalent_px':3.,'near_stationary_min_seconds':.25}


def require(value,message):
    if not value: raise ValueError(message)


def read(path): return json.loads(Path(path).read_text())


def write(path,value):
    with open(path,'x') as f:
        json.dump(value,f,indent=2,sort_keys=True,allow_nan=False);f.write('\n')


def canonical(value): return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)


def sha(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()


def tune():
    spec=importlib.util.spec_from_file_location('court_association_tune_helpers',TUNE)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def proposal():
    h=tune();prepared,receipt,old_config=h.audit(PREP)
    prior=read(OLD_RUN/'completion.json')
    require(sha(OLD_RUN/'predictions.jsonl')==prior['predictions_sha256'],'prior prediction artifact changed')
    return {'schema_version':1,'purpose':'development-only multi-candidate recoverability and association',
        'production':False,'human_validated':False,'optimizer_steps':0,'seed':20261029,'device':'cpu','threads':4,
        'prepared_input':str(prepared),'prepared_receipt_sha256':sha(prepared/'receipt.json'),
        'helper_sha256':sha(TUNE),'base_source':receipt['source'],'labels':receipt['packages'],
        'prior_prediction_control':{'path':str(OLD_RUN/'predictions.jsonl'),'sha256':prior['predictions_sha256'],
            'rule':'.5/full and .5/roi author coordinates must exactly equal prior original_full/original_roi for all960 outputs'},
        'views':old_config['views'],'parameters':PARAMS,'window_ids':sorted(receipt['windows']),
        'prediction_starts':list(range(0,120,8)),'fixed_display_indices':list(FIXED),
        'candidate_rule':'all8-connected foreground components, strict heatmap>threshold, no size filtering; bbox integer center maps to native; top20 peak descending, bbox-area descending, component-id ascending',
        'author_rule':'original external-contour maximum boundingRect area from ALL components, integer center/remap and original zero sentinel; separately evaluated at each threshold',
        'candidate_metadata':'component peak/mean, binary-pixel area, bounding-box area, bbox-center/peak/centroid coordinates, PTS; total/truncated count retained',
        'association_rule':'candidate cost=-log(peak)+0.5*(CV prediction residual/(8+800*last_seen_dt))^2; hard displacement<=8+3000*dt and residual<=3sigma; missing cost2.5; last_seen_age>.20 resets history',
        'causal_cv':'greedy minimum incremental cost using prior selected points only; no label seed',
        'offline_beam_cv':'width32 approximate beam over candidate/missing paths with same cost; future frame choices may change earlier selected path; not exact DP',
        'gap_rule':'actual adjacent PTS dt>1.5 nominal source periods, nonpositive dt, or explicit gap flag clears motion history; never cross windows; skip8-frame model input if it straddles gap',
        'coordinate_rule':'all association gates use1280x720-equivalent screen coordinates and actual PTS seconds; no physical ball speed',
        'missing_rule':'missing output isNone; no interpolation; record reinitialization and segment changes',
        'static_rule':'no forced static-object penalty; report selected runs staying within radius3equivalent pixels for>=.25s only as near-static heuristic',
        'label_use':'after all candidate extraction and all selections; only visible+confirmed contributes agreement; unknown/uncertain never negative; all prior train/eval sources now development',
        'metrics':'all visible denominators include misses/ROI-excluded; native+equivalent5/10/20; conditional distances n; oracle topK upper bound separate from selected algorithms; rescue/regression counts; jumps/near-static runs',
        'limits':['all480 original frames and192 agent labels are development data','not independent or human/physical truth',
            '8-frame temporal model has intra-sequence future context; uniform48 native median uses future frames',
            'causality applies only to causal_cv association, not the full detector pipeline',
            'weak ball may be merged into another component or fall below topK/threshold; oracle is only an upper bound',
            'smooth stationary spare balls, people or rackets can win; no semantic identity is inferred',
            'CV gates can reject real impacts/bounces or miss fast motion; a reset does not establish identity continuity',
            'no source001 access, training, InpaintNet, interpolation, physical speed or3D claim']}


def prepare(args):
    config=read(args.protocol)
    require(config['parameters']==PARAMS and config['views']=={'full':{'kind':'full'},'roi':{'kind':'normalized_roi','rect_normalized_xyxy':[.1,.1,.9,.9]}},'protocol parameters/views differ from registered recipe')
    require(config==proposal(),'protocol input/hash/specification drift')
    out=Path(args.output).resolve();require(not out.exists(),'prepare output exists');out.mkdir(parents=True)
    h=tune();_,receipt,_=h.audit(config['prepared_input'])
    metadata_paths={k for k in receipt['files'] if k.endswith('manifest.json')}
    source_rates={}
    for path in metadata_paths:
        document=read(path)
        for source in document.get('sources',[]): source_rates[source['source_sha256']]=source['nominal_frame_rate']
    require(all(w['source_sha256'] in source_rates for w in receipt['windows'].values()),'missing nominal source cadence')
    write(out/'protocol.json',config)
    write(out/'receipt.json',{'runner_sha256':sha(Path(__file__)),'protocol_sha256':sha(out/'protocol.json'),
        'original_protocol_sha256':sha(args.protocol),'source_nominal_frame_rates':source_rates,'runtime':h.runtime(),
        'created_at':datetime.now(timezone.utc).isoformat(),'labels_decoded':False})
    print(canonical({'prepared':str(out),'protocol_sha256':sha(out/'protocol.json')}))


def native_xy(cx,cy,rect):
    return [int(rect[0]+cx*(rect[2]-rect[0])/512),int(rect[1]+cy*(rect[3]-rect[1])/288)]


def equiv_xy(xy,width,height): return [xy[0]*1280/width,xy[1]*720/height]


def components(heatmap,threshold,rect,width,height,top_k):
    mask=(heatmap>threshold).astype(np.uint8)
    count,labels,stats,centroids=cv2.connectedComponentsWithStats(mask,connectivity=8)
    candidates=[]
    for component_id in range(1,count):
        x,y,w,h,area=map(int,stats[component_id]);region=labels[y:y+h,x:x+w]==component_id
        values=heatmap[y:y+h,x:x+w]
        peak_index=np.argmax(np.where(region,values,-np.inf));py,px=np.unravel_index(peak_index,values.shape)
        cx,cy=int(x+w/2),int(y+h/2);xy=native_xy(cx,cy,rect)
        candidates.append({'candidate_id':component_id,'score_peak':float(values[region].max()),'score_mean':float(values[region].mean()),
            'component_area_px':area,'bbox_area_px':w*h,'bbox_512x288':[x,y,w,h],
            'xy_original':xy,'xy_equivalent':equiv_xy(xy,width,height),
            'peak_xy_original':native_xy(x+int(px),y+int(py),rect),
            'centroid_xy_original':native_xy(float(centroids[component_id,0]),float(centroids[component_id,1]),rect)})
    candidates.sort(key=lambda c:(-c['score_peak'],-c['bbox_area_px'],c['candidate_id']))
    for rank,c in enumerate(candidates,1):c['rank_by_peak']=rank
    contours,_=cv2.findContours(mask.copy()*255,cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE)
    boxes=[cv2.boundingRect(c) for c in contours]
    box=max(boxes,key=lambda b:b[2]*b[3]) if boxes else None
    author=None
    if box:
        cx,cy=int(box[0]+box[2]/2),int(box[1]+box[3]/2)
        if cx or cy: author=native_xy(cx,cy,rect)
    match=next((c for c in candidates if box and c['bbox_512x288']==list(box)),None)
    return {'candidates':candidates[:top_k],'component_count':count-1,'truncated_component_count':max(0,count-1-top_k),
        'author':{'xy_original':author,'bbox_512x288':list(box) if box else None,
            'candidate_id':match['candidate_id'] if match else None,'in_topK':match is not None and match['rank_by_peak']<=top_k}}


def empty_state():return {'cost':0.,'history':(),'path':()}


def transition(state,candidate,row,params):
    t=row['time_seconds'];history=state['history'];reset=None
    if row['gap_before']:history=();reset='source_gap'
    if history and t-history[-1]['time']>params['max_last_seen_age_seconds']:
        history=();reset='last_seen_timeout'
    if candidate is None:
        return {'cost':state['cost']+params['missing_cost'],'history':history,'path':state['path']+(None,)}, {'reset':reset,'incremental_cost':params['missing_cost'],'prediction_residual':None,'linked':False}
    xy=candidate['xy_equivalent'];residual=0.;linked=bool(history)
    if history:
        last=history[-1];dt=t-last['time'];require(dt>0,'nonpositive association dt')
        displacement=math.dist(xy,last['xy'])
        if displacement>params['max_displacement_base']+params['max_displacement_per_second']*dt:return None,None
        rate=[0.,0.]
        if len(history)==2:
            earlier=history[0];old_dt=last['time']-earlier['time']
            rate=[(last['xy'][i]-earlier['xy'][i])/old_dt for i in (0,1)]
        predicted=[last['xy'][i]+rate[i]*dt for i in (0,1)]
        residual=math.dist(xy,predicted);sigma=params['position_sigma_base']+params['position_sigma_per_second']*dt
        if residual>params['max_prediction_residual_sigma']*sigma:return None,None
        motion_cost=.5*(residual/sigma)**2
    else:motion_cost=0.;reset=reset or 'initial_or_reinitialization'
    cost=-math.log(max(candidate['score_peak'],1e-6))+motion_cost
    point={'time':t,'xy':xy,'frame_index':row['frame_index'],'candidate_id':candidate['candidate_id']}
    next_state={'cost':state['cost']+cost,'history':(history+(point,))[-2:],'path':state['path']+(candidate['candidate_id'],)}
    return next_state,{'reset':reset,'incremental_cost':cost,'prediction_residual':residual if linked else None,'linked':linked}


def path_order(state):return state['cost'],tuple(1000000 if i is None else i for i in state['path'])


def associate(rows,params,offline):
    states=[empty_state()]
    for row in rows:
        options=[]
        for state in states:
            for candidate in row['candidates']+[None]:
                updated,_=transition(state,candidate,row,params)
                if updated is not None:options.append(updated)
        options.sort(key=path_order)
        # Histories with the same last two observations have identical future cost;
        # retain their lowest-cost prefix before applying the approximate beam cap.
        unique={}
        for state in options:
            key=tuple((p['frame_index'],p['candidate_id']) for p in state['history'])
            if key not in unique:unique[key]=state
        states=list(unique.values())[:params['beam_width'] if offline else 1]
    path=states[0]['path'];state=empty_state();result=[];segment=0
    for row,candidate_id in zip(rows,path):
        candidate=next((c for c in row['candidates'] if c['candidate_id']==candidate_id),None)
        state,event=transition(state,candidate,row,params)
        require(state is not None,'selected path replay failed')
        if candidate is not None and not event['linked']:segment+=1
        result.append({'candidate_id':candidate_id,'xy_original':candidate['xy_original'] if candidate else None,
            'score_peak':candidate['score_peak'] if candidate else None,'segment_id':segment if candidate else None,
            'status':'selected' if candidate else 'missing','event':event})
    return result


def point_metrics(xy,label,rect,width,height):
    h=tune();return h.point_result(xy,label,rect,width,height)


def motion_summary(rows,selector,params):
    jumps=0;adjacent=0;near_static=[];run=[]
    def finish():
        if len(run)>1 and run[-1][0]-run[0][0]>=params['near_stationary_min_seconds']:
            near_static.append({'start_frame':run[0][2],'end_frame':run[-1][2],'duration_seconds':run[-1][0]-run[0][0]})
    previous=None
    for row in rows:
        xy=row['selections'][selector]['xy_original'];t=row['time_seconds']
        point=equiv_xy(xy,row['width'],row['height']) if xy is not None else None
        if row['gap_before'] or point is None:
            finish();run=[];previous=None
        if point is not None:
            if previous is not None:
                dt=t-previous[0];adjacent+=1
                if math.dist(point,previous[1])>params['max_displacement_base']+params['max_displacement_per_second']*dt:jumps+=1
            if run and math.dist(point,run[0][1])>params['near_stationary_radius_equivalent_px']:
                finish();run=[]
            run.append((t,point,row['frame_index']));previous=(t,point)
    finish()
    return {'adjacent_both_output_pairs':adjacent,'large_screen_jump_count':jumps,'near_static_runs':near_static,
            'near_static_is_not_object_identity':True}


def summarize_points(points):
    summary={}
    for selector in SELECTORS:
        subset=[p[selector] for p in points]
        metric=tune().eval_summary(subset)
        metric['rescued_author_misses_equivalent10']=sum(not p['author_largest_area']['within_equivalent_px']['10'] and p[selector]['within_equivalent_px']['10'] for p in points)
        metric['lost_author_hits_equivalent10']=sum(p['author_largest_area']['within_equivalent_px']['10'] and not p[selector]['within_equivalent_px']['10'] for p in points)
        summary[selector]=metric
    oracle={str(radius):sum(p['oracle_topK']['within_equivalent_px'][str(radius)] for p in points) for radius in (5,10,20)}
    return {'visible_denominator':len(points),'selected_algorithms':summary,
        'oracle_candidate_upper_bound_only':{'within_equivalent_counts':oracle,'denominator':len(points),
            'potential_rescue_of_author_miss_equivalent10':sum(not p['author_largest_area']['within_equivalent_px']['10'] and p['oracle_topK']['within_equivalent_px']['10'] for p in points),
            'not_algorithm_performance':True}}


def run(args):
    prepared=Path(args.prepared).resolve();config=read(prepared/'protocol.json');receipt=read(prepared/'receipt.json')
    require(args.execute_frozen_protocol,'explicit --execute-frozen-protocol required')
    require(receipt['runner_sha256']==sha(Path(__file__)) and receipt['protocol_sha256']==sha(prepared/'protocol.json'),'frozen runner/protocol changed')
    require(config==proposal(),'frozen inputs/helper/reference changed')
    h=tune();old_prepared,old_receipt,old_config=h.audit(config['prepared_input'])
    require(receipt['runtime']==h.runtime(),'runtime changed')
    out=Path(args.output).resolve();require(not out.exists(),'run output exists');out.mkdir(parents=True)
    write(out/'protocol.json',config)
    torch.set_num_threads(4);torch.use_deterministic_algorithms(True);torch.manual_seed(config['seed'])
    model=h.factory('base');model_before=h.state_sha(model)
    prior={}
    for line in Path(config['prior_prediction_control']['path']).read_text().splitlines():
        row=json.loads(line)
        if row['model_group'] in {'original_full','original_roi'}:prior[(row['model_group'],row['sample_id'],row['frame_index'])]=row['candidate_xy_original']
    rows_all=[];control_count=0;skipped_sequences=0;started=time.perf_counter()
    for view_name,view in config['views'].items():
        for sid in config['window_ids']:
            window=old_receipt['windows'][sid];frames=window['frames']
            nominal_period=1/float(Fraction(receipt['source_nominal_frame_rates'][window['source_sha256']]))
            times={i:float(Fraction(f['source_pts'])*Fraction(f['source_time_base'])) for i,f in frames.items()}
            gaps={i:i>0 and (frames[i].get('gap_before',False) or times[i]<=times[i-1] or times[i]-times[i-1]>PARAMS['source_gap_nominal_period_factor']*nominal_period) for i in range(120)}
            by_threshold={threshold:[] for threshold in PARAMS['thresholds']}
            for start in config['prediction_starts']:
                x,_,_,_,rect=h.batch(old_prepared,window,start,view,{})
                crossing=any(gaps[i] for i in range(start+1,start+8))
                if crossing:maps=np.zeros((8,288,512),np.float32);skipped_sequences+=1
                else:
                    with torch.inference_mode():maps=model(x).numpy()[0]
                for offset,index in enumerate(range(start,start+8)):
                    frame=frames[index]
                    for threshold in PARAMS['thresholds']:
                        extracted=components(maps[offset],threshold,rect,window['width'],window['height'],PARAMS['top_k'])
                        row={'recipe':view_name+'-threshold-'+str(threshold),'view':view_name,'threshold':threshold,'threshold_operator':'>',
                            'sample_id':sid,'window_id':sid,'former_split_development_only':window['split'],'frame_index':index,
                            'sequence_start':start,'output_offset':offset,'input_frame_indices':list(range(start,start+8)),
                            'source_pts':frame['source_pts'],'source_time_base':frame['source_time_base'],
                            'time_seconds':times[index],'gap_before':bool(gaps[index]),'nominal_period_seconds':nominal_period,
                            'image_path':frame['image_path'],'image_sha256':frame['sha256'],'width':window['width'],'height':window['height'],
                            'crop_xyxy':rect,'heatmap_peak':float(maps[offset].max()),'input_sequence_crossed_gap':crossing,**extracted}
                        for candidate in row['candidates']:
                            candidate['source_pts']=frame['source_pts'];candidate['source_time_base']=frame['source_time_base']
                        if threshold==.5:
                            expected=prior[('original_'+view_name,sid,index)]
                            if row['author']['xy_original']!=expected:
                                write(out/'failure.json',{'reason':'prior baseline coordinate mismatch','row':row,'prior_xy':expected})
                                raise ValueError('same-input .5 author baseline control mismatch')
                            control_count+=1
                        by_threshold[threshold].append(row)
            for threshold,rows in by_threshold.items():
                causal=associate(rows,PARAMS,False);offline=associate(rows,PARAMS,True)
                for row,c,o in zip(rows,causal,offline):
                    peak=row['candidates'][0] if row['candidates'] else None
                    row['selections']={'author_largest_area':{'xy_original':row['author']['xy_original'],'candidate_id':row['author']['candidate_id']},
                        'peak_only':{'xy_original':peak['xy_original'] if peak else None,'candidate_id':peak['candidate_id'] if peak else None},
                        'causal_cv':c,'offline_beam_cv':o}
                rows_all.extend(rows)
            print(f'completed candidates/association {view_name}/{sid}',flush=True)
    # Freeze every chosen path before decoding any label records for metrics.
    with open(out/'frames.jsonl','x') as stream:
        for row in rows_all:stream.write(canonical(row)+'\n')
    labels={}
    for package in old_receipt['packages'].values():
        subset={sid:old_receipt['windows'][sid] for sid in package['window_ids']}
        labels.update(h.load_label_map(package['labels'],subset,True))
    require(len(labels)==192,'expected192 frozen development labels')
    points=[]
    for row in rows_all:
        label=labels.get((row['sample_id'],row['frame_index']))
        if not label or label['status']!='visible' or label['target_identity']!='confirmed':continue
        point={'recipe':row['recipe'],'sample_id':row['sample_id'],'frame_index':row['frame_index'],
            'former_split_development_only':row['former_split_development_only'],'label':label}
        for selector in SELECTORS:point[selector]=h.point_result(row['selections'][selector]['xy_original'],label,row['crop_xyxy'],row['width'],row['height'])
        closest=min(row['candidates'],key=lambda c:math.hypot((c['xy_original'][0]-label['x'])*1280/row['width'],(c['xy_original'][1]-label['y'])*720/row['height'])) if row['candidates'] else None
        point['oracle_topK']={**h.point_result(closest['xy_original'] if closest else None,label,row['crop_xyxy'],row['width'],row['height']),
            'candidate_id':closest['candidate_id'] if closest else None,'rank_by_peak':closest['rank_by_peak'] if closest else None,'upper_bound_only':True}
        points.append(point)
    require(len(points)==166*6,'expected166 visible confirmed points per recipe')
    write(out/'point-comparisons.json',{'production':False,'human_validated':False,'all_development':True,'points':points})
    summary={}
    for recipe in sorted({r['recipe'] for r in rows_all}):
        selected=[p for p in points if p['recipe']==recipe]
        recipe_rows=[r for r in rows_all if r['recipe']==recipe]
        summary[recipe]={'all_development':summarize_points(selected),
            'former_train_development':summarize_points([p for p in selected if p['former_split_development_only']=='train']),
            'former_eval_development':summarize_points([p for p in selected if p['former_split_development_only']=='eval']),
            'candidate_frame_counts':{'frame_count':len(recipe_rows),'no_candidates':sum(not r['candidates'] for r in recipe_rows),
                'topK_truncated_frames':sum(r['truncated_component_count']>0 for r in recipe_rows)},
            'motion_diagnostics':{sid:{selector:motion_summary([r for r in recipe_rows if r['sample_id']==sid],selector,PARAMS) for selector in SELECTORS} for sid in config['window_ids']}}
    require(control_count==960 and h.state_sha(model)==model_before,'baseline count/model state check failed')
    h.audit(config['prepared_input']) # verifies all opaque label/image/background/source hashes again.
    write(out/'summary.json',{'production':False,'human_validated':False,'all_development':True,'optimizer_steps':0,
        'recipes':summary,'protocol_sha256':sha(prepared/'protocol.json'),'same_input_prior_baseline_control':{'checked_frames':control_count,'exact_coordinate_agreement':True},
        'skipped_gap_crossing_sequences':skipped_sequences,'model_state_sha256_before':model_before,'model_state_sha256_after':h.state_sha(model),
        'all_frozen_inputs_unchanged':True,'elapsed_seconds':time.perf_counter()-started,'limits':config['limits']})
    write(out/'fixed-display-index.json',{'indices':list(FIXED),'windows':{sid:[{'frame_index':i,'image_path':old_receipt['windows'][sid]['frames'][i]['image_path']} for i in FIXED] for sid in config['window_ids']}})
    write(out/'completion.json',{'status':'complete','runner_sha256':sha(Path(__file__)),'protocol_sha256':sha(prepared/'protocol.json'),
        'frames_sha256':sha(out/'frames.jsonl'),'points_sha256':sha(out/'point-comparisons.json'),'summary_sha256':sha(out/'summary.json')})
    print(canonical({'output':str(out),'frame_recipe_records':len(rows_all),'point_comparisons':len(points),'same_input_baseline_controls':control_count}))


class SelfTests(unittest.TestCase):
    def test_components_threshold_and_author(self):
        heatmap=np.zeros((288,512),np.float32);heatmap[50:52,60:63]=.6;heatmap[90,100]=.9
        out=components(heatmap,.5,(0,0,1280,720),1280,720,20)
        self.assertEqual(out['candidates'][0]['score_peak'],float(np.float32(.9)))
        self.assertEqual(out['author']['xy_original'],[152,127])
        self.assertEqual(out['component_count'],2)
        heatmap[:]=.5;self.assertEqual(components(heatmap,.5,(0,0,1280,720),1280,720,20)['component_count'],0)

    def test_missing_and_gap_no_interpolation(self):
        make=lambda i,t,c,g=False:{'frame_index':i,'time_seconds':t,'gap_before':g,'candidates':c}
        cand=lambda i,x:{'candidate_id':i,'score_peak':.9,'xy_equivalent':[x,100.],'xy_original':[x,100.]}
        rows=[make(0,0,[cand(1,100)]),make(1,1/60,[]),make(2,2/60,[cand(2,110)]),make(3,.5,[cand(3,1100)],True)]
        for offline in (False,True):
            selected=associate(rows,PARAMS,offline)
            self.assertIsNone(selected[1]['xy_original']);self.assertIsNone(selected[1]['candidate_id'])
            self.assertFalse(selected[3]['event']['linked']);self.assertEqual(selected[3]['event']['reset'],'source_gap')

    def test_dt_changes_motion_gate(self):
        state={'cost':0.,'history':({'time':0.,'xy':[0.,0.],'frame_index':0,'candidate_id':1},),'path':(1,)}
        candidate={'candidate_id':2,'score_peak':.9,'xy_equivalent':[50.,0.],'xy_original':[50,0]}
        self.assertIsNone(transition(state,candidate,{'time_seconds':.001,'gap_before':False,'frame_index':1},PARAMS)[0])
        self.assertIsNotNone(transition(state,candidate,{'time_seconds':.03,'gap_before':False,'frame_index':1},PARAMS)[0])

    def test_oracle_separate_and_missing_denominator(self):
        h=tune();label={'x':100,'y':100,'uncertainty_px':5}
        make=lambda xy:h.point_result(xy,label,(0,0,1280,720),1280,720)
        p={selector:make(None) for selector in SELECTORS};p['oracle_topK']=make([100,100])
        result=summarize_points([p])
        self.assertEqual(result['selected_algorithms']['causal_cv']['equivalent']['within_counts']['10'],0)
        self.assertEqual(result['oracle_candidate_upper_bound_only']['potential_rescue_of_author_miss_equivalent10'],1)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--self-test',action='store_true')
    subs=parser.add_subparsers(dest='command')
    prop=subs.add_parser('propose');prop.add_argument('--output',required=True)
    prep=subs.add_parser('prepare');prep.add_argument('--protocol',required=True);prep.add_argument('--output',required=True)
    run_parser=subs.add_parser('run');run_parser.add_argument('--prepared',required=True);run_parser.add_argument('--output',required=True);run_parser.add_argument('--execute-frozen-protocol',action='store_true')
    args=parser.parse_args()
    if args.self_test:
        result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests));return 0 if result.wasSuccessful() else 1
    require(args.command,'choose propose/prepare/run or --self-test')
    if args.command=='propose':
        path=Path(args.output).resolve();path.parent.mkdir(parents=True,exist_ok=True);write(path,proposal());print(sha(path))
    elif args.command=='prepare':prepare(args)
    else:run(args)
    return 0


if __name__=='__main__':
    try:sys.exit(main())
    except (ValueError,KeyError,FileNotFoundError) as error:
        print('ball-track-associate: '+str(error),file=sys.stderr);sys.exit(2)
