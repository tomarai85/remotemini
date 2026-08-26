#!/bin/bash
# controls-for: tools/funnel-exposure-check.sh
# funnel-exposure-check-control.sh — 2026-08-26 新設。
#
# ★この対照が守る一線は「**空虚な緑を作らない**」。
#   元の検査は「9443 が Funnel されていないか」を見ていた。Funnel が扱える入口は
#   443 / 8443 / 10000 だけなので、その条件は**原理的に真にならない** = 常に緑で、
#   緑である事が何も証明していなかった。だから此処では、
#   **緑にならない入力(ケース2・3・7)を必ず持つ**事自体を検査する。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="${HERE}/funnel-exposure-check.sh"
[ -f "$CHK" ] || { echo "★${CHK} が無い"; exit 2; }

fail=0; reds=0
run() { # <番号> <説明> <期待exit> <port> <json>
    local out rc
    out=$(printf '%s' "$5" | /bin/bash "$CHK" "$4" 2>/dev/null); rc=$?
    [ "$3" = 1 ] && reds=$((reds + 1))
    if [ "$rc" = "$3" ]; then printf '  %-3s %-54s → exit=%s OK\n' "$1" "$2" "$rc"
    else printf '  %-3s %-54s → exit=%s ★期待 %s (out=%s)\n' "$1" "$2" "$rc" "$3" "${out:-空}"; fail=1; fi
}

# Friday の現物(2026-08-26 実測)。443 が公開・9443 が tailnet 限定。
REAL='{"TCP":{"443":{"HTTPS":true},"9443":{"HTTPS":true}},"Web":{"desk.tailnet.example:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8799"},"/ja":{"Proxy":"http://127.0.0.1:8801"}}},"desk.tailnet.example:9443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}},"AllowFunnel":{"desk.tailnet.example:443":true}}'
# 公開されている 443 に、机への小径を1本足しただけの形。**これが本当に怖い形**。
LEAK='{"TCP":{"443":{"HTTPS":true}},"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8799"},"/rc":{"Proxy":"http://127.0.0.1:8787"}}}},"AllowFunnel":{"h:443":true}}'
# Web の表に出ない経路。Web だけ見ると「表に無いから安全」と読み違える。
TCPLEAK='{"TCP":{"443":{"TCPForward":"127.0.0.1:8787"}},"AllowFunnel":{"h:443":true}}'
# 同じ入口に机が向いているが、**公開されていない**。→ 緑(tailnet 限定は守る対象でない)
PRIVATE='{"TCP":{"9443":{"HTTPS":true}},"Web":{"h:9443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}'
# 公開が false と明記されている形。
FALSE='{"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}},"AllowFunnel":{"h:443":false}}'
# ポートの前方一致で誤爆しないか(8787 と 78787 / 87870)。
NEAR='{"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:87870"}}}},"AllowFunnel":{"h:443":true}}'

echo "=== 実機の形 ==="
run 1 "Friday 現物・机(8787)は公開面の下に居ない"      0 8787 "$REAL"
run 2 "同じ現物・公開側(8799)は公開面の下に居る[赤]"   1 8799 "$REAL"

echo "=== 本当に怖い形(公開されている入口に小径を1本足す)==="
run 3 "公開 443 の /rc が机へ向いている[赤]"            1 8787 "$LEAK"
run 4 "公開 443 の TCP 転送が机へ向いている[赤]"        1 8787 "$TCPLEAK"

echo "=== 緑にすべき形(過剰発火の負)==="
run 5 "机が入口に居るが Funnel されていない"            0 8787 "$PRIVATE"
run 6 "AllowFunnel が false と明記"                     0 8787 "$FALSE"
run 7 "ポートの前方一致で誤爆しない(87870)"            0 8787 "$NEAR"
run 8 "設定ゼロ"                                        0 8787 "{}"

echo "=== 読めない時は緑に倒れない(exit 3)==="
run 9  "空の入力"                                       3 8787 ""
run 10 "壊れた JSON"                                    3 8787 '{oops'
run 11 "object でない(配列)"                          3 8787 '[]'
run 12 "null"                                           3 8787 'null'

echo "=== 使い方(exit 2)==="
run 13 "port が数字でない"                              2 abc  "$REAL"
run 14 "port=0"                                         2 0    "$REAL"

echo
# ★空虚さの検査。赤くなる入力が1つも無いなら、この対照は「常に緑」を証明しているだけ。
echo "  赤に倒れた入力: ${reds} 件"
if [ "$reds" -lt 2 ]; then
    echo "  ★対照が空虚: この検査を赤に出来る入力がほぼ無い = 緑が何も証明していない。"; fail=1
fi
echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
