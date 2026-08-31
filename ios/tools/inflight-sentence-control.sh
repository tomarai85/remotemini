#!/bin/bash
# controls-for: ios/Sources/Screens/Conversation/ConversationViewModel.swift ios/Sources/Screens/Conversation/ConversationView.swift ios/Tests/Screens/Conversation/ConversationViewModelTests.swift ios/Tests/Screens/Conversation/ConversationViewTests.swift
#
# 「飛んでいる間」の**文**と、押した鍵の**印**の負の対照(DESIGN §2.56)。
# 割り込みと打鍵が要求を投げてから返事が来るまでの最大30秒、画面が何を言うか —— その
# 検査10本が、実装に欠陥を植えた時に本当に赤くなるかを測る。
#
# なぜ要るか(2026-08-08):
#   §2.56 が足したのは「無言だった窓に一文を置く」だけの、見た目は小さな節。だが
#   S8-5 で判ったばかりの形が此処にも在る —— **文が出ない実装でも、文の**内容**を
#   測る検査は緑になり得る**。`interruptInFlightNotice` が常に `nil` を返しても、
#   静的な文言だけを突く検査(`interruptInFlightText(timeout:)` を直接呼ぶ物)は
#   一切気付かない。窓の中で観測する検査と、文言を組み立てる検査は別物で、
#   前者が死んでも後者が緑を出し続ける。だから前者を名指しで撃つ。
#
# ★この対照が「2つ在る」理由(片方だけでは通る欠陥が在る):
#   打鍵の「飛んでいる間」は2つの独立した物で出来ている ——
#     (a) 文    = `choiceInFlightNotice`(飛んでいる事)
#     (b) 印    = `ConversationView.spins`(**どれを**押したか)
#   M2 は (a) を殺し、M4 は (b) を殺す。probe はそれぞれで**もう片方が緑のまま**で
#   ある事を明示的に assert する。つまり「文は出るが全ボタンが一斉に回る」版も
#   「どれか1つだけ回るが何も言わない」版も、片側の検査だけでは緑で通る事を、
#   主張ではなく**この走行の実測**として出す。
#
# 何を測るか(変異 -> 赤くなるべき検査):
#   M1 `interruptInFlightNotice` が常に nil  -> 割り込みの文の検査が赤
#   M2 `choiceInFlightNotice` が常に nil     -> 打鍵の文の検査が赤
#      ★同時に「押した鍵だけが回る」検査は**緑のまま**である事を確かめる(上記)
#   M3 秒数を直書き(30)に変える              -> 「文の秒数は writeTimeout から来る」が赤
#      ★#26 の題は当初「8秒」と登録されていた。実測では割り込みも打鍵も
#        `BackendSession.writeTimeout` = 30秒で、8秒(`interactiveTimeout`)は**読みだけ**。
#        今たまたま 30 なので、直書きしても文面は基準と同一になる —— 定数が動いた日に
#        黙って古くなる形。それを掴めるかが此処の的。
#   M4 `spins` が `inFlight != nil` になる    -> 「押した鍵だけが回る」検査が赤
#      ★同時に打鍵の文の検査は**緑のまま**である事を確かめる(上記)
#   M5 答えが出た後に文を消す行を殺す         -> 「待ちの文を残さない」検査が赤
#      ★一番要る錨。待ちの文が残ると、**答えの顔をした待ち**になる —— 画面は
#        「送っています」と言い続け、利用者は返事が来ていない物と読む。
#        鈍い変異で、打鍵に関わる他の検査も同時に赤くなる(`inFlightChoiceKey` が
#        二度と nil に戻らないので `choiceEnabled` が永久に偽)。だから主張は
#        「的の検査**だけ**が赤」ではなく「的の検査が赤の中に居る」。
#
# 費用(隠さない): xcodebuild を6回(基準1 + 変異5)。ただし **UI 検査ではなく単体**を
#   2 class だけ(`-only-testing`)撃つので、姉家族の
#   `ios/tools/list-return-refresh-control.sh`(約8分)や
#   `ios/tools/conversation-ui-control.sh`(約3.6分)より軽い。実測値は
#   `rc-backend/tools/run-controls.sh` の登録行に書く。
#
# ★目印(INFLIGHT)は ios の変異対照で**共有**する。此処が変異させる
#   `ConversationViewModel.swift` は `conversation-ui-control.sh` と
#   `.harness/dod-sprint-6-controls.sh` も変異させるので、目印を分けると
#   片方の取り残しをもう片方が「走る前の中身」として複製し、復元の基準点ごと汚れる。
#   ズレは `rc-backend/test/mutation-recovery-copy.test.mjs` が毎 commit 測る。
#
# ★「検査が一度も走っていない」を別の事として扱う(2026-08-08 実測)。M1 の走行だけが
#   simulator の preflight に Busy で蹴られ(前の走行の app が終了しきる前に次の launch が
#   来た)、xcodebuild は非0で終わったが検査は**1本も走っていない**。判定自体は
#   UNMEASURED で正しかったが、理由が「赤くはなったが的ではない(赤: なし)」と出て、
#   読む側には**変異を捕まえられなかった**様に見える —— 探し文を疑って直しに行く事に
#   なる。実際には探し文は当たっていて、測定が起きなかっただけ。
#   走った本数が 0 の時だけ、app を落としてから1度取り直し、それでも 0 なら
#   「一度も走っていない」と名指しで UNMEASURED にする。
#   ★取り直す条件が「走った本数 0」**だけ**である事が肝心。赤い assertion を
#     取り直しに流用できる形にすると、この対照は嘘を隠す道具に変わる。だから
#     `run_unit` は赤緑の集合を一切見ない(見えるのは本数だけ)。
#
# 終了コード: 0=全変異が期待通り赤 / 1=赤くならない検査が在る / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
ROOT="$(cd "$HERE/.." && pwd)"
IOS="$HERE"
# ★機の既定は tools/sim-device.sh が持つ(2026-08-26)。此処で直に dogfood を既定に
#   していた間、`xcodebuild test` が対照のたびに **Tom が見る機**へ種なしの Debug 版を
#   install していた。守りを1箇所へ寄せる —— 既定・dogfood の拒否・機の不在を全部あちらで。
# ★$HERE(= ios/、先頭で絶対解決済み)から引く。BASH_SOURCE を此処で引き直すと、
#   相対 path で起動された時に `cd` 後の評価になって source が空振りする。
. "$HERE/tools/sim-device.sh"
BUNDLE_ID="com.tomarai.remotemini"
# UDID が読めなくても走る(落ち着かせる手順を飛ばすだけ)。此処で止めると、元は
# 動いていた対照を「測れない」に変えてしまう —— 直そうとした欠陥をこちら側で作る事になる。
SIM_UDID="$(xcrun simctl list devices 2>/dev/null | grep -F "$SIM_NAME (" | head -1 \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/inflight-sentence.XXXXXX")"
LOGDIR="${TMPDIR:-/tmp}"
INFLIGHT="${TMPDIR:-/tmp}/rc-ios-mutation-inflight.tsv"
PASS=0; FAIL=0; UNMEASURED=0

# ★書き換え先は**砂場**。作業中の木は1バイトも触らない(CF-12 / CF-21)。
#   殺されても木に変異は残らない —— trap が走るかどうかに安全が依存しなくなる。
#   土台と、其の選択の理由(A/B/C の比較と実測)は `ios/tools/mutation-sandbox.sh`。
. "$IOS/tools/mutation-sandbox.sh"
ms_prepare || exit 2
VM="$MS_TREE/Sources/Screens/Conversation/ConversationViewModel.swift"
CV="$MS_TREE/Sources/Screens/Conversation/ConversationView.swift"
TARGETS=("$VM" "$CV")

# 基準で緑である事を確かめる的。**件数ではなく実名**で錨を打つ(数を発明しない)。
WANT_INT=testTheInterruptInFlightStageSaysSomethingRatherThanSpinningSilently
WANT_CHO=testTheChoiceInFlightStageSaysSomethingRatherThanGoingGrey
WANT_SEC=testTheTwoNewInFlightSentencesAreBuiltFromTheRealTimeout
WANT_SPIN=testOnlyThePressedKeySpins
WANT_CLEAR=testTheChoiceInFlightLineIsGoneEvenOnThePathThatReportsNothing

ORIG="$WORK/orig"
mkdir -p "$ORIG"
snap_path() { printf '%s/%s' "$ORIG" "$1"; }   # $1 = TARGETS の添字

restore_one() { # $1 = 添字
    # ★`local i="$1" f="${TARGETS[$i]}"` と1行に書かない事。bash は local の右辺を
    #   全部展開してから代入するので、`$i` は引数ではなく**呼び出し元の i** を読む。
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
    # 目印は復元より**後**に消す。逆だと、消した直後に殺された時に
    # 「戻っていないのに手掛かりも無い」状態が作れる。
    /bin/rm -f "$INFLIGHT"
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] || return 0
    find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$WORK" -type d -depth -exec /bin/rmdir {} + 2>/dev/null
}
# ★生成物(ios/Info.plist / RemoteMini.xcodeproj)を触る走行を **1 本に絞る**。
# 2026-08-15、此れが無くて `build.sh --sim` と此の台本が `RC_BUILD_REV` の刻印を
# 潰し合い、**偽の赤が 9 本**出た(製品の欠陥と見分けが付かない赤)。
# 取れなければ此処で非零終了する = 生成物に触らないまま止まる。
# ★生成木の錠は**要らなくなった**。此の台本は生成木を触らないので、
#   握れば他の台本を無駄に待たせるだけ。直列化は砂場側の錠が持つ(`ms_prepare`)。
trap 'cleanup; ms_release' EXIT

# ---- 前回の走行が殺されていたら、その取り残しを先に戻す(ここから)-------------
# ★この位置でなければならない: 下の複製 loop より**前**。後に置くと、変異したバイトを
#   「走る前の中身」として複製してしまい、復元の基準点そのものが汚染される。
if [ -f "$INFLIGHT" ]; then
    recovered=""; lost=""
    while IFS="$(printf '\t')" read -r rf rs; do
        [ -n "${rf:-}" ] || continue
        if [ -f "$rs" ] && [ -f "$rf" ]; then
            if ! cmp -s "$rs" "$rf"; then
                /bin/cp "$rs" "$rf"
                recovered="$recovered ${rf#$ROOT/}"
            fi
        else
            lost="$lost ${rf#$ROOT/}"
        fi
    done < "$INFLIGHT"
    /bin/rm -f "$INFLIGHT"
    if [ -n "$recovered" ]; then
        echo "復旧: 前回の走行が殺されて残っていた変異を戻した:$recovered"
    fi
    if [ -n "$lost" ]; then
        echo "UNMEASURED  前回の変異を戻せない(複製が消えている):$lost"
        echo "            何が変わっているかは git diff で見え、戻すのは git checkout -- で足りる。"
        exit 2
    fi
fi
# ---- 前回の取り残しの復旧(ここまで)-----------------------------------------

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

# 複製が全部取れた**後**に目印を書く。先に書くと、複製に失敗して exit 2 した回が
# 「戻せる複製が在る」と嘘の申告を残す。
: > "$INFLIGHT"
i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    printf '%s\t%s\n' "${TARGETS[$i]}" "$(snap_path "$i")" >> "$INFLIGHT"
    i=$((i+1))
done

restore_all() {
    local j=0
    while [ "$j" -lt "${#TARGETS[@]}" ]; do
        restore_one "$j"
        j=$((j+1))
    done
}

ok() { PASS=$((PASS+1)); echo "  OK   $1"; }
ng() { FAIL=$((FAIL+1)); echo "  NG   $1"; }
un() { UNMEASURED=$((UNMEASURED+1)); echo "  UNM  $1"; }

# 走った検査の本数。0 = **一度も走っていない**(ビルドが通らない / simulator が
# 起動を拒んだ、のどちらも此処に落ちる)。赤緑の別を見ない事に意味が在る ——
# 取り直しの判断がこの値**しか**見ないので、落ちた assertion を取り直しに
# 流用できる形が構造上作れない。
ran_count() { # $1 = log path
    local n
    n="$(grep -cE "Test Case '-\[RemoteMiniTests\." "$1" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

# 前の走行の app が終了しきる前に次の launch が来ると、SpringBoard が preflight を
# Busy で蹴る。UDID が読めなければ何もしない(上記)。
settle_sim() {
    [ -n "${SIM_UDID:-}" ] || return 0
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

run_unit_once() { # $1 = log path -> rc を印字
    local log="$1" rc=0
    # ★砂場で焼く。derived data も砂場側に持つので、生成木と潰し合わない。
    #   固定 path なので温かいまま —— 実測: 変異を植てての再ビルド **4 秒**
    #   (作業中の木を使っていた頃の此の対照は 86 秒だった)。
    ( cd "$MS_TREE" && xcodegen generate >/dev/null 2>&1 && \
      xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$MS_ROOT/build" \
        -only-testing:RemoteMiniTests/ConversationViewModelTests \
        -only-testing:RemoteMiniTests/ConversationViewTests test ) >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ★診断を stdout に書かない事。呼び出し側は `rc=$(run_unit …)` で**標準出力を
#   そのまま rc として読む**ので、1行混ぜるだけで rc が壊れて全部の probe が狂う。
run_unit() { # $1 = log path -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(run_unit_once "$log")"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(run_unit_once "$log")"
    fi
    printf '%s' "$rc"
}

# ★module 名まで付けた形で探す事。log の行は `-[RemoteMiniTests.ConversationViewModelTests …]`
#   で、class 名だけで grep すると 2 class を跨いだ時に取りこぼす。
extract() { # $1 = log, $2 = passed|failed
    grep -oE "Test Case '-\[RemoteMiniTests\.(ConversationViewModelTests|ConversationViewTests) [a-zA-Z0-9_]+\]' $2" "$1" \
        | sed -E "s/^.*Tests ([a-zA-Z0-9_]+)\].*$/\1/" | sort -u | tr '\n' ' '
}
passed_tests() { extract "$1" passed; }
failed_tests() { extract "$1" failed; }

has() { # $1 = 空白区切りの一覧, $2 = 名前
    case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

echo "=== 基準(変異なし)"
BASE_LOG="$LOGDIR/inflight-sentence-base.log"
rc=$(run_unit "$BASE_LOG")
if [ "$(ran_count "$BASE_LOG")" -eq 0 ]; then
    un "基準で検査が一度も走っていない(2度試して 0 本)= 機械の側が動いていない。実装については何も測っていない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
if [ "$rc" -ne 0 ]; then
    un "基準が緑でない(rc=$rc)。以降は測れない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
BASE_PASSED="$(passed_tests "$BASE_LOG")"
for w in "$WANT_INT" "$WANT_CHO" "$WANT_SEC" "$WANT_SPIN" "$WANT_CLEAR"; do
    if ! has "$BASE_PASSED" "$w"; then
        un "基準で的の検査が緑になっていない: $w"
        echo "    (基準の緑は $(printf '%s' "$BASE_PASSED" | wc -w | tr -d ' ') 本。全文: $BASE_LOG)"
        echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
        exit 2
    fi
done
ok "基準: 的の検査が5本とも緑(この走行の緑は全部で $(printf '%s' "$BASE_PASSED" | wc -w | tr -d ' ') 本)"

# ---- 変異 M1: 割り込みの文が出なくなる ----------------------------------------
# 三項をやめて常に nil。窓の中で観測する検査だけが赤くなり、文言を組み立てる
# `interruptInFlightText(timeout:)` を直接呼ぶ検査は緑のまま = そこが此処の的。
mutate_m1() {
    /usr/bin/sed -i '' \
        's|^        isInterrupting ? Self.interruptInFlightText(timeout: BackendSession.writeTimeout) : nil$|        nil|' "$VM"
}
# ---- 変異 M2: 打鍵の文が出なくなる --------------------------------------------
mutate_m2() {
    /usr/bin/sed -i '' \
        's|^        inFlightChoiceKey == nil ? nil : Self.choiceInFlightText(timeout: BackendSession.writeTimeout)$|        nil|' "$VM"
}
# ---- 変異 M3: 秒数を直書きにする ----------------------------------------------
# `\(Int(timeout))` を `30` に潰す。今の `writeTimeout` は 30 なので**文面は変わらない**
# —— 定数が動いた日にだけ嘘になる形を、動かした値(45)で掴めるか測る。
mutate_m3() {
    /usr/bin/sed -i '' '/static func interruptInFlightText/,/^    }$/ s|\\(Int(timeout))|30|' "$VM"
}
# ---- 変異 M4: 全部のボタンが回る ----------------------------------------------
mutate_m4() {
    /usr/bin/sed -i '' '/static func spins/,/^    }$/ s|inFlight == key|inFlight != nil|' "$CV"
}
# ---- 変異 M5: 答えが出ても待ちの文が消えない ----------------------------------
mutate_m5() {
    /usr/bin/sed -i '' '/func applyChoiceAttempt/,/^    }$/ { /^        inFlightChoiceKey = nil$/d; }' "$VM"
}

probe() { # $1=名前 $2=変異する関数 $3=変異が当たる file $4=赤くなるべき検査 $5=(任意)緑のままであるべき検査
    local name="$1" fn="$2" target="$3" want="$4" stays="${5:-}"
    restore_all
    local before after
    before=$(shasum "$target" | awk '{print $1}')
    "$fn"
    after=$(shasum "$target" | awk '{print $1}')
    # ★バイトが動かない = 探し文が今の本文に当たらない(改名・整形で静かに外れる)。
    #   これを緑にすると「変異を植えても赤くならない」を「検査が強い」と読む事になる。
    if [ "$before" = "$after" ]; then
        un "$name: 変異が当たっていない(bytes が動かない)= 測っていない。探し文を付け直す事"
        return
    fi
    local log="$LOGDIR/inflight-sentence-$name.log" rc
    rc=$(run_unit "$log")
    # ★「走っていない」を「捕まえられなかった」と混ぜない。混ぜると、探し文が
    #   当たっているのに探し文を疑いに行く事になる(2026-08-08 の M1 が正にそれ)。
    if [ "$(ran_count "$log")" -eq 0 ]; then
        un "$name: 検査が一度も走っていない(2度試して 0 本)= 変異の当たり外れは測っていない。全文: $log"
        restore_all
        return
    fi
    local reds greens
    reds="$(failed_tests "$log")"
    greens="$(passed_tests "$log")"
    if [ "$rc" -eq 0 ]; then
        ng "$name: 欠陥を植えたのに全部緑。$want は $name を測っていない。全文: $log"
    elif has "$reds" "$want"; then
        ok "$name -> 赤: $reds"
        # 片側だけでは通る欠陥が在る事を、主張ではなく**この走行の実測**で出す。
        if [ -n "$stays" ]; then
            if has "$greens" "$stays"; then
                echo "       (実演: $stays は**緑のまま** = 片側の検査だけでは此の欠陥は通る)"
            else
                un "$name: 対になる検査 $stays まで赤くなった = 2本が別の物を測っている実演にならない"
            fi
        fi
    else
        un "$name: 赤くはなったが $want ではない(赤: ${reds:-なし}, rc=$rc)。全文: $log"
    fi
    restore_all
}

probe M1-interrupt-sentence-gone mutate_m1 "$VM" "$WANT_INT"
probe M2-choice-sentence-gone    mutate_m2 "$VM" "$WANT_CHO"  "$WANT_SPIN"
probe M3-seconds-hardcoded       mutate_m3 "$VM" "$WANT_SEC"
probe M4-every-key-spins         mutate_m4 "$CV" "$WANT_SPIN" "$WANT_CHO"
probe M5-waiting-sentence-stays  mutate_m5 "$VM" "$WANT_CLEAR"

# ---- 復元の確認(想定ではなく観測する) ---------------------------------------
# 此処は trap が走る**前**なので、戻っていなければ此処で言える。
restore_all
not_restored=""
i=0
while [ "$i" -lt "${#TARGETS[@]}" ]; do
    if ! cmp -s "$(snap_path "$i")" "${TARGETS[$i]}"; then
        not_restored="$not_restored ${TARGETS[$i]#$ROOT/}"
    fi
    i=$((i+1))
done
if [ -n "$not_restored" ]; then
    echo "UNMEASURED  変異が作業木に残っている:$not_restored"
    echo "            = 変異ごとの復元が効いていない。git diff で中身、git checkout -- で戻る。"
    UNMEASURED=$((UNMEASURED+1))
else
    echo "復元を確認(対象 ${#TARGETS[@]} file すべて走る前のバイトと一致)"
fi

# ★走行が**本物の木を1バイトも触っていない**事を測る(Codex 2026-08-30 の指摘4)。
#   「触らない設計だから触っていない」は証明ではない —— 設計が守られたかを測る。
#   走行中に本物が変わったなら、対照が触ったか別の何かが同時に触ったかで、
#   どちらでも結果は stale。緑を出さない。
if ! ms_assert_live_unchanged; then
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $((UNMEASURED + 1)) ---"
    echo "★本物の木が走行中に変わった = 此の走行の結果は使えない"
    exit 2
fi
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
