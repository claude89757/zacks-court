#!/usr/bin/env python3
"""Frozen, diagnostic-only fine-tuning on the actual native RGB/past background.

propose writes a reviewable protocol without fitting. run requires BOTH explicit
execution and agent-label authorization; failures preserve partial artifacts.
No video decoding, label mutation, downloads, model selection or speed output.
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
import tempfile
import time
import traceback
import unittest

sys.dont_write_bytecode = True
import cv2
import numpy as np
import PIL
import torch

ROOT = Path(__file__).resolve().parents[1]
HERE = Path(__file__).resolve()
TRAIN_WINDOWS = ("train-006", "train-007", "train-008")
MODES = ("head_only", "decoder_head")
INTENT_PATH = ROOT / ".local/speed-training/causal-tune-20261029/intent.json"
FLAGS = {"production": False, "formal_eligible": False, "final_eligible": False,
         "human_validated": False, "physical_accuracy_validated": False,
         "speed_model_accepted": False, "speed_metrics": None}


def module(filename, name):
    spec = importlib.util.spec_from_file_location(name, HERE.with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


tune = module("ball-track-tune.py", "causal_tune_legacy")
assoc = module("ball-track-associate.py", "causal_tune_association")
native = module("ball-native-video-audit.py", "causal_tune_native_audit")
require = tune.require


def write(path, value):
    with Path(path).open("x") as handle:
        json.dump(value, handle, indent=2, sort_keys=True, allow_nan=False)
        handle.write("\n")
    Path(path).chmod(0o600)


def digest(value):
    return hashlib.sha256(tune.canonical(value).encode()).hexdigest()


def versions():
    return {"python": sys.version, "executable": sys.executable, "torch": str(torch.__version__),
            "numpy": np.__version__, "opencv": cv2.__version__, "pillow": PIL.__version__}


def bn_names(model):
    affine, buffers = set(), set()
    for name, layer in model.named_modules():
        if isinstance(layer, torch.nn.modules.batchnorm._BatchNorm):
            affine.update(name + "." + key for key, _ in layer.named_parameters(recurse=False))
            buffers.update(name + "." + key for key, _ in layer.named_buffers(recurse=False))
    return affine, buffers


def model_contract(mode):
    model = tune.factory(mode)
    require(all(parameter.device.type == "cpu" and parameter.dtype == torch.float32 for parameter in model.parameters()),
            "Model parameters must be CPU float32")
    trainable = sorted(name for name, parameter in model.named_parameters() if parameter.requires_grad)
    affine, buffers = bn_names(model)
    result = {"mode": mode, "trainable_parameter_count": sum(parameter.numel() for parameter in model.parameters() if parameter.requires_grad),
              "trainable_state_names": trainable, "trainable_names_sha256": digest(trainable),
              "trainable_bn_affine_names": sorted(set(trainable) & affine),
              "trainable_bn_affine_names_sha256": digest(sorted(set(trainable) & affine)),
              "frozen_bn_buffer_names": sorted(buffers), "bn_policy": "eval; running buffers frozen, decoder-head affine trainable per unchanged legacy factory"}
    expected = 520 if mode == "head_only" else 148232
    require(result["trainable_parameter_count"] == expected, "Legacy trainable parameter contract changed")
    return result


class Inputs:
    """Only four frozen backgrounds remain resident. RGB/tensors are read on demand."""
    def __init__(self, paths):
        self.paths = paths
        self.manifest = native.load_json(paths["old_manifest"])
        self.windows = {row["window_id"]: row for row in self.manifest["windows"]}
        require(set(self.windows) == set(native.WINDOWS) and len(self.manifest["windows"]) == 4, "Expected four frozen windows")
        self.train_labels = native.load_json(paths["train_labels"])["records"]
        self.eval_labels = native.load_json(paths["eval_labels"])["records"]
        require(Counter(row["status"] for row in self.train_labels) == {"visible": 134, "unknown": 10}, "Train label counts changed")
        require(Counter(row["status"] for row in self.eval_labels) == {"visible": 32, "unknown": 16}, "Slow development label counts changed")
        self.labels = {(row["sample_id"], row["frame_index"]): row for row in self.train_labels + self.eval_labels}
        require(len(self.labels) == 192, "Duplicate/missing agent labels")
        self.reports, self.backgrounds, self.audit_reports = {}, {}, {}
        self.files = {}
        for name in ("old_manifest", "train_labels", "eval_labels", "intent"):
            self.record(Path(paths[name]))
        for name in native.WINDOWS:
            root = Path(paths["runs_root"]) / name
            protocol = Path(paths["native_protocols"]) / (name + ".json")
            labels = [label for (sample, _), label in self.labels.items() if sample == name]
            checked = native.audit_run(paths["runs_root"], protocol, self.windows[name], labels,
                                       tune.sha(paths["old_manifest"]))
            self.audit_reports[name] = {key: checked[key] for key in (
                "source_window", "source_sha256", "native_report_sha256", "protocol_sha256",
                "native_model_manifest_sha256", "decoded_pts_verified", "old_target_pts_verified",
                "resized_rgb_hashes_verified", "background_sha256", "tensor_windows")}
            report = native.load_json(root / "report.json")
            require(report.get("range_decoding_strategy") and report.get("total_decoded_samples_including_preroll", 0) >= 168,
                    "Expected native-v3 reader diagnostics")
            self.reports[name] = report
            for path in (root / "report.json", root / "input-protocol.json", protocol,
                         root / "first-background.rgb", root / "first-window.tensor.f32le", root / "first-window.heatmaps.f32le"):
                self.record(path)
            for row in report["decoded_inputs"]:
                path = (root / row["resized_rgb_file"]).resolve()
                self.record(path, row["resized_rgb_sha256"])
            background = native.prefix_median([self.rgb(name, index) for index in range(48)])
            require(native.sha_bytes(background.tobytes()) == checked["background_sha256"], "Native causal background differs")
            self.backgrounds[name] = background
        require(len({report["native_model_manifest_sha256"] for report in self.audit_reports.values()}) == 1,
                "Native model manifest differs across runs")
        self.eligible = []
        for name in TRAIN_WINDOWS:
            for start in range(0, 120, 8):
                _, mask, _ = self.targets(name, start)
                if mask.sum().item() > 0:
                    self.eligible.append({"sample_id": name, "start": start,
                                          "supervised_frames": int(mask.sum().item())})
        require(len(self.eligible) == 17 and sum(row["supervised_frames"] for row in self.eligible) == 134,
                "Expected17 supervised batches containing exactly134 visible train frames")

    def record(self, path, expected=None):
        path = Path(path).resolve()
        actual = tune.sha(path)
        require(expected is None or actual == expected, "Frozen input hash differs: " + str(path))
        self.files[str(path)] = actual

    def rgb(self, name, decode_index):
        row = self.reports[name]["decoded_inputs"][decode_index]
        root = Path(self.paths["runs_root"]) / name
        data = native.checked_bytes(root, row["resized_rgb_file"], native.RGB_BYTES, row["resized_rgb_sha256"])
        return np.frombuffer(data, dtype=np.uint8).reshape(native.RGB_SHAPE)

    def tensor(self, name, start):
        require(start in range(0, 120, 8), "Invalid real model window start")
        array = native.make_tensor(self.backgrounds[name], [self.rgb(name, 48 + start + offset) for offset in range(8)])
        require(native.sha_bytes(array.tobytes()) == self.reports[name]["windows"][start // 8]["tensor_sha256"],
                "Native NCHW tensor SHA differs")
        return torch.from_numpy(array)

    def targets(self, name, start):
        require(name in TRAIN_WINDOWS, "Slow source must never supply training targets")
        window = self.windows[name]
        targets, masks, geometry = [], [], []
        for index in range(start, start + 8):
            target, mask, geo = tune.make_target(self.labels.get((name, index)),
                                                (0, 0, window["width"], window["height"]))
            targets.append(target); masks.append(mask); geometry.append(geo)
        return (torch.from_numpy(np.stack(targets))[None],
                torch.tensor([masks], dtype=torch.float32), geometry)

    def verify_unchanged(self):
        for path, expected in self.files.items():
            require(tune.sha(path) == expected, "Input changed during experiment: " + path)


def proposal(paths):
    expected_intent_sha = native.valid_sha(paths["intent_sha256"])
    require(tune.sha(paths["intent"]) == expected_intent_sha, "Pre-experiment intent changed")
    intent = native.load_json(paths["intent"])
    require(paths["runs_root"] == intent["inputs"]["runs_root"], "Runs root differs from frozen intent")
    for key, value in {"windows": list(TRAIN_WINDOWS), "visible_unique_frames": 134, "unknown_candidate_frames": 10,
                       "optimizer": "Adam", "learning_rate": 1e-4, "steps_per_fit": 72, "seed": 20261029,
                       "device": "cpu", "dtype": "float32", "threads": 4, "interop_threads": 1,
                       "variants": list(MODES), "cache_mib": 4096}.items():
        require(intent["training"].get(key) == value, "Frozen intent differs from fixed experiment: " + key)
    require(intent["comparisons"]["candidate_threshold"] == .3 and intent["comparisons"]["top_k"] == 20,
            "Intent candidate recipe differs")
    inputs = Inputs(paths)
    dependencies = {str(path.resolve()): tune.sha(path) for path in (
        HERE, HERE.with_name("ball-track-tune.py"), HERE.with_name("ball-track-associate.py"),
        HERE.with_name("ball-native-video-audit.py"), tune.HELPER)}
    schedule = [inputs.eligible[step % len(inputs.eligible)] for step in range(72)]
    exposures = Counter()
    for item in schedule:
        for index in range(item["start"], item["start"] + 8):
            label = inputs.labels.get((item["sample_id"], index))
            if label and label["status"] == "visible" and label["target_identity"] == "confirmed":
                exposures[f"{item['sample_id']}:{index}"] += 1
    return {"schema_version": 1, **FLAGS, "purpose": "past-background fixed-input diagnostic agent-label fine-tuning",
            "all_windows_are_development": True, "diagnostic_agent_label_authorization_required": True,
            "frozen_intent": {"path": paths["intent"], "sha256": expected_intent_sha, "document": intent},
            "paths": paths, "input_files": inputs.files, "native_input_audits": inputs.audit_reports,
            "dependencies": dependencies, "official_source": tune.source_check(), "runtime": versions(),
            "seed": 20261029, "device": "cpu", "dtype": "float32", "threads": 4, "interop_threads": 1,
            "optimizer": "Adam", "learning_rate": 1e-4, "steps_per_fit": 72, "cache_mib": 4096,
            "variants": [model_contract(mode) for mode in MODES], "eligible_training_batches": inputs.eligible,
            "exact72_step_schedule": schedule,
            "supervised_frame_occurrences_per_fit": sum(exposures.values()),
            "supervised_occurrences_per_unique_train_frame": dict(sorted(exposures.items())),
            "batch_schedule": "fixed lexical train window/start order, repeat17 batches cyclically for72 steps",
            "loss": "unchanged legacy balanced_wbce; confirmed visible only; unknown/unlabelled loss-mask0",
            "selection": "final72-step weights only; independent official base for each fit; no best-checkpoint/model selection",
            "background": "np.median(actual native resized first48 RGB).astype(uint8), frozen before all120 target frames",
            "tensor": "unchanged native RGB background +8 real frames; Float32 NCHW1x27x288x512 /255; all60 SHA checked",
            "candidate_rule": {"threshold": 0.3, "operator": ">", "connectivity": 8, "top_k": 20,
                "identifier": "minimum foreground raster-flat index +1, NEVER OpenCV component ID",
                "sort": "peak descending, bbox area descending, raster identifier ascending",
                "point": "integer bounding-box center mapped to original image, same Swift truncation"},
            "causal_gate": "same Swift source PTS gap/age/CV/missing2.5 and exact-cost raster-ID tie; no interpolation",
            "causal_gate_parameters": {key: assoc.PARAMS[key] for key in (
                "missing_cost", "position_sigma_base", "position_sigma_per_second", "max_displacement_base",
                "max_displacement_per_second", "max_prediction_residual_sigma", "max_last_seen_age_seconds",
                "source_gap_nominal_period_factor")},
            "pre_fit_gate": "Torchbase vs native: all480 ordered structural candidate banks and causal selections must match; scores/costs atol1e-5; SHA differences alone are not failure",
            "pre_fit_raw_numeric_gate": {"scope": "first4 exported native heatmap batches, one per source window",
                "max_absolute_difference": 1e-5, "strict_threshold_0.3_mask_flips": 0,
                "threshold_0.1_and_0.5": "diagnostic only", "require_all_four": True,
                "unexported56": "SHA comparison and480-frame bank/selection gate only; no invented numeric bound"},
            "native_heatmap_comparison": "all60 batch SHA; only first4 exported raw batches permit absdiff/mask flips; no invented maxdiff for other56",
            "success_rule_each_fit_vs_own_torch_base": {
                "train134_within10": "strictly greater", "train134_wrong_over20": "not greater",
                "slow32_within10": "not lower", "slow32_wrong_over20": "not greater",
                "each_window": "report separately, not an additional selection rule",
                "author_and_oracle": "separate diagnostics; never the causal score or eligibility"},
            "limitations": ["All192 agent candidates/166visible are development evidence, not blinded human/physical truth.",
                "3 train windows134visible/10unknown; slow window32visible/16unknown; no unknown negative labels.",
                "Background contains only preceding frames, but8-frame detector still has up to7-frame lookahead.",
                "Input RGB/decode/background and gates stay fixed across fits; model parameters are the only intervention.",
                "No source001 access, camera backend change, speed output, automatic winner or formal qualification."]}


def candidate_bank(heatmap, width, height):
    require(heatmap.shape == (288, 512) and heatmap.dtype == np.float32 and np.isfinite(heatmap).all()
            and np.min(heatmap) >= 0 and np.max(heatmap) <= 1, "Invalid heatmap")
    mask = (heatmap > np.float32(0.3)).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    candidates = []
    for component_id in range(1, count):
        x, y, w, h, area = map(int, stats[component_id])
        region = labels[y:y + h, x:x + w] == component_id
        values = heatmap[y:y + h, x:x + w][region]
        seed = y * 512 + int(np.flatnonzero(labels[y] == component_id)[0]) + 1
        xy = [int((x + w // 2) * width / 512), int((y + h // 2) * height / 288)]
        candidates.append({"identifier": seed, "box": [x, y, w, h], "originalXY": xy,
            "equivalentXY": [xy[0] * 1280 / width, xy[1] * 720 / height], "peak": float(values.max()),
            "mean": float(values.sum(dtype=np.float64) / area), "pixelArea": area})
    candidates.sort(key=lambda row: (-row["peak"], -row["box"][2] * row["box"][3], row["identifier"]))
    contours, _ = cv2.findContours(mask * 255, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    boxes = [cv2.boundingRect(contour) for contour in contours]
    author = None
    if boxes:
        x, y, w, h = max(boxes, key=lambda box: box[2] * box[3])
        if x + w // 2 or y + h // 2:
            author = [int((x + w // 2) * width / 512), int((y + h // 2) * height / 288)]
    return {"candidates": candidates[:20], "totalComponents": count - 1,
            "truncatedComponents": max(0, count - 1 - 20)}, author


class CausalGate:
    """Swift IndependentCausalBallTracker rule, with exact rational source times."""
    def __init__(self, fps):
        self.fps = Fraction(str(fps))
        require(self.fps > 0, "Invalid source FPS")
        self.previous = None
        self.source = None
        self.history = []

    def select(self, bank, pts, source):
        require(isinstance(pts, Fraction) and source, "Missing rational source PTS/source")
        reason = None
        if self.source != source:
            self.history = []; self.previous = None; reason = "source_changed"
        if self.previous is not None:
            require(pts > self.previous, "Nonpositive source PTS interval")
            if float(pts - self.previous) > 1.5 / float(self.fps):
                self.history = []; reason = "source_gap"
        if self.history and float(pts - self.history[-1][0]) > 0.20:
            self.history = []; reason = "last_seen_timeout"
        self.source = source; self.previous = pts
        best, best_cost = None, 2.5
        for candidate in bank["candidates"]:
            xy = candidate["equivalentXY"]
            cost = -math.log(max(candidate["peak"], 1e-6))
            if self.history:
                last_time, last_xy = self.history[-1]
                dt = float(pts - last_time)
                require(dt > 0, "Invalid last-seen PTS")
                if math.dist(xy, last_xy) > 8 + 3000 * dt:
                    continue
                predicted = last_xy
                if len(self.history) == 2:
                    earlier_time, earlier_xy = self.history[0]
                    old_dt = float(last_time - earlier_time)
                    predicted = [last_xy[i] + (last_xy[i] - earlier_xy[i]) * dt / old_dt for i in (0, 1)]
                residual = math.dist(xy, predicted)
                sigma = 8 + 800 * dt
                if residual > 3 * sigma:
                    continue
                cost += 0.5 * (residual / sigma) ** 2
            if cost < best_cost or (cost == best_cost and (best is None or candidate["identifier"] < best["identifier"])):
                best, best_cost = candidate, cost
        linked = best is not None and bool(self.history)
        if best:
            self.history = (self.history + [(pts, best["equivalentXY"])])[-2:]
        return {"candidate": best, "linkedToPast": linked, "resetReason": reason,
                "missingReason": None if best else ("no_candidate" if not bank["candidates"] else "association_rejected"),
                "incrementalCost": best_cost}


def bank_alignment(actual, reference):
    reasons = []
    for key in ("totalComponents", "truncatedComponents"):
        if actual[key] != reference[key]: reasons.append(key)
    if len(actual["candidates"]) != len(reference["candidates"]): reasons.append("candidate_count")
    peak_difference = mean_difference = 0.0
    for index, (a, b) in enumerate(zip(actual["candidates"], reference["candidates"])):
        for key in ("identifier", "box", "originalXY", "pixelArea"):
            if a[key] != b[key]: reasons.append(f"candidate{index}.{key}")
        for key in ("peak", "mean"):
            difference = abs(a[key] - b[key])
            if key == "peak": peak_difference = max(peak_difference, difference)
            else: mean_difference = max(mean_difference, difference)
            if difference > 1e-5: reasons.append(f"candidate{index}.{key}")
        if any(abs(x - y) > 1e-9 for x, y in zip(a["equivalentXY"], b["equivalentXY"])):
            reasons.append(f"candidate{index}.equivalentXY")
    return {"passed": not reasons, "differences": reasons, "max_peak_difference": peak_difference,
            "max_mean_difference": mean_difference}


def selection_alignment(actual, reference):
    reasons = []
    for key in ("linkedToPast", "resetReason", "missingReason"):
        if actual[key] != reference.get(key): reasons.append(key)
    def identity(value):
        return None if value is None else (value["identifier"], value["originalXY"])
    if identity(actual["candidate"]) != identity(reference.get("candidate")): reasons.append("selected_candidate")
    difference = abs(actual["incrementalCost"] - reference["incrementalCost"])
    if difference > 1e-5: reasons.append("incrementalCost")
    return {"passed": not reasons, "differences": reasons, "incremental_cost_difference": difference}


def scoped_metrics(points):
    return {"all166_development": native.summarize_points(points),
            "train134_development": native.summarize_points([row for row in points if row["sample_id"] in TRAIN_WINDOWS]),
            "slow32_development": native.summarize_points([row for row in points if row["sample_id"] == "eval-002"]),
            "per_window": {name: native.summarize_points([row for row in points if row["sample_id"] == name]) for name in native.WINDOWS}}


def native_numeric_budget(max_absolute_difference, strict_03_mask_flips):
    return max_absolute_difference <= 1e-5 and strict_03_mask_flips == 0


def evaluate(model, name, inputs, out, prediction_stream):
    before = tune.state_sha(model)
    records, all_points = [], {"causal": [], "author_max_area": [], "oracle_topK_upper_bound": []}
    alignment_failures = []
    numeric_failures = []
    for sample in native.WINDOWS:
        window, reference = inputs.windows[sample], inputs.reports[sample]
        gate = CausalGate(reference["nominal_fps"])
        for start in range(0, 120, 8):
            with torch.inference_mode():
                maps = model(inputs.tensor(sample, start)).detach().cpu().numpy().astype("<f4", copy=False)
            require(maps.shape == native.HEATMAP_SHAPE and np.isfinite(maps).all(), "Bad model prediction")
            batch_sha = native.sha_bytes(maps.tobytes())
            batch = {"model": name, "sample_id": sample, "start": start, "torch_heatmap_sha256": batch_sha,
                     "native_heatmap_sha256": reference["windows"][start // 8]["heatmaps_sha256"],
                     "bit_exact_to_native": batch_sha == reference["windows"][start // 8]["heatmaps_sha256"],
                     "max_absolute_difference": None, "strict_threshold_mask_flips": None,
                     "numeric_scope": "not_available: remaining56 batches have no exported native heatmap bytes"}
            if start == 0:
                root = Path(inputs.paths["runs_root"]) / sample
                first = reference["windows"][0]
                raw = native.checked_bytes(root, first["heatmaps_file"], math.prod(native.HEATMAP_SHAPE) * 4, first["heatmaps_sha256"])
                native_maps = np.frombuffer(raw, dtype="<f4").reshape(native.HEATMAP_SHAPE)
                difference = np.abs(maps - native_maps)
                batch.update(max_absolute_difference=float(difference.max()), mean_absolute_difference=float(difference.mean()),
                             strict_threshold_mask_flips={str(t): int(np.count_nonzero((maps > np.float32(t)) != (native_maps > np.float32(t)))) for t in (0.1, 0.3, 0.5)},
                             numeric_scope="first real batch only; actual exported native heatmap compared")
                numeric_passed = native_numeric_budget(batch["max_absolute_difference"], batch["strict_threshold_mask_flips"]["0.3"])
                batch["pre_fit_numeric_gate_required"] = name == "base"
                batch["within_preregistered_native_numeric_budget"] = numeric_passed
                if name == "base" and not numeric_passed:
                    numeric_failures.append({"sample_id": sample, "start": start,
                        "max_absolute_difference": batch["max_absolute_difference"],
                        "strict_threshold_0.3_mask_flips": batch["strict_threshold_mask_flips"]["0.3"]})
                artifact = out / f"{name}-{sample}-first.heatmaps.f32le"
                with artifact.open("xb") as handle: handle.write(maps.tobytes())
                artifact.chmod(0o600)
                batch["torch_heatmap_file"] = artifact.name
            records.append(batch)
            for offset in range(8):
                index = start + offset
                frame = window["frames"][index]
                bank, author = candidate_bank(maps[0, offset], window["width"], window["height"])
                selection = gate.select(bank, native.manifest_time(frame), window["source_sha256"])
                label = inputs.labels.get((sample, index))
                oracle = None
                if label and label["status"] == "visible" and bank["candidates"]:
                    oracle = min(bank["candidates"], key=lambda candidate: (
                        math.hypot((candidate["originalXY"][0] - label["x"]) * 1280 / window["width"],
                                   (candidate["originalXY"][1] - label["y"]) * 720 / window["height"]), candidate["identifier"]))["originalXY"]
                row = {**FLAGS, "model": name, "sample_id": sample, "frame_index": index,
                       "source_sha256": window["source_sha256"], "source_pts": frame["source_pts"],
                       "source_time_base": frame["source_time_base"], "time": reference["frames"][index]["time"],
                       "available_at_pts": reference["frames"][index]["available_at_pts"],
                       "window_index": start // 8, "candidate_bank": bank, "causal_selection": selection,
                       "author_max_area_xy": author, "oracle_topK_upper_bound_xy": oracle,
                       "oracle_is_tracker": False, "speed_kmh": None}
                if name == "base":
                    bank_check = bank_alignment(bank, reference["frames"][index]["candidate_bank"])
                    selection_check = selection_alignment(selection, reference["frames"][index])
                    row["native_alignment"] = {"bank": bank_check, "selection": selection_check}
                    if not bank_check["passed"] or not selection_check["passed"]:
                        alignment_failures.append({"sample_id": sample, "frame_index": index,
                                                   "bank": bank_check, "selection": selection_check})
                if label:
                    for selector, xy in (("causal", selection["candidate"]["originalXY"] if selection["candidate"] else None),
                                         ("author_max_area", author), ("oracle_topK_upper_bound", oracle)):
                        all_points[selector].append(native.point_record(label, window, frame, xy))
                prediction_stream.write(tune.canonical(row) + "\n")
            prediction_stream.flush()
            print(f"EVALUATE {name} {sample} frames={start + 8}/120", flush=True)
    require(tune.state_sha(model) == before, "Evaluation mutated model state")
    metrics = {selector: scoped_metrics(points) for selector, points in all_points.items()}
    report = {**FLAGS, "model": name, "model_state_sha256": before, "model_unchanged": True,
              "frame_count": 480, "batch_count": 60, "batch_heatmaps": records,
              "metrics": metrics, "points": all_points,
              "native_alignment": {"required_before_training": name == "base", "frames_checked": 480 if name == "base" else 0,
                  "passed": not alignment_failures and not numeric_failures if name == "base" else None,
                  "failures": alignment_failures, "raw_numeric_failures": numeric_failures,
                  "raw_numeric_gate": {"max_absolute_difference": 1e-5, "strict_threshold_0.3_mask_flips": 0,
                                       "batches_required": 4, "required_before_training": name == "base"},
                  "batch_sha_equal": sum(row["bit_exact_to_native"] for row in records),
                  "batch_sha_different": sum(not row["bit_exact_to_native"] for row in records),
                  "raw_heatmap_comparison_batches": 4,
                  "note": "SHA inequality alone is not a failure; non-exported56 native batches have no numerical maxdiff/mask claim."}}
    write(out / (name + "-evaluation.json"), report)
    return report


def cache_spec(inputs, mode, frozen_sha, sample, start):
    return {"sample_id": sample, "start": start, "mode": mode, "dtype": "float32",
            "tensor_sha256": inputs.reports[sample]["windows"][start // 8]["tensor_sha256"],
            "background_policy": "prefix_median48_resized_rgb", "background_sha256": inputs.audit_reports[sample]["background_sha256"],
            "frozen_prefix_state_sha256": frozen_sha, "base_checkpoint_sha256": tune.BASE_SHA}


def fit(mode, inputs, protocol, protocol_sha, out):
    torch.manual_seed(protocol["seed"])
    model = tune.factory(mode)
    require(model_contract(mode) == next(row for row in protocol["variants"] if row["mode"] == mode), "Model contract drift")
    trainable = {name for name, parameter in model.named_parameters() if parameter.requires_grad}
    affine, buffers = bn_names(model)
    frozen_before = tune.state_sha(model, lambda key: key not in trainable)
    bn_before = tune.state_sha(model, lambda key: key in buffers)
    initial_full_sha = tune.state_sha(model)
    optimizer = torch.optim.Adam([parameter for parameter in model.parameters() if parameter.requires_grad], lr=1e-4)
    cache = tune.FeatureCache(protocol["cache_mib"])
    verified_first, cache_keys = set(), {}
    history = []
    started = time.perf_counter()
    with (out / (mode + "-steps.jsonl")).open("x") as stream:
        for step in range(72):
            item = protocol["exact72_step_schedule"][step]
            require(item == inputs.eligible[step % len(inputs.eligible)], "Frozen cyclic schedule differs")
            sample, start = item["sample_id"], item["start"]
            specification = cache_spec(inputs, mode, frozen_before, sample, start)
            key = digest(specification)
            cache_keys[key] = specification
            x = inputs.tensor(sample, start) if key not in cache.items or key not in verified_first else None
            features = cache.get(key, lambda: tune.frozen_features(model, x, mode))
            if key not in verified_first:
                with torch.no_grad():
                    require(torch.equal(model(x), tune.suffix(model, features, mode)), "Cached split differs from original full forward")
                verified_first.add(key)
            y, mask, geometry = inputs.targets(sample, start)
            require(not model.training and all(not layer.training for layer in model.modules() if isinstance(layer, torch.nn.modules.batchnorm._BatchNorm)), "BN left eval mode")
            optimizer.zero_grad(set_to_none=True)
            prediction = tune.suffix(model, features, mode)
            prediction.retain_grad()
            loss, diagnostics = tune.balanced_wbce(prediction, y, mask)
            require(torch.isfinite(loss).item(), "Nonfinite loss")
            loss.backward()
            masked = [index for index in range(8) if mask[0, index] == 0]
            require(all(torch.count_nonzero(prediction.grad[0, index]).item() == 0 for index in masked), "Unknown/unlabelled output has nonzero loss gradient")
            require(all(parameter.grad is None for name, parameter in model.named_parameters() if name not in trainable), "Frozen parameter has gradient")
            require(all(parameter.grad is not None and torch.isfinite(parameter.grad).all().item()
                        for parameter in model.parameters() if parameter.requires_grad), "Missing/nonfinite trainable gradient")
            norm = math.sqrt(sum(float(parameter.grad.double().square().sum()) for parameter in model.parameters() if parameter.requires_grad and parameter.grad is not None))
            require(math.isfinite(norm) and norm > 0, "Invalid training gradient")
            row = {"step": step, "sequence": item, "frame_mask": mask[0].tolist(), "unknown_loss_gradient_zero": True,
                   "cache_key": key, "loss": diagnostics, "gradient_norm": norm,
                   "label_point_predictions": tune.point_predictions(prediction, geometry)}
            optimizer.step()
            require(all(torch.isfinite(parameter).all().item() for parameter in model.parameters() if parameter.requires_grad),
                    "Nonfinite updated parameter")
            history.append(row)
            stream.write(tune.canonical(row) + "\n"); stream.flush()
            print(f"FIT {mode} step={step + 1}/72 loss={loss.item():.8f}", flush=True)
    require(len(verified_first) == 17, "Not every eligible first cached forward was checked")
    frozen_after = tune.state_sha(model, lambda key: key not in trainable)
    bn_after = tune.state_sha(model, lambda key: key in buffers)
    require(frozen_before == frozen_after and bn_before == bn_after, "Frozen parameters or BN running buffers changed")
    # Final weights, every eligible real batch: compare cached prefix plus current
    # suffix to unchanged official model.forward, with no further optimizer steps.
    for item in inputs.eligible:
        sample, start = item["sample_id"], item["start"]
        x = inputs.tensor(sample, start)
        key = digest(cache_spec(inputs, mode, frozen_before, sample, start))
        features = cache.get(key, lambda: tune.frozen_features(model, x, mode))
        with torch.no_grad():
            require(torch.equal(model(x), tune.suffix(model, features, mode)), "Final cached/full forward mismatch")
    final_sha = tune.state_sha(model)
    checkpoint = {**FLAGS, "parent_sha256": tune.BASE_SHA, "protocol_sha256": protocol_sha, "mode": mode,
                  "initial_model_state_sha256": initial_full_sha, "final_model_state_sha256": final_sha,
                  "trainable_state": {name: tensor.detach().cpu().clone() for name, tensor in model.state_dict().items() if name in trainable}}
    checkpoint_path = out / (mode + ".pt")
    torch.save(checkpoint, checkpoint_path)
    checkpoint_path.chmod(0o600)
    restored = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    require(restored["parent_sha256"] == tune.BASE_SHA and restored["protocol_sha256"] == protocol_sha and restored["mode"] == mode,
            "Checkpoint provenance differs")
    require(set(restored["trainable_state"]) == trainable, "Checkpoint state names differ")
    replay = tune.factory(mode)
    state = replay.state_dict()
    for name, value in restored["trainable_state"].items():
        require(value.dtype == state[name].dtype and value.shape == state[name].shape and torch.isfinite(value).all().item(), "Checkpoint tensor differs/invalid")
        state[name] = value
    replay.load_state_dict(state, strict=True)
    require(tune.state_sha(replay) == final_sha, "Safe checkpoint reload differs from fitted full model")
    require(tune.state_sha(model, lambda key: key not in trainable) == frozen_before, "Final verification changed frozen state")
    report = {**FLAGS, "mode": mode, "steps": 72, "seed": protocol["seed"], "learning_rate": 1e-4,
              "eligible_batches": inputs.eligible, "history": history, "initial_model_state_sha256": initial_full_sha,
              "supervised_frame_occurrences": sum(row["sequence"]["supervised_frames"] for row in history),
              "final_model_state_sha256": final_sha, "frozen_nontrainable_before": frozen_before,
              "frozen_nontrainable_after": frozen_after, "bn_running_buffers_before": bn_before,
              "bn_running_buffers_after": bn_after, "bn_affine_trainable": sorted(trainable & affine),
              "bn_affine_may_change": bool(trainable & affine), "all17_first_split_forwards_exact": True,
              "all17_final_split_forwards_exact": True, "unknown_loss_gradient_zero_every_step": True,
              "safe_reloaded_full_model_identical": True, "checkpoint": checkpoint_path.name,
              "checkpoint_sha256": tune.sha(checkpoint_path), "feature_cache": {
                  "limit_mib": protocol["cache_mib"], "resident_bytes": cache.bytes, "hits": cache.hits,
                  "misses": cache.misses, "fingerprints": cache_keys}, "seconds": time.perf_counter() - started}
    write(out / (mode + "-training.json"), report)
    return replay, report


def success(base, fitted):
    result = {}
    for scope in ("train134_development", "slow32_development"):
        old = base["metrics"]["causal"][scope]
        new = fitted["metrics"]["causal"][scope]
        result[scope] = {"visible_denominator": old["visible_denominator"],
            "base_within10": old["within_equivalent_px"]["10"], "fit_within10": new["within_equivalent_px"]["10"],
            "base_wrong_over20": old["wrong_over20_on_visible"], "fit_wrong_over20": new["wrong_over20_on_visible"],
            "base_missing": old["missing_on_visible"], "fit_missing": new["missing_on_visible"],
            "within10_rule_passed": (new["within_equivalent_px"]["10"] > old["within_equivalent_px"]["10"] if scope.startswith("train") else new["within_equivalent_px"]["10"] >= old["within_equivalent_px"]["10"]),
            "wrong_over20_rule_passed": new["wrong_over20_on_visible"] <= old["wrong_over20_on_visible"]}
    result["development_rule_passed"] = all(value["within10_rule_passed"] and value["wrong_over20_rule_passed"] for value in result.values())
    result["automatic_model_selection"] = False
    return result


def execute(args):
    require(args.execute_frozen_protocol and args.diagnostic_agent_labels,
            "run requires BOTH --execute-frozen-protocol and --diagnostic-agent-labels")
    protocol_path = Path(args.protocol).resolve()
    protocol = native.load_json(protocol_path)
    require(protocol == proposal(protocol["paths"]), "Frozen protocol/input/dependency/runtime drift; do not edit a frozen experiment")
    protocol_sha = tune.sha(protocol_path)
    inputs = Inputs(protocol["paths"])
    out = Path(args.output).resolve()
    require(not out.exists(), "Output exists; choose a NEW directory")
    out.mkdir(parents=True); out.chmod(0o700)
    write(out / "protocol.json", protocol)
    write(out / "receipt.json", {**FLAGS, "protocol_sha256": protocol_sha, "copied_protocol_semantic_sha256": digest(protocol),
          "runner_sha256": tune.sha(HERE), "input_files": inputs.files, "runtime": versions(),
          "created_at": datetime.now(timezone.utc).isoformat(), "training_started_at_receipt_creation": False})
    phase = "base_parity_before_fit"
    completed = []
    try:
        torch.set_num_threads(4)
        torch.set_num_interop_threads(1)
        torch.use_deterministic_algorithms(True)
        torch.set_default_dtype(torch.float32)
        torch.manual_seed(20261029)
        base_model = tune.factory("base")
        with (out / "predictions.jsonl").open("x") as stream:
            base = evaluate(base_model, "base", inputs, out, stream)
            require(base["native_alignment"]["passed"], "PRE_FIT_GATE_FAILED: raw numeric/mask or Torch base bank/causal selection differs from native; inspect base-evaluation.json; no fitting started")
            models, fits = {}, {}
            del base_model
            for mode in MODES:
                phase = "fit_" + mode
                models[mode], fits[mode] = fit(mode, inputs, protocol, protocol_sha, out)
                require(fits[mode]["initial_model_state_sha256"] == base["model_state_sha256"], "Fit did not independently start from same official base")
                completed.append(mode)
            evaluated = {}
            for mode in MODES:
                phase = "evaluate_" + mode
                evaluated[mode] = evaluate(models[mode], mode, inputs, out, stream)
        phase = "final_input_verification"
        inputs.verify_unchanged()
        require(tune.source_check() == protocol["official_source"], "Official base/source changed")
        for path, expected in protocol["dependencies"].items():
            require(tune.sha(path) == expected, "Runner/helper changed during experiment")
        report = {**FLAGS, "protocol_sha256": protocol_sha, "base_native_parity_gate_passed": True,
                  "fitted_modes": list(MODES), "training": fits,
                  "evaluations": {"base": base, **evaluated},
                  "success_rules": {mode: success(base, evaluated[mode]) for mode in MODES},
                  "automatic_model_selection": False, "all_inputs_unchanged": True,
                  "same_rgb_decode_background_across_models": True,
                  "limitations": protocol["limitations"]}
        write(out / "report.json", report)
        files = {path.name: tune.sha(path) for path in out.iterdir() if path.is_file()}
        write(out / "completion.json", {**FLAGS, "status": "complete", "protocol_sha256": protocol_sha,
              "runner_sha256": tune.sha(HERE), "files": files, "completed_fits": completed,
              "predicted_frames": 1440, "base_parity_gate_passed": True})
        print(tune.canonical({"output": str(out), "completed_fits": completed, "predicted_frames": 1440,
                              "development_success": {mode: report["success_rules"][mode]["development_rule_passed"] for mode in MODES}}))
    except BaseException as error:
        write(out / "failure.json", {**FLAGS, "status": "failed", "phase": phase, "error": str(error),
              "completed_fits": completed, "training_started": phase != "base_parity_before_fit",
              "protocol_sha256": protocol_sha, "traceback": traceback.format_exc(),
              "preserved_files": {path.name: tune.sha(path) for path in out.iterdir() if path.is_file()}})
        raise


class SelfTests(unittest.TestCase):
    def test_preregistered_numeric_budget_rejects_tiny_overrun_or_mask_flip(self):
        self.assertTrue(native_numeric_budget(1e-5, 0))
        self.assertFalse(native_numeric_budget(float(np.nextafter(1e-5, math.inf)), 0))
        self.assertFalse(native_numeric_budget(0, 1))

    def test_unknown_gradient_uses_unchanged_legacy_loss(self):
        test = tune.SelfTests("test_unknown_gradient_and_zero_shortcut")
        test.test_unknown_gradient_and_zero_shortcut()

    def test_raster_identifier_is_actual_minimum_not_component_label(self):
        heatmap = np.zeros((288, 512), np.float32)
        heatmap[0, 10] = .9
        heatmap[1, 0] = .9
        heatmap[10, 30:32] = .9
        heatmap[11, 30:32] = .9
        bank, _ = candidate_bank(heatmap, 1280, 720)
        self.assertEqual([row["identifier"] for row in bank["candidates"]], [10 * 512 + 31, 11, 513])
        self.assertEqual([row["pixelArea"] for row in bank["candidates"]], [4, 1, 1])
        gate = CausalGate(60)
        selected = gate.select(bank, Fraction(1), "source")
        self.assertEqual(selected["candidate"]["identifier"], 11)

    def test_strict_threshold_missing_denominator_and_unknown(self):
        heatmap = np.full((288, 512), np.float32(.3), dtype=np.float32)
        bank, author = candidate_bank(heatmap, 1280, 720)
        self.assertFalse(bank["candidates"]); self.assertIsNone(author)
        point = {"status": "visible", "candidate_original_xy": None, "distance_1280x720_equivalent_px": None}
        summary = native.summarize_points([point])
        self.assertEqual(summary["visible_denominator"], 1)
        self.assertEqual(summary["missing_on_visible"], 1)
        self.assertEqual(summary["wrong_over20_on_visible"], 0)
        self.assertIsNone(native.summarize_points([])["within_rates_over_all_visible"]["10"])

    def test_original_pts_gap_and_duplicates_rejected(self):
        gate = CausalGate(60)
        empty = {"candidates": []}
        gate.select(empty, Fraction(1), "source")
        with self.assertRaises(ValueError): gate.select(empty, Fraction(1), "source")
        self.assertEqual(gate.select(empty, Fraction(2), "source")["resetReason"], "source_gap")
        with self.assertRaises(ValueError): native.stamp({"timescale": 600})
        self.assertEqual(native.stamp({"value": 7, "timescale": 60}), Fraction(7, 60))

    def test_hash_refusal_and_cache_key_binds_policy_and_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            Path(temporary, "input.rgb").write_bytes(b"abc")
            with self.assertRaises(ValueError): native.checked_bytes(temporary, "input.rgb", 3, "0" * 64)
        spec = {"tensor_sha256": "a", "background_policy": "prefix48", "background_sha256": "b", "frozen_prefix_state_sha256": "c", "mode": "head_only", "dtype": "float32"}
        for key in spec:
            self.assertNotEqual(digest(spec), digest({**spec, key: "changed"}))

    def test_safe_reload_and_bn_contract_without_optimizer_step(self):
        model = tune.factory("decoder_head")
        affine, buffers = bn_names(model)
        trainable = {name for name, parameter in model.named_parameters() if parameter.requires_grad}
        self.assertTrue(trainable & affine)
        self.assertFalse(trainable & buffers)
        self.assertEqual(sum(parameter.numel() for parameter in model.parameters() if parameter.requires_grad), 148232)
        before = tune.state_sha(model)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "delta.pt")
            torch.save({"state": {name: value for name, value in model.state_dict().items() if name in trainable}}, path)
            loaded = torch.load(path, map_location="cpu", weights_only=True)
            state = model.state_dict(); state.update(loaded["state"])
            model.load_state_dict(state, strict=True)
        self.assertEqual(tune.state_sha(model), before)
        self.assertTrue(all(not layer.training for layer in model.modules() if isinstance(layer, torch.nn.modules.batchnorm._BatchNorm)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="command")
    propose = sub.add_parser("propose")
    for name in ("runs-root", "native-protocols", "old-manifest", "train-labels", "eval-labels", "output"):
        propose.add_argument("--" + name, required=True)
    propose.add_argument("--diagnostic-agent-labels", action="store_true")
    propose.add_argument("--intent", default=str(INTENT_PATH))
    propose.add_argument("--intent-sha256", required=True)
    run = sub.add_parser("run")
    run.add_argument("--protocol", required=True); run.add_argument("--output", required=True)
    run.add_argument("--execute-frozen-protocol", action="store_true")
    run.add_argument("--diagnostic-agent-labels", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        torch.set_num_threads(4)
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)).wasSuccessful() else 1
    require(args.command, "Choose propose/run or --self-test")
    if args.command == "propose":
        require(args.diagnostic_agent_labels, "propose requires --diagnostic-agent-labels")
        output = Path(args.output).resolve()
        require(not output.exists(), "Protocol exists; choose a NEW file")
        paths = {key: str(Path(getattr(args, key)).resolve()) for key in (
            "runs_root", "native_protocols", "old_manifest", "train_labels", "eval_labels", "intent")}
        paths["intent_sha256"] = native.valid_sha(args.intent_sha256)
        config = proposal(paths)
        output.parent.mkdir(parents=True, exist_ok=True)
        write(output, config)
        print(tune.canonical({"protocol": str(output), "sha256": tune.sha(output), "optimizer_steps": 0,
                              "supervised_batches": len(config["eligible_training_batches"]), "tensor_hashes_verified": 60}))
    else:
        execute(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError) as error:
        print("ball-causal-tune: " + str(error), file=sys.stderr)
        raise SystemExit(2)
