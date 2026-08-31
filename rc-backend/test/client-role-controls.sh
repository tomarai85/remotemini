#!/bin/bash
# controls-for: src/reqlog.mjs ../ios/tools/build.sh
#
# 「私の走行」と「Tom の電話」を数え分ける仕掛けの対照。
#
# ★なぜ要るか(H-3 訂正、2026-08-30 実測): `ios/tools/build.sh` が焼いた殻は
#   **製品の Swift をそのまま**使うので `RemoteMini/<番号> CFNetwork/…` を名乗り、
#   UA からは Tom の実機と1文字も違わない。述べ 593 件のうち 60 件が私の対照で、
#   36 件だけが Tom だった —— 私は**版番号で人を判じて**いた。彼が古い版に留まる日
#   (= 普段)には壊れる読み方で、実際 H-3 の解除条件を評価できなくしていた。
#
# ★守る一線は B1。**配布される束に `control` が焼かれない事**。焼かれれば Tom の要求が
#   `control` として記録され、「彼が使ったか」が永久に読めなくなる ——
#   今 直そうとしている嘘の、より悪い版になる。
#
#   B1 ★署名経路(sign / install)には役を焼かない
#   B2 simulator 向けにだけ `control` を焼く(Tom は simulator を持っていない)
#   B3 知らない mode は空(= Tom として数える側へ倒す。過大計上は見えるが、過少は嘘)
#   B4 机は `X-RC-Role: control` を採る(大小文字と前後の空白を問わない)
#   B5 知らない役は**採らない**。UA の判定へ落ちる(役の語彙を開いたままにしない)
#   B6 役を名乗らない要求は今まで通り(app / tool / probe / none)
#   B7 ★配る直前に**実物**の Info.plist を検める門が在る(方針だけ測って終わらない)
#   B8 ★app は**上限**であって「本人」ではない、と原文が言っている
#
# 使い方: bash rc-backend/test/client-role-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
REQLOG="$HERE/src/reqlog.mjs"
BUILD="$HERE/../ios/tools/build.sh"
for f in "$REQLOG" "$BUILD"; do [ -f "$f" ] || { echo "測る対象が無い: $f"; exit 1; }; done

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

role_of() { bash "$BUILD" --print-role "$1" 2>/dev/null | tr -d '[:space:]'; }

# ── B1 ★署名経路には焼かない ──────────────────────────────────────────────
bad=""
for m in sign install; do
    r="$(role_of "$m")"
    [ -n "$r" ] && bad="$bad $m=$r"
done
[ -z "$bad" ] && ok "B1 ★署名・導入の経路には役を焼かない(配布束が control になる道が無い)" \
              || ng "B1 署名経路" "役が焼かれている:$bad ← Tom の要求が control として記録される"

# ── B2 simulator ─────────────────────────────────────────────────────────
if [ "$(role_of sim)" = "control" ] && [ "$(role_of simapp)" = "control" ]; then
    ok "B2 simulator 向けにだけ control を焼く"
else ng "B2 simulator" "sim=$(role_of sim) simapp=$(role_of simapp)"; fi

# ── B3 知らない mode ─────────────────────────────────────────────────────
if [ -z "$(role_of nonsense)" ] && [ -z "$(role_of '')" ]; then
    ok "B3 知らない mode は空(過少計上より過大計上へ倒す)"
else ng "B3 知らない mode" "nonsense=[$(role_of nonsense)] 空=[$(role_of '')]"; fi

# ── B4-B6 机の分類 ───────────────────────────────────────────────────────
node --input-type=module -e '
import { clientClass } from "'"$REQLOG"'";
const UA = "RemoteMini/105 CFNetwork/3860.600.21 Darwin/25.5.0";
const bad = [];
const eq = (n, g, w) => { if (g !== w) bad.push(`${n}: got ${JSON.stringify(g)} want ${JSON.stringify(w)}`); };

eq("B4-採る",        clientClass(UA, { "x-rc-role": "control" }), "control");
eq("B4-大文字",      clientClass(UA, { "x-rc-role": "CONTROL" }), "control");
eq("B4-前後の空白",  clientClass(UA, { "x-rc-role": " control " }), "control");
eq("B5-知らない役",  clientClass(UA, { "x-rc-role": "admin" }), "app");
eq("B5-刻み損ね",    clientClass(UA, { "x-rc-role": "${RC_ROLE}" }), "app");
eq("B5-空の役",      clientClass(UA, { "x-rc-role": "" }), "app");
eq("B6-名乗らない",  clientClass(UA, {}), "app");
eq("B6-道具",        clientClass("curl/8.0", {}), "tool");
eq("B6-探り",        clientClass("rc-live-poll CFNetwork/1 Darwin/1", {}), "probe");
eq("B6-無名",        clientClass("", {}), "none");
eq("B6-引数1つ",     clientClass(UA), "app");

if (bad.length) { console.error(bad.join(" | ")); process.exit(1); }
' 2>&1
if [ $? -eq 0 ]; then ok "B4-B6 机の分類(役の採用・不採用・従来の語彙)"
else ng "B4-B6 机の分類" "上の行"; fi

# ── B7 ★配る直前に**実物**を検める門が在る(方針だけを測って終わらない)────
# `--print-role` が測るのは規則であって成果物ではない —— 古い plist が残っていた、
# 別の経路で焼かれた、は其れを通り抜ける(Codex 2026-08-30 の指摘1)。
OTA="$HERE/../ios/tools/adhoc-ota.sh"
if grep -q "Print :RCRole" "$OTA" && grep -q "配る束に役が焼かれている" "$OTA"; then
    ok "B7 配る前に実物の Info.plist を検める門が在る"
else ng "B7 成果物の門" "adhoc-ota.sh が焼かれた役を見ていない"; fi

# ── B8 ★`app` は**上限**であって「本人」ではない、と註記が言っている ──────────
# Codex 2026-08-30 の指摘3: 役を付けても曖昧さは移動しただけ。
#   control = たぶん私 / app = 本人 **または** 役を付け損ねた私の実機ビルド。
#   **不在**(app が0件)は強い陰性証拠だが、**存在**は本人の行為を証明しない。
# 読む人が此処を取り違えると、CF-17 の様な結論を逆向きに使う。
if grep -q "上限" "$REQLOG"; then
    ok "B8 app は上限であって本人ではない、と原文が言っている"
else ng "B8 上限の註記" "reqlog.mjs に無い(読む人が app=本人 と取り違える)"; fi

echo ""
echo "CLIENT-ROLE-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
