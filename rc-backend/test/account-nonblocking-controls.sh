#!/bin/bash
# controls-for: src/server.mjs
#
# account-nonblocking-controls.sh — 口座の読み取りが**事象ループを止めない**事を実測する。
# 2026-08-27 新設。
#
# ★何故これが要るか(実測が出発点): `fleet-account-cswap.sh` は friday 本番で 1回 180ms。
#   これを `execFileSync` で呼ぶと、その間 Node は他の要求を1つも処理できない ——
#   `healthz` は単独 0.4ms なのに `/api/account` の最中は 164ms(390倍)返らなかった。
#   電話は `/api/account` を**アプリを開くたび・前面へ戻るたび**に `/api/sessions` と
#   同時に撃つので、Tom が開く瞬間ちょうど机が凍る。
#
# ★測るのは「速いか」ではなく「**他を止めないか**」。応答時間だけを見ると、
#   同期でも非同期でも `/api/account` 自身は同じくらいかかるので見分けが付かない。
#   見分けるには**別の要求を同時に投げて、そちらが待たされるか**を見るしかない。
#
# ★陰性対照を同じ台本に持つ: 同期に戻した写しでも緑なら、この検査は何も測っていない。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NODE="${NODE_BIN:-/opt/homebrew/bin/node}"
PASS=0; FAIL=0
ok(){ printf '  \033[32mgreen\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mRED\033[0m    %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/projects/-sb-work" "$SB/keys" "$SB/attach" "$SB/src"

# 遅い口座台本。**本物の 180ms より遅く**しておく: 速いと、塞いでいるのか
# たまたま速いのかを時間で見分けられない。
cat > "$SB/slow-account.sh" <<'SLOW'
#!/bin/bash
sleep 0.4
echo "current: a@example.com"
echo "  a@example.com  [token] *"
SLOW
chmod +x "$SB/slow-account.sh"

# $1 = 使う src ディレクトリ。標準出力に「account の時間 healthz の時間」を返す。
probe(){
  local src="$1"
  local log="$SB/server-$(basename "$src").log"
  local port=""
  RC_PORT=0 RC_BIND=127.0.0.1 \
  RC_PROJECTS_DIR="$SB/projects" RC_KEY_DIR="$SB/keys" RC_ATTACH_DIR="$SB/attach" \
  RC_FLEET_ACCOUNT="$SB/slow-account.sh" RC_PREWARM=0 \
  "$NODE" "$src/server.mjs" > "$log" 2>&1 &
  local pid=$!
  local n=0
  while [ "$n" -lt 60 ]; do
    port="$(grep -o 'listening on http://127.0.0.1:[0-9]*' "$log" 2>/dev/null | head -1 | sed 's/.*://')"
    [ -n "$port" ] && break
    sleep 0.25; n=$((n+1))
  done
  if [ -z "$port" ]; then echo "NOPORT NOPORT"; kill -9 "$pid" 2>/dev/null; return; fi
  local key; key="$(cat "$SB/keys/api.key" 2>/dev/null)"
  # account を投げ、**その最中に** healthz を投げる。healthz は本来 1ms 未満。
  curl -s -o /dev/null -w "%{time_total}" -H "Authorization: Bearer $key" \
      "http://127.0.0.1:$port/api/account" > "$SB/t-account" &
  local acc=$!
  sleep 0.05
  local h; h="$(curl -s -o /dev/null -w "%{time_total}" "http://127.0.0.1:$port/healthz")"
  wait "$acc" 2>/dev/null
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "$(cat "$SB/t-account" 2>/dev/null || echo ERR) $h"
}

echo "account non-blocking controls (遅い口座台本 0.4s で、他の要求が待たされるかを見る)"

read -r A_NEW H_NEW <<<"$(probe "$ROOT/src")"
echo "  本物   : account=${A_NEW}s  healthz(同時)=${H_NEW}s"
# 0.15s は「塞いでいない」と「0.4s 塞いだ」を分ける線。実測は塞がなければ 1ms 未満、
# 塞げば 0.35s 前後になるので、どちら側にも余裕が在る。
if [ "$(awk -v v="$H_NEW" 'BEGIN{print (v<0.15)?1:0}')" = "1" ]; then
  ok "口座を読んでいる最中でも healthz が即返る(事象ループが空いている)"
else
  bad "本物" "healthz が ${H_NEW}s 待たされた = 口座の読みが事象ループを塞いでいる"
fi

# --- 陰性対照: 同期に戻した写し ------------------------------------------
cp -R "$ROOT/src/." "$SB/src/"
python3 - "$SB/src/server.mjs" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = '''async function readFleetAccount() {
  const { stdout } = await execFileAsync(FLEET_ACCOUNT, [], {'''
new = '''function readFleetAccount() {
  const { stdout } = ({ stdout: execFileSync(FLEET_ACCOUNT, [], {'''
if old not in s:
    print("MUTANT-FAIL", file=sys.stderr); raise SystemExit(9)
s = s.replace(old, new, 1)
s = s.replace('''    encoding: "utf8", timeout: FLEET_ACCOUNT_TIMEOUT_MS, killSignal: "SIGKILL",
  });
  return { raw: stdout, parsed: parseFleetAccount(stdout) };''',
'''    encoding: "utf8", timeout: FLEET_ACCOUNT_TIMEOUT_MS, killSignal: "SIGKILL",
  }) });
  return { raw: stdout, parsed: parseFleetAccount(stdout) };''', 1)
s = s.replace("await readFleetAccount()", "readFleetAccount()")
p.write_text(s)
PY
if [ $? -ne 0 ]; then
  bad "陰性対照" "同期へ戻す変異を当てられなかった(実装の綴りが変わった。探し文を付け替える事)"
else
  read -r A_OLD H_OLD <<<"$(probe "$SB/src")"
  echo "  同期版 : account=${A_OLD}s  healthz(同時)=${H_OLD}s"
  if [ "$(awk -v v="$H_OLD" 'BEGIN{print (v>=0.15)?1:0}')" = "1" ]; then
    ok "同期に戻すと healthz が待たされる(${H_OLD}s) — 対照は効いている"
  else
    bad "陰性対照" "同期に戻しても healthz が即返った(${H_OLD}s) = この検査は何も測っていない"
  fi
fi

echo "ACCOUNT-NONBLOCKING-CONTROLS: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
