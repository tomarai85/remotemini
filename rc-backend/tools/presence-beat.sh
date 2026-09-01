#!/bin/bash
# no-control: 計器。Jervis の画面の状態と tailnet 越しの ssh が要り、commit 時には回せない
# no-operator: launchd(`com.tom.rc-presence`)が 60 秒ごとに回す。人は撃たない。
#
# presence-beat.sh — 「Tom が机(Jervis)に座っている」を机(friday)へ伝える心拍。
#
# ── 何故 要るか(2026-08-31)────────────────────────────────────────────────
# 通知に会話名と着地のリンクを載せて価値を上げた。**其の直後に此れが要る** ——
# 机に居る時間帯の分だけ騒音が増え、狼少年化して信号ごと無視される様になるから。
# `digest-notify.sh` 自身が上の註で其の型を書いている(「狼を叫んだ見張りは3回目に読まれない」)。
#
# ── 何故 心拍なのか(施錠/解錠の出来事ではなく)────────────────────────────
# 出来事で捕まえる形だと、Jervis が落ちた・寝た・網が切れた時に「施錠された」が
# 届かず、**永久に在席扱い**で通知が死ぬ。心拍なら止まった時点で自然に古くなり、
# 受け手(`digest-notify.sh`)が「居ない」へ倒れる。
#
# ★★判らない時は**鳴らす側**へ倒す設計。此の台本が失敗しても、心拍が更新されない
#   = 通知が出る、にしかならない。逆(黙る側へ倒れる)には絶対にしない。
#
# ── 画面が開いているかの見方 ────────────────────────────────────────────────
# `ioreg` の `CGSSessionScreenIsLocked`。GUI にログイン中で施錠されていない時だけ
# 心拍を打つ。ログアウト / 施錠 / スリープ中は打たない。
set -uo pipefail

REMOTE="${RC_PRESENCE_HOST:-athenas}"
REMOTE_FILE="${RC_PRESENCE_REMOTE_FILE:-.rc-backend/presence-desk}"

locked="$(/usr/sbin/ioreg -n Root -d1 -a 2>/dev/null | /usr/bin/grep -c 'CGSSessionScreenIsLocked')"
if [ "${locked:-0}" != "0" ]; then
    exit 0   # 施錠中 = 居ない。打たない。
fi

# ★`-o BatchMode=yes` と短い timeout。網が渋い時に此の台本が溜まらない様にする
#   —— 溜まると 60 秒ごとの job が重なり、Jervis の資源を静かに食う。
/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=3 \
    "$REMOTE" "mkdir -p ~/.rc-backend && touch ~/$REMOTE_FILE" >/dev/null 2>&1

exit 0
