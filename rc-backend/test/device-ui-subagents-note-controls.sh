#!/bin/bash
# controls-for: ../ios/Sources/Screens/Conversation/SubagentsView.swift
#
# 電話が机の 1 文(「Background shells and teammates are not listed here.」= 一覧が見えない物の開示、対照表 #8 の後半の限界 2)を
# **そのまま描く**事の単体検査(SubagentsBlindSpotNoteTests)を**砂場の写し**で回し、変異 2 本で検査が本当に噛んでいる事を測る
# (2026-09-07)。
#   base: SubagentsBlindSpotNoteTests が緑(4 本)
#   M1  : 電話が数から文を組む(机の文を捨てる)→ 検査は赤にならなければならない
#   M2  : 識別子を変える(`subagents.notes`)→ 検査は赤にならなければならない
#
# 砂場 = `ios/` を rsync で写した一時 dir(生成物 `build*` は除く)。本物の木には一切書かない。
# 費用: xcodebuild を 3 回(冷えた初回が数分。`RC_STOP_UI_DD` に温かい derivedData を渡すと速い)。上限は 1 回 20 分。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS="$(cd "$HERE/../../ios" && pwd)"
SIM_NAME="${SIM_NAME:-iPhone-controls}"
LIMIT_S="${CONTROL_RUN_LIMIT_S:-1200}"
SB="$(mktemp -d "${TMPDIR:-/tmp}/rc-note-ui-XXXXXX")"
trap 'rm -rf "$SB"' EXIT INT TERM HUP
PASS=0; FAIL=0; UNMEASURED=0
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
ng() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
un() { echo "UNMEASURED  $1"; UNMEASURED=$((UNMEASURED+1)); }

if ! command -v xcodebuild >/dev/null 2>&1 || ! command -v xcodegen >/dev/null 2>&1; then
  un "xcodebuild / xcodegen が無い(此の機では測れない)"
  echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"; exit 3
fi
if ! xcrun simctl list devices available 2>/dev/null | grep -q "$SIM_NAME"; then
  un "simulator $SIM_NAME が無い"
  echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"; exit 3
fi

rsync -a --delete --exclude 'build' --exclude 'build-device' --exclude '*.xcodeproj' "$IOS/" "$SB/ios/" || { un "砂場を作れない"; echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"; exit 3; }
VW="$SB/ios/Sources/Screens/Conversation/SubagentsView.swift"
cp "$VW" "$SB/vw.orig"
DD="${RC_STOP_UI_DD:-$SB/dd}"

run() { # run <log> -> rc (142 = 上限)
  local log="$1" rc=0
  ( cd "$SB/ios" && xcodegen generate >/dev/null 2>&1 && \
    /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$LIMIT_S" \
      xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
      -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" -derivedDataPath "$DD" \
      -only-testing:RemoteMiniTests/SubagentsBlindSpotNoteTests test ) >"$log" 2>&1 || rc=$?
  printf '%s' "$rc"
}
ran() { grep -cE '^Test Case .* (passed|failed)' "$1" 2>/dev/null || true; }
failed() { grep -cE '^Test Case .* failed' "$1" 2>/dev/null || true; }

# base
rc=$(run "$SB/base.log")
if [ "$rc" = 142 ]; then un "base: 上限 ${LIMIT_S}s で打ち切り"; echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"; exit 3; fi
n=$(ran "$SB/base.log"); f=$(failed "$SB/base.log")
if [ "$rc" = 0 ] && [ "${n:-0}" -ge 4 ] && [ "${f:-0}" = 0 ]; then ok "base: SubagentsBlindSpotNoteTests が緑(ran=$n)"; else ng "base: rc=$rc ran=$n failed=$f(log: $SB/base.log)"; tail -20 "$SB/base.log" | sed 's/^/     | /'; echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"; exit 1; fi

# M1: 電話が数から文を組む(机の文を捨てる)
/usr/bin/sed -i '' 's/^    static func noteText(_ body: SubagentsBody) -> String { body.display.note }$/    static func noteText(_ body: SubagentsBody) -> String { "\\(body.subagents.count) subagents." }/' "$VW"
if cmp -s "$SB/vw.orig" "$VW"; then un "M1: 変異が当たらない(錨が動いた)"; else
  rc=$(run "$SB/m1.log"); f=$(failed "$SB/m1.log")
  if [ "$rc" = 142 ]; then un "M1: 上限で打ち切り"; elif [ "${f:-0}" -ge 1 ]; then ok "M1: 電話が文を組む版で検査が赤(failed=$f)"; else ng "M1: 机の文を捨てる版が緑で通った(検査が文を測っていない)"; fi
fi
cp "$SB/vw.orig" "$VW"

# M2: 識別子を変える
/usr/bin/sed -i '' 's/^    static let noteAccessibilityID = "subagents.note"$/    static let noteAccessibilityID = "subagents.notes"/' "$VW"
if cmp -s "$SB/vw.orig" "$VW"; then un "M2: 変異が当たらない(錨が動いた)"; else
  rc=$(run "$SB/m2.log"); f=$(failed "$SB/m2.log")
  if [ "$rc" = 142 ]; then un "M2: 上限で打ち切り"; elif [ "${f:-0}" -ge 1 ]; then ok "M2: 識別子を変えた版で検査が赤(failed=$f)"; else ng "M2: 識別子を変えた版が緑で通った"; fi
fi
cp "$SB/vw.orig" "$VW"

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$FAIL" = 0 ] && [ "$UNMEASURED" = 0 ]
