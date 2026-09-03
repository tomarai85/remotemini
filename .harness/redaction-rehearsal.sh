#!/bin/bash
# 履歴の伏字化を**捨てクローン**で予行する(2026-09-03、CF-5「private GitHub へ出すか」の材料)。
#
# 本物の repo には**一切 書かない**: clone → filter-repo → check-no-pii → 捨てる、の順で、最後に
# 本物の HEAD が動いていない事を自分で確かめる。remote も足さない。
#
# 出力(標準出力、人が読む):
#   REHEARSAL CLEAN   … 書き換え後の clone が check-no-pii(作業木 + 履歴)を通った
#   REHEARSAL DIRTY   … 通らなかった(残った物は check-no-pii の出力に在る)
#   併せて: 書き換えた file 数 / 変わった commit 数 / 書き換え後の `npm test` の集計(何が壊れるか)
#
# 使い方: bash .harness/redaction-rehearsal.sh   (数分。clone 114MB + 539 commit の書き換え)
set -uo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo"; exit 2; }
BASE="$(git -C "$ROOT" rev-parse HEAD)"
RULES="$ROOT/.harness/redaction-rules.txt"
[ -s "$RULES" ] || { echo "rules missing: $RULES"; exit 2; }
command -v git-filter-repo >/dev/null 2>&1 || { echo "git-filter-repo が無い(brew install git-filter-repo)"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/redaction-rehearsal.XXXXXX")" || exit 2
# KEEP=1 なら sandbox を残す(何が書き換わったかを目で見る為。既定は捨てる)
[ "${KEEP:-0}" = "1" ] || trap 'rm -rf "$T"' EXIT INT TERM HUP
echo "==> sandbox: $T"

# ★規則 file に註釈を書かない。filter-repo は `==>` の無い行を「其の文字列を ***REMOVED*** へ」
#   の規則として読む(2026-09-03 に単独の `#` の行が全 file の `#` を潰し、shebang まで壊れた)。
#   規則の意味は .harness/redaction-plan-2026-09-01.md に書く。此処では形だけ検査する。
if grep -vqE '==>' "$RULES"; then echo "★規則 file に `==>` の無い行が在る(註釈は禁止、全 file が壊れる)"; exit 2; fi

# 1. 捨てクローン(hardlink 無し = 本物の object に触らない)
git clone -q --no-hardlinks "$ROOT" "$T/clone" || { echo "clone failed"; exit 2; }

# 2. 規則 = 追跡している正規表現 + 走行時の hostname(literal を repo に置かない)
cp "$RULES" "$T/rules.txt"
HOST_SELF="$(hostname -s 2>/dev/null || true)"
if [ -n "$HOST_SELF" ] && [ "${#HOST_SELF}" -ge 6 ]; then
  printf 'regex:(?i)%s==>host-redacted\n' "$(printf '%s' "$HOST_SELF" | sed 's/[.[\*^$()+?{}|\\/]/\\&/g')" >> "$T/rules.txt"
fi

# 3. 書き換え(clone の中だけ)
before_commits="$(git -C "$T/clone" rev-list --count HEAD)"
( cd "$T/clone" && git filter-repo --replace-text "$T/rules.txt" --force --quiet ) || { echo "filter-repo failed"; exit 2; }
after_commits="$(git -C "$T/clone" rev-list --count HEAD)"

# 4. どれだけ変わったか(木の差 = 本物の HEAD の tree と書き換え後の tree)
mkdir -p "$T/orig"
git -C "$ROOT" archive "$BASE" | tar -x -C "$T/orig"
changed_files="$(diff -rq "$T/orig" "$T/clone" --exclude=.git 2>/dev/null | grep -c '^Files ' || true)"
# 書き換えで sha が変わった commit の数 = 元の sha が clone に残っていない数
rewritten="$(git -C "$ROOT" rev-list "$BASE" | while read -r c; do git -C "$T/clone" cat-file -e "$c" 2>/dev/null || echo x; done | grep -c x || true)"
echo "==> commits: $before_commits -> $after_commits / rewritten: $rewritten / files differing at HEAD: $changed_files"

# 5. 検出器を書き換え後の clone に当てる(作業木 + 履歴、同じ道具)
pii_out="$(cd "$T/clone" && bash rc-backend/tools/check-no-pii.sh 2>&1)"; pii_rc=$?
echo "==> check-no-pii in rewritten clone: exit $pii_rc"
printf '%s\n' "$pii_out" | tail -12

# 6. 書き換え後の一式(何が壊れるかの計測。壊れても予行は失敗ではない = 情報)
suite="$(cd "$T/clone/rc-backend" && npm test 2>&1 | grep -E '^# (tests|pass|fail)' | tr '\n' ' ')"
echo "==> npm test in rewritten clone: ${suite:-"(no summary)"}"

# 7. 本物が動いていない事
now="$(git -C "$ROOT" rev-parse HEAD)"
if [ "$now" != "$BASE" ]; then echo "★本物の HEAD が動いた: $BASE -> $now"; exit 3; fi
if git -C "$ROOT" remote -v | grep -q .; then echo "★本物に remote が在る"; exit 3; fi

if [ "$pii_rc" = 0 ]; then echo "REHEARSAL CLEAN"; exit 0; fi
echo "REHEARSAL DIRTY"; exit 1
