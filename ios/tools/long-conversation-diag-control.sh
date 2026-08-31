#!/bin/bash
# controls-for: ios/UITests/ConversationUITests.swift
#
# 「長い会話を開いた時どこへ寄るか」の検査が**倒れた時に画面を書き出す**事の対照。
#
# ── なぜ之を測るのか(2026-08-31)────────────────────────────────────────────
# 其の検査は全掃き 752 件の中でだけ **断続的に**倒れる(実測 FAIL/FAIL/PASS/PASS/PASS)。
# 原因は未特定 —— 待ちを 10 → 20 秒に延ばしても **23.4 秒で倒れ**、走行の記録では
# 20 秒間ずっと要素が存在しなかったので、混み具合ではない。band-aid は戻した。
# 追える材料は「倒れた瞬間に画面に何が居たか」しかないので、失敗時に
# `DIAG-LONG-CONVERSATION-BEGIN` … `END` で要素の有無と木を書き出す様にした(b6388f5)。
#
# ★問題は、**其の記録が一度も発火していない**事。緑の間は何も出ない = 書いた物が
#   本当に動くか判らない。今日 何度も踏んだ型(「配線されて見えるのに走らない」
#   「門が在るのに一度も閉じない」)そのものなので、**わざと倒して**確かめる。
#
# 測り方: 砂場(`mutation-sandbox.sh`)の中で fixture を壊し(`.long` が短い履歴を返す
# = `行 090` が存在しない)、其の1本だけを走らせて、log に記録が出る事を見る。
# ★本物の木は1バイトも触らない。走行後に `ms_assert_live_unchanged` で確かめる。
#
#   L1 ★変異を入れると検査が倒れる(= 之から測る物が「倒れた時の振る舞い」である事)
#   L2 ★倒れた時に `DIAG-LONG-CONVERSATION-BEGIN`/`END` が出る
#   L3 ★4つの在否(loadEarlier / composerField / line 031 / line 090)が出る
#   L4 ★要素の木が出る(空でない = 画面の中身が読める)
#   L5 ★緑の時は何も出さない(常に吐く実装ではない)
#   Z  本物の木が変わっていない
#
# 既知の費用(隠さない): 砂場で xcodebuild を2回(倒れる版・通る版)。実測 数分。
#
# 使い方: bash ios/tools/long-conversation-diag-control.sh
# 終了コード: 0=全部緑 / 1=1本でも赤 / 2=測定不成立
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # = ios/tools
SIM_NAME="${RC_SIM_NAME:-iPhone-dogfood}"
TEST_ID="RemoteMiniUITests/ConversationUITests/testOpeningALongConversationLandsAtTheNewestLine"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  OK   $1"; }
ng() { FAIL=$((FAIL+1)); echo "  NG   $1"; }

. "$HERE/mutation-sandbox.sh"
ms_prepare || exit 2
WORK="$(mktemp -d)"
trap '/bin/rm -rf "$WORK"; ms_release' EXIT

FIX="$MS_TREE/Sources/Core/HistoryFixture.swift"
[ -f "$FIX" ] || { echo "砂場に fixture が無い: $FIX"; exit 2; }

run_one() { # $1 = log path -> rc を印字
    local log="$1" rc=0
    ( cd "$MS_TREE" && xcodegen generate >/dev/null 2>&1 && \
      xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$MS_ROOT/build" \
        -only-testing:"$TEST_ID" test ) >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ── まず倒れない事を見る(L5 の基準)──────────────────────────────────────
echo "== 1/2 素の砂場(倒れない筈)=="
base_rc="$(run_one "$WORK/base.log")"
if [ "$base_rc" = "0" ]; then
    ok "L5 基準: 素の砂場では通る"
    if grep -q "DIAG-LONG-CONVERSATION-BEGIN" "$WORK/base.log"; then
        ng "L5 緑でも吐いている(常に吐く実装 = 記録の意味が無い)"
    else
        ok "L5 ★緑の時は何も出さない"
    fi
else
    # ★倒れた場合は「変異の効果」を測れない。緑に丸めず測定不成立で降りる。
    echo "  UNM  素の砂場で既に倒れている(rc=$base_rc)= 変異の効果を測れない"
    echo "  (断続的に倒れる検査なので、此の回が其の 1 回かもしれない。撃ち直す事)"
    ms_assert_live_unchanged || echo "  ★本物の木が変わった"
    echo ""
    echo "LONG-CONVERSATION-DIAG-CONTROL: pass=$PASS fail=$FAIL (測定不成立)"
    exit 2
fi

# ── 倒して、記録が出る事を見る ────────────────────────────────────────────
# `.long` の最初の取得を **1 行だけ**にする = `行 090` が存在しない。
echo "== 2/2 fixture を壊した砂場(倒れる筈)=="
python3 - "$FIX" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
a = "history: (31...90).map(line),"
b = "history: (31...31).map(line),"
if a not in s:
    sys.stderr.write("ANCHOR-MISS\n"); sys.exit(3)
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
[ $? -eq 0 ] || { echo "  NG   変異の錨が動いた(fixture の形が変わった)"; FAIL=1; }

mut_rc="$(run_one "$WORK/mut.log")"
if [ "$mut_rc" != "0" ]; then
    ok "L1 ★変異を入れると検査が倒れる"
else
    ng "L1 変異しても通った = 此の検査は履歴の中身を測っていない"
fi

if grep -q "DIAG-LONG-CONVERSATION-BEGIN" "$WORK/mut.log" \
   && grep -q "DIAG-LONG-CONVERSATION-END" "$WORK/mut.log"; then
    ok "L2 ★倒れた時に記録が出る(発火する事を実測)"
else
    ng "L2 倒れたのに記録が出ない = 書いた物が動いていない"
fi

miss=""
for k in "conversation.loadEarlier exists" "conversation.composerField exists" \
         "line 031 exists" "line 090 exists"; do
    grep -q "$k" "$WORK/mut.log" || miss="$miss [$k]"
done
[ -z "$miss" ] && ok "L3 ★4つの在否が出る(画面のどこに居るか判る)" \
               || ng "L3 在否が欠けている:$miss"

# 木は複数行の要素一覧。`Application, ` を含む行が出る筈。
if /usr/bin/sed -n '/DIAG-LONG-CONVERSATION-BEGIN/,/DIAG-LONG-CONVERSATION-END/p' "$WORK/mut.log" \
   | grep -qE "Application|Window|Attributes:"; then
    ok "L4 ★要素の木が出る(中身が読める)"
else
    ng "L4 木が空 = 記録は出たが画面が読めない"
fi

# ── Z 本物の木 ────────────────────────────────────────────────────────────
if ms_assert_live_unchanged; then ok "Z 本物の木は1バイトも変わっていない"
else ng "Z ★本物の木が変わった(変異が漏れた)"; fi

echo ""
echo "LONG-CONVERSATION-DIAG-CONTROL: pass=$PASS fail=$FAIL"
exit $(( FAIL > 0 ))
