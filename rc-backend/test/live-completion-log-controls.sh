#!/bin/bash
# controls-for: tools/live-completion-check.mjs
#
# `live-completion-check.mjs` の**判定だけ**を、観測値の全通りで撃つ(姉家族の `live-composer-guard-controls.sh`
# と同じ理由: 判定は 0/1/3 を決める分岐なのに、走らせるのに本物の机と使い捨ての会話と数分が要る)。
#
# ★此の計器の本体は 2 欄: `completion_logged=1`(検出器が記録した)と `no_alert=1`(其れが通知に**ならなかった**)。
#   後者が甘いと「記録専用」と名乗る仕掛けが本番で鳴っていても緑と読む —— `digest-notify.sh` が 2026-09-01 に
#   `--dry-run` で実際に起こした事故の形。
#
# 測らない物 = ssh / 本物の机 / 時間。其れは計器を本当に回す時の話。
set -u
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/live-completion-check.mjs"
NODE="$(command -v node || echo /opt/homebrew/bin/node)"
PASS=0; FAIL=0
want() { # want <期待 rc> <題> -- <verdict 引数...>
  local exp="$1" title="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$("$NODE" "$TOOL" --verdict "$@" 2>&1)"; local rc=$?
  if [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$title"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s(期待 rc=%s / 実際 %s)\n' "$title" "$exp" "$rc"; printf '%s\n' "$out" | sed 's/^/     | /'; fi
}
OK="kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=4 no_alert=1 torn_down=1 torn_retry=0 limited=not-limited"

want 0 "全部揃えば 0(閉じた)" -- 0 "$OK"

# ★1 欄ずつ落とす。まとめて撃つと「どれか 1 つを見ていれば緑」の判定でも通る。
want 1 "遷移の前(none)を見ていない = 1" -- 0 "kind=ok activity_seen=0 stopped_seen=1 completion_logged=1 window_min=4 no_alert=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "遷移の後(input)を見ていない = 1" -- 0 "kind=ok activity_seen=1 stopped_seen=0 completion_logged=1 window_min=4 no_alert=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "検出器が記録していない = 1(本体)" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=0 window_min=-1 no_alert=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "窓の長さが 0 = 1" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=0 no_alert=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "窓の長さが無い = 1" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 no_alert=1 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "鳴ってしまった = 1(本体: 記録専用が破れた)" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=4 no_alert=0 torn_down=1 torn_retry=0 limited=not-limited"
want 1 "畳めていない = 1" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=4 no_alert=1 torn_down=0 torn_retry=1 limited=not-limited"
want 0 "撃ち直して畳めた(torn_retry=1)は緑のまま = 0(競りは表に出るが赤ではない)" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=4 no_alert=1 torn_down=1 torn_retry=1 limited=not-limited"
want 1 "殻の rc が非零 = 1" -- 1 "$OK"
want 3 "利用上限の机 = 3(測っていない)" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=4 no_alert=1 torn_down=1 torn_retry=0 limited=limited"
want 3 "机に届かない = 3(測っていない)" -- 1 "kind=ng step=probe"
want 1 "空行 = 1(全欄 NG)" -- 0 ""
want 1 "似た欄名(completion_logged=10)では通らない" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=10 window_min=4 no_alert=1 torn_down=1 torn_retry=0 limited=not-limited"
# ★Codex 2026-09-06 の 5 点(判定を表として読む)
want 3 "kind=ng は step= が無くても『測っていない』(赤い記録を通さない)" -- 0 "kind=ng activity_seen=1 stopped_seen=1 completion_logged=1 window_min=60 no_alert=1 torn_down=1 limited=not-limited"
want 3 "kind=ng が limited より先(準備段の中断を上限の顔にしない)" -- 0 "kind=ng step=send limited=limited"
want 1 "kind=ok を名乗らない行は緑にならない" -- 0 "activity_seen=1 stopped_seen=1 completion_logged=1 window_min=60 no_alert=1 torn_down=1 limited=not-limited"
want 1 "同じ欄が 2 回(矛盾)= 1" -- 0 "kind=ok activity_seen=0 activity_seen=1 stopped_seen=1 completion_logged=1 window_min=60 no_alert=1 torn_down=1 limited=not-limited"
want 1 "window_min が数字でない = 1" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=1-junk no_alert=1 torn_down=1 limited=not-limited"
want 0 "似た鍵(x-limited=limited)は limited と読まない" -- 0 "kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=60 no_alert=1 torn_down=1 x-limited=limited limited=not-limited"
want 3 "活動を一度も観測できなかった殻(kind=ng step=activity)= 3" -- 1 "kind=ng step=activity"

# 知らない引数で usage が出る(姉家族と同じ最後の 1 本)。
if "$NODE" "$TOOL" --bogus 2>&1 | grep -q '^usage:'; then PASS=$((PASS+1)); echo "PASS  知らない引数で usage が出る"
else FAIL=$((FAIL+1)); echo "FAIL  知らない引数で usage が出ない"; fi

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED 0 ---"
[ "$FAIL" = 0 ]
