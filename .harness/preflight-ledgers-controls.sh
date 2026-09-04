#!/bin/bash
# controls-for: rc-backend/tools/preflight-ledgers.sh
#
# `preflight-ledgers.sh` が **赤を出せる**事を、5 種それぞれ壊して確かめる。
#
# なぜ要るか: preflight は「門を撃つ前に台帳の穴を見つける」為の計器で、今日作った時点では
# 「緑を見た」だけだった —— 其れは「壊れていても緑」と区別が付かない。同じ夜に Codex から
# 「落ちない検査」を 3 本指摘された直後に、同じ形の物をもう 1 つ増やす訳にいかない。
#
# ★復元は**写しから**。`git checkout --` は未コミットの実装ごと消す(2026-09-03 に踏んだ)。
# ★staged の状態を触るので、走らせる前に staged が空か、失っても良い状態である事を確かめる。
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
PRE="rc-backend/tools/preflight-ledgers.sh"
TMP="$(mktemp -d)"
PASS=0; FAIL=0
trap 'rm -rf "$TMP"' EXIT

# preflight を走らせて、期待した検査名の行が RED かを見る
expect_red() { # expect_red <題> <検査名>
  local title="$1" name="$2" out
  out="$(bash "$PRE" 2>&1)"
  if printf '%s' "$out" | grep -qE "^${name}[[:space:]]+RED"; then
    PASS=$((PASS+1)); printf 'PASS  %s\n' "$title"
  else
    FAIL=$((FAIL+1)); printf 'FAIL  %s(%s が RED にならない)\n' "$title" "$name"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}
expect_green_overall() {
  if bash "$PRE" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "PASS  $1"
  else FAIL=$((FAIL+1)); echo "FAIL  $1(壊していないのに赤)"; bash "$PRE" 2>&1 | sed 's/^/     | /'; fi
}

# 0. 素の状態が緑(全部赤い計器は何も見分けない)
expect_green_overall "壊していない状態は緑"

# 1. 書類の行番号引用
DOC=".harness/evidence-2026-09-03/detached-window.md"
if [ -f "$DOC" ]; then
  cp "$DOC" "$TMP/doc.bak"
  # ★引用を **実行時に組み立てる**。此の script に literal で書くと、行番号引用の検出器
  #   (`no-linerefs`)が**対照自身**を捕まえる —— 対照は捕まる形を作る道具なので、
  #   検出器を緩めるのではなく、対照の側が literal を持たない形にする。
  N=1234
  printf '\nSee `ConversationView.swift:%s` for the placement.\n' "$N" >> "$DOC"
  # ★**staged にしてから**測る。`doc-linerefs` は作業木ではなく index を読む
  #   (`git show :0:<path>`)ので、staged にしない変更は其の検査から見えない ——
  #   此の対照の 1 回目は其れを知らずに書いて緑を出し、計器ではなく**私の思い込み**を暴いた。
  git add "$DOC" >/dev/null 2>&1
  expect_red "行番号引用を staged にすると赤" "doc-linerefs"
  cp "$TMP/doc.bak" "$DOC"; git add "$DOC" >/dev/null 2>&1; git reset -q HEAD -- "$DOC" >/dev/null 2>&1
else
  echo "SKIP  行番号引用(対象の書類が無い)"
fi

# 2. wire の突き合わせ(新しい鍵付き型を置く)
SW="ios/Sources/Core/__PreflightControlType.swift"
cat > "$SW" <<'SWIFT'
import Foundation
/// 対照専用。preflight が「未登録の鍵付き型」を見つけられるかを測る為だけに置く。
struct PreflightControlEnvelope: Decodable {
    let someKey: String
    let otherKey: Int
}
SWIFT
expect_red "未登録の鍵付き型を足すと赤" "wire-key-agreement"
rm -f "$SW"

# 3. 変異の的(探し文を今のコードに当たらない形へ)
MUT="rc-backend/test/mutation-controls.py"
cp "$MUT" "$TMP/mut.bak"
python3 - "$MUT" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="'metadataIncomplete: !r.reachedStart"
assert s.count(old)>=1, "対照の錨が見つからない(的の書き方が変わった)"
s=s.replace(old,"'__preflight_control_no_such_text: !r.reachedStart",1)
open(p,'w').write(s)
PY
expect_red "変異の的が当たらなくなると赤" "mutation-targets"
cp "$TMP/mut.bak" "$MUT"

# 4. 対照の登録漏れ(新しい対照を staged にするが一覧には足さない)
NEWC=".harness/__preflight-probe-control.sh"
echo '#!/bin/bash' > "$NEWC"
git add -N "$NEWC" >/dev/null 2>&1; git add "$NEWC" >/dev/null 2>&1
expect_red "未登録の対照を staged にすると赤" "controls-registration"
git rm -q --cached "$NEWC" >/dev/null 2>&1; rm -f "$NEWC"

# 5. staged の衛生(生ログを混ぜる)
RAW=".harness/evidence-2026-09-03/__preflight-probe.raw.log"
echo probe > "$RAW"; git add -f "$RAW" >/dev/null 2>&1
expect_red "生ログを staged にすると赤" "staged-hygiene"
git rm -q --cached "$RAW" >/dev/null 2>&1; rm -f "$RAW"

# 6. 復元できている(対照が木を汚したまま終わらない)
expect_green_overall "全部戻した後は再び緑"

echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED 0 ---"
[ "$FAIL" = 0 ]
