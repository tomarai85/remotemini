#!/bin/bash
# controls-for: tools/live-subagent-stop-check.mjs
#
# `live-subagent-stop-check.mjs --mode shell` の**判定だけ**を全通りで撃つ(姉家族 = `live-subagent-stop-controls.sh` が twin の形)。
#
# 何を守るか(2026-09-07 の裁定 = shell-row の既定は反転しない、Codex DON'T SHIP):
#   親が背景シェルを持つ横で subagent を止めようとした時、口は `shells-present` で**断り、1 打も打たない**。本番で見る物は
#   「断った」だけでは足りない(Codex 2026-09-07、計器への 6 指摘):
#     sent=0 / pressed_none=1  = 机の鍵列がパネルを開く 3 打以外を含まない(「断った」と「打っていない」は別の主張)
#     shell_row_seen=1         = 机が断りに載せたシェル行に此の run の nonce が在る(TUI が**此の**シェルの行を出していた)
#     agent_running=1 / shell_alive=1 = 何も壊していない
#     retry_http=200 / retry_stopped=observed / target_frozen=1 = **対照**: シェルを殺して撃ち直すと止まる(断りはシェル由来で、
#                                助言「Wait for the shell to finish … then try again」が本当)
#   ★逆に `stop_http=200` が出たら**裁定が配備されていない**(古い机)か、パネルがシェル行を見せなかった = 赤。
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
# 1 欄だけ差し替えた行を作る(全通りを手で書くと写し間違いが対照を腐らせる)
OK="kind=ok mode=shell shell_seen=1 one_running=1 stop_http=409 reason=shells-present sent=0 pressed_none=1 shell_row_seen=1 agent_running=1 shell_alive=1 retry_http=200 retry_stopped=observed target_frozen=1 torn_down=1 torn_retry=0 limited=not-limited"
with() { echo "$OK" | sed -E "s/(^| )$1=[^ ]*/\1$1=$2/"; }

want 0 "全欄が揃って 0(断りが本物で、何も壊さず、シェルを消せば止まる)" -- 0 "$OK"
# ★1 欄ずつ落とす。まとめて撃つと「どれか 1 つを見ていれば緑」の判定でも通る。
want 1 "背景シェルが見えない = 1(此の形を測っていない)" -- 0 "$(with shell_seen 0)"
want 1 "agent が走っていない = 1" -- 0 "$(with one_running 0)"
want 1 "口が 200 で通した = 1(裁定が配備されていない / シェル行が見えていない)" -- 0 "$(with stop_http 200 | sed -E 's/reason=shells-present/reason=none/; s/sent=0/sent=1/')"
want 1 "409 でも別の語(ambiguous)= 1(断った理由が裁定の物ではない)" -- 0 "$(with reason ambiguous)"
want 1 "旧い語 shell-row では通らない(閉じた語は 1 つ)" -- 0 "$(with reason shell-row)"
want 1 "断ったのに x を打っている(sent=1)= 1(本体)" -- 0 "$(with sent 1)"
want 1 "鍵列に余計な打鍵(pressed_none=0)= 1(「断った」≠「打っていない」)" -- 0 "$(with pressed_none 0)"
want 1 "机の断りに此のシェルの行が無い(shell_row_seen=0)= 1(別のシェル / 見えていない)" -- 0 "$(with shell_row_seen 0)"
want 1 "agent の転写が凍った = 1(何かが agent を止めた)" -- 0 "$(with agent_running 0)"
want 1 "シェルが死んだ = 1(裁定が守ろうとした物そのもの)" -- 0 "$(with shell_alive 0)"
want 1 "対照: シェルを消しても 409 のまま = 1(断りがシェル由来でない / 助言が嘘)" -- 0 "$(with retry_http 409 | sed -E 's/retry_stopped=observed/retry_stopped=false/')"
want 1 "対照: 撃ち直しは 200 だが観測できていない = 1" -- 0 "$(with retry_stopped false)"
want 1 "対照: 撃ち直した後も目標が凍らない = 1(x が効いていない)" -- 0 "$(with target_frozen 0)"
want 1 "畳めていない = 1" -- 0 "$(with torn_down 0 | sed -E 's/torn_retry=0/torn_retry=1/')"
want 0 "撃ち直して畳めた(torn_retry=1)は緑のまま = 0" -- 0 "$(with torn_retry 1)"
want 1 "殻の rc が非零 = 1" -- 1 "$OK"
want 3 "利用上限の机 = 3" -- 0 "$(with limited limited)"
want 3 "上限を訊けなかった机(limited=unknown)も 3" -- 0 "$(with limited unknown)"
want 3 "シェルが起きなかった殻(kind=ng step=shell)= 3(測っていない)" -- 1 "kind=ng mode=shell step=shell"
want 3 "机に届かない = 3" -- 1 "kind=ng mode=shell step=probe"
want 1 "mode を名乗らない行は twin として読まれ、shell の欄では緑にならない" -- 0 "$(echo "$OK" | sed -E 's/ mode=shell//')"
want 1 "知らない mode は 1" -- 0 "$(with mode shells)"
want 1 "似た値(reason=shells-present-ish)では通らない" -- 0 "$(with reason shells-present-ish)"
want 1 "似た値(retry_stopped=observed-ish)では通らない" -- 0 "$(with retry_stopped observed-ish)"
want 1 "同じ欄が 2 回(矛盾)= 1" -- 0 "$OK sent=1"
want 1 "空行 = 1" -- 0 ""
# ★対照の対照: `with` が本当に 1 欄だけ変えている(sed が空振りすると上の全部が「同じ行」を撃つ)
if [ "$(with sent 1 | tr ' ' '\n' | grep -c '^sent=1$')" = 1 ] && [ "$(with sent 1 | tr ' ' '\n' | grep -c '^sent=0$')" = 0 ]; then PASS=$((PASS+1)); echo "PASS  with() は 1 欄だけ差し替える"
else FAIL=$((FAIL+1)); echo "FAIL  with() が欄を差し替えていない: $(with sent 1)"; fi

if "$NODE" "$TOOL" --mode shells --verdict 0 "$OK" 2>&1 | grep -q '^usage:'; then PASS=$((PASS+1)); echo "PASS  知らない --mode で usage が出る"
else FAIL=$((FAIL+1)); echo "FAIL  知らない --mode で usage が出ない"; fi

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED 0 ---"
[ "$FAIL" = 0 ]
