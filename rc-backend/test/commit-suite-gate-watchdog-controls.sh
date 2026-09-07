#!/bin/bash
# controls-for: tools/commit-suite-gate.sh
#
# 一式が**終わらない**時、門が時間で「測れなかった」(exit 2)と名乗り、止まっている process 木を出力に残し、子を殺す事を測る
# (2026-09-07、gate-41: `node --test` の子が idle のまま 20 分、出力ゼロ、commit は永遠に止まった)。
#   ①  hang: 一式の代わりに `sleep 999` を回し、SUITE_WATCHDOG_S=2 → exit 2 / 「終わらない」の文 / 木の dump に sleep が名指される /
#       sleep は殺されている(残すと次の commit の live 判定が「木が動いている」で止まる)
#   ②  対照(緑): 直ぐ終わる緑の一式は watchdog の下でも exit 0(退行なし)
#   ③  対照(遅いが終わる): 1 秒掛かる緑の一式は SUITE_WATCHDOG_S=10 で exit 0(締切の手前で終われば測れている)
#   ④  既定(600 s)を上書きせずに ①を撃つと待たされる —— 対照は撃たない(10 分待つ事になる)。代わりに既定値が script に在る事だけを読む
#   ⑤  孫(Codex #10): 子が孫を起こしてから止まる → 孫も dump に居て、殺されている
#   ⑥  壊れた値(Codex #7): 整数でない / 0 は既定に戻して測る
# 継ぎ目は既存の対照(`commit-suite-gate-controls.sh`)と同じ: `SUITE_CMD`(一式の代わり)/ `LIVE_CMD`(走行の有無 = exit 1 が「居ない」)。
# 本物の `npm test` も本物の走行も起こさない。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../tools/commit-suite-gate.sh"
SB="$(/usr/bin/mktemp -d -t suitewatch)" || exit 2
trap '/bin/rm -rf "$SB" 2>/dev/null' EXIT INT TERM HUP
PASS=0; FAIL=0
ok() { echo "PASS  $1"; PASS=$((PASS+1)); }
ng() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

printf '#!/bin/bash\nexit 1\n' > "$SB/live-none.sh"
printf '#!/bin/bash\necho "# tests 1"\necho "# pass 1"\necho "# fail 0"\nexit 0\n' > "$SB/green.sh"
printf '#!/bin/bash\n/bin/sleep 1\necho "# tests 1"\necho "# pass 1"\necho "# fail 0"\nexit 0\n' > "$SB/slow-green.sh"
NONCE="$$$(date +%s)"
printf '#!/bin/bash\n/bin/sleep 999.%s\n' "$NONCE" > "$SB/hang.sh"

# ① hang
out="$(SUITE_CMD="bash $SB/hang.sh" LIVE_CMD="bash $SB/live-none.sh" SUITE_WATCHDOG_S=2 bash "$GATE" 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then ok "hang: exit 2(測れていない、緑でも赤でもない)"; else ng "hang: exit $rc(2 を期待)"; echo "$out" | tail -5 | sed 's/^/     | /'; fi
if echo "$out" | grep -q '終わらない'; then ok "hang: 「終わらない」と名乗る"; else ng "hang: 文が無い"; fi
if echo "$out" | grep -q "sleep 999.$NONCE"; then ok "hang: 止まっている子(sleep)を木の dump で名指す"; else ng "hang: 木の dump に子が居ない"; echo "$out" | sed 's/^/     | /' | head -12; fi
/bin/sleep 1
if /usr/bin/pgrep -f "sleep 999.$NONCE" >/dev/null 2>&1; then ng "hang: 子が殺されていない(次の commit を止める)"; /usr/bin/pkill -f "sleep 999.$NONCE" 2>/dev/null; else ok "hang: 子は殺されている"; fi

# ② 対照(緑)
SUITE_CMD="bash $SB/green.sh" LIVE_CMD="bash $SB/live-none.sh" SUITE_WATCHDOG_S=5 bash "$GATE" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "対照: 直ぐ終わる緑の一式は exit 0(退行なし)"; else ng "対照: 緑が exit $rc"; fi

# ③ 対照(遅いが終わる)
SUITE_CMD="bash $SB/slow-green.sh" LIVE_CMD="bash $SB/live-none.sh" SUITE_WATCHDOG_S=10 bash "$GATE" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "対照: 締切の手前で終わる一式は exit 0"; else ng "対照: 遅い緑が exit $rc"; fi

# ④ 既定値
if grep -qE '^SUITE_WATCHDOG_S="\$\{SUITE_WATCHDOG_S:-600\}"$' "$GATE"; then ok "既定 600 s が script に在る"; else ng "既定値の行が無い / 変わった"; fi

# ⑤ 孫(Codex #10): 一式の子が孫を起こしてから止まる → 孫も殺されている
NONCE2="${NONCE}7"   # ★数字だけ(末尾に文字を付けると sleep が「単位」と読んで即座に死に、孫の対照が空回りする)
printf '#!/bin/bash\n/bin/sleep 999.%s &\n/bin/sleep 999.%s\n' "$NONCE2" "$NONCE" > "$SB/hang-grandchild.sh"
out="$(SUITE_CMD="bash $SB/hang-grandchild.sh" LIVE_CMD="bash $SB/live-none.sh" SUITE_WATCHDOG_S=2 bash "$GATE" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && echo "$out" | grep -q "sleep 999.$NONCE2"; then ok "孫: exit 2 で孫も dump に居る"; else ng "孫: exit $rc / dump に孫が無い"; fi
/bin/sleep 1
if /usr/bin/pgrep -f "sleep 999.$NONCE2" >/dev/null 2>&1 || /usr/bin/pgrep -f "sleep 999.$NONCE\b" >/dev/null 2>&1; then ng "孫: 子か孫が残っている"; /usr/bin/pkill -f "sleep 999.$NONCE" 2>/dev/null; else ok "孫: 子も孫も殺されている"; fi

# ⑥ 壊れた値(Codex #7): 整数でない / 範囲外は既定に戻して測る(緑の一式は exit 0 のまま)
out="$(SUITE_CMD="bash $SB/green.sh" LIVE_CMD="bash $SB/live-none.sh" SUITE_WATCHDOG_S=abc bash "$GATE" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && echo "$out" | grep -q '既定 600'; then ok "壊れた値は既定に戻して測る(exit 0)"; else ng "壊れた値: exit $rc"; fi
out="$(SUITE_CMD="bash $SB/green.sh" LIVE_CMD="bash $SB/live-none.sh" SUITE_WATCHDOG_S=0 bash "$GATE" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && echo "$out" | grep -q '既定 600'; then ok "0 は即時 timeout にならず既定に戻る"; else ng "0: exit $rc"; fi

echo "--- 合計: PASS $PASS / FAIL $FAIL ---"
[ "$FAIL" = 0 ]
