#!/bin/bash
# ensure-work-session.sh — 鎖②。tmux の `work` セッションが在る事だけを保証する。
#
# なぜ要るのか(2026-08-25、Friday への移設で判った)
#   `ensure-phone-window.sh`(鎖③)は **window を1枚足すだけ**で、session は作らない。
#   edith ではそこを `com.tom.work-tmux`(既存 job・60秒毎)が持っていたが、
#   **Friday にはその job が無い**(実測: launchctl に tmux 系 job ゼロ / tmux サーバ自体が不在)。
#   鎖②が欠けたまま鎖③だけ据えると、ensure-phone-window は永久に exit 10 を返し続ける ——
#   それは「異常ではない」と定義されている終了コードなので、**静かに永久に何もしない**。
#   この repo が一番恐れている壊れ方そのもの(= 正常と見分けが付かない)。
#
# 冪等の取り方: `has-session` の成否だけ。中で何が走っているかは見ない(鎖③の担当)。
# 既存の session には**一切触らない**。作るのは「無い時」だけ。
#
# 終了コード(鎖③と混ぜない):
#   0 … 在る(既に在った / 今作った)
#   1 … tmux の実行ファイルが無い
#   2 … 作ろうとしたが作れなかった(読み戻しで確認できなかった)
set -u
SESSION=${RC_PHONE_SESSION:-work}
CWD=${RC_WORK_SESSION_CWD:-$HOME}
TMUX_BIN=${RC_PHONE_TMUX:-/opt/homebrew/bin/tmux}

log() { printf '[%s] ensure-work-session: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

[ -x "$TMUX_BIN" ] || { log "★tmux が無い: $TMUX_BIN"; exit 1; }

if "$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null; then
    exit 0
fi

# ★作る時だけ書く。60 秒毎に「在る」を書くと log が壁紙になる(鎖③と同じ作法)。
log "session '$SESSION' が無いので作る(cwd=$CWD)"
"$TMUX_BIN" new-session -d -s "$SESSION" -c "$CWD" 2>&1 | sed 's/^/  tmux: /'

# 読み戻して確かめる。「撃った」は「在る」ではない。
if "$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null; then
    log "session '$SESSION' を作った"
    exit 0
fi
log "★作ったのに読み戻せない = 何かが即死している"
exit 2
