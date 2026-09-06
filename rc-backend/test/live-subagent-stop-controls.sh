#!/bin/bash
# controls-for: tools/live-subagent-stop-check.mjs
#
# `live-subagent-stop-check.mjs` の**判定だけ**を、観測値の全通りで撃つ(姉家族の `live-completion-log-controls.sh` と
# 同じ理由: 判定は 0/1/3 を決める分岐なのに、走らせるのに本物の机と使い捨ての会話と数分が要る)。
#
# ★此の計器の本体は 3 欄: `stopped=observed`(口が x を押して同じ詳細が消えたと言った)/ `target_frozen=1`(止めた方の
#   転写が凍った)/ `peer_running=1`(もう片方は伸び続けた)。後ろ 2 つが甘いと「x を押した」を「止まった」と読む。
#
# 測らない物 = ssh / 本物の机 / 時間。其れは計器を本当に回す時の話。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../tools/live-subagent-stop-check.mjs"
NODE="${NODE:-node}"
PASS=0; FAIL=0
want() { # want <期待 rc> <題> -- <verdict 引数...>
  local exp="$1" title="$2"; shift 3
  local out; out="$("$NODE" "$TOOL" --verdict "$@" 2>&1)"; local rc=$?
  if [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); echo "PASS  $title"
  else FAIL=$((FAIL+1)); echo "FAIL  $title (want $exp got $rc) $out"; fi
}
OK="kind=ok two_running=1 target_chosen=1 stop_http=200 stopped=observed target_frozen=1 peer_running=1 torn_down=1 torn_retry=0 limited=not-limited"

want 0 "全欄が揃って 0" -- 0 "$OK"
# ★1 欄ずつ落とす。まとめて撃つと「どれか 1 つを見ていれば緑」の判定でも通る。
want 1 "同名 2 本が見えない = 1" -- 0 "kind=ok two_running=0 target_chosen=1 stop_http=200 stopped=observed target_frozen=1 peer_running=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "目標を選べない = 1" -- 0 "kind=ok two_running=1 target_chosen=0 stop_http=200 stopped=observed target_frozen=1 peer_running=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "口が 409 で断った = 1(理由は欄に残る)" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=409 stopped=false reason=ambiguous target_frozen=0 peer_running=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "x は押したが観測できない(unverified)= 1" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=409 stopped=false reason=unverified target_frozen=1 peer_running=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "止めた方が凍らない = 1(本体: x が効いていない)" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=200 stopped=observed target_frozen=0 peer_running=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "もう片方が伸びない = 1(本体: 両方止めた / 親ごと止めた)" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=200 stopped=observed target_frozen=1 peer_running=0 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "畳めていない = 1" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=200 stopped=observed target_frozen=1 peer_running=1 torn_down=0 torn_retry=1 limited=not-limited"
want 0 "撃ち直して畳めた(torn_retry=1)は緑のまま = 0" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=200 stopped=observed target_frozen=1 peer_running=1 torn_down=1 torn_retry=1 limited=not-limited"
want 1 "殻の rc が非零 = 1" -- 1 "$OK"
want 3 "利用上限の机 = 3(測っていない)" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=200 stopped=observed target_frozen=1 peer_running=1 torn_down=1 torn_retry=0 limited=limited"
want 3 "机に届かない = 3(測っていない)" -- 1 "kind=ng step=probe"
want 3 "同名 2 本が起きなかった殻(kind=ng step=activity)= 3" -- 1 "kind=ng step=activity"
want 1 "空行 = 1(全欄 NG)" -- 0 ""
want 1 "似た欄名(stop_http=2000)では通らない" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=2000 stopped=observed target_frozen=1 peer_running=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "似た値(stopped=observed-ish)では通らない" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=200 stopped=observed-ish target_frozen=1 peer_running=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "kind=ok を名乗らない行は緑にならない" -- 0 "two_running=1 target_chosen=1 stop_http=200 stopped=observed target_frozen=1 peer_running=1 torn_down=1 limited=not-limited"
want 1 "同じ欄が 2 回(矛盾)= 1" -- 0 "kind=ok target_frozen=0 target_frozen=1 two_running=1 target_chosen=1 stop_http=200 stopped=observed peer_running=1 torn_down=1 limited=not-limited"
want 3 "kind=ng が limited より先(準備段の中断を上限の顔にしない)" -- 0 "kind=ng step=send limited=limited"
want 0 "似た鍵(x-limited=limited)は limited と読まない" -- 0 "kind=ok two_running=1 target_chosen=1 stop_http=200 stopped=observed target_frozen=1 peer_running=1 torn_down=1 torn_retry=0 x-limited=limited limited=not-limited"

if "$NODE" "$TOOL" --bogus 2>&1 | grep -q '^usage:'; then PASS=$((PASS+1)); echo "PASS  知らない引数で usage が出る"
else FAIL=$((FAIL+1)); echo "FAIL  知らない引数で usage が出ない"; fi

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED 0 ---"
[ "$FAIL" = 0 ]
