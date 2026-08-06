#!/bin/bash
# controls-for: ios/tools/live-interrupt-check.sh
#
# `live-interrupt-check.sh` の**判定2つ**を、観測値の全通りで撃つ。
#   1. 生成中を1度も観測できずに輪が尽きた時(`--busy-verdict`)
#   2. 最後の4つの足(`--verdict`)
#
# なぜ要るか(2026-08-06):
#   本体は edith と実機の会話が要る。しかも1回走らせて通るのは **verified の枝だけ**で、
#   残りの枝(already-done / not-in-flight / 陰性対照が壊れた時 / 上限)は
#   **一度も走った事が無いまま**書かれていた。姉家族の `live-send-check.sh` は同じ日に
#   同じ形で切り出して真理値表を当てたので、こちらだけ無検査で残す理由が無い。
#
#   兄弟の対照との棲み分け: `.harness/live-interrupt-wording-controls.sh` は
#   **文言が2つの file で一致しているか**を見る(view.mjs と実機検査)。此処は
#   **観測値 → 終了コード**を見る。掴む文が正しいかと、掴んだ後にどう裁くかは別の穴。
#
# ★測っている物と、測っていない物を分けて書く:
#   測る   = 観測値 → 終了コードの対応、順序(赤い足は測れていない足より強い)、出力の文言。
#   測らない = ssh / swiftc / 本物のサーバ。其れは本体を実際に回す時の話。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/live-interrupt-check.sh"
[ -f "$TOOL" ] || { echo "対象が無い: $TOOL"; exit 2; }

PASS=0
FAIL=0

# chk <期待する終了コード> <題> <口> <引数...>
chk() {
  local want="$1" title="$2" mouth="$3"; shift 3
  local out code
  out="$(bash "$TOOL" "$mouth" "$@" 2>&1)"
  code=$?
  if [ "$code" = "$want" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %-54s → %s\n' "$title" "$code"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %-54s → %s(期待 %s)\n' "$title" "$code" "$want"
    printf '%s\n' "$out" | /usr/bin/sed 's/^/        /'
  fi
}

# chk_text <yes|no> <綴り> <題> <口> <引数...>
chk_text() {
  local want="$1" pat="$2" title="$3" mouth="$4"; shift 4
  local out; out="$(bash "$TOOL" "$mouth" "$@" 2>&1)"
  local hit=no; printf '%s' "$out" | grep -q -- "$pat" && hit=yes
  if [ "$hit" = "$want" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-54s\n' "$title"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-54s(「%s」が %s)\n' "$title" "$pat" "$hit"
    printf '%s\n' "$out" | /usr/bin/sed 's/^/        /'
  fi
}

echo "=== 1. 輪が尽きた時 —— 上限なら 3(直す物は無い)、それ以外は 2 ==="
chk 3 "上限の告知が出ている"                  --busy-verdict ""          limited
chk 2 "上限は出ていない(仕込みの側の失敗)"  --busy-verdict "not-busy"  not-limited
chk 2 "limited を訊けなかった(上限扱いにしない)" --busy-verdict ""      ""
chk_text yes "利用上限" "3 の回は上限だと名指しする"        --busy-verdict "" limited
chk_text no  "測れていない" "3 の回に「測れていない」と言わない" --busy-verdict "" limited
chk_text yes "測れていない" "2 の回は「測れていない」と言う"  --busy-verdict "" not-limited

echo
echo "=== 2. 最後の判定 —— 全部通った時だけ 0 ==="
chk 0 "4つとも通った"                          --verdict 0 verified clean 401 "" -

echo
echo "=== 3. 運ぶ層・対照の赤は 1 ==="
chk 1 "display が届いていない"                 --verdict 7 verified clean 401 "" -
chk 1 "unverified(止まりを観測できない)"      --verdict 0 unverified clean 401 "" -
chk 1 "想定していない文"                       --verdict 0 unknown clean 401 "" -
chk 1 "陰性対照A —— 止まった後も verified の文" --verdict 0 verified verified-again 401 "" -
chk 1 "陰性対照A —— 何も返っていない"           --verdict 0 verified empty 401 "" -
chk 1 "陰性対照B —— でたらめな鍵が 401 でない"  --verdict 0 verified clean no "" 5

echo
echo "=== 4. 主の足が着地しなかった時 —— 上限なら 3、そうでなければ 2 ==="
chk 2 "already-done(上限は出ていない)"        --verdict 0 already-done clean 401 not-limited -
chk 2 "not-in-flight(上限は出ていない)"       --verdict 0 not-in-flight clean 401 not-limited -
chk 3 "already-done + 上限の告知"               --verdict 0 already-done clean 401 limited -
chk 3 "not-in-flight + 上限の告知"              --verdict 0 not-in-flight clean 401 limited -
chk 2 "already-done + 訊けなかった(上限扱いにしない)" --verdict 0 already-done clean 401 "" -

echo
echo "=== 5. ★順序 —— 赤い足は、着地しなかった足より強い ==="
# 此処の 2 は `rc-backend/tools/exit-codes.mjs` の prepAbort ではない。準備段の中断は
# 本体の 1-4 節がその場で 2 を返して此処へ来ない。此処の 2 は「主の足が着地しなかった」で、
# 陰性対照の2本は**それとは独立に測れている** —— だから其処の赤は本物の欠陥。
# 2 が勝つ形にしたら、陰性対照が壊れた回を「回し直せば直る」と報告する計器になる。
chk 1 "着地しなかった + 陰性対照Bが赤"          --verdict 0 already-done clean no not-limited 5
chk 1 "着地しなかった + display が届いていない" --verdict 7 already-done clean 401 not-limited -
chk 1 "上限 + 陰性対照Bが赤(1 > 3)"           --verdict 0 already-done clean no limited 5

echo
echo "=== 6. 陰性対照: 判定が入力を本当に読んでいるか ==="
BEFORE_FAIL=$FAIL
chk 1 "全部赤にしたら 0 にはならない"           --verdict 9 unknown empty no limited 9
if [ "$FAIL" = "$BEFORE_FAIL" ]; then
  echo "  (入力を読んでいる = 上の PASS 群は測定になっている)"
fi

echo
echo "=== 7. 出力の文言 —— 終了コードだけでは、行が嘘を吐いても捕まらない ==="
# ★姉家族の対照(live-send-check-control.sh)で実測した穴。上限で落ちた足を
#   `ok` と印字する細工でも終了コードは変わらないので、上の節は全部緑を出す。
chk_text yes "測れていない" "着地しなかった足は「測れていない」と言う" --verdict 0 already-done clean 401 not-limited -
chk_text no  "ok  : サーバ側" "着地しなかった足を ok と呼ばない"        --verdict 0 already-done clean 401 not-limited -
# ★2026-08-06、陰性対照⑤が 0 赤で捕まえた穴。上の2本は**足の文**しか見ていないので、
#   行頭の印だけを ok に変える細工(文は「測れていない」のまま)を素通りさせていた。
#   読み手が最初に読むのは行頭の印なので、**印そのもの**を見る1本を足す。
chk_text yes "  --  : " "着地しなかった足は行頭を -- 印で書く"          --verdict 0 already-done clean 401 not-limited -
chk_text no  "  --  : " "通った足に -- 印は出さない(対照)"            --verdict 0 verified clean 401 "" -
chk_text yes "ok  : サーバ側" "本当に通った足は ok と言う(対照)"      --verdict 0 verified clean 401 "" -
chk_text yes "利用上限" "3 の回は上限だと名指しする"                    --verdict 0 already-done clean 401 limited -
chk_text yes "NG  : 陰性対照A" "対照Aが赤い時は NG と言う"              --verdict 0 verified verified-again 401 "" -

echo
echo "LIVE-INTERRUPT-VERDICT-CONTROLS: pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ] || exit 1
exit 0
