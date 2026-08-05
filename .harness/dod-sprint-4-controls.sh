#!/bin/bash
# controls-for: .harness/dod-sprint-4.sh
# `dod-sprint-4.sh` の対照。**各行が本当に赤にも緑にもなる**事を確かめる。
#
# なぜ要るか(Sprint 3 の対照と同じ理由 + 今回の実例):
#   照合表は「全部緑」を出した瞬間から誰も疑わなくなる。しかも今回、本体の初回実行で
#   4 行目が赤になり、当たっていたのは実装ではなく「内部で Date() を読まない」と
#   **説明した doc 注釈**だった —— 判定の基準点の方が壊れていた。
#   だから 4 行目だけは3方向から撃つ: 本文の Date() は赤 / 注釈の Date() は緑 /
#   時刻を受ける宣言が消えたら赤。真ん中が無いと、私が踏んだ誤りを二度と検出できない。
#
# ★走らせ方の原則: 主作業木は**一切触らない**。scratch に複製し、複製だけを壊す。
#   加えて —— この対照は Generator が同じ木で ios/Tests と .harness/progress.md を
#   書き換えている最中にも走る。だから**現在の判定を前提にしない**。
#   各行の緑・赤は、写しの中で対照自身が組み立てる(基準の一式 log すら合成する)。
#   「今 8-b が赤だから赤を期待する」と書いた対照は、Generator が直した瞬間に嘘になる。
#
# 終了コード: 0=全対照が期待通り / 1=期待と違う物が在る / 2=測れなかった
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "$HARNESS/.." && pwd)"
SUBJECT="$HARNESS/dod-sprint-4.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dod-s4-controls.XXXXXX")"
PASS=0; FAIL=0; UNMEASURED=0

[ -f "$SUBJECT" ] || { echo "FAIL  対象が無い: dod-sprint-4.sh"; exit 2; }

# ★`rm -rf` は使わない(この環境の禁止事項)。file を消してから dir を深い順に畳む。
cleanup() {
    [ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ] || return 0
    find "$SCRATCH" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$SCRATCH" -type d -depth -exec /bin/rmdir {} + 2>/dev/null
}
trap cleanup EXIT

MET="$SCRATCH/ios/Sources/Core/UnreadableMeter.swift"
LOG="$SCRATCH/ios/build/xcodebuild-sim.log"
PG="$SCRATCH/.harness/progress.md"

# 汚れていない写しを作り直す。**基準の状態は全部ここで合成する**。
fresh() {
    cleanup
    mkdir -p "$SCRATCH/.harness/evidence-2026-08-05" "$SCRATCH/ios/build"
    cp "$SUBJECT" "$SCRATCH/.harness/dod-sprint-4.sh"
    # build/ は複製しない(Generator が今この瞬間そこへ書いている)。一式 log は下で合成する。
    rsync -a --exclude 'build/' --exclude 'DerivedData/' --exclude '.git/' \
        "$REAL_ROOT/ios/" "$SCRATCH/ios/" >/dev/null 2>&1 || true

    # 証跡 2 枚(中身は見ないので空で足りる)
    : > "$SCRATCH/.harness/evidence-2026-08-05/conversation-degraded.png"
    : > "$SCRATCH/.harness/evidence-2026-08-05/conversation-stalled.png"

    # ★一式 log は**写しの実数から合成する**。本物の log を持ち込むと、Generator が
    #   検査を1本足した瞬間に「log と disk が一致しない」で 1 行目が落ち、
    #   対照が自分の失敗ではない赤を報告する。
    local n
    n="$(grep -rhoE 'func test[A-Za-z0-9_]+' "$SCRATCH/ios/Tests" 2>/dev/null | grep -c .)"
    printf 'Test Suite passed\nExecuted %s tests, with 0 failures (0 unexpected)\n' "$n" > "$LOG"

    # 1-b 行が読む UI target 側も、同じ原則で**写しの実数から**合成する。
    # 本物の log を持ち込めば UI の検査名も一緒に来てしまい、写しの中で UI を
    # 消しても緑のままになる = 対照が自分の壊した物を見なくなる。
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        printf "Test Case '-[RemoteMiniUITests.RemoteMiniUITests %s]' passed\n" "$t" >> "$LOG"
    done < <(grep -rhoE 'func test[A-Za-z0-9_]+' "$SCRATCH/ios/UITests" 2>/dev/null | sed 's/func //' | sort -u)

    # 9 行目が読む progress.md も合成する(本物は Generator が書き換え中)。
    # 実在する検査名を1つだけ引用した、最小で正しい版。
    local real
    real="$(grep -rhoE 'func test[A-Za-z0-9_]+' "$SCRATCH/ios/Tests" 2>/dev/null \
            | sed 's/func //' | sort -u | head -1)"
    printf '# Sprint 4\n\n## Design decisions\n1. 引用の照合用: %s\n' "$real" > "$PG"

    # 8-b 行が読む入口3つ。**基準では緑**にしておき、赤は対照が作る。
    mkdir -p "$SCRATCH/ios/Tests/Core"
    printf '// entry-point anchor for the controls\n// handleForegroundResume retryPollingNow rereadNow\n' \
        > "$SCRATCH/ios/Tests/Core/ZZEntryAnchor.swift"
}

# verdict <行の番号> -- その行の判定(緑/赤/未測定)を返す
verdict() {
    # 既定は 0(重い行を回さない)。DOD_FULL=1 側の分岐を測る対照だけが CTL_FULL=1 にする。
    DOD_FULL="${CTL_FULL:-0}" bash "$SCRATCH/.harness/dod-sprint-4.sh" 2>/dev/null \
        | grep -E "^  (緑|赤|未測定) +$1\. " | awk '{print $1}' | head -1
}

# check <行の番号> <期待 緑|赤|未測定> <対照の名前>
check() {
    local row="$1" want="$2" name="$3" got
    got="$(verdict "$row")"
    if [ -z "$got" ]; then
        UNMEASURED=$((UNMEASURED+1)); printf '  未測定 [行%-3s] %s —— 判定行が出力に無い\n' "$row" "$name"
    elif [ "$got" = "$want" ]; then
        PASS=$((PASS+1));  printf '  緑    [行%-3s] %s(期待=%s 実測=%s)\n' "$row" "$name" "$want" "$got"
    else
        FAIL=$((FAIL+1));  printf '  赤    [行%-3s] %s(期待=%s 実測=%s)★対照が働いていない\n' "$row" "$name" "$want" "$got"
    fi
}

echo "=== dod-sprint-4.sh の対照 ==="
echo "  主作業木は触らない。写しの中で緑と赤を両方作って、判定が付いて来るかを見る。"
echo

# ── 前提: 基準の写しでは 1・2・2-b・3・4・6・8-b・9 が緑 ─────────────────────
fresh
for r in 1 1-b 2 2-b 3 4 8-b 9; do check "$r" 緑 "基準の写しでは緑"; done
# ★6 行目は**2 枚揃っていても未測定**が正しい。初版はここを緑と期待して対照が落ち、
#   落ちていたのは本体ではなく私の期待値だった。PNG が在る事は測れるが、
#   そこに段階1と段階2が写っているかは人の目でしか決まらない —— 存在を内容と読み替えない。
check 6 未測定 "証跡は2枚在っても未測定(存在は測れるが中身は目でしか測れない)"
check 5 未測定 "run-controls は既定で回さない(DOD_FULL=0)"
check 7 未測定 "実機の行は自動では緑にならない"
check 8 未測定 "実機の行は自動では緑にならない"

# ── 1 行目 ────────────────────────────────────────────────────────────────
fresh; printf 'Executed 9 tests, with 3 failures\n' >> "$LOG"
check 1 赤 "★log に失敗を含む Executed 行が在れば赤"

fresh; : > "$LOG"; printf 'Executed 12 tests, with 0 failures\n' > "$LOG"
check 1 赤 "★件数が Sprint 3 の 150 を超えなければ赤"

fresh; /bin/rm -f "$LOG"
check 1 未測定 "log が無ければ未測定(緑にも赤にも丸めない)"

fresh; printf 'Executed 999 tests, with 0 failures\n' > "$LOG"
check 1 未測定 "★log と disk の実数がズレたら未測定(どちらが正かは決められない)"

# ── DOD_FULL=1 の道(2026-08-05 に足した)────────────────────────────────────
# ★此処は**既存 31 件が1件も踏んでいなかった**枝である。対照は全部 DOD_FULL=0 で
#   回していたので、`build.sh --sim` を実際に呼ぶ側の分岐は無検査だった。
#   `sim-log-summary.sh` に 2(測っていない)を足した日に気付いた —— 足した終了コードを
#   受ける側が、それを赤に丸めていても誰も判らない状態だった。
# 本物の `build.sh` は数分掛かるので、写しの中の物を**終了コードだけ返す物**に
# 差し替える。測りたいのは「終了コードの写り方」であって build ではない。
stub_build() {   # $1 = 返させる終了コード
    mkdir -p "$SCRATCH/ios/tools"
    printf '#!/bin/bash\necho "==> 作り物: 終了コード %s を返す"\nexit %s\n' "$1" "$1" \
        > "$SCRATCH/ios/tools/build.sh"
}
# 5 行目は $SCRATCH に rc-backend が居ないので `cd` が落ちて即座に赤になる。
# 重くならないし、此処で見ているのは 1 行目だけなので影響しない。
# ★`VAR=1 check ...` の形は使わない。bash では**関数**への前置き代入は呼び出し後も
#   残るので、次の対照へ静かに漏れる。明示的に立てて明示的に落とす。
CTL_FULL=1
fresh; stub_build 0
check 1 緑 "--sim が 0 なら 1 行目は log の判定に進む"

fresh; stub_build 1
check 1 赤 "--sim が 1(赤)なら赤"

fresh; stub_build 2
check 1 未測定 "★--sim が 2(測っていない)を赤に丸めない —— これが直した所"
CTL_FULL=0

# ── 1-b 行目(UI target)────────────────────────────────────────────────────
# この行を足した理由は「1 行目が ios/Tests しか見ておらず、UI の検査を全部消しても
# 緑のままだった」。だから対照の本命は**消して赤になる**事と、**件数では緑にならない**事。
fresh
UIN="$(grep -rhoE 'func test[A-Za-z0-9_]+' "$SCRATCH/ios/UITests" 2>/dev/null | sed 's/func //' | sort -u | head -1)"
if [ -n "$UIN" ]; then
    grep -v "$UIN" "$LOG" > "$LOG.tmp" && /bin/mv "$LOG.tmp" "$LOG"
    check 1-b 赤 "★UI の検査が1本でも同じ log に通っていなければ赤"
else
    UNMEASURED=$((UNMEASURED+1)); echo "  未測定 [行1-b] UITests に検査が無い —— 対照の前提が壊れている"
fi

# ★★件数が合っていても名前が違えば赤。1-b を件数で書いていたら、log 中の
#   別 class の「Executed 3 tests」に当たって偽の緑になる —— 4 行目で踏んだ
#   「当たってはいるが当たっている相手が違う」と同じ型を、先に潰しておく。
fresh
n_ui="$(grep -rhoE 'func test[A-Za-z0-9_]+' "$SCRATCH/ios/UITests" 2>/dev/null | grep -c . || true)"
grep -v "Test Case " "$LOG" > "$LOG.tmp" && /bin/mv "$LOG.tmp" "$LOG"
printf 'Executed %s tests, with 0 failures (0 unexpected)\n' "$n_ui" >> "$LOG"
for i in $(seq 1 "$n_ui"); do
    printf "Test Case '-[SomeOtherSuite.SomeOtherSuite testUnrelatedName%s]' passed\n" "$i" >> "$LOG"
done
check 1-b 赤 "★★件数だけ合った log では緑にしない(名前で照合している事の証明)"

fresh
find "$SCRATCH/ios/UITests" -type f -name '*.swift' -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
check 1-b 赤 "★UI target が空になったら赤(既定の緑ではない)"

# ── 2 / 2-b 行目 ──────────────────────────────────────────────────────────
fresh
F="$(grep -rl 'testScreenFieldIsANestedObjectNotABareStringNegativeControl' "$SCRATCH/ios/Tests" 2>/dev/null | head -1)"
if [ -n "$F" ]; then
    sed -i '' 's/testScreenFieldIsANestedObjectNotABareStringNegativeControl/testRenamedAway/' "$F"
    check 2 赤 "★N4 の検査が消えたら赤(7 本の実在を数えている)"
else
    UNMEASURED=$((UNMEASURED+1)); echo "  未測定 [行2  ] N4 の検査が写しに無い —— 対照の前提が壊れている"
fi

fresh; printf '\n// MUTATION-N3 planted\n' >> "$SCRATCH/ios/Sources/Core/PollModels.swift"
check 2-b 赤 "★変異の印を戻し忘れたら赤(緑の一式が嘘になる)"

# ── 3 行目 ────────────────────────────────────────────────────────────────
fresh
F="$(grep -rl 'testPollRequestDoesNotFollowA302RedirectAndReturnsUnreachable' "$SCRATCH/ios/Tests" 2>/dev/null | head -1)"
if [ -n "$F" ]; then
    sed -i '' 's/testPollRequestDoesNotFollowA302RedirectAndReturnsUnreachable/testGone/' "$F"
    check 3 赤 "★10 分岐の1つ(302 に追随しない)が消えたら赤"
else
    UNMEASURED=$((UNMEASURED+1)); echo "  未測定 [行3  ] 302 の検査が写しに無い —— 対照の前提が壊れている"
fi

# ── 4 行目: **3方向から撃つ** ─────────────────────────────────────────────
# (a) 本文で現在時刻を読み始めたら赤
fresh; printf '\nlet leaked = Date()\n' >> "$MET"
check 4 赤 "★計器が本文で Date() を読み始めたら赤"

# (b) ★注釈の中の Date() では赤くならない —— 私が実際に踏んだ誤判定そのもの。
#     ここが緑でなければ、判定は実装ではなく説明文を測っている。
fresh; printf '\n/// 注釈の中で Date() に言及しても実装ではない\n' >> "$MET"
check 4 緑 "★★注釈の中の Date() は赤にしない(初版はここで偽の赤を出した)"

# (c) 時刻を引数で受ける宣言が消えたら赤(注釈剥がしだけでは計器の消失を見逃す)
fresh; sed -i '' 's/func stage(now: Date)/func stage()/' "$MET"
check 4 赤 "★時刻を受け取る宣言が消えたら赤(注釈剥がしだけでは足りない)"

# ── 6 行目 ────────────────────────────────────────────────────────────────
fresh; /bin/rm -f "$SCRATCH/.harness/evidence-2026-08-05/conversation-stalled.png"
check 6 赤 "★段階2 の証跡が欠けたら赤"

# ── 8-b 行目: 入口が検査から呼ばれているか ────────────────────────────────
fresh; /bin/rm -f "$SCRATCH/ios/Tests/Core/ZZEntryAnchor.swift"
F="$(grep -rl 'handleForegroundResume\|retryPollingNow\|rereadNow' "$SCRATCH/ios/Tests" 2>/dev/null)"
[ -n "$F" ] && printf '%s\n' "$F" | while read -r f; do
    sed -i '' 's/handleForegroundResume/xxRemovedA/g; s/retryPollingNow/xxRemovedB/g; s/rereadNow/xxRemovedC/g' "$f"
done
check 8-b 赤 "★前景復帰・手動再取得の入口を誰も呼ばなくなったら赤"

fresh
printf '// handleForegroundResume retryPollingNow rereadNow\n' > "$SCRATCH/ios/Tests/Core/ZZEntryAnchor.swift"
check 8-b 緑 "3 つとも呼ばれていれば緑"

# ── 9 行目: 引用の実在照合 ────────────────────────────────────────────────
fresh; printf '2. 実在しない引用: testThisNameDoesNotExistAnywhere\n' >> "$PG"
check 9 赤 "★★実在しない検査名を引いたら赤(名前だけ足した表を捕まえる)"

fresh; printf '# Sprint 4\n(節が無い)\n' > "$PG"
check 9 赤 "Design decisions の節が無ければ赤"

fresh; /bin/rm -f "$PG"
check 9 赤 "progress.md が無ければ赤"

echo
echo "=== 集計: 緑=$PASS 赤=$FAIL 未測定=$UNMEASURED ==="
echo "DOD-SPRINT-4-CONTROLS: pass=$PASS fail=$FAIL unmeasured=$UNMEASURED"
[ "$FAIL" -eq 0 ] || exit 1
[ "$UNMEASURED" -eq 0 ] || exit 2
exit 0
