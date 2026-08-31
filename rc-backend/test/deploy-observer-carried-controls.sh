#!/bin/bash
# controls-for: tools/deploy-to-friday.sh tools/deploy-to-edith.sh
#
# 「本体を配ると観測器の木も一緒に運ばれる」事の対照。
#
# ── なぜ要るか(2026-08-31)────────────────────────────────────────────────
# `deploy-to-edith.sh` は `~/rc-backend/` しか運ばない。監視器は別 dir(`~/rc-observer/`)に
# 住み、別の launchd label で走るので、**配備の守備範囲の外**に落ちていた。其の死角で
# friday の `health-observer.sh` は repo より 139 行・22 日 古いまま動き、
# 毎日 Tom の Discord へ誤報を投げていた(CF-7 / H-4)。
#
# ★測る中心は「呼んでいるか」ではなく、**呼べる形で繋がっているか**。
#   此の系は `deploy-to-friday.sh` が env を並べて `exec` する連鎖で渡すので、
#   連鎖の途中に空行や註記が1行入るだけで **上半分が黙って捨てられる**
#   (2026-08-26 に2回踏んだ。症状は「friday へ配備した筈が edith を叩いた」)。
#   だから配線と**連鎖の連続性**の両方を測る。
#
#   C1 ★`deploy-to-friday.sh` の env の連鎖に `RC_OBSERVER_DEPLOY` が在る
#   C2 ★其の行が **`exec` までの連鎖の中**に在る(連鎖の外に置くと渡らない)
#   C3 ★連鎖に空行・註記が混ざっていない(混ざると其処から上が捨てられる)
#   C4 ★`deploy-to-edith.sh` が其の変数を**実行**する(名前を持つだけでは運ばれない)
#   C5 ★空 = 運ばない(材料を持たない機体の殻が誤って運ばない)
#   C6 ★門にしない(観測器の同期の失敗で本体の配備を巻き戻さない)
#   C7 指す先が実在する
#
# 使い方: bash rc-backend/test/deploy-observer-carried-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
FRIDAY="$HERE/tools/deploy-to-friday.sh"
EDITH="$HERE/tools/deploy-to-edith.sh"
for f in "$FRIDAY" "$EDITH"; do [ -f "$f" ] || { echo "測る対象が無い: $f"; exit 1; }; done

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

# ── C1 連鎖に在る ────────────────────────────────────────────────────────
grep -q '^RC_OBSERVER_DEPLOY=' "$FRIDAY" \
    && ok "C1 ★deploy-to-friday.sh が RC_OBSERVER_DEPLOY を渡す" \
    || ng "C1 変数が無い" "本体を配っても観測器は置き去りのまま"

# ── C2/C3 連鎖の連続性 ───────────────────────────────────────────────────
# `exec` の行から上へ遡り、**空行でない・註記でない・`\` で終わる**行が続く限りが連鎖。
# ★終端の行は**出力しない**(2026-08-31、自分で踏んだ)。`print` を先に書くと、
#   連鎖の1つ上の註記まで出力に混ざり、C3 が「註記が混ざっている」と赤くなる ——
#   検査の抽出が1行多いだけで、実装は正しかった。判定の前に抽出を疑う事。
chain="$(/usr/bin/awk '
    /^exec bash /       { inchain = 1; next }
    inchain == 1        { if ($0 !~ /\\$/) exit; print }
' <(/usr/bin/tail -r "$FRIDAY") | /usr/bin/tail -r)"
if printf '%s\n' "$chain" | grep -q '^RC_OBSERVER_DEPLOY='; then
    ok "C2 ★其の行は exec までの連鎖の中に在る"
else
    ng "C2 連鎖の外" "変数は在るが exec へ渡らない位置に在る"
fi
if printf '%s\n' "$chain" | grep -qE '^[[:space:]]*(#|$)'; then
    ng "C3 連鎖が切れている" "空行か註記が混ざっている = 其処から上が捨てられる(2026-08-26 に2回)"
else
    ok "C3 ★連鎖に空行も註記も混ざっていない"
fi

# ── C4 実行している ──────────────────────────────────────────────────────
# 名前が出るだけでは運ばれない。**実行の行**(bash "$RC_OBSERVER_DEPLOY")を要求する。
if grep -qE '(bash|sh)[[:space:]]+"\$RC_OBSERVER_DEPLOY"' "$EDITH"; then
    ok "C4 ★deploy-to-edith.sh が其れを実行する"
else
    ng "C4 実行していない" "変数を読むだけ / 名前を印字するだけ = 運ばれない"
fi

# ── C5 空なら運ばない ────────────────────────────────────────────────────
if grep -qE '\[ -n "\$\{RC_OBSERVER_DEPLOY:-\}" \]' "$EDITH"; then
    ok "C5 ★空 = 運ばない(材料を持たない機体の殻が誤って運ばない)"
else
    ng "C5 既定の扱い" "空でも走る形 = 観測器を持たない機体で必ず赤くなる"
fi

# ── C6 門にしない ────────────────────────────────────────────────────────
# `wl_run`(帳尻に出すが配備の終了コードには使わない)で呼んでいる事。
if grep -qE 'wl_run[^\n]*RC_OBSERVER_DEPLOY' "$EDITH"; then
    ok "C6 ★門にしない(同期の失敗で本体の配備を巻き戻さない)"
else
    ng "C6 門にしている" "観測器の同期が転ぶと本体の配備まで失敗扱いになる"
fi

# ── C7 指す先が実在 ──────────────────────────────────────────────────────
tgt="$(grep '^RC_OBSERVER_DEPLOY=' "$FRIDAY" | sed 's/^[^=]*="//; s/".*//; s|\$HERE|'"$HERE/tools"'|')"
[ -f "$tgt" ] && ok "C7 指す先が実在する($(basename "$tgt"))" \
              || ng "C7 指す先が無い" "$tgt"

echo ""
echo "DEPLOY-OBSERVER-CARRIED-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
