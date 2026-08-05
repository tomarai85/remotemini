#!/bin/bash
# 書類(`.md`)の行番号引用を**増やす commit を止める**門。
# 本体の検査 = rc-backend/test/doc-linerefs.test.mjs(基準値 = test/fixtures/doc-linerefs-baseline.json)
#
# ── なぜ独立した門なのか(2026-08-05)──────────────────────────────────────
# ラチェット自体は単体スイートに入れた。だがこの repo の commit 門は
# 「code を触ったか」で絞り込んでおり、`.md` は素通しする —— それは
# **正しい**(走行中の 85 分に書類まで止めると、使えない門として外される)。
# 結果、`.md` だけの commit では単体が1度も回らず、**その検査が在る理由そのものの
# 場面でラチェットが走らない**。実測 2026-08-05: 追跡 .md 36 本を絞り込みに
# 当てて **36/36 が門ゼロ**。
#
# ★これは今日3件目の、そして同じ形の**5件目**である:
#   「下流に能力を足しても、上流の絞り込みがそれを知らなければ守りは伸びない」。
#   前の4件は他人が作った穴を私が見つけたが、これは**私が数時間前に、その形を
#   名指しした注釈を書いた直後に自分で作った**。
#
# ── なぜ `pre-commit-gates.sh` に直接書かないのか ────────────────────────
# 最初は直接 `node --test` を書いた。対照 `pre-commit-gates-controls.sh` が
# 4 本赤くなって分かった: 他の門は全部 `bash "$ROOT/rc-backend/tools/<名>.sh"`
# という**同じ形**で呼ばれていて、その形が (1) 対照の門一覧の自動導出、
# (2) 偽 repo でのスタブ差し替え、(3) 人が読んで門だと分かる事、の3つを同時に
# 成立させている。直書きはその3つ全部を壊した。門は門の形で足す。
#
# 終了コード: 0=緑(または対象なし) / 1=赤 / 2=測れていない
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

staged="$(git -C "$ROOT" diff --cached --name-only)"

# `.md` が1件も入らない commit には用が無い。**黙って通す**(門は自分の対象だけを見る)。
if ! printf '%s\n' "$staged" | grep -qE '\.md$'; then
    exit 0
fi

if [ ! -f "$ROOT/rc-backend/test/doc-linerefs.test.mjs" ]; then
    echo "doc-linerefs: 検査の本体が無い = 測れていない"
    exit 2
fi

out="$(cd "$ROOT/rc-backend" && node --test test/doc-linerefs.test.mjs 2>&1)"; rc=$?

if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | grep -E "^not ok|^ *\+ " | head -20
    echo "doc-linerefs: ★書類の行番号引用が増えている(または基準値が古い)。commit を止めた"
    echo '  直し = 行番号でなく中身の目印(関数名・特徴のある文字列)で引く'
    echo '  実測 2026-08-05: 人が読んだ 33 件のうち 13 件が既に別の場所を指していた'
    exit 1
fi

# 「測っていない」を緑と読み替えない。木の写し(変異台本)では skip が正しいが、
# 本物の repo で skip が出たら**走っていない**という事なので止める。
if ! printf '%s\n' "$out" | grep -q '^# skipped 0$'; then
    printf '%s\n' "$out" | grep -E "^# skipped|SKIP" | head -5
    echo "doc-linerefs: ★測れていない(skip が出た)。緑ではないので commit を止めた"
    exit 2
fi

echo "doc-linerefs: 書類の行番号引用 緑(増えていない)"
exit 0
