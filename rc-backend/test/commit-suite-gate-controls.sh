#!/bin/bash
# controls-for: tools/commit-suite-gate.sh
# `tools/commit-suite-gate.sh` の対照。
#
# なぜ要るか: これは commit を**止める**側の道具なので、一番危ない壊れ方は
# 「常に 0 を返す」= 緑の顔をした未測定。普段の使用(緑の commit)では見えない。
# 落ちる側・測れない側を**わざと作って**通す。
#
# 継ぎ目は2つ。
#   `$GATE_SCRIPT` = 測る対象そのもの(旧版を差し込んで赤になるか見る為。prove-control.sh 用)
#   `$SUITE_CMD`   = 一式の代わり。本物の `npm test` は回さない ——
#                    本物を回すと「今この repo が緑か」を測ってしまい、
#                    **判定の正しさ**を測れない(入力が固定できない)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${GATE_SCRIPT:-$ROOT/tools/commit-suite-gate.sh}"

pass=0; fail=0
chk() { # chk <名前> <期待rc> <実rc> <含むべき> <含んではいけない> <出力>
  local name=$1 want=$2 got=$3 must=$4 mustnot=$5 out=$6 bad=""
  [ "$got" = "$want" ] || bad="rc=$got (期待 $want)"
  # 日本語が直後に来る展開は必ず `${...}`(この repo で既に踏んでいる)
  [ -z "$must" ]    || printf '%s' "$out" | grep -qF -- "$must"    || bad="${bad}; 「${must}」が無い"
  [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot" || bad="${bad}; 「${mustnot}」が出ている"
  if [ -n "$bad" ]; then echo "NG  $name -- $bad"; fail=$((fail+1)); else echo "OK  $name"; pass=$((pass+1)); fi
}

SB="$(/usr/bin/mktemp -d -t suitegate)" || exit 2
trap '/bin/rm -rf "$SB" 2>/dev/null' EXIT INT TERM HUP

mkfake() { # mkfake <名前> <終了コード> <本文>
  printf '#!/bin/bash\n%s\nexit %s\n' "$3" "$2" > "$SB/$1.sh"
  /bin/chmod +x "$SB/$1.sh"
}
run_gate() { SUITE_CMD="bash $SB/$1.sh" bash "$GATE" 2>&1; }

# 本物の node runner が出す形(末尾の集計)をそのまま真似る
GREEN='echo "ok 1 - 何か"; echo "1..536"; echo "# tests 536"; echo "# suites 0"; echo "# pass 536"; echo "# fail 0"'
RED='echo "not ok 287 - ★backtick で引いたファイル名が全部実在する"; echo "# tests 536"; echo "# pass 535"; echo "# fail 1"'

# ── G1 緑は通す ───────────────────────────────────────────────────────────
mkfake green 0 "$GREEN"
out=$(run_gate green); chk "G1 一式が緑 -> 通す(rc=0)" 0 $? "536/536 緑" "止めた" "$out"

# ── G2 赤は止める + ★落ちた検査を名指しする ────────────────────────────────
#    「赤い」だけ言って名前を出さない実装だと、止められた側は何を見ればいいか分からない。
mkfake red 1 "$RED"
out=$(run_gate red); chk "G2 一式が赤 -> 止める(rc=1)" 1 $? "commit を止めた" "" "$out"
chk "G3 ★落ちた検査の名前を出す" 1 1 "not ok 287" "" "$out"

# ── G4 ★★rc が 0 でも、数え上げが赤なら止める ─────────────────────────────
#    runner が形の違う失敗で 0 を返す事が在る。rc を信じる実装はここだけが落ちる。
mkfake red_rc0 0 "$RED"
out=$(run_gate red_rc0); chk "G4 ★rc=0 でも fail>0 なら止める(rc を信じない)" 1 $? "止めた" "" "$out"

# ── G5 ★★数え上げは緑でも rc が非ゼロなら緑と呼ばない ─────────────────────
#    集計を出した**後で**壊れる形(crash 等)。fail 0 の行だけを根拠にすると素通りする。
mkfake green_rc1 1 "$GREEN"
out=$(run_gate green_rc1); chk "G5 ★数え上げ緑 + rc≠0 -> 未測定(rc=2)" 2 $? "終了コードが 1" "" "$out"
chk "G6 ★その時「緑」で終わらせない" 2 2 "緑と呼ばない" "" "$out"

# ── G7 ★★集計行が無い = 未測定。**緑でも赤でもない** ───────────────────────
#    一式がそもそも起動しない形(依存が壊れた / node が無い)。ここを 0 に丸めると
#    「検査が動いていない commit」が全部素通りする —— この道具の存在意義が消える。
mkfake nosummary 1 'echo "npm ERR! Missing script: \"test\""'
out=$(run_gate nosummary); chk "G7 ★集計行が読めない -> 未測定(rc=2)" 2 $? "測れていない" "" "$out"
# ★初稿はここの「含んではいけない」を素の「緑」にしていて、正しい文面
#   (「**緑ではない**」)に当たって赤くなった。**否定形を含む語を禁止語に使わない**。
#   緑の判定でしか出ない前置き(`単体 N/N 緑`)を狙う。
chk "G8 ★未測定を緑の判定として書かない" 2 2 "" "commit-suite-gate: 単体 " "$out"

# ── G9 出力が空でも同じ(黙って通さない)──────────────────────────────────
mkfake silent 0 'true'
out=$(run_gate silent); chk "G9 出力が空 -> 未測定(rc=2)" 2 $? "測れていない" "" "$out"

# ── G10 集計行の**途中一致**で騙されない ──────────────────────────────────
#     `# failures 3` の様な別の行を `# fail` として拾うと、赤を緑と読む。
mkfake lookalike 0 'echo "# tests 10"; echo "# failures 3"; echo "# fail 0"'
out=$(run_gate lookalike); chk "G10 似た名前の行を取り違えない" 0 $? "10/10 緑" "" "$out"

# ── G11 ★検査そのものが空振りしていない事(陰性対照)────────────────────────
#     上の G1 が緑を返すのは、判定が働いているからか、それとも何も見ずに 0 を返すからか。
#     同じ道で赤が出る事(G2/G4)と合わせて初めて「見分けている」と言える。
mkfake red2 1 'echo "# tests 2"; echo "# pass 0"; echo "# fail 2"'
out=$(run_gate red2); chk "G11 陰性対照: 別の赤も赤と言う(2件)" 1 $? "2 件中 2 件が落ちた" "" "$out"

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
