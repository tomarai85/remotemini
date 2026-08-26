#!/bin/bash
# phone-window-health.sh — 「窓は在るのに、中の claude が登録まで到達していない」を捕まえる。
# 2026-08-26 新設。
#
# なぜ要るか(2026-08-25 に実際に踏んだ穴)
#   `ensure-phone-window.sh` の冪等は **窓の有無**で取っている。これは正しい —— 週次上限に
#   当たった TUI は上限画面のまま生き続けるので、中身で判定すると窓が増え続ける。
#   だが副作用として、**窓が在って中が固まっている**状態はあの台本から正常に見える。
#   実測: Claude Code v2.1.245 が初回に `Try the new fullscreen renderer?` の 1/2 選択を出し、
#   答えるまで登録簿に載らなかった。登録されない会話は電話の一覧に出ない。
#   **電話から答える道が無い** = 窓は在るのに永久に使えない。
#
# ★この台本は**答えない**。検出して名前を付けて出すだけ。
#   自動化に安全確認を押させないのは DESIGN §3 の一線で、押す物が
#   「描画方式の勧誘」か「破壊的操作の確認」かを、機械は事前に見分けられない。
#   だから見つけたら人へ出す。押すのは人。
#
# 判定(3つ全部が要る。1つでも欠ければ「使える窓」ではない):
#   1. 窓が在る
#   2. その窓のペイン id が、登録簿 `panes/*.json` のどれかの `pane` と一致する
#   3. その登録の `pid` が今も生きている(古い登録が生き残ると、死んだペインを指す)
#
# 終了コード(状態を混ぜない):
#   0  … 使える(3つ揃っている)
#   1  … ★窓は在るが登録に届いていない = 固まっている疑い。画面の末尾を出す
#   10 … tmux か session がまだ無い(異常ではない。鎖②が 60 秒以内に作る)
#   11 … 窓がまだ無い(異常ではない。鎖③が作る)
#   3  … 監視自体が壊れている(登録簿が読めない等)
set -uo pipefail
SESSION=${RC_PHONE_SESSION:-work}
WINDOW=${RC_PHONE_WINDOW:-phone}
TMUX_BIN=${RC_PHONE_TMUX:-/opt/homebrew/bin/tmux}
PANES_DIR=${RC_PHONE_PANES_DIR:-$HOME/.rc-backend/panes}
CAPTURE_LINES=${RC_PHONE_CAPTURE_LINES:-12}

[ -x "$TMUX_BIN" ] || { echo "tmux が無い: $TMUX_BIN" >&2; exit 3; }
"$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null || { echo "session '$SESSION' がまだ無い"; exit 10; }

read -r pane pane_pid <<<"$("$TMUX_BIN" list-panes -t "=$SESSION:$WINDOW" -F '#{pane_id} #{pane_pid}' 2>/dev/null | head -1)"
[ -n "${pane:-}" ] || { echo "窓 '$WINDOW' がまだ無い"; exit 11; }

[ -d "$PANES_DIR" ] || { echo "登録簿の dir が無い: $PANES_DIR" >&2; exit 3; }

# 登録簿から「このペインを指していて、pid が生きている」行を探す。
# ★ペイン id だけの一致では足りない(Codex 2026-08-26)。tmux の `%N` は**再利用される**ので、
#   古い登録が残っていて id が回ってくると、別物のペインを「使える」と読む。
#   登録の pid が**そのペインの子孫か**まで確かめる = 登録側を変えずに偽造を潰せる。
hit="$(/usr/bin/python3 - "$PANES_DIR" "$pane" "${pane_pid:-0}" <<'PY'
import json, os, subprocess, sys
d, want = sys.argv[1], sys.argv[2]
pane_pid = int(sys.argv[3] or 0)

def descends_from(pid, root, limit=12):
    """pid が root(ペインの shell)の子孫か。root 自身も真。"""
    if root <= 0:
        return True                    # ペインの pid が取れない = この検査は諦める
    cur = pid
    for _ in range(limit):
        if cur == root:
            return True
        if cur <= 1:
            return False
        try:
            out = subprocess.run(["/bin/ps", "-o", "ppid=", "-p", str(cur)],
                                 capture_output=True, text=True, timeout=5)
        except Exception:
            return False
        t = out.stdout.strip()
        if not t.isdigit():
            return False
        cur = int(t)
    return False
try:
    names = os.listdir(d)
except Exception as e:
    sys.stderr.write("登録簿が読めない: %s\n" % e); sys.exit(3)
for n in names:
    if not n.endswith(".json"):
        continue
    try:
        r = json.load(open(os.path.join(d, n)))
    except Exception:
        # 1本壊れていても他を諦めない。壊れている事自体は下で数える。
        continue
    if r.get("pane") != want:
        continue
    pid = r.get("pid")
    if not isinstance(pid, int) or isinstance(pid, bool):
        continue
    try:
        os.kill(pid, 0)          # 生存確認のみ(シグナルは送らない)
    except ProcessLookupError:
        continue                  # 古い登録 = 死んだペインを指している
    except PermissionError:
        pass                      # 別 uid = 生きてはいる
    # ★そのペインの子孫でなければ、id が一致していても別物(再利用された id)
    if not descends_from(pid, pane_pid):
        continue
    print(r.get("session_id", ""))
    sys.exit(0)
sys.exit(1)
PY
)"; hrc=$?

[ "$hrc" -eq 3 ] && exit 3
if [ "$hrc" -eq 0 ] && [ -n "$hit" ]; then
    echo "使える: window=$SESSION:$WINDOW pane=$pane session=$hit"
    exit 0
fi

echo "★窓は在るが登録に届いていない(pane=$pane)。中で何かが答えを待っている疑い。"
echo "  ここは自動で押さない —— 押す物が描画方式の勧誘か破壊的操作の確認かを機械は見分けられない。"
echo "  画面の末尾 ${CAPTURE_LINES} 行:"
"$TMUX_BIN" capture-pane -p -t "=$SESSION:$WINDOW" 2>/dev/null \
    | grep -vE '^\s*$' | tail -"$CAPTURE_LINES" | sed 's/^/    /'
echo "  人が答える: ${TMUX_BIN} send-keys -t $SESSION:$WINDOW <選択> && ${TMUX_BIN} send-keys -t $SESSION:$WINDOW Enter"
exit 1
