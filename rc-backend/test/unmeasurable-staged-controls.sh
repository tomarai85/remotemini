#!/bin/bash
# controls-for: tools/pre-commit-gates.sh
#
# 「**測れなかった**」を「**回す物が無い**」と読まない事の対照。
#
# ── なぜ要るか(2026-09-09、実測して確定)────────────────────────────────────
# `pre-commit-gates.sh` は、staged な path が code の regex に当たらない時、
# 下流に「回すなら何が回るか」だけ聞いて(`staged-controls-gate.sh --would-select`)、
# 答えが空なら code の門を**全部飛ばす**。以前は其の判定が **出力が空か**だけだった。
#
# 下流が壊れて何も出さずに落ちた時、其れは「回す物が無い」と**同じ形**になる。
# 実測: `--would-select` を rc=3 で落とすと、11 本の門のうち **3 本しか走らず**
# commit は成功した(8 本が黙って飛ぶ)。壊れた門は「門が無い」より悪い ——
# 門が在ると皆が思っている分だけ。
#
# 直しは「聞けなかったなら skip しない」= **終了コードで決める**。此の対照は其の
# 一点だけを、偽の下流を差して測る。
#
# 測る事(全部 砂場の作り木。本物の tools/ は 1 バイトも触らない):
#   U1 下流が「回す物が在る」と答えたら、code の門が全部走る
#   U2 下流が「無い」と答えたら、code の門は走らない(絞り込みが効いている)
#   U3 ★下流が**落ちた**ら skip せず止まる(rc≠0)。之が本題
#   U4 ★陰性対照: 終了コードを見ない版に戻すと U3 が緑に化ける
#   U5 ★下流が pipefail を宣言している(依存を検査できる前提条件へ置換、Codex 指摘)
#      = 此の検査が本当に其の一行を測っている事の証明
#
# 使い方: bash rc-backend/test/unmeasurable-staged-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤 / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../tools/pre-commit-gates.sh"
[ -f "$SUBJECT" ] || { echo "測る対象が無い: $SUBJECT"; exit 2; }

pass=0; fail=0; unmeasured=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail+1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# 本体が呼ぶ門の一覧を**本体の行から**取る(手で書くと、門が増えた日にずれる)。
GATES="$(grep -v -- '--would-select' "$SUBJECT" \
         | grep -oE 'bash "\$ROOT/[a-z0-9/_-]+\.sh"' \
         | sed -E 's#^bash "\$ROOT/(.*)\.sh"$#\1#')"
NGATES="$(printf '%s\n' "$GATES" | grep -c . )"
if [ "$NGATES" -lt 3 ]; then
    echo "UNMEASURED  本体から門の一覧を取れない(呼び方が変わった = この対照が古い)"
    echo "--- 合計: PASS 0 / FAIL 0 / UNMEASURED 1 ---"; exit 2
fi

# 偽 repo: 本体を置き、門は「名前を書くだけ」に差し替える。
# $1=根 / $2=下流の振る舞い(has|none|broken) / $3=本体の path(空なら本物)
mk_repo() {
    local r="$1" mode="$2" body="${3:-$SUBJECT}" g
    mkdir -p "$r/rc-backend/tools" "$r/docs"
    git -C "$r" init -q 2>/dev/null || return 1
    git -C "$r" config user.email "c@example.invalid"
    git -C "$r" config user.name "controls"
    cp "$body" "$r/rc-backend/tools/pre-commit-gates.sh"
    for g in $GATES; do
        mkdir -p "$r/$(dirname "$g")"
        printf '#!/bin/bash\nprintf "%%s\\n" "%s" >> "$RCLOG"\nexit 0\n' "$g" > "$r/$g.sh"
        chmod +x "$r/$g.sh"
    done
    case "$mode" in
      has)    printf '#!/bin/bash\nif [ "${1:-}" = "--would-select" ]; then printf "%%s\\n" "ios/tools/x-control.sh"; exit 0; fi\nprintf "%%s\\n" staged >> "$RCLOG"\n' ;;
      none)   printf '#!/bin/bash\nif [ "${1:-}" = "--would-select" ]; then exit 0; fi\nprintf "%%s\\n" staged >> "$RCLOG"\n' ;;
      broken) printf '#!/bin/bash\nif [ "${1:-}" = "--would-select" ]; then echo boom >&2; exit 3; fi\nprintf "%%s\\n" staged >> "$RCLOG"\n' ;;
    esac > "$r/rc-backend/tools/staged-controls-gate.sh"
    chmod +x "$r/rc-backend/tools/staged-controls-gate.sh"
    # ★staged は **code の regex に当たらない** path だけにする。当たると聞く枝へ
    #   入らないので、此の対照は何も測らない(最初に書いた版が其れで、全ケース
    #   11 本が走って『穴が無い』様に見えた)。
    printf 'x\n' > "$r/docs/note.txt"
    git -C "$r" add -A >/dev/null 2>&1
    git -C "$r" commit -qm base --no-verify >/dev/null 2>&1
    printf 'y\n' >> "$r/docs/note.txt"
    git -C "$r" add docs/note.txt >/dev/null 2>&1
    return 0
}
run_it() { # run_it <根> -> rc を返す。呼ばれた門は $RCLOG
    RCLOG="$SB/called.log" : > "$SB/called.log"
    ( cd "$1" && RCLOG="$SB/called.log" bash rc-backend/tools/pre-commit-gates.sh >/dev/null 2>&1 )
}
ncalled() { grep -c . "$SB/called.log" 2>/dev/null || echo 0; }

# ── U1 「在る」なら全部走る ───────────────────────────────────────────────
mk_repo "$SB/u1" has || { echo "FAIL  偽 repo を作れない"; exit 2; }
run_it "$SB/u1"; rc=$?
if [ "$rc" = "0" ] && [ "$(ncalled)" -ge "$NGATES" ]; then
    ok "U1 下流が『回す物が在る』と答えたら門が全部走る($(ncalled)/$NGATES 本)"
else ng "U1" "rc=$rc 呼ばれた門=$(ncalled)本(>= $NGATES を期待)"; fi

# ── U2 「無い」なら走らない ───────────────────────────────────────────────
mk_repo "$SB/u2" none || { echo "FAIL  偽 repo を作れない"; exit 2; }
run_it "$SB/u2"; rc=$?
n2="$(ncalled)"
if [ "$rc" = "0" ] && [ "$n2" -lt "$NGATES" ]; then
    ok "U2 下流が『無い』と答えたら code の門は走らない(絞り込みが効いている: $n2 本)"
else ng "U2" "rc=$rc 呼ばれた門=$n2 本(< $NGATES を期待)= 絞り込みが意味を失っている"; fi

# ── U3 ★落ちたら skip せず止まる ─────────────────────────────────────────
mk_repo "$SB/u3" broken || { echo "FAIL  偽 repo を作れない"; exit 2; }
run_it "$SB/u3"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "U3 ★下流が落ちたら skip せず止まる(rc=$rc)= 測れなかったを回す物が無いと読まない"
else ng "U3" "rc=0 で通した(呼ばれた門=$(ncalled)本)= 壊れた下流が門を黙って外した"; fi

# ── U4 ★陰性対照: 終了コードを見ない版に戻すと U3 が緑に化ける ────────────
# 之が無いと U3 は「たまたま止まった」でも緑になり、判定の一行を測った事にならない。
sed 's#if \[ "$ws_rc" -ne 0 \]; then#if false; then#' "$SUBJECT" > "$SB/old-shape.sh"
if cmp -s "$SUBJECT" "$SB/old-shape.sh"; then
    ng "U4 陰性対照" "変異の的が消えている = この対照が古い(判定の書き方が変わった)"
else
    mk_repo "$SB/u4" broken "$SB/old-shape.sh" || { echo "FAIL  偽 repo を作れない"; exit 2; }
    run_it "$SB/u4"; rc=$?
    if [ "$rc" = "0" ]; then
        ok "U4 ★終了コードを見ない版では素通しする(U3 は本当に其の一行を測っている)"
    else ng "U4 陰性対照" "古い形でも止まった(rc=$rc)= U3 の緑は別の理由かもしれない"; fi
fi

# ── U5 ★下流が自分の失敗を伝える形になっている(Codex 2026-09-09)──────────
# 此の門の正しさは「下流が壊れたら非零で落ちる」に依存する。下流の中で
#     selector | sed …
# の様なパイプが `pipefail` 無しで在ると、selector が rc=3 で何も出さなくても
# 全体は 0 になり、**此処の判定は正しいまま素通しする**。依存は文章では守れないので、
# 検査できる前提条件へ置き換える —— 下流が `pipefail` を宣言している事を直に見る。
DOWN="$HERE/../tools/staged-controls-gate.sh"
if [ ! -f "$DOWN" ]; then
    ng "U5 下流の前提" "$DOWN が居ない = 前提を確かめられない"
elif grep -qE '^set [^#]*pipefail' "$DOWN"; then
    ok "U5 ★下流が pipefail を宣言している(パイプの中の失敗が 0 に化けない)"
else
    ng "U5 ★下流が pipefail を宣言していない" \
       "パイプの終端が 0 なら失敗が消える = 此の門の判定が正しくても素通しする"
fi

echo ""
echo "--- 合計: PASS $pass / FAIL $fail / UNMEASURED $unmeasured ---"
[ "$fail" -gt 0 ] && exit 1
[ "$unmeasured" -gt 0 ] && exit 2
exit 0
