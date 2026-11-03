#!/usr/bin/env python3
"""Audit exact video packet sequences without decoding; standard library + ffprobe.

Only identical complete sequences and complete leading prefixes are classified.
No inference about independent capture, intermediate clips, or re-encoding is made.
"""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from fractions import Fraction

VERSION = "1.0.1"
FIELDS = ("data_hash", "pts", "dts", "duration", "size")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def signature(path):
    s = path.stat()
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"ffprobe failed ({result.returncode}) for {command[-1]}: {result.stderr.strip()}")
    return result.stdout


def sequence_hash(packets):
    digest = hashlib.sha256()
    for packet in packets:
        digest.update((json.dumps(packet, separators=(",", ":")) + "\n").encode())
    return digest.hexdigest()


def normalize(packet, time_base):
    missing = [field for field in FIELDS if field not in packet]
    if missing:
        raise ValueError(f"missing required packet fields: {', '.join(missing)}")
    if not packet["data_hash"].startswith("SHA256:"):
        raise ValueError("ffprobe did not supply a SHA256 packet hash")
    return (packet["data_hash"].lower(),
            *(str(Fraction(packet[key]) * time_base) for key in ("pts", "dts", "duration")),
            int(packet["size"]))


def compare(a, b):
    """a/b are normalized packet sequences. Empty input supplies no evidence."""
    shared = 0
    for pa, pb in zip(a, b):
        if pa != pb:
            break
        shared += 1
    limit = min(len(a), len(b))
    hashes_equal = bool(limit) and all(x[0] == y[0] for x, y in zip(a, b))
    pts_equal = bool(limit) and all(x[1] == y[1] for x, y in zip(a, b))
    relationship = "not_detected"
    if limit and shared == limit:
        relationship = "same_video_packet_sequence" if len(a) == len(b) else "exact_complete_prefix"
    return {"relationship": relationship, "shared_packet_count": shared,
            "compared_packet_count": limit,
            "packet_hashes_identical_over_compared_range": hashes_equal,
            "pts_identical_over_compared_range": pts_equal,
            "all_fields_identical_over_compared_range": bool(limit) and shared == limit,
            "shared_normalized_packet_sequence_sha256": sequence_hash(a[:shared]) if shared else None}


def retained_sequences(sequences, members):
    """Remove proven contained inputs; divergent extensions both remain counted."""
    return [i for i in members if not any(
        i != j and sequences[i] and len(sequences[i]) <= len(sequences[j])
        and sequences[i] == sequences[j][:len(sequences[i])]
        and (len(sequences[i]) < len(sequences[j]) or j < i)
        for j in members)]


def inspect(path, ffprobe):
    before = signature(path)
    file_hash = sha256(path)
    command = [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_streams",
               "-show_format", "-show_packets", "-show_data_hash", "sha256",
               "-show_entries", "packet=pts,dts,duration,size,data_hash:stream=index,codec_name,width,height,time_base,duration,avg_frame_rate,r_frame_rate,nb_frames:format=duration,size,format_name",
               "-of", "json", str(path)]
    raw = json.loads(run(command))
    streams = raw.get("streams", [])
    if len(streams) != 1:
        raise ValueError(f"{path}: no first video stream found")
    stream = streams[0]
    packets = [normalize(p, Fraction(stream["time_base"])) for p in raw.get("packets", [])]
    if not packets:
        raise ValueError(f"{path}: empty video packet sequence")
    after_hash = sha256(path)
    if before != signature(path) or file_hash != after_hash:
        raise ValueError(f"{path}: file changed during audit (stat or SHA256 mismatch)")
    start = min(Fraction(p[1]) for p in packets)
    end = max(Fraction(p[1]) + Fraction(p[3]) for p in packets)
    duration = end - start
    return {"path": str(path), "file_sha256": file_hash,
            "file_size_bytes": before[2], "read_integrity": "stat_and_sha256_unchanged",
            "ffprobe_command": command, "stream_metadata": stream,
            "format_metadata": raw.get("format", {}), "packet_count": len(packets),
            "normalized_packet_sequence_sha256": sequence_hash(packets),
            "packet_timeline_duration_seconds": float(duration),
            "packet_timeline_duration_fraction": str(duration)}, packets


def audit(args):
    output = Path(args.output).expanduser().absolute()
    if output.exists() or output.is_symlink():
        raise ValueError(f"refusing to overwrite output: {output}")
    paths = [Path(p).expanduser().resolve(strict=True) for p in args.videos]
    identities = [signature(p)[:2] for p in paths]
    if len(set(paths)) != len(paths) or len(set(identities)) != len(identities):
        raise ValueError("duplicate source file/path (including symlinks or hardlinks)")
    if not all(p.is_file() for p in paths):
        raise ValueError("every source must be a regular file")
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        raise ValueError("ffprobe is required but was not found on PATH")
    sources, sequences = [], []
    for index, path in enumerate(paths):
        print(f"Auditing {index + 1}/{len(paths)}: {path.name}", file=sys.stderr, flush=True)
        source, packets = inspect(path, ffprobe)
        source["id"] = f"source-{index + 1}"
        sources.append(source)
        sequences.append(packets)
    parents = list(range(len(paths)))

    def root(i):
        while parents[i] != i:
            i = parents[i]
        return i

    relations = []
    for i, j in itertools.combinations(range(len(paths)), 2):
        evidence = compare(sequences[i], sequences[j])
        evidence.update(source_a=sources[i]["id"], source_b=sources[j]["id"],
                        file_sha256_identical=sources[i]["file_sha256"] == sources[j]["file_sha256"])
        if evidence["relationship"] != "not_detected":
            parents[root(j)] = root(i)
            if len(sequences[i]) != len(sequences[j]):
                evidence["prefix_source"] = sources[i if len(sequences[i]) < len(sequences[j]) else j]["id"]
        relations.append(evidence)
    components = {}
    for i in range(len(paths)):
        components.setdefault(root(i), []).append(i)
    groups = []
    total = Fraction(0)
    for members in components.values():
        retained = retained_sequences(sequences, members)
        duration = sum((Fraction(sources[i]["packet_timeline_duration_fraction"]) for i in retained), Fraction(0))
        total += duration
        groups.append({"members": [sources[i]["id"] for i in members],
                       "keep_for_duration": [sources[i]["id"] for i in retained],
                       "duration_seconds": float(duration),
                       "split_recommendation": "keep_all_members_in_one_dataset_split",
                       "independent_capture": "unknown"})
    result = {"tool": "speed-source-audit", "tool_version": VERSION,
              "created_at": datetime.now(timezone.utc).isoformat(),
              "invocation": [sys.executable, *sys.argv],
              "ffprobe_version": run([ffprobe, "-version"]).splitlines()[0],
              "normalization": {"fields": list(FIELDS), "timestamps": "exact rational seconds from stream time_base; no offset removal",
                                "sequence_hash": "SHA256 of compact JSON array per packet followed by LF; tuple order is fields"},
              "sources": sources, "pairwise_evidence": relations, "connected_groups": groups,
              "duration_summary": {"method": "sum packet PTS spans after removing only complete inputs proven identical to or a complete prefix of another retained input; divergent extensions both remain counted",
                                   "input_seconds": sum(s["packet_timeline_duration_seconds"] for s in sources),
                                   "deduplicated_only_for_proven_same_or_complete_prefix_seconds": float(total),
                                   "deduplicated_seconds_fraction": str(total),
                                   "other_content_duplicates": "unknown"},
              "limitations": ["No video decoding; only first video stream is compared.",
                              "not_detected does not prove independence or distinct visual content.",
                              "Intermediate clips, shifted timestamps, and re-encoded duplicates are not detected.",
                              "Duration is packet presentation span, not decoded effective playback duration; gaps are included."]}
    # Exclusive creation also protects against a race after the initial check.
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(json.dumps({"output": str(output), "sources": len(sources), "groups": len(groups),
                      "detected_relations": sum(r["relationship"] != "not_detected" for r in relations),
                      "duration": result["duration_summary"]}, indent=2))


def self_test():
    p = ("sha256:a", "0", "0", "1", 1)
    q = ("sha256:b", "1", "1", "1", 1)
    cases = [([p], [p], "same_video_packet_sequence"),
             ([p], [p, q], "exact_complete_prefix"),
             ([p, q], [p], "exact_complete_prefix"),
             ([p], [q], "not_detected"),
             ([], [], "not_detected"), ([], [p], "not_detected"),
             ([p], [(p[0], "1", *p[2:])], "not_detected"),
             ([p], [(p[0], p[1], "1", *p[3:])], "not_detected"),
             ([p, q], [q, p], "not_detected")]
    for a, b, expected in cases:
        assert compare(a, b)["relationship"] == expected, (a, b, expected)
    mismatch = compare([p], [(p[0], "1", *p[2:])])
    assert mismatch["packet_hashes_identical_over_compared_range"]
    assert not mismatch["pts_identical_over_compared_range"]
    assert sequence_hash([p]) != sequence_hash([p, q])
    assert normalize(dict(data_hash="SHA256:a", pts=2, dts=2, duration=2, size="1"), Fraction(1, 2)) == ("sha256:a", "1", "1", "1", 1)
    assert retained_sequences([[p], [p, q], [p, p]], [0, 1, 2]) == [1, 2]
    assert retained_sequences([[p], [p]], [0, 1]) == [0]
    print("self-test: 15 checks passed, 0 skipped, 0 failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    ap = sub.add_parser("audit")
    ap.add_argument("--output", required=True)
    ap.add_argument("videos", nargs="+")
    args = parser.parse_args()
    try:
        self_test() if args.command == "self-test" else audit(args)
    except (OSError, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
