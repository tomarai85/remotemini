#!/bin/bash
# controls-for: ios/Sources/Screens/Conversation/ConversationView.swift ios/Sources/Core/ComposerNotices.swift ios/Sources/Screens/Shared/RCConnectivityBanner.swift ios/Sources/Screens/Shared/TapTarget.swift ios/UITests/TapTargetUITests.swift ios/UITests/InFlightUITests.swift ios/UITests/AttachFileButtonUITests.swift
#
# **画面を描く file を触ったら、画面を描いて測る検査が回る**事を門で保証する(2026-09-08)。
#
# 何が起きたか(この対照が生まれた理由 = `.harness/evidence-2026-09-08/ui-tests-were-never-in-the-commit-path.md`):
#   9/7 の UI 作り直しを「電話の単体 全件 緑」と報告して出荷した。翌日 UI 検査を自分で全部
#   走らせたら **8 件 赤**で、内 4 つは独立した製品の欠陥だった —— 停止ボタンの的が 30pt
#   (下限 44pt)、選択待ちで停止ボタンが**存在しない**、打鍵が飛んでいる間 画面が無言(§2.56)、
#   帯を畳んだ時に時刻の識別子ごと文へ溶かした。どれも Tom が一番急いでいる時に触る所。
#
# 何故 門を素通りしたか(実測):
#   門は `controls-for:` で「触った file に紐づく対照」を回す。走査した結果、
#     TapTargetUITests / InFlightUITests / AttachButtonUITests は **対照 0 本**、
#     ConversationView.swift に紐づく 3 本のうち XCUITest を回すのは着地の負荷試験だけ、
#     inflight-sentence-control は `RemoteMiniTests/…`(**単体 class のみ**)。
#   つまり画面を描く file を触っても、描いて測る検査は 1 本も回らなかった。あれらが走るのは
#   人が `build.sh --sim`(全件・20 分超)を手で叩いた時だけで、門は其れを起動しない。
#   ★同型の 2 度目である事: 9/7 にも「停止ボタンが何処にも無いのに全検査が緑」を踏み、
#     其の時の対策は**私の注意**だった。注意は 1 日で破れたので、門へ降ろす。
#
# 何を測るか:
#   段 0(基準)  … 触った状態の木で、下の 3 class が**緑**である事。之だけで 9/8 の 8 件は全部捕まる。
#   段 1(負の対照)… 検査が空回りしていない事を、欠陥を植えて**赤くなる**事で測る:
#       MU1 停止ボタンから `.tapTarget()` を外す        -> TapTargetUITests
#       MU2 「今飛んでいる操作」を「出来ない理由」の下へ戻す -> InFlightUITests
#     其々 9/8 に実際に起きた欠陥そのもの。植えて赤くならないなら、其の検査は緑を出す資格が無い。
#
# 何を測らないか(意図した除外):
#   `AttachButtonUITests` は fixture を渡さない = **本物の机**に繋ぐ検査で、机が落ちていれば
#   自分で XCTSkip する。門の中で「繋がっているか」に結果が左右されるので此処では回さない
#   (回線の都合が製品の赤に化ける形は、あの file の header が明示的に禁じている)。
#
# 走らせ方: bash ios/tools/composer-surface-control.sh
# 終了コード: 0=基準が緑かつ全変異が期待通り赤 / 1=其れ以外 / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
ROOT="$(cd "$HERE/.." && pwd)"
IOS="$HERE"
. "$HERE/tools/sim-device.sh"
BUNDLE_ID="com.tomarai.remotemini"
SIM_UDID="$(xcrun simctl list devices 2>/dev/null | grep -F "$SIM_NAME (" | head -1 \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/composer-surface.XXXXXX")"
INFLIGHT="${TMPDIR:-/tmp}/rc-ios-mutation-inflight.tsv"
PASS=0; FAIL=0; UNMEASURED=0

# 書き換え先は**砂場**。作業中の木は 1 バイトも触らない(土台 = ios/tools/mutation-sandbox.sh)。
. "$IOS/tools/mutation-sandbox.sh"
ms_prepare || exit 2
CV="$MS_TREE/Sources/Screens/Conversation/ConversationView.swift"
CN="$MS_TREE/Sources/Core/ComposerNotices.swift"
TARGETS=("$CV" "$CN")

# 回す class。**実名で持つ**(件数を発明しない)。
CLASSES=(
    "RemoteMiniUITests/TapTargetUITests"
    "RemoteMiniUITests/InFlightUITests"
    "RemoteMiniUITests/AttachFileButtonUITests"
    "RemoteMiniUITests/ConversationUITests"
)

ORIG="$WORK/orig"
mkdir -p "$ORIG"
snap_path() { printf '%s/%s' "$ORIG" "$1"; }   # $1 = TARGETS の添字

restore_one() { # $1 = 添字
    local i="$1"
    local f s
    f="${TARGETS[$i]}"
    s="$(snap_path "$i")"
    [ -f "$s" ] || return 0
    /bin/cp "$s" "$f"
}
restore_all() {
    local j=0
    while [ "$j" -lt "${#TARGETS[@]}" ]; do
        restore_one "$j"
        j=$((j+1))
    done
}

cleanup() {
    local i=0
    while [ "$i" -lt "${#TARGETS[@]}" ]; do
        restore_one "$i"
        i=$((i+1))
    done
    /bin/rm -f "$INFLIGHT"
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] || return 0
    find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$WORK" -type d -depth -exec /bin/rmdir {} + 2>/dev/null
}
trap 'cleanup; ms_release' EXIT

# ★此の区間は**全対照で一字一句同じ**でなければならない
#   (`rc-backend/test/mutation-recovery-copy.test.mjs` が突き合わせる)。
#   1本だけ直すと、他が残した変異を此方が復元の基準点として複製する。
#   ★砂場へ移った後も残す: 台帳は**全対照で共有**なので、まだ作業中の木を触る
#     対照(bar-material / conversation-ui / signout-notice)が殺された時、
#     次に走った此の台本が其の取り残しを戻す。移行の途中こそ効く。
#   ★2026-08-30、中の助言文を「砂場では git checkout は効かない」と直そうとして
#     単体を1本落とした —— 共有ブロックへの善意の一行が、突き合わせを壊す。
# ---- 前回の走行が殺されていたら、その取り残しを先に戻す(ここから)-------------
# ★この位置でなければならない: 下の複製 loop より**前**。後に置くと、変異したバイトを
#   「走る前の中身」として複製してしまい、復元の基準点そのものが汚染される。
if [ -f "$INFLIGHT" ]; then
    recovered=""; lost=""
    while IFS="$(printf '\t')" read -r rf rs; do
        [ -n "${rf:-}" ] || continue
        if [ -f "$rs" ] && [ -f "$rf" ]; then
            if ! cmp -s "$rs" "$rf"; then
                /bin/cp "$rs" "$rf"
                recovered="$recovered ${rf#$ROOT/}"
            fi
        else
            lost="$lost ${rf#$ROOT/}"
        fi
    done < "$INFLIGHT"
    /bin/rm -f "$INFLIGHT"
    if [ -n "$recovered" ]; then
        echo "復旧: 前回の走行が殺されて残っていた変異を戻した:$recovered"
    fi
    if [ -n "$lost" ]; then
        echo "UNMEASURED  前回の変異を戻せない(複製が消えている):$lost"
        echo "            何が変わっているかは git diff で見え、戻すのは git checkout -- で足りる。"
        exit 2
    fi
fi
# ---- 前回の取り残しの復旧(ここまで)-----------------------------------------

i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    f="${TARGETS[$i]}"
    if [ ! -f "$f" ]; then
        echo "UNMEASURED  変異の対象が無い: ${f#$ROOT/}"
        exit 2
    fi
    if ! /bin/cp "$f" "$(snap_path "$i")"; then
        echo "UNMEASURED  複製を取れなかった: ${f#$ROOT/}(復元手段が無いので走らない)"
        exit 2
    fi
    i=$((i+1))
done
: > "$INFLIGHT"
i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    printf '%s\t%s\n' "${TARGETS[$i]}" "$(snap_path "$i")" >> "$INFLIGHT"
    i=$((i+1))
done

ok() { PASS=$((PASS+1)); echo "  OK   $1"; }
ng() { FAIL=$((FAIL+1)); echo "  NG   $1"; }
un() { UNMEASURED=$((UNMEASURED+1)); echo "  UNM  $1"; }

settle_sim() {
    [ -n "${SIM_UDID:-}" ] || return 0
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

# 走った検査の本数。0 = **一度も走っていない**(ビルドが通らない / simulator が起動を拒んだ)。
# 赤緑の別を見ない —— 取り直しの判断が此の値**しか**見ないので、落ちた assertion を
# 取り直しに流用できる形が構造上作れない。
ran_count() { # $1 = log
    local n
    n="$(grep -cE "Test Case '-\[RemoteMiniUITests\." "$1" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

run_ui_once() { # $1 = log -> rc を印字
    local log="$1" rc=0 args=()
    local c
    for c in "${CLASSES[@]}"; do args+=(-only-testing:"$c"); done
    ( cd "$MS_TREE" && xcodegen generate >/dev/null 2>&1 && \
      xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$MS_ROOT/build" "${args[@]}" test ) >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ★診断を stdout に書かない事。呼び出し側は `rc=$(run_ui …)` で**標準出力を
#   そのまま rc として読む**ので、1行混ぜるだけで rc が壊れる。
run_ui() { # $1 = log -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(run_ui_once "$log")"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(run_ui_once "$log")"
    fi
    printf '%s' "$rc"
}

failed_tests() { # $1 = log
    grep -oE "Test Case '-\[RemoteMiniUITests\.[A-Za-z]+ [a-zA-Z0-9_]+\]' failed" "$1" \
        | sed -E "s/^.*UITests\.[A-Za-z]+ ([a-zA-Z0-9_]+)\].*$/\1/" | sort -u | tr '\n' ' '
}

# ── 段 0: 基準が緑 ───────────────────────────────────────────────────────────
echo "段 0: 基準(${#CLASSES[@]} class)"
base_rc="$(run_ui "$WORK/base.log")"
base_n="$(ran_count "$WORK/base.log")"
if [ "$base_n" -eq 0 ]; then
    un "基準が一度も走っていない(ビルド不成立 / simulator)。全文: $WORK/base.log"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
if [ "$base_rc" = "0" ]; then
    ok "基準は緑($base_n 件 走行)"
else
    ng "★基準が赤: $(failed_tests "$WORK/base.log")(全文: $WORK/base.log)"
fi

# ── 段 1: 負の対照 ───────────────────────────────────────────────────────────
# 変異は sed ではなく python(複数行の塊を一致で置換する。当たらなければ UNMEASURED)。
mutate() { # $1 = file, $2 = 探す文, $3 = 置く文
    /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
}

probe() { # $1 = 名, $2 = file, $3 = old, $4 = new, $5 = 赤くなるべき検査
    local name="$1" f="$2" old="$3" new="$4" want="$5"
    if ! mutate "$f" "$old" "$new"; then
        un "$name: 変異の的が当たらない(本文が変わった = 見張っていない)"
        restore_all
        return
    fi
    local log="$WORK/$name.log" rc reds
    rc="$(run_ui "$log")"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        un "$name: 検査が一度も走っていない。全文: $log"
        restore_all
        return
    fi
    reds="$(failed_tests "$log")"
    if [ "$rc" = "0" ]; then
        ng "$name: 欠陥を植えても緑のまま = 此の検査は空回りしている"
    elif printf '%s' "$reds" | grep -q "$want"; then
        ok "$name -> $want が赤(赤: $reds)"
    else
        un "$name: 赤くはなったが $want ではない(赤: ${reds:-なし}, rc=$rc)。全文: $log"
    fi
    restore_all
}

echo "段 1: 負の対照(9/8 に実際に起きた欠陥を植え直す)"
probe MU1-tap-target-shrunk "$CV" \
'                        .tapTarget()
                        // ★見た目だけで状態を語る' \
'                        .frame(width: 30, height: 30)
                        // ★見た目だけで状態を語る' \
    testTheComposerButtonsAreThumbSizedIdleAndInFlight

probe MU2-in-flight-buried "$CN" \
'        if let choiceInFlight { return Urgent(id: "conversation.choiceInFlightNotice", text: choiceInFlight, tone: .warn) }' \
'        if composerDisabled == nil, let choiceInFlight { return Urgent(id: "conversation.choiceInFlightNotice", text: choiceInFlight, tone: .warn) }' \
    testChoiceInFlightSpinsOnlyTheKeyThatWasPressed

# ---- 復元の確認(想定ではなく観測する) ---------------------------------------
restore_all
not_restored=""
i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    if ! cmp -s "$(snap_path "$i")" "${TARGETS[$i]}"; then
        not_restored="$not_restored ${TARGETS[$i]#$ROOT/}"
    fi
    i=$((i+1))
done
if [ -n "$not_restored" ]; then
    echo "UNMEASURED  変異が残っている:$not_restored"
    UNMEASURED=$((UNMEASURED+1))
else
    echo "復元を確認(対象 ${#TARGETS[@]} file すべて走る前のバイトと一致)"
fi

if ! ms_assert_live_unchanged; then
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $((UNMEASURED + 1)) ---"
    echo "★本物の木が走行中に変わった = 此の走行の結果は使えない"
    exit 2
fi
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
