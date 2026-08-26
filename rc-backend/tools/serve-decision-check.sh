#!/bin/bash
# controls-for: tools/serve-decision.sh
# serve-decision-check.sh — `serve-decision.sh` を実物 + 負の対照で駆動する。
#
# ★この宣言が無かった間(〜2026-08-07)、`serve-decision.sh` だけを直す commit は
#   対照を1本も回さずに通っていた。名前の末尾が -check.sh で置き場が `tools/` なので、
#   commit の門から見ると此処は**ただの道具**だった。実測 0 秒。
#
# ★負の対照が本体: 「常に ok を返す実装」でも通ってしまう表には意味が無い。
#
# ★旧判定との対比の取り方を変えた(2026-08-02)。前の版は**1ケースだけ**旧判定に当てて
#   「締め直しが買った物はこの1件」と書いていた。1件の差分は「厳しくした」の証明にならない
#   (同じ日に serve-decision と USAGE_LIMIT で二度この形を踏んだ)。
#   今は**全ケースを旧判定にも通し**、動いた行を数え、動いた行それぞれについて
#   「**旧が期待値と違う = 旧が間違っていた**」事まで機械で確かめる。
#   これなら退行(= 旧が正しかった行で新が動く)は自動的に赤になり、表を足しても壊れない。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEC="${HERE}/serve-decision.sh"
[ -f "$DEC" ] || { echo "★${DEC} が無い"; exit 2; }

# --- 旧判定(v1 の骨格)を対照として再現する ---------------------------------
# ★これは「昔こう書いてあった」の再現であって、直した先ではない。
#   ここを新判定に寄せると対照が死ぬ(全部の差が消えて、表は緑のまま無意味になる)。
OLD=$(mktemp /tmp/serve-decision-old.XXXXXX)
trap 'rm -f "$OLD"' EXIT
cat >"$OLD" <<'EOS'
#!/bin/bash
set -u
cur=$(tr -d ' \n')
if [ -z "$cur" ] || [ "$cur" = "{}" ]; then echo apply; exit 0; fi
if printf '%s' "$cur" | grep -q "127.0.0.1:${1}"; then echo ok; else echo foreign; fi
EOS

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
# `/` は他人、`/x` だけが自分 = 旧判定が取り違える形。
TRAP='{"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"},"/x":{"Proxy":"http://127.0.0.1:8787"}}}}}'
OTHERPORT='{"TCP":{"8443":{"HTTPS":true}},"Web":{"h:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}'
NOTCP='{"Web":{"desk.tailnet.example:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}'
TCPFALSE='{"TCP":{"443":{"HTTPS":false}},"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}}}'
TWOHOST='{"TCP":{"443":{"HTTPS":true}},"Web":{"a:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}},"b:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}'

fail=0
moved=0     # 旧と新で答えが違った行の数

# 旧を同じ入力に当て、動いたなら**旧が間違っていた事**まで確かめる。
compare_old() { # <期待> <port> <json>
    local old; old=$(printf '%s' "$3" | /bin/bash "$OLD" "$2" 2>/dev/null)
    [ "$old" = "$1" ] && return 0
    moved=$((moved + 1))
    printf '       旧判定: %-8s ← 期待は %s(旧が間違っていた)\n' "${old:-(空)}" "$1"
}

run() { # <番号> <説明> <期待> <port> <json>
    local got; got=$(printf '%s' "$5" | /bin/bash "$DEC" "$4" 2>/dev/null)
    if [ "$got" = "$3" ]; then
        printf '  %-3s %-52s → %-8s OK\n' "$1" "$2" "$got"
    else
        printf '  %-3s %-52s → %-8s ★期待 %s\n' "$1" "$2" "$got" "$3"; fail=1
    fi
    compare_old "$3" "$4" "$5"
}

# ★入口ポートを指定して撃つ版(2026-08-25)。第2引数 = serve 側の入口。
#   `compare_old` は当てない —— 旧判定に第2引数は無く、比べる相手が存在しない。
run2() { # <番号> <説明> <期待> <port> <serve_port> <json>
    local got; got=$(printf '%s' "$6" | /bin/bash "$DEC" "$4" "$5" 2>/dev/null)
    if [ "$got" = "$3" ]; then
        printf '  %-3s %-52s → %-8s OK\n' "$1" "$2" "$got"
    else
        printf '  %-3s %-52s → %-8s ★期待 %s\n' "$1" "$2" "$got" "$3"; fail=1
    fi
}

echo "=== v1 から引き継いだ7ケース(ケース4 は期待値を意図的に変えた)==="
run 1 "edith の現物(pretty のまま)"                ok      8787 "$REAL"
run 2 "同じ現物・ポートだけ違う[負]"                 foreign 9999 "$REAL"
run 3 "設定ゼロ {}"                                  apply   8787 "{}"
run 4 "空の入力(取得できなかった)★v1 は apply"     unknown 8787 ""
run 5 "/ が他人の宛先[負]"                           foreign 8787 '{"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}'
run 6 "自分のポートが / 以外に在る[負]"              foreign 8787 "$TRAP"
run 7 "TCP 転送だけで Web が無い[負]"                foreign 8787 '{"TCP":{"443":{"TCPForward":"127.0.0.1:8787"}}}'

echo "=== 入口(host:port)を見ていなかった穴の負の対照 ==="
run A "自分の / が 443 以外の入口に在る(443 は空)"  apply   8787 "$OTHERPORT"
run B "Web 443 は自分・TCP 443 が無い[負]"           foreign 8787 "$NOTCP"
run C "TCP 443 が HTTPS:false[負]"                   foreign 8787 "$TCPFALSE"

echo "=== 壊れた入力(推測せず unknown / foreign に倒れる事)==="
run D "JSON として壊れている"                        unknown 8787 '{oops'
run E "null"                                          unknown 8787 'null'
run F "配列"                                          unknown 8787 '[]'
run G "文字列"                                        unknown 8787 '"x"'
run H "想定外スキーマ(Web が文字列)"                foreign 8787 '{"TCP":{"443":{"HTTPS":true}},"Web":"x"}'

echo "=== 入口が複数ある時 ==="
run I "443 の host が2つ・片方が他人[負]"            foreign 8787 "$TWOHOST"

echo "=== port の検証(使い方エラー = exit 2 で、1語を出さない)==="
# ★`2>&1 >/dev/null` は**順序で意味が変わる**。先に stderr を今の stdout(= 捕まえる先)へ
#   複製してから stdout を捨てるので、usage 文が変数に入る。最初これで自分の対照を落とした。
usage_case() { # <番号> <説明> <port>
    local out rc old
    out=$(printf '%s' "$REAL" | /bin/bash "$DEC" "$3" 2>/dev/null); rc=$?
    if [ "$rc" = 2 ] && [ -z "$out" ]; then
        printf '  %-3s %-52s → exit=2・stdout 空  OK\n' "$1" "$2"
    else
        printf '  %-3s %-52s → exit=%s stdout=%s ★期待 exit=2・空\n' "$1" "$2" "$rc" "${out:-(空)}"; fail=1
    fi
    # 旧判定は port を検証しない = 不正な port でも平然と1語を返す。
    old=$(printf '%s' "$REAL" | /bin/bash "$OLD" "$3" 2>/dev/null)
    if [ -n "$old" ]; then
        moved=$((moved + 1))
        printf '       旧判定: %-8s ← 期待は exit=2・空(旧は port を検証していない)\n' "$old"
    fi
}
usage_case J "port=0"              0
usage_case K "port=70000"          70000
usage_case L "port が数字でない"   abc

echo
echo "=== 入口ポートの指定と Funnel(2026-08-25 追加)==="
FRIDAY='{"TCP":{"443":{"HTTPS":true},"9443":{"HTTPS":true}},"Web":{"desk.tailnet.example:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8799"}}},"desk.tailnet.example:9443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}},"AllowFunnel":{"desk.tailnet.example:443":true}}'
run2 M "Friday 現物・9443 は自分で公開されていない"   ok       8787 9443 "$FRIDAY"
run2 N "同じ現物・443 は他人かつ Funnel[負]"          funneled 8787 443  "$FRIDAY"
run2 O "自分の宛先でも Funnel されていたら断る[負]"   funneled 8787 9443 '{"TCP":{"9443":{"HTTPS":true}},"Web":{"h:9443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}},"AllowFunnel":{"h:9443":true}}'
run2 P "入口が空いている(9443 に何も無い)"           apply    8787 9443 '{"TCP":{"443":{"HTTPS":true}},"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"}}}}}'
run2 Q "Funnel が別ポートに在っても巻き込まない"      apply    8787 9443 '{"AllowFunnel":{"h:443":true},"TCP":{"443":{"HTTPS":true}},"Web":{"h:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1"}}}}}'
printf '  %-3s %-52s → ' R "serve port が数字でない(使い方エラー)"
if printf '{}' | /bin/bash "$DEC" 8787 abc >/dev/null 2>&1; then printf '★通ってしまった\n'; fail=1; else printf 'exit 2 OK\n'; fi

echo
echo "=== 引数の順の取り違え(2026-08-26 追加。実際に踏んだ形)==="
# ★守る一線は「**別の入口の答えを 1 語で返さない**」。呼び手は 1 語しか見ないので、
#   どの入口についての答えかを区別できない = 黙って間違える形になる。
printf '  %-3s %-52s → ' S "入口ポートを第1引数に撃った(第2引数なし)[負]"
out=$(printf '%s' "$FRIDAY" | /bin/bash "$DEC" 9443 2>/dev/null); rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ]; then printf 'exit=2・stdout 空  OK\n'
else printf 'exit=%s stdout=%s ★1語を返してしまった\n' "$rc" "${out:-(空)}"; fail=1; fi

printf '  %-3s %-52s → ' T "同じ第1引数でも入口を明示すれば通る(逃げ道)"
out=$(printf '%s' "$FRIDAY" | /bin/bash "$DEC" 9443 443 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ -n "$out" ]; then printf '%-8s OK\n' "$out"
else printf 'exit=%s stdout=%s ★逃げ道が塞がっている\n' "$rc" "${out:-(空)}"; fail=1; fi

printf '  %-3s %-52s → ' U "普通の手元ポートは巻き込まない(過剰発火の負)"
out=$(printf '%s' "$REAL" | /bin/bash "$DEC" 8787 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ "$out" = ok ]; then printf 'ok       OK\n'
else printf 'exit=%s stdout=%s ★期待 exit=0・ok\n' "$rc" "${out:-(空)}"; fail=1; fi

echo
echo "=== 旧判定との対比(1件でなく全 19 ケース)==="
echo "  旧と答えが違った行: ${moved} 件"
# ★退行の検出は compare_old の中で構造的に済んでいる: 動いた行は必ず「旧 ≠ 期待」でしか
#   数えないので、旧が正しかった行で新が動けば、その行の `run` 側が先に赤くなる。
#   ここで見るのは「対照がまだ生きているか」だけ。
if [ "$moved" = 0 ]; then
    echo "  ★対照が死んでいる: 旧判定と新判定の答えが全ケースで一致した。"
    echo "    締め直しが何も買っていないか、旧判定の再現が新判定に寄ってしまっている。"; fail=1
fi

echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
