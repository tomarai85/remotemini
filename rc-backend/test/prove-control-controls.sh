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

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
