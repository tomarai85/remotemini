#!/bin/bash
# controls-for: rc-backend/tools/desktop-attach.sh
# desktop-attach-control.sh — 机側の入口が **正しい機体の登録簿**を読む事を測る。2026-08-26 新設。
#
# 守る一線: 「**答えが出る**」と「**正しい答えが出る**」を分ける。
#   登録簿は tmux を持っている機体(Friday)に在る。だが Jervis にも同じ形の登録が
#   **47 件**在る(Jervis 上で走っている Claude Code の物)。手元を読むと、
#   **Jervis の無関係な会話を解決して rc=0 で返す**。宛先だけは Friday の窓なので、
#   出力は完全にそれらしく見える —— 自信のある間違い。
#   ★2026-08-26 に実際にこう書いて、実測するまで気付かなかった。
#   ★Planner が書いた検査は `RC_PANES_DIR` を仕込むので、この壊れ方を**構造的に見られない**。
#
# ★偽 ssh で駆動する。本物の Friday を要求すると、機体が落ちている日に
#   「対照が赤」= 実装の欠陥と読めてしまう(измерение と対象の混同)。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DA="$HERE/desktop-attach.sh"
[ -f "$DA" ] || { echo "★$DA が無い"; exit 2; }

fail=0; reds=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- 偽 ssh: 「Friday の登録簿」と「生きた tmux」を演じる -------------------------
# 遠隔の登録簿は **1件だけ**、手元の登録簿とは**別の session id** にする。
# こうすると「どちらを読んだか」が出力の1語で判る。
REMOTE_SID="ffffffff-1111-2222-3333-444444444444"
LOCAL_SID="00000000-9999-8888-7777-666666666666"
mkdir -p "$TMP/localpanes"
printf '{"session_id":"%s","pane":"%%9","tmux":"/tmp/sock,111,0","pid":2}' "$LOCAL_SID" \
    > "$TMP/localpanes/$LOCAL_SID.json"

cat >"$TMP/ssh" <<STUB
#!/bin/bash
# 引数の最後が遠隔で走る command。中身で何を聞かれているか判じる。
last="\${!#}"
case "\$last" in
    *display-message*) echo "/tmp/sock,111,0"; exit 0 ;;          # 生きた tmux の同一性
    *has-session*)     exit 0 ;;                                   # 窓は在る
    *listdir*|*panes*|*python3*)
        printf '%s\t%s\t%s\n' "$REMOTE_SID" "%7" "/tmp/sock,111,0"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$TMP/ssh"

run_da() { # $@ = 引数。PATH に偽 ssh を差す。RC_PANES_DIR は**渡さない**(素の経路を測る)
    ( cd "$HERE" && env -u RC_PANES_DIR PATH="$TMP:$PATH" HOME="$TMP/fakehome" \
        RC_FRIDAY_HOST=fakehost /bin/bash "$DA" "$@" 2>&1 )
}

# 手元の登録簿を「$HOME/.rc-backend/panes」に見せかける = 誤って読んだら判る様に仕込む
mkdir -p "$TMP/fakehome/.rc-backend"
cp -R "$TMP/localpanes" "$TMP/fakehome/.rc-backend/panes"

echo "=== 1. 素で撃つと **遠隔の**登録簿を読む(手元へ黙って倒れない)[本命] ==="
out="$(run_da --resolve "")"; rc=$?
reds=$((reds + 1))
if printf '%s' "$out" | grep -q "${LOCAL_SID:0:8}"; then
    printf '  ★手元の登録簿を読んだ: %s\n' "$out"; fail=1
elif [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "${REMOTE_SID:0:8}"; then
    printf '  遠隔を読んだ  OK  (%s)\n' "$out"
else
    printf '  ★どちらでもない(rc=%s): %s\n' "$rc" "$out"; fail=1
fi

echo "=== 2. RC_PANES_DIR を明示した時だけ手元を読む(検査と机上の用途)==="
out="$( cd "$HERE" && env PATH="$TMP:$PATH" RC_PANES_DIR="$TMP/localpanes" RC_FRIDAY_HOST=fakehost \
        /bin/bash "$DA" --resolve "" 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "${LOCAL_SID:0:8}"; then
    printf '  明示した手元を読んだ  OK\n'
else
    printf '  ★明示しても手元を読まない(rc=%s): %s\n' "$rc" "$out"; fail=1
fi

echo "=== 3. 入口は pane id ではなく **窓の名前** ==="
out="$(run_da --print)"; rc=$?
if printf '%s' "$out" | grep -q "attach -t work:phone"; then
    printf '  名前で入る  OK\n'
else
    printf '  ★名前で入っていない: %s\n' "$out"; fail=1
fi
reds=$((reds + 1))
if printf '%s' "$out" | grep -qE "attach -t %[0-9]"; then
    printf '  ★pane id で入ろうとしている(世代が変わると別の会話に着く)\n'; fail=1
fi

echo "=== 4. 登録が1件も無ければ「無い」と言う(でっち上げない)[負] ==="
cat >"$TMP/ssh" <<'STUB2'
#!/bin/bash
last="${!#}"
case "$last" in
    *display-message*) echo "/tmp/sock,111,0"; exit 0 ;;
    *) exit 3 ;;
esac
STUB2
chmod +x "$TMP/ssh"
out="$(run_da --resolve "")"; rc=$?
reds=$((reds + 1))
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -q "登録が無い"; then
    printf '  無いと言う(rc=3)  OK\n'
else
    printf '  ★でっち上げた(rc=%s): %s\n' "$rc" "$out"; fail=1
fi

echo
echo "  赤に倒れる入力: ${reds} 件"
[ "$reds" -lt 2 ] && { echo "  ★対照が空虚"; fail=1; }
echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
