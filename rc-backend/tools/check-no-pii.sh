#!/bin/bash
# 実機の capture-pane を fixture にした代償として、画面の隅に出ている Tom のアカウント名
# (メールアドレス)がそのまま入っている。local only の repo に置く分には開示ではないが、
# remote を付けた瞬間に開示になる。**その瞬間に落ちる**ように push の直前で見る。
#
# 使い方: そのまま実行(exit 1 = PII が残ったまま remote に出そうとしている)。
#   git 側への取り付け: .git/hooks/pre-push から呼ぶ(取り付け済み。hooks は追跡されないので
#   clone し直した時はこの行を自分で入れ直す事)。
set -u
cd "$(dirname "$0")/.." || exit 2

PAT='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# 伏字として使う宛先だけを除外する。RFC 2606 / RFC 6761 が**文書用に予約**している名前 =
# 誰の物にもなり得ないので、これが残っていても開示にならない。
# ここを「それらしい偽アドレス」まで広げると検査が意味を失うので、予約名だけに限る。
SAFE='@(example\.(com|net|org)|[A-Za-z0-9.-]+\.(example|invalid|test|localhost))$'

# ファイル単位でなく**一致した文字列単位**で除外する。ファイル単位で外すと、
# 同じファイルに本物と伏字が混ざった時に本物ごと見逃す。
hits=""
while IFS= read -r f; do
  bad=$(grep -ohE "$PAT" "$f" | sort -u | grep -vE "$SAFE")
  [ -n "$bad" ] && hits="${hits}${f}"$'\t'"$(echo "$bad" | tr '\n' ' ')"$'\n'
done < <(grep -rlE "$PAT" test/fixtures 2>/dev/null)

if [ -z "$hits" ]; then
  echo "PII 検査: fixture に個人のメールアドレスなし(伏字 = 文書用予約ドメインのみ)"
  exit 0
fi

echo "PII 検査: **fixture に個人のメールアドレスが残っている**" >&2
printf '%s' "$hits" | while IFS=$'\t' read -r f addrs; do
  echo "  $f: $addrs" >&2
done
cat >&2 <<'MSG'

remote へ出す前に消すか、この repo を local only のままにするか、どちらかを選ぶ事。
消す場合: fixture は「実機の生 capture」である事に価値があるので、行ごと削らず
アドレスだけを同じ桁数の伏字に置換する(桁がずれると罫線・箱の判定が変わる)。
MSG
exit 1
