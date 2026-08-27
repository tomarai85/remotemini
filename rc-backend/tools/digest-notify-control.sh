#!/bin/bash
# controls-for: tools/digest-notify.sh
# digest-notify-control.sh — **鳴るべき時に鳴り、鳴るべきでない時に鳴らない**を対で測る。
# 2026-08-26 新設。
#
# ★片方だけでは意味が無い(Codex 2026-08-26):
#   「鳴った」だけを見る対照は、**何でも鳴らす実装**で緑になる。
#   「鳴らない」だけを見る対照は、**何も鳴らさない実装**で緑になる。
#   だから同じ仕掛けで **鳴る筈の入力(受信1回)** と **鳴らない筈の入力(受信0回)** を両方測る。
#
# ★沈黙が「検査していない」を装えない様にする(Codex の指定):
#   受信側は nonce を記録に残し、**検査が実際に走った事**を別の印で確かめる。
#   0 件を「鳴らなかった」と読む前に、「そもそも走ったか」を先に確定させる。
#
# ★偽の API(python の1行サーバではなく、ただの curl 差し替え)で駆動する。
#   本物の Friday も本物の Discord も触らない。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DN="$HERE/digest-notify.sh"
[ -f "$DN" ] || { echo "★$DN が無い"; exit 2; }

fail=0; reds=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'k\n' > "$TMP/key"

# --- 偽 curl: 一覧と digest を JSON で返す。呼ばれた事も記録する ---------------------
mk_api() { # $1 = digest の JSON
    cat >"$TMP/curl" <<STUB
#!/bin/bash
echo called >> "$TMP/api-called"
u="\${!#}"
case "\$u" in
    */api/sessions) printf '%s' '{"sessions":[{"id":"sess-aaaa-1111"}]}' ;;
    */digest)       printf '%s' '$1' ;;
    *)              exit 1 ;;
esac
STUB
    chmod +x "$TMP/curl"
}
# 偽の鳴らし先: nonce 付きで受信を記録(引数と stdin の**両方**を拾う)
cat >"$TMP/notify" <<STUB
#!/bin/bash
a="\$*"; i=""; [ ! -t 0 ] && i="\$(cat)"
printf '%s|%s|%s\n' "\$RC_TEST_NONCE" "\$a" "\$i" >> "$TMP/received"
STUB
chmod +x "$TMP/notify"

dg() { # attention level lastAt  -> digest の JSON
    printf '{"digest":{"lastAt":%s},"attention":"%s","action":{"level":"%s","reason":"%s"},"line":"L"}' \
        "$3" "$1" "$2" "$1"
}

run() { # $1=digest JSON, $2=SOON_MIN, $3=NOW_OBS, 状態は $TMP/state.json を持ち越す
    mk_api "$1"
    : > "$TMP/api-called"
    RC_TEST_NONCE="$NONCE" PATH="$TMP:$PATH" \
    RC_DIGEST_KEY="$TMP/key" RC_DIGEST_STATE="$TMP/state.json" RC_DIGEST_LOG="$TMP/log" \
    RC_DIGEST_NOTIFY="$TMP/notify" RC_DIGEST_SOON_MIN="${2:-20}" RC_DIGEST_NOW_OBS="${3:-2}" \
    /bin/bash "$DN" </dev/null >/dev/null 2>&1
    echo $?
}
# ★`grep -c` は 0 件で **rc=1** を返す。`|| echo 0` を足すと grep 自身の `0` と重なって
#   `0\n0` になり、数値比較が全部外れる(2026-08-26 実測。これも駆動側の欠陥で、
#   出力からは実装の欠陥と区別が付かない)。数だけを1行で出す形に固定する。
received() { grep -c "^$NONCE|" "$TMP/received" 2>/dev/null | head -1 | tr -dc 0-9; }
reset_all() { rm -f "$TMP/state.json" "$TMP/received"; : > "$TMP/received"; }
# 状態の `first` を過去へずらして「実経過」を作る(眠らずに時間を進める)
age_state() { # $1 = 分
    "${RC_DIGEST_PY:-/usr/bin/python3}" - "$TMP/state.json" "$1" <<'PY'
import json,sys,time
p,mins=sys.argv[1],int(sys.argv[2])
d=json.load(open(p))
for v in d.values():
    if isinstance(v,dict) and "first" in v: v["first"]=int(v["first"])-mins*60
json.dump(d,open(p,"w"))
PY
}

NONCE="n$(date +%s)$$"

echo "=== 1. 鳴る筈: now が2回続く → **受信ちょうど1回**[本命] ==="
reset_all
rc1=$(run "$(dg input now null)" 20 2)
c1=$(received)
rc2=$(run "$(dg input now null)" 20 2)
c2=$(received)
reds=$((reds + 1))
[ -s "$TMP/api-called" ] || { printf '  ★検査が走っていない(API を一度も叩いていない)\n'; fail=1; }
if [ "$c1" = 0 ] && [ "$c2" = 1 ]; then
    printf '  1回目は黙り、2回目で1回だけ鳴った  OK\n'
else
    printf '  ★1回目=%s 2回目=%s (期待 0 → 1) rc=%s/%s\n' "$c1" "$c2" "$rc1" "$rc2"; fail=1
fi

echo "=== 2. 鳴らない筈: 同じ状態を更に3回見ても **増えない**(鳴りっぱなしにしない)==="
run "$(dg input now null)" 20 2 >/dev/null
run "$(dg input now null)" 20 2 >/dev/null
run "$(dg input now null)" 20 2 >/dev/null
c3=$(received)
[ "$c3" = 1 ] && printf '  受信は1回のまま  OK\n' || { printf '  ★%s 回に増えた\n' "$c3"; fail=1; }

echo "=== 3. 鳴らない筈: unknown は何回見ても鳴らない[永久に不適格] ==="
reset_all
run "$(dg unknown now null)" 20 2 >/dev/null
run "$(dg unknown now null)" 20 2 >/dev/null
run "$(dg unknown now null)" 20 2 >/dev/null
reds=$((reds + 1))
[ "$(received)" = 0 ] && printf '  0 回  OK\n' || { printf '  ★鳴った(%s 回)\n' "$(received)"; fail=1; }

echo "=== 4. 鳴らない筈: now が1回だけで消えた(過渡)==="
reset_all
run "$(dg input now null)" 20 2 >/dev/null
run "$(dg input soon '\"2026-01-01T00:00:00Z\"')" 20 2 >/dev/null   # 指紋が変わる = 進んだ
reds=$((reds + 1))
[ "$(received)" = 0 ] && printf '  0 回  OK\n' || { printf '  ★過渡で鳴った(%s 回)\n' "$(received)"; fail=1; }

echo "=== 5. 鳴る筈: soon が **実経過 20 分**続いた → 1回[時間で測る] ==="
reset_all
run "$(dg input soon null)" 20 2 >/dev/null
a=$(received)
run "$(dg input soon null)" 20 2 >/dev/null          # 2回目でも まだ時間が経っていない
b=$(received)
age_state 25                                          # 実経過を 25 分に進める
run "$(dg input soon null)" 20 2 >/dev/null
c=$(received)
reds=$((reds + 1))
if [ "$a" = 0 ] && [ "$b" = 0 ] && [ "$c" = 1 ]; then
    printf '  回数では鳴らず、時間で鳴った  OK\n'
else
    printf '  ★%s/%s/%s (期待 0/0/1) = 回数で鳴らしている疑い\n' "$a" "$b" "$c"; fail=1
fi

echo "=== 6. 鳴らない筈: Tom が返した(指紋が変わる)→ 復旧の通知を出さない ==="
reset_all
run "$(dg input soon null)" 0 1 >/dev/null            # すぐ鳴らす設定で1回鳴らす
[ "$(received)" = 1 ] || { printf '  ★前提が作れていない(鳴っていない)\n'; fail=1; }
run "$(dg input soon '\"2026-02-02T00:00:00Z\"')" 0 1 >/dev/null   # 会話が進んだ
# 進んだ後 同じ状態がまた続けば また鳴ってよいが、**「直りました」は出さない**
last="$(tail -1 "$TMP/received" 2>/dev/null)"
reds=$((reds + 1))
if printf '%s' "$last" | grep -qE "直り|復旧|recovered"; then
    printf '  ★復旧の通知を出している: %s\n' "$last"; fail=1
else
    printf '  復旧の通知は出さない  OK\n'
fi

echo "=== 6b. 会話が **0 件**は壊れていない(rc=0)。取れないのと区別する[誤診の負] ==="
# ★0 件は起こり得る —— 常駐が落ちてから ensure-phone-window が作り直すまでの間。
#   それを「監視が壊れている」と言うのは誤診で、誤診は次に本当に壊れた日に読まれなくなる。
cat >"$TMP/curl" <<STUB
#!/bin/bash
echo called >> "$TMP/api-called"
u="\${!#}"
case "\$u" in
    */api/sessions) printf '%s' '{"sessions":[]}' ;;
    *)              exit 1 ;;
esac
STUB
chmod +x "$TMP/curl"
reset_all
rc0=$( RC_TEST_NONCE="$NONCE" PATH="$TMP:$PATH" RC_DIGEST_KEY="$TMP/key" \
       RC_DIGEST_STATE="$TMP/state.json" RC_DIGEST_LOG="$TMP/log" \
       RC_DIGEST_NOTIFY="$TMP/notify" /bin/bash "$DN" </dev/null >/dev/null 2>&1; echo $? )
reds=$((reds + 1))
if [ "$rc0" = 0 ] && [ "$(received)" = 0 ]; then
    printf '  0 件は rc=0 で黙る(壊れていると言わない)  OK\n'
else
    printf '  ★rc=%s / 受信=%s(0 件を「壊れている」と誤診している)\n' "$rc0" "$(received)"; fail=1
fi

echo "=== 7. 鳴らない筈だが**黙ってもいけない**: 見られなかったら rc=3 ==="
reset_all
rcx=$( RC_TEST_NONCE="$NONCE" PATH="$TMP:$PATH" RC_DIGEST_KEY="$TMP/nokey" \
       RC_DIGEST_STATE="$TMP/state.json" RC_DIGEST_LOG="$TMP/log" \
       RC_DIGEST_NOTIFY="$TMP/notify" /bin/bash "$DN" </dev/null >/dev/null 2>&1; echo $? )
reds=$((reds + 1))
[ "$rcx" = 3 ] && printf '  rc=3(静かではなく「見られなかった」)  OK\n' \
               || { printf '  ★rc=%s\n' "$rcx"; fail=1; }

echo "=== 8. 自分が壊れた時、**鳴らす1つと鳴らさない2つ**を分ける[本命] ==="
# ★Codex 2026-08-27 の裁定。此の台本が壊れる入口は3つ在るが、鳴らす価値が在るのは1つ:
#     鍵が読めない   … 電話も机と話せなくなるので**製品の側から数分で判る**
#     一覧が取れない … 机が落ちている事なので `health-observer` が既に見ている
#     判定が落ちた   … **此れだけ**が、他の全部が健康に見えたまま静かに死ぬ
#   前の2つで鳴らすと 1 つの障害で複数の通知が飛ぶ = 重複の騒音。
#   ★同じ日に `health-observer` の**偽の**「監視が壊れている」を消したばかりなので、
#     新しい叫び口は**他の誰も見ていない失敗**に限る。

# 8-a. 鍵が読めない → 鳴らない(rc=3 で黙る)
reset_all
mk_api "$(dg input now null)"
rc_a=$( RC_TEST_NONCE="$NONCE" PATH="$TMP:$PATH" RC_DIGEST_KEY="$TMP/nokey" \
        RC_DIGEST_STATE="$TMP/state.json" RC_DIGEST_LOG="$TMP/log" \
        RC_DIGEST_NOTIFY="$TMP/notify" /bin/bash "$DN" </dev/null >/dev/null 2>&1; echo $? )
reds=$((reds + 1))
if [ "$rc_a" = 3 ] && [ "$(received)" = 0 ]; then
    printf '  鍵が読めない → 鳴らない(製品の側から判る)  OK\n'
else
    printf '  ★rc=%s / 受信=%s(重複の騒音を出している)\n' "$rc_a" "$(received)"; fail=1
fi

# 8-b. 一覧が取れない → 鳴らない(health-observer が見ている)
reset_all
cat >"$TMP/curl" <<'STUB8'
#!/bin/bash
exit 7
STUB8
chmod +x "$TMP/curl"
rc_b=$( RC_TEST_NONCE="$NONCE" PATH="$TMP:$PATH" RC_DIGEST_KEY="$TMP/key" \
        RC_DIGEST_STATE="$TMP/state.json" RC_DIGEST_LOG="$TMP/log" \
        RC_DIGEST_NOTIFY="$TMP/notify" /bin/bash "$DN" </dev/null >/dev/null 2>&1; echo $? )
reds=$((reds + 1))
if [ "$rc_b" = 3 ] && [ "$(received)" = 0 ]; then
    printf '  一覧が取れない → 鳴らない(机の生死は別の見張り)  OK\n'
else
    printf '  ★rc=%s / 受信=%s\n' "$rc_b" "$(received)"; fail=1
fi

# 8-c. 判定が落ちた → **1回だけ鳴る**。此れだけが誰も見ていない失敗。
reset_all
mk_api "$(dg input now null)"
# ★`$PY` は一覧の段でも使う。丸ごと壊すと**先に一覧で落ちて判定の段まで届かない**
#   (実測 2026-08-27: 受信 0 で赤くなり、判定の枝を一度も通っていなかった)。
#   だから **判定の呼び出しだけ**を落とす —— 判定は `"$PY" - ...`(stdin から読む形)なので、
#   第1引数が `-` の時だけ失敗させ、`-c`(一覧の段)は本物へ通す。
cat >"$TMP/brokenpy" <<'BPY'
#!/bin/bash
if [ "${1:-}" = "-" ]; then exit 99; fi
exec /usr/bin/python3 "$@"
BPY
chmod +x "$TMP/brokenpy"
rc_c=$( RC_TEST_NONCE="$NONCE" PATH="$TMP:$PATH" RC_DIGEST_KEY="$TMP/key" \
        RC_DIGEST_STATE="$TMP/state.json" RC_DIGEST_LOG="$TMP/log" \
        RC_DIGEST_NOTIFY="$TMP/notify" RC_DIGEST_PY="$TMP/brokenpy" \
        /bin/bash "$DN" </dev/null >/dev/null 2>&1; echo $? )
reds=$((reds + 1))
n_c="$(received)"
if [ "$rc_c" = 3 ] && [ "$n_c" = 1 ]; then
    printf '  判定が落ちた → 1回だけ鳴る  OK\n'
else
    printf '  ★rc=%s / 受信=%s(期待 rc=3 / 1回)\n' "$rc_c" "$n_c"; fail=1
fi
# ★重さを混ぜない —— 製品の生死の文言(監視側が壊れています)を名乗らない。
if grep -q "監視側が壊れています" "$TMP/received" 2>/dev/null; then
    printf '  ★製品の生死の文言を名乗っている(便利機能の停止を同じ重さで出している)\n'; fail=1
else
    printf '  便利機能の停止として出している(重さを混ぜない)  OK\n'
fi

echo
echo "  赤に倒れる入力: ${reds} 件"
[ "$reds" -lt 2 ] && { echo "  ★対照が空虚"; fail=1; }
echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
