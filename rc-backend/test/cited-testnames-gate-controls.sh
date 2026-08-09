#!/bin/bash
# controls-for: tools/cited-testnames-gate.sh
# 引用の門が、**緑・赤・測れていない**を撃ち分けられるかを測る。
#
# ── なぜ要るか ────────────────────────────────────────────────────────────
# この門も既定が緑で始まる(対象が staged でなければ黙って exit 0)。加えて、
# 此処が塞ごうとしている病は **2026-08-09 に此処で実際に起きた**:
#   `.harness/dod-sprint-6.5.sh` は「切断を跨げるか」を検査名2つで名指ししていた。
#   検査が改名され(否定対照は1本→4本に増えていた)、表だけが古い名前を持ったまま
#   **製品の赤**を出し続けた。挙動は完全に覆われていたのに、表は「切断を跨げていない」
#   と読める形だった。
# だから此処の核心は 3 番 —— **表を1行も触らない commit で赤が出るか**である。
# 腐りを作るのは検査を改名した側で、その commit は表を触らない。表側だけを引き金に
# した門は、まさに事故を起こす commit を素通しする。
#
# ── どう測るか ────────────────────────────────────────────────────────────
# 本物の repo では測れない(本物の 470 名と 4 本の表に依存してしまう)。
# 偽の repo を `git init` し、門の本体だけ持ち込んで、そこで撃つ。
#
# 終了コード: 0=緑 / 1=赤 / 2=測れていない
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBJECT="$REPO_ROOT/rc-backend/tools/cited-testnames-gate.sh"

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

[ -f "$SUBJECT" ] || { echo "FAIL  対象が無い: $SUBJECT"; echo "--- 合計: PASS 0 / FAIL 1 ---"; exit 2; }

R="$T/repo"
mkdir -p "$R/rc-backend/tools" "$R/.harness/evidence-2026-01-01" "$R/ios/Tests" "$R/ios/Sources"
git -C "$R" init -q 2>/dev/null || { echo "FAIL  偽 repo を作れない"; exit 2; }
git -C "$R" config user.email "c@example.invalid"
git -C "$R" config user.name "controls"
cp "$SUBJECT" "$R/rc-backend/tools/cited-testnames-gate.sh"

# ★偽 repo には `ios/UITests` を**置かない**。本物には在るが、無い木(写し・部分 clone)で
#   抜き出しが壊れて「引用が全部腐っている」と叫ぶのが最悪の誤報なので、無い側で測る。
cat > "$R/ios/Tests/FooTests.swift" <<'SWIFT'
import XCTest
final class FooTests: XCTestCase {
    func testAlpha() {}
    func testBeta() {}
}
SWIFT

cat > "$R/.harness/dod-sprint-9.sh" <<'SH'
#!/bin/bash
# 偽の受け入れ表
check_names testAlpha testBeta
SH

cat > "$R/.harness/dod-sprint-9-controls.sh" <<'SH'
#!/bin/bash
# 偽の対照。**わざと実在しない名前を作る**のが此処の仕事
sed -i '' 's/testAlpha/testRenamedAway/' FooTests.swift
SH

cat > "$R/.harness/evidence-2026-01-01/acc.md" <<'MD'
# 偽の証跡
`testAlpha` が見ている。
MD

git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -qm base >/dev/null 2>&1

run_gate() { ( cd "$R" && bash "$R/rc-backend/tools/cited-testnames-gate.sh" > "$T/out.log" 2>&1; echo $? ); }
reset_tree() { git -C "$R" reset -q >/dev/null 2>&1; git -C "$R" checkout -q -- . >/dev/null 2>&1; }

# ── 1: 引用が全部実在 → 緑 ───────────────────────────────────────────────
printf '# 触った\n' >> "$R/.harness/dod-sprint-9.sh"
git -C "$R" add .harness/dod-sprint-9.sh >/dev/null 2>&1
rc="$(run_gate)"
if [ "$rc" = "0" ] && grep -q "全部実在" "$T/out.log"; then
    ok "1 引用が全部実在するなら緑"
else
    ng "1 引用が全部実在するなら緑" "exit=$rc: $(head -3 "$T/out.log" | tr '\n' ' ')"
fi
reset_tree

# ── 2: 表が実在しない名前を引いたら赤、その名前と file を名指しする ───────
printf 'check_names testGhostThatNeverExisted\n' >> "$R/.harness/dod-sprint-9.sh"
git -C "$R" add .harness/dod-sprint-9.sh >/dev/null 2>&1
rc="$(run_gate)"
if [ "$rc" = "1" ] && grep -q "testGhostThatNeverExisted" "$T/out.log" && grep -q "dod-sprint-9.sh" "$T/out.log"; then
    ok "2 表が実在しない検査名を引いたら赤(名前と file を名指しする)"
else
    ng "2 表が実在しない検査名を引いたら赤" "exit=$rc: $(head -4 "$T/out.log" | tr '\n' ' ')"
fi
reset_tree

# ── 3: ★検査を改名しただけで赤(表は1行も触らない)───────────────────────
# 2026-08-09 に実際に起きた形。此処が緑だと、門が在っても事故は起きる。
/usr/bin/sed -i '' 's/func testBeta()/func testBetaRenamedAndExpanded()/' "$R/ios/Tests/FooTests.swift"
git -C "$R" add ios/Tests/FooTests.swift >/dev/null 2>&1
git -C "$R" diff --cached --name-only | grep -q '^\.harness/' \
    && ng "3-前提 表が staged に混ざっている" "対照の組み立てが壊れている"
rc="$(run_gate)"
if [ "$rc" = "1" ] && grep -q "testBeta$" "$T/out.log"; then
    ok "3 ★検査の改名だけで赤(表を触らない commit を素通ししない)"
else
    ng "3 ★検査の改名だけで赤" "exit=$rc: $(head -4 "$T/out.log" | tr '\n' ' ')"
fi
reset_tree

# ── 4: 対象外の commit には何も言わない ──────────────────────────────────
echo "let x = 1" > "$R/ios/Sources/Z.swift"
git -C "$R" add ios/Sources/Z.swift >/dev/null 2>&1
rc="$(run_gate)"
if [ "$rc" = "0" ] && [ ! -s "$T/out.log" ]; then
    ok "4 検査も表も触らない commit には何も言わずに通す"
else
    ng "4 対象外の commit には何も言わず通す" "exit=$rc 出力=$(wc -l < "$T/out.log")行"
fi
git -C "$R" reset -q >/dev/null 2>&1; /bin/rm -f "$R/ios/Sources/Z.swift"

# ── 5: `*-controls.sh` の中の実在しない名前は赤にしない ───────────────────
# ★これは**意図した穴**であって、穴が意図どおりの形をしている事を測る。対照 file は
#   実在しない名前を作るのが仕事なので、見ると門は必ず赤になり、外される。
printf "sed -i '' 's/x/testAnotherGhostName/'\n" >> "$R/.harness/dod-sprint-9-controls.sh"
git -C "$R" add .harness/dod-sprint-9-controls.sh >/dev/null 2>&1
rc="$(run_gate)"
if [ "$rc" = "0" ]; then
    ok "5 対照 file の中の実在しない名前は赤にしない(意図した穴)"
else
    ng "5 対照 file は見ない" "exit=$rc(対照が名前を捏造する度に commit が止まる)"
fi
reset_tree

# ── 6: 実在名を1件も抜けない → 2(緑にも赤にも丸めない)──────────────────
# Swift の検査の書き方が変わった時に「引用が全部腐っている」と叫ばせない。
printf '# 触った\n' >> "$R/.harness/dod-sprint-9.sh"
git -C "$R" add .harness/dod-sprint-9.sh >/dev/null 2>&1
cp "$R/ios/Tests/FooTests.swift" "$T/stash.swift"
printf 'import XCTest\nfinal class FooTests: XCTestCase { @Test func alpha() {} }\n' > "$R/ios/Tests/FooTests.swift"
rc="$(run_gate)"
if [ "$rc" = "2" ] && grep -q "測れていない" "$T/out.log"; then
    ok "6 実在名を1件も抜けない時は 2(測れていない)= 緑とも赤とも言わない"
else
    ng "6 抜き出し 0 件は 2" "exit=$rc: $(head -2 "$T/out.log" | tr '\n' ' ')"
fi
cp "$T/stash.swift" "$R/ios/Tests/FooTests.swift"

# ── 7: `ios/Tests` ごと無い → 2 ──────────────────────────────────────────
mv "$R/ios/Tests" "$T/Tests-stash"
rc="$(run_gate)"
if [ "$rc" = "2" ]; then
    ok "7 ios/Tests が無い木では 2(門は自分が測れない事を言う)"
else
    ng "7 ios/Tests が無い木では 2" "exit=$rc"
fi
mv "$T/Tests-stash" "$R/ios/Tests"
reset_tree

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "CITED-TESTNAMES-GATE-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
