#!/bin/bash
# serve-decision-check.sh — `serve-decision.sh` を実物 + 負の対照で駆動する。
#
# ★負の対照が本体: ケース2/5/6 が無いと「常に ok を返す実装」でも全部緑になる。
#   最後に**旧判定(ポートの部分一致)を同じ表に当てて、ケース6 で外れる事**まで見せる
#   = 締め直しが飾りでない事の証明。これが無いと「厳しくした」は自己申告に留まる。

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEC="${HERE}/serve-decision.sh"
[ -x "$DEC" ] || { echo "★${DEC} が無い/実行できない"; exit 2; }

# edith の現物(2026-08-02 実測)。pretty のまま置く = 正規化も一緒に駆動される。
REAL='{
  "TCP": {
    "443": {
      "HTTPS": true
    }
  },
  "Web": {
    "desk.tailnet.example:443": {
      "Handlers": {
        "/": {
          "Proxy": "http://127.0.0.1:8787"
        }
      }
    }
  }
}'
REAL_COMPACT=$(printf '%s' "$REAL" | tr -d ' \n')
# `/` は他人、`/x` だけが自分 = 旧判定が取り違える形。
TRAP='{"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"},"/x":{"Proxy":"http://127.0.0.1:8787"}}}}}'

fail=0
run() { # <番号> <説明> <期待> <port> <json>
    got=$(printf '%s' "$5" | "$DEC" "$4" 2>/dev/null)
    if [ "$got" = "$3" ]; then
        printf '  %-2s %-46s → %-7s OK\n' "$1" "$2" "$got"
    else
        printf '  %-2s %-46s → %-7s ★期待 %s\n' "$1" "$2" "$got" "$3"; fail=1
    fi
}

echo "serve-decision.sh — 7ケース(うち負の対照4)"
run 1 "edith の現物(pretty のまま)"          ok      8787 "$REAL"
run 2 "同じ現物・ポートだけ違う[負]"           foreign 9999 "$REAL"
run 3 "設定ゼロ {}"                            apply   8787 "{}"
run 4 "空の入力(取得できなかった時)"          apply   8787 ""
run 5 "/ が他人の宛先[負]"                     foreign 8787 '{"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}'
run 6 "自分のポートが / 以外に在る[負]"        foreign 8787 "$TRAP"
run 7 "TCP 転送だけで Web が無い[負]"          foreign 8787 '{"TCP":{"443":{"TCPForward":"127.0.0.1:8787"}}}'

# --- 旧判定を同じ表に当てる(締め直しが何を買ったかを見せる) -------------------
OLD=$(mktemp); trap 'rm -f "$OLD"' EXIT
cat >"$OLD" <<'EOS'
#!/bin/bash
set -u
cur=$(tr -d ' \n')
if [ -z "$cur" ] || [ "$cur" = "{}" ]; then echo apply; exit 0; fi
if printf '%s' "$cur" | grep -q "127.0.0.1:${1}"; then echo ok; else echo foreign; fi
EOS
chmod +x "$OLD"
old6=$(printf '%s' "$TRAP" | "$OLD" 8787)
echo
if [ "$old6" = ok ]; then
    echo "  旧判定(ポートの部分一致)はケース6 を「${old6}」と言う = 電話は他人の宛先に着く。"
    echo "  → 締め直しが買った物はこの1件。★ここが 'foreign' に変わったら対照が死んでいる合図"
else
    echo "  ★対照が壊れている: 旧判定がケース6 を「${old6}」と言った(ok の筈)。"
    echo "    旧判定を直したのではなく、対照の作り方が変わっている。先にそちらを見る"; fail=1
fi

echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
