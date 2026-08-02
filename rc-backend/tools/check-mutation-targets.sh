#!/bin/bash
# 変異の**的**が今のコードに当たるかを commit の直前に確かめる。
#
# なぜ要るか(2026-08-02、実際に踏んだ):
#   `server.mjs` の `readHead` を `readBranchHead` へ**改名しただけ**で、変異 W9 の的が外れた。
#   的は本文を文字列で探すので、改名・整形・行の入れ替えは**検査の的を静かに無効化する**。
#   外れた的は走行すると「対象行が無い」で赤になるが、それが分かるのは **30〜85 分後**。
#   commit の時点では `npm test` も e2e も全部緑なので、**人の目で気付ける材料が1つも無い**。
#   `--dry` は 34ms で答えるのに、それを**呼ぶ物が無かった**のが唯一の穴だった。
#
# 対照(この検査が赤にもなる事の確認): `test/mutation-target-controls.sh`
# 本体はここ(追跡される)。`.git/hooks/pre-commit` は clone に付いてこない薄い呼び口。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ★★ここに「走行中は commit を止める」を置いていたが、**前提が事実と違った**ので外した
#   (2026-08-02 17:1x)。書いていた理由は「走行中は `src/` が意図的に壊れているので
#   `--dry` が嘘の赤を出す / commit すると変異が混ざった木を記録する」だった。
#   **どちらも起きない。** 変異台本は本物の木を書き換えない:
#     test/mutation-controls.py:716-719  d = tempfile.mkdtemp(prefix="mut-")
#                                        shutil.copytree(SRC, dst, ...)
#     同 706-707                          subprocess.run([...], cwd=dst)
#   実測(走行 38/119 の最中):
#     - `--dry` → 「的の照合: 112件 / 当たらない 0件」= 正確。嘘の赤は出ない
#     - 走行中の node の cwd = /private/var/folders/.../T/mut-yt53i0bl/rc(lsof) = 複製の中
#     - `git diff --stat -- src/` に出るのは自分の H2 差分だけで、変異の痕跡は無い
#   つまりこの門は**何も守っていないのに 85 分間 commit を塞いでいた**。
#   実害も出た: この日の H2 の仕事が、その窓の間ずっと記録できなかった。
#   ★教訓: 門を作る時、止める理由を**測ってから**書く。「壊れている最中だから」は
#   もっともらしいが、壊れているのは複製の方だった(method_measure_where_the_system_actually_reads)。
#
#   本当に守るべき事は別に在る = **走行中に `src/` を編集しない**事。
#   台本は変異ごとに木を copytree し直すので、途中で書き換えると
#   前半と後半で**違う木を測る**事になり、走行の結果が混ざる。
#   ただしそれは「編集」の禁止であって「commit」の禁止ではない(commit は木を変えない)。
#   なので止めずに、混ざり得る時だけ**注意書きを出す**。
if bash "$ROOT/tools/mutation-run-live.sh"; then
    echo "注意: 変異の走行が動いている。走行が始まってから src/ を編集していた場合、" >&2
    echo "  その走行の結果は**今の木を説明しない**(台本は変異ごとに木を写し直す為)。" >&2
    echo "  commit 自体は木を変えないので止めない。検査は続行する。" >&2
fi

out="$(cd "$ROOT" && python3 test/mutation-controls.py --dry 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "$out" >&2
    echo "" >&2
    echo "★commit しない: 上の変異が**今のコードに当たらない**。" >&2
    echo "  当たらない的は走っても意味が無い = その欠陥はもう誰も見張っていない。" >&2
    echo "  直し方: 改名・整形で本文が変わった側に合わせて test/mutation-controls.py の" >&2
    echo "  探し文を付け替える(消すのは、その欠陥を見張らないと決めた時だけ)。" >&2
    exit 1
fi
echo "$out" | tail -1
exit 0
