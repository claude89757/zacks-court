#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

COURT_SIMULATOR_ID=${1:-}
if [ -z "$COURT_SIMULATOR_ID" ]; then
    echo "Usage: ./scripts/test-ios-ui.sh SIMULATOR_UDID" >&2
    echo "List devices with: xcrun simctl list devices available" >&2
    exit 2
fi

./scripts/generate-ios.sh
xcrun simctl bootstatus "$COURT_SIMULATOR_ID" -b
COURT_ORIGINAL_SIZE=$(xcrun simctl ui "$COURT_SIMULATOR_ID" content_size)
COURT_RESULTS="$PWD/.local/ui-validation-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$COURT_RESULTS"
restore_size() { xcrun simctl ui "$COURT_SIMULATOR_ID" content_size "$COURT_ORIGINAL_SIZE" >/dev/null 2>&1 || true; }
trap restore_size EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_case() {
    COURT_CASE=$1
    COURT_LABEL=$2
    echo "Running $COURT_LABEL; log: $COURT_RESULTS/$COURT_LABEL.log"
    if ! xcodebuild test -project apps/iphone/ZacksCourt.xcodeproj -scheme ZacksCourt \
        -configuration Debug -destination "platform=iOS Simulator,id=$COURT_SIMULATOR_ID" \
        -derivedDataPath build/ui-validation -parallel-testing-enabled NO \
        "-only-testing:ZacksCourtUITests/WorkspaceUITests/$COURT_CASE" \
        -resultBundlePath "$COURT_RESULTS/$COURT_LABEL.xcresult" \
        >"$COURT_RESULTS/$COURT_LABEL.log" 2>&1; then
        tail -n 80 "$COURT_RESULTS/$COURT_LABEL.log" >&2
        return 1
    fi
    xcrun xcresulttool export attachments --path "$COURT_RESULTS/$COURT_LABEL.xcresult" \
        --output-path "$COURT_RESULTS/$COURT_LABEL-screenshots" >/dev/null
}

xcrun simctl ui "$COURT_SIMULATOR_ID" content_size large
run_case testOrientationTrainingAndBackgroundRecovery orientation-and-lifecycle
run_case testAnalysisSectionsHaveNoPlaceholderMeasurements analysis-empty-state
run_case testFinishedRecordShowsSummary record-summary
xcrun simctl ui "$COURT_SIMULATOR_ID" content_size accessibility-extra-extra-extra-large
run_case testLargeTextControlsRemainReachable accessibility-text
run_case testLargeTextHomeBrandTitle accessibility-home-brand
echo "PASS: simulator UI checks. Results and screenshots: $COURT_RESULTS"
