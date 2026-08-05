#!/bin/bash
# controls-for: ios/tools/live-interrupt-main.swift ios/tools/live-send-main.swift
#
# 何を守る対照か —— **実機の殻が鍵を漏らさない事**。
#
# `ios/tools/*-main.swift` は製品には入らない(アプリの target から参照されない)が、
# **本物の api key を握って本番の rc-backend に当たる**唯一の Swift である。
# 規律は3つ、全部「書かれていない事」で守られている:
#   1. 鍵は stdin からだけ来る —— argv は `ps` に、環境変数は `ps -E` と子プロセスに出る
#   2. 鍵はどこにも印字しない
#   3. 既定のホストを書かない(製品外の写しが「本番はここ」を語り出す)
#
# ★「書かれていない事」を守る検査は、**当たらないプローブと見分けが付かない**。
#   2026-08-06 に `live-interrupt-check.sh` の `--classify` を引数の輪より後ろに置いて
#   永久に届かない口にした事が在る(対照が 5/5 赤で捕まえた)。同じ形をここで踏まない為、
#   この対照は**囮の file に対して同じ探し方を走らせ、全部当たる事**を先に確かめる。
#   囮で当たらない探し方は、本物で 0 件だった事に意味が無い。
#
# 終了コード: 0 = 全部守られている / 1 = 破れている / 2 = 測れていない(file が無い等)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELLS=(
    "$ROOT/ios/tools/live-interrupt-main.swift"
    "$ROOT/ios/tools/live-send-main.swift"
)

for f in "${SHELLS[@]}"; do
    if [ ! -f "$f" ]; then
        echo "UNMEASURED  読む file が無い: ${f#$ROOT/}"
        exit 2
    fi
done

PASS=0
FAIL=0

# 禁止する形。名前|正規表現(ERE)。
#   ★`print` を1本の網で捕らないのは、`print("outcome=display …")` の様な**出してよい行**が
#     在るから。捕るのは「鍵や会話 id を含む print」だけ。
BANNED_NAMES=(
    "argv から読む"
    "環境変数から読む"
    "getenv"
    "鍵を印字する"
    "生の入力を印字する"
    "会話 id を印字する"
    "既定のホストを埋め込む"
    "file へ書き出す"
)
BANNED_PATTERNS=(
    'CommandLine\.arguments'
    'ProcessInfo\.processInfo\.environment'
    'getenv\('
    'print\(.*apiKey'
    'print\(.*input\['
    'print\(.*[sS]ession[IiD]'
    'https?://[a-zA-Z0-9]'
    'write\(toFile'
)

# 必ず在る形(= 鍵の入口が stdin である事)。
REQUIRED_NAME="stdin から読む"
REQUIRED_PATTERN='FileHandle\.standardInput'

echo "== 囮: この探し方が本当に当たるのか(先に確かめる) =="
# ★囮は**禁止形を全部含む**。1つでも見つからなければ、その探し方は本物に対しても
#   何も測っていないので、そこで 2(測れていない)で落ちる。
DECOY="$(mktemp)"
cat > "$DECOY" <<'DECOYEOF'
import Foundation
let apiKey = CommandLine.arguments[1]
let fromEnv = ProcessInfo.processInfo.environment["RC_KEY"]
let raw = getenv("RC_KEY")
let input = ["https://decoy.invalid", "sess-decoy", "decoy-key"]
let sessionID = input[1]
print("key=\(apiKey)")
print("raw=\(input[2])")
print("session=\(sessionID)")
try? "x".write(toFile: "/tmp/decoy", atomically: true, encoding: .utf8)
DECOYEOF
DECOY_MISS=0
i=0
while [ "$i" -lt "${#BANNED_PATTERNS[@]}" ]; do
    if grep -qE -- "${BANNED_PATTERNS[$i]}" "$DECOY"; then
        echo "PASS  囮で当たった: ${BANNED_NAMES[$i]}"
        PASS=$((PASS + 1))
    else
        echo "FAIL  囮で当たらない: ${BANNED_NAMES[$i]} = この探し方は本物でも何も測らない"
        DECOY_MISS=$((DECOY_MISS + 1))
    fi
    i=$((i + 1))
done
/bin/rm -f "$DECOY"
if [ "$DECOY_MISS" -ne 0 ]; then
    echo
    echo "UNMEASURED  囮で当たらない探し方が $DECOY_MISS 本ある。本物の 0 件に意味が無い。"
    exit 2
fi

echo
echo "== 本物: 禁止の形が1つも無いか =="
for f in "${SHELLS[@]}"; do
    short="${f#$ROOT/}"
    i=0
    while [ "$i" -lt "${#BANNED_PATTERNS[@]}" ]; do
        hits="$(grep -cE -- "${BANNED_PATTERNS[$i]}" "$f")"
        if [ "$hits" -eq 0 ]; then
            echo "PASS  [$short] ${BANNED_NAMES[$i]} —— 無し"
            PASS=$((PASS + 1))
        else
            echo "FAIL  [$short] ${BANNED_NAMES[$i]} —— $hits 箇所"
            grep -nE -- "${BANNED_PATTERNS[$i]}" "$f" | sed 's/^/        /'
            FAIL=$((FAIL + 1))
        fi
        i=$((i + 1))
    done
done

echo
echo "== 本物: 鍵の入口が stdin である事 =="
for f in "${SHELLS[@]}"; do
    short="${f#$ROOT/}"
    if grep -qE -- "$REQUIRED_PATTERN" "$f"; then
        echo "PASS  [$short] $REQUIRED_NAME"
        PASS=$((PASS + 1))
    else
        echo "FAIL  [$short] $REQUIRED_NAME —— 見当たらない(入口が別に移った可能性)"
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "== PASS $PASS / FAIL $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
