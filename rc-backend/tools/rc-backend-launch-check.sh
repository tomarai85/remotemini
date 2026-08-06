#!/bin/bash
# controls-for: tools/rc-backend-launch.sh tools/serve-decision.sh
# rc-backend-launch-check.sh — 起動ラッパ(rc-backend-launch.sh)を**実際に走らせて**測る。
#
# ★宣言が2本なのは、下の「何を偽物にしているか」に `serve-decision.sh の判定` が
#   **本物のまま**と書いてあるから。判定を直せば此処も一緒に動く = 見張る対象は2つ。
#   2026-08-07 まで宣言が無く、起動ラッパを直す commit は対照を1本も回していなかった。
#   実測 4 秒。
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

# ★RC_LAUNCH_CHECK_PROBE は下の O が**自分を子として回す時だけ**立てる印で、その時は
#   必ず LAUNCH_SRC(守りを外した写し)も一緒に渡る。片方だけ立っているのは外の環境から
#   紛れ込んだ印 —— そのまま走ると **O/P を黙って飛ばしたまま「全部 OK」と言う**。
#   配備は `ssh edith "... tools/rc-backend-launch-check.sh"` で回すので、環境変数は
#   素通しで入り得る(Codex 指摘 2026-08-04)。緑に倒れる抜け道なので落とす方に倒す。
#   ここが効いている事は下の Q が毎回測る。
if [ "${RC_LAUNCH_CHECK_PROBE:-0}" = 1 ] && [ -z "${LAUNCH_SRC:-}" ]; then
    echo "RC_LAUNCH_CHECK_PROBE が外から入っている(LAUNCH_SRC が無い)= 陰性対照を飛ばす形。走らない" >&2
    exit 2
fi

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

# 配備中の印。**必ず砂場の中を見せる**(既定値は edith の実物なので、edith 上でこの検査を
# 回した時に本物の配備の印を読んでしまう = 検査の答えが本番の状態で変わる)。
MARK_F="$S/deploy-in-progress"

reset_state() {
    printf '%s' 0 > "$S/serve-calls"
    printf '%s' 0 > "$S/serve-rc"
    rm -f "$S/applied" "$S/serve-err" "$MARK_F" "$S"/serve-out-* 2>/dev/null
    cp "$HERE/serve-decision.sh" "$T/app/tools/serve-decision.sh"
}

# ラッパを走らせて stdout+stderr を返す。TS を消したい時は TS_GONE=1。
# ★LAUNCH_SRC は陰性対照(O)専用の口 —— 守りを外した写しを噛ませる為だけに在る。
#   運用経路では常に既定(= 本物の起動ラッパ)が効く。
launch() {
    local ts="$T/bin/tailscale"
    [ "${TS_GONE:-0}" = 1 ] && ts="$T/bin/does-not-exist"
    RC_NODE_BIN="$T/bin/node" \
    RC_APP_DIR="$T/app" \
    RC_TAILSCALE_BIN="$ts" \
    RC_LOG_DIR="$T/logs" \
    RC_KEY_FILE="$T/state/api.key" \
    RC_DEPLOY_MARK="$MARK_F" \
    RC_DEPLOY_MARK_MAX_S="${MARK_MAX_OVERRIDE:-180}" \
    RC_PORT="${PORT_OVERRIDE:-8787}" \
        /bin/bash "${LAUNCH_SRC:-$SRC}" 2>&1
}

has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# ok/★ を1行で判定する。`want` が in / notin を切り替える。
expect() { # <番号> <説明> <in|notin> <部分文字列> <本文>
    if [ "$3" = in ]; then has "$4" "$5" && r=0 || r=1; else has "$4" "$5" && r=1 || r=0; fi
    if [ "$r" = 0 ]; then
        printf '  %-4s %s\n' "$1" "$2"
    else
        printf '  %-4s %s\n       ★外れた(%s 「%s」)\n' "$1" "$2" "$3" "$4"; fail=1
        # ★子として回された時(下の O)だけ、倒れた番号を機械が読める形で1行出す。
        #   人向けの表示を parse させると、文言を変えた日に陰性対照が黙って壊れる。
        if [ "${RC_LAUNCH_CHECK_PROBE:-0}" = 1 ]; then printf 'PROBE-NG %s\n' "$1"; fi
    fi
}

# 完全一致で見る版(番号の集合 / path の突き合わせ用)。部分一致だと
# 「余分に倒れた番号」を見逃すので、O/P はこちらを使う。
expect_eq() { # <番号> <説明> <期待> <実際>
    if [ "$3" = "$4" ]; then
        printf '  %-4s %s\n' "$1" "$2"
    else
        printf '  %-4s %s\n       ★外れた(期待「%s」/ 実際「%s」)\n' "$1" "$2" "$3" "$4"; fail=1
        # ★expect と**同じ**機械行を出す。片方だけ出さないと、将来 L/M の近くに
        #   expect_eq の場面を足した日に、その赤が O の集合から静かに落ちる。
        if [ "${RC_LAUNCH_CHECK_PROBE:-0}" = 1 ]; then printf 'PROBE-NG %s\n' "$1"; fi
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

# --- L/M/N: 配備中の印(2026-08-03 追加) -------------------------------------
# この分岐は `tools/deploy-to-edith.sh` が本番の木を書き換えている窓で launchd が
# node を起こさない為に在る。守る対象が「版の混ざった木で**起動に成功してしまう**」
# という一番診断しにくい壊れ方なので、読んで正しそうでは置けない。3 通り全部駆動する。

# --- L: 新しい印が在る -> 起動しない -----------------------------------------
# ★443 を**空**にしておく(= 印が無ければ serve を撃つ状況)。`$MINE` だと元々撃たない
#   場面なので、L3 が「守りが効いた」と「そもそも撃つ場面ではない」を区別できない。
#   守りを外した写しで駆動して確かめた(2026-08-03): `$MINE` だと L3 は緑のまま、
#   `{}` にすると赤くなる = ここで初めて対照になる。
#   ★その実験は**下の O が毎回やり直す**(2026-08-04)。此処に書いてあるだけの間は、
#     この分岐が壊れた日に誰も気付けなかった —— 根拠がコメント1行しか無かった。
reset_state; printf '%s' '{}' > "$S/serve-out-1"
date +%s > "$MARK_F"
out=$(launch); rc=$?
expect L  "新しい印 -> 起動しないと言う"           in  "起動しない"                "$out"
expect L2 "★陰性対照: node を起こしていない"       notin "NODE-EXEC"               "$out"
expect L3 "★陰性対照: serve も撃っていない"        in  "0"                         "$(applied_count)"
expect L4 "…exit 0(launchd の再試行に任せる)"      in  "0"                         "$rc"

# --- M: 古い印 -> 無視して起動する -------------------------------------------
# ★fail-closed が**恒久的な停止**にならない事の対照。配備台本が途中で落ちて印が残った時、
#   ここが無いと「サービスが二度と上がらない」になる。mtime の算術ごと駆動する為に
#   既定の 180 秒のまま、印を 2020 年の日付にする(閾値を 0 に下げて通すのは検査ではない)。
reset_state; printf '%s' "$MINE" > "$S/serve-out-1"
: > "$MARK_F"; touch -t 202001010000 "$MARK_F"
out=$(launch)
expect M  "古い印 -> 無視して起動すると言う"       in  "印を無視して起動する"      "$out"
expect M2 "…node まで到達する"                     in  "NODE-EXEC src/server.mjs"  "$out"
expect M3 "…黙って無視しない(★を出す)"            in  "★配備中の印が古い"        "$out"

# --- N: 印が無い -> 何も言わない ---------------------------------------------
# ★陰性対照。この分岐が常時発火していたら L/M は意味を持たない。
reset_state; printf '%s' "$MINE" > "$S/serve-out-1"
out=$(launch)
expect N  "★陰性対照: 印が無ければ印の話をしない"  notin "配備中の印"              "$out"
expect N2 "…node まで到達する"                     in  "NODE-EXEC src/server.mjs"  "$out"

# --- O/P: 対照そのものを測る(親の実行でだけ回す) ------------------------------
# ★子(RC_LAUNCH_CHECK_PROBE=1)では回さない。子の役目は「守りを外したら L/M が倒れるか」を
#   測る事だけで、此処を二度回すと O3 の集合に自分自身の結果が混ざる。
if [ "${RC_LAUNCH_CHECK_PROBE:-0}" != 1 ]; then

echo
echo "=== O: 守りを外した写しで倒れる番号(陰性対照) ==="
# なぜ要るか:
#   L/M/N が「守りが効いている」と言える根拠は、**守りを外したら赤くなる**事だけ。
#   それを 2026-08-03 に人が手で1回やって、rc-backend-launch.sh の「配備中は起動しない」の
#   節と、上の L の見出しに**コメントで**書いた。コメントは走らない = 分岐が壊れた日に
#   誰も気付けない。★実際この直後に気付いた: 根拠として書いた行番号は、同じ file に
#   数行足しただけでずれた(no-linerefs の検査が捕まえた)。写しは黙って腐る。
#
# 壊し方: 守りの if の**条件だけ**を false に倒した写しを作る(印を一度も読まない
#   = 守りを入れる前の姿)。行ごと消すのではなく条件を倒すので、構文は必ず生きたまま。
#   ★行の比較は awk の完全一致でやる。sed の型が当たらないと**壊していない木**で
#     対照を回して当然の緑を得る —— それは測定ではない。当たった事を O1/O2 で先に測る。
#
# 測り方: この検査自身を LAUNCH_SRC=<写し> で子として丸ごと回し、倒れた番号を集める。
#   「suite が赤い」では足りない —— A〜K・L4・M2・N が**緑のまま**である事まで見て
#   初めて「巻き添えではなく狙った欠陥を測っている」と言える。だから完全一致で見る。
BROKEN="$T/broken-launch.sh"
GUARD='if [ -f "$MARK" ]; then'

# grep -c は 0 件でも 0 を印字してから 1 を返すので、|| で足さない事(足すと "0\n0" になる)。
n_before=$(/usr/bin/grep -F -x -c "$GUARD" "$SRC" 2>/dev/null)
[ -n "$n_before" ] || n_before=0
expect_eq O1 "★空振り防止1: 壊す先が実在して 1 箇所だけ" "1" "$n_before"

/usr/bin/awk -v g="$GUARD" '$0==g{print "if false; then  # ★守りを外した写し(O 専用)"; next} {print}' \
    "$SRC" > "$BROKEN"
n_after=$(/usr/bin/grep -F -x -c "$GUARD" "$BROKEN" 2>/dev/null)
[ -n "$n_after" ] || n_after=0
# ★O2 だけでは空振りを捕まえられない(実測 2026-08-04): 存在しない行を的にすると
#   「写しにも無い」で O2 は緑のまま通る。**居ない事を消した証明にしない**為に、
#   実在と一意を先に見る O1 と対にして初めて空振り防止になる。片方だけ消さない事。
expect_eq O2 "★空振り防止2: 写しから守りの条件が本当に消えた" "0" "$n_after"

# ★O1+O2 は「的が在って、消えた」までしか言わない —— **写しが健全である事は言わない**
#   (Codex 指摘 2026-08-04)。awk が途中で落ちて空 file や切り詰めになっても O2 は緑。
#   その写しで L/M が倒れても、倒したのは守りの欠損ではなく台本の破損になる。
#   1 行の置換なら差分は「消えた 1 行 + 足した 1 行」= ちょうど 2 行。
d_changed=$(/usr/bin/diff "$SRC" "$BROKEN" | /usr/bin/grep -c '^[<>]' 2>/dev/null)
[ -n "$d_changed" ] || d_changed=0
expect_eq O3 "★空振り防止3: 写しの差分はその 1 行の置換だけ" "2" "$d_changed"

SELF="$HERE/$(/usr/bin/basename "${BASH_SOURCE[0]}")"
expect_eq O4 "自分自身を子として回せる(path が引ける)" "yes" \
    "$([ -f "$SELF" ] && echo yes || echo no)"

# 子を待つのは無限ではない。配備は ssh 越しにこの検査を回すので、子が固まると
# **配備そのものが止まる**(Codex 指摘 2026-08-04)。上限で落として赤にする。
# ★この上限の分岐は毎回は測っていない —— ただし倒れ方が緑ではなく赤(出力が空 =
#   O5/O6 が外れる)なので、黙って通る形にはならない。手で確かめる時は
#   RC_LAUNCH_CHECK_PROBE_MAX_S=0 を渡す。
PROBE_MAX_S="${RC_LAUNCH_CHECK_PROBE_MAX_S:-120}"
probe_log="$T/probe.out"
RC_LAUNCH_CHECK_PROBE=1 LAUNCH_SRC="$BROKEN" /bin/bash "$SELF" >"$probe_log" 2>&1 &
probe_pid=$!
waited=0
while /bin/kill -0 "$probe_pid" 2>/dev/null && [ "$waited" -lt "$PROBE_MAX_S" ]; do
    /bin/sleep 1; waited=$((waited + 1))
done
if /bin/kill -0 "$probe_pid" 2>/dev/null; then
    /bin/kill "$probe_pid" 2>/dev/null
    echo "  ★子の検査が ${PROBE_MAX_S} 秒で終わらなかったので落とした" >&2
fi
wait "$probe_pid" 2>/dev/null
probe_out=$(/bin/cat "$probe_log" 2>/dev/null)
# ★並べ替えてから比べる(Codex 指摘 2026-08-04)。同じ番号の集合なのに**実行順を
#   変えただけ**で赤くなるのは要らない脆さ。集合が変わった時だけ赤くする。
#   番号の形も絞る —— 万一ラッパの出力が `PROBE-NG …` に化けても混ざらない様に。
probe_ng=$(printf '%s\n' "$probe_out" \
    | /usr/bin/awk '/^PROBE-NG [A-Z][0-9]*$/{print $2}' | /usr/bin/sort | /usr/bin/tr '\n' ' ')
expect_eq O5 "倒れたのは L L2 L3 M M3 だけ(巻き添えが無い)" "L L2 L3 M M3 " "$probe_ng"

# ★O6 の値打ちは「番号ゼロを緑と読み違えない」事**ではない**(Codex 指摘 2026-08-04:
#   期待集合が空でないので、番号ゼロは O5 が既に赤にする)。ここが見ているのは
#   **子が最後まで走って正式な集計行を出した**事 —— 途中で死んだ子は番号が足りない
#   形で落ちるので、O5 の赤の意味が「巻き添え」なのか「中断」なのか区別が付く。
expect O6 "…子が最後まで走って集計行を出した" in "★外れが在る" "$probe_out"

echo
echo "=== P: 印の置き場が書く側と読む側で一致している ==="
# 書く側 (tools/deploy-to-edith.sh) と読む側 (tools/rc-backend-launch.sh) は**別々に**
# 既定値を持っている。片方だけ動かすと、印は毎回立つのに守りは一度も効かない ——
# しかも両方の検査は緑のまま(見ている file が違うだけで、各々は正しく動く)。
# 合っている根拠が deploy 側の「既定値は…と一致していなければならない」というコメント
# だけだったので、ここで文字列として突き合わせる。
# ★言わない事: edith の disk で実際にその path が使われている事は測っていない(既定値
#   どうしの一致だけ)。実物を見るのは tools/verify-rc-backend-state.sh の仕事。
DEP="$HERE/deploy-to-edith.sh"
if [ -f "$DEP" ]; then
    d_line=$(/usr/bin/grep -m1 -F 'MARK="${RC_DEPLOY_MARK:-' "$DEP")
    l_line=$(/usr/bin/grep -m1 -F 'MARK="${RC_DEPLOY_MARK:-' "$SRC")
    # ★1 行ずつ在る事まで見る(Codex 指摘 2026-08-04)。「在る」だけだと、後から
    #   2 行目の代入が足された時に -m1 が拾う 1 行目だけを比べて緑のまま通る。
    d_n=$(/usr/bin/grep -F -c 'MARK="${RC_DEPLOY_MARK:-' "$DEP" 2>/dev/null)
    [ -n "$d_n" ] || d_n=0
    l_n=$(/usr/bin/grep -F -c 'MARK="${RC_DEPLOY_MARK:-' "$SRC" 2>/dev/null)
    [ -n "$l_n" ] || l_n=0
    expect_eq P1 "既定値の行が書く側・読む側に 1 行ずつ在る" "1 1" "$d_n $l_n"
    expect_eq P2 "印の置き場の既定値が一致(期待=読む側 / 実際=書く側)" "$l_line" "$d_line"
else
    expect_eq P1 "配備台本が読める(無ければ突き合わせ自体が成立しない)" "yes" "no"
fi

echo
echo "=== Q: 陰性対照を飛ばす印が外から入ったら走らない ==="
# 新しい門を足したら、まずそれを落とす手を書く。この検査の O/P は
# RC_LAUNCH_CHECK_PROBE が立っていると丸ごと飛ぶ = **緑に倒れる抜け道**。
# 配備は ssh 越しにこの検査を回すので、環境から素通しで入り得る。
# 上の fail-closed が本当に効いている事をここで毎回測る。
q_out=$(RC_LAUNCH_CHECK_PROBE=1 /bin/bash "$SELF" 2>&1); q_rc=$?
expect_eq Q1 "外から印だけ立っていたら止まる(黙って O/P を飛ばさない)" "2" "$q_rc"
expect Q2 "…止めた理由を名指しする" in "陰性対照を飛ばす形" "$q_out"

fi

echo
if [ "$fail" = 0 ]; then echo "全部 OK"; else echo "★外れが在る"; fi
exit "$fail"
