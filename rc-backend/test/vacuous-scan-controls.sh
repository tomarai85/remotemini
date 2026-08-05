#!/bin/bash
# controls-for: tools/vacuous-scan.py
# vacuous-scan の**分母の仕掛け**を測る対照。
#
# ── なぜ要るか(2026-08-05)────────────────────────────────────────────────
# この道具は「否定だけで出来ている検査」を挙げる。つまり**空回りする検査を捕まえる
# 為の道具**である。その道具自身が空回りしていたら、洒落にならない。
#
# 旧版は scratchpad に在って、絶対パス埋め込み・非再帰 glob・分母なしだった。
# 実害: `ios/Tests` を一切見ていなかった(木として無く、19本中18本が部分木に在るので
# 非再帰 glob では届かない)。それでも出力は「否定だけの検査: N 本」と**堂々と**出る。
# 見ている範囲を言わない道具は、見ていない事を緑として報告する。
#
# 昇格版は木ごとに floor を持ち、下回れば **exit 2(測っていない)** を返す。
# ★ここが対照の主対象。`--self-test` は**分類器**しか見ておらず、分母の仕掛けを
#   一度も通らない。分類が正しくても走査が空なら、この道具は無害な顔で無力になる。
#
# ── 測る6つ ────────────────────────────────────────────────────────────
#   1 floor を下回る木では **exit 2**            (= 測っていないを緑にしない)
#   2 満たした木では exit 2 に**ならない**       (= 1 が常時発火ではない)
#   3 Swift の**部分木**に届く                   (= 非再帰 glob への回帰防止)
#   4 否定だけが無ければ exit 0                  (= 挙げるのが巻き添えでない)
#   5 同梱の自己検査が通る
#   6 分類器を1つ壊すと自己検査が**赤**          (= 5 が空回りでない証拠)
#
# ★6 が無いと 5 は無意味。「自己検査が通った」は、自己検査が何かを見分けている事を
#   意味しない —— 見分けていなくても通る。壊して赤くなって初めて計器になる。

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$REPO_ROOT/rc-backend/tools/vacuous-scan.py"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

T="$(mktemp -d)"
cleanup() {
    [ -n "${T:-}" ] || return 0
    [ -d "$T" ] || return 0
    find "$T" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    # 深い方から畳む(rmdir は空でなければ黙って失敗するので安全側)
    find "$T" -type d -depth -print 2>/dev/null | while read -r d; do /bin/rmdir "$d" 2>/dev/null; done
}
trap cleanup EXIT

if [ ! -f "$TOOL" ]; then
    echo "FAIL  道具が無い: $TOOL"
    echo "--- 合計: PASS 0 / FAIL 1 ---"
    exit 1
fi

# ── 偽の repo を建てる。根の目印は DESIGN.md + rc-backend/ ───────────────────
mk_repo() {  # $1 = 根, $2 = js の本数, $3 = swift の本数, $4 = vacuous を混ぜるか
    local r="$1" njs="$2" nsw="$3" vac="$4" i
    mkdir -p "$r/rc-backend/tools" "$r/rc-backend/test" "$r/ios/Tests/Core"
    : > "$r/DESIGN.md"
    cp "$TOOL" "$r/rc-backend/tools/vacuous-scan.py"
    for i in $(seq 1 "$njs"); do
        printf 'test("錨が在る %s", () => {\n  assert.equal(n, 3);\n});\n' "$i" \
            > "$r/rc-backend/test/f$i.test.mjs"
    done
    for i in $(seq 1 "$nsw"); do
        printf 'func testAnchored%s() {\n    XCTAssertEqual(items.count, 3)\n}\n' "$i" \
            > "$r/ios/Tests/Core/S${i}Tests.swift"
    done
    if [ "$vac" = "yes" ]; then
        # ★**部分木**に置く。非再帰 glob へ戻ったらこれが見えなくなる
        printf 'func testNothingHappens() {\n    XCTAssertNil(model.error)\n    XCTAssertTrue(model.items.isEmpty)\n}\n' \
            > "$r/ios/Tests/Core/PlantedTests.swift"
    fi
}

run_in() { python3 "$1/rc-backend/tools/vacuous-scan.py" 2>&1; }

# ── 1: floor を下回れば exit 2 ───────────────────────────────────────────────
mk_repo "$T/small" 2 1 no
out="$(run_in "$T/small")"; rc=$?
if [ "$rc" -eq 2 ]; then
    ok "1 floor を下回る木は exit 2(測っていない)"
else
    ng "1 floor を下回る木は exit 2(測っていない)" \
       "exit=$rc = 走査が空でも緑か赤を返している。分母の仕掛けが効いていない"
fi
case "$out" in
    *"測っていない"*) ok "1b 何が測れなかったかを名指しする" ;;
    *) ng "1b 何が測れなかったかを名指しする" "出力に理由が出ない" ;;
esac

# ── 2 + 3: floor を満たし、部分木の vacuous を挙げる ─────────────────────────
mk_repo "$T/full" 26 16 yes
out="$(run_in "$T/full")"; rc=$?
if [ "$rc" -ne 2 ]; then
    ok "2 floor を満たせば exit 2 にならない(1 が常時発火でない)"
else
    ng "2 floor を満たせば exit 2 にならない(1 が常時発火でない)" \
       "満たしても測っていない扱い: $out"
fi
case "$out" in
    *PlantedTests*)
        ok "3 Swift の部分木に届く(非再帰 glob への回帰を捕まえる)" ;;
    *)
        ng "3 Swift の部分木に届く(非再帰 glob への回帰を捕まえる)" \
           "部分木に植えた否定だけの検査が挙がらない = ios を歩けていない" ;;
esac

# ── 4: 否定だけが無ければ exit 0 ────────────────────────────────────────────
mk_repo "$T/clean" 26 16 no
out="$(run_in "$T/clean")"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "4 否定だけが無ければ exit 0(3 が巻き添えでない)"
else
    ng "4 否定だけが無ければ exit 0(3 が巻き添えでない)" \
       "綺麗な木で exit=$rc: $out"
fi

# ── 5: 同梱の自己検査 ───────────────────────────────────────────────────────
if python3 "$TOOL" --self-test > "$T/self.log" 2>&1; then
    ok "5 同梱の自己検査が通る"
else
    ng "5 同梱の自己検査が通る" "$(tail -3 "$T/self.log" | tr '\n' ' ')"
fi

# ── 6: 分類器を壊すと自己検査が赤(5 が空回りでない証拠)──────────────────
#     否定の判定そのものを潰す。壊して赤くならないなら、自己検査は何も見ていない。
sed 's/^NEG = re\.compile($/NEG = re.compile(r"(?!x)x") if False else re.compile(/' \
    "$TOOL" > "$T/mutant.py" 2>/dev/null
# 上の置換が当たらない環境でも確実に壊れる形にする(判定関数を常に False へ)
python3 - "$TOOL" "$T/mutant.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "    return bool(NEG.match(one) or NEG_ARGS.search(one) or NEG_SELF.search(one))"
assert old in src, "変異の的が消えている = この対照が古い"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "    return False"))
PY
if python3 "$T/mutant.py" --self-test > "$T/mutant.log" 2>&1; then
    ng "6 分類器を壊すと自己検査が赤" \
       "常に否定でないと判定させても自己検査が通る = 5 は何も見分けていない"
else
    ok "6 分類器を壊すと自己検査が赤(5 が空回りでない証拠)"
fi

cleanup
if [ -d "$T" ]; then
    ng "後始末" "細工した木が残っている: $T"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "VACUOUS-SCAN-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
