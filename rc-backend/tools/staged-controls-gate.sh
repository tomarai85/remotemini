#!/bin/bash
# commit に**触れた対照**が入っているなら、その対照を commit の前に一度通す。
#
# なぜ要るか(2026-08-03 に2回踏んだ):
#   ① commit `25f8e09` は対照を2本足したが `npm test` を回さず、赤いまま入った
#      → `tools/commit-suite-gate.sh`(単体の一式)で塞いだ
#   ② commit `45e0c8b` は `tools/mutation-verdict.sh` と
#      `test/mutation-verdict-controls.sh` を**同じ commit で**足したのに、
#      その対照を**最後まで通した事が一度も無かった**。後で回したら §7〜§9 の
#      3 本が倒れ、道具の側に本物の欠陥が在った(assert が失敗を全部 0 で返す)。
#      ★①の門は `npm test` しか見ないので、②は素通りする —— `test/*-controls.sh` は
#      `npm test` の一部ではない(走らせる物は `tools/run-controls.sh` の方)。
#
#   どちらも「規則が無かった」のではない。**回す物が無かった**(DESIGN (19))。
#   対照を書いた commit と、対照を通した commit は別、というのが②の教訓。
#
# 全部(`run-controls.sh` の 19 本)を毎 commit 回すのは**しない**。実測で 5 分を超え、
# 使えない検査は外される —— hook 本体の注釈と同じ理由。代わりに範囲を「この commit が
# 触れた物」に絞る。触れていない対照が壊れるのは、触れた物の commit では起きない。
#
# 選び方(2 通り。どちらも file の実在を確かめてから回す):
#   (a) `rc-backend/test/*-controls.sh` が staged → それを回す
#   (b) `rc-backend/tools/<名前>.sh` が staged で `rc-backend/test/<名前>-controls.sh`
#       が在る → それを回す(★②はこちら側。対照に触らず道具だけ直す事が在る)
#   (c) 対照を導けない `tools/*.sh` は**黙って見逃さず、名前を出す**。止めはしない ——
#       止めると対照の無い道具に触る commit が全部通らなくなる。見えれば足せる。
#
# 終了コード: 0=緑(または対象なし) / 1=赤 / **2=測れなかった**。
#   2 を 0 に丸めない。hook は非ゼロで止まるので、測れない時は止まる側へ倒れる。
#
# 継ぎ目(対照が差し込む口): RC_GATE_ROOT / STAGED_LIST_CMD
set -uo pipefail

ROOT="${RC_GATE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "staged-controls-gate: repo の根が判らない = 測れていない"; exit 2; }
LIST_CMD="${STAGED_LIST_CMD:-git diff --cached --name-only}"

staged="$(cd "$ROOT" && eval "$LIST_CMD" 2>/dev/null)"
if [ -z "$staged" ]; then
    echo "staged-controls-gate: staged の一覧が空 = 測れていない(何を触ったか判らない)"
    exit 2
fi

sel=""; orphan=""
add_sel() { case " $sel " in *" $1 "*) ;; *) sel="$sel $1" ;; esac; }

while IFS= read -r f; do
    case "$f" in
        rc-backend/test/*-controls.sh)
            [ -f "$ROOT/$f" ] && add_sel "$f" ;;   # 削除された対照は回さない
        rc-backend/tools/*.sh)
            base="${f##*/}"; base="${base%.sh}"
            cand="rc-backend/test/${base}-controls.sh"
            if [ -f "$ROOT/$cand" ]; then add_sel "$cand"
            elif [ -f "$ROOT/$f" ]; then orphan="$orphan $base"
            fi ;;
    esac
done <<EOF
$staged
EOF

if [ -n "$orphan" ]; then
    echo "staged-controls-gate: 注記 — 対照を導けない道具:$orphan"
    # ★ここを二重引用符 + backtick で書くと `test/...` が**命令として実行される**
    #   (しかも `<名前>` は「名前」という file からの入力の意味になる)。
    #   この repo で既に同じ形を踏んでいるので、注記は単一引用符で出す。
    echo '  (test/<名前>-controls.sh が在れば自動で回る。止めはしない)'
fi

if [ -z "$sel" ]; then
    echo "staged-controls-gate: 触れた対照は無い"
    exit 0
fi

n=0; for c in $sel; do n=$((n+1)); done
echo "staged-controls-gate: 触れた対照 ${n} 本を回す(長い物が在る。--no-verify は使わずに待つ事)"

red=0; unm=0; green=0; red_names=""; unm_names=""
for c in $sel; do
    t0=$(date +%s)
    out="$(cd "$ROOT" && bash "$c" 2>&1)"; rc=$?
    t1=$(date +%s)
    last="$(printf '%s' "$out" | /usr/bin/tail -1)"
    case "$rc" in
        0) green=$((green+1)); printf '  GREEN  %-36s %3ds  %s\n' "${c##*/}" "$((t1-t0))" "$last" ;;
        2) unm=$((unm+1)); unm_names="$unm_names ${c##*/}"
           printf '  UNMEA  %-36s %3ds  %s\n' "${c##*/}" "$((t1-t0))" "$last" ;;
        *) red=$((red+1)); red_names="$red_names ${c##*/}"
           printf '  RED    %-36s %3ds  %s\n' "${c##*/}" "$((t1-t0))" "$last"
           printf '%s' "$out" | /usr/bin/grep -E '^\s*(NG|not ok|★)' | /usr/bin/head -8 | /usr/bin/sed 's/^/         /' ;;
    esac
done

if [ "$red" -gt 0 ]; then
    # ★`$var` の直後に日本語を置くと、変数名がそこまで伸びて `unbound variable` になる
    #   (ロケール依存。この repo で既に踏んでいる)。展開は必ず `${var}` と書く。
    echo "staged-controls-gate: ★触れた対照が赤い(${red}本):${red_names}。commit を止めた"
    exit 1
fi
if [ "$unm" -gt 0 ]; then
    echo "staged-controls-gate: ★測れなかった対照が在る(${unm}本):$unm_names"
    echo "  緑ではない。条件が揃ってから回し直す事(変異の走行中など)"
    exit 2
fi
# ★緑の判定だけに出る綴りにする(「触れた対照 N 本を回す」の予告と**前置きを共有しない**)。
#   共有していると、対照が「緑と言っていない事」を測れない —— 予告の方に当たってしまう。
echo "staged-controls-gate: 触れた対照は全部緑(${green}/${green})"
exit 0
