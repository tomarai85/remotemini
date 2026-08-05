#!/bin/bash
# Sprint 3 の Definition of Done(ブリーフ §6、14行 + 訂正6-1 の 1 行)を機械で照合する。
#
# ★この道具が証明する事と、しない事
#   証明する: 「その検査が**在る**」「その本文が**在る**」「一式が**緑**」。
#   証明しない: 「その検査が本当に欠陥を捕まえる」。名前だけ一致した空の検査は緑になる。
#   後者を測るのは変異検査(ブリーフ §7-1)であって、この道具ではない。
#   —— 存在の検査を「検証済み」と読み替えないために、報告にこの区別を刷る。
#
# 終了コード(repo 共通): 0=緑 / 1=赤 / 2=測っていない。2 を 0 に丸めない。
# 人手が要る行は自動で 未測定 に落ちる。緑に見せかけない事が目的。
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HARNESS/.." && pwd)"
IOS="$ROOT/ios"
GREEN=0; RED=0; UNMEASURED=0
FULL=${DOD_FULL:-0}   # DOD_FULL=1 で重い行(単体一式 / run-controls)も回す

row() {  # row <判定 pass|fail|skip> <行の名前> <根拠>
    case "$1" in
        pass) GREEN=$((GREEN+1)); printf '  緑    %s\n        %s\n' "$2" "$3" ;;
        fail) RED=$((RED+1));     printf '  赤    %s\n        %s\n' "$2" "$3" ;;
        *)    UNMEASURED=$((UNMEASURED+1)); printf '  未測定 %s\n        %s\n' "$2" "$3" ;;
    esac
}

# has <file> <正規表現> -- 在れば 0
has() { [ -f "$1" ] && grep -qE "$2" "$1"; }

TESTS="$IOS/Tests"
SRC="$IOS/Sources"
CVM_T="$TESTS/Screens/Conversation/ConversationViewModelTests.swift"
MH_T="$TESTS/Core/MergeHistoryTests.swift"
HM_T="$TESTS/Core/HistoryModelsTests.swift"
HC_T="$TESTS/Core/HistoryClientTests.swift"
NHL_T="$TESTS/Core/NextHistoryLimitTests.swift"
MH_S="$SRC/Core/MergeHistory.swift"
CVM_S="$SRC/Screens/Conversation/ConversationViewModel.swift"
CV_S="$SRC/Screens/Conversation/ConversationView.swift"

echo "=== Sprint 3 DoD 照合 ($(date '+%Y-%m-%d %H:%M:%S')) ==="
echo

# --- 1. §4-a の単体が全部緑 --------------------------------------------------
if [ "$FULL" = 1 ]; then
    out=$(bash "$IOS/tools/build.sh" --sim 2>&1); simrc=$?
    # 2 = 測っていない。赤と同じ行に丸めない(dod-sprint-4.sh と同じ理由)。
    case "$simrc" in
        0) row pass "1. §4-a 単体一式" "build.sh --sim exit 0" ;;
        2) row skip "1. §4-a 単体一式" "build.sh --sim が 2 = 測っていない。末尾: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
        *) row fail "1. §4-a 単体一式" "build.sh --sim 非ゼロ($simrc)。末尾: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
    esac
else
    row skip "1. §4-a 単体一式" "重いので既定では回さない。DOD_FULL=1 で実測する"
fi

# --- 2. スクリーンショット ---------------------------------------------------
shots=$(ls "$HARNESS"/evidence-*/*.png 2>/dev/null | wc -l | tr -d ' ')
if [ "${shots:-0}" -ge 1 ]; then
    row skip "2. §4-b スクリーンショット" "$shots 枚在るが、**何が写っているか**は目で見るしかない。存在は緑、内容は未測定"
else
    row fail "2. §4-b スクリーンショット" ".harness/evidence-*/ に PNG が 0 枚"
fi

# --- 3. mergeHistory 6 ケース + 6件目が「既知限界」と判る名前 ---------------
n_mh=$(grep -c 'func test' "$MH_T" 2>/dev/null); n_mh=${n_mh:-0}
if [ "$n_mh" -ge 6 ]; then
    if has "$MH_T" 'func test.*(Known|Limitation|既知)'; then
        row pass "3. mergeHistory 6 ケース" "$n_mh 本。6件目が既知限界と判る名前で在る"
    else
        row fail "3. mergeHistory 6 ケース" "$n_mh 本在るが、Known/Limitation を名前に含む検査が無い(6件目が限界だと読めない)"
    fi
else
    row fail "3. mergeHistory 6 ケース" "$n_mh 本しか無い"
fi

# --- 4. truncated の鍵が**無い**本文 ----------------------------------------
# 「false と書いてある本文」で通しても、非 Optional の間違いは緑のまま。鍵が無い本文が要る。
#
# ★JSON の字面を正規表現で当てにいくのは脆い(初版は `{"history": []}` を想定したが
#   実物は `{ "history": [] }` で空白が入っており、対照の変異が一度も当たらなかった)。
#   なので**行そのもの**を取り出して、含む / 含まないで判定する。
#   `\s` は BSD grep の ERE では効かないので使わない —— macOS で静かに外れる。
#
# ★さらに: 「鍵の無い本文を持つ行」を数えるだけでは足りない。この file にはデコードが
#   **失敗する事**を測る負の対照(`testMissingEntryRoleFailsToDecodeNegativeControl` 等)が
#   在り、それらの本文にも当然 `truncated` は無い。数えるだけだと、肝心の
#   「鍵が無くても false としてデコードが**通る**」検査を丸ごと消しても緑のままになる
#   (対照でそれを踏んだ)。**検査1本の中で**「鍵の無い本文」と「truncated == false の
#   主張」が同居している事を測る。
absent_body=$(awk '
    function close_block() { if (in_block && has_absent && has_assert) n++ }
    /func test/ { close_block(); in_block=1; has_absent=0; has_assert=0; next }
    /decode\(#?"/ { if ($0 !~ /truncated/) has_absent=1 }
    /XCTAssertEqual\(response\.truncated, false\)/ { has_assert=1 }
    END { close_block(); print n+0 }
' "$HM_T" 2>/dev/null)
present_body=$(grep -E 'decode\(#?"' "$HM_T" 2>/dev/null | grep -c 'truncated')
if [ "${absent_body:-0}" -ge 1 ] && [ "${present_body:-0}" -ge 1 ]; then
    row pass "4. truncated 鍵欠け" "鍵の無い本文で false を主張する検査 $absent_body 本 / 鍵の在る本文 $present_body 本"
elif [ "${absent_body:-0}" -ge 1 ]; then
    row fail "4. truncated 鍵欠け" "鍵の無い本文は在るが、鍵が在る側の対照が無い"
else
    # ★backquote を二重引用符の中に書かない(この repo 自身の罠。書くと展開されて壊れる)
    row fail "4. truncated 鍵欠け" "truncated を含まない JSON 本文が検査に無い(非 Optional の間違いを捕まえられない)"
fi

# --- 5. 上限で引っ込む + 上限の文言 -----------------------------------------
if has "$CVM_T" 'atCeiling'; then
    row pass "5. 上限でボタンが引っ込む" "atCeiling を検査する本文が在る"
else
    row fail "5. 上限でボタンが引っ込む" "ConversationViewModelTests に atCeiling が無い"
fi

# --- 6. 一番古いのが変わらない → 居座り文 + ボタンは残る --------------------
if has "$CVM_T" 'stalledRetry'; then
    row pass "6. 進まなかった時に残る" "stalledRetry を検査する本文が在る"
else
    row fail "6. 進まなかった時に残る" "ConversationViewModelTests に stalledRetry が無い"
fi

# --- 7. 件数は増えたが一番古いのは変わらない --------------------------------
# 「count で測ると緑になってしまう」形。件数を増やした本文が要る。
if grep -qiE 'func test.*(grew|grow|増え|newer|appended)' "$CVM_T" 2>/dev/null; then
    row pass "7. 件数増・最古不変" "件数が増える経路の検査が名前で識別できる"
else
    row fail "7. 件数増・最古不変" "件数だけ増える場合を名指しした検査が見当たらない(count 判定の再発を捕まえられない)"
fi

# --- 8. 上限の文言と居座りの文言が別物 --------------------------------------
# 実物は前置きが付く("これより古い発言は在りますが、今回は読み込めませんでした")ので、
# 引用符の先頭に錨を打つと外れる。特徴語で探す。
stall_txt=$(grep -oE '"[^"]*今回は読み込めませんでした[^"]*"' "$CV_S" 2>/dev/null | head -1)
ceil_txt=$(grep -oE '"[^"]*500 件までしか出せません[^"]*"' "$CV_S" 2>/dev/null | head -1)
if [ -n "$ceil_txt" ] && [ -n "$stall_txt" ] && [ "$ceil_txt" != "$stall_txt" ]; then
    row pass "8. 2つの文言が別物" "上限=$ceil_txt / 居座り=$stall_txt"
else
    row fail "8. 2つの文言が別物" "上限側=[${ceil_txt:-無}] 居座り側=[${stall_txt:-無}] —— 片方が見つからないか同一"
fi

# --- 9. 未知の role を1件含む本文で、応答**全体**がデコードできる -----------
if grep -qE '"role"\s*:\s*"(system|unknown|[a-z]+)"' "$HM_T" 2>/dev/null \
   && grep -qE 'func test.*(nknown|未知)' "$HM_T" 2>/dev/null; then
    row pass "9. 未知 role で全体が生き残る" "未知 role を含む本文の検査が在る"
else
    row fail "9. 未知 role で全体が生き残る" "未知の role を含む JSON 本文を通す検査が $HM_T に見当たらない"
fi

# --- 10. 404 → .notFound、Conversation では再試行を出さない -----------------
# ★grep -c は一致 0 件でも「0」を出した上で exit 1 する。`|| echo 0` を足すと
#   出力が "0\n0" になり、算術比較が壊れる(この道具自身が最初の実行で踏んだ)。
c404_client=$(grep -c 'case 404' "$SRC/Core/HistoryClient.swift" 2>/dev/null); c404_client=${c404_client:-0}
c404_sess=$(grep -c 'case 404' "$SRC/Core/SessionsClient.swift" 2>/dev/null); c404_sess=${c404_sess:-0}
if [ "$c404_client" -ge 1 ] && [ "$c404_sess" -eq 0 ] && has "$HC_T" 'notFound' && has "$CVM_T" 'notFound'; then
    row pass "10. 404=.notFound / 再試行なし" "HistoryClient のみ 404 を写像($c404_client 箇所)、SessionsClient は 0。両方に検査在り"
else
    row fail "10. 404=.notFound / 再試行なし" "HistoryClient=$c404_client SessionsClient=$c404_sess / HC 検査=$(has "$HC_T" notFound && echo 有 || echo 無) / VM 検査=$(has "$CVM_T" notFound && echo 有 || echo 無)"
fi

# --- 11. ★正常経路の錨(⑨) -------------------------------------------------
# 「.available が出ている事」を測る検査。これが無いと ③⑤⑥ は全部
# 「常に .hidden を返す」実装で素通りする(不在ばかり測っている群への錨)。
if grep -qE 'loadEarlierState,\s*\.available|== \.available|\.available\)' "$CVM_T" 2>/dev/null; then
    row pass "11. 正常経路の錨(⑨)" ".available が出ている事を主張する本文が在る"
else
    row fail "11. 正常経路の錨(⑨)" ".available を**期待値として**主張する行が無い。③⑤⑥ は .hidden 固定の実装で全部緑になる"
fi

# --- 12. display.who だけ違う2件が畳まれる ---------------------------------
if grep -qE 'func test.*(isplay|who)' "$MH_T" 2>/dev/null; then
    row pass "12. display 違いを畳む" "display/who を名指しした検査が在る"
else
    row fail "12. display 違いを畳む" "Equatable 自動合成で display が等値に入る欠陥を捕まえる検査が無い"
fi

# --- 13. run-controls.sh が前景で red=0 未測定=0 ----------------------------
if [ "$FULL" = 1 ]; then
    if out=$(bash "$ROOT/rc-backend/tools/run-controls.sh" 2>&1); then
        tail_line=$(printf '%s' "$out" | grep -oE 'green=[0-9]+ red=[0-9]+ 未測定=[0-9]+' | tail -1)
        case "$tail_line" in
            *"red=0 未測定=0") row pass "13. run-controls" "$tail_line" ;;
            "")                row fail "13. run-controls" "集計行が出力に無い" ;;
            *)                 row fail "13. run-controls" "$tail_line" ;;
        esac
    else
        row fail "13. run-controls" "非ゼロ終了"
    fi
else
    row skip "13. run-controls" "重いので既定では回さない。DOD_FULL=1 で実測する"
fi

# --- 14. progress.md に食い違い・判断が書いてある ---------------------------
row skip "14. progress.md の記述" "散文なので機械では測れない。Evaluator が読む"

# --- 15. ★訂正6-1: nextHistoryLimit の falsy 意味論 -------------------------
# 本物は view.mjs: `Math.min(500, (current || 50) + 100)`。JS の `||` は 0 を偽と扱う
# ので nextHistoryLimit(0) === 150。Swift の `??` は 0 を値と扱うので 100 になる。
# C群の移植で意味が変わる唯一の箇所(移植 7 本を実測して 1 本だけ乖離)。
if grep -qE 'current == 0 \? 50|current\.flatMap|== 0.*50' "$MH_S" 2>/dev/null \
   || grep -qE '\(current ?\?\?? ?0\) == 0' "$MH_S" 2>/dev/null; then
    impl_ok=1
else
    impl_ok=0
fi
if grep -q 'nextHistoryLimit(0)' "$NHL_T" 2>/dev/null; then test_ok=1; else test_ok=0; fi
# コメントが JS を正しく引用しているか(`??` と書いてあると、読み手が「移植は合っている」と
# 確認したつもりで止まる。誤ったコメントは誤ったコードより悪い)
if grep -qE 'nextHistoryLimit`?:? *`?min\(500, \(current \?\? 50\)' "$MH_S" 2>/dev/null; then
    comment_bad=1
else
    comment_bad=0
fi
if [ "$impl_ok" = 1 ] && [ "$test_ok" = 1 ] && [ "$comment_bad" = 0 ]; then
    row pass "15. nextHistoryLimit の || 意味論" "0 を偽として扱う実装 + nextHistoryLimit(0) の検査 + JS 引用が正しい"
else
    row fail "15. nextHistoryLimit の || 意味論" "実装=$([ $impl_ok = 1 ] && echo OK || echo '?? のまま(0→100、本物は150)') / 検査 nextHistoryLimit(0)=$([ $test_ok = 1 ] && echo 有 || echo 無) / コメントの JS 引用=$([ $comment_bad = 0 ] && echo OK || echo '誤(?? と書いてある)')"
fi

echo
echo "=== 集計: 緑=$GREEN 赤=$RED 未測定=$UNMEASURED (全 15 行) ==="
echo "※ 緑 = 「在る」の証明。「効く」の証明ではない(変異検査 §7-1 が別に要る)。"
[ "$RED" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
