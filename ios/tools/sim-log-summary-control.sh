#!/bin/bash
# controls-for: ios/tools/sim-log-summary.sh
# `xcodebuild test` の log の要約が、**測っていない run を緑と呼ばないか**を測る対照。
#
# ── なぜ要るか ────────────────────────────────────────────────────────
# この1行が Sprint の DoD の主要な証拠である。「build.sh --sim が失敗0件」と書く時、
# 人も agent もこの行を読む。だから壊れ方が「数字が違う」で済まない ——
# **1件も測っていない run が「失敗 0件」と名乗れる**のが最悪の形で、
# それは log を最後まで読まない限り緑と見分けが付かない。
#
# ★本番の xcodebuild は要らない。要約は log を読むだけの純粋な処理なので、
#   作り物の log で全分岐を測れる。測るのに数分掛かる造りだと、対照は書かれない。
#
# ── 測る7つ ──────────────────────────────────────────────────────────
#   ① bundle が2本(97 + 3)の log で **100** と出る   (= 旧版の `tail -1` は 3 と出した)
#   ② 失敗が在る log は 1(赤)で、5件中1件と出る   (+ XCTest の error 行をコンパイル error と混同しない)
#   ③ Test Case が1件も無く rc=0 の log は **2(未測定)**   (= 0件を緑と呼ばない)
#   ④ コンパイル error 在りの log は 2(未測定)   (= 「落ちた」と「測っていない」を混ぜない)
#   ⑤ rc≠0 なのに全件 passed の log は 1(赤)   (= テスト以外で落ちた run を緑にしない)
#   ⑥ log が実在しない時は 2(未測定)
#   ⑦ bundle が起動しなかった run(rc≠0・Test Case 0件・コンパイルは通っている)は 2(未測定)
#   ⑧ 印が**行の途中**に在る log でも数え落とさない、失敗の名前も出す (2026-08-05 追加)
#   ⑨ 始まったのに終わりを報告しない検査が在る run は 2(未測定)   (2026-08-05 追加)
#
# ── ⑧⑨ を足した理由(この対照が本物の欠陥を通していた)────────────────
# ①〜⑦ が全部緑のまま、本物の run で要約が **226件** と出た(log 自身は 230)。
# `xcodebuild` は OS の log を**改行を挟まずに**吐くので、`Test Case ... passed` の
# 印が行の途中に来る。要約が `^Test Case` と行頭で数えていて、その分を落としていた。
# 落とす数は flush の間合いで変わるので、**同じ木の同じ検査群が run ごとに
# 227 / 226 と違う数を名乗っていた**。
#
# ★対照が捕まえられなかった原因は綴りではなく**作り物の綺麗さ**に在る。
#   `mk_bundle` が吐く log は印が必ず行頭で、本物にしか無い形が一度も測られていなかった。
#   ⑧はその形を写す。⑨は同じ穴の隣(始まったのに結果を出さない検査は分母から消える)。
#
# ★①②が要る理由: ③④⑤⑦は「危ない時に止まるか」しか見ない。止まるだけの道具は
#   **常に 2 を返す壊れ方**で全部緑になる。①②が「正常な log では正しい数を出して 0/1 を返す」
#   を同時に測るので、両側は互いの錨になっている。
#
# ── 赤くなる事の実測(2026-08-05、`RC_SIMSUMMARY_TOOL` に壊した写しを差して測った)──
#   旧版の `tail -1` の論理:  ①③④⑤⑦ が赤 / ②⑥ が緑  (PASS 2 / FAIL 5)
#     ②が緑なのは正しい —— 旧版も**最後の bundle に失敗が在れば**それは報告できた。
#     旧版の欠陥は「数を取り違える」ではなく「**測っていない run を緑と呼ぶ**」方に在る。
#   常に 2 を返す道具:        ①②④⑤ が赤 / ③⑥⑦ が緑  (PASS 3 / FAIL 4)
#     ④が赤なのは、③⑦と違って**文面まで**照合しているから(未測定の理由を名指しする事も契約)。
#
# 終了コード: 0 = 全部期待どおり / 1 = どれかが違う / 2 = 測れなかった
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ★差し替えの口。証明の為に live の道具を sed -i で壊すと、復元に失敗した時
#   repo が壊れたまま残る(`rc-backend/test/wire-shape-controls.sh` と同じ作法)。
TOOL="${RC_SIMSUMMARY_TOOL:-$HERE/sim-log-summary.sh}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

[ -f "$TOOL" ] || { echo "測れない: 道具が居ない ($TOOL)"; exit 2; }

SCRATCH="$(mktemp -d /tmp/rc-simsummary.XXXXXX)" || exit 2
cleanup() {
    find "$SCRATCH" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$SCRATCH" -type d -depth -exec /bin/rmdir {} \; 2>/dev/null
}
trap cleanup EXIT

# ── 作り物の log ──────────────────────────────────────────────────────
# 本物と同じ形にする。特に `Test Suite ... Executed N tests` を **suite / .xctest /
# All tests の3階層**で繰り返す所まで写す —— あの行を足して数える実装が
# 二重・三重に数える事を、この対照が捕まえられる様にする為。
# ★行の順序を本物に合わせる。本物は「失敗した Test Case の行 → Test Suite failed →
#   Executed N tests, with M failure」の順で、要約行は**必ず後**に来る。
#   ここを崩すと、要約行を読む実装が「失敗0件」と読める作り物の log が出来てしまい、
#   対照が**狙いと違う理由で**赤くなる(2026-08-05 に実際に一度そうなった)。
# ★"1 failure" は単数。本物の xcodebuild が単複を出し分けるので、そこも写す。
mk_bundle() {   # $1=出力先 $2=bundle名 $3=成功件数 $4=失敗件数
    local out="$1" name="$2" np="$3" nf="$4" i total
    total=$((np + nf))
    echo "Test Suite 'All tests' started at 2026-08-05 08:00:00.000." >>"$out"
    echo "Test Suite '$name.xctest' started at 2026-08-05 08:00:00.000." >>"$out"
    for ((i=1; i<=np; i++)); do
        # ★`started` の行も写す。要約は「始まった数」と「終わった数」を突き合わせる
        #   ので、片方しか無い作り物ではその照合が一度も働かない(⑨が測る性質)。
        echo "Test Case '-[$name.SomeTests testOK$i]' started." >>"$out"
        echo "Test Case '-[$name.SomeTests testOK$i]' passed (0.001 seconds)." >>"$out"
    done
    for ((i=1; i<=nf; i++)); do
        echo "Test Case '-[$name.SomeTests testNG$i]' started." >>"$out"
        # ★行番号は printf の引数で入れる。作り物の log の中では本物と同じ形が要るが、
        #   **この台本の本文に file:行番号 の綴りを残さない**為
        #   (`test/no-linerefs.test.mjs` は全文を走査するので、作り物でも引用として数える。
        #    検査側に例外を彫るより、こちらが形を避ける方が安い —— 例外は repo 全体に効く)。
        printf '/path/to/%s.swift:%d: error: -[%s.SomeTests testNG%d] : XCTAssertEqual failed\n' \
            "$name" 42 "$name" "$i" >>"$out"
        echo "Test Case '-[$name.SomeTests testNG$i]' failed (0.002 seconds)." >>"$out"
    done
    if [ "$nf" -gt 0 ]; then
        echo "Test Suite '$name.xctest' failed at 2026-08-05 08:00:01.000." >>"$out"
        printf '\t Executed %d tests, with %d failure%s (0 unexpected) in 0.100 (0.100) seconds\n' \
            "$total" "$nf" "$([ "$nf" -eq 1 ] || echo s)" >>"$out"
        printf '\t Executed %d tests, with %d failure%s (0 unexpected) in 0.100 (0.100) seconds\n' \
            "$total" "$nf" "$([ "$nf" -eq 1 ] || echo s)" >>"$out"
    else
        echo "Test Suite '$name.xctest' passed at 2026-08-05 08:00:01.000." >>"$out"
        printf '\t Executed %d tests, with 0 failures (0 unexpected) in 0.100 (0.100) seconds\n' "$total" >>"$out"
        printf '\t Executed %d tests, with 0 failures (0 unexpected) in 0.100 (0.100) seconds\n' "$total" >>"$out"
    fi
}

TWO="$SCRATCH/two-bundles.log"; : >"$TWO"
mk_bundle "$TWO" "RemoteMiniTests" 97 0
mk_bundle "$TWO" "RemoteMiniUITests" 3 0

# ── ① 2 bundle で 100 と出る ─────────────────────────────────────────
out=$("$TOOL" "$TWO" 0 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "テスト 100件 実行 / 失敗 0件"; then
    ok "① bundle が2本でも合計 100 件と出る(rc=0)"
else
    ng "① bundle が2本でも合計 100 件と出る(rc=0)" "rc=$rc / 出力=$(printf '%s' "$out" | head -1)"
fi

# ── ② 失敗が在る log は 1(赤) ───────────────────────────────────────
# ★この log は同時にもう一つ測っている: XCTest の失敗行(`.swift` の後ろが**行番号だけ**で
#   列番号が付かない形)を、**コンパイル error と取り違えない**事。判別は列番号の有無
#   だけなので、正規表現を緩めた瞬間に「テストが1件落ちた」が「ビルドが通っていない」に化ける。
FAILLOG="$SCRATCH/has-failure.log"; : >"$FAILLOG"
mk_bundle "$FAILLOG" "RemoteMiniTests" 4 1
out=$("$TOOL" "$FAILLOG" 65 2>&1); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "テスト 5件 実行" && printf '%s' "$out" | grep -q "失敗 1件"; then
    ok "② 失敗が在れば 1(赤)で、5件中1件と出る(XCTest の error 行をコンパイル error と混同しない)"
else
    ng "② 失敗が在れば 1(赤)で、5件中1件と出る" "rc=$rc / 出力=$(printf '%s' "$out" | head -1)"
fi

# ── ③ Test Case が0件・rc=0 は 2(未測定) ───────────────────────────
# ★此処がこの対照の本丸。bundle が起動しなかった run は、最後の `Executed` 行だけ
#   見ると「失敗0件」に見える。0件を緑と呼ばない事を測る。
EMPTY="$SCRATCH/no-testcases.log"
{
    echo "Test Suite 'All tests' started at 2026-08-05 08:00:00.000."
    echo "Test Suite 'All tests' passed at 2026-08-05 08:00:00.001."
    printf '\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\n'
} >"$EMPTY"
out=$("$TOOL" "$EMPTY" 0 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
    ok "③ 1件も走っていない run は 2(未測定)= 緑と区別される"
else
    ng "③ 1件も走っていない run は 2(未測定)" "rc=$rc(緑か赤に紛れている)/ 出力=$(printf '%s' "$out" | head -1)"
fi

# ── ④ コンパイル error は 2(未測定) ─────────────────────────────────
CERR="$SCRATCH/compile-error.log"
{
    # 行番号・列番号は printf の引数で(上の mk_bundle と同じ理由)。
    printf "/path/to/Thing.swift:%d:%d: error: cannot find type 'Nope' in scope\n" 12 34
    echo "** TEST FAILED **"
} >"$CERR"
out=$("$TOOL" "$CERR" 65 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "1件も測っていない"; then
    ok "④ コンパイル error は 2(未測定)= 「テストが落ちた」と混ぜない"
else
    ng "④ コンパイル error は 2(未測定)" "rc=$rc / 出力=$(printf '%s' "$out" | head -1)"
fi

# ── ⑤ 全件 passed でも rc≠0 なら赤 ──────────────────────────────────
# bundle の起動失敗・シミュレータの死・後処理の失敗はテスト行に出ない。
out=$("$TOOL" "$TWO" 70 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then
    ok "⑤ 全件 passed でも xcodebuild が落ちていれば赤"
else
    ng "⑤ 全件 passed でも xcodebuild が落ちていれば赤" "rc=$rc = テスト以外の失敗を緑にしている"
fi

# ── ⑥ log が無ければ 2(未測定) ─────────────────────────────────────
out=$("$TOOL" "$SCRATCH/does-not-exist.log" 0 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
    ok "⑥ log が無ければ 2(未測定)"
else
    ng "⑥ log が無ければ 2(未測定)" "rc=$rc"
fi

# ── ⑦ bundle が起動しなかった run(rc≠0・Test Case 0件・コンパイルは通っている)──
# build.sh の頭に書いてある「単体 bundle が起動しなかった」の実物の形。
# コンパイルは通っているので④の道には落ちない。**赤(1)ではなく未測定(2)**が正しい:
# 「テストが落ちた」と報告すると、落ちたテストを探しに行く事になる。実際は0件走っている。
DIED="$SCRATCH/bundle-never-started.log"
{
    echo "** BUILD SUCCEEDED **"
    echo "2026-08-05 08:00:00.000 xcodebuild[1:1] Failed to load test bundle: simulator died"
    echo "** TEST FAILED **"
} >"$DIED"
out=$("$TOOL" "$DIED" 65 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
    ok "⑦ bundle が起動しなかった run は 2(未測定)= 「落ちたテストを探せ」と言わない"
else
    ng "⑦ bundle が起動しなかった run は 2(未測定)" "rc=$rc / 出力=$(printf '%s' "$out" | head -1)"
fi

# ── ⑧ 印が行の途中に在っても数え落とさない ───────────────────────────
# 本物の形をそのまま写す。`xcodebuild` は NSURLSession の診断を改行無しで吐くので、
# 次の Test Case の印が**同じ行の後ろに繋がる**。2026-08-05 実測の実物:
#   ...NSLocalizedDescripTest Case '-[...]' passed (0.001 seconds).
# ★passed 側だけでなく failed 側も測る。落ちた検査の印が飲まれると、
#   要約は「失敗0件」と数え、倒れた検査の名前を1つも出さない —— 変異検査では
#   それは「どの検査も捕まえなかった」= 殺した変異を生存と読む道になる。
INTER="$SCRATCH/interleaved.log"; : >"$INTER"
{
    echo "Test Suite 'All tests' started at 2026-08-05 08:00:00.000."
    echo "Test Suite 'RemoteMiniTests.xctest' started at 2026-08-05 08:00:00.000."
    echo "Test Case '-[RemoteMiniTests.SomeTests testClean]' started."
    echo "Test Case '-[RemoteMiniTests.SomeTests testClean]' passed (0.001 seconds)."
    echo "Test Case '-[RemoteMiniTests.SomeTests testSwallowedPass]' started."
    # 行頭は OS の log。印はその後ろに繋がっている(改行が無い)。
    printf '2026-08-05 08:00:00.100+0900 App[1:2] [Default] Task finished with error [-1003] "A server with the specified hostname could not be found."'
    echo "Test Case '-[RemoteMiniTests.SomeTests testSwallowedPass]' passed (0.002 seconds)."
    echo "Test Case '-[RemoteMiniTests.SomeTests testSwallowedFail]' started."
    printf '/path/to/Some.swift:%d: error: -[RemoteMiniTests.SomeTests testSwallowedFail] : XCTAssertEqual failed\n' 42
    printf '2026-08-05 08:00:00.200+0900 App[1:2] [Default] Task finished with error [-1003] "A server with the specified hostname could not be found."'
    echo "Test Case '-[RemoteMiniTests.SomeTests testSwallowedFail]' failed (0.003 seconds)."
    echo "Test Suite 'RemoteMiniTests.xctest' failed at 2026-08-05 08:00:01.000."
    printf '\t Executed 3 tests, with 1 failure (0 unexpected) in 0.100 (0.100) seconds\n'
} >>"$INTER"
out=$("$TOOL" "$INTER" 65 2>&1); rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -q "テスト 3件 実行" \
   && printf '%s' "$out" | grep -q "失敗 1件" \
   && printf '%s' "$out" | grep -q "testSwallowedFail"; then
    ok "⑧ 印が行の途中でも 3件/失敗1件と数え、倒れた検査の名前を出す"
else
    ng "⑧ 印が行の途中でも 3件/失敗1件と数え、倒れた検査の名前を出す" \
       "rc=$rc / 出力=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi

# ── ⑨ 始まったのに終わりを報告しない検査が在れば 2(未測定)──────────
# 消えた検査は**分母からも消える**ので、件数だけ見ていると気付けない。
# 「3件中3件成功」に見える run の実体が「4件始まって1件は結果不明」でも、
# 印を数えるだけの実装は緑を返す。
VANISH="$SCRATCH/vanished-test.log"; : >"$VANISH"
{
    echo "Test Suite 'All tests' started at 2026-08-05 08:00:00.000."
    echo "Test Case '-[RemoteMiniTests.SomeTests testA]' started."
    echo "Test Case '-[RemoteMiniTests.SomeTests testA]' passed (0.001 seconds)."
    echo "Test Case '-[RemoteMiniTests.SomeTests testB]' started."
    echo "Test Case '-[RemoteMiniTests.SomeTests testB]' passed (0.001 seconds)."
    echo "Test Case '-[RemoteMiniTests.SomeTests testCrashesMidway]' started."
    echo "Restarting after unexpected exit, crash, or test timeout"
} >>"$VANISH"
out=$("$TOOL" "$VANISH" 0 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "始まった 3件"; then
    ok "⑨ 始まったのに結果を出していない検査が在れば 2(未測定)"
else
    ng "⑨ 始まったのに結果を出していない検査が在れば 2(未測定)" \
       "rc=$rc / 出力=$(printf '%s' "$out" | head -1)"
fi

# ── ⑨' skip は「消えた」ではない ─────────────────────────────────────
# ⑨の突き合わせが `skipped` を数え損なうと、XCTSkip を1本入れた瞬間に
# **緑の run が未測定に化ける**。この木は今 XCTSkip を0本しか持たないので、
# 実物では踏めない ——「まだ踏んでいない地雷」を対照側で先に踏んでおく。
SKIPLOG="$SCRATCH/has-skip.log"; : >"$SKIPLOG"
{
    echo "Test Suite 'All tests' started at 2026-08-05 08:00:00.000."
    echo "Test Case '-[RemoteMiniTests.SomeTests testA]' started."
    echo "Test Case '-[RemoteMiniTests.SomeTests testA]' passed (0.001 seconds)."
    echo "Test Case '-[RemoteMiniTests.SomeTests testSkipped]' started."
    echo "Test Case '-[RemoteMiniTests.SomeTests testSkipped]' skipped (0.001 seconds)."
    printf '\t Executed 2 tests, with 0 failures (0 unexpected) in 0.100 (0.100) seconds\n'
} >>"$SKIPLOG"
out=$("$TOOL" "$SKIPLOG" 0 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "テスト 2件 実行"; then
    ok "⑨' skip した検査は「消えた」ではない(2件・緑)"
else
    ng "⑨' skip した検査は「消えた」ではない(2件・緑)" "rc=$rc / 出力=$(printf '%s' "$out" | head -1)"
fi

echo
echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
