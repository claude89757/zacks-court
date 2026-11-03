#!/usr/bin/env python3
"""Render private development evidence: historical causal_cv vs native points.

Both panels show the SAME actual native resized RGB, not historical imagery.
No inference, label creation, coordinate interpolation, or speed is performed.
"""
import argparse
from fractions import Fraction
from functools import lru_cache
import importlib.util
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from PIL import Image, ImageDraw, ImageFont, __version__ as pillow_version

AUDIT_PATH = Path(__file__).with_name("ball-native-video-audit.py")
spec = importlib.util.spec_from_file_location("native_video_audit_helpers", AUDIT_PATH)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
require = audit.require
CYAN, ORANGE, MAGENTA = "#39d9ec", "#ffab52", "#ff79dc"
BACKGROUND = "#101820"
FIXED_STILLS = {"train-006": 10, "eval-002": 72}


@lru_cache(maxsize=8)
def font(size):
    return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", size)


def point(value, size):
    if value is None:
        return None
    require(isinstance(value, list) and len(value) == 2 and all(
        type(v) in (int, float) and math.isfinite(v) for v in value), "Invalid overlay point")
    require(0 <= value[0] < size[0] and 0 <= value[1] < size[1], "Overlay outside source image")
    return value


def old_rows(old_run, windows):
    path = old_run / "frames.jsonl"
    if not path.exists():
        return {}, {"status": "unavailable", "reason": "No complete historical frames.jsonl; native vs existing agent only"}
    completion = audit.load_json(old_run / "completion.json")
    require(completion.get("status") == "complete", "Historical association run incomplete")
    require(audit.sha_file(path) == completion["frames_sha256"], "Historical frame predictions hash changed")
    require(audit.sha_file(old_run / "protocol.json") == completion["protocol_sha256"], "Historical protocol hash changed")
    selected = {}
    with path.open() as handle:
        for line in handle:
            row = json.loads(line)
            if row.get("recipe") != "full-threshold-0.3":
                continue
            name, index = row["sample_id"], row["frame_index"]
            require(name in windows and type(index) is int and 0 <= index < 120, "Unexpected historical source/frame")
            key = (name, index)
            require(key not in selected, "Duplicate historical frame")
            source = windows[name]["frames"][index]
            require(audit.manifest_time(row) == audit.manifest_time(source), "Historical PTS does not match source")
            require(row["image_sha256"] == source["image_sha256"], "Historical source-frame hash differs")
            require(row["view"] == "full" and row["threshold"] == 0.3 and row["threshold_operator"] == ">",
                    "Historical recipe differs")
            require(row["crop_xyxy"] == [0, 0, row["width"], row["height"]], "Historical full view was cropped")
            require((row["width"], row["height"]) == (windows[name]["width"], windows[name]["height"]), "Historical dimensions differ")
            choice = row["selections"]["causal_cv"]
            xy = point(choice["xy_original"], (row["width"], row["height"]))
            require((choice["status"] == "missing") == (xy is None), "Historical missing status differs")
            selected[key] = row
    counts = {name: sum(key[0] == name for key in selected) for name in audit.WINDOWS}
    for name, count in counts.items():
        if count != 120:
            selected = {key: row for key, row in selected.items() if key[0] != name}
    return selected, {"status": "verified", "selector": "selections.causal_cv.xy_original",
                      "recipe": "full-threshold-0.3", "complete_frame_counts": counts,
                      "frames_sha256": audit.sha_file(path),
                      "completion_sha256": audit.sha_file(old_run / "completion.json"),
                      "protocol_sha256": audit.sha_file(old_run / "protocol.json"),
                      "fallback_rule": "Any window without all 120 historical rows shows native vs existing agent only"}


def draw_marker(draw, xy, color, shape, native_size):
    if xy is None:
        return
    x, y = xy[0] * 960 / native_size[0], xy[1] * 540 / native_size[1]
    if shape == "square":
        draw.rectangle((x - 7, y - 7, x + 7, y + 7), outline=color, width=2)
    else:
        draw.ellipse((x - 11, y - 11, x + 11, y + 11), outline=color, width=3)
        draw.line((x - 17, y, x - 12, y), fill=color, width=2)
        draw.line((x + 12, y, x + 17, y), fill=color, width=2)


def panel(source, xy, agent_xy, title, color, native_size, fallback=False):
    image = source.resize((960, 540), Image.Resampling.LANCZOS)
    draw = ImageDraw.Draw(image)
    if not fallback:
        draw_marker(draw, xy, color, "circle", native_size)
    draw_marker(draw, agent_xy, MAGENTA, "square", native_size)
    draw.rectangle((0, 0, 959, 33), fill=BACKGROUND)
    draw.text((10, 7), title, font=font(18), fill=color)
    if xy is None and not fallback:
        draw.rectangle((8, 42, 200, 71), fill=BACKGROUND)
        draw.text((14, 47), "NO SELECTED OUTPUT", font=font(16), fill="white")
    return image


def presentation(name, index, report, window, old, label_points, source):
    native_size = (window["width"], window["height"])
    native = report["frames"][index]
    native_xy = point(native["candidate"]["originalXY"] if native["candidate"] else None, native_size)
    historical = old.get((name, index))
    old_xy = point(historical["selections"]["causal_cv"]["xy_original"], native_size) if historical else None
    label = label_points.get(index)
    agent_xy = point(label["label_original_xy"], native_size) if label and label["status"] == "visible" else None
    fallback = historical is None
    left_title = "HISTORICAL causal_cv | threshold >0.3" if not fallback else "EXISTING AGENT REFERENCE | no complete historical run"
    left = panel(source, old_xy, agent_xy, left_title, CYAN, native_size, fallback)
    right = panel(source, native_xy, agent_xy, "NATIVE PAST TRACKER | threshold >0.3", ORANGE, native_size)
    image = Image.new("RGB", (1920, 720), BACKGROUND)
    image.paste(left, (0, 96)); image.paste(right, (960, 96))
    draw = ImageDraw.Draw(image)
    frame = window["frames"][index]
    pts = audit.manifest_time(frame)
    source_rate = Fraction(str(report["nominal_fps"]))
    slowed = source_rate / 15
    draw.text((12, 8), f"DEVELOPMENT / NO SPEED | {name} | frame {index:03d} | original PTS {frame['source_pts']} x {frame['source_time_base']} = {float(pts):.6f}s", font=font(21), fill="white")
    draw.text((12, 38), f"first48 warmup not shown | {native_size[0]}x{native_size[1]} / {float(source_rate):g}fps source slowed {float(slowed):g}x | 120 real frames / 15fps / 8s", font=font(20), fill="#dce5ef")
    draw.text((12, 68), "BOTH PANELS show current native 512x288 RGB upscaled. Historical inference used different decode + background; overlay positions only.", font=font(19), fill="#c6d1dc")
    label_text = "VISIBLE agent candidate (magenta square)" if agent_xy is not None else (
        "UNKNOWN ball identity: no agent coordinates drawn" if label else "UNLABELLED: no agent point filled or interpolated")
    draw.text((12, 645), "CYAN circle: historical causal_cv | ORANGE circle: native past tracker | MAGENTA square: existing AGENT candidate, NOT HUMAN truth", font=font(19), fill="#dce5ef")
    draw.text((12, 672), "Label at this frame: " + label_text, font=font(19), fill=MAGENTA if label else "#c6d1dc")
    draw.text((12, 699), "8-frame detector uses up to 7 future frames. Agent-development evidence only; no physical accuracy or speed qualification.", font=font(16), fill="#c6d1dc")
    return image


def encode_video(path, images):
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-f", "rawvideo", "-pixel_format", "rgb24",
               "-video_size", "1920x720", "-framerate", "15", "-i", "pipe:0", "-an", "-c:v", "libx264",
               "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(path)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    count = 0
    try:
        for image in images:
            require(image.size == (1920, 720), "Unexpected presentation size")
            process.stdin.write(image.tobytes())
            count += 1
        process.stdin.close()
        error = process.stderr.read().decode()
        require(process.wait() == 0, "ffmpeg encoding failed: " + error[-1500:])
    except BaseException:
        process.kill(); process.wait()
        raise
    require(count == 120, "Must encode all 120 real frames")
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
                            "stream=nb_read_frames,width,height,duration,avg_frame_rate", "-of", "json", str(path)],
                           check=True, capture_output=True, text=True)
    stream = json.loads(probe.stdout)["streams"][0]
    require(int(stream["nb_read_frames"]) == 120 and (stream["width"], stream["height"]) == (1920, 720), "Decoded frame count/dimensions differ")
    require(abs(float(stream["duration"]) - 8) < 1e-6 and Fraction(stream["avg_frame_rate"]) == 15, "Video duration/fps differ")
    decode = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(path),
                             "-map", "0:v:0", "-f", "null", "-"], check=True, capture_output=True, text=True)
    require(not decode.stderr.strip(), "Full ffmpeg decoding reported errors")
    path.chmod(0o600)
    return {"file": path.name, "sha256": audit.sha_file(path), "encoded_frames": 120, "decoded_frames": 120,
            "presentation_fps": 15, "duration_seconds": 8.0, "width": 1920, "height": 720,
            "ffmpeg_full_decode": "passed", "ffprobe_count_frames": stream}


def build(args):
    output = Path(args.output).absolute()
    require(not output.exists() and not output.is_symlink(), "Output exists; choose a NEW directory")
    manifest = audit.load_json(args.old_manifest)
    manifest_sha = audit.sha_file(args.old_manifest)
    windows = {row["window_id"]: row for row in manifest["windows"]}
    require(set(windows) == set(audit.WINDOWS), "Unexpected source-window manifest")
    labels = audit.load_json(args.train_labels)["records"] + audit.load_json(args.eval_labels)["records"]
    historical, historical_receipt = old_rows(Path(args.old_run), windows)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".native-video-view-", dir=output.parent))
    temporary.chmod(0o700)
    published = False
    try:
        videos, stills, input_runs = [], [], []
        for name in audit.WINDOWS:
            run_root = Path(args.runs_root) / name
            verified = audit.audit_run(args.runs_root, Path(args.protocols) / (name + ".json"), windows[name],
                                       [row for row in labels if row["sample_id"] == name], manifest_sha)
            report = audit.load_json(run_root / "report.json")
            label_points = {row["frame_index"]: row for row in verified["points"]}
            rgb_receipts = []
            def frames():
                for index in range(120):
                    row = report["decoded_inputs"][48 + index]
                    require(audit.stamp(row["presentation_time"]) == audit.manifest_time(windows[name]["frames"][index]), "Displayed source PTS differs")
                    data = audit.checked_bytes(run_root, row["resized_rgb_file"], audit.RGB_BYTES, row["resized_rgb_sha256"])
                    rgb_receipts.append({"frame_index": index, "original_pts": row["presentation_time"],
                                         "resized_rgb_sha256": row["resized_rgb_sha256"]})
                    source = Image.frombytes("RGB", (512, 288), data)
                    image = presentation(name, index, report, windows[name], historical, label_points, source)
                    if FIXED_STILLS.get(name) == index:
                        still = temporary / (name + f"-frame-{index:03d}-pair.png")
                        image.save(still)
                        still.chmod(0o600)
                        stills.append({"file": still.name, "sha256": audit.sha_file(still), "sample_id": name,
                                       "frame_index": index, "selection": "fixed before rendering: train-006 frame10 / eval-002 frame72"})
                    yield image
            video = encode_video(temporary / (name + ".mp4"), frames())
            video.update(source_window=name, native_report_sha256=verified["native_report_sha256"],
                         source_first_pts=str(audit.manifest_time(windows[name]["frames"][0])),
                         source_last_pts=str(audit.manifest_time(windows[name]["frames"][-1])),
                         source_nominal_fps=report["nominal_fps"], slowed_by=report["nominal_fps"] / 15,
                         historical_all120_present=all((name, index) in historical for index in range(120)),
                         displayed_rgb_inputs=rgb_receipts)
            videos.append(video)
            input_runs.append({key: verified[key] for key in ("source_window", "source_sha256", "native_report_sha256", "protocol_sha256", "background_sha256")})
            print(f"VIEW_OK {name}: decoded120 / 8seconds / 15fps / no speed", flush=True)
        receipt = {"schema_version": 1, "production": False, "formal_eligible": False, "final_eligible": False,
                   "human_validated": False, "speed_metrics": None, "tool_sha256": audit.sha_file(__file__),
                   "audit_helper_sha256": audit.sha_file(AUDIT_PATH), "pillow_version": pillow_version,
                   "ffmpeg_version": subprocess.run(["ffmpeg", "-version"], check=True, capture_output=True, text=True).stdout.splitlines()[0],
                   "old_manifest_sha256": manifest_sha, "train_labels_sha256": audit.sha_file(args.train_labels),
                   "eval_labels_sha256": audit.sha_file(args.eval_labels), "input_runs": input_runs,
                   "historical": historical_receipt, "videos": videos, "fixed_stills": stills,
                   "display_policy": "Both panels use identical current native 512x288 RGB upscaled to960x540. Historical overlay is causal_cv, never offline_beam_cv. Historical imagery/background is not displayed.",
                   "labels": "Existing48 candidates per window only; 166visible agent points,26unknown with no drawn coordinates. Unlabelled frames stay unlabelled. No human truth or new labels.",
                   "limitations": ["First48 prefix warmup frames are not shown; each video shows all120 target frames with original PTS labels.",
                       "1920x1080@60fps windows are slowed4x;1280x720@30fps window slowed2x. Presentation is15fps, not realtime.",
                       "Both associations use past selections, but their8-frame detector windows include up to7 future frames.",
                       "Decoder/color path, background policy and possible candidate tie rules differ; point differences cannot be attributed to a single change.",
                       "These local development clips establish software evidence, not camera capture performance, physical speed or independent accuracy."]}
        with (temporary / "video-receipt.json").open("x") as handle:
            json.dump(receipt, handle, indent=2, allow_nan=False)
            handle.write("\n")
        (temporary / "video-receipt.json").chmod(0o600)
        require(not output.exists(), "Destination appeared during rendering")
        temporary.rename(output)
        published = True
        print(json.dumps({"output": str(output), "videos": len(videos), "fully_decoded_frames": 480, "fixed_stills": len(stills)}))
    finally:
        if not published:
            shutil.rmtree(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs-root", required=True)
    parser.add_argument("--protocols", required=True)
    parser.add_argument("--old-run", required=True)
    parser.add_argument("--old-manifest", required=True)
    parser.add_argument("--train-labels", required=True)
    parser.add_argument("--eval-labels", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        build(args)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print("VIEW_REFUSED: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
