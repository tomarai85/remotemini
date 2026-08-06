#!/bin/bash
# controls-for: tools/port-coverage.py
# `tools/port-coverage.py` の対照。
#
# この道具の一番痛い壊れ方は**偽の緑**(移っていない入力を「在る」と言う)なので、
# 対照の重心もそこに置く: 語境界(P3)/ 数値の区切りの揺れ(P4)/ 判定しない種別が
# 赤にならない事(P5-P7)/ 測れない時に 0 へ丸めない事(P8-P9)。
#
# ★実測(2026-08-05。`PC_TOOL` に変異版を差した。素の版は 29/29):
#   | 差した物                                              | 倒れた assertion | 残り  |
#   |---|---|---|
#   | A: 語境界を素朴な部分一致へ戻した版                    | P2a P2b **P3**   | 26/29 |
#   | B: 識別子を「照合できる」側へ戻した版                  | P5a P5b          | 27/29 |
#   | C: 測れない時に 2 でなく 0 を返す版                    | P8 P9 **P13a**   | 26/29 |
#   | D: 死んだ受理を赤にしない版                            | P15a P15b        | 27/29 |
#   | E: 逆向きの数え(表に無い Swift 検査)を外した版        | P13a P13b        | 27/29 |
#   5つが**ほぼ重ならない** = それぞれ別の物を掴んでいる。A で P2 も倒れるのは、
#   素朴な部分一致だと JS の `50` が Swift の `150` の中に見つかるから ——
#   偽の緑の作られ方そのものが、P2 と P3 の2箇所から見えている。
#   C と E が P13a で重なるのは、P13 が「測れない = 2」の約束に乗っているから
#   (2 を 0 に丸めても、逆向きの数えを外しても、同じ assertion が落ちる)。
#   (A の下では P12 は素通りする。A は既に素朴版なので陰性対照の差し込みが
#    「元から当たっている」状態になる。変異版どうしの縮退で、素の版の欠陥ではない)
#
# ★この表は一度**間違って**書いた。最初の B は `lits` の側だけを書き換えて `opaque` の
#   側を残したので、識別子が**両方に数えられ**、P5b が素通りした。表には「B は P5a だけ」
#   と出た —— 対照の性能ではなく**変異の掛け方**が測っていた物なのに、表は対照の性能の
#   顔をして残る。変異は「消したい性質を丸ごと消す」形にしないと、出た表が嘘になる。
#
# 出口: 0=全部緑 / 1=赤在り / 2=継ぎ目が壊れて測っていない
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 継ぎ目: `PC_TOOL` で測る対象を差し替えられる。変異版を差して「どの assertion が
# 何を掴んでいるか」を測る為に在る(上の表はこれで取った)。既定は本物。
TOOL="${PC_TOOL:-$ROOT/rc-backend/tools/port-coverage.py}"
[ -f "$TOOL" ] || { echo "★継ぎ目の台本が読めない: $TOOL"; exit 2; }

SANDBOX="$(mktemp -d /tmp/port-cov-ctl.XXXXXX)"
trap '/bin/rm -rf "$SANDBOX"' EXIT

# ★砂場は repo と同じ深さを持たせる。2026-08-05 に `run-controls-controls.sh` が
#   砂場直下に台本を置いていた所為で `../ios/tools/…` が /tmp 本体へ解決し、
#   誰も掃除しない残骸を4本残していた。相対 path を使う道具の砂場は、
#   本物と同じ形にしないと密閉にならない。
R="$SANDBOX/repo"
/bin/mkdir -p "$R/rc-backend/test" "$R/ios/Tests/Core"

pass=0; fail=0
chk() { # chk <説明> <期待> <実測>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok  $1"
    else fail=$((fail+1)); echo "NG  $1 -- 期待:$2 実測:$3"; fi
}

# 走らせる。$OUT に出力、$RC に終了コード。
# 既定では受理ゼロで走らせる(本物の受理表が砂場の判定に混ざらない様に)。
run() { # run <PC_PORTS> [tool]
    local tool="${2:-$TOOL}"
    OUT="$(PC_ROOT="$R" PC_JS="rc-backend/test/fixture.test.mjs" PC_PORTS="$1" \
           PC_ACCEPT="${PC_ACCEPT_OVERRIDE-}" python3 "$tool" 2>&1)"
    RC=$?
}

js() { cat > "$R/rc-backend/test/fixture.test.mjs"; }
sw() { cat > "$R/ios/Tests/Core/$1"; }

# --- P1/P2: 素直な当たりと外れ -----------------------------------------------
js <<'EOF'
import { f } from "../src/x.mjs";
test("f", () => {
  assert.equal(f(0), 150);
  assert.equal(f(50), 150);
});
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase {
    func testZero() { XCTAssertEqual(F.f(0), 150) }
    func testFifty() { XCTAssertEqual(F.f(50), 150) }
}
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P1 リテラルが全部在れば緑" 0 "$RC"

sw FTests.swift <<'EOF'
final class FTests: XCTestCase {
    func testZero() { XCTAssertEqual(F.f(0), 150) }
}
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P2a 移っていないリテラルが在れば赤" 1 "$RC"
chk "P2b その入力を名指しする" 1 \
    "$(printf '%s' "$OUT" | /usr/bin/grep -c 'f(50)')"

# --- P3: ★語境界。`12` を `120` の中に見つけて「在る」と言わない ---------------
js <<'EOF'
test("f", () => { assert.equal(f(12), 112); });
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase {
    func testOneTwenty() { XCTAssertEqual(F.f(120), 220) }
}
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P3 ★12 は 120 の中に在っても「移っている」ではない(偽の緑を塞ぐ)" 1 "$RC"

# --- P4: 数値の区切りの揺れ。JS `1_000_000` と Swift `1000000` は同じ物 --------
js <<'EOF'
test("f", () => { assert.equal(f(1_000_000), 1); });
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase {
    func testBig() { XCTAssertEqual(F.f(1000000), 1) }
}
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P4a 区切りの有無で取り違えない(JS 1_000_000 = Swift 1000000)" 0 "$RC"

js <<'EOF'
test("f", () => { assert.equal(f(2000000), 1); });
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase {
    func testBig() { XCTAssertEqual(F.f(2_000_000), 1) }
}
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P4b 逆向きも同じ(JS 2000000 = Swift 2_000_000)" 0 "$RC"

# --- P5: ★識別子は判定しない。両方向に壊れる事を実測した(道具の docstring 参照) -
js <<'EOF'
test("f", () => { const T = 1; assert.equal(f(T), 1); });
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase {
    func testWhatever() { let base = 1.0; XCTAssertEqual(F.f(base), 1) }
}
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P5a ★識別子は赤にしない(Swift が別名でも「移っていない」と言わない)" 0 "$RC"
chk "P5b ★識別子として数える(緑に丸めず分母に残す)" 1 \
    "$(printf '%s' "$OUT" | /usr/bin/grep -c 'ident 1')"

# --- P6/P7: 構造体と keyword も同じく判定しないが、数える --------------------
js <<'EOF'
test("f", () => {
  assert.equal(f({ items: [] }), 1);
  assert.equal(f(null), 2);
});
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase {
    func testNothing() {}
}
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P6a 構造体と keyword だけなら赤にしない" 0 "$RC"
chk "P6b 構造体として数える" 1 "$(printf '%s' "$OUT" | /usr/bin/grep -c 'struct 1')"
chk "P7  keyword として数える" 1 "$(printf '%s' "$OUT" | /usr/bin/grep -c 'keyword 1')"
chk "P6c 照合できるリテラルが 0 件だと明言する" 1 \
    "$(printf '%s' "$OUT" | /usr/bin/grep -c 'この道具では測れない')"

# --- P8/P9: ★測れない時は 2。0 にも 1 にも丸めない --------------------------
js <<'EOF'
test("f", () => { assert.equal(f(1), 1); });
EOF
/bin/rm -f "$R/ios/Tests/Core/FTests.swift"
run "f=ios/Tests/Core/FTests.swift"
chk "P8 ★Swift の検査 file が無いなら 2(緑にも赤にもしない)" 2 "$RC"

sw FTests.swift <<'EOF'
final class FTests: XCTestCase { func testNothing() {} }
EOF
run "nosuchfn=ios/Tests/Core/FTests.swift"
chk "P9 ★JS 側に呼び出しが無いなら 2" 2 "$RC"

# --- P10: 文字列リテラル ------------------------------------------------------
js <<'EOF'
test("f", () => { assert.equal(f("こわれた"), ""); });
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase {
    func testBroken() { XCTAssertEqual(F.f("こわれた"), "") }
}
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P10a 文字列リテラルは中身で照合して当たる" 0 "$RC"

sw FTests.swift <<'EOF'
final class FTests: XCTestCase { func testNothing() {} }
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P10b 文字列が移っていなければ赤" 1 "$RC"

# --- P11: 移植表に複数関数。1つでも赤なら全体が赤 ----------------------------
js <<'EOF'
test("両方", () => {
  assert.equal(f(7), 1);
  assert.equal(g(9), 2);
});
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase { func testSeven() { XCTAssertEqual(F.f(7), 1) } }
EOF
sw GTests.swift <<'EOF'
final class GTests: XCTestCase { func testNothing() {} }
EOF
run "f=ios/Tests/Core/FTests.swift;g=ios/Tests/Core/GTests.swift"
chk "P11a 片方だけ欠けても全体は赤" 1 "$RC"
chk "P11b 欠けている方だけを名指しする" 1 \
    "$(printf '%s' "$OUT" | /usr/bin/grep -c 'g(9)')"
chk "P11c 足りている方は名指ししない" 0 \
    "$(printf '%s' "$OUT" | /usr/bin/grep -c 'f(7)')"

# --- P13: ★逆向き。表に書き忘れた Swift の検査を disk 側から見つける -----------
# P8 が見るのは「表に書いた物が実在するか」。此処が見るのは逆で、
# 「実在するのに表に書き忘れた」= 訂正6-1 で実際に落ちた向き。
js <<'EOF'
test("f", () => { assert.equal(f(1), 1); });
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase { func testOne() { XCTAssertEqual(F.f(1), 1) } }
EOF
sw OrphanTests.swift <<'EOF'
// MARK: - fixture.test.mjs: "★表に無い移植"
final class OrphanTests: XCTestCase { func testNothing() {} }
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P13a ★表に無い Swift の検査が在れば 2(赤でも緑でもなく、測っていない)" 2 "$RC"
# 件数で測らない: この名前は「■ 測れない」の行と集計の一覧の**両方**に出るのが正しい。
# 数を固定すると出力の書式を触るたびに赤くなる = 何も守らない赤になる。
chk "P13b その file を名指しする" "在る" \
    "$(printf '%s' "$OUT" | /usr/bin/grep -q 'OrphanTests.swift' && echo 在る || echo 無い)"

# 陰性対照: 目印を持たない file は逆側から見えない(= P13 は目印を測っている)
sw OrphanTests.swift <<'EOF'
final class OrphanTests: XCTestCase { func testNothing() {} }
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P13c JS の検査を名指ししていなければ拾わない(騒がない側の証明)" 0 "$RC"
/bin/rm -f "$R/ios/Tests/Core/OrphanTests.swift"

# --- P14/P15: 受理した差し替え。**緑に丸めず、腐ったら赤にする** ---------------
# 「移していないが、それが正しい」事は在る。散文で片付けると計器が永久に赤くなり、
# 永久に赤い計器は読まれなくなる = 何も守らなくなる。だから理由付きで受理し、
# 受理そのものが古びたら赤にする。
js <<'EOF'
test("f", () => { assert.equal(f(480), 500); });
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase { func testCap() { XCTAssertEqual(F.f(450), 500) } }
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P14-prep 受理が無ければ、この入力は赤" 1 "$RC"

PC_ACCEPT_OVERRIDE='f:480=同じ栓を 450 で踏んでいる' run "f=ios/Tests/Core/FTests.swift"
chk "P14a 受理すれば赤にならない" 0 "$RC"
chk "P14b ★それでも件数と理由を出す(黙って緑にしない)" "在る" \
    "$(printf '%s' "$OUT" | /usr/bin/grep -q '受理した差し替え: f(480)' && echo 在る || echo 無い)"

# 受理した入力が Swift 側に現れたら、その受理はもう何も受理していない
sw FTests.swift <<'EOF'
final class FTests: XCTestCase { func testCap() { XCTAssertEqual(F.f(480), 500) } }
EOF
PC_ACCEPT_OVERRIDE='f:480=同じ栓を 450 で踏んでいる' run "f=ios/Tests/Core/FTests.swift"
chk "P15a ★当たらなくなった受理は赤(残っている事自体が偽の主張)" 1 "$RC"
chk "P15b 畳むべき受理を名指しする" "在る" \
    "$(printf '%s' "$OUT" | /usr/bin/grep -q '死んだ受理 f(480)' && echo 在る || echo 無い)"

# --- 陰性対照: 語境界を外した版が P3 を見逃す事を見せる -----------------------
# ★この対照が「何かを測っている」事の証明。素朴な部分一致へ戻すと P3 が黙る。
VARIANT="$SANDBOX/naive.py"
/bin/cp "$TOOL" "$VARIANT"
/usr/bin/sed -i '' 's|^        if re\.search(r"(?<!\[\\w\.\$\])" + re\.escape(f) + r"(?!\[\\w\.\$\])", swift_text):|        if f in swift_text:|' "$VARIANT"

if /usr/bin/grep -q '^        if f in swift_text:' "$VARIANT"; then
    chk "P12-prep 陰性対照の差し込みが当たっている" 0 0
    js <<'EOF'
test("f", () => { assert.equal(f(12), 112); });
EOF
    sw FTests.swift <<'EOF'
final class FTests: XCTestCase {
    func testOneTwenty() { XCTAssertEqual(F.f(120), 220) }
}
EOF
    run "f=ios/Tests/Core/FTests.swift" "$VARIANT"
    chk "P12 ★素朴な部分一致へ戻すと P3 は黙る(= P3 は語境界を測っている)" 0 "$RC"
else
    # ★当たらなかった赤は「道具が壊れた」ではなく「対照が変異を掛けそこねた」。
    #   誤診する赤は緑を装う赤より始末が悪いので、別建てで報告して 2 で降りる。
    echo "NG  P12-prep ★差し込みが当たっていない -- P12 は陰性対照になっていない"
    fail=$((fail+1))
fi

# --- P16-P20: ★疑いの網に「違う」と言う口(2026-08-07)-------------------------
# P13 は「表に無いのに名指ししている」を全部 2(測っていない)にする。だが名指しの中には
# **散文であちらの検査に触れているだけ**の物が在り、それは永久に 2 のまま消えない。
# 実測 2026-08-07: 出口は 0 から 2 に落ちたまま、誰も走らせていないので気付かれなかった。
# 永久に赤(此処では永久に未測定)の計器は読まれなくなる = 何も守らなくなる。
# ★だから口を足す。ただし P14/P15 の受理と同じ規律で: 理由を書かせ、件数で刷り、腐ったら赤。
js <<'EOF'
test("f", () => { assert.equal(f(1), 1); });
EOF
sw FTests.swift <<'EOF'
final class FTests: XCTestCase { func testOne() { XCTAssertEqual(F.f(1), 1) } }
EOF
sw NotAPortTests.swift <<'EOF'
// MARK: - fixture.test.mjs: あちらが見られない性質を測る
// not-a-port: あちらが見られない継ぎ目の側を測るので、対応する行は無い
final class NotAPortTests: XCTestCase { func testNothing() {} }
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P16a ★印が在れば未測定にしない(2 で貼り付かない)" 0 "$RC"
chk "P16b ★それでも件数と理由を刷る(黙って落とさない)" "在る" \
    "$(printf '%s' "$OUT" | /usr/bin/grep -q '印で外した検査: 1' && echo 在る || echo 無い)"

# ★陰性対照: 同じ file から**印だけ**外す。名前も置き場所も中身も変えていない。
sw NotAPortTests.swift <<'EOF'
// MARK: - fixture.test.mjs: あちらが見られない性質を測る
final class NotAPortTests: XCTestCase { func testNothing() {} }
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P17 ★陰性対照: 印が無ければ未測定に戻る(= P16 は印を測っている)" 2 "$RC"

# ★理由の無い口は、ただの黙らせ方。短い理由は受け付けず赤にする。
sw NotAPortTests.swift <<'EOF'
// MARK: - fixture.test.mjs: あちらが見られない性質を測る
// not-a-port: なし
final class NotAPortTests: XCTestCase { func testNothing() {} }
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P18 ★理由が短い印は赤(黙らせるだけの口を作らない)" 1 "$RC"

# ★印もまた腐る。名指しをやめた file に印だけ残ったら、それは偽の主張。
sw NotAPortTests.swift <<'EOF'
// not-a-port: あちらが見られない継ぎ目の側を測るので、対応する行は無い
final class NotAPortTests: XCTestCase { func testNothing() {} }
EOF
run "f=ios/Tests/Core/FTests.swift"
chk "P19 ★腐った印は赤(死んだ受理と同じ作法)" 1 "$RC"

# ★表と印の両方に在る = どちらが本当か出力から判らない。黙って通さない。
sw NotAPortTests.swift <<'EOF'
// MARK: - fixture.test.mjs: あちらが見られない性質を測る
// not-a-port: あちらが見られない継ぎ目の側を測るので、対応する行は無い
final class NotAPortTests: XCTestCase { func testNothing() {} }
EOF
# ★最初に書いた形は捨てた: 表に別の関数 g を足して其処へ置く案。g は JS 側に呼び出しが
#   無いので**それ自体が「測れない」を出し**、出口は 2 になる。狙った赤とは別の理由で
#   2 が出るので、この項は何も測っていなかった(実測 2026-08-07、期待1/実測2)。
#   既に在る関数の**2本目の移植先**として置けば、出口の理由は矛盾ひとつに絞れる。
run "f=ios/Tests/Core/FTests.swift,ios/Tests/Core/NotAPortTests.swift"
chk "P20a ★表にも印にも在れば赤(どちらか一方にさせる)" 1 "$RC"
chk "P20b ★その理由を名指しする(出口の数字だけで正しさを言わない)" "在る" \
    "$(printf '%s' "$OUT" | /usr/bin/grep -q '移植表に在るのに印も付いている' && echo 在る || echo 無い)"
/bin/rm -f "$R/ios/Tests/Core/NotAPortTests.swift"

echo
echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" -eq 0 ] || exit 1
exit 0
