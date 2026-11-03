#!/usr/bin/env python3
"""Build a private, offline, blinded frame review package (never labels or trains).

  python3 scripts/speed-review.py build --dataset DATASET --output NEW_DIR --count 40
  python3 scripts/speed-review.py --self-test

Open NEW_DIR/index.html directly, or serve NEW_DIR with a local HTTP server.
Reviewers must not open audit/: it contains source/worksheet/anchor mappings.
FFmpeg showinfo preserves decoded presentation timestamps, independently checked
against ffprobe decoded frames. No packet ordinal is used as a frame identity.
"""

import argparse
from collections import defaultdict
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


POLICY = "review-v1:one-per-rally-then-hash-fill"
PTS_SEMANTICS = "FFmpeg decoded presentation PTS in the original video stream time_base, with edit-list handling; not AVFoundation PTS or packet order"


class ReviewError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def write_json(path, value):
    with open(path, "x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")


def number(value, label):
    if isinstance(value, bool):
        raise ReviewError(f"Invalid {label}")
    try:
        result = float(value)
    except (ValueError, TypeError) as error:
        raise ReviewError(f"Invalid {label}") from error
    if not math.isfinite(result):
        raise ReviewError(f"Nonfinite {label}")
    return result


def run(command, timeout=180):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        raise ReviewError(f"Unable to run {command[0]}: {error}") from error
    if result.returncode:
        raise ReviewError(f"{command[0]} failed: {result.stderr[-2000:]}")
    return result


def projected_shots(rows, sources):
    """Whitelist before selection: never inspect speed, coordinates or classes."""
    projected, seen = [], set()
    for row in rows:
        key = row.get("shot_id")
        if not isinstance(key, str) or not key or key in seen:
            raise ReviewError("Missing or duplicate shot_id")
        seen.add(key)
        source_sha = row.get("source_sha256")
        if source_sha not in sources:
            raise ReviewError("Shot references an unknown source")
        source = sources[source_sha]
        if row.get("group_id") != source.get("group_id"):
            raise ReviewError("Shot/source family mismatch")
        context = row.get("context", {})
        context = {k: context.get(k) for k in ("set", "game", "point")}
        if any(v is None or isinstance(v, (list, dict, bool)) for v in context.values()):
            raise ReviewError("Every shot requires scalar set/game/point context")
        anchor = number(row.get("timing", {}).get("software_event_anchor_seconds"), "software anchor")
        video = source["video"]
        duration = number(video["duration_seconds"], "duration")
        origin = number(video["start_time_seconds"], "video start")
        if not 0 <= anchor < duration:
            raise ReviewError("Software anchor outside source video")
        # Interpret the serialized input numbers exactly; do not let binary
        # float subtraction decide which side of a presentation tick is kept.
        anchor_q = Fraction(str(row["timing"]["software_event_anchor_seconds"]))
        origin_q = Fraction(str(video["start_time_seconds"]))
        duration_q = Fraction(str(video["duration_seconds"]))
        start_q = origin_q + max(Fraction(0), anchor_q - Fraction(3, 5))
        end_q = origin_q + min(duration_q, anchor_q + Fraction(7, 5))
        projected.append({"shot_id": key, "source_sha256": source_sha,
                          "source_family": row["group_id"], "context": context,
                          "worksheet_row": row.get("worksheet_row"),
                          "software_anchor_elapsed_seconds": anchor,
                          "window_start_pts_seconds": float(start_q),
                          "window_end_pts_seconds": float(end_q),
                          "window_start_pts_seconds_rational": str(start_q),
                          "window_end_pts_seconds_rational": str(end_q)})
    return projected


def selection_key(shot):
    return digest([POLICY, shot["source_sha256"], shot["shot_id"]])


def rally_key(shot):
    return canonical([shot["source_sha256"], shot["source_family"], shot["context"]])


def select_shots(shots, count):
    if not 1 <= count <= len(shots):
        raise ReviewError(f"count must be between 1 and {len(shots)}")
    groups = defaultdict(list)
    for shot in shots:
        groups[rally_key(shot)].append(shot)
    representatives = [min(group, key=selection_key) for group in groups.values()]
    representatives.sort(key=selection_key)
    chosen = representatives[:count]
    used = {s["shot_id"] for s in chosen}
    if len(chosen) < count:
        chosen += sorted((s for s in shots if s["shot_id"] not in used), key=selection_key)[:count-len(chosen)]
    # Stable presentation order independent of labels and source-time adjacency.
    chosen.sort(key=selection_key)
    return chosen, len(groups)


def overlap_groups(shots):
    """Connected components of selected windows, including transitive overlaps."""
    mapping, component = {}, 0
    by_source = defaultdict(list)
    for shot in shots:
        by_source[shot["source_sha256"]].append(shot)
    for source in sorted(by_source):
        end = -math.inf
        for shot in sorted(by_source[source], key=lambda s: (s["window_start_pts_seconds"], s["shot_id"])):
            start = shot["window_start_pts_seconds"]
            if start >= end:
                component += 1
                end = shot["window_end_pts_seconds"]
            else:
                end = max(end, shot["window_end_pts_seconds"])
            mapping[shot["shot_id"]] = f"overlap-{component:03d}"
    return mapping


def parse_showinfo(stderr, time_base):
    bases = re.findall(r"config in time_base:\s*(\d+/\d+)", stderr)
    if not bases or any(Fraction(base) != Fraction(time_base) for base in bases):
        raise ReviewError("showinfo time_base does not match source stream")
    matches = re.findall(r"\bn:\s*(\d+)\s+pts:\s*(-?\d+)\s+pts_time:\s*(\S+).*?\bs:(\d+)x(\d+)", stderr)
    frames = []
    for index, (n, pts, printed_seconds, width, height) in enumerate(matches):
        if int(n) != index:
            raise ReviewError("showinfo frame indices are not contiguous")
        pts = int(pts)
        if frames and pts <= frames[-1]["source_pts"]:
            raise ReviewError("Non-increasing decoded frame PTS; manual source investigation required")
        exact = Fraction(pts) * Fraction(time_base)
        frames.append({"filename": f"frame-{index:05d}.jpg", "window_frame_index": index,
                       "source_pts": pts, "source_time_base": time_base,
                       "source_pts_seconds": float(exact),
                       "source_pts_seconds_rational": f"{exact.numerator}/{exact.denominator}",
                       "width": int(width), "height": int(height)})
    if not frames:
        raise ReviewError("No decoded frames found in selected window")
    return frames


def probe_source(path, expected, ffprobe):
    payload = json.loads(run([ffprobe, "-v", "error", "-show_streams", "-of", "json", str(path)]).stdout)
    stream = next((s for s in payload["streams"] if s["index"] == expected["stream_index"]), None)
    if not stream or stream.get("codec_type") != "video":
        raise ReviewError("Configured video stream missing")
    for field in ("width", "height", "time_base"):
        if stream.get(field) != expected.get(field):
            raise ReviewError(f"Video metadata mismatch: {field}")
    if abs(number(stream.get("start_time", 0), "start") - number(expected["start_time_seconds"], "start")) > 1e-6:
        raise ReviewError("Source video start_time changed")
    return stream


def window_ticks(shot, time_base):
    """Exact half-open seconds interval maps to [ceil(start/tb), ceil(end/tb))."""
    base = Fraction(time_base)
    if base <= 0:
        raise ReviewError("Invalid source time_base")
    start = Fraction(shot.get("window_start_pts_seconds_rational", str(shot["window_start_pts_seconds"])))
    end = Fraction(shot.get("window_end_pts_seconds_rational", str(shot["window_end_pts_seconds"])))
    lower, upper = math.ceil(start / base), math.ceil(end / base)
    if lower >= upper:
        raise ReviewError("Window contains no presentation ticks")
    return lower, upper


def extract_frames(source, shot, directory, audit, ffmpeg, ffprobe):
    directory.mkdir(mode=0o700, parents=True)
    path, video = source["source_path"], source["video"]
    lo, hi = window_ticks(shot, video["time_base"])
    base = Fraction(video["time_base"])
    # Seeking only bounds decoding work. Seek at least 250 ms before the exact
    # lower tick (unless at source start) so the demuxer's microsecond rounding
    # cannot discard an eligible boundary frame. Only integer trim decides
    # membership; no epsilon, fps resampling or packet index is involved.
    origin = Fraction(str(video["start_time_seconds"]))
    seek_q = max(origin, lo * base - Fraction(1, 4))
    seek_us = math.floor(seek_q * 1_000_000)
    seek = seek_us / 1_000_000
    read_until = float(hi * base + Fraction(1, 2))
    filters = f"trim=start_pts={lo}:end_pts={hi},scale=w='min(1280,iw)':h=-2,showinfo"
    command = [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "info", "-n",
               "-threads", "2", "-filter_threads", "1", "-copyts", "-seek_timestamp", "1",
               "-ss", f"{seek:.6f}", "-t", f"{read_until-seek:.9f}", "-i", str(path),
               "-map", f"0:{video['stream_index']}", "-an", "-sn", "-dn", "-vf", filters,
               "-fps_mode", "passthrough", "-q:v", "3", "-start_number", "0",
               str(directory / "frame-%05d.jpg")]
    result = run(command)
    (audit / f"{directory.name}-ffmpeg.log").write_text(result.stderr, encoding="utf-8")
    frames = parse_showinfo(result.stderr, video["time_base"])
    actual_files = sorted(p.name for p in directory.glob("*.jpg"))
    if actual_files != [f["filename"] for f in frames]:
        raise ReviewError("JPEG/showinfo frame count mismatch")
    for frame in frames:
        if not lo <= frame["source_pts"] < hi or frame["width"] > 1280:
            raise ReviewError("Extracted frame lies outside requested bounds or resolution")
        frame["sha256"] = sha256(directory / frame["filename"])
    # Independent decoded-frame PTS check. Seeking may return an earlier keyframe;
    # filter decoded frame PTS, never assume read_intervals starts at its request.
    probe_command = [ffprobe, "-v", "error", "-threads", "2", "-select_streams", str(video["stream_index"]),
                     "-read_intervals", f"{seek:.6f}%{read_until:.9f}", "-show_frames",
                     "-show_entries", "frame=pts,best_effort_timestamp", "-of", "json", str(path)]
    decoded = json.loads(run(probe_command).stdout).get("frames", [])
    if any("pts" not in frame for frame in decoded):
        raise ReviewError("ffprobe decoded frame lacks original PTS")
    expected_pts = [frame["pts"] for frame in decoded if lo <= frame["pts"] < hi]
    if expected_pts != [f["source_pts"] for f in frames]:
        raise ReviewError("FFmpeg JPEG PTS differ from independently decoded ffprobe frame PTS")
    nominal = Fraction(video["nominal_frame_rate"])
    if nominal <= 0:
        raise ReviewError("Invalid nominal frame rate")
    gaps = []
    for previous, current in zip(frames, frames[1:]):
        delta = Fraction(current["source_pts"]-previous["source_pts"]) * Fraction(video["time_base"])
        current["delta_from_previous_seconds"] = float(delta)
        current["gap_before"] = delta > Fraction(3, 2) / nominal
        if current["gap_before"]:
            gaps.append({"before_frame": current["window_frame_index"], "delta_seconds": float(delta)})
    frames[0].update(delta_from_previous_seconds=None, gap_before=False)
    payload = {"schema_version": 1, "review_id": directory.name, "pts_semantics": PTS_SEMANTICS,
               "global_presentation_ordinal": None,
               "gap_rule": "adjacent decoded PTS difference > 1.5 / nominal_frame_rate; flags an interval, not proof of lost frames",
               "gaps": gaps, "frames": frames}
    write_json(directory / "frames.json", payload)
    return payload, {"ffmpeg_command": command, "ffprobe_command": probe_command,
                     "decoded_frame_count": len(frames), "pts_crosscheck": "exact_integer_pts_equal",
                     "ffprobe_window_pts_sha256": digest(expected_pts),
                     "actual_first_pts": frames[0]["source_pts"], "actual_last_pts": frames[-1]["source_pts"],
                     "source_time_base": video["time_base"],
                     "window_lower_pts_inclusive": lo, "window_upper_pts_exclusive": hi,
                     "window_rounding": "ceil(exact serialized seconds / time_base), half-open; no tolerance",
                     "image_transform": {"ffmpeg_autorotate": True,
                                         "source_rotation_degrees": video.get("rotation_degrees"),
                                         "scale": "min(1280, oriented_input_width); proportional even height",
                                         "format": "JPEG, FFmpeg q:v=3; no overlays"}}


HTML = r'''<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file: data:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; font-src 'none'; base-uri 'none'; form-action 'none'">
<title>离线逐帧盲审</title>
<style>
*{box-sizing:border-box}body{margin:0;font:16px system-ui,sans-serif;background:#15191b;color:#f4f5f5}main{max-width:1400px;margin:auto;padding:20px}h1{font-size:24px}p{line-height:1.6;color:#cbd1d4}button,select,input{font:inherit;min-height:44px;max-width:100%;padding:8px;border:1px solid #60717a;border-radius:6px;color:inherit;background:#253139}button{cursor:pointer}button:disabled{opacity:.4}input[type=range]{padding:0;flex:1;min-width:180px}textarea{width:100%;min-height:78px;font:inherit;padding:10px;color:inherit;background:#20282c;border:1px solid #60717a}.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:12px 0}.grid{display:grid;grid-template-columns:minmax(0,2fr) minmax(280px,1fr);gap:20px}img{width:100%;display:block;background:#000;min-height:120px}.muted{font-size:14px;color:#b7c3c9}.warning{color:#ffd38e;min-height:24px}label{display:block;margin:12px 0 5px}output{display:block;font-variant-numeric:tabular-nums;overflow-wrap:anywhere}.markers{border-top:1px solid #5d6870;margin-top:14px;padding-top:8px}a{color:#bcdeff}.status{min-height:24px}@media(max-width:850px){.grid{grid-template-columns:1fr}}
</style><main>
<h1>离线逐帧盲审</h1>
<p>只依据画面确认同一球和触拍／首次触地区间；无法判断就保留未知。这里的时间是 FFmpeg 解码画面的源 PTS，不是触球真值。左右方向键逐帧移动。数据不上传；请导出 JSON 保存结果，刷新可能清空未导出的记录。</p>
<p class="muted">素材来自同一来源时，不能作为独立会话留出集。不要查看 audit 目录，以免看到选样与原始标签的对应关系。</p>
<div class="row"><label for="sample">样本</label><select id="sample"></select><button id="export">导出 review.json</button><span id="progress"></span></div>
<div class="grid"><section><img id="frame" alt="原片逐帧画面"><div class="row"><button id="prev">← 上一帧</button><input aria-label="帧位置" id="slider" type="range" min="0" step="1"><button id="next">下一帧 →</button></div><output id="position"></output><div id="gap" class="warning"></div></section>
<section><label for="same">同一球／同一拍是否可确认</label><select id="same"><option value="unknown">未知／未审核</option value="yes">确认</option value="no">无法绑定同一球或拍</option></select>
<label for="visibility">可见性</label><select id="visibility"><option value="unknown">未知／未审核</option value="clear">清楚</option value="partial">局部遮挡或模糊</option value="unusable">无法判读</option></select>
<div class="markers"><strong>触拍区间</strong><div class="row"><button data-mark="contact_start">当前帧设为起点</button><button data-mark="contact_end">当前帧设为终点</button><button data-clear="contact">清空</button></div><output id="contact"></output></div>
<div class="markers"><strong>首次触地区间</strong><div class="row"><button data-mark="bounce_start">当前帧设为起点</button><button data-mark="bounce_end">当前帧设为终点</button><button data-clear="bounce">清空</button></div><output id="bounce"></output></div>
<label for="reason">排除原因（未知无需强填）</label><select id="reason"><option value="">未排除</option value="identity_ambiguous">球／拍身份歧义</option value="contact_not_visible">触拍不可见</option value="bounce_not_visible">触地不可见</option value="window_truncated">事件在窗口外</option value="multiple_events">窗口内多次击球</option value="pts_gap">时间断层</option value="other">其他</option></select>
<label for="notes">备注</label><textarea id="notes" maxlength="4000" placeholder="记录不确定之处，不推算球速"></textarea><div class="row"><button id="reviewed">标为已复核</button><button id="pending">恢复待复核</button></div><div id="status" class="status"></div><div id="validation" class="warning"></div>
</section></div></main><script id="data" type="application/json">__DATA__</script>
<script>
'use strict';
const data=JSON.parse(document.getElementById('data').textContent), $=id=>document.getElementById(id);
let sampleIndex=0, frameIndex=0, dirty=false;
const reviews=data.samples.map(s=>({review_id:s.review_id,status:'pending',same_ball:'unknown',visibility:'unknown',contact_start:null,contact_end:null,bounce_start:null,bounce_end:null,exclusion_reason:null,notes:''}));
const sample=()=>data.samples[sampleIndex], record=()=>reviews[sampleIndex];
for(const s of data.samples){const o=document.createElement('option');o.value=$('sample').options.length;o.textContent=s.review_id;$('sample').append(o)}
function frameRef(){const f=sample().frames[frameIndex];return {filename:f.filename,window_frame_index:f.window_frame_index,source_pts:f.source_pts,source_time_base:f.source_time_base,source_pts_seconds:f.source_pts_seconds}}
function intervalText(kind){const r=record(),a=r[kind+'_start'],b=r[kind+'_end'];return `${a?a.source_pts_seconds.toFixed(6)+' s':'未设起点'} → ${b?b.source_pts_seconds.toFixed(6)+' s':'未设终点'}`}
function invalid(r){for(const k of ['contact','bounce']){const a=r[k+'_start'],b=r[k+'_end'];if((a===null)!==(b===null))return '区间需要起点和终点，或同时保持为空';if(a&&b&&a.window_frame_index>b.window_frame_index)return '区间起点晚于终点'}return ''}
function render(){const s=sample(),f=s.frames[frameIndex],r=record();$('frame').src='samples/'+s.review_id+'/'+f.filename;$('slider').max=s.frames.length-1;$('slider').value=frameIndex;$('prev').disabled=frameIndex===0;$('next').disabled=frameIndex===s.frames.length-1;$('position').textContent=`${s.review_id} · 第 ${frameIndex+1} / ${s.frames.length} 帧 · 源 PTS ${f.source_pts_seconds.toFixed(6)} s (${f.source_pts} × ${f.source_time_base})`;$('gap').textContent=f.gap_before?`注意：与前帧间隔 ${(f.delta_from_previous_seconds*1000).toFixed(2)} ms`:(s.gaps.length?`本窗口存在 ${s.gaps.length} 处较大帧间隔`:'');for(const k of ['contact','bounce'])$(k).textContent=intervalText(k);$('status').textContent=r.status==='reviewed'?'已复核（不代表满足训练入池条件）':'待复核';$('validation').textContent=invalid(r);$('progress').textContent=`已复核 ${reviews.filter(r=>r.status==='reviewed').length} / ${reviews.length}`}
function load(){frameIndex=0;const r=record();$('same').value=r.same_ball;$('visibility').value=r.visibility;$('reason').value=r.exclusion_reason||'';$('notes').value=r.notes;render()}
function change(){dirty=true;record().status='pending';render()}
$('sample').onchange=()=>{sampleIndex=Number($('sample').value);load()};$('prev').onclick=()=>{if(frameIndex>0)frameIndex--;render()};$('next').onclick=()=>{if(frameIndex<sample().frames.length-1)frameIndex++;render()};$('slider').oninput=()=>{frameIndex=Number($('slider').value);render()};
document.addEventListener('keydown',e=>{if(['INPUT','TEXTAREA','SELECT','BUTTON'].includes(e.target.tagName))return;if(e.key==='ArrowLeft'){e.preventDefault();$('prev').click()}if(e.key==='ArrowRight'){e.preventDefault();$('next').click()}});
for(const b of document.querySelectorAll('[data-mark]'))b.onclick=()=>{record()[b.dataset.mark]=frameRef();change()};for(const b of document.querySelectorAll('[data-clear]'))b.onclick=()=>{record()[b.dataset.clear+'_start']=null;record()[b.dataset.clear+'_end']=null;change()};
for(const [id,key] of [['same','same_ball'],['visibility','visibility'],['reason','exclusion_reason'],['notes','notes']])$(id).addEventListener('input',()=>{record()[key]=$(id).value||null;change()});
$('reviewed').onclick=()=>{if(invalid(record())){render();return}record().status='reviewed';dirty=true;render()};$('pending').onclick=()=>{record().status='pending';dirty=true;render()};
$('export').onclick=()=>{const errors=reviews.map(r=>[r.review_id,invalid(r)]).filter(x=>x[1]);if(errors.length){$('validation').textContent=errors.map(x=>x.join(': ')).join('; ');return}const payload={schema_version:1,package_id:data.package_id,exported_at:new Date().toISOString(),pts_semantics:data.pts_semantics,reviewer_id:null,records:reviews};const url=URL.createObjectURL(new Blob([JSON.stringify(payload,null,2)+'\n'],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='review.json';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);dirty=false};
window.addEventListener('beforeunload',e=>{if(dirty){e.preventDefault();e.returnValue=''}});load();
</script></html>'''


def page_html(data):
    # JSON script contents are not HTML-escaped: neutralize the HTML parser's
    # closing-tag and entity delimiters while keeping valid JSON for JSON.parse.
    safe = canonical(data).replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
    return HTML.replace("__DATA__", safe)


def build(dataset, output, count, ffmpeg="ffmpeg", ffprobe="ffprobe"):
    dataset, output = dataset.expanduser().resolve(), output.expanduser().absolute()
    if os.path.lexists(output):
        raise ReviewError("Output already exists; choose a new directory")
    manifest_path, shots_path = dataset / "manifest.json", dataset / "shots.jsonl"
    input_hashes = {"manifest.json": sha256(manifest_path), "shots.jsonl": sha256(shots_path)}
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if input_hashes["shots.jsonl"] != manifest.get("artifacts", {}).get("shots.jsonl", {}).get("sha256"):
        raise ReviewError("shots.jsonl does not match dataset manifest SHA256")
    sources = {s["source_sha256"]: s for s in manifest["sources"]}
    if len(sources) != len(manifest["sources"]):
        raise ReviewError("Duplicate source identity")
    rows = [json.loads(line) for line in shots_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    shots = projected_shots(rows, sources)
    del rows  # Teacher fields have no role after whitelisting.
    chosen, rally_count = select_shots(shots, count)
    overlaps = overlap_groups(chosen)
    selected_sources = {s["source_sha256"] for s in chosen}
    for source_sha in sorted(selected_sources):
        source = sources[source_sha]
        if sha256(source["source_path"]) != source_sha:
            raise ReviewError("Original source SHA256 does not match manifest")
        probe_source(source["source_path"], source["video"], ffprobe)
    versions = {tool: run([executable, "-version"]).stdout.splitlines()[0]
                for tool, executable in (("ffmpeg", ffmpeg), ("ffprobe", ffprobe))}
    generator_sha = sha256(Path(__file__))
    package_id = "review-" + digest([input_hashes, generator_sha, POLICY, [s["shot_id"] for s in chosen], versions])[:24]
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    audit = output / "audit"
    audit.mkdir(mode=0o700)
    receipt = {"schema_version": 1, "status": "building", "package_id": package_id,
               "created_at": datetime.now(timezone.utc).isoformat(), "dataset_sha256": input_hashes,
               "generator_sha256": generator_sha,
               "selection_policy": POLICY, "selection_seed": "fixed policy string; no random state",
               "selection_inputs": ["shot_id", "source_sha256", "group_id", "context.set/game/point"],
               "available_shots": len(shots), "available_rallies": rally_count,
               "selected_count": len(chosen), "all_rallies_covered": count >= rally_count,
               "source_family_count": len({s["source_family"] for s in chosen}),
               "independent_holdout_established": False,
               "split_policy": "No split created. Preserve source families, whole rallies and overlapping windows together; one source family cannot establish independent session holdout.",
               "window_policy": "software elapsed anchor [-0.6,+1.4) seconds, clipped to source duration, plus selected stream start_time; rational arithmetic then integer [ceil(start/time_base),ceil(end/time_base)) trim and validation",
               "pts_semantics": PTS_SEMANTICS, "versions": versions,
               "limitations": ["Software anchors only locate review windows; they do not label physical contact.",
                               "Fixed window placement may reveal approximate anchor position even though it is not shown.",
                               "FFmpeg edit-list PTS are not interchangeable with AVFoundation PTS.",
                               "A bounded window can omit contact or bounce; reviewers must mark truncation rather than invent endpoints.",
                               "Source family IDs are declarations; this tool does not discover duplicate videos.",
                               "No review decisions, teacher accuracy or training are produced."],
               "samples": []}
    blind_samples = []
    try:
        for index, shot in enumerate(chosen, 1):
            review_id = f"sample-{index:03d}"
            payload, extraction = extract_frames(sources[shot["source_sha256"]], shot,
                                                  output / "samples" / review_id, audit, ffmpeg, ffprobe)
            blind_samples.append(payload)
            receipt["samples"].append({"review_id": review_id, **shot,
                                       "selection_hash": selection_key(shot),
                                       "overlap_group": overlaps[shot["shot_id"]],
                                       "rally_group": "rally-" + digest(rally_key(shot))[:20],
                                       "extraction": extraction})
            print(f"{review_id}: {len(payload['frames'])} decoded frames, exact PTS crosscheck passed", flush=True)
        for name, expected in input_hashes.items():
            if sha256(dataset / name) != expected:
                raise ReviewError("Dataset changed during extraction")
        for source_sha in selected_sources:
            if sha256(sources[source_sha]["source_path"]) != source_sha:
                raise ReviewError("Source changed during extraction")
        blind = {"schema_version": 1, "package_id": package_id, "pts_semantics": PTS_SEMANTICS,
                 "samples": blind_samples}
        write_json(output / "blind-data.json", blind)
        with open(output / "index.html", "x", encoding="utf-8") as handle:
            handle.write(page_html(blind))
        receipt["status"] = "complete"
        receipt["artifacts"] = {name: sha256(output / name) for name in ("blind-data.json", "index.html")}
        write_json(audit / "selection_receipt.json", receipt)
        return {"output": str(output), "package_id": package_id, "samples": len(chosen),
                "decoded_frames": sum(len(s["frames"]) for s in blind_samples),
                "rallies": len({rally_key(s) for s in chosen}),
                "source_families": receipt["source_family_count"], "independent_holdout_established": False}
    except Exception as error:
        receipt.update(status="failed", error=str(error))
        write_json(audit / "failed-build.json", receipt)
        raise


class ReviewTests(unittest.TestCase):
    def shots(self):
        return [{"shot_id": f"id-{n}", "source_sha256": "a", "source_family": "one",
                 "context": {"set": 0, "game": 0, "point": n // 3},
                 "window_start_pts_seconds": n, "window_end_pts_seconds": n+2}
                for n in range(12)]

    def test_selection_covers_rallies_and_ignores_order_and_teacher_fields(self):
        shots = self.shots()
        a, count = select_shots(shots, 6)
        self.assertEqual(count, 4)
        self.assertEqual(len({rally_key(s) for s in a}), 4)
        contaminated = [{**s, "teacher_speed_kmh": 9999-i, "teacher_hit": {"x": i}, "stroke": "changed"}
                        for i, s in enumerate(reversed(shots))]
        b, _ = select_shots(contaminated, 6)
        self.assertEqual([s["shot_id"] for s in a], [s["shot_id"] for s in b])

    def test_overlap_is_transitive_and_half_open(self):
        shots = self.shots()[:3]
        groups = overlap_groups(shots)
        self.assertEqual(len(set(groups.values())), 1)
        shots[2]["window_start_pts_seconds"] = 3
        groups = overlap_groups(shots)
        self.assertNotEqual(groups[shots[0]["shot_id"]], groups[shots[2]["shot_id"]])

    def test_showinfo_uses_integer_pts_and_rejects_reorder(self):
        log = "config in time_base: 1/600, frame_rate: 60/1\nn: 0 pts: 601 pts_time:1.00167 fmt:yuvj420p s:1280x720\nn: 1 pts: 611 pts_time:1.01833 fmt:yuvj420p s:1280x720"
        frames = parse_showinfo(log, "1/600")
        self.assertEqual(frames[0]["source_pts_seconds_rational"], "601/600")
        self.assertEqual(frames[1]["source_pts"], 611)
        with self.assertRaises(ReviewError):
            parse_showinfo(log.replace("pts: 611", "pts: 600"), "1/600")
        with self.assertRaises(ReviewError):
            parse_showinfo(log, "1/1000")

    def test_real_sample_015_boundary_uses_ceil_not_nearest_tick(self):
        # Real rejected frame: 226428/600=377.38 is 11 microseconds before
        # sample-015's requested 377.380011. Seconds trim rounded it in.
        shot = {"window_start_pts_seconds": 377.380011,
                "window_end_pts_seconds": 379.380011}
        lo, hi = window_ticks(shot, "1/600")
        self.assertEqual((lo, hi), (226429, 227629))
        irregular_pts = [226428, 226438, 226449, 226470, 227620, 227628, 227629]
        self.assertEqual([pts for pts in irregular_pts if lo <= pts < hi],
                         [226438, 226449, 226470, 227620, 227628])
        # Exactly-on-tick end must be excluded; no widening epsilon is used.
        shot["window_end_pts_seconds"] = 379.38
        self.assertEqual(window_ticks(shot, "1/600"), (226429, 227628))

    def test_zero_origin_and_variable_frame_intervals_preserve_half_open_bounds(self):
        source = {"group_id": "family", "video": {"duration_seconds": 10, "start_time_seconds": 0}}
        row = {"shot_id": "one", "source_sha256": "a", "group_id": "family",
               "context": {"set": 0, "game": 0, "point": 1},
               "timing": {"software_event_anchor_seconds": 0.1}}
        shot = projected_shots([row], {"a": source})[0]
        self.assertEqual(shot["window_start_pts_seconds_rational"], "0")
        self.assertEqual(shot["window_end_pts_seconds_rational"], "3/2")
        lo, hi = window_ticks(shot, "1/600")
        self.assertEqual((lo, hi), (0, 900))
        pts = [-10, 0, 10, 21, 50, 899, 900]
        self.assertEqual([p for p in pts if lo <= p < hi], [0, 10, 21, 50, 899])
        # Source start need not be zero; time origin is added before rounding.
        source["video"]["start_time_seconds"] = -0.1
        shifted = projected_shots([row], {"a": source})[0]
        self.assertEqual(window_ticks(shifted, "1/600"), (-60, 840))

    def test_json_embedded_in_html_cannot_close_script(self):
        value = {"samples": [], "text": "</script><img src=x onerror=alert(1)>&"}
        rendered = page_html(value)
        embedded = rendered.split('type="application/json">', 1)[1].split('</script>', 1)[0]
        self.assertNotIn("<", embedded)
        self.assertEqual(json.loads(embedded), value)

    def test_whitelist_excludes_teacher_fields(self):
        source = {"group_id": "family", "video": {"duration_seconds": 20, "start_time_seconds": 0}}
        row = {"shot_id": "one", "source_sha256": "a", "group_id": "family",
               "context": {"set": 0, "game": 0, "point": 1},
               "timing": {"software_event_anchor_seconds": 10},
               "teacher_speed_kmh": 80, "teacher_hit": {"x": 12}, "stroke": "serve"}
        result = projected_shots([row], {"a": source})[0]
        self.assertNotIn("teacher_speed_kmh", result)
        self.assertNotIn("teacher_hit", result)
        self.assertNotIn("stroke", result)

    def test_existing_output_and_source_hash_mismatch_fail_before_decode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ReviewError, "Output already exists"):
                build(root, root, 1)
            source_path = root / "source.mov"
            source_path.write_bytes(b"not a video")
            shot = {"shot_id": "one", "source_sha256": "incorrect", "group_id": "family",
                    "context": {"set": 0, "game": 0, "point": 1},
                    "timing": {"software_event_anchor_seconds": 10}}
            (root / "shots.jsonl").write_text(canonical(shot) + "\n", encoding="utf-8")
            write_json(root / "manifest.json", {
                "sources": [{"source_sha256": "incorrect", "source_path": str(source_path),
                             "group_id": "family", "video": {"duration_seconds": 20, "start_time_seconds": 0}}],
                "artifacts": {"shots.jsonl": {"sha256": sha256(root / "shots.jsonl")}}})
            with self.assertRaisesRegex(ReviewError, "Original source SHA256"):
                build(root, root / "output", 1, ffmpeg="must-not-run", ffprobe="must-not-run")
            self.assertFalse((root / "output").exists())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    commands = parser.add_subparsers(dest="command")
    command = commands.add_parser("build")
    command.add_argument("--dataset", required=True, type=Path)
    command.add_argument("--output", required=True, type=Path)
    command.add_argument("--count", type=int, default=40)
    command.add_argument("--ffmpeg", default="ffmpeg")
    command.add_argument("--ffprobe", default="ffprobe")
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ReviewTests))
        return 0 if result.wasSuccessful() else 1
    if args.command != "build":
        parser.error("choose build or --self-test")
    try:
        print(json.dumps(build(args.dataset, args.output, args.count, args.ffmpeg, args.ffprobe), ensure_ascii=False, indent=2))
        return 0
    except (ReviewError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"speed-review: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
