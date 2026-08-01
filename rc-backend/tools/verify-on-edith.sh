#!/bin/bash
# rc-backend の検査一式を edith(実運用機、Node 25)で回す。
#
# 設計上の約束(壊さない事):
#   - edith に**常設物を置かない**。`mktemp -d` の使い捨てコピーで走らせ、最後に消して
#     `ls` で不在を確認する。ここが崩れると「実運用機に検査用のコードが残る」状態になる。
#   - Tom の実 tmux セッション `work` には一切触れない。この台本は tmux を起動しない
#     (単体・e2e・変異はすべて偽 tmux で完結する。実機注入の確認は別の手順)。
#
# 使い方: bash tools/verify-on-edith.sh
# 終了コード: 0 = 単体・e2e・変異すべて緑 / 1 = どれかが落ちた / 2 = 到達不能・転送失敗
set -u
HOST="${RC_EDITH_HOST:-edith@10.0.0.0}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"

say() { printf '\n=== %s\n' "$*"; }

say "1/5 到達確認: $HOST"
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" 'echo ok; node -v; python3 -V' ; then
  echo "edith に到達できない(または鍵が通らない)。ここで止める。" >&2
  exit 2
fi

say "2/5 使い捨ての置き場を作る"
REMOTE_DIR=$(ssh "$HOST" 'mktemp -d /tmp/rc-verify.XXXXXX') || exit 2
if [ -z "$REMOTE_DIR" ]; then echo "mktemp に失敗" >&2; exit 2; fi
echo "$REMOTE_DIR"

cleanup() {
  say "5/5 片付け($REMOTE_DIR を消して不在を確認)"
  ssh "$HOST" "rm -rf '$REMOTE_DIR'; ls -d '$REMOTE_DIR' 2>/dev/null && echo '★残っている' || echo '不在を確認'"
}
trap cleanup EXIT

say "3/5 作業ツリーを転送(.git / node_modules は送らない)"
rsync -a --delete --exclude '.git' --exclude 'node_modules' "$SRC"/ "$HOST:$REMOTE_DIR"/ || exit 2

say "4/5 検査(単体 → e2e → 変異)"
# ★`cmd | tail` は tail の終了コードを返す = 落ちても 0 に化ける。ここは検査台本なので
# その fail-open が一番害が大きい(「緑だった」と報告して実際は赤)。remote 側で
# `pipefail` を立て、各段の終了コードを明示的に足し合わせる。
ssh "$HOST" "cd '$REMOTE_DIR' && set -o pipefail && rc=0
  echo '--- 単体 ---'; npm test 2>&1 | tail -12; rc=\$((rc + \$?))
  echo '--- e2e ---';  node test/e2e-local.mjs 2>&1 | tail -2; rc=\$((rc + \$?))
  # ★変異だけは tail で切らない。切ると対照2枚の行(= この道具が赤を見分けられる証明)と
  # 表の大半が消え、「証拠を出す為の台本が証拠を捨てる」状態になる。8/1 に一度これで
  # edith の対照行を見失った。全文を出す(40行前後)。
  # `-u` を付けるのは、ssh 越し(= tty が無い)だと python の stdout が塊単位になり、15分間
  # 一行も出ずに「止まっているのか進んでいるのか分からない」状態になる為。実際そうなった。
  echo '--- 変異 ---'; python3 -u test/mutation-controls.py 2>&1; rc=\$((rc + \$?))
  echo \"--- 合算 exit=\$rc\"; exit \$rc"
rc=$?

if [ $rc -ne 0 ]; then
  echo "★どれかが落ちた(exit=$rc)。上の出力を読む事。" >&2
fi
exit $rc
