#!/bin/bash
# `.git/hooks/pre-commit` を入れる(= 追跡側の門を呼ぶ薄い口を書く)。
#
# なぜ要るか(2026-08-05): この repo は commit の門を4つ持っていたが、それを呼ぶ
# `.git/hooks/pre-commit` は **git の管理外**で、この機械にしか存在しなかった。
# clone した先では門が1つも動かない —— 守りが repo に付いてこない。
# 5つ目(vacuous-gate)を足した時に、置き場所ごと直した。
#
# 書くのは**呼ぶだけの5行**。判定も範囲の絞り込みも `tools/pre-commit-gates.sh` に在る
# (追跡される)。hook 側に中身を持たせない限り、clone と手元は同じ物を回す。
#
# 既存の hook の扱い:
#   - 既に同じ物が入っている        → 何もしない(冪等)
#   - 中身が違う                    → **上書きしない**。控えを取って理由つきの強制を要求する
#     (誰かの hook を黙って消すのは、この repo の作法に反する)
# 強制: RC_HOOKS_FORCE="上書きしてよい理由"(10文字以上)。文言は出力に残る。
#
# 終了コード: 0=入っている / 1=入れられない(既存と違う) / 2=測れない(.git が無い等)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BODY="rc-backend/tools/pre-commit-gates.sh"

GITDIR="$(git -C "$ROOT" rev-parse --git-dir 2>/dev/null)" || {
    echo "install-hooks: ★git repo ではない($ROOT)= 入れられない"; exit 2; }
case "$GITDIR" in /*) ;; *) GITDIR="$ROOT/$GITDIR" ;; esac
[ -d "$GITDIR" ] || { echo "install-hooks: ★git dir が無い: $GITDIR"; exit 2; }
[ -f "$ROOT/$BODY" ] || { echo "install-hooks: ★本体が無い: $BODY"; exit 2; }

HOOKS="$GITDIR/hooks"
mkdir -p "$HOOKS" || { echo "install-hooks: ★hooks dir を作れない: $HOOKS"; exit 2; }
TARGET="$HOOKS/pre-commit"

# ★この中身が唯一の写し元。ここ以外に pre-commit の本文を置かない。
read -r -d '' WANT <<HOOK
#!/bin/bash
# 薄い呼び口。**本体は追跡側**: $BODY
# この file は clone に付いてこないので、中身を持たせない(2026-08-05 に移した)。
# 入れ直し = bash rc-backend/tools/install-hooks.sh
exec bash "\$(git rev-parse --show-toplevel)/$BODY"
HOOK

if [ -f "$TARGET" ]; then
    if [ "$(cat "$TARGET")" = "$WANT" ]; then
        chmod +x "$TARGET"
        echo "install-hooks: 既に入っている(何もしない)"
        exit 0
    fi
    _ok="${RC_HOOKS_FORCE:-}"
    if [ "${#_ok}" -lt 10 ]; then
        echo "install-hooks: ★既存の pre-commit が違う中身。**上書きしない**"
        echo "  既存: $TARGET($(wc -l < "$TARGET" | tr -d ' ') 行)"
        echo "  誰かの hook を黙って消さない。上書きしてよいなら理由を書いて回す:"
        echo '    RC_HOOKS_FORCE="旧版の厚い hook を薄い口へ置き換える" bash rc-backend/tools/install-hooks.sh'
        echo "  (10文字以上。文言はこの出力に残るので、後から理由を辿れる)"
        exit 1
    fi
    BK="$TARGET.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$TARGET" "$BK" || { echo "install-hooks: ★控えを取れない"; exit 2; }
    echo "install-hooks: 上書きする理由: ${RC_HOOKS_FORCE}"
    echo "  控え: $BK"
fi

printf '%s\n' "$WANT" > "$TARGET" || { echo "install-hooks: ★書けない: $TARGET"; exit 2; }
chmod +x "$TARGET"

# 入れた物が本当に本体を呼ぶか、書いた直後に確かめる(書けた = 効く、ではない)。
if ! grep -q "$BODY" "$TARGET"; then
    echo "install-hooks: ★入れたのに本体を指していない = 未測定として止める"; exit 2
fi
if [ ! -x "$TARGET" ]; then
    echo "install-hooks: ★実行権が付いていない = git は呼ばない"; exit 2
fi

echo "install-hooks: 入れた($TARGET → $BODY)"
exit 0
