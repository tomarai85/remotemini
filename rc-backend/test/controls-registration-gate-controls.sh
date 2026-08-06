#!/bin/bash
# controls-for: tools/controls-registration-gate.sh
#
# 「対照を新設した commit は全掃きの一覧も触る」門が、**緑・赤・測れていない**を
# 撃ち分けられるかを測る。
#
# ── なぜ要るか ────────────────────────────────────────────────────────────
# この門も既定が緑(対照を1本も新設していない commit は黙って通す)。この repo が
# 何度も踏んだ形なので、「新設したら赤くなる」を実際に撃って確かめるまで、
# 此の門は緑を主張する資格が無い。門の値打ちは**止める時**にしか出ない。
#
# ── どう測るか ────────────────────────────────────────────────────────────
# 本物の repo では測れない(本物の index を汚す)。偽の repo を `git init` して、
# 門の本体だけ持ち込んで撃つ。門は自分の位置から repo の根を導く造りなので、
# 偽 repo の中でも `rc-backend/tools/` に置けばそのまま動く。
#
# 終了コード: 0=緑 / 1=赤 / 2=測れていない
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBJECT="$REPO_ROOT/rc-backend/tools/controls-registration-gate.sh"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

T="$(mktemp -d)"
cleanup() {
    [ -n "${T:-}" ] && [ -d "$T" ] || return 0
    find "$T" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$T" -type d -depth -print 2>/dev/null | while read -r d; do /bin/rmdir "$d" 2>/dev/null; done
}
trap cleanup EXIT

[ -f "$SUBJECT" ] || { echo "FAIL  対象が無い: $SUBJECT"; echo "--- 合計: PASS 0 / FAIL 1 ---"; exit 2; }

# ── 偽 repo ───────────────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R/rc-backend/tools" "$R/rc-backend/test" "$R/.harness" "$R/odd"
git -C "$R" init -q 2>/dev/null || { echo "FAIL  偽 repo を作れない"; exit 2; }
git -C "$R" config user.email "c@example.invalid"
git -C "$R" config user.name "controls"
cp "$SUBJECT" "$R/rc-backend/tools/controls-registration-gate.sh"
printf 'LOCAL_CTLS=(\n)\n' > "$R/rc-backend/tools/run-controls.sh"
printf '#!/bin/bash\n# controls-for: tools/x.sh\nexit 0\n' > "$R/rc-backend/test/existing-controls.sh"
printf '# doc\n' > "$R/README.md"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -qm base >/dev/null 2>&1 || { echo "FAIL  base commit が作れない"; exit 2; }

run_gate() { # $1 = 使う門の path(既定は偽 repo の中の本物)
    local g="${1:-$R/rc-backend/tools/controls-registration-gate.sh}"
    ( cd "$R" && bash "$g" > "$T/out.log" 2>&1; echo $? )
}
unstage() { git -C "$R" reset -q >/dev/null 2>&1; }
new_ctl() { printf '#!/bin/bash\n# controls-for: tools/y.sh\nexit 0\n' > "$R/$1"; git -C "$R" add "$1" >/dev/null 2>&1; }
touch_reg() { printf '#追記\n' >> "$R/rc-backend/tools/run-controls.sh"; git -C "$R" add rc-backend/tools/run-controls.sh >/dev/null 2>&1; }

# ── 1: 対照を新設して一覧を触っていない → 赤、名前が出る ────────────────────
unstage; new_ctl rc-backend/test/new-a-controls.sh
rc="$(run_gate)"
if [ "$rc" = "1" ] && grep -q "new-a-controls.sh" "$T/out.log"; then
    ok "1 新設だけ(一覧を触らない)なら赤で、その file を名指しする"
else
    ng "1 新設だけなら赤" "exit=$rc: $(head -2 "$T/out.log" | tr '\n' ' ')"
fi

# ── 2: 同じ commit で一覧も触れば緑 ───────────────────────────────────────
touch_reg
rc="$(run_gate)"
[ "$rc" = "0" ] && ok "2 一覧も同じ commit で触れば緑" \
    || ng "2 一覧も触れば緑" "exit=$rc: $(head -2 "$T/out.log" | tr '\n' ' ')"

# ── 3: 既存の対照を**変更しただけ**なら止めない(A でも R でもない)──────────
unstage
printf '# 変更\n' >> "$R/rc-backend/test/existing-controls.sh"
git -C "$R" add rc-backend/test/existing-controls.sh >/dev/null 2>&1
rc="$(run_gate)"
[ "$rc" = "0" ] && ok "3 既存の対照の変更だけでは止めない" \
    || ng "3 既存の変更では止めない" "exit=$rc: $(head -2 "$T/out.log" | tr '\n' ' ')"

# ── 4: ★走査 dir の**外**に新設しても赤(手書きの dir 一覧を持たない証明)────
#    ここが緑になる造りだと、門の視野の外に対照を置く事で守りを黙らせられる。
unstage; new_ctl odd/oddplace-controls.sh
rc="$(run_gate)"
if [ "$rc" = "1" ] && grep -q "oddplace-controls.sh" "$T/out.log"; then
    ok "4 走査 dir の外に置いても赤(名前だけで判る)"
else
    ng "4 走査 dir の外でも赤" "exit=$rc: $(head -2 "$T/out.log" | tr '\n' ' ')"
fi

# ── 5: 改名で対照の名前になった時も赤 ─────────────────────────────────────
#    git が改名(R)と読むか 追加+削除(A+D)と読むかは類似度次第だが、
#    **どちらでも赤**でなければならない(この対照はその両方を許す形で測る)。
unstage
git -C "$R" mv rc-backend/test/existing-controls.sh rc-backend/test/renamed-controls.sh >/dev/null 2>&1
rc="$(run_gate)"
if [ "$rc" = "1" ] && grep -q "renamed-controls.sh" "$T/out.log"; then
    ok "5 改名で対照名になった時も赤"
else
    ng "5 改名でも赤" "exit=$rc: $(head -2 "$T/out.log" | tr '\n' ' ')"
fi
git -C "$R" mv rc-backend/test/renamed-controls.sh rc-backend/test/existing-controls.sh >/dev/null 2>&1

# ── 6: 対照を1本も新設していない commit は緑、しかも**無言** ─────────────────
#    喋る門は「書類だけの commit」に費用を掛ける。無言である事も契約のうち。
unstage
printf '# 追記\n' >> "$R/README.md"
git -C "$R" add README.md >/dev/null 2>&1
rc="$(run_gate)"
if [ "$rc" = "0" ] && [ ! -s "$T/out.log" ]; then
    ok "6 対照を新設していなければ緑、かつ無言"
else
    ng "6 新設が無ければ緑かつ無言" "exit=$rc out=$(wc -c < "$T/out.log")B"
fi

# ── 7: 降ろす口は理由を出力に残す ─────────────────────────────────────────
unstage; new_ctl rc-backend/test/new-b-controls.sh
rc="$( cd "$R" && RC_CTLREG_OK="理由を書いた" bash "$R/rc-backend/tools/controls-registration-gate.sh" > "$T/out.log" 2>&1; echo $? )"
if [ "$rc" = "0" ] && grep -q "理由を書いた" "$T/out.log"; then
    ok "7 降ろす口は通すが、理由を出力に残す"
else
    ng "7 降ろす口は理由を残す" "exit=$rc: $(head -2 "$T/out.log" | tr '\n' ' ')"
fi

# ── 8: ★陰性対照 —— 止める部分を潰すと 1 が緑になる ────────────────────────
#    1 の赤が「たまたま非ゼロ」ではなく、**この門の停止**から来ている事の証明。
MUT="$T/mutant-gate.sh"
mkdir -p "$T/mut/rc-backend/tools"
sed 's/^exit 1$/exit 0/' "$SUBJECT" > "$T/mut/rc-backend/tools/controls-registration-gate.sh"
MUT="$T/mut/rc-backend/tools/controls-registration-gate.sh"
if cmp -s "$SUBJECT" "$MUT"; then
    echo "UNMEASURED  8 変異が当たっていない(exit 1 の行が見つからない)"
    fail=$((fail+1))
else
    # 変異した門は偽 repo の外に居るので、repo の根は引数で渡せない造り ——
    # 代わりに偽 repo の中へ**置き換えて**撃ち、終わったら本物へ戻す。
    cp "$R/rc-backend/tools/controls-registration-gate.sh" "$T/gate-backup.sh"
    cp "$MUT" "$R/rc-backend/tools/controls-registration-gate.sh"
    unstage; new_ctl rc-backend/test/new-c-controls.sh
    rc="$(run_gate)"
    cp "$T/gate-backup.sh" "$R/rc-backend/tools/controls-registration-gate.sh"
    [ "$rc" = "0" ] && ok "8 陰性対照: 止める行を潰すと 1 の場面が緑に変わる" \
        || ng "8 陰性対照" "変異させても exit=$rc(1 の赤は別の所から来ている)"
fi

# ── 9: git として読めない所では**測っていない**(緑に丸めない)──────────────
mkdir -p "$T/nogit/rc-backend/tools"
cp "$SUBJECT" "$T/nogit/rc-backend/tools/controls-registration-gate.sh"
rc="$( cd "$T/nogit" && bash "$T/nogit/rc-backend/tools/controls-registration-gate.sh" > "$T/out.log" 2>&1; echo $? )"
[ "$rc" = "2" ] && ok "9 git として読めなければ exit 2(未測定)" \
    || ng "9 git でなければ未測定" "exit=$rc: $(head -2 "$T/out.log" | tr '\n' ' ')"

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" -eq 0 ] || exit 1
exit 0
