#!/bin/bash
# rc-backend-launch-check.sh — 起動ラッパ(rc-backend-launch.sh)を**実際に走らせて**測る。
#
# なぜ要るのか:
#   このラッパが間違えた時の症状は「edith の上では全部緑、電話からだけ永久に到達できない」。
#   ssh で入って見る限り node は生きていて、検査も通る。**一番気付けない形の壊れ方**なので、
#   「読んで正しそう」で置くのは危険側。ここで偽の tailscale / node を噛ませて駆動する。
#
# 何を偽物にしているか(= この検査が証明しない事):
#   偽物 = tailscale CLI・node・APP dir・ログの置き場。本物のまま = ラッパの分岐・
#   引数の組み立て・ログの文面・serve-decision.sh の判定。
#   つまりここが緑でも「本物の tailscale が同じ JSON を返す」事は証明されない。
#   それは edith 上の `tools/verify-rc-backend-state.sh` の仕事。役割を混ぜない。
#
# 使い方: bash tools/rc-backend-launch-check.sh   (exit 0 = 全部 OK)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/rc-backend-launch.sh"
[ -f "$SRC" ] || { echo "起動ラッパが無い: $SRC" >&2; exit 2; }

T=$(mktemp -d /tmp/rc-launch-check.XXXXXX) || exit 2
# ★`rm -rf` は使わない(この環境の禁止形)。find -delete で深さ優先に消す。
cleanup() { [ -d "$T" ] && find "$T" -mindepth 0 -delete 2>/dev/null; }
trap cleanup EXIT

fail=0
S="$T/state"
mkdir -p "$S" "$T/bin" "$T/logs" "$T/app/tools" "$T/app/src"
cp "$HERE/serve-decision.sh" "$HERE/tailnet-key-expiry.sh" "$T/app/tools/"
: > "$T/app/src/server.mjs"

# --- 偽の tailscale ----------------------------------------------------------
# `serve status` は**呼ばれた回数を数える**。スナップショットを使い回す直しの
# 負の対照(F)はこの数と、回ごとに違う答えを返す事で成り立っている。
cat > "$T/bin/tailscale" <<EOF
#!/bin/bash
S="$S"
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then cat "\$S/status.json"; exit 0; fi
if [ "\${1:-}" = serve ] && [ "\${2:-}" = status ]; then
    n=\$(( \$(cat "\$S/serve-calls") + 1 )); printf '%s' "\$n" > "\$S/serve-calls"
    f="\$S/serve-out-\$n"; [ -f "\$f" ] || f="\$S/serve-out-1"
    cat "\$f"
    [ -f "\$S/serve-err" ] && cat "\$S/serve-err" >&2
    exit "\$(cat "\$S/serve-rc")"
fi
if [ "\${1:-}" = serve ]; then printf '%s\n' "\$*" >> "\$S/applied"; exit 0; fi
exit 0
EOF
chmod +x "$T/bin/tailscale"

cat > "$T/bin/node" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-v" ] && { echo v25.0.0; exit 0; }
echo "NODE-EXEC $*"
EOF
chmod +x "$T/bin/node"

# 鍵の期限は遠い方に倒す(この検査の対象ではないので、警告行で紛れさせない)
printf '%s' '{"BackendState":"Running","Self":{"KeyExpiry":"2027-12-25T00:00:00Z"}}' > "$S/status.json"

reset_state() {
    printf '%s' 0 > "$S/serve-calls"
    printf '%s' 0 > "$S/serve-rc"
    rm -f "$S/applied" "$S/serve-err" "$S"/serve-out-* 2>/dev/null
    cp "$HERE/serve-decision.sh" "$T/app/tools/serve-decision.sh"
}

# ラッパを走らせて stdout+stderr を返す。TS を消したい時は TS_GONE=1。
launch() {
    local ts="$T/bin/tailscale"
    [ "${TS_GONE:-0}" = 1 ] && ts="$T/bin/does-not-exist"
    RC_NODE_BIN="$T/bin/node" \
    RC_APP_DIR="$T/app" \
    RC_TAILSCALE_BIN="$ts" \
    RC_LOG_DIR="$T/logs" \
    RC_KEY_FILE="$T/state/api.key" \
    RC_PORT="${PORT_OVERRIDE:-8787}" \
        /bin/bash "$SRC" 2>&1
}

has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# ok/★ を1行で判定する。`want` が in / notin を切り替える。
expect() { # <番号> <説明> <in|notin> <部分文字列> <本文>
    if [ "$3" = in ]; then has "$4" "$5" && r=0 || r=1; else has "$4" "$5" && r=1 || r=0; fi
    if [ "$r" = 0 ]; then
        printf '  %-4s %s\n' "$1" "$2"
    else
        printf '  %-4s %s\n       ★外れた(%s 「%s」)\n' "$1" "$2" "$3" "$4"; fail=1
    fi
}
applied_count() { [ -f "$S/applied" ] && wc -l < "$S/applied" | tr -d ' ' || echo 0; }

MINE='{"TCP":{"443":{"HTTPS":true}},"Web":{"desk.tailnet.example:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}'
THEIRS='{"TCP":{"443":{"HTTPS":true}},"Web":{"desk.tailnet.example:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}'

echo "=== 起動ラッパ: 分岐ごとの実走 ==="

# --- A: 443 が空 -> 入れる ---------------------------------------------------
reset_state; printf '%s' '{}' > "$S/serve-out-1"
out=$(launch)
expect A "443 が空 -> 入れると言う"                in  "443 は未使用なので入れる" "$out"
expect A2 "…実際に serve を撃っている"             in  "--https=443"               "$(cat "$S/applied" 2>/dev/null)"
expect A3 "…宛先が自分の port"                     in  "http://127.0.0.1:8787"     "$(cat "$S/applied" 2>/dev/null)"
expect A4 "…node まで到達する(途中で死なない)"     in  "NODE-EXEC src/server.mjs"  "$out"

# --- B: 自分の設定 -> 触らない -----------------------------------------------
reset_state; printf '%s' "$MINE" > "$S/serve-out-1"
out=$(launch)
expect B  "自分の設定 -> 触らないと言う"           in  "既に自分に向いている"      "$out"
expect B2 "★陰性対照: serve を撃っていない"        in  "0"                         "$(applied_count)"

# --- C: 他人の設定 -> 上書きしない -------------------------------------------
reset_state; printf '%s' "$THEIRS" > "$S/serve-out-1"
out=$(launch)
expect C  "他人の設定 -> 上書きしないと言う"       in  "自分以外の設定"            "$out"
expect C2 "★陰性対照: serve を撃っていない"        in  "0"                         "$(applied_count)"
expect C3 "…判定した現物をログに載せる"            in  '"Proxy":"http://127.0.0.1:3000"' "$out"

# --- D: status が落ちた -> unknown -------------------------------------------
# ★この分岐が旧版に無かった。旧版は「他人の設定が在る」と言った = 居もしない他人を探させる。
reset_state; : > "$S/serve-out-1"; printf '%s' 1 > "$S/serve-rc"
printf '%s\n' "failed to connect to local tailscaled" > "$S/serve-err"
out=$(launch)
expect D  "読めない -> 読めないと言う"             in  "状態が**読めない**"        "$out"
expect D2 "…status の rc をログに残す"             in  "rc=1"                      "$out"
expect D3 "…stderr を捨てずに残す"                 in  "failed to connect to local tailscaled" "$out"
expect D4 "★陰性対照: serve を撃っていない"        in  "0"                         "$(applied_count)"
expect D5 "★陰性対照: 他人の話にすり替えない"      notin "自分以外の設定"          "$out"

# --- E: 壊れた JSON -> unknown -----------------------------------------------
reset_state; printf '%s' '{"TCP":' > "$S/serve-out-1"
out=$(launch)
expect E  "壊れた JSON -> 読めないと言う"          in  "状態が**読めない**"        "$out"
expect E2 "★陰性対照: serve を撃っていない"        in  "0"                         "$(applied_count)"

# --- F: ★スナップショットを1回だけ取る --------------------------------------
# 旧版は判定用と失敗ログ用で2回 `serve status` を撃っていた。1回目=他人 / 2回目=空 を
# 返す偽物を噛ませると、旧版は「他人の設定が在る」と言いながら現物に `{}` を載せる =
# **後から読んでも辻褄の合わない証拠**が残る。ここはその形を直接殺す為の対照。
reset_state
printf '%s' "$THEIRS" > "$S/serve-out-1"
printf '%s' '{}'      > "$S/serve-out-2"
out=$(launch)
expect F  "status を撃つのは1回だけ"               in  "1"                         "$(cat "$S/serve-calls")"
expect F2 "…載る現物は判定に使った1回目"           in  '"Proxy":"http://127.0.0.1:3000"' "$out"
expect F3 "★陰性対照: 2回目の答えは載らない"       notin '現物: {}'                "$out"

# --- G: 判定台本が壊れている -------------------------------------------------
# 4語のどれでもない物が返った時、これは設定の話ではなく**こちらの不具合**。
# 旧版は `*` で「他人の設定が在る」に落としていた = 自分の bug を他人のせいにする。
reset_state; printf '%s' '{}' > "$S/serve-out-1"
printf '#!/bin/bash\necho banana\n' > "$T/app/tools/serve-decision.sh"
out=$(launch)
expect G  "1語でない -> 台本の不具合として言う"    in  "判定台本が 1 語を返さなかった" "$out"
expect G2 "★陰性対照: serve を撃っていない"        in  "0"                         "$(applied_count)"
expect G3 "★陰性対照: 他人のせいにしない"          notin "自分以外の設定"          "$out"

# --- H: tailscale が無い -----------------------------------------------------
reset_state; printf '%s' '{}' > "$S/serve-out-1"
out=$(TS_GONE=1 launch)
expect H  "tailscale が無い -> そう言う"           in  "到達できない状態で起動する" "$out"
expect H2 "…それでも node は上げる(ssh で診れる)" in  "NODE-EXEC src/server.mjs"  "$out"

# --- I/J: ログの退避 ---------------------------------------------------------
reset_state; printf '%s' "$MINE" > "$S/serve-out-1"
/bin/dd if=/dev/zero of="$T/logs/rc-backend.log" bs=1048576 count=11 2>/dev/null
out=$(launch)
expect I  "10MB 超のログは退避する"                in  "ログを退避した"            "$out"
expect I2 "…退避先が実在する"                      in  "yes" "$([ -f "$T/logs/rc-backend.log.1" ] && echo yes || echo no)"
rm -f "$T/logs/rc-backend.log" "$T/logs/rc-backend.log.1"

reset_state; printf '%s' "$MINE" > "$S/serve-out-1"
printf 'small\n' > "$T/logs/rc-backend.log"
out=$(launch)
expect J  "★陰性対照: 小さいログは退避しない"      notin "ログを退避した"          "$out"

# --- K: port を変えると宛先も変わる ------------------------------------------
# PORT が serve-decision と serve の両方へ通っている事(片方だけ通ると、
# 「自分の設定なのに foreign と判定して撃たない」等の無言の停止になる)。
reset_state; printf '%s' '{}' > "$S/serve-out-1"
out=$(PORT_OVERRIDE=9999 launch)
expect K  "port を変えると宛先も変わる"            in  "http://127.0.0.1:9999"     "$(cat "$S/applied" 2>/dev/null)"

reset_state
printf '%s' '{"TCP":{"443":{"HTTPS":true}},"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}' > "$S/serve-out-1"
out=$(PORT_OVERRIDE=9999 launch)
expect K2 "…その port の既存設定は自分の物と読む"  in  "既に自分に向いている"      "$out"

echo
if [ "$fail" = 0 ]; then echo "全部 OK"; else echo "★外れが在る"; fi
exit "$fail"
