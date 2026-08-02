#!/bin/bash
# ensure-phone-window.sh — 鎖③。無人再起動の後、tmux の中に「話せる相手」を1枚だけ用意する。
#
# 位置づけ(DESIGN.md §6「常設の完了条件は『サーバが上がる』ではない — 鎖4本」):
#   ① 機械が起きて rc-backend が上がる  … launchd(com.edith.rc-backend)
#   ② tmux `work` が在る                … 既存の com.tom.work-tmux(60秒ごと・**素の shell**)
#   ③ その中で Claude Code が走る        … ★これ。今まで誰も戻していなかった
#   ④ 登録簿に載る                      … 起動を `rc-claude` 経由にする事で満たす(statusLine が書く)
#
# ★採らなかった形(DESIGN §6 に理由の全文):既存ペインが「素の shell に見えたら」
#   `rc-claude` を打ち込む案は捨てた。`pane_current_command` は**人がコマンドを打つ合間**と
#   区別が付かず、Tom が半分打ちかけた行を壊して実行し得る。ここは **window を1枚足すだけ**で、
#   既存のペインには一切触れない。新しい window は定義上まだ誰も使っていない。
#
# 冪等の取り方 = **window の有無**。「claude が走っているか」では判定しない。
#   週次上限に当たっている間、TUI は上限の画面のまま**生き続ける**ので、
#   プロセスの中身で判定すると上限画面の window が 60 秒ごとに増え続ける。
#
# 終了コード(**状態を混ぜない**。混ざった時点で計器として壊れる):
#   0  … 在る(既に在った / 今作った)
#   10 … tmux か session がまだ無い = 異常ではない。work-tmux が 60 秒以内に作る
#   20 … 起動する場所が Claude Code に**未信頼** → 作らない(作れば信頼確認の画面で固まり、
#         電話からは答える道が無い = DESIGN §3 の穴。自動化に安全確認を押させない)
#   21 … 起動する実行ファイルが無い
#   22 … 信頼を**確かめられなかった**(~/.claude.json か python3 が読めない)。20 と混ぜない
#   30 … 短時間に作り直し過ぎ = 何かが即死している。作り続けない(fail-closed)
#   31 … 同名の window が2枚以上在る。どれが本物か機械には決められないので**触らない**
#   40 … 別の実行が走っている(lock)
#
# 出力の作法(ここを間違えると log が計器でなく壁紙になる):
#   ・**状態が変わった時だけ**書く。同じ状態が続く間は 1 時間に 1 行まで。
#     60 秒ごとに同じ行を出すと 1 日 1440 行になり、最初の 1 回(= 原因)が埋まる。
#   ・逆に**完全な無言にもしない**。一番怖い壊れ方は「静かに永久に何もしない」で、
#     それは正常と見分けが付かない。だから 10/20/21/22/30 は必ず**最初の 1 回**を書く。
#
# 生存の記録は**2つに分ける**(2026-08-02 Codex 指摘。ここは元は1つで、間違っていた):
#   $ATTEMPT … 走った時刻。**一番上で**触るので「走った」しか意味しない
#   $SUCCESS … ★「在る」を確かめられた時刻。既存 window の生存確認 or 作成の読み戻しに成功した時だけ
#   1つに混ぜていた頃は、信頼判定が永久に失敗していても(exit 22)心拍だけは新しく、
#   **壊れている状態が健康と同じ顔をしていた**。「走った」と「効いている」は別の状態で、
#   1つの計器に混ぜた時点でその計器は壊れている。
# ★読む人への約束: **静か = 「変化なし」であって「正常」ではない**。
#   効いている事を確かめたいなら $SUCCESS の mtime を見る($ATTEMPT ではなく)。
set -u

SESSION=${RC_PHONE_SESSION:-work}
WINDOW=${RC_PHONE_WINDOW:-phone}
CWD=${RC_PHONE_CWD:-/Users/edith/Projects}
CMD=${RC_PHONE_CMD:-/Users/edith/.local/bin/rc-claude}
TMUX_BIN=${RC_PHONE_TMUX:-/opt/homebrew/bin/tmux}
# ★絶対パスで持つ。launchd 下の PATH に依存させない(Codex 2026-08-02)。
# 実測では plist の PATH で /usr/bin/python3 に解決するが、**解決する事を確かめた**という
# 事実と、**解決に依存しない**設計は別物。無ければ 22(= 確かめられない)で作らない。
PY_BIN=${RC_PHONE_PYTHON:-/usr/bin/python3}
TRUST_FILE=${RC_PHONE_TRUST_FILE:-$HOME/.claude.json}
STATE_DIR=${RC_PHONE_STATE_DIR:-$HOME/.rc-backend}
PANE_PATH=${RC_PHONE_PATH:-/Users/edith/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin}
BURST_MAX=${RC_PHONE_BURST_MAX:-3}
BURST_WINDOW_S=${RC_PHONE_BURST_WINDOW_S:-600}
REPEAT_S=${RC_PHONE_REPEAT_S:-3600}
VERBOSE=${RC_PHONE_VERBOSE:-0}

BIRTHS="$STATE_DIR/phone-window.births"
ATTEMPT="$STATE_DIR/phone-window.attempt"   # 走った(それだけ)
SUCCESS="$STATE_DIR/phone-window.success"   # ★在る事を確かめられた
LOCK="$STATE_DIR/phone-window.lock"
STATE_F="$STATE_DIR/phone-window.state"

say() { printf '%s ensure-phone-window: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
chatty() { [ "$VERBOSE" = "1" ] && say "$@"; return 0; }

# note <状態キー> <行...> — 状態が前回と違えば書く。同じなら $REPEAT_S 秒に 1 度だけ書く。
# 「変わった事」と「続いている事」を両方読めるようにする為で、静かにする事自体が目的ではない。
note() {
    local key=$1; shift
    local now_s prev_key="" prev_t=0
    now_s=$(date +%s)
    if [ -f "$STATE_F" ]; then read -r prev_key prev_t <"$STATE_F" 2>/dev/null || true; fi
    case "${prev_t:-}" in ''|*[!0-9]*) prev_t=0 ;; esac
    printf '%s %s\n' "$key" "$now_s" >"$STATE_F" 2>/dev/null || true
    if [ "$prev_key" = "$key" ] && [ $((now_s - prev_t)) -lt "$REPEAT_S" ]; then
        return 0
    fi
    local m
    for m in "$@"; do say "$m"; done
    return 0
}

mkdir -p "$STATE_DIR" 2>/dev/null || true

# 走った事の証拠。中身ではなく mtime を見る(60秒ごとに書き足すと log が育つだけ)。
# ★これは「走った」しか意味しない。効いているかは $SUCCESS の方。
: >"$ATTEMPT" 2>/dev/null || true

# 排他。launchd は StartInterval の重複起動はしないが、手で叩く経路が在る。
# 二重に走ると `phone` が2枚出来る(検査 → 作成 の間が競合する)。
if ! mkdir "$LOCK" 2>/dev/null; then
    # 取り残された lock を無限に信じない。10 分より古ければ壊す
    if [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin -10 2>/dev/null)" ]; then
        rmdir "$LOCK" 2>/dev/null || true
        mkdir "$LOCK" 2>/dev/null || { note lock-stuck "lock を取れない: $LOCK"; exit 40; }
    else
        chatty "別の実行が走っている"
        exit 40
    fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# --- ② が居るか。居ないのは異常ではない(work-tmux が 60 秒以内に作る) ---
if [ ! -x "$TMUX_BIN" ]; then
    note tmux-missing "tmux が無い: $TMUX_BIN"
    exit 10
fi
if ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
    # 冷起動直後は正常にここを通る(work-tmux が 60 秒以内に作る)。1 回だけ書いて、
    # 続く限り 1 時間に 1 行。**永久に session が来ない**壊れ方を無言にしない為。
    note no-session "session '$SESSION' がまだ無い(work-tmux 待ち)"
    exit 10
fi

# --- 既に在るなら何もしない。ここが冪等の本体 ---
# ★数える。在る/無いの2値で見ていたのが 2026-08-02 の Codex 指摘で、tmux は**同名 window を許す**。
#   2枚在る状態で「在る」と答えると、増えた事に永久に気付かない。
existing=$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -cxF "$WINDOW")
if [ "$existing" -gt 1 ]; then
    # ★消して1枚に揃えない。どちらかで人が話している可能性が在り、機械には見分けが付かない。
    #   「正しい状態に直す」より「壊さない」を採る(既存ペインに触れないという全体方針と同じ)。
    note duplicate \
        "'$SESSION:$WINDOW' が ${existing} 枚在る。どれが本物か機械には決められないので触らない" \
        "  ★同名が2枚在ると tmux は '$SESSION:$WINDOW' を**解決しない**(can't find window)。" \
        "    名前では見る事も閉じる事も出来ないので、window_id で扱う:" \
        "      tmux list-windows -t $SESSION -F '#{window_id} #{window_name} #{pane_current_command}'" \
        "      tmux capture-pane -p -t @<id> | tail -30   # 中身を見てから" \
        "      tmux kill-window -t @<id>                  # 余分な方を人が閉じる"
    exit 31
fi
if [ "$existing" -eq 1 ]; then
    # ★中身が生きているか。tmux の remain-on-exit が on だと、起動した物が死んでも
    #   **名前だけの抜け殻**が残る。名前で冪等を取っている以上、抜け殻を「在る」と数えると
    #   永久に偽の健康を報告する(実測: edith の remain-on-exit は今 off。**既定に依存しない**)。
    alive=$("$TMUX_BIN" list-panes -t "$SESSION:$WINDOW" -F '#{pane_dead}' 2>/dev/null | grep -cx 0)
    if [ "$alive" -ge 1 ]; then
        : >"$SUCCESS" 2>/dev/null || true    # ★ここだけが「効いている」の記録
        note ok        # 正常。書かないが、状態は記録する(次に崩れた時に必ず 1 行出る)
        chatty "'$SESSION:$WINDOW' は既に在る(生きているペイン ${alive})"
        exit 0
    fi
    # 抜け殻。中で走っている物が無いので閉じてよい(= 会話を壊さない)。作り直しは下の関門を通る
    note dead-shell "'$SESSION:$WINDOW' は在るが中身が全部死んでいる(抜け殻)。閉じて作り直す"
    "$TMUX_BIN" kill-window -t "$SESSION:$WINDOW" 2>/dev/null || true
fi

# --- 作る前の関門1: 起動する場所が信頼されているか ---
# 未信頼の dir で起動すると Claude Code は「このフォルダを信頼するか」の選択画面で止まる。
# その画面には**電話から答える道が無い**(API に key 送信の口が無い = DESIGN §3)。
# = 黙って死ぬ window が 1 枚増えるだけなので、作らない。
if [ ! -x "$PY_BIN" ]; then
    note no-python \
        "JSON を読む物が無いので信頼を確かめられない: $PY_BIN" \
        "  作らずに降りる(未信頼の場所で起動する方が高くつく)"
    exit 22
fi
trust_verdict=$(TRUST_FILE="$TRUST_FILE" CWD="$CWD" "$PY_BIN" - <<'PY' 2>/dev/null
import json, os, sys
try:
    with open(os.environ["TRUST_FILE"], encoding="utf-8") as f:
        j = json.load(f)
except Exception:
    print("unknown"); sys.exit(0)
p = (j.get("projects") or {}).get(os.environ["CWD"])
print("trusted" if isinstance(p, dict) and p.get("hasTrustDialogAccepted") is True else "untrusted")
PY
)
case "${trust_verdict:-unknown}" in
    trusted) ;;
    untrusted)
        note untrusted \
            "起動する場所が未信頼なので window を作らない: $CWD" \
            "  (作れば信頼確認の選択画面で固まる。電話からその画面には答えられない)" \
            "  直し方: その dir で一度 claude を人が起動して信頼するか、RC_PHONE_CWD を信頼済みの dir にする"
        exit 20
        ;;
    *)
        note trust-unknown \
            "信頼を確かめられない(読めない: $TRUST_FILE)。作らずに次の tick で再試行する" \
            "  ここが続くと**永久に何も作らない**。python3 と $TRUST_FILE を確かめる事"
        exit 22
        ;;
esac

# --- 作る前の関門2: 起動する物が在るか ---
if [ ! -x "$CMD" ]; then
    note no-cmd "起動する実行ファイルが無い(または実行権が無い): $CMD"
    exit 21
fi

# --- 作る前の関門3: 作り直し過ぎていないか ---
# window が消えている = 直前に作った物が死んだ、という意味。即死する物を 60 秒ごとに
# 作り続けると、原因は直らないまま log と process だけが回る。上限で止めて大声で言う。
now=$(date +%s)
recent=0
if [ -f "$BIRTHS" ]; then
    while read -r t; do
        case "$t" in ''|*[!0-9]*) continue ;; esac
        [ $((now - t)) -lt "$BURST_WINDOW_S" ] && recent=$((recent + 1))
    done <"$BIRTHS"
fi
if [ "$recent" -ge "$BURST_MAX" ]; then
    note burst \
        "直近 ${BURST_WINDOW_S}秒 に ${recent} 回作り直している = 起動した物が即死している。作るのを止める" \
        "  見る所: tmux capture-pane -p -t ${SESSION}:${WINDOW} / $CMD を手で叩く" \
        "  再開: rm $BIRTHS"
    exit 30
fi

# --- 作る。既存の window/pane には触れない(new-window だけ) ---
# PATH を明示するのは、`rc-claude` の中の `exec claude` が PATH に依存する為。
# tmux server の global env にも入っているが、**そこに依存しない形**にしておく。
# ★`-P -F` で**作った物の id を受け取る**(Codex 2026-08-02)。名前で引き直すと、
#   同名の window が別に在った時に**別人を読み戻して「作れた」と言う**事が起き得る。
#   id は一意なので、以降の操作(名前固定・読み戻し)は全部この id に対して行う。
created=$("$TMUX_BIN" new-window -d -P -F '#{window_id} #{pane_id}' \
        -t "$SESSION" -n "$WINDOW" -c "$CWD" -e "PATH=$PANE_PATH" "exec $CMD" 2>&1)
if [ $? -ne 0 ] || [ -z "$created" ]; then
    note new-window-failed "new-window に失敗した(session=$SESSION window=$WINDOW cwd=$CWD): $created"
    exit 1
fi
win_id=${created%% *}
pane_id=${created##* }

# ★名前を固定する。冪等の鍵が window 名なので、名前が動くと 60 秒ごとに window が増え続ける。
# 実測(2026-08-02、tmux 3.6a): `new-window -n` で作った window は automatic-rename が
# 自動的に 0 になるので既定でも動かない。それでも明示するのは、**既定に依存しない**為
# (`work:0` は -n 無しで作られていて auto=1、実際に `2.1.220` に化けている = 化ける側の実例)。
"$TMUX_BIN" set-option -t "$win_id" automatic-rename off 2>/dev/null || true

# 作った「つもり」で終わらせない。**id で**観測して初めて作られた事にする
pane=$("$TMUX_BIN" list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null | head -1)
if [ -z "$pane" ] || [ "$pane" != "$pane_id" ]; then
    note pane-missing "new-window は通ったのに読み戻せない($win_id / 期待 $pane_id / 実際 ${pane:-無})"
    exit 1
fi

printf '%s\n' "$now" >>"$BIRTHS"
# 記録は必要な分だけ残す(上限判定に使う窓の 2 倍)
if [ "$(wc -l <"$BIRTHS" 2>/dev/null || echo 0)" -gt 50 ]; then
    tail -20 "$BIRTHS" >"$BIRTHS.tmp" && mv "$BIRTHS.tmp" "$BIRTHS"
fi

# 作成だけは**毎回書く**(note を通さない)。実際に起きた事で、しかも
# 「30 分おきに死んで作り直されている」形は 1 行ずつ残っていないと見えない。
# 状態だけは記録しておく = 次に崩れた時の 1 行目が必ず出る。
printf 'created %s\n' "$now" >"$STATE_F" 2>/dev/null || true
: >"$SUCCESS" 2>/dev/null || true    # ★読み戻せた時だけ。ここと既存確認の 2 箇所以外では触らない
say "作った: $SESSION:$WINDOW win=$win_id pane=$pane cwd=$CWD cmd=$CMD"
exit 0
