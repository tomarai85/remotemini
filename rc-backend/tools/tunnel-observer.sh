#!/bin/bash
# no-operator: repo の外が回す。Jervis の LaunchAgent `com.tomtim.rc-tunnel-observer`
#   (10分毎)が唯一の操作者で、**配備先ではない機体から**叩く事がこの道具の存在理由。
#   門から回すと、この repo が載っている機体自身から叩く事になり、測りたい経路
#   (外 -> tailnet -> 配備先)を通らない = 測っている物が別物になる。
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

if [ "$st" = up ]; then
    [ "$prev_st" = down ] && { log "戻った(${code:-rc=$crc})"; [ "$DRY" = 0 ] && [ -x "$NOTIFY" ] && "$NOTIFY" "rc-backend のトンネルが戻りました: $URL" >/dev/null 2>&1; }
    exit 0
fi

log "ng(code=${code:-none} curl rc=$crc)— 連続 $fails"
if [ "$fails" -eq "$THRESHOLD" ] && [ "$DRY" = 0 ] && [ -x "$NOTIFY" ]; then
    # ★閾値に**丁度**達した回だけ鳴らす(超えている間ずっと鳴らすと経路ごと黙らされる)
    "$NOTIFY" "rc-backend のトンネルに届きません: $URL($((fails*${RC_TUNNEL_EVERY_S:-600}/60)) 分)" >/dev/null 2>&1
fi
exit 1
