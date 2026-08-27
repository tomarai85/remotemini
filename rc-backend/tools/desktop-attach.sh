#!/bin/bash
# no-operator: 人が撃つ。Tom が机に座った時、電話で続きを話していた会話へ入る為の物。
#   門から回さない(生きた tmux と ssh が要る)。
#
# desktop-attach.sh — **電話が話している相手と同じ場所へ、机から入る**。2026-08-26 新設。
#
# なぜ要るか
#   この造りの固有の強みは「電話と机が**同じ tmux pane を共有できる**」事。会話の写しでも
#   要約でもなく、同じ端末に二つの入口が在る。だが今日まで机側の入口が無く、Tom は
#   `ssh athenas` してから tmux の session 名と窓名を自分で思い出す必要があった。
#
# ★入口を **pane id にしない**(`%0` 等)。理由は `src/registry.mjs` の頭に実測で書いてある:
#   tmux の pane id は**サーバ世代ごとに %0 から振り直される**ので、登録簿の 10 件が
#   **全件 %0 を名乗っていた**(全部別世代)。id を信じて入ると別の会話に着く。
#   窓の名前(`work:phone`)は世代をまたいで安定で、`ensure-phone-window.sh` が維持している。
#   だから **入口は名前、登録簿は照合にだけ使う**。
#
# 使い方:
#   desktop-attach.sh                 … 電話の窓へ入る(ssh -t で attach)
#   desktop-attach.sh --resolve <id>  … 入口を1行 出すだけ(機械用・入らない)
#   desktop-attach.sh --print         … 入る代わりに撃つべき command を出す
#
# 終了コード: 0=解決した / 3=その会話の登録が無い / 4=登録は在るが世代が違う / 2=使い方
set -uo pipefail

HOST="${RC_FRIDAY_HOST:-athenas}"
SESSION="${RC_PHONE_SESSION:-work}"
WINDOW="${RC_PHONE_WINDOW:-phone}"
TARGET="${SESSION}:${WINDOW}"
PANES_DIR="${RC_PANES_DIR:-$HOME/.rc-backend/panes}"
# ★tmux の場所は repo の既存の規約に合わせる(`ensure-work-session.sh` の `TMUX_BIN=${RC_PHONE_TMUX:-...}`)。
#   非対話 ssh の PATH に tmux は居ない —— 素で `tmux` と書くと `command not found` になり、
#   此の台本はそれを「同一性が取れない」と読んで **unverified のまま黙る**。
#   規約を再発明せず、同じ env 名(`RC_PHONE_TMUX`)を使う。
TMUX_BIN="${RC_PHONE_TMUX:-/opt/homebrew/bin/tmux}"

mode="attach"; want=""
while [ $# -gt 0 ]; do
    case "$1" in
        --resolve) mode="resolve"; want="${2:-}"; shift 2 ;;
        --print)   mode="print"; shift ;;
        -h|--help) echo "usage: $0 [--resolve <session-id-prefix>] [--print]"; exit 2 ;;
        *) echo "usage: $0 [--resolve <session-id-prefix>] [--print]" >&2; exit 2 ;;
    esac
done

# ---- 登録簿から1件引く ----------------------------------------------------------
# ★file 名ではなく **中の `session_id`** で照合する。書き手は `<session_id>.json` で置くが、
#   それに頼ると「名前は合っているが中身が別」を見逃す。中身が正本。
find_entry() { # $1 = prefix(空なら一番新しい物)
    local pref="${1:-}"
    /usr/bin/python3 - "$PANES_DIR" "$pref" <<'PY'
import json, os, sys
d, pref = sys.argv[1], sys.argv[2]
best = None
try:
    names = os.listdir(d)
except Exception:
    sys.exit(3)
for n in names:
    if not n.endswith(".json"):
        continue
    p = os.path.join(d, n)
    try:
        o = json.load(open(p))
    except Exception:
        continue          # 壊れた1件で全体を落とさない
    sid = str(o.get("session_id", ""))
    if pref and not sid.startswith(pref):
        continue
    try:
        m = os.path.getmtime(p)
    except Exception:
        m = 0
    if best is None or m > best[0]:
        best = (m, o)
if best is None:
    sys.exit(3)
o = best[1]
print("%s\t%s\t%s" % (o.get("session_id", ""), o.get("pane", ""), o.get("tmux", "")))
PY
}

# ★登録簿は **tmux を持っている機体**に在る。此処を間違えると、答えは出るが別の機体の
#   会話を指す —— 2026-08-26 に実際にやった: Jervis には自分自身の登録が **47 件** 在り、
#   素で撃つと Jervis の無関係な会話を解決して `rc=0` で返した。宛先だけ Friday の窓なので、
#   **自信のある間違い**になる。Planner が書いた検査は `RC_PANES_DIR` を仕込むので素通りした。
#   だから: `RC_PANES_DIR` が**明示された時だけ**手元を読む(= 検査と、机の上で撃つ時)。
#   それ以外は **$HOST の上で解決する**。手元へ黙って倒さない。
if [ -n "${RC_PANES_DIR:-}" ]; then
    entry="$(find_entry "$want")"; rc=$?
else
    entry="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
        "RC_PANES_DIR=\"\$HOME/.rc-backend/panes\" /usr/bin/python3 -c \"
import json, os, sys
d = os.environ['RC_PANES_DIR']; pref = '${want}'
best = None
try:
    names = os.listdir(d)
except Exception:
    sys.exit(3)
for n in names:
    if not n.endswith('.json'): continue
    p = os.path.join(d, n)
    try: o = json.load(open(p))
    except Exception: continue
    sid = str(o.get('session_id',''))
    if pref and not sid.startswith(pref): continue
    try: m = os.path.getmtime(p)
    except Exception: m = 0
    if best is None or m > best[0]: best = (m, o)
if best is None: sys.exit(3)
o = best[1]
print('%s\\t%s\\t%s' % (o.get('session_id',''), o.get('pane',''), o.get('tmux','')))
\"" 2>/dev/null)"; rc=$?
fi
if [ "$rc" != 0 ] || [ -z "$entry" ]; then
    echo "その会話の登録が無い(探した所: $PANES_DIR${want:+ / prefix=$want})" >&2
    exit 3
fi
sid="$(printf '%s' "$entry" | cut -f1)"
pane="$(printf '%s' "$entry" | cut -f2)"
tmuxid="$(printf '%s' "$entry" | cut -f3)"

# ---- 世代の照合(できる時だけ。できない事を「一致」と言わない)---------------------
# ★「分からない」を「危険」にも「安全」にも倒さない。ここは**入口が名前**なので、
#   世代が違っても別の会話に着く事は無い —— 影響は「登録が古い」という情報だけ。
#   だから照合の結果は**表示**であって、拒否の根拠にしない(`registry.mjs` の注入経路とは
#   要件が違う。あちらは pane id へ**書き込む**ので不明は拒否が正しい)。
gen="unverified"
live="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" \
        "'$TMUX_BIN' display-message -p '#{socket_path},#{pid}' 2>/dev/null" 2>/dev/null || true)"
if [ -n "$live" ] && [ -n "$tmuxid" ]; then
    case "$tmuxid" in
        "$live"*) gen="same" ;;
        *)        gen="stale" ;;
    esac
fi

case "$mode" in
    resolve)
        printf '%s\tpane=%s\tsession=%s\tgeneration=%s\n' "$TARGET" "${pane:-?}" "${sid:0:8}" "$gen"
        exit 0 ;;
    print)
        printf "ssh -t %s \"'%s' attach -t %s\"\n" "$HOST" "$TMUX_BIN" "$TARGET"
        [ "$gen" = "stale" ] && echo "  (注: 登録は別世代の tmux を指している。窓の名前で入るので着く先は正しい)" >&2
        exit 0 ;;
esac

# ---- 実際に入る -----------------------------------------------------------------
# ★Tom がこの command を自分で撃った = 入る意思表示。だから確認を挟まない。
#   ただし**窓が無い時に作らない** —— 作るのは `ensure-phone-window.sh` の仕事で、
#   此処が作ると「入口が2つの物を作る」= 世代の話と同じ病気になる。
if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" \
     "'$TMUX_BIN' has-session -t '${SESSION}' 2>/dev/null && '$TMUX_BIN' list-windows -t '${SESSION}' -F '#{window_name}' 2>/dev/null | grep -qx '${WINDOW}'"; then
    echo "★${TARGET} が無い。作るのは ensure-phone-window.sh の仕事なので、此処では作らない。" >&2
    echo "  机側から起こすなら: ssh ${HOST} 'bash ~/rc-backend/tools/ensure-phone-window.sh'" >&2
    exit 4
fi
exec ssh -t "$HOST" "'$TMUX_BIN' attach -t '$TARGET'"
