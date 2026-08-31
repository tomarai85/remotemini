#!/bin/bash
# 走らせる物: `rc-backend/test/delivery-check-controls.sh`(2026-08-31 新設)。
#   偽の ssh / curl / launchctl / PlistBuddy を差して**判定の分岐だけ**を門から測る。
#   ★`no-operator:` の印は其の時に外した —— 対照が出来た後も印が残ると、
#     **回っている物を回っていないと記録する**事になる。
#   本物の机に対しては**人が撃つ**: 配備の直後と「効いている筈なのに効かない」と思った時。
#   其れは門から回せない(生きた机への ssh が要る)。
set -uo pipefail

HOST="${RC_FRIDAY_HOST:-athenas}"
REMOTE_HOME="${RC_REMOTE_HOME:-/Users/athenas}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$REPO/.." && pwd)"

ok=0; ng=0
good() { printf '  OK   %s\n' "$1"; ok=$((ok+1)); }
bad()  { printf '  ★NG  %s — %s\n' "$1" "$2"; ng=$((ng+1)); }

# ★外へ出る道具は**差せる様に**する(2026-08-31)。此の台本は生きた机が要るので
#   門から回せず、其の所為で**判定の分岐が一度も対照に掛かっていなかった** ——
#   実際、時代判定の分岐は 20 分で2回 壊れた(書き忘れ / `date -j` の `-u` 落ち)。
#   偽物を差せれば、机が無くても「どの入力でどの判定に落ちるか」を測れる。
#   ★継ぎ目は**呼び出しの形を変えずに**足す(既定は今までと同じ実物)。
SSH_BIN="${RC_DELIVERY_SSH:-ssh}"
CURL_BIN="${RC_DELIVERY_CURL:-curl}"
LAUNCHCTL_BIN="${RC_DELIVERY_LAUNCHCTL:-launchctl}"
PLISTBUDDY_BIN="${RC_DELIVERY_PLISTBUDDY:-/usr/libexec/PlistBuddy}"
rexec() { "$SSH_BIN" -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$@" 2>/dev/null; }

echo "=== 1. 版が3側で揃っているか(手元 / 本番 / 電話)==="
LOCAL=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")
# ★healthz は**1回だけ**叩いて両方の欄を採る(版と稼働秒)。稼働秒は下の 1b で
#   「其のログ行が今の実装から出た物か」を決めるのに要る。2回叩くと、間に再起動が挟まった時に
#   版と稼働秒が別の走行の物になる。
HEALTH=$("$CURL_BIN" -s --max-time 12 "${RC_TUNNEL_URL:-https://desk.tailnet.example:9443/healthz}" 2>/dev/null || echo "")
LIVE=$(printf '%s' "$HEALTH" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo "?")
UPTIME=$(printf '%s' "$HEALTH" | /usr/bin/python3 -c 'import json,sys;v=json.load(sys.stdin).get("uptime");print(int(v) if isinstance(v,(int,float)) else "")' 2>/dev/null || echo "")
# ★之は「**最後に device 向けに焼いた物**」であって電話ではない(2026-08-31 に訂正)。
#   書くのは `ios/tools/build.sh`(`OUT="$DERIVED/signed"`)で、配布と無関係な
#   ただの開発ビルドでも動く。旧版は此れを `電話=` と印字しており、**手元で焼いた瞬間に
#   「電話が手元と一致」と言う**道具だった —— 電話に何も入れていなくても。
#   同じ日に `ota-freshness-check.sh` の生存検査が同型で偽の DEAD を出しており、
#   `ios/build/signed/` を「配った物 / 電話の物」と読む癖は此の木に2箇所在った。
BAKED=$("$PLISTBUDDY_BIN" -c "Print :RCBuildRev" "$ROOT/ios/build/signed/RemoteMini.app/Info.plist" 2>/dev/null || echo "?")
printf '  手元=%s 本番=%s 直近に焼いた物=%s\n' "$LOCAL" "$LIVE" "$BAKED"
# ★`-dirty` を許さない。汚れた木で焼いた物は、どの commit とも突き合わせられない。
# ★commit が違っても、**机が走らせる file が同じなら**それは「遅れ」ではない
#   (2026-08-31 に実測で踏んだ)。此の行は commit の刻を比べるので、
#   docs・検査・iOS だけの commit を1つ入れた瞬間に赤くなる —— 配備は要らないのに。
#   **常に赤い検査は読まれなくなる**ので、赤の意味を「机が古いコードを走らせている」に絞る。
#   判定は `git diff` に委ねる: 机の刻と手元の間で `rc-backend/src` と
#   `package.json` に差が無ければ、走っている物は今の物。
src_differs() {   # 0=差が在る / 1=無い / 2=判らない
    local from="$1"
    git -C "$ROOT" rev-parse --verify --quiet "$from^{commit}" >/dev/null 2>&1 || return 2
    local n
    n="$(git -C "$ROOT" diff --name-only "$from"..HEAD -- rc-backend/src rc-backend/package.json 2>/dev/null | wc -l | tr -d ' ')"
    case "$n" in ''|*[!0-9]*) return 2 ;; 0) return 1 ;; *) return 0 ;; esac
}
case "$LIVE" in
    *-dirty) bad "本番が汚れた木の版" "$LIVE" ;;
    "$LOCAL") good "本番が手元と一致" ;;
    *)
        src_differs "$LIVE"; case $? in
            1) good "本番は別の commit だが、机が走らせる file は手元と同一($LIVE → $LOCAL は src の外だけ)" ;;
            0) bad "本番が古いコードを走らせている" "$LIVE != $LOCAL で rc-backend/src に差が在る = 配備が要る" ;;
            *) bad "本番の版を突き合わせられない" "$LIVE がこの木に無い(別の機体から配った?)" ;;
        esac ;;
esac

echo "=== 1b. 電話が実際に動かしている版(机の要求ログから)==="
# ★電話の版は**電話が名乗った物**からしか判らない。手元の成果物は電話について何も語らない。
#   材料は rc-backend の要求ログの `client=app` の行(`X-App-Build` → 無ければ UA)。
#   ★比べる相手は HEAD ではなく**配っている版**。電話には配った物しか入りようがない。
APPLOG="${RC_BACKEND_LOG:-$REMOTE_HOME/Library/Logs/rc-backend/rc-backend.log}"
# ★**版を名乗った行**の最後を採る(2026-08-31、実測で踏んだ)。
#   単に最後の `client=app` を取ると、名乗らない口の行に上書きされる ——
#   電話が `X-App-Build` を付けるのは `/api/sessions` だけで、`/api/account` 等は付けない。
#   実測: 同じミリ秒に sessions(build=115)と account(build=-)が並び、
#   `tail -1` が account を掴んで「電話は版を名乗っていない」と報告した。
#   **電話は 115 を名乗っていたのに**。友の観測器は同じ log から 115 を読んでおり、
#   2つの計器が食い違った事で気付いた。
# ★**control としても現れた版は私の殻**(2026-08-31 夕、実測で踏んだ)。
#   役の既定を control へ倒す前に焼いた砂場の app は `client=app build=1` として
#   記録されており、其の行が今も log に残る。机の起動より後なので時代の門も通る ——
#   結果、道具は「電話=1 / 栞を叩けば 115 ビルド進む」という**存在しない差**を出した。
#   ★弾き方に数字の勘は使わない: **同じ版が `client=control` の行にも出ている**なら、
#     其の版は私の焼いた殻である事が log 自身から確定する(電話は control を名乗らない)。
CTRL_BUILDS=$(rexec "grep 'client=control' '$APPLOG' 2>/dev/null | sed -n 's/.* build=\([0-9][0-9]*\) .*/\1/p' | sort -u | tr '\n' ' '")
PHONE_LINE=$(rexec "grep 'client=app' '$APPLOG' 2>/dev/null | grep -v 'build=-' | tail -50" \
    | /usr/bin/awk -v ctrl=" ${CTRL_BUILDS} " '
        { b=""; for (i=1;i<=NF;i++) if ($i ~ /^build=[0-9]+$/) { b=substr($i,7) }
          if (b != "" && index(ctrl, " " b " ") == 0) last=$0 }
        END { print last }')
if [ -z "$PHONE_LINE" ]; then
    # ★「一度も無い」とは言えない —— この log は上限で切られる。測れた範囲だけを言う。
    bad "電話の版" "この log に残っている範囲に app からの要求が1本も無い(切られた後かもしれない)"
else
    PHONE_BUILD=$(printf '%s' "$PHONE_LINE" | sed -n 's/.* build=\([0-9-]*\) .*/\1/p')
    PHONE_SEEN=$(printf '%s' "$PHONE_LINE" | sed -n 's/^\[rc-backend\] req \([^ ]*\) .*/\1/p')
    # ★**其の行を今の意味で読んでよいか**を確かめる(2026-08-31)。08-31 より前の机は
    #   `build=` に UA 由来の**売り物の版**を書いていた(実測: 861 本 全部 `1`)。
    #   古い行を今の意味で読むと「1 は 105 より 104 古い」という**存在しない差**を作る
    #   —— 実際に一度書きかけた。だから条件は2つ、どちらも観測で決める:
    #     (a) 机に**配ってある** reqlog.mjs が版をヘッダから採る形になっているか
    #     (b) **走っている process** が其の file より後に起きたか
    #   (a) だけでは足りない —— 配ったが再起動していない、が此の道具の存在理由そのもの。
    ERA_OK=1
    HAS_FIX=$(rexec "grep -c 'const build = headerBuild(' $REMOTE_HOME/rc-backend/src/reqlog.mjs 2>/dev/null" | tr -d '[:space:]')
    case "${HAS_FIX:-0}" in
        ''|0) bad "電話の版" "机の reqlog.mjs がまだ UA から版を採る形 = build 欄は build 番号ではない(配れば直る)"; ERA_OK=0 ;;
    esac
    if [ "$ERA_OK" = 1 ] && [ -n "${UPTIME:-}" ]; then
        BOOT_EPOCH=$(( $(date +%s) - UPTIME ))
        FIX_MTIME=$(rexec "/usr/bin/stat -f %m $REMOTE_HOME/rc-backend/src/reqlog.mjs 2>/dev/null" | tr -d '[:space:]')
        case "${FIX_MTIME:-}" in
            ''|*[!0-9]*) : ;;
            *) if [ "$FIX_MTIME" -gt "$BOOT_EPOCH" ]; then
                   bad "電話の版" "机の reqlog.mjs は直っているが、走っている process は其れより前に起きている = まだ古い実装が書いている"
                   ERA_OK=0
               fi ;;
        esac
        # (c) ★**其の行自体が今の process から出たか**(2026-08-31、配備直後に実測で踏んだ)。
        #   (a)(b) は「今 書いている物は正しい」しか言わない。**既に書かれている行**は
        #   古い実装の産物のまま残る —— 配備した直後は必ず其の状態で、実際に
        #   直後の走行が偽の差「1 < 105 = 104 ビルド進む」を復活させた。
        #   ★判定は `tools/log-line-era.sh` が持つ。此処に埋めていた時に 20 分で2回 壊れ、
        #     どちらも「生きた机が要るので対照が書けない」場所だったから気付けなかった。
        if [ "$ERA_OK" = 1 ] && [ -n "$PHONE_SEEN" ]; then
            bash "$REPO/tools/log-line-era.sh" "$BOOT_EPOCH" "$PHONE_SEEN" >/dev/null 2>&1
            case $? in
                0) : ;;
                2) bad "電話の版" "最後の app 要求($PHONE_SEEN)は今の机が起きる前の行 = 古い実装が書いた欄。電話が一度要求を出すまで判らない"; ERA_OK=0 ;;
                *) bad "電話の版" "ログの刻を読めない($PHONE_SEEN)= 版は判らない"; ERA_OK=0 ;;
            esac
        fi
    fi
    PUB=$(rexec "/usr/libexec/PlistBuddy -c 'Print :items:0:metadata:bundle-version' \$HOME/ota/*/manifest.plist 2>/dev/null" | tr -d '[:space:]')
    printf '  電話=%s(最後に見たのは %s) 配布中=%s\n' \
        "$([ "$ERA_OK" = 1 ] && printf '%s' "${PHONE_BUILD:-?}" || printf '読めない')" \
        "${PHONE_SEEN:-?}" "${PUB:-?}"
    # ★時代が合わない時は**版の話をしない**。上で既に理由を1本 出しているので、
    #   此処で更に「名乗っていない」と言うと、同じ事実に2つの違う説明が付く。
    if [ "$ERA_OK" = 1 ]; then
        case "${PHONE_BUILD:-}" in
            ''|-|*[!0-9]*)
                bad "電話の版" "app の行は在るが版を名乗っていない(= 08-30 以前の版。X-App-Build を持たない)" ;;
            *)
                case "${PUB:-}" in
                    ''|*[!0-9]*) bad "電話の版" "配っている版を読めないので比べられない" ;;
                    *) if [ "$PHONE_BUILD" -ge "$PUB" ]; then good "電話が配布中の版に追いついている($PHONE_BUILD >= $PUB)"
                       else bad "電話が配布中より古い" "$PHONE_BUILD < $PUB = 栞を叩けば $((PUB - PHONE_BUILD)) ビルド進む"; fi ;;
                esac ;;
        esac
    fi
fi

echo "=== 2. 常設が全部 load されているか ==="
for j in com.fleet.rc-backend com.fleet.rc-phone-window com.fleet.rc-health-observer; do
    if rexec "launchctl print gui/501/$j >/dev/null 2>&1"; then good "$j"; else bad "$j" "未 load"; fi
done
if "$LAUNCHCTL_BIN" print "gui/$(id -u)/com.tomtim.rc-tunnel-observer" >/dev/null 2>&1; then
    good "com.tomtim.rc-tunnel-observer(手元)"
else
    bad "com.tomtim.rc-tunnel-observer(手元)" "未 load = 外からトンネルを見る目が無い"
fi

echo "=== 3. 設定 file が机に在るか(在っても『効いている』とは限らない)==="
# ★repo に例が在る物は、本番に**実物**が在るべき。例だけ在って実物が無い =
#   「作ったが配っていない」の一番よく出る形(2026-08-26 の拒否規則がこれ)。
for pair in "deny.example.json:deny.json"; do
    ex="${pair%%:*}"; live="${pair##*:}"
    if [ ! -f "$REPO/tools/$ex" ]; then continue; fi
    if rexec "[ -f $REMOTE_HOME/.rc-backend/$live ]"; then good "$live が机に在る"
    else bad "$live" "repo に例($ex)は在るのに机に実物が無い = 層は動くが1本も効かない"; fi
done

echo "=== 4. 拒否規則が**実際に効く**か(在る事と効く事は別)==="
if rexec "[ -f $REMOTE_HOME/.rc-backend/deny.json ]"; then
    n=$(rexec "/usr/bin/python3 -c \"
import json
try:
    d=json.load(open('$REMOTE_HOME/.rc-backend/deny.json'))
    print(len(d) if isinstance(d,list) else -1)
except Exception:
    print(-1)\"")
    case "$n" in
        -1|"") bad "deny.json" "机の上で読めない(壊れている / 形が違う)= 静かに0本になる" ;;
        0)     bad "deny.json" "空の配列 = 在るのに1本も効かない" ;;
        *)     good "deny.json が $n 本 読める" ;;
    esac
fi

echo "=== 5. 公開面が机へ繋がっていないか(2026-08-26 追加)==="
# ★実測して分かった形: この機体の 443 は別 PJ(resonance-os)が Funnel で**公開**していて、
#   私たちの机は 9443(tailnet 限定)に載っている。公開されている入口に `/rc -> 8787` を
#   1行足すだけで、生きた Claude Code の操縦面が公開インターネットに出る。
#   ★入口の**名前**ではなく**経路**で見る。「9443 が Funnel されていないか」は Funnel が
#   443/8443/10000 しか扱えない以上 原理的に真にならない空虚な条件だった(Codex 2026-08-26)。
fx=$(rexec "/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status --json")
fxout=$(printf '%s' "$fx" | bash "$REPO/tools/funnel-exposure-check.sh" 8787 2>/dev/null); fxrc=$?
case "$fxrc" in
    0) good "公開されている入口から机(8787)へ繋がっていない" ;;
    1) bad  "★公開面が机へ繋がっている" "$fxout — 生きた Claude Code が公開面に出ている" ;;
    *) bad  "公開面の判定" "serve status が読めなかった(exit=$fxrc)= 安全とは言えない" ;;
esac

echo "=== 6. 外からトンネルが見えるか(loopback の緑は電話の緑ではない)==="
code=$("$CURL_BIN" -s -o /dev/null -m 12 -w '%{http_code}' "${RC_TUNNEL_URL:-https://desk.tailnet.example:9443/healthz}" 2>/dev/null)
[ "$code" = "200" ] && good "外から 200" || bad "外からトンネル" "code=$code"

echo ""
echo "--- 合計: OK $ok / NG $ng ---"
exit $(( ng > 0 ))
