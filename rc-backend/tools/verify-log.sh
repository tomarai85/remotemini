#!/bin/bash
# 検査を回して、**出力と終了コードを残す**薄い包み。
#
# なぜ要るか(2026-08-03): `loop-replan-gate.sh survival` は検査の出力を捨てる
# (`subprocess.run(..., capture_output=True)` の結果を読まずに `returncode` だけ見る)。
# その所為で `choice-reply` が赤を出した時、**赤の理由を後から一言も言えなかった**。
# 仮説を3つ潰す羽目になった —— ポート衝突(否定: e2e は `RC_PORT=0` の一時ポート)、
# `npm test` の同時実行(否定: 2本同時でも両方 536/536 緑)、機械の負荷(否定: 負荷下でも
# e2e 203/203 緑)。どれも当たらず、赤は再現しないまま残った。
#
# ★根は「機序が分からない」ではなく「**計器が証拠を捨てる**」。証拠を残せば、次の赤は
#   仮説を立てずに読める。此処が直す場所。
#
# 使い方: bash tools/verify-log.sh <id> '<検査のコマンド>'
#   終了コードは包まない場合と**同じ**(これが崩れたら包みが判定を書き換えている)。
#   置き場は `RC_VERIFY_LOG_DIR`(既定 /tmp/rc-verify-logs)。repo は汚さない。
#
# ★包み自体が走れない時(この file が無い等)は shell が 127 を返す = 非ゼロ。
#   ゲートは非ゼロを dead に丸めるので「計器が無い」は緑にはならない = fail-closed 側。
set -uo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: verify-log.sh <id> <command…>" >&2
  exit 3
fi
ID="$1"; shift

DIR="${RC_VERIFY_LOG_DIR:-/tmp/rc-verify-logs}"
/bin/mkdir -p "$DIR" 2>/dev/null || { echo "★記録先が作れない: $DIR" >&2; exit 3; }
LOG="$DIR/$ID.log"

{
  echo "=== $(/bin/date '+%Y-%m-%d %H:%M:%S') id=$ID pid=$$"
  echo "--- cmd: $*"
} >> "$LOG" 2>/dev/null

# ★`$*` で1つの文字列に戻して shell に渡す。検査は元々1本の文字列なので、
#   ここで語に割ると `&&` が壊れる。
/bin/bash -c "$*" >> "$LOG" 2>&1
rc=$?

echo "--- exit=$rc" >> "$LOG" 2>/dev/null
exit "$rc"
