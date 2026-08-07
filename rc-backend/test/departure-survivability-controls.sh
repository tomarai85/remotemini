#!/bin/bash
# controls-for: tools/departure-survivability-check.sh
# departure-survivability-controls.sh — 渡米前の耐久検査が**赤へ倒れる**事を測る。
#
# なぜ要るのか:
#   あの検査は 2026-08-07 の実機で 1 項目を除いて全部緑だった。緑しか見ていない検査は
#   「壊れていない」と「壊れを見付けられない」を区別できない。ここは**壊した状態を
#   与えて赤(または未測定)が出るか**だけを見る = 陰性対照。
#
# どうやって edith 無しで測るか:
#   検査は `ssh` を1回だけ呼び、その標準出力の `key=value` を全部の判定に使う。
#   PATH の先頭に偽の `ssh` を置けば、実機無しで任意の状態を作れる。
#   ★偽物にしているのは **ssh の返答だけ**。判定・閾値・文面・終了コードは本物。
#   ★冷起動の 7 項目は向こうの coldboot-chain.sh の**終了コードをそのまま**使うので、
#     ここで測るのはその引き取り方(0/1/2/欠落)だけ。7 項目自体の対照は
#     `test/coldboot-chain-controls.sh` の仕事 —— 役割を混ぜない。
#
# 使い方: bash test/departure-survivability-controls.sh   (exit 0 = 全部 OK)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/../tools/departure-survivability-check.sh"
[ -f "$SUT" ] || { echo "検査本体が無い: $SUT" >&2; exit 2; }

T=$(mktemp -d /tmp/rc-dep-controls.XXXXXX) || exit 2
cleanup() { [ -d "$T" ] && find "$T" -mindepth 0 -delete 2>/dev/null; }
trap cleanup EXIT

mkdir -p "$T/bin"
fail=0

# 全項目が緑になる返答。各対照はここから **1 行だけ** 差し替える。
# こうしないと「別の理由で赤になった」のを「狙った項目で赤になった」と読み違える。
GOOD='cb_rc=0
job_rc=0
job_pid=574
http=401
freeg=133
ts_state=ok
ts_total=6
ts_expiring=0
ts_min_days=-'

cat > "$T/bin/ssh" <<'EOS'
#!/bin/bash
cat "$FAKE_SSH_ANSWER"
EOS
chmod +x "$T/bin/ssh"

# 1行を置き換える(キーの完全一致)。無いキーを指定したら落とす —— 綴りを間違えたまま
# 「対照が通った」と言わない為。
replace() {
    printf '%s\n' "$GOOD" | awk -F= -v k="$1" -v l="$2" '
        $1 == k { print l; found=1; next } { print }
        END { if (!found) exit 9 }
    ' || { echo "対照の綴り間違い: $1 は GOOD に無い" >&2; exit 2; }
}

run() {  # run <answer-text> [args...]
    local ans="$1"; shift
    printf '%s\n' "$ans" > "$T/answer"
    OUT=$(FAKE_SSH_ANSWER="$T/answer" PATH="$T/bin:$PATH" bash "$SUT" "$@" 2>&1)
    RC=$?
}

ok() { printf '  OK   %s\n' "$1"; }
ng() { printf '  NG   %s\n' "$1"; fail=$((fail+1)); printf '%s\n' "$OUT" | sed 's/^/       /'; }

# --- P: 全部良ければ緑 -------------------------------------------------------
# これが無いと「常に赤を返す壊れた検査」でも下の対照が全部通ってしまう。
run "$GOOD" --days 30
if [ "$RC" -eq 0 ]; then ok "P 全項目良好 -> 終了 0"; else ng "P 全項目良好なのに 終了 $RC"; fi

probe() {  # probe <名前> <key> <壊した行> <期待コード> <出力に居るべき語>
    run "$(replace "$2" "$3")" --days 30
    if [ "$RC" -ne "$4" ]; then ng "$1: 終了 $RC(期待 $4)"; return; fi
    if printf '%s\n' "$OUT" | grep -q "$5"; then ok "$1 -> 終了 $4"
    else ng "$1: 終了は合ったが理由が出ていない($5 が無い)"; fi
}

# --- 冷起動の鎖の引き取り方 --------------------------------------------------
probe "A 鎖が切れている"     cb_rc "cb_rc=1"       1 "鎖が切れている"
probe "B 鎖が測れなかった"   cb_rc "cb_rc=2"       2 "緑と読まない"
probe "C 道具が向こうに無い" cb_rc "cb_rc=missing" 1 "deploy-to-edith"

# --- ここが足している 4 項目 -------------------------------------------------
probe "D 落ちて再起動を繰り返す" job_rc      "job_rc=78"      1 "繰り返している疑い"
probe "E 鍵が外れて 200"         http        "http=200"       1 "鍵が外れている"
probe "F 面に届かない"           http        "http=000"       2 "届かなかった"
probe "G 空きが少ない"           freeg       "freeg=3"        1 "空き 3GB"
probe "H 鍵に期限が在る"         ts_expiring "ts_expiring=2"  1 "期限付き 2 台"
probe "I tailscale が無い"       ts_state    "ts_state=absent" 1 "経路そのものを測れていない"

# --- J: job が居ない ---------------------------------------------------------
run "$(printf '%s\n' "$GOOD" | grep -v '^job_pid=')" --days 30
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q "launchctl に居ない"; then ok "J job 不在 -> 赤"
else ng "J job 不在: 終了 $RC"; fi

# --- K: 赤と未測定が同時に在れば**赤**が勝つ ---------------------------------
# 未測定が在るからと 2 を返すと、直さなければならない赤が「測り直せ」に化ける。
run "$(printf '%s\n' "$GOOD" | sed 's/^http=401/http=000/; s/^freeg=133/freeg=3/')" --days 30
if [ "$RC" -eq 1 ]; then ok "K 赤+未測定 -> 赤(1)が勝つ"
else ng "K 赤が在るのに 終了 $RC"; fi

# --- L: edith に届かない時は 2(未測定)。**赤に丸めない** -------------------
# 到達不能を赤にすると「向こうが壊れている」と読まれ、実際は自分の回線だった時に
# 渡米前の判断を誤らせる。ここがこの対照の本丸。
run "" --days 30
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -q "未測定"; then ok "L 到達不能 -> 終了 2"
else ng "L 到達不能なのに 終了 $RC(赤にも緑にも丸めてはいけない)"; fi

# --- M: 旅程を伸ばしても、期限が無ければ緑のまま -----------------------------
# 「日数を伸ばせば必ず赤」という誤った実装を落とす。期限が無い機器は日数と無関係。
run "$GOOD" --days 365
if [ "$RC" -eq 0 ]; then ok "M 旅程 365 日でも期限無しなら緑"
else ng "M 期限が無いのに旅程を伸ばしただけで 終了 $RC"; fi

# --- N: 引数の検算 -----------------------------------------------------------
run "$GOOD" --days abc
if [ "$RC" -eq 2 ]; then ok "N --days abc -> 終了 2"; else ng "N --days abc を受け入れた(終了 $RC)"; fi
run "$GOOD" --days
if [ "$RC" -eq 2 ]; then ok "N2 --days が空 -> 終了 2"; else ng "N2 空の --days を受け入れた(終了 $RC)"; fi

echo
if [ "$fail" -eq 0 ]; then echo "departure-survivability-controls: 全部 OK"; exit 0; fi
echo "departure-survivability-controls: NG ${fail} 件"; exit 1
