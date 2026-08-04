#!/bin/bash
# controls-for: tools/warn-ledger.sh
# `tools/warn-ledger.sh` の対照。
#
# なぜ要るか: この帳面は「門ではない検査の信号を捨てない」為に在るので、
# **一番危ない壊れ方は「静かに緑を返す」**——
#   - 1 段も記録していないのに「異常なし」と出す
#   - ssh が繋がらなかった(255)のを赤に丸めて「edith が壊れている」と読ませる
#   - 未測定(2)を緑に丸める
# どれも普段(全部緑の配備)の出力では区別が付かない。だから**丸め方**を正面から測る。
#
# 型 = 自力型。帳面は source して使う純粋な関数なので、継ぎ目は要らない ——
#   `$WARN_LEDGER` で差し込めば旧版も測れる様にしてある(prove-control.sh 用)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDGER="${WARN_LEDGER:-$ROOT/tools/warn-ledger.sh}"

pass=0; fail=0
chk() { # chk <名前> <期待rc> <実rc> <含むべき> <含んではいけない> <出力>
  local name=$1 want=$2 got=$3 must=$4 mustnot=$5 out=$6 bad=""
  [ "$got" = "$want" ] || bad="rc=$got (期待 $want)"
  # 日本語が直後に来る展開は必ず `${...}`(この repo で既に2度踏んでいる)
  [ -z "$must" ]    || printf '%s' "$out" | grep -qF -- "$must"    || bad="${bad}; 「${must}」が無い"
  [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot" || bad="${bad}; 「${mustnot}」が出ている"
  if [ -n "$bad" ]; then echo "NG  $name -- $bad"; fail=$((fail+1)); else echo "OK  $name"; pass=$((pass+1)); fi
}

# 帳面は状態を持つので、1件ずつ**別の bash** で回す(前の段の残りが次に混ざらない)。
run() { # run <本文>
  LEDGER="$LEDGER" /bin/bash -c '
    . "$LEDGER"
    '"$1"'
    wl_report; echo "REPORT_RC=$?"
  ' 2>&1
}
rc_of() { printf '%s' "$1" | /usr/bin/sed -n 's/^REPORT_RC=//p' | /usr/bin/tail -1; }

# ── W1 全部緑 ──────────────────────────────────────────────────────────────
out=$(run 'wl_init; wl_run "A" /bin/bash -c "exit 0"; wl_run "B" /bin/bash -c "exit 0"')
chk "W1 全部緑 -> 0" 0 "$(rc_of "$out")" "異常なし(2/2)" "★" "$out"

# ── W2 赤が1件 ────────────────────────────────────────────────────────────
out=$(run 'wl_init; wl_run "A" /bin/bash -c "exit 0"; wl_run "停電から戻れるか" /bin/bash -c "exit 1"')
chk "W2 赤が在れば 1" 1 "$(rc_of "$out")" "★赤が 1 件" "異常なし" "$out"
chk "W3 ★赤の段を名指しする" 1 1 "停電から戻れるか" "" "$out"

# ── W4 未測定(2)を緑に丸めない ───────────────────────────────────────────
out=$(run 'wl_init; wl_run "A" /bin/bash -c "exit 0"; wl_run "鍵の期限" /bin/bash -c "exit 2"')
# ★禁止語に素の「緑」を使わない —— 正しい文面「緑ではない」に当たって偽の赤になる。
#   同じ罠を 2026-08-03 に G8 と S5 で**2回**踏んでいる。緑の判定でしか出ない綴りを狙う。
chk "W4 ★未測定は 2。緑に丸めない" 2 "$(rc_of "$out")" "測れなかったのが 1 件" "異常なし" "$out"
chk "W5 ★未測定の理由を文で言う" 2 2 "壊れているか判らない" "" "$out"

# ── W6 ★ssh が繋がらない(255)を赤に落とさない ───────────────────────────
#   ここがこの帳面の要点。255 を赤に混ぜると「edith が答えない」が
#   「edith の停電対策が壊れている」として log に残り、居ない相手を直しに行く事になる。
out=$(run 'wl_init; wl_run "停電から戻れるか" /bin/bash -c "exit 255"')
chk "W6 ★255 は未測定(2)であって赤ではない" 2 "$(rc_of "$out")" "届かず" "★赤が" "$out"
chk "W7 ★255 は ssh と分かる形で出す" 2 2 "(ssh)" "" "$out"

# ── W8 ★赤と未測定が同時 -> 赤が勝つ ─────────────────────────────────────
out=$(run 'wl_init; wl_run "A" /bin/bash -c "exit 1"; wl_run "B" /bin/bash -c "exit 2"')
chk "W8 ★赤 + 未測定 -> 赤(1)" 1 "$(rc_of "$out")" "★赤が 1 件" "" "$out"
chk "W9 ★未測定も同時に出す(赤で塗り潰さない)" 1 1 "測れなかったのが 1 件" "" "$out"

# ── W10 ★★1 段も記録していないのに緑にしない ────────────────────────────
out=$(run 'wl_init')
chk "W10 ★★記録 0 段 -> 未測定(2)" 2 "$(rc_of "$out")" "1 段も記録されていない" "異常なし" "$out"

# ── W11 ★★wl_init 自体を呼び忘れた時も緑にしない ────────────────────────
#      「警告が 0 件だった」と「帳面が一度も始まっていない」は別。
out=$(run ':')
chk "W11 ★★init 忘れ -> 未測定(2)" 2 "$(rc_of "$out")" "帳面が始まっていない" "異常なし" "$out"

# ── W12 wl_run は**常に 0 を返す**(門ではない = 呼び側の set -e を殺さない)───
out=$(LEDGER="$LEDGER" /bin/bash -c '
  set -e
  . "$LEDGER"
  wl_init
  wl_run "落ちる段" /bin/bash -c "exit 3"
  echo "台本は生きている"
  wl_report >/dev/null || true
' 2>&1)
chk "W12 ★wl_run は set -e の下でも台本を殺さない" 0 $? "台本は生きている" "" "$out"

# ── W13 命令の出力はそのまま流れる(握り潰さない)─────────────────────────
out=$(run 'wl_init; wl_run "A" /bin/bash -c "echo 段の中身; exit 0"')
chk "W13 段の出力を握り潰さない" 0 "$(rc_of "$out")" "段の中身" "" "$out"

# ── W14 wl_add(既に走らせた rc を後から足す口)───────────────────────────
out=$(run 'wl_init; wl_add "外で走らせた段" 1')
chk "W14 wl_add でも赤として数える" 1 "$(rc_of "$out")" "外で走らせた段" "" "$out"

# ── W15 陰性対照: 分類が**空振り**していない事 ─────────────────────────────
#     W1/W10/W11 が緑や 2 を返すのは、正しく分類したからか、**何も数えていない**からか。
#     4 種類が同じ表に同時に並ぶ事を見せて初めて「見分けている」と言える。
out=$(run 'wl_init
  wl_run "緑の段" /bin/bash -c "exit 0"
  wl_run "赤の段" /bin/bash -c "exit 1"
  wl_run "未測定の段" /bin/bash -c "exit 2"
  wl_run "届かない段" /bin/bash -c "exit 255"')
chk "W15 陰性対照: 4 種が同じ表に並ぶ" 1 "$(rc_of "$out")" "緑     " "" "$out"
chk "W16 陰性対照: 赤と未測定を両方数える" 1 1 "測れなかったのが 2 件" "" "$out"

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
