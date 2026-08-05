#!/bin/bash
# controls-for: tools/install-hooks.sh
# 「門を入れ直す道具」が、入れた気にさせるだけの物になっていない事を測る。
#
# ── なぜ本物の .git では測れないか ──────────────────────────────────────
# この repo の `.git/hooks/pre-commit` は**今まさに使われている**。上書きの枝を
# 本物で測ると、失敗した瞬間に自分の commit 経路が壊れる。だから偽の repo を
# `git init` して、その中で全部の枝を回す。触るのは細工した木だけ。
#
# ── 測る8つ ────────────────────────────────────────────────────────────
#   1 hook が無い所へ入れる            → exit 0 かつ file が出来る
#   2 入れた hook が**本体を指す**     → (書けた ≠ 効く)
#   3 入れた hook に実行権が付く       → (無ければ git は呼ばない)
#   4 もう一度回しても壊れない(冪等)  → exit 0 かつ「既に入っている」
#   5 別人の hook が在れば**上書きしない** → exit 1 かつ中身が残る
#   6 理由つきなら上書きし、控えを残す → exit 0 かつ .bak が出来る
#   7 理由が短ければ上書きしない       → 5 が「変数が在れば通る」でない事
#   8 git repo でなければ exit 2       → 測れない事を緑にしない
#
# ★5 と 6 は対で要る。片方だけでは「常に拒む道具」「常に上書きする道具」と
#   見分けが付かない。守るべきは**黙って消さない**事であって、拒む事ではない。
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBJECT="$REPO_ROOT/rc-backend/tools/install-hooks.sh"
BODY_REL="rc-backend/tools/pre-commit-gates.sh"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

T="$(mktemp -d)"
cleanup() {
    [ -n "${T:-}" ] || return 0
    [ -d "$T" ] || return 0
    find "$T" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$T" -type d -depth -print 2>/dev/null | while read -r d; do /bin/rmdir "$d" 2>/dev/null; done
}
trap cleanup EXIT

if [ ! -f "$SUBJECT" ]; then
    echo "FAIL  対象が無い: $SUBJECT"
    echo "--- 合計: PASS 0 / FAIL 1 ---"
    exit 1
fi

# 偽の repo。道具は自分の位置から根を取るので、同じ骨格を作って写す。
mk_repo() {
    local r="$1"
    mkdir -p "$r/rc-backend/tools"
    git -C "$r" init -q 2>/dev/null || return 1
    cp "$SUBJECT" "$r/rc-backend/tools/install-hooks.sh"
    printf '#!/bin/bash\necho "偽の本体"\nexit 0\n' > "$r/$BODY_REL"
    chmod +x "$r/$BODY_REL"
}

# ── 1-3: 何も無い所へ入れる ───────────────────────────────────────────────
mk_repo "$T/fresh" || { echo "FAIL  偽 repo を作れない"; exit 1; }
bash "$T/fresh/rc-backend/tools/install-hooks.sh" > "$T/fresh.log" 2>&1
rc=$?
H="$T/fresh/.git/hooks/pre-commit"
if [ "$rc" = "0" ] && [ -f "$H" ]; then
    ok "1 hook が無い所へ入れる(exit 0 かつ file が出来る)"
else
    ng "1 hook が無い所へ入れる" "exit=$rc / $(tail -3 "$T/fresh.log" | tr '\n' ' ')"
fi
if grep -q "$BODY_REL" "$H" 2>/dev/null; then
    ok "2 入れた hook が本体を指す(書けた ≠ 効く)"
else
    ng "2 入れた hook が本体を指す" "本体を呼ばない hook は入れても門が動かない"
fi
if [ -x "$H" ]; then
    ok "3 入れた hook に実行権が付く"
else
    ng "3 入れた hook に実行権が付く" "実行権が無ければ git は黙って無視する"
fi

# ── 4: 冪等 ───────────────────────────────────────────────────────────────
bash "$T/fresh/rc-backend/tools/install-hooks.sh" > "$T/again.log" 2>&1
rc=$?
if [ "$rc" = "0" ] && grep -q "既に入っている" "$T/again.log"; then
    ok "4 もう一度回しても壊れない(冪等)"
else
    ng "4 もう一度回しても壊れない" "exit=$rc / $(tail -2 "$T/again.log" | tr '\n' ' ')"
fi

# ── 5: 別人の hook を黙って消さない ───────────────────────────────────────
mk_repo "$T/foreign" || { echo "FAIL  偽 repo を作れない"; exit 1; }
FH="$T/foreign/.git/hooks/pre-commit"
printf '#!/bin/bash\n# 誰かの大事な hook\nexit 0\n' > "$FH"
chmod +x "$FH"
bash "$T/foreign/rc-backend/tools/install-hooks.sh" > "$T/foreign.log" 2>&1
rc=$?
if [ "$rc" = "1" ]; then
    ok "5 別人の hook が在れば上書きしない(exit 1)"
else
    ng "5 別人の hook が在れば上書きしない" "exit=$rc(黙って誰かの hook を消す道具になっている)"
fi
if grep -q "誰かの大事な hook" "$FH" 2>/dev/null; then
    ok "5b 拒んだ時、既存の中身がそのまま残る"
else
    ng "5b 拒んだ時、既存の中身がそのまま残る" "拒んだと言いながら書き換えている"
fi

# ── 6: 理由つきなら上書きし、控えを残す ───────────────────────────────────
RC_HOOKS_FORCE="旧版の厚い hook を薄い口へ置き換える" \
  bash "$T/foreign/rc-backend/tools/install-hooks.sh" > "$T/force.log" 2>&1
rc=$?
if [ "$rc" = "0" ] && grep -q "$BODY_REL" "$FH" 2>/dev/null; then
    ok "6 理由つきなら上書きする(5 が『常に拒む道具』でない)"
else
    ng "6 理由つきなら上書きする" "exit=$rc / $(tail -3 "$T/force.log" | tr '\n' ' ')"
fi
if ls "$T/foreign/.git/hooks/"pre-commit.bak.* > /dev/null 2>&1; then
    ok "6b 上書きの前に控えを取る(戻せる)"
else
    ng "6b 上書きの前に控えを取る" "消した物が戻せない"
fi
if grep -q "置き換える" "$T/force.log" 2>/dev/null; then
    ok "6c 上書きした理由が出力に残る"
else
    ng "6c 上書きした理由が出力に残る" "黙って上書きしている = 後から辿れない"
fi

# ── 7: 理由が短ければ上書きしない ─────────────────────────────────────────
mk_repo "$T/short" || { echo "FAIL  偽 repo を作れない"; exit 1; }
SH="$T/short/.git/hooks/pre-commit"
printf '#!/bin/bash\n# 誰かの大事な hook\nexit 0\n' > "$SH"
RC_HOOKS_FORCE="ok" bash "$T/short/rc-backend/tools/install-hooks.sh" > "$T/short.log" 2>&1
rc=$?
if [ "$rc" = "1" ] && grep -q "誰かの大事な hook" "$SH" 2>/dev/null; then
    ok "7 短い理由では上書きしない(6 が『変数が在れば通る』でない)"
else
    ng "7 短い理由では上書きしない" "exit=$rc(一言で誰かの hook を消せる = 逃がし弁ではなく穴)"
fi

# ── 8: git repo でなければ exit 2 ─────────────────────────────────────────
mkdir -p "$T/nogit/rc-backend/tools"
cp "$SUBJECT" "$T/nogit/rc-backend/tools/install-hooks.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/nogit/$BODY_REL"
( cd "$T/nogit" && bash rc-backend/tools/install-hooks.sh ) > "$T/nogit.log" 2>&1
rc=$?
if [ "$rc" = "2" ]; then
    ok "8 git repo でなければ未測定として止める(exit 2)"
else
    ng "8 git repo でなければ未測定として止める" "exit=$rc(入れられていないのに 0 か 1 を返している)"
fi

cleanup
if [ -d "$T" ]; then
    ng "後始末" "細工した木が残っている: $T"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
echo "INSTALL-HOOKS-CONTROLS: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
