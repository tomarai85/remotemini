#!/bin/bash
# controls-for: ios/tools/uitest-reachability-gate.sh
#
# `uitest-reachability-gate.sh` の負の対照。**門が本当に赤を出せるか**だけを測る。
#
# ★此の対照が要る理由は、門の最初の版が実際に嘘を吐いたから(2026-09-08)。
#   あの版は class 名を `grep -rqF` していて、註や `.harness/evidence-*` の中の
#   言及まで「到達可能」に数え、**27/27 緑**を返した —— 実際は 10 本しか走っていない。
#   結論(到達可能か)を grep する検査は、主張とその否定を区別できない。
#   だから此処では**通ってはいけない配置**を作って、門が其れを赤と呼ぶ事を毎回示す。
#
# 測る事(全部 砂場の作り木の上。本物の ios/ は1バイトも触らない):
#   C1 全部が走る形で名指しされていれば緑(rc=0)
#   C2 1 本が誰にも名指しされなければ赤(rc=1)で、**その名前を出す**
#   C3 ★class 名が**註の中にだけ**在る時は到達可能にしない(最初の版が踏んだ穴)
#   C4 ★名指しした台本が門に載っていなければ到達可能にしない
#      (「人が撃てば走る」は「門が走らせる」ではない)
#   C5 宣言(DECLARED)に載っていれば緑
#   C6 ★宣言の理由が短すぎる時は緑にせず**測定不成立**(rc=2)にする
#   C7 ★列挙が下限を割ったら緑にせず測定不成立(空の網を「違反 0 件」と読まない)
#
# 使い方: bash ios/tools/uitest-reachability-control.sh
# 終了コード: 0=全部緑 / 1=1本でも赤 / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/uitest-reachability-gate.sh"
[ -f "$GATE" ] || { echo "測る対象が無い: $GATE"; exit 2; }

pass=0; fail=0; unmeasured=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail+1)); }
un() { echo "UNMEASURED  $1"; unmeasured=$((unmeasured+1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# 門は自分の位置から `../UITests` と `../tools` と `../../rc-backend/...` を引く。
# 其の形の作り木を1つ組む。
# $1 = 木の名前 / 以降は組み立てに使う旗
build_tree() { # build_tree <name>
    local t="$SB/$1"
    mkdir -p "$t/ios/tools" "$t/ios/UITests" "$t/rc-backend/tools" "$t/rc-backend/test" "$t/.harness"
    cp "$GATE" "$t/ios/tools/gate.sh"
    : > "$t/rc-backend/tools/run-controls.sh"
    printf '%s' "$t"
}
mkclass() { # mkclass <木> <class 名>
    printf 'import XCTest\nfinal class %s: XCTestCase {}\n' "$2" > "$1/ios/UITests/$2.swift"
}
# 走る形で名指しする対照(門に載っている = controls-for: を持つ)
name_it() { # name_it <木> <class 名>
    { printf '#!/bin/bash\n# controls-for: ios/UITests/%s.swift\n' "$2"
      printf 'xcodebuild -only-testing:RemoteMiniUITests/%s test\n' "$2"
    } > "$1/ios/tools/$2-control.sh"
}
# ★`out="$(run_gate …)"` の形にすると、run_gate は**命令置換の subshell**で走るので
#   其の中で立てた `GRC` は親へ帰らない(最初に書いた版が `unbound variable` で落ちた)。
#   出力は file 経由で渡し、rc は関数の**戻り値**として返す —— 経路を1つにする。
GOUT="$SB/gate-out.txt"
run_gate() { # run_gate <木> [env...] -> rc を返す。出力は $GOUT
    local t="$1"; shift
    env "$@" RC_UITEST_FLOOR=1 bash "$t/ios/tools/gate.sh" > "$GOUT" 2>&1
}

# ── C1 全部到達可能なら緑 ─────────────────────────────────────────────────
T="$(build_tree c1)"
for c in AlphaUITests BetaUITests; do mkclass "$T" "$c"; name_it "$T" "$c"; done
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
[ "$GRC" = "0" ] && ok "C1 全部が走る形で名指しされていれば緑" \
                 || ng "C1" "rc=$GRC / $out"

# ── C2 1 本が孤児なら赤で、名前を出す ─────────────────────────────────────
T="$(build_tree c2)"
mkclass "$T" AlphaUITests; name_it "$T" AlphaUITests
mkclass "$T" OrphanUITests            # 誰も名指ししない
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
if [ "$GRC" = "1" ] && printf '%s' "$out" | grep -q "OrphanUITests"; then
    ok "C2 孤児が居れば赤(rc=1)で、その名前を出す"
else ng "C2" "rc=$GRC / 出力に OrphanUITests が無い: $out"; fi

# ── C3 ★註の中の言及は到達可能にしない(最初の版が踏んだ穴)───────────────
T="$(build_tree c3)"
mkclass "$T" AlphaUITests; name_it "$T" AlphaUITests
mkclass "$T" MentionedOnlyUITests
{ printf '#!/bin/bash\n# controls-for: ios/UITests/AlphaUITests.swift\n'
  printf '# 註: 昔は MentionedOnlyUITests も見ていた(今は見ていない)\n'
} > "$T/ios/tools/prose-control.sh"
printf '本文で MentionedOnlyUITests に言及するだけの証拠 file\n' > "$T/.harness/evidence.md"
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
if [ "$GRC" = "1" ] && printf '%s' "$out" | grep -q "MentionedOnlyUITests"; then
    ok "C3 ★名前が註に在るだけでは到達可能にしない(結論を grep しない)"
else ng "C3" "rc=$GRC / 註だけの言及を走ると読んだ: $out"; fi

# ── C4 ★門に載っていない台本の名指しは数えない ───────────────────────────
T="$(build_tree c4)"
mkclass "$T" AlphaUITests; name_it "$T" AlphaUITests
mkclass "$T" HandRunUITests
# 宣言(controls-for)を持たず、run-controls.sh にも載っていない = 人が撃つ物
printf '#!/bin/bash\nxcodebuild -only-testing:RemoteMiniUITests/HandRunUITests test\n' \
    > "$T/ios/tools/hand-check.sh"
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
if [ "$GRC" = "1" ] && printf '%s' "$out" | grep -q "HandRunUITests"; then
    ok "C4 ★人が撃つ台本の名指しは『門が走らせる』に数えない"
else ng "C4" "rc=$GRC / 門に載っていない台本を数えた: $out"; fi
# 陰性対照: 同じ台本を run-controls.sh に登録すれば緑になる(C4 が厳しすぎない事)
printf 'ios/tools/hand-check.sh\n' > "$T/rc-backend/tools/run-controls.sh"
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
[ "$GRC" = "0" ] && ok "C4b 登録すれば到達可能に変わる(判定が登録で動く)" \
                 || ng "C4b" "登録しても緑にならない: rc=$GRC / $out"

# ── C5/C6 宣言 ───────────────────────────────────────────────────────────
# 宣言は門の中の配列なので、写した門を書き換えて測る。
T="$(build_tree c5)"
mkclass "$T" AlphaUITests; name_it "$T" AlphaUITests
mkclass "$T" DeclaredUITests
/usr/bin/sed -i '' 's|^DECLARED=($|DECLARED=(\n  "DeclaredUITests\|実機を繋がないと走らない構造的な理由がここに入る"|' "$T/ios/tools/gate.sh"
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
[ "$GRC" = "0" ] && ok "C5 理由つきで宣言すれば緑" || ng "C5" "rc=$GRC / $out"

T="$(build_tree c6)"
mkclass "$T" AlphaUITests; name_it "$T" AlphaUITests
mkclass "$T" ShortUITests
/usr/bin/sed -i '' 's|^DECLARED=($|DECLARED=(\n  "ShortUITests\|短い"|' "$T/ios/tools/gate.sh"
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
if [ "$GRC" = "2" ]; then ok "C6 ★理由が短い宣言は緑にせず測定不成立(rc=2)"
else ng "C6" "rc=$GRC(2 が期待)= 中身の無い理由で免除された: $out"; fi

# ── C7 ★列挙が下限を割ったら測定不成立 ───────────────────────────────────
T="$(build_tree c7)"
mkclass "$T" AlphaUITests; name_it "$T" AlphaUITests
env RC_UITEST_FLOOR=99 bash "$T/ios/tools/gate.sh" > "$GOUT" 2>&1; GRC=$?
out="$(cat "$GOUT")"
if [ "$GRC" = "2" ]; then ok "C7 ★列挙が下限を割ったら緑にしない(空の網を違反 0 と読まない)"
else ng "C7" "rc=$GRC(2 が期待)= 数えられていないのに判定した: $out"; fi

# ── C8 ★腐った宣言(走るのに DECLARED にも載っている)は測定不成立 ──────────
# Codex 2026-09-09: DECLARED は放っておくと「走らせられない理由」から
# 「免除の一覧」へ変わる。到達可能になった日に宣言を消させる枝を撃つ。
T="$(build_tree c8)"
mkclass "$T" AlphaUITests; name_it "$T" AlphaUITests
mkclass "$T" BothUITests;  name_it "$T" BothUITests      # 走る
/usr/bin/sed -i '' 's|^DECLARED=($|DECLARED=(\n  "BothUITests\|走らせられない構造的な理由がここに入る"|' "$T/ios/tools/gate.sh"
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
if [ "$GRC" = "2" ] && printf '%s' "$out" | grep -q "BothUITests"; then
    ok "C8 ★走るのに宣言も持つ物は緑にせず止める(免除の一覧に変わらない)"
else ng "C8" "rc=$GRC(2 が期待)= 腐った宣言を素通しした: $out"; fi

# ── C9 ★列挙が 2 通りで食い違ったら測定不成立 ────────────────────────────
# 厳しい方の regex は行頭の `final class X` しか拾わない。`@MainActor final class` が
# 入った日に**黙って視界の外へ落ちる** —— 見えない class は「到達不能」ですらない。
T="$(build_tree c9)"
mkclass "$T" AlphaUITests; name_it "$T" AlphaUITests
printf 'import XCTest\n@MainActor final class HiddenUITests: XCTestCase {}\n' > "$T/ios/UITests/HiddenUITests.swift"
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
if [ "$GRC" = "2" ] && printf '%s' "$out" | grep -q "HiddenUITests"; then
    ok "C9 ★列挙が食い違ったら判定しない(取り零した名前も出す)"
else ng "C9" "rc=$GRC(2 が期待)= 見えない class が在るのに判定した: $out"; fi

# ── C10 ★登録の照合は basename ではなく path ────────────────────────────
# .harness 側の同名 file が literal を持ち、`run-controls.sh` は ios/tools 側の同名 file を
# 登録している配置。basename 一致だと無関係な方が「登録済み」に化ける。
T="$(build_tree c10)"
mkclass "$T" AlphaUITests; name_it "$T" AlphaUITests
mkclass "$T" DupUITests
printf '#!/bin/bash\nxcodebuild -only-testing:RemoteMiniUITests/DupUITests test\n' > "$T/.harness/dup.sh"
printf '../ios/tools/dup.sh\n' > "$T/rc-backend/tools/run-controls.sh"
run_gate "$T"; GRC=$?
out="$(cat "$GOUT")"
if [ "$GRC" = "1" ] && printf '%s' "$out" | grep -q "DupUITests"; then
    ok "C10 ★別 dir の同名 file を登録済みと読まない(照合は path)"
else ng "C10" "rc=$GRC(1 が期待)= basename 衝突で登録済みに化けた: $out"; fi

echo ""
echo "--- 合計: PASS $pass / FAIL $fail / UNMEASURED $unmeasured ---"
[ "$fail" -gt 0 ] && exit 1
[ "$unmeasured" -gt 0 ] && exit 2
exit 0
