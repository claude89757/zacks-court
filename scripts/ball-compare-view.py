#!/usr/bin/env python3
"""Render frozen ball-model comparisons into private, local review media.

Requires Pillow and local ffmpeg/ffprobe. This renderer does not infer or train.
Every overlay is bound to a recorded image hash and decoded source PTS.
"""
import argparse
from collections import defaultdict
from fractions import Fraction
from functools import lru_cache
import hashlib
import html
import json
import math
from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

CYAN = '#39d9ec'
ORANGE = '#ffab52'
FONT_PATH = '/System/Library/Fonts/Supplemental/Arial.ttf'


@lru_cache(maxsize=16)
def font(size):
    return ImageFont.truetype(FONT_PATH, size)


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for data in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(data)
    return result.hexdigest()


def write_json(path, value):
    with path.open('x', encoding='utf-8') as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write('\n')
    path.chmod(0o600)


def open_verified(path, expected_sha, size):
    if sha(path) != expected_sha:
        raise ValueError('Original image hash mismatch')
    with Image.open(path) as source:
        if source.size != tuple(size):
            raise ValueError('Original image dimensions mismatch')
        return source.convert('RGB')


def finite_xy(value, size):
    if value is None:
        return None
    if not isinstance(value, list) or len(value) != 2:
        raise ValueError('Invalid model candidate point')
    x, y = value
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in value):
        raise ValueError('Non-finite model candidate point')
    if not (0 <= x < size[0] and 0 <= y < size[1]):
        raise ValueError('Model candidate outside original image')
    return value


def overlay(source, point, color, text, output_size=(960, 540), crop=None):
    if crop is None:
        image = source.resize(output_size, Image.Resampling.LANCZOS)
        origin = (0, 0)
        scale = (output_size[0] / source.width, output_size[1] / source.height)
    else:
        # Keep one source image pixel equal to one crop image pixel.
        image = source.crop(crop)
        origin, scale = crop[:2], (1, 1)
    draw = ImageDraw.Draw(image)
    if point is not None:
        x, y = (point[0] - origin[0])*scale[0], (point[1] - origin[1])*scale[1]
        draw.ellipse((x-11,y-11,x+11,y+11),outline=color,width=3)
        draw.line((x-17,y,x-5,y),fill=color,width=2)
        draw.line((x+5,y,x+17,y),fill=color,width=2)
        draw.line((x,y-17,x,y-5),fill=color,width=2)
        draw.line((x,y+5,x,y+17),fill=color,width=2)
    draw.rectangle((0,0,image.width,34),fill='#101820')
    draw.text((10,6),text,fill=color,font=font(19))
    if point is None:
        draw.rectangle((8,44,min(image.width-8,348),78),fill='#101820')
        draw.text((14,50),'NO OUTPUT (threshold > 0.5)',fill='#ffffff',font=font(18))
    return image


def pair_image(source, base_point, adapted_point, frame_text, details, crop=None):
    left = overlay(source,base_point,CYAN,'BASE / original',crop=crop)
    right = overlay(source,adapted_point,ORANGE,'ADAPTED / 8 steps',crop=crop)
    result = Image.new('RGB',(left.width+right.width,left.height+82),'#101820')
    result.paste(left,(0,40));result.paste(right,(left.width,40))
    draw=ImageDraw.Draw(result)
    draw.text((12,9),frame_text,fill='#ffffff',font=font(20))
    draw.text((12,left.height+50),details,fill='#c6d1dc',font=font(17))
    return result


def encode_video(path, images, fps):
    first=next(images)
    command=['ffmpeg','-hide_banner','-loglevel','error','-nostdin','-f','rawvideo','-pixel_format','rgb24',
             '-video_size',f'{first.width}x{first.height}','-framerate',str(fps),'-i','pipe:0',
             '-an','-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(path)]
    process=subprocess.Popen(command,stdin=subprocess.PIPE,stderr=subprocess.PIPE)
    count=0
    try:
        process.stdin.write(first.tobytes());count=1
        for image in images:
            if image.size != first.size: raise ValueError('Video frame dimensions changed')
            process.stdin.write(image.tobytes());count+=1
        process.stdin.close()
        stderr=process.stderr.read().decode()
        if process.wait()!=0:raise ValueError('ffmpeg encode failed: '+stderr[-1200:])
    except Exception:
        process.kill();process.wait();raise
    path.chmod(0o600)
    result=subprocess.run(['ffprobe','-v','error','-select_streams','v:0','-count_frames',
                           '-show_entries','stream=nb_read_frames,width,height,duration,avg_frame_rate',
                           '-of','json',str(path)],check=True,capture_output=True,text=True)
    stream=json.loads(result.stdout)['streams'][0]
    if int(stream['nb_read_frames'])!=count:raise ValueError('Decoded video frame count mismatch')
    return {'encoded_frame_count':count,'decoded_frame_count':int(stream['nb_read_frames']),
            'width':stream['width'],'height':stream['height'],'duration_seconds':float(stream['duration']),
            'presentation_fps':fps,'sha256':sha(path)}


def pts_value(row):
    exact = Fraction(row['source_pts']) * Fraction(row['source_time_base'])
    if exact != Fraction(row['source_pts_seconds_rational']):
        raise ValueError('Source PTS rational binding mismatch')
    return exact


def checked_row(row, image_root):
    path = Path(row['image_path']).resolve()
    expected = (image_root / row['sample_id'] / f"frame-{row['frame_index']:05d}.jpg").resolve()
    if path != expected:
        raise ValueError('Unexpected comparison image source')
    pts_value(row)
    size=(row['width'],row['height'])
    for model in ('base','adapted'):
        data=row[model]
        if data['threshold']!=0.5 or data['operator']!='>':
            raise ValueError('Comparison threshold differs from frozen >0.5 rule')
        point=finite_xy(data['candidate_xy_original'],size)
        if data['visible'] != (point is not None):
            raise ValueError('Visibility differs from candidate presence')
    return open_verified(path,row['image_sha256'],size)


def presentation(row, image_root, mode):
    source=checked_row(row,image_root)
    t=pts_value(row)
    label=f"{row['sample_id']} | frame {row['frame_index']:03d} | source PTS {row['source_pts']} x {row['source_time_base']} = {float(t):.6f}s"
    detail=f"{mode} | ball localization only; NO new ball-speed estimate | peak {row['base']['peak']:.5f} / {row['adapted']['peak']:.5f}"
    return pair_image(source,row['base']['candidate_xy_original'],row['adapted']['candidate_xy_original'],label,detail)


def crop_box(point,size):
    width,height=min(384,size[0]),min(320,size[1])
    left=max(0,min(size[0]-width,round(point[0])-width//2))
    top=max(0,min(size[1]-height,round(point[1])-height//2))
    return (left,top,left+width,top+height)


def numeric(value):
    if value is None:return '—'
    if isinstance(value,bool):return '是' if value else '否'
    if isinstance(value,float):return f'{value:.3f}'
    return html.escape(str(value))


def metrics_table(groups):
    rows=[]
    for group_name,group in groups:
        for model in ('base','adapted'):
            data=group[model]
            rows.append('<tr>'+''.join('<td>'+numeric(value)+'</td>' for value in (
                group_name,'原始' if model=='base' else '微调8步',group['n'],data['outputs'],
                data['within5'],data['within10'],data['within20'],data['median'],data['p90']))+'</tr>')
    return '<div class="scroll"><table><thead><tr><th>比较点</th><th>模型</th><th>分母</th><th>有输出</th><th>≤5px</th><th>≤10px</th><th>≤20px</th><th>距离中位数</th><th>P90</th></tr></thead><tbody>'+''.join(rows)+'</tbody></table></div>'


def html_page(videos,stills,groups,limitations):
    media=''
    for sample,info in videos.items():
        media+=f'<section><h2>{sample}</h2><p>{html.escape(info["playback_label"])}。原始青色在左，微调橙色在右；无输出处明确标记。</p><video controls preload="metadata" playsinline src="{sample}.mp4"></video><p class="small">已实际解码核验 {info["decoded_frame_count"]} 帧，输出 {info["duration_seconds"]:.2f} 秒。源 PTS：{info["source_first_pts"]} → {info["source_last_pts"]} × {info["source_time_base"]}。</p><details><summary>查看固定帧和原像素裁区</summary>'
        for item in stills:
            if item['sample_id']!=sample:continue
            media+=f'<article><h3>帧 {item["frame_index"]} · prepared_sequence</h3><a href="{item["full_image"]}"><img loading="lazy" src="{item["full_image"]}" alt="原始与微调全场定位对照"></a>'
            if item.get('crop_image'):
                media+=f'<p class="small">裁区按该帧已存在的 Agent 候选居中；该候选不是人工真值。每个裁区保持一源图像素对应一图片像素，点击可看原尺寸。默认没有叠加 Agent 标签点。</p><a href="{item["crop_image"]}"><img loading="lazy" class="crop" src="{item["crop_image"]}" alt="原像素区域的模型预测对照"></a>'
            else:media+='<p class="small">本帧没有可用的已标候选，保留全场对照；未创建虚构裁区或球心。</p>'
            media+='</article>'
        media+='</details></section>'
    limits=''.join('<li>'+html.escape(x)+'</li>' for x in limitations)
    return '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>球定位：原始与8步微调对照</title><style>body{margin:0;background:#10151d;color:#edf1f5;font:16px/1.65 system-ui,-apple-system,sans-serif}main{max-width:1240px;margin:auto;padding:28px 20px}h1{font-size:30px;line-height:1.3}h2{font-size:23px}section{margin:30px 0;padding:22px;background:#1a2430;border-radius:12px}video,img{display:block;width:100%;height:auto;background:#080d13;border-radius:6px}.crop{max-width:768px}a{color:#9ddaff}.small{font-size:14px;color:#bbc8d6}.notice{border-left:4px solid #ffb15f;padding:12px 18px;background:#202c39}.legend span{display:inline-block;margin-right:22px}.base{color:#39d9ec}.adapted{color:#ffab52}table{border-collapse:collapse;width:100%;font-size:14px}th,td{padding:9px;text-align:right;border-bottom:1px solid #455567;white-space:nowrap}th:first-child,td:first-child{text-align:left}.scroll{overflow:auto}summary{cursor:pointer;min-height:44px;padding:10px 0}article{margin:24px 0}li{margin:8px 0}</style><main><h1>球定位模块：原始与微调8步的实际输出</h1><p class="notice">这里只比较球心定位，<strong>没有产生新的球速数值</strong>。圆圈是模型预测；Agent 候选不是人工真值。这是探索性对照，不能据此宣称网球精度或泛化能力。</p><div class="legend"><span class="base">青色：原始模型</span><span class="adapted">橙色：微调8步</span><span>同帧、同图、固定阈值 &gt;0.5</span></div>'''+media+'''<section><h2>相对 Agent 候选的距离</h2><p>分母为可比较的45点；8点参与过微调，37点未参与该8步的监督。<strong>未训37点与训练共享来源、窗口或背景，不是独立测试集。</strong>无输出按未命中计入≤5/10/20像素分母；距离中位数/P90仅统计有输出项，数量见“有输出”。</p>'''+metrics_table(groups)+'''</section><section><h2>阅读边界</h2><ul>'''+limits+'''</ul><p class="small">本页全部素材、模型输出和视频位于本机，没有外部服务请求。原始模型使用羽毛球预训练权重；背景包含未来帧，仅适用于离线展示。</p><a href="render-summary.json">查看生成与解码核验摘要</a></section></main></html>'''


def build(comparison, image_root, output):
    comparison,image_root,output=comparison.resolve(),image_root.resolve(),output.absolute()
    if output.exists() or output.is_symlink():raise ValueError('Output exists; choose a new directory')
    receipt=json.loads((comparison/'artifact-receipt.json').read_text())
    names={'protocol.json':'protocol_sha256','summary.json':'summary_sha256',
           'frames.jsonl':'frames_sha256','label-pairs.json':'label_pairs_sha256'}
    inputs={name:sha(comparison/name) for name in names}
    for name,key in names.items():
        if receipt.get(key)!=inputs[name]:raise ValueError('Frozen comparison artifact hash mismatch: '+name)
    protocol=json.loads((comparison/'protocol.json').read_text())
    summary=json.loads((comparison/'summary.json').read_text())
    points=json.loads((comparison/'label-pairs.json').read_text())['points']
    frames=[json.loads(line) for line in (comparison/'frames.jsonl').read_text().splitlines()]
    if protocol['threshold']!=0.5 or protocol['threshold_operator']!='>':raise ValueError('Unexpected frozen protocol')
    if len(points)!=45:raise ValueError('Expected 45 comparable agent points')
    groups=[]
    for title,key,n in [('总体45点','all_45',45),('已训8点','trained_supervised_8',8),('未训37点（非独立）','untrained_points_37',37)]:
        raw=summary['point_groups'][key];group={'n':n}
        for model in ('base','adapted'):
            data=raw[model]
            if data['denominator_all_comparable_points']!=n:raise ValueError('Metric denominator mismatch')
            group[model]={'outputs':data['output_count'],'within5':data['within_px_counts']['5'],
                          'within10':data['within_px_counts']['10'],'within20':data['within_px_counts']['20'],
                          'median':data['conditional_distance_median_px'],'p90':data['conditional_distance_p90_px']}
        groups.append((title,group))
    prepared={}
    full=defaultdict(list)
    for row in frames:
        key=(row['sample_id'],row['frame_index'])
        if row['scope']=='prepared_sequence':
            if key in prepared:raise ValueError('Ambiguous prepared frame identity')
            prepared[key]=row
        elif row['scope']=='full_window':full[row['sample_id']].append(row)
        else:raise ValueError('Unexpected inference scope')
    point_map={(p['sample_id'],p['frame_index']):p for p in points}
    if len(point_map)!=len(points):raise ValueError('Duplicate agent point identity')
    output.mkdir(parents=True,mode=0o700)
    (output/'stills').mkdir(mode=0o700)
    videos,stills={},[]
    for sample in ('sample-006','sample-007','sample-008'):
        rows=sorted(full[sample],key=lambda r:r['frame_index'])
        if [r['frame_index'] for r in rows]!=list(range(120)):raise ValueError('Full window must contain exactly frames 0..119')
        timestamps=[pts_value(row) for row in rows]
        intervals=[b-a for a,b in zip(timestamps,timestamps[1:])]
        if any(value<=0 for value in intervals):raise ValueError('Full window source PTS not increasing')
        exact60=all(delta==Fraction(1,60) for delta in intervals)
        mode='4x slow review (source intervals exactly 1/60s)' if exact60 else '15 fps frame review; NOT real-time speed display'
        info=encode_video(output/f'{sample}.mp4',(presentation(row,image_root,mode) for row in rows),15)
        info.update(source_first_pts=rows[0]['source_pts'],source_last_pts=rows[-1]['source_pts'],
                    source_time_base=rows[0]['source_time_base'],source_interval_values=sorted({str(value) for value in intervals}),
                    source_intervals_exactly_1_60=exact60,
                    playback_label='4倍慢放（已核验全部相邻源PTS间隔恰为1/60秒）' if exact60 else '15帧/秒逐帧浏览，非实时测速展示')
        videos[sample]=info
        print(f'{sample}: encoded/decoded {info["decoded_frame_count"]} frames; source intervals {info["source_interval_values"]}',flush=True)
        for index in (10,50,70,90,110):
            row=prepared[(sample,index)]
            source=checked_row(row,image_root)
            label=f'{sample} | prepared frame {index:03d} | sequence {row["sequence_start"]}+{row["output_offset"]} | PTS {row["source_pts"]} x {row["source_time_base"]}'
            point_pair=point_map.get((sample,index))
            crop=None
            if point_pair:
                candidate=point_pair['label']
                if candidate['status']=='visible' and candidate['target_identity']=='confirmed':
                    if candidate['reviewer_kind']!='agent':raise ValueError('Expected explicitly agent-labelled crop center')
                    if candidate['image_sha256']!=row['image_sha256'] or candidate['source_pts']!=row['source_pts']:
                        raise ValueError('Agent crop location frame binding mismatch')
                    crop=crop_box(finite_xy([candidate['x'],candidate['y']],source.size),source.size)
            full_source=source.copy()
            if crop:
                ImageDraw.Draw(full_source).rectangle(crop,outline='#ffffff',width=2)
            name=f'stills/{sample}-frame-{index:05d}-full.jpg'
            pair_image(full_source,row['base']['candidate_xy_original'],row['adapted']['candidate_xy_original'],label,
                       'White box = crop region around AGENT candidate, NOT truth; no agent point overlay').save(output/name,quality=94)
            (output/name).chmod(0o600)
            item={'sample_id':sample,'frame_index':index,'scope':'prepared_sequence','full_image':name,
                  'image_sha256':row['image_sha256'],'source_pts':row['source_pts'],
                  'source_time_base':row['source_time_base'],'crop_box_original':crop,'agent_point_shown':False}
            if crop:
                crop_name=f'stills/{sample}-frame-{index:05d}-crop.jpg'
                pair_image(source,row['base']['candidate_xy_original'],row['adapted']['candidate_xy_original'],label,
                           '1:1 source pixels; crop centered on AGENT candidate (NOT truth)',crop=crop).save(output/crop_name,quality=96)
                (output/crop_name).chmod(0o600);item['crop_image']=crop_name
            stills.append(item)
    for name,expected in inputs.items():
        if sha(comparison/name)!=expected:raise ValueError('Comparison changed during rendering')
    limits=['没有新球速，只显示球定位候选；未执行新的训练或阈值调整。',
            '本次840次帧输出的候选位置和有无输出均未变化；不同scope会重复原始帧，不能看作840张独立图片。热图的极小变化不等于定位改善。',
            'prepared_sequence固定帧与full_window使用不同序列上下文，不能混作同一组推理结果。',
            'Agent标注是工程候选，不是人工真值；45点不覆盖全部真实球与无球帧，不能计算真实精确率或误报率。',
            '8点参与过微调；其余37点共享已见来源、窗口或背景，没有建立独立测试集。',
            '背景由同窗口48帧中位数构成，使用未来帧；这里只是离线观察，不证明实时性能。',
            '原始模型为羽毛球预训练，不能以本页结果宣称网球检测精度。']
    page=html_page(videos,stills,groups,limits)
    page=page.replace('<div class="legend">','<p><strong>这次8步微调没有改变这840次帧输出的候选坐标或有无输出；当前看不到定位改进。</strong>下面展示三段完整窗口及固定帧对照。</p><div class="legend">')
    (output/'index.html').write_text(page,encoding='utf-8');(output/'index.html').chmod(0o600)
    artifacts={str(path.relative_to(output)):{'sha256':sha(path),'bytes':path.stat().st_size}
               for path in output.rglob('*') if path.is_file()}
    report={'schema_version':1,'renderer_sha256':sha(Path(__file__)),'input_artifacts':inputs,
            'video_scope':'full_window','static_scope':'prepared_sequence','videos':videos,'stills':stills,
            'frame_output_occurrences':len(frames),'frame_outputs_are_independent':False,
            'metric_groups':groups,'static_full_images':len(stills),'static_crops':sum('crop_image' in x for x in stills),
            'no_ball_speed_generated':True,'agent_label_points_shown':False,'human_validated':False,
            'all_840_candidate_presence_or_position_changes':sum(r['base']['candidate_xy_original']!=r['adapted']['candidate_xy_original'] for r in frames),
            'artifacts':artifacts,'limits':limits}
    write_json(output/'render-summary.json',report)
    return {'output':str(output),'videos':{k:{n:v[n] for n in ('decoded_frame_count','duration_seconds','source_intervals_exactly_1_60')} for k,v in videos.items()},
            'static_full_images':len(stills),'static_crops':report['static_crops'],'candidate_changes':report['all_840_candidate_presence_or_position_changes']}



def full_window_stills(comparison,image_root,output):
    comparison,image_root,output=comparison.resolve(),image_root.resolve(),output.absolute()
    if output.exists():raise ValueError('Output exists; choose a new directory')
    receipt=json.loads((comparison/'artifact-receipt.json').read_text())
    for filename,key in [('frames.jsonl','frames_sha256'),('label-pairs.json','label_pairs_sha256')]:
        if sha(comparison/filename)!=receipt[key]:raise ValueError('Frozen input mismatch')
    frames=[json.loads(line) for line in (comparison/'frames.jsonl').read_text().splitlines()]
    rows={(r['sample_id'],r['frame_index']):r for r in frames if r['scope']=='full_window'}
    points=json.loads((comparison/'label-pairs.json').read_text())['points']
    points={(r['sample_id'],r['frame_index']):r for r in points}
    output.mkdir(parents=True,mode=0o700)
    records=[]
    for sample in ('sample-006','sample-007','sample-008'):
        for index in (10,50,70,90,110):
            row=rows[(sample,index)];source=checked_row(row,image_root)
            label=f'{sample} | FULL_WINDOW frame {index:03d} | PTS {row["source_pts"]} x {row["source_time_base"]}'
            crop=None;point=points.get((sample,index))
            if point:
                agent=point['label']
                if agent['status']=='visible' and agent['target_identity']=='confirmed':
                    if agent['reviewer_kind']!='agent' or agent['image_sha256']!=row['image_sha256']:raise ValueError('Agent frame mismatch')
                    crop=crop_box(finite_xy([agent['x'],agent['y']],source.size),source.size)
            field=source.copy()
            if crop:ImageDraw.Draw(field).rectangle(crop,outline='white',width=2)
            name=f'{sample}-frame-{index:05d}-full-window-full.jpg'
            pair_image(field,row['base']['candidate_xy_original'],row['adapted']['candidate_xy_original'],label,'FULL_WINDOW context; white box = agent-centered region, NOT truth').save(output/name,quality=94)
            (output/name).chmod(0o600)
            item={'scope':'full_window','sample_id':sample,'frame_index':index,'full_image':name,
                  'base_candidate':row['base']['candidate_xy_original'],'adapted_candidate':row['adapted']['candidate_xy_original'],
                  'source_pts':row['source_pts'],'source_time_base':row['source_time_base'],'image_sha256':row['image_sha256']}
            if crop:
                crop_name=f'{sample}-frame-{index:05d}-full-window-crop.jpg'
                pair_image(source,row['base']['candidate_xy_original'],row['adapted']['candidate_xy_original'],label,'FULL_WINDOW | 1:1 source pixels; AGENT-centered region, NOT truth',crop=crop).save(output/crop_name,quality=96)
                (output/crop_name).chmod(0o600);item['crop_image']=crop_name
            records.append(item)
    report={'renderer_sha256':sha(Path(__file__)),'scope':'full_window','full_images':15,'crops':sum('crop_image' in r for r in records),'frames':records,
            'frames_sha256':receipt['frames_sha256'],'agent_points_shown':False,
            'artifacts':{path.name:sha(path) for path in output.iterdir() if path.is_file()}}
    write_json(output/'full-window-stills-summary.json',report)
    return {'output':str(output),'scope':'full_window','full_images':15,'crops':report['crops']}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--full-window-stills-only',action='store_true')
    parser.add_argument('--comparison',required=True,type=Path)
    parser.add_argument('--image-root',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    try:
        operation=full_window_stills if args.full_window_stills_only else build
        print(json.dumps(operation(args.comparison,args.image_root,args.output),ensure_ascii=False,indent=2));return 0
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
        print('ball-compare-view: '+str(error),file=sys.stderr);return 2


if __name__=='__main__':sys.exit(main())
