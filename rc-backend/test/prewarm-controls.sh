#!/bin/bash
# controls-for: src/server.mjs src/listing.mjs
# prewarm-controls.sh — 起動直後の1発目が**冷えていない**事を、実際にサーバを起こして測る。
#
# ★なぜ単体では測れないか: 温めは `server.listen` の callback に在る。純関数として
#   取り出せる部分が無いので、「起動して1発目を撃つ」以外にこの性質を測る方法が無い。
#
# ★陰性対照を同じ台本の中に持つ: `RC_PREWARM=0` で起こした時に**赤にならなければ**、
#   この検査は何も測っていない。緑と赤を1回ずつ取って初めて「効いている」と言える
#   (2026-08-27、上限4000のキャッシュが本番で 0% のまま全検査が緑だった件の教訓)。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NODE="${NODE_BIN:-/opt/homebrew/bin/node}"
PASS=0; FAIL=0
ok(){ printf '  \033[32mgreen\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mRED\033[0m    %s -- %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/projects/-sb-work" "$SB/keys" "$SB/attach"

# 走査対象。中身は本物と同じ形(1行1 JSON、`entrypoint` が末尾側に在る)。
# 電話に出るのは `cli` だけなので、出す物と出さない物の両方を置く。
i=0
while [ "$i" -lt 40 ]; do
  if [ $((i % 8)) -eq 0 ]; then EP="cli"; else EP="sdk-cli"; fi
  printf '{"entrypoint":"%s","cwd":"/sb/work","type":"user","message":{"role":"user","content":"q%s"}}\n' \
    "$EP" "$i" > "$SB/projects/-sb-work/0000000$(printf '%04d' $i)-0000-0000-0000-000000000000.jsonl"
  i=$((i+1))
done

# 起動して、1発目の `/api/sessions` の `read` を返す。$1 = RC_PREWARM の値。
first_read(){
  # ★1つの `local` にまとめない。bash 3.2(macOS の /bin/bash)は同じ宣言の中で
  #   先に代入した変数を後続の初期化子から見せない事が在り、`set -u` と組むと
  #   「unbound variable」で落ちる(2026-08-27 に実際に踏んだ)。
  local prewarm="$1"
  local log="$SB/server-$prewarm.log"
  local port=""
  RC_PORT=0 RC_BIND=127.0.0.1 \
  RC_PROJECTS_DIR="$SB/projects" RC_KEY_DIR="$SB/keys" RC_ATTACH_DIR="$SB/attach" \
  RC_PREWARM="$prewarm" \
  "$NODE" "$ROOT/src/server.mjs" > "$log" 2>&1 &
  local pid=$!
  # 実際に bind した番号をログから取る(RC_PORT=0 で頼んでいるので設定値は使えない)
  local n=0
  while [ "$n" -lt 60 ]; do
    port="$(grep -o 'listening on http://127.0.0.1:[0-9]*' "$log" 2>/dev/null | head -1 | sed 's/.*://')"
    [ -n "$port" ] && break
    sleep 0.25; n=$((n+1))
  done
  if [ -z "${port:-}" ]; then echo "NOPORT"; kill -9 "$pid" 2>/dev/null; return; fi
  # ★温めは非同期なので、**その完了を待ってから**1発目を撃つ。待たずに撃つと
  #   「温めが間に合わなかっただけ」を「温めが無い」と読む(競走で赤くなる検査)。
  if [ "$prewarm" != "0" ]; then
    n=0
    while [ "$n" -lt 80 ]; do
      grep -q "一覧を先に温めた" "$log" && break
      sleep 0.25; n=$((n+1))
    done
  fi
  local key; key="$(cat "$SB/keys/api.key" 2>/dev/null)"
  local body; body="$(curl -s -H "Authorization: Bearer $key" "http://127.0.0.1:$port/api/sessions")"
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(j.scan&&j.scan.read!=null?j.scan.read:"NOSCAN")}catch{console.log("BADJSON")}})' <<< "$body"
}

echo "prewarm controls (実際にサーバを起こして測る)"
WARM="$(first_read 1)"
COLD="$(first_read 0)"
echo "  1発目の read: 温めあり=$WARM / 温めなし(陰性対照)=$COLD"

case "$WARM" in
  0) ok "温めありなら1発目は1本も読まない(read=0)";;
  NOPORT|NOSCAN|BADJSON) bad "温めあり" "サーバが起きない/応答が読めない ($WARM)";;
  *) bad "温めあり" "1発目が $WARM 本読んだ = 温めが効いていない";;
esac

case "$COLD" in
  0) bad "陰性対照" "温めを切っても read=0 = この検査は何も測っていない";;
  NOPORT|NOSCAN|BADJSON) bad "陰性対照" "サーバが起きない/応答が読めない ($COLD)";;
  *) ok "温めを切ると1発目が読む(=$COLD 本) — 対照は効いている";;
esac

echo "PREWARM-CONTROLS: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
