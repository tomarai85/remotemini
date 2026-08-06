#!/bin/bash
# controls-for: tools/port-coverage-gate.sh
# 「JS から Swift への移植を照合する道具」を**走らせる門**が、それ自身空回りして
# いない事を測る。道具そのものの中身は test/port-coverage-controls.sh が測る。
#
# ── なぜ実物だけでは測れないか ────────────────────────────────────────────
# 実物の木は今この瞬間 **赤 0 / 未測定 0** なので、実物で回すと常に緑になる。
# つまり実物の緑は「効いている」の証拠に**ならない**。赤くなる形は木の中に無いので、
# 走査の出力と終了コードを継ぎ目(SCAN_CMD)から差し替えて作る。
#   ★ただし 9 だけは本物を通す —— 細工だけで固めると、下限(PC_FLOOR)を実測より
#     高く置いてしまった様な「実物でだけ赤い」事故を一つも捕まえられない。
#
# ── 測る9つ ────────────────────────────────────────────────────────────
#   1 赤 0 + 集計在り + 関数 6 個   → exit 0  (= 常に赤い門ではない)
#   2 道具が赤(rc=1)              → exit 1  かつ直し方を2通り出す
#   3 道具が未測定(rc=2)          → exit 2  (= 赤に丸めない)
#   4 集計が読めない                → exit 2  (= 走っていないを緑にしない)
#   5 **集計は在り赤 0、但し関数 0 個** → exit 2  (= この門の主柱)
#   6 関数がちょうど下限            → exit 0  (= 5 の陰性対照。下限に歯が在る)
#   7 緑の一行が関数の数と印の数を名指しする(出口の数字だけで語らない)
#   8 見知らぬ終了コードもそのまま返す(全部 1 に潰さない)
#   9 本物の道具を本物の木で通すと緑(下限を実測より高く置いていない)
#
# ★5 がこの門の存在理由そのもの。判定材料は「道具が 赤 0 と言った」であり、
#   **移植表が空になっても道具は 赤 0 と刷る** —— 表が潰れた時の出力は健全な時と
#   字面がほぼ同じ(赤 0 / 測れなかった関数 0 / exit 0)。照合できた関数を数える事
#   だけが両者を分ける。ここが緑を通す様になったら、この門は
#   **何も見ていない 0 を承認する装置**に変わる。
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 継ぎ目。突然変異で「この対照に歯が在るか」を測る時だけ差し替える。
#   ★差し替え先は **tools/ の中**に置く事。門は BASH_SOURCE から rc-backend を
#     割り出すので、/tmp に写すと木に辿り着けず 9 が別の理由で赤くなる。
GATE="${PORT_COVERAGE_GATE:-$REPO_ROOT/rc-backend/tools/port-coverage-gate.sh}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

T="$(mktemp -d)"
cleanup() {
    [ -n "${T:-}" ] || return 0
    [ -d "$T" ] || return 0
    find "$T" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$T" -type d -depth -print 2>/dev/null | while read -r d; do /bin/rmdir "$d" 2>/dev/null; done
}
trap cleanup EXIT

if [ ! -f "$GATE" ]; then
    echo "FAIL  対象が無い: $GATE"
    echo "--- 合計: PASS 0 / FAIL 1 ---"
    exit 1
fi

# ── 偽の出力(本物の形をそのまま写す)────────────────────────────────────
# 関数の行を n 個ぶん刷ってから集計を付ける。第1引数 = 関数の数、第2 = 赤の件数。
fake() {  # $1=関数の数 $2=赤の件数 $3=出力先
    local n="$1" red="$2" dst="$3" i=1
    : > "$dst"
    while [ "$i" -le "$n" ]; do
        echo "■ fn$i: JS 呼び出し 5 件 / 相異なる第1引数 5 件(リテラル 5 / 照合できない 0)" >> "$dst"
        echo "   リテラルは全部 Swift 側にも在る(5/5)" >> "$dst"
        echo "" >> "$dst"
        i=$((i+1))
    done
    {
        echo "=== 集計 ==="
        echo "  赤(移っていないリテラル入力 + 死んだ受理): $red"
        echo "  照合できなかった入力: 20 件(★緑ではない。数えているだけ)"
        echo "  測れなかった関数: 0"
        echo "  受理した差し替え: 0 / 死んでいる受理: 0"
        echo "  印で外した検査: 2"
    } >> "$dst"
}

fake 6 0 "$T/clean.txt"      # 健全
fake 6 1 "$T/red.txt"        # 移っていないリテラルが1件
fake 0 0 "$T/collapsed.txt"  # ★集計は在るのに何も照合していない
fake 4 0 "$T/atfloor.txt"    # ちょうど下限
# 集計に辿り着く前に死んだ形。**関数の行は下限ぶん残す**のが肝 —— ここを空にすると
# 下限の判定(③)でも exit 2 になり、4 は「集計を見ているから」ではなく
# 「関数が 0 個だから」通ってしまう。実測 2026-08-07: 空の版で作った 4 は
# 集計の判定を丸ごと消す変異体の下でも緑のままだった(= 歯が無かった)。
fake 6 0 "$T/nosummary.txt"
/usr/bin/sed -i '' '/^=== 集計 ===/,$d' "$T/nosummary.txt"
{
  echo "Traceback (most recent call last):"
  echo "  RuntimeError: 集計を刷る前に死んだ"
} >> "$T/nosummary.txt"

run_gate() {  # $1=SCAN_CMD
    SCAN_CMD="$1" bash "$GATE" > "$T/out.log" 2>&1
    echo $?
}

# ── 1: 健全なら通す ───────────────────────────────────────────────────────
rc="$(run_gate "/bin/cat $T/clean.txt")"
if [ "$rc" = "0" ]; then
    ok "1 赤 0 かつ関数が下限以上なら通す(常に赤い門ではない)"
else
    ng "1 赤 0 かつ関数が下限以上なら通す" "exit=$rc / $(tail -3 "$T/out.log" | tr '\n' ' ')"
fi

# ── 2: 道具が赤 → exit 1 かつ直し方を出す ────────────────────────────────
rc="$(run_gate "/bin/cat $T/red.txt; (exit 1)")"
if [ "$rc" = "1" ]; then
    ok "2 道具が赤なら止める(exit 1)"
else
    ng "2 道具が赤なら止める" "exit=$rc(止めていない = 門が無いのと同じ)"
fi
if grep -q "not-a-port" "$T/out.log" 2>/dev/null && grep -q "PORTS" "$T/out.log" 2>/dev/null; then
    ok "2b 直し方を2通りとも出す(移植表に足す / 印を置く)"
else
    ng "2b 直し方を2通りとも出す" "止めたが、どう直せばよいか出ない"
fi

# ── 3: 道具が未測定 → exit 2(赤に丸めない)──────────────────────────────
rc="$(run_gate "/bin/cat $T/clean.txt; (exit 2)")"
if [ "$rc" = "2" ]; then
    ok "3 未測定は未測定のまま返す(2 を 1 にも 0 にも丸めない)"
else
    ng "3 未測定は未測定のまま返す" "exit=$rc(三色の判定が二色に潰れている)"
fi

# ── 4: 集計が読めない → exit 2 ────────────────────────────────────────────
#     「走らなかった」を「異常なし」と読む形。
rc="$(run_gate "/bin/cat $T/nosummary.txt")"
if [ "$rc" = "2" ]; then
    ok "4 集計を読めなければ未測定として止める(exit 2)"
else
    ng "4 集計を読めなければ未測定として止める" "exit=$rc(走っていないのに緑 or 赤と断じている)"
fi

# ── 5: 集計は在り赤 0、但し関数 0 個 → exit 2 ★主柱 ─────────────────────
rc="$(run_gate "/bin/cat $T/collapsed.txt")"
if [ "$rc" = "2" ]; then
    ok "5 ★何も照合していない赤 0 は通さない(潰れた移植表を緑と読まない)"
else
    ng "5 ★何も照合していない赤 0 は通さない" \
       "exit=$rc —— 表が空でも道具は赤 0 と刷るので、これを通すとこの門は無力"
fi

# ── 6: ちょうど下限 → exit 0(5 の陰性対照)──────────────────────────────
#     5 が「関数の行が少しでも減れば赤」だと、下限ではなく実測値の写しになる。
rc="$(run_gate "/bin/cat $T/atfloor.txt")"
if [ "$rc" = "0" ]; then
    ok "6 ちょうど下限なら通す(5 が『減ったら常に赤』ではない)"
else
    ng "6 ちょうど下限なら通す" "exit=$rc(下限が実測値の写しになっている)"
fi

# ── 7: 緑の一行が中身を名指しする ─────────────────────────────────────────
run_gate "/bin/cat $T/clean.txt" > /dev/null
if grep -q "関数 6 個" "$T/out.log" 2>/dev/null && grep -q "印で外した検査 2 件" "$T/out.log" 2>/dev/null; then
    ok "7 緑の一行が関数の数と印の数を名指しする(exit 0 だけで語らない)"
else
    ng "7 緑の一行が関数の数と印の数を名指しする" "出た行: $(tail -1 "$T/out.log")"
fi

# ── 8: 見知らぬ終了コードもそのまま返す ───────────────────────────────────
#     道具が 0/1/2 以外で死んだ時に 1 へ潰すと、赤と事故が見分けられなくなる。
rc="$(run_gate "/bin/cat $T/clean.txt; (exit 7)")"
if [ "$rc" = "7" ]; then
    ok "8 見知らぬ終了コードもそのまま返す(全部 1 に潰さない)"
else
    ng "8 見知らぬ終了コードもそのまま返す" "exit=$rc(道具の死に方が門の出口で消えている)"
fi

# ── 9: 本物の道具 × 本物の木 → 緑 ─────────────────────────────────────────
#     1〜8 は全部細工した出力なので、下限を実測より高く置く事故を捕まえられない。
bash "$GATE" > "$T/real.log" 2>&1
rc=$?
if [ "$rc" = "0" ]; then
    ok "9 本物の道具を本物の木で通すと緑(下限を実測より高く置いていない)"
else
    ng "9 本物の道具を本物の木で通すと緑" "exit=$rc / $(tail -2 "$T/real.log" | tr '\n' ' ')"
fi

cleanup
if [ -d "$T" ]; then
    ng "後始末" "細工した木が残っている: $T"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "PORT-COVERAGE-GATE-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
