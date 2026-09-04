#!/bin/bash
# controls-for: ios/tools/live-search-check.sh
#
# `live-search-check.sh` の**判定だけ**を、観測値の全通りで撃つ(live-send-check-control.sh と同じ理由:
# 判定は 0 / 1 / 3 を決める分岐なのに、走らせるのに実機と本物の会話が要るせいで一度も走らないまま書かれ得る)。
# 測らない = ssh / 実機 / Swift の側。其れは `live-search-check.sh` を本当に回す時の話。
set -u
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/live-search-check.sh"
PASS=0; FAIL=0; UNMEASURED=0
want() { # want <期待 rc> <題> -- <verdict 引数...>
  local exp="$1" title="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$(bash "$TOOL" --verdict "$@" 2>&1)"; local rc=$?
  if [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$title"
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
if bash "$TOOL" --bogus-flag 2>&1 | grep -q 'usage:'; then PASS=$((PASS+1)); echo "PASS  知らない引数は usage で止まる"
else FAIL=$((FAIL+1)); echo "FAIL  知らない引数で usage が出ない"; fi
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$FAIL" = 0 ]
