#!/bin/bash
# controls-for: ios/tools/live-search-check.sh
#
# `live-search-check.sh` の**判定だけ**を、観測値の全通りで撃つ(live-send-check-control.sh と同じ理由:
# 判定は 0 / 1 / 3 を決める分岐なのに、走らせるのに実機と本物の会話が要るせいで一度も走らないまま書かれ得る)。
# 測らない = ssh / 実機 / Swift の側。其れは `live-search-check.sh` を本当に回す時の話。
set -u
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/live-search-check.sh"
PASS=0; FAIL=0; UNMEASURED=0

# ★合計行の `UNMEASURED` は**一度も増えない幽霊の欄**だった(2026-09-08)。常に 0 なので、
#   読む側は「測れない物は無かった」と受け取るが、実際には**測れない事が起きても 0 のまま**。
#   欄を消すのではなく、実在する測れなさを拾って欄を生かす。
#
# ★分ける線は「答えが違う」と「そもそも走らなかった」。台本が居ない / 実行できないと
#   `bash` は 127 や 126 を返し、其れは判定の答えではないのに **FAIL** に数えられていた ——
#   赤なので安全側ではあるが、報告は「判定が間違っている」と名乗る。読む側は判定表を
#   疑いに行く事になり、実際の原因(台本が消えた・改名された)へ辿り着けない。
#   姉家族の `ios/tools/inflight-sentence-control.sh` が「検査が一度も走っていない」を
#   「捕まえられなかった」と混ぜないのと同じ線。
#
# ★判定に**期待値を置かない**のが肝心。「この入力なら 0 の筈」と書くと、判定規則が
#   変わった日に此の preflight 自身が嘘をつく(今直している欠陥と同じ形)。
#   代わりに **`live-search-check.sh` が名乗る終了コードの集合**だけを見る:
#   0/1/2/3 なら走った(答えの当否は下の照合が決める)、其れ以外なら走っていない。
CODES="0 1 2 3"
ran() { # $1 = rc -> 走ったなら 0
  case " $CODES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

want() { # want <期待 rc> <題> -- <verdict 引数...>
  local exp="$1" title="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$(bash "$TOOL" --verdict "$@" 2>&1)"; local rc=$?
  if ! ran "$rc"; then
    UNMEASURED=$((UNMEASURED+1))
    printf 'UNMEASURED  %s(rc=%s は判定の答えではない = 台本が走っていない)\n' "$title" "$rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  elif [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$title"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s(期待 rc=%s / 実際 %s)\n' "$title" "$exp" "$rc"; printf '%s\n' "$out" | sed 's/^/     | /'; fi
}
OK="kind=ok matched=3 fromEnd=9 inWindow=1 shortMiss=1 neg=0 query=abc"
want 0 "全部揃えば 0(閉じた)" -- 0 "$OK"
want 1 "窓に anchor が居ない = 1" -- 1 "kind=ng matched=3 fromEnd=9 inWindow=0 shortMiss=1 neg=0 query=abc"
want 1 "1 ずれの対照が落ちる = 1" -- 1 "kind=ng matched=3 fromEnd=9 inWindow=1 shortMiss=0 neg=0 query=abc"
want 1 "陰性対照が 0 件でない = 1" -- 1 "kind=ng matched=3 fromEnd=9 inWindow=1 shortMiss=1 neg=2 query=abc"
want 1 "殻が ok と言っても終了コードが非 0 なら 1" -- 1 "$OK"
want 3 "机に届いていない = 3(測っていない)" -- 1 "kind=ng step=fetch-latest"
want 3 "探索が届いていない = 3" -- 1 "kind=ng step=search"
want 1 "読めない出力 = 1" -- 0 "garbage"
# ★上限は赤を隠さない(GET の門。送る計器の 3 とは違う)/ 上限でも揃っていれば 0
want 1 "上限の日でも赤は 1 のまま(3 に隠れない)" -- 1 "kind=ng matched=3 fromEnd=9 inWindow=0 shortMiss=1 neg=0 query=abc limited=limited"
want 0 "上限の日でも揃っていれば 0" -- 0 "$OK limited=limited"
# 知らない引数は `--verdict` を通さず本体に直接(usage を出して 2 で止まる = 登録 verifier と同じ撃ち方)
# ★此処も `want` と同じ線を引く。台本が居ないと `bash` は 127 を返し、`usage:` は当然出ない ——
#   以前は其れを「usage が出ない」= FAIL と数えていたので、台本を改名しただけで
#   「知らない引数の扱いが壊れた」と報告する事になっていた。
#   ★`$(...)` は末尾の改行を落とすだけで rc は素通しする(`| grep` と違い pipe を挟まない)。
bogus_out="$(bash "$TOOL" --bogus-flag 2>&1)"; bogus_rc=$?
if ! ran "$bogus_rc"; then
  UNMEASURED=$((UNMEASURED+1))
  echo "UNMEASURED  知らない引数の扱い(rc=$bogus_rc は判定の答えではない = 台本が走っていない)"
elif printf '%s' "$bogus_out" | grep -q 'usage:'; then PASS=$((PASS+1)); echo "PASS  知らない引数は usage で止まる"
else FAIL=$((FAIL+1)); echo "FAIL  知らない引数で usage が出ない"; fi
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
# ★測れなかったら緑にしない。欄を生かした以上、終了コードにも載せる ——
#   載せなければ「印字はするが結果を変えない」= 幽霊の欄に戻る。
#   0=全部当たり / 1=判定が違う / 2=測れなかった(姉家族の対照と同じ約束)。
if [ "$FAIL" != 0 ]; then exit 1; fi
if [ "$UNMEASURED" != 0 ]; then exit 2; fi
exit 0
