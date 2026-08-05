#!/bin/bash
# controls-for: tools/vacuous-gate.sh
# 「空回りする検査を入れていないか」の門が、それ自身空回りしていない事を測る。
#
# ── なぜ実物では測れないか(この門に固有の事情)──────────────────────────
# 実物の木は今この瞬間**錨なし 0 本**なので、実物で回すと常に緑になる。つまり
# 実物の緑は「効いている」の証拠に**ならない**。赤くなる形は木の中に無いので、
# 走査の出力と終了コードを継ぎ目(SCAN_CMD / SELFTEST_CMD)から差し替えて作る。
#
# ── 測る9つ ────────────────────────────────────────────────────────────
#   1 錨なし 0 + 自己検査緑            → exit 0  (= 常に赤い門ではない)
#   2 錨なし 3                          → exit 1  (= 件名を出す)
#   3 集計行が読めない                  → exit 2  (= 走っていないを緑にしない)
#   4 走査が floor 割れ(rc=2)         → exit 2
#   5 **自己検査が赤なら錨なし 0 でも** → exit 2  (= この門の主柱)
#   6 自己検査の結果行が読めない        → exit 2
#   7 逃がし弁(10文字以上)            → exit 0 かつ理由が出力に残る
#   8 逃がし弁が短い                    → 効かない(exit 1 のまま)
#   9 数え上げ 0 なのに rc 非ゼロ       → exit 2  (= 集計の後で壊れている形)
#
# ★5 がこの門の存在理由そのもの。判定材料は「道具が 0 と言った」であり、道具は
#   壊れても 0 と言う —— 分類器が「常に錨あり」へ潰れた時の出力は健全な時と
#   **字面が同じ**(要人手 0 本 / exit 0)。自己検査を先に見る事だけが両者を分ける。
#   ここが緑を通す様になったら、この門は**壊れた道具の 0 を承認する装置**に変わる。
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/rc-backend/tools/vacuous-gate.sh"

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

if [ ! -f "$GATE" ]; then
    echo "FAIL  対象が無い: $GATE"
    echo "--- 合計: PASS 0 / FAIL 1 ---"
    exit 1
fi

# ── 偽の出力(本物の形をそのまま写す)────────────────────────────────────
{
  echo "[js   ] rc-backend/test    file= 30 検査= 619 (floor=25)"
  echo "[swift] ios/Tests          file= 23 検査= 201 (floor=15)"
  echo ""
  echo "--- file 53 / 検査 820 / 否定だけの検査 59 本 (錨あり: literal 11 / producer 10 / 兄弟 38 → **要人手 0 本**) ---"
} > "$T/clean.txt"

{
  echo "  rc-backend/test/fake-a.test.mjs"
  echo "    否定1件のみ  走査した入力に錨が無い検査A"
  echo "  rc-backend/test/fake-b.test.mjs"
  echo "    否定2件のみ  走査した入力に錨が無い検査B"
  echo "  ios/Tests/Core/FakeTests.swift"
  echo "    否定1件のみ  testScannedInputWithNoAnchor"
  echo ""
  echo "--- file 53 / 検査 820 / 否定だけの検査 59 本 (錨あり: literal 11 / producer 10 / 兄弟 35 → **要人手 3 本**) ---"
} > "$T/dirty.txt"

{
  echo "[js   ] rc-backend/test    file= 30 検査= 619 (floor=25)"
  echo "Traceback (most recent call last):"
  echo "  RuntimeError: 走査の途中で死んだ"
} > "$T/nosummary.txt"

echo "[js   ] rc-backend/test    file=  2 検査=   7 (floor=25) ★測っていない" > "$T/floor.txt"

echo "SELF-TEST: pass=17 fail=0" > "$T/self-green.txt"
{
  echo "  FAIL 兄弟も否定だけなら錨にしない(挙がった=2/2 錨なし=0/2)"
  echo "SELF-TEST: pass=16 fail=1"
} > "$T/self-red.txt"
echo "python3: can't open file 'vacuous-scan.py': No such file" > "$T/self-broken.txt"

GREEN="/bin/cat $T/self-green.txt"

run_gate() {  # $1=SELFTEST_CMD $2=SCAN_CMD (残りは env)
    SELFTEST_CMD="$1" SCAN_CMD="$2" bash "$GATE" > "$T/out.log" 2>&1
    echo $?
}

# ── 1: 錨なし 0 + 自己検査緑 → exit 0 ──────────────────────────────────────
rc="$(run_gate "$GREEN" "/bin/cat $T/clean.txt")"
if [ "$rc" = "0" ]; then
    ok "1 錨なし 0 かつ自己検査緑なら通す(常に赤い門ではない)"
else
    ng "1 錨なし 0 かつ自己検査緑なら通す" "exit=$rc / $(tail -3 "$T/out.log" | tr '\n' ' ')"
fi

# ── 2: 錨なし 3 → exit 1 かつ件名を出す ───────────────────────────────────
rc="$(run_gate "$GREEN" "/bin/cat $T/dirty.txt")"
if [ "$rc" = "1" ]; then
    ok "2 錨なしが在れば止める(exit 1)"
else
    ng "2 錨なしが在れば止める" "exit=$rc(止めていない = 門が無いのと同じ)"
fi
if grep -q "fake-a.test.mjs" "$T/out.log" 2>/dev/null; then
    ok "2b どの検査かを名指しする"
else
    ng "2b どの検査かを名指しする" "止めたが、どれを直せばよいか出ない"
fi

# ── 3: 集計行が読めない → exit 2 ──────────────────────────────────────────
#     「走らなかった」を「異常なし」と読む形。この門で一番危ない壊れ方。
rc="$(run_gate "$GREEN" "/bin/cat $T/nosummary.txt")"
if [ "$rc" = "2" ]; then
    ok "3 集計行が読めなければ未測定として止める(exit 2)"
else
    ng "3 集計行が読めなければ未測定として止める" "exit=$rc(走っていないのに緑 or 赤と断じている)"
fi

# ── 4: 走査が floor 割れ(rc=2)→ exit 2 ─────────────────────────────────
rc="$(run_gate "$GREEN" "/bin/cat $T/floor.txt; (exit 2)")"
if [ "$rc" = "2" ]; then
    ok "4 floor 割れは未測定として止める(exit 2)"
else
    ng "4 floor 割れは未測定として止める" "exit=$rc(木が縮んだのを緑と読んでいる)"
fi

# ── 5: 自己検査が赤なら、錨なし 0 でも exit 2 ★主柱 ───────────────────────
rc="$(run_gate "/bin/cat $T/self-red.txt" "/bin/cat $T/clean.txt")"
if [ "$rc" = "2" ]; then
    ok "5 ★自己検査が赤なら錨なし 0 でも止める(壊れた道具の 0 を承認しない)"
else
    ng "5 ★自己検査が赤なら錨なし 0 でも止める" \
       "exit=$rc —— 分類器が潰れた時の出力は健全な時と字面が同じなので、これを通すとこの門は無力"
fi

# ── 6: 自己検査の結果行が読めない → exit 2 ────────────────────────────────
rc="$(run_gate "/bin/cat $T/self-broken.txt" "/bin/cat $T/clean.txt")"
if [ "$rc" = "2" ]; then
    ok "6 自己検査の結果を読めなければ止める(exit 2)"
else
    ng "6 自己検査の結果を読めなければ止める" "exit=$rc(道具が動いていない事を緑と読んでいる)"
fi

# ── 7: 逃がし弁(10文字以上)→ exit 0 かつ理由が残る ─────────────────────
SELFTEST_CMD="$GREEN" SCAN_CMD="/bin/cat $T/dirty.txt" \
  RC_VACUOUS_OK="この3本は入力が固定なので錨は要らないと判断した" \
  bash "$GATE" > "$T/out.log" 2>&1
rc=$?
if [ "$rc" = "0" ]; then
    ok "7 理由つきなら降ろせる(exit 0)"
else
    ng "7 理由つきなら降ろせる" "exit=$rc(降ろせない門は外される)"
fi
if grep -q "錨は要らないと判断した" "$T/out.log" 2>/dev/null; then
    ok "7b 降ろした理由が出力に残る(後から辿れる)"
else
    ng "7b 降ろした理由が出力に残る" "黙って通している = 誰が何を降ろしたか分からない"
fi

# ── 8: 逃がし弁が短ければ効かない ─────────────────────────────────────────
#     「ok」「あとで」の一言で門を開けられるなら、逃がし弁ではなく穴である。
SELFTEST_CMD="$GREEN" SCAN_CMD="/bin/cat $T/dirty.txt" RC_VACUOUS_OK="ok" \
  bash "$GATE" > "$T/out.log" 2>&1
rc=$?
if [ "$rc" = "1" ]; then
    ok "8 短い理由では降ろせない(7 が『環境変数が在れば通る』ではない)"
else
    ng "8 短い理由では降ろせない" "exit=$rc(一言で開く門は穴)"
fi

# ── 9: 数え上げ 0 なのに rc 非ゼロ → exit 2 ───────────────────────────────
#     集計の**後で**壊れている形。「0 と書いてあった」だけで通すと丸ごと素通りする。
rc="$(run_gate "$GREEN" "/bin/cat $T/clean.txt; (exit 3)")"
if [ "$rc" = "2" ]; then
    ok "9 集計は 0 でも終了コードが非ゼロなら止める(集計後の破損)"
else
    ng "9 集計は 0 でも終了コードが非ゼロなら止める" "exit=$rc(集計行だけを根拠に通している)"
fi

cleanup
if [ -d "$T" ]; then
    ng "後始末" "細工した木が残っている: $T"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "VACUOUS-GATE-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
