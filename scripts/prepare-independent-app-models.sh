#!/bin/sh
set -eu
COURT_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COURT_INDEPENDENT_ROOT="$COURT_REPO/.local/IndependentModels"
# Frozen in-house ball models: the FP32 research conversion (offline, bit-for-bit with Python) and its
# FP16 conversion for the Neural Engine (live chain). COURT_INDEPENDENT_MODEL_SOURCE overrides the FP32
# source package only, as before.
for COURT_MODEL_ID in tracknetv3-base-v1 tracknetv3-base-fp16-v1; do
    COURT_CATALOG="$COURT_REPO/assets/independent-models/$COURT_MODEL_ID/manifest.json"
    COURT_INDEPENDENT_SOURCE="$COURT_REPO/assets/independent-model-weights/$COURT_MODEL_ID/TrackNetV3Base.mlpackage"
    if [ "$COURT_MODEL_ID" = tracknetv3-base-v1 ]; then
        COURT_INDEPENDENT_SOURCE=${COURT_INDEPENDENT_MODEL_SOURCE:-"$COURT_INDEPENDENT_SOURCE"}
    fi
    COURT_INDEPENDENT_STAGE="$COURT_INDEPENDENT_ROOT/$COURT_MODEL_ID"
    COURT_MANIFEST_SHA=$(shasum -a 256 "$COURT_CATALOG" | cut -d ' ' -f 1)
    # The verifier checks package bytes, full file set, original MIT notice, and
    # rejects Git LFS pointers. No download or model inference occurs here.
    python3 "$COURT_REPO/scripts/prepare-independent-ball-model.py" verify \
        --source "$COURT_INDEPENDENT_SOURCE" --manifest "$COURT_CATALOG" >/dev/null
    if [ -e "$COURT_INDEPENDENT_STAGE" ]; then
        python3 "$COURT_REPO/scripts/prepare-independent-ball-model.py" verify \
            --source "$COURT_INDEPENDENT_STAGE/TrackNetV3Base.mlpackage" \
            --manifest "$COURT_INDEPENDENT_STAGE/manifest.json" \
            --expected-manifest-sha256 "$COURT_MANIFEST_SHA" >/dev/null
    else
        python3 "$COURT_REPO/scripts/prepare-independent-ball-model.py" stage \
            --source "$COURT_INDEPENDENT_SOURCE" --manifest "$COURT_CATALOG" \
            --destination "$COURT_INDEPENDENT_STAGE" >/dev/null
    fi
done
# Xcode's folder reference includes this entire parent directory. Reject unrelated
# contents rather than copying arbitrary local experiment files into the App.
python3 - "$COURT_INDEPENDENT_ROOT" "$COURT_REPO/.local/independent-model-build-receipts" <<'PY'
from pathlib import Path
import sys
import uuid
root = Path(sys.argv[1])
models = ["tracknetv3-base-fp16-v1", "tracknetv3-base-v1"]
if sorted(p.name for p in root.iterdir()) != models:
    raise SystemExit("Unexpected files in .local/IndependentModels; keep this App resource directory dedicated to verified models")
for name in models:
    stage = root / name
    receipt = stage / "receipt.json"
    if receipt.exists():
        receipts = Path(sys.argv[2])
        receipts.mkdir(parents=True, exist_ok=True)
        receipt.rename(receipts / (str(uuid.uuid4()) + ".json"))
    if sorted(p.name for p in stage.iterdir()) != ["LICENSE", "README.md", "TrackNetV3Base.mlpackage", "manifest.json"]:
        raise SystemExit("Unexpected independent App resource files")
    # Models and notices are distributable resources, not private recordings. Make
    # their bundle permissions readable after installation by another OS user.
    stage.chmod(0o755)
    for path in stage.rglob("*"):
        if path.is_symlink():
            raise SystemExit("Symlink in independent App resources")
        path.chmod(0o755 if path.is_dir() else 0o644)
root.chmod(0o755)
PY
printf '%s\n' "$COURT_INDEPENDENT_ROOT"
