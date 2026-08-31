#!/bin/bash
# no-operator: 人が撃つ。配備の直後と「効いている筈なのに効かない」と思った時に1発。
#   門から回さないのは、生きた机への ssh が要るから(手元だけでは何も測れない)。
#
# delivery-check.sh — **作ったのに配っていない物**を探す。2026-08-26 新設。
#
# なぜ要るか(同じ日に3回踏んだ)
#   1. 拒否規則を作り、検査も緑、本番も稼働していた。だが**規則 file が手元にしか無く、
#      拒否層は動いているのに1本も効いていなかった**。
#   2. 危険承認を commit したが、本番と電話が1つ前の版のままだった。
#   3. 添付の保管層を書いたが、机の木に配る前に「動いている」と思っていた。
#
#   共通の形は「**commit と稼働は揃っているのに、間の1段だけが抜けている**」。
#   緑の数でも healthz でも出ない —— どちらも「配った物が正しい」しか言わないから。
#
# ★この台本は**直さない。報告するだけ。** 直す手は人が選ぶ(配る / 消す / 要らないと決める)。
#   自動で配ると、消したつもりの物が黙って戻る。
set -uo pipefail

HOST="${RC_FRIDAY_HOST:-athenas}"
REMOTE_HOME="${RC_REMOTE_HOME:-/Users/athenas}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$REPO/.." && pwd)"

ok=0; ng=0
good() { printf '  OK   %s\n' "$1"; ok=$((ok+1)); }
bad()  { printf '  ★NG  %s — %s\n' "$1" "$2"; ng=$((ng+1)); }

rexec() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$@" 2>/dev/null; }

echo "=== 1. 版が3側で揃っているか(手元 / 本番 / 電話)==="
LOCAL=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")
# ★healthz は**1回だけ**叩いて両方の欄を採る(版と稼働秒)。稼働秒は下の 1b で
#   「其のログ行が今の実装から出た物か」を決めるのに要る。2回叩くと、間に再起動が挟まった時に
#   版と稼働秒が別の走行の物になる。
HEALTH=$(curl -s --max-time 12 "${RC_TUNNEL_URL:-https://desk.tailnet.example:9443/healthz}" 2>/dev/null || echo "")
LIVE=$(printf '%s' "$HEALTH" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo "?")
UPTIME=$(printf '%s' "$HEALTH" | /usr/bin/python3 -c 'import json,sys;v=json.load(sys.stdin).get("uptime");print(int(v) if isinstance(v,(int,float)) else "")' 2>/dev/null || echo "")
# ★之は「**最後に device 向けに焼いた物**」であって電話ではない(2026-08-31 に訂正)。
#   書くのは `ios/tools/build.sh`(`OUT="$DERIVED/signed"`)で、配布と無関係な
#   ただの開発ビルドでも動く。旧版は此れを `電話=` と印字しており、**手元で焼いた瞬間に
#   「電話が手元と一致」と言う**道具だった —— 電話に何も入れていなくても。
#   同じ日に `ota-freshness-check.sh` の生存検査が同型で偽の DEAD を出しており、
#   `ios/build/signed/` を「配った物 / 電話の物」と読む癖は此の木に2箇所在った。
BAKED=$(/usr/libexec/PlistBuddy -c "Print :RCBuildRev" "$ROOT/ios/build/signed/RemoteMini.app/Info.plist" 2>/dev/null || echo "?")
printf '  手元=%s 本番=%s 直近に焼いた物=%s\n' "$LOCAL" "$LIVE" "$BAKED"
# ★`-dirty` を許さない。汚れた木で焼いた物は、どの commit とも突き合わせられない。
case "$LIVE" in *-dirty) bad "本番が汚れた木の版" "$LIVE";; "$LOCAL") good "本番が手元と一致";; *) bad "本番が手元と違う" "$LIVE != $LOCAL";; esac

echo "=== 1b. 電話が実際に動かしている版(机の要求ログから)==="
# ★電話の版は**電話が名乗った物**からしか判らない。手元の成果物は電話について何も語らない。
#   材料は rc-backend の要求ログの `client=app` の行(`X-App-Build` → 無ければ UA)。
#   ★比べる相手は HEAD ではなく**配っている版**。電話には配った物しか入りようがない。
APPLOG="${RC_BACKEND_LOG:-$REMOTE_HOME/Library/Logs/rc-backend/rc-backend.log}"
PHONE_LINE=$(rexec "grep 'client=app' '$APPLOG' 2>/dev/null | tail -1")
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
if launchctl print "gui/$(id -u)/com.tomtim.rc-tunnel-observer" >/dev/null 2>&1; then
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
code=$(curl -s -o /dev/null -m 12 -w '%{http_code}' "${RC_TUNNEL_URL:-https://desk.tailnet.example:9443/healthz}" 2>/dev/null)
[ "$code" = "200" ] && good "外から 200" || bad "外からトンネル" "code=$code"

echo ""
echo "--- 合計: OK $ok / NG $ng ---"
exit $(( ng > 0 ))
