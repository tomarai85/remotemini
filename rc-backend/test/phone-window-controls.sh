#!/bin/bash
# controls-for: tools/ensure-phone-window.sh
# phone-window-controls.sh — `tools/ensure-phone-window.sh`(鎖③)そのものへの対照。
#
# なぜ本物の tmux で回すか:
#   この台本の仕事は「**既存のペインに触れずに** window を1枚だけ足す」で、その性質は
#   偽 tmux では原理的に測れない(触れたかどうかは実際の pane pid でしか見えない)。
#   使い捨ての session 名(`rcphone-ctl-$$`)を建てて、そこだけで完結させる。
#   ★Tom の本物の `work` には**一切触れない**。名前も被らない。
#
# 何を見張っているか — 「作らない」側が本体:
#   window を作る失敗は目に見える。作ってはいけない時に作る失敗は**静かに死ぬ**:
#     - 未信頼の dir で作る → Claude Code は信頼確認の選択画面で固まる。
#       その画面には電話から答える道が無い(DESIGN §3 の穴)= 見えるが答えられない window が増える
#     - 即死する物を 60 秒ごとに作り直す → 原因は直らないまま process と log だけが回る
#   なので関門(20 / 21 / 22 / 30)には**変異**を当てて、緩めた版が実際に捕まる事まで確かめる。
#
# 使い方: bash test/phone-window-controls.sh   (ネットワークに出ない。tmux だけ使う)
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET="$SELF_DIR/../tools/ensure-phone-window.sh"
[ -f "$TARGET" ] || { echo "検査対象が無い: $TARGET" >&2; exit 2; }

TMUX_BIN=${TMUX_BIN:-$(command -v tmux)}
[ -x "$TMUX_BIN" ] || { echo "tmux が無いので測れない(環境の都合 = 判定不能)" >&2; exit 2; }

SESSION="rcphone-ctl-$$"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rcphone-ctl.XXXXXX") || exit 2

cleanup() {
  "$TMUX_BIN" kill-session -t "$SESSION" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0; FAIL=0
chk() { # chk <名前> <期待> <実際>
  if [ "$2" = "$3" ]; then printf 'OK  %s\n' "$1"; PASS=$((PASS+1))
  else printf 'NG  %s\n      期待=%s / 実際=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

# --- 道具立て ---------------------------------------------------------------
mkdir -p "$TMP/trusted" "$TMP/untrusted" "$TMP/state"
cat >"$TMP/stub" <<'STUB'
#!/bin/bash
# 本物の TUI の代わり。起動して生き続けるだけ(= 生きている限り window が残る)
exec sleep 600
STUB
chmod +x "$TMP/stub"
python3 - "$TMP" <<'PY'
import json, sys
tmp = sys.argv[1]
json.dump({"projects": {
    f"{tmp}/trusted": {"hasTrustDialogAccepted": True},
    f"{tmp}/untrusted": {"hasTrustDialogAccepted": False},
}}, open(f"{tmp}/claude.json", "w"))
PY

# run <cwd> <cmd> [script] -> 終了コードを $CODE、出力を $OUT に入れる
run() {
  local cwd=$1 cmd=$2 script=${3:-$TARGET}
  OUT=$(RC_PHONE_SESSION="$SESSION" RC_PHONE_WINDOW=phone \
        RC_PHONE_CWD="$cwd" RC_PHONE_CMD="$cmd" \
        RC_PHONE_TMUX="$TMUX_BIN" RC_PHONE_TRUST_FILE="$TMP/claude.json" \
        RC_PHONE_STATE_DIR="$TMP/state" RC_PHONE_PATH="$PATH" \
        bash "$script" 2>&1)
  CODE=$?
}
windows() { "$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | tr '\n' ',' ; }
phone_pane() { "$TMUX_BIN" list-panes -t "$SESSION:phone" -F '#{pane_id}' 2>/dev/null | head -1; }

echo "--- 作らない側(ここが本体) ---"

# C1: session がまだ無い。異常ではないので 10、しかも何も作らない
run "$TMP/trusted" "$TMP/stub"
chk "C1 session が無い時は 10(異常ではない)" "10" "$CODE"

"$TMUX_BIN" new-session -d -s "$SESSION" -c "$TMP" 'sleep 600' || { echo "使い捨て session を建てられない" >&2; exit 2; }
BASE_PANE=$("$TMUX_BIN" list-panes -t "$SESSION:0" -F '#{pane_id}' | head -1)
BASE_PID=$("$TMUX_BIN" list-panes -t "$SESSION:0" -F '#{pane_pid}' | head -1)

# C2: 信頼を確かめられない(ファイルが読めない)。20 と混ぜない
OUT=$(RC_PHONE_SESSION="$SESSION" RC_PHONE_CWD="$TMP/trusted" RC_PHONE_CMD="$TMP/stub" \
      RC_PHONE_TMUX="$TMUX_BIN" RC_PHONE_TRUST_FILE="$TMP/does-not-exist.json" \
      RC_PHONE_STATE_DIR="$TMP/state" bash "$TARGET" 2>&1); CODE=$?
chk "C2 信頼を確かめられない時は 22(未信頼の 20 と別)" "22" "$CODE"
chk "C2 その時 window を作っていない" "0" "$("$TMUX_BIN" list-windows -t "$SESSION" 2>/dev/null | grep -c phone)"

# C3: 未信頼。**ここで作ると電話から答えられない画面が生える**
run "$TMP/untrusted" "$TMP/stub"
chk "C3 未信頼の cwd では 20" "20" "$CODE"
chk "C3 その時 window を作っていない" "0" "$("$TMUX_BIN" list-windows -t "$SESSION" 2>/dev/null | grep -c phone)"

# C4: 起動する物が無い
run "$TMP/trusted" "$TMP/no-such-binary"
chk "C4 実行ファイルが無ければ 21" "21" "$CODE"
chk "C4 その時 window を作っていない" "0" "$("$TMUX_BIN" list-windows -t "$SESSION" 2>/dev/null | grep -c phone)"

echo "--- 作る側 ---"

# C5: 素直な成功。**既存の window には触れない**
run "$TMP/trusted" "$TMP/stub"
chk "C5 信頼済み + 実行ファイル在り → 0" "0" "$CODE"
chk "C5 phone window が1枚だけ在る" "1" "$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_name}' | grep -cx phone)"
chk "C5 既存 window 0 の pane が入れ替わっていない" "$BASE_PANE" "$("$TMUX_BIN" list-panes -t "$SESSION:0" -F '#{pane_id}' | head -1)"
chk "C5 既存 window 0 のプロセスが入れ替わっていない" "$BASE_PID" "$("$TMUX_BIN" list-panes -t "$SESSION:0" -F '#{pane_pid}' | head -1)"
chk "C5 既存 window 0 のペインが増えていない" "1" "$("$TMUX_BIN" list-panes -t "$SESSION:0" 2>/dev/null | wc -l | tr -d ' ')"
PHONE_PANE=$(phone_pane)

# C5b: 名前が動かない事。冪等の鍵が window 名なので、tmux の automatic-rename に
# 名前を書き換えられると「無いから作る」を 60 秒ごとに繰り返して window が増え続ける。
# (この session の window 0 は -n 無しで作ってあるので、化ける側の実例が同居している)
sleep 2
chk "C5b 走らせたまま名前が動かない(automatic-rename に食われない)" \
    "1" "$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_name}' | grep -cx phone)"
chk "C5b 名前を自動で書き換えない設定になっている" \
    "0" "$("$TMUX_BIN" display-message -p -t "$SESSION:phone" '#{automatic-rename}')"
chk "C5b 参考: -n 無しで作った window 0 の方は書き換える側" \
    "1" "$("$TMUX_BIN" display-message -p -t "$SESSION:0" '#{automatic-rename}')"

# C6: 冪等。二度目は**作り直さない**(pane が同じ = 同じプロセスが生きたまま)
run "$TMP/trusted" "$TMP/stub"
chk "C6 二度目も 0" "0" "$CODE"
chk "C6 二度目は作り直していない(pane が同じ)" "$PHONE_PANE" "$(phone_pane)"
chk "C6 window は増えていない" "1" "$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_name}' | grep -cx phone)"

echo "--- 作り直し過ぎの関門 ---"

# C7: 即死する物を 60 秒ごとに作り続ける形を止める
"$TMUX_BIN" kill-window -t "$SESSION:phone" 2>/dev/null
now=$(date +%s); : >"$TMP/state/phone-window.births"
for i in 1 2 3; do echo "$now" >>"$TMP/state/phone-window.births"; done
run "$TMP/trusted" "$TMP/stub"
chk "C7 直近に作り直し過ぎていたら 30" "30" "$CODE"
chk "C7 その時 window を作っていない" "0" "$("$TMUX_BIN" list-windows -t "$SESSION" 2>/dev/null | grep -c phone)"
# 窓の外の記録は数えない(でないと一度当たった上限が永久に解けない)
: >"$TMP/state/phone-window.births"
for i in 1 2 3; do echo "$((now - 4000))" >>"$TMP/state/phone-window.births"; done
run "$TMP/trusted" "$TMP/stub"
chk "C7 古い記録は数えない(窓の外は忘れる)" "0" "$CODE"

echo "--- 変異(上の関門が空振りしていない事) ---"
# 関門を1つずつ**緩めた**写しを作り、C3 / C7 が緑に化ける事を確かめる。
# 化けないなら、その対照は関門を測っていない = 在っても意味が無い。
"$TMUX_BIN" kill-window -t "$SESSION:phone" 2>/dev/null

# M1: 信頼判定を「常に trusted」に緩める → C3(未信頼)が window を作ってしまうはず
sed 's/^print("trusted" if isinstance.*$/print("trusted")/' "$TARGET" >"$TMP/mut-trust.sh"
if cmp -s "$TARGET" "$TMP/mut-trust.sh"; then
  chk "M1 変異が当たっている(写しが本物と違う)" "different" "same"
else
  : >"$TMP/state/phone-window.births"
  run "$TMP/untrusted" "$TMP/stub" "$TMP/mut-trust.sh"
  chk "M1 信頼判定を外すと未信頼でも作ってしまう(= C3 は本物を測っている)" "0" "$CODE"
  chk "M1 実際に window が生えた" "1" "$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_name}' | grep -cx phone)"
  "$TMUX_BIN" kill-window -t "$SESSION:phone" 2>/dev/null
fi

# M2: 作り直し上限を実質無限に緩める → C7 が緑に化けるはず
sed 's/^BURST_MAX=.*$/BURST_MAX=999999/' "$TARGET" >"$TMP/mut-burst.sh"
if cmp -s "$TARGET" "$TMP/mut-burst.sh"; then
  chk "M2 変異が当たっている(写しが本物と違う)" "different" "same"
else
  now=$(date +%s); : >"$TMP/state/phone-window.births"
  for i in 1 2 3; do echo "$now" >>"$TMP/state/phone-window.births"; done
  run "$TMP/trusted" "$TMP/stub" "$TMP/mut-burst.sh"
  chk "M2 上限を外すと作り直し続ける(= C7 は本物を測っている)" "0" "$CODE"
  "$TMUX_BIN" kill-window -t "$SESSION:phone" 2>/dev/null
fi

echo "--- log の作法(静かにする。ただし黙り込まない) ---"
# 一番怖い壊れ方は「静かに永久に何もしない」で、それは正常と見分けが付かない。
# かといって 60 秒ごとに同じ行を出すと 1 日 1440 行になり、最初の 1 回(= 原因)が埋まる。
# 折衷 = 「状態が変わった時に書く / 続く間は $RC_PHONE_REPEAT_S 秒に 1 度」。
# ★測るのは3つ: 最初の1回は必ず出る / 二度目は消える / **黙っても終了コードは変わらない**。
mkdir -p "$TMP/state-log"
runlog() { # runlog <cwd> <cmd> [REPEAT_S]
  OUT=$(RC_PHONE_SESSION="$SESSION" RC_PHONE_WINDOW=phone \
        RC_PHONE_CWD="$1" RC_PHONE_CMD="$2" \
        RC_PHONE_TMUX="$TMUX_BIN" RC_PHONE_TRUST_FILE="$TMP/claude.json" \
        RC_PHONE_STATE_DIR="$TMP/state-log" RC_PHONE_PATH="$PATH" \
        RC_PHONE_REPEAT_S="${3:-3600}" bash "$TARGET" 2>&1)
  CODE=$?
}
"$TMUX_BIN" kill-window -t "$SESSION:phone" 2>/dev/null

# L1: 同じ状態が続く間の口数
runlog "$TMP/untrusted" "$TMP/stub"; L1_CODE=$CODE
chk "L1 最初の1回は必ず書く" "1" "$(printf '%s\n' "$OUT" | grep -c '未信頼')"
runlog "$TMP/untrusted" "$TMP/stub"
chk "L1 二度目は書かない(log を壁紙にしない)" "0" "$(printf '%s\n' "$OUT" | grep -c '未信頼')"
chk "L1 ★黙っても終了コードは同じ(静か=成功、にしない)" "20 20" "$L1_CODE $CODE"

# L2: 状態が変われば必ず書く(前の状態に埋もれない)
runlog "$TMP/trusted" "$TMP/no-such-binary"
chk "L2 状態が変われば書く" "1" "$(printf '%s\n' "$OUT" | grep -c '実行ファイルが無い')"
chk "L2 その時の exit は 21" "21" "$CODE"

# L3: 抑制そのものを外すと二度目も出る = L1 が抑制を測っている証明(変異と同じ役)
runlog "$TMP/untrusted" "$TMP/stub" 0
runlog "$TMP/untrusted" "$TMP/stub" 0
chk "L3 抑制を外せば二度目も書く(= L1 は本物を測っている)" "1" "$(printf '%s\n' "$OUT" | grep -c '未信頼')"

# L4: 正常側の口数。作った時は毎回書き、既に在る時は無言
runlog "$TMP/trusted" "$TMP/stub"
chk "L4 作った時は必ず書く" "1" "$(printf '%s\n' "$OUT" | grep -c '作った')"
runlog "$TMP/trusted" "$TMP/stub"
chk "L4 既に在る時は無言" "" "$OUT"
chk "L4 その無言は exit 0" "0" "$CODE"

# L5: ★「無言 = 走っていない」ではない事。走った証拠は mtime で見る、と説明書に書いた以上、
#     その mtime が本当に進む事を測っておく。ここが嘘だと生存確認の手段が全部消える。
AT="$TMP/state-log/phone-window.attempt"
SU="$TMP/state-log/phone-window.success"
prev_at=$(stat -f %m "$AT" 2>/dev/null || echo 0)
sleep 1
runlog "$TMP/trusted" "$TMP/stub"
now_at=$(stat -f %m "$AT" 2>/dev/null || echo 0)
chk "L5 無言の回でも走った証拠(attempt の mtime)は進む" "進む" \
    "$([ "$now_at" -gt "$prev_at" ] && echo 進む || echo 止まったまま)"

echo "--- 走った と 効いている を混ぜない ---"
# ★Codex 2026-08-02 の一番痛い指摘。心拍を1本にしていた頃は、信頼判定が永久に失敗していても
#   心拍だけ新しく、**壊れている状態が健康と同じ顔**をしていた。2本に分けた事を現物で測る。
"$TMUX_BIN" kill-window -t "$SESSION:phone" 2>/dev/null
sleep 1
before_at=$(stat -f %m "$AT" 2>/dev/null || echo 0)
before_su=$(stat -f %m "$SU" 2>/dev/null || echo 0)
sleep 1
runlog "$TMP/untrusted" "$TMP/stub"
after_at=$(stat -f %m "$AT" 2>/dev/null || echo 0)
after_su=$(stat -f %m "$SU" 2>/dev/null || echo 0)
chk "S1 関門で止まった回も attempt は進む(走ってはいる)" "進む" \
    "$([ "$after_at" -gt "$before_at" ] && echo 進む || echo 止まったまま)"
chk "S1 ★その回 success は進まない(「効いている」を騙らない)" "据え置き" \
    "$([ "$after_su" = "$before_su" ] && echo 据え置き || echo 進んだ)"
chk "S1 その時の exit は 20" "20" "$CODE"
runlog "$TMP/trusted" "$TMP/stub"
chk "S1 直った回に success が進む" "進む" \
    "$([ "$(stat -f %m "$SU" 2>/dev/null || echo 0)" -gt "$after_su" ] && echo 進む || echo 止まったまま)"

echo "--- 同名2枚 / 抜け殻 ---"
# D1: tmux は同名 window を許す。2枚在る時に「在る」と答えると増えた事に永久に気付かない。
#     ★直さずに手を引く(どちらかで人が話している可能性が在り、機械には見分けが付かない)。
"$TMUX_BIN" new-window -d -t "$SESSION" -n phone -c "$TMP" "$TMP/stub" 2>/dev/null
D1_BEFORE=$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_id}' | tr '\n' ',')
runlog "$TMP/trusted" "$TMP/stub"
chk "D1 同名が2枚在れば 31(在る/無いの2値で答えない)" "31" "$CODE"
chk "D1 ★その時 window を1枚も消していない(壊さない側に倒す)" "$D1_BEFORE" \
    "$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_id}' | tr '\n' ',')"
chk "D1 phone は2枚のまま" "2" "$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_name}' | grep -cx phone)"
# ★ここで実測した事(想定していなかった): 同名が2枚在ると tmux は `session:phone` を
#   **一切解決しない**(`can't find window: phone`)。片方を指す訳でもない。
#   = 名前で kill も list も出来ない。exit 31 は「機械が決められない」だけでなく
#   「機械が触りようがない」状態でもある。片付けは window_id でやる。
kill_phone_windows() {
  "$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_id} #{window_name}' 2>/dev/null \
    | awk '$2 == "phone" {print $1}' \
    | while read -r wid; do "$TMUX_BIN" kill-window -t "$wid" 2>/dev/null; done
}
kill_phone_windows
chk "D1 片付け: window_id なら消せる(名前では解決すら出来ない)" "0" \
    "$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_name}' | grep -cx phone)"

# D2: 抜け殻(remain-on-exit で名前だけ残った死んだ window)。名前で冪等を取っている以上、
#     これを「在る」と数えると**永久に偽の健康**を報告する。
"$TMUX_BIN" new-window -d -t "$SESSION" -n phone -c "$TMP" "$TMP/stub" 2>/dev/null
"$TMUX_BIN" set-option -w -t "$SESSION:phone" remain-on-exit on 2>/dev/null
DEAD_PID=$("$TMUX_BIN" list-panes -t "$SESSION:phone" -F '#{pane_pid}' 2>/dev/null | head -1)
DEAD_PANE=$(phone_pane)
kill "$DEAD_PID" 2>/dev/null; sleep 1
chk "D2 前提: 抜け殻を作れている(ペインが死んで名前だけ残る)" "0" \
    "$("$TMUX_BIN" list-panes -t "$SESSION:phone" -F '#{pane_dead}' | grep -cx 0)"
runlog "$TMP/trusted" "$TMP/stub"
chk "D2 抜け殻は「在る」と数えず作り直す" "0" "$CODE"
chk "D2 中身が生きている" "1" \
    "$("$TMUX_BIN" list-panes -t "$SESSION:phone" -F '#{pane_dead}' | grep -cx 0)"
chk "D2 別のペインになっている(前のではない)" "different" \
    "$([ "$(phone_pane)" != "$DEAD_PANE" ] && echo different || echo same)"
chk "D2 増えていない(1枚のまま)" "1" "$("$TMUX_BIN" list-windows -t "$SESSION" -F '#{window_name}' | grep -cx phone)"
"$TMUX_BIN" kill-window -t "$SESSION:phone" 2>/dev/null

echo "--- 区切りが locale で消える(本番の launchd 環境を再現する) ---"
# ★2026-08-02 に本番で踏んだ故障の現物対照。tmux 3.7b/3.6a は locale が UTF-8 でないと
#   `-F` の出力中の**制御文字**を潰す(タブが `_` になる)。launchd は locale を渡さないので、
#   **本番の server だけ**ペイン一覧が 0 件になり、全会話がワーカー経路に落ちていた。
#   シェルから走らせる限り LANG が在るので、この故障は他のどの検査にも映らない。
#   ここでは本物の tmux を **env を剥いだ状態**で叩き、3つ測る:
#     L1 対策あり(makeTmuxRunner で locale を被せる)= 読める
#     L2 現行書式は対策なしでも読める = 区切りが印字可能 ASCII だから(根の直し)
#     L3 ★負の対照: 旧書式(タブ)は対策なしだと現に潰れる = 故障は今もこの機械で起きる
#   L3 が「潰れない」に変われば、この対照はもう故障を見分けられないという事。
#   L2 が落ちれば、区切りに locale 依存の文字が混ざったという事。
"$TMUX_BIN" new-window -d -t "$SESSION" -n loc -c "$TMP" "$TMP/stub" 2>/dev/null
LOC_JS="$TMP/loc-probe.mjs"
cat >"$LOC_JS" <<'JS'
import { execFileSync } from "node:child_process";
// ★import 先は実行時に決まる(この台本は使い捨ての dir に置かれる)ので動的 import。
// ★叩くのは **本番と同じ TmuxInjector.listPanes()**。書式を手で写すと、本番の書式を
//   変えた時にこの対照だけが古い書式を測り続ける(= 緑のまま守っていない)。
const { makeTmuxRunner, TmuxInjector } = await import(process.env.RC_INJECT_URL);
const bin = process.env.TMUX_BIN;
// ★locale 対策なし。**この対照が測るのは locale だけ**なので、runStrict にも同じ実体を
//   渡す(構築は両方を要求する = M84)。片方を欠かした注入にすると、測っている物が
//   「locale が無い」から「runStrict が無い」にすり替わる。
const nakedExec = (args) => execFileSync(bin, args, { encoding: "utf8" });
const naked = { run: nakedExec, runStrict: nakedExec };
const fixed = makeTmuxRunner({ tmuxBin: bin, exec: execFileSync, quiet: false }); // locale 対策あり
const out = {};
for (const [name, runner] of [["fixed", fixed], ["naked", naked]]) {
  try {
    out[name] = new TmuxInjector({ tmux: runner }).listPanes().length > 0 ? "read" : "empty";
  } catch (e) { out[name] = e.code === "TMUX_UNREADABLE" ? "threw" : "other"; }
}
// 旧書式(タブ区切り)を locale 対策なしで直接叩く = 故障そのものが今も起きる事の実測。
const raw = naked.run(["list-panes", "-a", "-F", "#{pane_id}\t#{pane_current_command}"]);
out.tab = raw.includes("\t") ? "kept" : /%\d+_/.test(raw) ? "garbled" : "other";
console.log(out.fixed + " " + out.naked + " " + out.tab);
JS
LOC_OUT=$(env -i PATH=/usr/bin:/bin HOME="$TMP" \
  TMUX_BIN="$TMUX_BIN" RC_INJECT_URL="file://$SELF_DIR/../src/inject.mjs" \
  "$(command -v node || echo /opt/homebrew/bin/node)" "$LOC_JS" 2>&1 | tail -1)
set -- $LOC_OUT
chk "L1 locale を被せれば env を剥いでも読める(makeTmuxRunner)" "read" "${1:-}"
chk "L2 現行書式は locale 対策が無くても読める(区切りが印字可能 ASCII)" "read" "${2:-}"
chk "L3 ★負の対照: 旧書式(タブ)は今もこの機械で潰れる" "garbled" "${3:-}"
"$TMUX_BIN" kill-window -t "$SESSION:loc" 2>/dev/null

echo
printf '合計 OK=%d NG=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
