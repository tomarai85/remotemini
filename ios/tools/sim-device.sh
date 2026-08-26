#!/bin/bash
# sim-device.sh — 対照が使う simulator の**機を決める1箇所**。2026-08-26 新設。
#   使い方: 対照の頭で `. "$(dirname "${BASH_SOURCE[0]}")/sim-device.sh"` して `$SIM_NAME` を使う。
#
# なぜ要るか(2026-08-26 に画を撮って初めて見えた)
#   `xcodebuild ... test` は **その機にアプリを install する**。対照 7 本が全部
#   `SIM_NAME="${SIM_NAME:-iPhone-dogfood}"` を既定にしていたので、対照を1回回すたびに
#   **Tom が見る機の中身が、種の入っていない Debug 版に差し替わっていた**。
#   症状: dogfood 機を開くと「This app was built without a destination / Enter the key
#   manually」= Tom が名指しで拒否した「鍵を打つ」画面が出る。
#   ★緑の数にも healthz にも出ない。**画を撮って初めて分かった**(3案の画が byte 単位で
#     同一になり、アプリが一覧に到達していない事に気付いた)。
#
# 決めた事(Codex 2026-08-26 の裁定):
#   1. 既定を分ける。所有の境界(= 誰が見る機か)で分けるので、呼び出し経路が
#      runner 経由でも門から直でも同じように効く。
#      (runner で `export SIM_NAME` する案は、**commit 前の門が対照を直に叩く**ので漏れる)
#   2. 機が無ければ**大声で落ちる**。黙って作ると infrastructure を勝手に変える事になり、
#      黙って dogfood へ倒すと「緑のまま Tom の機を壊す」= 一番悪い形になる。
#   3. **外から `SIM_NAME=iPhone-dogfood` を刺されたら断る。** 既定を変えただけでは、
#      環境変数の継承で衝突が再現する(Codex の指摘4)。緊急時は
#      `RC_ALLOW_DOGFOOD_SIM=1` を明示的に置く —— 名前で意図を宣言させる。
#
# ★`build.sh` と `shots.sh` は此処を通さない。あれらは **Tom が見る物を焼く側**なので
#   dogfood 機が正しい。境界はそこに在る。

RC_CONTROL_SIM_DEFAULT="iPhone-controls"
SIM_NAME="${SIM_NAME:-$RC_CONTROL_SIM_DEFAULT}"

if [ "$SIM_NAME" = "iPhone-dogfood" ] && [ "${RC_ALLOW_DOGFOOD_SIM:-0}" != "1" ]; then
    echo "★対照が dogfood 機を指している: SIM_NAME=$SIM_NAME" >&2
    # ★ここを二重引用にするとバッククォートが**コマンド置換として走る**(2026-08-26 に
    #   実際に xcodebuild が起動し、result bundle まで書かれた)。断り文の中で重い物を
    #   起動するのは論外なので、この行は単一引用で固定する。
    echo '  xcodebuild test はその機にアプリを install するので、Tom が見る面が' >&2
    echo "  種の入っていない Debug 版に差し替わる(2026-08-26 に実際に起きた)。" >&2
    echo "  対照は $RC_CONTROL_SIM_DEFAULT を使う事。どうしても必要なら RC_ALLOW_DOGFOOD_SIM=1。" >&2
    exit 2
fi

if ! xcrun simctl list devices 2>/dev/null | grep -qF "$SIM_NAME ("; then
    echo "★simulator の機が無い: $SIM_NAME" >&2
    echo "  作る:  xcrun simctl create \"$SIM_NAME\" \\" >&2
    echo "           com.apple.CoreSimulator.SimDeviceType.iPhone-13-mini \\" >&2
    echo "           com.apple.CoreSimulator.SimRuntime.iOS-26-5" >&2
    echo "  ★dogfood 機へ倒さないのは意図的 —— 倒すと緑のまま Tom の機を壊すから。" >&2
    exit 2
fi
