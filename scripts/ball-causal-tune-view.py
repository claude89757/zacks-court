#!/usr/bin/env python3
"""Render completed causal-tune development runs as three-column private videos.

No model inference, new labels, interpolation, oracle overlay or browser service.
Every column uses the same actual native RGB and its own causal selection.
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
import unittest

sys.dont_write_bytecode = True
from PIL import Image, ImageDraw, ImageFont, __version__ as pillow_version

HERE = Path(__file__).resolve()
AUDIT_PATH = HERE.with_name("ball-native-video-audit.py")
spec = importlib.util.spec_from_file_location("causal_view_native_audit", AUDIT_PATH)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
require = audit.require
MODELS = ("base", "head_only", "decoder_head")
COLORS = ("#39d9ec", "#ffab52", "#76e6ab")
MAGENTA, BACKGROUND = "#ff79dc", "#101820"
SIZE = (1920, 600)
FIXED_STILLS = {"train-006": 10, "eval-002": 72}


def file_hashes(root, mapping):
    for name, expected in mapping.items():
        require(Path(name).name == name and name not in (".", ".."), "Invalid output artifact path")
        require(audit.sha_file(root / name) == audit.valid_sha(expected), "Run output hash differs: " + name)


def complete_run(root):
    require(not (root / "failure.json").exists(), "Failed run is not renderable")
    completion = audit.load_json(root / "completion.json")
    require(completion.get("status") == "complete", "Incomplete experiment")
    require(completion.get("completed_fits") == list(MODELS[1:]), "Missing final fit")
    require(completion.get("predicted_frames") == 1440 and completion.get("base_parity_gate_passed") is True,
            "Expected 3 models x480 real predictions and passed baseline gate")
    require(completion.get("production") is False and completion.get("formal_eligible") is False,
            "Expected development-only completion")
    file_hashes(root, completion["files"])
    for name in ("protocol.json", "receipt.json", "report.json", "predictions.jsonl",
                 "base-evaluation.json", "head_only-evaluation.json", "decoder_head-evaluation.json",
                 "head_only-training.json", "decoder_head-training.json", "head_only.pt", "decoder_head.pt"):
        require(name in completion["files"], "Missing registered completed artifact: " + name)
    protocol = audit.load_json(root / "protocol.json")
    receipt = audit.load_json(root / "receipt.json")
    report = audit.load_json(root / "report.json")
    require(audit.sha_file(root / "protocol.json") == completion["protocol_sha256"] == receipt["protocol_sha256"] == report["protocol_sha256"],
            "Frozen protocol receipt differs")
    require(receipt["runner_sha256"] == completion["runner_sha256"], "Runner identity differs")
    require(report.get("base_native_parity_gate_passed") is True and report.get("same_rgb_decode_background_across_models") is True,
            "Experiment did not preserve the fixed native input or pass the baseline gate")
    require(report.get("fitted_modes") == list(MODELS[1:]) and set(report["evaluations"]) == set(MODELS), "Model list differs")
    require(report.get("production") is False and report.get("final_eligible") is False and report.get("speed_metrics", "missing") is None,
            "Unexpected qualification/speed claim")
    require(protocol["steps_per_fit"] == 72 and protocol["seed"] == 20261029 and protocol["learning_rate"] == 1e-4,
            "Unexpected fixed fitting protocol")
    require([row["mode"] for row in protocol["variants"]] == list(MODELS[1:]), "Protocol variants differ")
    require(receipt["input_files"] == protocol["input_files"], "Input file receipt differs")
    for path, expected in protocol["input_files"].items():
        require(audit.sha_file(path) == expected, "Frozen experiment input changed: " + path)
    for path, expected in protocol["dependencies"].items():
        require(audit.sha_file(path) == expected, "Frozen experiment helper/runner changed: " + path)
    model_receipt = {}
    for model in MODELS:
        evaluation = audit.load_json(root / (model + "-evaluation.json"))
        require(evaluation == report["evaluations"][model], "Final evaluation report differs")
        require(evaluation["model"] == model and evaluation["frame_count"] == 480 and evaluation["batch_count"] == 60,
                "Evaluation model/frame list differs")
        require(evaluation["model_unchanged"] is True, "Evaluation changed model state")
        model_receipt[model] = {"model_state_sha256": audit.valid_sha(evaluation["model_state_sha256"]),
                                "evaluation_sha256": audit.sha_file(root / (model + "-evaluation.json"))}
        if model != "base":
            fitting = audit.load_json(root / (model + "-training.json"))
            require(fitting == report["training"][model], "Final fit report differs")
            require(fitting["mode"] == model and fitting["steps"] == 72 and [row["step"] for row in fitting["history"]] == list(range(72)),
                    "Fit is not the complete final72-step model")
            require(fitting["safe_reloaded_full_model_identical"] is True and fitting["all17_first_split_forwards_exact"] is True
                    and fitting["all17_final_split_forwards_exact"] is True, "Missing model reload/cache verification")
            require(fitting["final_model_state_sha256"] == model_receipt[model]["model_state_sha256"], "Evaluated weights differ from fitted weights")
            require(fitting["initial_model_state_sha256"] == model_receipt["base"]["model_state_sha256"], "Fit did not start from this official base")
            require(fitting["checkpoint"] == model + ".pt" and fitting["checkpoint_sha256"] == audit.sha_file(root / (model + ".pt")), "Checkpoint digest differs")
            require(fitting["frozen_nontrainable_before"] == fitting["frozen_nontrainable_after"] and
                    fitting["bn_running_buffers_before"] == fitting["bn_running_buffers_after"], "Frozen model/BN state changed")
            model_receipt[model].update(checkpoint=fitting["checkpoint"], checkpoint_sha256=fitting["checkpoint_sha256"],
                                        training_sha256=audit.sha_file(root / (model + "-training.json")))
    return completion, protocol, model_receipt


def index_rows(rows):
    require(len(rows) == 1440, "Expected exactly1440 predictions, not1400 or a subset")
    result = {}
    for row in rows:
        model, sample, index = row["model"], row["sample_id"], row["frame_index"]
        require(model in MODELS and sample in audit.WINDOWS and type(index) is int and 0 <= index < 120,
                "Unexpected prediction identity")
        key = (model, sample, index)
        require(key not in result, "Duplicate model/source/frame prediction")
        result[key] = row
    expected = {(model, sample, index) for model in MODELS for sample in audit.WINDOWS for index in range(120)}
    require(set(result) == expected, "Missing model/source/frame prediction")
    return result


def xy(value, width, height):
    if value is None:
        return None
    require(isinstance(value, list) and len(value) == 2 and all(type(v) is int for v in value), "Invalid selected point")
    require(0 <= value[0] < width and 0 <= value[1] < height, "Selected point outside source image")
    return value


def verify_row(row, frame, reference, window):
    require(row["source_sha256"] == window["source_sha256"], "Prediction source SHA differs")
    require(audit.manifest_time(row) == audit.manifest_time(frame) == audit.stamp(row["time"]), "Prediction original PTS differs")
    require(audit.stamp(row["available_at_pts"]) == audit.stamp(reference["available_at_pts"]), "Prediction availability PTS differs")
    require(row["window_index"] == frame["frame_index"] // 8, "Prediction8-frame group differs")
    require(row.get("production") is False and row.get("formal_eligible") is False and row.get("speed_kmh", "missing") is None,
            "Unexpected qualified or speed output")
    selected = row["causal_selection"]["candidate"]
    if selected is not None:
        require(selected in row["candidate_bank"]["candidates"], "Selected causal point is outside its candidate bank")
    return xy(selected["originalXY"] if selected else None, window["width"], window["height"])


@lru_cache(maxsize=8)
def font(size):
    return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", size)


def agent_point(label, width, height):
    return xy(label["label_original_xy"], width, height) if label and label["status"] == "visible" else None


def marker(draw, value, size, color, square=False):
    if value is None:
        return
    x, y = value[0] * 640 / size[0], value[1] * 360 / size[1]
    if square:
        draw.rectangle((x - 5, y - 5, x + 5, y + 5), outline=color, width=2)
    else:
        draw.ellipse((x - 8, y - 8, x + 8, y + 8), outline=color, width=2)
        draw.line((x - 12, y, x - 9, y), fill=color, width=2)
        draw.line((x + 9, y, x + 12, y), fill=color, width=2)


def presentation(sample, index, source, candidates, label, window, report):
    image = Image.new("RGB", SIZE, BACKGROUND)
    draw = ImageDraw.Draw(image)
    frame = window["frames"][index]
    original_time = audit.manifest_time(frame)
    draw.text((12, 8), f"PYTORCH DEVELOPMENT / NO SPEED | {sample} | frame {index:03d} | original PTS {frame['source_pts']} x {frame['source_time_base']} = {float(original_time):.6f}s", font=font(20), fill="white")
    fps = report["nominal_fps"]
    draw.text((12, 37), f"All columns: SAME actual RGB + prefix48 past background + original PTS causal gate | {window['width']}x{window['height']} / {fps:g}fps slowed {fps / 15:g}x | 15fps /8s", font=font(19), fill="#dce5ef")
    titles = ("BASE / official weights", "HEAD_ONLY / final step72", "DECODER_HEAD / final step72")
    visible_agent = agent_point(label, window["width"], window["height"])
    for column, (model, color, title) in enumerate(zip(MODELS, COLORS, titles)):
        draw.text((column * 640 + 12, 77), title, font=font(21), fill=color)
        panel = source.resize((640, 360), Image.Resampling.LANCZOS)
        overlay = ImageDraw.Draw(panel)
        marker(overlay, candidates[model], (window["width"], window["height"]), color)
        marker(overlay, visible_agent, (window["width"], window["height"]), MAGENTA, square=True)
        image.paste(panel, (column * 640, 104))
        if candidates[model] is None:
            draw.rectangle((column * 640 + 8, 111, column * 640 + 218, 137), fill=BACKGROUND)
            draw.text((column * 640 + 14, 115), "NO SELECTED OUTPUT", font=font(17), fill="white")
    draw.text((12, 479), "Colored circles: each model's causal selection. MAGENTA squares: existing AGENT candidates, NOT HUMAN truth.", font=font(20), fill="#dce5ef")
    draw.text((12, 509), "Fixed RGB/decode/background/gates; model parameters are the only intervention. No oracle or beam is drawn. No coordinates are interpolated.", font=font(19), fill="#c6d1dc")
    label_text = "VISIBLE agent candidate" if visible_agent is not None else (
        "UNKNOWN identity; no agent coordinates drawn" if label else "UNLABELLED; no agent coordinates filled")
    draw.text((12, 539), "Agent at this frame: " + label_text + " | first48 warmup not shown", font=font(19), fill=MAGENTA if label else "#c6d1dc")
    draw.text((12, 570), "8-frame detector has up to7-frame lookahead. Development evidence only; no independent human accuracy, camera performance or physical speed claim.", font=font(18), fill="#c6d1dc")
    return image


def encode_video(path, images):
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-f", "rawvideo", "-pixel_format", "rgb24",
               "-video_size", f"{SIZE[0]}x{SIZE[1]}", "-framerate", "15", "-i", "pipe:0", "-an", "-c:v", "libx264",
               "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(path)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    count = 0
    try:
        for image in images:
            require(image.size == SIZE, "Presentation size changed")
            process.stdin.write(image.tobytes()); count += 1
        process.stdin.close()
        error = process.stderr.read().decode()
        require(process.wait() == 0, "ffmpeg encoding failed: " + error[-1500:])
    except BaseException:
        process.kill(); process.wait(); raise
    require(count == 120, "Expected all120 real target frames")
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
        "stream=nb_read_frames,width,height,duration,avg_frame_rate", "-of", "json", str(path)], check=True, capture_output=True, text=True)
    stream = json.loads(probe.stdout)["streams"][0]
    require(int(stream["nb_read_frames"]) == 120 and (stream["width"], stream["height"]) == SIZE,
            "Decoded video frame count/size differs")
    require(abs(float(stream["duration"]) - 8) < 1e-6 and Fraction(stream["avg_frame_rate"]) == 15, "Video duration/rate differs")
    decode = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(path),
                             "-map", "0:v:0", "-f", "null", "-"], check=True, capture_output=True, text=True)
    require(not decode.stderr.strip(), "Full decoding reported errors")
    path.chmod(0o600)
    return {"file": path.name, "sha256": audit.sha_file(path), "encoded_frames": count, "decoded_frames": 120,
            "width": SIZE[0], "height": SIZE[1], "presentation_fps": 15, "duration_seconds": 8,
            "ffmpeg_full_decode": "passed", "ffprobe_count_frames": stream}


def build(args):
    root, output = Path(args.run).resolve(), Path(args.output).absolute()
    require(not output.exists() and not output.is_symlink(), "Output exists; choose a NEW directory")
    completion, protocol, model_receipt = complete_run(root)
    paths = protocol["paths"]
    windows = {row["window_id"]: row for row in audit.load_json(paths["old_manifest"])["windows"]}
    require(set(windows) == set(audit.WINDOWS), "Source window list differs")
    labels = audit.load_json(paths["train_labels"])["records"] + audit.load_json(paths["eval_labels"])["records"]
    with (root / "predictions.jsonl").open() as handle:
        rows = index_rows([json.loads(line) for line in handle])
    checked_runs, reports, label_points, points = {}, {}, {}, {}
    for sample in audit.WINDOWS:
        checked = audit.audit_run(paths["runs_root"], Path(paths["native_protocols"]) / (sample + ".json"), windows[sample],
            [row for row in labels if row["sample_id"] == sample], audit.sha_file(paths["old_manifest"]))
        checked_runs[sample] = {key: checked[key] for key in ("source_window", "source_sha256", "native_report_sha256", "protocol_sha256", "background_sha256")}
        report = audit.load_json(Path(paths["runs_root"]) / sample / "report.json")
        reports[sample] = report
        label_points[sample] = {row["frame_index"]: row for row in checked["points"]}
        for index in range(120):
            for model in MODELS:
                points[(model, sample, index)] = verify_row(rows[(model, sample, index)], windows[sample]["frames"][index], report["frames"][index], windows[sample])
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".causal-tune-view-", dir=output.parent)); temporary.chmod(0o700)
    published = False
    try:
        videos, stills = [], []
        for sample in audit.WINDOWS:
            displayed = []
            def frames():
                for index in range(120):
                    rgb_row = reports[sample]["decoded_inputs"][48 + index]
                    data = audit.checked_bytes(Path(paths["runs_root"]) / sample, rgb_row["resized_rgb_file"], audit.RGB_BYTES, rgb_row["resized_rgb_sha256"])
                    require(audit.stamp(rgb_row["presentation_time"]) == audit.manifest_time(windows[sample]["frames"][index]), "RGB original PTS differs")
                    source = Image.frombytes("RGB", (512, 288), data)
                    candidates = {model: points[(model, sample, index)] for model in MODELS}
                    image = presentation(sample, index, source, candidates, label_points[sample].get(index), windows[sample], reports[sample])
                    displayed.append({"frame_index": index, "original_pts": rgb_row["presentation_time"], "rgb_sha256": rgb_row["resized_rgb_sha256"]})
                    if FIXED_STILLS.get(sample) == index:
                        path = temporary / f"{sample}-frame-{index:03d}-triple.png"
                        image.save(path); path.chmod(0o600)
                        stills.append({"file": path.name, "sha256": audit.sha_file(path), "sample_id": sample, "frame_index": index,
                                       "selection": "predeclared train-006 frame10 / eval-002 frame72"})
                    yield image
            video = encode_video(temporary / (sample + ".mp4"), frames())
            video.update(sample_id=sample, models=list(MODELS), displayed_inputs=displayed,
                         source_nominal_fps=reports[sample]["nominal_fps"], slowed_by=reports[sample]["nominal_fps"] / 15)
            videos.append(video)
            print(f"CAUSAL_VIEW_OK {sample}:120 decoded frames/8seconds/15fps/3models", flush=True)
        receipt = {"schema_version": 1, "production": False, "formal_eligible": False, "final_eligible": False,
                   "human_validated": False, "speed_metrics": None, "tool_sha256": audit.sha_file(HERE),
                   "audit_helper_sha256": audit.sha_file(AUDIT_PATH), "pillow_version": pillow_version,
                   "run_completion_sha256": audit.sha_file(root / "completion.json"), "run_report_sha256": audit.sha_file(root / "report.json"),
                   "predictions_sha256": completion["files"]["predictions.jsonl"], "frozen_protocol_sha256": completion["protocol_sha256"],
                   "prediction_rows_verified": 1440, "models": model_receipt, "native_inputs": checked_runs,
                   "videos": videos, "fixed_stills": stills,
                   "ffmpeg_version": subprocess.run(["ffmpeg", "-version"], check=True, capture_output=True, text=True).stdout.splitlines()[0],
                   "display_policy": "Three columns share the same actual native512RGB; only each model's causal_selection is drawn. Existing visible Agent squares only; unknown/unlabelled points are never filled. No oracle or beam overlay.",
                   "limitations": ["All192 existing agent annotations and all4 windows are development data; not independent human truth.",
                       "Each clip shows all120 target frames, omitting48 preceding warmup frames;15fps playback slows60fps4x or30fps2x.",
                       "Past background and association gates are fixed, but8-frame detector has up to7-frame lookahead.",
                       "Final72-step models are both shown regardless of development effect; no automatic winner or speed qualification."]}
        with (temporary / "video-receipt.json").open("x") as handle:
            json.dump(receipt, handle, indent=2, allow_nan=False); handle.write("\n")
        (temporary / "video-receipt.json").chmod(0o600)
        require(not output.exists(), "Output appeared during rendering")
        temporary.rename(output); published = True
        print(json.dumps({"output": str(output), "videos": 4, "fully_decoded_frames": 480, "verified_prediction_rows": 1440}))
    finally:
        if not published: shutil.rmtree(temporary)


class SelfTests(unittest.TestCase):
    def test_prediction_count_duplicate_and_missing_rejected(self):
        rows = [{"model": model, "sample_id": sample, "frame_index": index}
                for model in MODELS for sample in audit.WINDOWS for index in range(120)]
        self.assertEqual(len(index_rows(rows)), 1440)
        with self.assertRaises(ValueError): index_rows(rows[:1400])
        with self.assertRaises(ValueError): index_rows(rows[:-1] + [rows[0]])

    def test_incomplete_failed_missing_fit_run_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "failure.json").write_text("{}")
            with self.assertRaises(ValueError): complete_run(root)
            (root / "failure.json").unlink()
            for value in ({"status": "running"}, {"status": "complete", "completed_fits": ["head_only"]}):
                (root / "completion.json").write_text(json.dumps(value))
                with self.assertRaises(ValueError): complete_run(root)

    def test_hash_and_pts_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / "artifact").write_bytes(b"abc")
            with self.assertRaises(ValueError): file_hashes(root, {"artifact": "0" * 64})
        with self.assertRaises(ValueError): audit.stamp({"timescale": 600})

    def test_unknown_and_unlabelled_never_drawn(self):
        self.assertIsNone(agent_point(None, 1280, 720))
        self.assertIsNone(agent_point({"status": "unknown", "label_original_xy": [300, 200]}, 1280, 720))
        self.assertEqual(agent_point({"status": "visible", "label_original_xy": [300, 200]}, 1280, 720), [300, 200])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run"); parser.add_argument("--output")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)).wasSuccessful() else 1
    if not args.run or not args.output: parser.error("--run and --output are required")
    try:
        build(args)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print("CAUSAL_VIEW_REFUSED: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
