#!/bin/bash
# controls-for: test/mutation-controls.py package.json
# 単体スイートが**木の写しでも回る**か。
#
# ── なぜ要るか(2026-08-04、実際に踏んだ)────────────────────────────────────
# `test/mutation-controls.py` は `rc-backend` **だけ**を temp へ写し、その写しで
# `npm test` を回す。それが走行の最初に立てる対照1(無変異の木は緑)で、ここが落ちると
# 台本は `die()` する = **197 件の変異が 1 件も回らない**。
#
# この日、`test/design-supersede.test.mjs` が module の先頭で木の**外**に在る
# `../DESIGN.md` を読んでいた。手元では 580/580 緑。写しには親が無いので import の
# 時点で throw し、file ごと `testCodeFailure` になって対照1 が死んでいた。
# **その場の緑は、写しの緑を意味しない。** 単体スイートは変異走行の判定器なので、
# 「写しで回る」はスイートの機能要件である。
#
# 気付いたのは `mutation-freeze-controls.sh`(85 秒)が赤くなった時で、そこから
# 原因の1行に辿り着くまで 4 手かかった。この対照は同じ事を **7 秒で file 名ごと**言う。
#
# ── 検査そのものを落とす手 ────────────────────────────────────────────────
# 「写しで緑」を確かめるだけでは、写しの作り方を間違えて**常に緑**でも気付けない。
# だから同じ写しに、木の外を読む1行だけの囮を植えて**赤になる事**まで見る。
# 囮は砂場の中にしか置かない(本物の `test/` には1度も書かない)。
#
# 終了コード: 0=緑 / 1=赤 / 2=測れていない
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; return 0; }

SB=""
purge() {
    [ -n "$SB" ] && [ -d "$SB" ] || return 0
    case "$SB" in
        /tmp/copytree-ctl.*|/private/tmp/copytree-ctl.*) : ;;
        *) echo "  (砂場の path が想定の形でないので消さない: $SB)" >&2; return 0 ;;
    esac
    /usr/bin/find "$SB" -type f -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null
    /usr/bin/find "$SB" -type l -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null
    /usr/bin/find "$SB" -depth -type d 2>/dev/null | while IFS= read -r d; do /bin/rmdir "$d" 2>/dev/null; done
}
trap purge EXIT INT TERM

SB="$(cd "$(/usr/bin/mktemp -d /tmp/copytree-ctl.XXXXXX)" && pwd -P)" || exit 2

# ★除外は変異台本と**同じ2つ**にする(`shutil.ignore_patterns("node_modules", ".git")`)。
#   ここを増やすと、この対照は台本より甘い木を測る事になり、緑の意味が変わる。
DST="$SB/rc"
/usr/bin/rsync -a --exclude node_modules --exclude .git "$ROOT/" "$DST/" >/dev/null 2>&1 \
    || { echo "写しを作れなかった"; echo "COPIED-TREE-CONTROLS: 測定不成立(緑ではない)"; exit 2; }

# 写しが本物の親を持っていない事を確かめる。持っていたら、この対照は何も見分けない。
if [ -e "$SB/DESIGN.md" ] || [ -e "$SB/.git" ]; then
    echo "砂場の親に repo の物が在る = 木の外が見えてしまう配置"
    echo "COPIED-TREE-CONTROLS: 測定不成立(緑ではない)"
    exit 2
fi

run_suite() {   # $1 = 出力先。exit code をそのまま返す
    ( cd "$DST" && npm test --silent ) > "$1" 2>&1
}

# ── ① 写しで単体スイートが緑 ──────────────────────────────────────────────
OUT1="$SB/run1.txt"
rc1=0
run_suite "$OUT1" || rc1=$?
nfail="$(/usr/bin/sed -n 's/^# fail \([0-9][0-9]*\)$/\1/p' "$OUT1" | /usr/bin/tail -1)"
if [ -z "$nfail" ]; then
    echo "要約行(# fail)が出ていない = 測れていない"
    /usr/bin/tail -5 "$OUT1"
    echo "COPIED-TREE-CONTROLS: 測定不成立(緑ではない)"
    exit 2
fi
if [ "$rc1" -eq 0 ] && [ "$nfail" = "0" ]; then
    ntests="$(/usr/bin/sed -n 's/^# tests \([0-9][0-9]*\)$/\1/p' "$OUT1" | /usr/bin/tail -1)"
    nskip="$(/usr/bin/sed -n 's/^# skipped \([0-9][0-9]*\)$/\1/p' "$OUT1" | /usr/bin/tail -1)"
    ok "木の写しで単体スイートが緑(tests=${ntests} skipped=${nskip:-0})"
else
    ng "木の写しで単体スイートが緑" \
       "写しでだけ落ちている = 木の**外**を読んでいる file が居る。変異走行はこれで起動できない:
        $(/usr/bin/grep '^not ok' "$OUT1" | /usr/bin/head -5)"
fi

# ── ② 陰性対照: 木の外を読む file を植えると赤になる ──────────────────────
PROBE="$DST/test/zz-outside-read-probe.test.mjs"
{
  echo '// 対照用の囮(砂場の中だけ)。module の先頭で木の**外**を読む = 写しでは落ちる形。'
  echo 'import { readFileSync } from "node:fs";'
  echo 'import { dirname, join } from "node:path";'
  echo 'import { fileURLToPath } from "node:url";'
  echo 'import { test } from "node:test";'
  echo 'const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");'
  echo 'readFileSync(join(ROOT, "..", "DESIGN.md"), "utf8");'
  echo 'test("囮", () => {});'
} > "$PROBE"

OUT2="$SB/run2.txt"
rc2=0
run_suite "$OUT2" || rc2=$?
if [ "$rc2" -ne 0 ] && /usr/bin/grep -q 'zz-outside-read-probe' "$OUT2"; then
    ok "陰性対照: 木の外を読む file を植えると赤になり、**その file を名指しで**出す"
else
    ng "陰性対照: 木の外を読む file を植えると赤になる" \
       "rc=${rc2} —— 赤にならない/名前が出ないなら、①の緑は何も証明していない"
fi

/bin/rm -f "$PROBE"
[ -e "$PROBE" ] && ng "囮を片付けた" "残っている: $PROBE" || ok "囮を片付けた(不在を確認)"

echo ""
echo "COPIED-TREE-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
