#!/bin/bash
# controls-for: tools/deploy-to-friday.sh
#
# ★この対照が生まれた理由(2026-08-26、同じ日に2回踏んだ)
#   `deploy-to-friday.sh` は env を被せて `deploy-to-edith.sh` を exec するだけの殻。
#   その代入は `\` で繋いだ**1本の連鎖**で、途中にコメントを1行挟むと
#   **そこで切れて、上側の代入が全部 exec に届かなくなる**。bash は警告を出さない ——
#   上半分はただの一時代入として捨てられ、下半分だけが渡る。
#   症状は「Friday へ配備した筈が edith を叩いて 12 分後に timeout」= 12 分捨てて
#   初めて気付く形。目視では2回続けて見落とした(1回目の直しが切断を1行上へ動かしただけ)。
#
# ★測り方: `exec` の行だけを `env` に差し替えて**実際に走らせ**、届いた変数を数える。
#   台本の字面を正規表現で読む方式は採らない —— それは「連鎖が繋がっているか」ではなく
#   「そう書いてあるか」を測る事で、まさに今回すり抜けた側の検査になる。
#   ssh も rsync も撃たない(exec を env に差し替えるので、本体は一度も走らない)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$ROOT/tools/deploy-to-friday.sh"
pass=0; fail=0
ok(){ printf '  OK   %s\n' "$1"; pass=$((pass+1)); }
ng(){ printf '  ★NG  %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
PROBE="$D/probe.sh"
sed 's|^exec bash "$HERE/deploy-to-edith.sh" "$@"|exec /usr/bin/env|' "$SH" > "$PROBE"
grep -q '^exec /usr/bin/env$' "$PROBE" \
  && ok "F0 exec の行を差し替えられた(台本の形が変わっていない)" \
  || { ng "F0" "exec の行が見付からない = 台本の形が変わった"; echo "--- 合計: PASS $pass / FAIL $fail ---"; exit 1; }

OUT="$(bash "$PROBE" 2>/dev/null | grep -E '^RC_' | sort)"

# ★台本が**書いている**変数名を数え、その全部が届いた事を要求する。
#   期待値をここに書き写すと、台本に1つ足した日にこの対照が古くなる。
WANT="$(grep -oE '^RC_[A-Z_]+=' "$SH" | tr -d '=' | sort -u)"
want_n=$(printf '%s\n' "$WANT" | grep -c .)
[ "$want_n" -ge 8 ] && ok "F1 台本が $want_n 個の RC_ 変数を書いている" \
                    || ng "F1" "変数が $want_n 個しか見付からない = 読めていない"

missing=""
while read -r v; do
    [ -n "$v" ] || continue
    printf '%s\n' "$OUT" | grep -q "^${v}=" || missing="$missing $v"
done <<< "$WANT"
[ -z "$missing" ] && ok "F2 ★書いた変数が全部 exec に届く(連鎖が切れていない)" \
                  || ng "F2" "届いていない:$missing"

# --- 値そのものの検査(宛先を間違えると 12 分捨てる) --------------------------
host="$(printf '%s\n' "$OUT" | sed -n 's/^RC_EDITH_HOST=//p')"
[ "$host" = "athenas" ] && ok "F3 既定の宛先は athenas(edith ではない)" || ng "F3" "host=$host"

label="$(printf '%s\n' "$OUT" | sed -n 's/^RC_JOB_LABEL=//p')"
[ "$label" = "com.fleet.rc-backend" ] && ok "F4 job label は com.fleet.rc-backend" || ng "F4" "label=$label"

# ★`$HOME` が手元で展開されていないか。Jervis の HOME が混ざったら宛先が別機体になる。
printf '%s\n' "$OUT" | grep -qE '^RC_[A-Z_]+=/Users/tomtim' \
  && ng "F5" "手元の HOME が混ざった値が在る(Friday 上でその path は無い)" \
  || ok "F5 ★手元の HOME が混ざっていない"

# ★宛先の上書きが効く(殻が env を無視して直値で固めていない事の確認)
alt="$(RC_FRIDAY_HOST=canary-host bash "$PROBE" 2>/dev/null | sed -n 's/^RC_EDITH_HOST=//p')"
[ "$alt" = "canary-host" ] && ok "F6 RC_FRIDAY_HOST で宛先を差し替えられる" || ng "F6" "alt=$alt"

# --- ★陰性: 連鎖を切ったら F2 が本当に落ちるか(空振り防止)-------------------
BROKEN="$D/broken.sh"
awk '
  /^RC_JOB_LABEL=/ { print "# 連鎖を切る細工(この対照の空振り防止)"; }
  { print }
' "$PROBE" > "$BROKEN"
bout="$(bash "$BROKEN" 2>/dev/null | grep -cE '^RC_')"
oout="$(printf '%s\n' "$OUT" | grep -c .)"
[ "$bout" -lt "$oout" ] \
  && ok "F7 ★陰性: 連鎖の途中にコメントを挿すと届く数が減る($oout → $bout)" \
  || ng "F7" "細工しても $bout のまま = この対照は空振りしている"

echo "--- 合計: PASS $pass / FAIL $fail ---"
exit $(( fail > 0 ))
