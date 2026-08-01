#!/bin/bash
# serve-decision.sh — `tailscale serve` の設定を見て1語を返す。
#
# 検査: `tools/serve-decision-check.sh`(19ケース。旧判定を同じ表に当てて 14 行動く)
#       `tools/rc-backend-launch-check.sh`(呼び出し側の分岐を偽の tailscale で実走)
#
# v1 との違い(2026-08-02、自分の diff の読み返し + Codex 追認):
#   1. **文字列一致をやめて JSON として見る**。v1 は
#        grep -F '"/":{"Proxy":"http://127.0.0.1:<port>"}'
#      で、**入口(host:port キー)を一切見ていなかった** = 自分の `/` が `:8443` に在るだけで
#      `ok`(= 触らない)と答えた。443 は空いているのに。実測で確認済。
#   2. **`TCP["443"].HTTPS` を条件に足す**。v1 は Web 側だけ見ていたので、TLS が終端されない
#      設定でも `ok` と答えた。症状は「ローカルは全部緑、電話からだけ永久に到達できない」。
#   3. **`unknown` を新設**。v1 は空入力(= status が取れなかった)を `{}` と同じ扱いにして
#      `apply` を返していた = **状態が読めない時に 443 へ書きに行く**。呼び出し側が掲げている
#      約束「他人の 443 設定を黙って上書きしない」と逆向き。
#
# 使い方:
#   out=$("$TS" serve status --json 2>/tmp/err); rc=$?      # ★パイプに直で繋がない
#   printf '%s' "$out" | serve-decision.sh <port>            #   (パイプは status の rc を捨てる)
#   stdout に apply / ok / foreign / unknown のいずれか1語。exit 0 = 1語出した / 2 = 使い方が違う。
#
#   apply   … 443 が**完全に未使用**。入れてよい
#   ok      … `TCP["443"].HTTPS == true` かつ `:443` の Web entry 全部の `/` が自分に向いている
#   foreign … 443 に何か在るが上と一致しない。**上書きしない**(fail-closed)
#   unknown … 状態が読めない(空 / 壊れた JSON / object でない / jq が無い)。**触らない**
#             ★`foreign` と分ける理由: 「他人が居る」と「読めない」は人が取る次の手が違う。
#
# ★jq への依存について: macOS 同梱(`/usr/bin/jq` = `jq-1.7.1-apple`、root:wheel)。
#   edith / Jervis 両方で実測(2026-08-02)。**絶対パスが両機で同じ = launchd の細い PATH でも届く**。
#   node は機械ごとに場所も版も違う(edith `/opt/homebrew/bin/node` v25 / Jervis `~/.local/node` v22)ので
#   この用途では jq の方が移植性が高い。無ければ `unknown` に倒す(推測で書きに行かない)。
#
# ★TOCTOU は残る: ここが `apply` と答えてから呼び出し側が `serve` を撃つまでの間に、
#   他人が 443 を取る事は原理的に防げない(`tailscale serve` に比較交換は無い)。
#   排他を自作するより、**起きたら上書きになる**と正直に書く方を採った。頻度は実質ゼロ
#   (この機械で 443 を触るのはこのラッパだけ)。
set -u

PORT="${1:-}"
case "$PORT" in
    ''|*[!0-9]*) echo "usage: <tailscale serve status --json> | $0 <port>" >&2; exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "usage: port は 1..65535: $PORT" >&2; exit 2
fi

JQ=""
if [ -x /usr/bin/jq ]; then JQ=/usr/bin/jq
elif command -v jq >/dev/null 2>&1; then JQ=$(command -v jq)
else echo unknown; exit 0
fi

raw=$(cat)
# 空白だけ / 完全に空 = status が取れなかった。`{}`(= 設定ゼロ)とは別物。
case "$(printf '%s' "$raw" | tr -d ' \t\n\r')" in
    '') echo unknown; exit 0 ;;
esac

out=$(printf '%s' "$raw" | "$JQ" -r --arg port "$PORT" '
  if type != "object" then "unknown"
  else
    (.TCP // {}) as $tcp
    | (.Web // {}) as $web
    | (if ($web|type) == "object" then ($web | to_entries | map(select(.key | endswith(":443")))) else [] end) as $w443
    | (if ($tcp|type) == "object" then ($tcp["443"] // null) else null end) as $t443
    | (($t443 != null) or (($w443 | length) > 0)) as $has443
    | if ($has443 | not) then "apply"
      elif ($t443 | type) == "object"
           and ($t443.HTTPS == true)
           and (($w443 | length) > 0)
           and ($w443 | all(.value.Handlers["/"].Proxy? == ("http://127.0.0.1:" + $port)))
        then "ok"
      else "foreign"
      end
  end
' 2>/dev/null)

# jq が解析に失敗した(= 壊れた JSON)時は空。**推測しない**。
case "$out" in
    apply|ok|foreign|unknown) echo "$out" ;;
    *) echo unknown ;;
esac
exit 0
