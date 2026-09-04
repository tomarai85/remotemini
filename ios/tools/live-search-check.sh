#!/bin/bash
# live-search-check.sh — 探索の当たりから其の行へ跳ぶ道(対照表 #3)を、**製品の Swift と本物の机**で測る。
#
# なぜ要るか(2026-09-03): #3 は机側 e2e(偽 tmux)と電話側 fixture の 2 つで緑になったが、電話 → 実机の鎖は
#   一度も走っていなかった(Codex の後追いレビューでも「実機の測定が無い」)。live-send / live-poll / live-interrupt
#   と同じ形で、電話のコード(HistoryClient)をそのまま compile して friday の本物の会話に当てる。
#
# 測る物(全部 GET。机の状態は変えない):
#   1. 最新の項目の語で探す → 当たりが anchor と fromEnd を持つ
#   2. limit = fromEnd + 1 の履歴に同じ anchor が居る / limit = fromEnd には居ない(1 ずれの対照)
#   3. 当たり得ない語は matched 0(陰性対照)
#
# 終了コード(艦隊の live-* と同じ契約 = rc-backend/test/live-exit-codes.test.mjs):
#   0 = 観測で閉じた / 1 = 赤 / 2 = 準備段で中断(swiftc・鍵)。
#   3 = 測っていない(机に届かない・会話が 0 本)。★利用上限では 3 を**出さない**: この門は GET だけなので
#     上限は赤の説明にならない(送る計器と違う)。上限の告知は訊いて**記録する**だけ。赤を 3 に隠さない。
#
# 使い方: ios/tools/live-search-check.sh [--url URL] [--host SSH_HOST] [--sid 会話id]
#         ios/tools/live-search-check.sh --verdict <rc> <line>   # 判定だけ(対照が撃つ)
# 鍵の扱い: ssh で読んで**変数から標準入力へ流すだけ**。引数・環境・file に出さない(live-send と同じ約束)。
set -uo pipefail
usage() { echo "usage: $0 [--url URL] [--host SSH_HOST] [--sid SESSION_ID] | --verdict <rc> <kind-line>" >&2; }
URL="${RC_LIVE_URL:-https://desk.tailnet.example:9443}"
SSH_HOST="${RC_LIVE_SSH:-athenas}"
REMOTE_TOOLS="${RC_LIVE_REMOTE:-\$HOME/rc-backend/tools}"
REMOTE_NODE="${RC_LIVE_NODE:-}"   # 相手の node は実行時に訊く(path を焼き込むと機体が変わった日に腐る)
SID="${RC_LIVE_SID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --host) SSH_HOST="$2"; shift 2 ;;
    --sid) SID="$2"; shift 2 ;;
    --verdict) break ;;
    *) usage; exit 2 ;;
  esac
done

# 判定(純粋。対照 `live-search-check-control.sh` が全通り撃つ): 0 = 閉じた / 1 = 赤 / 3 = 測れていない
search_verdict() {
  local rc="$1" line="${2:-}"
  local fail=0
  case "$line" in
    kind=ok*) echo "  ok  : 電話の HistoryClient が探索の当たり(anchor + fromEnd)を受け取った" ;;
    kind=ng*step=fetch-latest*|kind=ng*step=search*|kind=ng*step=fetch-window*)
      echo "  --  : 机に届いていない(${line#kind=ng }) —— **測っていない**"; return 3 ;;
    kind=ng*) echo "  NG  : $line"; fail=1 ;;
    *) echo "  NG  : 殻の出力が読めない: '$line'(終了コード $rc)"; return 1 ;;
  esac
  case "$line" in *"inWindow=1"*) echo "  ok  : limit = fromEnd + 1 の窓に同じ anchor が居る" ;; *) echo "  NG  : 窓に anchor が居ない(跳びの読み足しが足りない)"; fail=1 ;; esac
  case "$line" in *"shortMiss=1"*) echo "  ok  : limit = fromEnd には居ない(1 ずれの対照)" ;; *) echo "  NG  : 1 本少ない窓に居る = fromEnd が 1 ずれている"; fail=1 ;; esac
  case "$line" in *"neg=0"*) echo "  ok  : 陰性対照 0 件(探索は何でも当てない)" ;; *) echo "  NG  : 陰性対照が 0 件でない"; fail=1 ;; esac
  if [ "$fail" != "0" ] || [ "$rc" != "0" ]; then echo "→ #3 live: 閉じていない"; return 1; fi
  echo "→ #3 live: 観測で閉じた"; return 0
}
if [ "${1:-}" = "--verdict" ]; then shift; search_verdict "$@"; exit $?; fi

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
BIN="$WORK/rc-live-search"
trap '/bin/rm -rf "$WORK"' EXIT

echo "=== 1. 電話側の殻を建てる(製品の Swift をそのまま使う) ==="
swiftc -O -o "$BIN" \
  "$IOS_DIR/tools/live-search-main.swift" \
  "$IOS_DIR/Sources/Core/HistoryClient.swift" \
  "$IOS_DIR/Sources/Core/HistoryModels.swift" \
  "$IOS_DIR/Sources/Core/SessionsClient.swift" \
  "$IOS_DIR/Sources/Core/SessionsModels.swift" \
  "$IOS_DIR/Sources/Core/ResultDisplay.swift" \
  "$IOS_DIR/Sources/Core/BackendSession.swift" || { echo "swiftc が通らない"; exit 2; }

echo
echo "=== 2. 会話を選ぶ(登録簿の一番新しい物。id は出さない) ==="
if [ -z "$SID" ]; then
  SID="$(ssh "$SSH_HOST" 'ls -t ~/.rc-backend/panes/*.json 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed "s/\.json$//"')" || true
fi
[ -n "$SID" ] || { echo "登録簿に会話が無い(机に会話が 0 本)= 測れていない"; exit 3; }

echo
echo "=== 3. 電話のコードで探して跳ぶ ==="
KEY="$(ssh "$SSH_HOST" 'cat ~/.rc-backend/api.key')" || { echo "鍵が読めない"; exit 2; }
[ -n "$KEY" ] || { echo "鍵が空"; exit 2; }
LINE="$(printf '%s\n%s\n%s\n' "$URL" "$SID" "$KEY" | "$BIN" 2>&1 | tail -1)"
RC=${PIPESTATUS[1]:-$?}
KEY=""
echo "殻の出力: $LINE"
echo "終了コード = $RC"
echo
echo "=== 4. 相手が利用上限か(記録のみ。GET の門なので赤は隠さない) ==="
[ -n "$REMOTE_NODE" ] || REMOTE_NODE="$(ssh "$SSH_HOST" 'command -v node || ls /opt/homebrew/bin/node 2>/dev/null' 2>/dev/null | head -1)"
LIMITED="$(ssh "$SSH_HOST" "$REMOTE_NODE $REMOTE_TOOLS/disposable-session.mjs limited '$SID'" 2>/dev/null || echo "")"
echo "利用上限の告知 = ${LIMITED:-unknown}"
echo
echo "=== 5. 判定 ==="
search_verdict "$RC" "$LINE limited=${LIMITED:-unknown}"
