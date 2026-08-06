#!/bin/bash
# controls-for: ios/tools/live-send-check.sh
#
# `live-send-check.sh` の**判定だけ**を、観測値の全通りで撃つ。
#
# なぜ要るか(2026-08-06):
#   判定は 0(通った)/ 1(赤い)/ 3(上限で測れていない)を決める分岐なのに、
#   走らせるのに edith と実機の会話が要るせいで**一度も走った事が無い**まま書かれていた。
#   同じ日に `.mjs` 側は `tools/exit-codes.mjs` へ正本を切り出して 8 通りの真理値表を
#   当てた(`rc-backend/test/live-exit-codes.test.mjs`)。shell からは其の正本を import
#   出来ないので、写しの側が黙ってずれる余地が此処にだけ残る —— だから此処で測る。
#
# ★測っている物と、測っていない物を分けて書く:
#   測る   = 観測値 → 終了コードの対応(順序 1 > 3 を含む)、上限の時に赤を出さない事。
#   測らない = ssh / 実機 / Swift の側。其れは `live-send-check.sh` を本当に回す時の話。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/live-send-check.sh"
[ -x "$TOOL" ] || [ -f "$TOOL" ] || { echo "対象が無い: $TOOL"; exit 2; }

PASS=0
FAIL=0

# chk <期待する終了コード> <題> <RC> <MISS> <K1> <K2> <K3> <limited>
chk() {
  local want="$1" title="$2"; shift 2
  local out code
  out="$(bash "$TOOL" --verdict "$@" 2>&1)"
  code=$?
  if [ "$code" = "$want" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %-52s → %s\n' "$title" "$code"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %-52s → %s(期待 %s)\n' "$title" "$code" "$want"
    printf '%s\n' "$out" | /usr/bin/sed 's/^/        /'
  fi
}

echo "=== 1. 上限が出ていない時(limited を訊けた・出ていない)==="
chk 0 "全部 ok"                                 0 0 1 1 1 not-limited
chk 1 "kind が ok でない"                        0 0 0 1 1 not-limited
chk 1 "keepText が false でない"                 0 0 1 0 1 not-limited
chk 1 "本文が転写に居ない"                       0 0 1 1 0 not-limited
chk 1 "display が届いていない"                   7 0 1 1 1 not-limited
chk 1 "陰性対照が 0 件でない(数える口が壊れた)" 0 3 1 1 1 not-limited

echo
echo "=== 2. 上限が出ている時 —— 上限で説明が付く赤は 3(直す物は無い)==="
chk 3 "上限 + kind が ok でない"                 0 0 0 1 1 limited
chk 3 "上限 + 本文が転写に居ない"                0 0 1 1 0 limited
chk 3 "上限 + 上限に依る足が全部赤"              0 0 0 0 0 limited

echo
echo "=== 3. ★順序 1 > 3 —— 上限は「送れない」ではないので、運ぶ層の赤を隠さない ==="
# 此処が 3 になったら、上限の回に**本物の欠陥を見逃す**計器になっている。
chk 1 "上限 + display が届いていない"            7 0 1 1 1 limited
chk 1 "上限 + 陰性対照が壊れている"              0 3 1 1 1 limited
chk 1 "上限 + 運ぶ層も上限に依る足も赤"          7 0 0 0 0 limited

echo
echo "=== 4. 上限が出ていても、全部通ったなら緑(告知は出るが送れる回は実在する)==="
# `classifyScreen` は SENDABLE と limited を同時に立てる(view.mjs の注記)。
# 此処を 3 にすると、成功した回を「測れていない」と言う計器になる。
chk 0 "上限の告知は出ているが 3 つとも通った"    0 0 1 1 1 limited

echo
echo "=== 5. limited を訊けなかった時は、上限扱いにしない(fail-closed)==="
# 空の答え = 訊けなかった。上限だと**決め付けない** —— 決め付けると本物の赤が 3 に化ける。
chk 1 "訊けなかった + kind が ok でない"         0 0 0 1 1 ""
chk 0 "訊けなかった + 全部 ok"                   0 0 1 1 1 ""

echo
echo "=== 6. 陰性対照: 判定が入力を本当に読んでいるか ==="
# 上の緑が「此の口はいつでも 0 と言う」の意味しか持たないなら、全部無意味になる。
BEFORE_FAIL=$FAIL
chk 1 "全部赤にしたら 0 にはならない"             9 9 0 0 0 not-limited
if [ "$FAIL" = "$BEFORE_FAIL" ]; then
  echo "  (入力を読んでいる = 上の PASS 群は測定になっている)"
fi

echo
echo "=== 7. 出力の文言 —— 終了コードだけでは、行が嘘を吐いても捕まらない ==="
# ★此の節は陰性対照で穴が見つかって足した(2026-08-06)。上限の足を `--(測っていない)`
#   ではなく `ok` と印字する細工を入れても、終了コードは 3 のままなので上の 1-6 は全部緑だった。
#   読み手が見るのは行なので、「測っていない足を ok と呼ばない」は**別に測る**必要が在る。
# chk_text <yes|no> <綴り> <題> <RC MISS K1 K2 K3 limited>
chk_text() {
  local want="$1" pat="$2" title="$3"; shift 3
  local out; out="$(bash "$TOOL" --verdict "$@" 2>&1)"
  local hit=no; printf '%s' "$out" | grep -q -- "$pat" && hit=yes
  if [ "$hit" = "$want" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-52s\n' "$title"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-52s(「%s」が %s)\n' "$title" "$pat" "$hit"
    printf '%s\n' "$out" | /usr/bin/sed 's/^/        /'
  fi
}
chk_text yes "測っていない" "上限で落ちた足は「測っていない」と言う"     0 0 0 1 1 limited
chk_text no  "ok  : kind=ok" "上限で落ちた足を ok と呼ばない"            0 0 0 1 1 limited
chk_text yes "ok  : kind=ok" "本当に通った足は ok と言う(対照)"        0 0 1 1 1 limited
chk_text yes "NG  : kind=ok" "上限でない時に落ちた足は NG と言う"       0 0 0 1 1 not-limited
chk_text no  "測っていない" "上限でない回に「測っていない」は出さない"  0 0 0 1 1 not-limited

echo
echo "LIVE-SEND-VERDICT-CONTROLS: pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ] || exit 1
exit 0
