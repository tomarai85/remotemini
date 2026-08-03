#!/bin/bash
# commit の直前に**単体の一式が緑か**を確かめる。
#
# なぜ要るか(2026-08-03 に自分で踏んだ): `test/` と `tools/` を触る commit 25f8e09 を
# 出した時、**新しく足した対照2本は手で回したが `npm test` を回さなかった**。
# その commit は `test/no-linerefs.test.mjs` の引用検査を1本赤にしたまま入った
# (砂場が走行時に作る `$d/tools/guard.sh` を、実在する file の様に backtick で引いた)。
# 見つかったのは commit の 1 時間後、別件で一式を回した時。
#
# 「commit は緑で出す」は前から書いてあった規則で、破ったのは怠慢ではなく
# **回す物が無かった**から(DESIGN (19) と同じ形)。6 秒の検査に人の記憶を使わせない。
#
# 範囲: pre-commit hook 側で `rc-backend/(src|test|tools)/` に絞ってから呼ぶ。
#   書類だけの commit を止めない理由は hook 本体の注釈と同じ。
#
# 終了コード: 0=緑 / 1=赤(落ちた検査が在る) / 2=**測れなかった**。
#   2 を 0 に丸めない —— hook は非ゼロで止まるので、測れない時は止まる側に倒れる。
#   「一式が走らなかった」を「異常なし」と読み替えるのが、この道具で一番危ない壊れ方。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "commit-suite-gate: rc-backend へ入れない"; exit 2; }

# 継ぎ目。対照は本物の `npm test` を回さずに、出力と終了コードだけを差し替えて判定を測る。
SUITE_CMD="${SUITE_CMD:-npm test}"

OUT="$(/usr/bin/mktemp -t commitsuite)" || exit 2
trap '/bin/rm -f "$OUT" 2>/dev/null' EXIT INT TERM HUP

eval "$SUITE_CMD" > "$OUT" 2>&1
suite_rc=$?

tests_line="$(/usr/bin/grep -E '^# tests [0-9]+$' "$OUT" | /usr/bin/tail -1)"
fail_line="$(/usr/bin/grep -E '^# fail [0-9]+$'  "$OUT" | /usr/bin/tail -1)"

# ① 集計行が無い = 一式がそもそも走っていない。**緑でも赤でもなく未測定**。
if [ -z "$tests_line" ] || [ -z "$fail_line" ]; then
    echo "commit-suite-gate: ★一式の集計行を読めない = **測れていない**(緑ではない)"
    echo "  期待する形: '# tests N' と '# fail N' の 2 行"
    echo "  出た物の末尾:"
    /usr/bin/tail -8 "$OUT" | /usr/bin/sed 's/^/    /'
    echo "  通すなら理由を確かめてから --no-verify。黙って通さない事。"
    exit 2
fi

n_tests="${tests_line##* }"
n_fail="${fail_line##* }"

# ② 数えた結果が先。**終了コードより数え上げを信じる** —— runner は形の違う失敗で
#    0 を返す事が在るので、rc だけを見ると「落ちたのに緑」を作れる。
if [ "$n_fail" != "0" ]; then
    echo "commit-suite-gate: ★単体が赤い($n_tests 件中 $n_fail 件が落ちた)。commit を止めた"
    /usr/bin/grep -E '^not ok ' "$OUT" | /usr/bin/head -10 | /usr/bin/sed 's/^/    /'
    exit 1
fi

# ③ 数え上げは緑なのに rc が非ゼロ = 集計の**後で**壊れている(crash 等)。
#    「fail 0 と書いてあった」だけを根拠に通すと、この形が丸ごと素通りする。
if [ "$suite_rc" != "0" ]; then
    echo "commit-suite-gate: ★数え上げは $n_tests/$n_tests 緑だが、一式の終了コードが $suite_rc"
    echo "  = 集計の後で壊れている可能性。緑と呼ばない(未測定として止める)"
    /usr/bin/tail -6 "$OUT" | /usr/bin/sed 's/^/    /'
    exit 2
fi

echo "commit-suite-gate: 単体 $n_tests/$n_tests 緑"
exit 0
