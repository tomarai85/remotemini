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
LIVE=$(curl -s --max-time 12 "${RC_TUNNEL_URL:-https://desk.tailnet.example:9443/healthz}" 2>/dev/null \
       | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo "?")
PHONE=$(/usr/libexec/PlistBuddy -c "Print :RCBuildRev" "$ROOT/ios/build/signed/RemoteMini.app/Info.plist" 2>/dev/null || echo "?")
printf '  手元=%s 本番=%s 電話=%s\n' "$LOCAL" "$LIVE" "$PHONE"
# ★`-dirty` を許さない。汚れた木で焼いた物は、どの commit とも突き合わせられない。
case "$LIVE" in *-dirty) bad "本番が汚れた木の版" "$LIVE";; "$LOCAL") good "本番が手元と一致";; *) bad "本番が手元と違う" "$LIVE != $LOCAL";; esac
case "$PHONE" in *-dirty) bad "電話が汚れた木の版" "$PHONE";; "$LOCAL") good "電話が手元と一致";; *) bad "電話が手元と違う" "$PHONE != $LOCAL";; esac

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
