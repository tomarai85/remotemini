#!/bin/bash
# 本番の操作者は repo の外に在る: Jervis の LaunchAgent `com.tomtim.rc-tunnel-observer`
#   (10分毎)。**配備先ではない機体から**叩く事がこの道具の存在理由で、
#   本物の経路(外 -> tailnet -> 配備先)を本番でだけ通る。
#
# ★`no-operator:` の印は 2026-08-27 に外した。`tools/tunnel-observer-control.sh` を
#   新設して門から回る様になった為 —— 印が「走らせる物が無い」と言い続けると、
#   **走っている物を走っていないと記録する**事になり、次に読む人が判断を誤る。
#   対照が測るのは**判定の分岐**(自分の回線が落ちている時に鳴らないか等)で、
#   偽 curl で駆動する。本物の経路は本番でしか通らない、という上の事実は変わらない。
#   **同じ道具に「本番の操作者」と「門から回る対照」が両方在ってよい。**
# tunnel-observer.sh — **外から**トンネル越しに rc-backend を叩く観測者。2026-08-26 新設。
#
# なぜ要るか(2026-08-25 実測で開いた穴)
#   既存の health-observer は配備先の機体自身で loopback を叩く。理由は物理: その機体は
#   **自分の tailscale serve URL に届かない**(hairpin。friday が自分の friday…:9443 を
#   引くと curl exit 28。Jervis からは同じ URL が 200)。
#   結果、`tailscale serve` の設定が消えても tailscaled が死んでも **loopback は緑のまま**。
#   電話から見た世界は死んでいるのに、監視は健康だと言う。
#
# ★この台本が守らない事(先に書く。守っていると誤読させない為):
#   これは**この台本を走らせている機体から**トンネルが見えるかを測るだけ。
#   Tom の iPhone から見えるかは測っていない(電話は別の経路・別の DNS・別の網に居る)。
#
# ★沈黙を正常と読ませない(この repo が繰り返し踏んだ型)
#   観測者が寝る機体(MBP)に載ると、走らない事と異常が無い事が同じ顔になる。
#   だから毎回 `$STATE` に**走った時刻**を書き、`--report` はそれを必ず出す。
#   「最後に見たのは N 分前」が読めない監視は監視ではない。
#
# 使い方:
#   tunnel-observer.sh              1回測って状態を更新(launchd から回す)
#   tunnel-observer.sh --report     最後の観測を人が読む形で出す(測らない)
#   tunnel-observer.sh --dry-run    測るが通知しない
#
# 終了コード: 0 = 生きている / 1 = 死んでいる(閾値超え)/ 2 = 使い方 / 3 = 監視自体が壊れている
set -uo pipefail

URL="${RC_TUNNEL_URL:-https://desk.tailnet.example:9443/healthz}"
STATE="${RC_TUNNEL_STATE:-$HOME/.rc-backend/tunnel-state.json}"
LOG="${RC_TUNNEL_LOG:-$HOME/.rc-backend/tunnel-observer.log}"
NOTIFY="${RC_TUNNEL_NOTIFY:-$HOME/bin/discord-notify.sh}"
THRESHOLD="${RC_TUNNEL_THRESHOLD:-3}"

# ---- 自分の回線が生きているかを、tailnet の外で確かめる(2026-08-27 新設)-----------
# なぜ要るか(実測): この機体(Jervis)は Tom が持ち歩いてテザリングする。回線が不定期に
#   落ちるのは**仕様**で、実測では 2026-08-26 の 14:00-20:20 に 186 FAIL / 178 OK ——
#   **ほぼ半分の時間 自分の回線が死んでいた**。閾値 3 回は そんな窓では容易に達する。
#   その時に鳴るのは「相手が死んだ」ではなく「**私が届かない**」であって、別の事実。
#
# ★此の機体が言えるのは「私が届かない」までで、「相手が死んだ」とは**原理的に言えない**
#   (Codex 2026-08-27)。だから鳴らす前に、自分の egress が生きている事を確かめる。
#
# ★確かめ方(Codex の指定):
#   ・**tailnet の外**の、**2 箇所**へ TCP/TLS を張る。片方でも通れば egress は生きている。
#   ・**やらない事**: gateway だけ / DNS だけ / 別の tailnet peer / 任意の公開サイト。
#     前3つは egress を証明しないし、最後は相手の都合で落ちて偽の「回線が死んだ」を作る。
#   ・両方塞がれていたら **unknown**。unknown を「回線が生きている」に倒さない。
# ★`:-` ではなく `-`。`:-` は**空文字にも既定を当てる**ので、
#   「確かめる術が無い」構成(= 意図的に確認先を外した機体)を選べなくなる。
#   空を渡せる事が、unknown を**意図して選べる**という意味を持つ。
SELF_URLS="${RC_TUNNEL_SELF_URLS-https://www.apple.com/library/test/success.html https://api.anthropic.com/}"
SELF_TIMEOUT="${RC_TUNNEL_SELF_TIMEOUT:-8}"

# 0 = 自分の回線は生きている / 1 = 自分が落ちている / 2 = 判らない
self_link_state() {
    local u ok=0 tried=0
    for u in $SELF_URLS; do
        tried=$((tried + 1))
        if curl -s -o /dev/null -m "$SELF_TIMEOUT" --max-redirs 2 "$u" 2>/dev/null; then
            ok=1; break
        fi
    done
    [ "$tried" -eq 0 ] && return 2
    [ "$ok" -eq 1 ] && return 0
    return 1
}
TIMEOUT="${RC_TUNNEL_TIMEOUT:-12}"
DRY=0; REPORT=0
case "${1:-}" in
    --dry-run) DRY=1 ;;
    --report)  REPORT=1 ;;
    "") ;;
    *) echo "usage: $0 [--dry-run|--report]" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$STATE")" 2>/dev/null || { echo "状態の置き場が作れない" >&2; exit 3; }

# ★重なった実行を1本に絞る(Codex 2026-08-26)。読む→判定→書く→鳴らす が不可分でないと、
#   2本が同時に fails==2 を読んで両方が 3 を書き、**二重に鳴る**か、片方の増加が消えて
#   閾値に永久に届かない。launchd は前の実行が終わる保証をしない。
#   取れなければ**黙って何もしない**(前の実行が今まさに測っている = 測り直す意味が無い)。
LOCK="${RC_TUNNEL_LOCK:-$STATE.lock}"
if [ "$REPORT" = 0 ]; then
    exec 9>"$LOCK" || { echo "錠が開けない: $LOCK" >&2; exit 3; }
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || exit 0
    else
        # macOS に flock(1) は無い。shlock 相当を自前で持たず、python の fcntl で取る。
        /usr/bin/python3 -c "
import fcntl,sys
try:
    f=open(sys.argv[1],'a'); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
except Exception:
    sys.exit(2)
sys.exit(0)" "$LOCK" || exit 0
    fi
fi
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# ★配備した物が repo とずれた事を、**配備の時でなく定期に**気付く枝(2026-08-31、CF-22)。
#   `observer-parity-check.sh` / `fleet-plist-parity-check.sh` は repo が要るので
#   Jervis からしか回せず、今は配備の前後にしか走らない —— CF-7 の再発路。
#   ★此の観測器に相乗りする理由: 既に「自分の回線が落ちている時は黙る」枝を持っている。
#     新しい見張りを建てると、其の判断を2箇所で持つ事になる(CF-22 で一度
#     「既に在る物の上に2本目を建てる」提案を実測で取り下げている)。
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/parity-observer.sh"

read_state() { # -> status fails lastRunAt lastOkAt
    /usr/bin/python3 - "$STATE" <<'PY' 2>/dev/null || echo "unknown 0 0 0"
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
print(d.get("status","unknown"), int(d.get("fails",0) or 0),
      int(d.get("lastRunAt",0) or 0), int(d.get("lastOkAt",0) or 0))
PY
}

if [ "$REPORT" = 1 ]; then
    read -r st fails lastrun lastok <<<"$(read_state)"
    now=$(date +%s)
    if [ "$lastrun" -eq 0 ]; then
        echo "この機体はまだ一度も測っていない($STATE が無い)"
        echo "★これは『異常なし』ではない。観測者が走っていない。"
        exit 3
    fi
    age=$(( now - lastrun ))
    # ★時計が巻き戻ると古い観測が新しく見える。負は「判らない」へ倒す。
    if [ "$age" -lt 0 ]; then
        echo "★時計が前回の観測より前を指している(age=${age}s)。今どうかは判らない"
        exit 3
    fi
    printf '宛先   : %s\n' "$URL"
    printf '状態   : %s(連続失敗 %s)\n' "$st" "$fails"
    printf '最終観測: %s 秒前\n' "$age"
    [ "$lastok" -gt 0 ] && printf '最後に生きていた: %s 秒前\n' "$(( now - lastok ))" \
                        || printf '最後に生きていた: 一度も無い\n'
    # ★寝ている機体に載る前提なので、古い観測を新しい観測のふりをさせない。
    if [ "$age" -gt "${RC_TUNNEL_STALE_S:-3600}" ]; then
        echo "★この観測は古い(${age}秒前)。今どうかは**判らない**。"
        exit 3
    fi
    [ "$st" = "up" ] && exit 0 || exit 1
fi

now=$(date +%s)
# ★本文まで見る(Codex 2026-08-26)。200 だけを緑にすると、その入口が**別のサーバ**へ
#   向いていても緑になる —— この機体の 443 は実際に別 PJ が持っているので、
#   設定が1つずれれば「200 を返す他人」が現れる。それを健康と読むのが一番危ない誤診。
body="$(curl -s -m "$TIMEOUT" -H 'cache-control: no-cache' -w $'\n%{http_code}' "$URL" 2>/dev/null)"; crc=$?
code="$(printf '%s' "$body" | tail -1)"
payload="$(printf '%s' "$body" | sed '$d' | head -c 4096)"
read -r prev_st prev_fails prev_run prev_ok <<<"$(read_state)"

healthy=0
if [ "$crc" -eq 0 ] && [ "$code" = "200" ]; then
    printf '%s' "$payload" | /usr/bin/python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
if d.get("ok") is not True: sys.exit(1)
p=d.get("pid")
if not isinstance(p,int) or isinstance(p,bool) or p<1: sys.exit(1)
u=d.get("uptime")
if not isinstance(u,(int,float)) or isinstance(u,bool) or u<0: sys.exit(1)
v=d.get("version")
if not isinstance(v,str) or not v.strip(): sys.exit(1)
sys.exit(0)' 2>/dev/null && healthy=1
fi

if [ "$healthy" = 1 ]; then
    st=up; fails=0; lastok=$now
else
    st=down; fails=$(( prev_fails + 1 )); lastok=$prev_ok
fi

# ★観測の空白そのものを事件として扱う(Codex #1/#2)。この機体は寝るので、
#   停止が丸ごと睡眠の中に収まると誰も知らないまま終わる。空いた時間を1行残し、
#   長すぎる時は鳴らす —— 「見ていなかった」は「異常が無かった」ではない。
if [ "$prev_run" -gt 0 ]; then
    gap=$(( now - prev_run ))
    if [ "$gap" -lt 0 ]; then
        log "★時計が巻き戻った(gap=${gap}s)。前回との比較は信用しない"
    elif [ "$gap" -gt "${RC_TUNNEL_GAP_S:-5400}" ]; then
        log "★観測に ${gap} 秒の空白(この間の生死は判らない)"
        [ "$DRY" = 0 ] && [ -x "$NOTIFY" ] &&             "$NOTIFY" "rc-backend の外部監視に $((gap/60)) 分の空白がありました(機体が寝ていた等)。この間の生死は不明です。" >/dev/null 2>&1
    fi
fi

/usr/bin/python3 - "$STATE" "$st" "$fails" "$now" "$lastok" "$URL" <<'PY' || { echo "状態を書けない" >&2; exit 3; }
import json,sys,os,tempfile
path,st,fails,run,ok,url = sys.argv[1:7]
d={"status":st,"fails":int(fails),"lastRunAt":int(run),"lastOkAt":int(ok),"url":url}
# 原子的に置き換える(読み手が半分書けた JSON を掴むと「監視が壊れている」に化ける)
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path)); os.close(fd)
open(tmp,"w").write(json.dumps(d))
os.replace(tmp,path)
PY

# ★配備のずれを見る枝(2026-08-31、CF-22)。**up/down のどちらでも通る位置**に置く ——
#   最初は下の `exit 0` より後ろに書いてしまい、**トンネルが落ちている時しか走らない**
#   配線になっていた(通常は up なので、事実上一度も走らない)。
#   「配線されて見えるのに走らない」は此の repo が繰り返し踏んだ型。
#   ★`--dry-run` / `--report` では回さない(前者は「測るが鳴らさない」、後者は「測らない」)。
#   ★自分の回線が落ちている時に黙るのは `parity_observe` の中(`self_link_state`)。
if [ "$DRY" -eq 0 ] && [ "$REPORT" -eq 0 ]; then
    parity_observe || true
fi

if [ "$st" = up ]; then
    [ "$prev_st" = down ] && { log "戻った(${code:-rc=$crc})"; [ "$DRY" = 0 ] && [ -x "$NOTIFY" ] && "$NOTIFY" "rc-backend のトンネルが戻りました: $URL" >/dev/null 2>&1; }
    exit 0
fi

log "ng(code=${code:-none} curl rc=$crc)— 連続 $fails"

# ★鳴らす直前にだけ自分の回線を確かめる。毎回撃つと、健康な時に外へ 10 分ごとの余計な
#   要求を出す事になる —— 見張りは見張られる物より軽くあるべき。
if [ "$fails" -eq "$THRESHOLD" ] && [ "$DRY" = 0 ] && [ -x "$NOTIFY" ]; then
    self_link_state; sls=$?
    case "$sls" in
        1)
            # ★自分が落ちている。**相手の失敗の記録は消さない** —— 回線が戻った次の回に
            #   まだ届かなければ、その時に鳴る(閾値は既に超えているので次の一致で鳴る)。
            log "★鳴らさない: 自分の回線が落ちている(観測者の側)。相手の生死は判らない"
            printf '%s\n' "$(date +%s)" > "${RC_TUNNEL_OFFLINE_MARK:-$STATE.observer-offline}" 2>/dev/null || true
            ;;
        2)
            # 確かめる術が塞がれている。**「生きている」に倒さない**が、黙りもしない ——
            # 判らない事を判らないと言った上で、相手の失敗は事実なので鳴らす。
            log "自分の回線を確かめられない(unknown)。相手に届かない事実として鳴らす"
            "$NOTIFY" "rc-backend のトンネルに届きません: $URL($((fails*${RC_TUNNEL_EVERY_S:-600}/60)) 分 / 観測者の回線は未確認)" >/dev/null 2>&1
            ;;
        *)
            # 自分の回線は生きていて、相手に届かない = 言ってよい。
            /bin/rm -f "${RC_TUNNEL_OFFLINE_MARK:-$STATE.observer-offline}" 2>/dev/null || true
            "$NOTIFY" "rc-backend のトンネルに届きません: $URL($((fails*${RC_TUNNEL_EVERY_S:-600}/60)) 分)" >/dev/null 2>&1
            ;;
    esac
elif [ "$fails" -gt "$THRESHOLD" ] && [ "$DRY" = 0 ] && [ -x "$NOTIFY" ] \
     && [ -f "${RC_TUNNEL_OFFLINE_MARK:-$STATE.observer-offline}" ]; then
    # ★前回は自分の回線が落ちていて鳴らせなかった。回線が戻ったなら**その場で鳴らす** ——
    #   自分が落ちている間に相手も死んでいた場合を、永久に取り逃がさない為(Codex 裁定2)。
    self_link_state
    if [ $? -eq 0 ]; then
        log "回線が戻った。まだ相手に届かないので、抑えていた分を鳴らす"
        /bin/rm -f "${RC_TUNNEL_OFFLINE_MARK:-$STATE.observer-offline}" 2>/dev/null || true
        "$NOTIFY" "rc-backend のトンネルに届きません: $URL($((fails*${RC_TUNNEL_EVERY_S:-600}/60)) 分 / 観測者の回線が戻った後も届かない)" >/dev/null 2>&1
    fi
fi
exit 1
