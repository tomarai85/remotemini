#!/bin/bash
# controls-for: rc-backend/tools/health-observer.sh
# exposure-standing-control.sh — 常設の見張りが **露出 / 判らない / 安全** を取り違えない事を測る。
# 2026-08-26 新設。
#
# 守る一線は3つ。どれも「緑だから安全」と読ませない為に在る:
#   1. **露出(exit 1)は閾値を置かずに1回で鳴る。** 生存は揺れるが公開設定は揺れない ——
#      「3回続いたら」を掛けると、その間ずっと公開されたまま黙る事になる。
#   2. **測れない(exit 3)を安全と混ぜない。** 「判らない」は別の事象(保証を失った)で、
#      別の閾値で鳴る。混ぜると、どちらの意味でも読めない警報になる。
#   3. **安全(exit 0)では鳴らない。** 復旧を連呼すると、人が通知を読まなくなる。
#
# ★偽の tailscale と偽の通知先で駆動する。本物の serve を触らないし、本物の Discord も鳴らさない。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HO="$HERE/health-observer.sh"
[ -f "$HO" ] || { echo "★$HO が無い"; exit 2; }

fail=0; reds=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

SAFE='{"TCP":{"9443":{"HTTPS":true}},"Web":{"h:9443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}}},"AllowFunnel":{"h:443":true}}'
EXPOSED='{"TCP":{"443":{"HTTPS":true}},"Web":{"h:443":{"Handlers":{"/rc":{"Proxy":"http://127.0.0.1:8787"}}}},"AllowFunnel":{"h:443":true}}'

make_ts() { # $1 = 吐く JSON(空文字 = 何も吐かない = 読めない)
    printf '#!/bin/bash\nprintf %%s %s\n' "'$1'" > "$TMP/ts"
    chmod +x "$TMP/ts"
}
# ★出し先は **引数と標準入力の両方**を拾う。`health-observer.sh` の中で規約が2つ在る:
#   `notify_monitor_broken` は本文を **stdin** で渡し(`printf ... | "$NOTIFY"`)、
#   露出の通知は **引数**で渡す。片方しか拾わない偽物にすると、鳴っているのに
#   「鳴らない」と赤が出る —— 2026-08-26 に実際そうなり、実装を疑って時間を使った。
make_notify() {
    {
      echo '#!/bin/bash'
      echo 'a="$*"'
      echo 'i=""; [ ! -t 0 ] && i="$(cat)"'
      printf 'printf "%%s %%s\\n" "$a" "$i" >> "%s"\n' "$TMP/notified"
    } > "$TMP/notify"
    chmod +x "$TMP/notify"
}
make_notify

# ★**本物の口**(`--exposure-only`)を叩く。関数を sed で切り出して eval する駆動は、
#   本文の書式が少し変わるだけで黙って何も走らなくなる —— 2026-08-26 に実際そうなり、
#   対照が「鳴らない」と赤を出した。あれは実装の欠陥ではなく**駆動の欠陥**で、
#   出力からは区別が付かない。測る物と測られる物を一致させる為に口を1つ開けた。
run_exposure() { # $1 = serve JSON(空 = 読めない)、$2 = 直前の mark 内容(空可)
    make_ts "$1"
    : > "$TMP/notified"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$TMP/mark"; else rm -f "$TMP/mark"; fi
    env \
        RC_HEALTH_EXP_TS="$TMP/ts" \
        RC_HEALTH_EXP_MARK="$TMP/mark" \
        RC_HEALTH_EXP_CHECK="$HERE/funnel-exposure-check.sh" \
        RC_HEALTH_NOTIFY="$TMP/notify" \
        RC_HEALTH_LOG="$TMP/log" \
        RC_HEALTH_STATE="$TMP/state.json" \
        RC_HEALTH_KEY_EVERY=999999999 \
        RC_HEALTH_EXP_BLIND_THRESHOLD=2 \
        /bin/bash "$HO" --exposure-only </dev/null >/dev/null 2>&1
    # ★`</dev/null` は要る。露出の通知は**引数**で渡すので、偽の出し先が
    #   stdin も読もうとすると親の stdin を継いで**永久に待つ**(実測で固まった)。
}

verdict() { head -1 "$TMP/mark" 2>/dev/null | cut -d' ' -f1; }
notified() { [ -s "$TMP/notified" ] && cat "$TMP/notified" || printf ''; }

echo "=== 1. 露出は **1回で** 鳴る(閾値を置かない)[本命] ==="
run_exposure "$EXPOSED" ""
reds=$((reds + 1))
n="$(notified)"
if [ "$(verdict)" = "exposed" ] && printf '%s' "$n" | grep -q "公開面が机へ"; then
    printf '  1回目で鳴った  OK\n'
else
    printf '  ★鳴らなかった(判定=%s / 通知=%s)\n' "$(verdict)" "${n:-無し}"; fail=1
fi

echo "=== 2. 安全では鳴らない(復旧の連呼をしない)[過剰発火の負] ==="
run_exposure "$SAFE" "exposed 0"
if [ "$(verdict)" = "safe" ] && [ -z "$(notified)" ]; then
    printf '  黙って記録だけ  OK\n'
else
    printf '  ★安全なのに鳴った(判定=%s / 通知=%s)\n' "$(verdict)" "$(notified)"; fail=1
fi

echo "=== 3. 測れない = **安全と混ぜない**。1回目は溜めるだけ ==="
run_exposure "" ""
if [ "$(verdict)" = "blind" ] && [ -z "$(notified)" ]; then
    printf '  blind と記録・まだ鳴らさない  OK\n'
else
    printf '  ★1回目で鳴ったか、safe に倒れた(判定=%s / 通知=%s)\n' "$(verdict)" "$(notified)"; fail=1
fi

echo "=== 4. 測れないが続いたら「監視が壊れている」で鳴る(露出とは別の文言)[赤] ==="
run_exposure "" "blind 1"
reds=$((reds + 1))
n="$(notified)"
if [ "$(verdict)" = "blind" ] && printf '%s' "$n" | grep -q "監視側が壊れています"; then
    printf '  別の文言で鳴った  OK\n'
    if printf '%s' "$n" | grep -q "公開面が机へ"; then
        printf '  ★露出の文言と混ざっている\n'; fail=1
    fi
else
    printf '  ★鳴らない(判定=%s / 通知=%s)\n' "$(verdict)" "${n:-無し}"; fail=1
fi

echo
echo "  赤に倒れる入力: ${reds} 件"
[ "$reds" -lt 2 ] && { echo "  ★対照が空虚"; fail=1; }
echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
