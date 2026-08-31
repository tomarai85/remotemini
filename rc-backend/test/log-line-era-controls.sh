#!/bin/bash
# controls-for: tools/log-line-era.sh
#
# 「其のログ行は今 走っている実装が書いた物か」の対照。
#
# ★測る中心は「今 通るか」ではなく、**壊れ方の2つを再び通さないか**。
#   此の判定は 2026-08-31 に 20 分で2回 壊れており、どちらも「緑のまま何も見ていない」型:
#     E4 判定が**構造的に真にならない**(UTC の刻を手元の時間帯で読み、刻が未来になる)
#     E1/E2 起動の前後で答が変わらない(= 判定そのものを書き忘れた形)
#
#   E1 起動より**後**の行 → 0
#   E2 起動より**前**の行 → 2(欄の意味が違うかもしれない)
#   E3 刻が空 / 形が違う → 3(0 に丸めない)
#   E4 ★UTC の刻を手元の時間帯で読んでいない(CDT で撃つと 5 時間ずれる)
#   E5 ★未来の刻は 3(読み違いを「今の走行」にしない)
#   E6 起動 epoch が数字でない → 3
#   E7 秒より下と末尾の Z を落として読める(本物の行の形)
#   M1 ★変異: `-u` を外すと E4 が赤くなる(= E4 が本当に其れを測っている)
#   M2 ★変異: 前後の比較を外すと E2 が赤くなる
#
# 使い方: bash rc-backend/test/log-line-era-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/log-line-era.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

SB="$(mktemp -d)"
cp "$SUT" "$SB/orig"
restore() { cp -f "$SB/orig" "$SUT"; }
trap 'restore; rm -rf "$SB"' EXIT

# 固定の数字で撃つ(「今」を渡せるので、走らせる時刻に依存しない)。
# ★刻は**UTC で書く**。手元の時間帯で書くと、判定が時間帯を取り違えていても通ってしまう。
NOW=1788156982          # 2026-08-31T06:16:22Z
BOOT=1788156964         # 其の 18 秒前 = 06:16:04Z
BEFORE="2026-08-31T04:42:03.766Z"   # 起動の約 1.6 時間前(本物の行の刻)
AFTER="2026-08-31T06:16:10.100Z"    # 起動の後、今より前

run() {  # run <期待 rc> <名前> <引数...>
    local want="$1" name="$2"; shift 2
    bash "$SUT" "$@" >/dev/null 2>&1; local rc=$?
    if [ "$rc" = "$want" ]; then ok "$name (rc=$rc)"
    else ng "$name" "期待 rc=$want 実測 rc=$rc"; fi
}

run 0 "E1 起動より後の行は 0"        "$BOOT" "$AFTER"  "$NOW"
run 2 "E2 起動より前の行は 2"        "$BOOT" "$BEFORE" "$NOW"
run 3 "E3 刻が空なら 3"              "$BOOT" ""        "$NOW"
run 3 "E3b 形が違えば 3"             "$BOOT" "昨日の夕方" "$NOW"
run 3 "E5 ★未来の刻は 3"            "$BOOT" "2027-01-01T00:00:00.000Z" "$NOW"
run 3 "E6 起動が数字でなければ 3"    "abc"   "$AFTER"  "$NOW"

# ── E4 ★時間帯。之が此の道具の存在理由 ────────────────────────────────────
# UTC で 04:42 の行は、CDT(UTC-5)で読むと 09:42 = **今より後**になる。
# 正しく読めていれば 2(起動より前)。手元の時間帯で読んでいれば 3(未来)か 0。
out_rc=$(bash "$SUT" "$BOOT" "$BEFORE" "$NOW" >/dev/null 2>&1; echo $?)
if [ "$out_rc" -eq 2 ]; then
    ok "E4 ★UTC の刻を UTC として読む(手元の時間帯で読むと 5 時間ずれる)"
else ng "E4 時間帯" "rc=$out_rc(2 が期待)= 刻を手元の時間帯で読んでいる"; fi

# ── 変異(→ 上の検査が赤くなるべき)────────────────────────────────────────
mutate() {  # mutate <元> <後>
    python3 - "$SUT" "$1" "$2" <<'PY'
import io, sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding="utf-8").read()
if a not in s:
    sys.stderr.write("ANCHOR-MISS\n"); sys.exit(3)
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
}

# M1 `-u` を外す = 2026-08-31 に実際に踏んだ形。
if mutate "date -u -j -f" "date -j -f"; then
    rc=$(bash "$SUT" "$BOOT" "$BEFORE" "$NOW" >/dev/null 2>&1; echo $?)
    if [ "$rc" -ne 2 ]; then ok 'M1 ★date の -u を外すと E4 が赤くなる'
    else ng "M1" "変異しても 2 のまま = E4 は時間帯を測っていない"; fi
    restore
else ng "M1" "錨が動いた"; fi

# M2 前後の比較を外す = 判定を書き忘れた形。
if mutate 'if [ "$SEEN_EPOCH" -lt "$BOOT" ]; then' 'if false; then'; then
    rc=$(bash "$SUT" "$BOOT" "$BEFORE" "$NOW" >/dev/null 2>&1; echo $?)
    if [ "$rc" -ne 2 ]; then ok "M2 ★前後の比較を外すと E2 が赤くなる(rc=$rc)"
    else ng "M2" "変異しても 2 のまま = E2 は比較を測っていない"; fi
    restore
else ng "M2" "錨が動いた"; fi

# ── E7 本物の行の形から刻を切り出せるか ────────────────────────────────────
LINE='[rc-backend] req 2026-08-31T04:42:03.766Z GET /api/sessions route=- client=app build=- code=200 reason=- ms=98'
SEEN=$(printf '%s' "$LINE" | sed -n 's/^\[rc-backend\] req \([^ ]*\) .*/\1/p')
if [ "$SEEN" = "$BEFORE" ]; then ok "E7 本物の行から刻を切り出せる"
else ng "E7 切り出し" "[$SEEN] != [$BEFORE]"; fi

# ── E8 ★呼ぶ側が本当に此れを使っているか(道具だけ直って呼ばれない形を塞ぐ)──
DC="$HERE/tools/delivery-check.sh"
if [ -f "$DC" ]; then
    if grep -q 'log-line-era.sh' "$DC"; then ok "E8 ★delivery-check が此の判定を呼んでいる"
    else ng "E8 呼び手" "delivery-check.sh が log-line-era.sh を呼んでいない = 直しても効かない"; fi
fi

# ── Z 木を汚したまま終わらない ────────────────────────────────────────────
if cmp -s "$SUT" "$SB/orig"; then ok "Z 木を汚したまま終わらない"
else ng "Z 木が汚れている" "手で git checkout -- tools/log-line-era.sh する事"; fi

echo ""
echo "LOG-LINE-ERA-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
