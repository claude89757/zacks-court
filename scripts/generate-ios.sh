#!/bin/sh
set -eu
COURT_SCRIPTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$COURT_SCRIPTS_DIR/../apps/iphone"
# independent (default): in-house models only, no S家 resources.
# both: S家 and in-house sets, switchable in the App; sjia: S家 only. Both need the S家 models you
# keep locally in .local/s-models (never in Git, see scripts/prepare-analysis-models.sh).
COURT_MODEL_SET=${COURT_MODEL_SET:-independent}
case "$COURT_MODEL_SET" in
    swing) COURT_MODEL_SET=sjia ;;  # old name
esac
case "$COURT_MODEL_SET" in
    both|sjia|independent) ;;
    *) echo "COURT_MODEL_SET must be independent, both or sjia" >&2; exit 1 ;;
esac
# The S家 reference chain is linked in only for builds that carry S家 models (docs/s-reference.md).
if [ "$COURT_MODEL_SET" = independent ] || [ "${COURT_CODE_ONLY:-0}" = "1" ]; then
    "$COURT_SCRIPTS_DIR/reference-chain.sh" off
else
    "$COURT_SCRIPTS_DIR/reference-chain.sh" on
fi
if [ "${COURT_CODE_ONLY:-0}" = "1" ]; then
    # Keep the specification beside project.yml so relative source/package paths
    # retain their meaning. Exclude assets even if this checkout has local models.
    COURT_CODE_SPEC=$(mktemp "$PWD/.code-only-project.XXXXXX")
    trap 'rm -f "$COURT_CODE_SPEC"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    python3 - "$COURT_CODE_SPEC" <<'PY'
from pathlib import Path
import sys

source = Path("project.yml").read_text()
resource = """      - path: ../../.local/AnalysisModels
        type: folder
        buildPhase: resources
        optional: true
"""
if source.count(resource) != 1:
    raise SystemExit("Unable to identify the optional model resource in project.yml")
Path(sys.argv[1]).write_text(source.replace(resource, "").replace("        CourtModelSet: sjia\n", "        CourtModelSet: code-only\n"))
PY
    echo "COURT_CODE_ONLY=1: generating without analysis model resources; this build cannot analyze tennis." >&2
    xcodegen generate --spec "$COURT_CODE_SPEC"
elif [ "$COURT_MODEL_SET" = independent ]; then
    "$COURT_SCRIPTS_DIR/prepare-independent-app-models.sh" >/dev/null
    COURT_INDEPENDENT_SPEC=$(mktemp "$PWD/.independent-project.XXXXXX")
    trap 'rm -f "$COURT_INDEPENDENT_SPEC"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    python3 - "$COURT_INDEPENDENT_SPEC" <<'PY'
from pathlib import Path
import sys
source = Path("project.yml").read_text()
resource = """      - path: ../../.local/AnalysisModels
        type: folder
        buildPhase: resources
        optional: true
"""
replacement = """      - path: ../../.local/IndependentModels
        type: folder
        buildPhase: resources
"""
if source.count(resource) != 1:
    raise SystemExit("Unable to identify the model resource in project.yml")
source = source.replace(resource, replacement)
source = source.replace("        CourtModelSet: sjia\n", "        CourtModelSet: independent\n")
Path(sys.argv[1]).write_text(source)
PY
    echo "COURT_MODEL_SET=independent: bundling only the independent research model; no S家 model resources." >&2
    xcodegen generate --spec "$COURT_INDEPENDENT_SPEC"
elif [ "$COURT_MODEL_SET" = both ]; then
    "$COURT_SCRIPTS_DIR/prepare-analysis-models.sh" >/dev/null
    "$COURT_SCRIPTS_DIR/prepare-independent-app-models.sh" >/dev/null
    COURT_BOTH_SPEC=$(mktemp "$PWD/.both-project.XXXXXX")
    trap 'rm -f "$COURT_BOTH_SPEC"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    python3 - "$COURT_BOTH_SPEC" <<'PY'
from pathlib import Path
import sys
source = Path("project.yml").read_text()
resource = """      - path: ../../.local/AnalysisModels
        type: folder
        buildPhase: resources
        optional: true
"""
independent = """      - path: ../../.local/IndependentModels
        type: folder
        buildPhase: resources
"""
if source.count(resource) != 1 or source.count("        CourtModelSet: sjia\n") != 1:
    raise SystemExit("Unable to identify the model resource in project.yml")
source = source.replace(resource, resource + independent).replace("        CourtModelSet: sjia\n", "        CourtModelSet: both\n")
Path(sys.argv[1]).write_text(source)
PY
    echo "COURT_MODEL_SET=both: bundling the S家 and in-house model sets; the App switches between them (default S家)." >&2
    xcodegen generate --spec "$COURT_BOTH_SPEC"
else
    "$COURT_SCRIPTS_DIR/prepare-analysis-models.sh" >/dev/null
    xcodegen generate --spec project.yml
fi
