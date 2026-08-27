#!/bin/bash
# no-control: 計器。simulator と build 済みの app が要り、commit 時には回せない
# no-operator: DoD の画を撮りたい時に人が撃つ。simulator を起こして app を焼く物なので
#   門から 1 commit ごとに回すと数分 x 毎回の費用になる(2026-08-15、錠の対照が
#   `controls-for:` で此の file を名指しした事で「対照は在るが走らせる物が無い」と挙がった。
#   宣言を狭めて逃げると C1-C4 が此の file の取っ手の外れを見なくなるので、印の側で言う)
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
# ★日付をべた書きしない(2026-08-27)。2026-08-05 に焼いた定数が3週間そのまま残り、
#   撮った画が毎回「3週間前の日付の dir」へ落ちていた。日付入りの dir に**別の日の画**が
#   混ざると、後から証拠を引く時にどちらの版か判らなくなる —— 日付は名前の意味そのもの。
#   ★既存の evidence-2026-08-05/(22 ファイル)は動かさない。WORKLOG や HANDOFF が
#   その path で成果物を指しているので、動かすと文書側の参照が全部腐る。
#   再現目的で古い dir へ入れたい時だけ RC_SHOTS_OUT で上書きする。
OUT_DIR="${RC_SHOTS_OUT:-$HERE/../.harness/evidence-$(date +%Y-%m-%d)}"
mkdir -p "$OUT_DIR"

STATES=("$@")
[ "${#STATES[@]}" -eq 0 ] && STATES=(list-normal list-panefault list-empty)

# 版を差し込んでから generate する(2026-08-08 / 監査 X2-7)。此処は撮った絵が
# そのまま DoD の証拠になる経路なので、版の行が `rev unknown` のまま写ると
# 「機能が壊れている」と読まれる —— 実際には差し込みを通っていないだけ。
# 計算は build.sh にしか無い(`--print-rev`)。写しを持つと片方だけ腐る。
RC_BUILD_REV="$("$HERE/tools/build.sh" --print-rev)"
export RC_BUILD_REV

# ★生成物(ios/Info.plist / RemoteMini.xcodeproj)を触る走行を **1 本に絞る**。
# 2026-08-15、此れが無くて `build.sh --sim` と対照台本が `RC_BUILD_REV` の刻印を
# 潰し合い、**偽の赤が 9 本**出た(製品の欠陥と見分けが付かない赤)。
. "$HERE/tools/xcode-tree-guard.sh"
trap 'xtl_release' EXIT

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
