#!/bin/bash
# controls-for: ios/tools/live-interrupt-check.sh rc-backend/src/view.mjs
#
# 何を守る対照か —— **当たらないプローブは「無い」と報告する**。
#
# `ios/tools/live-interrupt-check.sh` は、サーバの生フィールド `stopped` を読まない。
# 読まないのは正しい(電話も読まないので、読んだら電話が通らない道を検査する事になる)。
# 代わりに `rc-backend/src/view.mjs` の `interruptResult` が四択の各枝で書く**文**を掴む。
#
# その形の弱点はただ1つ: **片側だけ文言が変わった時に黙る**。
#   - `view.mjs` を書き換えると、実機検査は緑の枝を見失って「想定していない文」= 赤。
#     これは気付ける(赤になるので)。
#   - もっと悪いのは**未測定の枝**の文言が変わった場合。`already-done` の文が変われば、
#     実機検査はそれを「想定していない文」= **赤**と読む。仕込みが甘かっただけの走行が、
#     割り込みが壊れている顔で残る —— この repo が繰り返し踏んだ
#     「狭い観測を、それが支えていない結論に貼る」の裏返し。
#
# だから此処で、**2つの file が同じ文を持っている事**だけを機械で確かめる。
# 対照はどちらの写しでもない第三者なので、片側の書き換えは必ず赤になる。
# (3つとも同時に書き換えられたらこの対照は通る。それは「意図してやった」の形なので狙わない。)
#
# 終了コード: 0 = 一致 / 1 = 食い違い / 2 = 測れていない(file が無い等)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT/rc-backend/src/view.mjs"
CHECK="$ROOT/ios/tools/live-interrupt-check.sh"

for f in "$VIEW" "$CHECK"; do
    if [ ! -f "$f" ]; then
        echo "UNMEASURED  読む file が無い: ${f#$ROOT/}"
        exit 2
    fi
done

# 実機検査が掴んでいる4つの針。左から順に、`interruptResult` の四択に対応する。
#   verified / already-done / unverified / null
NEEDLES=(
    "止めました(生成が止まったのを確認)。"
    "押した時には終わっていました"
    "まだ止まっていません"
    "止める対象が見当たりませんでした"
)
NAMES=(verified already-done unverified null)

PASS=0
FAIL=0

chk() { # $1 = 名前, $2 = 針
    local name="$1" needle="$2"
    local in_view in_check
    in_view="$(grep -cF -- "$needle" "$VIEW")"
    in_check="$(grep -cF -- "$needle" "$CHECK")"
    if [ "$in_view" -eq 0 ]; then
        echo "FAIL  [$name] view.mjs に無い(サーバ側の文言が変わった)"
        FAIL=$((FAIL + 1))
        return
    fi
    if [ "$in_view" -gt 1 ]; then
        # 2箇所以上に在ると、実機検査の elif の梯子が**どの枝を指しているか言えなくなる**。
        echo "FAIL  [$name] view.mjs に $in_view 箇所ある(枝を一意に指せない)"
        FAIL=$((FAIL + 1))
        return
    fi
    if [ "$in_check" -eq 0 ]; then
        echo "FAIL  [$name] live-interrupt-check.sh が此の文を掴んでいない"
        FAIL=$((FAIL + 1))
        return
    fi
    echo "PASS  [$name] 両方が同じ文を持っている"
    PASS=$((PASS + 1))
}

echo "== 四択の文言が、サーバと実機検査で一致しているか =="
i=0
while [ "$i" -lt "${#NEEDLES[@]}" ]; do
    chk "${NAMES[$i]}" "${NEEDLES[$i]}"
    i=$((i + 1))
done

echo
echo "== 針どうしが食い合っていないか(梯子の順で誤射しない事) =="
# ★`grep -F` は部分一致なので、ある針が別の針の**部分文字列**だと、梯子の上の枝が
#   下の枝の文まで拾う。四択が四択でなくなる。
a=0
COLLIDE=0
while [ "$a" -lt "${#NEEDLES[@]}" ]; do
    b=0
    while [ "$b" -lt "${#NEEDLES[@]}" ]; do
        if [ "$a" != "$b" ]; then
            case "${NEEDLES[$b]}" in
                *"${NEEDLES[$a]}"*)
                    echo "FAIL  [${NAMES[$a]}] の針が [${NAMES[$b]}] の文にも当たる"
                    COLLIDE=$((COLLIDE + 1))
                    ;;
            esac
        fi
        b=$((b + 1))
    done
    a=$((a + 1))
done
if [ "$COLLIDE" -eq 0 ]; then
    echo "PASS  4本とも他の枝には当たらない"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + COLLIDE))
fi

echo
echo "== 実機検査の判定が、四択を四択として名付けるか =="
# ★実機を1回走らせても **verified の枝しか通らない**。残り3枝は「壊れている」ではなく
#   「測れていない」を名指しする側なので、無検査のまま置くと、仕込みが甘かった走行が
#   割り込みの故障の顔で残る。`--classify` は通信も build もしない判定だけの口。
cls() { # $1 = 期待, $2 = 食わせる文
    local want="$1" got
    got="$(bash "$CHECK" --classify "$2" 2>/dev/null)"
    if [ "$got" = "$want" ]; then
        echo "PASS  [$want] と名付けた"
        PASS=$((PASS + 1))
    else
        echo "FAIL  [$want] のはずが [$got] になった"
        FAIL=$((FAIL + 1))
    fi
}
cls verified      "outcome=display kind=ok tone=ok
text=${NEEDLES[0]}"
cls already-done  "outcome=display kind=ok tone=ok
text=押した時には終わっていました(止めるものは残っていません)。"
cls unverified    "outcome=display kind=warn tone=warn
text=Escape は押しましたが、まだ止まっていません。画面を見て確かめてください。"
cls not-in-flight "outcome=display kind=warn tone=warn
text=止める対象が見当たりませんでした(Escape は押しました)。"
# ★陰性対照。四択のどれにも当たらない文が **unknown** に落ちる事(= 判定が
#   「何でも verified にする」形になっていない事)。
cls unknown       "outcome=display kind=ok tone=ok
text=止めました(Escape)。"

echo
echo "== 陰性対照: 在りもしない文が「在る」と出ないか =="
# ★上の PASS が「grep がいつでも当たる」の意味ではない事を、同じ口で確かめる。
DECOY="止めました(この文はどの file にも書かれていない筈の対照)。"
if grep -qF -- "$DECOY" "$VIEW" || grep -qF -- "$DECOY" "$CHECK"; then
    echo "FAIL  陰性対照が当たった(この探し方は測定になっていない)"
    FAIL=$((FAIL + 1))
else
    echo "PASS  陰性対照は 0 件"
    PASS=$((PASS + 1))
fi

echo
echo "== PASS $PASS / FAIL $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
