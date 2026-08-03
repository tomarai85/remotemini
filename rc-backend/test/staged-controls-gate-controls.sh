#!/bin/bash
# `tools/staged-controls-gate.sh` の対照。
#
# なぜ要るか: これは「対照を回し忘れる」を塞ぐ門なので、壊れ方が **一段ぶん意地悪**に
# なる —— 回し忘れを塞ぐ物が、自分を回し忘れさせる形で壊れる。
# 一番危ないのは「選び方が空振りして、いつも『触れた対照は無い』と言う」。
# 普段(対照を触らない commit)では区別が付かないので、**選ばれる事**を正面から測る。
#
# 継ぎ目:
#   $STAGED_GATE     = 測る対象そのもの(prove-control.sh が旧版を差し込む口)
#   $RC_GATE_ROOT    = 偽の repo の根(本物の repo にも git にも触らない)
#   $STAGED_LIST_CMD = staged 一覧の代わり(本物の `git diff --cached` を撃たない)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${STAGED_GATE:-$ROOT/tools/staged-controls-gate.sh}"

pass=0; fail=0
chk() { # chk <名前> <期待rc> <実rc> <含むべき> <含んではいけない> <出力>
  local name=$1 want=$2 got=$3 must=$4 mustnot=$5 out=$6 bad=""
  [ "$got" = "$want" ] || bad="rc=$got (期待 $want)"
  # 日本語が直後に来る展開は必ず `${...}`(この repo で既に踏んでいる)
  [ -z "$must" ]    || printf '%s' "$out" | grep -qF -- "$must"    || bad="${bad}; 「${must}」が無い"
  [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot" || bad="${bad}; 「${mustnot}」が出ている"
  if [ -n "$bad" ]; then echo "NG  $name -- $bad"; fail=$((fail+1)); else echo "OK  $name"; pass=$((pass+1)); fi
}

SB="$(/usr/bin/mktemp -d -t stagedgate)" || exit 2
trap '/bin/rm -rf "$SB" 2>/dev/null' EXIT INT TERM HUP

# ── 偽の repo。本物と同じ木の形(rc-backend/{src,test,tools})にする ──────────
R="$SB/repo"
/bin/mkdir -p "$R/rc-backend/test" "$R/rc-backend/tools" "$R/rc-backend/src"
mkctl() { # mkctl <相対パス> <終了コード> <最後の1行>
  printf '#!/bin/bash\necho "%s"\nexit %s\n' "$3" "$2" > "$R/$1"; /bin/chmod +x "$R/$1"
}
mkctl rc-backend/test/aa-controls.sh 0 "--- 合計: PASS 5 / FAIL 0 ---"
mkctl rc-backend/test/bb-controls.sh 1 "NG  B2 何かが倒れた"
mkctl rc-backend/test/cc-controls.sh 2 "CC: 未測定(走行中)= **緑ではない**"
mkctl rc-backend/test/dd-controls.sh 0 "--- 合計: PASS 2 / FAIL 0 ---"
: > "$R/rc-backend/tools/dd.sh"          # dd.sh は対照を導ける
: > "$R/rc-backend/tools/lonely.sh"      # lonely.sh は導けない
: > "$R/rc-backend/src/server.mjs"
: > "$R/rc-backend/test/plain.test.mjs"  # `npm test` 側の物。ここでは選ばない

run_gate() { # run_gate <staged の中身(改行区切り)>
  RC_GATE_ROOT="$R" STAGED_LIST_CMD="printf '%s\n' '$1'" bash "$GATE" 2>&1
}

# ── S1 対照に触れていない commit は素通り ──────────────────────────────────
out=$(run_gate 'rc-backend/src/server.mjs')
chk "S1 対照に触れていなければ rc=0" 0 $? "触れた対照は無い" "★" "$out"

# ── S2 触れた対照が緑なら通す ──────────────────────────────────────────────
out=$(run_gate 'rc-backend/test/aa-controls.sh')
chk "S2 触れた対照が緑 -> rc=0" 0 $? "全部緑(1/1)" "★" "$out"

# ── S3 触れた対照が赤なら止める + 名指しする ───────────────────────────────
out=$(run_gate 'rc-backend/test/bb-controls.sh')
chk "S3 触れた対照が赤 -> rc=1" 1 $? "commit を止めた" "" "$out"
chk "S4 ★倒れた対照の名前を出す" 1 1 "bb-controls.sh" "" "$out"

# ── S5 ★測れない対照を緑に丸めない ────────────────────────────────────────
out=$(run_gate 'rc-backend/test/cc-controls.sh')
# ★禁止語に素の「緑」を使うと、正しい文面「**緑ではない**」に当たって偽の赤になる。
#   同じ罠を今夜 `commit-suite-gate-controls.sh` G8 で既に踏んでいる ——
#   **否定形を含む語を禁止語に使わない**。緑の判定でしか出ない前置きを狙う。
chk "S5 ★対照が未測定 -> rc=2(緑でも赤でもない)" 2 $? "測れなかった対照" "対照は全部緑" "$out"

# ── S6 ★★道具だけ触った commit でも、その対照を回す ──────────────────────
#     ここが本題。2026-08-03 に踏んだのはこの形 —— `tools/mutation-verdict.sh` を
#     直す時に対照 file には触らないので、「staged な対照」だけ見る実装は素通りする。
out=$(run_gate 'rc-backend/tools/dd.sh')
chk "S6 ★道具だけ staged でも対照を導いて回す" 0 $? "dd-controls.sh" "触れた対照は無い" "$out"

# ── S7 対照を導けない道具は**名前を出す**が、止めない ─────────────────────
out=$(run_gate 'rc-backend/tools/lonely.sh')
chk "S7 対照の無い道具 -> 名前を出すが rc=0" 0 $? "対照を導けない道具" "" "$out"
chk "S8 ★その名前が実際に出ている" 0 0 "lonely" "" "$out"

# ── S9 両方の道で同じ対照に届く時、二度回さない ────────────────────────────
out=$(run_gate 'rc-backend/tools/dd.sh
rc-backend/test/dd-controls.sh')
chk "S9 重複は 1 回に畳む" 0 $? "触れた対照 1 本" "" "$out"

# ── S10 ★★staged の一覧が空 = 未測定。**素通りさせない** ──────────────────
#      「何も触っていない」と「何を触ったか判らない」は別。前者は hook 側が先に
#      弾く(範囲の絞り込み)ので、ここに空が来る = 一覧を取る道が壊れている。
out=$(run_gate '')
chk "S10 ★staged 一覧が空 -> 未測定(rc=2)" 2 $? "測れていない" "触れた対照は無い" "$out"

# ── S11 ★repo の根が無い時も未測定 ────────────────────────────────────────
out=$(RC_GATE_ROOT="$SB/no-such-repo" STAGED_LIST_CMD="echo x" bash "$GATE" 2>&1)
chk "S11 ★根が判らない -> 未測定(rc=2)" 2 $? "測れていない" "" "$out"

# ── S12 削除された対照は回さない(存在確認をしている事)────────────────────
out=$(run_gate 'rc-backend/test/deleted-controls.sh')
chk "S12 削除された対照は回さない" 0 $? "触れた対照は無い" "" "$out"

# ── S13 `npm test` 側の file は選ばない(役割が違う。二重に回さない)────────
out=$(run_gate 'rc-backend/test/plain.test.mjs')
chk "S13 *.test.mjs は選ばない" 0 $? "触れた対照は無い" "" "$out"

# ── S14 ★赤と未測定が同時に在る時は**赤**が勝つ ───────────────────────────
out=$(run_gate 'rc-backend/test/bb-controls.sh
rc-backend/test/cc-controls.sh')
chk "S14 ★赤 + 未測定 -> 赤(1)。未測定に丸めない" 1 $? "commit を止めた" "" "$out"

# ── S15 陰性対照: 選び方が空振りしていない事 ───────────────────────────────
#     S1/S12/S13 が 0 を返すのは、正しく選ばなかったからか、**何も選べない**からか。
#     同じ道で 2 本が選ばれる事を見せて初めて「見分けている」と言える。
out=$(run_gate 'rc-backend/test/aa-controls.sh
rc-backend/test/dd-controls.sh')
chk "S15 陰性対照: 2 本 staged なら 2 本回る" 0 $? "触れた対照 2 本" "" "$out"

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
