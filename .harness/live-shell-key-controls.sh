#!/bin/bash
# controls-for: ios/tools/live-interrupt-main.swift ios/tools/live-send-main.swift ios/tools/live-send-check.sh ios/tools/live-interrupt-check.sh
#
# 何を守る対照か —— **実機の殻が鍵を漏らさない事**。
#
# `ios/tools/*-main.swift` は製品には入らない(アプリの target から参照されない)が、
# **本物の api key を握って本番の rc-backend に当たる**唯一の Swift である。
# 規律は3つ、全部「書かれていない事」で守られている:
#   1. 鍵は stdin からだけ来る —— argv は `ps` に、環境変数は `ps -E` と子プロセスに出る
#   2. 鍵はどこにも印字しない
#   3. 既定のホストを書かない(製品外の写しが「本番はここ」を語り出す)
#   4. 殻を呼ぶ `.sh` の側でも、鍵に触る行が**許した4つの形以外に無い**
#      —— 鍵を ssh で取り出すのは `.sh` の方なので、形を閉じる価値は此処が一番高い
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
echo "== 殻の側(.sh): 鍵に触る行が**許した4つの形以外に無い**か =="
# ★此処だけ「禁止の一覧」ではなく**許可の一覧**にする。禁止は思い付いた漏らし方しか
#   捕らないが、許可は**思い付かなかった漏らし方も捕る**(閉じている)。鍵は殻の
#   `.sh` で ssh から取り出される —— 取り出す場所こそ形を閉じる価値がある。
#
# 許す4つ(実測 2026-08-06、2本の殻はこの4形しか使っていない):
#   A 取り出す   KEY="$(ssh … 'cat ~/.rc-backend/api.key')"
#   B 空の確認   [ -n "$KEY" ] || …
#   C 標準入力へ printf '…' … "$KEY" … | "$…BIN"
#   D 消す       KEY=""
SHELLS_SH=(
    "$ROOT/ios/tools/live-send-check.sh"
    "$ROOT/ios/tools/live-interrupt-check.sh"
)
for f in "${SHELLS_SH[@]}"; do
    if [ ! -f "$f" ]; then
        echo "UNMEASURED  読む file が無い: ${f#$ROOT/}"
        exit 2
    fi
done

ALLOW_A='^KEY="\$\(ssh .*api\.key.*\)"'
ALLOW_B='^\[ -n "\$KEY" \] \|\|'
ALLOW_C='printf .[^|]*"\$KEY".*\| "\$[A-Z_]*BIN"'
ALLOW_D='^KEY=""$'

key_line_ok() { # $1 = 行。許した形なら 0
    # 丸ごと注釈の行は対象外。★頭の空白を落としてから**先頭の1文字**で見る。
    #   `[[:space:]]*\#*` と書くと「空白で始まり何処かに # が在る行」に化けるので、
    #   `echo "$KEY"  # 説明` が注釈として素通りする(2026-08-06、書いた直後に自分で踏んだ)。
    local _trimmed="${1#"${1%%[![:space:]]*}"}"
    case "$_trimmed" in \#*) return 0 ;; esac
    printf '%s\n' "$1" | grep -qE "$ALLOW_A" && return 0
    printf '%s\n' "$1" | grep -qE "$ALLOW_B" && return 0
    printf '%s\n' "$1" | grep -qE "$ALLOW_C" && return 0
    printf '%s\n' "$1" | grep -qE "$ALLOW_D" && return 0
    return 1
}

# 囮を先に。許可の一覧が**漏らし方を落とせる**事を、本物より前に確かめる。
echo "-- 囮: 漏らし方を7通り書いて、7通りとも弾かれるか --"
DECOY_SH="$(mktemp)"
cat > "$DECOY_SH" <<'DECOYSHEOF'
"$BIN" "$KEY"
export RC_KEY="$KEY"
RC_KEY="$KEY" "$BIN"
echo "$KEY"
printf '%s' "$KEY" > /tmp/leak
logger "$KEY"
KEY_COPY="$KEY"
DECOYSHEOF
DECOY_SH_MISS=0
DECOY_SH_N=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    DECOY_SH_N=$((DECOY_SH_N + 1))
    if key_line_ok "$line"; then
        echo "FAIL  囮を許してしまう: $line"
        DECOY_SH_MISS=$((DECOY_SH_MISS + 1))
    else
        PASS=$((PASS + 1))
    fi
done < "$DECOY_SH"
/bin/rm -f "$DECOY_SH"
if [ "$DECOY_SH_MISS" -ne 0 ]; then
    echo
    echo "UNMEASURED  囮を $DECOY_SH_MISS 通り許した。本物が全部通っても意味が無い。"
    exit 2
fi
echo "PASS  囮 $DECOY_SH_N 通りとも弾いた"
PASS=$((PASS + 1))

# ★注釈の扱いそのものにも陰性対照を置く。「注釈は対象外」は**素通りの口**なので、
#   そこが広がると検査全体が静かに死ぬ。初版は実際に広すぎた(末尾注釈で素通りした)。
if key_line_ok '    echo "$KEY"  # 説明'; then
    echo "FAIL  末尾に注釈を足しただけの漏らしを許す = 注釈の口が広すぎる"
    FAIL=$((FAIL + 1))
else
    echo "PASS  陰性対照: 末尾注釈つきの漏らしは弾く"
    PASS=$((PASS + 1))
fi
if key_line_ok '  # ここで KEY を使う'; then
    echo "PASS  陰性対照: 丸ごと注釈の行は対象外のまま"
    PASS=$((PASS + 1))
else
    echo "FAIL  丸ごと注釈まで赤にしている(狭すぎ = 説明が書けなくなる)"
    FAIL=$((FAIL + 1))
fi

echo "-- 本物 --"
for f in "${SHELLS_SH[@]}"; do
    short="${f#$ROOT/}"
    bad=0
    n=0
    while IFS= read -r line; do
        case "$line" in *KEY*) ;; *) continue ;; esac
        n=$((n + 1))
        if key_line_ok "$line"; then
            continue
        fi
        echo "FAIL  [$short] 許した4形のどれでもない行: $line"
        bad=$((bad + 1))
    done < "$f"
    if [ "$n" -eq 0 ]; then
        echo "FAIL  [$short] 鍵に触る行が1つも無い = 錨が外れている(名前を変えた?)"
        FAIL=$((FAIL + 1))
    elif [ "$bad" -eq 0 ]; then
        echo "PASS  [$short] 鍵に触る $n 行、全部が許した4形"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

echo "-- 本物: 使った後に消しているか --"
for f in "${SHELLS_SH[@]}"; do
    short="${f#$ROOT/}"
    if grep -qE '^KEY=""$' "$f"; then
        echo "PASS  [$short] 使い終わりに鍵を消す"
        PASS=$((PASS + 1))
    else
        echo "FAIL  [$short] 鍵を消す行が無い(殻が終わるまで変数に残る)"
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "== PASS $PASS / FAIL $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
