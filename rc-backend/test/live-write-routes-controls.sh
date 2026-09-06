#!/bin/bash
# controls-for: tools/live-write-routes-check.mjs
#
# `live-write-routes-check.mjs` の**判定だけ**を、観測値の全通りで撃つ(姉家族の
# `ios/tools/live-send-check-control.sh` / `rc-backend/test/live-cold-routes-controls.sh` と
# 同じ理由: 判定は 0/1/3 を決める分岐なのに、走らせるのに本物の机と使い捨ての会話が要る)。
#
# ★此の計器は**本番の机に書き込む**ので、判定の穴は残骸に直結する。とくに
#   `torn_down` は「畳めた」を名乗る唯一の欄で、之が甘いと机に使い捨てが積む ——
#   2026-09-04 に実際に 4 本積んだ(しかも `tmux` が PATH に無くて「0 本」と誤報した)。
#
# 測らない物 = ssh / 本物の机 / disposable-session の側。其れは計器を本当に回す時の話。
set -u
TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/live-write-routes-check.mjs"
NODE="$(command -v node || echo /opt/homebrew/bin/node)"
PASS=0; FAIL=0
want() { # want <期待 rc> <題> -- <verdict 引数...>
  local exp="$1" title="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$("$NODE" "$TOOL" --verdict "$@" 2>&1)"; local rc=$?
  if [ "$rc" = "$exp" ]; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$title"
  else FAIL=$((FAIL+1)); printf 'FAIL  %s(期待 rc=%s / 実際 %s)\n' "$title" "$exp" "$rc"; printf '%s\n' "$out" | sed 's/^/     | /'; fi
}
OK="kind=ok title_set=200 title_read=1 title_clear=200 archive_on=200 archive_seen=1 archive_off=200 torn_down=1 limited=not-limited"

want 0 "全部揃えば 0(閉じた)" -- 0 "$OK"

# ★1 欄ずつ落とす。まとめて撃つと「どれか 1 つを見ていれば緑」の判定でも通る。
want 1 "title を付けられない = 1" -- 0 "kind=ok title_set=500 title_read=1 title_clear=200 archive_on=200 archive_seen=1 archive_off=200 torn_down=1 limited=not-limited"
want 1 "付けた title が読み返せない = 1" -- 0 "kind=ok title_set=200 title_read=0 title_clear=200 archive_on=200 archive_seen=1 archive_off=200 torn_down=1 limited=not-limited"
want 1 "title を外せない(元に戻せない)= 1" -- 0 "kind=ok title_set=200 title_read=1 title_clear=500 archive_on=200 archive_seen=1 archive_off=200 torn_down=1 limited=not-limited"
want 1 "archive を立てられない = 1" -- 0 "kind=ok title_set=200 title_read=1 title_clear=200 archive_on=409 archive_seen=1 archive_off=200 torn_down=1 limited=not-limited"
want 1 "立てた archive が一覧に出ない = 1" -- 0 "kind=ok title_set=200 title_read=1 title_clear=200 archive_on=200 archive_seen=0 archive_off=200 torn_down=1 limited=not-limited"
want 1 "archive を下ろせない(元に戻せない)= 1" -- 0 "kind=ok title_set=200 title_read=1 title_clear=200 archive_on=200 archive_seen=1 archive_off=500 torn_down=1 limited=not-limited"

# ★**残骸**。此の 1 件だけは他と重さが違う: 赤を見落とすと机に使い捨てが積む。
want 1 "畳めていなければ 1(机に残したまま緑を名乗らない)" -- 0 "kind=ok title_set=200 title_read=1 title_clear=200 archive_on=200 archive_seen=1 archive_off=200 torn_down=0 limited=not-limited"

# ★届いていない = 測っていない(赤ではない)
want 3 "書き込みの段に届いていない = 3" -- 1 "kind=ng step=write"
# ★上限の机では緑を名乗らない。赤い観測より上限が優先。
want 3 "机が利用上限なら 3" -- 0 "$OK limited=limited"
want 3 "上限は赤より優先" -- 0 "kind=ok title_set=500 title_read=1 title_clear=200 archive_on=200 archive_seen=1 archive_off=200 torn_down=0 limited=limited"
# ★殻が 0 と言っても終了コードが非 0 なら赤
want 1 "終了コードが非 0 なら 1" -- 1 "$OK"
# 知らない引数は usage を出して 2 で止まる
if "$NODE" "$TOOL" --bogus-flag 2>&1 | grep -q 'usage:'; then PASS=$((PASS+1)); echo "PASS  知らない引数は usage で止まる"
else FAIL=$((FAIL+1)); echo "FAIL  知らない引数で usage が出ない"; fi

# ★2026-09-06: 似た欄名で通らない事(`includes("title_read=1")` は `title_read=10` にも当たっていた。completion 計器の対照が捕まえた)。
want 1 "似た欄名(title_read=10)では通らない" -- 0 "kind=ok title_set=200 title_read=10 title_clear=200 archive_on=200 archive_seen=1 archive_off=200 torn_down=1 limited=not-limited"

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED 0 ---"
[ "$FAIL" = 0 ]
