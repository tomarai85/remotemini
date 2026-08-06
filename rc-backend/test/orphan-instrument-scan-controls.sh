#!/bin/bash
# controls-for: tools/orphan-instrument-scan.sh
# `tools/orphan-instrument-scan.sh` が**緑にも赤にも未測定にもなる**事の確認。
#
# ── なぜ書くか ──────────────────────────────────────────────────────────
# この道具は「対照は在るのに走らせる物が無い」を挙げる物なので、**それ自身が
# 走らせる物を持たないまま置かれる**という同じ病に真っ先に罹る。門に繋いだ上で、
# 判定が現に効いている事を測らないと「毎回 0 本」が緑なのか盲目なのか判らない。
#
# ★本物の木は一切触らない。使い捨ての小さな repo を作り、その中だけで壊す。
#   (`test/mutation-target-controls.sh` と同じ作法。本物を壊して trap で戻す形は
#    2026-08-02 に別件で 805 行の file を消した実績が在る。)
#
# ── 測る物 ──────────────────────────────────────────────────────────────
#   ① 基準の木で緑。glob で回る物と印を置いた物が正しく差し引かれる
#   ② 操作者を消す / 印を消す / 理由を短くする -> それぞれ赤
#   ③ 操作者が在るのに印 -> 腐った印で赤(死んだ免除を溜めない)
#   ④ 印の**言及**は印と数えない(行頭の註 1 段深く)
#   ⑤ glob の差し引きが現に効いている(綴りを外せば孤児が出る)
#   ⑥ 測れない時は赤にも緑にもせず 2(glob 導出 0 / 宣言が下限割れ)
#   ⑦ 範囲外(path で撃たれない拡張子)は赤にせず**件数で出す**
#   ⑧ 註の中の名指しは操作者と数えない
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../tools/orphan-instrument-scan.sh"
[ -f "$TOOL" ] || { echo "道具が無い: $TOOL"; exit 2; }

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

T="$(/usr/bin/mktemp -d -t oisctl)" || exit 2
wipe() {
    [ -n "${1:-}" ] && [ -d "$1" ] || return 0
    /usr/bin/find "$1" -type f -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null
    /usr/bin/find "$1" -type d -mindepth 1 2>/dev/null | /usr/bin/sort -r \
      | while IFS= read -r d; do /bin/rmdir "$d" 2>/dev/null; done
    /bin/rmdir "$1" 2>/dev/null
}
trap 'wipe "$T"' EXIT INT TERM HUP

R="$T/repo"

# 使い捨ての木を毎回作り直す。
#   tools/widget.sh        操作者が在る(tools/gate.sh が名指しする)
#   tools/manual.sh        操作者は無いが印が在る
#   test/globbed.test.mjs  名指しは無いが npm test の glob が拾う
#   test/keeper.test.mjs   controls-for の対象ではない。glob を絞る試験の受け皿
mk() {
    wipe "$R"
    /bin/mkdir -p "$R/rc-backend/tools" "$R/rc-backend/test"
    /bin/cp "$TOOL" "$R/rc-backend/tools/orphan-instrument-scan.sh"
    /bin/cat > "$R/rc-backend/package.json" <<'JSON'
{ "scripts": { "test": "node --test 'test/**/*.test.mjs'" } }
JSON
    printf '#!/bin/bash\necho widget\n'                        > "$R/rc-backend/tools/widget.sh"
    printf '#!/bin/bash\n# no-operator: 人が手で撃つ物なので操作者は居ない\necho manual\n' \
                                                               > "$R/rc-backend/tools/manual.sh"
    printf '#!/bin/bash\nbash tools/widget.sh\n'               > "$R/rc-backend/tools/gate.sh"
    printf 'export const shape = 1;\n'                         > "$R/rc-backend/test/globbed.test.mjs"
    printf 'export const keep = 1;\n'                          > "$R/rc-backend/test/keeper.test.mjs"
    printf '# controls-for: tools/widget.sh\n'                 > "$R/rc-backend/test/widget-controls.sh"
    printf '# controls-for: tools/manual.sh\n'                 > "$R/rc-backend/test/manual-controls.sh"
    printf '# controls-for: test/globbed.test.mjs\n'           > "$R/rc-backend/test/globbed-controls.sh"
}

OUT=""; RC=0
run() {
    OUT="$(OIS_FLOOR=2 bash "$R/rc-backend/tools/orphan-instrument-scan.sh" 2>&1)"; RC=$?
}
# expect <期待する終了コード> <説明> [出力に含まれるべき綴り]
expect() {
    local want="$1" desc="$2" needle="${3:-}"
    if [ "$RC" != "$want" ]; then
        ng "$desc" "exit=$RC 期待=$want"; return
    fi
    if [ -n "$needle" ] && ! printf '%s' "$OUT" | /usr/bin/grep -qF "$needle"; then
        ng "$desc" "出力に $needle が無い"; return
    fi
    ok "$desc"
}

# --- ① 基準 ---------------------------------------------------------------
mk; run
expect 0 "基準の木は緑" "走らせる物が無い道具 0 本"
printf '%s' "$OUT" | /usr/bin/grep -qF "glob で回る 1" \
  && ok "glob で回る物が 1 本と数えられている" \
  || ng "glob で回る物の計数" "出力: $(printf '%s' "$OUT" | /usr/bin/grep '組 ')"
printf '%s' "$OUT" | /usr/bin/grep -qF "印で外した 1" \
  && ok "印で外した物が 1 本と数えられている" \
  || ng "印で外した物の計数" "出力: $(printf '%s' "$OUT" | /usr/bin/grep '組 ')"

# --- ② 操作者を消す -------------------------------------------------------
mk
printf '#!/bin/bash\necho nothing\n' > "$R/rc-backend/tools/gate.sh"
run
expect 1 "操作者を消せば孤児として赤" "孤児: rc-backend/tools/widget.sh"

# --- ② 印を消す -----------------------------------------------------------
mk
printf '#!/bin/bash\necho manual\n' > "$R/rc-backend/tools/manual.sh"
run
expect 1 "印を消せば孤児として赤" "孤児: rc-backend/tools/manual.sh"

# --- ② 理由が短い ---------------------------------------------------------
mk
printf '#!/bin/bash\n# no-operator: 短い\necho manual\n' > "$R/rc-backend/tools/manual.sh"
run
expect 1 "理由が短い印は黙らせているだけなので赤" "印の理由が短すぎる"

# --- ③ 操作者が在るのに印(死んだ免除)------------------------------------
mk
printf '#!/bin/bash\n# no-operator: 本当は門から撃たれているのに置かれた印\necho widget\n' \
  > "$R/rc-backend/tools/widget.sh"
run
expect 1 "操作者が在るのに印が付いていれば赤" "腐った印"

# --- ④ 印の「言及」は印ではない -------------------------------------------
#   註を 1 段深くした行(行頭の # の後がまた #)は書式の説明であって宣言ではない。
#   此処が緩いと、道具自身の説明文が印と読まれて自分を免除する。
mk
printf '#!/bin/bash\n#   # no-operator: これは書式の説明であって宣言ではない\necho manual\n' \
  > "$R/rc-backend/tools/manual.sh"
run
expect 1 "印の言及は印と数えない(孤児のまま赤)" "孤児: rc-backend/tools/manual.sh"

# --- ⑤ glob の差し引きが現に効いている ------------------------------------
#   glob を別の file だけに当たる綴りへ変える。導出は 1 本成立する(未測定にならない)が、
#   globbed.test.mjs は拾われなくなるので孤児として出るはず。
mk
/bin/cat > "$R/rc-backend/package.json" <<'JSON'
{ "scripts": { "test": "node --test 'test/keeper*.mjs'" } }
JSON
run
expect 1 "glob が外れれば glob 頼りの物が孤児として出る" "孤児: rc-backend/test/globbed.test.mjs"

# --- ⑥ 測れない: glob を 1 本も導出できない --------------------------------
mk
/bin/cat > "$R/rc-backend/package.json" <<'JSON'
{ "scripts": { "test": "node --test test/globbed.test.mjs" } }
JSON
run
expect 2 "glob を導出できなければ未測定(赤に丸めない)" "測れていない"

# --- ⑥ 測れない: 宣言が下限を割る ------------------------------------------
mk
printf 'controls-for という綴りを持たない file\n' > "$R/rc-backend/test/widget-controls.sh"
printf 'controls-for という綴りを持たない file\n' > "$R/rc-backend/test/manual-controls.sh"
printf 'controls-for という綴りを持たない file\n' > "$R/rc-backend/test/globbed-controls.sh"
run
expect 2 "宣言が下限を割れば未測定" "測れていない"

# --- ⑦ 指し先が実在しない --------------------------------------------------
mk
printf '# controls-for: tools/does-not-exist.sh\n' > "$R/rc-backend/test/dead-controls.sh"
run
expect 1 "実在しない指し先は赤" "指している道具が無い"

# --- ⑦ 範囲外は赤にせず件数で出す ------------------------------------------
mk
printf 'let x = 1\n' > "$R/rc-backend/test/Thing.swift"
printf '# controls-for: test/Thing.swift\n' > "$R/rc-backend/test/swift-controls.sh"
run
expect 0 "path で撃たれない拡張子は赤にしない" "path で撃たれない 1"

# --- ⑧ 註の中の名指しは操作者ではない --------------------------------------
mk
printf '#!/bin/bash\n# bash tools/widget.sh を昔は呼んでいた\necho nothing\n' \
  > "$R/rc-backend/tools/gate.sh"
run
expect 1 "註の中の名指しは操作者と数えない" "孤児: rc-backend/tools/widget.sh"

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" -eq 0 ] || exit 1
exit 0
