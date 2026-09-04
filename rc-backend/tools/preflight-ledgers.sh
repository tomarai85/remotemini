#!/bin/bash
# preflight-ledgers.sh — 門を撃つ**前**に、台帳の穴だけを 2 分以内で洗う。
#
# なぜ在るか(2026-09-04 の実測): 直近 5 回の門付き commit のうち **4 回が最初の走行で失敗**し、
# その全部が製品の欠陥ではなく**登録漏れ**だった ——
#   commit-r2: 新しい対照が `run-controls.sh` に未登録 / 変異の的 M43・M45 が複製先にも当たる
#   commit-r3: wire の突き合わせ表に古い `serverOnly` 宣言 / 対照の錨が本文の変化で外れた
#   commit-r7: subagent が書いた書類の行番号引用 / 新しい鍵付き型が PAIRS にも UNPAIRED にも無い
# 門 1 回は 10〜20 分(Swift の対照が走る)。此処は同じ 4 種を数秒で見るので、
# 「門に教えてもらう」を「撃つ前に自分で気づく」に変える。
#
# ★此れは門の**代わりではない**。門が持つ検査の一部を先取りするだけで、通っても門は通らない事が在る。
#   逆に此処が赤い時は門も必ず赤いので、撃つ意味が無い事だけは確実に分かる。
#
# ★**`git add` の後に走らせる**。`doc-linerefs` は作業木ではなく **index** を読む
#   (`git show :0:<path>`)ので、staged にしていない編集は其の検査から見えない。
#   門が commit するのも index なので之が正しい向きだが、「書いた直後に走らせれば分かる」
#   と思い込むと、緑を見て安心したまま門で止まる(2026-09-04、対照 1 回目で実測)。
#
# 使い方: git add … の後に bash rc-backend/tools/preflight-ledgers.sh   (repo のどこからでも)
# 終了コード: 0 = 4 種とも緑 / 1 = どれかが赤(内訳は出力)
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2   # rc-backend/
ROOT="$(cd .. && pwd)"
FAIL=0
say() { printf '%-28s %s\n' "$1" "$2"; }

# 1. 書類の行番号引用(基準値は下げる方向にしか動かない)
if node --test test/doc-linerefs.test.mjs >/tmp/pf-linerefs.$$ 2>&1; then
  say "doc-linerefs" "GREEN"
else
  say "doc-linerefs" "RED  — 行番号引用が増えた。中身の目印へ張り替える"
  grep -oE "'[^']+: [0-9]+ -> [0-9]+'" /tmp/pf-linerefs.$$ | head -5 | sed 's/^/    /'
  FAIL=1
fi
rm -f /tmp/pf-linerefs.$$

# 1b. 注釈の行番号引用(`doc-linerefs` とは**別の検査**。書類ではなく**コードとscript の注釈**を見る)
#     ★2026-09-04: 之を入れていなかったせいで、preflight 緑のまま門が赤になった。
#     「行番号引用」で 1 つだと思い込んでいたが、検出器は 2 本在る。
if node --test test/no-linerefs.test.mjs >/tmp/pf-nolineref.$$ 2>&1; then
  say "no-linerefs" "GREEN"
else
  say "no-linerefs" "RED  — 注釈が行番号で他所を引いている"
  grep -oE "'[^']+: [^']+:[0-9]+'" /tmp/pf-nolineref.$$ | head -5 | sed 's/^/    /'
  FAIL=1
fi
rm -f /tmp/pf-nolineref.$$

# 2. wire の突き合わせ(新しい鍵付き型は PAIRS か UNPAIRED のどちらかに要る)
if node --test test/wire-key-agreement.test.mjs >/tmp/pf-wire.$$ 2>&1; then
  say "wire-key-agreement" "GREEN"
else
  say "wire-key-agreement" "RED  — 鍵付き型の登録漏れ、または古い serverOnly 宣言"
  grep -E '^not ok' /tmp/pf-wire.$$ | head -3 | sed 's/^/    /'
  FAIL=1
fi
rm -f /tmp/pf-wire.$$

# 3. 変異の的が今のコードに当たるか(当たらない的は誰も見張っていない)
if OUT=$(python3 test/mutation-controls.py --dry 2>&1); then
  if printf '%s' "$OUT" | grep -q '当たらない 0件'; then
    say "mutation-targets" "GREEN  $(printf '%s' "$OUT" | grep -oE '的の照合: [0-9]+件')"
  else
    say "mutation-targets" "RED  — 的が今のコードに当たらない(改名・整形で本文が動いた)"
    printf '%s' "$OUT" | grep -E '当たらない|NG' | head -4 | sed 's/^/    /'
    FAIL=1
  fi
else
  say "mutation-targets" "RED  — --dry が走らない"; FAIL=1
fi

# 4. 触った対照が全掃きの一覧に登録されているか(未登録は commit の門でしか赤くならない)
MISSING=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  base="$(basename "$c")"
  grep -q "$base" tools/run-controls.sh || MISSING="$MISSING $base"
done < <(cd "$ROOT" && git diff --cached --name-only --diff-filter=A | grep -E 'controls?\.sh$|control\.sh$' || true)
if [ -z "$MISSING" ]; then
  say "controls-registration" "GREEN"
else
  say "controls-registration" "RED  — 新しい対照が run-controls.sh に未登録:$MISSING"
  FAIL=1
fi

# 5. 生ログ・巨大 file を staged に混ぜていないか(`git add -A` の事故、2026-09-04 に 61,451 行)
BIG=$(cd "$ROOT" && git diff --cached --name-only | grep -E '\.raw\.log|\.log\.limit-hit$' || true)
if [ -z "$BIG" ]; then
  say "staged-hygiene" "GREEN"
else
  say "staged-hygiene" "RED  — 追跡対象外の生ログが staged:"
  printf '%s\n' "$BIG" | sed 's/^/    /'
  FAIL=1
fi

echo "--- preflight: $([ $FAIL = 0 ] && echo 'GREEN(門を撃ってよい)' || echo 'RED(撃つ前に直す)')"
exit $FAIL
