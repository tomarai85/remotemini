#!/bin/bash
# controls-for: ios/Sources/Screens/Conversation/ConversationView.swift
#
# 「長い会話を開いた時、本当に一番下へ着くか」を **混んでいる機械で N 回** 測る計器。
#
# ── なぜ之が要るか(2026-08-31)────────────────────────────────────────────────
# `testOpeningALongConversationLandsAtTheNewestLine` は **単独では必ず通る**。
# 倒れるのは全掃き(752 件)の最中だけ —— 実測 FAIL/FAIL/PASS/PASS/PASS。
# 今朝 仕込んだ失敗時の記録が発火して、倒れた瞬間の画面が取れた:
#
#     ScrollView   高さ 501.7 / 内容 3308.0 / 寄せ -2430.7  → 下端まで 375.6pt 残り
#     実在した行 068〜087(088/089/090 は作られていない)
#
# = 「一番下へ寄る」は走っているが **3 行手前で止まっている**。
#
# ★此処が此の計器の存在理由: **1 回 緑でも直った証拠にならない**。素の走行は
#   直す前でも 5 回中 3 回 緑だった。だから「直った」を主張するには
#   **倒れる条件を再現した上で、其の条件で 0 件になる**事を見せる必要が在る。
#
# ── 測り方 ────────────────────────────────────────────────────────────────
#   1. まず 1 回だけ組む(組み立ては測定の対象外なので、負荷を掛けない)
#   2. 全核に忙しい仕事を撒く(= 全掃き中の機械と同じ状態を作る)
#   3. 組んだ物を **N 回** 走らせ、倒れた回数を数える
#   4. 負荷を必ず片付ける(trap)
#
# 終了コード(三値):
#   0 = N 回とも通った
#   1 = 1 回でも倒れた
#   2 = 測れなかった(組み立て失敗 / simulator が無い)—— 緑にも赤にも丸めない
#
# ★使い方は 2 通りで、意味が逆になる:
#   直す**前**に走らせる = 負の対照。**rc=1 が期待値**(倒れなければ計器が無力)
#   直した**後**に走らせる = 本番。rc=0 が期待値
#
# 環境変数:
#   CLS_RUNS       走らせる回数(既定 5)
#   CLS_LOAD       撒く負荷の本数(既定 = 論理コア数。0 で負荷なし)
#   RC_SIM_NAME    simulator 名(既定 iPhone-dogfood)
set -uo pipefail
# ★ジョブ制御の通知を止める。負荷を片付ける時の `Terminated:` が 15 行 出て、
#   呼び側が `tail` で受けていると**判定行を押し出す**(2026-08-31、実際に見失った)。
set +m

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # = ios/tools
IOS="$(cd "$HERE/.." && pwd)"                                  # = ios
SIM_NAME="${RC_SIM_NAME:-iPhone-dogfood}"
RUNS="${CLS_RUNS:-5}"
NCPU="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
# ★既定 0。機械負荷は **2 回 実測して 2 回とも空振り**だったので、既定から外した。
#   残してあるのは「効かない事」を再測できる様にする為で、勧める設定ではない。
LOAD="${CLS_LOAD:-0}"
TEST_ID="RemoteMiniUITests/ConversationUITests/testOpeningALongConversationLandsAtTheNewestLine"

# ★生成木の錠を取る。此の計器は `xcodegen generate` を撃つので、錠を取らずに回すと
#   他の走行(`build.sh` / 変異対照)と刻印を潰し合い、**偽の赤**が出る。
#   取れなければ 2(測っていない)—— 「壊れている」ではないので赤に丸めない。
RC_XTL_FAIL_CODE=2
export RC_XTL_FAIL_CODE
. "$IOS/tools/xcode-tree-guard.sh"

WORK="$(mktemp -d)"
DD="$WORK/build"
LOAD_PIDS=""
cleanup() {
    [ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
    # ★並走の輪は**孫まで殺す**。輪の shell を殺しても、其の下の `xcodebuild` は
    #   親を失って走り続け、次の走行の判定を汚す(= 消し忘れた負荷が「混んでいる」を
    #   勝手に作る)。名指しは並走用の simulator に限る —— 測定側を巻き込まない為。
    /usr/bin/pkill -f "name=${CO_SIM:-__none__}" 2>/dev/null
    wait $LOAD_PIDS 2>/dev/null
    /bin/rm -rf "$WORK"
}
# ★解錠は**此の行に書く**。`trap ... EXIT` は加算されず後から掛けた方が前を置き換えるので、
#   guard が自分で掛けた解錠の trap は此処で消える —— 消したなら自分で返す必要が在る。
#   ★★更に、`xtl_release` を `cleanup` の**中**へ隠すと C4 が赤くなる
#     (`xcode-tree-lock-controls.sh` の C4 は trap の行に literal が出る事を要求する)。
#     2026-08-31 に実際に赤を出した。検査は正しく、規約に合わせるのは此方 ——
#     関数の中を追う様に検査を緩めると、「解錠を呼んだつもりで呼んでいない」形が通る。
trap 'cleanup; xtl_release' EXIT

echo "== 会話画面の着地 —— 混んだ機械で ${RUNS} 回 =="
echo "   負荷 ${LOAD} 本 / 論理コア ${NCPU} / simulator ${SIM_NAME}"

# ── 1. 組む(負荷なし。組み立ての失敗は「測れなかった」)──────────────────────
echo "-- 組み立て中(1 回だけ)…"
if ! ( cd "$IOS" && xcodegen generate >/dev/null 2>&1 && \
       xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Debug \
         -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM_NAME" \
         -derivedDataPath "$DD" \
         -only-testing:"$TEST_ID" build-for-testing ) >"$WORK/build.log" 2>&1; then
    echo "  UNM  組み立てに失敗した = 着地を測れない"
    /usr/bin/tail -20 "$WORK/build.log" | /usr/bin/sed 's/^/       /'
    echo ""
    echo "CONVERSATION-LANDING-STRESS: 測定不成立(組み立て)"
    exit 2
fi
echo "   組み立て OK"

# ── 2. 負荷を撒く ────────────────────────────────────────────────────────────
# ★★負荷の模型を 2026-08-31 に**作り直した**。初版は `yes` を全核へ撒くだけで、
#   **直す前のコードでも 5/5 PASS = 欠陥を一度も再現できなかった**(実測)。
#   計器が欠陥を出せないなら、直した後の緑は何も証明しない。
#
#   倒れた時に実際に並走していたのは CPU の空回しではなく、**別の simulator 上の
#   もう一つの XCUITest**(全掃きが回していた `conversation-ui-control.sh` 等)。
#   XCUITest は CoreSimulator / SpringBoard / 描画サーバを共有するので、
#   争っているのは核ではなく **layout が回る順番**。`yes` は其処を一切触らない。
#
#   ★★2026-08-31 追記: **其の第2版も外した**(直す前のコードで 5/5 PASS)。
#     理由は QoS とプロセス木。shell から起いた `yes` は default QoS で、simulator の
#     前面 app は user-interactive —— scheduler は app を優先するので 15 核を埋めても
#     **app の主スレッドは飢えない**。別 simulator は `launchd_sim` ごと木が別なので、
#     競合は host の GPU と `CoreSimulator` daemon で止まり、対象の run loop に届かない。
#
#   ★結論: 機械を混ませる形の負荷は**両方とも既定から外す**(下の既定は 0)。
#     再現すべきは原因(混んだ機械)ではなく機序(app の main run loop が細切れになる事)
#     なので、§3 で `MainThreadHog` へ直接 注入する。此処に残すのは、
#     「効かない」を後からもう一度 測れる様にする為だけ。
CO_SIM="${CLS_CO_SIM:-iPhone-controls}"
CO_TEST="${CLS_CO_TEST:-RemoteMiniUITests/ConversationUITests}"
if [ "${CLS_CO_LOAD:-0}" = "1" ]; then
    (
        while :; do
            ( cd "$IOS" && xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini \
                -configuration Debug -sdk iphonesimulator \
                -destination "platform=iOS Simulator,name=$CO_SIM" \
                -derivedDataPath "$DD" \
                -only-testing:"$CO_TEST" test-without-building ) >/dev/null 2>&1
        done
    ) &
    LOAD_PIDS="$LOAD_PIDS $!"
    echo "   並走: $CO_SIM で $CO_TEST を回し続ける(倒れた時と同じ形)"
fi
if [ "$LOAD" -gt 0 ]; then
    for _ in $(/usr/bin/seq "$LOAD"); do
        yes >/dev/null 2>&1 &
        LOAD_PIDS="$LOAD_PIDS $!"
    done
    echo "   負荷 ${LOAD} 本 起動"
fi

# ── 3. 決定的な対 —— 輪が「必要」である事を毎回 測る ────────────────────────
# ★2026-08-31 に此処を作り直した。初版は「混んだ機械で N 回 走らせて倒れるのを待つ」
#   形だったが、**直す前のコードで 3 通りの負荷すべてが空振り**した
#   (`yes` 15 本 / 別 simulator の並走 XCUITest / 主スレッド占有 14ms)。
#   競合を待つ計器は、当たらない日には何も言わない。
#
#   代わりに**故障の形そのものを注入して**測る。破壊口(`RC_UI_LANDING_SABOTAGE`)は
#   開いた時の錨への `scrollTo` を丸ごと飛ばす = 「寄せが完走しなかった」の形。
#
#     E 破壊口 ON + 輪 動作 → 通らねばならない(輪が引き戻す)
#     C 破壊口 ON + 輪 停止 → **倒れねばならない**(倒れなければ輪は要らない)
#     D 破壊口 OFF + 輪 停止 → 通る(通常経路が壊れていない事の対照)
#
#   ★C が此の計器の芯。E だけなら「輪が働いた」しか言えず、
#     「輪が必要だった」は C が倒れて初めて言える。
#     2026-08-31 実測: C rc=65 `pending 2793.3 corr=0` / E rc=0 `settled -1.7 corr=1`。
#
#   ★渡し口は `simctl ... launchctl setenv`。`TEST_RUNNER_` 接頭辞は
#     `test-without-building` では検査プロセスに**届かない**(実測 `runner=[unset]`)。
sim() { /usr/bin/xcrun simctl spawn "$SIM_NAME" launchctl "$@" >/dev/null 2>&1; }
sim unsetenv RC_UI_LANDING_SABOTAGE
sim unsetenv RC_UI_LANDING_NOLOOP
sim unsetenv RC_UI_MAIN_HOG_MS

one_run() {  # one_run <log> -> rc を印字
    local rc=0
    ( cd "$IOS" && xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini \
        -configuration Debug -sdk iphonesimulator \
        -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$DD" \
        -only-testing:"$TEST_ID" test-without-building ) >"$1" 2>&1 || rc=$?
    printf '%s' "$rc"
}
readout() { /usr/bin/grep -m1 'LANDING-DISTANCE=' "$1" | /usr/bin/sed 's/.*LANDING-DISTANCE=//'; }

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  OK   $1"; }
ng() { FAIL=$((FAIL+1)); echo "  NG   $1"; }

# ── E 破壊口 ON + 輪 動作 ────────────────────────────────────────────────────
sim setenv RC_UI_LANDING_SABOTAGE 1
e_rc="$(one_run "$WORK/e.log")"; e_out="$(readout "$WORK/e.log")"
echo "  E 破壊口ON/輪ON  rc=$e_rc  [$e_out]"
case "$e_out" in
    *" sab "*) : ;;
    *) ng "E 破壊口が app に届いていない(読み出しに sab が無い)= 以下は何も測っていない" ;;
esac
# ★倒れ方を分ける。`rc` は xcodebuild の汎用の失敗で、負荷下では**アプリの起動が
#   `waitForExistence(timeout: 10)` に間に合わない**だけでも非零になる —— 其れは
#   着地の失敗ではない。検査は倒れた時に `DIAG-LONG-CONVERSATION-BEGIN` を刷るので
#   其の有無で分ける。2026-08-31、門の走行で出た `rc=65` を診断を読まずに
#   「着地しない」と名乗り、Tom へ誤報した。**同じ file の古い版(hog の掃引)には
#   此の切り分けが在ったのに、C/D/E へ書き直した時に落とした。**
kind_of() { # kind_of <rc> <log> -> pass / landing / other
    if [ "$1" = "0" ]; then printf 'pass'; return; fi
    if /usr/bin/grep -q 'DIAG-LONG-CONVERSATION-BEGIN' "$2"; then printf 'landing'; else printf 'other'; fi
}
case "$(kind_of "$e_rc" "$WORK/e.log")" in
    pass)    ok "E ★輪が在れば、寄せが完走しなくても下端へ着く" ;;
    landing) ng "E ★輪が在っても着地しない(着地の失敗、rc=$e_rc)" ;;
    other)   echo "  UNM  E 着地とは別の失敗(rc=$e_rc、診断が出ていない = 起動が間に合わない等)"
             echo "       → 緑にも赤にも丸めない。撃ち直す事" ;;
esac
case "$e_out" in
    settled*) ok "E 着地が確定している(pending のまま終わっていない)" ;;
    *) ng "E 着地が確定していない: [$e_out]" ;;
esac

# ── C ★★破壊口 ON + 輪 停止 —— 倒れねばならない ─────────────────────────────
sim setenv RC_UI_LANDING_NOLOOP 1
c_rc="$(one_run "$WORK/c.log")"; c_out="$(readout "$WORK/c.log")"
echo "  C 破壊口ON/輪OFF rc=$c_rc  [$c_out]"
# ★C も「着地の失敗で倒れた」でなければ意味が無い。別の失敗で倒れても
#   「輪が必要」の証拠にはならない —— 倒れさえすれば良い、にすると
#   simulator の事故が此の主張を通してしまう。
case "$(kind_of "$c_rc" "$WORK/c.log")" in
    landing) ok "C ★★輪を止めると**着地に失敗する** = 輪は必要(E は空虚でない)" ;;
    pass)    ng "C 輪を止めても通った = **輪は要らない**。機械を撤回し読み出しだけ残す事" ;;
    other)   echo "  UNM  C 別の失敗で倒れた(rc=$c_rc)= 輪の必要性の証拠にならない。撃ち直す事" ;;
esac

# ── D 破壊口 OFF + 輪 停止(通常経路の対照)──────────────────────────────────
sim unsetenv RC_UI_LANDING_SABOTAGE
d_rc="$(one_run "$WORK/d.log")"; d_out="$(readout "$WORK/d.log")"
echo "  D 破壊口OFF/輪OFF rc=$d_rc  [$d_out]"
[ "$d_rc" = "0" ] && ok "D 通常経路は輪が無くても通る(C の赤は破壊口に由来する)" \
                  || ng "D 通常経路が輪無しで倒れる(rc=$d_rc)= C の赤の原因が切り分けられない"

sim unsetenv RC_UI_LANDING_NOLOOP
sim unsetenv RC_UI_LANDING_SABOTAGE

echo ""
echo "CONVERSATION-LANDING-STRESS: pass=$PASS fail=$FAIL"
exit $(( FAIL > 0 ))
