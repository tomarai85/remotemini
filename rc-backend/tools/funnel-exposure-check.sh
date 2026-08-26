#!/bin/bash
# funnel-exposure-check.sh — **公開面が私たちの机へ繋がっていないか**を1つ問う。2026-08-26 新設。
#
# なぜ要るか(2026-08-26 に実測して分かった形)
#   配備先の Friday では、443 が別 PJ(`resonance-os`)に埋まっていて **Funnel で公開**されている。
#   私たちの机は 9443(tailnet 限定)→ 127.0.0.1:8787 に載せてあるので、外の網からは届かない。
#   ★ところが最初に書いた検査は「**9443 が Funnel されていないか**」を見ていた。
#     Funnel が扱える入口は 443 / 8443 / 10000 だけなので、`AllowFunnel[":9443"]` は
#     **原理的に真にならない** = その検査は空虚で、緑である事が何も証明していなかった
#     (Codex 2026-08-26: "a vacuous assertion manufactures the feeling that exposure is
#      being checked")。
#
#   本当に守りたいのは入口の**名前**ではなく **経路**:
#     「**公開されている入口の下に、私たちの机へ向く handler が1つも無い**」
#   こちらは空虚でない —— 443 は現に公開されていて、そこに `/rc -> 127.0.0.1:8787` を
#   1行足すだけで、机は公開面に出る。足せてしまう以上、見る価値が在る。
#
# 使い方:
#   out=$("$TS" serve status --json 2>/tmp/err)      # ★パイプに直で繋がない(rc を捨てる)
#   printf '%s' "$out" | funnel-exposure-check.sh <手元のポート>
#
#   exit 0 … 公開されている入口のどれからも、127.0.0.1:<port> へ繋がっていない
#   exit 1 … **繋がっている**。どの入口か stdout に出す
#   exit 3 … 判断できない(空 / 壊れた JSON / jq が無い)。★緑と混ぜない
#   exit 2 … 使い方が違う
#
# ★exit 3 を 0 と分ける理由: これは「安全だ」と主張する検査なので、**読めなかった時に
#   安全側の顔をしてはいけない**。呼び手が `&&` で繋いでも 3 は非ゼロなので赤に倒れる。
set -uo pipefail

PORT="${1:-}"
case "$PORT" in
    ''|*[!0-9]*) echo "usage: <tailscale serve status --json> | $0 <手元のポート>" >&2; exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "usage: port は 1..65535: $PORT" >&2; exit 2
fi

JQ=""
if [ -x /usr/bin/jq ]; then JQ=/usr/bin/jq
elif command -v jq >/dev/null 2>&1; then JQ=$(command -v jq)
else exit 3; fi

raw=$(cat)
case "$(printf '%s' "$raw" | tr -d ' \t\n\r')" in '') exit 3 ;; esac

# 公開が真の入口キーを取り、その入口の Web handler と TCP 転送の両方を見る。
# ★TCP 側も見る理由: `serve --tcp` は Web の表に載らないので、Web だけ見ると
#   「表に無いから安全」と読み違える(= 入口キーを見ていなかった v1 と同じ病気)。
# ★jq の **プログラム側の失敗**と「該当なし」は、どちらも出力が空になる。
#   区別しないと「壊れた検査が毎回 緑」になる —— 2026-08-26 に実際この形で一度書き、
#   自分の対照(公開側 8799 が exit 1 になる筈の行)が掴んだ。だから rc を必ず見る。
hits=$(printf '%s' "$raw" | "$JQ" -r --arg p "$PORT" '
  if type != "object" then error("not-object") else
    (.Web // {}) as $web
    | (.TCP // {}) as $tcp
    | [ (.AllowFunnel // {}) | if type=="object" then to_entries[] else empty end
        | select(.value == true) | .key ] as $fk
    | ( [ $fk[]
          | . as $k
          | ( ($web[$k].Handlers // {}) | if type=="object" then to_entries[] else empty end
              | select((.value.Proxy // "") | endswith(":" + $p))
              | "\($k)\(.key)" ) ]
      + [ $fk[]
          | . as $k
          | ($k | split(":") | last) as $ep
          | select((($tcp[$ep].TCPForward // "") | endswith(":" + $p)))
          | "\($k) (TCP転送)" ]
      ) | .[]
  end
' 2>/dev/null); jqrc=$?
[ "$jqrc" = 0 ] || exit 3

if [ -z "$hits" ]; then exit 0; fi
printf '%s\n' "$hits"
exit 1
