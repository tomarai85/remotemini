#!/bin/bash
# controls-for: tools/staged-controls-gate.sh ../ios/tools/mutation-residue-check.sh
#
# **空白を含む path が来ても、対照を選ぶ 2 つの門が黙って壊れない**事の対照。
#
# ── なぜ要るか(2026-09-09、SC2086 の掃引)────────────────────────────────────
# 引用漏れの怖さは「落ちる」事ではなく **黙って別の物を見る** 事。
#   `git diff -- $paths` に `my file.swift` が混ざると、git は
#   `my` と `file.swift` という**当たらない 2 つの path** を受け取り、当たらない path を
#   無視する —— つまり其の file だけが照合から静かに抜ける。出力には何も出ない。
# 此の型は `ios/tools/mutation-residue-check.sh` の一線(「静かに抜ける path を作らない」)
# を、其の道具自身の引数の渡し方が破る形だった。
#
# ★同じ掃引で**実行されていた診断文**も 1 件 見つかっている:
#   `ios/tools/initial-load-narration-control.sh` が「変異が残っている」と気付いた瞬間に
#   二重引用符の中の backtick で `git checkout HEAD -- <file>` を**本当に走らせ**、
#   利用者の作業中の変更を黙って捨てていた(実測で確認して修正済)。
#
# 測る事(全部 砂場の作り木。本物の木は 1 バイトも触らない):
#   P1 ★`git diff -- <配列>` が、空白を含む path の変更を**見つける**
#   P2 ★陰性対照 —— 同じ入力を**生展開**で渡すと見つけられない(P1 が本当に其れを測っている)
#   P3 ★`git checkout -- <配列>` が、空白を含む path を正しく 1 本として戻す
#   P4 `staged-controls-gate.sh` の混在の報告が、空白を含む path を途中で切らない
#   P5 ★引用しても git 自身が pathspec を glob として展開する(機序を実測で見せる)
#   P6 ★破壊的な checkout は宣言ではなく git の出力を使っている(構造の主張)
#
# 使い方: bash rc-backend/test/path-with-space-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤 / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
pass=0; fail=0; unmeasured=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail+1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
R="$SB/repo"; mkdir -p "$R/dir"
git -C "$R" init -q 2>/dev/null || { echo "UNMEASURED  git init できない"; exit 2; }
git -C "$R" config user.email "c@example.invalid"
git -C "$R" config user.name "controls"
SPACED="dir/my file.swift"
printf 'original\n' > "$R/$SPACED"
printf 'plain\n'    > "$R/dir/plain.swift"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -qm base >/dev/null 2>&1
printf 'mutated\n' > "$R/$SPACED"

# 対象の一覧(改行区切り)。実物と同じ形で持つ。
targets="$SPACED
dir/plain.swift"

# ── P1 配列で渡せば見つかる ───────────────────────────────────────────────
arr=(); while IFS= read -r t; do [ -n "$t" ] && arr+=("$t"); done <<< "$targets"
found="$( cd "$R" && git diff --name-only -- "${arr[@]}" 2>/dev/null )"
if printf '%s' "$found" | grep -qF "$SPACED"; then
    ok "P1 ★配列で渡せば、空白を含む path の変更を見つける"
else ng "P1" "見つけられなかった(found=[$found])"; fi

# ── P2 ★陰性対照: 生展開だと見つけられない ───────────────────────────────
# 之が無いと P1 は「git が賢いから通った」でも緑になり、渡し方を測った事にならない。
# shellcheck disable=SC2086  # 生展開が壊れる事を**示す為**の行。引用したら陰性対照にならない
raw="$( cd "$R" && git diff --name-only -- $targets 2>/dev/null )"
if printf '%s' "$raw" | grep -qF "$SPACED"; then
    ng "P2 陰性対照" "生展開でも見つかった = P1 の緑は渡し方を測っていない"
else
    ok "P2 ★生展開では見つけられない(P1 は本当に渡し方を測っている)"
fi

# ── P3 配列なら正しく戻せる ───────────────────────────────────────────────
( cd "$R" && git checkout -- "${arr[@]}" ) >/dev/null 2>&1
after="$(cat "$R/$SPACED" 2>/dev/null)"
if [ "$after" = "original" ]; then
    ok "P3 ★配列で渡せば、空白を含む path を 1 本として正しく戻せる"
else ng "P3" "戻っていない(中身=[$after])"; fi

# ── P4 混在の報告が path を切らない ───────────────────────────────────────
# `staged-controls-gate.sh` の該当行の形だけを、同じ入力で測る。
mixed="$SPACED"
out="$(printf '    %s\n' "$mixed")"
if [ "$(printf '%s\n' "$out" | grep -c .)" = "1" ] && printf '%s' "$out" | grep -qF "$SPACED"; then
    ok "P4 混在の報告が空白を含む path を 1 行のまま出す"
else ng "P4" "報告が割れた: [$out]"; fi
# 本体が引用した形になっているか(退行したら此処が気付く)
if grep -qE "printf '    %s\\\\n' \"\\\$mixed\"" "$ROOT/rc-backend/tools/staged-controls-gate.sh"; then
    ok "P4b 本体も引用した形のまま(生展開へ戻っていない)"
else ng "P4b" "本体が生展開へ戻っている = 報告が再び割れる"; fi

# ── P5 ★引用しても **git 自身が** pathspec を glob として展開する ────────────
# Codex 2026-09-09: 引用が止めるのは shell だけ。之を知らないと「配列にしたから安全」と
# 読んでしまう。機序を実測で毎回 見せる。
G="$SB/glob"; mkdir -p "$G/dir"
git -C "$G" init -q 2>/dev/null && git -C "$G" config user.email c@e.invalid && git -C "$G" config user.name c
printf 'a\n' > "$G/dir/a.swift"; printf 'b\n' > "$G/dir/b.swift"
git -C "$G" add -A >/dev/null 2>&1; git -C "$G" commit -qm base >/dev/null 2>&1
printf 'A\n' > "$G/dir/a.swift"; printf 'B\n' > "$G/dir/b.swift"
gpaths=("dir/*.swift")
( cd "$G" && git checkout -- "${gpaths[@]}" ) >/dev/null 2>&1
if [ "$(cat "$G/dir/b.swift")" = "b" ]; then
    ok "P5 ★引用しても git は pathspec を展開する(名指ししていない file まで戻った)"
else ng "P5" "展開しなかった = 此の git では機序が違う。註の前提を見直す事"; fi

# ── P6 ★戻す側は宣言ではなく **git の出力** を使っている(構造の主張)─────────
# P5 の機序が在るので、宣言(glob 可)を破壊的な `git checkout` へ渡すと
# **照合で一度も見ていない file まで戻る**。今の形が其れを避けている事を見る。
# ★之は静的な主張(どの変数を渡しているか)で、振る舞いの測定ではない。
#   対にして P5 が「なぜ其れが要るか」を実測で示す。
RES="$ROOT/ios/tools/mutation-residue-check.sh"
if [ ! -f "$RES" ]; then
    ng "P6" "$RES が居ない"
elif grep -qE 'git checkout -- \$\{dirty_args\[@\]' "$RES" \
     && ! grep -qE 'git checkout -- \$\{target_args\[@\]' "$RES"; then
    ok "P6 ★戻すのは git diff の出力(具体的な path)で、宣言(glob 可)ではない"
else ng "P6" "破壊的な checkout に宣言由来の path が渡っている疑い = 見ていない file まで戻る"; fi

echo ""
echo "--- 合計: PASS $pass / FAIL $fail / UNMEASURED $unmeasured ---"
[ "$fail" -gt 0 ] && exit 1
[ "$unmeasured" -gt 0 ] && exit 2
exit 0
