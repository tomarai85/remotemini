#!/bin/bash
# controls-for: rc-backend/tools/log-size-cap.sh
# controls-for: rc-backend/tools/log-cap-all.sh
#
# log-cap-controls.sh — 上限を掛ける台本が「行を失わずに」切れるかを測る。
#
# ★測るのは「上限内に収まるか」**ではない**。それは初版でも通っていた。
#   測るのは **切る過程で追記中の行を失わないか**。
#   2026-08-30、初版の検査は「大きさが増え続けるか」だけを見ていて、
#   上書きが起きていても成立する物だった(Codex の指摘で気付いた)。
#
# 対照の構成:
#   C1 基本      — 上限を超えた file が上限内に収まり、空にならない
#   C2 巨大1行   — 改行の無い巨大な1行で `sed 1d` が中身を消し飛ばさない(81 B 事故)
#   C3 同時追記  — 追記され続けている file を切っても連番に欠けが出ない ★中核
#   C4 変異対照  — 書き戻し方式に戻すと C3 が**赤くなる**(検査が本物である事の証明)
#   C5 掃き手    — 0 本を舐めた時に「全部上限内」と読ませない
#   C6 退避      — 末尾が `<file>.tail` に在り、本体には行方を示す1行が残る
#
# 使い方: bash rc-backend/test/log-cap-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP_ONE="$HERE/tools/log-size-cap.sh"
CAP_ALL="$HERE/tools/log-cap-all.sh"
pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }

for f in "$CAP_ONE" "$CAP_ALL"; do
    [ -f "$f" ] || { echo "測る対象が無い: $f"; exit 1; }
done

# ── C1 基本 ────────────────────────────────────────────────────────────────
D="$(mktemp -d)"; F="$D/c1.log"
head -c 3000000 /dev/urandom | base64 > "$F"
bash "$CAP_ONE" "$F" 500000 >/dev/null 2>&1
s="$(size "$F")"
if [ "${s:-0}" -le 500000 ] && [ "${s:-0}" -gt 0 ]; then ok "C1 上限内に収まり空にならない ($s B)"
else ng "C1 上限内に収まり空にならない" "$s B"; fi
# C6 は C1 の産物で測る(退避 file と註記の1行)
if [ -s "$F.tail" ] && grep -q "log-size-cap" "$F"; then
    ok "C6 末尾は $(basename "$F").tail に在り、本体に行方の1行が残る"
else ng "C6 退避と註記" "tail=$(size "$F.tail" 2>/dev/null) / 本体に註記なし"; fi
/bin/rm -rf "$D"

# ── C2 巨大1行 ─────────────────────────────────────────────────────────────
# 改行の無い1行だけの file。`sed 1d` で処理すると中身が消える(実際 500KB -> 81 B にした)。
D="$(mktemp -d)"; F="$D/c2.log"
head -c 400000 /dev/urandom | base64 | tr -d '\n' > "$F"
bash "$CAP_ONE" "$F" 200000 >/dev/null 2>&1
t="$(size "$F.tail" 2>/dev/null || echo 0)"
if [ "${t:-0}" -gt 50000 ]; then ok "C2 巨大1行でも中身が残る (退避 $t B)"
else ng "C2 巨大1行でも中身が残る" "退避 $t B = 81 B 事故の再演"; fi
/bin/rm -rf "$D"

# ── C3 / C4 同時追記(共通の測り手)─────────────────────────────────────────
# 書き手が SEQ-1, SEQ-2, … を追記している最中に切り、後で**連番の欠け**を数える。
# ★「連番が戻った箇所」ではない。上書きは順序を戻さず、行を消す。
concurrent_holes() {   # $1=使う台本 -> 標準出力に "holes broken lines"
    local script="$1" d f w
    d="$(mktemp -d)"; f="$d/live.log"
    ( i=0; while [ $i -lt 200000 ]; do i=$((i+1)); echo "SEQ-$i"
        [ $((i % 2000)) -eq 0 ] && sleep 0.05; done > "$f" ) & w=$!
    sleep 3
    bash "$script" "$f" 200000 >/dev/null 2>&1
    sleep 3
    kill $w 2>/dev/null; wait $w 2>/dev/null
    python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
lines = list(open(p, errors="replace"))
nums = [int(m.group(1)) for m in (re.match(r"SEQ-(\d+)\s*$", l) for l in lines) if m]
broken = sum(1 for l in lines if l.startswith("SEQ-") and not re.match(r"SEQ-\d+\s*$", l))
holes = sum(1 for i in range(1, len(nums)) if nums[i] != nums[i - 1] + 1)
print(holes, broken, len(nums))
PY
    /bin/rm -rf "$d"
}

read -r h b n <<< "$(concurrent_holes "$CAP_ONE")"
if [ "${h:-1}" -eq 0 ] && [ "${b:-1}" -eq 0 ] && [ "${n:-0}" -gt 1000 ]; then
    ok "C3 同時追記中に切っても欠け 0 / 壊れた行 0 ($n 行)"
else ng "C3 同時追記中に切っても欠け 0" "欠け=$h 壊れ=$b 行数=$n"; fi

# ── C4 変異対照 ────────────────────────────────────────────────────────────
# `: > "$F"`(1回だけ空にする)を `cp "$snap" "$F"`(書き戻し = Codex 前の形)に差し替える。
# ★これで C3 が緑のままなら、C3 は何も測っていない。
MD="$(mktemp -d)"; MUT="$MD/mutant.sh"
sed -e 's|^: > "\$F" .*|cp "$snap" "$F" \|\| exit 1|' \
    -e '/^printf .\[log-size-cap\] %s 時点/,+2d' "$CAP_ONE" > "$MUT"
if ! bash -n "$MUT" 2>/dev/null; then
    ng "C4 変異対照" "変異が構文として成立しない = sed の当て先が動いた(対照を直す事)"
elif ! grep -q 'cp "$snap" "$F"' "$MUT"; then
    ng "C4 変異対照" "変異が当たっていない = 元の台本の綴りが変わった(対照を直す事)"
else
    read -r mh mb mn <<< "$(concurrent_holes "$MUT")"
    if [ "${mh:-0}" -gt 0 ]; then ok "C4 書き戻し方式に戻すと赤くなる (欠け $mh 箇所) = C3 は本物"
    else ng "C4 書き戻し方式に戻すと赤くなる" "欠け 0 のまま = C3 が壊れ方を測れていない"; fi
fi
/bin/rm -rf "$MD"

# ── C5 掃き手 ──────────────────────────────────────────────────────────────
D="$(mktemp -d)"
if bash "$CAP_ALL" "$D" 100000 >/dev/null 2>&1; then
    ng "C5 0 本を舐めたら測定不成立" "rc=0 = 『全部上限内』に見えてしまう"
else
    [ $? -eq 2 ] && ok "C5 0 本を舐めたら rc=2(測定不成立)" || ok "C5 0 本を舐めたら非 0"
fi
printf 'x%.0s' $(seq 1 300000) > "$D/a.log"; echo hi > "$D/b.log"
out="$(bash "$CAP_ALL" "$D" 100000 2>&1)"
if printf '%s' "$out" | grep -q "2 本を見て 1 本を切った"; then
    ok "C5 見た本数と切った本数を別々に言う"
else ng "C5 件数の報告" "$out"; fi
/bin/rm -rf "$D"

echo ""
echo "LOG-CAP-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
