#!/bin/bash
# 上限が明けた後の**一発勝負**を、手打ちせずに順番どおり撃つ。
#
# ── なぜ台本にするか ────────────────────────────────────────────────────
# 解除は1回きり。順番・`cd`・`--cwd`・絶対 path のどれか1つを手で打ち間違えると、
# 「上限以外の理由」で赤が出て、その赤を読み違える。§1-G の表を目で写す作業を消す。
#
# ── 順番と止め方 ────────────────────────────────────────────────────────
#   門) limit-lifted-check.mjs を **edith で** → exit 3 なら**何も撃たずに終わる**
#   1)  live-inject-check --cases A     … 1件で「明けた」が判る
#   2)  live-inject-check(4件)         … edith という機械での一巡
#   3)  live-http-check                 … ここが exit 0 になるまで「一巡した」と書かない
#   4)  live-fork-check(launchd 越し)  … DESIGN §2.17 の前提。exit 1 なら設計を書き換える
#   **赤が出たらそこで止める**(先を撃っても意味が無く、上限だけ減る)。
#
# 終了コード: 0 = 4項目とも緑 / 3 = 門が閉じている(何も撃っていない) / 1 = どれかが赤
#
# ★この台本自身は**何も新しい事をしない**。§1-G で1本ずつ実測済みの呼び出しを、
#   順番と停止条件だけ足して並べた物。中身を足したくなったら §1-G を先に直す。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
EDITH="${RC_EDITH_HOST:-edith@10.0.0.0}"
NODE_R="/opt/homebrew/bin/node"
RCDIR="/Users/edith/rc-backend"
CWD_ARG="/Users/edith/Projects"

say() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

# RC_DRY=1 … 撃たずに「何を撃つか」だけを出す。
# ★これが要る理由: 門が閉じている間に控えを取れるのは門の脚だけで、1-4 の**文字列**は
#   一度も組み立てられない。`--cwd` の打ち間違いが、窓が開いた後に初めて赤で出る —— つまり
#   一発勝負を台本の誤字で潰す。dry で先に目視照合できる様にする。
DRY="${RC_DRY:-0}"
run() {
    # ★%q で出す。"$*" だと引用が潰れて、remote に渡す1個の文字列が
    #   手元の `&&` に見える —— 突き合わせの為の控えが、突き合わせを誤らせる。
    if [ "$DRY" = "1" ]; then printf '  [dry]'; printf ' %q' "$@"; printf '\n'; return 0; fi
    "$@"
}

# ── 門 ──────────────────────────────────────────────────────────────────
say "門) 上限が明けたか(生成を起こさずに読む)"
if [ "$DRY" = "1" ]; then
    echo "  [dry] scp tools/limit-lifted-check.mjs $EDITH:/tmp/lc.mjs"
    echo "  [dry] ssh $EDITH \"$NODE_R /tmp/lc.mjs\"  → exit 0 以外なら**ここで終わる**"
    echo "  [dry] ★出力に「測った所: Edith」が無ければ、たとえ exit 0 でも撃たない"
else
scp -q tools/limit-lifted-check.mjs "$EDITH:/tmp/lc.mjs" || { echo "門: scp に失敗 = 未測定"; exit 3; }
gate_out="$(ssh "$EDITH" "$NODE_R /tmp/lc.mjs; echo GATE-EXIT=\$?; /bin/rm -f /tmp/lc.mjs")"
echo "$gate_out"
gate_rc="$(printf '%s' "$gate_out" | sed -n 's/^GATE-EXIT=//p' | tail -1)"

# ★「測った所」が edith である事を確かめる。手元で測った答えを edith の答えとして読まない。
if ! printf '%s' "$gate_out" | grep -q "測った所: Edith"; then
    echo "門: ★測定対象が edith ではない(出力の1行目を見る)。撃たない"
    exit 3
fi
if [ "$gate_rc" != "0" ]; then
    echo "門: まだ明けていない(GATE-EXIT=$gate_rc)。**何も撃っていない**"
    exit 3
fi
echo "門: 明けている。1→4 を順に撃つ(赤で止める)"
fi

fail() { echo "★ item $1 が赤(exit $2)。ここで止める = 先を撃っても意味が無い"; exit 1; }

# ── 1 ───────────────────────────────────────────────────────────────────
say "1) live-inject-check --cases A(1件)"
run ssh "$EDITH" "cd $RCDIR && $NODE_R tools/live-inject-check.mjs --cwd $CWD_ARG --cases A"
rc=$?; [ $rc -eq 0 ] || fail 1 $rc

# ── 2 ───────────────────────────────────────────────────────────────────
say "2) live-inject-check(4件)"
run ssh "$EDITH" "cd $RCDIR && $NODE_R tools/live-inject-check.mjs --cwd $CWD_ARG"
rc=$?; [ $rc -eq 0 ] || fail 2 $rc

# ── 3 ───────────────────────────────────────────────────────────────────
say "3) live-http-check(ここが 0 になるまで「一巡した」と書かない)"
run ssh "$EDITH" "cd $RCDIR && $NODE_R tools/live-http-check.mjs --cwd $CWD_ARG"
rc=$?; [ $rc -eq 0 ] || fail 3 $rc

# ── 4 ── launchd 越し。使い捨て dir を作って消し、不在まで確認する ──────
say "4) live-fork-check(launchd 越し = keychain が要る経路)"
if [ "$DRY" = "1" ]; then
    echo "  [dry] D=\$(ssh $EDITH 'mktemp -d /tmp/rc-forktool.XXXXXX')"
    echo "  [dry] scp tools/live-fork-check.mjs $EDITH:\$D/"
    echo "  [dry] bash tools/edith-gui-run.sh --timeout 90 -- $NODE_R \$D/live-fork-check.mjs --bin /Users/edith/.local/bin/claude"
    echo "  [dry] ssh $EDITH \"/bin/rm -f \$D/*; rmdir \$D; ls -d \$D\"  → 不在まで確認する"
else
D="$(ssh "$EDITH" 'mktemp -d /tmp/rc-forktool.XXXXXX')" || fail 4 2
echo "使い捨て dir: $D"
scp -q tools/live-fork-check.mjs "$EDITH:$D/" || { ssh "$EDITH" "rmdir '$D'"; fail 4 2; }
bash tools/edith-gui-run.sh --timeout 90 -- \
    "$NODE_R" "$D/live-fork-check.mjs" --bin /Users/edith/.local/bin/claude
rc=$?
ssh "$EDITH" "/bin/rm -f '$D'/*; rmdir '$D'; ls -d '$D' 2>&1 | tail -1"
[ $rc -eq 0 ] || fail 4 $rc
fi

# ★dry で「緑」と言わない。dry は**何も測っていない**ので、ここで緑を出すと
#   今夜3回踏んだ「主語の無い green」(= 何を測った答えなのかを言わない緑)そのものになる。
if [ "$DRY" = "1" ]; then
    say "dry 終わり — **何も測っていない**。上の文字列を §1-G と突き合わせる為だけの出力"
    exit 0
fi
say "4項目とも緑。§1-G の表と DESIGN §2.17 を実測値で更新する事"
exit 0
