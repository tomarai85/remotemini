#!/bin/bash
# controls-for: tools/shellcheck-gate.sh
#
# `shellcheck-gate.sh` の負の対照。**門が本当に赤を出せるか**だけを測る。
#
# ★測る中心は「指摘を見つけるか」ではなく **通してはいけない物を通さないか**。
#   此の門は「指摘 0 件」を出す門なので、壊れ方は必ず**静かな緑**の形で来る:
#   走査が空振りしても 0 件、道具が居なくても 0 件、`disable` を撒いても 0 件。
#   だから作り木の上で其の 3 つを実際に作って、門が緑を出さない事を毎回示す。
#
# 測る事(全部 砂場の作り木。本物の tools/ は 1 バイトも触らない):
#   G1 指摘の無い台本だけなら緑
#   G2 指摘の在る台本が 1 本 在れば赤(rc=1)で、その file を名指しする
#   G3 ★理由つきの `disable` は緑(構造上ひとつに出来ない対を残せる)
#   G4 ★理由の**無い** `disable` は赤 —— 之が無いと門は「黙らせれば通る」門になる
#   G5 ★走査が下限を割ったら緑にせず測定不成立(rc=2)。空の網を違反 0 と読まない
#   G6 ★`shellcheck` が居なければ測定不成立(rc=2)。道具の不在を指摘の不在と読まない
#   G7 ★空の `#` を足しただけの理由では免除されない(判定は理由の中身の長さ)
#   G8 ★道具が異常終了したら測定不成立(出力が空でも measured ではない)
#   G9/G10 ★除外は理由の宣言 —— 理由が短い / 除外先が消えている なら測定不成立
#   G11 陰性対照: 理由つきで実在する除外は本当に走査から外れる
#
# 使い方: bash rc-backend/test/shellcheck-gate-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤 / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../tools/shellcheck-gate.sh"
[ -f "$GATE" ] || { echo "測る対象が無い: $GATE"; exit 2; }
command -v shellcheck >/dev/null 2>&1 || {
    echo "UNMEASURED  shellcheck が居ないので門の判定は測れない"
    echo "--- 合計: PASS 0 / FAIL 0 / UNMEASURED 1 ---"; exit 2; }

pass=0; fail=0; unmeasured=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail+1)); }
un() { echo "UNMEASURED  $1"; unmeasured=$((unmeasured+1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
GOUT="$SB/out.txt"

# 門は自分の位置から `../../rc-backend/tools` と `../../ios/tools` を引く。其の形を組む。
build_tree() { # build_tree <名前> <clean な台本の本数>
    local t="$SB/$1" n="$2" i
    mkdir -p "$t/rc-backend/tools" "$t/ios/tools"
    # ★写した門の EXCLUDED は**空にする**。本物の除外先は作り木に居ないので、
    #   そのまま写すと全ケースが「腐った除外」で倒れる(2026-09-09、自分で踏んだ)。
    #   除外の振る舞いは下の G9/G10/G11 が**自分で行を足して**測る。
    /usr/bin/sed -e '/^EXCLUDED=(/,/^)$/c\
EXCLUDED=()\
' "$GATE" > "$t/rc-backend/tools/shellcheck-gate.sh"
    i=0
    while [ "$i" -lt "$n" ]; do
        printf '#!/bin/bash\nset -u\necho "clean %s"\n' "$i" > "$t/ios/tools/clean-$i.sh"
        i=$((i+1))
    done
    printf '%s' "$t"
}
run_gate() { # run_gate <木> [env…] -> rc を返す。出力は $GOUT
    local t="$1"; shift
    env "$@" bash "$t/rc-backend/tools/shellcheck-gate.sh" > "$GOUT" 2>&1
}

# ── G1 clean なら緑 ───────────────────────────────────────────────────────
T="$(build_tree g1 3)"
run_gate "$T" RC_SHELLCHECK_FLOOR=3; GRC=$?
[ "$GRC" = "0" ] && ok "G1 指摘の無い台本だけなら緑" || ng "G1" "rc=$GRC / $(cat "$GOUT")"

# ── G2 指摘が在れば赤で名指し ─────────────────────────────────────────────
T="$(build_tree g2 3)"
# SC2115 と同じ形(生の変数を rm -rf の引数に置く)
# ★「必ず warning を出す」形を使う。最初は SC2115 を狙って生の変数を rm -rf に
#   置いたが、其の書き方では shellcheck は何も言わず **G2 が緑になった** ——
#   欠陥を植えたつもりで植えていない検査は、門ではなく自分を測っている。
printf '#!/bin/bash\nset -u\nUNUSED_IN_CONTROL=1\necho hi\n' > "$T/ios/tools/dirty.sh"
run_gate "$T" RC_SHELLCHECK_FLOOR=3; GRC=$?
if [ "$GRC" = "1" ] && grep -q "dirty.sh" "$GOUT"; then
    ok "G2 指摘が在れば赤(rc=1)で、その file を名指しする"
else ng "G2" "rc=$GRC / dirty.sh を名指ししていない: $(cat "$GOUT")"; fi

# ── G3 理由つきの disable は緑 ────────────────────────────────────────────
T="$(build_tree g3 3)"
{ printf '#!/bin/bash\nset -u\n'
  printf '# shellcheck disable=SC2034  # remote が literal で返す番号の名前(構造上ひとつに出来ない)\n'
  printf 'UNUSED_ON_PURPOSE=92\n'
} > "$T/ios/tools/declared.sh"
run_gate "$T" RC_SHELLCHECK_FLOOR=3; GRC=$?
[ "$GRC" = "0" ] && ok "G3 ★理由つきの disable は通る(構造上の対を残せる)" \
                 || ng "G3" "rc=$GRC / $(cat "$GOUT")"

# ── G4 ★理由の無い disable は赤 ──────────────────────────────────────────
T="$(build_tree g4 3)"
{ printf '#!/bin/bash\nset -u\n'
  printf '# shellcheck disable=SC2034\n'
  printf 'UNUSED_NO_REASON=92\n'
} > "$T/ios/tools/bare.sh"
run_gate "$T" RC_SHELLCHECK_FLOOR=3; GRC=$?
if [ "$GRC" = "1" ] && grep -q "bare.sh" "$GOUT"; then
    ok "G4 ★理由の無い disable は赤(黙らせれば通る門にしない)"
else ng "G4" "rc=$GRC / 理由の無い disable を通した: $(cat "$GOUT")"; fi

# ── G5 ★下限を割ったら測定不成立 ─────────────────────────────────────────
T="$(build_tree g5 2)"
run_gate "$T" RC_SHELLCHECK_FLOOR=99; GRC=$?
if [ "$GRC" = "2" ]; then ok "G5 ★走査が下限を割ったら緑にしない(空の網を違反 0 と読まない)"
else ng "G5" "rc=$GRC(2 が期待)= 数えられていないのに判定した: $(cat "$GOUT")"; fi

# ── G6 ★道具が居なければ測定不成立 ───────────────────────────────────────
T="$(build_tree g6 3)"
# ★`PATH` を潰すと `env` が `bash` すら見つけられず 127 になる —— 之では
#   「道具が無い時の門の判定」ではなく「私の撃ち方」を測っている(最初の版が其れだった)。
#   門の継ぎ目(`RC_SHELLCHECK_BIN`)で不在を作る。
run_gate "$T" RC_SHELLCHECK_FLOOR=3 RC_SHELLCHECK_BIN=/nonexistent/shellcheck; GRC=$?
if [ "$GRC" = "2" ]; then ok "G6 ★shellcheck が居なければ測定不成立(不在を『指摘なし』と読まない)"
else ng "G6" "rc=$GRC(2 が期待)= 道具が無いのに判定した: $(cat "$GOUT")"; fi

# ── G7 ★空の `#` を足しただけの理由は通らない ────────────────────────────
# 最初の版は「行が directive で終わっているか」で判定していたので、後ろに `#` を
# 1 つ足すだけで免除できた(2026-09-09、自分で撃って確認)。判定を「理由の中身が
# 8 文字以上在るか」へ変えた枝を、実際に回避を作って撃つ。
T="$(build_tree g7 3)"
{ printf '#!/bin/bash\nset -u\n'
  printf '# %s disable=SC2034 #\n' shellcheck
  printf 'EVADE_ME=92\n'
} > "$T/ios/tools/evade.sh"
run_gate "$T" RC_SHELLCHECK_FLOOR=3; GRC=$?
if [ "$GRC" = "1" ] && grep -q "evade.sh" "$GOUT"; then
    ok "G7 ★空の # を足しただけの理由は通らない(免除の抜け道を塞いだ)"
else ng "G7" "rc=$GRC / 空の理由で免除された: $(cat "$GOUT")"; fi

# ── G8 ★shellcheck が異常終了したら測定不成立 ────────────────────────────
# 以前は `2>/dev/null` と `|| true` の組で、道具が rc=2 で落ちても標準出力が空なら
# 「指摘 0 件」= 緑になっていた。道具が動かなかった事を、何も言わなかった事と混ぜない。
T="$(build_tree g8 3)"
printf '#!/bin/bash\necho "boom" >&2\nexit 4\n' > "$SB/broken-shellcheck"
chmod +x "$SB/broken-shellcheck"
run_gate "$T" RC_SHELLCHECK_FLOOR=3 RC_SHELLCHECK_BIN="$SB/broken-shellcheck"; GRC=$?
if [ "$GRC" = "2" ]; then ok "G8 ★道具が異常終了したら緑にしない(出力が空でも measured ではない)"
else ng "G8" "rc=$GRC(2 が期待)= 道具が落ちたのに判定した: $(cat "$GOUT")"; fi

# ── G9/G10 ★除外は理由の宣言であって免除ではない ─────────────────────────
# 除外一覧は放っておくと「都合の悪い file を入れる場所」に変わる。2 つで縛る:
#   理由が短ければ測定不成立 / 除外先が消えていたら測定不成立(腐った除外)。
# ★`sed` は使わない: 除外の行は `名前|理由` なので、`|` を区切りにした置換と衝突する
#   (2026-09-09、自分で踏んだ)。区切りを変えても理由文に何が来るか判らないので、
#   置換ではなく **行の挿入**で足す。
mk_gate_with_excl() { # mk_gate_with_excl <木> <行>
    local g="$1/rc-backend/tools/shellcheck-gate.sh" tmp
    tmp="$(mktemp)"
    while IFS= read -r line; do
        printf '%s\n' "$line"
        [ "$line" = "EXCLUDED=()" ] && continue
    done < "$g" > /dev/null   # 形の確認だけ(下で作り直す)
    awk -v row="$2" '{ if ($0 == "EXCLUDED=()") { print "EXCLUDED=("; print "  \"" row "\""; print ")" } else print }' "$g" > "$tmp"
    mv -f "$tmp" "$g"
}
T="$(build_tree g9 3)"
printf '#!/bin/bash\nset -u\nSTILL_DIRTY=1\necho hi\n' > "$T/ios/tools/skipme.sh"
mk_gate_with_excl "$T" "ios/tools/skipme.sh|短い"
run_gate "$T" RC_SHELLCHECK_FLOOR=3; GRC=$?
# ★rc=2 だけを見ない。別の理由の 2 でも緑になる —— 最初の版が実際に其れで
#   「通った」ので、**理由の文言に的の名前が出ているか**まで見る。
if [ "$GRC" = "2" ] && grep -q "理由が短すぎる" "$GOUT" && grep -q "skipme.sh" "$GOUT"; then
    ok "G9 ★除外の理由が短ければ測定不成立(免除の置き場にしない)"
else ng "G9" "rc=$GRC(2 と『理由が短すぎる』が期待)= $(cat "$GOUT")"; fi

T="$(build_tree g10 3)"
mk_gate_with_excl "$T" "ios/tools/gone-away.sh|艦隊を離れた機体の道具で、対照が 1 件も測れないので編集を迫らない"
run_gate "$T" RC_SHELLCHECK_FLOOR=3; GRC=$?
if [ "$GRC" = "2" ] && grep -q "gone-away.sh" "$GOUT"; then
    ok "G10 ★除外先が消えていたら測定不成立(腐った除外を残さない)"
else ng "G10" "rc=$GRC(2 が期待)= 実在しない除外を素通しした: $(cat "$GOUT")"; fi

# 陰性対照: 理由が足りていて file も在るなら、其の 1 本は本当に走査から外れる。
T="$(build_tree g11 3)"
printf '#!/bin/bash\nset -u\nSTILL_DIRTY=1\necho hi\n' > "$T/ios/tools/skipme.sh"
mk_gate_with_excl "$T" "ios/tools/skipme.sh|艦隊を離れた機体の道具で、対照が 1 件も測れないので編集を迫らない"
run_gate "$T" RC_SHELLCHECK_FLOOR=3; GRC=$?
[ "$GRC" = "0" ] && ok "G11 理由つきで実在する除外は本当に外れる(除外が効いている)" \
                 || ng "G11" "rc=$GRC / 除外が効いていない: $(cat "$GOUT")"

echo ""
echo "--- 合計: PASS $pass / FAIL $fail / UNMEASURED $unmeasured ---"
[ "$fail" -gt 0 ] && exit 1
[ "$unmeasured" -gt 0 ] && exit 2
exit 0
