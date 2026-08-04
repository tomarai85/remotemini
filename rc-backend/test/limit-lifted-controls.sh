#!/bin/bash
# controls-for: tools/limit-lifted-check.mjs
# `tools/limit-lifted-check.mjs` が**計器として壊れていないか**を測る対照。
#
# ── なぜ要るか ──────────────────────────────────────────────────────────
# この道具は「一発勝負の台本を撃ってよいか」を決める門番になる。誤って「明けた」と
# 言えば、上限中の台本を無駄撃ちする。誤って「明けていない」と言えば、解禁の夜を
# 逃す。**両方向に落ちる可能性がある**ので、両方向の対照を置く。
#
# ★この対照が実在する理由は机上ではない: 初版は **21:40 JST の haiku の成功2件**を
#   拾って「明けている」と誤答した(2026-08-02 23:1x、edith 実機)。
#   fake の HOME を使うので edith も上限も要らない。実測1秒。
#
# 終了コード: 0 = 全部期待どおり / 1 = どれかが違う
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${RC_LIMIT_CHECK_BIN:-$ROOT/tools/limit-lifted-check.mjs}"
NODE="${RC_NODE_BIN:-node}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

FAKEHOME="$(mktemp -d /tmp/rc-limithome.XXXXXX)" || exit 1
trap 'find "$FAKEHOME" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
      find "$FAKEHOME" -type d 2>/dev/null | awk "{print length, \$0}" | sort -rn | cut -d" " -f2- |
        while read -r d; do rmdir "$d" 2>/dev/null; done' EXIT

PROJ="$FAKEHOME/.claude/projects/-fake-proj"
mkdir -p "$PROJ"

# 転写を1本書く。$1=file名 $2=model $3=err(1で isApiErrorMessage)
write_jsonl() {
    local f="$PROJ/$1.jsonl" model="$2" err="$3"
    {
      printf '{"type":"user","message":{"role":"user","content":"x"}}\n'
      printf '{"type":"assistant","isApiErrorMessage":%s,"message":{"role":"assistant","model":"%s","content":[{"type":"text","text":"y"}]}}\n' \
        "$([ "$err" = "1" ] && echo true || echo false)" "$model"
    } > "$f"
}

run_check() {  # 戻り = exit code、出力は $LAST_OUT
    LAST_OUT="$(HOME="$FAKEHOME" "$NODE" "$CHECK" "${1:-2}" 2>&1)"
    return $?
}

clear_proj() { find "$PROJ" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; }

# ── L1) ★haiku の成功だけ → まだ明けていない(3)──────────────────────────
# これが初版の誤答そのもの。ここが 0 を返すなら、道具は別枠の model を根拠にしている。
echo "=== L1) haiku の成功だけ → 3 ==="
clear_proj; write_jsonl a claude-haiku-4-5-20251001 0
run_check; rc=$?
[ "$rc" = "3" ] && ok "L1 haiku を『明けた』の根拠にしない(exit 3)" \
                || ng "L1 haiku の扱い" "exit 3 を期待して $rc / $LAST_OUT"

# ── L2) 本番 model の成功 → 明けている(0)────────────────────────────────
# 陽性側。ここが 3 のままなら、道具は**永久に「撃つな」と言い続ける**。
echo "=== L2) 本番 model の成功 → 0 ==="
clear_proj; write_jsonl b claude-opus-4-5-20260101 0
run_check; rc=$?
[ "$rc" = "0" ] && ok "L2 本番 model の成功を拾う(exit 0)" \
                || ng "L2 陽性側" "exit 0 を期待して $rc / $LAST_OUT"

# ── L3) 上限の告知だけ → 3 ───────────────────────────────────────────────
echo "=== L3) <synthetic> のエラーだけ → 3 ==="
clear_proj; write_jsonl c "<synthetic>" 1
run_check; rc=$?
[ "$rc" = "3" ] && ok "L3 上限の告知を『答えた』と読まない(exit 3)" \
                || ng "L3 告知の扱い" "exit 3 を期待して $rc / $LAST_OUT"

# ── L4) 本番 model でも isApiErrorMessage なら 3 ─────────────────────────
echo "=== L4) 本番 model だがエラー → 3 ==="
clear_proj; write_jsonl d claude-opus-4-5-20260101 1
run_check; rc=$?
[ "$rc" = "3" ] && ok "L4 エラー応答を成功に数えない(exit 3)" \
                || ng "L4 エラーの扱い" "exit 3 を期待して $rc / $LAST_OUT"

# ── L5) 窓の外(古い)成功は数えない → 3 ────────────────────────────────
# 「先週明けていた」を「今夜明けている」と読むのが一番危ない誤り。
echo "=== L5) 窓の外の成功は数えない → 3 ==="
clear_proj; write_jsonl e claude-opus-4-5-20260101 0
touch -t 202001010000 "$PROJ/e.jsonl"
run_check; rc=$?
[ "$rc" = "3" ] && ok "L5 古い成功を今夜の根拠にしない(exit 3)" \
                || ng "L5 時間窓" "exit 3 を期待して $rc / $LAST_OUT"

# ── L6) 混在(haiku 成功 + 本番 model エラー)→ 3 ───────────────────────
# 今夜の edith が実際にこの形。一番踏みやすい。
echo "=== L6) haiku 成功 + 本番 model エラー(= 今夜の実機の形)→ 3 ==="
clear_proj; write_jsonl f claude-haiku-4-5-20251001 0; write_jsonl g "<synthetic>" 1
run_check; rc=$?
[ "$rc" = "3" ] && ok "L6 実機と同じ混在で『撃つな』を出す(exit 3)" \
                || ng "L6 混在" "exit 3 を期待して $rc / $LAST_OUT"
printf '%s' "$LAST_OUT" | grep -q "haiku" \
  && ok "L6b 出力に model 別の内訳が出る(なぜ撃たないかが読める)" \
  || ng "L6b 内訳" "model 別の行が出ていない / $LAST_OUT"

# ── L7) 壊れた行で全体を落とさない ───────────────────────────────────────
echo "=== L7) 壊れた行が混ざっても落ちない ==="
clear_proj; write_jsonl h claude-opus-4-5-20260101 0
printf '{"type":"assistant" 途中で切れ\n' >> "$PROJ/h.jsonl"
run_check; rc=$?
[ "$rc" = "0" ] && ok "L7 壊れた末尾行を飛ばして判定できる(exit 0)" \
                || ng "L7 壊れ行" "exit 0 を期待して $rc / $LAST_OUT"

# ── L8) 置き場が無い → 2(未測定。「明けていない」に丸めない)──────────
echo "=== L8) 転写の置き場が無い → 2 ==="
EMPTY="$(mktemp -d /tmp/rc-limitempty.XXXXXX)"
out="$(HOME="$EMPTY" "$NODE" "$CHECK" 2>&1)"; rc=$?
rmdir "$EMPTY" 2>/dev/null
[ "$rc" = "2" ] && ok "L8 読めない時は未測定(exit 2)= 3 に丸めない" \
                || ng "L8 未測定" "exit 2 を期待して $rc / $out"

# ── L9) ★答えが「どこを測ったか」を必ず名乗る ──────────────────────────
# 主語の無い green が一番危ない: MBP で回すと MBP の転写を読んで「明けている」と
# 出るが、それは **edith の上限について何も言っていない**。
echo "=== L9) 出力が測定対象の HOME を名乗る ==="
clear_proj; write_jsonl i claude-opus-4-5-20260101 0
run_check; rc=$?
printf '%s' "$LAST_OUT" | grep -q "$FAKEHOME" \
  && ok "L9 どの置き場を測ったかが出力に出る(主語の無い green を作らない)" \
  || ng "L9 主語" "測定対象の path が出力に無い / $LAST_OUT"

echo ""
echo "LIMIT-LIFTED-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
