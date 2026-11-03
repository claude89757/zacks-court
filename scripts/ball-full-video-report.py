#!/usr/bin/env python3
"""Summarize a completed whole-video run and make a private synchronized viewer.

Candidate availability is not detection accuracy. Software teacher anchors are
navigation references, never automatically accepted hit matches or truth.
"""
import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import html
import json
import math
from pathlib import Path
import statistics


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(4 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def seconds(frame):
    t = frame['time']
    return Fraction(t['sourcePTS'] * t['timeBaseNumerator'], t['timeBaseDenominator'])


def evaluate(run, teachers):
    summary = json.loads((run / 'summary.json').read_text())
    protocol = json.loads((run / 'input-protocol.json').read_text())
    if summary.get('complete') is not True:
        raise ValueError('Only a terminal, complete full-source run may be summarized')
    report = json.loads((run / 'report.json').read_text())
    frames = report['frames']
    assert len(frames) == summary['decodedFrames']
    assert report['sourceSHA256'] == summary['sourceSHA256']
    assert all(seconds(b) > seconds(a) for a, b in zip(frames, frames[1:]))
    states = Counter(f['state'] for f in frames)
    assert states == summary['frameStates']
    bins = {}
    compact = []
    runs, current, resets = [], 0, Counter()
    for f in frames:
        t, xy = float(seconds(f)), f['candidate']['originalXY'] if f['candidate'] else None
        compact.append([t, xy, f['state']])
        b = bins.setdefault(int(t // 10), {'start': int(t // 10) * 10, 'decoded': 0, 'tracked': 0, 'missing': 0, 'warmup': 0})
        b['decoded'] += 1
        if f['state'] in b:
            b[f['state']] += 1
        selection = f.get('selection')
        reset = selection.get('resetReason') if selection else None
        if reset:
            resets[reset] += 1
        if xy is not None:
            assert f['state'] == 'tracked' and 0 <= xy[0] < report['width'] and 0 <= xy[1] < report['height']
            if current and selection.get('linkedToPast') is not True:
                runs.append(current)
                current = 0
            current += 1
        elif current:
            runs.append(current)
            current = 0
    if current:
        runs.append(current)
    inference_states = states['tracked'] + states['missing']
    assert inference_states == summary['inferredFrames']
    reference = [x for x in teachers if x['source_sha256'] == report['sourceSHA256']]
    teacher_rows = [{'row': x['worksheet_row'], 'anchor': x['timing']['software_event_anchor_seconds'],
                     'exportTime': x['timing']['export_video_time_seconds'], 'speed': x['teacher_speed_kmh'],
                     'id': x['shot_id']} for x in reference]
    speed_outputs = sum(f.get('speedKilometersPerHour') is not None for f in frames)
    assert speed_outputs == summary['speedOutputs'] == 0
    for b in bins.values():
        count = b['tracked'] + b['missing']
        b['candidateAvailabilityPercent'] = 100 * b['tracked'] / count if count else None
    duration = report['requestedDuration']['value'] / report['requestedDuration']['timescale']
    stats = {'sourceName': Path(protocol['videoPath']).name, 'sourceDurationSeconds': duration, 'sourceNominalFPS': report['nominalFPS'], 'sourceSHA256': report['sourceSHA256'], 'sourceWidth': report['width'], 'sourceHeight': report['height'],
             'decodedFrames': len(frames), 'inferredFrames': inference_states, 'coreMLForwards': len(report['windows']),
             'frameStates': dict(states), 'candidateAvailabilityPercent': 100 * states['tracked'] / inference_states if inference_states else None,
             'candidateAvailabilityAllFramesPercent': 100 * states['tracked'] / len(frames),
             'consecutiveCandidateRuns': len(runs), 'longestConsecutiveCandidateRunFrames': max(runs, default=0),
             'medianConsecutiveCandidateRunFrames': statistics.median(runs) if runs else None,
             'consecutiveCandidateRunsAtLeast32Frames': sum(n >= 32 for n in runs), 'trackerResets': dict(resets),
             'teacherSoftwareRows': len(teacher_rows), 'automaticSpeedOutputs': speed_outputs,
             'correctHitMatchingPrecision': None, 'speedMAEKmh': None, 'speedMAPE': None,
             'human': False, 'formal': False, 'physicalAccuracyValidated': False, 'twentyPercentAcceptanceEligible': False,
             'qualificationReason': 'No independently verified hit matches, automatic shot-speed output, qualified camera or physical truth.',
             'bins10Seconds': list(bins.values()), 'wallSecondsExcludingSourceHashAndModelLoad': summary['wallSecondsExcludingSourceHashAndModelLoad'],
             'inferenceSeconds': summary['inferenceSeconds'], 'reportSHA256': sha(run / 'report.json')}
    return stats, compact, teacher_rows


HTML = r'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>整片独立模型回看</title><style>
:root{color-scheme:dark;font:16px system-ui;background:#101414;color:#edf1ed}*{box-sizing:border-box}body{margin:0 auto;max-width:1440px;padding:28px}h1{font-size:26px;margin:0 0 8px}h2{font-size:20px}p{line-height:1.6;color:#aebbb2}button,select{font:inherit;min-height:44px;background:#27322c;color:inherit;border:1px solid #536257;border-radius:8px;padding:8px 14px;cursor:pointer}a{color:#c5ed94}.metrics{display:flex;flex-wrap:wrap;gap:36px;margin:24px 0}.metric strong{font-size:25px;display:block}.metric small{color:#aebbb2}.video{position:relative;background:black}video{display:block;width:100%}#overlay{position:absolute;inset:0;width:100%;height:100%;pointer-events:none}.controls{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0;align-items:center}.time{font-variant-numeric:tabular-nums}#chart{width:100%;height:180px;cursor:pointer;background:#18201b}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:12px;border-bottom:1px solid #354138}th{position:sticky;top:0;background:#18201b}.rows{max-height:390px;overflow:auto}.muted{color:#aebbb2}.notice{border-left:3px solid #c5ed94;padding:8px 18px;background:#18201b}input[type=range]{width:100%;min-height:44px}
</style><h1>整片独立模型：实际效果与差距</h1><p id="source"></p>
<div class="notice">这是完整开发视频的模型候选回看。白圈是模型选中的球点候选，可能误认人物、球拍或背景；没有白圈表示该帧没有输出。<b>候选输出率不是正确率。</b> 当前独立链路没有自动触拍分段与可信相机，因此没有整片球速结果，不能计算与 S家 的整体误差。</div>
<div class="metrics" id="metrics"></div><div class="video"><video id="video" controls preload="metadata" src="__PROXY__"></video><canvas id="overlay"></canvas></div>
<div class="controls"><button id="prev">上一帧</button><button id="next">下一帧</button><label>播放速度 <select id="rate"><option value="0.25">0.25×</option><option value="0.5">0.5×</option><option value="1" selected>1×</option><option value="2">2×</option></select></label><button id="toggle">隐藏候选</button><span id="stamp" class="time"></span></div>
<h2>每10秒的候选输出率</h2><p>横轴：原视频时间（秒）；纵轴：有候选的帧 / 已推理帧（%）。点击图表跳转。来源：本次完整原生推理；不含预热帧，不代表网球识别准确率。</p><canvas id="chart"></canvas>
<h2>预声明的均匀抽查位置</h2><p>30秒起每60秒取一个位置，共12处；只用于人工查看，未自动算作正确标注。</p><div id="samples" class="controls"></div>
<h2>S家 App 导出参考行</h2><p>保留该来源全部参考行。点击时间可回看附近画面；软件锚点采用既有时间映射，可能与物理触拍错开，不表示已完成同拍匹配。独立球速缺失保持为空，不按0算误差。</p>
<div class="rows"><table><thead><tr><th>软件行</th><th>映射锚点</th><th>S家导出速度</th><th>独立自动球速</th></tr></thead><tbody id="rows"></tbody></table></div>
<p id="limits"></p><script>const D=__PAYLOAD__;
const v=document.getElementById('video'),c=document.getElementById('overlay'),ctx=c.getContext('2d');let visible=true;
const fmt=t=>`${Math.floor(t/60)}:${(t%60).toFixed(2).padStart(5,'0')}`;const S=D.stats;
document.getElementById('source').textContent=`${S.sourceName} · ${S.sourceWidth}×${S.sourceHeight} / ${S.sourceNominalFPS}fps · 全片${fmt(S.sourceDurationSeconds)} · ${S.decodedFrames.toLocaleString()}帧 · ${S.coreMLForwards.toLocaleString()}次Core ML · 已暴露开发素材`;
document.getElementById('metrics').innerHTML=[['完整解码',S.decodedFrames.toLocaleString(),'全部原始帧'],['候选输出率',S.candidateAvailabilityPercent===null?'—':S.candidateAvailabilityPercent.toFixed(1)+'%','含误检，非正确率'],['独立自动球速',String(S.automaticSpeedOutputs),'未确认触拍/相机'],['S家参考行',String(S.teacherSoftwareRows),'未经独立同拍复核']].map(x=>`<div class="metric"><small>${x[0]}</small><strong>${x[1]}</strong><small>${x[2]}</small></div>`).join('');
document.getElementById('limits').textContent=`模型纯推理累计 ${S.inferenceSeconds.toFixed(1)}秒；原生处理墙钟 ${S.wallSecondsExcludingSourceHashAndModelLoad.toFixed(1)}秒（不含文件校验和模型加载，Mac离线结果）。连续候选段 ${S.consecutiveCandidateRuns} 段，最长 ${S.longestConsecutiveCandidateRunFrames} 帧；这不代表已确认的完整飞行。正式验收0拍。`;
function nearest(t){let lo=0,hi=D.frames.length;while(lo<hi){let m=(lo+hi)>>1;if(D.frames[m][0]<t)lo=m+1;else hi=m;}let j=Math.min(lo,D.frames.length-1);if(j>0&&Math.abs(D.frames[j-1][0]-t)<Math.abs(D.frames[j][0]-t))j--;return j;}
function draw(time){const i=nearest(time),f=D.frames[i];c.width=S.sourceWidth;c.height=S.sourceHeight;ctx.clearRect(0,0,c.width,c.height);if(visible&&f[1]&&Math.abs(f[0]-time)<1/100){ctx.strokeStyle='white';ctx.lineWidth=4;ctx.beginPath();ctx.arc(f[1][0],f[1][1],17,0,2*Math.PI);ctx.stroke();ctx.fillStyle='black';ctx.fillRect(f[1][0]+22,f[1][1]-24,116,30);ctx.fillStyle='white';ctx.font='20px system-ui';ctx.fillText('球点候选',f[1][0]+27,f[1][1]-2);}document.getElementById('stamp').textContent=`原视频 ${fmt(time)} · 帧${i} · PTS ${f[0].toFixed(6)}s · ${f[2]}`;chart(time);}
function loop(_,metadata){draw(metadata.mediaTime);v.requestVideoFrameCallback(loop);}if(v.requestVideoFrameCallback)v.requestVideoFrameCallback(loop);else v.addEventListener('timeupdate',()=>draw(v.currentTime));v.addEventListener('seeked',()=>draw(v.currentTime));v.addEventListener('loadedmetadata',()=>draw(v.currentTime));
document.getElementById('prev').onclick=()=>{v.pause();v.currentTime=Math.max(0,D.frames[Math.max(0,nearest(v.currentTime)-1)][0]);};document.getElementById('next').onclick=()=>{v.pause();v.currentTime=D.frames[Math.min(D.frames.length-1,nearest(v.currentTime)+1)][0];};document.getElementById('rate').onchange=e=>v.playbackRate=Number(e.target.value);document.getElementById('toggle').onclick=e=>{visible=!visible;e.target.textContent=visible?'隐藏候选':'显示候选';draw(v.currentTime);};
function chart(time=0){const c=document.getElementById('chart'),r=c.getBoundingClientRect();c.width=r.width*devicePixelRatio;c.height=180*devicePixelRatio;const x=c.getContext('2d');x.scale(devicePixelRatio,devicePixelRatio);const left=40,top=15,w=r.width-55,h=130,duration=D.frames.at(-1)[0];x.fillStyle='#aebbb2';x.font='12px system-ui';for(const n of [0,50,100]){const y=top+h*(1-n/100);x.fillText(n+'%',2,y+4);x.strokeStyle='#354138';x.beginPath();x.moveTo(left,y);x.lineTo(left+w,y);x.stroke();}x.strokeStyle='#c5ed94';x.lineWidth=2;x.beginPath();let pen=false;for(const b of S.bins10Seconds){if(b.candidateAvailabilityPercent===null){pen=false;continue;}const px=left+w*(b.start+5)/duration,py=top+h*(1-b.candidateAvailabilityPercent/100);if(pen)x.lineTo(px,py);else x.moveTo(px,py);pen=true;}x.stroke();x.fillStyle='#aebbb2';for(let t=0;t<=duration;t+=120)x.fillText(t+'s',left+w*t/duration,170);x.strokeStyle='white';x.beginPath();x.moveTo(left+w*time/duration,top);x.lineTo(left+w*time/duration,top+h);x.stroke();}
document.getElementById('chart').onclick=e=>{let r=e.currentTarget.getBoundingClientRect();v.currentTime=Math.max(0,Math.min(1,(e.clientX-r.left-40)/(r.width-55)))*D.frames.at(-1)[0];};window.addEventListener('resize',()=>{draw(v.currentTime);});
for(const t of D.sampleTimes){let b=document.createElement('button');b.textContent=fmt(t);b.onclick=()=>{v.pause();v.currentTime=t;};document.getElementById('samples').appendChild(b);}for(const r of D.teachers){let tr=document.createElement('tr');let speed=typeof r.speed==='number'?r.speed.toFixed(1)+' km/h':'—';tr.innerHTML=`<td>${r.row}</td><td><button>${fmt(r.anchor)}</button></td><td>${speed}</td><td>—（缺事件与标定）</td>`;tr.querySelector('button').onclick=()=>{v.pause();v.currentTime=r.anchor;};document.getElementById('rows').appendChild(tr);}chart();
</script></html>'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run', type=Path, required=True)
    p.add_argument('--teachers', type=Path, required=True)
    p.add_argument('--proxy-relative-url', required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    if args.output.exists():
        raise ValueError('Output exists; choose a new directory')
    teachers = [json.loads(x) for x in args.teachers.read_text().splitlines() if x.strip()]
    stats, compact, teacher_rows = evaluate(args.run, teachers)
    args.output.mkdir(mode=0o700)
    (args.output / 'metrics.json').write_text(json.dumps(stats, ensure_ascii=False, indent=2) + '\n')
    payload = {'stats': stats, 'frames': compact, 'teachers': teacher_rows, 'sampleTimes': list(range(30,math.ceil(stats['sourceDurationSeconds']),60))}
    page = HTML.replace('__PROXY__', html.escape(args.proxy_relative_url, quote=True)).replace('__PAYLOAD__', json.dumps(payload, ensure_ascii=False, separators=(',',':')).replace('</',r'<\/'))
    (args.output / 'index.html').write_text(page)
    print(json.dumps({k:v for k,v in stats.items() if k != 'bins10Seconds'}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
