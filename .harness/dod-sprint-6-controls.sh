#!/bin/bash
# controls-for: ios/Tests/Screens/Conversation/ConversationViewModelTests.swift ios/Tests/Core/ReachabilityMeterTests.swift ios/Tests/Core/InterruptClientTests.swift
#
# Sprint 6 の負の対照 —— **各検査が本当に赤にもなる**事を、実際に欠陥を植えて測る。
#
# なぜ要るか:
#   Sprint 6 で足した 60 本は全部緑で出た。緑は「欠陥が無い」の証拠ではなく
#   「今の実装とこの検査が一致している」の証拠でしかない。骨抜きの検査も同じ緑を出す。
#   この repo は既に3回それを踏んでいる(vacuous-gate が生まれた経緯、
#   `MockURLProtocol.requestedBodies` が永久に nil を比べていた件、
#   `check-reference` が基準点ごと壊れていた件)。
#   だから **実装を1行だけ壊して、名指しの検査が赤くなるか**を見る。
#   赤くならない検査は、その性質を測っていない。
#
# ★走らせ方について(Sprint 3/4 の対照との違いを明記する):
#   あちらは主作業木を触らず scratch に複製した。理由は「Generator が同じ木を
#   書き換えている最中にも走るから」。ここは事情が違う:
#     - 変異の対象は Swift の**本文**で、測るには xcodebuild が要る。
#       scratch に複製すると DerivedData が効かず、1回あたり数分 → 10 変異で 30 分超。
#     - 復元は走る前に取った複製が保証する。作業木で変異させ、複製から戻し、
#       **戻った事を git status で確かめる**(想定ではなく観測する)。
#   なので作業木で変異させる。ただし条件付きで:
#     - 走る前に対象 file の**中身を複製**し、復元はそこから戻す。
#     - trap EXIT で必ず復元。中断されても作業木は元に戻る。
#     - 最後に**複製と shasum が一致する事**を確かめ、違えば 2(未測定)で落ちる。
#
# ★復元の基準点を「index」から「走る前の中身」へ替えた(2026-08-06、測って直した)。
#   初版は「対象が dirty なら走らない」+ `git checkout --` で戻す形だった。これは
#   **この対照が commit の門から呼ばれた時に自分で自分を止める**:
#     `staged-controls-gate` はこの対照を `ios/Tests/…` が staged の時に選ぶ。
#     一方 Sprint 5/6 の commit の形は「検査と実装を同じ commit に入れる」なので、
#     その瞬間 `ios/Sources/…` は staged = `git status --porcelain` は非空 = dirty 判定。
#     → この対照が 2(未測定)で落ちる → 門は 2 を 0 に丸めないので **commit が止まる**。
#   実測(2026-08-06): `ReachabilityMeter.swift` に改行を1つ足して回すと
#     `UNMEASURED  変異の対象が最初から dirty` / rc=2。
#   index を基準にしたのが原因なので、index を見ない形へ直した。副産物として復元の確認も
#   強くなる —— `git status` が清潔なのは「index と一致」の意味しか無く、元から staged
#   だった file にはそもそも間違った問いだった。shasum の一致は**バイトが戻った事**を言う。
#
# 既知の費用(黙って隠さない): xcodebuild を 14 回(基準1 + 変異13)回すので **11 分前後**。
#   (2026-08-06 に DoD 1 の method / path / header を足して 10 → 13 になった。実測 471s → 下記)
#   commit の門から呼ばれるとその分待つ。`--no-verify` で外すのは、この repo が
#   一番繰り返している失敗の形なので、待つ側に倒してある。短くするなら「staged な物に
#   関わる変異だけ回す」だが、選び方を2箇所に持つ事になるので、実際に外されるまでやらない。
#
# 終了コード: 0=全変異が期待通り赤 / 1=赤くならない検査が在る / 2=測れなかった
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS="$ROOT/ios"
SIM_NAME="${SIM_NAME:-iPhone-dogfood}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dod-s6.XXXXXX")"
# 失敗した回の全文だけ WORK の外へ残す(WORK は EXIT で畳まれるので、中に置くと
# 「なぜ緑だったのか」を後から読めない)。
LOGDIR="${TMPDIR:-/tmp}"
PASS=0; FAIL=0; UNMEASURED=0

VM="$IOS/Sources/Screens/Conversation/ConversationViewModel.swift"
METER="$IOS/Sources/Core/ReachabilityMeter.swift"
ICLIENT="$IOS/Sources/Core/InterruptClient.swift"
LVM="$IOS/Sources/Screens/List/ListViewModel.swift"
TARGETS=("$VM" "$METER" "$ICLIENT" "$LVM")

# ---- 走る前に中身を複製する(= 復元の基準点。index ではない)-------------------
# 名前の衝突を避ける為に添字で持つ。`ConversationView.swift` と
# `ConversationViewModel.swift` の様に basename が近い物が在るので basename では置かない。
ORIG="$WORK/orig"
mkdir -p "$ORIG"
snap_path() { printf '%s/%s' "$ORIG" "$1"; }   # $1 = TARGETS の添字

restore_one() { # $1 = 添字
    # ★`local i="$1" f="${TARGETS[$i]}"` と1行に書かない事(2026-08-06、実測で捕まえた)。
    #   bash は `local` の**右辺を全部展開してから**代入するので、`${TARGETS[$i]}` の `$i` は
    #   まだ引数ではなく**呼び出し元の `i`** を読む。変異の loop から呼ぶと、直前の複製 loop が
    #   置いた global の `i=4`(範囲外)を引いて `set -u` で落ちた。
    #   ★この欠陥は `cleanup` に**隠されていた**: cleanup は `local i=0` を持つので、
    #     動的スコープでそちらを引いて正しく戻る。だから最後の「復元を確認」は緑のまま、
    #     途中の走行だけが死ぬ —— 後始末が効いている事を、本体が効いている証拠に読めない。
    local i="$1"
    local f s
    f="${TARGETS[$i]}"
    s="$(snap_path "$i")"
    [ -f "$s" ] || return 0
    /bin/cp "$s" "$f"
}

cleanup() {
    local i=0
    while [ "$i" -lt "${#TARGETS[@]}" ]; do
        restore_one "$i"
        i=$((i+1))
    done
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] || return 0
    find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$WORK" -type d -depth -exec /bin/rmdir {} + 2>/dev/null
}
trap cleanup EXIT

# 複製が取れない = 復元できない = 走ってはいけない。此処だけは走る前に止める。
i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    f="${TARGETS[$i]}"
    if [ ! -f "$f" ]; then
        echo "UNMEASURED  変異の対象が無い: ${f#$ROOT/}"
        exit 2
    fi
    if ! /bin/cp "$f" "$(snap_path "$i")"; then
        echo "UNMEASURED  複製を取れなかった: ${f#$ROOT/}(復元手段が無いので走らない)"
        exit 2
    fi
    i=$((i+1))
done

run_tests() {  # $@ = -only-testing の引数群。log の path を stdout に、rc を返す
    local log="$WORK/run-$RANDOM.log" rc=0
    xcodebuild -project "$IOS/RemoteMini.xcodeproj" -scheme RemoteMini \
        -configuration Debug -sdk iphonesimulator \
        -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$IOS/build" "$@" test >"$log" 2>&1 || rc=$?
    echo "$log"
    return $rc
}

# ---- 変異の一覧 ---------------------------------------------------------------
# 1行 = <id>|<file>|<perl の置換式>|<赤くなるはずの Class/test>|<何を壊したか>
#
# perl は -0777(file 丸ごと)で回す。**置換が0件なら「未測定」**で落とす ——
# 的が本文から外れたのを緑と読むのが、この repo が `check-mutation-targets.sh` を
# 作る事になった失敗そのものなので、ここでも同じ扱いにする。
MUTATIONS=()
MUTATIONS+=("choice-button|$VM|s/(case \.choice:\n            return )Self\.interruptAllowedOnChoiceScreen(\n        case \.sendable, \.busy)/\${1}true\${2}/|ConversationViewModelTests/testTheChoiceSentenceAndTheChoiceButtonMoveTogetherNegativeControl|CHOICE のボタンだけを開け、文はそのまま(片側だけ動かす)")
MUTATIONS+=("meter-substitution|$VM|s/(the deploy\.\n            )reachability\.recordSuccess\(\)/\${1}reachability.recordFailure()/|ConversationViewModelTests/testUnreadablePollsDriveTheOtherMeterAndNeverTheReachabilityOneNegativeControl|読めない 200 を到達性の失敗として数える(§5-5 で §5-4 を代用)")
MUTATIONS+=("unreachable-arm-inert|$VM|s/            reachability\.recordFailure\(\)\n            return true/            return true/|ConversationViewModelTests/testTwoPollTransportFailuresAreNotEnoughAndTheThirdRaisesTheBanner|poll の .unreachable 腕を Sprint 5 の「何もしない」に戻す")
MUTATIONS+=("banner-merge|$VM|s/            interruptBanner = SendBanner\(display: display\)/            sendBanner = SendBanner(display: display)/|ConversationViewModelTests/testAnInterruptOutcomeNeverTouchesTheSendBanner|割り込みの答えを送信の欄へ書く(欄を1つに畳む)")
MUTATIONS+=("banner-provenance|$VM|s/            interruptBanner = SendBanner\(display: display\)/            interruptBanner = SendBanner(locallyWorded: display.text, tone: display.tone)/|ConversationViewModelTests/testPhoneWordedInterruptBannersAreMarkedAsNotComingFromTheServerNegativeControl|文言は同じまま、出所だけ電話側にすり替える")
MUTATIONS+=("inflight-guard|$VM|s/        guard canInterrupt else \{ return \}/        guard interruptEnabled else { return }/|ConversationViewModelTests/testASecondPressWhileOneIsInFlightDoesNotLaunchASecondRequest|二度押しの門を外す(有効かどうかだけ見る)")
MUTATIONS+=("threshold-equality|$METER|s/consecutiveFailures >= Self\.unreachableThreshold/consecutiveFailures == Self.unreachableThreshold/|ReachabilityMeterTests/testTheBannerStaysUpPastTheThresholdNegativeControl|>= を == にする(4回目で banner が消える双子)")
MUTATIONS+=("recovery-decay|$METER|s/    mutating func recordSuccess\(\) \{\n        consecutiveFailures = 0\n    \}/    mutating func recordSuccess() {\n        consecutiveFailures = max(0, consecutiveFailures - 1)\n    }/|ReachabilityMeterTests/testRecoveryIsNotADecayNegativeControl|復帰を「即座に 0」から「1 ずつ減衰」にする")
MUTATIONS+=("threshold-fork|$LVM|s/    static var unreachableThreshold: Int \{ ReachabilityMeter\.unreachableThreshold \}/    static let unreachableThreshold = 4/|ReachabilityMeterTests/testListViewModelForwardsToThisThresholdRatherThanHoldingItsOwn|転送別名を「展開」して2本目の定数にする")
MUTATIONS+=("interrupt-body|$ICLIENT|s/(request\.setValue\(\"Bearer \\\\\(apiKey\)\", forHTTPHeaderField: \"Authorization\"\))/\${1}\n        request.setValue(\"application\/json\", forHTTPHeaderField: \"Content-Type\")\n        request.httpBody = Data(\"{}\".utf8)/|InterruptClientTests/testRequestCarriesNoBodyAndNoContentTypeWithAWorkingRecorderAsControl|割り込みに body と Content-Type を付ける")

# ---- DoD 1 の残り3次元(2026-08-06 追加)----------------------------------------
# Sprint 5 から持ち越していた穴: 「`InterruptClient` が POST / 正しい path /
# `Authorization` を出す」は**等値では見ている**が、その等値が効いているかは未測定だった。
# body 次元(上の `interrupt-body`)だけ植えて、残り3次元を植えていない状態は
# 「対照が在る」で安心して、対照が答えていない次元をそのまま残す形そのもの。
#
# ★3本とも受け止めるのは同じ1本の検査
# (`testRequestIsAPOSTToTheInterruptPathWithTheBearerKey` が3つの `XCTAssertEqual` を持つ)。
# だから**1本でも緑のまま残ったら、その行の等値が飾り**という読み方になる。
MUTATIONS+=("interrupt-method|$ICLIENT|s/request\.httpMethod = \"POST\"/request.httpMethod = \"PUT\"/|InterruptClientTests/testRequestIsAPOSTToTheInterruptPathWithTheBearerKey|POST を PUT にする(method 次元)")
MUTATIONS+=("interrupt-path|$ICLIENT|s#/interrupt\"\)#/stop\")#|InterruptClientTests/testRequestIsAPOSTToTheInterruptPathWithTheBearerKey|path の末尾を /interrupt から /stop にする(path 次元)")
MUTATIONS+=("interrupt-header|$ICLIENT|s/setValue\(\"Bearer \\\\\(apiKey\)\", forHTTPHeaderField/setValue(\"\\\\\(apiKey)\", forHTTPHeaderField/|InterruptClientTests/testRequestIsAPOSTToTheInterruptPathWithTheBearerKey|Authorization から Bearer の接頭辞を落とす(header 次元)")

# ---- 基準: 名指しの検査が、無変異では全部緑である事 ---------------------------
# 1回の xcodebuild にまとめる(1本ずつ回すと 10 倍かかる)。
BASE_ARGS=()
for m in "${MUTATIONS[@]}"; do
    IFS='|' read -r _id _file _expr _test _what <<<"$m"
    BASE_ARGS+=("-only-testing:RemoteMiniTests/$_test")
done
echo "== 基準(無変異): 名指しの ${#MUTATIONS[@]} 本"
base_rc=0
base_log="$(run_tests "${BASE_ARGS[@]}")" || base_rc=$?
base_passed="$(grep -cE "^Test Case .* passed" "$base_log" 2>/dev/null || echo 0)"
if [ "$base_rc" -ne 0 ]; then
    echo "UNMEASURED  無変異で既に赤(rc=$base_rc)。変異の赤と区別が付かないので止める。"
    echo "            全文: $base_log"
    cp "$base_log" "$LOGDIR/dod-s6-baseline.log" 2>/dev/null
    exit 2
fi
echo "   緑 $base_passed 本"
echo

# ---- 各変異 -------------------------------------------------------------------
# 変異の対象を TARGETS の添字へ引く。引けない = 複製が無い = 戻せないので走らない。
idx_of() {
    local i=0
    while [ "$i" -lt "${#TARGETS[@]}" ]; do
        [ "${TARGETS[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
        i=$((i+1))
    done
    return 1
}

for m in "${MUTATIONS[@]}"; do
    IFS='|' read -r id file expr test what <<<"$m"
    short="${file#$ROOT/}"

    if ! fi_idx="$(idx_of "$file")"; then
        echo "UNMEASURED  [$id] 変異の対象が TARGETS に無い: $short"
        echo "            = 複製を取っていない file なので戻せない。TARGETS へ足す事。"
        UNMEASURED=$((UNMEASURED+1))
        continue
    fi

    before="$(shasum -a 256 "$file" | cut -c1-16)"
    perl -0777 -pi -e "$expr" "$file"
    after="$(shasum -a 256 "$file" | cut -c1-16)"

    if [ "$before" = "$after" ]; then
        echo "UNMEASURED  [$id] 置換が1件も当たらなかった: $short"
        echo "            = 変異の的が本文から外れている。緑と読んではいけない。"
        UNMEASURED=$((UNMEASURED+1))
        restore_one "$fi_idx"
        continue
    fi

    rc=0
    log="$(run_tests "-only-testing:RemoteMiniTests/$test")" || rc=$?
    restore_one "$fi_idx"

    if [ "$rc" -ne 0 ]; then
        echo "PASS  [$id] $test が赤くなった"
        echo "      壊した物: $what"
        PASS=$((PASS+1))
    else
        echo "FAIL  [$id] 実装を壊しても $test は緑のまま"
        echo "      壊した物: $what"
        cp "$log" "$LOGDIR/dod-s6-$id.log" 2>/dev/null
        echo "      = この検査はその性質を測っていない。全文: $LOGDIR/dod-s6-$id.log"
        FAIL=$((FAIL+1))
    fi
done

# ---- 復元の確認(想定ではなく観測する) ---------------------------------------
# ★`git status` が清潔である事ではなく、**走る前のバイトと一致する事**を見る。
#   前者は「index と一致」の意味しか無く、元から staged だった file には答えにならない
#   —— 変異が残っていても index と一致していれば清潔に見える、という逆向きの穴も在る。
echo
not_restored=""
i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    f="${TARGETS[$i]}"
    now="$(shasum -a 256 "$f" | cut -d' ' -f1)"
    was="$(shasum -a 256 "$(snap_path "$i")" | cut -d' ' -f1)"
    [ "$now" = "$was" ] || not_restored="$not_restored ${f#$ROOT/}"
    i=$((i+1))
done
if [ -n "$not_restored" ]; then
    echo "UNMEASURED  変異が作業木に残っている:$not_restored"
    echo "            = 変異ごとの復元が効いていない(此処は trap が走る**前**なので、"
    echo "              測っているのは「その都度戻したか」であって「最後に片付くか」ではない)。"
    echo "            この直後の trap が複製から戻すが、戻った事はこの回では測れていない。"
    exit 2
fi
echo "復元を確認(対象 ${#TARGETS[@]} file すべて走る前のバイトと一致)"

echo "== PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED"
[ "$UNMEASURED" -gt 0 ] && exit 2
[ "$FAIL" -gt 0 ] && exit 1
exit 0
