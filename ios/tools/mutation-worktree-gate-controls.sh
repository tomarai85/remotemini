#!/bin/bash
# controls-for: ios/tools/mutation-worktree-gate.sh
#
# 「変異対照が作業中の木を書き換えるのを、これ以上増やさない」門の対照。
#
# ★測る中心は「今 緑か」ではない。緑は借金の数を写しているだけ。測るのは
#   **検出器が実物に当たるか** —— 此の門は書き直すたびに実物を取り零した:
#     1回目 `sed -i` の行に path が在るか        → **0 本**(書き換え先は変数で渡る)
#     2回目 `git checkout --` で戻すか            → 註記の文まで当たり、
#                                                  写しから戻す**主犯**を丸ごと取り零した
#     3回目 書き換え先の変数を追う                → 関数経由の間接参照を取り零した
#                                                  (取り零したのは**私が書いた対照**)
#     4回目 間接参照も当てる + 写しを作る台本は外す → 実物と一致
#   だから対照は「見つけるか」と「見つけ過ぎないか」の**両方**を撃つ。
#
#   G1 ★木を直接書き換える偽物を置くと**未宣言**として挙げる
#   G2 ★写しの上で撃つ偽物は挙げない(false positive も欠陥)
#   G3 ★註記で `git checkout --` に言及するだけの偽物は挙げない
#   G4 ★関数経由の間接参照(変数を関数へ渡す形)も挙げる
#   G5 宣言に在る名前は緑のまま通す(借金は通す)
#   G6 宣言が実態より古い(もう書き換えていない)なら赤
#   G7 走査対象が 0 本なら 2(綴りが変わった時に黙って緑にしない)
#   G8 実 repo で借金が**増えていない**
#   G9 ★共通の砂場(`mutation-sandbox.sh`)を使う台本は挙げない
#   G10 ★`MS_TREE` を自分で定義した台本は挙げる(名前だけでは許さない)
#   G11 ★「触るのが不可避」は名前と理由を毎回出す(黙って許す一覧に化けない)
#   G12 ★「不可避」に挙げた物が もう木を触らないなら赤(一覧が腐らない)
#
# 使い方: bash ios/tools/mutation-worktree-gate-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # = ios/tools
SUT="$HERE/mutation-worktree-gate.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/scan"

# ★偽物の中身は**連結で組み立てる**。生の綴りを此の file に置くと、
#   実 repo を走査した時に**此の対照自身**が引っ掛かる
#   (`mutation-freeze-controls.sh` が 2026-08-03 に同じ結論を書いている)。
SEDI="sed -""i"
CO="git check""out --"
SRC="Sour""ces"

# ★出力を**先に受けてから**探す。`… | grep -q` にすると、`grep -q` が最初の一致で
#   閉じ、上流が SIGPIPE(141)で終わる。`set -o pipefail` の下では其の 141 が
#   pipeline の値になり、**一致しているのに偽**になる。
#   (`method_a_red_check_can_be_the_checks_own_defect` に同じ型が記録されている)
listed() {  # listed <名前> → 一覧に出るか
    local out
    out="$(RC_MWG_SCAN="$SB/scan" bash "$SUT" --list 2>&1)"
    case "$out" in *"$1"*) return 0 ;; esac
    return 1
}

# ── G1 直接書き換える偽物 ─────────────────────────────────────────────────
printf '#!/bin/bash\nVM="$IOS/%s/A.swift"\n/usr/bin/%s "" "s/a/b/" "$VM"\n' "$SRC" "$SEDI" \
    > "$SB/scan/direct-control.sh"
listed "direct-control.sh" && ok "G1 ★木を直接書き換える偽物を挙げる" \
                           || ng "G1 直接書き換え" "挙げていない = 検出器が実物に当たらない"

# ── G2 写しの上で撃つ偽物 ─────────────────────────────────────────────────
printf '#!/bin/bash\nVM="$IOS/%s/A.swift"\nWORK=$(mktemp -d)\ncp "$VM" "$WORK/a"\n/usr/bin/%s "" "s/a/b/" "$WORK/a"\n' \
    "$SRC" "$SEDI" > "$SB/scan/copy-control.sh"
listed "copy-control.sh" && ng "G2 写しの上" "挙げてしまう(false positive も欠陥)" \
                         || ok "G2 ★写しの上で撃つ偽物は挙げない"

# ── G3 註記で言及するだけ ────────────────────────────────────────────────
printf '#!/bin/bash\nVM="$IOS/%s/A.swift"\n# 戻すのは %s で足りる\necho "%s $VM で戻す事"\n' \
    "$SRC" "$CO" "$CO" > "$SB/scan/prose-control.sh"
listed "prose-control.sh" && ng "G3 註記だけ" "挙げてしまう(もう触らない台本を借金に数える)" \
                          || ok "G3 ★註記で言及するだけの偽物は挙げない"

# ── G4 関数経由の間接参照 ────────────────────────────────────────────────
# ★此処を取り零したのは実際に起きた事(私が書いた対照が挙がらなかった)。
printf '#!/bin/bash\nVM="$IOS/%s/A.swift"\nmut() { /usr/bin/python3 - "$1" <<EOF\npass\nEOF\n}\nmut "$VM"\n' \
    "$SRC" > "$SB/scan/indirect-control.sh"
listed "indirect-control.sh" && ok "G4 ★関数へ変数を渡す形(間接参照)も挙げる" \
                             || ng "G4 間接参照" "挙げていない = 私が踏んだ取り零しが再発する"

# ── G9 ★共通の砂場を使う台本は挙げない ─────────────────────────────────────
# `mutation-sandbox.sh` を source して `$MS_TREE/Sources/…` を書き換える台本は、
# 作業中の木を1バイトも触らない。根の変数は助けの側に在るので、
# 此の台本の中を幾ら探しても `mktemp` は出て来ない —— **source している事**が信号。
printf '#!/bin/bash\n. "$IOS/tools/mutation-sandbox.sh"\nms_prepare || exit 2\nVM="$MS_TREE/%s/A.swift"\n/usr/bin/%s "" "s/a/b/" "$VM"\n' \
    "$SRC" "$SEDI" > "$SB/scan/sandboxed-control.sh"
listed "sandboxed-control.sh" && ng "G9 砂場を使う台本" "挙げてしまう(移した台本が借金に残る)" \
                              || ok "G9 ★共通の砂場を使う台本は挙げない"

# ── G10 ★名前だけでは許さない(自分で MS_TREE を定義して素通りできない)──────
# 名前の一致だけで許すと、`MS_TREE=` を自分で定義して砂場を装える。
printf '#!/bin/bash\nMS_TREE="$IOS"\nVM="$MS_TREE/%s/A.swift"\n/usr/bin/%s "" "s/a/b/" "$VM"\n' \
    "$SRC" "$SEDI" > "$SB/scan/fake-sandbox-control.sh"
listed "fake-sandbox-control.sh" && ok "G10 ★MS_TREE を自分で定義した台本は挙げる(名前だけでは許さない)" \
                                 || ng "G10 偽の砂場" "素通りした = 名前の一致だけで許している"
/bin/rm -f "$SB/scan/sandboxed-control.sh" "$SB/scan/fake-sandbox-control.sh"

# ── G5 / G6 宣言との突き合わせ ───────────────────────────────────────────
# 宣言に在る物だけが在る状態 → 緑。
/bin/rm -f "$SB/scan/copy-control.sh" "$SB/scan/prose-control.sh" "$SB/scan/indirect-control.sh"
out="$(RC_MWG_SCAN="$SB/scan" bash "$SUT" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "増えた"; then
    ok "G5 宣言に無い物が在れば赤(此の砂場の偽物は宣言に無い)"
else ng "G5 未宣言" "rc=$rc / $out"; fi

# 宣言に在るのに実態が無い → 赤(宣言が実態から離れると門は何も守らなくなる)。
/bin/rm -f "$SB/scan/direct-control.sh"
printf '#!/bin/bash\necho nothing\n' > "$SB/scan/account-ui-control.sh"
# ★宣言を**此処で差す**(2026-08-30)。借金が 0 になった日、実物の宣言が空になって
#   此の枝が「測れる宣言が無い」で赤くなった —— 対照が本番の状態に依存していた形。
out="$(RC_MWG_SCAN="$SB/scan" RC_MWG_DEBT="
account-ui-control.sh
" bash "$SUT" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "宣言が実態より古い"; then
    ok "G6 宣言が実態より古ければ赤(消せる物を消させる)"
else ng "G6 古い宣言" "rc=$rc / $(printf '%s' "$out" | tail -1)"; fi

# ── G7 走査対象が 0 本 ───────────────────────────────────────────────────
mkdir -p "$SB/empty"
RC_MWG_SCAN="$SB/empty" bash "$SUT" >/dev/null 2>&1
[ $? -eq 2 ] && ok "G7 走査対象が 0 本なら 2(黙って緑にしない)" || ng "G7 0 本" "rc=$?"

# ── G8 実 repo ──────────────────────────────────────────────────────────
bash "$SUT" >/dev/null 2>&1
[ $? -eq 0 ] && ok "G8 実 repo で借金が増えていない" \
             || { ng "G8 実 repo" "$(bash "$SUT" 2>&1 | head -2)"; }

# ── G11 ★「触るのが不可避」は理由ごと毎回出る(黙って許さない)────────────
# 借金と別枠にした以上、抜け道になり得る。**理由が画面に出続ける**事が抑止で、
# 出なくなったら其の枠は「黙って許す一覧」に化ける。
out="$(bash "$SUT" 2>&1)"
if printf '%s' "$out" | grep -q "触るのが不可避:" && printf '%s' "$out" | grep -q "digest"; then
    ok "G11 ★『触るのが不可避』は名前と理由を毎回出す"
else ng "G11 不可避の可視化" "理由が出ていない = 黙って許す一覧に化けている"; fi

# ── G12 ★「不可避」に挙げた物が もう木を触らないなら赤(一覧が腐らない)──────
# 実物を触らずに測る: 走査の根を空にすれば、挙げた名前は「もう触っていない」側に回る。
mkdir -p "$SB/none"
bash "$SUT" >/dev/null 2>&1
RC_MWG_SCAN="$SB/scan2" bash "$SUT" >/dev/null 2>&1
mkdir -p "$SB/scan2"
printf '#!/bin/bash\nVM="$IOS/%s/A.swift"\n/usr/bin/%s "" "s/a/b/" "$VM"\n' "$SRC" "$SEDI" \
    > "$SB/scan2/direct-control.sh"
out="$(RC_MWG_SCAN="$SB/scan2" RC_MWG_DEBT="
direct-control.sh
" bash "$SUT" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "もう木を触っていない"; then
    ok "G12 ★『不可避』に挙げた物が走査に居なければ赤(一覧が実態から離れない)"
else ng "G12 腐った不可避" "rc=$rc / $(printf '%s' "$out" | tail -1)"; fi

echo ""
echo "MUTATION-WORKTREE-GATE-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
