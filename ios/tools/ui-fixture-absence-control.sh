#!/bin/bash
# 対照(a) -- 文字列走査: `RC_UI_FIXTURE` が Release バイナリの文字列表に
# 一切出ない事を測る(Sprint 2 brief §5-b)。
#
# 何を守るか: `SessionsListingFactory`(ios/Sources/Core/SessionsListingFixture.swift)
# は `#if DEBUG` の中でしか `ProcessInfo...environment["RC_UI_FIXTURE"]` を読まない
# 設計になっている。この設計は Release ビルドが Key-entry を飛ばして UI テスト用の
# 固定データへ落ちる経路を持たない事の唯一の保証で、もし壊れると審査に出す実機ビルドが
# 環境変数ひとつで中身の無いダミー画面に切り替わる(=審査担当や利用者が触れる状態を
# 開発者が握れてしまう)。`#if DEBUG` を信じるだけでは確認にならない --
# 条件コンパイルで落ちたはずの文字列リテラルが最適化の都合で残る事があるので、
# コンパイラの意図ではなく実際に生成されたバイナリを strings で直接見る。
#
# Debug 側は逆に**居る事**を確認する錨(anchor): この検索方法自体が壊れて常に0を
# 返す(=何を探しても見つからない)状態だと、「Release の0」と「検査が死んでいる0」が
# 見分けられない。Debug に居るはずの文字列が本当に見えるかを同じ道具で確かめて
# 初めて、Release の0を「漏れていない」と読んでよくなる。
#
# 3値の落とし穴(brief 本文の警告そのもの): `grep -c` はヒット数が0の時、
# 終了コード1を返す。ここを `set -e` の下に置くと「見つからなかった(正しい)」が
# 「検査が壊れた」と誤判定される。だからこの台本は `set -e` を使わず、件数は
# 一度変数へ受けてから比較する。
#
# ビルド自体が失敗した場合(=まだ測っていない)と、測った上で漏れがある場合
# (=赤)を同じ籠に入れない: 前者は終了コード2、後者は1。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = ios/
cd "$HERE" || { echo "ios/ に入れない"; exit 2; }

DERIVED="$HERE/build"
mkdir -p "$DERIVED"

xcodegen generate >"$DERIVED/xcodegen-fixture-absence.log" 2>&1
if [ $? -ne 0 ]; then
    echo "UNMEASURED: xcodegen generate に失敗(プロジェクトが生成できていない = 測っていない)"
    tail -20 "$DERIVED/xcodegen-fixture-absence.log"
    exit 2
fi

build_config() {
    local config="$1"
    local log="$DERIVED/xcodebuild-${config}-fixture-absence.log"
    xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration "$config" \
        -sdk iphonesimulator -derivedDataPath "$DERIVED" build >"$log" 2>&1
}

build_config Release
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "UNMEASURED: Release の iphonesimulator ビルドが失敗(=まだ測っていない)"
    tail -20 "$DERIVED/xcodebuild-Release-fixture-absence.log"
    exit 2
fi

build_config Debug
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "UNMEASURED: Debug(錨)の iphonesimulator ビルドが失敗(=まだ測っていない)"
    tail -20 "$DERIVED/xcodebuild-Debug-fixture-absence.log"
    exit 2
fi

RELEASE_APP="$DERIVED/Build/Products/Release-iphonesimulator/RemoteMini.app"
DEBUG_APP="$DERIVED/Build/Products/Debug-iphonesimulator/RemoteMini.app"
RELEASE_BIN="$RELEASE_APP/RemoteMini"
DEBUG_BIN="$DEBUG_APP/RemoteMini"

if [ ! -f "$RELEASE_BIN" ]; then
    echo "UNMEASURED: Release バイナリが見当たらない -- $RELEASE_BIN"
    exit 2
fi
if [ ! -f "$DEBUG_BIN" ]; then
    echo "UNMEASURED: Debug バイナリ(錨)が見当たらない -- $DEBUG_BIN"
    exit 2
fi

# Debug 構成はこの Xcode が「debug dylib」最適化(インクリメンタルビルドを速める
# 為、実コードを `<Product>.debug.dylib` へ分離し、`.app/RemoteMini` 本体は
# outlined helper だけの薄いスタブになる)を使う事がある(実測 2026-08-05: スタブ
# 123,808 byte・`nm` で symbol 123件のみ、対して同名の `.debug.dylib` が
# 2,111,408 byte で `RootView` 等の実 symbol を持つ)。これに気付かず本体だけを
# 見ると、Debug 側の錨が「文字列が無い」= 検査そのものが壊れていると誤判定する
# (実際に一度そう倒れた: 2026-08-05 07:33 実測)。だから錨は**両方**を見る --
# 実コードが今後どちらに載っても取りこぼさない。Release は現行 Xcode でこの分割を
# 作らない(実測: dylib 無し、本体 1,321,264 byte)が、将来分割される可能性に
# 備えて同じ扱いにしておく(在れば足す、無ければ本体だけ)。
strings_all() {
    local app_dir="$1" main_bin="$2"
    strings "$main_bin" 2>/dev/null
    local dylib="$app_dir/RemoteMini.debug.dylib"
    [ -f "$dylib" ] && strings "$dylib" 2>/dev/null
    return 0
}

# `grep -c` 単体は「0件」を終了コード1で返す -- ここでは `set -e` の外なので、
# その1は「検査が失敗した」ではなく「件数が0だった」の意味でしかない。
release_count="$(strings_all "$RELEASE_APP" "$RELEASE_BIN" | grep -c RC_UI_FIXTURE)"
debug_count="$(strings_all "$DEBUG_APP" "$DEBUG_BIN" | grep -c RC_UI_FIXTURE)"

ok=1
if [ "$release_count" -ne 0 ]; then
    echo "RED: Release バイナリに RC_UI_FIXTURE の文字列が ${release_count} 件残っている"
    ok=0
fi
if [ "$debug_count" -lt 1 ]; then
    echo "RED: 錨(Debug)にも RC_UI_FIXTURE が一件も見えない = 検索方法そのものが壊れている疑い"
    ok=0
fi

if [ "$ok" -eq 1 ]; then
    echo "GREEN: Release=${release_count}件 / Debug(錨)=${debug_count}件"
    exit 0
fi
exit 1
