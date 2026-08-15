#!/bin/bash
# controls-for: ios/Sources/Screens/Shared/AccountBar.swift ios/Sources/Screens/Shared/AccountViewModel.swift ios/Sources/Screens/Settings/SettingsView.swift ios/Sources/Core/AccountClient.swift ios/Sources/Core/AccountFixture.swift ios/Tests/Screens/Shared/AccountViewModelTests.swift ios/UITests/AccountUITests.swift
#
# ★`SettingsView.swift` を宣言に足したのは 2026-08-15(§9-4 で画面を割った後)。
#   足すまでの間、口座の切替は設定画面に居るのに宣言は `AccountBar.swift` までしか
#   届いておらず、**設定画面だけを触る commit ではこの対照が1本も回らなかった**。
#   この gate の頭が名指ししている「守りの届く範囲が、欠陥と一緒に縮む」の実例で、
#   宣言が古びる形の残余リスク(同じく頭に明記)が実際に起きた1件目。
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
SV="$IOS/Sources/Screens/Settings/SettingsView.swift"
TARGETS=("$VM" "$BAR" "$CL" "$SV")

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
REL_TARGETS="ios/Sources/Screens/Shared/AccountViewModel.swift ios/Sources/Screens/Shared/AccountBar.swift ios/Sources/Core/AccountClient.swift ios/Sources/Screens/Settings/SettingsView.swift"
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
# ★生成物(ios/Info.plist / RemoteMini.xcodeproj)を触る走行を **1 本に絞る**。
# 2026-08-15、此れが無くて `build.sh --sim` と此の台本が `RC_BUILD_REV` の刻印を
# 潰し合い、**偽の赤が 9 本**出た(製品の欠陥と見分けが付かない赤)。
# 取れなければ此処で非零終了する = 生成物に触らないまま止まる。
. "$IOS/tools/xcode-tree-guard.sh"
trap 'restore_all; xtl_release' EXIT INT TERM HUP

ok() { echo "  OK   $1"; PASS=$((PASS+1)); }
ng() { echo "  NG   $1"; FAIL=$((FAIL+1)); }
un() { echo "  UNMEASURED  $1"; UNMEASURED=$((UNMEASURED+1)); }

# 単体2 class + UI は A5 / A7 が要る。既定は単体のみ(安い方)。
UNIT_ONLY="-only-testing:RemoteMiniTests/AccountViewModelTests \
-only-testing:RemoteMiniTests/AccountClientTests"
UI_ACCOUNT="RemoteMiniUITests/AccountUITests"

# 1回の走行に掛ける上限(秒)。
#
# ★此処に上限が要る理由(2026-08-15、実測)。A3 の変異(= `select()` の失敗後の
#   `await load()` を削る)を植えると、検査の二重が待っていた事象が**一度も起きない**。
#   二重側の待ちに期限が無かったので `xcodebuild` が **16分26秒 生きたまま**返らず、
#   log には赤も何も出なかった。二重の側は直した(DESIGN §2.96)が、直したのは
#   **其の1箇所**であって、期限の無い待ちを誰かが次に書けば同じ事が起きる。
#
#   質が悪いのは待つ事自体ではなく**出口**: 此の台本は pre-commit の門の中でも回るので、
#   吊ると commit が永久に返らず、画面には「対照を回している」としか出ない。
#   上限を置くと其れが `UNMEASURED`(= commit を止める)に変わる。緑には決してならない。
#
#   値: 変異1本あたりの実測は約29秒。冷えた最初のビルドが数分掛かるので 20 分。
#   偽の UNMEASURED を出さない幅を取った上での上限で、性能の目標ではない。
CONTROL_RUN_LIMIT_S="${CONTROL_RUN_LIMIT_S:-1200}"
# 上限で殺された時の終了コード(= 128 + SIGALRM(14))。実測で確認済み。
LIMIT_RC=142

xcb() { # $1 = log, 残り = -only-testing 群
    local log="$1" rc=0
    shift
    # `perl -e alarm` で上限を掛ける(macOS に GNU timeout は無い)。上限で殺された時の
    # 終了コードは 142(= 128+SIGALRM)で、下の `numeric()` を通って 0 以外なので
    # 「全部緑」の枝には決して落ちない。
    ( cd "$IOS" && xcodegen generate >/dev/null 2>&1 && \
      /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$CONTROL_RUN_LIMIT_S" \
        xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$IOS/build" "$@" test ) >"$log" 2>&1 || rc=$?
    if [ "$rc" = 142 ]; then
        printf '\n[control] 上限 %s 秒で打ち切った(= 走行が返らなかった。期限の無い待ちを疑う)\n' \
            "$CONTROL_RUN_LIMIT_S" >>"$log"
    fi
    # 終了コードを**全文の中にも**残す。呼び出し側は `$(...)` で受けるので、
    # 受け損ねた時に後から追える先が此処以外に無い(2026-08-15 に実際に空で来た)。
    printf '\n[control] xcodebuild exit=%s\n' "$rc" >>"$log"
    printf '%s' "$rc"
}
# 走った検査の本数。0 = **一度も走っていない**(ビルドが通らない / simulator が拒んだ)。
#
# ★`|| printf '0'` で書いてはいけない(2026-08-15、実測)。`grep -c` は一件も無い時
#   **標準出力に `0` を出した上で終了コード 1 を返す**ので、`||` の右も走って
#   戻り値が `0\n0` になる。呼び出し側の `[ "$(ran_count ...)" -eq 0 ]` は
#   `[: 0\n0: integer expression expected` で**評価そのものに失敗**し、bash は
#   其れを偽として扱うから、「一本も走っていない」を見張る門が黙って素通りする。
#   実測: `ran_count の戻り値 = [0\n0]` / `門が発火しない(= 落ちて次の枝へ行く)`。
#   終了コードは代入の `||` で捨て、値は変数経由で一度だけ出す
#   (= `signout-notice-control.sh` と同じ形。片方だけ直すと同じ穴が残る)。
ran_count() { # $1 = log path
    local n
    n="$(grep -cE "Test Case '-\[RemoteMini(UI)?Tests\." "$1" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}
failed_tests() {
    grep -E "Test Case .* failed" "$1" 2>/dev/null \
        | sed -E "s/^.*Tests ([a-zA-Z0-9_]+)\].*$/\1/" | sort -u | tr '\n' ' '
}
has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
# 終了コードが数字として来ているか。空や非数だと `[ "$rc" -eq 0 ]` が**評価そのものに失敗**し、
# bash は其れを「偽」として扱うので、判定は黙って次の枝(= OK を出せる枝)へ落ちる。
# 2026-08-15 の走行で実際に `line 218: [: : integer expression expected` が出ており、
# 「測れなかった」が「緑」の顔をして通り抜ける道が開いていた。
numeric() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

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
WANT_BLOCKED_ROW=testARowThatCannotBeSelectedStaysVisibleAndDisabledWithItsReason
# ★A1 と対を成すが、守っている物は別。A1/WANT_RACE = 「切替**より前に**発行された
#   読み取りが後に着く」= 世代が捨てる。此処 = 「切替の**最中に**発行された読み取り」で、
#   其れは切替より新しい世代を持つので世代では捨てられない。錠を分けるのは、
#   片方の守り(世代)を消しても もう片方(発行を止める)が残る事を別々に測る為。
WANT_SWITCH_WINDOW=testAForegroundRefreshDuringASwitchDoesNotResurrectTheOldAccount
WANTS="$WANT_RACE $WANT_SWITCH_WINDOW $WANT_REREAD $WANT_VM_NORETRY $WANT_CLIENT_NORETRY $WANT_ONSCREEN $WANT_BLOCKED_ROW"

echo "=== 基準(変異なし)"
BASE_LOG="$LOGDIR/account-ui-base.log"
rc=$(xcb "$BASE_LOG" $UNIT_ONLY "-only-testing:$UI_ACCOUNT")
if [ "$(ran_count "$BASE_LOG")" -eq 0 ]; then
    un "基準で検査が一度も走っていない = 機械の側が動いていない。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
if [ "$rc" = "$LIMIT_RC" ]; then
    un "基準が上限 ${CONTROL_RUN_LIMIT_S} 秒で打ち切られた(= 走行が返らなかった)。全文: $BASE_LOG"
    echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
    exit 2
fi
if ! numeric "$rc" || [ "$rc" -ne 0 ]; then
    un "基準が緑でない(rc='$rc')。以降は測れない。全文: $BASE_LOG"
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
# ★2026-08-15、A3 / A4 / A5 の探し文を張り直した。3本とも**当たっていなかった** ——
#   走行は「変異が bytes を動かさない」を検出して UNMEASURED を返していたので、
#   嘘の緑にはならなかったが、其の間この3本は**1度も守っていない**。
#   原因は同じ1つ: view model が書き換わった時(理由を先に憶えてから読み直す形へ、
#   `advance()` の switch を `let result` へ)に、**変異の探し文だけが 08-12 の版のまま
#   置き去りになった**。守る対象と守り方が別の file に在る以上、これは再発する形なので、
#   探し文は**行の丸ごとの写し**ではなく、其の行が担っている振る舞いに寄せて書く。
#
# A3 失敗の後に読み直さない = 机が進んでいるのに画面が古いまま
#    行1本では狙えない(`await load()` は同じ形で4箇所に在る)。「失敗の理由を憶えた
#    直後の読み直し」という**対**で捉える。`advance()` と `select()` の両方から消えるが、
#    植えている欠陥は1種類 =「失敗したら読み直す」を止める事。
mutate_a3() {
    /usr/bin/perl -0pi -e 's/            let reason = Self\.message\(for: error\)\n            await load\(\)\n/            let reason = Self.message(for: error)\n/g' "$VM"
}
# A4 切替の失敗を撃ち直す = 二段進めて一段失敗したと報告する
mutate_a4() {
    /usr/bin/sed -i '' 's|^        let result = await advancer.next(baseURL: baseURL, apiKey: apiKey)$|        var result = await advancer.next(baseURL: baseURL, apiKey: apiKey)\n        if case .failure = result { result = await advancer.next(baseURL: baseURL, apiKey: apiKey) }|' "$VM"
}
# A6 client が失敗を撃ち直す = 1回の呼びで机の口座が二段進む。
#    ★A4 と**同じ嘘を別の層で**作る。両方に変異が要るのは、片方だけ守っても
#      もう片方から同じ結末に着ける為(A4 を直しても A6 の道が残る)。
mutate_a6() {
    /usr/bin/sed -i '' 's|^        return await perform(request)$|        let r = await perform(request)\n        if case .failure = r { return await perform(request) }\n        return r|' "$CL"
}
# A5 バーが自分で読みに行かない = 相が `.idle` のまま留まり、実機でも口座が永久に出ない。
#    ★2026-08-15、変異を**取り替えた**。以前は `.idle` を `EmptyView()` で描く変異で、
#      名前も `A5-idle-draws-nothing` だった。走らせたら「欠陥を植えたのに全部緑」で
#      返り、読み直して理由が確定した —— 嘘の緑ではなく、**的が存在しない**:
#        - 歴史上の欠陥(2026-08-12、UI 検査5本で観測)は `.task` を `EmptyView` に
#          付けた事で `load()` が一度も呼ばれない、という物だった。此の版は `.task` を
#          `NavigationLink` へ移して**構造で潰してある**ので、`.idle` が空白でも
#          `load()` は走り、口座は出る。
#        - 残る差は「読み込み中の一瞬が空白か回転印か」だけ。`AccountFixture` の
#          `current()` は全状態が即返るので、`.idle` / `.loading` の瞬間を XCUITest から
#          掴む手段が此の repo に無い(掴むには読み取りを止める fixture が要る)。
#      よって守る対象を、**残っている方の主張**へ寄せた: 「バーは自分で読みに行く」。
#      空白か回転印かの主張は今この対照では守られていない —— DESIGN §2.93 に明記した。
mutate_a5() {
    /usr/bin/sed -i '' 's|^        .task { await viewModel.load() }$|        .task { }|' "$BAR"
}
# A7 選べない行を**消す** = 断りの理由ごと画面から消え、「そんな口座は無い」と読める。
#    ★2026-08-15 追加。`controls-for` に `SettingsView.swift` を足した以上、
#      設定画面を触る commit で此の対照が回る —— が、変異が1つも其の file に
#      当たっていなければ「回っている」だけで**守ってはいない**(此の file が A2 を
#      落とした時に書いた「走らせない変異は守っている振り」と同じ穴の、宣言側の版)。
#      的は §5-8 の product 判断そのもの:「選べない行は消さず、押せなくして理由を置く」。
mutate_a7() {
    /usr/bin/sed -i '' 's|^        ForEach(state.accounts) { row in$|        ForEach(state.accounts.filter { $0.selectable }) { row in|' "$SV"
}
# A8 切替中でも読み取りを発行する = 机が切替の**前**の状態で答えた古い名前が、
#    切替より新しい世代を持って着地し、着地済みの切替を巻き戻す。
#    ★A1(世代を捨てる)とは別の道。世代を残したまま此処だけ壊すと A1 の的は緑のまま
#      なので、2本立てている事に意味が在る事も同時に測れる。
#    ★探し文は `load()` の冒頭にしか無い形で撃つ。`select()`/`advance()` の
#      `guard case ... , !isBusy else` とは行の形が違うので、此の1本だけに当たる。
mutate_a8() {
    /usr/bin/sed -i '' '/^        guard !isBusy else { return }$/d' "$VM"
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
    if ! numeric "$rc"; then
        un "$name: xcodebuild の終了コードを受け損ねた(rc='$rc')= 当たり外れを測っていない。全文: $log"
        restore_all
        return
    fi
    # ★上限で打ち切られた走行は、赤の名前が合っていても `OK` にしない。
    #   打ち切りより前に的が赤くなっていれば `has` は真になるが、其の走行は
    #   **途中で止まっている**ので「変異を植えたら此の検査だけが赤くなる」を測れていない。
    #   §2.93-b と同じ原則: 「測れなかった」は緑と区別が付く場所に必ず置く。
    if [ "$rc" = "$LIMIT_RC" ]; then
        un "$name: 上限 ${CONTROL_RUN_LIMIT_S} 秒で打ち切った(= 走行が返らなかった。期限の無い待ちを疑う)。全文: $log"
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
probe A8-read-issued-during-switch mutate_a8 "$VM"  "$WANT_SWITCH_WINDOW"
probe A3-no-reread-after-failure   mutate_a3 "$VM"  "$WANT_REREAD"
probe A4-viewmodel-retries-switch  mutate_a4 "$VM"  "$WANT_VM_NORETRY"
probe A6-client-retries-switch     mutate_a6 "$CL"  "$WANT_CLIENT_NORETRY"
probe A5-bar-never-loads           mutate_a5 "$BAR" "$WANT_ONSCREEN" ui
probe A7-blocked-row-hidden        mutate_a7 "$SV"  "$WANT_BLOCKED_ROW" ui

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
