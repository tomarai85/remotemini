#!/usr/bin/env bash
# controls-for: tools/disposable-session.mjs
#
# `reap` の対照。掃除機の検査で一番大事なのは「掃く物を掃く」ではなく
# **掃いてはいけない物を掃かない**事なので、そちらを先に測る。
#
# ★なぜ在るか(2026-08-28): Codex が名指しした唯一残った穴が「呼び出し側が SIGKILL で
#   死ぬと trap が走らず、tmux セッションと登録簿が残る」。台本の側にどんな守りを
#   足しても台本が死ぬ形は台本では拾えないので、後始末を独立させた。
#   其の後始末が**間違って Tom の実セッションを畳む**と、直した物より酷い事になる。
#
# ★本物の tmux サーバに触らない。専用の socket(`-L`)を噛ませた包みを
#   `RC_TMUX_BIN` に渡し、その中だけで建てて壊す。
#
# 終了コード: 0=全部 OK / 1=NG が在る / 2=測れなかった
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/disposable-session.mjs"
NODE="${NODE_BIN:-node}"
REAL_TMUX="${RC_TMUX_BIN:-$( [ -x /opt/homebrew/bin/tmux ] && echo /opt/homebrew/bin/tmux || command -v tmux )}"
[ -x "$REAL_TMUX" ] || { echo "tmux が無いので測れない"; exit 2; }

SOCK="rc-reap-control-$$"
T=$(mktemp -d -t reap-controls)
PANES="$T/panes"; mkdir -p "$PANES"

# 専用 socket を噛ませる包み。道具は引数を組み立てるので、此処で -L を先頭へ挿す。
WRAP="$T/tmux"
printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$SOCK" > "$WRAP"
chmod +x "$WRAP"

PASS=0; FAIL=0
ok() { printf '  OK   %s\n' "$1"; PASS=$((PASS+1)); }
ng() { printf '  NG   %s\n' "$1"; FAIL=$((FAIL+1)); }

cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

run_reap() {  # run_reap <分>
    RC_TMUX_BIN="$WRAP" RC_PANE_DIR="$PANES" RC_KEY_DIR="$T/rc" \
        "$NODE" "$SUT" reap "$1" 2>&1
}
alive() { "$REAL_TMUX" -L "$SOCK" has-session -t "=$1" 2>/dev/null; }

# --- 古い物を建てる。齢は `session_created` なので**実際に待つ**しかない -------
"$REAL_TMUX" -L "$SOCK" new-session -d -s "rc-e2e-99999999999999" sleep 600 2>/dev/null
"$REAL_TMUX" -L "$SOCK" new-session -d -s "work"                  sleep 600 2>/dev/null
"$REAL_TMUX" -L "$SOCK" new-session -d -s "rc-e2e-like-but-not"   sleep 600 2>/dev/null
sleep 65   # 齢 1 分を跨がせる

# --- 1. 掃いてはいけない物(此処が本題)---------------------------------------
out=$(run_reap 1)
if alive "work"; then ok "実セッション work は齢が対象でも**畳まれない**(名前が守る)"
else ng "★work を畳んだ = 直した物より酷い事故"; fi
if alive "rc-e2e-like-but-not"; then
    ok "形が惜しいだけの名前は畳まない(rc-e2e-like-but-not)"
else ng "形が合わない名前を畳んだ = 正規表現が緩い"; fi

# --- 2. 掃くべき物 -----------------------------------------------------------
if alive "rc-e2e-99999999999999"; then
    ng "置き去りの使い捨てを畳んでいない($out)"
else ok "置き去りの使い捨て(齢 1 分超)を畳んだ"; fi

# --- 3. 若い物は畳まない -----------------------------------------------------
"$REAL_TMUX" -L "$SOCK" new-session -d -s "rc-e2e-88888888888888" sleep 600 2>/dev/null
run_reap 60 > /dev/null
if alive "rc-e2e-88888888888888"; then
    ok "齢が閾値に満たない使い捨ては畳まない(走行中を殺さない)"
else ng "★走行中かもしれない若い使い捨てを畳んだ"; fi

# --- 4. 登録簿: 生きている pid の記録は消さない -------------------------------
sleep 300 & LIVE_PID=$!
printf '{"session_id":"aaaaaaaa-0000-0000-0000-000000000000","pane":"%%1","pid":%s}\n' "$LIVE_PID" > "$PANES/aaaaaaaa-0000-0000-0000-000000000000.json"
printf '{"session_id":"bbbbbbbb-0000-0000-0000-000000000000","pane":"%%2","pid":999999}\n' > "$PANES/bbbbbbbb-0000-0000-0000-000000000000.json"
run_reap 60 > /dev/null
[ -f "$PANES/aaaaaaaa-0000-0000-0000-000000000000.json" ] \
    && ok "生きている pid の登録は残す" || ng "★生きている登録を消した"
[ -f "$PANES/bbbbbbbb-0000-0000-0000-000000000000.json" ] \
    && ng "死んだ pid の登録が残っている" || ok "死んだ pid の登録は消す"
kill "$LIVE_PID" 2>/dev/null

# --- 5. 齢の指定が読めない時は掃かない ----------------------------------------
run_reap "abc" > /dev/null 2>&1
if [ "$?" = "2" ]; then ok "齢が読めなければ 2 を返して何も掃かない(fail-closed)"
else ng "齢が読めないのに掃きに行った"; fi

echo
echo "disposable-reap-controls: OK $PASS / NG $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
