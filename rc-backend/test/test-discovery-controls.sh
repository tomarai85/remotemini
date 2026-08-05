#!/bin/bash
# controls-for: test/test-discovery.test.mjs
# 「走らなかった検査を捕まえる検査」が、それ自身空回りしていない事を測る。
#
# ── なぜ実物では測れないか ──────────────────────────────────────────────
# `test-discovery.test.mjs` は今の木では**必ず緑**になる。走査は再帰だし、部分木に
# 検査 file は1本も無いからだ。つまり実物の緑は「効いている」の証拠に**ならない**。
# 罠が実際に起きた形(= 非再帰の走査 + 部分木に置かれた検査 file)は、細工した木の中で
# しか作れない。だから偽の木を建てて、そこで赤くなる事を確かめる。
#
# ── 測る4つ ────────────────────────────────────────────────────────────
#   1 非再帰 + 部分木に検査 file  → **赤**(= 罠そのもの。落ちる本数を名指しする)
#   2 再帰   + 部分木に検査 file  → 緑  (= 1 が「部分木が在るだけで赤」ではない)
#   3 非再帰 + 部分木は空         → 緑  (= 1 が「非再帰なら赤」でもない)
#   4 走査パターンを取り出せない  → **赤**(= 判定が空回りする形を緑にしない)
#
# ★ 1 だけでは足りない。2 と 3 が無いと「常に赤い検査」と見分けが付かない。
#   赤くなる条件が**2つの掛け合わせ**である事まで示して、初めて計器になる。
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBJECT="$REPO_ROOT/rc-backend/test/test-discovery.test.mjs"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

T="$(mktemp -d)"
cleanup() {
    [ -n "${T:-}" ] || return 0
    [ -d "$T" ] || return 0
    find "$T" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$T" -type d -depth -print 2>/dev/null | while read -r d; do /bin/rmdir "$d" 2>/dev/null; done
}
trap cleanup EXIT

if [ ! -f "$SUBJECT" ]; then
    echo "FAIL  対象が無い: $SUBJECT"
    echo "--- 合計: PASS 0 / FAIL 1 ---"
    exit 1
fi

# $1=根 $2=走査パターン $3=部分木に検査を置くか(yes/no)
mk_tree() {
    local r="$1" pattern="$2" sub="$3" i
    mkdir -p "$r/test/sub"
    printf '{\n  "name": "fake",\n  "scripts": { "test": "node --test %s" }\n}\n' \
        "'$pattern'" > "$r/package.json"
    cp "$SUBJECT" "$r/test/test-discovery.test.mjs"
    # 分母(>=25)を満たす当たり障りのない検査 file
    for i in $(seq 1 30); do
        printf 'import { test } from "node:test";\nimport assert from "node:assert/strict";\ntest("f%s", () => { assert.equal(1, 1); });\n' \
            "$i" > "$r/test/f$i.test.mjs"
    done
    if [ "$sub" = "yes" ]; then
        printf 'import { test } from "node:test";\nimport assert from "node:assert/strict";\ntest("部分木", () => { assert.equal(1, 1); });\n' \
            > "$r/test/sub/planted.test.mjs"
    fi
}

# 対象 file だけを走らせ、その合否を返す
run_subject() { node --test "$1/test/test-discovery.test.mjs" > "$1/out.log" 2>&1; }

# ── 1: 非再帰 + 部分木に検査 file → 赤 ─────────────────────────────────────
mk_tree "$T/trap" "test/*.test.mjs" yes
if run_subject "$T/trap"; then
    ng "1 非再帰 + 部分木の検査 file で赤" \
       "罠そのものの形で緑 = この検査は走査の穴を見ていない"
else
    ok "1 非再帰 + 部分木の検査 file で赤(罠を捕まえる)"
fi
if grep -q "planted.test.mjs" "$T/trap/out.log" 2>/dev/null; then
    ok "1b 走らない file を名指しする"
else
    ng "1b 走らない file を名指しする" "赤いが、どれが落ちているか出ない"
fi

# ── 2: 再帰 + 部分木に検査 file → 緑 ───────────────────────────────────────
mk_tree "$T/ok-recursive" "test/**/*.test.mjs" yes
if run_subject "$T/ok-recursive"; then
    ok "2 再帰なら部分木が在っても緑(1 が『部分木で常に赤』でない)"
else
    ng "2 再帰なら部分木が在っても緑(1 が『部分木で常に赤』でない)" \
       "$(tail -5 "$T/ok-recursive/out.log" | tr '\n' ' ')"
fi

# ── 3: 非再帰 + 部分木は空 → 緑 ────────────────────────────────────────────
mk_tree "$T/ok-flat" "test/*.test.mjs" no
if run_subject "$T/ok-flat"; then
    ok "3 非再帰でも落ちる物が無ければ緑(1 が『非再帰で常に赤』でない)"
else
    ng "3 非再帰でも落ちる物が無ければ緑(1 が『非再帰で常に赤』でない)" \
       "$(tail -5 "$T/ok-flat/out.log" | tr '\n' ' ')"
fi

# ── 4: 走査パターンが取り出せない → 赤 ─────────────────────────────────────
#     これが緑だと、以下の判定が全部「該当なし」で素通りする形を許してしまう。
mk_tree "$T/nopattern" "test/*.test.mjs" yes
printf '{\n  "name": "fake",\n  "scripts": { "test": "node --test" }\n}\n' \
    > "$T/nopattern/package.json"
if run_subject "$T/nopattern"; then
    ng "4 走査パターンを取り出せなければ赤" \
       "パターン不明でも緑 = 空回りする形を緑にしている"
else
    ok "4 走査パターンを取り出せなければ赤(空回りを緑にしない)"
fi

cleanup
if [ -d "$T" ]; then
    ng "後始末" "細工した木が残っている: $T"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "TEST-DISCOVERY-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
