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

echo "=== 7. 鳴らない筈だが**黙ってもいけない**: 見られなかったら rc=3 ==="
reset_all
rcx=$( RC_TEST_NONCE="$NONCE" PATH="$TMP:$PATH" RC_DIGEST_KEY="$TMP/nokey" \
       RC_DIGEST_STATE="$TMP/state.json" RC_DIGEST_LOG="$TMP/log" \
       RC_DIGEST_NOTIFY="$TMP/notify" /bin/bash "$DN" </dev/null >/dev/null 2>&1; echo $? )
reds=$((reds + 1))
[ "$rcx" = 3 ] && printf '  rc=3(静かではなく「見られなかった」)  OK\n' \
               || { printf '  ★rc=%s\n' "$rcx"; fail=1; }

echo
echo "  赤に倒れる入力: ${reds} 件"
[ "$reds" -lt 2 ] && { echo "  ★対照が空虚"; fail=1; }
echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
