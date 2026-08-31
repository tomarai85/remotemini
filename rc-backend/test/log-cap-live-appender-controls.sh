#!/bin/bash
# controls-for: tools/log-cap-live-appender-proof.sh
#
# 「上限が launchd の追記者から書き込みを落とさないか」を示す台本の**解析部**の対照。
#
# ★測る中心は「本番で緑が出たか」ではない —— 其れは friday が要るし、緑は
#   「今日の機械の速さでは落ちなかった」しか言わない。測るのは
#   **抜けが在る時に、此の台本が本当に赤くなるか**。
#   検出できない検出器は、緑を出すたびに嘘をつく。
#
#   D1 抜けが無ければ 0
#   D2 ★抜けが在れば 1(しかも**どこが抜けたか**を数で言う)
#   D3 退避と log を**跨いだ**連続を見る(片方だけ見ると境目を測れない)
#   D4 番号を1つも読めなければ 2(0 に丸めない)
#   D5 file が無ければ 2
#   D6 ★頭が捨てられている事を抜けと呼ばない(上限の仕事は頭を捨てる事)
#
# 変異(→ 赤くなるべき検査):
#   M1 個数を数えず最初と最後だけ見る → D2(中抜けを見逃す)
#   M2 退避を読まない                 → D3
#   M3 読めない時に 0 を返す          → D4
#
# 使い方: bash rc-backend/test/log-cap-live-appender-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/log-cap-live-appender-proof.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"
cp "$SUT" "$SB/orig.sh"
restore() { cp -f "$SB/orig.sh" "$SUT"; }
trap 'restore; rm -rf "$SB"' EXIT

seqfile() {  # seqfile <file> <from> <to> [飛ばす番号...]
    local f="$1" from="$2" to="$3"; shift 3
    : > "$f"
    local i
    for ((i = from; i <= to; i++)); do
        case " $* " in *" $i "*) continue ;; esac
        printf 'seq=%d line\n' "$i" >> "$f"
    done
}

check() { bash "$SUT" --check "$1" "$2" >/dev/null 2>&1; }

# ── D1 / D3 抜けが無い(退避と log を跨いで連続)───────────────────────────
seqfile "$SB/snap" 100 149
seqfile "$SB/live" 150 200
check "$SB/snap" "$SB/live"
[ $? -eq 0 ] && ok "D1/D3 退避 100-149 と log 150-200 が跨いで連続していれば 0" \
             || ng "D1/D3 連続" "rc=$?(境目を跨げていない疑い)"

# ── D2 ★中抜け ──────────────────────────────────────────────────────────
seqfile "$SB/snap2" 100 149
seqfile "$SB/live2" 150 200 160 161 162
out="$(bash "$SUT" --check "$SB/snap2" "$SB/live2" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "160..162"; then
    ok "D2 ★中抜けを 1 で言い、どこが抜けたかを数で出す"
else ng "D2 中抜け" "rc=$rc / $out"; fi

# ── D2b 境目ちょうどの抜け(退避の末尾と log の先頭の間)────────────────────
# ★此処が此の台本の存在理由そのもの。上限が切った瞬間に落ちるなら、抜けは
#   **必ず此の位置**に出る。
seqfile "$SB/snap3" 100 149
seqfile "$SB/live3" 155 200
out="$(bash "$SUT" --check "$SB/snap3" "$SB/live3" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "150..154"; then
    ok "D2b ★境目ちょうどの抜け(切った瞬間に落ちた形)を掴む"
else ng "D2b 境目" "rc=$rc / $out"; fi

# ── D4 番号が読めない ───────────────────────────────────────────────────
printf 'no numbers here\n' > "$SB/snap4"; printf 'none either\n' > "$SB/live4"
bash "$SUT" --check "$SB/snap4" "$SB/live4" >/dev/null 2>&1
[ $? -eq 2 ] && ok "D4 番号を1つも読めなければ 2(0 に丸めない)" || ng "D4 読めない" "rc=$?"

# ── D5 file が無い ──────────────────────────────────────────────────────
bash "$SUT" --check "$SB/absent" "$SB/live" >/dev/null 2>&1
[ $? -eq 2 ] && ok "D5 file が無ければ 2" || ng "D5 不在" "rc=$?"

# ── D6 頭が捨てられている事を抜けと呼ばない ────────────────────────────────
# 上限の仕事は**頭を捨てる**事。1 から始まっていない事を欠陥と読むと、
# 正常な走行が毎回赤くなり、此の台本は使われなくなる。
seqfile "$SB/snap6" 5000 5049
seqfile "$SB/live6" 5050 5100
check "$SB/snap6" "$SB/live6"
[ $? -eq 0 ] && ok "D6 頭が捨てられている(1 から始まらない)事を抜けと呼ばない" \
             || ng "D6 頭の切り捨て" "rc=$?"

# ── 変異 ────────────────────────────────────────────────────────────────
mutate() {
    python3 - "$SUT" "$1" "$2" <<'PY'
import io, sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding="utf-8").read()
if a not in s:
    sys.stderr.write("ANCHOR-MISS\n"); sys.exit(3)
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
}
red() {  # red <名前> <退避> <log> — 変異を植えた後、赤くならなければ FAIL
    local name="$1"
    bash "$SUT" --check "$2" "$3" >/dev/null 2>&1
    [ $? -ne 1 ] && ok "$name → 見逃す(= 素の実装が守っている証拠)" \
                 || ng "$name" "変異を植えても赤いまま = 別の理由で赤かった疑い"
    restore
}

mutate 'if [ "$have" -ne "$want" ]; then' 'if [ "$first" -gt "$last" ]; then' \
    && red "M1 個数を数えず端だけ見る" "$SB/snap2" "$SB/live2" \
    || { ng "M1" "錨が動いた"; restore; }

mutate 'nums="$(cat "$snap" "$live" 2>/dev/null' 'nums="$(cat "$live" 2>/dev/null' \
    && red "M2 退避を読まない" "$SB/snap" "$SB/live" \
    || { ng "M2" "錨が動いた"; restore; }

mutate '[ -n "$nums" ] || { echo "log-cap-proof: 番号を1つも読めない = 測定不成立" >&2; exit 2; }' \
       '[ -n "$nums" ] || exit 0' \
    && { bash "$SUT" --check "$SB/snap4" "$SB/live4" >/dev/null 2>&1
         [ $? -eq 0 ] && ok "M3 読めない時に 0 を返す → D4 が守っている物が消える" \
                      || ng "M3" "変異が効いていない"; restore; } \
    || { ng "M3" "錨が動いた"; restore; }

# ★戻せた事を測る。
cmp -s "$SUT" "$SB/orig.sh" && ok "Z 台本を書き換えたまま終わらない" \
                            || ng "Z 台本が汚れている" "手で git checkout -- する事"

echo ""
echo "LOG-CAP-LIVE-APPENDER-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
