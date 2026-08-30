#!/bin/bash
# controls-for: tools/app-usage-census.sh
#
# app-usage-census.sh の**挙動**対照。
#
# ★測る中心は「数えられるか」ではない —— それは1行の awk でも通る。
#   測るのは **log が切られた後も、既に観測した数が残るか**。
#   此の道具が在る理由がそれだから(H-3 の観測窓を、同じ日に据えた上限が消しに来る)。
#
#   C1 日ごとに数え、client=tool を混ぜない
#   C2a ★日が log から丸ごと消えても残る(畳み込みの引き継ぎ節)
#   C2b ★日は残るが件数が減って見えても下がらない(日ごとの max)
#   C3  ★変異対照を機構ごとに2本。1本にまとめると片方が死んでいても緑が出る
#   C4 同じ日が本当に増えたら**伸びる**(max が固まって止まらない事)
#   C5 元 log が無ければ rc=2(0 件と読ませない)
#   C6 置き場が上限を掛けている dir の**外**である事(既定値の検査)
#   C7 client=apple の様な語に巻き込まれない(語として当てている)
#
# 使い方: bash rc-backend/test/app-usage-census-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/app-usage-census.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

row() {  # row <ISO日時> <client>
    printf '[rc-backend] req %s GET /api/sessions route=x client=%s code=200 reason=- ms=1\n' "$1" "$2"
}
count_for() { awk -F'\t' -v d="$1" '$1==d {print $2}' "$2" 2>/dev/null; }

# ── C1 日ごとに数え、tool を混ぜない ──────────────────────────────────────
L="$SB/a.log"; O="$SB/a.tsv"
{ row 2026-08-29T20:00:00.000Z app; row 2026-08-29T21:00:00.000Z tool
  row 2026-08-29T22:00:00.000Z app; row 2026-08-30T05:33:00.000Z app; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" bash "$SUT" >/dev/null 2>&1
if [ "$(count_for 2026-08-29 "$O")" = "2" ] && [ "$(count_for 2026-08-30 "$O")" = "1" ]; then
    ok "C1 日ごとに数え、client=tool を混ぜない"
else ng "C1 日ごとの数" "$(cat "$O" 2>/dev/null | tr '\n' ' ')"; fi

# ── C2 log を切っても前に数えた日が減らない ★中核 ─────────────────────────
# ★守っている機構は**2つ在り、別々に測らないと片方が空虚になる**(初版はここを取り違え、
#   C3 の変異が赤くならない事で判った):
#     (a) 日が log から**丸ごと消えた**時 → 畳み込みの END 節が古い行を引き継ぐ
#     (b) 日は残っているが**件数が減った**時 → 日ごとの max
#   初版は (a) だけを測って「max を測っている」と註記していた。註記が実装とずれていた。

# (a) 日が丸ごと消える(上限が古い方を捨てた形)
{ row 2026-08-30T06:00:00.000Z app; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" bash "$SUT" >/dev/null 2>&1
if [ "$(count_for 2026-08-29 "$O")" = "2" ]; then
    ok "C2a 日が log から消えても 8/29 の 2 件が残る(引き継ぎ節)"
else ng "C2a 日が消えた後も残る" "8/29 = $(count_for 2026-08-29 "$O")"; fi

# (b) 日は残っているが件数が減った(切り口が日の途中に来た形)
{ row 2026-08-29T22:00:00.000Z app; row 2026-08-30T06:00:00.000Z app; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" bash "$SUT" >/dev/null 2>&1
if [ "$(count_for 2026-08-29 "$O")" = "2" ]; then
    ok "C2b 件数が 2→1 に減って見えても 2 のまま(日ごとの max)"
else ng "C2b 減って見えた時" "8/29 = $(count_for 2026-08-29 "$O")"; fi

# ── C3 変異対照(2つ・機構ごとに1本ずつ)───────────────────────────────────
# ★1本にまとめると、片方の機構が死んでいても緑が出る。実際 初版は max だけを変異させ、
#   (a) が引き継ぎ節に守られていた為に**赤くならず**、それで取り違えに気付いた。
mutate_and_check() {   # $1=説明 $2=消す綴り $3=場面(a|b)
    local md mut ml mo
    md="$(mktemp -d)"; mut="$md/mut.sh"
    python3 - "$SUT" "$mut" "$2" <<'PY2'
import sys
s = open(sys.argv[1]).read()
target = sys.argv[3]
if target not in s:
    sys.exit(9)
open(sys.argv[2], "w").write(s.replace(target, ''))
PY2
    if [ $? -eq 9 ] || ! bash -n "$mut" 2>/dev/null; then
        ng "C3 $1" "変異の当て先が動いた(対照を直す事)"; /bin/rm -rf "$md"; return
    fi
    ml="$md/m.log"; mo="$md/m.tsv"
    { row 2026-08-29T20:00:00.000Z app; row 2026-08-29T22:00:00.000Z app; } > "$ml"
    RC_CENSUS_LOG="$ml" RC_CENSUS_OUT="$mo" bash "$mut" >/dev/null 2>&1
    if [ "$3" = "a" ]; then { row 2026-08-30T06:00:00.000Z app; } > "$ml"
    else { row 2026-08-29T22:00:00.000Z app; } > "$ml"; fi
    RC_CENSUS_LOG="$ml" RC_CENSUS_OUT="$mo" bash "$mut" >/dev/null 2>&1
    if [ "$(count_for 2026-08-29 "$mo")" = "2" ]; then
        ng "C3 $1" "変異しても 2 のまま = その場面を測れていない"
    else ok "C3 $1(変異で 2 が失われる = 対応する検査は本物)"; fi
    /bin/rm -rf "$md"
}
mutate_and_check "引き継ぎ節を外すと C2a が崩れる" \
    'for (k in old) if (!(k in seen)) printf "%s\t%d\n", k, old[k]' a
mutate_and_check "max を外すと C2b が崩れる" \
    'if ($1 in old && old[$1] > cur) cur = old[$1];' b

# ── C4 同じ日が本当に増えたら伸びる ───────────────────────────────────────
# max が「一度観測した数で固まって動かない」物になっていない事。
{ row 2026-08-30T06:00:00.000Z app; row 2026-08-30T07:00:00.000Z app
  row 2026-08-30T08:00:00.000Z app; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" bash "$SUT" >/dev/null 2>&1
if [ "$(count_for 2026-08-30 "$O")" = "3" ]; then
    ok "C4 同じ日が本当に増えたら伸びる(max が固まらない)"
else ng "C4 増えたら伸びる" "8/30 = $(count_for 2026-08-30 "$O")"; fi

# ── C5 元 log が無ければ測定不成立 ────────────────────────────────────────
RC_CENSUS_LOG="$SB/no-such.log" RC_CENSUS_OUT="$SB/x.tsv" bash "$SUT" >/dev/null 2>&1
[ $? -eq 2 ] && ok "C5 元 log が無ければ rc=2(0 件と読ませない)" \
             || ng "C5 元 log が無い時" "rc=$?"

# ── C6 置き場が上限の外 ───────────────────────────────────────────────────
# ★能力ではなく**既定値**を測る。掃かれる場所に置いたら、この道具は自分の目的を裏切る。
defout="$(grep -m1 'OUT="\${RC_CENSUS_OUT:-' "$SUT" | sed 's/.*RC_CENSUS_OUT:-//; s/}.*//')"
case "$defout" in
    *"Library/Logs/rc-backend"*|*"/.rc-backend/"*)
        ng "C6 置き場が上限の外" "既定が掃かれる dir の中: $defout" ;;
    *) ok "C6 既定の置き場は上限を掛けている dir の外($defout)" ;;
esac

# ── C7 client=apple の様な語に巻き込まれない ──────────────────────────────
L2="$SB/b.log"; O2="$SB/b.tsv"
{ row 2026-08-31T01:00:00.000Z apple; row 2026-08-31T02:00:00.000Z app; } > "$L2"
RC_CENSUS_LOG="$L2" RC_CENSUS_OUT="$O2" bash "$SUT" >/dev/null 2>&1
if [ "$(count_for 2026-08-31 "$O2")" = "1" ]; then
    ok "C7 client=apple を app と数えない(語として当てている)"
else ng "C7 語として当てる" "8/31 = $(count_for 2026-08-31 "$O2")(2 なら前方一致で拾っている)"; fi

echo ""
echo "APP-USAGE-CENSUS-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
