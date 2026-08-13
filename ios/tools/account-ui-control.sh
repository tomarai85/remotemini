#!/bin/bash
# controls-for: ios/Sources/Screens/Shared/AccountBar.swift ios/Sources/Screens/Shared/AccountViewModel.swift ios/Sources/Core/AccountClient.swift ios/Sources/Core/AccountFixture.swift ios/Tests/Screens/Shared/AccountViewModelTests.swift ios/UITests/AccountUITests.swift
#
# 口座の表示と切替(REQUIREMENTS §4-5 / §5-8)の負の対照。
#
# 何を守るか: 此の層の欠陥は**全部「画面が机と食い違う」**の形をしていて、
# 食い違ったまま緑になる。2026-08-12 の出荷までに実際に4つ出た:
#
#   (a) `.idle` を EmptyView で描くと `.task` が繋がらず、実機でも口座が永久に出ない
#       -> 単体は1本も落ちない。UI 検査だけが赤
#   (b) 切替の失敗を「口座は動かなかった」と読むと、机が B なのに画面が A のまま
#   (c) 遅い読み取りが新しい切替を上書きする(会話画面から戻る -> 再読込中に切替)
#   (d) 背面から戻っても読み直さないと、他所で変えた口座に画面が追随しない
#
# ★(a) と (c)(d) は**性質が違う**: (a) は単体から届かない層、(c)(d) は順序。
#   だから変異も両方の層に置く —— 片方だけだと「守っている振り」になる。
#
# 費用: xcodebuild を 1 + 変異の数だけ回す。単体のみ(UI class は A5 だけが撃つ)。
#
# 終了コード: 0=全変異が期待通り赤 / 1=赤くならない検査が在る / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
ROOT="$(cd "$HERE/.." && pwd)"
IOS="$HERE"
SIM_NAME="${SIM_NAME:-iPhone-dogfood}"
LOGDIR="${TMPDIR:-/tmp}"
PASS=0; FAIL=0; UNMEASURED=0

VM="$IOS/Sources/Screens/Shared/AccountViewModel.swift"
BAR="$IOS/Sources/Screens/Shared/AccountBar.swift"
CL="$IOS/Sources/Core/AccountClient.swift"
TARGETS=("$VM" "$BAR" "$CL")

# ★**git を復元の正本にする**(2026-08-12、事故の直後に書き直した)。
#
#   最初の版は `signout-notice-control.sh` の型を真似て、追跡ファイルを其の場で汚し
#   `trap` で戻していた。**其の日の内に事故を起こした**: 走行が SIGKILL で殺されると
#   trap は走らず、変異(切替を撃ち直す版)が `AccountViewModel.swift` に**残った**。
#   `git checkout` で戻せたのは、偶々 commit の直前で索引に清浄な版が在ったから ——
#   運に助けられただけで、設計は間違っていた。
#
#   ★真似る対象を間違えた: 同じ日に書いた `mutation-deferral-control.sh` は
#   **写しを作って追跡ファイルを一切触らない**形にしてある。此処もそちらに寄せる…
#   が、Swift の変異は「その木をビルドする」事が測定そのものなので写しでは測れない。
#   代わりに**復元の正本を git に置く**: 走行の前に木が清浄である事を要求し、
#   戻す時は `git checkout` を使う。trap が走らなくても、次の走行の入口で気付ける。
# ★見るのは「索引との差」であって「commit との差」ではない。`git checkout --` が
#   戻す先は**索引**なので、staged なだけの変更は復元元であって汚れではない。
#   `git status --porcelain` で見ると staged を汚れと読み、出荷前の commit 直前に
#   対照が一切回せなくなる(2026-08-12、書いた直後に気付いた)。
REL_TARGETS="ios/Sources/Screens/Shared/AccountViewModel.swift ios/Sources/Screens/Shared/AccountBar.swift ios/Sources/Core/AccountClient.swift"
unstaged() { ( cd "$ROOT" && git diff --name-only -- $REL_TARGETS 2>/dev/null ); }

require_clean_tree() {
    local dirty
    dirty="$(unstaged)"
    if [ -n "$dirty" ]; then
        echo "UNMEASURED  測る対象が既に汚れている(前の走行が変異を残した可能性):"
        printf '%s\n' "$dirty" | /usr/bin/sed 's/^/    /'
        echo "  戻し方: git checkout -- <上の file>  (未コミットの意図的な変更なら先に commit/stash)"
        exit 2
    fi
}
require_clean_tree

restore_all() {
    ( cd "$ROOT" && git checkout -- $REL_TARGETS ) 2>/dev/null
}
trap 'restore_all' EXIT INT TERM HUP

ok() { echo "  OK   $1"; PASS=$((PASS+1)); }
ng() { echo "  NG   $1"; FAIL=$((FAIL+1)); }
un() { echo "  UNMEASURED  $1"; UNMEASURED=$((UNMEASURED+1)); }

# 単体5 class + UI は A5 だけが要る。既定は単体のみ(安い方)。
UNIT_ONLY="-only-testing:RemoteMiniTests/AccountViewModelTests \
-only-testing:RemoteMiniTests/AccountClientTests"
UI_ACCOUNT="RemoteMiniUITests/AccountUITests"

xcb() { # $1 = log, 残り = -only-testing 群
    local log="$1" rc=0
    shift
    ( cd "$IOS" && xcodegen generate >/dev/null 2>&1 && \
      xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$IOS/build" "$@" test ) >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
}
ran_count() { grep -cE "Test Case '-\[RemoteMini(UI)?Tests\." "$1" 2>/dev/null || printf '0'; }
failed_tests() {
    grep -E "Test Case .* failed" "$1" 2>/dev/null \
        | sed -E "s/^.*Tests ([a-zA-Z0-9_]+)\].*$/\1/" | sort -u | tr '\n' ' '
}
has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

# ---- 錨(実名で持つ。件数を手で書かない)------------------------------------
WANT_RACE=testASlowReadThatLandsAfterASwitchDoesNotOverwriteIt
WANT_REREAD=testAFailedSwitchRereadsTheAccountRatherThanAssumingItDidNotMove
# ★層で分かれている。同じ「撃ち直さない」でも、測っている物も壊れ方も違う:
#   view model 層 = `advance()` が `next()` を2回呼ぶか(口座が二段進む)
#   client 層     = `next()` が HTTP を2本撃つか(1回の呼びで二段進む)
#   ★2026-08-12 に此処で外した: view model へ植えた変異の錨に client 層の検査名を
#     書いていた。変異は正しく捕まっていた(view model 側の検査が赤)のに、
#     名指しが違うので UNMEASURED になった —— **層を跨いだ錨は当たらない**。
WANT_VM_NORETRY=testAdvanceIsNotFiredTwiceForOneTap
WANT_CLIENT_NORETRY=testAFailedSwitchIsNotRetried
WANT_ONSCREEN=testTheAccountIsActuallyOnTheScreen
WANTS="$WANT_RACE $WANT_REREAD $WANT_VM_NORETRY $WANT_CLIENT_NORETRY $WANT_ONSCREEN"

echo "=== 基準(変異なし)"
BASE_LOG="$LOGDIR/account-ui-base.log"
rc=$(xcb "$BASE_LOG" $UNIT_ONLY "-only-testing:$UI_ACCOUNT")
if [ "$(ran_count "$BASE_LOG")" -eq 0 ]; then
    un "基準で検査が一度も走っていない = 機械の側が動いていない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
if [ "$rc" -ne 0 ]; then
    un "基準が緑でない(rc=$rc)。以降は測れない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
BASE_PASSED="$(grep -E "Test Case .* passed" "$BASE_LOG" 2>/dev/null \
    | sed -E "s/^.*Tests ([a-zA-Z0-9_]+)\].*$/\1/" | sort -u | tr '\n' ' ')"
for w in $WANTS; do
    if ! has "$BASE_PASSED" "$w"; then
        un "基準で的の検査が緑になっていない: $w"
        echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
        exit 2
    fi
done
ok "基準: 的の検査が $(printf '%s' "$WANTS" | wc -w | tr -d ' ') 本とも緑"

# ---- 変異 ---------------------------------------------------------------------
# A1 世代を捨てる = 遅い読み取りが新しい切替を上書きする(Codex が名指しした操作列)
mutate_a1() {
    /usr/bin/sed -i '' '/^        guard mine == generation else { return }$/d' "$VM"
}
# ★A2(切替が世代を進めない)は**書いたが落とした**。probe から呼んでおらず、
#   sed も当たらない形だった —— 走らせない変異は「守っている振り」で、
#   此の repo が `vacuous-gate` で名指ししている錨なしの検査と同じ物。
#   A1 が同じ結末(遅い読み取りが上書きする)を別の道から測っているので、
#   数を増やす為だけに死んだ変異を置かない。
# A3 失敗の後に読み直さない = 机が進んでいるのに画面が古いまま
mutate_a3() {
    /usr/bin/sed -i '' 's|^            apply(await reader.current(baseURL: baseURL, apiKey: apiKey), fallbackReason: reason)$|            phase = .failed(reason: reason)|' "$VM"
}
# A4 切替の失敗を撃ち直す = 二段進めて一段失敗したと報告する
mutate_a4() {
    /usr/bin/sed -i '' 's|^        switch await advancer.next(baseURL: baseURL, apiKey: apiKey) {$|        var _r = await advancer.next(baseURL: baseURL, apiKey: apiKey)\n        if case .failure = _r { _r = await advancer.next(baseURL: baseURL, apiKey: apiKey) }\n        switch _r {|' "$VM"
}
# A6 client が失敗を撃ち直す = 1回の呼びで机の口座が二段進む。
#    ★A4 と**同じ嘘を別の層で**作る。両方に変異が要るのは、片方だけ守っても
#      もう片方から同じ結末に着ける為(A4 を直しても A6 の道が残る)。
mutate_a6() {
    /usr/bin/sed -i '' 's|^        return await perform(request)$|        let r = await perform(request)\n        if case .failure = r { return await perform(request) }\n        return r|' "$CL"
}
# A5 `.idle` を空で描く = `.task` が繋がらず、実機でも口座が永久に出ない(出荷前の実物)
mutate_a5() {
    /usr/bin/sed -i '' 's|^            case .idle, .loading:$|            case .idle: EmptyView()\n            case .loading:|' "$BAR"
}

probe() { # $1=名前 $2=変異関数 $3=対象file $4=赤くなるべき検査 $5=(任意)走らせ方
    local name="$1" fn="$2" target="$3" want="$4" ui="${5:-}"
    restore_all
    local before after
    before=$(shasum "$target" | awk '{print $1}')
    "$fn"
    after=$(shasum "$target" | awk '{print $1}')
    if [ "$before" = "$after" ]; then
        un "$name: 変異が当たっていない(bytes が動かない)= 測っていない。探し文を付け直す事"
        return
    fi
    local log="$LOGDIR/account-ui-$name.log" rc
    if [ -n "$ui" ]; then
        rc=$(xcb "$log" "-only-testing:$UI_ACCOUNT")
    else
        rc=$(xcb "$log" $UNIT_ONLY)
    fi
    if [ "$(ran_count "$log")" -eq 0 ]; then
        un "$name: 検査が一度も走っていない = 変異の当たり外れは測っていない。全文: $log"
        restore_all
        return
    fi
    local reds; reds="$(failed_tests "$log")"
    if [ "$rc" -eq 0 ]; then
        ng "$name: 欠陥を植えたのに全部緑。$want は $name を測っていない。全文: $log"
    elif has "$reds" "$want"; then
        ok "$name -> 赤: $reds"
    else
        un "$name: 赤くはなったが $want ではない(赤: ${reds:-なし}, rc=$rc)。全文: $log"
    fi
    restore_all
}

probe A1-generation-guard-removed  mutate_a1 "$VM"  "$WANT_RACE"
probe A3-no-reread-after-failure   mutate_a3 "$VM"  "$WANT_REREAD"
probe A4-viewmodel-retries-switch  mutate_a4 "$VM"  "$WANT_VM_NORETRY"
probe A6-client-retries-switch     mutate_a6 "$CL"  "$WANT_CLIENT_NORETRY"
probe A5-idle-draws-nothing        mutate_a5 "$BAR" "$WANT_ONSCREEN" ui

# ---- 復元の確認(想定ではなく観測する)----------------------------------------
restore_all
not_restored="$(unstaged | tr '\n' ' ')"
if [ -n "$not_restored" ]; then
    echo "UNMEASURED  変異が作業木に残っている:$not_restored"
    UNMEASURED=$((UNMEASURED+1))
else
    echo "復元を確認(対象 ${#TARGETS[@]} file すべて走る前のバイトと一致)"
fi

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
[ "$FAIL" -gt 0 ] && exit 1
[ "$UNMEASURED" -gt 0 ] && exit 2
exit 0
