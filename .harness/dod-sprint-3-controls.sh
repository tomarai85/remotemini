#!/bin/bash
# controls-for: .harness/dod-sprint-3.sh
# `dod-sprint-3.sh` の対照。**各行が本当に赤にも緑にもなる**事を確かめる。
#
# なぜ要るか: 照合表は「全部緑」を出した瞬間から誰も疑わなくなる。だが grep の
# 基準点が1つずれているだけで、測っていない物を緑と報告する —— 本体の初回実行で
# 実際に 4 赤のうち 3 つが**私の regex の基準点の誤り**だった(探索先の dir が違う /
# `grep -c` の `|| echo 0` が "0\n0" を作る / 文言の錨を引用符の先頭に打っていた)。
# 対照が無ければ、逆向きの誤り(測っていないのに緑)は誰にも見えない。
#
# 走らせ方: 主作業木は**一切触らない**。scratch に ios/ を複製し、その複製だけを壊す。
#   (Generator が同じ木で `xcodebuild` を回している間に source を壊すと、
#    自分のせいでない赤を見る事になる。この repo で実際に注意した事そのもの)
#
# 終了コード: 0=全対照が期待通り / 1=期待と違う物が在る / 2=測れなかった
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "$HARNESS/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dod-s3-controls.XXXXXX")"
PASS=0; FAIL=0; UNMEASURED=0

# ★`rm -rf` は使わない(この環境の禁止事項)。file を消してから dir を深い順に畳む。
cleanup() {
    [ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ] || return 0
    find "$SCRATCH" -type f -print0 | xargs -0 /bin/rm -f
    find "$SCRATCH" -type d -depth -exec /bin/rmdir {} + 2>/dev/null
}
trap cleanup EXIT

# 複製を作り直す(各対照は汚れていない複製から始める)
fresh() {
    cleanup
    mkdir -p "$SCRATCH/.harness"
    cp "$HARNESS/dod-sprint-3.sh" "$SCRATCH/.harness/"
    # ★`ios/build/` を複製しない。Generator が今この瞬間 `xcodebuild` の結果束を
    #   書いているので、丸ごと cp すると**複製の最中に元の file が消える**
    #   (初版は cp のエラーを 89KB 吐いた)。照合表が読むのは Sources/Tests だけ。
    rsync -a --exclude 'build/' --exclude 'DerivedData/' --exclude '.git/' \
        "$REAL_ROOT/ios/" "$SCRATCH/ios/" >/dev/null 2>&1
    mkdir -p "$SCRATCH/.harness/evidence-copy"
    cp "$HARNESS"/evidence-*/*.png "$SCRATCH/.harness/evidence-copy/" 2>/dev/null
}

# verdict <行番号> -- その行の判定(緑/赤/未測定)を返す
verdict() {
    # 既定は 0(重い行を回さない)。DOD_FULL=1 側の分岐を測る対照だけが CTL_FULL=1 にする。
    DOD_FULL="${CTL_FULL:-0}" bash "$SCRATCH/.harness/dod-sprint-3.sh" 2>/dev/null \
        | grep -E "^  (緑|赤|未測定) +$1\. " | awk '{print $1}' | head -1
}

# check <行番号> <期待 緑|赤> <対照の名前> -- fresh 済みの複製に対して測る
check() {
    local row="$1" want="$2" name="$3" got
    got="$(verdict "$row")"
    if [ -z "$got" ]; then
        UNMEASURED=$((UNMEASURED+1)); printf '  未測定 [行%-2s] %s —— 判定行が出力に無い\n' "$row" "$name"
    elif [ "$got" = "$want" ]; then
        PASS=$((PASS+1));  printf '  緑    [行%-2s] %s(期待=%s 実測=%s)\n' "$row" "$name" "$want" "$got"
    else
        FAIL=$((FAIL+1));  printf '  赤    [行%-2s] %s(期待=%s 実測=%s)★対照が働いていない\n' "$row" "$name" "$want" "$got"
    fi
}

echo "=== dod-sprint-3.sh の対照 ($(date '+%Y-%m-%d %H:%M:%S')) ==="
echo "複製: $SCRATCH  (主作業木 $REAL_ROOT は読むだけ)"
echo

# ---- 行1: --sim の終了コードが3通りに写るか(2026-08-05 に足した)-----------
# ★既存の対照は全部 DOD_FULL=0 で回っていたので、`build.sh --sim` を実際に呼ぶ
#   分岐は無検査だった。`sim-log-summary.sh` に 2(測っていない)を足した日に、
#   受ける側がそれを赤へ丸めていた事に気付いた —— 足した終了コードが、読む人の
#   所へ届くまでに1段で潰れていた。
# 本物の build は数分掛かるので、写しの中の物を終了コードだけ返す物に差し替える。
stub_build() {   # $1 = 返させる終了コード
    mkdir -p "$SCRATCH/ios/tools"
    printf '#!/bin/bash\necho "==> 作り物: 終了コード %s を返す"\nexit %s\n' "$1" "$1" \
        > "$SCRATCH/ios/tools/build.sh"
}
# ★`VAR=1 check ...` の形は使わない。bash では関数への前置き代入が呼び出し後も残り、
#   次の対照へ静かに漏れる。明示的に立てて明示的に落とす。
CTL_FULL=1
fresh; stub_build 0
check 1 緑 "--sim が 0 なら緑"

fresh; stub_build 1
check 1 赤 "--sim が 1(赤)なら赤"

fresh; stub_build 2
check 1 未測定 "★--sim が 2(測っていない)を赤に丸めない —— これが直した所"
CTL_FULL=0

# ---- 行2: スクショを消したら赤 ---------------------------------------------
fresh; /bin/rm -f "$SCRATCH/.harness/evidence-copy"/*.png
check 2 赤 "PNG を全部消す"

# ---- 行3: 「既知限界」と判る名前を潰したら赤 -------------------------------
fresh; sed -i '' 's/testKnownLimitationSameUtteranceTwiceOverStrips/testSameUtteranceTwiceOverStrips/' \
    "$SCRATCH/ios/Tests/Core/MergeHistoryTests.swift"
check 3 赤 "6件目から Known/Limitation を外す"

# ---- 行4: 鍵の無い本文を鍵在りに書き換えたら赤 ------------------------------
# ★初版はここで `{"history": []}`(空白なし)を探しており、実物 `{ "history": [] }` に
#   一度も当たっていなかった —— 対照が「変異を掛けたつもりで何も変えていない」型。
#   字面を当てにいかず、鍵の無い本文を持つ**行**に鍵を差し込む。
fresh; sed -i '' 's/"history": \[\] }"#/"history": [], "truncated": false }"#/' \
    "$SCRATCH/ios/Tests/Core/HistoryModelsTests.swift"
check 4 赤 "鍵欠けの本文に truncated を差し込む"

# ---- 行5 / 行6: 状態名を潰したら赤 ------------------------------------------
fresh; sed -i '' 's/atCeiling/ceilingReached/g' "$SCRATCH/ios/Tests/Screens/Conversation/ConversationViewModelTests.swift"
check 5 赤 "検査から atCeiling を消す"

fresh; sed -i '' 's/stalledRetry/retryStalled/g' "$SCRATCH/ios/Tests/Screens/Conversation/ConversationViewModelTests.swift"
check 6 赤 "検査から stalledRetry を消す"

# ---- 行7: 「件数だけ増える」経路の検査名を潰したら赤 ------------------------
fresh; sed -i '' 's/testLoadEarlierWithGrowingLiveEndButUnchangedOldestStillReadsAsStalledRetry/testLoadEarlierCaseTwo/' \
    "$SCRATCH/ios/Tests/Screens/Conversation/ConversationViewModelTests.swift"
check 7 赤 "件数増の検査名から grow を外す"

# ---- 行8: 2つの文言を同一にしたら赤 ----------------------------------------
fresh; sed -i '' 's/これより古い発言は在りますが、今回は読み込めませんでした/これより古い発言は在りますが、電話には最新 500 件までしか出せません/' \
    "$SCRATCH/ios/Sources/Screens/Conversation/ConversationView.swift"
check 8 赤 "居座りの文言を上限の文言に揃える"

# ---- 行9: 未知 role の検査名を潰したら赤 -----------------------------------
fresh; sed -i '' 's/testUnrecognizedRoleFallsBackToUnknownWithoutFailingDecode/testRoleFallback/' \
    "$SCRATCH/ios/Tests/Core/HistoryModelsTests.swift"
check 9 赤 "未知 role の検査名から unknown を外す"

# ---- 行10: 404 写像を SessionsClient 側にも置いたら赤(B の置き場所の誤り) --
# これは §3-c の裁定そのものの対照。`/api/sessions` は 404 を返す session id を
# 持たないので、そこに 404 分岐が生えたら「API の設定間違い」を「会話が消えた」と
# 読む事になる。照合表がそれを見逃さない事を確かめる。
fresh; sed -i '' 's|^        case 401:|        case 404:\n            return .failure(.notFound)\n        case 401:|' \
    "$SCRATCH/ios/Sources/Core/SessionsClient.swift"
check 10 赤 "SessionsClient にも 404 分岐を生やす(置き場所の誤り)"

# ---- 行11: 正常経路の錨を潰したら赤(⑨) -----------------------------------
fresh; sed -i '' 's/available/reachable/g' "$SCRATCH/ios/Tests/Screens/Conversation/ConversationViewModelTests.swift"
check 11 赤 "⑨ の .available 主張を消す"

# ---- 行12: display の検査名を潰したら赤 ------------------------------------
fresh; sed -i '' 's/testOverlapStillStripsWhenDisplayWhoDiffersButRoleAndTextMatch/testOverlapStillStripsCaseSeven/' \
    "$SCRATCH/ios/Tests/Core/MergeHistoryTests.swift"
check 12 赤 "display 違いの検査名から display/who を外す"

# ---- 行15: 直したら緑になるか(今は赤なので、逆向きを測らないと意味が無い) --
# 赤のまま動かない行は「常に赤を出すだけの飾り」と区別が付かない。
# 訂正6-1 の直し方をそのまま複製に当てて、緑へ動く事を確かめる。
fresh
python3 - "$SCRATCH" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
mh = root / "ios/Sources/Core/MergeHistory.swift"
s = mh.read_text()
s = s.replace("min(500, (current ?? 50) + 100)",
              "min(500, ((current ?? 0) == 0 ? 50 : current!) + 100)")
s = s.replace("`view.mjs`'s `nextHistoryLimit`: `min(500, (current ?? 50) + 100)`",
              "`view.mjs`'s `nextHistoryLimit`: `Math.min(500, (current || 50) + 100)`")
mh.write_text(s)
t = root / "ios/Tests/Core/NextHistoryLimitTests.swift"
u = t.read_text()
u = u.replace("    func testNilFallsBackToFifty() {",
              "    func testZeroIsFalsyInJSSoItAlsoFallsBackToFifty() {\n"
              "        XCTAssertEqual(MergeHistory.nextHistoryLimit(0), 150)\n"
              "    }\n\n"
              "    func testNilFallsBackToFifty() {")
t.write_text(u)
PY
check 15 緑 "訂正6-1 を当てたら緑へ動く"

# ---- 対照を掛けていない行(分母を隠さない) ---------------------------------
echo
echo "  対照を掛けていない行: 13(run-controls)/ 14(progress.md 散文)"
echo "    —— 13 は本体側で既定 未測定、14 は機械で測れないと宣言済み。"
echo "       1(単体一式)は 2026-08-05 に対照が付いた(終了コード 0/1/2 の写り方)。"
echo "       「対照が在る行」は 15 行中 13 行。"

echo
echo "=== 集計: 緑=$PASS 赤=$FAIL 未測定=$UNMEASURED (対照 13 本) ==="
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
