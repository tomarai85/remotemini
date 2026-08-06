#!/bin/bash
# no-control: 計器。simulator と build 済みの app が要り、commit 時には回せない
# Sprint 2 DoD screenshots (brief §5-c) -- entirely headless via `xcrun simctl`.
# `open -a Simulator` is never used here or anywhere in this project: Tom's
# machine only ever runs a GUI Simulator window if he opens one himself.
#
#   ./tools/shots.sh                 -- capture all 3 required states
#   ./tools/shots.sh list-normal     -- capture just one state
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
cd "$HERE" || { echo "ios/ に入れない"; exit 2; }

DERIVED="$HERE/build"
mkdir -p "$DERIVED"
SIM_NAME="${SIM_NAME:-iPhone-dogfood}"
BUNDLE="com.tomarai.remotemini"
OUT_DIR="$HERE/../.harness/evidence-2026-08-05"
mkdir -p "$OUT_DIR"

STATES=("$@")
[ "${#STATES[@]}" -eq 0 ] && STATES=(list-normal list-panefault list-empty)

xcodegen generate >"$DERIVED/xcodegen-shots.log" 2>&1
if [ $? -ne 0 ]; then
    echo "xcodegen generate に失敗"
    tail -20 "$DERIVED/xcodegen-shots.log"
    exit 1
fi

# Debug config -- same binary `build.sh --sim` produces at the same derived path,
# but built here directly (`build`, not `test`) so this script does not depend on
# having run the test suite first.
xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
    -sdk iphonesimulator -derivedDataPath "$DERIVED" build \
    >"$DERIVED/xcodebuild-Debug-shots.log" 2>&1
if [ $? -ne 0 ]; then
    echo "Debug の iphonesimulator ビルドが失敗"
    tail -20 "$DERIVED/xcodebuild-Debug-shots.log"
    exit 1
fi

APP="$DERIVED/Build/Products/Debug-iphonesimulator/RemoteMini.app"
[ -d "$APP" ] || { echo "Debug の .app が見当たらない -- $APP"; exit 1; }

DEV_LINE="$(xcrun simctl list devices | grep -F "$SIM_NAME (" | head -1)"
[ -n "$DEV_LINE" ] || { echo "シミュレータ '$SIM_NAME' が見当たらない"; exit 1; }
DEV="$(echo "$DEV_LINE" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"
[ -n "$DEV" ] || { echo "'$SIM_NAME' の UDID が読み取れない"; exit 1; }

if ! echo "$DEV_LINE" | grep -q "Booted"; then
    xcrun simctl boot "$DEV" >/dev/null 2>&1
    xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1
fi

xcrun simctl install "$DEV" "$APP"

for state in "${STATES[@]}"; do
    SIMCTL_CHILD_RC_UI_FIXTURE="$state" \
        xcrun simctl launch --terminate-running-process "$DEV" "$BUNDLE" >/dev/null
    # Give SwiftUI a moment to render past the launch screen before capturing --
    # no top-level bare `sleep`, only inside this script, per brief §5-c.
    sleep 2
    xcrun simctl io "$DEV" screenshot "$OUT_DIR/$state.png"
    echo "==> $OUT_DIR/$state.png"
    xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1
done
