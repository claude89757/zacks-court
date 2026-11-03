#!/usr/bin/env python3
"""Four-column private evidence for one completed hard-negative experiment.

The three historical models and one new model share the same actual512RGB.
Only causal selections and existing visible Agent rectangles are drawn.
"""
import argparse
from fractions import Fraction
from functools import lru_cache
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
from PIL import Image, ImageDraw, ImageFont, __version__ as pillow_version

HERE = Path(__file__).resolve()
PREVIOUS_VIEW = HERE.with_name("ball-causal-tune-view.py")
spec = importlib.util.spec_from_file_location("hardnegative_view_frozen_previous", PREVIOUS_VIEW)
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)
audit, require = previous.audit, previous.require
NEW_MODEL = "hardnegative_decoder_head"
MODELS = previous.MODELS + (NEW_MODEL,)
COLORS = ("#39d9ec", "#ffab52", "#76e6ab", "#ffe26b")
MAGENTA, BACKGROUND = "#ff79dc", "#101820"
SIZE = (2048, 512)
FIXED_STILLS = {"train-006": 10, "eval-002": 72}


def new_run(root, old_root, old_completion, old_protocol, old_models):
    require(not (root / "failure.json").exists(), "Failed new run is not renderable")
    completion = audit.load_json(root / "completion.json")
    require(completion.get("status") == "complete" and completion.get("completed_fits") == [NEW_MODEL],
            "Missing completed single hard-negative fit")
    require(completion.get("predicted_frames") == 480 and completion.get("previous_control_models") == list(previous.MODELS),
            "Unexpected new/control model inventory")
    require(completion.get("previous_completion_sha256") == audit.sha_file(old_root / "completion.json"),
            "New run refers to another old experiment")
    previous.file_hashes(root, completion["files"])
    required = ("protocol.json", "receipt.json", "report.json", "predictions.jsonl", "training.json",
                NEW_MODEL + ".pt", NEW_MODEL + "-evaluation.json")
    require(all(name in completion["files"] for name in required), "Missing registered new artifact")
    protocol = audit.load_json(root / "protocol.json")
    receipt = audit.load_json(root / "receipt.json")
    report = audit.load_json(root / "report.json")
    require(audit.sha_file(root / "protocol.json") == completion["protocol_sha256"] == receipt["protocol_sha256"] == report["protocol_sha256"],
            "New frozen protocol identity differs")
    require(receipt["runner_sha256"] == completion["runner_sha256"], "New runner identity differs")
    require(protocol["paths"]["previous_run"] == str(old_root) and protocol["previous_completion_sha256"] == audit.sha_file(old_root / "completion.json")
            and protocol["previous_protocol_sha256"] == old_completion["protocol_sha256"], "Previous experiment binding differs")
    require(protocol["previous_models"] == old_models and receipt["files"] == protocol["files"], "Previous model/input receipt differs")
    for field in ("candidate_rule", "causal_gate", "causal_gate_parameters", "background", "tensor"):
        require(protocol[field] == old_protocol[field], "Fixed inference policy differs: " + field)
    require(protocol["exact72_step_schedule"] == old_protocol["exact72_step_schedule"] and protocol["supervised_frame_occurrences_per_fit"] == 568,
            "New fit schedule differs")
    for path, expected in {**protocol["files"], **protocol["dependencies"]}.items():
        require(audit.sha_file(path) == expected, "Frozen new input/comparison/helper changed: " + path)
    require(report.get("single_new_fit") is True and report.get("previous_controls_refit_or_reevaluated") is False
            and report.get("all_frozen_inputs_and_comparison_artifacts_unchanged") is True, "Expected fixed old controls and one fit")
    require(report.get("production") is False and report.get("formal_eligible") is False and report.get("speed_metrics", "missing") is None,
            "Unexpected qualification/speed claim")
    fitting = audit.load_json(root / "training.json")
    evaluation = audit.load_json(root / (NEW_MODEL + "-evaluation.json"))
    require(fitting == report["training"] and evaluation == report["evaluation"], "Final new report differs")
    require(fitting["model"] == NEW_MODEL and fitting["mode"] == "decoder_head" and fitting["steps"] == 72
            and [row["step"] for row in fitting["history"]] == list(range(72)) and fitting["supervised_frame_occurrences"] == 568,
            "New fit is not the complete final72-step experiment")
    for field in ("all17_first_split_forwards_exact", "all17_final_split_forwards_exact", "safe_reloaded_full_model_identical"):
        require(fitting[field] is True, "Missing new fit verification: " + field)
    require(fitting["initial_model_state_sha256"] == old_models["base"]["model_state_sha256"], "New fit did not start from same official base")
    require(fitting["final_model_state_sha256"] == evaluation["model_state_sha256"] and evaluation["model"] == NEW_MODEL
            and evaluation["model_unchanged"] is True and evaluation["frame_count"] == 480 and evaluation["batch_count"] == 60,
            "New evaluation model/state inventory differs")
    require(fitting["frozen_nontrainable_before"] == fitting["frozen_nontrainable_after"]
            and fitting["bn_running_buffers_before"] == fitting["bn_running_buffers_after"], "New frozen state/BN buffers changed")
    require(fitting["checkpoint"] == NEW_MODEL + ".pt" and fitting["checkpoint_sha256"] == audit.sha_file(root / fitting["checkpoint"]),
            "New checkpoint digest differs")
    model_receipt = {"model_state_sha256": audit.valid_sha(evaluation["model_state_sha256"]),
        "checkpoint": fitting["checkpoint"], "checkpoint_sha256": fitting["checkpoint_sha256"],
        "evaluation_sha256": audit.sha_file(root / (NEW_MODEL + "-evaluation.json")),
        "training_sha256": audit.sha_file(root / "training.json")}
    return completion, protocol, model_receipt


def index_new_rows(rows):
    require(len(rows) == 480, "Expected exactly480 new model predictions")
    result = {}
    for row in rows:
        sample, index = row["sample_id"], row["frame_index"]
        require(row["model"] == NEW_MODEL and sample in audit.WINDOWS and type(index) is int and 0 <= index < 120,
                "Unexpected new prediction identity")
        key = (NEW_MODEL, sample, index)
        require(key not in result, "Duplicate new model/source/frame")
        result[key] = row
    require(set(result) == {(NEW_MODEL, sample, index) for sample in audit.WINDOWS for index in range(120)},
            "Missing new model/source/frame")
    return result


@lru_cache(maxsize=8)
def font(size):
    return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", size)


def panel_point(value, width, height):
    value = previous.xy(value, width, height)
    return None if value is None else (value[0] * 512 / width, value[1] * 288 / height)


def marker(draw, value, color, square=False):
    if value is None:
        return
    x, y = value
    if square:
        draw.rectangle((x - 4, y - 4, x + 4, y + 4), outline=color, width=2)
    else:
        draw.ellipse((x - 7, y - 7, x + 7, y + 7), outline=color, width=2)
        draw.line((x - 11, y, x - 8, y), fill=color, width=2)
        draw.line((x + 8, y, x + 11, y), fill=color, width=2)


def presentation(sample, index, source, candidates, label, window, native_report):
    require(source.size == (512, 288), "Actual native512RGB required")
    image = Image.new("RGB", SIZE, BACKGROUND)
    draw = ImageDraw.Draw(image)
    frame = window["frames"][index]
    fps = native_report["nominal_fps"]
    draw.text((12, 7), f"PYTORCH DEVELOPMENT / NO SPEED | {sample} | frame {index:03d} | original PTS {frame['source_pts']} x {frame['source_time_base']} = {float(audit.manifest_time(frame)):.6f}s", font=font(20), fill="white")
    draw.text((12, 34), f"All4: SAME actual512RGB + past background48 + original PTS causal gate | {window['width']}x{window['height']} / {fps:g}fps slowed {fps / 15:g}x |15fps /8s", font=font(19), fill="#dce5ef")
    titles = ("BASE / official", "HEAD_ONLY / old final72", "OLD DECODER / final72", "HARD NEGATIVE / new final72")
    agent = previous.agent_point(label, window["width"], window["height"])
    agent = panel_point(agent, window["width"], window["height"])
    for column, (model, color, title) in enumerate(zip(MODELS, COLORS, titles)):
        draw.text((column * 512 + 10, 68), title, font=font(19), fill=color)
        panel = source.copy()  # exact512x288 display, no input resampling
        overlay = ImageDraw.Draw(panel)
        selected = panel_point(candidates[model], window["width"], window["height"])
        marker(overlay, selected, color)
        marker(overlay, agent, MAGENTA, square=True)
        image.paste(panel, (column * 512, 94))
        if selected is None:
            draw.rectangle((column * 512 + 7, 100, column * 512 + 211, 126), fill=BACKGROUND)
            draw.text((column * 512 + 12, 104), "NO SELECTED OUTPUT", font=font(16), fill="white")
    draw.text((12, 394), "Colored circles: each model's CAUSAL selection. MAGENTA rectangles: existing visible AGENT candidates, NOT HUMAN truth.", font=font(19), fill="#dce5ef")
    label_text = "VISIBLE existing Agent candidate" if agent is not None else (
        "UNKNOWN identity: no agent coordinates drawn" if label else "UNLABELLED: no agent coordinates filled")
    draw.text((12, 423), "Agent at this frame: " + label_text + " | first48 warmup not shown", font=font(18), fill=MAGENTA if label else "#c6d1dc")
    draw.text((12, 452), "8-frame detector has up to7-frame lookahead. Same RGB/background/gates; only model weights differ. No oracle, beam or interpolation is drawn.", font=font(18), fill="#c6d1dc")
    draw.text((12, 481), "All4 windows/166visible agent points are development evidence only. No human accuracy, phone performance, physical speed or product qualification.", font=font(17), fill="#c6d1dc")
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
        require(process.wait() == 0, "ffmpeg encode failed: " + error[-1500:])
    except BaseException:
        process.kill(); process.wait(); raise
    require(count == 120, "Expected all120 real target frames")
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
        "stream=nb_read_frames,width,height,duration,avg_frame_rate", "-of", "json", str(path)], check=True, capture_output=True, text=True)
    stream = json.loads(probe.stdout)["streams"][0]
    require(int(stream["nb_read_frames"]) == 120 and (stream["width"], stream["height"]) == SIZE,
            "Decoded video frame count/size differs")
    require(abs(float(stream["duration"]) - 8) < 1e-6 and Fraction(stream["avg_frame_rate"]) == 15, "Video duration/rate differs")
    decoded = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(path),
        "-map", "0:v:0", "-f", "null", "-"], check=True, capture_output=True, text=True)
    require(not decoded.stderr.strip(), "Full ffmpeg decode reported errors")
    path.chmod(0o600)
    return {"file": path.name, "sha256": audit.sha_file(path), "encoded_frames": count, "decoded_frames": 120,
        "width": SIZE[0], "height": SIZE[1], "presentation_fps": 15, "duration_seconds": 8,
        "ffmpeg_full_decode": "passed", "ffprobe_count_frames": stream}


def build(args):
    root, old_root, output = Path(args.run).resolve(), Path(args.previous_run).resolve(), Path(args.output).absolute()
    require(not output.exists() and not output.is_symlink(), "Output exists; choose NEW directory")
    old_completion, old_protocol, model_receipts = previous.complete_run(old_root)
    completion, protocol, model_receipts[NEW_MODEL] = new_run(root, old_root, old_completion, old_protocol, model_receipts)
    with (old_root / "predictions.jsonl").open() as handle:
        rows = previous.index_rows([json.loads(line) for line in handle])
    with (root / "predictions.jsonl").open() as handle:
        rows.update(index_new_rows([json.loads(line) for line in handle]))
    require(len(rows) == 1920, "Expected unique1920 model/source/frame predictions")
    paths = old_protocol["paths"]
    windows = {row["window_id"]: row for row in audit.load_json(paths["old_manifest"])["windows"]}
    labels = audit.load_json(paths["train_labels"])["records"] + audit.load_json(paths["eval_labels"])["records"]
    native_reports, label_points, native_receipts, selected_points = {}, {}, {}, {}
    for sample in audit.WINDOWS:
        checked = audit.audit_run(paths["runs_root"], Path(paths["native_protocols"]) / (sample + ".json"), windows[sample],
            [row for row in labels if row["sample_id"] == sample], audit.sha_file(paths["old_manifest"]))
        native_reports[sample] = audit.load_json(Path(paths["runs_root"]) / sample / "report.json")
        label_points[sample] = {row["frame_index"]: row for row in checked["points"]}
        native_receipts[sample] = {key: checked[key] for key in ("source_window", "source_sha256", "native_report_sha256", "protocol_sha256", "background_sha256")}
        for index in range(120):
            for model in MODELS:
                selected_points[(model, sample, index)] = previous.verify_row(rows[(model, sample, index)], windows[sample]["frames"][index], native_reports[sample]["frames"][index], windows[sample])
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".hardnegative-view-", dir=output.parent)); temporary.chmod(0o700)
    published = False
    try:
        videos, stills = [], []
        for sample in audit.WINDOWS:
            displayed = []
            def frames():
                for index in range(120):
                    rgb = native_reports[sample]["decoded_inputs"][48 + index]
                    data = audit.checked_bytes(Path(paths["runs_root"]) / sample, rgb["resized_rgb_file"], audit.RGB_BYTES, rgb["resized_rgb_sha256"])
                    require(audit.stamp(rgb["presentation_time"]) == audit.manifest_time(windows[sample]["frames"][index]), "Displayed RGB PTS differs")
                    source = Image.frombytes("RGB", (512, 288), data)
                    candidates = {model: selected_points[(model, sample, index)] for model in MODELS}
                    image = presentation(sample, index, source, candidates, label_points[sample].get(index), windows[sample], native_reports[sample])
                    displayed.append({"frame_index": index, "original_pts": rgb["presentation_time"], "rgb_sha256": rgb["resized_rgb_sha256"]})
                    if FIXED_STILLS.get(sample) == index:
                        path = temporary / f"{sample}-frame-{index:03d}-four.png"
                        image.save(path); path.chmod(0o600)
                        stills.append({"file": path.name, "sha256": audit.sha_file(path), "sample_id": sample, "frame_index": index,
                            "selection": "predeclared train-006 frame10 / eval-002 frame72"})
                    yield image
            video = encode_video(temporary / (sample + ".mp4"), frames())
            video.update(sample_id=sample, models=list(MODELS), displayed_inputs=displayed,
                         source_nominal_fps=native_reports[sample]["nominal_fps"], slowed_by=native_reports[sample]["nominal_fps"] / 15)
            videos.append(video)
            print(f"HARDNEGATIVE_VIEW_OK {sample}:120 decoded frames/8seconds/15fps/4models", flush=True)
        receipt = {"schema_version": 1, "production": False, "formal_eligible": False, "final_eligible": False,
            "human_validated": False, "speed_metrics": None, "tool_sha256": audit.sha_file(HERE),
            "previous_view_helper_sha256": audit.sha_file(PREVIOUS_VIEW), "native_audit_helper_sha256": audit.sha_file(previous.AUDIT_PATH),
            "pillow_version": pillow_version, "new_completion_sha256": audit.sha_file(root / "completion.json"),
            "previous_completion_sha256": audit.sha_file(old_root / "completion.json"),
            "new_predictions_sha256": completion["files"]["predictions.jsonl"],
            "previous_predictions_sha256": old_completion["files"]["predictions.jsonl"],
            "new_protocol_sha256": completion["protocol_sha256"], "previous_protocol_sha256": old_completion["protocol_sha256"],
            "unique_prediction_rows_verified": 1920, "models": model_receipts, "native_inputs": native_receipts,
            "videos": videos, "fixed_stills": stills,
            "ffmpeg_version": subprocess.run(["ffmpeg", "-version"], check=True, capture_output=True, text=True).stdout.splitlines()[0],
            "display_policy": "Four exact512x288 actual native RGB copies; per-model causal_selection circles and existing visible Agent rectangles only. No oracle, beam or interpolation.",
            "limits": ["All4 windows/192 agent candidates are development data;166visible are not human truth;26unknown points are never filled.",
                "First48 background warmup frames omitted; all120 targets shown at15fps,60fps slowed4x and30fps slowed2x.",
                "Background and association use the past, while8-frame detector has up to7-frame lookahead.",
                "All final72-step fits are shown regardless of effects. No automatic winner, camera performance or physical speed qualification."]}
        with (temporary / "video-receipt.json").open("x") as handle:
            json.dump(receipt, handle, indent=2, allow_nan=False); handle.write("\n")
        (temporary / "video-receipt.json").chmod(0o600)
        require(not output.exists(), "Output appeared during rendering")
        temporary.rename(output); published = True
        print(json.dumps({"output": str(output), "videos": 4, "fully_decoded_frames": 480, "unique_model_predictions": 1920}))
    finally:
        if not published: shutil.rmtree(temporary)


class SelfTests(unittest.TestCase):
    def test_count_duplicate_and_model_identity_rejected(self):
        rows = [{"model": NEW_MODEL, "sample_id": sample, "frame_index": index} for sample in audit.WINDOWS for index in range(120)]
        self.assertEqual(len(index_new_rows(rows)), 480)
        with self.assertRaises(ValueError): index_new_rows(rows[:-1])
        with self.assertRaises(ValueError): index_new_rows(rows[:-1] + [rows[0]])
        with self.assertRaises(ValueError): index_new_rows([{**rows[0], "model": "oracle"}] + rows[1:])

    def test_coordinate_mapping_and_unknown_point(self):
        self.assertEqual(panel_point([960, 540], 1920, 1080), (256, 144))
        self.assertEqual(panel_point([640, 360], 1280, 720), (256, 144))
        self.assertIsNone(panel_point(None, 1280, 720))
        self.assertIsNone(previous.agent_point({"status": "unknown", "label_original_xy": [100, 100]}, 1280, 720))
        with self.assertRaises(ValueError): panel_point([1280, 720], 1280, 720)

    def test_failed_or_incomplete_new_run_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "failure.json").write_text("{}")
            with self.assertRaises(ValueError): new_run(root, root, {}, {}, {})
            (root / "failure.json").unlink()
            for completion in ({"status": "running"}, {"status": "complete", "completed_fits": []}):
                (root / "completion.json").write_text(json.dumps(completion))
                with self.assertRaises(ValueError): new_run(root, root, {}, {}, {})

    def test_hash_and_missing_pts_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / "artifact").write_bytes(b"actual")
            with self.assertRaises(ValueError): previous.file_hashes(root, {"artifact": "0" * 64})
        with self.assertRaises(ValueError): audit.stamp({"timescale": 600})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run"); parser.add_argument("--previous-run"); parser.add_argument("--output")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)).wasSuccessful() else 1
    if not args.run or not args.previous_run or not args.output: parser.error("--run --previous-run --output are required")
    try:
        build(args)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print("HARDNEGATIVE_VIEW_REFUSED: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
