#!/bin/bash
# Sprint 5 DoD 9行目 —— **電話の送信路を、本物の rc-backend へ実際に当てる**。
#
# 何を確かめるか(3つ、全部**観測**で):
#   1. 製品の `SendClient` が本物のサーバから `display` を受け取る(モックではなく)
#   2. その `display` が `kind=ok` / `keepText=false` = サーバ側 `delivered:"verified"` の顔
#   3. 送った本文が**転写(jsonl)に着いている** = 行数が増える
#      ★2 だけでは足りない。サーバが「取り込まれた」と言った事と、Claude Code が実際に
#        受け取った事は別の主張。3 が無いと前者を後者として読む型になる。
#
# 走る場所: 送る側 = この機械(Jervis、swiftc がある)。建てる側 = edith(rc-backend の本番)。
# 経路: tailnet の https。`tailscale serve` が 127.0.0.1:8787 へ渡している。
#
# ★鍵の扱い: `ssh edith 'cat ~/.rc-backend/api.key'` を**変数に取って標準入力へ流すだけ**。
#   - argv に置かない(`ps` に出る)/ 環境変数に置かない(`ps -E` と子に漏れる)
#   - 印字しない / log に残さない。`printf` は bash の組込みなのでプロセスにならない。
# ★会話 id も出さない(`live-http-check.mjs` と同じ理由で、id は持ち出さない)。
#
# 使い方: ios/tools/live-send-check.sh [--url URL] [--host SSH先] [--keep]
#   --keep = 終わってもセッションを畳まない(人が画面を見たい時だけ)
set -uo pipefail

URL="${RC_LIVE_URL:-https://desk.tailnet.example}"
# ★`edith` という短い別名は**この機械には無い**(2026-08-05 実測: Host key verification failed)。
#   Tom の `~/.ssh/config` に Host エントリが入るまでは名前を全部書く方が動く。
SSH_HOST="${RC_LIVE_SSH:mail-redacted@example.invalid}"
REMOTE_TOOLS="${RC_LIVE_REMOTE:-\$HOME/rc-backend/tools}"
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --host) SSH_HOST="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "知らない引数: $1" >&2; exit 2 ;;
  esac
done

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
BIN="$WORK/rc-live-send"
SESSION=""
SID=""

VERDICT_OK=0
cleanup() {
  if [ -n "$SESSION" ] && [ "$KEEP" = "0" ]; then
    echo "--- 畳む ---"
    # ★転写を消すのは**緑だった時だけ**。転んだ走行の転写は、人が次に読む唯一の物なので残す。
    PURGE=""
    [ "$VERDICT_OK" = "1" ] && PURGE=" --purge-transcript"
    [ "$VERDICT_OK" = "1" ] || echo "(判定が緑でないので転写は残す)"
    ssh "$SSH_HOST" "node $REMOTE_TOOLS/disposable-session.mjs down '$SESSION' '$SID'$PURGE" 2>&1 |
      sed "s#$SID#<会話 id>#g"
  elif [ -n "$SESSION" ]; then
    echo "--keep: セッションを残した(畳むのは人の手)"
  fi
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== 1. 電話側の殻を建てる(製品の Swift をそのまま使う) ==="
# ★ここで建てるのは**製品コード**。`Sources/Core/` の3本は アプリの target と同じ file。
swiftc -O -o "$BIN" \
  "$IOS_DIR/tools/live-send-main.swift" \
  "$IOS_DIR/Sources/Core/SendClient.swift" \
  "$IOS_DIR/Sources/Core/ResultDisplay.swift" \
  "$IOS_DIR/Sources/Core/BackendSession.swift" || { echo "swiftc が通らない"; exit 2; }
echo "ok: $(/usr/bin/stat -f %z "$BIN") bytes"

echo
echo "=== 2. edith に使い捨ての本物 TUI を建てる ==="
UP="$(ssh "$SSH_HOST" "node $REMOTE_TOOLS/disposable-session.mjs up")" || { echo "建たなかった"; exit 2; }
SESSION="$(printf '%s\n' "$UP" | sed -n 1p)"
SID="$(printf '%s\n' "$UP" | sed -n 2p)"
if [ -z "$SESSION" ] || [ -z "$SID" ]; then echo "up の出力が2行ではない"; exit 2; fi
echo "セッション: $SESSION(会話 id は出さない)"

echo
echo "=== 3. 送る前の転写の行数 ==="
BEFORE="$(ssh "$SSH_HOST" "node $REMOTE_TOOLS/disposable-session.mjs lines '$SID'" 2>/dev/null || echo 0)"
BEFORE="${BEFORE:-0}"
echo "before = $BEFORE 行"

echo
echo "=== 4. 電話のコードで送る ==="
# 本文は一意にする(転写の増分が**この送信の物**だと言える様に)。id は混ぜない。
BODY="rc-live-send probe $(date +%Y%m%d-%H%M%S) —— 返事は要りません"
KEY="$(ssh "$SSH_HOST" 'cat ~/.rc-backend/api.key')" || { echo "鍵が読めない"; exit 2; }
[ -n "$KEY" ] || { echo "鍵が空"; exit 2; }
OUT="$(printf '%s\n%s\n%s\n%s\n' "$URL" "$SID" "$KEY" "$BODY" | "$BIN" 2>&1)"
RC=$?
KEY=""
printf '%s\n' "$OUT" | sed "s#$SID#<会話 id>#g"
echo "終了コード = $RC"

echo
echo "=== 5. 送った本文が転写に着いたか(サーバの言い分ではなく、file を数える) ==="
# ★行数の増分**では足りない**。使い捨ての会話は転写が無い所から始まるので、
#   「0 → 7 行」には起動そのものが書いた行が混ざる。増えた事は「私の本文が着いた事」を
#   意味しない。だから一意な本文そのものを数える(件数だけが返る)。
AFTER="$BEFORE"
HITS=0
for _ in $(seq 1 20); do
  sleep 3
  AFTER="$(ssh "$SSH_HOST" "node $REMOTE_TOOLS/disposable-session.mjs lines '$SID'" 2>/dev/null || echo 0)"
  AFTER="${AFTER:-0}"
  HITS="$(ssh "$SSH_HOST" "node $REMOTE_TOOLS/disposable-session.mjs contains '$SID' '$BODY'" 2>/dev/null || echo 0)"
  HITS="${HITS:-0}"
  [ "$HITS" -gt 0 ] && break
done
echo "行数 = $AFTER(送る前 $BEFORE) / 本文の一致 = $HITS 件"
# ★陰性対照。数える口が壊れて「いつでも1件以上」を返すなら、上の ok は何も測っていない。
#   送っていない本文が 0 件で返る事を、同じ口で確かめる。
DECOY="rc-live-send decoy $(date +%Y%m%d-%H%M%S)-not-sent"
MISS="$(ssh "$SSH_HOST" "node $REMOTE_TOOLS/disposable-session.mjs contains '$SID' '$DECOY'" 2>/dev/null || echo -1)"
echo "陰性対照(送っていない本文)= $MISS 件"

echo
echo "=== 判定 ==="
FAIL=0
if [ "$RC" = "0" ]; then echo "  ok  : 電話のコードが display を受け取った"; else echo "  NG  : display が届いていない(終了コード $RC)"; FAIL=1; fi
if printf '%s' "$OUT" | grep -q "kind=ok"; then echo "  ok  : kind=ok"; else echo "  NG  : kind が ok ではない"; FAIL=1; fi
if printf '%s' "$OUT" | grep -q "keepText=false"; then echo "  ok  : keepText=false(= サーバは verified と言っている)"; else echo "  NG  : keepText が false ではない"; FAIL=1; fi
if [ "$HITS" -gt 0 ]; then echo "  ok  : 送った本文が転写に $HITS 件 居る(行数は $BEFORE → $AFTER)"; else echo "  NG  : 送った本文が転写に居ない(サーバの verified と実物が食い違う)"; FAIL=1; fi
if [ "$MISS" = "0" ]; then echo "  ok  : 陰性対照 0 件(数える口は生きている)"; else echo "  NG  : 陰性対照が $MISS 件(上の一致は測定になっていない)"; FAIL=1; fi
if [ "$FAIL" = "0" ]; then VERDICT_OK=1; echo "→ DoD 9行目: 観測で閉じた"; else echo "→ DoD 9行目: 閉じていない"; fi
exit "$FAIL"
