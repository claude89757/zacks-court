#!/usr/bin/env python3
"""Verify or explicitly stage the frozen TrackNetV3 research Core ML artifact.

Standard library only. No download, conversion, Core ML execution, App packaging,
or publication. The caller-supplied text manifest is the byte-integrity trust
root; an external copy may additionally be pinned with --expected-manifest-sha256.
Verification checks declared contracts and bytes, not model accuracy or execution.
"""

import argparse
import copy
import ctypes
import datetime
import errno
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
import unittest
from unittest import mock
import uuid

MODEL_ID = "tracknetv3-base-v1"
# Frozen conversions of the same MIT checkpoint and their compute precision. The FP16 one runs on the
# Neural Engine; it matches FP32 within a tolerance only.
MODEL_PRECISIONS = {MODEL_ID: "float32", "tracknetv3-base-fp16-v1": "float16"}
PACKAGE_NAME = "TrackNetV3Base.mlpackage"
PREPROCESSING_VERSION = "tracknetv3-rgb-native-median48-bicubic-v1"
LICENSE_SHA256 = "1eeb31683deba741bce99f5f33bb813293a23b4e6c8302d6f056a587a30cd497"
UPSTREAM_COMMIT = "6eda442ada1740573f200f836d93edc9a541ee86"
CHECKPOINT_SHA256 = "df867641a02712b021f04548ff4b1208ddfdb47f629ab2094ceb978667e83b1a"
PACKAGE_FILES = {
    "Manifest.json",
    "Data/com.apple.CoreML/model.mlmodel",
    "Data/com.apple.CoreML/weights/weight.bin",
}
CATALOG_KEYS = {
    "schema_version", "model_id", "display_name", "artifact_role", "package_name",
    "license", "documentation", "upstream", "conversion", "contract",
    "preprocessing", "validation", "package_files", "package_bytes", "limitations",
}
LFS_HEADER = b"version https://git-lfs.github.com/spec/v1"


class ModelError(ValueError):
    pass


def path_without_symlinks(value):
    path = Path(value).expanduser()
    if ".." in path.parts:
        raise ModelError("Parent traversal is forbidden; pass a direct canonical path")
    path = path.absolute()
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise ModelError(f"Symlinks are forbidden: {current}")
    return path


def relative_package_path(value):
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise ModelError("Invalid relative package path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(x in {".", "..", ""} for x in value.split("/")):
        raise ModelError("Absolute, empty or traversing package path")
    if path.as_posix() != value:
        raise ModelError("Non-canonical package path")
    return value


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def valid_sha(value):
    return (isinstance(value, str) and len(value) == 64
            and all(x in "0123456789abcdef" for x in value))


def file_record(path, expected=None, destination=None, keep_bytes=False):
    """Open without following the final link; hash/copy and verify before/after stat."""
    path = path_without_symlinks(path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise ModelError(f"Expected a regular file: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(path, flags)
    result = hashlib.sha256()
    chunks = [] if keep_bytes else None
    copied = None
    try:
        with os.fdopen(fd, "rb") as source:
            if file_identity(os.fstat(source.fileno())) != file_identity(before):
                raise ModelError("File identity changed while opening")
            head = source.read(512)
            if head.startswith(LFS_HEADER):
                raise ModelError(f"Git LFS pointer rejected; full artifact required: {path}")
            if expected is not None and before.st_size != expected["bytes"]:
                raise ModelError(f"File size mismatch: {path}")
            if keep_bytes and before.st_size > 4 * 1024 * 1024:
                raise ModelError("Text/package manifest exceeds metadata size limit")
            if destination is not None:
                copied = Path(destination).open("xb")
            data = head
            while data:
                result.update(data)
                if chunks is not None:
                    chunks.append(data)
                if copied is not None:
                    copied.write(data)
                data = source.read(1024 * 1024)
            if file_identity(os.fstat(source.fileno())) != file_identity(before):
                raise ModelError("Source file changed during read/copy")
        path_without_symlinks(path)
        if file_identity(path.lstat()) != file_identity(before):
            raise ModelError("Source file identity changed during read/copy")
    finally:
        if copied is not None:
            copied.close()
    actual = {"bytes": before.st_size, "sha256": result.hexdigest()}
    if expected is not None and actual["sha256"] != expected["sha256"]:
        raise ModelError(f"File SHA256 mismatch: {path}")
    if destination is not None:
        Path(destination).chmod(0o600)
    return actual, file_identity(before), b"".join(chunks) if chunks is not None else None


def json_bytes(data):
    def reject(value):
        raise ModelError("Non-finite JSON value: " + value)

    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ModelError("Duplicate JSON key: " + key)
            result[key] = value
        return result

    try:
        value = json.loads(data.decode("utf-8"), parse_constant=reject, object_pairs_hook=pairs)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ModelError("Invalid UTF-8 JSON manifest") from error

    def finite_tree(node):
        if isinstance(node, float) and not math.isfinite(node):
            raise ModelError("Non-finite JSON number")
        if isinstance(node, dict):
            for item in node.values():
                finite_tree(item)
        elif isinstance(node, list):
            for item in node:
                finite_tree(item)
    finite_tree(value)
    return value


def positive_size(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate_catalog(manifest):
    if not isinstance(manifest, dict) or set(manifest) != CATALOG_KEYS:
        raise ModelError("Unsupported or incomplete catalog fields")
    if (type(manifest["schema_version"]) is not int or manifest["schema_version"] != 1 or manifest["model_id"] not in MODEL_PRECISIONS
            or manifest["artifact_role"] != "research_base_ball_detector"
            or manifest["package_name"] != PACKAGE_NAME):
        raise ModelError("Frozen model identity/schema mismatch")
    license_info = manifest["license"]
    if (license_info.get("spdx") != "MIT" or license_info.get("file") != "LICENSE"
            or license_info.get("sha256") != LICENSE_SHA256
            or license_info.get("bytes") != 1097):
        raise ModelError("Original upstream MIT license binding mismatch")
    documentation = manifest["documentation"]
    if (documentation.get("file") != "README.md" or not positive_size(documentation.get("bytes"))
            or not valid_sha(documentation.get("sha256"))):
        raise ModelError("README binding mismatch")
    upstream = manifest["upstream"]
    if (upstream.get("commit") != UPSTREAM_COMMIT
            or upstream.get("checkpoint", {}).get("sha256") != CHECKPOINT_SHA256
            or upstream.get("source_files_sha256", {}).get("LICENSE") != LICENSE_SHA256):
        raise ModelError("Original checkpoint/source/license provenance mismatch")
    conversion = manifest["conversion"]
    if (conversion.get("format") != "mlprogram" or conversion.get("specification_version") != 8
            or conversion.get("compute_precision") != MODEL_PRECISIONS[manifest["model_id"]]
            or conversion.get("minimum_deployment_target") != {"ios": "17.0", "macos": "14.0"}
            or not valid_sha(conversion.get("report_sha256"))):
        raise ModelError("Declared conversion/deployment contract mismatch")
    contract = manifest["contract"]
    for key, name, shape, layout in (("input", "frames", [1, 27, 288, 512], "NCHW"),
                                     ("output", "heatmaps", [1, 8, 288, 512], "NTHW")):
        tensor = contract.get(key, {})
        if not isinstance(tensor.get("shape"), list) or any(type(x) is not int or x <= 0 for x in tensor["shape"]):
            raise ModelError("Tensor dimensions must be positive integers")
        if not isinstance(tensor.get("range"), list) or any(isinstance(x, bool) or not isinstance(x, (int, float)) for x in tensor["range"]):
            raise ModelError("Tensor range must be numeric")
        if (tensor.get("name") != name or tensor.get("shape") != shape
                or tensor.get("dtype") != "float32" or tensor.get("layout") != layout
                or tensor.get("range") != [0, 1]):
            raise ModelError("Declared tensor contract mismatch: " + key)
    if contract["output"].get("activation") != "sigmoid":
        raise ModelError("Declared output activation mismatch")
    preprocessing = manifest["preprocessing"]
    required = {"algorithm_version": PREPROCESSING_VERSION, "rgb_dtype": "uint8",
                "background_frame_count": 48, "resize": "BICUBIC", "resize_size_wh": [512, 288],
                "same_view_for_background_and_sequence": True, "tensor_layout": "NCHW",
                "normalization_divisor": 255, "tensor_dtype": "float32",
                "includes_future_frames": True, "offline_only": True,
                "causal_realtime_background_validated": False}
    if any(type(preprocessing.get(k)) is not type(v) or preprocessing.get(k) != v for k, v in required.items()):
        raise ModelError("Declared offline preprocessing contract mismatch")
    for flag in ("iphone_tested", "tennis_accuracy_accepted", "speed_model", "app_integrated", "production", "auto_publish"):
        if manifest["validation"].get(flag) is not False:
            raise ModelError("Research-only status mismatch: " + flag)
    files = manifest["package_files"]
    if not isinstance(files, list) or len(files) != 3:
        raise ModelError("Exactly three package file bindings required")
    expected = {}
    for item in files:
        path = relative_package_path(item["path"])
        if path in expected or not positive_size(item.get("bytes")) or not valid_sha(item.get("sha256")):
            raise ModelError("Invalid/duplicate package file binding")
        expected[path] = {"bytes": item["bytes"], "sha256": item["sha256"]}
    if set(expected) != PACKAGE_FILES or sum(x["bytes"] for x in expected.values()) != manifest["package_bytes"]:
        raise ModelError("Frozen package file set/total size mismatch")
    return expected


def inspect_tree(root, expected_files):
    root = path_without_symlinks(root)
    if not root.is_dir():
        raise ModelError("Source is not a model package directory")
    expected_dirs = set()
    for name in expected_files:
        expected_dirs.update(str(p) for p in PurePosixPath(name).parents if str(p) != ".")
    files, directories = set(), set()
    for directory, child_dirs, child_files in os.walk(root, followlinks=False):
        for name in child_dirs + child_files:
            child = Path(directory) / name
            info = child.lstat()
            relative = child.relative_to(root).as_posix()
            if stat.S_ISLNK(info.st_mode):
                raise ModelError("Symlink within model package")
            if stat.S_ISDIR(info.st_mode):
                directories.add(relative)
            elif stat.S_ISREG(info.st_mode):
                files.add(relative)
            else:
                raise ModelError("Special files are forbidden in model package")
    if files != set(expected_files) or directories != expected_dirs:
        raise ModelError("Package has missing/extra files or directories (including empty directories)")


def validate_package_manifest(data):
    manifest = json_bytes(data)
    if manifest.get("fileFormatVersion") != "1.0.0":
        raise ModelError("Core ML package fileFormatVersion mismatch")
    entries = manifest.get("itemInfoEntries", {})
    root_id = manifest.get("rootModelIdentifier")
    if len(entries) != 2 or root_id not in entries:
        raise ModelError("Core ML package root/item count mismatch")
    for key in entries:
        try:
            uuid.UUID(key)
        except (ValueError, TypeError, AttributeError) as error:
            raise ModelError("Invalid Core ML package item UUID") from error
    wanted = {"com.apple.CoreML/model.mlmodel": "model.mlmodel", "com.apple.CoreML/weights": "weights"}
    actual = {}
    for item in entries.values():
        path = relative_package_path(item["path"])
        if path in actual or item.get("author") != "com.apple.CoreML":
            raise ModelError("Duplicate/wrong Core ML package item")
        actual[path] = item.get("name")
    if actual != wanted or entries[root_id].get("path") != "com.apple.CoreML/model.mlmodel":
        raise ModelError("Core ML package item/root relationship mismatch")


def load_catalog(path, expected_manifest_sha256=None):
    path = path_without_symlinks(path)
    record, identity, data = file_record(path, keep_bytes=True)
    if expected_manifest_sha256 is not None and record["sha256"] != expected_manifest_sha256:
        raise ModelError("Catalog SHA256 differs from explicitly pinned manifest")
    manifest = json_bytes(data)
    expected_files = validate_catalog(manifest)
    texts = {"manifest.json": data}
    records = {"manifest.json": {"path": path, "identity": identity, "record": record}}
    for key, info in (("LICENSE", manifest["license"]), ("README.md", manifest["documentation"])):
        source = path.parent / key
        actual, state, payload = file_record(source, info, keep_bytes=True)
        records[key] = {"path": source, "identity": state, "record": actual}
        texts[key] = payload
    return {"path": path, "manifest": manifest, "expected": expected_files,
            "texts": texts, "records": records, "sha256": record["sha256"]}


def verify_package(source, catalog):
    source = path_without_symlinks(source)
    if source.name != PACKAGE_NAME:
        raise ModelError("Source package basename differs from declared package_name")
    inspect_tree(source, catalog["expected"])
    records = {}
    for relative, expected in sorted(catalog["expected"].items()):
        actual, state, data = file_record(source / relative, expected, keep_bytes=relative == "Manifest.json")
        if relative == "Manifest.json":
            validate_package_manifest(data)
        records[relative] = {"identity": state, "record": actual}
    inspect_tree(source, catalog["expected"])
    return records


def assert_unchanged(source, catalog, records):
    for entry in catalog["records"].values():
        actual, state, _ = file_record(entry["path"], entry["record"])
        if state != entry["identity"] or actual != entry["record"]:
            raise ModelError("Catalog/license/README changed during operation")
    again = verify_package(source, catalog)
    if again != records:
        raise ModelError("Source package changed during operation")


def atomic_publish_new(source, destination):
    """Whole-directory atomic publication without replacing even an empty destination."""
    source = path_without_symlinks(source)
    destination = path_without_symlinks(destination)
    if os.path.lexists(destination):
        raise ModelError("Destination already exists; choose a new path")
    if sys.platform == "darwin":
        library = ctypes.CDLL(None, use_errno=True)
        operation = library.renamex_np
        operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        operation.restype = ctypes.c_int
        result = operation(os.fsencode(source), os.fsencode(destination), 0x00000004)  # RENAME_EXCL
        method = "renamex_np(RENAME_EXCL)"
    elif sys.platform.startswith("linux"):
        library = ctypes.CDLL(None, use_errno=True)
        operation = getattr(library, "renameat2", None)
        if operation is None:
            raise ModelError("Exclusive atomic rename is unavailable on this platform")
        operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        operation.restype = ctypes.c_int
        result = operation(-100, os.fsencode(source), -100, os.fsencode(destination), 1)  # RENAME_NOREPLACE
        method = "renameat2(RENAME_NOREPLACE)"
    elif os.name == "nt":
        os.rename(source, destination)  # Windows rejects an existing destination.
        return "os.rename(no replacement on Windows)"
    else:
        raise ModelError("Exclusive atomic rename is unavailable; refusing unsafe fallback")
    if result != 0:
        code = ctypes.get_errno()
        if code in (errno.EEXIST, errno.ENOTEMPTY):
            raise ModelError("Destination appeared during publication; it was preserved")
        raise OSError(code, os.strerror(code))
    return method


def receipt(source, catalog, records, operation, destination=None):
    return {
        "schema_version": 1, "operation": operation, "status": "verified",
        "model_id": catalog["manifest"]["model_id"], "package_relative_path": PACKAGE_NAME,
        "source_package": str(source), "destination": str(destination) if destination else None,
        "catalog_path": str(catalog["path"]), "manifest_sha256": catalog["sha256"],
        "license_sha256": catalog["records"]["LICENSE"]["record"]["sha256"],
        "readme_sha256": catalog["records"]["README.md"]["record"]["sha256"],
        "package_files": [{"path": name, **item["record"]} for name, item in records.items()],
        "package_bytes": catalog["manifest"]["package_bytes"],
        "generator_sha256": file_record(Path(__file__))[0]["sha256"],
        "verified_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_before_after_unchanged": True, "coreml_compilation_or_inference_performed": False,
        "declared_contract_only": True, "speed_model": False, "production": False,
        "iphone_tested": False, "accuracy_accepted": False, "automatic_app_packaging": False,
        "automatic_publication": False,
    }


def write_json_new(path, payload):
    with path.open("x", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")
    path.chmod(0o600)


def verify(source, manifest_path, expected_manifest_sha256=None):
    source = path_without_symlinks(source)
    catalog = load_catalog(manifest_path, expected_manifest_sha256)
    records = verify_package(source, catalog)
    assert_unchanged(source, catalog, records)
    return receipt(source, catalog, records, "verify")


def stage(source, manifest_path, destination, expected_manifest_sha256=None):
    source, destination = path_without_symlinks(source), path_without_symlinks(destination)
    if os.path.lexists(destination):
        raise ModelError("Destination already exists; choose a new directory")
    catalog = load_catalog(manifest_path, expected_manifest_sha256)
    records = verify_package(source, catalog)
    if source == destination or source in destination.parents or destination in source.parents:
        raise ModelError("Source and destination directories must not overlap")
    destination.parent.mkdir(parents=True, exist_ok=True)
    path_without_symlinks(destination.parent)
    temporary = Path(tempfile.mkdtemp(prefix=".independent-ball-stage-", dir=destination.parent))
    temporary.chmod(0o700)
    try:
        package = temporary / PACKAGE_NAME
        package.mkdir(mode=0o700)
        for relative, expected in sorted(catalog["expected"].items()):
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            _, state, _ = file_record(source / relative, expected, destination=target)
            if state != records[relative]["identity"]:
                raise ModelError("Source changed between verification and copy")
        for name, data in catalog["texts"].items():
            target = temporary / name
            with target.open("xb") as handle:
                handle.write(data)
            target.chmod(0o600)
        copied_catalog = load_catalog(temporary / "manifest.json", catalog["sha256"])
        copied_records = verify_package(package, copied_catalog)
        if {k: v["record"] for k, v in copied_records.items()} != {k: v["record"] for k, v in records.items()}:
            raise ModelError("Copied package differs from source")
        assert_unchanged(source, catalog, records)
        payload = receipt(source, catalog, records, "stage", destination)
        payload["status"] = "verified_staged"
        payload["copied_package_verified"] = True
        payload["atomic_no_replace_publication"] = True
        write_json_new(temporary / "receipt.json", payload)
        # No successful receipt is visible until the complete staged tree is published.
        atomic_publish_new(temporary, destination)
        return payload
    finally:
        # Never remove/modify an existing destination, including a raced destination.
        if temporary.exists():
            shutil.rmtree(temporary)


def write_receipt_atomic(path, payload):
    path = path_without_symlinks(path)
    if os.path.lexists(path):
        raise ModelError("Receipt already exists; choose a new path")
    path.parent.mkdir(parents=True, exist_ok=True)
    path_without_symlinks(path.parent)
    fd, temporary_name = tempfile.mkstemp(prefix=".independent-ball-receipt-", dir=path.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        # mkstemp exclusively created this private file; only that file is replaced.
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write("\n")
        temporary.chmod(0o600)
        atomic_publish_new(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


class ModelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / PACKAGE_NAME
        self.source.mkdir()
        self.catalog_dir = self.root / "catalog"
        self.catalog_dir.mkdir()
        original = Path(__file__).resolve().parents[1] / "assets/independent-models" / MODEL_ID
        for name in ("LICENSE", "README.md"):
            (self.catalog_dir / name).write_bytes((original / name).read_bytes())
        self.manifest_path = self.catalog_dir / "manifest.json"
        self.manifest = json_bytes((original / "manifest.json").read_bytes())
        package_manifest = {
            "fileFormatVersion": "1.0.0",
            "rootModelIdentifier": "00000000-0000-0000-0000-000000000001",
            "itemInfoEntries": {
                "00000000-0000-0000-0000-000000000001": {
                    "author": "com.apple.CoreML", "name": "model.mlmodel",
                    "path": "com.apple.CoreML/model.mlmodel"},
                "00000000-0000-0000-0000-000000000002": {
                    "author": "com.apple.CoreML", "name": "weights",
                    "path": "com.apple.CoreML/weights"},
            },
        }
        for name, data in {
            "Manifest.json": json.dumps(package_manifest).encode(),
            "Data/com.apple.CoreML/model.mlmodel": b"synthetic byte-integrity fixture, NOT an executable model",
            "Data/com.apple.CoreML/weights/weight.bin": bytes(range(256)) * 8,
        }.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.rebind_fixture()
        self.destination = self.root / "new-stage"

    def rebind_fixture(self):
        self.manifest["package_files"] = []
        for name in sorted(PACKAGE_FILES):
            data = (self.source / name).read_bytes()
            self.manifest["package_files"].append({
                "path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        self.manifest["package_bytes"] = sum(x["bytes"] for x in self.manifest["package_files"])
        self.save_manifest()

    def save_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest, ensure_ascii=False, indent=2) + "\n")

    def test_verify_and_stage_preserve_exact_bytes_and_license(self):
        checked = verify(self.source, self.manifest_path)
        self.assertTrue(checked["declared_contract_only"])
        self.assertFalse(checked["coreml_compilation_or_inference_performed"])
        staged = stage(self.source, self.manifest_path, self.destination)
        self.assertEqual(staged["status"], "verified_staged")
        self.assertEqual(len(staged["package_files"]), 3)
        for name in PACKAGE_FILES:
            self.assertEqual((self.source / name).read_bytes(), (self.destination / PACKAGE_NAME / name).read_bytes())
        self.assertEqual((self.destination / "LICENSE").read_bytes(), (self.catalog_dir / "LICENSE").read_bytes())
        self.assertEqual(verify(self.destination / PACKAGE_NAME, self.destination / "manifest.json")["manifest_sha256"], checked["manifest_sha256"])
        self.assertFalse(staged["iphone_tested"])
        self.assertFalse(staged["production"])

    def test_size_and_hash_mismatches_are_rejected(self):
        path = self.source / "Data/com.apple.CoreML/weights/weight.bin"
        original = path.read_bytes()
        for changed in (bytes([original[0] ^ 1]) + original[1:], original + b"extra"):
            path.write_bytes(changed)
            with self.assertRaisesRegex(ModelError, "mismatch"):
                verify(self.source, self.manifest_path)
        self.assertFalse(self.destination.exists())

    def test_missing_file_extra_file_and_extra_empty_directory(self):
        path = self.source / "Data/com.apple.CoreML/weights/weight.bin"
        original = path.read_bytes()
        path.unlink()
        with self.assertRaises(ModelError):
            verify(self.source, self.manifest_path)
        path.write_bytes(original)
        extra = self.source / "unexpected.txt"
        extra.write_text("not part of the frozen model")
        with self.assertRaises(ModelError):
            verify(self.source, self.manifest_path)
        extra.unlink()
        (self.source / "empty-extra-directory").mkdir()
        with self.assertRaisesRegex(ModelError, "directories"):
            verify(self.source, self.manifest_path)

    def test_lfs_pointer_rejected_even_with_matching_fixture_digest(self):
        path = self.source / "Data/com.apple.CoreML/weights/weight.bin"
        path.write_bytes(LFS_HEADER + b"\noid sha256:" + b"0" * 64 + b"\nsize 45350912\n")
        self.rebind_fixture()
        with self.assertRaisesRegex(ModelError, "LFS pointer"):
            verify(self.source, self.manifest_path)

    def test_symlink_source_member_and_ancestor_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ModelError, "Symlink"):
            verify(alias, self.manifest_path)
        path = self.source / "Data/com.apple.CoreML/weights/weight.bin"
        external = self.root / "external.bin"
        path.rename(external)
        path.symlink_to(external)
        with self.assertRaisesRegex(ModelError, "Symlink"):
            verify(self.source, self.manifest_path)
        parent_alias = self.root / "parent-alias"
        parent_alias.symlink_to(self.catalog_dir, target_is_directory=True)
        with self.assertRaisesRegex(ModelError, "Symlink"):
            load_catalog(parent_alias / "manifest.json")

    def test_symlink_license_and_destination_parent_rejected(self):
        license_path = self.catalog_dir / "LICENSE"
        old = self.root / "license-original"
        license_path.rename(old)
        license_path.symlink_to(old)
        with self.assertRaises(ModelError):
            verify(self.source, self.manifest_path)
        license_path.unlink()
        license_path.write_bytes(old.read_bytes())
        alias = self.root / "destination-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ModelError):
            stage(self.source, self.manifest_path, alias / "new-stage")

    def test_traversal_absolute_and_duplicate_manifest_paths_rejected(self):
        for unsafe in ("../outside.bin", "/absolute.bin", "Data/../model.mlmodel", "Data\\model.mlmodel"):
            broken = copy.deepcopy(self.manifest)
            broken["package_files"][0]["path"] = unsafe
            with self.assertRaises(ModelError):
                validate_catalog(broken)
        with self.assertRaises(ModelError):
            path_without_symlinks(self.root / "catalog" / ".." / PACKAGE_NAME)
        broken = copy.deepcopy(self.manifest)
        broken["package_files"][1]["path"] = broken["package_files"][0]["path"]
        with self.assertRaises(ModelError):
            validate_catalog(broken)

    def test_declared_tensor_preprocessing_and_research_status_cannot_drift(self):
        for mutation in ("shape", "boolean_dimension", "background", "production", "license"):
            broken = copy.deepcopy(self.manifest)
            if mutation == "shape":
                broken["contract"]["input"]["shape"] = [1, 3, 288, 512]
            elif mutation == "boolean_dimension":
                broken["contract"]["input"]["shape"][0] = True
            elif mutation == "background":
                broken["preprocessing"]["offline_only"] = False
            elif mutation == "production":
                broken["validation"]["production"] = True
            else:
                broken["license"]["sha256"] = "0" * 64
            with self.subTest(mutation=mutation), self.assertRaises(ModelError):
                validate_catalog(broken)

    def test_package_manifest_root_and_traversal_mismatches_rejected(self):
        path = self.source / "Manifest.json"
        original = path.read_bytes()
        for mutation in ("root", "path"):
            value = json_bytes(original)
            if mutation == "root":
                value["rootModelIdentifier"] = "00000000-0000-0000-0000-000000000003"
            else:
                value["itemInfoEntries"][value["rootModelIdentifier"]]["path"] = "../model.mlmodel"
            path.write_text(json.dumps(value))
            self.rebind_fixture()
            with self.assertRaises(ModelError):
                verify(self.source, self.manifest_path)

    def test_existing_empty_or_populated_destination_is_preserved(self):
        self.destination.mkdir()
        with self.assertRaises(ModelError):
            stage(self.source, self.manifest_path, self.destination)
        marker = self.destination / "user-owned.txt"
        marker.write_text("keep this")
        with self.assertRaises(ModelError):
            stage(self.source, self.manifest_path, self.destination)
        self.assertEqual(marker.read_text(), "keep this")

    def test_kernel_exclusive_rename_preserves_raced_destination(self):
        temporary = self.root / "publish-temporary"
        temporary.mkdir()
        (temporary / "new.txt").write_text("new")
        self.destination.mkdir()
        marker = self.destination / "old.txt"
        marker.write_text("keep")
        original_lexists = os.path.lexists
        with mock.patch("os.path.lexists", side_effect=lambda p: False if Path(p) == self.destination else original_lexists(p)):
            with self.assertRaises((ModelError, OSError)):
                atomic_publish_new(temporary, self.destination)
        self.assertEqual(marker.read_text(), "keep")
        self.assertTrue((temporary / "new.txt").exists())
        self.assertFalse((self.destination / "new.txt").exists())

    def test_copy_failure_cleans_only_current_temporary(self):
        unrelated = self.root / "unrelated"
        unrelated.mkdir()
        marker = unrelated / "user.txt"
        marker.write_text("keep")
        original = file_record

        def fail_on_copy(path, expected=None, destination=None, keep_bytes=False):
            if destination is not None:
                raise OSError("injected copy failure")
            return original(path, expected, destination, keep_bytes)

        with mock.patch.dict(globals(), {"file_record": fail_on_copy}):
            with self.assertRaises(OSError):
                stage(self.source, self.manifest_path, self.destination)
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.root.glob(".independent-ball-stage-*")))
        self.assertEqual(marker.read_text(), "keep")

    def test_source_change_after_copy_is_rejected_without_publication(self):
        original = file_record
        changed = False

        def mutate_after_copy(path, expected=None, destination=None, keep_bytes=False):
            nonlocal changed
            result = original(path, expected, destination, keep_bytes)
            if destination is not None and Path(path).name == "weight.bin" and not changed:
                data = Path(path).read_bytes()
                Path(path).write_bytes(bytes([data[0] ^ 1]) + data[1:])
                changed = True
            return result

        with mock.patch.dict(globals(), {"file_record": mutate_after_copy}):
            with self.assertRaises(ModelError):
                stage(self.source, self.manifest_path, self.destination)
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.root.glob(".independent-ball-stage-*")))

    def test_explicit_manifest_pin_and_receipt_no_overwrite(self):
        with self.assertRaisesRegex(ModelError, "pinned manifest"):
            verify(self.source, self.manifest_path, "0" * 64)
        payload = verify(self.source, self.manifest_path, hashlib.sha256(self.manifest_path.read_bytes()).hexdigest())
        output = self.root / "verify-receipt.json"
        write_receipt_atomic(output, payload)
        before = output.read_bytes()
        with self.assertRaises(ModelError):
            write_receipt_atomic(output, payload)
        self.assertEqual(output.read_bytes(), before)

    def test_duplicate_and_nonfinite_json_metadata_rejected(self):
        for data in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":1e999}'):
            with self.assertRaises(ModelError):
                json_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    commands = parser.add_subparsers(dest="command")
    for name in ("verify", "stage"):
        command = commands.add_parser(name)
        command.add_argument("--source", type=Path, required=True, help="Explicit existing .mlpackage source")
        command.add_argument("--manifest", type=Path, required=True, help="Reviewed text catalog with sibling LICENSE and README.md")
        command.add_argument("--expected-manifest-sha256", help="Optional explicit pin for an external catalog copy")
        if name == "verify":
            command.add_argument("--receipt", type=Path, help="Optional new receipt JSON; existing files are refused")
        else:
            command.add_argument("--destination", type=Path, required=True, help="Explicit new staging directory")
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ModelTests))
        return 0 if result.wasSuccessful() else 1
    try:
        if args.command == "verify":
            payload = verify(args.source, args.manifest, args.expected_manifest_sha256)
            if args.receipt:
                write_receipt_atomic(args.receipt, payload)
        elif args.command == "stage":
            payload = stage(args.source, args.manifest, args.destination, args.expected_manifest_sha256)
        else:
            parser.error("Choose verify, stage, or --self-test")
        print(json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False))
        return 0
    except (ModelError, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"prepare-independent-ball-model: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
