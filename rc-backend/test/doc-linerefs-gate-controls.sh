#!/bin/bash
# controls-for: tools/doc-linerefs-gate.sh
# 書類の門が、**緑・赤・測れていない**の3つを撃ち分けられるかを測る。
#
# ── なぜ要るか ────────────────────────────────────────────────────────────
# この門は「`.md` が staged でなければ黙って exit 0」で始まる。つまり**既定が緑**で、
# 何もしなくても緑に見える。この repo が今日だけで何度も踏んだ形そのものなので、
# 「増やせば赤くなる」を実際に撃って確かめるまでは、この門は緑を主張する資格が無い。
#
# ── どう測るか ────────────────────────────────────────────────────────────
# 本物の repo では測れない(本物の基準値と本物の 36 本の .md に依存してしまう)。
# 偽の repo を `git init` し、検査の本体と基準値だけ持ち込んで、そこで撃つ。
#
# 終了コード: 0=緑 / 1=赤 / 2=測れていない
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBJECT="$REPO_ROOT/rc-backend/tools/doc-linerefs-gate.sh"
TESTSRC="$REPO_ROOT/rc-backend/test/doc-linerefs.test.mjs"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

T="$(mktemp -d)"
cleanup() {
    [ -n "${T:-}" ] && [ -d "$T" ] || return 0
    find "$T" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$T" -type d -depth -print 2>/dev/null | while read -r d; do /bin/rmdir "$d" 2>/dev/null; done
}
trap cleanup EXIT

for f in "$SUBJECT" "$TESTSRC"; do
    [ -f "$f" ] || { echo "FAIL  対象が無い: $f"; echo "--- 合計: PASS 0 / FAIL 1 ---"; exit 2; }
done

# 偽 repo。基準値は合成(本物の 393 件に依存させない)。
R="$T/repo"
mkdir -p "$R/rc-backend/tools" "$R/rc-backend/test/fixtures"
git -C "$R" init -q 2>/dev/null || { echo "FAIL  偽 repo を作れない"; exit 2; }
git -C "$R" config user.email "c@example.invalid"
git -C "$R" config user.name "controls"
cp "$SUBJECT" "$R/rc-backend/tools/doc-linerefs-gate.sh"
cp "$TESTSRC" "$R/rc-backend/test/doc-linerefs.test.mjs"

# 引用を1件持つ書類を 20 本(検査は「追跡 .md が 20 本未満なら壊れている」と見る)。
# ★綴りは連結で組み立てる。この対照 file 自身も `no-linerefs` に走査されるので、
#   「見つかってはいけない形」を1バイトも自分の中に置かない。
# ★初版は `REF="$REF" + ".mjs:320"` と書いて**自分の検査に捕まった**。変数の境界で
#   割っても、割った後の literal に `.mjs:320` がそのまま残っていたら意味が無い。
#   割るべきは変数の境界ではなく、**当たる部分文字列そのもの**(拡張子の前の `.` と
#   行番号の前の `:`)である。
D="." ; C=":"
REF="view${D}mjs${C}320"
{ echo '{'; for i in $(seq 1 20); do
      printf '  "d%02d.md": 1%s\n' "$i" "$([ "$i" -lt 20 ] && echo ,)"
  done; echo '}'; } > "$R/rc-backend/test/fixtures/doc-linerefs-baseline.json"
for i in $(seq 1 20); do printf '# %s\n出所は %s\n' "$i" "$REF" > "$R/$(printf 'd%02d.md' "$i")"; done
git -C "$R" add -A >/dev/null 2>&1

run_gate() { ( cd "$R" && bash "$R/rc-backend/tools/doc-linerefs-gate.sh" > "$T/out.log" 2>&1; echo $? ); }

# ── 1: 基準値どおり → 緑 ─────────────────────────────────────────────────
rc="$(run_gate)"
if [ "$rc" = "0" ] && grep -q "緑" "$T/out.log"; then
    ok "1 基準値どおりの書類なら緑"
else
    ng "1 基準値どおりの書類なら緑" "exit=$rc: $(head -3 "$T/out.log" | tr '\n' ' ')"
fi

# ── 2: ★1件増やすと赤(既定の緑ではない事の証明)──────────────────────────
printf '# 1\n出所は %s\nもう1つ %s\n' "$REF" "$REF" > "$R/d01.md"
git -C "$R" add d01.md >/dev/null 2>&1
rc="$(run_gate)"
if [ "$rc" = "1" ] && grep -q "d01.md" "$T/out.log"; then
    ok "2 ★引用を1件増やすと赤になり、増えた file を名指しする"
else
    ng "2 ★引用を1件増やすと赤になる" "exit=$rc: $(grep -c . "$T/out.log") 行"
fi

# ── 3: stage しなければ止めない(隣の書きかけで全員が止まらない)──────────
printf '# 1\n出所は %s\n' "$REF" > "$R/d01.md"
git -C "$R" add d01.md >/dev/null 2>&1          # 索引を基準値どおりへ戻し
printf '# 1\n出所は %s\nさらに %s\n' "$REF" "$REF" > "$R/d01.md"   # 作業木だけ増やす
rc="$(run_gate)"
if [ "$rc" = "0" ]; then
    ok "3 stage していない増分では止めない(門が見るのは索引 = repo に入る物)"
else
    ng "3 stage していない増分では止めない" "exit=$rc(隣の書きかけで全員の commit が止まる)"
fi
git -C "$R" checkout -- d01.md 2>/dev/null

# ── 4: `.md` が1件も staged でなければ黙って通す ──────────────────────────
git -C "$R" commit -qm base >/dev/null 2>&1
mkdir -p "$R/rc-backend/src"; echo "export const x = 1;" > "$R/rc-backend/src/z.mjs"
git -C "$R" add rc-backend/src/z.mjs >/dev/null 2>&1
rc="$(run_gate)"
if [ "$rc" = "0" ] && [ ! -s "$T/out.log" ]; then
    ok "4 .md を含まない commit には何も言わずに通す(門は自分の対象だけを見る)"
else
    ng "4 .md を含まない commit には何も言わず通す" "exit=$rc 出力=$(wc -l < "$T/out.log")行"
fi

# ── 5: 検査の本体が無い → 2(緑にも赤にも丸めない)────────────────────────
# ★中身は HEAD と**変えて** stage する。同じ内容を `git add` しても staged 差分は
#   0 件で、門は「.md が入っていない」と読んで正しく素通しする —— 初版はそれで
#   偽の PASS ではなく偽の FAIL を出した(引用の数は変えない)。
git -C "$R" reset -q >/dev/null 2>&1
printf '# 1 (改)\n出所は %s\n' "$REF" > "$R/d01.md"; git -C "$R" add d01.md >/dev/null 2>&1
git -C "$R" diff --cached --name-only | grep -q '^d01\.md$' \
    || ng "5-前提 d01.md が staged になっていない" "対照の組み立てが壊れている"
mv "$R/rc-backend/test/doc-linerefs.test.mjs" "$T/stash.mjs"
rc="$(run_gate)"
if [ "$rc" = "2" ]; then
    ok "5 検査の本体が無い時は 2(測れていない)= 緑と言わない"
else
    ng "5 検査の本体が無い時は 2" "exit=$rc(測れていないのに $([ "$rc" = 0 ] && echo 緑 || echo 赤)と言った)"
fi

# ── 6: 検査が skip を出したら 2(本物の repo で走っていないのを緑と読まない)──
# ★`console.log("# skipped 4")` を刷るだけの偽物では測れない: `node --test` は
#   自分の集計として `# skipped 0` を**別に**刷るので、門の grep はそちらに当たって緑になる。
#   本物と同じ形 —— 実際に skip する test —— を置く。これは写しの木で起きる事そのもの。
printf 'import { test } from "node:test";\ntest("m", { skip: "測っていない" }, () => {});\n' \
    > "$R/rc-backend/test/doc-linerefs.test.mjs"
rc="$(run_gate)"
if [ "$rc" = "2" ] && grep -q "測れていない" "$T/out.log"; then
    ok "6 skip が出たら 2(『測っていない』を緑と読み替えない)"
else
    ng "6 skip が出たら 2" "exit=$rc: $(head -2 "$T/out.log" | tr '\n' ' ')"
fi
cp "$T/stash.mjs" "$R/rc-backend/test/doc-linerefs.test.mjs"

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "DOC-LINEREFS-GATE-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
