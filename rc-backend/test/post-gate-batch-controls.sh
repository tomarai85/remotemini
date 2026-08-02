#!/bin/bash
# post-gate-batch.sh の**門**が両方向に壊れていないかを、edith も上限も使わずに測る。
#
# なぜ要るか: この台本の値打ちは「明けていない間、絶対に撃たない」事だけにある。
# 門が誤って開けば、上限の残りを台本の誤作動で溶かす —— しかも解除は1回きり。
# 「閉じている時に閉じる」は今夜1回実測したが、それは**片方向**でしかない:
#   ・閉じる方向 … 上限が生きている今なら本物で撃てる(済)
#   ・開く方向   … 本物では窓が開くまで測れない → **偽の ssh/scp で測る**
# 開く方向を測らないと「常に閉じる門」(= 窓が開いても撃たない)を緑と読んでしまう。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
BATCH="tools/post-gate-batch.sh"
ok=0; ng=0
STUB="$(mktemp -d "${TMPDIR:-/tmp}/pgb-stub.XXXXXX")"
trap 'find "$STUB" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
      find "$STUB" -type d 2>/dev/null | awk "{print length, \$0}" | sort -rn | cut -d" " -f2- |
        while read -r d; do rmdir "$d" 2>/dev/null; done' EXIT

chk() { # chk <名前> <期待exit> <実exit> [<出てはいけない語>]
    local name="$1" want="$2" got="$3" forbid="${4:-}"
    if [ "$got" = "$want" ] && { [ -z "$forbid" ] || ! grep -q "$forbid" "$STUB/out"; }; then
        echo "  OK   $name"; ok=$((ok+1))
    else
        echo "  NG   $name (期待 exit=$want / 実際 $got${forbid:+ / 禁句「$forbid」})"
        sed 's/^/       | /' "$STUB/out" | head -12
        ng=$((ng+1))
    fi
}

# 偽の ssh / scp を PATH の先頭に置く。FAKE_MODE で門の答えを差し替える。
mkstub() {
    cat > "$STUB/ssh" <<'EOS'
#!/bin/bash
# 撃った事を記録する。ここに何か残ったら「撃たない筈が撃った」の証拠。
echo "SSH-CALLED: $*" >> "$FIRED"
# ★偽物は**向こう側の契約**まで真似る必要がある。本物の ssh は渡された
#   コマンド文字列を remote の shell で走らせるので、その中の `echo GATE-EXIT=$?`
#   も出力に載る。ここを省くと台本は「GATE-EXIT が読めない」で fail-closed し、
#   偽物の手抜きが**台本の欠陥に見える**(初版はこれで C2 が偽赤になった)。
emit() { echo "GATE-EXIT=$1"; }
case "$FAKE_MODE" in
  lifted)   echo "測った所: Edith : /Users/edith/.claude/projects"
            echo "直近2時間: 転写7本"; echo "   claude-opus-4: 成功 3 / エラー 0"
            echo "→ 上限は明けている(成功した model: claude-opus-4)"; emit 0; exit 0 ;;
  wronghost)echo "測った所: Jervis : /Users/tomtim/.claude/projects"
            echo "→ 上限は明けている(成功した model: claude-opus-4)"; emit 0; exit 0 ;;
  closed)   echo "測った所: Edith : /Users/edith/.claude/projects"
            echo "→ まだ明けていない"; emit 3; exit 3 ;;
  nogate)   # 門の行そのものが出ない(ssh が途中で切れた等)。fail-closed が正。
            echo "ssh: connect to host port 22: Operation timed out" >&2; exit 255 ;;
esac
exit 0
EOS
    printf '#!/bin/bash\nexit 0\n' > "$STUB/scp"
    chmod +x "$STUB/ssh" "$STUB/scp"
}
mkstub
export FIRED="$STUB/fired"

run_batch() { # run_batch <FAKE_MODE>
    : > "$FIRED"
    FAKE_MODE="$1" PATH="$STUB:$PATH" bash "$BATCH" > "$STUB/out" 2>&1
    echo $?
}

echo "post-gate-batch 門の対照:"

# C1 閉じている → 3、かつ item を1本も撃たない
rc=$(run_batch closed)
chk "C1 閉じている時は exit 3" 3 "$rc"
if grep -q "live-inject-check\|live-http-check\|live-fork-check" "$FIRED" 2>/dev/null; then
    echo "  NG   C1b 閉じているのに検査を撃った"; sed 's/^/       | /' "$FIRED"; ng=$((ng+1))
else
    echo "  OK   C1b 閉じている間、検査は1本も撃たれない"; ok=$((ok+1))
fi

# C2 ★開く方向 —— 明けたら実際に 1→4 を撃つ。ここが緑でないと門は「常に閉じる門」
rc=$(run_batch lifted)
n=$(grep -c "live-inject-check\|live-http-check" "$FIRED" 2>/dev/null || true)
if [ "${n:-0}" -ge 3 ]; then
    echo "  OK   C2 明けたら 1-3 を撃つ(観測 ${n}本)"; ok=$((ok+1))
else
    echo "  NG   C2 明けたのに撃たない = 常に閉じる門(観測 ${n:-0}本)"; ng=$((ng+1))
fi

# C3 ★機械が違う —— exit 0 でも「測った所」が edith でなければ撃たない。
#    今夜の「主語の無い green」がそのままこの台本に入り込む経路。
rc=$(run_batch wronghost)
chk "C3 手元で測った緑では撃たない" 3 "$rc"
if grep -q "live-inject-check" "$FIRED" 2>/dev/null; then
    echo "  NG   C3b 別の機械の緑で撃った"; ng=$((ng+1))
else
    echo "  OK   C3b 別の機械の緑では1本も撃たない"; ok=$((ok+1))
fi

# C5 門の行が読めない(ssh が落ちた) → 撃たない。曖昧な時に撃つ門は門ではない
rc=$(run_batch nogate)
chk "C5 門の答えが読めなければ撃たない" 3 "$rc"
if grep -q "live-inject-check" "$FIRED" 2>/dev/null; then
    echo "  NG   C5b 門が読めないのに撃った"; ng=$((ng+1))
else
    echo "  OK   C5b 門が読めない時は1本も撃たない"; ok=$((ok+1))
fi

# C4 dry は何も撃たず、緑とも言わない
: > "$FIRED"
RC_DRY=1 PATH="$STUB:$PATH" bash "$BATCH" > "$STUB/out" 2>&1
rc=$?
chk "C4 dry は exit 0 で「4項目とも緑」と言わない" 0 "$rc" "4項目とも緑"
if [ -s "$FIRED" ]; then
    echo "  NG   C4b dry なのに ssh を撃った"; ng=$((ng+1))
else
    echo "  OK   C4b dry は ssh を1回も撃たない"; ok=$((ok+1))
fi

echo "post-gate-batch 門: OK=$ok NG=$ng"
[ "$ng" -eq 0 ] || exit 1
