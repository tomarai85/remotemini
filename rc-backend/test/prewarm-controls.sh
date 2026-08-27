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
#
# ★本数を 40 から 12000(本番 ~10,300 と同規模)へ増やした(2026-08-27、Codex の指摘の後)。40 本だと温めが一瞬で
#   終わるので、**塞ぐ版と譲る版の区別が付かない** —— 窓が無い検査は、その性質について
#   何も言っていない。実測: 12000 本で塞ぐ版は 185ms 止まり、譲る版は 12ms(15倍差)。
"$NODE" -e '
const fs = require("fs"), path = require("path");
const dir = process.argv[1];
for (let i = 0; i < 12000; i++) {
  const ep = i % 8 === 0 ? "cli" : "sdk-cli";
  const id = String(i).padStart(8, "0") + "-0000-0000-0000-000000000000";
  fs.writeFileSync(path.join(dir, id + ".jsonl"),
    JSON.stringify({ entrypoint: ep, cwd: "/sb/work", type: "user",
                     message: { role: "user", content: "q" + i } }) + "\n");
}' "$SB/projects/-sb-work"

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

# ── 温めが**他の要求を止めない**か ────────────────────────────────────────
# ★2026-08-27、Codex の指摘で足した。第1版の温めは `scanSessions()` を1回呼ぶだけで、
#   走査が全部同期なので**ポートが開いた後にイベントループが止まっていた**
#   (friday 実測: 窓に投げた healthz が 483ms 待たされた)。速さではなく
#   「止めないか」を測る検査が無いと、この退行は緑のまま戻って来る。
blocked_ms(){
  # ★1つの `local` にまとめない(bash 3.2 の宣言内可視性。この台本で3度目に踏んだ)。
  local src="$1"
  local log="$SB/blk-$(basename "$src").log"
  local port=""
  RC_PORT=0 RC_BIND=127.0.0.1 \
  RC_PROJECTS_DIR="$SB/projects" RC_KEY_DIR="$SB/keys" RC_ATTACH_DIR="$SB/attach" \
  "$NODE" "$src/server.mjs" > "$log" 2>&1 &
  local pid=$!
  local n=0
  while [ "$n" -lt 200 ]; do
    port="$(grep -o 'listening on http://127.0.0.1:[0-9]*' "$log" 2>/dev/null | head -1 | sed 's/.*://')"
    [ -n "$port" ] && break
    sleep 0.05; n=$((n+1))
  done
  if [ -z "$port" ]; then echo "NOPORT"; kill -9 "$pid" 2>/dev/null; return; fi
  # listen 直後 = 温めの真っ最中に投げる。
  local t; t="$(curl -s -o /dev/null -w "%{time_total}" --max-time 20 "http://127.0.0.1:$port/healthz")"
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "$t"
}

T_NEW="$(blocked_ms "$ROOT/src")"
echo "  温めの最中の healthz: 本物=${T_NEW}s"
if [ "$(awk -v v="$T_NEW" 'BEGIN{print (v<0.08)?1:0}')" = "1" ]; then
  ok "温めの最中でも他の要求が即返る(小分けにして事象ループへ譲っている)"
else
  bad "非閉塞" "healthz が ${T_NEW}s 待たされた = 温めがイベントループを塞いでいる"
fi

# 陰性対照: 小分けをやめる(1 slice で全部やる = 第1版と同じ塞ぎ方)
MUT="$SB/mutant-src"; mkdir -p "$MUT"; cp -R "$ROOT/src/." "$MUT/"
if /usr/bin/sed -i "" 's/const SLICE = 400;/const SLICE = 100000000;/' "$MUT/server.mjs" \
   && grep -q "const SLICE = 100000000;" "$MUT/server.mjs"; then
  T_OLD="$(blocked_ms "$MUT")"
  echo "  温めの最中の healthz: 塞ぐ版=${T_OLD}s"
  # ★絶対値ではなく**比**で見る。機械の速さでどちらも一様に縮むので、
  #   絶対の閾値は速い機械で偽陰性、遅い機械で偽陽性になる。
  if [ "$(awk -v o="$T_OLD" -v n="$T_NEW" 'BEGIN{print (o >= 3*n && o >= 0.05)?1:0}')" = "1" ]; then
    ok "小分けをやめると待たされる(${T_OLD}s vs 本物 ${T_NEW}s = 3倍以上) — 非閉塞の対照は効いている"
  else
    bad "非閉塞の陰性対照" "小分けをやめても差が出ない(塞ぐ版 ${T_OLD}s / 本物 ${T_NEW}s) = この検査は何も測っていない"
  fi
else
  bad "非閉塞の陰性対照" "変異(SLICE を巨大化)を当てられなかった"
fi

echo "PREWARM-CONTROLS: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
