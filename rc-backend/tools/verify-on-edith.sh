#!/bin/bash
# rc-backend の検査一式を edith(実運用機、Node 25)で回す。
#
# 設計上の約束(壊さない事):
#   - edith に**常設物を置かない**。`mktemp -d` の使い捨てコピーで走らせ、最後に消して
#     `ls` で不在を確認する。ここが崩れると「実運用機に検査用のコードが残る」状態になる。
#   - Tom の実 tmux セッション `work` には一切触れない。この台本は tmux を起動しない
#     (単体・e2e・変異はすべて偽 tmux で完結する。実機注入の確認は別の手順)。
#
# ★中身を `main()` に入れてある理由(飾りではない)。bash は台本を**バイト位置で読み進める**
#   ので、走っている最中に台本を編集すると、以降の実行位置がずれて別の場所を実行する。
#   2026-08-01 に実際に踏んだ: 19分の変異段の最中にこのファイルを編集し、
#   `verify-on-edith.sh: line 42: -u: command not found` が出た(その時の42行目は空行、
#   `set -u` は12行目 = 旧ファイルのバイト位置を読んでいた)。関数にしておけば
#   定義の時点で丸ごと読み込まれるので、途中の編集で壊れない。
#   ただし**壊れないのは本体だけ**で、走行中の編集が良い考えになる訳ではない。
#
# 使い方: bash tools/verify-on-edith.sh
# 終了コード: 0 = 単体・e2e・PII 対照・変異すべて緑 / 1 = どれかが落ちた / 2 = 到達不能・転送失敗
set -u

main() {
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
    # ★`$REMOTE_DIR` の外に作られる物も見る。変異台本は `mut-*`、PII 対照は `/tmp/pii-ctl.*` を
    #   自前で作る(どちらも自分で消すが、中断された時に残る)。「消した」の確認を
    #   自分が作った1つの dir だけに限ると、残っている物を見ないまま「不在を確認」と言う。
    ssh "$HOST" "rm -rf '$REMOTE_DIR'; ls -d '$REMOTE_DIR' 2>/dev/null && echo '★残っている' || echo '不在を確認'
      stray=\$(ls -d /tmp/pii-ctl.* /var/folders/*/*/T/mut-* /tmp/mut-* 2>/dev/null)
      [ -n \"\$stray\" ] && { echo '★他に残留物がある:'; echo \"\$stray\"; } || echo '他の残留物も無し'"
  }
  trap cleanup EXIT

  say "3/5 作業ツリーを転送(.git / node_modules は送らない)"
  rsync -a --delete --exclude '.git' --exclude 'node_modules' "$SRC"/ "$HOST:$REMOTE_DIR"/ || exit 2

  say "4/5 検査(単体 → e2e → PII 対照 → 変異)"
  # ★`cmd | tail` は tail の終了コードを返す = 落ちても 0 に化ける。ここは検査台本なので
  # その fail-open が一番害が大きい(「緑だった」と報告して実際は赤)。remote 側で
  # `pipefail` を立て、各段の終了コードを明示的に足し合わせる。
  ssh "$HOST" "cd '$REMOTE_DIR' && set -o pipefail && rc=0
    echo '--- 単体 ---'; npm test 2>&1 | tail -12; rc=\$((rc + \$?))
    echo '--- e2e ---';  node test/e2e-local.mjs 2>&1 | tail -2; rc=\$((rc + \$?))
    # PII 検査そのものは**ここでは走らせない**。この木は .git を除いて rsync した物なので
    # repo ではなく、検査は判定不能(exit 2)になるのが正しい。代わりに**対照**を走らせる:
    # 対照は自前で使い捨ての git repo を建てるので、repo の外でも成立し、かつ
    # 「その道具が緑にも赤にもなるか」を edith の git / grep で確かめる事になる。
    echo '--- PII 対照 ---'; bash test/pii-controls.sh 2>&1 | tail -18; rc=\$((rc + \$?))
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
}

main "$@"
