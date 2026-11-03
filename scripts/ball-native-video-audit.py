#!/usr/bin/env python3
"""Audit frozen native-video development runs without changing inputs or labels.

Requires NumPy; optional Core ML parity uses coremltools CPU_ONLY. No downloads,
FFmpeg calls, new annotations, training, or physical-speed metrics are produced.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import sys
import tempfile
import time
import unittest

import numpy as np

WINDOWS = ("eval-002", "train-006", "train-007", "train-008")
LABEL_INDICES = tuple(range(16)) + tuple(range(64, 96))
RGB_SHAPE = (288, 512, 3)
RGB_BYTES = math.prod(RGB_SHAPE)
TENSOR_SHAPE = (1, 27, 288, 512)
HEATMAP_SHAPE = (1, 8, 288, 512)


class AuditError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise AuditError(message)


def integer(value, name):
    require(type(value) is int, f"{name}: integer required")
    return value


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def package_files(path):
    root = Path(path).resolve()
    files = []
    for item in sorted(root.rglob("*")):
        if item.is_file():
            require(item.resolve().is_relative_to(root), "Core ML package symlink escapes supplied package")
            files.append({"path": str(item.relative_to(root)), "bytes": item.stat().st_size,
                          "sha256": sha_file(item)})
    require(files, "Empty Core ML package")
    return files


def valid_sha(value):
    require(isinstance(value, str) and len(value) == 64
            and all(c in "0123456789abcdef" for c in value), "Invalid SHA256")
    return value


def load_json(path):
    path = Path(path)
    require(path.stat().st_size <= 128 * 1024 * 1024, f"JSON too large: {path}")
    return json.loads(path.read_text(), parse_constant=lambda x: (_ for _ in ()).throw(AuditError(f"Nonfinite JSON: {x}")))


def stamp(value):
    """Interpret the two explicitly used CMTime/IndependentFrameTime schemas."""
    require(isinstance(value, dict), "Missing PTS object")
    if "sourcePTS" in value:
        numerator = integer(value.get("timeBaseNumerator"), "timeBaseNumerator")
        denominator = integer(value.get("timeBaseDenominator"), "timeBaseDenominator")
        ticks = integer(value.get("sourcePTS"), "sourcePTS")
    else:
        numerator = integer(value.get("time_base_numerator", 1), "time_base_numerator")
        denominator = integer(value.get("timescale"), "timescale")
        ticks = integer(value.get("value"), "value")
        require(value.get("epoch", 0) == 0, "Unsupported timestamp epoch")
        if "flags" in value:
            require(integer(value["flags"], "flags") == 1, "Invalid/rounded/non-numeric PTS")
    require(numerator > 0 and denominator > 0, "Invalid timestamp timebase")
    return Fraction(ticks * numerator, denominator)


def manifest_time(row):
    require("source_pts" in row and "source_time_base" in row, "Missing original source PTS")
    base = Fraction(row["source_time_base"])
    require(base > 0, "Invalid original timebase")
    return integer(row["source_pts"], "source_pts") * base


def checked_bytes(root, relative, expected_size, expected_sha):
    require(isinstance(relative, str), "Missing exported artifact path")
    root = Path(root).resolve()
    path = (root / relative).resolve()
    require(path.is_relative_to(root), "Artifact path escapes run directory")
    require(path.stat().st_size == expected_size, f"Artifact size differs: {path}")
    data = path.read_bytes()
    require(sha_bytes(data) == valid_sha(expected_sha), f"Artifact hash differs: {path}")
    return data


def prefix_median(images):
    require(len(images) > 0, "No median frames")
    require(all(image.dtype == np.uint8 and image.shape == images[0].shape for image in images),
            "Median requires equal-shaped uint8 images")
    # np.median averages the two middle bytes in float64; astype(uint8)
    # truncates their nonnegative half-integer result, matching integer floor.
    return np.median(np.stack(images), axis=0).astype(np.uint8)


def make_tensor(background, frames):
    require(len(frames) == 8 and background.shape == RGB_SHAPE, "Tensor requires background + 8 RGB frames")
    require(all(frame.shape == RGB_SHAPE and frame.dtype == np.uint8 for frame in frames), "Bad tensor RGB input")
    chw = np.concatenate([image.transpose(2, 0, 1) for image in [background] + frames], axis=0)
    return np.ascontiguousarray(chw[np.newaxis].astype("<f4") / np.float32(255))


def rate(numerator, denominator):
    return numerator / denominator if denominator else None


def summarize_points(points):
    visible = [row for row in points if row["status"] == "visible"]
    unknown = [row for row in points if row["status"] == "unknown"]
    distances = [row["distance_1280x720_equivalent_px"] for row in visible
                 if row["distance_1280x720_equivalent_px"] is not None]
    missing = sum(row["candidate_original_xy"] is None for row in visible)
    wrong = sum(distance > 20 for distance in distances)
    within = {str(threshold): sum(distance <= threshold for distance in distances) for threshold in (5, 10, 20)}
    return {"label_candidates": len(points), "visible_denominator": len(visible),
            "selected_on_visible": len(distances), "missing_on_visible": missing,
            "wrong_over20_on_visible": wrong, "within_equivalent_px": within,
            "within_rates_over_all_visible": {key: rate(value, len(visible)) for key, value in within.items()},
            "missing_rate_over_all_visible": rate(missing, len(visible)),
            "wrong_over20_rate_over_all_visible": rate(wrong, len(visible)),
            "mean_distance_selected_visible_only": float(np.mean(distances)) if distances else None,
            "median_distance_selected_visible_only": float(np.median(distances)) if distances else None,
            "unknown_excluded_from_distance_denominator": len(unknown),
            "selected_on_unknown_identity_unscored": sum(row["candidate_original_xy"] is not None for row in unknown)}


def point_record(label, window, frame, candidate_xy):
    index = integer(label.get("frame_index"), "label frame_index")
    require(label.get("sample_id") == window["sample_id"] == window["window_id"], "Label sample/window identity differs")
    require(label.get("window_id", label["sample_id"]) == window["window_id"], "Label window identity differs")
    require(manifest_time(label) == manifest_time(frame), "Label PTS differs from frozen source frame")
    require(label.get("source_sha256", window["source_sha256"]) == window["source_sha256"], "Label source hash differs")
    require(label.get("image_sha256") == frame["image_sha256"], "Label source-image hash differs")
    require(label.get("status") in ("visible", "unknown"), "Unsupported label status")
    require(label.get("formal_eligible") is False and label.get("training_eligible") is False,
            "Expected frozen development-only labels")
    require(label.get("reviewer_kind") == "agent", "Expected agent annotations")
    width, height = window["width"], window["height"]
    space = label.get("coordinate_space")
    if isinstance(space, dict):
        require((space.get("width"), space.get("height")) == (width, height), "Label coordinate dimensions differ")
    else:
        require(space == f"{width}x{height}", "Unknown label coordinate space")
    if candidate_xy is not None:
        require(isinstance(candidate_xy, list) and len(candidate_xy) == 2 and
                all(type(value) is int for value in candidate_xy), "Bad native candidate coordinates")
        require(0 <= candidate_xy[0] < width and 0 <= candidate_xy[1] < height,
                "Native candidate outside source image")
    distance = None
    label_xy = None
    if label["status"] == "visible":
        x, y = label.get("x"), label.get("y")
        require(type(x) in (int, float) and type(y) in (int, float) and math.isfinite(x) and math.isfinite(y),
                "Visible label lacks finite center")
        require(0 <= x < width and 0 <= y < height, "Visible label outside source image")
        label_xy = [x, y]
        if candidate_xy is not None:
            distance = math.hypot((candidate_xy[0] - x) * 1280 / width,
                                  (candidate_xy[1] - y) * 720 / height)
    else:
        require(label.get("x") is None and label.get("y") is None, "Unknown label must not supply scored coordinates")
    return {"sample_id": window["sample_id"], "source_sha256": window["source_sha256"],
            "frame_index": index, "source_time_rational": str(manifest_time(frame)),
            "status": label["status"], "label_original_xy": label_xy,
            "candidate_original_xy": candidate_xy, "distance_1280x720_equivalent_px": distance,
            "formal_eligible": False, "human_validated": False}


def coreml_parity(model, tensor, native):
    started = time.perf_counter()
    predicted = np.asarray(model.predict({"frames": tensor})["heatmaps"], dtype="<f4")
    elapsed = time.perf_counter() - started
    require(predicted.shape == HEATMAP_SHAPE and np.isfinite(predicted).all(), "Bad Python Core ML heatmap")
    difference = np.abs(predicted - native)
    masks = {str(threshold): int(np.count_nonzero((predicted > np.float32(threshold)) !=
                                                  (native > np.float32(threshold))))
             for threshold in (0.1, 0.3, 0.5)}
    close = bool(np.allclose(predicted, native, atol=1e-5, rtol=1e-5))
    return {"compute_units": "CPU_ONLY", "python_prediction_seconds": elapsed,
            "float_count": int(native.size), "exact_float_count": int(np.count_nonzero(predicted == native)),
            "native_sha256": sha_bytes(native.tobytes()), "python_sha256": sha_bytes(predicted.tobytes()),
            "max_absolute_difference": float(difference.max()), "mean_absolute_difference": float(difference.mean()),
            "atol": 1e-5, "rtol": 1e-5, "allclose": close,
            "strict_threshold_mask_disagreements": masks,
            "passed": close and not any(masks.values())}


def audit_run(run_root, protocol_path, window, labels, manifest_sha, model=None):
    protocol = load_json(protocol_path)
    root = Path(run_root) / window["window_id"]
    report_path = root / "report.json"
    report = load_json(report_path)
    protocol_sha = sha_file(protocol_path)
    require(protocol["source_window"] == window["window_id"] == report["source_window"], "Run/window identity differs")
    require(protocol["source_sha256"] == window["source_sha256"] == report["source_sha256"], "Run source hash differs")
    require(protocol["old_window_manifest_sha256"] == manifest_sha, "Protocol's old manifest changed")
    require(report["protocol_sha256"] == protocol_sha == sha_file(root / "input-protocol.json"), "Frozen protocol differs")
    require(protocol.get("roi_xywh") is None and protocol.get("export_resized_rgb") is True, "Expected full-view RGB export policy")
    require((report["width"], report["height"]) == (window["width"], window["height"]), "Native dimensions differ")
    for flag in ("production", "speed_model_accepted", "physical_accuracy_validated", "app_capture_integrated"):
        require(report.get(flag) is False, f"Unsafe qualification claim: {flag}")
    require(report.get("speed_outputs") == 0 and report.get("unflushed_tail_frames") == 0, "Speed output or incomplete window")
    require(report.get("candidate_threshold") == 0.3, "Unexpected native candidate threshold")
    require(report.get("background_strategy") == "prefix_median48_resized_rgb" and
            report.get("background_uses_future_inference_frames") is False, "Unexpected background policy")
    require(report.get("preferred_transform") == [1, 0, 0, 1, 0, 0], "Unexpected track transform")
    warmup = [stamp(row) for row in protocol["expected_warmup_times"]]
    target = [stamp(row) for row in protocol["expected_inference_times"]]
    expected = warmup + target
    require(len(warmup) == 48 and len(target) == 120, "Frozen protocol must contain 48 + 120 frames")
    require(all(a < b for a, b in zip(expected, expected[1:])), "PTS duplicates or nonmonotonic protocol")
    require(stamp(protocol["decode_start"]) <= expected[0] and expected[-1] < stamp(protocol["decode_end"]), "Protocol PTS outside decode range")
    require([manifest_time(row) for row in window["frames"]] == target, "Inference PTS differ from all 120 old targets")
    decoded, frames, windows = report["decoded_inputs"], report["frames"], report["windows"]
    require(len(decoded) == report["decoded_frames"] == 168 and len(frames) == report["inferred_frames"] == 120,
            "Missing, padded or additional input/output frames")
    require(len(windows) == 15, "Expected 15 complete 8-frame windows")
    for index, row in enumerate(decoded):
        require(row["decode_index"] == index and stamp(row["presentation_time"]) == expected[index], "Decoded original PTS/index differs")
        valid_sha(row["owned_native_rgb_sha256"])
    for index, row in enumerate(frames):
        require(row["frame_index"] == index and stamp(row.get("time")) == target[index], "Output original PTS/index differs")
        require(row["window_index"] == index // 8 and row["segment_index"] == 0, "Padded/reordered/reset output window")
        available = target[(index // 8) * 8 + 7]
        require(stamp(row["available_at_pts"]) == available, "Output available_at must be batch's last real frame")
        require(abs(row["source_lookahead_seconds"] - float(available - target[index])) < 1e-9, "Lookahead accounting differs")
        require(row.get("speed_kmh", "missing") is None, "Unexpected speed output")
    for index, row in enumerate(windows):
        require(row["window_index"] == index and row["segment_index"] == 0, "Invalid window ordering")
        require(row["background_strategy"] == "prefix_median48_resized_rgb" and row["lookahead_frames"] == 7, "Window policy differs")
        background_times = [stamp(value) for value in row["background_times"]]
        require(background_times == warmup and max(background_times) < min(target), "Background is not strictly before all inference frames")
        require(stamp(row["available_at_pts"]) == target[index * 8 + 7], "Window available_at differs")
    def rgb_at(index):
        row = decoded[index]
        data = checked_bytes(root, row.get("resized_rgb_file"), RGB_BYTES, row.get("resized_rgb_sha256"))
        return np.frombuffer(data, dtype=np.uint8).reshape(RGB_SHAPE)
    background = prefix_median([rgb_at(index) for index in range(48)])
    background_sha = sha_bytes(background.tobytes())
    checked_bytes(root, "first-background.rgb", RGB_BYTES, background_sha)
    tensor_audits = []
    first_tensor = first_heatmaps = None
    for index, row in enumerate(windows):
        require(row["background_sha256"] == background_sha, "Frozen background hash differs")
        tensor = make_tensor(background, [rgb_at(48 + index * 8 + offset) for offset in range(8)])
        tensor_sha = sha_bytes(tensor.tobytes())
        require(tensor_sha == row["tensor_sha256"], "Independent NCHW tensor bytes differ")
        tensor_audits.append({"window_index": index, "tensor_sha256": tensor_sha, "bit_exact": True})
        valid_sha(row["heatmaps_sha256"])
        if index == 0:
            exported = checked_bytes(root, row.get("tensor_file"), math.prod(TENSOR_SHAPE) * 4, tensor_sha)
            require(exported == tensor.tobytes(), "First tensor differs despite hash")
            heatmap_data = checked_bytes(root, row.get("heatmaps_file"), math.prod(HEATMAP_SHAPE) * 4, row["heatmaps_sha256"])
            first_heatmaps = np.frombuffer(heatmap_data, dtype="<f4").reshape(HEATMAP_SHAPE)
            require(np.isfinite(first_heatmaps).all() and ((first_heatmaps >= 0) & (first_heatmaps <= 1)).all(), "Invalid native heatmaps")
            first_tensor = tensor
    require(len(labels) == 48 and sorted(row["frame_index"] for row in labels) == list(LABEL_INDICES), "Label subset changed or duplicated")
    points = []
    for label in labels:
        index = label["frame_index"]
        candidate = frames[index].get("candidate")
        if candidate is not None:
            require(isinstance(candidate, dict) and "originalXY" in candidate, "Malformed selected candidate")
        points.append(point_record(label, window, window["frames"][index], candidate["originalXY"] if candidate else None))
    parity = coreml_parity(model, first_tensor, first_heatmaps) if model is not None else {
        "status": "not_run", "reason": "No --coreml-package supplied", "passed": None}
    return {"source_window": window["window_id"], "source_sha256": window["source_sha256"],
            "native_report_sha256": sha_file(report_path), "protocol_sha256": protocol_sha,
            "native_model_manifest_sha256": valid_sha(report["model_manifest_sha256"]),
            "decoded_pts_verified": 168, "old_target_pts_verified": 120, "resized_rgb_hashes_verified": 168,
            "background_sha256": background_sha, "background_bit_exact": True,
            "tensor_windows": tensor_audits, "first_window_coreml_parity": parity,
            "point_metrics": summarize_points(points), "points": points}


def old_comparison(path, windows_by_id, native_points):
    historical = load_json(path)
    selected = [row for row in historical["points"] if row.get("recipe") == "full-threshold-0.3"]
    new_index = {(row["sample_id"], row["frame_index"]): row for row in native_points if row["status"] == "visible"}
    require(len(selected) == len(new_index), "Old full-threshold-0.3 visible subset has different size")
    seen, old_points, paired = set(), [], []
    for row in selected:
        key = (row["sample_id"], row["frame_index"])
        require(key in new_index and key not in seen, "Old comparison subset differs/duplicates")
        seen.add(key)
        window = windows_by_id[key[0]]
        old = point_record(row["label"], window, window["frames"][key[1]], row["causal_cv"]["candidate_xy_original"])
        new = new_index[key]
        require(old["label_original_xy"] == new["label_original_xy"] and old["source_time_rational"] == new["source_time_rational"],
                "Historical comparison label differs")
        old_points.append(old)
        paired.append({"sample_id": key[0], "frame_index": key[1],
                       "old_distance": old["distance_1280x720_equivalent_px"],
                       "native_distance": new["distance_1280x720_equivalent_px"],
                       "old_candidate_original_xy": old["candidate_original_xy"],
                       "native_candidate_original_xy": new["candidate_original_xy"]})
    return {"input_sha256": sha_file(path), "recipe": "full-threshold-0.3", "association": "causal_cv",
            "scope_matched_visible_points": len(paired), "old_metrics_recomputed_from_same_labels": summarize_points(old_points),
            "native_metrics_on_same_visible_scope": summarize_points(list(new_index.values())), "pairs": paired,
            "attribution": "Decoder/color path and background policy both changed; this comparison cannot attribute a difference to either one alone. Candidate tie rules may also differ."}


def run(args):
    output = Path(args.output)
    require(not output.exists(), "Output exists: choose a NEW file")
    manifest = load_json(args.old_manifest)
    manifest_sha = sha_file(args.old_manifest)
    windows = {window["window_id"]: window for window in manifest["windows"]}
    require(set(windows) == set(WINDOWS) and len(manifest["windows"]) == 4, "Expected exactly four frozen source windows")
    all_labels = load_json(args.train_labels)["records"] + load_json(args.eval_labels)["records"]
    require(len(all_labels) == 192, "Expected exactly 192 frozen agent candidates")
    require(Counter(row["status"] for row in all_labels) == {"visible": 166, "unknown": 26}, "Frozen label status counts differ")
    model = None
    supplied_package = None
    versions = {"python": sys.version.split()[0], "numpy": np.__version__}
    if args.coreml_package:
        import coremltools as ct
        versions["coremltools"] = importlib.metadata.version("coremltools")
        require(Path(args.coreml_package).is_dir(), "Local Core ML package directory is required")
        supplied_package = {"path": str(Path(args.coreml_package).resolve()),
                            "files": package_files(args.coreml_package)}
        model = ct.models.MLModel(str(Path(args.coreml_package).resolve()), compute_units=ct.ComputeUnit.CPU_ONLY)
    runs = []
    for name in WINDOWS:
        result = audit_run(args.runs_root, Path(args.protocols) / f"{name}.json", windows[name],
                           [row for row in all_labels if row["sample_id"] == name], manifest_sha, model)
        runs.append(result)
        print(f"AUDITED {name}: 168 decoded PTS, 120 old target PTS, median + 15 tensor hashes", flush=True)
    require(len({result["native_model_manifest_sha256"] for result in runs}) == 1,
            "Native runs used differing model manifests")
    points = [point for result in runs for point in result["points"]]
    comparison = old_comparison(args.old_point_comparisons, windows, points) if args.old_point_comparisons else {
        "status": "not_run", "reason": "No --old-point-comparisons supplied"}
    report = {"schema_version": 1, "artifact_kind": "independent_native_video_development_audit",
              "created_at": datetime.now(timezone.utc).isoformat(), "versions": versions,
              "tool_sha256": sha_file(__file__), "old_manifest_sha256": manifest_sha,
              "python_coreml_package": supplied_package,
              "coreml_first_window_batches_checked": 4 if model is not None else 0,
              "train_labels_sha256": sha_file(args.train_labels), "eval_labels_sha256": sha_file(args.eval_labels),
              "audit_passed": all(result["first_window_coreml_parity"]["passed"] is not False for result in runs),
              "structural_and_preprocessing_audit_passed": True, "runs": runs,
              "decoded_pts_verified": sum(result["decoded_pts_verified"] for result in runs),
              "old_target_pts_verified": sum(result["old_target_pts_verified"] for result in runs),
              "point_metrics": summarize_points(points), "old_scope_comparison": comparison,
              "production": False, "human_validated": False, "independent_ground_truth": False,
              "formal_eligible": False, "final_eligible": False, "speed_model_accepted": False,
              "physical_accuracy_validated": False, "app_capture_integrated": False, "speed_metrics": None,
              "limitations": ["All 192 labels are existing agent development candidates; 26 unknown identities are excluded from distance denominators.",
                  "Image-distance checks are not physical ball-speed, bounce, contact or classification accuracy.",
                  "RGB median/tensor checks start from the actual exported AVFoundation RGB inputs; they do not establish FFmpeg/Pillow decoder equivalence.",
                  "Frozen protocol and old manifest establish the checked PTS identity; this tool does not decode the source videos again or rehash multi-gigabyte source files.",
                  "Only the first real 8-frame heatmap batch in each run is exported for optional Python Core ML numerical parity; remaining batches have no exported heatmap bytes.",
                  "Decoder/color path, background policy and possible candidate tie behavior differ from historical runs, preventing single-change attribution."]}
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")
    print(f"AUDIT_OK={report['audit_passed']} target_pts=480 labels=192 visible=166 speed_metrics=null output={output}")
    return 0 if report["audit_passed"] else 1


class SelfTests(unittest.TestCase):
    def test_even_median_floors_half_and_does_not_overflow(self):
        images = [np.array([0, 254, 255], dtype=np.uint8), np.array([1, 255, 255], dtype=np.uint8)]
        np.testing.assert_array_equal(prefix_median(images), [0, 254, 255])

    def test_odd_median_and_order(self):
        images = [np.array([x], dtype=np.uint8) for x in (255, 1, 2)]
        np.testing.assert_array_equal(prefix_median(images), [2])

    def test_bad_hash_and_export_size_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            Path(temporary, "frame.rgb").write_bytes(b"abc")
            self.assertEqual(checked_bytes(temporary, "frame.rgb", 3, sha_bytes(b"abc")), b"abc")
            with self.assertRaises(AuditError):
                checked_bytes(temporary, "frame.rgb", 3, "0" * 64)
            with self.assertRaises(AuditError):
                checked_bytes(temporary, "frame.rgb", 4, sha_bytes(b"abc"))
            with self.assertRaises(AuditError):
                checked_bytes(temporary, "../outside", 3, "0" * 64)

    def test_missing_pts_invalid_flags_and_exact_rational(self):
        self.assertEqual(stamp({"value": 7, "timescale": 60}), stamp({"sourcePTS": 70, "timeBaseNumerator": 1, "timeBaseDenominator": 600}))
        for value in ({}, {"timescale": 600}, {"value": 1, "timescale": 0}, {"value": 1, "timescale": 600, "flags": 3}):
            with self.assertRaises(AuditError):
                stamp(value)
        with self.assertRaises(AuditError):
            manifest_time({"source_pts": 1})

    def test_empty_denominator_is_null_and_missing_is_not_wrong(self):
        empty = summarize_points([])
        self.assertIsNone(empty["within_rates_over_all_visible"]["5"])
        self.assertIsNone(empty["mean_distance_selected_visible_only"])
        row = {"status": "visible", "candidate_original_xy": None, "distance_1280x720_equivalent_px": None}
        actual = summarize_points([row])
        self.assertEqual(actual["missing_on_visible"], 1)
        self.assertEqual(actual["wrong_over20_on_visible"], 0)
        self.assertEqual(actual["within_rates_over_all_visible"]["20"], 0)

    def test_nchw_channel_order_and_float32_normalization(self):
        background = np.zeros(RGB_SHAPE, dtype=np.uint8)
        background[:, :, 0] = 255
        frames = [np.full(RGB_SHAPE, value, dtype=np.uint8) for value in range(8)]
        tensor = make_tensor(background, frames)
        self.assertEqual(tensor.shape, TENSOR_SHAPE)
        self.assertEqual(tensor.dtype, np.dtype("<f4"))
        self.assertEqual(float(tensor[0, 0, 0, 0]), 1)
        self.assertEqual(float(tensor[0, 1, 0, 0]), 0)
        self.assertEqual(tensor[0, 26, 0, 0], np.float32(7) / np.float32(255))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    for name in ("runs-root", "protocols", "old-manifest", "train-labels", "eval-labels", "output"):
        parser.add_argument("--" + name)
    parser.add_argument("--coreml-package")
    parser.add_argument("--old-point-comparisons")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    for name in ("runs_root", "protocols", "old_manifest", "train_labels", "eval_labels", "output"):
        if getattr(args, name) is None:
            parser.error("--" + name.replace("_", "-") + " is required")
    try:
        return run(args)
    except (AuditError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"AUDIT_REFUSED: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
