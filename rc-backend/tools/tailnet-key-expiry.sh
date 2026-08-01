#!/bin/bash
# tailnet-key-expiry.sh — この機械の tailnet 鍵があと何日で切れるかを言う。
#   宛先: rc-backend/tools/tailnet-key-expiry.sh(= edith 上では /Users/edith/rc-backend/tools/)
#
# なぜ独立した file なのか:
#   呼ぶ側が2つ在る(起動ラッパ / deploy 台本)。同じ計算を2箇所に書くと**片方だけ古くなる**。
#   DESIGN.md §2.13 で同じ理由から表の再掲を禁じたのと同じ話。
#
# なぜこれが要るのか(2026-08-02 実測):
#   edith の鍵は 2026-12-25 に切れる。Tom の渡米は 8/20。= **旅行の途中で切れる**。
#   切れると edith は tailnet から落ち、電話の面と**復旧用の ssh を同時に失う**。
#   無人の機械に物理で触れない場所から、戻す手が無くなる = 単一障害点(Codex 2026-08-02)。
#
# 終了コード:
#   0 = 期限なし、または閾値より遠い
#   1 = 閾値より近い(**警告であって門ではない** — 下記)
#   2 = 測れなかった(「切れない」とは言わない)
#
# ★1 を門にしない理由: 鍵が 40 日後に切れる事は、コードを配る事の妨げにならない。
#   ここで deploy を止めても被害は1つも減らず、出来る仕事だけが止まる。fail-closed は
#   「送信」や「本番反映」の判断に効かせる物で、警報を門に化けさせる為の物ではない。
#   → 呼ぶ側は `|| true` で受け、**大きな声で出す**。止めるかは人が決める。

set -u

TS="${RC_TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
WARN_DAYS="${RC_KEY_WARN_DAYS:-45}"

if [ ! -x "$TS" ]; then
    echo "鍵の期限: 測れない(${TS} が無い)"
    exit 2
fi

"$TS" status --json 2>/dev/null | WARN_DAYS="$WARN_DAYS" /usr/bin/python3 -c '
import sys, os, json, datetime

warn = int(os.environ.get("WARN_DAYS", "45"))
try:
    e = (json.load(sys.stdin).get("Self") or {}).get("KeyExpiry")
except Exception:
    print("鍵の期限: 取得できなかった(status --json が読めない)")
    raise SystemExit(2)

if not e:
    # 期限を無効化すると KeyExpiry ごと消える。= Tom の操作が効いた事の確認にもなる。
    print("鍵の期限: なし(無効化済み = 渡米中に切れる心配は無い)")
    raise SystemExit(0)

t = datetime.datetime.fromisoformat(e.replace("Z", "+00:00"))
d = (t - datetime.datetime.now(datetime.timezone.utc)).days
if d >= warn:
    print(f"鍵の期限: {t:%Y-%m-%d} (残り {d} 日)")
    raise SystemExit(0)

print(f"★鍵の期限: {t:%Y-%m-%d} (残り {d} 日 = 閾値 {warn} 日を切った)")
print("★切れると tailnet から落ちる。電話の面も、復旧用の ssh も、同時に失う")
print("★直す = Tailscale admin console → Machines → 該当機 → Disable key expiry")
raise SystemExit(1)
'
exit "${PIPESTATUS[1]}"
