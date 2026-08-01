#!/bin/bash
# rc-backend の検査一式を edith(実運用機、Node 25)で回す。
#
# 設計上の約束(壊さない事):
#   - edith に**常設物を置かない**。`mktemp -d` の使い捨てコピーで走らせ、最後に消して
#     `ls` で不在を確認する。ここが崩れると「実運用機に検査用のコードが残る」状態になる。
#   - Tom の実 tmux セッション `work` には一切触れない。この台本は tmux を起動しない
#     (単体・e2e・変異はすべて偽 tmux で完結する。実機注入の確認は別の手順)。
#   - **remote へ渡す台本は引用符付きヒアドキュメント**で書く(理由は下)。
#
# ★remote 台本を二重引用符の中に組み立てない。二重引用符の中身は **送る前に一度
#   こちらの機械の shell に食われる**: バッククォートはローカルでコマンド置換として
#   実行され、`$` も展開される。2026-08-01 の run7 が実際にこれを踏み、
#   `verify-on-edith.sh: line 57: -u: command not found` を出した(説明のつもりで
#   書いた `-u` が Jervis 上で実行され、その行は remote 側では中身が消えていた)。
#   たまたま無害な語だったから何も壊れていないだけで、同じ場所に rm や git を含む
#   説明を書けばそれが走る。**検査台本ほどこの穴は危ない**。
#   ★当初これを「bash は台本をバイト位置で読み進めるので走行中の編集でずれた」と
#     診断してここに書き残したが、**その診断は誤り**だった(再現 = 2行、
#     test/verify-script-controls.sh の C3/C4)。バイト位置の話自体は本当なので
#     `main()` の包みは残すが、根拠は別物として扱う事。
#   引用符付きヒアドキュメント `<<'REMOTE'` は一切展開しない = **書いた通りが edith に届く**。
#   値を渡したい時は `bash -s -- "$値"` の引数として渡し、remote 側は `$1` で受ける。
#   (ヒアドキュメントの中身が字下げされていないのは、終端語を行頭に置く必要がある為)
#
# 使い方: bash tools/verify-on-edith.sh
# 終了コード: 0 = 自己検査・単体・e2e・PII 対照・serve 判定・環境死の関門・変異すべて緑 / 1 = どれかが落ちた / 2 = 到達不能・転送失敗
set -u

main() {
  HOST="${RC_EDITH_HOST:-edith@10.0.0.0}"
  SRC="$(cd "$(dirname "$0")/.." && pwd)"

  say() { printf '\n=== %s\n' "$*"; }

  # ★edith に触る前に、この台本自身を検査する。検査台本が壊れていれば、その先の緑は
  #   全部意味が無い(変異段が最初に無変異=緑/故意破壊=赤を確かめるのと同じ理由)。
  #   `RC_VERIFY_SELFTEST` は対照側が立てる合図。無いと 対照→本体→対照 で無限再帰する。
  if [ -z "${RC_VERIFY_SELFTEST:-}" ]; then
    say "0/5 台本自身の検査(ネットワークには出ない)"
    if ! bash "$SRC/test/verify-script-controls.sh"; then
      echo "この台本自体が対照に落ちた。edith には行かない。" >&2
      exit 1
    fi
  fi

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
    # ★`$REMOTE_DIR` の外に作られる物も見る。変異台本は `mut-*`、PII 対照は `/tmp/pii-ctl.*`、
    #   e2e は `$TMPDIR/rc-e2e-*` を自前で作る(どれも自分で消すが、中断された時に残る)。
    #   「消した」の確認を自分が作った1つの dir だけに限ると、残っている物を見ないまま
    #   「不在を確認」と言う。
    # ★`rc-e2e-*` を足したのは 8/02。**足す前に実機で 364個 65MB 残していた**のに、
    #   この検査は「他の残留物も無し」と言い続けていた(WORKLOG 2026-08-02 02:10)。
    #   = 見ていない物は「無い」と報告される。負の対照(現物を1つ置いて赤が出るか)で確認済み。
    # ★remote 側の1行目 = 削除先のガード。実運用機で `rm -rf` を撃つ台本なので、
    #   渡された宛先が想定の形でなければ**撃たずに落ちる**。対照 C5/C6 がここを現物で通す。
    # ★残留物は**1つずつ**見る。`ls -d A B C` と並べると、edith の login shell が zsh なので
    #   A が一致しないだけで nomatch エラーになり、B と C を**一度も見ずに**
    #   「他の残留物も無し」と出る(run7 の記録に `zsh: no matches found` として残っている)。
    #   `bash -s` にした事で shell は bash に固定されたが、並べる書き方自体を止める。
    ssh "$HOST" bash -s -- "$(printf %q "$REMOTE_DIR")" <<'REMOTE'
case "$1" in */rc-verify.*) : ;; *) echo "★想定外の削除先なので撃たない: $1" >&2; exit 2 ;; esac
rm -rf "$1"
ls -d "$1" 2>/dev/null && echo '★残っている' || echo '不在を確認'
stray=""
for g in /tmp/pii-ctl.* /var/folders/*/*/T/mut-* /tmp/mut-* /var/folders/*/*/T/rc-e2e-* /tmp/rc-e2e-*; do
  [ -e "$g" ] && stray="${stray}${g}
"
done
[ -n "$stray" ] && { echo '★他に残留物がある:'; printf '%s' "$stray"; } || echo '他の残留物も無し'
REMOTE
  }
  trap cleanup EXIT

  say "3/5 作業ツリーを転送(.git / node_modules は送らない)"
  rsync -a --delete --exclude '.git' --exclude 'node_modules' "$SRC"/ "$HOST:$REMOTE_DIR"/ || exit 2

  say "4/5 検査(単体 → e2e → PII 対照 → serve 判定 → 環境死の関門 → 変異)"
  # ★`cmd | tail` は tail の終了コードを返す = 落ちても 0 に化ける。ここは検査台本なので
  # その fail-open が一番害が大きい(「緑だった」と報告して実際は赤)。remote 側で
  # `pipefail` を立て、各段の終了コードを明示的に足し合わせる。
  ssh "$HOST" bash -s -- "$(printf %q "$REMOTE_DIR")" <<'REMOTE'
set -o pipefail
cd "$1" || exit 2
rc=0
echo '--- 単体 ---'; npm test 2>&1 | tail -12; rc=$((rc + $?))
echo '--- e2e ---';  node test/e2e-local.mjs 2>&1 | tail -2; rc=$((rc + $?))
# PII 検査そのものは**ここでは走らせない**。この木は .git を除いて rsync した物なので
# repo ではなく、検査は判定不能(exit 2)になるのが正しい。代わりに**対照**を走らせる:
# 対照は自前で使い捨ての git repo を建てるので、repo の外でも成立し、かつ
# 「その道具が緑にも赤にもなるか」を edith の git / grep で確かめる事になる。
echo '--- PII 対照 ---'; bash test/pii-controls.sh 2>&1 | tail -18; rc=$((rc + $?))
# ★serve 判定は**この機械で**回す意味がある(2026-08-02 追加)。判定するのは
# 「電話から 443 で届くか」で、宛先の実物を持っているのは edith の側。MBP の緑は
# ここの緑ではない、を単体・e2e と同じ理由でここにも当てる。
echo '--- serve 判定 ---'; bash tools/serve-decision-check.sh 2>&1 | tail -14; rc=$((rc + $?))
# ★環境死の関門の対照(2026-08-02 追加)。下の変異段の対照2は「関門が誤って止める」向きなら
# 自分で大声を出すが、「関門が本物の衝突を見逃す」向き(= 偽の検出を素通しする側)は
# 変異段からは一切見えない。そちらを測るのはこの1段だけ。**本物の bind 失敗**で駆動する。
echo '--- 環境死の関門 ---'; bash test/env-death-controls.sh 2>&1 | tail -16; rc=$((rc + $?))
# ★変異だけは tail で切らない。切ると対照2枚の行(= この道具が赤を見分けられる証明)と
# 表の大半が消え、「証拠を出す為の台本が証拠を捨てる」状態になる。8/1 に一度これで
# edith の対照行を見失った。全文を出す(40行前後)。
# `-u` を付けるのは、ssh 越し(= tty が無い)だと python の stdout が塊単位になり、15分間
# 一行も出ずに「止まっているのか進んでいるのか分からない」状態になる為。実際そうなった。
echo '--- 変異 ---'; python3 -u test/mutation-controls.py 2>&1; rc=$((rc + $?))
echo "--- 合算 exit=$rc"; exit $rc
REMOTE
  rc=$?

  if [ $rc -ne 0 ]; then
    echo "★どれかが落ちた(exit=$rc)。上の出力を読む事。" >&2
  fi
  exit $rc
}

main "$@"
