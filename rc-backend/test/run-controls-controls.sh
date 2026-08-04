#!/bin/bash
# controls-for: tools/run-controls.sh
# `tools/run-controls.sh` の対照 —— **対照を回す物そのもの**を測る。
#
# なぜ要るか(2026-08-03): この repo の対照 21 本は全部この1本から回る。
# だからこれが静かに壊れると、**21 本分の緑が一度に嘘になる**。それでいて
# 今日まで対照が無く、`staged-controls-gate.sh` が
# 「対照を導けない道具: deploy-to-edith run-controls」と名指しして初めて見えた。
#
# ★実際に1件見つけた: 直す前は `exit $(( red > 0 ))` だったので、
#   **未測定が在っても 0 = 緑**を返していた。画面には「未測定(緑ではない)」と正しく
#   出しているのに、終了コードだけ緑。HANDOFF:2496 は最初から
#   「0=緑 / 1=赤 / 2=測っていない の三値を保つ事」と書いてある —— 規則は在って、
#   **回す物が無かった**(DESIGN (19))。この lane では変異の走行中に
#   `mutation-verdict` / `mutation-freeze` が 2 を返すので、**一番よく起きる状況**で
#   「一番重い対照2本を測っていない run」が緑になっていた。
#
# 型 = 差替型。`${RUN_CONTROLS:-…}` の継ぎ目から旧版を差し込める(prove-control.sh 用)。
#
# ★入力の作り方(run-controls.sh 冒頭の規則 (1)「入力は本物の生成元から取る」):
#   子の一覧を手で書かない。**測る当の台本から `LOCAL_CTLS` / `EDITH_CTLS` を読み取って**
#   その名前で偽の子を作る。手で書くと「一覧はこういう形の筈だ」という思い込みごと緑になり、
#   本数が変わった時に対照だけ古いまま通る。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${RUN_CONTROLS:-$ROOT/tools/run-controls.sh}"

pass=0; fail=0
chk() { # chk <名前> <期待> <実際>
  local name=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then echo "OK  $name"; pass=$((pass+1))
  else echo "NG  $name"; echo "      期待=$want 実際=$got"; fail=$((fail+1)); fi
}

# ── 砂場を1つ建てる ────────────────────────────────────────────────────────
# 本物の repo にも本物の対照にも触らない。台本は自分の `dirname/..` を ROOT にするので、
# 砂場の `tools/` に置けば砂場の `test/` を見る。
SANDBOX="$(/usr/bin/mktemp -d /tmp/rc-runctl.XXXXXX)"
trap '/usr/bin/find "$SANDBOX" -type f -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null; /usr/bin/find "$SANDBOX" -type d -depth -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rmdir 2>/dev/null' EXIT
/bin/mkdir -p "$SANDBOX/tools" "$SANDBOX/test"
/bin/cp "$RUNNER" "$SANDBOX/tools/run-controls.sh" || { echo "★継ぎ目の台本が読めない: $RUNNER"; exit 2; }

# ★一覧は測る台本から取る(規則 (1))。手書きしない。
# ★2026-08-05 に相対パスの許容範囲を広げた: 電話側(`ios/tools/`)の対照は
#   `rc-backend/` の外に居るので、`LOCAL_CTLS` の項目は「..(スラッシュ)ios(スラッシュ)
#   tools(スラッシュ)実ファイル名」の形になる(`run-controls.sh` の cwd が
#   `rc-backend/` の為)。※この形をそのまま backtick で書かない事 --
#   引用元がこの file(`rc-backend/test/`)だと相対パスの起点がずれて実在しない
#   引用と誤判定される(no-linerefs.test.mjs の解決規則: `../` 始まりは
#   引用元ファイルの dirname から解決するので、`run-controls.sh` の中で正しい
#   相対パスをここへそのまま貼ると壊れる)。旧正規表現は
#   行頭が文字通り `test/` か `tools/` で始まる項目しか拾えず、`../` で始まる
#   この2項目を無言で数え落としていた(実測: 34本中32本しか拾えず、この台本
#   自身の R13/R16 が `$N_LOCAL` の値で赤になった —— 本物の `run-controls.sh`
#   は regex を使わず配列をそのまま回すので2本とも正しく実行・緑になっていたのに、
#   **測る側の再集計だけ**が古い前提のまま止まっていた)。コメント継続行は
#   この配列ブロック内では必ず行頭が `#` なので、`test|tools` の縛りを外しても
#   誤って拾う行は無い(確認済み: 新旧の抽出結果の差分は追加した2項目のみ)。
mapfile_names() { # mapfile_names <配列名>
  /usr/bin/sed -n "/^$1=(/,/^)/p" "$SANDBOX/tools/run-controls.sh" \
    | /usr/bin/grep -oE '^ *[A-Za-z0-9._/-]+\.(sh|py)' \
    | /usr/bin/tr -d ' '
}
LOCAL_NAMES=$(mapfile_names LOCAL_CTLS)
EDITH_NAMES=$(mapfile_names EDITH_CTLS)
N_LOCAL=$(printf '%s\n' "$LOCAL_NAMES" | /usr/bin/grep -c . )
N_EDITH=$(printf '%s\n' "$EDITH_NAMES" | /usr/bin/grep -c . )

if [ "$N_LOCAL" -lt 3 ] || [ "$N_EDITH" -lt 1 ]; then
  echo "★一覧を読み取れなかった(local=$N_LOCAL edith=$N_EDITH)= 測定不成立"
  exit 2
fi

# 偽の子を据える。`<名前> <rc>` を渡された物だけ rc を変え、他は 0。
# ★どの子も**走った印**を残す —— 「最初の赤で打ち切っていないか」を測る為(R15)。
setup() { # setup [<basename> <rc>]...
  local n rc
  # ★`! -path …/run-controls.sh` を外すと**測る当の台本を消す**。
  #   `run-controls.sh` 自身が `*-controls.sh` に一致するので、掃除の網に掛かる。
  #   一度これで 19 本全部が rc=127(台本が無い)で落ちた。名前が似ている道具を
  #   glob で掃除する時の定番の事故。
  /usr/bin/find "$SANDBOX/test" "$SANDBOX/tools" -name '*-controls.sh' -type f \
    ! -path "$SANDBOX/tools/run-controls.sh" -print0 2>/dev/null \
    | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null
  /bin/rm -f "$SANDBOX/ran.txt" "$SANDBOX/tools/rc-backend-launch-check.sh"
  : > "$SANDBOX/ran.txt"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    /bin/mkdir -p "$SANDBOX/$(/usr/bin/dirname "$n")"
    printf '#!/bin/bash\necho "%s" >> "%s/ran.txt"\necho "偽の子 %s"\nexit 0\n' \
      "$(/usr/bin/basename "$n")" "$SANDBOX" "$n" > "$SANDBOX/$n"
  done <<EOF
$LOCAL_NAMES
$EDITH_NAMES
EOF
  while [ $# -gt 0 ]; do
    n="$1"; rc="$2"; shift 2
    if [ "$rc" = "missing" ]; then
      /bin/rm -f "$SANDBOX/test/$n" "$SANDBOX/tools/$n"
    else
      local p="$SANDBOX/test/$n"; [ -f "$p" ] || p="$SANDBOX/tools/$n"
      printf '#!/bin/bash\necho "%s" >> "%s/ran.txt"\necho "偽の子 %s(rc=%s)"\nexit %s\n' \
        "$n" "$SANDBOX" "$n" "$rc" "$rc" > "$p"
    fi
  done
}

# ★出力を返り値でなく file 経由にする理由: 命令置換は**部分shell**なので、
#   関数の中で置いた `RUN_RC` が親へ戻らない(`set -u` の下では unbound で落ちる)。
#   終了コードを親で読む必要が在るので、出力は file、rc は変数、と分ける。
OUTF="$SANDBOX/out.txt"
RUN_RC=0
run() { # run [--all] -> 出力は $OUTF、rc は $RUN_RC
  /bin/bash "$SANDBOX/tools/run-controls.sh" "$@" > "$OUTF" 2>&1
  RUN_RC=$?
}
readout() { /bin/cat "$OUTF"; }

# 一覧の先頭2本(名前は測る台本から来るので固定名を書かない)
C1=$(printf '%s\n' "$LOCAL_NAMES" | /usr/bin/sed -n 1p | /usr/bin/xargs /usr/bin/basename)
C2=$(printf '%s\n' "$LOCAL_NAMES" | /usr/bin/sed -n 2p | /usr/bin/xargs /usr/bin/basename)
C3=$(printf '%s\n' "$LOCAL_NAMES" | /usr/bin/sed -n 3p | /usr/bin/xargs /usr/bin/basename)

# ── R1 全部緑 ──────────────────────────────────────────────────────────────
setup
run; out=$(readout)
chk "R1 全部緑 -> 0" 0 "$RUN_RC"
chk "R1b 集計が緑の本数を出す" 1 "$(printf '%s' "$out" | /usr/bin/grep -c "green=$N_LOCAL red=0 未測定=0")"

# ── R2 赤が1本 ────────────────────────────────────────────────────────────
setup "$C1" 1
run; out=$(readout)
chk "R2 赤が在れば 1" 1 "$RUN_RC"
chk "R3 赤の名前を出す" 1 "$(printf '%s' "$out" | /usr/bin/grep -c "赤: .*$C1")"

# ── R4 ★★未測定(2)を終了コードでも緑に丸めない ──────────────────────────
#   ここが直した所。旧版は `exit $(( red > 0 ))` なので **0** を返す。
setup "$C1" 2
run; out=$(readout)
chk "R4 ★★未測定は 2(0 に丸めない)" 2 "$RUN_RC"
chk "R5 未測定の名前を出す" 1 "$(printf '%s' "$out" | /usr/bin/grep -c "未測定(.*): .*$C1")"
chk "R6 未測定は赤に混ぜない" 1 "$(printf '%s' "$out" | /usr/bin/grep -c 'red=0 未測定=1')"

# ── R7 赤と未測定が同時 -> 赤が勝つ ───────────────────────────────────────
setup "$C1" 1 "$C2" 2
run; out=$(readout)
chk "R7 赤 + 未測定 -> 1" 1 "$RUN_RC"
chk "R8 両方数える" 1 "$(printf '%s' "$out" | /usr/bin/grep -c 'red=1 未測定=1')"

# ── R9 ★file が無い時に黙って飛ばさない ──────────────────────────────────
#   一覧に在るのに現物が無い = 「対照を消したのに一覧から外し忘れた」形。
#   飛ばすと本数だけ減って緑になる。
setup "$C1" missing
run; out=$(readout)
chk "R9 ★不在は赤(黙って飛ばさない)" 1 "$RUN_RC"
chk "R10 不在と分かる形で名指しする" 1 "$(printf '%s' "$out" | /usr/bin/grep -c "$C1(不在)")"

# ── R11 0/1/2 以外は赤(未測定に落とさない)────────────────────────────────
setup "$C1" 7
run; out=$(readout)
chk "R11 rc=7 は赤" 1 "$RUN_RC"
chk "R12 未測定に数えない" 1 "$(printf '%s' "$out" | /usr/bin/grep -c 'red=1 未測定=0')"

# ── R13 --all で edith 専用が加わる ───────────────────────────────────────
setup
run --all; out=$(readout)
chk "R13 --all で対象が増える" 1 "$(printf '%s' "$out" | /usr/bin/grep -c "対象 $((N_LOCAL + N_EDITH))本")"
chk "R14 既定では edith 専用を除外と明記" 1 "$(run; readout | /usr/bin/grep -c 'edith専用')"

# ── R15 ★最初の赤で打ち切らない ───────────────────────────────────────────
#   打ち切ると、後ろに並んだ対照の赤が**一度も出ない**。全部緑の日には区別が付かない。
setup "$C1" 1
run
chk "R15 ★赤の後の子も走る" "$N_LOCAL" "$(/usr/bin/grep -c . "$SANDBOX/ran.txt")"

# ── R16 ★陰性対照: 4 種が同じ run で同時に数えられる ─────────────────────
#   R1/R4/R9 が個別に通るのは、分類しているからか **たまたま同じ枝を通っている**からか。
#   緑・赤・未測定・不在が1回の run で同時に立つ事を見せて初めて「見分けている」と言える。
setup "$C1" 1 "$C2" 2 "$C3" missing
run; out=$(readout)
chk "R16 ★陰性対照: 赤2(不在含む)+ 未測定1" 1 \
    "$(printf '%s' "$out" | /usr/bin/grep -c "green=$((N_LOCAL - 3)) red=2 未測定=1")"
chk "R17 ★陰性対照: 赤が勝って 1" 1 "$RUN_RC"

# ── R18 子の最終行を人が読める形で出す ────────────────────────────────────
setup
run; out=$(readout)
#   ★本数で見る。1本でも出ていれば良い、にすると「1本だけ出して残りを捨てる」を通す。
chk "R18 子の最終行を全部の子について出す" "$N_LOCAL" "$(printf '%s' "$out" | /usr/bin/grep -c '偽の子 ')"

# ── R19-R21 ★一覧に載っていない対照を見つける(2026-08-04 に実際に漏れた)──────
#   `LOCAL_CTLS` は手書きなので、対照を書いても足し忘れると**一度も回らない**。
#   実測: repo に 30 本在って登録は 29 本、漏れは同じ日に書いた copied-tree-controls.sh。
#   ★ここで測るのは「漏れを見つける」だけでなく、**平時に鳴らない**事の両方。
#     常に鳴る門は外されるので、偽陽性が出ないかを先に釘付けにする(R19)。
setup
run; out=$(readout)
chk "R19 平時は登録漏れを鳴らさない(偽陽性なし)" 0 \
    "$(printf '%s' "$out" | /usr/bin/grep -c 'UNREG')"

# 一覧に無い対照を1本植える。名前は既存のどれとも重ならない形にする。
ORPHAN="$SANDBOX/test/zz-not-registered-controls.sh"
printf '#!/bin/bash\necho "偽の子 zz"\nexit 0\n' > "$ORPHAN"
run; out=$(readout)
chk "R20 ★未登録の対照を**名指しで**出す" 1 \
    "$(printf '%s' "$out" | /usr/bin/grep -c 'UNREG.*zz-not-registered-controls.sh')"
#   赤(1)であって未測定(2)ではない —— 回せなかったのではなく、回す物が無い事が確定している。
chk "R21 ★未登録は赤(未測定に丸めない)" 1 "$RUN_RC"
/bin/rm -f "$ORPHAN"

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
