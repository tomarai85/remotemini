#!/bin/bash
# controls-for: tools/live-subagent-stop-check.mjs
#
# `live-subagent-stop-check.mjs --mode single` の**判定だけ**を全通りで撃つ(姉家族 = `live-subagent-stop-controls.sh` が twin の形)。
#
# 何を守るか: 走っている subagent が**1 本だけ**の会話で其れを止めると、パネルは節の無い「Background + 脚注」だけの形
#   (driver の `emptyPanel`)になる。twin の実測(2026-09-06 に 2 回 0)は同名 2 本で、止めた後もパネルに行が残る形しか
#   見ていない。此処で見る物 —— `stopped=observed` / `observed_via` がパネル(空パネルを減少と読んだ)か再表示か /
#   目標の転写が凍る / 机の画面が **SENDABLE に戻っている**(パネルが閉じたまま残らない)。
#   ★`screen_after` が overlay-* なら、driver がパネルを閉じ損ねて次の送信を塞ぐ = 赤。
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
OK="kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=not-limited"

want 0 "全欄が揃って 0(空パネルで減少を読んだ)" -- 0 "$OK"
want 0 "再表示で数えた(observed_via=reopened)も 0" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=reopened target_frozen=1 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=not-limited"
# ★1 欄ずつ落とす。
want 1 "1 本が走らなかった = 1" -- 0 "kind=ok mode=single one_running=0 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=not-limited"
want 1 "口が 409 で断った = 1(理由は欄に残る)" -- 0 "kind=ok mode=single one_running=1 stop_http=409 stopped=false reason=unverified observed_via=none target_frozen=0 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=not-limited"
want 1 "観測の道が none = 1(x は押したが減少を読めていない)" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=none target_frozen=1 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=not-limited"
want 1 "目標が凍らない = 1(本体: x が効いていない)" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=0 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=not-limited"
want 1 "画面が overlay のまま = 1(パネルを閉じ損ねた)" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=overlay-PANEL torn_down=1 torn_retry=0 limited=not-limited"
want 1 "画面が UNKNOWN = 1(閉じたと言えない)" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=UNKNOWN torn_down=1 torn_retry=0 limited=not-limited"
want 1 "畳めていない = 1" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=SENDABLE torn_down=0 torn_retry=1 limited=not-limited"
want 0 "撃ち直して畳めた(torn_retry=1)は緑のまま = 0" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=SENDABLE torn_down=1 torn_retry=1 limited=not-limited"
want 1 "殻の rc が非零 = 1" -- 1 "$OK"
want 3 "利用上限の机 = 3" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=limited"
want 3 "上限を訊けなかった机(limited=unknown)も 3" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=unknown"
want 3 "1 本が起きなかった殻(kind=ng step=activity)= 3" -- 1 "kind=ng mode=single step=activity"
want 3 "机に届かない = 3" -- 1 "kind=ng mode=single step=probe"
want 1 "mode を名乗らない行は twin として読まれ、single の欄では緑にならない" -- 0 "kind=ok one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=not-limited"
want 1 "似た値(observed_via=panels)では通らない" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panels target_frozen=1 screen_after=SENDABLE torn_down=1 torn_retry=0 limited=not-limited"
want 1 "似た値(screen_after=SENDABLE-ish)では通らない" -- 0 "kind=ok mode=single one_running=1 stop_http=200 stopped=observed observed_via=panel target_frozen=1 screen_after=SENDABLE-ish torn_down=1 torn_retry=0 limited=not-limited"
want 1 "同じ欄が 2 回(矛盾)= 1" -- 0 "kind=ok mode=single target_frozen=0 target_frozen=1 one_running=1 stop_http=200 stopped=observed observed_via=panel screen_after=SENDABLE torn_down=1 torn_retry=0 limited=not-limited"
want 1 "空行 = 1" -- 0 ""

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED 0 ---"
[ "$FAIL" = 0 ]
