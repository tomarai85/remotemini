#!/bin/bash
# controls-for: tools/phone-window-health.sh
#
# ★この対照が守る一線: **窓が在る事を「使える」と読ませない**。
#   本物の tmux で偽の session/window を立て(名前を分ける)、登録簿だけを差し替えて
#   4つの状態(使える / 登録なし / 死んだ pid / 壊れた JSON)が別々の顔をするか見る。
#   本物の `work` session と本物の登録簿には触らない。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/tools/phone-window-health.sh"
TM="${RC_PHONE_TMUX:-/opt/homebrew/bin/tmux}"
pass=0; fail=0
ok(){ printf '  OK   %s\n' "$1"; pass=$((pass+1)); }
ng(){ printf '  ★NG  %s — %s\n' "$1" "$2"; fail=$((fail+1)); }
[ -x "$TM" ] || { echo "tmux が無い = 測っていない"; exit 2; }

S="ctl-pwh-$$"; D="$(mktemp -d)"; P="$D/panes"; mkdir -p "$P"
cleanup(){ "$TM" kill-session -t "=$S" 2>/dev/null; rm -rf "$D"; }
trap cleanup EXIT
run(){ RC_PHONE_SESSION="$S" RC_PHONE_WINDOW=phone RC_PHONE_PANES_DIR="$P" bash "$H" "$@" 2>&1; }

# --- session がまだ無い -------------------------------------------------------
run >/dev/null 2>&1; [ $? -eq 10 ] && ok "P1 session が無い時は 10(異常ではないと区別する)" || ng "P1" "10 以外"

"$TM" new-session -d -s "$S" -c "$D" 2>/dev/null; sleep 1
run >/dev/null 2>&1; [ $? -eq 11 ] && ok "P2 窓が無い時は 11(10 と混ぜない)" || ng "P2" "11 以外"

"$TM" new-window -d -t "=$S" -n phone -c "$D" 2>/dev/null; sleep 1
read -r PANE PPID_ <<<"$("$TM" list-panes -t "=$S:phone" -F '#{pane_id} #{pane_pid}' | head -1)"
# ★登録の pid は**そのペインの中の**プロセスでなければならない(2026-08-26 の締め直し)。
#   ペイン id は再利用されるので、id 一致だけでは別物を「使える」と読む。
#   だから検体もペイン自身の pid を使う —— 手元の $$ を使うと、検査ではなく検体が嘘になる。
[ -n "$PANE" ] && ok "P3 検体の窓が立った($PANE)" || ng "P3" "ペインが取れない"

# --- 窓は在るが登録が無い(= 2026-08-25 に踏んだ穴そのもの)---------------------
out="$(run)"; rc=$?
[ "$rc" -eq 1 ] && ok "P4 ★窓が在っても登録が無ければ 1(在る事を使えると読まない)" || ng "P4" "rc=$rc"
printf '%s' "$out" | grep -q "自動で押さない" && ok "P5 ★自動で答えないと明言する" || ng "P5" "文が無い"
printf '%s' "$out" | grep -q "画面の末尾" && ok "P6 何が待っているか画面を出す" || ng "P6" "画面が無い"

# --- 生きた pid の登録が在る --------------------------------------------------
printf '{"session_id":"S-ALIVE","pane":"%s","pid":%s}\n' "$PANE" "$PPID_" > "$P/a.json"
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && ok "P7 生きた登録が在れば 0" || ng "P7" "rc=$rc"
printf '%s' "$out" | grep -q "S-ALIVE" && ok "P8 どの会話かを名乗る" || ng "P8" "session_id が出ない"

# --- ★死んだ pid の登録を「使える」と読まない ---------------------------------
dead=$( (sleep 0 & echo $!) ); sleep 1
printf '{"session_id":"S-DEAD","pane":"%s","pid":%s}\n' "$PANE" "$dead" > "$P/a.json"
run >/dev/null 2>&1
[ $? -eq 1 ] && ok "P9 ★死んだ pid の古い登録を使えると読まない" || ng "P9" "緑にした"

# --- ★別のペインを指す登録に釣られない ---------------------------------------
printf '{"session_id":"S-OTHER","pane":"%%999","pid":%s}\n' "$PPID_" > "$P/a.json"
run >/dev/null 2>&1
[ $? -eq 1 ] && ok "P10 ★別ペインの登録に釣られない" || ng "P10" "緑にした"

# --- 壊れた JSON が1本在っても、生きた登録は見つける -------------------------
echo "{oops" > "$P/broken.json"
printf '{"session_id":"S-ALIVE2","pane":"%s","pid":%s}\n' "$PANE" "$PPID_" > "$P/a.json"
run >/dev/null 2>&1
[ $? -eq 0 ] && ok "P11 壊れた登録が1本在っても他を諦めない" || ng "P11" "全部捨てた"

# --- ★ペイン id が一致していても、中のプロセスでなければ使えると読まない ------
printf '{"session_id":"S-ALIEN","pane":"%s","pid":%s}\n' "$PANE" "$$" > "$P/a.json"
run >/dev/null 2>&1
[ $? -eq 1 ] && ok "P13 ★id が一致しても別プロセスの登録は使えないと読む(id 再利用)" || ng "P13" "緑にした"
printf '{"session_id":"S-ALIVE3","pane":"%s","pid":%s}\n' "$PANE" "$PPID_" > "$P/a.json"
rm -f "$P/broken.json"
run >/dev/null 2>&1
[ $? -eq 0 ] && ok "P14 ★陰性: 正しい pid なら緑(P13 が常に赤ではない)" || ng "P14" "赤のまま"

# --- 登録簿の dir ごと無い = 監視が壊れている(使えないとは別) ----------------
RC_PHONE_SESSION="$S" RC_PHONE_WINDOW=phone RC_PHONE_PANES_DIR="$D/nope" bash "$H" >/dev/null 2>&1
[ $? -eq 3 ] && ok "P12 ★登録簿が無い = 3(『使えない』1 と混ぜない)" || ng "P12" "3 以外"

echo "--- 合計: PASS $pass / FAIL $fail ---"
exit $(( fail > 0 ))
