#!/bin/bash
# 手元で回す**対照**を全部まとめて回す。
#
# なぜ要るか(2026-08-02): 対照が6本在るのに、それを**まとめて回す物が無かった**。
#   実測した参照元:
#     env-death-controls.sh      → tools/verify-on-edith.sh が呼ぶ(edith 上)
#     phone-window-controls.sh   → 同上
#     pii-controls.sh            → 書類に名前が在るだけ
#     verify-script-controls.sh  → 書類に名前が在るだけ
#     mutation-target-controls.sh→ 書類に名前が在るだけ(pre-commit が回すのは**検査**であって対照ではない)
#     mutation-run-live-controls.sh → **参照 0 件**
#   対照は「検査が壊れていないか」を見る物なので、**誰も回さない対照は対照ではない**。
#   検査そのものが常に緑を返す病気(DESIGN §2.18-10)を見つける唯一の目がこれなので、
#   置き場所を1つに決めて、書類からはここを指す。
#
# edith 上でしか意味が無い2本(実 tmux / 実 launchd 相当)は既定では回さない。
#   `--all` を付けると回す(edith 上での `verify-on-edith.sh` 経由が本来の道)。
#
# 終了コードの扱い: 0=緑 / 1=赤 / **2=測っていない**(変異の走行中など)。
#   2 を緑に丸めない —— 「測れなかった」を「異常なし」と読み替えるのが一番危ない。
#
# ══ ★対照を**新しく書く**時に必ず読む2行(ここに置く理由 = 判断する場所に置かないと効かない)══
#   (1) **入力は本物の生成元から取る。** 手で書いた入力を食わせた対照は、
#       「入力の形についての自分の思い込み」を検証できない —— 思い込みごと緑になる。
#   (2) **直したら、直す前の版で対照が赤になるか個別に見る。** 赤にならない対照は
#       その欠陥について何も測っていない。「守りが緑」と「守りが効く」は別。
#   経緯: (1) は env-death の対照で一度学んだのに、8/02 に `deploy-dirt-controls.sh` で
#   **同じ形で再発**した(手書きの porcelain 行を食わせて 13/13 緑 → 実物で偽陰性)。
#   前回の是正が「その対照1本を直す」で終わっていたから、次に対照を書く私は規則を読まずに
#   同じ穴を掘れた。だから規則を**呼び口の頭**に移した。詳細 = DESIGN §2.18-10 (15)(16)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

LOCAL_CTLS=(
    test/mutation-run-live-controls.sh
    test/mutation-target-controls.sh
    test/pii-controls.sh
    test/verify-script-controls.sh
    test/deploy-dirt-controls.sh
    test/child-reaping-controls.sh   # 実際に変異台本を起こして殺す。実測10秒だが e2e の子が
                                     # 上がるまで待つので状況で伸びる(上限90秒で測定不成立)
    test/health-observer-controls.sh # 本物の HTTP サーバを立てて probe を測る。実測3秒
    test/example-artifacts-controls.sh # 見本(plist / conf)が据える前に壊れていないか。実測1秒
    test/gui-run-controls.sh         # edith の launchd の中で走らせる計器が、終了コードを
                                     # ちゃんと持ち帰るか。実測6秒。**網が要る** —— 届かない時は
                                     # 2(未測定)を返す。緑に丸めない事
    test/fork-check-controls.sh      # `--fork-session` を測る台本が、**測れていない時に
                                     # 測れていないと言う**か。偽の claude を7通りに振る舞わせる
                                     # ので上限を1トークンも食わない。実測2秒。網も不要
    test/limit-lifted-controls.sh    # 「上限が明けたか」の門番が両方向に壊れていないか。
                                     # fake HOME なので edith も上限も要らない。実測1秒。
                                     # ★据えた初回に2件捕まえた: haiku を根拠にする誤答と、
                                     # `.js` が repo 内で crash する(= /tmp では動く)拡張子の罠
)
EDITH_CTLS=(
    test/env-death-controls.sh
    test/phone-window-controls.sh
)

list=("${LOCAL_CTLS[@]}")
[ "$ALL" -eq 1 ] && list+=("${EDITH_CTLS[@]}")

green=0; red=0; unmeasured=0
declare -a red_names=() unm_names=()

for c in "${list[@]}"; do
    if [ ! -f "$c" ]; then
        echo "MISSING  $c  ← 書類が指しているのに無い"
        red=$((red+1)); red_names+=("$c(不在)")
        continue
    fi
    t0=$(date +%s)
    out="$(bash "$c" 2>&1)"; rc=$?
    t1=$(date +%s)
    last="$(echo "$out" | tail -1)"
    case "$rc" in
        0) green=$((green+1));      printf 'GREEN  %-34s %3ds  %s\n' "$(basename "$c")" "$((t1-t0))" "$last" ;;
        2) unmeasured=$((unmeasured+1)); unm_names+=("$(basename "$c")")
           printf 'UNMEA  %-34s %3ds  %s\n' "$(basename "$c")" "$((t1-t0))" "$last" ;;
        *) red=$((red+1)); red_names+=("$(basename "$c")")
           printf 'RED    %-34s %3ds  %s\n' "$(basename "$c")" "$((t1-t0))" "$last"
           echo "$out" | sed 's/^/         /' | tail -12 ;;
    esac
done

echo ""
echo "RUN-CONTROLS: green=$green red=$red 未測定=$unmeasured  (対象 ${#list[@]}本$([ "$ALL" -eq 1 ] || echo '、edith専用2本は除外'))"
[ "$red" -gt 0 ] && echo "  赤: ${red_names[*]}"
[ "$unmeasured" -gt 0 ] && echo "  未測定(緑ではない): ${unm_names[*]} ← 条件が揃ってから回し直す事"
exit $(( red > 0 ))
