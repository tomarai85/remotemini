#!/bin/bash
# no-operator: 渡米前に人が撃つ(PRE-DEPARTURE-2026-08-20.md の最後の手順)。生きた edith と
#   tailnet が要るので門からは回せない —— 回線が落ちている日の commit が全部止まる
# departure-survivability-check.sh — 「3週間、誰も触らない edith は生き延びるか」を
# **Jervis から1回で**測る。渡米直前に撃つ。
#
# ★この道具が測らない7項目(FileVault / 自動ログイン / plist の在処 / RunAtLoad /
#   KeepAlive / autorestart / sleep)は `tools/coldboot-chain.sh` が既に測っている。
#   写しを作らず、**edith の上のそれを呼んで結果を引き取る**。
#   (2026-08-07: 一度そこを手で作り直しかけた。同じ物を2つ持つと、片方だけ直る)
#
# ここが足すのは、冷起動の鎖の外に在って**渡米すると触れなくなる** 4 つ:
#   (1) tailnet の鍵の期限 … 切れると tailnet から落ち、復旧用の ssh も同じ経路なので同時に死ぬ
#   (2) job が今この瞬間 動いている事 … plist が正しくても、落ちて再起動を繰り返す形は別問題
#   (3) 面が 401 を返す事      … 200 は鍵が外れている印。tailnet 内の誰でも読める状態
#   (4) 空き容量               … 3週間分のログと OS 更新の置き場
#
# 使い方:
#   bash rc-backend/tools/departure-survivability-check.sh [--days N] [--host user@host]
#
# 終了コード(この repo の三色):
#   0 = 緑     渡米に耐える
#   1 = 赤     1つ以上が耐えない(各行に直し方が出る)
#   2 = 未測定  edith に届かない等で判定が付かない。**緑にも赤にも丸めない**
#
# 出さない物: 会話 id / 機器名 / 鍵。tailnet は**台数と残日数だけ**を出す。
set -u

HOST="${RC_EDITH_HOST:mail-redacted@example.invalid}"
# 旅程。帰国が延びた時に「余裕がある」と嘘を吐かない為、上書きできる
TRIP_DAYS="${RC_TRIP_DAYS:-30}"

while [ $# -gt 0 ]; do
    case "$1" in
        # ★`shift 2` を裸で書かない。引数が1つしか残っていない時 `shift 2` は**失敗して
        #   $# を減らさない**ので、`--days` を値無しで渡すと此処が無限ループする
        #   (2026-08-07、対照 N2 が実際に捕まえた)。値の有無を先に見る。
        --days) [ $# -ge 2 ] || { echo "--days に値が無い" >&2; exit 2; }
                TRIP_DAYS="$2"; shift 2 ;;
        --host) [ $# -ge 2 ] || { echo "--host に値が無い" >&2; exit 2; }
                HOST="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "知らない引数: $1" >&2; exit 2 ;;
    esac
done

case "$TRIP_DAYS" in
    ''|*[!0-9]*) echo "--days は正の整数で: ${TRIP_DAYS:-(空)}" >&2; exit 2 ;;
esac

red=0; unmeasured=0
say_ok()  { printf '  緑    %s\n' "$1"; }
say_bad() { printf '  赤    %s\n' "$1"; red=$((red+1)); }
say_unm() { printf '  未測定 %s\n' "$1"; unmeasured=$((unmeasured+1)); }
say_note(){ printf '  --    %s\n' "$1"; }

echo "3週間の無人耐久(旅程 ${TRIP_DAYS} 日で判定)"
echo

# ---------------------------------------------------------------------------
# ssh は1回だけ。項目ごとに張ると、途中で切れた時に「一部だけ緑」という
# 一番読み違えやすい中間状態が出る。
# 冷起動の鎖は edith の上の coldboot-chain.sh に**そのまま**やらせて、
# 出力と終了コードを持ち帰る(判定を此処で作り直さない = 写しを作らない)。
# ---------------------------------------------------------------------------
RAW=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" '
    p() { printf "%s=%s\n" "$1" "$2"; }

    CB="$HOME/rc-backend/tools/coldboot-chain.sh"
    if [ -f "$CB" ]; then
        out=$(bash "$CB" 2>&1); rc=$?
        p cb_rc "$rc"
        printf "cb_out<<\n%s\ncb_out>>\n" "$out"
    else
        p cb_rc missing
    fi

    p job_rc  "$(launchctl list 2>/dev/null | awk "\$3 == \"com.edith.rc-backend\" { print \$2; exit }")"
    p job_pid "$(launchctl list 2>/dev/null | awk "\$3 == \"com.edith.rc-backend\" { print \$1; exit }")"

    # 401 が正。200 = 鍵が外れている、それ以外 = 面が応答していない。
    p http "$(curl -sS -m 5 -o /dev/null -w "%{http_code}" http://127.0.0.1:8787/api/sessions 2>/dev/null || echo 000)"

    p freeg "$(df -g / 2>/dev/null | awk "NR==2 { print \$4 }")"

    # tailnet: **機器名は一切出さない**。期限が付いている台数と最小残日数だけ。
    TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    [ -x "$TS" ] || TS=$(command -v tailscale 2>/dev/null)
    if [ -n "${TS:-}" ] && [ -x "$TS" ]; then
        "$TS" status --json 2>/dev/null | /usr/bin/python3 -c "
import json,sys,datetime
try: d = json.load(sys.stdin)
except Exception: print(\"ts_state=unreadable\"); sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
nodes = [d.get(\"Self\") or {}] + list((d.get(\"Peer\") or {}).values())
days = []
for n in nodes:
    e = n.get(\"KeyExpiry\")
    if not e: continue          # 期限なし = 望ましい形
    try: t = datetime.datetime.fromisoformat(e.replace(\"Z\", \"+00:00\"))
    except Exception: continue
    days.append(int((t - now).total_seconds() // 86400))
print(\"ts_state=ok\")
print(\"ts_total=%d\" % len(nodes))
print(\"ts_expiring=%d\" % len(days))
print(\"ts_min_days=%s\" % (min(days) if days else \"-\"))
"
    else
        echo "ts_state=absent"
    fi
' 2>/dev/null)

if [ -z "$RAW" ]; then
    echo "  未測定 edith に届かない($HOST)。**赤ではない** —— こちらの回線かもしれず、"
    echo "         「向こうが死んでいる」とは言えない。回線を変えて測り直す。"
    exit 2
fi

g() { printf '%s\n' "$RAW" | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }

# --- 冷起動の鎖(判定は向こうの道具の物をそのまま使う)-----------------------
echo "停電・強制再起動から独りで戻る鎖(coldboot-chain.sh @ edith)"
cb=$(g cb_rc)
case "$cb" in
    0) say_ok "7/7 繋がっている" ;;
    1) say_bad "鎖が切れている —— 下がその出力"
       printf '%s\n' "$RAW" | awk '/^cb_out<</{f=1;next} /^cb_out>>/{f=0} f' | sed 's/^/        /' ;;
    2) say_unm "coldboot-chain が測れなかった(2)。緑と読まない"
       printf '%s\n' "$RAW" | awk '/^cb_out<</{f=1;next} /^cb_out>>/{f=0} f' | sed 's/^/        /' ;;
    missing) say_bad "edith に coldboot-chain.sh が無い —— deploy-to-edith.sh を先に回す" ;;
    *) say_unm "coldboot-chain の終了コードが読めない(${cb:-空})" ;;
esac

# --- 今この瞬間 上がっているか -----------------------------------------------
echo
echo "面が上がっている事(冷起動の鎖とは別の問い = 今の状態)"
if [ -z "$(g job_pid)" ]; then
    say_bad "com.edith.rc-backend が launchctl に居ない"
elif [ "$(g job_rc)" = "0" ]; then
    say_ok "稼働中(最後の終了コード 0)"
else
    say_bad "最後の終了コードが $(g job_rc) —— 落ちて再起動を繰り返している疑い"
fi

case "$(g http)" in
    401) say_ok "/api/sessions が 401(生きている、かつ鍵が効いている)" ;;
    200) say_bad "/api/sessions が 200 —— **鍵が外れている**。tailnet 内の誰でも読める" ;;
    000) say_unm "/api/sessions に届かなかった(curl が答えを返さない)" ;;
    *)   say_bad "/api/sessions が $(g http)(面が応答していない)" ;;
esac

# --- 余白 --------------------------------------------------------------------
echo
echo "余白"
v=$(g freeg)
case "$v" in
    ''|*[!0-9]*) say_unm "空き容量が読めない" ;;
    *) if [ "$v" -ge 20 ]; then say_ok "空き ${v}GB"
       else say_bad "空き ${v}GB —— 3週間分のログと OS 更新に足りない恐れ"; fi ;;
esac

# --- tailnet の鍵 ------------------------------------------------------------
echo
echo "tailnet の鍵(切れると復旧用の ssh も同じ経路なので同時に死ぬ)"
case "$(g ts_state)" in
    ok)
        n=$(g ts_expiring); m=$(g ts_min_days)
        if [ "$n" = "0" ]; then
            say_ok "期限付き 0 台 / 全 $(g ts_total) 台(失効しない形になっている)"
        else
            say_bad "期限付き ${n} 台、最短 残り ${m} 日(旅程 ${TRIP_DAYS} 日)—— admin console → Machines → Disable key expiry"
            say_note "機器名は出さない。どの台かは admin console 側で見る"
        fi
        ;;
    absent)     say_bad "tailscale CLI が見付からない —— 経路そのものを測れていない" ;;
    unreadable) say_bad "tailscale status が JSON を返さない(tailscaled が落ちている疑い)" ;;
    *)          say_unm "tailnet の状態が読めない" ;;
esac

# --- 判定 --------------------------------------------------------------------
# 順序が要点: 赤が1つでも在れば赤。無ければ未測定を緑に丸めない。
echo
if [ "$red" -gt 0 ]; then
    echo "赤 ${red} 件(未測定 ${unmeasured} 件)—— 各行に直し方が書いてある。渡米前に潰す。"
    exit 1
fi
if [ "$unmeasured" -gt 0 ]; then
    echo "未測定 ${unmeasured} 件 —— 赤は無いが、**全部通ったとは言えない**。測り直す。"
    exit 2
fi
echo "緑 —— 測れる範囲は全部通った。"
echo "     測っていないのは「更新の再起動が自動ログインを解除しない事」(実績が無い)。"
exit 0
