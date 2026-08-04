#!/bin/bash
# controls-for: tools/verify-log.sh
# `tools/verify-log.sh` の対照。
#
# 何を守るか: この包みは **survival の判定の途中に立つ**。判定を書き換えたら、repo 全体の
# 「生きている/死んでいる」が嘘になる。だから測るのは1点に尽きる ——
#   **終了コードが素で回した時と一字一句同じか**。
# 加えて、包む目的(証拠を残す)が本当に果たされているか = stdout も stderr も log に落ちるか。
#
# ★この型の前科がこの repo に在る: `mutation-verdict.sh assert` が**検出した失敗の全部に
#   緑を返していた**。「間に立つ道具が判定を握り潰す」は既に一度起きている。
#
# 型 = 自力型(継ぎ目を差し込まず、本物の包みを砂場で回す)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${VERIFY_LOG_SCRIPT:-$ROOT/tools/verify-log.sh}"

[ -f "$W" ] || { echo "★包みが読めない: $W = 測定不成立"; exit 2; }

pass=0; fail=0
chk() { # chk <名前> <期待> <実際>
  local name=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then echo "OK  $name"; pass=$((pass+1))
  else echo "NG  $name"; echo "      期待=$want 実際=$got"; fail=$((fail+1)); fi
}

# ★数える道具は2つ在り、混ぜると測定が壊れる。両方ともこの file を書いた初回に踏んだ。
#
# (1) `grep -c` は**一致0でも 0 を印字して終了1**を返す。so `|| echo 0` を付けると
#     0 件の時に "0\n0" が出て、期待値 0 と一致しなくなる(V13/N3 で実際に踏んだ)。
#     file が無い時だけ 0 を出したいので、file の有無で分岐する。
# ★`--` を内側に置く。検査語は `--- exit=` の様に `-` で始まる事が在り、外から `--` を
#   足すと引数の位置がずれる(pattern が `--` になる)。
cnt() { # cnt <pattern> <file> -> 一致行数を1つだけ印字
  if [ -f "$2" ]; then /usr/bin/grep -c -- "$1" "$2" 2>/dev/null; else echo 0; fi
}
# (2) log には `--- cmd: <回したコマンド>` の行が入る。**そこに検査語がそのまま載る**ので、
#     素で数えると出力を1件も捕まえていなくても当たる = 陰性対照が黙って無効化される
#     (V6/V7/V10/V11/N2b で実際に踏んだ。`deploy-to-edith-controls.sh` の `ncode()` の上に
#     「自分の注記に自分で当たる」として書いてある型と同じ)。
cnt_out() { # cnt_out <pattern> <file> -> `--- cmd:` 行を除いた一致行数
  if [ -f "$2" ]; then /usr/bin/grep -v -- '--- cmd: ' "$2" | /usr/bin/grep -c -- "$1"; else echo 0; fi
}

SB="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/rc-vlog.XXXXXX")" || { echo "★砂場が作れない = 測定不成立"; exit 2; }
trap '/usr/bin/find "$SB" -type f -print0 2>/dev/null | /usr/bin/xargs -0 /bin/rm -f 2>/dev/null; /usr/bin/find "$SB" -depth -type d -print0 2>/dev/null | /usr/bin/xargs -0 -n1 /bin/rmdir 2>/dev/null' EXIT

run() { # run <id> <コマンド> -> 終了コードを返す(log は $SB/logs へ)
  RC_VERIFY_LOG_DIR="$SB/logs" /bin/bash "$W" "$1" "$2" >/dev/null 2>&1
}

# ── V1-V3 ★終了コードを書き換えない ────────────────────────────────────────
# 素で回した時の値と同じでなければ、この包みは判定を握り潰している。
run v-ok '/bin/bash -c "exit 0"'; chk "V1 ★成功(0)をそのまま返す" 0 "$?"
run v-ng '/bin/bash -c "exit 1"'; chk "V2 ★失敗(1)を握り潰さない" 1 "$?"
# ★1 に丸めない事も見る。`exit $rc` でなく `exit 1` と書いた版はここで落ちる。
run v-7  '/bin/bash -c "exit 7"'; chk "V3 ★終了コードを 1 に丸めない(7 は 7)" 7 "$?"

# ── V4 ★`&&` の連鎖を語に割らない ──────────────────────────────────────────
# `$*` でなく `"$@"` を素で渡すと連鎖が壊れる。前半が落ちたら後半は走らない事で見る。
run v-chain '/bin/bash -c "exit 3" && /bin/bash -c "exit 0"'
chk "V4 ★連鎖が生きている(前半 3 で落ちれば 3 が返る)" 3 "$?"

# ── V5-V7 ★証拠が残る(この包みが存在する理由そのもの) ─────────────────────
run v-out '/bin/bash -c "echo HELLO_STDOUT; echo HELLO_STDERR >&2; exit 4"'
L="$SB/logs/v-out.log"
chk "V5 ★log が出来ている" "yes" "$([ -f "$L" ] && echo yes || echo no)"
chk "V6 ★stdout が log に落ちる" 1 "$(cnt_out 'HELLO_STDOUT' "$L")"
chk "V7 ★stderr も log に落ちる(赤の理由は大抵こちら)" 1 "$(cnt_out 'HELLO_STDERR' "$L")"
chk "V8 ★log に終了コードの行が在り値が合う" 1 "$(cnt '--- exit=4' "$L")"
chk "V9 ★log に回したコマンドが残る" 1 "$(cnt '--- cmd: ' "$L")"

# ── V10 ★追記で、前の走行を消さない ───────────────────────────────────────
# survival は失敗すると 3 秒置いてもう一度回す。上書きだと**1回目の証拠が消える**。
run v-out '/bin/bash -c "echo SECOND_RUN; exit 0"'
chk "V10 ★2回目は追記(1回目の証拠が残る)" 1 "$(cnt_out 'HELLO_STDOUT' "$L")"
chk "V11 ★2回目の出力も入っている" 1 "$(cnt_out 'SECOND_RUN' "$L")"

# ── V12 ★id ごとに分かれる ────────────────────────────────────────────────
chk "V12 ★別の id は別の log" "yes" \
    "$([ -f "$SB/logs/v-ok.log" ] && [ -f "$SB/logs/v-7.log" ] && echo yes || echo no)"

# ── V13 ★repo を汚さない ──────────────────────────────────────────────────
# 既定の置き場は /tmp。repo 直下に log を作る版はここで落ちる。
chk "V13 ★repo 直下に log を作らない" 0 \
    "$(/usr/bin/find "$ROOT" -maxdepth 1 -name '*.log' 2>/dev/null | /usr/bin/grep -c .)"

# ── V14 ★使い方を誤った時は緑にしない ─────────────────────────────────────
RC_VERIFY_LOG_DIR="$SB/logs" /bin/bash "$W" >/dev/null 2>&1
chk "V14 ★引数無しは 3(未測定側)で、0 ではない" 3 "$?"

# ── N1-N3 ★陰性対照 ───────────────────────────────────────────────────────
# 上が緑なのは見分けているからか、どの版でも通る書き方だからか。壊した複製で見せる。
if [ "${RC_VERIFY_LOG_NEG:-1}" = "1" ]; then
  MUT="$SB/mut.sh"

  # (a) 終了コードを握り潰す版(= mutation-verdict.sh が実際に踏んだ病気)
  /usr/bin/sed 's/^exit "\$rc"$/exit 0/' "$W" > "$MUT"
  # ★空振り防止: 狙った性質になったかを見る。「違う」では弱い。
  chk "N0 ★空振り防止: 壊した版に \`exit \"\$rc\"\` が残っていない" 0 \
      "$(/usr/bin/grep -c 'exit "\$rc"' "$MUT")"
  RC_VERIFY_LOG_DIR="$SB/n1" /bin/bash "$MUT" n1 '/bin/bash -c "exit 1"' >/dev/null 2>&1
  chk "N1 ★陰性: 終了コードを握り潰す版は失敗を 0 で返す" 0 "$?"

  # (b) stderr を捨てる版 -> V7 が測っている性質が消える
  /usr/bin/sed 's|/bin/bash -c "\$\*" >> "\$LOG" 2>&1|/bin/bash -c "$*" >> "$LOG" 2>/dev/null|' "$W" > "$MUT"
  # ★空振り防止は**狙った行**を見る。`2>/dev/null$` で数えると mkdir 等の別行にも当たり
  #   (実測3件)、sed が空振りしても緑になる。
  chk "N2a ★空振り防止: 本走行の行から 2>&1 が消えている" 0 \
      "$(cnt '/bin/bash -c "\$\*" >> "\$LOG" 2>&1' "$MUT")"
  RC_VERIFY_LOG_DIR="$SB/n2" /bin/bash "$MUT" n2 '/bin/bash -c "echo GONE >&2; exit 0"' >/dev/null 2>&1
  chk "N2b ★陰性: stderr を捨てる版では赤の理由が log に残らない" 0 \
      "$(cnt_out 'GONE' "$SB/n2/n2.log")"

  # (c) 上書きする版 -> V10 が測っている性質が消える
  /usr/bin/sed 's|>> "\$LOG" 2>&1|> "$LOG" 2>\&1|' "$W" > "$MUT"
  RC_VERIFY_LOG_DIR="$SB/n3" /bin/bash "$MUT" n3 '/bin/bash -c "echo FIRST; exit 0"' >/dev/null 2>&1
  RC_VERIFY_LOG_DIR="$SB/n3" /bin/bash "$MUT" n3 '/bin/bash -c "echo SECOND; exit 0"' >/dev/null 2>&1
  chk "N3 ★陰性: 上書きする版では1回目の証拠が消える" 0 \
      "$(cnt_out 'FIRST' "$SB/n3/n3.log")"
fi

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
