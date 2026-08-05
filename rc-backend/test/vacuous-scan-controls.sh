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
# ── 測る9つ ────────────────────────────────────────────────────────────
#   1 floor を下回る木では **exit 2**            (= 測っていないを緑にしない)
#   2 満たした木では exit 2 に**ならない**       (= 1 が常時発火ではない)
#   3 Swift の**部分木**に届く                   (= 非再帰 glob への回帰防止)
#   4 否定だけが無ければ exit 0                  (= 挙げるのが巻き添えでない)
#   5 同梱の自己検査が通る
#   6 分類器を1つ壊すと自己検査が**赤**          (= 5 が空回りでない証拠)
#   7 説明文の剥がしを外すと自己検査が**赤**     (= 2026-08-05 の素通りへの回帰防止)
#   8 分類が常に**錨あり**へ潰れると自己検査が赤 (= 「要人手 0 本」が既定値でない証拠)
#   9 分類が常に**錨なし**へ潰れると自己検査が赤 (= 錨ありの3類が飾りでない証拠)
#
# ★6 が無いと 5 は無意味。「自己検査が通った」は、自己検査が何かを見分けている事を
#   意味しない —— 見分けていなくても通る。壊して赤くなって初めて計器になる。
# ★8/9 を足したのは、2026-08-05 に分類層(錨あり literal/producer/兄弟 を報告から
#   落とす)を入れた日。この層の壊れ方は静かで、潰れても出力は「要人手 0 本 / exit 0」
#   = 健全な報告と**字面が同じ**。実物の木は現に 0 本なので、実物では見分けられない。
#   両向きに壊して両方赤くなる事だけが、分類が何かを見分けている証拠になる。

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
old = "        if NEG.match(form) or NEG_ARGS.search(form) or NEG_SELF.search(form):"
assert old in src, "変異の的が消えている = この対照が古い"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "        if False:"))
PY
if python3 "$T/mutant.py" --self-test > "$T/mutant.log" 2>&1; then
    ng "6 分類器を壊すと自己検査が赤" \
       "常に否定でないと判定させても自己検査が通る = 5 は何も見分けていない"
else
    ok "6 分類器を壊すと自己検査が赤(5 が空回りでない証拠)"
fi

# ── 7: 説明文の剥がしを外すと自己検査が赤 ───────────────────────────────────
#     2026-08-05 の実害そのもの。`assert.deepEqual(x, [], "説明")` —— 説明文を1つ
#     足すだけで、否定だけの検査が**挙がらなくなっていた**(NEG_ARGS が閉じ括弧に
#     錨を打っていた為)。この repo の主流の書き方なので、素通りの範囲は広い。
#     見つけ方は道具の出力ではなく、**実物を空にする変異**: live-http-swallow の
#     `SRC` を空にしたら 10 本中 9 本が赤くなり、緑のまま残った1本を道具は挙げて
#     いなかった。挙げていない事の方が答えだった。
#     ★ここを外して赤くならないなら、その修正はもう効いていない。
python3 - "$TOOL" "$T/mutant2.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "    for form in (one, strip_message(one)):"
assert old in src, "変異の的が消えている = この対照が古い"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "    for form in (one,):"))
PY
if python3 "$T/mutant2.py" --self-test > "$T/mutant2.log" 2>&1; then
    ng "7 説明文の剥がしを外すと自己検査が赤" \
       "説明文つきを見分けられなくても自己検査が通る = 2026-08-05 の穴へ戻っても気づけない"
else
    ok "7 説明文の剥がしを外すと自己検査が赤(素通りへの回帰を捕まえる)"
fi

# ── 8: 分類が「常に錨あり」へ潰れると自己検査が赤 ─────────────────────────
#     2026-08-05 に足した分類層(literal / producer / 兄弟)の対照。この層は
#     **報告から件を落とす**側なので、壊れ方が静かである:潰れても出力は
#     「要人手 0 本 / exit 0」—— 完全に健全な報告と**字面が同じ**になる。
#     実物の木は今この瞬間 0 本なので、実物では両者を見分けられない。
#     だから的は分類器その物に打つ。錨なしの枝を殺して赤くならないなら、
#     「要人手 0 本」は測定ではなく既定値である。
python3 - "$TOOL" "$T/mutant3.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '\n    return "", ""\n'
assert src.count(old) == 1, "変異の的が消えている = この対照が古い"
open(sys.argv[2], "w", encoding="utf-8").write(
    src.replace(old, '\n    return "sibling", "常に錨あり(変異)"\n'))
PY
if python3 "$T/mutant3.py" --self-test > "$T/mutant3.log" 2>&1; then
    ng "8 分類が常に錨ありへ潰れると自己検査が赤" \
       "錨なしの枝を殺しても自己検査が通る = 「要人手 0 本」が測定である保証が無い"
else
    ok "8 分類が常に錨ありへ潰れると自己検査が赤(報告が空になる壊れ方を捕まえる)"
fi

# ── 9: 分類が「常に錨なし」へ潰れると自己検査が赤 ─────────────────────────
#     8 の裏返し。こちらは 2026-08-05 の分類前の状態そのもの —— 58 本挙げて
#     本物 0 本(偽陽性 98%)。赤くならないなら、錨ありの 3 類は飾りで、
#     この道具はまた「読む価値の無い一覧」に戻っている。
#     ★8 と 9 の両方が要る。片方だけでは「常に同じ答えを返す分類器」と
#       見分けが付かない —— 見分けているのは、両向きに壊せる事だけが示す。
python3 - "$TOOL" "$T/mutant4.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '    """(類, 証拠)。類が "" = 錨がどこにも無い = 人手に回す物。"""\n'
assert src.count(old) == 1, "変異の的が消えている = この対照が古い"
open(sys.argv[2], "w", encoding="utf-8").write(
    src.replace(old, old + '    return "", ""\n'))
PY
if python3 "$T/mutant4.py" --self-test > "$T/mutant4.log" 2>&1; then
    ng "9 分類が常に錨なしへ潰れると自己検査が赤" \
       "錨ありを一切出さなくても自己検査が通る = 3類が飾り(偽陽性 98% へ戻っても気づけない)"
else
    ok "9 分類が常に錨なしへ潰れると自己検査が赤(雑音まみれへの回帰を捕まえる)"
fi

cleanup
if [ -d "$T" ]; then
    ng "後始末" "細工した木が残っている: $T"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "VACUOUS-SCAN-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
