#!/bin/bash
# `tools/mutation-run-live.sh` が「走行中か」を**正しく**見分ける事の確認。
#
# なぜ要るか(2026-08-02): この判定は3箇所(配備 / 的検査 / その対照)に複製されていて、
#   3つとも同じ欠陥 —— 素の `pgrep -f 'mutation-controls\.py'` は**文字列を含むだけの
#   無関係なプロセス**にも当たる —— を持っていた。実害は2つ:
#     (a) 待ち受け `until ! pgrep -f mutation-controls.py; ...` が**自分自身**を見つけて
#         永久に終わらない(実測で2本が1時間53分回り続けていた)
#     (b) `deploy-to-edith.sh` はこの判定で配備を拒否するので、無関係なシェルが1本
#         残っているだけで**配備が恒久的に塞がる**
#
# ★この対照の肝: 走行中でも測れる形にする事。
#   「今 pgrep が何か拾うか」で測ると、本物の走行中は常に真になって何も分からない。
#   だから**囮のPIDが一致集合に入るか**で測る。本物が走っていても答えが変わらない。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE="$ROOT/tools/mutation-run-live.sh"
PAT='[Pp]ython[0-9.]* +[^ ]*mutation-controls\.py'

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

# ★囮は必ず stdout を切って起動する事(`>/dev/null 2>&1 &`)。
#   切らないと、この対照を `out=$(bash ...)` の形で呼んだ親が**囮の sleep が終わるまで待つ**。
#   コマンド置換は「書き手が全員 pipe を閉じる」まで返らないので、背景の子が pipe を
#   握ったままだと親が固まる。実測: 1秒で終わる筈の対照が 31 秒かかった(2026-08-02)。
pids=()
cleanup() {
    for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    [ -n "${SB:-}" ] && [ -d "$SB" ] && /bin/rm -rf -- "$SB"
}
trap cleanup EXIT INT TERM

matched() {  # $1 = pid → その pid が一致集合に居れば 0
    pgrep -f "$PAT" 2>/dev/null | grep -qx "$1"
}

# --- 1) 偽陽性(a): 待ち受け自身。文字列は含むが python ではない ---
bash -c 'until ! pgrep -f mutation-controls.py >/dev/null 2>&1; do sleep 30; done' >/dev/null 2>&1 &
W=$!; pids+=("$W"); sleep 0.4
if matched "$W"; then ng "待ち受けを走行と誤認しない" "自己参照 — この判定を使う待ち受けは永久に終わらない"
else ok "待ち受けを走行と誤認しない(自己参照しない)"; fi

# --- 2) 偽陽性(b): 編集セッション相当。やはり python ではない ---
bash -c 'V="vim test/mutation-controls.py"; sleep 30' >/dev/null 2>&1 &
E=$!; pids+=("$E"); sleep 0.4
if matched "$E"; then ng "編集セッションを走行と誤認しない" "無関係なシェルで配備が塞がる"
else ok "編集セッションを走行と誤認しない"; fi

# --- 3) 真陽性: 本物の形。ここが緑でないと**守りごと効かない** ---
#   (1)(2) だけ通す判定は「常に走行していない」と言えば作れてしまう。
SB="$(mktemp -d /tmp/mutlive-ctl.XXXXXX)"
mkdir -p "$SB/test"
printf 'import time\ntime.sleep(30)\n' > "$SB/test/mutation-controls.py"
python3 "$SB/test/mutation-controls.py" >/dev/null 2>&1 &
R=$!; pids+=("$R"); sleep 0.6
if matched "$R"; then ok "本物の走行は捕まえる(守りが効いている)"
else ng "本物の走行は捕まえる" "★守りが空振り — 走行中でも配備できてしまう"; fi

# --- 4) 判定スクリプトの exit がその集合と一致する事 ---
bash "$LIVE"; live_rc=$?
if pgrep -f "$PAT" >/dev/null 2>&1; then want=0; else want=1; fi
if [ "$live_rc" -eq "$want" ]; then ok "exit が一致集合と揃っている(exit=$live_rc)"
else ng "exit が一致集合と揃っている" "exit=$live_rc 期待=$want"; fi

echo ""
echo "MUTATION-RUN-LIVE-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
