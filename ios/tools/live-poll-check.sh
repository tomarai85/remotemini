#!/bin/bash
# controls-for: ios/Sources/Core/PollClient.swift ios/Sources/Core/ReadablePoll.swift
#
# live-poll-check.sh — 電話の**受け取り**(`PollClient`)を、本物の rc-backend に当てる。
# ★名前が被覆を誇張しない様に、測る範囲を最初に書く(Codex 2026-08-27:「初回 poll の検査で
#   あって、状態を持つ受け取り経路の検査ではない」— その通りだったので2回目を足した)。
# 2026-08-27 新設。`live-send-check.sh` / `live-interrupt-check.sh` と同じ型。
#
# ★なぜ要るか: 電話の主要な経路のうち、読み・書き・割り込みは本番へ当てた事が在るのに、
#   **受け取りだけ一度も無かった**。Tom が Claude の答えを見るのは此の経路で、単体では
#   `MockURLProtocol` としか繋がっていない。
#
# ★測る物と測らない物を先に書く:
#   測る   = ① 使い捨ての本物の会話に対し、電話の `PollClient` が **読める応答**を受け取る事
#            (二段読み `ReadablePoll.check` → 型付き decode を通った物だけが success)。
#            ② **サーバが返した cursor をそのまま撃ち返して、サーバが受け取る事**。
#            ②が無いと「一度は読めるが二度目から進まない」(= 電話が最初の1画面で固まる)が
#            緑のまま通る。①だけなら実質「200 が JSON の形で返る」しか言っていない。
#   測らない = ・「送った物への返事が来る」事(`live-send-check.sh` が転写の行数と本文の
#              一致で押さえている)。
#            ・cursor の**進み方**の正しさ(重複 / 取りこぼし / 並べ替え / 再生)。
#            ・待ち受け中に出力が来た時の起こされ方(long-poll の起床)。
#            ・中身の意味(古い出力 / 別の会話の出力 / 途中で切れた本文)。
#            ★Codex 2026-08-27 が「捕まえられない物」として列挙した物を、そのまま書き写す。
#              **測っていない事を名前の隣に置く**のが、この台本の存在理由の半分。
#
# ★陰性対照を2本持つ。片方だけでは「本物のサーバに当たっているか」が言えない。
#
# 終了コード: 0 = 全部通った / 1 = 測って赤い(直す物が在る) / 2 = 準備段で中断(何も測れていない)
#            3 = 運ぶ層は通ったが相手が答えていない(**利用上限**。直す物は無い、待つ)
#   意味と順序(2 > 1 > 3 > 0)の正本は `rc-backend/tools/exit-codes.mjs`。
#   ★3 が要るのは、上限の日に赤を出すと「製品が壊れた」に見え、**次の本物の赤が
#     読まれなくなる**から。3 は「測れていない」であって「通った」でも「壊れた」でもない。
set -uo pipefail
IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

URL="${RC_LIVE_URL:-https://desk.tailnet.example:9443}"
# ★短い別名を使う(艦隊の他の全経路と同じ)。機体の解決先は ~/.ssh/config の1箇所に閉じ込める。
SSH_HOST="${RC_LIVE_SSH:-athenas}"
REMOTE_TOOLS="${RC_LIVE_REMOTE:-\$HOME/rc-backend/tools}"
# ★相手の node は**実行時に訊く**。path を焼き込むと、機体が変わった日に静かに腐る
#   (2026-08-27 に live-send-check.sh で実際に踏んだ)。
REMOTE_NODE="${RC_LIVE_NODE:-}"
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --host) SSH_HOST="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "usage: $0 [--url URL] [--host SSH] [--keep]" >&2; exit 2 ;;
  esac
done
if [ -z "$REMOTE_NODE" ]; then
  REMOTE_NODE="$(ssh "$SSH_HOST" 'command -v node || ls /opt/homebrew/bin/node 2>/dev/null' 2>/dev/null | head -1)"
fi
if [ -z "$REMOTE_NODE" ]; then
  echo "相手の機械($SSH_HOST)で node が見つからない。RC_LIVE_NODE=/path/to/node で渡せる" >&2
  exit 2
fi

WORK="$(mktemp -d)"
BIN="$WORK/rc-live-poll"
SESSION=""
SID=""
PASS=0; FAIL=0
ok(){ printf '  \033[32mok  \033[0m: %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mNG  \033[0m: %s\n' "$1"; FAIL=$((FAIL+1)); }

cleanup() {
  if [ -n "$SESSION" ] && [ "$KEEP" = "0" ]; then
    echo "--- 畳む ---"
    PURGE=""
    [ "$FAIL" = "0" ] && PURGE=" --purge-transcript"
    [ "$FAIL" = "0" ] || echo "(判定が緑でないので転写は残す)"
    ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs down '$SESSION' '$SID'$PURGE" 2>&1 |
      sed "s#$SID#<会話 id>#g"
  elif [ -n "$SESSION" ]; then
    echo "--keep: セッションを残した(畳むのは人の手)"
  fi
  /bin/rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== 1. 電話側の殻を建てる(製品の Swift をそのまま使う) ==="
swiftc -O -o "$BIN" \
  "$IOS_DIR/tools/live-poll-main.swift" \
  "$IOS_DIR/Sources/Core/PollClient.swift" \
  "$IOS_DIR/Sources/Core/PollCursor.swift" \
  "$IOS_DIR/Sources/Core/ReadablePoll.swift" \
  "$IOS_DIR/Sources/Core/PollModels.swift" \
  "$IOS_DIR/Sources/Core/HistoryModels.swift" \
  "$IOS_DIR/Sources/Core/ResultDisplay.swift" \
  "$IOS_DIR/Sources/Core/BackendSession.swift" 2>&1 | tail -20 || { echo "swiftc が通らない"; exit 2; }
[ -x "$BIN" ] || { echo "swiftc が通らない(束が出来ていない)"; exit 2; }
echo "ok: $(/usr/bin/stat -f %z "$BIN") bytes"

echo
echo "=== 2. 使い捨ての本物 TUI を建てる ==="
UP="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs up")" || { echo "建たなかった"; exit 2; }
SID="$(printf '%s' "$UP" | tail -1 | tr -d '[:space:]')"
SESSION="$(ssh "$SSH_HOST" "export PATH=/opt/homebrew/bin:\$PATH; tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^rc-e2e-' | tail -1")"
[ -n "$SID" ] || { echo "会話 id が取れない"; exit 2; }
echo "ok: 建った(会話 id は伏せる)"

KEY="$(ssh "$SSH_HOST" 'cat ~/.rc-backend/api.key')" || { echo "鍵が読めない"; exit 2; }

echo
echo "=== 3. 電話のコードで受け取る ==="
OUT="$(printf '%s\n%s\n%s\n' "$URL" "$SID" "$KEY" | "$BIN")"; RC=$?
echo "$OUT"
echo "終了コード = $RC"
# ★判定は**2回目まで**を要求する。`outcome=success*` だけで一致させると、
#   1回目が成功して2回目が落ちた行(`outcome=success ... second=<失敗>`)も
#   前方一致で緑になる —— 書いた直後に自分で踏んだ穴。
case "$OUT" in
  *second=success*) ok "電話の PollClient が読める応答を受け取り、**返ってきた cursor でもう一度通った**" ;;
  outcome=success*second=*) bad "1回目は読めたが2回目が落ちた($OUT) = 最初の1画面で固まる形" ;;
  outcome=unreadable*) bad "200 は来たが電話の二段読みが拒んだ(= 見せてよい形ではない)" ;;
  *) bad "受け取れていない($OUT)" ;;
esac

echo
echo "=== 4. 陰性対照A: でたらめな鍵(401 が返ること) ==="
OUT_A="$(printf '%s\n%s\n%s\n' "$URL" "$SID" "not-a-real-key" | "$BIN")"
echo "$OUT_A"
case "$OUT_A" in
  outcome=unauthorized*) ok "でたらめな鍵は 401 = **本物のサーバに当たっている**" ;;
  *) bad "でたらめな鍵が 401 にならない($OUT_A) = 当たっている相手が本物か言えない" ;;
esac

echo
echo "=== 5. 陰性対照B: 居ない会話(404 SESSION_NOT_FOUND が返ること) ==="
OUT_B="$(printf '%s\n%s\n%s\n' "$URL" "00000000-0000-0000-0000-000000000000" "$KEY" | "$BIN")"
echo "$OUT_B"
case "$OUT_B" in
  outcome=sessionNotFound*) ok "居ない会話は 404 を**網の障害と混ぜずに**名乗る" ;;
  outcome=unreachable*) bad "居ない会話が unreachable に化けた(= 人を電波の確認へ走らせる形)" ;;
  *) bad "居ない会話の扱いが想定外($OUT_B)" ;;
esac

echo
echo "=== 6. 相手が上限で答えられない状態か(赤の意味が変わるので判定の前に訊く) ==="
# ★`live-*` の計器は**上限で 3 を返す**のが契約(test/live-exit-codes.test.mjs)。
#   上限の日に赤を出すと「製品が壊れた」に見え、次の本物の赤が読まれなくなる。
#   3 は「測れていない」であって「通った」でも「壊れた」でもない。
LIMITED="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs limited '$SID'" 2>/dev/null || echo "")"
echo "利用上限の告知 = ${LIMITED:-unknown}"

echo
echo "=== 判定 ==="
echo "LIVE-POLL-CHECK: pass=$PASS fail=$FAIL"
if [ "$FAIL" -ne 0 ] && [ "$LIMITED" = "limited" ]; then
  echo "→ 上限で答えられない机だった。**赤の意味が付かない**ので 3(測れていない)で降りる"
  exit 3
fi
[ "$FAIL" -eq 0 ]
