#!/bin/bash
# `tools/deploy-dirt.sh` が「汚れは実行コードか付随物か」を**両向きに**正しく答える事の確認。
#   exit 0=綺麗 / 1=付随物のみ / 2=src|test が汚れている / 3=git で判らない
#
# ── なぜこの対照が**本物の git repo を作る**のか(2026-08-02、失敗から) ──────────
# 最初これを「porcelain の行を模した文字列」を食わせる形で書き、13/13 緑になった。
# その直後に実物へ通したら **false negative** で落ちた:
#     ?? rc-backend/test/deploy-dirt-controls.sh   ← 実物はこう出る
# `git status --porcelain` の path は **repo root からの相対**で、`-C <srcdir>` を付けても
# 変わらない。ここは root が `mobile-work/` で `rc-backend/` は部分木。作り物の行には
# その prefix が無かったので、対照は**私の思い込みの形**だけを撃っていた。
#   ★型: 作り物の入力で組んだ対照は、入力の形そのものが違う欠陥を**原理的に**見つけられない。
#     今朝の `-u` の穴(囮が旗なしの形だけ)と同じ病気を、同じ日に別の場所で繰り返した。
# → 以後この対照は git repo を実際に作り、判定を**同じ経路**で通す。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIRT="$ROOT/tools/deploy-dirt.sh"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

TMP="$(mktemp -d /tmp/deploy-dirt-ctl.XXXXXX)"
cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && /bin/rm -rf -- "$TMP"; }
trap cleanup EXIT INT TERM

G() { git -c user.email=c@x -c user.name=c -C "$1" "${@:2}"; }

# 土台を作る。$1=repo 名, $2=srcdir の repo 内 path(空 = root 自身が srcdir)
mkrepo() {
    local r="$TMP/$1" sub="${2:-}"
    mkdir -p "$r"; G "$r" init -q -b main
    local s="$r${sub:+/$sub}"
    mkdir -p "$s/src" "$s/test" "$s/.harness"
    echo "x" > "$s/src/a.mjs"; echo "x" > "$s/test/a.test.mjs"; echo "x" > "$s/WORKLOG.md"
    [ -n "$sub" ] && echo "root" > "$r/REQUIREMENTS.md"
    G "$r" add -A >/dev/null; G "$r" commit -qm base >/dev/null
    echo "$s"
}

# $1=期待exit $2=題名 $3=srcdir
expect() {
    local want="$1" name="$2" s="$3" got out
    out="$(bash "$DIRT" "$s" 2>&1)"; got=$?
    if [ "$got" -eq "$want" ]; then ok "$name"
    else ng "$name" "期待exit=$want 実際=$got  出力: $(printf '%s' "$out" | tr '\n' '/')"; fi
}

# ══ A) srcdir が repo root 自身 ══════════════════════════════════════════
S="$(mkrepo a)"
expect 0 "A1 綺麗な木" "$S"
echo '{}' > "$S/.harness/ev.json"
expect 1 "A2 未追跡の evidence だけ = 付随物" "$S"
echo "y" >> "$S/src/a.mjs"
expect 2 "A3 src/ の変更 = 実行コード" "$S"

# ══ B) srcdir が部分木(実物と同じ形。ここで一度落ちた) ═══════════════════
S="$(mkrepo b sub)"
expect 0 "B1 綺麗な木(部分木)" "$S"
echo '{}' > "$S/.harness/ev.json"
expect 1 "B2 evidence だけ(部分木) = 付随物" "$S"
# ★これが実物で落ちた形: 未追跡の test/ が prefix 付きで出る
echo "x" > "$S/test/new.test.mjs"
expect 2 "B3 ★未追跡の test/(部分木) = 実行コード" "$S"
/bin/rm -f -- "$S/test/new.test.mjs"
echo "y" >> "$S/src/a.mjs"
expect 2 "B4 src/ の変更(部分木) = 実行コード" "$S"
G "$TMP/b" checkout -q -- . 2>/dev/null

# ══ C) 空白入り path(引用符で括られる形) ════════════════════════════════
S="$(mkrepo c sub)"
echo "x" > "$S/src/a b.mjs"
expect 2 "C1 ★空白入りの新 src/(引用符つき)" "$S"

# ══ D) 偽陽性の向き: 送らない場所の汚れで「汚れた配備」と言わない ══════════
S="$(mkrepo d sub)"
echo "changed" >> "$TMP/d/REQUIREMENTS.md"     # srcdir の**外**
expect 0 "D1 ★srcdir 外の汚れは無視する(送る物は変わっていない)" "$S"

# ══ E) 判らない時は黙って「綺麗」と言わない ══════════════════════════════
mkdir -p "$TMP/nogit/src"
expect 3 "E1 git repo でない = 3(綺麗と誤答しない)" "$TMP/nogit"

echo ""
echo "DEPLOY-DIRT-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
