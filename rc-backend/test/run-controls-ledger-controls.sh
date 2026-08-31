#!/bin/bash
# controls-for: tools/run-controls.sh
#
# 全掃きが**途中で死んでも判定を失わない**事の対照(台帳 / 再開 / 1本あたりの上限)。
#
# ── なぜ要るか(2026-08-31、実測)────────────────────────────────────────────
# 全掃きは**一度も完走していない**。2.5 時間走って殺され、其の時点までに出ていた判定は
# **全部消えた** —— 走者は結果を画面へ刷るだけで、shell の変数にしか持っていなかった。
# 門は commit が触れた対照しか回さないので、対照どうしの干渉は測れないまま。
# 「もう一度回す」は同じ 2.5 時間を買い直すだけで、途中で止まればまた全部消える。
#
# ★測る中心は「台帳が出来るか」ではない。**次の走行で買い直さずに済むか**と、
#   **固まった1本が掃引ごと道連れにしないか**の2つ。
#
#   R1 1本 終わるごとに台帳へ `<epoch> <名> <rc> <秒>` が積まれる
#   R2 ★`--resume` は**緑と記録された物だけ**を飛ばす(実際に走らせない事を数で見る)
#   R3 ★赤/未測定は `--resume` でも回し直す(「終わった」と「上手くいった」を混ぜない)
#   R4 ★上限を越えた対照は **2(測っていない)**。赤ではない —— 固まった事は
#      「壊れている」の証拠ではないので、緑にも赤にも丸めない
#   R5 ★★上限が**実時間を本当に縛る**。記録だけ 2 で 60 秒待つ形を捕まえる ——
#      実際に其の形を出荷しかけた(`$( )` が孤児のパイプの EOF を待つ罠。
#      同じ物を今朝 `parity-observer.sh` で潰している)
#   R6 未測定が在れば掃引の終了コードは 2(緑に丸めない)
#   R7 一覧を差した時は登録の照合を飛ばす(差した一覧は repo の宣言と一致しなくて当然)
#   R8 ★**既定の台帳の経路**を撃つ —— 差すと `${VAR:-既定}` の既定側を通らないので、
#      既定の式が壊れていても緑になる(実際に `$HERE` と書いて全走行が死んでいた)
#
# 使い方: bash rc-backend/test/run-controls-ledger-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/run-controls.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# 偽の対照3本: 緑 / 赤 / 固まる。緑と赤は走った回数を数えられる様にする。
mk() { printf '%s\n' "$2" > "$SB/$1"; chmod +x "$SB/$1"; }
mk a-controls.sh "$(printf '#!/bin/bash\necho ran >> "%s/a.count"\nexit 0\n' "$SB")"
mk r-controls.sh "$(printf '#!/bin/bash\necho ran >> "%s/r.count"\nexit 1\n' "$SB")"
mk h-controls.sh '#!/bin/bash
sleep 60'
printf '%s\n%s\n%s\n' "$SB/a-controls.sh" "$SB/r-controls.sh" "$SB/h-controls.sh" > "$SB/list"

sweep() {  # sweep [引数...] → rc を印字
    ( cd "$HERE" && RC_CTL_LIST_FILE="$SB/list" RC_CTL_LEDGER="$SB/ledger.tsv" \
        RC_CTL_TIMEOUT_S=5 bash "$SUT" "$@" >"$SB/out.txt" 2>&1; printf '%s' "$?" )
}
count() { [ -f "$SB/$1" ] && wc -l < "$SB/$1" | tr -d ' ' || echo 0; }
row_rc() { /usr/bin/awk -F'\t' -v n="$1" '$2==n{v=$3} END{print v}' "$SB/ledger.tsv" 2>/dev/null; }

# ── 1回目 ────────────────────────────────────────────────────────────────
t0="$(date +%s)"
rc1="$(sweep)"
t1="$(date +%s)"

[ -s "$SB/ledger.tsv" ] && ok "R1 1本 終わるごとに台帳へ積まれる($(wc -l < "$SB/ledger.tsv" | tr -d ' ') 行)" \
                        || ng "R1 台帳" "空 = 途中で死んだら判定が全部消える"

[ "$(row_rc a-controls.sh)" = "0" ] && [ "$(row_rc r-controls.sh)" = "1" ] \
    && ok "R1b 台帳が緑と赤を書き分ける" \
    || ng "R1b 台帳の中身" "緑=[$(row_rc a-controls.sh)] 赤=[$(row_rc r-controls.sh)]"

[ "$(row_rc h-controls.sh)" = "2" ] \
    && ok "R4 ★上限を越えた対照は 2(測っていない)= 赤に丸めない" \
    || ng "R4 上限の値" "実測=[$(row_rc h-controls.sh)](2 が期待)"

# ★R5 が此の対照の中心。記録だけ 2 で 60 秒待つ形を捕まえる。
_elapsed=$((t1 - t0))
if [ "$_elapsed" -lt 30 ]; then
    ok "R5 ★上限が実時間を縛る(掃引 ${_elapsed} 秒 < 30。固まった 1 本に道連れにされない)"
else
    ng "R5 実時間" "${_elapsed} 秒 —— 記録は 2 でも待たされている(孤児のパイプの EOF 待ち)"
fi

[ "$rc1" = "1" ] && ok "R6a 赤が在れば掃引は 1" \
                 || ng "R6a 終了コード" "rc=$rc1(赤が在るので 1 が期待)"

# ── 2回目: --resume ──────────────────────────────────────────────────────
_a_before="$(count a.count)"; _r_before="$(count r.count)"
rc2="$(sweep --resume)"
[ "$(count a.count)" = "$_a_before" ] \
    && ok "R2 ★--resume は緑と記録された物を**走らせない**(実際の回数で見る)" \
    || ng "R2 再開" "緑の対照が再び走った($_a_before → $(count a.count))= 買い直している"
[ "$(count r.count)" -gt "$_r_before" ] \
    && ok "R3 ★赤は --resume でも回し直す(『終わった』と『上手くいった』を混ぜない)" \
    || ng "R3 赤の再走" "赤が飛ばされた = 一度 赤を出した対照が二度と走らない掃引になる"
printf '%s' "$rc2" | grep -qE '^[12]$' && ok "R6b --resume でも三値を保つ(rc=$rc2)" \
                                       || ng "R6b" "rc=$rc2"

# ── R7 一覧を差した時は登録の照合を飛ばす ────────────────────────────────
if grep -q "UNREG" "$SB/out.txt" 2>/dev/null; then
    ng "R7 登録の照合" "差した一覧に対して未登録を叫んでいる = 対照が此の走者を測れない"
else
    ok "R7 一覧を差した時は登録の照合を飛ばす"
fi

# ── R8 ★**既定の台帳の経路**を撃つ(検査は利用者と同じ入口を通る)──────────────
# 上の R1-R7 は全部 `RC_CTL_LEDGER` を差している。差すと `${VAR:-既定}` の既定側が
# 一度も展開されないので、既定の式が壊れていても緑になる —— 実際に其れを出荷しかけた
# (`$HERE` と書き、`set -u` で全走行が起動直後に死んでいた)。
# ★差さずに1回 走らせて、**起動して集計まで到達する**事だけを見る。
( cd "$HERE" && RC_CTL_LIST_FILE="$SB/list" RC_CTL_TIMEOUT_S=5 bash "$SUT" >"$SB/def.txt" 2>&1 )
if grep -q "unbound variable" "$SB/def.txt"; then
    ng "R8 既定の台帳" "起動直後に落ちている: $(grep -m1 'unbound variable' "$SB/def.txt")"
elif grep -qE "RUN-CONTROLS:|合計" "$SB/def.txt"; then
    ok "R8 ★台帳を差さずに走らせても集計まで到達する(既定の式が生きている)"
else
    ng "R8 既定の台帳" "集計行が出ていない: $(tail -1 "$SB/def.txt")"
fi

echo ""
echo "RUN-CONTROLS-LEDGER-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
