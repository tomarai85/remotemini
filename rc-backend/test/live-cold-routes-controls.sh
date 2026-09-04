#!/bin/bash
# controls-for: tools/live-cold-routes-check.mjs
#
# `live-cold-routes-check.mjs` の**判定だけ**を、観測値の全通りで撃つ(姉家族の
# `ios/tools/live-send-check-control.sh` / `ios/tools/live-search-check-control.sh` と同じ理由:
# ★木の名前から書く —— `rc-backend` は単独で写されるので、裸の名前は写しの中で解決できず、
#   変異走行の対照 1 が落ちて以降の変異が全部「検出」に化ける。判定は 0/1/3 を
# 決める分岐なのに、走らせるのに本物の机と会話が要るせいで一度も走らないまま書かれ得る)。
#
# 測らない物 = ssh / 本物の机 / fetch の側。其れは計器を本当に回す時の話。
set -u
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/live-cold-routes-check.mjs"
NODE="$(command -v node || echo /opt/homebrew/bin/node)"
PASS=0; FAIL=0
want() { # want <期待 rc> <題> -- <verdict 引数...>
  local exp="$1" title="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$("$NODE" "$TOOL" --verdict "$@" 2>&1)"; local rc=$?
  if [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$title"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s(期待 rc=%s / 実際 %s)\n' "$title" "$exp" "$rc"; printf '%s\n' "$out" | sed 's/^/     | /'; fi
}
OK="kind=ok status=200 diff=200 paths=200 shape_status=1 shape_diff=1 shape_paths=1 limited=not-limited"

want 0 "全部揃えば 0(閉じた)" -- 0 "$OK"
# ★1 口ずつ落とす。まとめて 1 通りだけ撃つと、判定が「どれか 1 つでも見ていれば緑」でも通る。
want 1 "status が 500 なら 1" -- 0 "kind=ok status=500 diff=200 paths=200 shape_status=1 shape_diff=1 shape_paths=1 limited=not-limited"
want 1 "diff が 404 なら 1" -- 0 "kind=ok status=200 diff=404 paths=200 shape_status=1 shape_diff=1 shape_paths=1 limited=not-limited"
want 1 "paths が 401 なら 1" -- 0 "kind=ok status=200 diff=200 paths=401 shape_status=1 shape_diff=1 shape_paths=1 limited=not-limited"
# ★200 だが中身が噛み合わない。之を見ないと「空の body を返す机」で緑になる。
want 1 "status が 200 でも screen が無ければ 1" -- 0 "kind=ok status=200 diff=200 paths=200 shape_status=0 shape_diff=1 shape_paths=1 limited=not-limited"
want 1 "diff が 200 でも files が無ければ 1" -- 0 "kind=ok status=200 diff=200 paths=200 shape_status=1 shape_diff=0 shape_paths=1 limited=not-limited"
want 1 "paths が 200 でも paths が無ければ 1" -- 0 "kind=ok status=200 diff=200 paths=200 shape_status=1 shape_diff=1 shape_paths=0 limited=not-limited"
# ★届いていない = 測っていない(赤ではない)。3 口それぞれで。
want 3 "status に届いていない = 3" -- 1 "kind=ng step=status"
want 3 "diff に届いていない = 3" -- 1 "kind=ng step=diff"
want 3 "paths に届いていない = 3" -- 1 "kind=ng step=paths"
# ★上限は赤を隠さない…のではなく、此処では「机が普通でない」ので 3。読むだけの口なので
#   上限が赤の原因になる事は無いが、上限の机で測った緑を「閉じた」と言わない。
want 3 "机が利用上限なら 3(緑を名乗らない)" -- 0 "kind=ok status=200 diff=200 paths=200 shape_status=1 shape_diff=1 shape_paths=1 limited=limited"
want 3 "上限は赤より優先(赤い観測でも測っていない扱い)" -- 0 "kind=ok status=500 diff=200 paths=200 shape_status=1 shape_diff=1 shape_paths=1 limited=limited"
# ★殻が 0 と言っても終了コードが非 0 なら赤
want 1 "終了コードが非 0 なら 1" -- 1 "$OK"
# 知らない引数は usage を出して 2 で止まる(登録 verifier と同じ撃ち方)
if "$NODE" "$TOOL" --bogus-flag 2>&1 | grep -q 'usage:'; then PASS=$((PASS+1)); echo "PASS  知らない引数は usage で止まる"
else FAIL=$((FAIL+1)); echo "FAIL  知らない引数で usage が出ない"; fi

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED 0 ---"
[ "$FAIL" = 0 ]
