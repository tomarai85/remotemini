#!/bin/bash
# mutation-timeout-controls.sh — 変異の脚が**時間切れ**になった時の処分の対照。
#
# 何を守っているか(2026-08-04):
#   `test/mutation-controls.py` は脚が 600 秒を超えたら **die** して走行ごと止めていた。
#   理由(時間切れを「検出」に丸めるのは成績の水増し)は正しかったが、結論が行き過ぎ:
#   **変異1件の測定失敗で 157 件の走行が全部落ちる**。実際に M111 で起きた。
#   M111 は「上限超えを断る」を「古い待ちを外す」へ変える変異で、外された待ちの約束が
#   永久に未解決になる = e2e の HTTP 要求が永遠に返らない。つまり**撃っている欠陥の
#   症状そのもの**として脚が固まる。台本ごと止まるなら、固まる系の欠陥を撃つ変異は
#   1つも置けなくなる。
#
#   分けたのは**処分**であって閾値ではない(600 は 1 つのまま):
#     対照の脚(無変異 / 故意に壊した木)で時間切れ → die
#     変異の脚で時間切れ                          → その脚は **未測定**。走行は続ける
#
# ★この対照が撃つ嘘は3方向:
#     (a) 未測定を **緑(素通り)** に丸める  → 在りもしない検査の穴を報告する
#     (b) 未測定を **赤(検出)** に丸める    → 守れていない物を守れたと報告する(水増し)
#     (c) 判定表だけ正しくて **配線が die のまま** → 表は満点、走行は今まで通り全滅
#   (c) が本命。この file の作法「判定を対照側に書き写さない」の、もう一段外側 ——
#   判定に**辿り着く事**まで本物で測る。だから §2 は `run_child` を現物で回す。
#
# 使い方: bash test/mutation-timeout-controls.sh
# 終了コード: 0 = 全ケース期待通り / 1 = どれかが外れた
set -u

cd "$(dirname "$0")/.." || exit 1
ng=0

judge() {  # judge <ケース名> <期待> <実際>
  if [ "$2" = "$3" ]; then
    printf '  %-52s 期待=%-22s OK\n' "$1" "$2"
  else
    printf '  %-52s 期待=%-22s 実際=%-22s ★外れ\n' "$1" "$2" "$3"
    ng=$((ng + 1))
  fi
}

V() {  # V <u> <e> [why] -> 判定文字列。**本体の verdict_of** に答えさせる
  python3 test/mutation-controls.py --verdict "$@"
}

echo "=== §1 判定表: 赤 > 未測定 > 緑 の順序(本体の verdict_of を直に叩く)==="
# 脚が1本でも赤なら検出。他方が固まっていても「捕まえた」は動かない。
judge "unit赤 e2e赤   -> 検出"            "検出"              "$(V t t)"
judge "unit赤 e2e緑   -> 検出"            "検出"              "$(V t f)"
judge "unit赤 e2e未測 -> 検出"            "検出"              "$(V t u)"
judge "unit緑 e2e赤   -> 検出"            "検出"              "$(V f t)"
judge "unit未測 e2e赤 -> 検出"            "検出"              "$(V u t)"
# 赤が無く未測定が在る = 素通り(検査の穴)と区別が付いていない。どちらにも倒さない。
judge "unit緑 e2e未測 -> 未測定"          "★未測定(時間切れ)" "$(V f u)"
judge "unit未測 e2e緑 -> 未測定"          "★未測定(時間切れ)" "$(V u f)"
judge "両方未測定     -> 未測定"          "★未測定(時間切れ)" "$(V u u)"
# 全部緑で初めて素通り。ここが (a) の的 —— 未測定がここへ落ちたら嘘の穴を報告する。
judge "両方緑         -> 素通り"          "★素通り"           "$(V f f)"
# 注記(= 測った上で到達しないと分かっている変異)との掛け算。
judge "注記つき+赤    -> 注記を外せる"    "★注記を外せる"     "$(V t t 到達しない)"
judge "注記つき+緑    -> 未到達(注記)"    "未到達(注記)"      "$(V f f 到達しない)"
judge "注記つき+未測定-> 未測定"          "★未測定(時間切れ)" "$(V f u 到達しない)"

echo
echo "=== §2 配線: 判定表が正しくても、脚が verdict_of へ**辿り着く**とは限らない ==="
# 偽の脚(`sleep`)を本物の `run_child` に食わせる。検査一式は回さないので数秒。
S() { python3 test/mutation-controls.py --selftest-timeout "$@" 2>/dev/null; }

out=$(S soft 2 hang)
judge "変異の脚(soft)が固まった -> 未測定を返す" "未測定 timed_out=1" "$out"
# ★陰性対照。これが無いと「常に未測定と言う口」でも §2 の1行目は緑になる。
out=$(S soft 2 fast)
judge "変異の脚(soft)が普通に終わった -> 測れた" "測れた rc=0 timed_out=0" "$out"
# 対照の脚は今まで通り止まる。ここが緩むと「台本が赤を見分けられる証明」が消える。
S fatal 2 hang >/dev/null 2>&1; rc=$?
judge "対照の脚(fatal)が固まった -> 台本を止める" "止まる" "$([ $rc -ne 0 ] && echo 止まる || echo 止まらない)"
out=$(S fatal 2 fast)
judge "対照の脚(fatal)が普通に終わった -> 通す" "測れた rc=0 timed_out=0" "$out"

echo
echo "=== §3 呼び出し側: soft は変異の脚**だけ**。対照2枚は fatal のまま ==="
# 文字列で見る対照なので弱い。だが (c) の再発は「呼び出し側を1行変える」で起きるので、
# ここは行を数える方が直接的。注釈行は `suites(dst` を含まないので当たらない
# (= **緑になり得る**検査。緑になれない検査は誰も見なくなる。今日その形を1つ潰した)。
n_fatal=$(grep -c '^[^#]*suites(dst)' test/mutation-controls.py)
n_soft=$(grep -c '^[^#]*suites(dst, timeout_fatal=False)' test/mutation-controls.py)
judge "対照の呼び出し(既定=fatal)が 2 箇所" "2" "$n_fatal"
judge "変異の呼び出し(soft)が 1 箇所"       "1" "$n_soft"

echo
echo "=== §4 終了コード: 未測定を 0 に丸めない ==="
# 走行本体は回さない(数時間かかる)。丸めの規則そのものを最終行から読む。
tail_rule=$(grep -c 'sys.exit(1 if missed else (2 if unmeasured else 0))' test/mutation-controls.py)
judge "素通り=1 / 未測定=2 / 全部測れて穴なし=0" "1" "$tail_rule"

echo
if [ $ng -eq 0 ]; then
  echo "全ケース OK(固まった脚は緑にも赤にも丸まらず、走行は1件だけ落として続く)"
  exit 0
fi
echo "★${ng} 件外れた。変異の走行が返す「素通り 0 件」は当てにできない"
exit 1
