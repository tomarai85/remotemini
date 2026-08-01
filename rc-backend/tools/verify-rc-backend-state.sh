#!/bin/bash
# verify-rc-backend-state.sh — edith の常設 rc-backend が **本当に動いているか / 本当に止まるか**を
# 層ごとの観測値で JSON に落とす。AI の主観(「起動しました」)を証拠として使わない為の道具。
#
# 出典: ~/.claude/rules/safety-core.md HARD GATE 1。あちらの `verify-production-stop.sh` は
# **停止方向**の判定器で、自動送信系(yoda / client-a)の形に合わせてある。こちらはその鏡:
#   - 常設を**入れた**時に要るのは「全層が『動いている』で一致するか」+「止められるか」
#   - 「止められるか」を測らずに常駐を置くと、消せない物を人の機械に残す事になる
#
# ★HTTP の応答コードを同一性の証拠に使わない。8787 を掴んだままの**古いプロセス**も
#   同じ 401 を返す。だから PID で見る:
#     launchd の job の pid == 8787 の listener の pid == 我々の起動ラッパの子
#   この3つが一致して初めて「今のコードが動いている」と言える(deploy-to-edith.sh:6 と同じ理由)。
#
# 使い方:
#   bash tools/verify-rc-backend-state.sh                 # 観測だけ(何も変えない)
#   bash tools/verify-rc-backend-state.sh --prove-stop    # ★止めて→全層の不在を観測→戻す
#   VERIFY_ARTIFACT_DIR=... bash tools/verify-rc-backend-state.sh   # 保存先を変える
#
# 終了コード: 0 = 期待通り / 1 = 層が食い違う / 2 = 到達不能
#
# ★`--prove-stop` は **bootout する**(KeepAlive=true なので SIGTERM では止まらない)。
#   plist の TEARDOWN 手順そのもの。数秒で戻す。実行中に電話が繋いでいれば SSE は切れる
#   (電話側は再接続する = §2.11)。人が使っている時間帯には回さない事。
set -u

HOST="${RC_EDITH_HOST:-edith@10.0.0.0}"
JOB="gui/501/com.edith.rc-backend"
ART_DIR="${VERIFY_ARTIFACT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.harness/evidence-$(date +%Y-%m-%d)}"
MODE="observe"
[ "${1:-}" = "--prove-stop" ] && MODE="prove-stop"
# 第2引数 = プロセスプローブのパターン。既定でよい。**当たらない語を渡すのが負の対照**。
PROC_PAT="${2:-node src/server.mjs}"

mkdir -p "$ART_DIR" || exit 2
OUT="$ART_DIR/verify-rc-backend-${MODE}-$(date +%Y%m%d-%H%M%S).json"

# remote 台本は**引用符付きヒアドキュメント**で渡す(verify-on-edith.sh 冒頭の理由と同じ:
# 二重引用符の中に組み立てると、送る前にこちらの shell がバッククォートと `$` を食う)。
#
# ★`if ! ssh ...; then rc=$?` と書いてはいけない。`!` で反転した後の状態が条件の状態になるので、
#   then 節に入った時点で `$?` は **0**。実際に 8/02 03:55 の負の対照で
#   「★観測に失敗した(exit=0)」という自己矛盾した行を出し、**検査器が exit 0 を返した**
#   (= 呼び出し側は「拒否」を「成功」と読む = 検査器における fail-open)。
#   → 素直に走らせて終了コードをそのまま拾う。
#
# ★★引数は `printf %q` で包む。**ssh は引数を1本の文字列に潰して remote の shell に渡す**ので、
#   `ssh host bash -s -- "$MODE" "node src/server.mjs"` は remote 側で
#   `$2="node" / $3="src/server.mjs"` に割れる。実際 8/02 03:55 にこれを踏み、
#   pgrep のパターンが `node` に化けて **EDITH 自身の常駐6本**(edith-claude-http 等)を
#   拾い、「bootout 後も残留プロセスがある」という**偽の赤**を出した。
#   この罠は verify-on-edith.sh:9-24 に既に書いてあったのに、こちらで適用し忘れた。
ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" bash -s -- "$(printf %q "$MODE")" "$(printf %q "$PROC_PAT")" > "$OUT" <<'REMOTE'
job=gui/501/com.edith.rc-backend
label=com.edith.rc-backend
plist=/Users/edith/Library/LaunchAgents/$label.plist

jobpid() { launchctl print "$job" 2>/dev/null | awk -F'= *' '/^[[:space:]]*pid =/ {print $2; exit}'; }
listener() { lsof -nP -iTCP:8787 -sTCP:LISTEN -t 2>/dev/null | head -1; }
httpcode() { curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8787/api/sessions 2>/dev/null || echo none; }
# 走っているサーバのプロセス。
# ★2026-08-02: 最初 `/Users/edith/rc-backend/src/server.mjs` で探して**常に空**だった。
#   実際の argv は `/opt/homebrew/bin/node src/server.mjs`(plist の WorkingDirectory 基準の
#   相対パス)。= 当たらないプローブが「残留プロセス無し」を毎回名乗る状態 =
#   赤が出せない検査。verify-on-edith.sh の `rc-e2e-*` と同じ型を、同じ夜に2度書いた。
#   → 下の `probe_blind` で「動いているのに空」を毎回自己検査する(盲なら判定を拒む)。
#   ★起動ラッパ(rc-backend-launch.sh)は `exec` で node に置き換わるので**残らない**
#     (PPID=1 で node が直接 launchd の子になる)。ラッパ名で探しても当たらないのが正常。
#   ★`$2` でパターンを差し替えられるのは**負の対照の為**。当たらない語を渡して、
#     この道具がちゃんと「盲だ」と言って止まるかを現物で確かめられる:
#       bash tools/verify-rc-backend-state.sh --prove-stop 当たらない語 → 止めずに中止する筈
PROC_PAT="${2:-node src/server.mjs}"   # ★関数の中の $2 は関数の引数。ここで受けておく
# ★argv だけで決めない。**作業ディレクトリで裏を取る**。この機械には EDITH 自身の node 常駐が
#   何本も居るので、パターンが少しでも緩むと他人のプロセスを「rc-backend の残留」と呼ぶ
#   (実際 03:55 にそれをやった)。cwd が /Users/edith/rc-backend の物だけを我々の物とする。
#   代償: 別の場所から起動された我々のプロセスは見えない。今の起動経路は launchd の
#   WorkingDirectory 固定なので成立する。**起動経路を増やしたらこの行を疑う事**。
wrapperkids() {
  for p in $(pgrep -f "$PROC_PAT" 2>/dev/null); do
    d=$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | grep '^n' | head -1)
    [ "$d" = "n/Users/edith/rc-backend" ] && printf '%s ' "$p"
  done
}
serve_target() {
  /Applications/Tailscale.app/Contents/MacOS/Tailscale serve status 2>/dev/null \
    | tr -d ' ' | grep -o '127.0.0.1:8787' | head -1
}

# 観測を1組ぶん JSON の断片で出す。**判定はしない**(判定は下でまとめて行う)。
snap() {
  p=$(jobpid); l=$(listener); c=$(httpcode); k=$(wrapperkids); s=$(serve_target)
  printf '{"phase":"%s","at":"%s","launchd_job_present":%s,"launchd_pid":"%s","port8787_listener_pid":"%s","server_mjs_pids":"%s","http_code":"%s","tailscale_serve_to_8787":%s}' \
    "$1" "$(date -Iseconds)" \
    "$(launchctl print "$job" >/dev/null 2>&1 && echo true || echo false)" \
    "${p:-}" "${l:-}" "${k% }" "$c" \
    "$([ -n "$s" ] && echo true || echo false)"
}

mode="$1"
echo '{'
echo "  \"service\": \"$label\","
echo "  \"host\": \"$(hostname -s)\","
echo "  \"mode\": \"$mode\","
echo "  \"plist_present\": $([ -f "$plist" ] && echo true || echo false),"
echo "  \"deployed_head\": \"$(cd /Users/edith/rc-backend 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo 'no-git(rsync で .git を送っていない = 正常)')\","
echo "  \"node\": \"$(/opt/homebrew/bin/node -v 2>/dev/null)\","

if [ "$mode" = "observe" ]; then
  echo "  \"snapshots\": [$(snap running)],"
  p=$(jobpid); l=$(listener); c=$(httpcode); k=$(wrapperkids)
  ok=true; why=""
  [ -n "$p" ] || { ok=false; why="${why}launchd job に pid が無い; "; }
  [ -n "$l" ] || { ok=false; why="${why}8787 に listener が居ない; "; }
  [ "$p" = "$l" ] || { ok=false; why="${why}launchd の pid($p)と 8787 の listener($l)が違う = 古い居座り; "; }
  [ "$c" = "401" ] || { ok=false; why="${why}HTTP が 401 でない($c)= 認証層が居ない; "; }
  # ★プローブの自己検査。動いているのにプロセスが1つも見えない = パターンが当たっていない。
  #   「残留無し」と言える道具かどうかを、毎回**動いている側で**確かめる。
  [ -z "$l" ] || [ -n "$k" ] || { ok=false; why="${why}★プローブが盲(listener は居るのに pgrep が0件)= この道具は不在を証明できない; "; }
  echo "  \"layers_agree_running\": $ok,"
  echo "  \"disagreement\": \"${why}\","
  echo "  \"verdict\": \"$([ "$ok" = true ] && echo '全層が RUNNING で一致' || echo '★層が食い違う')\","
  echo "  \"note\": \"応答コードだけでは同一性を証明しない。pid の一致まで見ている。\""
  echo '}'
  [ "$ok" = true ] || exit 1
  exit 0
fi

# --- prove-stop: 止めて、全層の不在を観測して、戻す ---------------------------
before=$(snap "before")
# ★測る前にプローブの目を確かめる。動いている今、プロセスが1つも見えないなら、
#   停止後の「0件」も何も意味しない。**止める前に**拒む(止めてから気付いても遅い)。
if ! echo "$before" | grep -q '"server_mjs_pids":"[0-9]'; then
  echo "  \"snapshots\": [$before],"
  echo "  \"aborted\": true,"
  echo "  \"verdict\": \"★止めずに中止。動いている状態でプロセスプローブが0件 = 不在を証明できない道具\","
  echo "  \"note\": \"pgrep のパターンが当たっていない。当たらないプローブは停止後も0件を返し、それを『残留無し』と読んでしまう。\""
  echo '}'
  exit 1
fi
launchctl bootout "$job" 2>/dev/null
# 落ちるまで待つ。固定 sleep は速い機械で無駄、遅い機械で偽の赤。
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  [ -z "$(jobpid)" ] && [ -z "$(listener)" ] && break
done
stopped=$(snap "after-bootout")

launchctl bootstrap gui/501 "$plist" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  p=$(jobpid); l=$(listener)
  [ -n "$p" ] && [ "$p" = "$l" ] && break
done
back=$(snap "after-bootstrap")

echo "  \"snapshots\": [$before, $stopped, $back],"

# 判定: ①止めた時に4層すべて不在 ②戻した時に pid が一致して 401
sp=$(echo "$stopped" | grep -o '"launchd_pid":"[^"]*"' | cut -d'"' -f4)
sl=$(echo "$stopped" | grep -o '"port8787_listener_pid":"[^"]*"' | cut -d'"' -f4)
sk=$(echo "$stopped" | grep -o '"server_mjs_pids":"[^"]*"' | cut -d'"' -f4)
sj=$(echo "$stopped" | grep -o '"launchd_job_present":[a-z]*' | cut -d: -f2)
bp=$(echo "$back" | grep -o '"launchd_pid":"[^"]*"' | cut -d'"' -f4)
bl=$(echo "$back" | grep -o '"port8787_listener_pid":"[^"]*"' | cut -d'"' -f4)
bc=$(echo "$back" | grep -o '"http_code":"[^"]*"' | cut -d'"' -f4)

truly_stopped=true; why=""
[ "$sj" = "false" ] || { truly_stopped=false; why="${why}bootout 後も launchd の登録が残る; "; }
[ -z "$sp" ] || { truly_stopped=false; why="${why}bootout 後も job に pid($sp); "; }
[ -z "$sl" ] || { truly_stopped=false; why="${why}bootout 後も 8787 を掴む pid($sl)= 止まっていない; "; }
[ -z "$sk" ] || { truly_stopped=false; why="${why}bootout 後も server.mjs のプロセス($sk); "; }

restored=true
[ -n "$bp" ] && [ "$bp" = "$bl" ] || { restored=false; why="${why}戻した後 pid が一致しない(job=$bp listener=$bl); "; }
[ "$bc" = "401" ] || { restored=false; why="${why}戻した後 401 でない($bc); "; }

echo "  \"truly_stopped_at_bootout\": $truly_stopped,"
echo "  \"restored_after_bootstrap\": $restored,"
echo "  \"problems\": \"${why}\","
echo "  \"verdict\": \"$([ "$truly_stopped" = true ] && [ "$restored" = true ] && echo '止められる事と戻る事の両方を観測した' || echo '★どちらかが観測できなかった')\","
echo "  \"note\": \"KeepAlive=true なので SIGTERM では止まらない。真の停止は bootout のみ(plist の TEARDOWN と同じ)。\""
echo '}'
[ "$truly_stopped" = true ] && [ "$restored" = true ] || exit 1
exit 0
REMOTE
rc=$?

cat "$OUT"
echo "" >&2
echo "# artifact: $OUT" >&2
if [ "$rc" -ne 0 ]; then
  echo "★期待通りでない(exit=$rc)。上の JSON の verdict / problems を読む事。" >&2
fi
exit "$rc"
