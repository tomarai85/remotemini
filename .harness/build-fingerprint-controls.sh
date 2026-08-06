#!/bin/bash
# controls-for: ios/tools/build.sh
#
# `build.sh --sim` が log の隣に落とす**原稿の指紋**の対照。
#
# ── なぜ要るか ──────────────────────────────────────────────────────────
# `.harness/dod-sprint-6.5.sh` の 0 行目は、この指紋だけを根拠に
# 「この log は今の木の話だ」と言う。そして 0 行目が緑の時にだけ、log を根拠にする
# 5 行(1-b / 2-b / 3 / 5-a / 6-b)が緑になれる。つまり **受入の緑 6 行がこの一文に
# 懸かっている**のに、commit の門は 2026-08-07 の時点で
#   「注記 — 対照を導けない道具: build.sh」
# と正直に言っていた。門が名指しした穴を、その日のうちに塞ぐ。
#
# ── 壊れ方には2種類あり、危ないのは片方だけ ────────────────────────────
#   指紋が**書かれない / 壊れる**  -> 0 行目は 未測定。閉じる側に倒れるので安全。
#   指紋が**古い中身を指す**      -> 0 行目は **緑**。古い log が今の木の証拠になる。
# 後者だけが受入を嘘にする。だから此処は「順序」と「範囲」を測る:
#   順序 = xcodebuild が走る**前**に取っているか(後で取ると、走らせた木ではなく
#          走り終えた後の木の指紋になる = 走行中に原稿を変えた回が緑で通る)
#   範囲 = Sources / Tests / UITests の**どれを変えても**指紋が動くか
#
# ★指紋の式は build.sh から**切り出して**回す(写しを持たない)。写すと、
#   build.sh 側だけ変わった日にこの対照が古い式を測り続ける —— この repo が
#   何度も踏んでいる「手で同期する一覧が2本」と同じ形になる。
#   先例: .harness/dod-sprint-6-recovery-controls.sh(的の本文から切り出して回す)
#
# ★xcodebuild は回さない(数分 x 何本、の代償を払う理由が無い)。
#   測るのは式そのものと、build.sh の中での順序。実測 1 秒未満。
#
# 終了コード: 0=全部の対照が期待通り / 1=期待通りでない物が在る / 2=測れなかった
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HARNESS/.." && pwd)"
BUILD="$ROOT/ios/tools/build.sh"
PASS=0; FAIL=0
WT="$(mktemp -d "${TMPDIR:-/tmp}/buildfp-controls.XXXXXX")"
trap 'rm -rf "$WT"' EXIT

[ -f "$BUILD" ] || { echo "測れない: $BUILD が無い"; exit 2; }

ok() { PASS=$((PASS+1)); printf '  OK   %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  NG   %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

echo "=== build.sh --sim の指紋 対照 ==="

# --- 1. 順序: 指紋は xcodebuild より前に取っているか --------------------------
# 行番号ではなく**出現の順**で見る(行番号を書くと註が1行増えるだけで腐る)。
fp_line="$(grep -n 'xcodebuild-sim\.sources\.sha' "$BUILD" | head -1 | cut -d: -f1)"
xb_line="$(grep -n 'xcodebuild -project' "$BUILD" | head -1 | cut -d: -f1)"
if [ -z "$fp_line" ]; then
    ng "指紋を落とす行が在る" "build.sh に xcodebuild-sim.sources.sha が無い"
elif [ -z "$xb_line" ]; then
    ng "xcodebuild の行が在る" "build.sh に xcodebuild -project が無い"
elif [ "$fp_line" -lt "$xb_line" ]; then
    ok "指紋を xcodebuild より前に取っている(走らせた木の指紋になる)"
else
    ng "指紋を xcodebuild より前に取っている" \
       "後で取っている = 走行中に原稿を変えた回が緑で通る(指紋 $fp_line 行 / xcodebuild $xb_line 行)"
fi

# --- 2. 式を build.sh から切り出す --------------------------------------------
# `( cd "$HERE" && find …` から `> "$SRC_SHA"` を含む行までを、そのまま取る。
EXPR="$WT/expr.sh"
awk '/^ *\( cd "\$HERE" && find Sources/{f=1} f{print} f && /> "\$SRC_SHA"/{exit}' \
    "$BUILD" > "$EXPR"
if [ ! -s "$EXPR" ]; then
    echo "  NG   指紋の式を切り出せない = 此処から先は測れていない"
    echo "       build.sh の式の形が変わった。この対照の awk を合わせる事。"
    echo
    echo "=== 合計: OK $PASS / NG $((FAIL+1)) ==="
    exit 2
fi
ok "指紋の式を build.sh から切り出せた($(grep -c . "$EXPR") 行、写しは持たない)"

# 切り出した式を、砂場の木に対して回す小片。
digest() { # digest <木の根>
    HERE="$1" SRC_SHA="$WT/out.sha" bash -c "set -euo pipefail; $(cat "$EXPR")" 2>/dev/null \
        && cat "$WT/out.sha"
}

# --- 3. 砂場の木を作る --------------------------------------------------------
TREE="$WT/tree"
ORIG="$WT/orig"
mkdir -p "$TREE/Sources" "$TREE/Tests" "$TREE/UITests"
printf 'let a = 1\n' > "$TREE/Sources/A.swift"
printf 'let b = 2\n' > "$TREE/Tests/B.swift"
printf 'let c = 3\n' > "$TREE/UITests/C.swift"
# ★戻しは**複製から**行う。元の中身を式の中に書き直す形にしたら、
#   `$(case $f in A) …)` の `)` が command substitution を先に閉じて戻しが不発になった
#   (2026-08-07、此処で実際にやった)。そして下の「戻すと指紋も戻る」がそれを捕まえた ——
#   戻し損ないは、後続の対照を**別の理由で**赤くする形の壊れ方をするので、
#   戻せた事自体を測る行が要る。
cp -R "$TREE" "$ORIG"

# ★mtime は**毎回明示で固定する**。固定しないと、下の「中身を変えると動く」3行が
#   秒の境目を跨いだかどうかで結果を変える —— 2026-08-07 に mtime 変異を2回回して
#   NG 4 と NG 2 の別々の結果が出た(壊し方は同じ)。再現しない陰性対照の表は、
#   道具が嘘を吐いているのと同じ。ここを固定すると、中身の行は**中身だけ**を測る。
PIN=202001010000
pin() { touch -t "$PIN" "$TREE"/*/*.swift; }
restore_tree() { rm -rf "$TREE"; cp -R "$ORIG" "$TREE"; pin; }
pin
base="$(digest "$TREE")"
if [ -z "$base" ]; then
    echo "  NG   砂場の木で指紋が出ない = 此処から先は測れていない"
    echo
    echo "=== 合計: OK $PASS / NG $((FAIL+1)) ==="
    exit 2
fi
ok "砂場の木で指紋が出る(${base:0:12})"

# --- 4. 範囲: 3 つの木のどれを変えても指紋が動く ------------------------------
# ★一番効く対照。`find Sources Tests` の様に1つ落ちても、普段の走行では誰も気付かない
#   (指紋は毎回出るし、0 行目は緑のまま)。落ちた木の変更だけが**黙って**素通りする。
for d in Sources:A Tests:B UITests:C; do
    dir="${d%%:*}"; f="${d##*:}"
    printf 'let %s = 999\n' "$f" > "$TREE/$dir/$f.swift"
    pin                      # ★中身だけが違う状態にする(mtime は据え置き)
    now="$(digest "$TREE")"
    if [ "$now" != "$base" ]; then
        ok "$dir の中身を変えると指紋が動く"
    else
        ng "$dir の中身を変えると指紋が動く" \
           "動かない = $dir だけの変更が古い log で緑のまま通る"
    fi
    restore_tree
done

# 戻したら元の指紋に戻る事(戻せていないなら上の3件は別の理由で動いていた)
if [ "$(digest "$TREE")" = "$base" ]; then
    ok "戻すと指紋も戻る(上の3件は本当にその変更で動いていた)"
else
    ng "戻すと指紋も戻る" "戻らない = 上の3件が測っていたのは中身ではない"
fi

# --- 5. 中身であって mtime ではない -------------------------------------------
# ★これが指紋を入れた理由そのもの。mtime を代理にして外した経緯は build.sh の註に在る。
#
# ★時刻は**明示で**打つ。素の `touch` は作った直後だと同じ秒に落ちるので、
#   mtime を測る式に差し替えてもこの行は緑のままだった(2026-08-07、変異で確認)。
#   「壊した時に赤くなるか」を実際に試すまで、此処は緑の理由を取り違えていた。
#   今は木全体を $PIN に固定してあるので、此処だけ**別の時刻**に打てば差が確実に出る。
touch -t 202506010000 "$TREE/Sources/A.swift" "$TREE/Tests/B.swift" "$TREE/UITests/C.swift"
if [ "$(digest "$TREE")" = "$base" ]; then
    ok "触っただけ(mtime のみ)では指紋が動かない = 中身を測っている"
else
    ng "触っただけでは指紋が動かない" \
       "動く = mtime を測っている。変異を複製から戻す対照の後で毎回 未測定 になる"
fi
# ★此処で木を**canonical へ戻す**。戻さずに下へ行くと、上で打った別時刻が残り、
#   下の陰性対照が「変異のせい」ではなく**私の後始末のせい**で赤くなる
#   (2026-08-07 に実際に出した偽の赤: 変異3 の kill set が 4 本ではなく 5 本に見えた)。
restore_tree

# --- 6. 陰性対照: 範囲を1つ落とせば、この対照は赤くなるか ---------------------
# 上の 4 が「効いている」事の確認。式から UITests を落とした版で同じ事を測り、
# **UITests の行だけが落ちる**なら、4 は本当に範囲を見ている。
NARROW="$WT/narrow.sh"
/usr/bin/sed 's|find Sources Tests UITests|find Sources Tests|' "$EXPR" > "$NARROW"
if ! /usr/bin/grep -q 'find Sources Tests$\|find Sources Tests ' "$NARROW"; then
    ng "陰性対照: 範囲を狭めた式を作れた" "sed が当たらなかった = 陰性対照が空振り"
else
    nbase="$(HERE="$TREE" SRC_SHA="$WT/n.sha" bash -c "set -euo pipefail; $(cat "$NARROW")" \
             >/dev/null 2>&1 && cat "$WT/n.sha")"
    printf 'let C = 999\n' > "$TREE/UITests/C.swift"; pin
    nnow="$(HERE="$TREE" SRC_SHA="$WT/n.sha" bash -c "set -euo pipefail; $(cat "$NARROW")" \
            >/dev/null 2>&1 && cat "$WT/n.sha")"
    restore_tree
    if [ -n "$nbase" ] && [ "$nbase" = "$nnow" ]; then
        ok "陰性対照: 範囲から UITests を落とすと UITests の変更が見えなくなる(4 は効いている)"
    else
        ng "陰性対照: 範囲を落とすと見えなくなる" \
           "狭めても指紋が動いた = 4 の緑は範囲を測って出た物ではない"
    fi
fi

echo
echo "=== 合計: OK $PASS / NG $FAIL ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
