#!/usr/bin/env bash
# controls-for: rc-backend/tools/ota-server.mjs
#
# 此の配信には**認証が無い**(iOS の installd は header を送らない)。だから守っているのは
# 「秘密の一段」「一覧を出さない」「ROOT の外へ出られない」の3つだけで、
# 其の3つが本当に効いているかを毎回実測する。効いていない配信は、
# Tom の tailnet に居る全機体(2026-08-28 時点で edith を含む)へ束を開けている事になる。
#
# ★否定の対照を主にする。200 が返る事は必要条件でしかない。
#
# 終了コード: 0=全部緑 / 1=赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/ota-server.mjs"
NODE="${NODE_BIN:-node}"
PORT="${OTA_TEST_PORT:-18799}"

T=$(mktemp -d -t ota-controls)
ROOT="$T/ota"
mkdir -p "$ROOT/s3cret"
printf 'MANIFEST\n' > "$ROOT/s3cret/manifest.plist"
printf 'IPABYTES\n' > "$ROOT/s3cret/RemoteMini.ipa"
printf '<h1>install</h1>\n' > "$ROOT/s3cret/index.html"
# ROOT の**外**に置いた餌。此処が読めたら traversal が通っている。
printf 'TOPSECRET\n' > "$T/outside.txt"
# 接頭辞が同じ別の dir。`startsWith(ROOT)` だけの判定はこれを通してしまう。
mkdir -p "$T/ota-evil"; printf 'EVIL\n' > "$T/ota-evil/x.txt"

PASS=0; FAIL=0
ok() { printf '  OK   %s\n' "$1"; PASS=$((PASS+1)); }
ng() { printf '  NG   %s\n' "$1"; FAIL=$((FAIL+1)); }

OTA_ROOT="$ROOT" OTA_PORT="$PORT" "$NODE" "$SUT" > "$T/server.log" 2>&1 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

for _ in $(seq 1 40); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/s3cret/manifest.plist" && break
    sleep 0.25
done

# ★`--path-as-is` が要る(2026-08-28、嘘の緑を1本掴んで判った)。
#   curl は既定で URL の `..` を**送る前に**畳む。だから `/../outside.txt` は
#   `/outside.txt` になってサーバへ届き、ROOT に無いので 404 —— 守りが1行も
#   効いていなくても緑が出る。実際に守りを素朴な startsWith へ落とす変異を当てても
#   15 本全部緑のままだった。生の `..` を届かせて初めて測っている事になる。
code() { curl -s --path-as-is -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null; }
body() { curl -s --path-as-is --max-time 5 "$@" 2>/dev/null; }

# --- 本体が配れる(必要条件) --------------------------------------------------
[ "$(code "http://127.0.0.1:$PORT/s3cret/manifest.plist")" = "200" ] \
    && ok "manifest が返る" || ng "manifest が返らない"
[ "$(code "http://127.0.0.1:$PORT/s3cret/RemoteMini.ipa")" = "200" ] \
    && ok "束が返る" || ng "束が返らない"
[ "$(code "http://127.0.0.1:$PORT/s3cret/")" = "200" ] \
    && ok "dir を叩くと index.html が出る" || ng "index.html が出ない"

# --- N1 一覧を返さない --------------------------------------------------------
b=$(body "http://127.0.0.1:$PORT/")
if printf '%s' "$b" | grep -q "s3cret"; then
    ng "N1 ROOT が中身を一覧した = 秘密の一段が無意味になる"
else
    ok "N1 ROOT は一覧を返さない"
fi

# --- N2 ROOT の外へ出られない -------------------------------------------------
for p in "/../outside.txt" "/s3cret/../../outside.txt" "/%2e%2e/outside.txt" "/..%2foutside.txt"; do
    b=$(body "http://127.0.0.1:$PORT$p")
    if printf '%s' "$b" | grep -q "TOPSECRET"; then
        ng "N2 traversal が通った: $p"
    else
        ok "N2 traversal を弾く: $p"
    fi
done

# --- N3 接頭辞が同じ隣の dir へ出られない -------------------------------------
# ★`real.startsWith(ROOT)` だけで判定すると此処が通る。区切りまで見ているかの検査。
b=$(body "http://127.0.0.1:$PORT/../ota-evil/x.txt")
if printf '%s' "$b" | grep -q "EVIL"; then
    ng "N3 接頭辞が同じ隣の dir が読めた(ota → ota-evil)"
else
    ok "N3 接頭辞が同じ隣の dir を弾く"
fi

# --- N4 symlink で外へ出られない ----------------------------------------------
ln -s "$T/outside.txt" "$ROOT/s3cret/link.txt" 2>/dev/null || true
b=$(body "http://127.0.0.1:$PORT/s3cret/link.txt")
if printf '%s' "$b" | grep -q "TOPSECRET"; then
    ng "N4 symlink で ROOT の外が読めた"
else
    ok "N4 symlink で外へ出られない"
fi

# --- N5 書き込みの口が無い ----------------------------------------------------
for m in POST PUT DELETE; do
    c=$(code -X "$m" "http://127.0.0.1:$PORT/s3cret/manifest.plist")
    [ "$c" = "405" ] && ok "N5 $m は 405" || ng "N5 $m が $c(405 でない)"
done

# --- N6 外の網に listen していない --------------------------------------------
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -qv "127.0.0.1:$PORT"; then
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -q "\*:$PORT"; then
        ng "N6 全ての面に listen している = tailnet 限定が効かない"
    else
        ok "N6 127.0.0.1 だけに listen"
    fi
else
    ok "N6 127.0.0.1 だけに listen"
fi

# --- 型 -----------------------------------------------------------------------
ct=$(curl -s -o /dev/null -w '%{content_type}' --max-time 5 "http://127.0.0.1:$PORT/s3cret/RemoteMini.ipa")
[ "$ct" = "application/octet-stream" ] && ok "束の型が octet-stream" || ng "束の型が $ct"

echo
echo "ota-server-controls: OK $PASS / NG $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
