#!/bin/bash
# no-operator: 人が撃つ。CF-5(private GitHub へ出すか)を Tom が裁く時の材料で、その裁定が要る時にしか意味が無い。門から毎 commit 回すと git rev-list を全 history に走らせる。
# push-readiness-check.sh — 「この repo を初めて private GitHub へ push したら通るか」を測る。
# **読み取り専用**。remote を足さない・push しない・何も書かない。
#
# ── なぜ要るか(CF-5、2026-08-30)──────────────────────────────────────────
# CF-5 は「private GitHub へ push するか」が Tom の裁定待ちのまま開いている。
# 裁定に要るのは意見ではなく**数字**なので、それを出す物を先に置く。
#
# ★この形の壊れ方は Tom の環境で**既に起きている**(2026-08-30 発見):
#   `.claude` の設定バックアップが **6 日間 push 0** だった。121-153MB の講義 .wav が
#   GitHub の **1 file 100MB** 上限に当たって pre-receive で弾かれ、
#   **commit は成功し続けていた**ので誰にも見えなかった。467 commit が未送信。
#   → だから此処が見るのは「commit できるか」ではなく「**向こうが受け取るか**」。
#
# ── 見る物(それぞれ独立に報告する。混ぜると片方の判断が他方に紛れる)──────
#   A. 1 file の大きさ    … 100MB(104857600 B)超 = **拒まれる** / 50MB 超 = 警告
#   B. 送る量の見積り      … pack の大きさ
#   C. 秘密と個人情報      … `rc-backend/tools/check-no-pii.sh` に委ねる(重複して書かない)
#   D. remote の有無       … 既に在るなら「初めての push」ではない
#
# ★A は **history 全体**を見る。`HEAD` だけ見ると、一度 commit して消した大きな file を
#   見逃す —— push が運ぶのは history であって作業木ではない。
#
# 使い方: bash .harness/push-readiness-check.sh
# 終了コード: 0=測れた(READY / NOT READY は文面で言う) / 2=測れない(repo でない等)
#   ★NOT READY でも 0 で帰る。これは**判断材料を出す道具**で、門ではない。
#     門にすると「赤いから push しない」が「赤いから道具を外す」に化ける。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = repo 根
cd "$HERE" 2>/dev/null || { echo "push-readiness: $HERE へ入れない = 測定不成立"; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "push-readiness: git repo ではない = 測定不成立"; exit 2; }

# ★境界は env で差せる。**対照が此の腕を発火させられる様にする為**(2026-08-30)——
#   本物の 100MB blob を検査の度に作るのは重すぎるし、作らなければ
#   「大きさの腕は一度も赤くなった事が無い」状態で緑を出し続ける事になる。
#   既定は GitHub の実際の境界。
HARD="${PRC_HARD:-104857600}"      # GitHub が 1 file で拒む境界(100MB)
SOFT="${PRC_SOFT:-52428800}"       # 警告(50MB)
PII_BIN="${PRC_PII_BIN:-}"         # 対照が差し替える為の継ぎ目(既定は下で決める)
blocking=0

echo "== push readiness: $HERE =="
echo

# ── D. remote ────────────────────────────────────────────────────────────────
echo "-- D. remote --"
if git remote | grep -q .; then
    git remote -v | sed 's/^/   /'
    echo "   ※ 既に remote が在る = 「初めての push」ではない。以下は参考値"
else
    echo "   remote 未設定(= まだ一度も外へ出していない)"
fi
echo

# ── A. 1 file の大きさ(history 全体)──────────────────────────────────────
echo "-- A. 1 file の大きさ(上限 $HARD B。GitHub の実際の境界は 104857600 B = 100MB。history 全体を見る)--"
big="$(git rev-list --objects --all 2>/dev/null \
      | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null \
      | awk -v h="$HARD" -v s="$SOFT" '$1=="blob" && $3+0 >= s {printf "%d\t%s\t%s\n", $3, ($3+0>=h?"拒否":"警告"), $4}' \
      | sort -rn)"
if [ -n "$big" ]; then
    printf '%s\n' "$big" | while IFS=$'\t' read -r sz kind name; do
        printf '   %-6s %10d B  %s\n' "$kind" "$sz" "$name"
    done
    printf '%s\n' "$big" | grep -q '拒否' && blocking=1
else
    echo "   50MB を超える blob なし"
fi
# ★最大値は「無かった」の裏付けとして必ず出す。件数 0 だけだと、
#   走査そのものが空振りした時と区別が付かない。
maxline="$(git rev-list --objects --all 2>/dev/null \
      | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null \
      | awk '$1=="blob"{if ($3+0 > m) {m=$3+0; n=$4}} END {if (m) printf "%d\t%s\n", m, n}')"
if [ -n "$maxline" ]; then
    printf '   最大: %s B  %s\n' "${maxline%%	*}" "${maxline##*	}"
    case "${maxline%%	*}" in ''|*[!0-9]*) ;; *) [ "${maxline%%	*}" -ge "$HARD" ] && blocking=1 ;; esac
else
    echo "   ★blob を1つも数えられなかった = 走査が空振り(結論を出さない)"
    blocking=1
fi
echo

# ── B. 送る量 ────────────────────────────────────────────────────────────────
echo "-- B. 送る量の見積り --"
git count-objects -vH | grep -E "^(count|size|in-pack|size-pack):" | sed 's/^/   /'
echo "   ※ 初回 push は history 全部を運ぶ。size-pack + 未 pack の loose が目安"
echo

# ── C. 秘密と個人情報 ────────────────────────────────────────────────────────
echo "-- C. 秘密・個人情報(rc-backend/tools/check-no-pii.sh に委ねる)--"
PII="${PII_BIN:-$HERE/rc-backend/tools/check-no-pii.sh}"
if [ -x "$PII" ]; then
    if bash "$PII" >/tmp/.push-readiness-pii.$$ 2>&1; then
        echo "   check-no-pii: 緑"
    else
        echo "   ★check-no-pii: 赤(下は末尾)"
        tail -12 /tmp/.push-readiness-pii.$$ | sed 's/^/     /'
        blocking=1
    fi
    /bin/rm -f /tmp/.push-readiness-pii.$$
else
    echo "   ★check-no-pii.sh が無いか実行できない($PII)= **測れていない**"
    blocking=1
fi
echo

# ── 結論 ─────────────────────────────────────────────────────────────────────
if [ "$blocking" -eq 0 ]; then
    echo "== READY: 初回 push を止める材料は見つからなかった =="
    echo "   ★これは「push してよい」ではない —— 公開範囲の判断(CF-5)は Tom のもの。"
    echo "   ★見ていない物: GitHub 側の設定(組織の方針・LFS・branch protection)。"
else
    echo "== NOT READY: 上の ★ を解いてから =="
    echo "   ★1 file 100MB 超は pre-receive で拒まれ、**commit は成功し続ける**ので"
    echo "     詰まりが見えない(Tom の .claude で実際に 6 日間これが起きた)。"
fi
exit 0
