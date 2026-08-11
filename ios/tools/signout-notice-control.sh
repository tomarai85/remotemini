#!/bin/bash
# controls-for: ios/Sources/AppState.swift ios/Sources/Core/KeyEntryClients.swift ios/Sources/Core/KeyEntryProbeFixture.swift ios/Sources/Core/Provisioning.swift ios/Sources/Core/ProvisioningFixture.swift ios/Sources/Core/SignOutNotice.swift ios/Sources/Core/SignOutNoticeFixture.swift ios/Sources/RootView.swift ios/Sources/Screens/KeyEntry/KeyEntryView.swift ios/Sources/Screens/KeyEntry/KeyEntryViewModel.swift ios/Tests/AppStateTests.swift ios/Tests/Core/ProvisioningTests.swift ios/Tests/Core/SignOutNoticeStoreTests.swift ios/Tests/Screens/KeyEntryViewTests.swift ios/Tests/Screens/KeyEntryViewModelTests.swift ios/UITests/FirstRunUITests.swift ios/UITests/KeyEntryUITests.swift
#
# 鍵入力画面の負の対照。守っている物は3つ在り、**同じ file 群**の上に載っている:
#   (a) 401 で戻された時の断り(DESIGN §2.65 / 監査 X2-6) …… M1-M9
#   (b) 接続を押した後の「確かめています」(DESIGN §2.68 / 監査 X2-8) …… M10-M12
#   (c) 焼き込んだ種で初回起動が一覧に着く事(2026-08-11 の欠陥) …… M13-M20
#       M13-M17 = 蒔く側(AppState / RootView)。M18-M19 = **刻印の形を落とす門**
#       (`Provisioning.clean` と scheme+host)。後者は `vacuous-gate` が
#       「否定だけで錨なし」と挙げた6本の錨が本当に効くかを測る為に足した。
#
# ★1本に束ねてあるのは、`staged-controls-gate.sh` が path で対照を選ぶから。別 file に
#   割ると `KeyEntryViewModel.swift` を1行触るだけで xcodebuild が**2組**走る ——
#   同じ木・同じ simulator を測るのに費用だけ倍になる。概念の綺麗さより測定の費用を取る。
#
# 何を守るか(a): 「通っていた鍵が拒まれた」という事実が、disk に書かれてから**画面の
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
# 何を測るか(b)。此方の継ぎ目は3本:
#
#     KeyEntryViewModel.probe(今どの段か)
#       -> inFlightText が段ごとに別の文を返す
#         -> body の footer が描く / 欄が .disabled になる
#
#   M10 2段目の文を1段目の文に差し替える -> 「段ごとに別の文」が赤
#       ★同時に文を作る純関数の検査は**緑のまま**。M4 と同じ形の実演で、
#         「文は正しいが、正しい段に結ばれていない」を純関数側は永久に見ない。
#   M11 footer が一文を描かない            -> **UI 検査だけ**が赤
#       ★同時に viewModel 側の段の検査は緑のまま。M8 の相方。
#   M12 欄の .disabled を外す              -> **UI 検査だけ**が赤
#       ★同時に単体の「両段で isChecking が立つ」は緑のまま = 単体が届くのは
#         `isChecking` の値までで、その値が現に欄を止めている事は測れない。
#
# 何を測るか(c)。2026-08-11、Tom が実機で開いた最初の画面が「Base URL と API Key を
# 打て」だった —— 合格条件は「開くと一覧が出る」で、人が打つとは何処にも書いていない。
# 数十本の検査が一度も赤くならなかったのは、**製品の入口を見る計器が1つも無かった**から。
# 継ぎ目は此の4本:
#
#     ProvisioningSource(焼き込んだ刻印)
#       -> AppState.loadStoredCredentials が「読めた上で空」だけを見る
#         -> plantSeedIfNeeded が指紋を見て1回だけ蒔く
#           -> RootView.normalFlow が一覧を選ぶ
#
#   M13 種を蒔かない                      -> 「空の Keychain が種で埋まる」が赤
#       ★直す前の姿そのもの。此の1行が Tom の見た画面を作っていた。
#   M14 指紋の門を外す(毎回蒔く)          -> 「捨てた種は蒔き直さない」が赤
#       ★同時に「空の Keychain が種で埋まる」は**緑のまま** = 幸せな道だけ測ると、
#         401 で捨てた鍵をまた蒔いて電話が回り続ける実装が通る。
#   M15 「読めなかった」を「空」に潰す      -> 「読めない Keychain を空と読まない」が赤
#       ★同時に幸せな道は緑のまま。潰したままだと、Keychain が一時的に読めない起動で
#         **Tom が手で入れた鍵を種が上書きする**。
#   M16 記録を Keychain へ書く**前**に付ける -> 「順序」の検査が赤
#       ★同時に幸せな道は緑のまま。M2 と同じ形で、間で殺された時だけ壊れる。
#   M17 RootView が鍵を持っていても鍵入力画面を出す -> **UI 検査だけ**が赤
#       ★単体は1本も落ちない。此れが 2026-08-11 に実際に起きた形 —— 種の側を
#         どれだけ単体で固めても、画面まで繋がっている事は単体からは永久に見えない。
#   M18 `clean` が何も落とさない            -> 「未解決の ${…} は種でない」が赤
#   M19 宛先の門(https + host)を外す        -> 「平文の URL は種でない」が赤
#       ★M18/M19 は**両方とも**「整った刻印は種になる」を緑のまま残す。此の2本は
#         `vacuous-gate` が「否定だけ・錨なし」と挙げた6本(①〜⑥)の錨が本当に
#         効くかを測る為に足した —— 錨を足しただけでは、其の錨が働く証拠にならない。
#   M20 保存の失敗を握り潰して記録だけ付ける -> 「書けなかった種は蒔いた事にしない」が赤
#       ★同時に**順序の検査(M16 の的)は緑のまま**。順序を見る対照だけでは、
#         `try?` で握り潰す実装が通る —— 一度きりの保存失敗で、次の起動が入力欄に戻る。
#         此の変異は commit 26d4566 直後まで実際に出荷していた姿そのもの。
#
# 費用(隠さない): xcodebuild を21回(基準1 + 変異20)。うち6回は UI 検査を含むので重い。
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
PR="$IOS/Sources/Core/Provisioning.swift"
TARGETS=("$AS" "$KV" "$KM" "$SN" "$RV" "$PR")

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
# (b) 「確かめています」の側。
WANT_STAGES=testEachStageSaysWhichStageItIsWhileItIsRunning
WANT_TIMEOUT=testTheSentencesAreBuiltFromTheTimeoutTheyAreGiven
WANT_INFLIGHT=testTheURLStageSaysWhatItIsWaitingFor
WANT_LOCKED=testTheFieldsCannotBeEditedWhileAStageIsRunning
WANT_LOCKED_UNIT=testTheFieldsStayLockedAcrossBothStages
# (c) 焼き込んだ種の側。
WANT_SEEDED=testAnEmptyKeychainIsSeededFromTheStampSoTheFirstScreenIsNotTheForm
WANT_ONCE=testARejectedSeedIsNotPlantedAgainOnTheNextLaunch
WANT_UNREADABLE=testAnUnreadableKeychainIsNotTreatedAsEmpty
WANT_SEED_ORDER=testTheLedgerIsWrittenAfterTheKeychain
WANT_SEED_FAIL=testASeedThatCouldNotBeSavedIsNotRecordedAsPlanted
WANT_FIRSTRUN=testAProvisionedPhoneReachesTheListWithoutBeingAskedToTypeAnything
# 刻印の**形**を落とす側(M18/M19)。整った刻印は種になる、を同じ検査の中で錨にしてある。
WANT_TEMPLATE=testAnUnresolvedTemplateIsNotASeed
WANT_PLAINTEXT=testAPlaintextURLIsNotASeed

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

# 単体5 class。UI 検査は含めない(速い方)。
# ★ProvisioningTests を 2026-08-11 に足した。足す前は17本の変異が**一度も**此の class を
#   走らせておらず、刻印の形を落とす門(`clean` / scheme+host)を壊す変異は
#   どの probe にも映らなかった。「対照が在る」と「その対照を走らせている」は別。
UNIT_ONLY="-only-testing:RemoteMiniTests/AppStateTests \
-only-testing:RemoteMiniTests/SignOutNoticeStoreTests \
-only-testing:RemoteMiniTests/KeyEntryViewTests \
-only-testing:RemoteMiniTests/KeyEntryViewModelTests \
-only-testing:RemoteMiniTests/ProvisioningTests"

# UI の class も**変数で一度だけ**名乗る。runner が字面で書くと、下の extract() が
# 持つ一覧と2つ目の写しになる。
UI_KEYENTRY="RemoteMiniUITests/KeyEntryUITests"
UI_FIRSTRUN="RemoteMiniUITests/FirstRunUITests"

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
    rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_KEYENTRY)"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_KEYENTRY)"
    fi
    printf '%s' "$rc"
}

# 単体4 class + 初回起動の画面。M17 は此れでしか測れない。
run_firstrun() { # $1 = log path -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_FIRSTRUN)"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_FIRSTRUN)"
    fi
    printf '%s' "$rc"
}

# 基準だけは**両方**の UI class を走らせる。錨(WANT_*)は21本在り、其のうち
# WANT_FIRSTRUN は FirstRunUITests にしか居ない —— 基準で緑を見ていない名前を
# 変異の側で「赤くなった」と読むと、元から赤かった物を成果に数える事になる。
run_base() { # $1 = log path -> rc を印字
    local log="$1" rc
    settle_sim
    rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_KEYENTRY \
          -only-testing:$UI_FIRSTRUN)"
    if [ "$(ran_count "$log")" -eq 0 ]; then
        echo "     (検査が1本も走っていない = 測定が起きていない。app を落として1度だけ取り直す)" >&2
        settle_sim
        rc="$(xcb "$log" $UNIT_ONLY -only-testing:$UI_KEYENTRY \
              -only-testing:$UI_FIRSTRUN)"
    fi
    printf '%s' "$rc"
}

# ★module 名まで付けた形で探す事。log の行は `-[RemoteMiniTests.AppStateTests …]` /
#   `-[RemoteMiniUITests.KeyEntryUITests …]` で、class 名だけで grep すると跨いだ時に取りこぼす。
#
# ★class の一覧は**走らせている引数から機械で取る**(2026-08-11)。此処は元々
#   6つを字面で持っており、`ProvisioningTests` を UNIT_ONLY へ足した時に**此方だけ
#   古いまま**になった —— 10本が緑で走っているのに scanner から見えず、基準の
#   錨チェックが「緑になっていない」と正しく止めた。写しを2つ持つと、片方を直した
#   人がもう片方の存在を知らない。**一覧は1つ、残りは導出。**
CLASS_ALT="$(
    { printf '%s\n' $UNIT_ONLY | sed -n 's|^-only-testing:RemoteMini\(UI\)\{0,1\}Tests/||p'
      printf '%s\n' "$UI_KEYENTRY" "$UI_FIRSTRUN" | sed 's|^RemoteMini\(UI\)\{0,1\}Tests/||'
    } | sort -u | paste -sd'|' -
)"
extract() { # $1 = log, $2 = passed|failed
    grep -oE "Test Case '-\[RemoteMini(UI)?Tests\.($CLASS_ALT) [a-zA-Z0-9_]+\]' $2" "$1" \
        | sed -E "s/^.*Tests ([a-zA-Z0-9_]+)\].*$/\1/" | sort -u | tr '\n' ' '
}
passed_tests() { extract "$1" passed; }
failed_tests() { extract "$1" failed; }

has() { # $1 = 空白区切りの一覧, $2 = 名前
    case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

echo "=== 基準(変異なし)"
BASE_LOG="$LOGDIR/signout-notice-base.log"
rc=$(run_base "$BASE_LOG")
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

# 錨の一覧。**本数を手で書かない**(2026-08-11、#64)。前の版は下の報告文に `21本` と
# 直書きしていて、此処へ1本足した人が報告文を知らない = 数が黙って嘘になる形だった。
# 同じ日に `extract()` の class 一覧でも踏んだ、写しが2つ在る型。
WANTS="$WANT_LEFT $WANT_ORDER $WANT_SWEEP $WANT_CARRIED $WANT_SENTENCE
       $WANT_TWO $WANT_DISK $WANT_NOKEY $WANT_SCREEN
       $WANT_STAGES $WANT_TIMEOUT $WANT_INFLIGHT $WANT_LOCKED $WANT_LOCKED_UNIT
       $WANT_SEEDED $WANT_ONCE $WANT_UNREADABLE $WANT_SEED_ORDER $WANT_SEED_FAIL $WANT_FIRSTRUN
       $WANT_TEMPLATE $WANT_PLAINTEXT"
WANT_N="$(printf '%s' "$WANTS" | wc -w | tr -d ' ')"

for w in $WANTS; do
    if ! has "$BASE_PASSED" "$w"; then
        un "基準で的の検査が緑になっていない: $w"
        echo "    (基準の緑は $(printf '%s' "$BASE_PASSED" | wc -w | tr -d ' ') 本。全文: $BASE_LOG)"
        echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
        exit 2
    fi
done
ok "基準: 的の検査が ${WANT_N} 本とも緑(この走行の緑は全部で $(printf '%s' "$BASE_PASSED" | wc -w | tr -d ' ') 本)"

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
# ★探し文は 2026-08-08(監査 X2-8)に付け直した。同じ行に `clients:` が入った日、
#   古い探し文は静かに当たらなくなる —— それは probe の shasum 検査が UNMEASURED で
#   捕まえる形なので、赤を緑と読む事にはならない。
mutate_m9() {
    /usr/bin/sed -i '' 's|^            KeyEntryView(clients: keyEntryClients, notice: appState.signOutNotice, onSaved: appState.setCredentials)$|            KeyEntryView(clients: keyEntryClients, onSaved: appState.setCredentials)|' "$RV"
}
# ---- 変異 M10: 2段目の文を1段目の文に差し替える -------------------------------
# 文そのものは2つとも正しいまま。**段との結び**だけを壊す。畳んだ実装
# (どちらの段でも同じ事を言う)と観測上まったく同じ姿になる。
mutate_m10() {
    /usr/bin/sed -i '' 's|^            return Self.keyProbeInFlightText(timeout: BackendSession.interactiveTimeout)$|            return Self.urlProbeInFlightText(timeout: BackendSession.interactiveTimeout)|' "$KM"
}
# ---- 変異 M11: footer が一文を描かない ----------------------------------------
# `inFlightText` は正しく段ごとの文を返し続ける。画面に出ないだけ ——
# 直す前の「押してから最大16秒空白」がそっくり戻る。
mutate_m11() {
    /usr/bin/sed -i '' 's|^                if let inFlight = viewModel.inFlightText {$|                if let inFlight = viewModel.inFlightText, inFlight.isEmpty {|' "$KV"
}
# ---- 変異 M12: 確かめている間も欄が打てる -------------------------------------
# 2行(URL 欄と鍵欄)を同時に外す。片方だけ外す版は「もう片方が守っている」と
# 読めてしまい、欠陥として弱い。
mutate_m12() {
    /usr/bin/sed -i '' 's|^                    .disabled(viewModel.isChecking)$|                    .disabled(false)|' "$KV"
}
# ---- 変異 M13: 種を蒔かない(2026-08-11 に Tom が見た画面そのもの)---------------
# 焼き込みは在るのに、空の Keychain を埋めない。初回起動が Base URL と API Key の
# 入力欄になる —— 直す前の姿。
mutate_m13() {
    /usr/bin/sed -i '' 's|^            stored = plantSeedIfNeeded()$|            stored = nil|' "$AS"
}
# ---- 変異 M14: 指紋の門を外す(毎回蒔く)---------------------------------------
# 幸せな道(空の Keychain が埋まる)は緑のまま。401 で捨てた鍵を次の起動で蒔き直し、
# 電話が「拒まれる鍵 -> 断り -> 同じ鍵」で回り続ける形だけが壊れる。
mutate_m14() {
    /usr/bin/sed -i '' '/^        guard seedLedger.plantedSeedDigest != digest else { return nil }$/d' "$AS"
}
# ---- 変異 M15: 「読めなかった」を「空」に潰す ---------------------------------
# `try? store.load()` へ戻すのと同じ意味。Keychain が一時的に読めない起動で、
# Tom が手で入れた鍵を焼き込みの種が上書きする。
mutate_m15() {
    /usr/bin/sed -i '' 's|^        if stored == nil \&\& storeIsReadable {$|        if stored == nil {|' "$AS"
}
# ---- 変異 M16: 記録を Keychain へ書く**前**に付ける ---------------------------
# 蒔けた時の結果は同じなので、順序を見る検査にしか映らない。間で殺されると
# 「書けなかった種を蒔いたと記録して二度と蒔かない」= 電話が永久に空のまま。
mutate_m16() {
    /usr/bin/sed -i '' 's|^            try store.save(seed)$|            seedLedger.plantedSeedDigest = digest; try store.save(seed)|' "$AS"
    /usr/bin/sed -i '' '/^        seedLedger.plantedSeedDigest = digest$/d' "$AS"
}
# ---- 変異 M20: 保存の失敗を握り潰して記録だけ付ける ---------------------------
# catch の `return seed` を消すと、書けなかった種が下の記録行まで落ちる = 2026-08-11
# の commit 直後まで実際に出荷していた `try?` の姿。順序(M16)は正しいまま壊れるので、
# 見えるのは⑮だけ —— 一度きりの保存失敗で、次の起動が**鍵の入力欄**に戻る。
mutate_m20() {
    /usr/bin/sed -i '' '/^            return seed$/d' "$AS"
}
# ---- 変異 M17: 鍵を持っていても鍵入力画面を出す -------------------------------
# `isLoadingCredentials` は此処では必ず false なので、資格情報が在っても else に落ちる。
# 種の側は単体で全部緑のまま —— **画面まで繋がっている事**だけが壊れる。
mutate_m17() {
    /usr/bin/sed -i '' 's|^        } else if let credentials = appState.credentials {$|        } else if let credentials = appState.credentials, appState.isLoadingCredentials {|' "$RV"
}

# ---- 変異 M18: `clean` が何も落とさない(もっともらしい文字列を種にする)-------
# `${RC_BASE_URL}` も空文字も、そのまま種として通る。★**整った刻印は種のまま**なので
# 「空の Keychain が埋まる」側は緑 —— 壊れるのは「半端な刻印を蒔かない」だけ。
# 2026-08-11 に此れを足したのは、否定だけの検査6本が `seed` の全否定でしか
# 赤くならず、`vacuous-gate` に「錨なし」と挙げられた為。錨を足した証明が此処。
mutate_m18() {
    /usr/bin/sed -i '' '/^        if trimmed.contains("${") { return nil }$/d' "$PR"
    /usr/bin/sed -i '' '/^        if trimmed.isEmpty { return nil }$/d' "$PR"
}
# ---- 変異 M19: 宛先の門(https + host)を外す ----------------------------------
# `http://` も `desk.invalid`(scheme 無し)も通る。此方も整った刻印は種のまま。
mutate_m19() {
    /usr/bin/sed -i '' 's|^        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else { return nil }$|        guard let parsed = URL(string: url) else { return nil }|' "$PR"
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
probe M10-both-stages-one-line mutate_m10 "$KM" "$WANT_STAGES" "$WANT_TIMEOUT"
probe M11-footer-draws-nothing mutate_m11 "$KV" "$WANT_INFLIGHT" "$WANT_STAGES" run_screen
probe M12-fields-stay-editable mutate_m12 "$KV" "$WANT_LOCKED" "$WANT_LOCKED_UNIT" run_screen
probe M13-seed-never-planted   mutate_m13 "$AS" "$WANT_SEEDED"
probe M14-seed-planted-always  mutate_m14 "$AS" "$WANT_ONCE"      "$WANT_SEEDED"
probe M15-unreadable-as-empty  mutate_m15 "$AS" "$WANT_UNREADABLE" "$WANT_SEEDED"
probe M16-ledger-before-keychain mutate_m16 "$AS" "$WANT_SEED_ORDER" "$WANT_SEEDED"
probe M17-key-but-still-the-form mutate_m17 "$RV" "$WANT_FIRSTRUN" "$WANT_SEEDED" run_firstrun
probe M18-clean-rejects-nothing  mutate_m18 "$PR" "$WANT_TEMPLATE"  "$WANT_SEEDED"
probe M19-any-scheme-accepted    mutate_m19 "$PR" "$WANT_PLAINTEXT" "$WANT_SEEDED"
probe M20-unsaved-seed-recorded  mutate_m20 "$AS" "$WANT_SEED_FAIL" "$WANT_SEED_ORDER"

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
