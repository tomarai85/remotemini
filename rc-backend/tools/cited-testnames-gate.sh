#!/bin/bash
# 受け入れ表と証跡が**引いている検査名が実在するか**を見る門。
#
# ── なぜ要るか(2026-08-09、実測)────────────────────────────────────────
# `.harness/dod-sprint-6.5.sh` は v1 の受け入れ表で、行ごとに「この性質はこの検査が
# 見ている」と検査名で名指しする。ある日 `ForegroundResumeTests.swift` の検査が改名
# (かつ否定対照が1本→4本に分割)された。表は改名を知らず、
#   testBackgroundToActiveEdgeTriggersForegroundResume
#   testInactiveToActiveDoesNotTriggerForegroundResumeNegativeControl
# を引き続き名指しし、**「実在しない検査名」= 製品の赤**として2行を出していた。
# 挙動は完全に覆われていたのに、表は「切断を跨げていない」と読める形で赤かった。
#
# ★これは `doc-linerefs-gate.sh` が止めた病の**次の段**である。あちらの指示は
#   「行番号でなく中身の目印(関数名)で引け」だった —— その関数名もまた腐る。
#   行番号 → 名前、と逃げた先に見張りが居なかった。
#
# ★腐りが赤として出る事の何が悪いか: 赤は**製品の欠陥**として読まれる。計器の腐りが
#   製品の赤に化けると、直す先を間違えるか、赤に慣れて表ごと信用しなくなる。
#   検査名が消えた時に赤を出すのは正しい(`check_names` の設計)。悪いのは、
#   改名が起きた**その commit で**誰も気付けない事の方。門は其処に置く。
#
# ── 対象(狭く取る)────────────────────────────────────────────────────
#   ① `.harness/dod-sprint-*.sh` のうち `*-controls.sh` でない物 = 生きた受け入れ表
#   ② `.harness/evidence-*/**.md` = 表が行10で照合する証跡
# 対象外にした物と、その理由:
#   - `*-controls.sh`: **わざと実在しない検査名を作る**のが仕事(`testRenamedAway`
#     `testThisNameDoesNotExistAnywhere` 等)。此処を見ると門は必ず赤になる。
#     残る穴 = 対照 file の中の本物の腐りは捕まらない。塞いでいない事を明記しておく。
#   - `DESIGN.md` / `WORKLOG.md` / `.harness/progress.md` / `feedback/*.md`:
#     **その時点の記録**。当時実在した名前が今無いのは腐りではなく歴史で、
#     此処を赤にする門は「使えない門」として外される(doc-linerefs-gate.sh の教訓)。
#
# 終了コード: 0=緑(または対象なし) / 1=赤 / 2=測れていない
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS="$ROOT/ios"

staged="$(git -C "$ROOT" diff --cached --name-only 2>/dev/null || true)"

# ★引き金は**両側**に要る。腐りを作るのは大抵「検査を改名した commit」の方で、
#   その commit は受け入れ表を1行も触らない —— 表側だけを引き金にすると素通りする。
if ! printf '%s\n' "$staged" | grep -qE '^(ios/(Tests|UITests)/|\.harness/dod-sprint-.*\.sh$|\.harness/evidence-.*\.md$)'; then
    exit 0
fi

if [ ! -d "$IOS/Tests" ]; then
    echo "cited-testnames: ios/Tests が無い = 測れていない"
    exit 2
fi

real="$(grep -rho -a 'func test[A-Za-z0-9_]*' "$IOS/Tests" "$IOS/UITests" 2>/dev/null \
        | sed 's/^func //' | sort -u)"

# 空振り防止。抜き出しに失敗した時の「引用が全部腐っている」は最悪の誤報なので、
# 0 件は緑にも赤にもせず**測れていない**へ落とす。
if [ -z "$real" ]; then
    echo "cited-testnames: 実在する検査名を1件も抜き出せなかった = 測れていない"
    echo "  (Swift の検査が 'func test…' 以外の書き方に変わった可能性。此処を直すまで緑にしない)"
    exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cited-testnames.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$real" > "$tmp/real.txt"

scope=()
while IFS= read -r f; do
    case "$f" in *-controls.sh) continue ;; esac
    scope+=("$f")
done < <(find "$ROOT/.harness" -maxdepth 1 -name 'dod-sprint-*.sh' 2>/dev/null | sort)
while IFS= read -r f; do
    scope+=("$f")
done < <(find "$ROOT/.harness" -path '*evidence*' -name '*.md' 2>/dev/null | sort)

if [ "${#scope[@]}" -eq 0 ]; then
    exit 0   # 受け入れ表も証跡も無い repo(木の写し等)。門は自分の対象だけを見る
fi

bad=0
for f in "${scope[@]}"; do
    grep -o -a -E '\btest[A-Z][A-Za-z0-9_]*' "$f" 2>/dev/null | sort -u > "$tmp/cited.txt"
    [ -s "$tmp/cited.txt" ] || continue
    stale="$(comm -23 "$tmp/cited.txt" "$tmp/real.txt")"
    if [ -n "$stale" ]; then
        bad=1
        printf '  %s\n' "${f#"$ROOT"/}"
        printf '%s\n' "$stale" | sed 's/^/      実在しない: /'
    fi
done

if [ "$bad" -ne 0 ]; then
    echo "cited-testnames: ★受け入れ表か証跡が、実在しない検査名を引いている。commit を止めた"
    echo '  直し = 検査を改名したなら引用側も同じ commit で直す。消したなら行ごと畳む'
    echo '  ★「名前が無い」を製品の赤として出さない事が目的。挙動が覆われていても表は赤くなる'
    exit 1
fi

echo "cited-testnames: 引用された検査名は全部実在する(表 ${#scope[@]} 本を照合)"
exit 0
