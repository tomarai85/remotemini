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
    # ★`build=` を含める(2026-08-30)。本番の行は 2852f6c 以降この形。
    #   検体が本番の出さない形だと、対照は「本番に無い形」に対して緑になる。
    printf '[rc-backend] req %s GET /api/sessions route=x client=%s build=- code=200 reason=- ms=1\n' "$1" "$2"
}
count_for() { awk -F'\t' -v d="$1" '$1==d {print $2}' "$2" 2>/dev/null; }

# ── C1 日ごとに数え、tool を混ぜない ──────────────────────────────────────
L="$SB/a.log"; O="$SB/a.tsv"; DOX="$SB/a-detail.tsv"
{ row 2026-08-29T20:00:00.000Z app; row 2026-08-29T21:00:00.000Z tool
  row 2026-08-29T22:00:00.000Z app; row 2026-08-30T05:33:00.000Z app; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" RC_CENSUS_DETAIL_OUT="$DOX" bash "$SUT" >/dev/null 2>&1
if [ "$(count_for 2026-08-29 "$O")" = "2" ] && [ "$(count_for 2026-08-30 "$O")" = "1" ]; then
    ok "C1 日ごとに数え、client=tool を混ぜない"
else ng "C1 日ごとの数" "$(cat "$O" 2>/dev/null | tr '\n' ' ')"; fi

# ── C2 log を切っても前に数えた日が減らない ★中核 ─────────────────────────
# ★**この系の切り方に合わせて測る**(2026-08-30 改訂)。`log-size-cap.sh` は末尾を
#   別 file へ退避してから `: > "$F"` で**空にする**ので、切った後の live log に
#   前の行は1つも残らない。だから世代を跨いだら**足す**のが正しい。
#   ★前提が変わったら此処も変える: もし将来「末尾を残す」回転にすると、残った行は
#     前の世代で既に数えているので、足すと**二重に数える**。
#     其の時は残った分を引く仕組みが要る —— 前提を書いておかないと、
#     回転の実装を変えた人が此処の正しさが崩れた事に気付けない。

# (a) 日が丸ごと消える(上限が古い方を捨て、空から書き直す)
rm -f "$L"; { row 2026-08-30T06:00:00.000Z app; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" RC_CENSUS_DETAIL_OUT="$DOX" bash "$SUT" >/dev/null 2>&1
if [ "$(count_for 2026-08-29 "$O")" = "2" ]; then
    ok "C2a 日が log から消えても 8/29 の 2 件が残る(繰越)"
else ng "C2a 日が消えた後も残る" "8/29 = $(count_for 2026-08-29 "$O")"; fi

# (b) 同じ日が切断を跨いで続く: 前の 2 件 + 新しい 1 件 = 3
#     ★旧実装(max)は 2 のままで、**新しい 1 件を失っていた**。Codex 2026-08-30 の指摘2。
rm -f "$L"; { row 2026-08-29T23:00:00.000Z app; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" RC_CENSUS_DETAIL_OUT="$DOX" bash "$SUT" >/dev/null 2>&1
if [ "$(count_for 2026-08-29 "$O")" = "3" ]; then
    ok "C2b 切断を跨いだ同じ日は**足される**(2 + 1 = 3。max なら 2 で 1 件消えた)"
else ng "C2b 切断を跨いだ加算" "8/29 = $(count_for 2026-08-29 "$O")(3 が期待)"; fi

# ── C3 変異対照(機構ごとに1本ずつ)───────────────────────────────────────
mutate_and_check() {   # $1=説明 $2=置き換える綴り $3=場面(a|b) $4=置換後(既定は空)
    local md mut ml mo rc2
    md="$(mktemp -d)"; mut="$md/mut.sh"
    python3 - "$SUT" "$mut" "$2" "${4:-}" <<'PY2'
import sys
s = open(sys.argv[1]).read()
target, repl = sys.argv[3], (sys.argv[4] if len(sys.argv) > 4 else "")
if target not in s:
    sys.exit(9)
open(sys.argv[2], "w").write(s.replace(target, repl))
PY2
    rc2=$?
    # ★2つの失敗を**別の文言で**言う(2026-08-30、混ぜていて診断に 2 手余計にかかった)。
    #   「当て先が動いた」= 対象の綴りが変わった。「構文にならない」= 変異の作り方が悪い
    #   (例: `if…then` の唯一の行を消すと空ブロックで落ちる)。直す場所が違う。
    if [ "$rc2" -eq 9 ]; then
        ng "C3 $1" "変異の当て先が動いた(対象の綴りを確かめる事)"; /bin/rm -rf "$md"; return
    fi
    if ! bash -n "$mut" 2>/dev/null; then
        ng "C3 $1" "変異が構文にならない(置換後を指定する。空にすると空ブロックが出来る)"
        /bin/rm -rf "$md"; return
    fi
    ml="$md/m.log"; mo="$md/m.tsv"; mdo="$md/m-detail.tsv"
    { row 2026-08-29T20:00:00.000Z app; row 2026-08-29T22:00:00.000Z app; } > "$ml"
    RC_CENSUS_LOG="$ml" RC_CENSUS_OUT="$mo" RC_CENSUS_DETAIL_OUT="$mdo" bash "$mut" >/dev/null 2>&1
    if [ "$3" = "a" ]; then rm -f "$ml"; { row 2026-08-30T06:00:00.000Z app; } > "$ml"
    else rm -f "$ml"; { row 2026-08-29T23:00:00.000Z app; } > "$ml"; fi
    RC_CENSUS_LOG="$ml" RC_CENSUS_OUT="$mo" RC_CENSUS_DETAIL_OUT="$mdo" bash "$mut" >/dev/null 2>&1
    local got; got="$(count_for 2026-08-29 "$mo")"
    local want; [ "$3" = "a" ] && want=2 || want=3
    if [ "$got" = "$want" ]; then
        ng "C3 $1" "変異しても $want のまま = その場面を測れていない"
    else ok "C3 $1(変異で $want が失われる = 対応する検査は本物)"; fi
    /bin/rm -rf "$md"
}
# 繰越の引き継ぎを外す = 消えた日が失われる
mutate_and_check "繰越の引き継ぎを外すと C2a が崩れる" \
    'END { for (k in c) if (!(k in seen)) printf "%s\t%d\n", k, c[k] }' a
# 世代の判定を外す = 切断を跨いだ加算が起きない
# ★置換後に `:` を置く。消すだけだと `if…then` が空になり構文で落ちて、
#   「変異が効いた」と区別が付かない。
mutate_and_check "世代の判定を外すと C2b が崩れる" \
    '    cp -f "$OUT" "$CARRY"' b '    :' 

# ── C4 同じ世代の中で log が伸びたら数も伸びる ────────────────────────────
# ★**自己完結にする**(2026-08-30 改訂)。以前は前の項が積んだ状態の上で数を期待していて、
#   世代つきの和に変えた途端に期待値が history 依存になった —— 前の項を1つ足すたびに
#   此処が壊れる検査は、測っている物より脆い。新しい file で、場面だけを作る。
C4L="$SB/c4.log"; C4O="$SB/c4.tsv"; C4D="$SB/c4-detail.tsv"
{ row 2026-09-02T06:00:00.000Z app; } > "$C4L"
RC_CENSUS_LOG="$C4L" RC_CENSUS_OUT="$C4O" RC_CENSUS_DETAIL_OUT="$C4D" bash "$SUT" >/dev/null 2>&1
# **追記**で伸ばす(inode も大きさも増える = 同じ世代)。切断ではない。
{ row 2026-09-02T07:00:00.000Z app; row 2026-09-02T08:00:00.000Z app; } >> "$C4L"
RC_CENSUS_LOG="$C4L" RC_CENSUS_OUT="$C4O" RC_CENSUS_DETAIL_OUT="$C4D" bash "$SUT" >/dev/null 2>&1
if [ "$(count_for 2026-09-02 "$C4O")" = "3" ]; then
    ok "C4 同じ世代の中で log が伸びれば数も伸びる(3 件。二重には数えない)"
else ng "C4 同じ世代での伸び" "9/02 = $(count_for 2026-09-02 "$C4O")(3 が期待)"; fi

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

# ── C9-C12 時刻 × 版 の副台帳(2026-08-30)────────────────────────────────
# ★H-3 の解除条件は「**起きている時間**に本物の機会が来た時に使うか」。日次の合計だけでは
#   1日 100 件が深夜の常駐なのか昼の実使用なのかを復元できず、条件を評価できない。
# ★測る中心は「副台帳が出来るか」ではなく **日次の形が変わっていないか**。
#   既に積んである履歴を壊す変更なら、後から読めなくなる方が損失が大きい。
D="$(mktemp -d)"; L="$D/x.log"; O="$D/day.tsv"; DO="$D/detail.tsv"
# ★版は `row` の外で足さない(2026-08-30、sed で後から差し込んで効かず C11 が赤くなった)。
#   検体は**作る時に完成させる** —— 後から書き換える形は、書き換えが効いたかを
#   別途確かめないと判らず、検査が自分の検体を信じられなくなる。
rowb() {  # rowb <ISO日時> <client> <build>
    printf '[rc-backend] req %s GET /api/sessions route=x client=%s build=%s code=200 reason=- ms=1\n' "$1" "$2" "$3"
}
{ rowb 2026-08-30T05:33:00.000Z app 99; rowb 2026-08-30T05:40:00.000Z app 99
  rowb 2026-08-30T14:02:00.000Z app 99; rowb 2026-08-30T14:09:00.000Z tool -; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" RC_CENSUS_DETAIL_OUT="$DO" bash "$SUT" >/dev/null 2>&1

# app は 3 件、tool は入らない。
if [ "$(count_for 2026-08-30 "$O")" = "3" ]; then
    ok "C9 日次の合計は形も値も変わらない(app 3 件 / client=tool は入らない)"
else ng "C9 日次の合計" "$(cat "$O" | tr '\n' ' ')"; fi

h05="$(awk -F'\t' '$1=="2026-08-30" && $2=="05" {print $4}' "$DO")"
h14="$(awk -F'\t' '$1=="2026-08-30" && $2=="14" {print $4}' "$DO")"
if [ "$h05" = "2" ] && [ "$h14" = "1" ]; then
    ok "C10 時刻ごとに分かれる(05 時 2 件 / 14 時 1 件)"
else ng "C10 時刻の分解" "05=$h05 14=$h14"; fi

if awk -F'\t' '$3=="99"{f=1} END{exit !f}' "$DO"; then
    ok "C11 版が記録される"
else ng "C11 版の記録" "$(cat "$DO" | tr '\n' ' ')"; fi

# ★`build=` が無い古い行を捨てない。「版が判らない要求が在った」事自体が情報。
{ row 2026-08-31T03:00:00.000Z app; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" RC_CENSUS_DETAIL_OUT="$DO" bash "$SUT" >/dev/null 2>&1
if awk -F'\t' '$1=="2026-08-31" && $3=="-" {f=1} END{exit !f}' "$DO"; then
    ok "C12 build= が無い行はハイフンとして残す(捨てない)"
else ng "C12 版なしの行" "$(grep 2026-08-31 "$DO" | tr '\n' ' ')"; fi

# ★積む事(切られても減らない)は副台帳でも成り立つか。日次と同じ機構に乗っている事の確認。
{ row 2026-08-31T03:00:00.000Z app; } > "$L"
RC_CENSUS_LOG="$L" RC_CENSUS_OUT="$O" RC_CENSUS_DETAIL_OUT="$DO" bash "$SUT" >/dev/null 2>&1
if awk -F'\t' '$1=="2026-08-30" && $2=="05" && $4=="2" {f=1} END{exit !f}' "$DO"; then
    ok "C13 log から消えた時刻の行も副台帳に残る(積む機構に乗っている)"
else ng "C13 副台帳の積み" "$(grep 2026-08-30 "$DO" | tr '\n' ' ')"; fi
/bin/rm -rf "$D"

echo ""
echo "APP-USAGE-CENSUS-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
