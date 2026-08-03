#!/bin/bash
# `tools/prove-control.sh` 自身の対照。
#
# なぜ要るか: prove-control.sh は「対照が効いているか」を判定する道具なので、
# **これが壊れると全ての対照の判定が静かに嘘になる**。しかも一番危ない壊れ方は
# 「常に 0(効いている)を返す」= 緑の顔をした未測定で、それは普段の使用では見えない。
#
# 本物の repo では変異走行中に断る造りなので、測定経路が長時間**一度も動かせない**。
# そこで `RC_ROOT` の継ぎ目で**砂場の repo** を指す(継ぎ目を使うのであって、
# 門を迂回しているのではない —— 砂場には変異走行の機構がそもそも無い)。
#
# 砂場の作り: 守り `$d/tools/guard.sh` を v1(欠陥あり)→ v2(直した)の順で commit し、
# 対照 `$d/test/g-controls.sh` を置く(**この repo の file ではない**。走行中に
# `mk_sandbox` が作る。名前だけ書くと「実在する file を引いた」形になり、
# `test/no-linerefs.test.mjs` の引用検査が正しく赤にする —— 実際に一度赤くした)。
# prove-control.sh が
#   ①今の版(v2)= 緑 ②旧版(v1)= 赤 ③どの行が倒れたか
# を正しく出せるかを見る。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVE="${PROVE_SCRIPT:-$ROOT/tools/prove-control.sh}"

pass=0; fail=0
chk() { # chk <名前> <期待rc> <実rc> <含むべき> <含んではいけない> <出力>
  local name=$1 want=$2 got=$3 must=$4 mustnot=$5 out=$6 bad=""
  [ "$got" = "$want" ] || bad="rc=$got (期待 $want)"
  # ★`$must」` と書くと bash が変数名に multibyte を巻き込み `set -u` で落ちる。
  #   日本語が直後に来る展開は **必ず `${...}`**(この repo で既に一度踏んでいる)。
  #   しかもこの行は**失敗した時にしか通らない**ので、対照が全部緑の間は見えなかった。
  #   検査の失敗経路そのものを一度は通す事(負の対照で実際に通して見つけた)。
  [ -z "$must" ]    || printf '%s' "$out" | grep -qF -- "$must"    || bad="${bad}; 「${must}」が無い"
  [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot" || bad="${bad}; 「${mustnot}」が出ている"
  if [ -n "$bad" ]; then echo "NG  $name -- $bad"; fail=$((fail+1)); else echo "OK  $name"; pass=$((pass+1)); fi
}

SB="$(/usr/bin/mktemp -d -t provectl)" || exit 2
trap '/bin/rm -rf "$SB" 2>/dev/null' EXIT INT TERM HUP
G() { git -c user.email=t@example.com -c user.name=t -C "$1" "${@:2}"; }

# ── 砂場を組む ────────────────────────────────────────────────────────────
mk_sandbox() { # mk_sandbox <dir> <対照の中身>
  local d=$1 ctl=$2
  /bin/mkdir -p "$d/tools" "$d/test"
  G "$d" init -q 2>/dev/null || { /bin/mkdir -p "$d"; (cd "$d" && git init -q); }
  # v1 = 欠陥あり(危ない入力を素通しする)
  printf '#!/bin/bash\nexit 0\n' > "$d/tools/guard.sh"
  /bin/chmod +x "$d/tools/guard.sh"
  printf '%s\n' "$ctl" > "$d/test/g-controls.sh"
  /bin/chmod +x "$d/test/g-controls.sh"
  G "$d" add -A >/dev/null 2>&1; G "$d" commit -q -m v1 >/dev/null 2>&1
  # v2 = 直した(危ない入力を赤にする)
  printf '#!/bin/bash\n[ "${1:-}" = BAD ] && exit 1\nexit 0\n' > "$d/tools/guard.sh"
  G "$d" add -A >/dev/null 2>&1; G "$d" commit -q -m "危ない入力を赤にする" >/dev/null 2>&1
}

# 見分ける対照 = 危ない入力の検査(A1)と、安全な入力の検査(A2)を両方持つ
CTL_GOOD='#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="${GUARD_SCRIPT:-$ROOT/tools/guard.sh}"
f=0
if bash "$G" BAD >/dev/null 2>&1; then echo "NG  A1 危ない入力を赤にする"; f=1; else echo "OK  A1 危ない入力を赤にする"; fi
if bash "$G" GOOD >/dev/null 2>&1; then echo "OK  A2 安全な入力は緑のまま"; else echo "NG  A2 安全な入力は緑のまま"; f=1; fi
exit $f'

# 見分けない対照 = 安全な入力しか見ていない(v1 でも v2 でも緑)
CTL_BLIND='#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="${GUARD_SCRIPT:-$ROOT/tools/guard.sh}"
f=0
if bash "$G" GOOD >/dev/null 2>&1; then echo "OK  B1 安全な入力は緑のまま"; else echo "NG  B1 安全な入力は緑のまま"; f=1; fi
exit $f'

# 見分けるが、**行の形が NG/OK でない**対照(判定は正しいのに③が読めない型)
CTL_ODD='#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="${GUARD_SCRIPT:-$ROOT/tools/guard.sh}"
f=0
if bash "$G" BAD >/dev/null 2>&1; then echo "[×] C1 危ない入力を赤にする"; f=1; else echo "[○] C1 危ない入力を赤にする"; fi
exit $f'

run_prove() { RC_ROOT="$1" bash "$PROVE" test/g-controls.sh GUARD_SCRIPT tools/guard.sh 2>&1; }

# ── P1 効いている対照を「効いている」と言う ───────────────────────────────
d="$SB/good"; mk_sandbox "$d" "$CTL_GOOD"
out=$(run_prove "$d"); chk "P1 見分ける対照 -> 効いている(rc=0)" 0 $? "PROVE: 効いている" "" "$out"

# ── P2 ★どの行が倒れたかを名指しする ──────────────────────────────────────
#    ここがこの道具の本体。「suite が赤い」で終わる実装を落とす為の対照。
chk "P2 倒れた assertion を名指しする(A1)" 0 0 "A1 危ない入力を赤にする" "" "$out"
chk "P3 倒れなかった側も出す(A2)" 0 0 "A2 安全な入力は緑のまま" "" "$out"

# ── P4 効いていない対照を「効いていない」と言う ★一番危ない誤り ───────────
#    常に 0 を返す実装はここだけが落ちる。
d2="$SB/blind"; mk_sandbox "$d2" "$CTL_BLIND"
out2=$(run_prove "$d2"); chk "P4 見分けない対照 -> 効いていない(rc=1)" 1 $? "効いていない" "" "$out2"

# ── P5 「効いていない」に rev の選び方の但し書きを必ず付ける ──────────────
#    これが無いと、改名だけの commit を拾った緑を欠陥として数える(DESIGN (19))。
chk "P5 効いていない の文面に rev の但し書きが付く" 0 0 "rev の選び方" "" "$out2"

# ── P6 継ぎ目が無い対照は測らない(自力型を欠陥と呼ばない)─────────────────
out3=$(RC_ROOT="$d" bash "$PROVE" test/g-controls.sh NO_SUCH_SEAM tools/guard.sh 2>&1); rc3=$?
chk "P6 継ぎ目が無い -> 未測定(rc=2)・自力型の説明を出す" 2 $rc3 "自力型" "" "$out3"

# ── P7 比べた commit の中身を出す(欠陥と rev 選択を見分ける材料)───────────
chk "P7 比べた commit の subject を出す" 0 0 "危ない入力を赤にする" "" "$out"

# ── P8 ★行の形が違う対照を「効いている」と言わない ────────────────────────
#    初稿は `^NG` 決め打ちで数えていたので、行頭を字下げする対照から1行も読めず
#    「倒れた 0 枚 / 倒れなかった 0 枚」と出しながら結論だけ「効いている」と書いた。
#    rc が赤い事は「狙った欠陥を測っている」証明にならない(この file の P2/P3 と同じ話)。
d3="$SB/odd"; mk_sandbox "$d3" "$CTL_ODD"
out4=$(run_prove "$d3")
chk "P8 行の形が読めない -> 未測定(rc=2)・名指しできないと言う" 2 $? "名指しできない" "" "$out4"
chk "P8b 0枚のまま「効いている」と書かない" 2 2 "" "PROVE: 効いている" "$out4"

# ── P8c 助言の文が消えない ────────────────────────────────────────────────
#    ★P8 の枝の助言行は初稿が**二重引用の中に backtick** を書いていた為、
#      `NG <名前>` がコマンド置換として走り `syntax error` を吐いて助言が丸ごと消えていた。
#      P8 は rc と「名指しできない」しか見ていないので、**この消失を素通ししていた**。
#      「赤である事」と「読める赤である事」は別物、という此の repo の型そのもの。
chk "P8c 助言の文が消えていない(backtick がコマンド置換で走っていない)" 2 2 "の形に揃えるか" "syntax error" "$out4"

# ── P9 ★守っている file が repo の root 直下に無い時も履歴が引ける ────────
#    2026-08-03 実測の欠陥: `git ls-files --full-name` は **root 基準**の経路を返すが、
#    `git log -- <経路>` の pathspec は **cwd 基準**。この道具は `rc-backend/` の中で
#    走るので、素で渡すと `rc-backend/rc-backend/tools/…` を探して必ず空 = 「履歴が引けない」。
#    **14 本中 14 本が未測定**で、この道具は一度も何も証明していなかった。
#    P1-P8 が全部緑だったのは、砂場が守り file を repo の root 直下に置いていて
#    「root 基準 == cwd 基準」が偶然成り立っていたから = **砂場の形が本物と違った**。
#    だから此処は「入れ子の砂場」でしか意味を持たない。
mk_nested() { # mk_nested <repo> — repo の root の**一つ下**に tools/ と test/ を置く
  local r=$1
  /bin/mkdir -p "$r/sub/tools" "$r/sub/test"
  (cd "$r" && git init -q)
  # root 直下にも file を置く(root と sub を取り違えた時に気付ける様に)
  printf 'root marker\n' > "$r/README"
  printf '#!/bin/bash\nexit 0\n' > "$r/sub/tools/guard.sh"
  /bin/chmod +x "$r/sub/tools/guard.sh"
  printf '%s\n' "$CTL_GOOD" > "$r/sub/test/g-controls.sh"
  /bin/chmod +x "$r/sub/test/g-controls.sh"
  G "$r" add -A >/dev/null 2>&1; G "$r" commit -q -m v1 >/dev/null 2>&1
  printf '#!/bin/bash\n[ "${1:-}" = BAD ] && exit 1\nexit 0\n' > "$r/sub/tools/guard.sh"
  G "$r" add -A >/dev/null 2>&1; G "$r" commit -q -m "危ない入力を赤にする" >/dev/null 2>&1
}
d4="$SB/nested"; mk_nested "$d4"
out5=$(RC_ROOT="$d4/sub" bash "$PROVE" test/g-controls.sh GUARD_SCRIPT tools/guard.sh 2>&1)
chk "P9 root 直下に無い守りでも履歴が引ける(入れ子の砂場)" 0 $? "PROVE: 効いている" "履歴が引けない" "$out5"
# ★陰性: 直す前の形(`--` の後ろに root 基準の経路を素で渡す)に戻すと P9 だけが落ちる。
#   file を書き換えず、`sed` で写しを作って当てる(本物の道具は触らない)。
BROKEN="$SB/prove-broken.sh"
/usr/bin/sed 's|^PSPEC=":/\$FULL"|PSPEC="$FULL"|' "$PROVE" > "$BROKEN"; /bin/chmod +x "$BROKEN"
if /usr/bin/grep -q '^PSPEC="\$FULL"$' "$BROKEN"; then
  out6=$(RC_ROOT="$d4/sub" bash "$BROKEN" test/g-controls.sh GUARD_SCRIPT tools/guard.sh 2>&1)
  chk "P9b ★陰性: 経路を cwd 基準に戻すと「履歴が引けない」で未測定になる" 2 $? "履歴が引けない" "" "$out6"
else
  echo "NG  P9b ★陰性: 差し替えが当たっていない(PSPEC の行の形が変わった)"; fail=$((fail+1))
fi

# ── P10 ★prove-all が stdin を食う対照で一覧を落とさない ──────────────────
#    prove-all の loop は `<<< "$MAP"` = stdin から読む。中で回す対照が stdin を
#    読む物(`ssh` は黙って読み切る)を含むと**残りの行ごと食われて途中で終わる**。
#    2026-08-03 実測: 本物で 14 本中 gui-run(ssh)まで走った所で打ち切られ、
#    以降 8 本が一覧にすら出ずに消えた。「黙って落とさない」を売りにする道具の、
#    売り物そのものの欠陥。砂場に**食う対照**と**その後ろの対照**を置いて見る。
PALL="${PROVE_ALL_SCRIPT:-$ROOT/tools/prove-all-controls.sh}"
mk_eater() { # mk_eater <repo> — a-controls.sh が stdin を食い、z-controls.sh が後ろに居る
  local r=$1
  /bin/mkdir -p "$r/tools" "$r/test"
  (cd "$r" && git init -q)
  printf '#!/bin/bash\nexit 0\n' > "$r/tools/guard.sh"
  /bin/chmod +x "$r/tools/guard.sh"
  # a = stdin を読み切る(ssh の代役)。継ぎ目は prove-all が読める `$ROOT/` の形。
  /bin/cat > "$r/test/a-controls.sh" <<'EOS'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="${GUARD_SCRIPT:-$ROOT/tools/guard.sh}"
/bin/cat > /dev/null            # ← ssh と同じで stdin を黙って読み切る
if bash "$G" BAD >/dev/null 2>&1; then echo "NG  A1 危ない入力を赤にする"; exit 1; fi
echo "OK  A1 危ない入力を赤にする"
EOS
  /bin/cat > "$r/test/z-controls.sh" <<'EOS'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="${GUARD_SCRIPT:-$ROOT/tools/guard.sh}"
if bash "$G" BAD >/dev/null 2>&1; then echo "NG  Z1 危ない入力を赤にする"; exit 1; fi
echo "OK  Z1 危ない入力を赤にする"
EOS
  /bin/chmod +x "$r/test/a-controls.sh" "$r/test/z-controls.sh"
  G "$r" add -A >/dev/null 2>&1; G "$r" commit -q -m v1 >/dev/null 2>&1
  printf '#!/bin/bash\n[ "${1:-}" = BAD ] && exit 1\nexit 0\n' > "$r/tools/guard.sh"
  G "$r" add -A >/dev/null 2>&1; G "$r" commit -q -m "危ない入力を赤にする" >/dev/null 2>&1
}
d5="$SB/eater"; mk_eater "$d5"
# prove-all は自分の置き場所から ROOT を決めるので、砂場側に写しを置いて回す。
/bin/cp "$PALL" "$d5/tools/prove-all-controls.sh"
/bin/cp "$PROVE" "$d5/tools/prove-control.sh"
/bin/chmod +x "$d5/tools/prove-all-controls.sh" "$d5/tools/prove-control.sh"
out7=$(bash "$d5/tools/prove-all-controls.sh" 2>&1); rc7=$?
chk "P10 stdin を食う対照の**後ろ**も一覧に出る(2本とも効いている=rc 0)" 0 $rc7 "z-controls.sh" "" "$out7"
chk "P10b 食う側も出る(前だけ出て終わっていない)" 0 0 "a-controls.sh" "" "$out7"
# ★陰性: `</dev/null` を外すと z が**消える**。消える事を見ないと、この対照は
#   「2本とも出た」を偶然で当て続ける(食っていない砂場でも緑になる)。
EATER_BROKEN="$d5/tools/prove-all-broken.sh"
/usr/bin/sed 's| </dev/null$||' "$d5/tools/prove-all-controls.sh" > "$EATER_BROKEN"
/bin/chmod +x "$EATER_BROKEN"
if /usr/bin/grep -q 'prove-control.sh "\$ctl" "\$seam" "\$rel"$' "$EATER_BROKEN"; then
  out8=$(bash "$EATER_BROKEN" 2>&1)
  chk "P10c ★陰性: </dev/null を外すと後ろの z が一覧から消える" 0 0 "a-controls.sh" "z-controls.sh" "$out8"
else
  echo "NG  P10c ★陰性: 差し替えが当たっていない(呼び出し行の形が変わった)"; fail=$((fail+1))
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
