#!/bin/bash
# controls-for: rc-backend/tools/staged-controls-gate.sh
# mixed-index-control.sh — 門が **index と作業木のずれ**で止まる事を測る。2026-08-26 新設。
#
# 守る一線: 「**緑が、commit に載る版を測っている**」。
#   門は `bash "$c"` = **作業木の版**を走らせるが、commit に載るのは **index の版**。
#   同じ file が `MM`(staged かつ さらに変更済み)の時、緑は載らない版を証明している。
#   ★2026-08-26 に実際に起きた: `git add -A` の後に対照台本の実バグを直し、add し直さずに
#     commit。門は直した版で **12/12 緑**、履歴には**壊れた版**が入った。
#     門は何も言わず、気付いたのは後から `git show HEAD:<file>` を疑って読んだから。
#
# ★本物の repo では試さない。**使い捨ての git repo を作って**、そこで門を撃つ。
#   本物で `MM` を作って測ると、失敗した時に測定者自身が汚れた木を残す。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/staged-controls-gate.sh"
[ -f "$GATE" ] || { echo "★$GATE が無い"; exit 2; }

fail=0; reds=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 使い捨ての repo を組む -------------------------------------------------------
R="$TMP/repo"
mkdir -p "$R/rc-backend/tools"
( cd "$R" && git init -q && git config user.email t@e && git config user.name t ) || { echo "★git init 失敗"; exit 2; }
printf 'v1\n' > "$R/rc-backend/tools/thing.sh"
( cd "$R" && git add -A && git commit -qm base ) || { echo "★基準 commit 失敗"; exit 2; }

run_gate() { # stdout = 出力、return = rc。$1 = 追加 env(空可)
    local extra="${1:-}"
    ( cd "$R" && env $extra RC_STAGED_FILES="" /bin/bash "$GATE" 2>&1 )
}

echo "=== 1. 清潔(staged のみ・ずれ無し)では此の守りが発火しない[過剰発火の負] ==="
printf 'v2\n' > "$R/rc-backend/tools/thing.sh"
( cd "$R" && git add -A )
out="$(run_gate)"; rc=$?
if printf '%s' "$out" | grep -q "index と作業木がずれている"; then
    printf '  ★清潔な木で発火した(rc=%s)\n' "$rc"; fail=1
else
    printf '  発火しない OK\n'
fi

echo "=== 2. MM(staged の後にさらに書き換え)で止まる[赤] ==="
printf 'v3-worktree-only\n' > "$R/rc-backend/tools/thing.sh"   # add し直さない = MM
mm="$( cd "$R" && git status --porcelain | head -1 )"
case "$mm" in
    MM*) printf '  前提: git status = %s\n' "$mm" ;;
    *)   printf '  ★前提が作れていない: git status = %s(MM を作れていないので測っていない)\n' "$mm"; fail=1 ;;
esac
out="$(run_gate)"; rc=$?
reds=$((reds + 1))
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "index と作業木がずれている"; then
    printf '  止まった(rc=%s)・ずれた file を名指ししたか: %s  OK\n' "$rc" \
        "$(printf '%s' "$out" | grep -c 'thing.sh')"
else
    printf '  ★止まらなかった(rc=%s)= 載らない版の緑が commit を通す\n' "$rc"; fail=1
fi

echo "=== 3. 明示の抜け道だけが此の守りを外す ==="
out="$(run_gate 'RC_ALLOW_MIXED_INDEX=1')"; rc=$?
if printf '%s' "$out" | grep -q "index と作業木がずれている"; then
    printf '  ★抜け道が効いていない\n'; fail=1
else
    printf '  抜け道で素通り OK\n'
fi

echo "=== 4. 抜け道は**この守りだけ**を外す(他の判断まで殺さない)[負] ==="
# staged を空にすると、門は別の理由(何を触ったか判らない)で 2 を返す筈。
( cd "$R" && git add -A && git commit -qm x ) >/dev/null 2>&1
out="$(run_gate 'RC_ALLOW_MIXED_INDEX=1')"; rc=$?
reds=$((reds + 1))
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "staged の一覧が空"; then
    printf '  空 staged は抜け道でも止まる OK\n'
else
    printf '  ★抜け道が他の判断まで殺している(rc=%s / %s)\n' "$rc" "$(printf '%s' "$out" | tail -1)"; fail=1
fi

echo
echo "  赤に倒れる入力: ${reds} 件"
[ "$reds" -lt 2 ] && { echo "  ★対照が空虚"; fail=1; }
echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
