#!/bin/bash
# controls-for: ios/UITests/ConversationUITests.swift ios/Sources/Core/PollFixture.swift ios/Sources/Core/HistoryFixture.swift ios/Sources/Screens/Conversation/ConversationViewModel.swift
#
# 会話画面の UI 検査(ios/UITests/ConversationUITests.swift)の**負の対照** ——
# あの4本が本当に赤にもなるかを、実装に欠陥を植えて測る。
#
# なぜ要るか(2026-08-06、書いた当夜に実際に踏んだ):
#   会話画面は v1 の中心(一覧 / 履歴+ライブ / 打ち込む / 割り込む の後ろ3つが全部ここ)
#   なのに、UI 層の検査が**1本も無かった**。書けなかった理由は fixture の側に在る:
#   `PollFetchingFixture` は全状態で `.unreadable` を返し続けるので
#   `ConversationViewModel.screen` が永久に nil、つまり composer / 割り込みの可否表
#   —— 画面の形を決めている規則そのもの —— に UI から触れる道が無かった。
#   fixture に readable な状態を2つ(busy / choice)足して初めて書けた。
#
#   そして書いた4本の初版は**空振りだった**。`composerEnabled` も `interruptEnabled` も
#   `guard let screen else { return true }` を持つので、BUSY と「まだ screen を観測して
#   いない」は画面上まったく同じ。fixture が readable な応答を返そうが返すまいが
#   `testBusyLeavesBothTheComposerAndTheInterruptButtonUsable` は緑になる。
#   緑が「欠陥が無い」でなく「何も繋がっていない」を意味していた。
#   直しは fixture 側 —— readable な応答に**ライブの行を1本**載せ、UI テストは
#   先にその行の出現を待つ(錨)。錨が出ない = 応答が適用されていない = 以降の主張は
#   何も測っていない、と読める形にした。
#
#   この対照は、その錨が本当に効いている事を**変異で**確かめる。特に M2 が要:
#   fixture の readable の枝を殺すと、錨が無い版では緑のままだった検査が赤になる。
#
# 何を測るか(変異 → 赤くなるべき検査):
#   M1 BUSY で composer を止める  -> testBusyLeavesBothTheComposerAndTheInterruptButtonUsable
#   M2 fixture の readable を殺す -> 同上(= 錨が空振りを捕まえる事の直接の証拠)
#   M3 CHOICE でも composer を生かす -> testChoiceDisablesTheComposerAndSaysWhy
#
# 走らせ方(dod-sprint-6-controls.sh と同じ理由で**作業木を変異させる**):
#   scratch へ複製すると DerivedData が効かず1回あたり数分になる。復元は走る前に取った
#   複製が保証し、最後に shasum の一致で**戻った事を観測する**(想定しない)。
#   trap EXIT は SIGKILL では走らない(向こうの header の実測どおり)ので、
#   取り残しは「次に起きた側が拾う」= 下の復旧区間で受ける。
#
# ★目印(INFLIGHT)は ios の変異対照で**共有**する。理由: この対照と
#   `.harness/dod-sprint-6-controls.sh` は同じ `ConversationViewModel.swift` を変異させる。
#   目印を別々に持つと、片方が殺されて残した変異を、もう片方が「走る前の中身」として
#   複製してしまう —— 復元の基準点が汚染され、以後その変異は誰にも戻せない。
#   共有して安全なのは、この2本が**直列にしか走らない**から(commit の門は
#   `staged-controls-gate.sh` の `for c in $sel` で1本ずつ、全掃きは
#   `run-controls.sh` の `for c in "${list[@]}"` で1本ずつ)。並行に走らせる口が
#   出来た日は、ここが最初に壊れる。
#
# 既知の費用(隠さない): xcodebuild を4回(基準1 + 変異3)。実測 2026-08-06、
#   DerivedData が温まっている状態で 基準 37s / 変異 39s・48s・49s = **合計 3.6 分**。
#   同じ commit が ios/Sources を大きく触って DerivedData が無効化されると基準が
#   素からになるので、その分伸びる(dod-sprint-6 の実測では 4.1 分 -> 27.5 分)。
#   待つ側の規則は数字に依存しない形にしてある: **この門を待つ commit は前景で
#   timeout を掛けず、背景で回して終了を待つ**。
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/conv-ui.XXXXXX")"
# 失敗した回の全文だけ WORK の外へ残す(WORK は EXIT で畳まれる)。
LOGDIR="${TMPDIR:-/tmp}"
# 殺された回の後始末に使う目印。**固定 path** である事が全て。名前に sprint も
# 対照名も入れないのは、上に書いた通り ios の変異対照で共有する物だから。
INFLIGHT="${TMPDIR:-/tmp}/rc-ios-mutation-inflight.tsv"
PASS=0; FAIL=0; UNMEASURED=0

# ★書き換え先は**砂場**(2026-08-30、CF-21 の移行)。作業中の木は1バイトも触らない。
. "$IOS/tools/mutation-sandbox.sh"
ms_prepare || exit 2
VM="$MS_TREE/Sources/Screens/Conversation/ConversationViewModel.swift"
PF="$MS_TREE/Sources/Core/PollFixture.swift"
TARGETS=("$VM" "$PF")

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
# ★生成木の錠は要らない(砂場で焼くので生成木を触らない)。直列化は砂場側の錠が持つ。
trap 'cleanup; ms_release' EXIT

# ---- 前回の走行が殺されていたら、その取り残しを先に戻す(ここから)-------------
# ★この位置でなければならない: 下の複製 loop より**前**。後に置くと、変異したバイトを
#   「走る前の中身」として複製してしまい、復元の基準点そのものが汚染される。
# ★目印は ios の変異対照で共有なので、ここで戻すのは**他の対照が残した**変異かもしれない。
#   戻し方は同じ(複製から書き戻す)ので区別は要らない。
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
        # 複製が消えている = 戻せない。清潔だと言い張らず、測れなかったと言う。
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

run_ui() { # $1 = log path -> rc を印字
    local log="$1" rc=0
    # ★砂場で焼く。derived data も砂場側(固定 path なので温かいまま)。
    ( cd "$MS_TREE" && xcodegen generate >/dev/null 2>&1 && \
      xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$MS_ROOT/build" \
        -only-testing:RemoteMiniUITests/ConversationUITests test ) >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ★module 名を付けた形で探す事。log の行は `-[RemoteMiniUITests.ConversationUITests …]`
#   で、class 名だけで grep すると**1件も当たらない** = 「走っていない」と読み違える
#   (2026-08-06、実際に一度そう読みかけた)。
passed_tests() { # $1 = log
    grep -oE "Test Case '-\[RemoteMiniUITests\.ConversationUITests [a-zA-Z]+\]' passed" "$1" \
        | sed 's/.*ConversationUITests //; s/\]. passed//' | sort -u | tr '\n' ' '
}
failed_tests() { # $1 = log
    grep -oE "Test Case '-\[RemoteMiniUITests\.ConversationUITests [a-zA-Z]+\]' failed" "$1" \
        | sed 's/.*ConversationUITests //; s/\]. failed//' | sort -u | tr '\n' ' '
}

echo "=== 基準(変異なし)"
BASE_LOG="$LOGDIR/conv-ui-base.log"
rc=$(run_ui "$BASE_LOG")
if [ "$rc" -ne 0 ]; then
    un "基準が緑でない(rc=$rc)。以降は測れない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
# 錨は**件数の下限ではなく実名**。数を書くと検査を1本足した日に此処が UNMEASURED で
# 落ち、数を緩めると1本も走っていない log も通る。下の変異が名指しする検査が
# 基準で確かに走って緑だった事だけを言う(vacuous-scan.py の言う「数字を発明しない錨」)。
BASE_PASSED="$(passed_tests "$BASE_LOG")"
missing=""
for want in testBusyLeavesBothTheComposerAndTheInterruptButtonUsable \
            testChoiceDisablesTheComposerAndSaysWhy; do
    case " $BASE_PASSED " in *" $want "*) ;; *) missing="$missing $want" ;; esac
done
if [ -n "$missing" ]; then
    un "基準で変異の的になる検査が緑になっていない:$missing(実測: ${BASE_PASSED:-なし})"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
ok "基準: 的の検査が緑($BASE_PASSED)"

# 範囲を切らずに置換すると `composerDisabledReason` の同じ綴りの行にも当たり、
# switch が非網羅になって**コンパイルが落ちる**(= 赤の理由が変異でなくなる)。
# だから `var composerEnabled` の本体だけに限定する。
CE='/var composerEnabled: Bool {/,/^    }$/'

# ---- 変異 M1: BUSY で composer を止める --------------------------------------
mutate_m1() {
    /usr/bin/sed -i '' "$CE"' s/^        case \.choice, \.unknown:$/        case .choice, .unknown, .busy:/' "$VM"
    /usr/bin/sed -i '' "$CE"' s/^        case \.sendable, \.busy, \.unrecognized:$/        case .sendable, .unrecognized:/' "$VM"
}
# ---- 変異 M2: readable の枝を殺す(BUSY を unreadable 側へ戻す)---------------
mutate_m2() {
    /usr/bin/sed -i '' 's/^        case \.busy: return \.busy$/        case .busy: return nil/' "$PF"
}
# ---- 変異 M3: CHOICE でも composer を生かす ----------------------------------
mutate_m3() {
    /usr/bin/sed -i '' "$CE"' s/^        case \.choice, \.unknown:$/        case .unknown:/' "$VM"
    /usr/bin/sed -i '' "$CE"' s/^        case \.sendable, \.busy, \.unrecognized:$/        case .sendable, .busy, .unrecognized, .choice:/' "$VM"
}

probe() { # $1=名前 $2=変異する関数 $3=赤くなるべき検査名 $4=変異が当たる file
    local name="$1" fn="$2" want="$3" target="$4"
    restore_all
    local before after
    before=$(shasum "$target" | awk '{print $1}')
    "$fn"
    after=$(shasum "$target" | awk '{print $1}')
    # ★バイトが動かない = 探し文が今の本文に当たらない(改名・整形で静かに外れる)。
    #   これを緑にすると「変異を植てても赤くならない」を「検査が強い」と読む事になる。
    if [ "$before" = "$after" ]; then
        un "$name: 変異が当たっていない(bytes が動かない)= 測っていない。探し文を付け直す事"
        return
    fi
    local log="$LOGDIR/conv-ui-$name.log" rc
    rc=$(run_ui "$log")
    local reds; reds="$(failed_tests "$log")"
    if [ "$rc" -eq 0 ]; then
        ng "$name: 欠陥を植えたのに全部緑。$want は $name を測っていない。全文: $log"
    elif printf '%s' "$reds" | grep -q "$want"; then
        ok "$name -> 赤: $reds"
    else
        un "$name: 赤くはなったが $want ではない(赤: ${reds:-なし}, rc=$rc)。全文: $log"
    fi
    restore_all
}

probe M1-busy-composer-disabled mutate_m1 testBusyLeavesBothTheComposerAndTheInterruptButtonUsable "$VM"
probe M2-readable-branch-killed mutate_m2 testBusyLeavesBothTheComposerAndTheInterruptButtonUsable "$PF"
probe M3-choice-composer-enabled mutate_m3 testChoiceDisablesTheComposerAndSaysWhy "$VM"

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

if ! ms_assert_live_unchanged; then
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $((UNMEASURED + 1)) ---"
    echo "★本物の木が走行中に変わった = 此の走行の結果は使えない"
    exit 2
fi
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
