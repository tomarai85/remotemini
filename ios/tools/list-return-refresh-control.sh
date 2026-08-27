#!/bin/bash
# controls-for: ios/UITests/RemoteMiniUITests.swift ios/Sources/Screens/List/ListView.swift ios/Sources/Core/SessionsListingFixture.swift ios/Sources/Screens/Shared/ForegroundResume.swift
#
# 一覧が**いつ取り直すか**の負の対照 —— 会話から戻った時(引き金 #5)と背面から
# 戻った時(引き金 #3)の2本の UI 検査が、本当に赤にもなるかを、実装に欠陥を植えて測る。
#
# なぜ要るか(2026-08-08):
#   この節が触ったのは `refresh()` の中身ではなく **`ListView` の配線**。`refresh()`
#   は何も変わっておらず、同じ応答なら `phase` も同じ値に落ち着くので、「取り直した」と
#   「取り直していない」は画面上まったく同じになる。つまり ViewModel の検査では届かず、
#   UI 検査も**器が要る**: fixture の scan 行に取得の通し番号を載せて初めて、取得回数が
#   画面から読める。
#
#   器を足した検査には固有の失敗の形が在る —— **器が死ぬと検査が静かに緑になる**。
#   M3 はその形を、主張ではなく実測として此処に出す(下記)。
#
# ★この対照が今の形をしている理由(S8-5 の一番高い授業料):
#   会話画面の N4「背面から戻ったら読み直す」は Sprint 4 から 2026-08-08 まで
#   **一度も発火していなかった**。単体2本と変異2本(N8c/N8d)が緑を出し続けていたのに、
#   だ。全部が `f(.background, .active) == true` という**規則**を測っていて、
#   「iOS がその引数で f を呼ぶか」を誰も測っていなかったから(iOS は
#   `background -> active` という辺を一度も配らない。実測列は `ForegroundResume` の doc)。
#   だから此処の変異は規則を触るだけでは足りず、**本物の背面往復を通した振る舞い**を
#   赤にできるかで測る。M4 がその1本。
#
# 何を測るか(変異 -> 赤くなるべき検査):
#   M1 `.task` を消す(= 引き金 #1 と #5 の出所を断つ)  -> 会話から戻る検査が赤
#      ★鈍い変異で、起動側の検査や中身の検査も同時に赤くなる。だから主張は
#        「的の検査**だけ**が赤」ではなく「的の検査が赤の中に居る」。5つ目の引き金は
#        `ListView` に1行も書かれておらず、`.task` の生存期間その物から出ているので、
#        断ち方が此処しか無い。
#   M2 `.task` が2回撃つ                                -> 会話から戻る検査が赤(+2)
#      ★これが「違う番号になった」ではなく **ちょうど +1** を主張している事の直接の
#        証拠。`!=` で書いていたら M2 は緑で通る。起動側の検査も同時に赤くなる ——
#        二重取得は起動と復帰の両方の瞬間で掴める、という事。
#   M3 fixture の番号が **1 で凍る**(器の死)          -> 会話から戻る検査が赤
#      ★行を消さず `count = 1` にするのが要点。0 で凍らせると起動側の検査も赤になり、
#        「器が死ぬと静かに緑になる」形が見えない。1 で凍らせると
#        `testColdLaunchFetchesTheListExactlyOnce` は**緑のまま**になる ——
#        それが此処で実演したい失敗そのもの(死んだ計器が、主張している値 1 を
#        そのまま出す)。両方の回数検査が `XCTUnwrap` を錨に置いている理由。
#   M4 `ForegroundResume` が復帰を返さなくなる          -> 背面から戻る検査が赤
#      ★これが Sprint 4 の欠陥を掴む変異。当時の条件は「厳しすぎた」のではなく
#        **決して満たされない**ので、規則側だけを見る検査は全部緑のままだった。
#   M5 `.onChange(of: scenePhase)` の塊を消す           -> 背面から戻る検査が赤
#      ★M4 と的が同じで意味が違う: M4 は**規則**が効いている事、M5 は**配線**が
#        繋がっている事。片方だけだと、もう片方が死んでも誰も赤くしない。
#
# 走らせ方(conversation-ui-control.sh と同じ理由で**作業木を変異させる**):
#   scratch へ複製すると DerivedData が効かず1回あたり数分になる。復元は走る前に取った
#   複製が保証し、最後に shasum の一致で**戻った事を観測する**(想定しない)。
#
# ★目印(INFLIGHT)は ios の変異対照で**共有**する。ここが変異させるのは
#   ListView.swift / SessionsListingFixture.swift / ForegroundResume.swift で、他の
#   対照とは重ならないが、共有の理由は重なりではなく**取り残しを誰が拾うか**:
#   殺された走行の変異は、次に起きた対照が目印を読んで戻す。目印を対照ごとに分けると、
#   殺した対照を二度と走らせない限り誰も戻さない。共有して安全なのは、この一群が
#   **直列にしか走らない**から(commit の門は staged-controls-gate.sh の
#   `for c in $sel`、全掃きは run-controls.sh の `for c in "${list[@]}"`)。
#
# 既知の費用(隠さない): xcodebuild を6回(基準1 + 変異5)、しかも 6 本の UI 検査を
#   毎回全部走らせる。conversation-ui-control.sh の実測(基準+3 で合計 3.6 分)より
#   確実に長く、温まった DerivedData で概ねその倍を見込む事。
#   **この門を待つ commit は前景で timeout を掛けず、背景で回して待つ事。**
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/list-return.XXXXXX")"
LOGDIR="${TMPDIR:-/tmp}"
INFLIGHT="${TMPDIR:-/tmp}/rc-ios-mutation-inflight.tsv"
PASS=0; FAIL=0; UNMEASURED=0

LV="$IOS/Sources/Screens/List/ListView.swift"
FX="$IOS/Sources/Core/SessionsListingFixture.swift"
FR="$IOS/Sources/Screens/Shared/ForegroundResume.swift"
TARGETS=("$LV" "$FX" "$FR")

# 基準で緑である事を確かめる的。**件数ではなく実名**で錨を打つ(数を発明しない)。
WANT_RETURN=testReturningFromAConversationRefreshesTheListExactlyOnce
WANT_BG=testReturningFromTheBackgroundRefreshesTheListExactlyOnce
WANT_LAUNCH=testColdLaunchFetchesTheListExactlyOnce

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
. "$IOS/tools/xcode-tree-guard.sh"
trap 'cleanup; xtl_release' EXIT

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

run_ui() { # $1 = log path -> rc を印字
    local log="$1" rc=0
    ( cd "$IOS" && xcodegen generate >/dev/null 2>&1 && \
      xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$IOS/build" \
        -only-testing:RemoteMiniUITests/RemoteMiniUITests test ) >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ★module 名を付けた形で探す事。log の行は `-[RemoteMiniUITests.RemoteMiniUITests …]`
#   で、class 名だけで grep すると**1件も当たらない** = 「走っていない」と読み違える。
passed_tests() { # $1 = log
    grep -oE "Test Case '-\[RemoteMiniUITests\.RemoteMiniUITests [a-zA-Z]+\]' passed" "$1" \
        | sed 's/.*RemoteMiniUITests //; s/\]. passed//' | sort -u | tr '\n' ' '
}
failed_tests() { # $1 = log
    grep -oE "Test Case '-\[RemoteMiniUITests\.RemoteMiniUITests [a-zA-Z]+\]' failed" "$1" \
        | sed 's/.*RemoteMiniUITests //; s/\]. failed//' | sort -u | tr '\n' ' '
}

echo "=== 基準(変異なし)"
BASE_LOG="$LOGDIR/list-return-base.log"
rc=$(run_ui "$BASE_LOG")
if [ "$rc" -ne 0 ]; then
    un "基準が緑でない(rc=$rc)。以降は測れない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
BASE_PASSED="$(passed_tests "$BASE_LOG")"
for w in "$WANT_RETURN" "$WANT_BG" "$WANT_LAUNCH"; do
    case " $BASE_PASSED " in
        *" $w "*) ;;
        *) un "基準で的の検査が緑になっていない: $w(実測: ${BASE_PASSED:-なし})"
           echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
           exit 2 ;;
    esac
done
ok "基準: 的の検査が3本とも緑($BASE_PASSED)"

TASKLINE='        .task { await viewModel.refresh() } // initial display (brief §3-d trigger #1)'

# ---- 変異 M1: 5つ目の引き金の出所を断つ --------------------------------------
# `.task` を行ごと落とす。5つ目は「SwiftUI が push の間 `.task` を中断し、pop で
# 走らせ直す」事から出ているので、断てる場所が此処しか無い。
mutate_m1() {
    /usr/bin/sed -i '' "\|^${TASKLINE}\$|d" "$LV"
}
# ---- 変異 M2: `.task` が2回撃つ ----------------------------------------------
mutate_m2() {
    /usr/bin/sed -i '' "\|^${TASKLINE}\$|s|refresh() }|refresh(); await viewModel.refresh() }|" "$LV"
}
# ---- 変異 M3: fixture の番号が 1 で凍る(計器の死)---------------------------
# 行ごと消すと `count` が一度も変更されない変数になり、「let にしろ」の警告で赤の理由が
# 濁る。0 で凍らせると起動側の検査まで赤くなって、此処で見せたい形(死んだ計器が
# 起動側を**緑のまま**通す)が消える。だから 1 で凍らせる。
mutate_m3() {
    /usr/bin/sed -i '' 's|^        count += 1$|        count = 1|' "$FX"
}
# ---- 変異 M4: 規則が復帰を返さなくなる(Sprint 4 の欠陥の再現)---------------
# 背面を通った印を立てなくする = `shouldResume` が二度と真を返さない。当時の
# `oldPhase == .background && newPhase == .active` と、観測される結果は同じ。
mutate_m4() {
    /usr/bin/sed -i '' 's|^            wasBackgrounded = true$|            wasBackgrounded = false|' "$FR"
}
# ---- 変異 M5: 配線を断つ ------------------------------------------------------
# `.onChange(of: scenePhase)` の塊ごと落とす(閉じ括弧は同じ深さの `        }` )。
mutate_m5() {
    /usr/bin/sed -i '' '/onChange(of: scenePhase)/,/^        }$/d' "$LV"
}

probe() { # $1=名前 $2=変異する関数 $3=変異が当たる file $4=赤くなるべき検査
    local name="$1" fn="$2" target="$3" want="$4"
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
    local log="$LOGDIR/list-return-$name.log" rc
    rc=$(run_ui "$log")
    local reds greens
    reds="$(failed_tests "$log")"
    greens="$(passed_tests "$log")"
    if [ "$rc" -eq 0 ]; then
        ng "$name: 欠陥を植えたのに全部緑。$want は $name を測っていない。全文: $log"
    elif printf '%s' "$reds" | grep -q "$want"; then
        ok "$name -> 赤: $reds"
        # M3 の要点は「赤くなった事」ではなく「**起動側が緑のまま**である事」。
        # 器が死ぬと、主張している値をそのまま出す検査が在る —— それを毎回言わせる。
        if [ "$name" = "M3-fixture-counter-frozen" ]; then
            case " $greens " in
                *" $WANT_LAUNCH "*)
                    echo "       (実演: 器が死んでも $WANT_LAUNCH は緑のまま = 回数の検査は錨が要る)" ;;
                *)
                    un "M3: 起動側まで赤くなっている(緑: ${greens:-なし})= 凍らせる値が 1 でない。実演になっていない" ;;
            esac
        fi
    else
        un "$name: 赤くはなったが $want ではない(赤: ${reds:-なし}, rc=$rc)。全文: $log"
    fi
    restore_all
}

probe M1-no-task-no-return-refresh mutate_m1 "$LV" "$WANT_RETURN"
probe M2-task-fetches-twice        mutate_m2 "$LV" "$WANT_RETURN"
probe M3-fixture-counter-frozen    mutate_m3 "$FX" "$WANT_RETURN"
probe M4-rule-never-resumes        mutate_m4 "$FR" "$WANT_BG"
probe M5-scenephase-unwired        mutate_m5 "$LV" "$WANT_BG"

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

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
