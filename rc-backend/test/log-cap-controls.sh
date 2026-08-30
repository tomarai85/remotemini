#!/bin/bash
# controls-for: tools/log-size-cap.sh
# controls-for: tools/log-cap-all.sh
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
#   C7 権限      — 退避先の mode が元 log と一致する(600 の中身を 644 に写さない)
#   C8 掃引の継続 — 1本失敗しても後ろの log は切られ、失敗は非 0 で帰る
#   C9 複数 dir  — dir を複数渡すと全部切られ、従来の <dir> <bytes> も動く
#   C10 無い dir  — 綴り違いを緑で帰さない(fail-open の修正)
#   C11 実配線   — plist が実際に2つの dir を渡している
#   C12 安全     — 退避先/元 log が symlink・hardlink なら触らない(api.key 上書き経路)
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

# ── C7 権限 ────────────────────────────────────────────────────────────────
# 本番の log は 600(`~/Library/Logs/rc-backend/` は 700)。退避先を umask 任せにすると
# 既定の 022 で **644** になり、600 の中身が緩い file に写る。実測で踏んだ欠陥。
# ★2つの mode で測る。片方だけだと「常に 600 にする」実装でも緑になり、
#   「元に合わせている」事を測れない。
D="$(mktemp -d)"
for m in 600 640; do
    F="$D/perm-$m.log"
    head -c 600000 /dev/urandom | base64 > "$F"; chmod "$m" "$F"
    bash "$CAP_ONE" "$F" 200000 >/dev/null 2>&1
    got="$(stat -f%Lp "$F.tail" 2>/dev/null || stat -c%a "$F.tail" 2>/dev/null)"
    if [ "$got" = "$m" ]; then ok "C7 退避の権限が元 log と一致する (mode $m)"
    else ng "C7 退避の権限が元 log と一致する" "元 $m に対し退避 $got"; fi
done
/bin/rm -rf "$D"

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

# ── C8 1本の失敗が掃引を止めない ───────────────────────────────────────────
# ★名前順で**前**に在る file が失敗した時、後ろの file が上限なしのまま残らないか。
#   初版は最初の失敗で exit していたので、`a-broken.log` の後ろは全部素通りだった。
#   しかも1時間ごとに同じ所で失敗するので、その状態が自動では解けない。
D="$(mktemp -d)"
printf 'x%.0s' $(seq 1 300000) > "$D/a-broken.log"; chmod 000 "$D/a-broken.log"
printf 'x%.0s' $(seq 1 300000) > "$D/z-ok.log"
out="$(bash "$CAP_ALL" "$D" 100000 2>&1)"; rc=$?
chmod 644 "$D/a-broken.log"
zs="$(size "$D/z-ok.log")"
if [ "${zs:-999999}" -le 100000 ]; then ok "C8 前の1本が失敗しても後ろは切られる (z-ok=$zs B)"
else ng "C8 前の1本が失敗しても後ろは切られる" "z-ok=$zs B = 掃引が止まった"; fi
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "失敗"; then
    ok "C8 失敗は握り潰さず非 0 で帰る (rc=$rc)"
else ng "C8 失敗を非 0 で帰す" "rc=$rc / $out"; fi
/bin/rm -rf "$D"

# ── C9 複数の dir ──────────────────────────────────────────────────────────
# ★上限を「大きい file の在る場所」ではなく「暴走の起きる場所」に置く為に、
#   dir を複数取れる様にした。測るのは3つ:
#   (a) 2つ目の dir も実際に切られる (b) 従来の <dir> <bytes> がそのまま動く
#   (c) 末尾が数字でなければ dir として扱う(上限を dir と誤読しない)
D="$(mktemp -d)"; mkdir -p "$D/one" "$D/two"
printf 'x%.0s' $(seq 1 300000) > "$D/one/a.log"
printf 'x%.0s' $(seq 1 300000) > "$D/two/b.log"
bash "$CAP_ALL" "$D/one" "$D/two" 100000 >/dev/null 2>&1
s1="$(size "$D/one/a.log")"; s2="$(size "$D/two/b.log")"
if [ "${s1:-9}" -le 100000 ] && [ "${s2:-9}" -le 100000 ]; then
    ok "C9 dir を2つ渡すと**両方**切られる (one=$s1 two=$s2)"
else ng "C9 dir 2つの両方が切られる" "one=$s1 two=$s2"; fi
/bin/rm -rf "$D"

# (b) 従来の形。★これが壊れると launchd の既存の呼び方と対照 C5 が同時に死ぬ。
D="$(mktemp -d)"; printf 'x%.0s' $(seq 1 300000) > "$D/c.log"
bash "$CAP_ALL" "$D" 100000 >/dev/null 2>&1
s3="$(size "$D/c.log")"
[ "${s3:-9}" -le 100000 ] && ok "C9b 従来の <dir> <bytes> がそのまま動く" \
                          || ng "C9b 従来の形" "$s3 B"
/bin/rm -rf "$D"

# (c) 上限を書かない時、既定の 5MB で回り、dir 引数が上限と誤読されない。
D="$(mktemp -d)"; printf 'x%.0s' $(seq 1 3000) > "$D/d.log"
out="$(bash "$CAP_ALL" "$D" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "上限 5242880 B"; then
    ok "C9c 上限を省くと既定 5MB(dir を上限と読まない)"
else ng "C9c 上限の省略" "rc=$rc / $out"; fi
/bin/rm -rf "$D"

# ── C10 無い dir を緑で帰さない ★fail-open の修正 ──────────────────────────
# ★初版は `[ -d "$DIR" ] || exit 0` だった。綴りを1文字間違えた引数が
#   「全部上限内」に見え、しかも launchd から1時間ごとに同じ嘘を出し続ける。
#   ★此処が緑に戻ったら、それは「直った」ではなく**守りが外れた**合図。
D="$(mktemp -d)"; printf 'x%.0s' $(seq 1 3000) > "$D/e.log"
out="$(bash "$CAP_ALL" "$D" "$D/no-such-dir" 100000 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "無い"; then
    ok "C10 指定した dir が無ければ rc=2(緑にしない)"
else ng "C10 無い dir で rc=2" "rc=$rc / $(printf '%s' "$out" | tail -1)"; fi
/bin/rm -rf "$D"

# ── C11 plist が両方の dir を渡している ────────────────────────────────────
# ★台本が複数 dir を取れても、plist が1つしか渡さなければ本番では何も変わらない。
#   「出来る様にした」と「実際にそう回っている」は別。
PL="$HERE/tools/com.fleet.rc-log-cap.plist"
if [ -f "$PL" ] && grep -q "Library/Logs/rc-backend" "$PL" && grep -q "/\.rc-backend" "$PL"; then
    ok "C11 plist が2つの dir を渡している(能力だけでなく実配線)"
else ng "C11 plist が2つの dir を渡す" "$PL"; fi

# ★数える方が切る方より**先**に居る事。順序が逆だと、切った回にその日の観測が失われる。
#   「両方書いてある」では足りない —— 並び順そのものが仕様。
if [ -f "$PL" ]; then
    line="$(grep -m1 'app-usage-census.sh' "$PL" || true)"
    if [ -z "$line" ]; then
        ng "C11b census が plist に居る" "1行も無い"
    elif printf '%s' "$line" | awk '{ c = index($0, "app-usage-census.sh"); l = index($0, "log-cap-all.sh"); exit !(c > 0 && l > 0 && c < l) }'; then
        ok "C11b plist は census を先に、cap を後に回す(順序が仕様)"
    else ng "C11b census が先" "順序が逆か、片方が別の行に居る: $line"; fi
fi

# ── C12 symlink 経由で別の file を上書きしない ★安全 ──────────────────────
# ★2026-08-30、Codex が**実演して**見せた経路。`>` は symlink を辿るので、
#   予測できる名前 `<file>.tail.new` に細工を置かれると其の先が上書きされる。
#   ★此のレーンでは机上の話ではない —— 同じ日に掃引を `~/.rc-backend` へ向けており、
#     其処には **api.key が在る**。「暴走の起きる場所へ上限を置く」は正しかったが、
#     其処は同時に「壊されて困る物が在る場所」でもあった。
#   実測(守りを外した変異): api.key 24 B -> 100,000 B、しかも **exit 0**。
D="$(mktemp -d)"
printf 'SECRET-KEY-DO-NOT-TOUCH\n' > "$D/api.key"
kbefore="$(size "$D/api.key")"
head -c 600000 /dev/urandom | base64 > "$D/live.log"
ln -s "$D/api.key" "$D/live.log.tail.new"
bash "$CAP_ONE" "$D/live.log" 200000 >/dev/null 2>&1; rc=$?
kafter="$(size "$D/api.key")"
if [ "$kbefore" = "$kafter" ] && [ "$rc" -ne 0 ]; then
    ok "C12 退避先が symlink なら拒む(api.key は $kafter B のまま・rc=$rc)"
else ng "C12 symlink 経由の上書きを拒む" "api.key $kbefore B -> $kafter B / rc=$rc"; fi
/bin/rm -rf "$D"

# 入口(元 log)が symlink の時も触らない。辿ると**別の file を切る**事になる。
D="$(mktemp -d)"
head -c 600000 /dev/urandom | base64 > "$D/real.log"
rbefore="$(size "$D/real.log")"
ln -s "$D/real.log" "$D/link.log"
bash "$CAP_ONE" "$D/link.log" 200000 >/dev/null 2>&1; rc=$?
rafter="$(size "$D/real.log")"
if [ "$rbefore" = "$rafter" ] && [ "$rc" -ne 0 ]; then
    ok "C12b 元 log が symlink なら切らない(rc=$rc)"
else ng "C12b 元 log が symlink" "$rbefore -> $rafter / rc=$rc"; fi
/bin/rm -rf "$D"

# ★退避先が hardlink の時も拒む(symlink だけ塞いでも同じ結果になる別経路)。
D="$(mktemp -d)"
printf 'SECRET\n' > "$D/api.key"
head -c 600000 /dev/urandom | base64 > "$D/h.log"
ln "$D/api.key" "$D/h.log.tail" 2>/dev/null && {
    hbefore="$(size "$D/api.key")"
    bash "$CAP_ONE" "$D/h.log" 200000 >/dev/null 2>&1; rc=$?
    hafter="$(size "$D/api.key")"
    if [ "$hbefore" = "$hafter" ] && [ "$rc" -ne 0 ]; then
        ok "C12c 退避先が hardlink なら拒む(rc=$rc)"
    else ng "C12c hardlink を拒む" "$hbefore -> $hafter / rc=$rc"; fi
}
/bin/rm -rf "$D"

echo ""
echo "LOG-CAP-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
