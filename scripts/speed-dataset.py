#!/usr/bin/env python3
"""Build an auditable, local teacher-pseudo-label dataset; never trains a model.

Usage: python3 scripts/speed-dataset.py build CONFIG.json --output NEW_DIRECTORY
       python3 scripts/speed-dataset.py --self-test

CONFIG (relative input paths resolve against the config's directory):
{
  "sources": [{
    "source": {"path": "/video.mov", "expected_sha256": "64 hex characters"},
    "export": {"path": "/labels.xlsx", "expected_sha256": "64 hex characters"},
    "group_id": "same-session-scene", "split": "train",
    "teacher": {
      "name": "S家",
      "installed_app_version": "unknown",
      "inference_version": "unknown",
      "snapshot_id": "current-export-20261015",
      "provenance": "Describe the export snapshot and version evidence separately"
    },
    "anchor_offset_seconds": 2.0,
    "anchor_offset_basis": "Exporter evidence: Video Time + 2 is a software event"
  }],
  "speed_range_kmh": [1, 300]
}

The offset produces a software event anchor, NOT a human-labelled contact PTS.
Unknown inference versions and confidences remain unknown. Installed application
versions are independent provenance and never imply an inference version.
A source may appear only once per build, including repeated export snapshots.
Split assignment is explicit at source/group level; the tool never splits shots.
Only Python's standard library is imported; the build also requires ffprobe.
"""

import argparse
import copy
import csv
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
import zipfile

SCHEMA_VERSION = 1
MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
REQUIRED_HEADERS = (
    "Speed (KM/H)", "Hit (x)", "Hit (y)", "Hit (z)", "Bounce (x)",
    "Bounce (y)", "Stroke", "Spin", "Result", "Point", "Game", "Set", "Video Time",
)
# An allowlist ensures Player and other identity columns never reach output.
TECHNICAL_HEADERS = REQUIRED_HEADERS + ("Shot", "Type")
SPLITS = {"train", "validation", "test"}
REVIEW_FIELDS = (
    "shot_id", "source_sha256", "export_sha256", "group_id", "split",
    "worksheet_row", "video_time_seconds", "software_event_anchor_seconds",
    "human_contact_time_seconds", "trajectory_visibility", "teacher_speed_concern",
    "reviewed", "review_notes",
)


class DatasetError(ValueError):
    """A validation failure that must leave no dataset output."""


def finite_number(value, context, optional=False):
    if value is None or (isinstance(value, str) and not value.strip()):
        if optional:
            return None
        raise DatasetError(f"{context}: a number is required")
    if isinstance(value, bool):
        raise DatasetError(f"{context}: booleans are not numbers")
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError) as error:
        raise DatasetError(f"{context}: invalid number") from error
    if not math.isfinite(number):
        raise DatasetError(f"{context}: non-finite number")
    return number


def required_text(value, context):
    if not isinstance(value, str) or not value.strip():
        raise DatasetError(f"{context}: nonempty text is required")
    return value.strip()


def optional_text(value):
    return None if value is None or not str(value).strip() else str(value).strip()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def file_identity(path):
    stat = path.stat()
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)


def verify_unchanged(path, expected_sha256, initial_identity, context):
    """Bind the actual bytes read/probed to the original verified file identity."""
    if file_identity(path) != initial_identity:
        raise DatasetError(f"{context}: file changed during build")
    actual = sha256_file(path)
    if actual != expected_sha256 or file_identity(path) != initial_identity:
        raise DatasetError(f"{context}: file changed during build")


def verified_file(spec, base, context):
    if not isinstance(spec, dict):
        raise DatasetError(f"{context}: path and expected_sha256 are required")
    path = Path(required_text(spec.get("path"), context + ".path")).expanduser()
    path = (base / path).resolve() if not path.is_absolute() else path.resolve()
    expected = required_text(spec.get("expected_sha256"), context + ".expected_sha256").lower()
    if not re.fullmatch(r"[a-f0-9]{64}", expected):
        raise DatasetError(f"{context}: expected_sha256 must contain 64 hex characters")
    if not path.is_file():
        raise DatasetError(f"{context}: file does not exist: {path}")
    identity = file_identity(path)
    actual = sha256_file(path)
    if file_identity(path) != identity:
        raise DatasetError(f"{context}: file changed while checking SHA256")
    if actual != expected:
        raise DatasetError(f"{context}: SHA256 mismatch (expected {expected}, got {actual})")
    return path, actual, identity


def package_target(part, target):
    """Resolve a package relationship relative to its owning part."""
    if "\\" in target or ":" in target or "?" in target or "#" in target:
        raise DatasetError("XLSX has an unsupported relationship target")
    resolved = posixpath.normpath(target.lstrip("/") if target.startswith("/")
                                 else posixpath.join(posixpath.dirname(part), target))
    if resolved == ".." or resolved.startswith("../"):
        raise DatasetError("XLSX relationship escapes the package")
    return resolved


def xml_part(archive, name):
    try:
        return ET.fromstring(archive.read(name))
    except (KeyError, ET.ParseError) as error:
        raise DatasetError(f"XLSX missing or malformed part: {name}") from error


def relationships(archive, part):
    name = (posixpath.dirname(part) + "/_rels/" + posixpath.basename(part) + ".rels"
            if part else "_rels/.rels")
    result = {}
    for rel in xml_part(archive, name).findall(f"{{{PKG_NS}}}Relationship"):
        if rel.get("TargetMode") == "External":
            continue
        result[rel.get("Id")] = {
            "type": rel.get("Type", ""),
            "target": package_target(part, rel.get("Target", "")),
        }
    return result


def cell_column(reference):
    match = re.fullmatch(r"([A-Z]+)[1-9][0-9]*", reference or "")
    if not match:
        raise DatasetError("XLSX contains an invalid cell reference")
    return match.group(1)


def read_shots_xlsx(path):
    """Resolve the named Shots sheet; preserve worksheet rows and allowed raw text."""
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as error:
        raise DatasetError("Export is not a readable XLSX ZIP") from error
    with archive:
        roots = [rel["target"] for rel in relationships(archive, "").values()
                 if rel["type"].endswith("/officeDocument")]
        if len(roots) != 1:
            raise DatasetError("XLSX must have one workbook relationship")
        workbook_path = roots[0]
        workbook = xml_part(archive, workbook_path)
        rels = relationships(archive, workbook_path)
        sheets = [sheet for sheet in workbook.findall(f"{{{MAIN_NS}}}sheets/{{{MAIN_NS}}}sheet")
                  if sheet.get("name") == "Shots"]
        if len(sheets) != 1:
            raise DatasetError("XLSX must have exactly one named Shots worksheet")
        sheet_rel = rels.get(sheets[0].get(f"{{{REL_NS}}}id"))
        if not sheet_rel or not sheet_rel["type"].endswith("/worksheet"):
            raise DatasetError("Shots worksheet relationship is invalid")
        shared = []
        string_parts = [rel["target"] for rel in rels.values()
                        if rel["type"].endswith("/sharedStrings")]
        if len(string_parts) > 1:
            raise DatasetError("XLSX has multiple shared-string parts")
        if string_parts:
            shared = ["".join(node.itertext()) for node in
                      xml_part(archive, string_parts[0]).findall(f"{{{MAIN_NS}}}si")]
        rows = []
        seen_rows = set()
        for row in xml_part(archive, sheet_rel["target"]).findall(
                f"{{{MAIN_NS}}}sheetData/{{{MAIN_NS}}}row"):
            try:
                index = int(row.get("r", ""))
            except ValueError as error:
                raise DatasetError("XLSX row index is invalid") from error
            if index < 1 or index in seen_rows:
                raise DatasetError("XLSX row index is invalid or duplicated")
            seen_rows.add(index)
            cells = {}
            for cell in row.findall(f"{{{MAIN_NS}}}c"):
                reference = cell.get("r", "")
                col = cell_column(reference)
                if int(re.search(r"[0-9]+$", reference).group()) != index or col in cells:
                    raise DatasetError("XLSX cell row mismatch or duplicate cell")
                if cell.find(f"{{{MAIN_NS}}}f") is not None:
                    raise DatasetError("Shots formula cells are unsupported; export static values")
                value = cell.find(f"{{{MAIN_NS}}}v")
                text = value.text if value is not None else None
                kind = cell.get("t", "n")
                if kind == "s":
                    try:
                        string_index = int(text)
                        if string_index < 0:
                            raise ValueError()
                        text = shared[string_index]
                    except (ValueError, TypeError, IndexError) as error:
                        raise DatasetError("XLSX shared-string index is invalid") from error
                elif kind == "inlineStr":
                    inline = cell.find(f"{{{MAIN_NS}}}is")
                    text = "".join(inline.itertext()) if inline is not None else None
                elif kind == "e":
                    raise DatasetError("Shots contains an Excel error cell")
                elif kind == "n" and text is not None:
                    finite_number(text, f"Shots!{reference}")
                elif kind not in ("n", "str", "b", "d"):
                    raise DatasetError(f"Unsupported XLSX cell type: {kind}")
                cells[col] = text
            if any(value is not None and value.strip() for value in cells.values()):
                rows.append((index, cells))
        rows.sort(key=lambda row: row[0])
        if not rows:
            raise DatasetError("Shots worksheet is empty")
        header_row, cells = rows[0]
        headers = {}
        for col, name in cells.items():
            if name in TECHNICAL_HEADERS:
                if name in headers:
                    raise DatasetError(f"Duplicate Shots header: {name}")
                headers[name] = col
        missing = set(REQUIRED_HEADERS) - headers.keys()
        if missing:
            raise DatasetError("Shots is missing headers: " + ", ".join(sorted(missing)))
        result = []
        for row_number, cells in rows[1:]:
            technical = {name: cells.get(col) for name, col in headers.items()}
            if any(optional_text(value) is not None for value in technical.values()):
                result.append((row_number, technical))
        if not result:
            raise DatasetError("Shots worksheet contains no shots")
        return result, {"name": "Shots", "part": sheet_rel["target"], "header_row": header_row}


def frame_rate(text, context):
    try:
        numerator, denominator = text.split("/")
        rate = finite_number(numerator, context) / finite_number(denominator, context)
    except (ValueError, AttributeError, ZeroDivisionError) as error:
        raise DatasetError(f"{context}: invalid frame rate") from error
    if rate <= 0 or not math.isfinite(rate):
        raise DatasetError(f"{context}: frame rate must be positive")
    return rate


def probe_video(path, executable="ffprobe"):
    command = [executable, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]
    try:
        process = subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
        payload = json.loads(process.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        raise DatasetError("ffprobe failed; install ffprobe and verify the source video") from error
    videos = [stream for stream in payload.get("streams", [])
              if stream.get("codec_type") == "video" and not stream.get("disposition", {}).get("attached_pic")]
    if not videos:
        raise DatasetError("ffprobe found no video stream")
    stream = videos[0]
    # Stream duration bounds anchors against the selected video, not a longer audio track.
    duration = finite_number(stream.get("duration", payload.get("format", {}).get("duration")),
                             "video duration")
    if duration <= 0:
        raise DatasetError("Video duration must be positive")
    width = finite_number(stream.get("width"), "video width")
    height = finite_number(stream.get("height"), "video height")
    if width <= 0 or height <= 0 or not width.is_integer() or not height.is_integer():
        raise DatasetError("Video dimensions must be positive integers")
    return {
        "probe": "ffprobe", "stream_index": stream.get("index"),
        "codec_name": stream.get("codec_name"), "width": int(width), "height": int(height),
        "duration_seconds": duration,
        "start_time_seconds": finite_number(stream.get("start_time", 0), "video start time"),
        "average_frame_rate": stream.get("avg_frame_rate"),
        "average_fps": frame_rate(stream.get("avg_frame_rate"), "video average frame rate"),
        "nominal_frame_rate": stream.get("r_frame_rate"),
        "time_base": stream.get("time_base"),
        "frame_count": stream.get("nb_frames"),
        "anchor_time_origin": "elapsed seconds from source video start; not decoded frame PTS",
        "rotation_degrees": next((item.get("rotation") for item in stream.get("side_data_list", [])
                                   if "rotation" in item), stream.get("tags", {}).get("rotate")),
    }


def parse_video_time(value, context):
    # Current S家 exports use numeric seconds; HH:MM:SS(.sss) is also explicit.
    if isinstance(value, str) and ":" in value:
        parts = value.split(":")
        if len(parts) != 3 or not re.fullmatch(r"[0-9]+", parts[0]):
            raise DatasetError(f"{context}: expected seconds or HH:MM:SS")
        hours, minutes, seconds = [finite_number(part, context) for part in parts]
        if not minutes.is_integer() or not 0 <= minutes < 60 or not 0 <= seconds < 60:
            raise DatasetError(f"{context}: invalid clock time")
        return hours * 3600 + minutes * 60 + seconds
    return finite_number(value, context)


def make_shot(source, row_number, raw, video, speed_range):
    context = f"Shots row {row_number}"
    video_time = parse_video_time(raw.get("Video Time"), context + " Video Time")
    anchor = video_time + source["anchor_offset_seconds"]
    if not math.isfinite(anchor) or not 0 <= anchor < video["duration_seconds"]:
        raise DatasetError(f"{context}: software event anchor is outside video duration")
    speed = finite_number(raw.get("Speed (KM/H)"), context + " speed", optional=True)
    flags = []
    if speed is None:
        flags.append("missing_teacher_speed")
    elif not speed_range[0] <= speed <= speed_range[1]:
        flags.append("teacher_speed_out_of_range")
    shot_id = "shot-" + hashlib.sha256(
        f"{source['source_sha256']}:{source['export_sha256']}:Shots:{row_number}".encode("utf-8")).hexdigest()
    context_values = {}
    for key in ("Shot", "Point", "Game", "Set"):
        value = finite_number(raw.get(key), context + " " + key, optional=True)
        if value is not None and (value < 0 or not value.is_integer()):
            raise DatasetError(f"{context}: {key} must be a nonnegative integer when present")
        context_values[key.lower()] = None if value is None else int(value)
    return {
        "schema_version": SCHEMA_VERSION, "shot_id": shot_id,
        "source_sha256": source["source_sha256"], "export_sha256": source["export_sha256"],
        "group_id": source["group_id"], "split": source["split"],
        "worksheet": "Shots", "worksheet_row": row_number,
        "label_kind": "teacher_pseudo_label", "teacher_snapshot_id": source["teacher"]["snapshot_id"],
        "teacher_inference_version": source["teacher"]["inference_version"],
        "teacher_confidence": None,
        "timing": {"export_video_time_seconds": video_time,
                   "anchor_offset_seconds": source["anchor_offset_seconds"],
                   "software_event_anchor_seconds": anchor,
                   "anchor_kind": "software_shot_event",
                   "human_contact_time_seconds": None},
        "teacher_speed_kmh": speed, "speed_target_kmh": speed,
        "speed_target_valid": speed is not None and not flags,
        "training_eligible": False,
        "geometry_training_eligible": False,
        "coordinate_semantics": {"status": "unconfirmed", "units": None, "axes": None,
                                 "origin": None, "physical_truth_confirmed": False},
        "teacher_hit": {axis: finite_number(raw.get(f"Hit ({axis})"),
                         context + f" Hit ({axis})", optional=True) for axis in "xyz"},
        "teacher_bounce": {axis: finite_number(raw.get(f"Bounce ({axis})"),
                            context + f" Bounce ({axis})", optional=True) for axis in "xy"},
        "stroke": optional_text(raw.get("Stroke")), "spin": optional_text(raw.get("Spin")),
        "result": optional_text(raw.get("Result")), "type": optional_text(raw.get("Type")),
        "context": context_values,
        "teacher_raw": raw,
        "review": {"status": "pending", "trajectory_visibility": None,
                   "teacher_speed_concern": None, "notes": None},
        "flags": flags,
    }


def build_dataset(config, output, base=Path.cwd(), probe=probe_video, ffprobe="ffprobe"):
    output = Path(output).expanduser().absolute()
    if os.path.lexists(output):
        raise DatasetError("Output already exists; choose an explicit new directory")
    if not isinstance(config, dict) or not isinstance(config.get("sources"), list) or not config["sources"]:
        raise DatasetError("Config requires a nonempty sources list")
    speed_range = config.get("speed_range_kmh", [1, 300])
    if not isinstance(speed_range, list) or len(speed_range) != 2:
        raise DatasetError("speed_range_kmh must be [minimum, maximum]")
    speed_range = [finite_number(value, "speed_range_kmh") for value in speed_range]
    if speed_range[0] < 0 or speed_range[0] >= speed_range[1]:
        raise DatasetError("speed_range_kmh must be increasing and nonnegative")
    groups, seen_sources, sources, shots = {}, set(), [], []
    for index, item in enumerate(config["sources"]):
        if not isinstance(item, dict):
            raise DatasetError(f"sources[{index}] must be an object")
        group = required_text(item.get("group_id"), "group_id")
        split = item.get("split", "train")
        if split not in SPLITS:
            raise DatasetError("split must be train, validation, or test")
        if group in groups and groups[group] != split:
            raise DatasetError(f"Split leakage: group {group} is assigned to multiple splits")
        groups[group] = split
        teacher = item.get("teacher")
        if not isinstance(teacher, dict):
            raise DatasetError("teacher provenance is required")
        teacher = {key: required_text(teacher.get(key), "teacher." + key) for key in
                   ("name", "installed_app_version", "inference_version", "snapshot_id", "provenance")}
        offset = finite_number(item.get("anchor_offset_seconds"), "anchor_offset_seconds")
        basis = required_text(item.get("anchor_offset_basis"), "anchor_offset_basis")
        source_path, source_sha, source_identity = verified_file(item.get("source"), base, "source")
        if source_sha in seen_sources:
            raise DatasetError("Duplicate source SHA256: select one export snapshot per source; do not mix snapshots")
        seen_sources.add(source_sha)
        export_path, export_sha, export_identity = verified_file(item.get("export"), base, "export")
        video = probe(source_path, ffprobe)
        raw_shots, worksheet = read_shots_xlsx(export_path)
        source = {
            "source_path": str(source_path), "source_sha256": source_sha,
            "source_bytes": source_identity[2],
            "export_path": str(export_path), "export_sha256": export_sha,
            "export_bytes": export_identity[2],
            "group_id": group, "split": split, "teacher": teacher,
            "anchor_offset_seconds": offset, "anchor_offset_basis": basis,
            "video": video, "worksheet": worksheet,
        }
        source_shots = [make_shot(source, row, raw, video, speed_range) for row, raw in raw_shots]
        verify_unchanged(source_path, source_sha, source_identity, "source")
        verify_unchanged(export_path, export_sha, export_identity, "export")
        source["shot_count"] = len(source_shots)
        sources.append(source)
        shots.extend(source_shots)
    counts = {name: sum(shot["split"] == name for shot in shots) for name in sorted(SPLITS)}
    valid_counts = {name: sum(shot["split"] == name and shot["speed_target_valid"] for shot in shots)
                    for name in sorted(SPLITS)}
    train_groups = {source["group_id"] for source in sources if source["split"] == "train"}
    holdout_groups = {source["group_id"] for source in sources if source["split"] in {"validation", "test"}}
    holdout_available = bool(train_groups and holdout_groups and valid_counts["train"]
                             and valid_counts["validation"] + valid_counts["test"])
    summary = {
        "schema_version": SCHEMA_VERSION, "total_shots": len(shots),
        "shots_with_teacher_speed": sum(shot["teacher_speed_kmh"] is not None for shot in shots),
        "valid_speed_targets": sum(shot["speed_target_valid"] for shot in shots),
        "missing_teacher_speed": sum(shot["teacher_speed_kmh"] is None for shot in shots),
        "out_of_range_teacher_speed": sum("teacher_speed_out_of_range" in shot["flags"] for shot in shots),
        "pending_review": len(shots), "reviewed": 0,
        "independent_sources": len(seen_sources), "scene_groups": len(groups),
        "shots_by_split": counts, "valid_speed_targets_by_split": valid_counts,
        "independent_holdout_available": holdout_available,
        "holdout_basis": "explicit source SHA and declared scene groups only; group independence is user-supplied",
        "holdout_unavailable_reason": None if holdout_available else
            "Need valid teacher speeds in train and an explicitly separate source/scene group holdout",
        "physical_speed_accuracy_verified": False,
        "physical_accuracy_not_ready_reasons": ["No independent physical speed reference is supplied"],
        "human_contact_labels": 0,
        "training_eligible_shots": 0,
        "geometry_training_eligible_shots": 0,
        "pseudo_label_dataset_ready": True,
        "training_ready": False,
        "training_not_ready_reasons": ["All shots await human timing, visibility, and teacher-target review"],
        "generalization_evaluation_target": "teacher_snapshot_agreement",
        "generalization_evaluation_ready": False,
        "generalization_not_ready_reasons": (
            ([] if holdout_available else ["No explicitly independent scene/source holdout with speed targets"])
            + ["Human review is pending"]),
    }
    limitations = [
        "Teacher speeds are pseudo-labels, not physical speed measurements or independent truth.",
        "Software event anchors are not human-labelled ball/racket contact PTS.",
        "All shots require human review; confidence and unobserved values remain null.",
        "Installed teacher app version does not establish the export inference version.",
        "A speed target passing range checks does not mean human review passed.",
        "No random per-shot split; one source snapshot per source SHA, with declared scene groups kept together.",
        "Source SHA identifies file bytes, not independent camera scenes; declare shared group IDs for related footage.",
        "Hit/Bounce are unverified teacher coordinates; units, axes, and origin are unconfirmed and geometry training is ineligible.",
        "Shot identities bind source SHA, frozen export SHA, and worksheet row; reviews never transfer automatically across snapshots.",
    ]
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "dataset_kind": "teacher_pseudo_label", "generator": "scripts/speed-dataset.py",
        "speed_range_kmh": speed_range, "sources": sources,
        "split_policy": "explicit source/group assignment; omitted split means train",
        "shot_id_policy": "SHA256(source_sha256 + ':' + export_sha256 + ':Shots:' + worksheet_row); row identity within a frozen source/export snapshot, with no automatic linkage across snapshots",
        "input_consistency_policy": "Source/export stat identity checked around SHA256 reads; stat identity and SHA256 rechecked after probing/parsing",
        "limitations": limitations,
    }
    # Stage beside the destination and publish once; never open an existing artifact for writing.
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".speed-dataset-", dir=output.parent))
    try:
        shots_path = staging / "shots.jsonl"
        with shots_path.open("w", encoding="utf-8") as handle:
            for shot in shots:
                handle.write(json.dumps(shot, ensure_ascii=False, allow_nan=False, sort_keys=True) + "\n")
        review_path = staging / "review.csv"
        with review_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=REVIEW_FIELDS)
            writer.writeheader()
            for shot in shots:
                row = {key: shot[key] for key in
                       ("shot_id", "source_sha256", "export_sha256", "group_id", "split", "worksheet_row")}
                row.update(video_time_seconds=shot["timing"]["export_video_time_seconds"],
                           software_event_anchor_seconds=shot["timing"]["software_event_anchor_seconds"])
                writer.writerow({key: csv_safe(value) for key, value in row.items()})
        write_json(staging / "summary.json", summary)
        manifest["artifacts"] = {name: {"sha256": sha256_file(staging / name),
                                        "bytes": (staging / name).stat().st_size}
                                  for name in ("shots.jsonl", "review.csv", "summary.json")}
        write_json(staging / "manifest.json", manifest)
        # mkdir is an exclusive claim even when another build races for this exact path.
        output.mkdir()
        for part in staging.iterdir():
            part.rename(output / part.name)
        staging.rmdir()
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return summary


def csv_safe(value):
    # Preserve numeric values while preventing user-supplied text becoming spreadsheet formulas.
    if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def write_json(path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False, sort_keys=True) + "\n",
                    encoding="utf-8")


def fixture_xlsx(path, data=None, shared=True, sheet_target="/xl/worksheets/not-first.xml"):
    """Small adversarial workbook: Shots is second and sharedStrings has a custom path."""
    data = data if data is not None else [{"Speed (KM/H)": "86.5", "Video Time": "7.31"}]
    headers = ["Player"] + list(TECHNICAL_HEADERS)
    strings = []
    def cell(col, row, value, is_header=False):
        node = ET.Element(f"{{{MAIN_NS}}}c", {"r": f"{col}{row}"})
        if value is None:
            return node
        if is_header or col == "A" or shared:
            node.set("t", "s")
            strings.append(str(value))
            ET.SubElement(node, f"{{{MAIN_NS}}}v").text = str(len(strings) - 1)
        else:
            node.set("t", "inlineStr")
            inline = ET.SubElement(node, f"{{{MAIN_NS}}}is")
            # Rich inline runs must concatenate, not lose the second run.
            for text in (str(value)[:1], str(value)[1:]):
                ET.SubElement(ET.SubElement(inline, f"{{{MAIN_NS}}}r"), f"{{{MAIN_NS}}}t").text = text
        return node
    sheet = ET.Element(f"{{{MAIN_NS}}}worksheet")
    sheet_data = ET.SubElement(sheet, f"{{{MAIN_NS}}}sheetData")
    for row_index, row_values in enumerate([dict(zip(headers, headers))] + data, 1):
        row = ET.SubElement(sheet_data, f"{{{MAIN_NS}}}row", {"r": str(row_index)})
        for index, header in enumerate(headers):
            col = chr(65 + index)
            value = row_values.get(header)
            if header == "Player" and row_index > 1:
                value = "PRIVATE_PLAYER_DO_NOT_EXPORT"
            row.append(cell(col, row_index, value, row_index == 1))
    workbook = ET.Element(f"{{{MAIN_NS}}}workbook")
    sheets = ET.SubElement(workbook, f"{{{MAIN_NS}}}sheets")
    for name, rid in (("Settings", "r1"), ("Shots", "r9")):
        ET.SubElement(sheets, f"{{{MAIN_NS}}}sheet", {"name": name, f"{{{REL_NS}}}id": rid})
    shared_root = ET.Element(f"{{{MAIN_NS}}}sst")
    for text in strings:
        ET.SubElement(ET.SubElement(shared_root, f"{{{MAIN_NS}}}si"), f"{{{MAIN_NS}}}t").text = text
    def rels(entries):
        root = ET.Element(f"{{{PKG_NS}}}Relationships")
        for rid, kind, target in entries:
            ET.SubElement(root, f"{{{PKG_NS}}}Relationship",
                          {"Id": rid, "Type": REL_NS + "/" + kind, "Target": target})
        return ET.tostring(root)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("_rels/.rels", rels([("root", "officeDocument", "xl/workbook.xml")]))
        archive.writestr("xl/workbook.xml", ET.tostring(workbook))
        archive.writestr("xl/_rels/workbook.xml.rels", rels([
            ("r1", "worksheet", "worksheets/settings.xml"),
            ("r9", "worksheet", sheet_target), ("strings", "sharedStrings", "strings/custom.xml")]))
        archive.writestr("xl/strings/custom.xml", ET.tostring(shared_root))
        archive.writestr("xl/worksheets/not-first.xml", ET.tostring(sheet))


class DatasetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "video.mov"
        self.source.write_bytes(b"video fixture")
        self.export = self.base / "export.xlsx"
        fixture_xlsx(self.export)
        self.config = {"sources": [{
            "source": {"path": "video.mov", "expected_sha256": sha256_file(self.source)},
            "export": {"path": "export.xlsx", "expected_sha256": sha256_file(self.export)},
            "group_id": "scene-one", "split": "train",
            "teacher": {"name": "S家", "installed_app_version": "unknown",
                        "inference_version": "unknown", "snapshot_id": "fixture", "provenance": "fixture export"},
            "anchor_offset_seconds": 2, "anchor_offset_basis": "exporter software event evidence",
        }]}
        self.output = self.base / "dataset"

    @staticmethod
    def probe(path, executable):
        return {"duration_seconds": 30, "width": 1920, "height": 1080, "average_fps": 60}

    def build(self):
        return build_dataset(self.config, self.output, self.base, self.probe)

    def change_export(self, data, **kwargs):
        fixture_xlsx(self.export, data, **kwargs)
        self.config["sources"][0]["export"]["expected_sha256"] = sha256_file(self.export)

    def shots(self):
        return [json.loads(line) for line in (self.output / "shots.jsonl").read_text().splitlines()]

    def test_resolves_second_named_sheet_and_shared_strings(self):
        self.assertEqual(self.build()["total_shots"], 1)
        shot = self.shots()[0]
        self.assertEqual(shot["teacher_speed_kmh"], 86.5)
        self.assertAlmostEqual(shot["timing"]["software_event_anchor_seconds"], 9.31)
        self.assertEqual(shot["worksheet_row"], 2)

    def test_inline_rich_strings_and_relative_relationship(self):
        self.change_export([{"Speed (KM/H)": "73.2", "Video Time": "00:00:07.31"}],
                           shared=False, sheet_target="worksheets/not-first.xml")
        self.build()
        self.assertEqual(self.shots()[0]["teacher_speed_kmh"], 73.2)

    def test_missing_values_stay_null(self):
        self.change_export([{"Video Time": "1"}])
        summary = self.build()
        shot = self.shots()[0]
        self.assertIsNone(shot["speed_target_kmh"])
        self.assertIsNone(shot["teacher_hit"]["x"])
        self.assertIsNone(shot["teacher_confidence"])
        self.assertFalse(summary["training_ready"])
        self.assertFalse(summary["generalization_evaluation_ready"])
        self.assertEqual(summary["generalization_evaluation_target"], "teacher_snapshot_agreement")
        self.assertNotIn("No independent physical speed reference is supplied",
                         summary["generalization_not_ready_reasons"])
        self.assertEqual(summary["physical_accuracy_not_ready_reasons"],
                         ["No independent physical speed reference is supplied"])
        self.assertEqual(summary["valid_speed_targets"], 0)
        self.assertEqual(summary["missing_teacher_speed"], 1)

    def test_nonfinite_speed_and_geometry_rejected(self):
        for header, value in (("Speed (KM/H)", "nan"), ("Hit (x)", "Infinity"),
                              ("Bounce (y)", "-inf"), ("Point", "nan")):
            with self.subTest(header=header):
                self.change_export([{"Video Time": "1", header: value}])
                with self.assertRaisesRegex(DatasetError, "non-finite"):
                    self.build()
                self.assertFalse(self.output.exists())

    def test_bad_time_rejected(self):
        for value in (None, "nan", "-3", "28", "100", "00:61:00", "oops"):
            with self.subTest(value=value):
                self.change_export([{"Video Time": value, "Speed (KM/H)": "80"}])
                with self.assertRaises(DatasetError):
                    self.build()
                self.assertFalse(self.output.exists())

    def test_bad_offset_rejected(self):
        self.config["sources"][0]["anchor_offset_seconds"] = float("inf")
        with self.assertRaisesRegex(DatasetError, "non-finite"):
            self.build()

    def test_sha_mismatch_source_and_export(self):
        for key in ("source", "export"):
            with self.subTest(key=key):
                original = self.config["sources"][0][key]["expected_sha256"]
                self.config["sources"][0][key]["expected_sha256"] = "0" * 64
                with self.assertRaisesRegex(DatasetError, "SHA256 mismatch"):
                    self.build()
                self.config["sources"][0][key]["expected_sha256"] = original
                self.assertFalse(self.output.exists())

    def test_duplicate_source_snapshot_rejected(self):
        for changed_snapshot in (False, True):
            duplicate = copy.deepcopy(self.config["sources"][0])
            if changed_snapshot:
                duplicate["teacher"]["snapshot_id"] = "another-snapshot"
            self.config["sources"] = [self.config["sources"][0], duplicate]
            with self.assertRaisesRegex(DatasetError, "Duplicate source"):
                self.build()

    def test_group_split_leak_rejected(self):
        duplicate = copy.deepcopy(self.config["sources"][0])
        duplicate["split"] = "test"
        self.config["sources"].append(duplicate)
        with self.assertRaisesRegex(DatasetError, "Split leakage"):
            self.build()

    def test_out_of_range_retained_and_flagged(self):
        self.change_export([{"Video Time": "1", "Speed (KM/H)": "0"},
                            {"Video Time": "2", "Speed (KM/H)": "999"}])
        summary = self.build()
        self.assertEqual(summary["shots_with_teacher_speed"], 2)
        self.assertEqual(summary["valid_speed_targets"], 0)
        self.assertEqual(summary["out_of_range_teacher_speed"], 2)
        self.assertEqual(self.shots()[0]["teacher_speed_kmh"], 0)

    def test_identity_removed_and_review_blanks(self):
        self.build()
        for path in self.output.iterdir():
            self.assertNotIn("PRIVATE_PLAYER_DO_NOT_EXPORT", path.read_text())
        with (self.output / "review.csv").open(newline="") as handle:
            row = next(csv.DictReader(handle))
        self.assertNotIn("teacher_speed_kmh", row)
        self.assertNotIn("speed_target_valid", row)
        for key in ("human_contact_time_seconds", "trajectory_visibility", "teacher_speed_concern", "reviewed"):
            self.assertEqual(row[key], "")

    def test_one_source_stays_train_and_has_no_holdout(self):
        del self.config["sources"][0]["split"]
        summary = self.build()
        self.assertFalse(summary["independent_holdout_available"])
        self.assertEqual(summary["shots_by_split"], {"train": 1, "validation": 0, "test": 0})
        self.assertEqual(self.shots()[0]["teacher_inference_version"], "unknown")

    def test_independent_declared_holdout(self):
        source2 = self.base / "other.mov"
        source2.write_bytes(b"different video")
        other = copy.deepcopy(self.config["sources"][0])
        other.update(group_id="scene-two", split="test")
        other["source"] = {"path": "other.mov", "expected_sha256": sha256_file(source2)}
        self.config["sources"].append(other)
        summary = self.build()
        self.assertTrue(summary["independent_holdout_available"])
        self.assertEqual(summary["generalization_not_ready_reasons"], ["Human review is pending"])
        self.assertFalse(summary["physical_speed_accuracy_verified"])

    def test_existing_output_even_empty_rejected(self):
        self.output.mkdir()
        with self.assertRaisesRegex(DatasetError, "already exists"):
            self.build()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_ids_bind_frozen_snapshot_and_reviews_do_not_transfer(self):
        self.build()
        first_shot = self.shots()[0]
        first = first_shot["shot_id"]
        first_shot["review"]["status"] = "reviewed"
        first_shot["timing"]["human_contact_time_seconds"] = 9.2
        manifest = json.loads((self.output / "manifest.json").read_text())
        for name, record in manifest["artifacts"].items():
            self.assertEqual(record["sha256"], sha256_file(self.output / name))
        (self.output / "shots.jsonl").write_text(json.dumps(first_shot) + "\n")
        self.output = self.base / "second-dataset"
        self.change_export([{"Video Time": "7.31", "Speed (KM/H)": "85"}], shared=False)
        self.build()
        second = self.shots()[0]
        self.assertNotEqual(first, second["shot_id"])
        self.assertEqual(second["review"]["status"], "pending")
        self.assertIsNone(second["timing"]["human_contact_time_seconds"])
        self.assertFalse(second["training_eligible"])
        self.assertFalse(second["geometry_training_eligible"])
        self.assertEqual(second["coordinate_semantics"]["status"], "unconfirmed")
        for key in ("units", "axes", "origin"):
            self.assertIsNone(second["coordinate_semantics"][key])

    def test_same_frozen_snapshot_keeps_id(self):
        self.build()
        first = self.shots()[0]["shot_id"]
        self.output = self.base / "same-snapshot"
        self.build()
        self.assertEqual(first, self.shots()[0]["shot_id"])

    def test_source_and_export_changes_during_probe_rejected(self):
        for changed in ("source", "export"):
            with self.subTest(changed=changed):
                # Restore both fixtures and their expected identities before each build.
                self.source.write_bytes(b"video fixture")
                self.config["sources"][0]["source"]["expected_sha256"] = sha256_file(self.source)
                self.change_export([{"Video Time": "7.31", "Speed (KM/H)": "85"}])
                def mutating_probe(path, executable):
                    if changed == "source":
                        self.source.write_bytes(b"changed video fixture")
                    else:
                        fixture_xlsx(self.export, [{"Video Time": "8.31", "Speed (KM/H)": "90"}])
                    return self.probe(path, executable)
                with self.assertRaisesRegex(DatasetError, "file changed during build"):
                    build_dataset(self.config, self.output, self.base, mutating_probe)
                self.assertFalse(self.output.exists())

    def test_source_change_during_initial_hash_rejected(self):
        real_hash = sha256_file
        def changing_hash(path):
            result = real_hash(path)
            if path.resolve() == self.source.resolve():
                path.write_bytes(b"mutated after hash read")
            return result
        with mock.patch.dict(globals(), {"sha256_file": changing_hash}):
            with self.assertRaisesRegex(DatasetError, "file changed while checking SHA256"):
                self.build()
        self.assertFalse(self.output.exists())

    def test_mandatory_version_provenance(self):
        del self.config["sources"][0]["teacher"]["inference_version"]
        with self.assertRaisesRegex(DatasetError, "inference_version"):
            self.build()

    def test_frame_rate_validation(self):
        self.assertAlmostEqual(frame_rate("60000/1001", "test"), 59.94005994)
        for value in ("0/0", "inf/1", "-30/1", "oops"):
            with self.assertRaises(DatasetError):
                frame_rate(value, "test")

    def test_csv_formula_escape(self):
        self.assertEqual(csv_safe("=1+1"), "'=1+1")
        self.assertEqual(csv_safe(-3), -3)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true", help="run standard-library tests without ffprobe")
    subparsers = parser.add_subparsers(dest="command")
    build = subparsers.add_parser("build", help="validate inputs and write a new dataset directory")
    build.add_argument("config", type=Path)
    build.add_argument("--output", required=True, type=Path)
    build.add_argument("--ffprobe", default="ffprobe", help="ffprobe executable (default: PATH)")
    args = parser.parse_args(argv)
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(DatasetTests))
        return 0 if result.wasSuccessful() else 1
    if args.command != "build":
        parser.error("choose build or --self-test")
    try:
        config_path = args.config.expanduser().resolve()
        config = json.loads(config_path.read_text(encoding="utf-8"))
        summary = build_dataset(config, args.output, config_path.parent, ffprobe=args.ffprobe)
        print(json.dumps({"output": str(args.output.resolve()), "summary": summary}, ensure_ascii=False, indent=2))
        return 0
    except (DatasetError, OSError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        print(f"speed-dataset: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
