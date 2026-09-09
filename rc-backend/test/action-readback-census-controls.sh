#!/bin/bash
# controls-for: tools/action-readback-census.sh
#
# 行為の読み戻しの台帳が、**台帳として壊れていないか**の負の対照。
#
# ★此の台帳の価値は「今 no-readback が 0 件」ではなく、**新しく足された変更する台本が
#   判定を書くまで通らない**事に在る。だから測る中心は其処:
#   判定の無い候補を素通しするなら、台帳は「作った日の写真」に過ぎない。
#
# 測る事(全部 砂場の作り木。本物の tools/ は 1 バイトも触らない):
#   A1 全候補に判定が在れば緑で、TSV を書く
#   A2 ★判定の無い候補が 1 本 在れば赤(rc=1)で、その名前を出す
#   A3 ★no-readback の理由が 20 文字未満なら赤(理由の無い免除を作らない)
#   A4 ★候補が下限を割ったら緑にせず測定不成立(空の網を『違反 0』と読まない)
#   A5 ★註の中だけに変更の語が在る台本は候補に**挙げない**
#      (挙げると判定の要求が語の言及へ広がり、台帳が本物の変更を見失う)
#   A6 ★TSV は判定を**そのまま**運ぶ(緑の時に空の台帳を書いていない)
#   A7 ★継ぎ目ごしの呼び出し(tool=defaults; "$tool" write)も候補になる(+ 陰性対照 A7b)
#
# 使い方: bash rc-backend/test/action-readback-census-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤 / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENSUS="$HERE/../tools/action-readback-census.sh"
[ -f "$CENSUS" ] || { echo "測る対象が無い: $CENSUS"; exit 2; }

pass=0; fail=0; unmeasured=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail+1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
GOUT="$SB/out.txt"

# 台帳は自分の位置から `../../rc-backend/tools` と `../../ios/tools` を引く。其の形を組む。
# $1=木の名前 / 以降=判定表へ足す行
build_tree() {
    local t="$SB/$1"; shift
    mkdir -p "$t/rc-backend/tools" "$t/ios/tools"
    cp "$CENSUS" "$t/rc-backend/tools/action-readback-census.sh"
    # ★判定表は script の外の .tsv(2026-09-09 に出した。理由は其の file の頭)。
    #   作り木では**其の file を組む** —— 台帳は自分自身も候補に挙げるので、
    #   自分の行を必ず入れる。忘れると全ケースが「判定の無い候補」で倒れ、
    #   測りたい枝へ一度も届かない(2026-09-09 に踏んだ)。
    # ★下限 20 行を満たす為に、当たらない詰め物の行を入れる(候補に居ない path)。
    {
      printf '# 作り木の判定表\n'
      printf 'rc-backend/tools/action-readback-census.sh\treadback\t書いた TSV を読み直して内訳を印字する(作り木)\n'
      local r
      for r in "$@"; do printf '%s\n' "$(printf '%s' "$r" | tr '|' '\t')"; done
      local i=0
      while [ "$i" -lt 25 ]; do
          printf 'ios/tools/filler-%s.sh\tnot-mutating\t候補に居ない詰め物。下限を満たす為だけの行\n' "$i"
          i=$((i+1))
      done
    } > "$t/rc-backend/tools/action-readback-verdicts.tsv"
}
mk_mut() { # mk_mut <木> <相対 path>  … 註の外に変更の行を持つ台本
    printf '#!/bin/bash\nset -u\nrsync -a /tmp/a/ /tmp/b/\n' > "$1/$2"
}
mk_prose() { # mk_prose <木> <相対 path> … 変更の語が註の中だけ
    printf '#!/bin/bash\nset -u\n# 註: 昔は rsync -a で配っていた\necho ok\n' > "$1/$2"
}
run_census() { # run_census <木> [env…] -> rc。出力は $GOUT
    local t="$1"; shift
    env "$@" RC_CENSUS_OUT="$t/out.tsv" RC_CENSUS_FLOOR=1 \
        bash "$t/rc-backend/tools/action-readback-census.sh" > "$GOUT" 2>&1
}

# ── A1 全候補に判定が在れば緑 ─────────────────────────────────────────────
T="$SB/a1"; build_tree a1 "ios/tools/mut-a.sh|readback|配った後に状態を読み直して確かめる(作り木)"
mk_mut "$T" ios/tools/mut-a.sh
run_census "$T"; rc=$?
if [ "$rc" = "0" ] && [ -s "$T/out.tsv" ]; then
    ok "A1 全候補に判定が在れば緑で、TSV を書く"
else ng "A1" "rc=$rc / $(cat "$GOUT")"; fi

# ── A6 TSV が判定をそのまま運ぶ ───────────────────────────────────────────
if grep -qF "ios/tools/mut-a.sh	readback" "$T/out.tsv" 2>/dev/null; then
    ok "A6 ★TSV が判定をそのまま運ぶ(緑の時に空の台帳を書いていない)"
else ng "A6" "TSV の中身: $(cat "$T/out.tsv" 2>/dev/null | tr '\n' '|')"; fi

# ── A2 ★判定の無い候補が在れば赤で名指し ─────────────────────────────────
T="$SB/a2"; build_tree a2 "ios/tools/mut-a.sh|readback|作り木の判定"
mk_mut "$T" ios/tools/mut-a.sh
mk_mut "$T" ios/tools/mut-new.sh          # 判定を書いていない新入り
run_census "$T"; rc=$?
if [ "$rc" = "1" ] && grep -q "mut-new.sh" "$GOUT"; then
    ok "A2 ★判定の無い候補が在れば赤(rc=1)で、その名前を出す"
else ng "A2" "rc=$rc / 新入りを名指ししていない: $(cat "$GOUT")"; fi

# ── A3 ★no-readback の理由が短ければ赤 ───────────────────────────────────
T="$SB/a3"; build_tree a3 "ios/tools/mut-a.sh|no-readback|短い"
mk_mut "$T" ios/tools/mut-a.sh
run_census "$T"; rc=$?
if [ "$rc" = "1" ] && grep -q "理由が短すぎる" "$GOUT"; then
    ok "A3 ★no-readback の理由が 20 文字未満なら赤(免除を作らない)"
else ng "A3" "rc=$rc(1 と『理由が短すぎる』が期待)= $(cat "$GOUT")"; fi
# 陰性対照: 同じ判定でも理由が足りていれば通る(A3 が厳しすぎない事)
T="$SB/a3b"; build_tree a3b "ios/tools/mut-a.sh|no-readback|配った後の状態を読み直す手が今は無い。遠隔の口が開いたら足す事"
mk_mut "$T" ios/tools/mut-a.sh
run_census "$T"; rc=$?
[ "$rc" = "0" ] && ok "A3b 理由が足りていれば no-readback でも通る(判定を書けば進める)" \
                || ng "A3b" "rc=$rc / $(cat "$GOUT")"

# ── A4 ★下限を割ったら測定不成立 ─────────────────────────────────────────
T="$SB/a4"; build_tree a4 "ios/tools/mut-a.sh|readback|作り木の判定"
mk_mut "$T" ios/tools/mut-a.sh
env RC_CENSUS_OUT="$T/out.tsv" RC_CENSUS_FLOOR=99 \
    bash "$T/rc-backend/tools/action-readback-census.sh" > "$GOUT" 2>&1; rc=$?
if [ "$rc" = "2" ]; then ok "A4 ★候補が下限を割ったら緑にしない(空の網を違反 0 と読まない)"
else ng "A4" "rc=$rc(2 が期待)= 数えられていないのに判定した: $(cat "$GOUT")"; fi

# ── A5 ★註の中だけの言及は候補にしない ───────────────────────────────────
T="$SB/a5"; build_tree a5 "ios/tools/mut-a.sh|readback|作り木の判定"
mk_mut "$T" ios/tools/mut-a.sh
mk_prose "$T" ios/tools/prose.sh          # 変更の語は註の中だけ
run_census "$T"; rc=$?
if [ "$rc" = "0" ] && ! grep -q "prose.sh" "$T/out.tsv" 2>/dev/null; then
    ok "A5 ★註の中だけの言及は候補に挙げない(判定の要求が語の言及へ広がらない)"
else ng "A5" "rc=$rc / prose.sh を候補に挙げた: $(cat "$GOUT")"; fi

# ── A7 ★継ぎ目ごしの呼び出しも候補になる(Codex 2026-09-09)──────────────────
# 字面だけを見る検出は `tool=defaults; "$tool" write …` をすり抜ける。
# 此の repo は其の書き方を実際に使う(`SSH_BIN="${RC_DELIVERY_SSH:-ssh}"` 等)ので、
# 理論上の穴ではない。判定を書いていない其の形が**赤になる**事を撃つ。
T="$SB/a7"; build_tree a7 "ios/tools/mut-a.sh|readback|作り木の判定"
mk_mut "$T" ios/tools/mut-a.sh
printf '#!/bin/bash\nset -u\nRS="${MY_RSYNC:-rsync}"\n"$RS" -a /tmp/a/ /tmp/b/\n' > "$T/ios/tools/indirect.sh"
run_census "$T"; rc=$?
if [ "$rc" = "1" ] && grep -q "indirect.sh" "$GOUT"; then
    ok "A7 ★継ぎ目の既定値で変更の道具を名指しする形も候補になる(字面をすり抜けない)"
else ng "A7" "rc=$rc / 継ぎ目ごしの呼び出しを見逃した: $(cat "$GOUT")"; fi
# 陰性対照: `ssh` の継ぎ目は候補にしない(読み取りにも使う道具なので、入れると
# 判定の要求が『外へ出る台本』全部へ広がって薄まる)。
T="$SB/a7b"; build_tree a7b "ios/tools/mut-a.sh|readback|作り木の判定"
mk_mut "$T" ios/tools/mut-a.sh
printf '#!/bin/bash\nset -u\nSSH_BIN="${MY_SSH:-ssh}"\n"$SSH_BIN" host true\n' > "$T/ios/tools/readonly-ssh.sh"
run_census "$T"; rc=$?
if [ "$rc" = "0" ] && ! grep -q "readonly-ssh.sh" "$T/out.tsv" 2>/dev/null; then
    ok "A7b ssh の継ぎ目は候補にしない(曖昧な道具で網を広げない)"
else ng "A7b" "rc=$rc / ssh の継ぎ目まで候補にした: $(cat "$GOUT")"; fi

echo ""
echo "--- 合計: PASS $pass / FAIL $fail / UNMEASURED $unmeasured ---"
[ "$fail" -gt 0 ] && exit 1
[ "$unmeasured" -gt 0 ] && exit 2
exit 0
