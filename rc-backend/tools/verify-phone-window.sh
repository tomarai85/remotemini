#!/bin/bash
# verify-phone-window.sh — 鎖③④を**観測値で**確定して JSON に落とす。
#
# なぜ専用の物を書くか(safety-core HARD GATE 1 の道具を流用しない理由):
#   `~/.claude/tools/verify-production-stop.sh` は「止まった」を測る道具で、しかも
#   check 4/5 が `~/client-a` 決め打ち。この案件に当てると、**測っていない軸に緑を出す**。
#   それは今夜ずっと潰してきた型(「正しい観測を、それが支えていない結論に貼る」)そのもの。
#   → 止まった側の証明はあちらで取る(teardown の可逆性)。**動いている側はこちらで測る**。
#
# 測る物 = DESIGN §6 の鎖4本のうち、この案件が担当する ③④ と、その生存:
#   job_present     … launchd に居るか(= 60 秒ごとに走る仕掛けが在るか)
#   heartbeat_age_s … ★最重要。**実際に走った時刻**。job が居ても走っていない事は在る
#   phone_windows   … `work:phone` が**ちょうど1枚**(0 = 鎖③未達、2+ = 増殖)
#   phone_pane_cmd  … その中で何が走っているか(素の shell なら「話せる相手」ではない)
#   registry_hits   … 登録簿に載っているか(= 電話の一覧に出る = 鎖④)
#   window0_pane    … Tom の既存ペインが**入れ替わっていない**事の記録(baseline と比較)
#
# 判定(ready): job_present ∧ heartbeat が新しい ∧ phone_windows == 1 ∧ registry_hits >= 1。
#   ssh が通らない = **判定不能(exit 2)**。「見えない」を「無事」と書かない。
#
# 使い方:
#   bash tools/verify-phone-window.sh                 # 観測して JSON を吐く + artifact 保存
#   bash tools/verify-phone-window.sh --expect-absent # 撤去の確認(job も script も居ない事)
# 終了コード: 0 = 期待通り / 1 = 期待と違う / 2 = 判定不能
set -u

HOST="${RC_EDITH_HOST:-edith@10.0.0.0}"
LABEL="${RC_PHONE_LABEL:-com.edith.rc-phone-window}"
SESSION="${RC_PHONE_SESSION:-work}"
WINDOW="${RC_PHONE_WINDOW:-phone}"
FRESH_S="${RC_PHONE_FRESH_S:-180}"   # StartInterval 60 の 3 倍。これを超えたら「走っていない」
ARTIFACT_DIR="${VERIFY_ARTIFACT_DIR:-.harness/evidence-$(date +%Y-%m-%d)}"

EXPECT="present"
[ "${1:-}" = "--expect-absent" ] && EXPECT="absent"

RAW=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
        bash -s -- "$LABEL" "$SESSION" "$WINDOW" <<'REMOTE' 2>/dev/null
set -u
LABEL=$1; SESSION=$2; WINDOW=$3
TMUX=/opt/homebrew/bin/tmux
now=$(date +%s)
echo "host=$(hostname -s)"
echo "observed_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"

line=$(launchctl list 2>/dev/null | grep -F "$LABEL" || true)
if [ -n "$line" ]; then
    echo "job_present=true"
    echo "job_pid=$(printf '%s' "$line" | awk '{print $1}')"
    echo "job_last_exit=$(printf '%s' "$line" | awk '{print $2}')"
else
    echo "job_present=false"
fi

# ★2つ別々に見る。attempt = 走った / success = 在る事を確かめられた。
# 混ぜると「信頼判定が永久に失敗しているのに心拍だけ新しい」が健康と同じ顔になる。
at="$HOME/.rc-backend/phone-window.attempt"
su="$HOME/.rc-backend/phone-window.success"
if [ -f "$at" ]; then echo "attempt_age_s=$(( now - $(stat -f %m "$at") ))"; else echo "attempt_age_s=-1"; fi
if [ -f "$su" ]; then echo "success_age_s=$(( now - $(stat -f %m "$su") ))"; else echo "success_age_s=-1"; fi
st="$HOME/.rc-backend/phone-window.state"
[ -f "$st" ] && echo "last_state=$(cat "$st")"
lg="$HOME/Library/Logs/rc-backend/phone-window.log"
[ -f "$lg" ] && echo "log_bytes=$(stat -f %z "$lg")" || echo "log_bytes=0"
le="$HOME/Library/Logs/rc-backend/phone-window.error.log"
[ -f "$le" ] && echo "errlog_bytes=$(stat -f %z "$le")" || echo "errlog_bytes=0"

# 走っている script の数(撤去の確認に要る。label では ps に映らないので実体で見る)
echo "script_procs=$(ps ax -o command= | grep -c '[e]nsure-phone-window.sh')"

if [ -x "$TMUX" ] && $TMUX has-session -t "$SESSION" 2>/dev/null; then
    echo "session_present=true"
    echo "windows=$($TMUX list-windows -t "$SESSION" -F '#{window_name}' | tr '\n' ' ')"
    n=$($TMUX list-windows -t "$SESSION" -F '#{window_name}' | grep -cx "$WINDOW")
    echo "phone_windows=$n"
    # ★`-eq 1` であって `-ge 1` ではない。2枚在ると tmux は `session:phone` を一切
    #   解決しない(実測 2026-08-02, 対照 D1)ので、名前で引いた値は全部空になる。
    #   空を「観測値」として記録すると、増殖している時に registry_hits=0 のような
    #   **測っていない数字**が JSON に残る。枚数が1でない事は上の phone_windows が言う。
    if [ "$n" -eq 1 ]; then
        pane=$($TMUX list-panes -t "${SESSION}:${WINDOW}" -F '#{pane_id}' | head -1)
        echo "phone_pane=$pane"
        echo "phone_pane_pid=$($TMUX list-panes -t "${SESSION}:${WINDOW}" -F '#{pane_pid}' | head -1)"
        echo "phone_pane_cmd=$($TMUX list-panes -t "${SESSION}:${WINDOW}" -F '#{pane_current_command}' | head -1)"
        echo "phone_auto_rename=$($TMUX display-message -p -t "${SESSION}:${WINDOW}" '#{automatic-rename}')"
        # 抜け殻(名前だけ在って中身が死んでいる)を「在る」と数えない為
        echo "phone_panes_alive=$($TMUX list-panes -t "${SESSION}:${WINDOW}" -F '#{pane_dead}' | grep -cx 0)"
        hits=0; sid=""
        for f in "$HOME"/.rc-backend/panes/*.json; do
            [ -e "$f" ] || continue
            if grep -q "\"$pane\"" "$f" 2>/dev/null; then
                hits=$((hits + 1)); sid=$(basename "$f" .json)
            fi
        done
        echo "registry_hits=$hits"
        echo "phone_session_id=$sid"
        # ★「登録簿に載っている」と「電話の一覧に出る」は**別物**(2026-08-02 実測で乖離した)。
        #   一覧は会話の記録ファイル(jsonl)を走査して作るので、まだ1ターンも話していない
        #   会話は記録ファイルが無く、登録簿に居ても一覧に**出ない**。
        #   登録の有無だけ見て「一覧に出る」と書いていたのが元の誤り。実物に聞く。
        key="$HOME/.rc-backend/api.key"
        if [ -n "$sid" ] && [ -f "$key" ]; then
            body=$(curl -s -m 5 -H "Authorization: Bearer $(cat "$key")" \
                   "http://127.0.0.1:8787/api/sessions?limit=50" 2>/dev/null)
            if [ -z "$body" ]; then echo "listed_in_api=unknown"
            elif printf '%s' "$body" | grep -q "$sid"; then echo "listed_in_api=true"
            else echo "listed_in_api=false"; fi
        else
            echo "listed_in_api=unknown"
        fi
    else
        echo "registry_hits=0"
    fi
    echo "window0_pane=$($TMUX list-panes -t "${SESSION}:0" -F '#{pane_id}' 2>/dev/null | head -1)"
    echo "window0_pane_pid=$($TMUX list-panes -t "${SESSION}:0" -F '#{pane_pid}' 2>/dev/null | head -1)"
else
    echo "session_present=false"
    echo "phone_windows=0"
    echo "registry_hits=0"
fi
REMOTE
)
SSH_RC=$?

if [ "$SSH_RC" -ne 0 ] || [ -z "$RAW" ]; then
    echo '{"verdict":"unknown","reason":"ssh が通らない = 判定不能。見えない事を無事と書かない"}'
    exit 2
fi

mkdir -p "$ARTIFACT_DIR" 2>/dev/null
# ★秒までの時刻だけだと、同じ秒に 2 回走った時に**前の証拠を上書きする**。
# (導入前に「不在を期待」と「在を期待」を連続で回して実際に 1 個消した)
# 証拠を残す為の道具が証拠を消すのは本末転倒なので、期待と pid まで名前に入れる。
OUT="$ARTIFACT_DIR/verify-phone-window-${EXPECT}-$(date +%Y%m%d-%H%M%S)-$$.json"

RAW="$RAW" EXPECT="$EXPECT" FRESH_S="$FRESH_S" LABEL="$LABEL" \
SESSION="$SESSION" WINDOW="$WINDOW" HOST="$HOST" OUT="$OUT" python3 - <<'PY'
import json, os, sys

kv = {}
for ln in os.environ["RAW"].splitlines():
    if "=" in ln:
        k, v = ln.split("=", 1)
        kv[k.strip()] = v.strip()

def i(k, d=-1):
    try: return int(kv.get(k, d))
    except ValueError: return d

fresh_s = int(os.environ["FRESH_S"])
expect  = os.environ["EXPECT"]

job     = kv.get("job_present") == "true"
att     = i("attempt_age_s")
suc     = i("success_age_s")
att_ok  = 0 <= att <= fresh_s
suc_ok  = 0 <= suc <= fresh_s
n       = i("phone_windows", 0)
alive   = i("phone_panes_alive", 0)
reg     = i("registry_hits", 0)
procs   = i("script_procs", -1)
logb    = i("log_bytes", 0)
listed  = kv.get("listed_in_api", "unknown")

fail = []
if expect == "present":
    if not job:            fail.append("launchd に job が居ない(= 60 秒ごとに戻す仕掛けが無い)")
    if not att_ok:         fail.append(f"attempt が古い/無い({att}s > {fresh_s}s)= job は居ても走っていない")
    # ★attempt と success を分けて見る。走っているのに success が古い = 走ってはいるが
    #   毎回どこかの関門で止まっている(信頼判定など)。心拍1本だとこれが健康に見える。
    if not suc_ok:         fail.append(f"success が古い/無い({suc}s > {fresh_s}s)= 走ってはいるが「在る」を確かめられていない")
    if n != 1:             fail.append(f"work:phone が {n} 枚(1 枚でなければならない。0=鎖③未達 / 2+=増殖)")
    if n == 1 and alive < 1: fail.append("window は在るが中のペインが全部死んでいる(抜け殻)= 話せる相手ではない")
    if reg < 1:            fail.append("登録簿に載っていない(= その会話がどのペインに居るか誰も知らない)")
    # ★ここを分けた理由(2026-08-02): 登録簿に載っている事を「電話の一覧に出る」と書いていたが、
    #   実測すると **載っていても出ない**。一覧は jsonl を走査して作るので、0ターンの会話は
    #   ファイルが無く走査に載らない。= 再起動直後に用意した window が、電話からは見えない。
    #   1つの verdict に混ぜず、鎖ごとに状態を出す(混ぜると「どっちが壊れたか」が消える)。
    if listed == "false":  fail.append("★登録簿には在るのに電話の一覧に出ない。0ターンの会話は記録ファイルが無く、一覧の走査に載らない = 再起動直後に用意した window は電話から見えない")
    elif listed == "unknown": fail.append("一覧に出るか確かめられなかった(api.key か 8787 に届かない)= 未測定であって緑ではない")
    cmd = kv.get("phone_pane_cmd", "")
    if n == 1 and cmd in ("bash", "zsh", "sh", "-zsh", "login"):
        fail.append(f"pane で走っているのが素の shell({cmd})= 話せる相手ではない")
    # launchd は StandardOutPath を回さない。書く量は throttle で抑えてあるが、
    # 抑えが効いているかは**実測**で見る(効いていない事に気付く道が要る)。
    if logb > 8 * 1024 * 1024:
        fail.append(f"log が {logb} bytes = 抑えが効いていない。中身を読んで原因を潰す事")
else:  # absent
    if job:                fail.append("launchd に job がまだ居る")
    if procs > 0:          fail.append(f"script がまだ {procs} 本走っている")

verdict = "ok" if not fail else "fail"
# 鎖ごとに出す。1つの verdict に丸めると「window が消えた」と「一覧に出ない」が同じ赤になり、
# 後で読んだ時にどちらが壊れたのか分からない(= 状態を混ぜた値は欠陥、という今週の型)。
chains = {
    "3_window":   "ok" if (n == 1 and alive >= 1) else "fail",
    "3_scheduler": "ok" if (job and att_ok) else "fail",
    "4_registry": "ok" if reg >= 1 else "fail",
    "4_listed":   {"true": "ok", "false": "fail"}.get(listed, "unknown"),
} if expect == "present" else {}
doc = {
    "what":        "鎖③④(tmux の中に話せる相手が居て、登録簿に載っている)の観測",
    "expect":      expect,
    "verdict":     verdict,
    "chains":      chains,
    "label":       os.environ["LABEL"],
    "target":      f'{os.environ["SESSION"]}:{os.environ["WINDOW"]}',
    "host":        os.environ["HOST"],
    "fresh_threshold_s": fresh_s,
    "observed":    kv,
    "failures":    fail,
    "not_measured_here": [
        "電話から実際に打ち込んで返事が返るか(= live-inject-check の仕事)",
        "会話の文脈が復元されるか(この job は --resume しない。設計通り)",
        "一覧に出た後、その行が tmux のペインに繋がるか(= route が worker でなく tmux か)。"
        "今日の実測では登録が古い会話は全部 worker 送りになっていた",
    ],
}
with open(os.environ["OUT"], "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
print(json.dumps(doc, ensure_ascii=False, indent=2))
sys.exit(0 if verdict == "ok" else 1)
PY
RC=$?
echo "# artifact: $OUT" >&2
exit $RC
