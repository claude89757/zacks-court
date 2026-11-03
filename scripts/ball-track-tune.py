#!/usr/bin/env python3
"""Bounded, frozen-protocol TrackNet exploration; no automatic model selection.

prepare --protocol JSON --output NEW_DIR [--diagnostic-agent-labels]
benchmark --output NEW_DIR                 # synthetic batch, backward, no update
run --prepared DIR --output NEW_DIR --execute-frozen-protocol

Each fit starts from the official base. Evaluation labels are decoded only after
every planned variant has finished fitting. All artifacts remain production=false.
"""
import argparse
from collections import OrderedDict
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import importlib.util
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
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parents[1]
OFFICIAL = ROOT/'.local/speed-training/tracknet-smoke-20261028'
PIN = '6eda442ada1740573f200f836d93edc9a541ee86'
BASE_SHA = 'df867641a02712b021f04548ff4b1208ddfdb47f629ab2094ceb978667e83b1a'
W,H,L = 512,288,8
HELPER = Path(__file__).with_name('ball-track-diagnostic.py')


def require(value,message):
    if not value:
        raise ValueError(message)


def sha(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):
            h.update(block)
    return h.hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def write(path,value):
    with open(path,'x') as f:
        json.dump(value,f,indent=2,sort_keys=True,allow_nan=False)
        f.write('\n')


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)


def helper():
    spec=importlib.util.spec_from_file_location('court_ball_diagnostic_helpers',HELPER)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolved(path,base):
    value=Path(path).expanduser()
    return (base/value).resolve() if not value.is_absolute() else value.resolve()


def runtime():
    return {'python':sys.version,'executable':sys.executable,'torch':str(torch.__version__),
        'numpy':np.__version__,'opencv':cv2.__version__,'platform':platform.platform(),
        'pip_freeze':subprocess.check_output([sys.executable,'-m','pip','freeze'],text=True).splitlines()}


def source_check():
    source=OFFICIAL/'TrackNetV3'
    checkpoint=OFFICIAL/'checkpoints/ckpts/TrackNet_best.pt'
    require(sha(checkpoint)==BASE_SHA,'official base checkpoint digest mismatch')
    require(subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()==PIN,'source commit changed')
    require(not subprocess.check_output(['git','-C',str(source),'status','--porcelain'],text=True).strip(),'source checkout modified')
    return {'repo':str(source),'commit':PIN,'checkpoint':str(checkpoint),'checkpoint_sha256':BASE_SHA,
            'model_py_sha256':sha(source/'model.py'),'license_sha256':sha(source/'LICENSE')}


def factory(mode):
    provenance=source_check()
    sys.path.insert(0,provenance['repo'])
    from model import TrackNet
    ckpt=torch.load(provenance['checkpoint'],map_location='cpu',weights_only=True)
    require(ckpt['param_dict']['seq_len']==8 and ckpt['param_dict']['bg_mode']=='concat','unexpected official architecture')
    model=TrackNet(in_dim=27,out_dim=8)
    model.load_state_dict(ckpt['model'],strict=True)
    prefixes=('predictor.',) if mode=='head_only' else ('up_block_3.','predictor.')
    require(mode in {'head_only','decoder_head','base'},'unknown trainable mode')
    for name,p in model.named_parameters():
        p.requires_grad_(mode!='base' and name.startswith(prefixes))
    model.eval()  # BN statistics remain frozen; decoder BN affine is trainable.
    return model


def frozen_features(model,x,mode):
    """Exact original forward prefix. Cache only detached float32 activations."""
    with torch.no_grad():
        x1=model.down_block_1(x)
        x2=model.down_block_2(F.max_pool2d(x1,2))
        x3=model.down_block_3(F.max_pool2d(x2,2))
        z=model.bottleneck(F.max_pool2d(x3,2))
        z=model.up_block_1(torch.cat([F.interpolate(z,scale_factor=2,mode='nearest'),x3],dim=1))
        z=model.up_block_2(torch.cat([F.interpolate(z,scale_factor=2,mode='nearest'),x2],dim=1))
        z=torch.cat([F.interpolate(z,scale_factor=2,mode='nearest'),x1],dim=1)
        if mode=='head_only':
            z=model.up_block_3(z)
    return z.detach()


def suffix(model,features,mode):
    z=model.up_block_3(features) if mode=='decoder_head' else features
    return model.sigmoid(model.predictor(z))


class FeatureCache:
    def __init__(self,mib):
        self.limit=int(mib)*1024*1024
        self.items=OrderedDict()
        self.bytes=0
        self.hits=self.misses=0

    def get(self,key,build):
        if key in self.items:
            self.hits+=1
            self.items.move_to_end(key)
            return self.items[key]
        self.misses+=1
        value=build()
        size=value.numel()*value.element_size()
        if size<=self.limit:
            while self.items and self.bytes+size>self.limit:
                _,old=self.items.popitem(last=False)
                self.bytes-=old.numel()*old.element_size()
            self.items[key]=value
            self.bytes+=size
        return value


def crop_rect(view,width,height):
    if view['kind']=='full':
        return (0,0,width,height)
    require(view['kind']=='normalized_roi','view must be full or normalized_roi')
    edges=view['rect_normalized_xyxy']
    require(len(edges)==4 and all(isinstance(v,(int,float)) and math.isfinite(v) for v in edges),'invalid ROI')
    require(0<=edges[0]<edges[2]<=1 and 0<=edges[1]<edges[3]<=1,'invalid normalized ROI bounds')
    rect=(int(edges[0]*width),int(edges[1]*height),int(edges[2]*width),int(edges[3]*height))
    require(rect[2]>rect[0] and rect[3]>rect[1],'empty pixel ROI')
    return rect


def inside(label,rect):
    return rect[0]<=label['x']<rect[2] and rect[1]<=label['y']<rect[3]


def resize_rgb(image,rect):
    return np.asarray(image.convert('RGB').crop(rect).resize((W,H)))


def make_target(label,rect):
    if label is None or label['target_identity']!='confirmed' or label['status'] not in {'visible','absent'}:
        return np.zeros((H,W),np.float32),0.,None
    if label['status']=='absent':
        return np.zeros((H,W),np.float32),1.,None
    if not inside(label,rect):
        return np.zeros((H,W),np.float32),0.,{'reason':'visible_point_outside_fixed_training_ROI'}
    width,height=rect[2]-rect[0],rect[3]-rect[1]
    x,y=(label['x']-rect[0])*W/width,(label['y']-rect[1])*H/height
    sx,sy=max(1.5,label['uncertainty_px']*W/width),max(1.5,label['uncertainty_px']*H/height)
    yy,xx=np.ogrid[:H,:W]
    gaussian=np.exp(-.5*(((xx-x)/sx)**2+((yy-y)/sy)**2)).astype(np.float32)
    return gaussian,1.,{'center_xy':[x,y],'sigma_xy':[sx,sy]}


def balanced_wbce(prediction,targets,frame_mask):
    require(prediction.shape==targets.shape and frame_mask.shape==prediction.shape[:2],'loss geometry mismatch')
    count=frame_mask.sum()
    require(count.item()>0,'all-unknown/ROI-excluded batch rejected')
    p=prediction
    positive=-(1-p).square()*targets*torch.log(p.clamp(1e-7,1))
    negative=-p.square()*(1-targets)*torch.log((1-p).clamp(1e-7,1))
    pos_mass=targets.sum((-1,-2))
    neg_mass=(1-targets).sum((-1,-2))
    pos=positive.sum((-1,-2))/pos_mass.clamp_min(1e-7)
    neg=negative.sum((-1,-2))/neg_mass.clamp_min(1e-7)
    per_frame=torch.where(pos_mass>0,.5*(pos+neg),neg)
    loss=(per_frame*frame_mask).sum()/count
    diagnostics={'balanced_wbce':loss.detach().item(),
        'positive_component':((pos*frame_mask).sum()/count).detach().item(),
        'negative_component':((neg*frame_mask).sum()/count).detach().item(),
        'raw_full_image_wbce':((((positive+negative).mean((-1,-2)))*frame_mask).sum()/count).detach().item(),
        'supervised_frames':int(count.item()),'positive_frames':int(((pos_mass>0)*frame_mask).sum().item())}
    return loss,diagnostics


def state_sha(model,predicate=lambda name:True):
    h=hashlib.sha256()
    for name,tensor in sorted(model.state_dict().items()):
        if predicate(name):
            h.update(canonical({'name':name,'shape':list(tensor.shape),'dtype':str(tensor.dtype)}).encode())
            h.update(tensor.detach().cpu().contiguous().numpy().tobytes())
    return h.hexdigest()


def labels_list(document):
    return document.get('records',document.get('labels')) if isinstance(document,dict) else document


def normalize_window(window,base):
    wid=window.get('window_id',window.get('sample_id'))
    require(isinstance(wid,str) and Path(wid).name==wid,'invalid window id')
    result=dict(window,sample_id=wid)
    for key in ('source_sha256','source_family','rally_group','overlap_group','split'):
        require(isinstance(result.get(key),str) and result[key],'missing source/split metadata: '+key)
    require(len(result['source_sha256'])==64 and all(c in '0123456789abcdef' for c in result['source_sha256']),'source SHA must be64 lowercase hex characters')
    frames={}
    for f in window['frames']:
        index=f.get('frame_index',f.get('window_frame_index'))
        require(isinstance(index,int) and index not in frames,'invalid/duplicate frame index')
        require(isinstance(f['source_pts'],int) and not isinstance(f['source_pts'],bool),'source PTS must be integer')
        path=resolved(f['image_path'],base)
        frames[index]={**f,'window_frame_index':index,'source_time_base':f.get('source_time_base',window['source_time_base']),
            'width':f.get('width',window['width']),'height':f.get('height',window['height']),
            'filename':path.name,'image_path':str(path),'sha256':f.get('image_sha256',f.get('sha256'))}
    result['frames']=frames
    return result


def load_label_map(path,windows,diagnostic):
    labels=labels_list(read(path))
    require(isinstance(labels,list),'label list missing')
    normalized=[{**l,'sample_id':l.get('window_id',l.get('sample_id'))} for l in labels]
    lookup={(sid,i):f for sid,w in windows.items() for i,f in w['frames'].items()}
    return helper().check_labels(normalized,lookup,diagnostic)


def validate_protocol(config):
    require(config.get('schema_version')==1,'unsupported protocol schema')
    require(not config.get('example_only',False),'interface example is not an executable protocol')
    require(config.get('purpose') in {'sanity','held_out_source_exploration'},'explicit experimental purpose required')
    require(config.get('seed')==20261029 and config.get('device')=='cpu','this run is fixed to seed20261029 / CPU')
    require(config.get('optimizer')=='Adam' and config.get('loss')=='balanced_wbce_v1','fixed optimizer/loss required')
    require(isinstance(config.get('steps'),int) and 1<=config['steps']<=512,'bounded steps must be1..512')
    require(isinstance(config.get('learning_rate'),(int,float)) and 0<config['learning_rate']<=.01,'invalid fixed lr')
    require(0<=config.get('cache_mib',0)<=8192,'feature cache must be0..8192MiB')
    require(config.get('background_pipeline')=='original_rgb_median48_then_view_resize','background pipeline must be explicit')
    require(config.get('variants') and len(config['variants'])<=4 and config.get('views'),'missing or excessive frozen variants/views')
    seen=set()
    for variant in config['variants']:
        require(variant['name'] not in seen and Path(variant['name']).name==variant['name'],'invalid variant name')
        seen.add(variant['name'])
        require(variant['trainable'] in {'head_only','decoder_head'} and variant['view'] in config['views'],'invalid variant')
    if config['purpose']=='held_out_source_exploration':
        require('eval' in config['packages'],'source-held-out exploration requires explicit eval package')


def prepare(args):
    protocol_path=Path(args.protocol).resolve()
    config=read(protocol_path)
    validate_protocol(config)
    provenance=source_check()
    out=Path(args.output).resolve()
    require(not out.exists(),'prepare output exists')
    windows,packages,files={}, {}, {}
    for split,package in config['packages'].items():
        require(split in {'train','eval'},'unknown package split')
        metadata=resolved(package['metadata']['path'],protocol_path.parent)
        label_path=resolved(package['labels']['path'],protocol_path.parent)
        require(sha(metadata)==package['metadata']['sha256'] and sha(label_path)==package['labels']['sha256'],'package metadata/label digest mismatch')
        # Hash eval label bytes only. Never decode or inspect them during prepare.
        files[str(metadata)]=sha(metadata); files[str(label_path)]=sha(label_path)
        document=read(metadata)
        selected={wid:normalize_window(w,metadata.parent) for w in document['windows'] if (wid:=w.get('window_id',w.get('sample_id'))) in package['window_ids']}
        require(set(selected)==set(package['window_ids']),'missing configured windows')
        for sid,window in selected.items():
            require(window['split']==split and sid not in windows,'window split mismatch/duplicate')
            frames=window['frames']
            for i,frame in frames.items():
                require(sha(frame['image_path'])==frame['sha256'],'source frame digest mismatch')
                files[frame['image_path']]=frame['sha256']
                with Image.open(frame['image_path']) as image:
                    require(image.size==(frame['width'],frame['height']),'original frame geometry mismatch')
            starts=package['sequence_starts']
            require(isinstance(starts,list) and starts and len(set(starts))==len(starts) and all(isinstance(s,int) and not isinstance(s,bool) and s>=0 for s in starts),'invalid fixed sequence starts')
            for start in starts:
                seq=[frames[i] for i in range(start,start+8)]
                times=[Fraction(f['source_pts'])*Fraction(f['source_time_base']) for f in seq]
                require(all(a<b for a,b in zip(times,times[1:])),'non-increasing actual PTS')
                require(not any(f.get('gap_before',False) for f in seq[1:]),'sequence crosses a gap')
            window['sequence_starts']=starts
            background=window['background']
            indices=background.get('indices',background.get('indices48'))
            require(indices==[math.floor(i*(len(frames)-1)/47) for i in range(48)],'background must use frozen uniform48 indices')
            window['background_indices']=indices
            windows[sid]=window
        prediction_starts=package['prediction_starts']
        require(prediction_starts==list(range(0,120,8)),'full-window prediction starts must be0,8,...112')
        for window in selected.values():
            require(sorted(window['frames'])==list(range(120)),'this frozen experiment requires120 actual indexed frames per window')
        packages[split]={'window_ids':sorted(selected),'labels':str(label_path),'labels_sha256':sha(label_path),
                         'prediction_starts':prediction_starts}
    require('train' in packages,'missing train package')
    helper().check_splits([{**w,
        'first_time':min(Fraction(f['source_pts'])*Fraction(f['source_time_base']) for f in w['frames'].values()),
        'last_time':max(Fraction(f['source_pts'])*Fraction(f['source_time_base']) for f in w['frames'].values())} for w in windows.values()])
    train_windows={sid:windows[sid] for sid in packages['train']['window_ids']}
    labels=load_label_map(packages['train']['labels'],train_windows,args.diagnostic_agent_labels)
    eligible={}
    for variant in config['variants']:
        view=config['views'][variant['view']]
        seqs=[]
        for sid,window in sorted(train_windows.items()):
            rect=crop_rect(view,window['width'],window['height'])
            for start in sorted(window['sequence_starts']):
                masks=[make_target(labels.get((sid,i)),rect)[1] for i in range(start,start+8)]
                if sum(masks)>0:
                    seqs.append({'sample_id':sid,'start':start,'supervised_frames':int(sum(masks))})
        require(seqs,'all-unknown/ROI-excluded variant rejected')
        eligible[variant['name']]=seqs
    out.mkdir(parents=True)
    write(out/'protocol.json',config)
    background_hashes={}
    # One native RGB median per window; every view uses this same frozen array.
    for sid,window in sorted(windows.items()):
        stack=np.stack([np.asarray(Image.open(window['frames'][i]['image_path']).convert('RGB')) for i in window['background_indices']])
        median=np.median(stack,axis=0).astype(np.uint8)
        del stack
        path=out/f'{sid}-background.npy'
        np.save(path,median,allow_pickle=False)
        background_hashes[path.name]=sha(path)
    receipt={'schema_version':1,'production':False,'human_validated':False,
        'created_at':datetime.now(timezone.utc).isoformat(),'runner_sha256':sha(Path(__file__)),'helper_sha256':sha(HELPER),
        'protocol_sha256':sha(out/'protocol.json'),'original_protocol_sha256':sha(protocol_path),
        'source':provenance,'runtime':runtime(),'files':files,'backgrounds':background_hashes,
        'packages':packages,'windows':windows,'eligible':eligible,'diagnostic_agent_labels':args.diagnostic_agent_labels,
        'eval_labels_decoded':False,'sequence_schedule':'sorted eligible sample/start, cyclic for exactly fixed steps',
        'loss_formula':'per frame Lpos=sum((1-p)^2*y*-log(p))/sum(y); Lneg=sum(p^2*(1-y)*-log(1-p))/sum(1-y); visible .5*(Lpos+Lneg), absent negative-only; valid frames mean; clamp logs1e-7',
        'limits':['new balanced loss is not a reproduction of original author training','agent labels are not physical truth',
            'native median uses future frames; offline context','held-out-source exploratory labels do not establish court accuracy',
            'no model selection or early stopping from eval labels','no-output and ROI-excluded eval positives stay in denominator',
            'monotonic manifest PTS alone is not proof of no dropped frames; source60fps/train vs30fps/eval domain shift retained',
            'training agreement is a fit diagnostic, not generalization']}
    write(out/'receipt.json',receipt)
    print(canonical({'prepared':str(out),'eligible_sequences':{k:len(v) for k,v in eligible.items()},'eval_labels_decoded':False}))


def audit(prepared):
    prepared=Path(prepared).resolve()
    receipt=read(prepared/'receipt.json'); config=read(prepared/'protocol.json')
    require(receipt['runner_sha256']==sha(Path(__file__)) and receipt['helper_sha256']==sha(HELPER),'runner/helper changed since prepare')
    require(receipt['protocol_sha256']==sha(prepared/'protocol.json'),'frozen protocol changed')
    require(receipt['runtime']==runtime(),'runtime changed')
    require(receipt['source']==source_check(),'official source changed')
    for path,expected in receipt['files'].items():
        require(sha(path)==expected,'frozen input changed: '+path)
    for name,expected in receipt['backgrounds'].items():
        require(sha(prepared/name)==expected,'frozen median changed')
    for window in receipt['windows'].values():
        window['frames']={int(k):v for k,v in window['frames'].items()}
    return prepared,receipt,config


def batch(prepared,window,start,view,labels,include_input=True):
    rect=crop_rect(view,window['width'],window['height'])
    channels=[]
    if include_input:
        background=Image.fromarray(np.load(prepared/f"{window['sample_id']}-background.npy",allow_pickle=False))
        channels=[np.moveaxis(resize_rgb(background,rect),-1,0)]
    targets,masks,geometry=[],[],[]
    for i in range(start,start+8):
        if include_input:
            with Image.open(window['frames'][i]['image_path']) as im:
                channels.append(np.moveaxis(resize_rgb(im,rect),-1,0))
        target,mask,geo=make_target(labels.get((window['sample_id'],i)),rect)
        targets.append(target); masks.append(mask); geometry.append(geo)
    x=torch.from_numpy(np.concatenate(channels,axis=0).astype(np.float32)/255).unsqueeze(0) if include_input else None
    y=torch.from_numpy(np.stack(targets)).unsqueeze(0)
    return x,y,torch.tensor([masks],dtype=torch.float32),geometry,rect


def point_predictions(prediction,geometry):
    result=[]
    for offset,item in enumerate(geometry):
        if not item or 'center_xy' not in item:
            continue
        x,y=item['center_xy']
        grid=torch.tensor([[[[2*x/(W-1)-1,2*y/(H-1)-1]]]],dtype=torch.float32)
        result.append({'output_channel':offset,'prediction_at_label':F.grid_sample(prediction[:,offset:offset+1].detach(),grid,align_corners=True).item()})
    return result


def fit_variant(prepared,receipt,config,variant,labels,out):
    torch.manual_seed(config['seed'])
    mode=variant['trainable']; view=config['views'][variant['view']]
    model=factory(mode)
    trainable={n for n,p in model.named_parameters() if p.requires_grad}
    frozen_before=state_sha(model,lambda n:n not in trainable)
    optimizer=torch.optim.Adam([p for p in model.parameters() if p.requires_grad],lr=config['learning_rate'])
    cache=FeatureCache(config.get('cache_mib',0))
    seqs=receipt['eligible'][variant['name']]
    history=[]
    start_time=time.perf_counter()
    first_cache_fingerprint=None
    for step in range(config['steps']):
        item=seqs[step%len(seqs)]; window=receipt['windows'][item['sample_id']]
        cache_spec={'sample_id':item['sample_id'],'start':item['start'],'mode':mode,
            'input_frame_sha256':[window['frames'][i]['sha256'] for i in range(item['start'],item['start']+8)],
            'native_background_sha256':receipt['backgrounds'][item['sample_id']+'-background.npy'],
            'view':view,'prefix_frozen_state_sha256':frozen_before,'base_sha256':BASE_SHA,'dtype':'float32'}
        cache_key=hashlib.sha256(canonical(cache_spec).encode()).hexdigest()
        first_cache_fingerprint=first_cache_fingerprint or {'sha256':cache_key,'specification':cache_spec}
        x,y,mask,geometry,rect=batch(prepared,window,item['start'],view,labels,include_input=cache_key not in cache.items)
        features=cache.get(cache_key,lambda:frozen_features(model,x,mode))
        if step==0:
            with torch.no_grad():
                require(torch.equal(model(x),suffix(model,features,mode)),'actual input split-forward differs from official forward')
        optimizer.zero_grad(set_to_none=True)
        pred=suffix(model,features,mode); pred.retain_grad()
        loss,diag=balanced_wbce(pred,y,mask)
        require(torch.isfinite(loss).item(),'nonfinite training loss')
        loss.backward()
        require(all(torch.count_nonzero(pred.grad[0,i]).item()==0 for i in range(8) if mask[0,i]==0),'masked output has nonzero loss gradient')
        grad=math.sqrt(sum(float((p.grad.double()**2).sum()) for p in model.parameters() if p.requires_grad))
        require(math.isfinite(grad) and grad>0,'invalid training gradient')
        _,zero_diag=balanced_wbce(torch.zeros_like(pred),y,mask)
        history.append({'step':step,'sequence':item,'frame_mask':mask[0].tolist(),'crop_xyxy':rect,
            'loss':diag,'all_zero_prediction_loss':zero_diag,'label_point_predictions':point_predictions(pred,geometry),
            'gradient_norm':grad})
        optimizer.step()
    frozen_after=state_sha(model,lambda n:n not in trainable)
    require(frozen_before==frozen_after,'frozen weights or BN buffers changed')
    artifact={'production':False,'human_validated':False,'parent_sha256':BASE_SHA,
        'protocol_sha256':receipt['protocol_sha256'],'variant':variant,
        'trainable_state':{n:t for n,t in model.state_dict().items() if n in trainable}}
    path=out/(variant['name']+'.pt'); torch.save(artifact,path)
    # Reload saved tensors safely and reconstruct the exact evaluated model.
    restored=torch.load(path,map_location='cpu',weights_only=True)
    require(restored['parent_sha256']==BASE_SHA and restored['protocol_sha256']==receipt['protocol_sha256'] and restored['variant']==variant,'saved artifact provenance mismatch')
    require(set(restored['trainable_state'])==trainable,'saved trainable key mismatch')
    replay=factory(mode); state=replay.state_dict()
    for name,tensor in restored['trainable_state'].items():
        require(tensor.shape==state[name].shape and tensor.dtype==state[name].dtype,'saved tensor geometry/type mismatch')
        state[name]=tensor
    replay.load_state_dict(state,strict=True)
    require(state_sha(replay)==state_sha(model),'safe-reloaded model is not identical to fitted model')
    report={'production':False,'human_validated':False,'variant':variant,'steps':config['steps'],'learning_rate':config['learning_rate'],
        'trainable_parameter_count':sum(p.numel() for p in model.parameters() if p.requires_grad),
        'eligible_sequences':len(seqs),'history':history,'frozen_state_before':frozen_before,'frozen_state_after':frozen_after,
        'feature_cache':{'limit_mib':config.get('cache_mib',0),'hits':cache.hits,'misses':cache.misses,'resident_bytes':cache.bytes},
        'split_forward_exact_first_batch':True,
        'cache_first_fingerprint':first_cache_fingerprint,'safe_reloaded_exact':True,
        'elapsed_seconds':time.perf_counter()-start_time,'artifact':str(path),'artifact_sha256':sha(path)}
    del cache
    return replay,report


def candidate(heatmap,rect):
    contours,_=cv2.findContours((heatmap>.5).astype(np.uint8)*255,cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE)
    boxes=[cv2.boundingRect(c) for c in contours]
    if not boxes:
        return None
    box=max(boxes,key=lambda b:b[2]*b[3])
    x,y=int(box[0]+box[2]/2),int(box[1]+box[3]/2)
    if x==0 and y==0:
        return None
    return [int(rect[0]+x*(rect[2]-rect[0])/W),int(rect[1]+y*(rect[3]-rect[1])/H)]


def point_result(xy,label,rect,width,height):
    is_inside=inside(label,rect)
    native=None if xy is None else math.hypot(xy[0]-label['x'],xy[1]-label['y'])
    equivalent=None if xy is None else math.hypot((xy[0]-label['x'])*1280/width,(xy[1]-label['y'])*720/height)
    return {'candidate_xy_original':xy,'point_inside_fixed_view':is_inside,'distance_native_px':native,
        'distance_1280x720_equivalent_px':equivalent,
        'within_native_px':{str(r):is_inside and native is not None and native<=r for r in (5,10,20)},
        'within_equivalent_px':{str(r):is_inside and equivalent is not None and equivalent<=r for r in (5,10,20)}}


def eval_summary(points):
    n=len(points)
    result={'visible_confirmed_denominator':n,'output_count':sum(p['candidate_xy_original'] is not None for p in points),
        'output_coverage':sum(p['candidate_xy_original'] is not None for p in points)/n if n else None,
        'no_output_count':sum(p['candidate_xy_original'] is None for p in points),'ROI_outside_positive_count':sum(not p['point_inside_fixed_view'] for p in points)}
    for kind,key in [('native','distance_native_px'),('equivalent','distance_1280x720_equivalent_px')]:
        values=[p[key] for p in points if p[key] is not None]
        result[kind]={'conditional_output_n':len(values),'distance_median':float(np.median(values)) if values else None,
            'distance_p90':float(np.percentile(values,90)) if values else None,
            'conditional_output_distance_over_20_count':sum(v>20 for v in values),
            'within_counts':{str(r):sum(p['within_'+kind+'_px'][str(r)] for p in points) for r in (5,10,20)},
            'within_fraction_of_all':{str(r):sum(p['within_'+kind+'_px'][str(r)] for p in points)/n if n else None for r in (5,10,20)},
            'denominator':n}
    return result


def evaluate(prepared,receipt,config,models,labels,out,split,prediction_stream):
    reports={}
    for name,(model,view_name) in models.items():
        view=config['views'][view_name]
        rows=[]
        before=state_sha(model)
        for sid in receipt['packages'][split]['window_ids']:
            window=receipt['windows'][sid]
            for start in receipt['packages'][split]['prediction_starts']:
                x,_,_,_,rect=batch(prepared,window,start,view,{})
                with torch.inference_mode():
                    maps=model(x).numpy()[0]
                for offset,index in enumerate(range(start,start+8)):
                    frame=window['frames'][index]; label=labels.get((sid,index))
                    xy=candidate(maps[offset],rect)
                    row={'split':split,'model_group':name,'view':view_name,'sample_id':sid,'window_id':sid,'frame_index':index,'sequence_start':start,'output_offset':offset,
                        'source_pts':frame['source_pts'],'source_time_base':frame['source_time_base'],
                        'image_path':frame['image_path'],'image_sha256':frame['sha256'],'width':frame['width'],'height':frame['height'],
                        'candidate_xy_original':xy,'heatmap_peak':float(maps[offset].max()),'crop_xyxy':rect,
                        'threshold':.5,'threshold_operator':'>','label':label}
                    if label and label['status']=='visible' and label['target_identity']=='confirmed':
                        row['comparison']=point_result(xy,label,rect,frame['width'],frame['height'])
                    rows.append(row)
                    prediction_stream.write(canonical(row)+'\n')
        require(before==state_sha(model),'evaluation mutated model state')
        write(out/(name+'-'+split+'-frames.json'),rows)
        reports[name]={'view':view_name,'frame_occurrences':len(rows),
            'visible_candidate_agreement':eval_summary([r['comparison'] for r in rows if 'comparison' in r]),
            'explicit_absence_denominator':sum(r['label'] is not None and r['label']['status']=='absent' and r['label']['target_identity']=='confirmed' for r in rows),
            'explicit_absence_false_output_count':sum(r['label'] is not None and r['label']['status']=='absent' and r['label']['target_identity']=='confirmed' and r['candidate_xy_original'] is not None for r in rows),
            'unknown_or_uncertain_label_count':sum(r['label'] is not None and (r['label']['status'] not in {'visible','absent'} or r['label']['target_identity']!='confirmed') for r in rows),
            'model_unchanged':True,'production':False,'human_validated':False,'accuracy':None}
    return reports


def execute(args):
    require(args.execute_frozen_protocol,'run requires --execute-frozen-protocol')
    prepared,receipt,config=audit(args.prepared)
    require(not receipt['diagnostic_agent_labels'] or args.diagnostic_agent_labels,'agent-label protocol requires explicit --diagnostic-agent-labels at run')
    out=Path(args.output).resolve(); require(not out.exists(),'run output exists'); out.mkdir(parents=True)
    torch.set_num_threads(4); torch.use_deterministic_algorithms(True)
    train_windows={sid:receipt['windows'][sid] for sid in receipt['packages']['train']['window_ids']}
    labels=load_label_map(receipt['packages']['train']['labels'],train_windows,receipt['diagnostic_agent_labels'])
    models,reports={},{}
    for variant in config['variants']:
        model,report=fit_variant(prepared,receipt,config,variant,labels,out)
        models[variant['name']]=(model,variant['view']); reports[variant['name']]=report
        write(out/(variant['name']+'-training.json'),report)
    # Only now decode eval label JSON: all hyperparameters and final weights fixed.
    evaluation={}; training_diagnostic={}
    for view_name in config['views']:
        models['original_'+view_name]=(factory('base'),view_name)
    with open(out/'predictions.jsonl','x') as prediction_stream:
        training_diagnostic=evaluate(prepared,receipt,config,models,labels,out,'train',prediction_stream)
        if 'eval' in receipt['packages']:
            eval_windows={sid:receipt['windows'][sid] for sid in receipt['packages']['eval']['window_ids']}
            eval_labels=load_label_map(receipt['packages']['eval']['labels'],eval_windows,receipt['diagnostic_agent_labels'])
            evaluation=evaluate(prepared,receipt,config,models,eval_labels,out,'eval',prediction_stream)
    require(source_check()==receipt['source'],'official base/source changed during run')
    for path,expected in receipt['files'].items():
        require(sha(path)==expected,'frozen input changed during execution: '+path)
    for name,expected in receipt['backgrounds'].items():
        require(sha(prepared/name)==expected,'frozen background changed during execution')
    write(out/'report.json',{'production':False,'human_validated':False,'protocol_sha256':receipt['protocol_sha256'],
        'training':reports,'training_diagnostic':training_diagnostic,'evaluation':evaluation,'eval_labels_read_only_after_all_fits':True,
        'all_frozen_inputs_unchanged_after_run':True,
        'model_selection':False,'accuracy':None,'limits':receipt['limits']})
    write(out/'completion.json',{'status':'complete','production':False,'protocol_sha256':receipt['protocol_sha256'],
        'runner_sha256':sha(Path(__file__)),'predictions_sha256':sha(out/'predictions.jsonl'),'report_sha256':sha(out/'report.json')})
    print(canonical({'output':str(out),'completed_variants':list(reports),'evaluation_groups':list(evaluation)}))


def benchmark(args):
    out=Path(args.output).resolve(); require(not out.exists(),'benchmark output exists'); out.mkdir(parents=True)
    write(out/'protocol.json',{'synthetic_only':True,'optimizer_steps':0,'seed':20261029,'device':'cpu','threads':4,
        'modes':['head_only','decoder_head'],'input':[1,27,H,W],'purpose':'kernel and split-forward timing; no accuracy evidence'})
    torch.manual_seed(20261029); torch.set_num_threads(4)
    x=torch.rand((1,27,H,W)); yy,xx=torch.meshgrid(torch.arange(H),torch.arange(W),indexing='ij')
    y=torch.exp(-((xx-W/2).square()+(yy-H/2).square())/(2*2.**2))[None,None].repeat(1,8,1,1)
    mask=torch.ones((1,8)); rows=[]
    for mode in ('head_only','decoder_head'):
        model=factory(mode); before=state_sha(model)
        started=time.perf_counter(); features=frozen_features(model,x,mode); feature_time=time.perf_counter()-started
        with torch.no_grad():
            require(torch.equal(model(x),suffix(model,features,mode)),'split-forward differs from official forward')
        started=time.perf_counter(); pred=suffix(model,features,mode); loss,diag=balanced_wbce(pred,y,mask); loss.backward(); suffix_time=time.perf_counter()-started
        require(state_sha(model)==before,'benchmark changed model tensors')
        rows.append({'mode':mode,'feature_seconds':feature_time,'cached_suffix_forward_backward_seconds':suffix_time,
            'feature_mib':features.numel()*features.element_size()/1024**2,
            'trainable_parameters':sum(p.numel() for p in model.parameters() if p.requires_grad),
            'model_unchanged':True,'split_forward_exact':True,'optimizer_steps':0,'loss':diag})
    write(out/'report.json',{'synthetic_only':True,'production':False,'optimizer_steps':0,'rows':rows,'runtime':runtime()})
    print(canonical(rows))


class SelfTests(unittest.TestCase):
    def test_ROI_coordinates_and_equivalent_distance(self):
        rect=crop_rect({'kind':'normalized_roi','rect_normalized_xyxy':[.1,.1,.9,.9]},1920,1080)
        self.assertEqual(rect,(192,108,1728,972))
        label={'status':'visible','target_identity':'confirmed','x':960,'y':540,'uncertainty_px':6}
        _,mask,geo=make_target(label,rect)
        self.assertEqual(mask,1.); self.assertEqual(geo['center_xy'],[256.,144.])
        point=point_result([975,540],label,rect,1920,1080)
        self.assertEqual(point['distance_native_px'],15.); self.assertEqual(point['distance_1280x720_equivalent_px'],10.)

    def test_unknown_gradient_and_zero_shortcut(self):
        _,_,geo=make_target({'status':'unknown','target_identity':'uncertain'},(0,0,1280,720)); self.assertIsNone(geo)
        label={'status':'visible','target_identity':'confirmed','x':640,'y':360,'uncertainty_px':5}
        target,_,_=make_target(label,(0,0,1280,720)); y=torch.from_numpy(np.stack([target,target]))[None]
        p=torch.full_like(y,.5,requires_grad=True); mask=torch.tensor([[1.,0.]])
        loss,_=balanced_wbce(p,y,mask); loss.backward()
        self.assertEqual(torch.count_nonzero(p.grad[0,1]).item(),0)
        zero,_=balanced_wbce(torch.zeros_like(y),y,mask)
        self.assertGreater(zero.item(),loss.item()*10)
        with self.assertRaisesRegex(ValueError,'all-unknown'):
            balanced_wbce(p,y,torch.zeros_like(mask))

    def test_ROI_outside_is_training_unknown_and_eval_miss(self):
        label={'status':'visible','target_identity':'confirmed','x':99,'y':200,'uncertainty_px':5}
        rect=(100,100,1100,600)
        _,mask,_=make_target(label,rect); self.assertEqual(mask,0.)
        result=point_result([100,200],label,rect,1280,720)
        self.assertFalse(result['within_native_px']['5'])
        summary=eval_summary([result,point_result(None,label,rect,1280,720)])
        self.assertEqual(summary['native']['denominator'],2); self.assertEqual(summary['native']['within_counts']['5'],0)

    def test_source_isolation(self):
        item={'source_sha256':'a','source_family':'f','rally_group':'r','overlap_group':'o','split':'train','first_time':0,'last_time':1}
        with self.assertRaises(ValueError):
            helper().check_splits([item,{**item,'split':'eval'}])


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--self-test',action='store_true'); subs=p.add_subparsers(dest='command')
    prep=subs.add_parser('prepare'); prep.add_argument('--protocol',required=True); prep.add_argument('--output',required=True)
    prep.add_argument('--diagnostic-agent-labels',action='store_true')
    bench=subs.add_parser('benchmark'); bench.add_argument('--output',required=True)
    run=subs.add_parser('run'); run.add_argument('--prepared',required=True); run.add_argument('--output',required=True)
    run.add_argument('--execute-frozen-protocol',action='store_true')
    run.add_argument('--diagnostic-agent-labels',action='store_true')
    args=p.parse_args()
    if args.self_test:
        result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests))
        return 0 if result.wasSuccessful() else 1
    require(args.command,'choose prepare, benchmark, run, or --self-test')
    {'prepare':prepare,'benchmark':benchmark,'run':execute}[args.command](args)
    return 0


if __name__=='__main__':
    try:
        sys.exit(main())
    except (ValueError,KeyError,FileNotFoundError) as error:
        print('ball-track-tune: '+str(error),file=sys.stderr)
        sys.exit(2)
