#!/bin/bash
# `xcode-tree-lock.sh` を**呼び側へ 1 行で繋ぐ**ための取っ手。source して使う。
#
#   . "$IOS/tools/xcode-tree-guard.sh"      # 取れなければ此処で exit 1(fail-closed)
#   trap 'cleanup; xtl_release' EXIT        # 既存の trap に release を足す
#
# 何故「錠」と「取っ手」を分けたか:
#   錠(`xcode-tree-lock.sh`)は取る/外す/持ち主を見る、の 3 語しか知らない。
#   だが呼び側には**入れ子**が在る —— `run-controls.sh` が錠を取り、その中から
#   `account-ui-control.sh` が走る。子が素直に acquire すると、親の錠に当たって
#   自分で自分を締め出す(= 死ぬ)。入れ子の判定を 5 本の台本へ書き写すと、写しが
#   別々に古びる。だから**1 ファイルに閉じて、そこだけ計器で測る**。
#
# 入れ子の規約:
#   - 親が取ると `RC_XCODE_TREE_LOCK_OWNER` を export する。
#   - 子は其れが入っているのを見て、取りに行かない(= 素通り)。
#   - `RC_XTL_HELD` は **export しない**。だから「自分で取った者」だけが 1 を持ち、
#     `xtl_release` は其の者でしか動かない。子の終了で親の錠は外れない。
#   - 二重の安全として、錠側も札(owner)が一致しない release を無視する。
#
# 2026-08-15: この鎖が無かったので `build.sh --sim` と `run-controls.sh --all` が
# `ios/Info.plist` の刻印(`RC_BUILD_REV`)を潰し合い、**偽の赤が 9 本**出た。

XTL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XTL="$XTL_DIR/xcode-tree-lock.sh"

xtl_release() {
    [ "${RC_XTL_HELD:-0}" = "1" ] || return 0
    RC_XTL_HELD=0
    "$XTL" release "${RC_XCODE_TREE_LOCK_OWNER:-}" 2>/dev/null
    return 0
}

# ★刻印(`RC_BUILD_REV`)も此処で入れる。錠と同じ取っ手に置くのは、どちらも
# 「生成木へ入る前に済ませる事」だから —— 片方だけ通った走行が `rev unknown` を作る。
#   xcodegen は未定義の `${RC_BUILD_REV}` を**文字列のまま** Info.plist へ書き、落ちない。
#   `BuildInfo.displayRev` が其れを見て `unknown` と出す。Tom の写真の下端の
#   `rev unknown` は此れ = 台本が自分で generate した app を触っていた、という意味。
#   計算は `build.sh --print-rev` にしか無い(写しを持つと片方だけ腐る。shots.sh の
#   註釈と同じ理由)。`--print-rev` は錠を取る前に exit するので、入れ子にならない。
if [ -z "${RC_BUILD_REV:-}" ] && [ "$(basename "${0:-}")" != "build.sh" ]; then
    RC_BUILD_REV="$("$XTL_DIR/build.sh" --print-rev 2>/dev/null)"
    if [ -n "$RC_BUILD_REV" ]; then export RC_BUILD_REV; else unset RC_BUILD_REV; fi
fi

if [ -z "${RC_XCODE_TREE_LOCK_OWNER:-}" ]; then
    RC_XCODE_TREE_LOCK_OWNER="$(basename "${0:-shell}") $$"
    export RC_XCODE_TREE_LOCK_OWNER
    if "$XTL" acquire "$RC_XCODE_TREE_LOCK_OWNER"; then
        RC_XTL_HELD=1
    else
        # fail-closed: 取れなければ生成物に触れないまま止まる。
        # ★`return` ではなく `exit`。source された側の `return` は「読み込みを終える」
        #   だけで、呼び側は**そのまま先へ進む** = 錠を取れていないのに generate を撃つ。
        #   fail-open になるので此処は `exit` でなければならない。
        # ★終了コードは呼び側が決められる(既定 1)。`.harness/dod-sprint-6.5-controls.sh`
        #   は 2 = 「測れなかった」を持っていて、1 = 「壊れるべき対照が壊れなかった」と
        #   混ぜると判定を読み違える —— 錠が空かなかったのは**測れなかった**方。
        unset RC_XCODE_TREE_LOCK_OWNER
        exit "${RC_XTL_FAIL_CODE:-1}"
    fi
fi
