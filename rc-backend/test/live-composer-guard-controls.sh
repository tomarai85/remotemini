#!/bin/bash
# controls-for: tools/live-composer-guard-check.mjs
#
# `live-composer-guard-check.mjs` の**判定だけ**を、観測値の全通りで撃つ(姉家族の
# `live-cold-routes-controls.sh` / `live-write-routes-controls.sh` と同じ理由: 判定は
# 0/1/3 を決める分岐なのに、走らせるのに本物の机と使い捨ての会話が要る)。
#
# ★此の計器は**本番の机の入力欄に打鍵する**ので、判定の穴は残骸と誤った安心に直結する。
#   とくに `refused=409` と `reason=composer-busy` は「合成された命令を作らない」という
#   2026-09-04 の Critical の直りを名乗る唯一の欄で、之が甘いと**直っていない机を緑と読む**。
#
# 測らない物 = ssh / 本物の机 / tmux の側。其れは計器を本当に回す時の話。
set -u
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/live-composer-guard-check.mjs"
NODE="$(command -v node || echo /opt/homebrew/bin/node)"
PASS=0; FAIL=0
want() { # want <期待 rc> <題> -- <verdict 引数...>
  local exp="$1" title="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$("$NODE" "$TOOL" --verdict "$@" 2>&1)"; local rc=$?
  if [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$title"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s(期待 rc=%s / 実際 %s)\n' "$title" "$exp" "$rc"; printf '%s\n' "$out" | sed 's/^/     | /'; fi
}
OK="kind=ok refused=409 reason=composer-busy message=1 draft_kept=1 after_clear=202 torn_down=1 limited=not-limited"

want 0 "全部揃えば 0(閉じた)" -- 0 "$OK"

# ★1 欄ずつ落とす。まとめて撃つと「どれか 1 つを見ていれば緑」の判定でも通る。
# ★之が此の計器の本体。202 = 合成された命令が通った = 直っていない机。
want 1 "断らずに送れてしまう(202)= 1" -- 0 "kind=ok refused=202 reason=composer-busy message=1 draft_kept=1 after_clear=202 torn_down=1 limited=not-limited"
want 1 "断りの理由が違う = 1" -- 0 "kind=ok refused=409 reason=pane-busy message=1 draft_kept=1 after_clear=202 torn_down=1 limited=not-limited"
want 1 "断りに文が無い = 1(電話には直し方の書いていない壁が出る)" -- 0 "kind=ok refused=409 reason=composer-busy message=0 draft_kept=1 after_clear=202 torn_down=1 limited=not-limited"
want 1 "断った時に下書きを消していた = 1(人の文を黙って捨てない)" -- 0 "kind=ok refused=409 reason=composer-busy message=1 draft_kept=0 after_clear=202 torn_down=1 limited=not-limited"
want 1 "消した後も送れない = 1(断りが行き止まりになっている)" -- 0 "kind=ok refused=409 reason=composer-busy message=1 draft_kept=1 after_clear=409 torn_down=1 limited=not-limited"

# ★残骸。赤を見落とすと机に使い捨てが積む(2026-09-04 に実際に 4 本積んだ)。
want 1 "畳めていなければ 1(机に残したまま緑を名乗らない)" -- 0 "kind=ok refused=409 reason=composer-busy message=1 draft_kept=1 after_clear=202 torn_down=0 limited=not-limited"

# ★届いていない = 測っていない(赤ではない)
want 3 "撃つ段に届いていない = 3" -- 1 "kind=ng step=probe"
# ★上限の机では緑を名乗らない。赤い観測より上限が優先。
want 3 "机が利用上限なら 3" -- 0 "$OK limited=limited"
want 3 "上限は赤より優先" -- 0 "kind=ok refused=202 reason=composer-busy message=1 draft_kept=1 after_clear=202 torn_down=0 limited=limited"
# ★殻が 0 と言っても終了コードが非 0 なら赤
want 1 "終了コードが非 0 なら 1" -- 1 "$OK"
# 知らない引数は usage を出して 2 で止まる
if "$NODE" "$TOOL" --bogus-flag 2>&1 | grep -q 'usage:'; then PASS=$((PASS+1)); echo "PASS  知らない引数は usage で止まる"
else FAIL=$((FAIL+1)); echo "FAIL  知らない引数で usage が出ない"; fi

# ★2026-09-06: 似た欄名で通らない事(`includes("message=1")` は `message=10` にも当たっていた。家族の completion 計器の対照が捕まえた)。
want 1 "似た欄名(message=10)では通らない" -- 0 "kind=ok refused=409 reason=composer-busy message=10 draft_kept=1 after_clear=202 torn_down=1 limited=not-limited"

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED 0 ---"
[ "$FAIL" = 0 ]
