#!/bin/bash
# controls-for: ios/Sources/AppState.swift ios/Sources/Core/SignOutNotice.swift ios/Sources/Core/SignOutNoticeFixture.swift ios/Sources/RootView.swift ios/Sources/Screens/KeyEntry/KeyEntryView.swift ios/Sources/Screens/KeyEntry/KeyEntryViewModel.swift ios/Tests/AppStateTests.swift ios/Tests/Core/SignOutNoticeStoreTests.swift ios/Tests/Screens/KeyEntryViewTests.swift ios/Tests/Screens/KeyEntryViewModelTests.swift ios/UITests/KeyEntryUITests.swift
#
# 401 で戻された鍵入力画面の負の対照(DESIGN §2.65 / 監査 X2-6)。
#
# 何を守るか: 「通っていた鍵が拒まれた」という事実が、disk に書かれてから**画面の
# 画素になる**まで4本の継ぎ目を渡る。
#
#     SignOutNoticeStoring(UserDefaults)
#       -> AppState.clearCredentials / loadStoredCredentials
#         -> RootView.normalFlow が KeyEntryView に notice を渡す
#           -> KeyEntryView.init が文に変える
#             -> body が節を描く
#
# どの継ぎ目が切れても、残りの検査は緑を出し続ける。これは S8-5 で実際に起きた形
# (規則は正しく、単体も緑で、画面に繋がっていなかった)なので、継ぎ目ごとに名指しで撃つ。
#
# 何を測るか(変異 -> 赤くなるべき検査):
#   M1 clearCredentials が断りを一切残さない -> 401 が理由を残す検査が赤
#   M2 断りを Keychain の**後**に書く        -> 「順序」の検査が赤
#      ★同時に「断りが残る」検査は**緑のまま**。順序だけを見る検査が在って初めて
#        「間で殺された電話が白紙に戻る」欠陥が捕まる事の実演。
#   M3 起動時の掃除を外す                    -> 「鍵が在れば古い断りは掃かれる」が赤
#   M4 KeyEntryView.init が notice を捨てる  -> 「組んだ view が文を握る」が赤
#      ★同時に純関数 sentence(for:) の検査は**緑のまま** = 純関数だけ測っても
#        画面に繋がらない実装が通る、の実演。
#   M5 2文を1文に畳む                        -> 「URL が無い時に前のままと言わない」が赤
#   M6 UserDefaults の store が書かない       -> 「別の器から読める」が赤
#      ★同時に AppState 側の検査は**緑のまま** = 忘れる金庫でも app の検査は通る。
#   M7 拒まれた鍵まで欄に戻す                -> 「鍵は戻さない」が赤
#   M8 body の節を描かない                   -> **UI 検査だけ**が赤
#      ★同時に「組んだ view が文を握る」は緑のまま。単体では永久に届かない一歩が
#        此処に在る事の実演で、この対照の一番の要。
#   M9 RootView が notice を渡さない          -> **UI 検査だけ**が赤
#      ★配線の1行。単体は1本も落ちない。RootView は今後も触られる file なので、
#        黙って外れた日に気付けるかを測る。
#
# 費用(隠さない): xcodebuild を10回(基準1 + 変異9)。うち3回は UI 検査を含むので重い。
#   実測値は rc-backend/tools/run-controls.sh の登録行に書く。
#
# ★目印(INFLIGHT)は ios の変異対照で**共有**する。分けると片方の取り残しを
#   もう片方が「走る前の中身」として複製し、復元の基準点ごと汚れる。ズレは
#   rc-backend/test/mutation-recovery-copy.test.mjs が毎 commit 測る。
#
# 終了コード: 0=全変異が期待通り赤 / 1=赤くならない検査が在る / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
ROOT="$(cd "$HERE/.." && pwd)"
IOS="$HERE"
SIM_NAME="${SIM_NAME:-iPhone-dogfood}"
BUNDLE_ID="com.tomarai.remotemini"
# UDID が読めなくても走る(落ち着かせる手順を飛ばすだけ)。此処で止めると、元は
# 動いていた対照を「測れない」に変えてしまう。
SIM_UDID="$(xcrun simctl list devices 2>/dev/null | grep -F "$SIM_NAME (" | head -1 \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/signout-notice.XXXXXX")"
LOGDIR="${TMPDIR:-/tmp}"
INFLIGHT="${TMPDIR:-/tmp}/rc-ios-mutation-inflight.tsv"
PASS=0; FAIL=0; UNMEASURED=0

AS="$IOS/Sources/AppState.swift"
KV="$IOS/Sources/Screens/KeyEntry/KeyEntryView.swift"
KM="$IOS/Sources/Screens/KeyEntry/KeyEntryViewModel.swift"
SN="$IOS/Sources/Core/SignOutNotice.swift"
RV="$IOS/Sources/RootView.swift"
TARGETS=("$AS" "$KV" "$KM" "$SN" "$RV")

# 基準で緑である事を確かめる的。**件数ではなく実名**で錨を打つ(数を発明しない)。
WANT_LEFT=testA401LeavesAReasonBehindRatherThanJustDroppingTheKey
WANT_ORDER=testTheNoticeIsWrittenBeforeTheKeychainIsCleared
WANT_SWEEP=testAStaleNoticeIsSweptWhenCredentialsAreStillThere
WANT_CARRIED=testTheViewBuiltWithANoticeCarriesTheSentence
WANT_SENTENCE=testWithAURLTheSentenceExplainsWhyTheFieldIsAlreadyFilled
WANT_TWO=testWithoutAURLTheSentenceDoesNotClaimTheFieldWasFilled
WANT_DISK=testANoticeSurvivesTheObjectThatWroteIt
WANT_NOKEY=testTheRejectedKeyIsNotBroughtBackWithTheURL
WANT_SCREEN=testTheRejectedKeyNoticeIsActuallyOnTheScreen

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
trap cleanup EXIT

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
    n="$(grep -cE "Test Case '-\[RemoteMini(UI)?Tests\." "$1" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

# 前の走行の app が終了しきる前に次の launch が来ると、SpringBoard が preflight を
# Busy で蹴る。UDID が読めなければ何もしない(上記)。
settle_sim() {
    [ -n "${SIM_UDID:-}" ] || return 0
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

# 単体4 class。UI 検査は含めない(速い方)。
UNIT_ONLY="-only-testing:RemoteMiniTests/AppStateTests \
-only-testing:RemoteMiniTests/SignOutNoticeStoreTests \
-only-testing:RemoteMiniTests/KeyEntryViewTests \
-only-testing:RemoteMiniTests/KeyEntryViewModelTests"

xcb() { # $1 = log, 残り = -only-testing 群
    local log="$1" rc=0
    shift
    ( cd "$IOS" && xcodegen generate >/dev/null 2>&1 && \
      xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$IOS/build" "$@" test ) >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ★診断を stdout に書かない事。呼び出し側は `rc=$(run_… )` で**標準出力を
#   そのまま rc として読む**ので、1行混ぜるだけで rc が壊れて全部の probe が狂う。
# ★zsh ではなく bash で走る(shebang)ので、引用しない $UNIT_ONLY は単語分割される。
run_unit() { # $1 = log path -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(xcb "$log" $UNIT_ONLY)"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(xcb "$log" $UNIT_ONLY)"
    fi
    printf '%s' "$rc"
}

# 単体4 class + 画面の検査。M8/M9 は画面まで届かないと測れない。
run_screen() { # $1 = log path -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(xcb "$log" $UNIT_ONLY -only-testing:RemoteMiniUITests/KeyEntryUITests)"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(xcb "$log" $UNIT_ONLY -only-testing:RemoteMiniUITests/KeyEntryUITests)"
    fi
    printf '%s' "$rc"
}

# ★module 名まで付けた形で探す事。log の行は `-[RemoteMiniTests.AppStateTests …]` /
#   `-[RemoteMiniUITests.KeyEntryUITests …]` で、class 名だけで grep すると跨いだ時に取りこぼす。
extract() { # $1 = log, $2 = passed|failed
    grep -oE "Test Case '-\[RemoteMini(UI)?Tests\.(AppStateTests|SignOutNoticeStoreTests|KeyEntryViewTests|KeyEntryViewModelTests|KeyEntryUITests) [a-zA-Z0-9_]+\]' $2" "$1" \
        | sed -E "s/^.*Tests ([a-zA-Z0-9_]+)\].*$/\1/" | sort -u | tr '\n' ' '
}
passed_tests() { extract "$1" passed; }
failed_tests() { extract "$1" failed; }

has() { # $1 = 空白区切りの一覧, $2 = 名前
    case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

echo "=== 基準(変異なし)"
BASE_LOG="$LOGDIR/signout-notice-base.log"
rc=$(run_screen "$BASE_LOG")
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
for w in "$WANT_LEFT" "$WANT_ORDER" "$WANT_SWEEP" "$WANT_CARRIED" "$WANT_SENTENCE" \
         "$WANT_TWO" "$WANT_DISK" "$WANT_NOKEY" "$WANT_SCREEN"; do
    if ! has "$BASE_PASSED" "$w"; then
        un "基準で的の検査が緑になっていない: $w"
        echo "    (基準の緑は $(printf '%s' "$BASE_PASSED" | wc -w | tr -d ' ') 本。全文: $BASE_LOG)"
        echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
        exit 2
    fi
done
ok "基準: 的の検査が9本とも緑(この走行の緑は全部で $(printf '%s' "$BASE_PASSED" | wc -w | tr -d ' ') 本)"

# ---- 変異 M1: 401 が何も残さない(直す前の姿) ---------------------------------
# 断りを disk にも memory にも置かない。鍵だけ捨てて白紙の画面に戻る、元の欠陥そのもの。
mutate_m1() {
    /usr/bin/sed -i '' '/func clearCredentials/,/^    }$/ { /^        notices.save(notice)$/d; /^        signOutNotice = notice$/d; }' "$AS"
}
# ---- 変異 M2: 断りを Keychain の後に書く --------------------------------------
# 断りは最後には残るので「残す」検査は緑のまま。間で殺された時だけ白紙に戻る、
# 順序を見る検査にしか映らない欠陥。
mutate_m2() {
    /usr/bin/sed -i '' '/func clearCredentials/,/^    }$/ { /^        notices.save(notice)$/d; }' "$AS"
    /usr/bin/sed -i '' '/func clearCredentials/,/^    }$/ s|^        try? store.clear()$|        try? store.clear(); notices.save(notice)|' "$AS"
}
# ---- 変異 M3: 起動時に古い断りを掃かない --------------------------------------
mutate_m3() {
    /usr/bin/sed -i '' '/func loadStoredCredentials/,/^    }$/ { /^            notices.save(nil)$/d; }' "$AS"
}
# ---- 変異 M4: init が notice を捨てる -----------------------------------------
mutate_m4() {
    /usr/bin/sed -i '' 's|^        self.noticeText = Self.sentence(for: notice)$|        self.noticeText = nil|' "$KV"
}
# ---- 変異 M5: 2文を1文に畳む --------------------------------------------------
# URL が無くても「URL は前のまま入れてあります」と言う版。空欄を前にして
# 入っていない物を探させる。
mutate_m5() {
    /usr/bin/sed -i '' 's|^            if notice.baseURL != nil {$|            if true {|' "$KV"
}
# ---- 変異 M6: disk に書かない金庫 ---------------------------------------------
mutate_m6() {
    /usr/bin/sed -i '' 's|^        defaults.set(data, forKey: Self.storageKey)$|        _ = data|' "$SN"
}
# ---- 変異 M7: 拒まれた鍵まで欄に戻す ------------------------------------------
mutate_m7() {
    /usr/bin/sed -i '' 's|^        self.baseURLText = initialBaseURL?.absoluteString ?? ""$|        self.baseURLText = initialBaseURL?.absoluteString ?? ""; self.apiKeyText = initialBaseURL == nil ? "" : "rejected-key"|' "$KM"
}
# ---- 変異 M8: body が節を描かない ---------------------------------------------
# 文は init が握ったまま、画面には出ない。単体からは永久に見えない一歩。
mutate_m8() {
    /usr/bin/sed -i '' 's|^            if let noticeText {$|            if let noticeText, noticeText.isEmpty {|' "$KV"
}
# ---- 変異 M9: RootView が notice を渡さない -----------------------------------
mutate_m9() {
    /usr/bin/sed -i '' 's|^            KeyEntryView(notice: appState.signOutNotice, onSaved: appState.setCredentials)$|            KeyEntryView(onSaved: appState.setCredentials)|' "$RV"
}

probe() { # $1=名前 $2=変異関数 $3=対象file $4=赤くなるべき検査 $5=(任意)緑のままであるべき検査 $6=(任意)走らせ方
    local name="$1" fn="$2" target="$3" want="$4" stays="${5:-}" runner="${6:-run_unit}"
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
    local log="$LOGDIR/signout-notice-$name.log" rc
    rc=$("$runner" "$log")
    # ★「走っていない」を「捕まえられなかった」と混ぜない。混ぜると、探し文が
    #   当たっているのに探し文を疑いに行く事になる。
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

probe M1-no-reason-left-behind mutate_m1 "$AS" "$WANT_LEFT"
probe M2-notice-after-keychain mutate_m2 "$AS" "$WANT_ORDER"  "$WANT_LEFT"
probe M3-stale-notice-kept     mutate_m3 "$AS" "$WANT_SWEEP"
probe M4-init-drops-notice     mutate_m4 "$KV" "$WANT_CARRIED" "$WANT_SENTENCE"
probe M5-one-sentence-for-both mutate_m5 "$KV" "$WANT_TWO"
probe M6-store-forgets-on-disk mutate_m6 "$SN" "$WANT_DISK"   "$WANT_LEFT"
probe M7-rejected-key-restored mutate_m7 "$KM" "$WANT_NOKEY"
probe M8-body-draws-nothing    mutate_m8 "$KV" "$WANT_SCREEN" "$WANT_CARRIED" run_screen
probe M9-rootview-passes-none  mutate_m9 "$RV" "$WANT_SCREEN" "$WANT_CARRIED" run_screen

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
