#!/bin/bash
# 対照(b) -- 挙動検査: control (a) の文字列走査は速いが脆い(brief 本文の指摘
# そのまま)。バイナリに文字が無くても、別の経路で同じ状態に落ちる作りのバグは
# 拾えない。ここでは実際に Release バイナリを headless simulator へ入れて起動し、
# `RC_UI_FIXTURE` を渡しても fixture の一覧画面へ落ちない事を**実際に走らせて**測る。
#
# 画面のピクセルや a11y ツリーを直接読む道具は simctl 単体には無い(それを持つのは
# `xcodebuild test` 経由の XCUITest で、Release 単体バイナリには接続できない)。
# 代わりに Sprint 1 が既に確立した手筋を使う: `KeyEntryViewModel.swift` の
# `print("healthz ok:...")` -- 鍵もホストも書かず、通った経路だけを1行残し、
# `--console` でその行を拾う -- と同じ形で `RootView.swift` の `.task` に
# 診断行を足した(`print("root flow:normal")` / `print("root flow:fixture state:...")`、
# 後者は `#if DEBUG` の中で、Release では該当ブロックごと存在しない)。
#
# 期待する読み: Release + `RC_UI_FIXTURE=list-empty` を渡しても
#   - "root flow:normal" が出る(=通常経路が実際に走った)
#   - "root flow:fixture" は一切出ない(=fixture 経路には一切入っていない)
# 両方が真の時だけ緑。どちらか片方だけでは「たまたま今回は退避していた」を
# 緑と誤読しかねないので、両方を独立に見る。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
cd "$HERE" || { echo "ios/ に入れない"; exit 2; }

DERIVED="$HERE/build"
mkdir -p "$DERIVED"
SIM_NAME="${SIM_NAME:-iPhone-dogfood}"
BUNDLE="com.tomarai.remotemini"

xcodegen generate >"$DERIVED/xcodegen-fixture-behavior.log" 2>&1
if [ $? -ne 0 ]; then
    echo "UNMEASURED: xcodegen generate に失敗"
    tail -20 "$DERIVED/xcodegen-fixture-behavior.log"
    exit 2
fi

xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Release \
    -sdk iphonesimulator -derivedDataPath "$DERIVED" build \
    >"$DERIVED/xcodebuild-Release-fixture-behavior.log" 2>&1
if [ $? -ne 0 ]; then
    echo "UNMEASURED: Release の iphonesimulator ビルドが失敗(=まだ測っていない)"
    tail -20 "$DERIVED/xcodebuild-Release-fixture-behavior.log"
    exit 2
fi

APP="$DERIVED/Build/Products/Release-iphonesimulator/RemoteMini.app"
if [ ! -d "$APP" ]; then
    echo "UNMEASURED: Release の .app が見当たらない -- $APP"
    exit 2
fi

# デバイスは名前で引く(UDID を書き取らない -- 端末が作り直されても壊れない)。
DEV_LINE="$(xcrun simctl list devices | grep -F "$SIM_NAME (" | head -1)"
if [ -z "$DEV_LINE" ]; then
    echo "UNMEASURED: シミュレータ '$SIM_NAME' が見当たらない(先に一度作成が要る)"
    exit 2
fi
DEV="$(echo "$DEV_LINE" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1)"
if [ -z "$DEV" ]; then
    echo "UNMEASURED: '$SIM_NAME' の UDID が読み取れない"
    exit 2
fi

# headless のみ -- `open -a Simulator` は使わない。既に起動済みでも壊さない。
if ! echo "$DEV_LINE" | grep -q "Booted"; then
    xcrun simctl boot "$DEV" >/dev/null 2>&1
    xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1
fi

xcrun simctl install "$DEV" "$APP" >"$DERIVED/simctl-install-fixture-behavior.log" 2>&1
if [ $? -ne 0 ]; then
    echo "UNMEASURED: simctl install に失敗"
    cat "$DERIVED/simctl-install-fixture-behavior.log"
    exit 2
fi

CONSOLE_LOG="$DERIVED/console-fixture-behavior.log"
: > "$CONSOLE_LOG"
# `simctl launch --console` はアプリの標準出力をこのプロセスへ流したまま常駐する
# ので、バックグラウンドで走らせて数秒待ち、診断行が出た所で切る。
#
# `NSUnbufferedIO=YES` が無いと `print()` は消える(実測 2026-08-05): stdout が
# TTY でなくパイプの時、libc は行バッファでなく**フルバッファ**を使うので、
# アプリを4秒で kill する前にバッファが flush されず、`root flow:normal` が
# 一度も console log に載らなかった(この行が無い版で実際に検査が RED になった)。
# Xcode がスキームの環境変数に既定でこれを足しているのと同じ理由・同じ値。
SIMCTL_CHILD_RC_UI_FIXTURE=list-empty SIMCTL_CHILD_NSUnbufferedIO=YES \
    xcrun simctl launch --console --terminate-running-process "$DEV" "$BUNDLE" >"$CONSOLE_LOG" 2>&1 &
LAUNCH_PID=$!
sleep 4
kill "$LAUNCH_PID" >/dev/null 2>&1
wait "$LAUNCH_PID" 2>/dev/null
xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1

ok=1
if ! grep -q "root flow:normal" "$CONSOLE_LOG"; then
    echo "RED: 'root flow:normal' が出ていない -- 通常経路が実際に走った確証が無い"
    ok=0
fi
if grep -q "root flow:fixture" "$CONSOLE_LOG"; then
    echo "RED: 'root flow:fixture' が出た -- Release が RC_UI_FIXTURE を読んでしまっている"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    echo "GREEN: Release + RC_UI_FIXTURE=list-empty は通常経路のみを通った(console: $CONSOLE_LOG)"
    exit 0
fi
echo "console 全文:"
cat "$CONSOLE_LOG"
exit 1
