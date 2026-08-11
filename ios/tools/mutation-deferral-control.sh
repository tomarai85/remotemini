#!/bin/bash
# controls-for: ios/tools/signout-notice-control.sh
#
# `ios/tools/signout-notice-control.sh` の**繰り延べ規則**(#66、2026-08-12)の対照。
#
# 何を守るか: 変異20本を毎 commit 回すと 725 秒なので、commit では変異を繰り延べ、
# 基準(検査一式が緑 + 錨22本が実在して緑)だけを回す様にした。
# 壊れ方は**二方向**で、危険の格が全く違う:
#
#   繰り延べ過ぎ = 計器そのものを直した commit で変異が回らない
#                  -> 錨が鈍った事を証明する機会が消える。**此方が危ない。**
#   繰り延べ足りず = 全部回る -> 遅いだけ。安全側。
#
# ★もう一つ、格が同じくらい危ないのが「**黙って**繰り延べる」事。回さなかった物を
#   言わないと「触れた対照は全部緑」が分母の痩せた緑になる。だから印字も的にする。
#
# ★最初は「変わった面の変異だけ回す」形を測る対照だった。Codex に前提を否定されて
#   捨てた(変異の sed 対象は欠陥を注入する点であって、同じ欠陥が発生し得る file の
#   集合ではない)。経緯は測る対象の頭に書いてある。
#
# ★安い。`--which` は判定だけ答えて xcodebuild を1回も撃たない口なので全部で1秒未満。
# ★測るのは**写し**。追跡された file を其の場で汚さない —— 走行中に落ちた時、
#   計器が変異を作業木に残す事故を原理的に起こさない為。写しは同じ dir に置く
#   (`ROOT` を自分の位置から導く実装なので、別の dir へ写すと木を見失う)。
#
# 終了コード: 0=全部緑 / 1=赤が在る / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # = ios/tools
SUT="$HERE/signout-notice-control.sh"
[ -r "$SUT" ] || { echo "UNMEASURED  測る対象が無い: $SUT"; exit 2; }

pass=0; fail=0; unmeasured=0
ok() { echo "OK  $1"; pass=$((pass+1)); }
ng() { echo "NG  $1"; fail=$((fail+1)); }
un() { echo "UNMEASURED  $1"; unmeasured=$((unmeasured+1)); }

# ★写しの掃除は**glob で**やる。`mkcopy` は `$(...)` の中(= 子シェル)で呼ばれるので、
#   名前を変数へ溜めても親には戻らない —— 実際に此れで 6 本を作業木へ残した
#   (2026-08-12、`git status` で発覚)。走行が落ちた時に残った写しも同じ glob で消える。
PROBE_GLOB=".defer-probe-"
cleanup() { /bin/rm -f "$HERE/$PROBE_GLOB"*.tmp.sh 2>/dev/null; }
trap cleanup EXIT INT TERM HUP
cleanup   # 前の走行が落ちて残した物を先に掃く(残骸を「今回の写し」と読まない)

# `.` 始まりかつ `-control` を含まない名前 = 門からは対照として拾われない。
mkcopy() { # $1=識別子 -> 写しの path を印字
    local p="$HERE/$PROBE_GLOB$1.tmp.sh"
    /bin/cp "$SUT" "$p" && /bin/chmod +x "$p" || return 1
    printf '%s' "$p"
}
which_out() { # $1=写し $2=RC_STAGED_FILES の中身 -> 出力を印字
    if [ -z "$2" ]; then bash "$1" --which 2>&1
    else RC_STAGED_FILES="$2" bash "$1" --which 2>&1; fi
}
ran_n()   { printf '%s' "$1" | /usr/bin/sed -n 's/^--- 変異: 回す \([0-9]*\) 本.*/\1/p'; }
defer_n() { printf '%s' "$1" | /usr/bin/sed -n 's/^--- 変異: 回す [0-9]* 本 \/ 繰り延べ \([0-9]*\) 本.*/\1/p'; }

BASE="$(mkcopy base)" || { echo "UNMEASURED  写しが作れない"; exit 2; }

# 変異の総数は**訊く**(数を発明しない)。呼び出しの行から数える。
ALL_N="$(/usr/bin/grep -cE '^probe M[0-9]+' "$SUT")"
if [ "${ALL_N:-0}" -lt 2 ]; then
    un "変異の呼び出しが読めない(${ALL_N:-0} 本)= 以降は測っていない"
    echo "--- 合計: PASS $pass / FAIL $fail / UNMEASURED $unmeasured ---"
    exit 2
fi

want_all() { # $1=名前 $2=staged の中身
    local out n; out="$(which_out "$BASE" "$2")"; n="$(ran_n "$out")"
    if [ "$n" = "$ALL_N" ]; then ok "$1(全部回す: ${n}/${ALL_N})"
    else ng "$1 -- 回すのは ${n:-読めない} 本(全 ${ALL_N} 本を期待)= 証明の機会が消えている"; fi
}
want_defer() { # $1=名前 $2=staged の中身
    local out n d; out="$(which_out "$BASE" "$2")"; n="$(ran_n "$out")"; d="$(defer_n "$out")"
    if [ "${n:-x}" = "0" ] && [ "${d:-x}" = "$ALL_N" ]; then ok "$1(繰り延べ ${d}/${ALL_N})"
    else ng "$1 -- 回す ${n:-読めない} / 繰り延べ ${d:-読めない}(0 と ${ALL_N} を期待)"; fi
}

echo "=== 繰り延べない事(計器の証明が消えない側)"
want_all "D1 RC_STAGED_FILES 未設定(手叩き / 全掃き)" ""
want_all "D2 ★計器そのもの(計器を直した commit は計器を全部証明する)" "ios/tools/signout-notice-control.sh"
want_all "D3 ★ビルドの土台 project.yml" "ios/project.yml"
want_all "D4 ★ビルドの土台 build.sh" "ios/tools/build.sh"
want_all "D5 ★計器 + 他の file が同じ commit に居ても繰り延べない" "ios/Sources/AppState.swift
ios/tools/signout-notice-control.sh"

echo "=== 繰り延べる事(#66 が効いている側)"
want_defer "D6 製品の file だけ(Sources)" "ios/Sources/Core/Provisioning.swift"
want_defer "D7 検査の file だけ(Tests)" "ios/Tests/AppStateTests.swift"
want_defer "D8 ★ios 以外だけ(此の対照が呼ばれる筈は無いが、呼ばれても黙らない)" "rc-backend/src/server.mjs"

echo "=== 黙って繰り延べない事(分母の痩せた緑を作らない)"
out="$(which_out "$BASE" "ios/Sources/Core/Provisioning.swift")"
if printf '%s' "$out" | /usr/bin/grep -q '繰り延べた変異:.*M13' \
   && printf '%s' "$out" | /usr/bin/grep -q '緑ではない'; then
    ok "D9 ★繰り延べた変異を名前で印字し、緑でないと断る"
else
    ng "D9 -- 繰り延べた変異の名前か「緑ではない」の断りが出力に無い"
fi
if printf '%s' "$out" | /usr/bin/grep -qE '^ +bash .*signout-notice-control\.sh' \
   && printf '%s' "$out" | /usr/bin/grep -qF 'run-controls.sh --all'; then
    ok "D10 ★何を叩けば全部回るかを出力に書く(読み手が繰り延べを閉じられる)"
else
    ng "D10 -- 繰り延べを閉じる手が出力に無い = 読み手は何をすれば良いか判らない"
fi
# 数が嘘をつかない事。2026-08-12 に実際に踏んだ(本番だけ基準の緑まで1本に数えていた)。
defer_lines="$(printf '%s' "$out" | /usr/bin/grep -c '^  DEFER ')"
if [ "$(defer_n "$out")" = "$defer_lines" ]; then
    ok "D11 ★要約の数 = 実際に繰り延べた変異の数(${defer_lines})"
else
    ng "D11 -- 要約は $(defer_n "$out") 本、DEFER 行は ${defer_lines} 本 = 数が嘘をついている"
fi
n_calls="$(/usr/bin/grep -c 'defer_summary "\$RAN_N" "\$DEFERRED_N"' "$SUT")"
if [ "$n_calls" = 2 ]; then
    ok "D12 ★本番と --which が同じ counter を渡す(呼び出し 2 箇所)"
else
    ng "D12 -- defer_summary へ RAN_N/DEFERRED_N を渡す呼び出しが ${n_calls} 箇所(2 を期待)"
fi

echo "=== 全走行の印(出荷の口が読む物)"
# D13: 繰り延べた走行は印を置かない。置くと「回した」と「回していない」が同じ顔になる
#      = #66 が作った穴そのもの。
_ans="$(bash "$SUT" --sweep-digest 2>/dev/null)"
_dg="$(printf '%s' "$_ans" | /usr/bin/sed -n '1p')"
_st="$(printf '%s' "$_ans" | /usr/bin/sed -n '2p')"
if printf '%s' "$_dg" | /usr/bin/grep -qE '^[0-9a-f]{40}$' && [ -n "$_st" ]; then
    ok "D13 ★--sweep-digest が digest と印の場所を答える"
else
    ng "D13 -- --sweep-digest の答えが読めない(digest=[$_dg] 印=[$_st])"
fi

# D14: digest が**本当に**測る file 群から出ている事。定数なら出荷の警告は永久に沈黙する。
#      追跡 file は触らない —— ios/Tests に空の .swift を一時的に置いて digest が動くか見る。
_probe_swift="$HERE/../Tests/.deferral-control-probe.swift"
: > "$_probe_swift" 2>/dev/null
_dg2="$(bash "$SUT" --sweep-digest 2>/dev/null | /usr/bin/sed -n '1p')"
/bin/rm -f "$_probe_swift"
_dg3="$(bash "$SUT" --sweep-digest 2>/dev/null | /usr/bin/sed -n '1p')"
if [ "$_dg" != "$_dg2" ] && [ "$_dg" = "$_dg3" ]; then
    ok "D14 ★digest は測る file 群から出ている(検査を1本足すと動き、戻すと戻る)"
elif [ "$_dg" = "$_dg2" ]; then
    ng "D14 -- 検査 file を足しても digest が動かない = 出荷の警告は永久に沈黙する"
else
    un "D14 -- 戻した後の digest が元に戻らない(掃除に失敗した可能性)"
fi

# D15: 出荷の口は digest を**訊く**。書き写すと実装が2本になり、食い違いが嘘の警告になる。
BUILD="$HERE/build.sh"
if [ ! -r "$BUILD" ]; then
    un "D15 -- ios/tools/build.sh が読めない = 継ぎ目は測っていない"
elif /usr/bin/grep -q -- '--sweep-digest' "$BUILD"; then
    ok "D15 ★出荷の口は digest を訊く(写しを持たない)"
else
    ng "D15 -- build.sh が --sweep-digest を呼んでいない = digest の実装が2本目に化けている"
fi

# ── 陰性対照: 上の緑が**測られている**事を、壊して確かめる ────────────────────
mutate() { # $1=識別子 $2=sed の式 -> 写しの path を印字(当たらなければ空)
    local p; p="$(mkcopy "$1")" || return 1
    /usr/bin/sed -i '' "$2" "$p"
    if /usr/bin/cmp -s "$SUT" "$p"; then printf ''; else printf '%s' "$p"; fi
}
echo "=== 陰性対照(壊すと赤くなる事)"

X1="$(mutate x1 '/_has_line "\$STAGED_IOS" "\$SELF_REL"           \&\& DEFER=0/d')"
if [ -z "$X1" ]; then un "X1 ★変異が当たっていない = D2 の緑は測っていない"
else
    n="$(ran_n "$(which_out "$X1" "ios/tools/signout-notice-control.sh")")"
    [ "${n:-x}" = "0" ] && ok "X1 ★計器の逃げ道を消すと計器の commit でも繰り延べる(= D2 に歯が在る)" \
                        || ng "X1 -- 逃げ道を消したのに回すのは ${n:-読めない} 本 = D2 に歯が無い"
fi

X2="$(mutate x2 's/^    DEFER=1$/    DEFER=0/')"
if [ -z "$X2" ]; then un "X2 ★変異が当たっていない = D6/D7 の緑は測っていない"
else
    n="$(ran_n "$(which_out "$X2" "ios/Sources/Core/Provisioning.swift")")"
    [ "${n:-x}" = "$ALL_N" ] && ok "X2 ★繰り延べを止めると全部回る(= D6/D7 が繰り延べを測っている)" \
                             || ng "X2 -- 止めたのに回すのは ${n:-読めない} 本 = D6/D7 に歯が無い"
fi

X3="$(mutate x3 '/^        echo "  繰り延べた変異:\${DEFERRED:- なし}"$/d')"
if [ -z "$X3" ]; then un "X3 ★変異が当たっていない = D9 の緑は測っていない"
else
    if printf '%s' "$(which_out "$X3" "ios/Sources/Core/Provisioning.swift")" \
       | /usr/bin/grep -q '繰り延べた変異:'; then
        ng "X3 -- 名前の行を消したのにまだ出ている = D9 に歯が無い"
    else ok "X3 ★名前の行を消すと D9 が成り立たなくなる(= D9 に歯が在る)"; fi
fi

X4="$(mutate x4 's/^    defer_summary "\$RAN_N" "\$DEFERRED_N"$/    defer_summary "$((PASS+FAIL+UNMEASURED))" "$DEFERRED_N"/')"
if [ -z "$X4" ]; then un "X4 ★変異が当たっていない = D12 の緑は測っていない"
elif [ "$(/usr/bin/grep -c 'defer_summary "\$RAN_N" "\$DEFERRED_N"' "$X4")" = 1 ]; then
    ok "X4 ★片方を別の counter に戻すと D12 が破れる(= D12 に歯が在る)"
else
    ng "X4 -- 戻したのに呼び出しが 2 箇所のまま = D12 に歯が無い"
fi

X5="$(mutate x5 's|^if \[ "\$DEFER" -eq 0 \] \&\& \[ "\$FAIL" -eq 0 \]|if [ "$DEFER" -eq 2 ] \&\& [ "$FAIL" -eq 0 ]|')"
if [ -z "$X5" ]; then un "X5 ★変異が当たっていない = 印を置く条件は測っていない"
else
    if /usr/bin/grep -q 'if \[ "\$DEFER" -eq 0 \] && \[ "\$FAIL" -eq 0 \]' "$SUT"; then
        ok "X5 ★印を置くのは「繰り延べ無し かつ 赤0 かつ 未測定0」の時だけ"
    else
        ng "X5 -- 印を置く条件が読めない = 繰り延べた走行が印を置き得る"
    fi
fi

echo "--- 合計: PASS $pass / FAIL $fail / UNMEASURED $unmeasured ---"
[ "$fail" -gt 0 ] && exit 1
[ "$unmeasured" -gt 0 ] && exit 2
exit 0
