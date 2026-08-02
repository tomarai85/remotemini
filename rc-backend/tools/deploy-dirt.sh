#!/bin/bash
# 「配備しようとしている木の汚れは、**実行コード**か、付随物か」を判定する唯一の場所。
#
#   使い方: deploy-dirt.sh <srcdir>
#   stdout = 汚れの一覧(<srcdir> からの相対 path に正規化済み。無ければ空)
#   exit 0 = 綺麗 / 1 = 付随物のみ / 2 = src/ か test/ が汚れている / 3 = git で判らない
#
# なぜ独立した file か(2026-08-02):
#   判定を配備台本の中に直書きしたら、対照が**作り物の文字列**しか食えず、実物の形を
#   一度も通さないまま 13/13 緑になった。そして実物で落ちた。判定を外に出せば、対照は
#   本物の git repo を作って**同じ経路**を通せる。複製された判定は片方だけ腐る。
#
# ★実物で踏んだ穴(偽陰性 = 危険な向き):
#   `git status --porcelain` の path は **repo の root からの相対**であって、
#   `-C <srcdir>` を付けても変わらない。ここは repo root が `mobile-work/` で
#   `rc-backend/` が部分木なので、実際の行はこうなる:
#       ?? rc-backend/test/deploy-dirt-controls.sh
#   `^.. (src|test)/` はこれに当たらない = **test/ が汚れているのに「無傷」と答えた**。
#   → root からの prefix を `rev-parse --show-prefix` で取り、剥がしてから判定する。
#
# ★もう一つ直した事(偽陽性): pathspec `-- .` で <srcdir> の外を見ない。
#   repo root には REQUIREMENTS.md 等、**配備で送らない** file が在る。それが汚れただけで
#   「汚れた木からの配備」と刻むのは嘘に近い(送る物は一切変わっていない)。
set -uo pipefail
SRC="${1:?usage: deploy-dirt.sh <srcdir>}"

git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 3
PREFIX="$(git -C "$SRC" rev-parse --show-prefix 2>/dev/null)" || exit 3

# `-- .` = <srcdir> 配下だけ。path は root 相対で出てくるので prefix を剥がす。
RAW="$(git -C "$SRC" status --porcelain -- . 2>/dev/null)" || exit 3
[ -z "$RAW" ] && exit 0

if [ -n "$PREFIX" ]; then
    # 行頭は「状態2文字 + 空白 + (引用符) + prefix」。引用符は空白入り path の時だけ付く。
    # BSD sed なので `\?` でなく `\{0,1\}` を使う事。
    DIRT="$(printf '%s\n' "$RAW" | sed "s|^\(.. \"\{0,1\}\)${PREFIX}|\1|")"
else
    DIRT="$RAW"
fi

printf '%s\n' "$DIRT"

# ★`"\{0,1\}` が要る: porcelain は空白を含む path を引用符で括る(`?? "src/a b.mjs"`)。
#   括られた瞬間に外れる形にすると、src/ が汚れているのに「無傷」と答える = 偽陰性。
if printf '%s\n' "$DIRT" | grep -qE '^.. "?(src|test)/'; then
    exit 2
fi
exit 1
