#!/bin/bash
# controls-for: .harness/dod-sprint-6.5.sh
#
# Sprint 6.5 の照合表の**負の対照** —— 各行が本当に赤(または未測定)にもなるかを、
# 実際に性質を壊して測る。
#
# なぜ要るか:
#   `dod-sprint-6.5.sh` は初回から 緑 9 / 赤 1 / 未測定 5 を出した。緑は
#   「その性質が守られている」の証拠ではなく「今の木とこの照合が一致している」の
#   証拠でしかない。骨抜きの照合も同じ緑を出す。この repo は既に何度も踏んでいる
#   (vacuous-gate、requestedBodies が永久に nil を比べていた件、
#    request-shape が綴りで対象を選んでいて Probe を素通りさせた件)。
#
# ★走らせ方: **作業木を一切触らない**。照合表が読む file だけを scratch に複製し、
#   其処で壊す。Sprint 6 の対照が作業木で変異させたのは xcodebuild が要ったからで、
#   此処の行は全部 file の中身を読むだけなので、その代償を払う理由が無い。
#   → 中断されても作業木は初めから変わっていない(「戻る」ではなく「触っていない」)。
#
# ★DOD_FULL は使わない。使うと対照1本ごとに xcodebuild が回り、11 本で1時間を超える。
#   代わりに log と原稿の指紋を複製して持ち込む = 0 行目も測れる。
#
# ★**build が走っている最中に此処を回さない**(2026-08-07 に踏んだ)。
#   `DOD_FULL=1` の照合と同時に走らせたら OK 13 の内容のまま終了コードだけ 1 で出た。
#   原因は競合: 複製した log と指紋が、`build.sh --sim` の書き込み途中の物だった。
#   → 基準が緑にならない行が出て guard が NG を数えた。対照の欠陥ではないが、
#     **同時に走らせると偽の NG が出る**事は判定を読む側が知っている必要が在る。
#
# 終了コード: 0=全部の対照が期待通り / 1=期待通りに壊れない対照が在る / 2=測れなかった
#   ★2 は「作業木が汚れた」だけでなく「**基準が揃わず壊す前後を比べられない行が在る**」
#     でも出る。後者は 2026-08-07 まで 1(赤)へ丸めていた —— 下の guard の註を参照。
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HARNESS/.." && pwd)"
DOD="$HARNESS/dod-sprint-6.5.sh"
PASS=0; FAIL=0; SKIP=0
WT="$(mktemp -d "${TMPDIR:-/tmp}/dod65-controls.XXXXXX")"
trap 'rm -rf "$WT"' EXIT

[ -f "$DOD" ] || { echo "測れない: $DOD が無い"; exit 2; }

# --- 照合表が読む物だけを複製する ---------------------------------------------
mkdir -p "$WT/.harness" "$WT/ios/build" "$WT/rc-backend/test" "$WT/rc-backend/tools"
cp "$DOD" "$WT/.harness/"
cp -R "$ROOT/ios/Sources" "$ROOT/ios/Tests" "$ROOT/ios/UITests" "$WT/ios/" 2>/dev/null
cp "$ROOT/ios/project.yml" "$WT/ios/" 2>/dev/null
cp "$ROOT/ios/build/xcodebuild-sim.log" "$WT/ios/build/" 2>/dev/null
cp "$ROOT/ios/build/xcodebuild-sim.sources.sha" "$WT/ios/build/" 2>/dev/null
cp "$ROOT/DESIGN.md" "$ROOT/HANDOFF-NEXT-SESSION.md" "$WT/" 2>/dev/null
cp "$ROOT/rc-backend/test/restart-epoch-controls.sh" "$WT/rc-backend/test/" 2>/dev/null
cp "$ROOT/rc-backend/tools/tailnet-key-expiry.sh" "$WT/rc-backend/tools/" 2>/dev/null

# 複製は元の木と同じ指紋になっていなければならない。ここがズレていると 0 行目が
# 最初から未測定で、以降の対照は「壊したから未測定」を区別できない。
PRISTINE="$WT/.pristine"
mkdir -p "$PRISTINE"
cp -R "$WT/ios" "$WT/DESIGN.md" "$WT/HANDOFF-NEXT-SESSION.md" "$PRISTINE/" 2>/dev/null

restore() { # restore <WT からの相対パス>
    rm -rf "$WT/$1"
    cp -R "$PRISTINE/$1" "$WT/$1"
}

run_dod() { bash "$WT/.harness/dod-sprint-6.5.sh" 2>&1; }

# --- 基準 ---------------------------------------------------------------------
BASE="$(run_dod)"
echo "=== 基準(壊す前)==="
printf '%s\n' "$BASE" | grep -E '^  (緑|赤|未測定)' | sed 's/^/  /'
echo

> "$WT/.baseline-status"
(cd "$ROOT" && git status --porcelain) > "$WT/.baseline-status" 2>/dev/null || true

chk() { # chk <説明> <期待する行の正規表現> <出力>
    if printf '%s\n' "$3" | grep -qE "$2"; then
        PASS=$((PASS+1)); printf '  OK   %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"
        printf '       期待した行が出ていない: %s\n' "$2"
        printf '%s\n' "$3" | grep -E '^  (緑|赤|未測定)' | sed 's/^/         /'
    fi
}

# 壊す前の判定が期待と違うなら、壊しても何も証明できない。
# ★既定は 緑 だが、**電話が要る行は基準が 未測定**(6-c)。そこを一律 緑 で要求すると、
#   壊しても意味が無い行として弾かれ、その行の対照が永久に走らない = 対照側の空振り。
#
# ★2026-08-07 訂正: 此処は NG を数えていた。基準が揃わないのは**この対照が欠陥を
#   見つけた**事ではなく、**測れなかった**事なので、赤へ丸めるのは照合表本体が
#   守っている「未測定を緑にも赤にも丸めない」を対照側だけが破っていた形。
#   実測でそのまま損をした: `ios/` の swift を1行(註だけ)直すと 0 行目の指紋が
#   ずれ、log 頼りの5行が未測定へ落ち、この対照が `OK 9 / NG 5` を出した。読む側は
#   「対照が5件の欠陥を見つけた」と「指紋が古くて何も測れなかった」を区別できず、
#   実際に私はここで誤った診断を1回公言している。指紋を録り直すと `OK 14 / NG 0`。
guard() { # guard <行の見出しの正規表現> <説明> [期待する基準の判定 = 緑]
    local want="${3:-緑}"
    if printf '%s\n' "$BASE" | grep -qE "^  $want( |    )$1"; then return 0; fi
    SKIP=$((SKIP+1))
    printf '  未測定 %s\n       基準が %s ではないので、壊しても意味が無い(欠陥ではない)\n' "$2" "$want"
    printf '       0 行目が未測定なら DOD_FULL=1 で照合表を回して指紋を録り直す\n'
    return 1
}

echo "=== 対照 ==="

# --- 1. 0 行目: log の指紋が今の原稿と違えば未測定 -----------------------------
if guard '0\. 土台' "0 行目 指紋の不一致"; then
    echo "こわれた指紋" > "$WT/ios/build/xcodebuild-sim.sources.sha"
    chk "0 行目 指紋の不一致 -> 未測定" '^  未測定 0\. 土台' "$(run_dod)"
    restore ios
fi

# --- 2. 0 行目: 指紋そのものが無ければ未測定(古い build.sh の log) -----------
if guard '0\. 土台' "0 行目 指紋が無い"; then
    rm -f "$WT/ios/build/xcodebuild-sim.sources.sha"
    chk "0 行目 指紋が無い -> 未測定" '^  未測定 0\. 土台' "$(run_dod)"
    restore ios
fi

# --- 3. 指紋が違う時、log 頼りの行が**全部**未測定へ落ちる ---------------------
# ★2026-08-07 に見つけた照合側の穴。0 行目は指紋を見ていたのに、下の `check_names` が
#   使う行(1-b / 2-b / 3 / 5-a / 6-b)は **0 行目の判定を見ていなかった**。
#   照合表の頭には「0 行目が未測定なら下の緑は全部古い木の話」と註が書いてあり、
#   機械は何もしていなかった —— 「指紋が違う」という 1 行の下に緑が 5 行並ぶ形が
#   実際に作れた。上の対照 1・2 は 0 行目しか見ていないので、この穴を通した。
#   註は守りではない。だから伝播そのものを測る対照を置く。
if guard '1-b\.' "指紋の不一致が log 頼りの行へ伝わる"; then
    echo "こわれた指紋" > "$WT/ios/build/xcodebuild-sim.sources.sha"
    out="$(run_dod)"
    miss=""
    for r in '1-b\.' '2-b\.' '3\. ' '5-a\.' '6-b\.'; do
        printf '%s\n' "$out" | grep -qE "^  未測定 $r" || miss="$miss $r"
    done
    if [ -z "$miss" ]; then
        PASS=$((PASS+1))
        printf '  OK   %s\n' "指紋の不一致 -> log 頼りの 5 行が全部 未測定"
    else
        FAIL=$((FAIL+1))
        printf '  NG   %s\n       まだ緑を出している行:%s\n' \
            "指紋の不一致 -> log 頼りの 5 行が全部 未測定" "$miss"
        printf '%s\n' "$out" | grep -E '^  (緑|赤|未測定)' | sed 's/^/         /'
    fi
    restore ios
fi

# --- 4. 1-a: 通常経路が会話画面へ直行したら赤 ---------------------------------
if guard '1-a\.' "1-a 固定1部屋への直行"; then
    /usr/bin/sed -i '' 's|^            ListView(|            ConversationView(viewModel: x)\n            ListView(|' \
        "$WT/ios/Sources/RootView.swift"
    chk "1-a 通常経路が ConversationView を直に出す -> 赤" '^  赤    1-a\.' "$(run_dod)"
    restore ios
fi

# --- 5. 1-a: 抜き出しが空になったら緑ではなく未測定 ---------------------------
# ★これが一番効く対照。「含まない」を根拠にする検査は、対象を見失った時に
#   黙って緑を出す。この repo が繰り返し踏んでいる形そのもの。
if guard '1-a\.' "1-a 抜き出しの空振り"; then
    # ★接尾辞を足す改名では駄目(2026-08-07、この対照が初回に自分で外した)。
    #   照合側の目印は部分一致なので `normalFlowRenamed` にも当たる = 抜き出しは成功する。
    #   目印を**消す**改名でないと、空振りの状況を作れていない。
    /usr/bin/sed -i '' 's|private var normalFlow|private var mainRoute|' \
        "$WT/ios/Sources/RootView.swift"
    chk "1-a normalFlow を見失う -> 緑にせず未測定" '^  未測定 1-a\.' "$(run_dod)"
    restore ios
fi

# --- 6. 1-b: 画面の検査が同じ log で通っていなければ赤 -------------------------
if guard '1-b\.' "1-b log に無い"; then
    /usr/bin/sed -i '' '/testListEmptyShowsTheNoConversationsMessage\]. passed/d' \
        "$WT/ios/build/xcodebuild-sim.log"
    chk "1-b 検査は在るが log に passed が無い -> 赤" '^  赤    1-b\.' "$(run_dod)"
    restore ios
fi

# --- 7. 2-a: 送信の3つの性質、どれが外れても赤 -------------------------------
# ★2026-08-09。元は `sendClient: MessageSending = SendClient()` を潰す1本だった。
#   その綴りは client が注入容器(`Core/ConversationClients.swift`)へ移った時に消えて
#   おり、sed は**空振りしていた** —— 壊していないのに「壊しても赤が出た」と読める形。
#   気付けなかった理由が重要で、当時は表側の錨(`grep 'SendClient('`)も同じ改修で
#   腐って 2-a が赤だったので、guard が此処を「基準が緑でない」として未測定へ落として
#   いた。**二つの腐りが互いを隠していた**。表を性質3つで測る形にしたので対照も3つに割る。
if guard '2-a\.' "2-a 送信の組み込み"; then
    VMW="$WT/ios/Sources/Screens/Conversation/ConversationViewModel.swift"
    CCW="$WT/ios/Sources/Core/ConversationClients.swift"

    /usr/bin/sed -i '' 's|private let sendClient: MessageSending|private let sendClient: AnyObject|' "$VMW"
    chk "2-a ViewModel が送り手を保持しない -> 赤" '^  赤    2-a\.' "$(run_dod)"
    restore ios

    /usr/bin/sed -i '' 's|await sendClient\.send(|await sendClient.transmitNothing(|' "$VMW"
    chk "2-a 保持するだけで呼んでいない -> 赤" '^  赤    2-a\.' "$(run_dod)"
    restore ios

    /usr/bin/sed -i '' 's|send: SendClient(),|send: NullSender(),|' "$CCW"
    chk "2-a 容器が本物の送り手を挿さない -> 赤" '^  赤    2-a\.' "$(run_dod)"
    restore ios
fi

# --- 8. 3: BUSY の検査が1本消えたら赤 -----------------------------------------
# Tom の裁定(返答待ちでも作業中でも干渉できる)を守る検査。消えたら赤で出る事。
if guard '3\. ' "3 BUSY の検査"; then
    /usr/bin/sed -i '' 's|func testInterruptStaysEnabledOnBUSY(|func testInterruptStaysEnabledOnBUSYRenamed(|' \
        "$(grep -rlE 'func testInterruptStaysEnabledOnBUSY\(' "$WT/ios/Tests" | head -1)"
    chk "3 BUSY の検査が1本消える -> 赤" '^  赤    3\. ' "$(run_dod)"
    restore ios
fi

# --- 9. 6-a: 待ち時間の定数が1本消えたら赤 ------------------------------------
if guard '6-a\.' "6-a 定数"; then
    # ★接尾辞を足すだけの改名にしてある。照合側が部分一致だと此処が緑のまま通り、
    #   `writeTimeoutDisabled` の様な**定数を殺す改名**を素通しする。初回はまさに
    #   そうなって、この行が照合側の語の境界不足を教えた(2026-08-07)。
    /usr/bin/sed -i '' 's|static let writeTimeout|static let writeTimeoutRenamed|' \
        "$(grep -rl 'static let writeTimeout' "$WT/ios/Sources" | head -1)"
    chk "6-a writeTimeout の改名(接尾辞) -> 赤" '^  赤    6-a\.' "$(run_dod)"
    restore ios
fi

# --- 10. 6-c: 引用先の節が消えたら赤(どこも指していない矢印) ------------------
# ★2026-08-07 に自分で踏んだ形。「§4 の E に合流させた」と書いた時、E は存在しなかった。
if guard '6-c\.' "6-c 引用先の実在" 未測定; then
    /usr/bin/sed -i '' 's|^### 8-10\.|### 8-99-書き換えた.|' "$WT/DESIGN.md"
    chk "6-c DESIGN §8-10 が消える -> 赤" '^  赤    6-c\.' "$(run_dod)"
    cp "$PRISTINE/DESIGN.md" "$WT/DESIGN.md"
fi

# --- 11. 7: 外部依存が入ったら赤 ----------------------------------------------
if guard '7\. ' "7 外部 import"; then
    printf 'import Alamofire\n' >> "$WT/ios/Sources/RootView.swift"
    chk "7 Apple 標準でない import -> 赤" '^  赤    7\. ' "$(run_dod)"
    restore ios
fi

# --- 12. 7: Package.resolved が現れたら赤 -------------------------------------
if guard '7\. ' "7 Package.resolved"; then
    printf '{}\n' > "$WT/ios/Package.resolved"
    chk "7 Package.resolved が在る -> 赤" '^  赤    7\. ' "$(run_dod)"
    restore ios
fi

# --- 13. 10: 証跡が未測定の行を持たなければ赤 ---------------------------------
# = 電話が要る脚を緑に丸めた証跡を、門が受け取らない事。
mkdir -p "$WT/.harness/evidence-2026-08-1x"
{
    echo "# Sprint 6.5 受入(壊した版)"
    echo "dod-sprint-6.5.sh の出力から作った。"
    echo "全部みどり。testBusyLeavesBothTheComposerAndTheInterruptButtonUsable"
} > "$WT/.harness/evidence-2026-08-1x/sprint6-acceptance.md"
chk "10 証跡に未測定の行が無い -> 赤" '^  赤    10\.' "$(run_dod)"

# --- 14. 10: 引用した検査名が実在しなければ赤 ---------------------------------
{
    echo "# Sprint 6.5 受入(壊した版その2)"
    echo "dod-sprint-6.5.sh の出力から作った。未測定の行も在る。"
    echo "testThisNameDoesNotExistAnywhere"
} > "$WT/.harness/evidence-2026-08-1x/sprint6-acceptance.md"
chk "10 証跡が実在しない検査名を引く -> 赤" '^  赤    10\.' "$(run_dod)"
rm -rf "$WT/.harness/evidence-2026-08-1x"

# --- 復元の確認 ---------------------------------------------------------------
# 作業木は初めから触っていないが、**触っていない事を観測する**。
# ★「木が綺麗である事」ではなく「**走らせる前と同じである事**」を見る(2026-08-07 訂正)。
#   綺麗さを条件にすると、無関係な編集中の file が1つ在るだけでこの対照が 2 で落ちる。
#   初回はまさに `ios/tools/build.sh` の未 commit 編集で落ちた —— この対照が触った物では無い。
(cd "$ROOT" && git status --porcelain) > "$WT/.final-status" 2>/dev/null || true
DELTA="$(diff "$WT/.baseline-status" "$WT/.final-status" | grep -c . || true)"

echo
echo "=== 合計: OK $PASS / NG $FAIL / 未測定 $SKIP ==="
[ "$SKIP" -gt 0 ] && echo "  ★未測定は「対照が欠陥を見つけた」ではない。基準が揃わず**壊す前と後を比べられなかった**行。"
if [ "${DELTA:-0}" -ne 0 ]; then
    echo "  ★走らせる前後で作業木の状態が変わっている(差 $DELTA 行)。"
    echo "    この対照は scratch でしか壊さない筈なので、対照側が壊れている。判定を出さない:"
    diff "$WT/.baseline-status" "$WT/.final-status" | sed 's/^/      /'
    exit 2
fi
echo "  作業木は走らせる前と同一(git status の差 0 行、観測値)"
# 赤が最優先。赤が無くても測れなかった行が在れば緑を名乗らない(0 へ丸めない)。
[ "$FAIL" -gt 0 ] && exit 1
[ "$SKIP" -gt 0 ] && exit 2
exit 0
