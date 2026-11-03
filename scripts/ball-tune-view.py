#!/usr/bin/env python3
"""Render source-bound six-group ball-localization development comparisons.

This script only reads frozen inference outputs and original decoded images.
Requires Pillow, ffmpeg/ffprobe; it never trains, annotates, or estimates speed.
"""
import argparse
from fractions import Fraction
import hashlib
import html
import importlib.util
import json
import math
from pathlib import Path
import sys

from PIL import Image, ImageDraw

_spec=importlib.util.spec_from_file_location('ball_compare_render',Path(__file__).with_name('ball-compare-view.py'))
render=importlib.util.module_from_spec(_spec);_spec.loader.exec_module(render)
GROUPS=('original_full','original_roi','full_head_only','full_decoder_head','roi_head_only','roi_decoder_head')
FITS=('full_head_only','full_decoder_head','roi_head_only','roi_decoder_head')
NAMES={'original_full':'原始 · 全画面','original_roi':'原始 · 中心80% ROI',
       'full_head_only':'全画面 · 仅输出头 · 72步','full_decoder_head':'全画面 · 解码器与输出头 · 72步',
       'roi_head_only':'中心80% ROI · 仅输出头 · 72步','roi_decoder_head':'中心80% ROI · 解码器与输出头 · 72步'}
STILL_INDICES=(0,10,64,72,80,88,95,110)
CYAN='#39d9ec';ORANGE='#ffab52'


def baseline(group):return 'original_roi' if group.startswith('roi_') else 'original_full'


def sha(path):return render.sha(path)


def write_json(path,value):return render.write_json(path,value)


def point_overlay(source,point,color,roi):
    image=source.resize((960,540),Image.Resampling.LANCZOS)
    draw=ImageDraw.Draw(image)
    if roi:
        draw.rectangle((96,54,864,486),outline='#f0f3f6',width=2)
    if point is not None:
        x,y=point[0]*960/source.width,point[1]*540/source.height
        draw.ellipse((x-11,y-11,x+11,y+11),outline=color,width=3)
        for line in ((x-17,y,x-6,y),(x+6,y,x+17,y),(x,y-17,x,y-6),(x,y+6,x,y+17)):
            draw.line(line,fill=color,width=2)
    return image


def pair_image(source,left_point,right_point,group,frame_text,details):
    roi=group.startswith('roi_')
    left=point_overlay(source,left_point,CYAN,roi);right=point_overlay(source,right_point,ORANGE,roi)
    image=Image.new('RGB',(1920,652),'#101820');image.paste(left,(0,70));image.paste(right,(960,70))
    draw=ImageDraw.Draw(image)
    draw.text((12,8),frame_text,fill='white',font=render.font(20))
    left_text=('ORIGINAL ROI80' if roi else 'ORIGINAL FULL')+(' | NO OUTPUT >0.5' if left_point is None else '')
    right_text=group.upper()+' / 72 STEPS'+(' | NO OUTPUT >0.5' if right_point is None else '')
    draw.text((12,38),left_text,fill=CYAN,font=render.font(19));draw.text((972,38),right_text,fill=ORANGE,font=render.font(19))
    draw.text((12,620),details,fill='#c4d1dd',font=render.font(17))
    return image


def html_page(data):
    serialized=json.dumps(data,ensure_ascii=False,separators=(',',':'),allow_nan=False).replace('<','\\u003c')
    return '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>球定位开发：6组固定对照</title><style>
body{margin:0;background:#10151d;color:#edf1f5;font:16px/1.65 system-ui,-apple-system,sans-serif}main{max-width:1240px;margin:auto;padding:28px 20px}h1{font-size:30px;line-height:1.3}h2{font-size:23px}section{margin:28px 0;padding:22px;background:#1a2430;border-radius:12px}video,img{display:block;width:100%;height:auto;background:#080d13;border-radius:6px}select{font:inherit;min-height:44px;background:#263747;color:white;border:1px solid #788c9f;border-radius:7px;padding:8px;max-width:100%}a{color:#9ddaff}.small{font-size:14px;color:#bbc8d6}.notice{border-left:4px solid #ffb15f;padding:12px 18px;background:#202c39}.legend{display:flex;flex-wrap:wrap;gap:20px}.base{color:#39d9ec}.fit{color:#ffab52}table{border-collapse:collapse;width:100%;font-size:14px}th,td{padding:9px;text-align:right;border-bottom:1px solid #455567;white-space:nowrap}th:first-child,td:first-child{text-align:left}.scroll{overflow:auto}summary{cursor:pointer;min-height:44px;padding:10px 0}article{margin:24px 0}li{margin:8px 0}.sticky{position:sticky;top:0;background:#10151df2;z-index:3;padding:12px 0}
</style><main><h1>球定位开发：6组固定对照</h1><p class="notice">只比较球定位，<strong>没有新球速数值</strong>。圈为模型输出；标注为 Agent 候选，距离统计只是与候选的一致性，不能称为准确率。</p><div class="sticky"><label>选择对照模型 <select id="model"></select></label><div class="legend"><span class="base">左：相同输入视野的原始模型</span><span class="fit">右：独立微调72步</span><span>白框：预先固定的中心80% ROI</span></div></div><p>默认展示全画面“解码器与输出头”组，选择不根据结果挑优。四组微调各自从同一原始模型独立开始。ROI结果已映射回原片坐标，左右使用同一原片帧；ROI组的原始对照也只接收相同ROI。</p><div id="videos"></div><section><h2>训练来源：候选一致性</h2><p>训练窗上的拟合表现不证明泛化。visible分母包含无输出；未知、遮挡与画外均不当无球负例。</p><div id="trainTable" class="scroll"></div></section><section><h2>Eval来源：候选一致性</h2><p>Eval来源单独报告，未把其标注用于训练或选步数。这是30fps传球窗口，<strong>不是高速球检测或测速测试</strong>，不代表跨设备、场地或真实球速精度。</p><div id="evalTable" class="scroll"></div></section><section><h2>固定边界</h2><ul><li>每窗固定120连续帧；静图预先固定0/10/64/72/80/88/95/110，无结果驱动替换。</li><li>≤10与&gt;20像素均按1280×720等效坐标计算。条件距离统计不能取代包含miss的visible分母。</li><li>每窗背景仅由本窗均匀48帧的原片RGB中位数生成，包含未来帧；只适用于离线开发，不证明实时性能。</li><li>原始预训练模型来自羽毛球领域；Agent身份不是独立人工复核，当前结果不能宣称网球准确率。</li><li>所有图片和视频都在本机，没有外部服务请求；未生成新的球速。</li></ul><a href="view-summary.json">查看输出帧数、PTS与哈希核验摘要</a></section></main>
<script id="view-data" type="application/json">'''+serialized+'''</script><script>
'use strict';const data=JSON.parse(document.getElementById('view-data').textContent),$=id=>document.getElementById(id);const selector=$('model');for(const key of data.fit_groups){const option=document.createElement('option');option.value=key;option.textContent=data.group_names[key];selector.append(option)}selector.value='full_decoder_head';
function number(v){if(v===null||v===undefined)return '—';return typeof v==='number'&&!Number.isInteger(v)?v.toFixed(3):String(v)}
function table(rows){const table=document.createElement('table'),head=document.createElement('thead'),tr=document.createElement('tr');for(const title of ['组别','visible分母','有输出','无输出 / miss','≤10px等效','错误输出 >20px','距离中位数（有输出）']){const th=document.createElement('th');th.textContent=title;tr.append(th)}head.append(tr);table.append(head);const body=document.createElement('tbody');for(const r of rows){const tr=document.createElement('tr');for(const value of [data.group_names[r.group],r.visible_denominator,r.output_count,r.no_output_count,r.within10,r.wrong20,r.conditional_median]){const td=document.createElement('td');td.textContent=number(value);tr.append(td)}body.append(tr)}table.append(body);return table}
$('trainTable').append(table(data.metrics.train));$('evalTable').append(table(data.metrics.eval));
function render(){const group=selector.value;const root=$('videos');root.replaceChildren();for(const window of data.windows){const section=document.createElement('section'),h=document.createElement('h2');h.textContent=window.window_id+' · '+(window.split==='train'?'训练来源':'Eval来源');section.append(h);const caption=document.createElement('p');caption.textContent=data.group_names[window.pairs[group].baseline]+' 对照 '+data.group_names[group]+'。'+window.playback_label;section.append(caption);const video=document.createElement('video');video.controls=true;video.preload='metadata';video.playsInline=true;video.src=window.pairs[group].video_path;section.append(video);const note=document.createElement('p');note.className='small';note.textContent='实际解码 '+window.pairs[group].decoded_frame_count+' 帧；原PTS '+window.first_pts+' → '+window.last_pts+' × '+window.time_base+'；球圈已回原片。';section.append(note);const details=document.createElement('details'),summary=document.createElement('summary');summary.textContent='查看8张预先固定静图';details.append(summary);for(const still of window.pairs[group].stills){const article=document.createElement('article'),title=document.createElement('h3');title.textContent='原帧 '+still.frame_index;article.append(title);const a=document.createElement('a');a.href=still.image_path;const img=document.createElement('img');img.loading='lazy';img.src=still.image_path;img.alt='同帧原始模型与微调模型球定位对照';a.append(img);article.append(a);details.append(article)}section.append(details);root.append(section)}}selector.onchange=render;render();
</script></html>'''


def frame_point(row,frame,window,group,data_root):
    expected_view='roi' if group=='original_roi' or group.startswith('roi_') else 'full'
    expected_path=(data_root/frame['image_path']).resolve()
    for key in ('source_pts','source_time_base','image_sha256','width','height'):
        if row.get(key)!=frame[key]:raise ValueError('Prediction image/PTS binding differs from data manifest: '+key)
    if Path(row['image_path']).resolve()!=expected_path:raise ValueError('Prediction uses unexpected original image')
    if row['window_id']!=window['window_id'] or row['split']!=window['split'] or row['model_group']!=group or row['view']!=expected_view:
        raise ValueError('Prediction group/view/window/split mismatch')
    if row['threshold']!=0.5 or row['threshold_operator']!='>':raise ValueError('Unexpected threshold rule')
    width,height=frame['width'],frame['height']
    rect=[int(v*d) for v,d in zip((.1,.1,.9,.9),(width,height,width,height))] if expected_view=='roi' else [0,0,width,height]
    if row['crop_xyxy']!=rect:raise ValueError('Prediction crop differs from pre-frozen center80/full view')
    xy=render.finite_xy(row['candidate_xy_original'],(width,height))
    if xy is not None and not (rect[0]<=xy[0]<rect[2] and rect[1]<=xy[1]<rect[3]):raise ValueError('Original-coordinate candidate lies outside its input crop')
    return xy


def derived_metrics(rows):
    visible=[]
    for row in rows:
        label=row.get('label')
        if not label or label['status']!='visible' or label['target_identity']!='confirmed':continue
        xy=row['candidate_xy_original'];rect=row['crop_xyxy'];inside=rect[0]<=label['x']<rect[2] and rect[1]<=label['y']<rect[3]
        distance=None if xy is None else math.hypot((xy[0]-label['x'])*1280/row['width'],(xy[1]-label['y'])*720/row['height'])
        visible.append({'output':xy is not None,'inside':inside,'distance':distance,
                        'within10':inside and distance is not None and distance<=10,
                        'wrong20':distance is not None and distance>20})
    return {'visible_denominator':len(visible),'output_count':sum(x['output'] for x in visible),
            'no_output_count':sum(not x['output'] for x in visible),'within10':sum(x['within10'] for x in visible),
            'wrong20':sum(x['wrong20'] for x in visible),'roi_outside':sum(not x['inside'] for x in visible)}


def metrics_rows(report,rows):
    result={}
    for split,key in [('train','training_diagnostic'),('eval','evaluation')]:
        result[split]=[]
        for group in GROUPS:
            raw=report[key][group]['visible_candidate_agreement']
            derived=derived_metrics([r for r in rows if r['split']==split and r['model_group']==group])
            expected={'visible_denominator':raw['visible_confirmed_denominator'],'output_count':raw['output_count'],
                      'no_output_count':raw['no_output_count'],'within10':raw['equivalent']['within_counts']['10'],
                      'roi_outside':raw['ROI_outside_positive_count']}
            if any(derived[k]!=v for k,v in expected.items()):raise ValueError('Independent visible-metric recomputation differs from frozen report')
            if 'conditional_output_distance_over_20_count' in raw['equivalent'] and derived['wrong20']!=raw['equivalent']['conditional_output_distance_over_20_count']:
                raise ValueError('Independent wrong>20 count differs from frozen report')
            result[split].append({'group':group,**derived,'conditional_median':raw['equivalent']['distance_median']})
    return result


def make_pair(window,frame,left,right,group,data_root):
    left_xy=frame_point(left,frame,window,baseline(group),data_root)
    right_xy=frame_point(right,frame,window,group,data_root)
    source=render.open_verified(data_root/frame['image_path'],frame['image_sha256'],(frame['width'],frame['height']))
    exact=Fraction(frame['source_pts'])*Fraction(frame['source_time_base'])
    label=f"{window['window_id']} | frame {frame['frame_index']:03d} | source PTS {frame['source_pts']} x {frame['source_time_base']} = {float(exact):.6f}s"
    detail=f"15 fps frame review | ORIGINAL source coordinates | ball localization only; NO new speed | peak {left['heatmap_peak']:.5f}/{right['heatmap_peak']:.5f}"
    return pair_image(source,left_xy,right_xy,group,label,detail)



def audit_mosaic(window,frame,index,data_root,path):
    wid=window['window_id'];fid=frame['frame_index']
    source=render.open_verified(data_root/frame['image_path'],frame['image_sha256'],(frame['width'],frame['height']))
    row=index[('original_full',wid,fid)];label=row.get('label');box=None
    if label and label['status']=='visible' and label['target_identity']=='confirmed':
        if label.get('reviewer_kind')!='agent':raise ValueError('Expected explicitly Agent audit crop basis')
        if label['image_sha256']!=frame['image_sha256'] or label['source_pts']!=frame['source_pts']:raise ValueError('Audit crop agent binding mismatch')
        center=render.finite_xy([label['x'],label['y']],source.size)
        box=render.crop_box(center,source.size)
    panel_size=(box[2]-box[0],box[3]-box[1]) if box else (512,288)
    pw,ph=panel_size;image=Image.new('RGB',(pw*3,64+2*(ph+34)+40),'#101820');draw=ImageDraw.Draw(image)
    draw.text((10,8),f"{wid} | frame {fid:03d} | PTS {frame['source_pts']} x {frame['source_time_base']}",fill='white',font=render.font(18))
    draw.text((10,35),'1:1 ORIGINAL PIXELS; AGENT-centered region (NOT truth)' if box else 'FULL-FIELD THUMBNAILS; no visible-confirmed label, NO invented crop center',fill='#c7d1db',font=render.font(16))
    order=('original_full','full_head_only','full_decoder_head','original_roi','roi_head_only','roi_decoder_head')
    for k,group in enumerate(order):
        pred=index[(group,wid,fid)];xy=frame_point(pred,frame,window,group,data_root)
        panel=source.crop(box) if box else source.resize(panel_size,Image.Resampling.LANCZOS)
        pd=ImageDraw.Draw(panel);color=CYAN if group.startswith('original_') else ORANGE
        off=False
        if xy is not None:
            if box:
                x,y=xy[0]-box[0],xy[1]-box[1];off=not (0<=x<pw and 0<=y<ph)
            else:x,y=xy[0]*pw/source.width,xy[1]*ph/source.height
            pd.ellipse((x-8,y-8,x+8,y+8),outline=color,width=2)
        x0,y0=(k%3)*pw,64+(k//3)*(ph+34)
        title=group.upper()+(' | NO OUTPUT' if xy is None else ' | OFF-CROP' if off else '')
        draw.text((x0+7,y0+7),title,fill=color,font=render.font(15))
        image.paste(panel,(x0,y0+34))
    draw.text((10,image.height-29),'No Agent point overlay. Full-field paired images retain off-crop outputs for audit.',fill='#c7d1db',font=render.font(15))
    image.save(path,quality=95);path.chmod(0o600)
    return {'window_id':wid,'frame_index':fid,'image_path':str(path),'image_sha256':sha(path),
            'source_pts':frame['source_pts'],'source_time_base':frame['source_time_base'],
            'original_image_sha256':frame['image_sha256'],'crop_box_original':box,
            'crop_basis':'Agent visible+confirmed location, not truth' if box else 'no label center; full-field thumbnails',
            'agent_label_point_shown':False,'model_order':list(order)}


def build(run_root,data_root,output):
    run_root,data_root,output=run_root.resolve(),data_root.resolve(),output.absolute()
    if output.exists() or output.is_symlink():raise ValueError('Output exists; choose a new directory')
    completion=json.loads((run_root/'completion.json').read_text())
    if completion['status']!='complete':raise ValueError('Frozen run is incomplete')
    input_hashes={name:sha(run_root/name) for name in ('predictions.jsonl','report.json','completion.json')}
    if input_hashes['predictions.jsonl']!=completion['predictions_sha256'] or input_hashes['report.json']!=completion['report_sha256']:
        raise ValueError('Frozen result hash mismatch')
    report=json.loads((run_root/'report.json').read_text())
    if report['protocol_sha256']!=completion['protocol_sha256']:raise ValueError('Frozen protocol identity mismatch')
    for group in FITS:
        if report['training'][group]['steps']!=72:raise ValueError('Expected exactly72 independent fit steps')
        if not report['training'][group]['safe_reloaded_exact']:raise ValueError('Model safe reload check failed')
    data_manifest_path=data_root/'manifest.json';data_manifest_hash=sha(data_manifest_path)
    manifest=json.loads(data_manifest_path.read_text())
    windows=manifest['windows']
    if {w['window_id'] for w in windows}!={'train-006','train-007','train-008','eval-002'}:raise ValueError('Unexpected fixed window plan')
    rows=[json.loads(line) for line in (run_root/'predictions.jsonl').read_text().splitlines()]
    index={}
    for row in rows:
        key=(row['model_group'],row['window_id'],row['frame_index'])
        if key in index:raise ValueError('Duplicate group/window/frame prediction')
        index[key]=row
    if len(rows)!=6*4*120:raise ValueError('Expected exactly2880 frame output occurrences')
    for window in windows:
        if len(window['frames'])!=120:raise ValueError('Expected120 source frames per window')
        for frame in window['frames']:
            for group in GROUPS:frame_point(index[(group,window['window_id'],frame['frame_index'])],frame,window,group,data_root)
    metrics=metrics_rows(report,rows)
    output.parent.mkdir(parents=True,exist_ok=True)
    import tempfile
    staging=Path(tempfile.mkdtemp(prefix='.ball-tune-view-',dir=output.parent));staging.chmod(0o700)
    import shutil
    try:
        media=[];mosaics=[]
        for window in sorted(windows,key=lambda w:(w['split']!='train',w['window_id'])):
            wid=window['window_id'];times=[Fraction(f['source_pts'])*Fraction(f['source_time_base']) for f in window['frames']]
            if any(b<=a for a,b in zip(times,times[1:])):raise ValueError('Non-increasing source PTS')
            deltas=[b-a for a,b in zip(times,times[1:])]
            exact60=all(delta==Fraction(1,60) for delta in deltas)
            near30=all(delta in {Fraction(33333,1000000),Fraction(33334,1000000)} for delta in deltas)
            playback=('15帧/秒逐帧浏览；相邻源PTS严格1/60秒，为4倍慢放。' if exact60 else
                      '15帧/秒逐帧浏览；源PTS间隔33333/33334微秒，为约2倍慢放，不是实时测速展示。' if near30 else
                      '15帧/秒逐帧浏览，非实时测速展示；源PTS按原始时钟保留。')
            item={'window_id':wid,'split':window['split'],'pairs':{},'first_pts':window['frames'][0]['source_pts'],
                  'last_pts':window['frames'][-1]['source_pts'],'time_base':window['source_time_base'],
                  'playback_label':playback,'source_sha256':window['source_sha256'],'width':window['width'],'height':window['height']}
            for group in FITS:
                def images():
                    for frame in window['frames']:
                        fid=frame['frame_index']
                        yield make_pair(window,frame,index[(baseline(group),wid,fid)],index[(group,wid,fid)],group,data_root)
                video_name=f'{wid}--{group}.mp4'
                video=render.encode_video(staging/video_name,images(),15)
                still_dir=staging/'stills'/wid/group;still_dir.mkdir(parents=True,mode=0o700)
                stills=[]
                for fid in STILL_INDICES:
                    frame=window['frames'][fid]
                    image=make_pair(window,frame,index[(baseline(group),wid,fid)],index[(group,wid,fid)],group,data_root)
                    path=still_dir/f'frame-{fid:05d}.jpg';image.save(path,quality=94);path.chmod(0o600)
                    stills.append({'frame_index':fid,'image_path':str(path.relative_to(staging)),'sha256':sha(path),
                                   'source_pts':frame['source_pts'],'source_time_base':frame['source_time_base'],'original_image_sha256':frame['image_sha256']})
                item['pairs'][group]={'baseline':baseline(group),'video_path':video_name,**video,'stills':stills}
                print(f'{wid}/{group}: decoded {video["decoded_frame_count"]} frames; 8 fixed stills',flush=True)
            mosaic_dir=staging/'mosaics'/wid;mosaic_dir.mkdir(parents=True,mode=0o700)
            for fid in STILL_INDICES:
                path=mosaic_dir/f'frame-{fid:05d}-six-groups.jpg'
                record=audit_mosaic(window,window['frames'][fid],index,data_root,path)
                record['image_path']=str(path.relative_to(staging));mosaics.append(record)
            media.append(item)
        page_data={'fit_groups':list(FITS),'group_names':NAMES,'windows':media,'metrics':metrics}
        (staging/'index.html').write_text(html_page(page_data),encoding='utf-8');(staging/'index.html').chmod(0o600)
        for name,expected in input_hashes.items():
            if sha(run_root/name)!=expected:raise ValueError('Frozen run changed during rendering')
        if sha(data_manifest_path)!=data_manifest_hash:raise ValueError('Data manifest changed during rendering')
        summary={'schema_version':1,'renderer_sha256':sha(Path(__file__)),'data_manifest_sha256':data_manifest_hash,
                 'input_artifacts':input_hashes,'protocol_sha256':completion['protocol_sha256'],
                 'prediction_output_occurrences':len(rows),'source_image_count':480,'frame_outputs_are_independent':False,
                 'windows':media,'metrics':metrics,'videos':16,'static_pairs':4*4*len(STILL_INDICES),'audit_mosaics':mosaics,
                 'no_new_ball_speed':True,'human_validated':False,'accuracy':None,
                 'artifacts':{str(p.relative_to(staging)):{'sha256':sha(p),'bytes':p.stat().st_size} for p in staging.rglob('*') if p.is_file()}}
        write_json(staging/'view-summary.json',summary)
        output.mkdir(mode=0o700)
        for path in staging.iterdir():path.rename(output/path.name)
        staging.rmdir()
        return {'output':str(output),'videos':16,'actual_decoded_frame_occurrences':sum(p['decoded_frame_count'] for w in media for p in w['pairs'].values()),
                'static_pairs':summary['static_pairs'],'audit_mosaics':len(mosaics),'default_group':'full_decoder_head'}
    except Exception:
        shutil.rmtree(staging,ignore_errors=True);raise


def self_test():
    import unittest
    class Tests(unittest.TestCase):
        def test_fixed_same_view_baselines(self):
            self.assertEqual(baseline('full_decoder_head'),'original_full');self.assertEqual(baseline('roi_head_only'),'original_roi')
        def test_unknown_never_enters_visible_denominator(self):
            self.assertEqual(derived_metrics([{'label':{'status':'unknown','target_identity':'uncertain'}}])['visible_denominator'],0)
        def test_miss_and_equivalent_distance(self):
            row={'label':{'status':'visible','target_identity':'confirmed','x':960,'y':540},'candidate_xy_original':[990,540],
                 'crop_xyxy':[0,0,1920,1080],'width':1920,'height':1080}
            m=derived_metrics([row]);self.assertEqual(m['within10'],0);self.assertEqual(m['wrong20'],0)
            row['candidate_xy_original']=[991,540];self.assertEqual(derived_metrics([row])['wrong20'],1)
            row['candidate_xy_original']=None;m=derived_metrics([row]);self.assertEqual(m['visible_denominator'],1);self.assertEqual(m['no_output_count'],1)
        def test_full_roi_coordinate_binding_cannot_mix(self):
            root=Path('/tmp/ball-tune-test')
            frame={'source_pts':100,'source_time_base':'1/600','image_sha256':'a'*64,'width':1920,'height':1080,'image_path':'frame.jpg'}
            window={'window_id':'train-006','split':'train'}
            row={**frame,'image_path':str(root/'frame.jpg'),'window_id':'train-006','split':'train','model_group':'roi_head_only','view':'roi',
                 'threshold':.5,'threshold_operator':'>','candidate_xy_original':[300,300],'crop_xyxy':[0,0,1920,1080]}
            with self.assertRaises(ValueError):frame_point(row,frame,window,'roi_head_only',root)
            row['crop_xyxy']=[192,108,1728,972]
            self.assertEqual(frame_point(row,frame,window,'roi_head_only',root),[300,300])
            row['candidate_xy_original']=[10,10]
            with self.assertRaises(ValueError):frame_point(row,frame,window,'roi_head_only',root)
        def test_source_point_mapping_rejects_nan(self):
            with self.assertRaises(ValueError):render.finite_xy([float('nan'),1],(1920,1080))
        def test_ui_has_no_external_resources_and_fixed_default(self):
            page=html_page({'fit_groups':[],'group_names':{},'windows':[],'metrics':{'train':[],'eval':[]}})
            self.assertNotIn('https://',page);self.assertIn("selector.value='full_decoder_head'",page)
            self.assertEqual(STILL_INDICES,(0,10,64,72,80,88,95,110))
    r=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests));return 0 if r.wasSuccessful() else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--run',type=Path);parser.add_argument('--data',type=Path);parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    if args.self_test:return self_test()
    if not all((args.run,args.data,args.output)):parser.error('--run, --data, --output are required')
    try:print(json.dumps(build(args.run,args.data,args.output),ensure_ascii=False,indent=2));return 0
    except (OSError,ValueError,KeyError) as error:print('ball-tune-view: '+str(error),file=sys.stderr);return 2


if __name__=='__main__':sys.exit(main())
