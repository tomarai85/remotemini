#!/bin/bash
# serve-decision.sh — `tailscale serve` の設定を見て「入れる / 触らない / 他人の物」を1語で返す。
#
# なぜ独立した file か:
#   起動ラッパの中に埋めると**駆動できない**。ここは「電話から届くか」を決める唯一の分岐で、
#   間違えた時の症状は「ローカルは全部緑、電話からだけ永久に到達できない」= 一番気付けない形。
#   判断を1つの file に出して、実物の JSON と負の対照で叩ける様にする。
#
# 使い方:
#   tailscale serve status --json 2>/dev/null | serve-decision.sh <port>
#   stdout に apply / ok / foreign のいずれか1語。exit 0 = 判定できた / 2 = 使い方が違う。
#
#   apply   … 設定が空。入れてよい
#   ok      … 443 の `/` が既に自分(127.0.0.1:<port>)に向いている。触らない(入れ直しても no-op)
#   foreign … それ以外。**上書きしない**(fail-closed)。人が見て決める
#
# ★2026-08-02 に実物の形を見て締めた(それまでは「設定後の JSON を見ていない」ので
#   ポート番号の部分一致に留めてあった)。edith の実測 compact:
#     {"TCP":{"443":{"HTTPS":true}},"Web":{"desk.tailnet.example:443":
#      {"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}
#   旧判定 `grep "127.0.0.1:8787"` は、**`/x` だけが自分に向いていて `/` は他人**という
#   設定でも `ok` と言う = 電話は他人の宛先に着く。新判定は `/` の宛先そのものを見る
#   (この差は `serve-decision-check.sh` のケース6が現物で示す)。
#
# ★形が変われば `foreign` に落ちる。それは「黙って壊れる」ではなく「触らずに大声で言う」で、
#   意図した倒し方。`serve` は宣言的なので、人が1回入れ直せば `ok` に戻る。

set -u

PORT="${1:-}"
case "$PORT" in
    ''|*[!0-9]*) echo "usage: <tailscale serve status --json> | $0 <port>" >&2; exit 2 ;;
esac

# 空白と改行を落として1行にする。値の中に空白を含むキーはこの JSON には無い。
cur=$(tr -d ' \n')

if [ -z "$cur" ] || [ "$cur" = "{}" ]; then
    echo apply
    exit 0
fi

# 443 の `/` が自分に向いているか。ポートだけでなく**経路ごと**見る。
if printf '%s' "$cur" | grep -qF "\"/\":{\"Proxy\":\"http://127.0.0.1:${PORT}\"}"; then
    echo ok
else
    echo foreign
fi
exit 0
