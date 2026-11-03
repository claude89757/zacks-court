#!/bin/sh
# Verify and stage the S家 reference models for COURT_MODEL_SET=both or sjia; never fetch weights.
# The models are not in Git: each developer keeps their own copy in .local/s-models (or passes a
# directory as the first argument or COURT_ANALYSIS_MODELS_SOURCE). In a git worktree the main
# checkout's .local/s-models is used when the worktree has none.
set -eu
COURT_PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COURT_DEFAULT_SOURCE="$COURT_PROJECT_ROOT/.local/s-models"
if [ ! -d "$COURT_DEFAULT_SOURCE" ]; then
    COURT_COMMON=$(git -C "$COURT_PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    [ -n "$COURT_COMMON" ] && [ -d "$COURT_COMMON/../.local/s-models" ] && COURT_DEFAULT_SOURCE="$COURT_COMMON/../.local/s-models"
fi
COURT_MODELS_SOURCE=${1:-${COURT_ANALYSIS_MODELS_SOURCE:-"$COURT_DEFAULT_SOURCE"}}
COURT_MODELS_DESTINATION=${2:-"$COURT_PROJECT_ROOT/.local/AnalysisModels"}
exec python3 - "$COURT_MODELS_SOURCE" "$COURT_MODELS_DESTINATION" <<'PY'
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile

MANIFEST_SHA256 = "cdb25be7f35971ad36234397f4092ca5c1d1fe38336a337c52bf8fbb0a8f1117"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def relative(value):
    require(isinstance(value, str) and bool(value), "empty model path")
    path = PurePosixPath(value)
    require(not path.is_absolute() and ".." not in path.parts and str(path) == value, "unsafe model path")
    return path


def verify(root):
    require(root.exists() and stat.S_ISDIR(root.lstat().st_mode), "S家 models not found (they are not in Git; put your own copy in .local/s-models, or build with the default COURT_MODEL_SET=independent): " + str(root))
    manifest = root / "manifest.json"
    require(manifest.is_file() and not manifest.is_symlink(), "missing manifest.json")
    require(sha256(manifest) == MANIFEST_SHA256, "model manifest digest mismatch")
    data = json.loads(manifest.read_text())
    require(data["modelCount"] == len(data["models"]) == 21, "model count mismatch")
    expected = {"manifest.json"}
    expected_directories = set()
    count = total = 0
    for model in data["models"]:
        directory = relative(model["directory"])
        require(len(directory.parts) == 1 and str(directory).endswith(".mlmodelc"), "invalid model directory")
        model_bytes = 0
        for item in model["files"]:
            name = directory / relative(item["path"])
            require(str(name) not in expected, "duplicate file")
            expected.add(str(name))
            expected_directories.update(str(parent) for parent in name.parents if str(parent) != ".")
            path = root / str(name)
            require(path.exists() and stat.S_ISREG(path.lstat().st_mode), "missing/nonregular model file: " + str(name))
            if path.stat().st_size != item["bytes"]:
                with path.open("rb") as stream:
                    require(not stream.read(64).startswith(b"version https://git-lfs.github.com/spec/"),
                            "Git LFS pointer instead of model data, run `git lfs install && git lfs pull`: " + str(name))
            require(path.stat().st_size == item["bytes"], "model size mismatch: " + str(name))
            require(sha256(path) == item["sha256"], "model file digest mismatch: " + str(name))
            model_bytes += item["bytes"]
            count += 1
        require(model_bytes == model["bytes"], "model byte count mismatch")
        total += model_bytes
    actual = set()
    for current, directories, files in os.walk(root, followlinks=False):
        for name in directories:
            path = Path(current) / name
            require(stat.S_ISDIR(path.lstat().st_mode), "symlink/non-directory in model bundle")
            require(path.relative_to(root).as_posix() in expected_directories, "unexpected model directory")
        for name in files:
            actual.add((Path(current) / name).relative_to(root).as_posix())
    require(actual == expected, "unexpected or missing model files")
    require(count == 213 and total == data["bytes"] == 275637324, "bundle inventory mismatch")
    require(sha256(manifest) == MANIFEST_SHA256, "manifest changed during verification")


try:
    source, destination = map(lambda value: Path(value).absolute(), sys.argv[1:3])
    if destination.exists():
        verify(destination)
    else:
        verify(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=".court-models-", dir=destination.parent))
        try:
            shutil.copytree(source, staging, dirs_exist_ok=True)
            verify(staging)
            require(not destination.exists(), "destination appeared while preparing models")
            staging.rename(destination)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    print("ANALYSIS_MODELS_OK source=s-models models=21 files=213 bytes=275637324 manifest_sha256=" + MANIFEST_SHA256, file=sys.stderr)
    print(destination)
except (OSError, ValueError, KeyError, TypeError) as error:
    print("ANALYSIS_MODELS_INVALID: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
