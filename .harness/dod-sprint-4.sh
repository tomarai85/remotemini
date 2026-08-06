#!/bin/bash
# no-operator: sprint 4 を締める時に人が撃つ。門から回すと 1 commit ごとに実機と本番を叩く
# Sprint 4 の Definition of Done(ブリーフ §7、9 行)を機械で照合する。
#
# ★この道具が証明する事と、しない事
#   証明する: 「その検査が**在る**」「主張された数が**実測と合う**」「一式が**緑**」。
#   証明しない: 「その検査が本当に欠陥を捕まえる」。名前だけ一致した空の検査は緑になる。
#   後者を測るのは §5-a の負の対照(植える→赤→戻す→緑)であって、この道具ではない。
#   —— 存在の検査を「検証済み」と読み替えないために、報告にこの区別を刷る。
#
# ★Sprint 3 の照合表から持ち越した規律: 引用された名前は**実在を照合する**。
#   Sprint 4 の初回照合で、進捗が名指しした Swift の検査名 18 種のうち 1 種が
#   実在しなかった(接尾辞 NegativeControl 付きの名前を2箇所で引いていた)。
#   実体の検査は在るので中身は満たしているが、grep で辿れない引用は腐りの初期段階である。
#
# 終了コード(repo 共通): 0=緑 / 1=赤 / 2=測っていない。2 を 0 に丸めない。
# 人手(Tom の実機)が要る行は自動で 未測定 に落ちる。緑に見せかけない事が目的。
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HARNESS/.." && pwd)"
IOS="$ROOT/ios"
TESTS="$IOS/Tests"
SRC="$IOS/Sources"
GREEN=0; RED=0; UNMEASURED=0
FULL=${DOD_FULL:-0}   # DOD_FULL=1 で重い行(単体一式 / run-controls)も実際に回す

row() {  # row <pass|fail|skip> <行の名前> <根拠>
    case "$1" in
        pass) GREEN=$((GREEN+1));      printf '  緑    %s\n        %s\n' "$2" "$3" ;;
        fail) RED=$((RED+1));          printf '  赤    %s\n        %s\n' "$2" "$3" ;;
        *)    UNMEASURED=$((UNMEASURED+1)); printf '  未測定 %s\n        %s\n' "$2" "$3" ;;
    esac
}

# 検査名が ios/Tests に実在するか(接尾辞違いを拾う為、完全一致で見る)
have_test() { grep -rqE "func $1\(" "$TESTS" 2>/dev/null; }

# 名前の一覧(一度だけ作る)
ALL_TESTS="$(grep -rhoE 'func test[A-Za-z0-9_]+' "$TESTS" 2>/dev/null | sed 's/func //' | sort -u)"
N_TESTS="$(grep -rhoE 'func test[A-Za-z0-9_]+' "$TESTS" 2>/dev/null | grep -c .)"

echo "=== Sprint 4 DoD 照合 ($(date '+%Y-%m-%d %H:%M:%S')) ==="
echo "  (在る事の照合。効く事の照合は §5-a の植える→赤→戻す→緑 が担う)"
echo

# --- 1. 単体一式が緑で、件数が Sprint 3 の 150 を超える ----------------------
SIMLOG="$IOS/build/xcodebuild-sim.log"
if [ "$FULL" = 1 ]; then
    out=$(bash "$IOS/tools/build.sh" --sim 2>&1); simrc=$?
    # 2 = **測っていない**(印が1件も無い / 始まった数と終わった数が合わない)。
    # 1 = 赤。この2つを同じ行に丸めると、DoD の合計が「未測定を緑に丸めない」と
    # 名乗りながら**未測定を赤に丸める**事になり、合計の3分類が意味を失う。
    case "$simrc" in
        0) : ;;
        2) row skip "1. 単体一式" "build.sh --sim が 2 = 測っていない。末尾: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
        *) row fail "1. 単体一式" "build.sh --sim 非ゼロ($simrc)。末尾: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
    esac
fi
if [ -f "$SIMLOG" ]; then
    # 最大の Executed 行 = 一式の総数(class 単位の行も同じ形で出るので最大を取る)
    logmax="$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$SIMLOG" \
              | awk '{print $2}' | sort -n | tail -1)"
    # ★失敗数は $NF ではなく $(NF-1)。抜き出した文字列の最終語は "failures" という
    #   **語**なので、$NF+0 は常に 0 —— 失敗を含む log でも「失敗 0」と読んでしまう。
    #   初版はそう書いていて、対照(1 行目・失敗を含む log)が捕まえた。
    logfail="$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$SIMLOG" \
              | awk '$(NF-1)+0 > 0' | grep -c .)"
    logmax=${logmax:-0}
    if [ "$logfail" -ne 0 ]; then
        row fail "1. 単体一式" "log に失敗を含む Executed 行が $logfail 本"
    elif [ "$logmax" -le 150 ]; then
        row fail "1. 単体一式" "log の最大件数 $logmax = Sprint 3 の 150 を超えていない"
    elif [ "$logmax" -ne "$N_TESTS" ]; then
        # ★log と disk がズレたら緑にしない。どちらが正かをこの道具は決められない。
        row skip "1. 単体一式" "log $logmax 件 / disk の func test $N_TESTS 件 = **一致しない**。log が古いか、走らない検査が在る"
    else
        row pass "1. 単体一式" "log $logmax 件 / 失敗 0 / disk と一致。Sprint 3 の 150 を超えている"
    fi
else
    row skip "1. 単体一式" "$SIMLOG が無い(DOD_FULL=1 で回すと作られる)"
fi

# --- 1-b. UI target(ios/UITests)も同じ実行で走ったか ------------------------
# ★1 行目は `ios/Tests` しか見ていない。UI の検査は**別 target**で、消しても
#   1 行目は緑のまま —— 今夜の他の欠陥と同じ「静かに範囲外」の形。
# ★件数では照合しない。UI は 3 本で、log には class 単位の「Executed 3 tests」が
#   幾つも出るので、数だけ見ると別 class の 3 に当たって偽の緑になる。
#   名前で照合する = 当たる相手が一意に決まる。
UITESTS="$IOS/UITests"
if [ ! -d "$UITESTS" ]; then
    row skip "1-b. UI target" "$UITESTS が無い"
elif [ ! -f "$SIMLOG" ]; then
    row skip "1-b. UI target" "log が無い(DOD_FULL=1 で作られる)"
else
    ui_names="$(grep -rhoE 'func test[A-Za-z0-9_]+' "$UITESTS" 2>/dev/null | sed 's/func //' | sort -u)"
    ui_total="$(printf '%s' "$ui_names" | grep -c . || true)"
    ui_missing=""
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        grep -qE "Test Case '-\[[A-Za-z0-9_.]+ $t\]' passed" "$SIMLOG" \
            || ui_missing="$ui_missing $t"
    done <<< "$ui_names"
    if [ "$ui_total" -eq 0 ]; then
        row fail "1-b. UI target" "$UITESTS に検査が1本も無い(target が空になっている)"
    elif [ -n "$ui_missing" ]; then
        row fail "1-b. UI target" "同じ log で通ったと言えない検査:$ui_missing"
    else
        row pass "1-b. UI target" "$ui_total 本、全部が同じ log に passed として名前で在る"
    fi
fi

# --- 2. §5-a の負の対照 7 本が在り、名前が実在する --------------------------
# 表の右列 = ブリーフが「何が壊れたら赤くなるべきか」と書いた主題。
declare -a NCTL=(
    "N1 計器を1本に畳む改変|testRepeatedUnreadableResponsesNeverClimbTheLocalBackoffLadderNegativeControl"
    "N2 notice を非 optional|testTailAttachedNullNoticeWouldThrowUnderANonOptionalNoticeNegativeControl"
    "N3 根の display を非 optional|testWorkerRouteWouldFailToDecodeUnderANonOptionalRootDisplayNegativeControl"
    "N4 screen を文字列比較|testScreenFieldIsANestedObjectNotABareStringNegativeControl"
    "N5 screen:null を上書き扱い|testNullScreenAndChoiceHoldOverThePreviousValueRatherThanClearingItNegativeControl"
    "N6 読めない応答で cursor が進む|testUnreadableLeavesCursorUntouchedAndInventsNoLocalBackoff"
    "N7 自動取り直しの1回上限を外す|testAutoResyncFiresAtMostOnceUntilAReadableResponseEndsTheEpisodeNegativeControl"
)
miss_n=""
for e in "${NCTL[@]}"; do
    have_test "${e#*|}" || miss_n="$miss_n ${e%%|*}"
done
if [ -z "$miss_n" ]; then
    row pass "2. §5-a 負の対照 7 本" "7/7 実在。植える→赤→戻す→緑 の記録は progress.md 側(この道具は在る事だけを見る)"
else
    row fail "2. §5-a 負の対照 7 本" "対応する検査が無い:$miss_n"
fi

# 2-b. 変異の跡が残っていないか(戻し忘れは**赤**。緑の一式が嘘になる)
resid="$(grep -rn 'MUTATION-TEST\|MUTATION-N' "$SRC" "$TESTS" 2>/dev/null | grep -c .)"
if [ "$resid" -eq 0 ]; then
    row pass "2-b. 変異の跡ゼロ" "ios/Sources + ios/Tests に MUTATION 印 0 件"
else
    row fail "2-b. 変異の跡ゼロ" "$resid 件残っている = 一式の緑が信用できない"
fi

# --- 3. §5-b の 10 分岐が在る -----------------------------------------------
declare -a B10=(
    "1 正常|testNormalRoundTripAdvancesCursorAndReturnsTheReadableResponse"
    "2 more:true の即時再poll|testMoreTrueRequestsImmediateRepollAndTheSecondRequestActuallyCarriesWaitZero"
    "3 screen のみ変化|testScreenOnlyChangeUpdatesScreenWithoutTouchingChoiceViewOrLive"
    "4 readablePoll 偽|testStatus200RejectedByReadablePollCheckIsUnreadable"
    "5 gap(notice あり)|testGapWithNoticeDrawsTheNoticeAndAlwaysTriggersARefetch"
    "6 gap(notice null / tail-attached)|testGapWithNullNoticeTailAttachedDoesNotDrawButStillRefetches"
    "7 gap と message の同居|testGapAndMessageInTheSameResponseAreBothProcessed"
    "8 worker 経路|testWorkerRouteShapedBodyDecodesCleanlyThroughTheFullClient"
    "9 401|testUnauthorizedStepStopsTheDriveLoopAndInvokesTheCallback"
    "10 302 に追随しない|testPollRequestDoesNotFollowA302RedirectAndReturnsUnreachable"
)
miss_b=""
for e in "${B10[@]}"; do
    have_test "${e#*|}" || miss_b="$miss_b [${e%%|*}]"
done
if [ -z "$miss_b" ]; then
    row pass "3. §5-b 10 分岐" "10/10 実在"
else
    row fail "3. §5-b 10 分岐" "無い分岐:$miss_b"
fi

# --- 4. §5-c の段階遷移 ------------------------------------------------------
declare -a C6=(
    "段階0(初期)|testFreshMeterIsNormal"
    "段階1(1-2回)|testOneOrTwoUnreadableMarksWithinTenSecondsIsDegraded"
    "段階2(3連続)|testThirdConsecutiveUnreadableMarkEscalatesToStalledEvenAtZeroElapsed"
    "段階2(10秒経過)|testStreakStuckAtOneEscalatesToStalledOnceTenSecondsHavePassed"
    "読めた1回で0復帰|testMarkReadableResetsStreakToZeroAndUpdatesLastReadableAt"
    "cursor 不変|testUnreadableLeavesCursorUntouchedAndInventsNoLocalBackoff"
    "自動取り直しは1回だけ|testAutoResyncFiresAtMostOnceUntilAReadableResponseEndsTheEpisodeNegativeControl"
)
miss_c=""
for e in "${C6[@]}"; do
    have_test "${e#*|}" || miss_c="$miss_c [${e%%|*}]"
done
# ★時刻が注入されているか = 10 秒の検査が書ける形になっているか。
#   UnreadableMeter が内部で現在時刻を読んでいたら、上の「10秒経過」は書けない。
#
# ★初版はここで `grep -q 'Date()'` と書き、**この行が赤くなった**。当たっていたのは
#   実装ではなく「`Date()` を内部で読まない」と説明した doc 注釈である。
#   実装は正しく、判定の基準点の方が壊れていた —— 落ちたら形でなく基準を疑う、の実例。
#   直し方は2つ重ねる: (a) 注釈を落としてから探す(負の形)、
#   (b) **時刻を引数で受ける宣言が在る事**を要求する(正の形)。
#   (b) が要る理由: 注釈剥がしだけでは「計器そのものが消えた」時にも緑になる。
METER="$SRC/Core/UnreadableMeter.swift"
inject=""
if [ ! -f "$METER" ]; then
    inject="UnreadableMeter.swift が無い"
else
    # 行頭コメントを丸ごと落とし、行末コメントも落としてから探す
    body="$(grep -v '^[[:space:]]*//' "$METER" | sed 's://.*::')"
    if printf '%s' "$body" | grep -q 'Date()'; then
        inject="計器が本文で Date() を読んでいる = 時刻が注入されていない"
    elif ! grep -qE 'func stage\(now: Date\)' "$METER" \
      || ! grep -qE 'func markReadable\(now: Date\)' "$METER"; then
        inject="時刻を引数で受ける宣言(stage(now:) / markReadable(now:))が見当たらない"
    fi
fi
if [ -z "$miss_c" ] && [ -z "$inject" ]; then
    row pass "4. §5-c 段階遷移" "7/7 実在。計器は時刻を引数で受ける(内部で Date() を読まない)"
elif [ -n "$miss_c" ]; then
    row fail "4. §5-c 段階遷移" "無い遷移:$miss_c $inject"
else
    row fail "4. §5-c 段階遷移" "$inject"
fi

# --- 5. run-controls.sh が前景で緑 ------------------------------------------
if [ "$FULL" = 1 ]; then
    if out=$(cd "$ROOT/rc-backend" && bash tools/run-controls.sh 2>&1); then
        row pass "5. run-controls" "$(printf '%s' "$out" | tail -1)"
    else
        row fail "5. run-controls" "$(printf '%s' "$out" | grep -E '合計|red|未測定' | tail -2 | tr '\n' ' ')"
    fi
else
    row skip "5. run-controls" "重い(実測 5〜10 分)ので既定では回さない。DOD_FULL=1 で実測する"
fi

# --- 6. Simulator の証跡 2 枚 ------------------------------------------------
deg="$HARNESS/evidence-2026-08-05/conversation-degraded.png"
sta="$HARNESS/evidence-2026-08-05/conversation-stalled.png"
if [ -f "$deg" ] && [ -f "$sta" ]; then
    row skip "6. Simulator 証跡" "2 枚在る(段階1 / 段階2)。**何が写っているかは目で見るしかない**ので内容は未測定"
else
    row fail "6. Simulator 証跡" "段階1 / 段階2 の PNG が揃っていない"
fi

# --- 7. 実機で kind:"message" を観測 ----------------------------------------
row skip '7. 実機で message を観測' 'Tom の実機が要る。devicectl の console を grep する行'

# --- 8. 実機 N4(背景→前景で history refetched)------------------------------
row skip '8. 実機 N4(背景→前景)' 'Tom の実機が要る'

# --- 8-b. ★前景復帰の入口に**机の上で**触れる検査が在るか --------------------
# ブリーフ §1-a 5 は「背景→前景の復帰」を**作る物**に挙げている。DoD 8 は実機だが、
# 入口(handleForegroundResume / 再試行 / 読み直す)は机の上で叩ける。
# 実測 2026-08-05: 3 つとも ios/Tests から一度も呼ばれていない。
entry_miss=""
for m in handleForegroundResume retryPollingNow rereadNow; do
    grep -rq "$m" "$TESTS" 2>/dev/null || entry_miss="$entry_miss $m"
done
if [ -z "$entry_miss" ]; then
    row pass "8-b. 復帰・手動再取得の入口" "3 つとも検査から叩かれている"
else
    row fail "8-b. 復帰・手動再取得の入口" "検査が一度も呼ばない入口:$entry_miss(実装は在るが、机の上で守られていない)"
fi

# --- 9. progress.md に決定・除外・発見が在る --------------------------------
PG="$HARNESS/progress.md"
if [ -f "$PG" ] && grep -q 'Design decisions' "$PG" && grep -qE 'Sprint 4' "$PG"; then
    # ★引用の実在照合。名前だけ足して中身が無い表を、この行で捕まえる。
    cited="$(grep -oE '\btest[A-Z][A-Za-z0-9_]+' "$PG" | sort -u)"
    ncit="$(printf '%s\n' "$cited" | grep -c .)"
    ghost="$(comm -23 <(printf '%s\n' "$cited") <(printf '%s\n' "$ALL_TESTS") | grep . || true)"
    nghost="$(printf '%s\n' "$ghost" | grep -c . || true)"
    if [ "${nghost:-0}" -eq 0 ]; then
        row pass "9. progress.md" "決定・除外・発見が在る。名指しした検査 $ncit 種は全部実在する"
    else
        row fail "9. progress.md" "名指しした $ncit 種のうち $nghost 種が実在しない: $(printf '%s' "$ghost" | tr '\n' ' ')"
    fi
else
    row fail "9. progress.md" "Sprint 4 の節 / Design decisions が無い"
fi

echo
echo "=== 合計: 緑 $GREEN / 赤 $RED / 未測定 $UNMEASURED ==="
echo "  未測定を緑に丸めない。7・8 は Tom の実機、6 の中身は人の目、1・5 は DOD_FULL=1 で実測。"
[ "$RED" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
