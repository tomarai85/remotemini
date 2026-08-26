#!/bin/bash
# phone-window-notify.sh — `phone-window-health.sh` の赤を Tom へ届ける段。2026-08-26 新設。
#
# 分けた理由: 検出(health)と配達(notify)を1本にすると、通知を黙らせる為に検出ごと
# 止める事になる。検出は常に走らせ、鳴らし方だけをここで絞る。
#
# 鳴らし方の規約(この repo が繰り返し踏んだ型を避ける):
#   ・固まっている**間ずっと**鳴らさない。一度鳴らしたら $EVERY 秒は黙る
#     (10 分毎に同じ事を言う見張りは、経路ごと黙らされて次に本当に要る時に届かない)。
#   ・直った時に1回鳴らす(「まだ壊れているのか」を人に確かめさせない)。
#   ・監視自体が壊れた(rc=3)時も鳴らす。**沈黙と正常を同じ顔にしない**。
#   ・10/11(まだ出来ていないだけ)は鳴らさない。異常ではないと台本が明言している。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH="${RC_PHONE_HEALTH:-$HERE/phone-window-health.sh}"
STATE="${RC_PHONE_NOTIFY_STATE:-$HOME/.rc-backend/phone-window-notify.json}"
NOTIFY="${RC_PHONE_NOTIFY_BIN:-$HOME/bin/discord-notify.sh}"
EVERY="${RC_PHONE_NOTIFY_EVERY_S:-21600}"
DRY="${RC_PHONE_NOTIFY_DRY:-0}"

out="$(/bin/bash "$HEALTH" 2>&1)"; rc=$?
now=$(date +%s)
mkdir -p "$(dirname "$STATE")" 2>/dev/null || exit 3

read -r prev last <<<"$(/usr/bin/python3 - "$STATE" <<'PY' 2>/dev/null || echo "ok 0"
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print(d.get("last","ok"), int(d.get("at",0) or 0))
PY
)"

case "$rc" in
    0)  cur=ok ;;
    1)  cur=wedged ;;
    3)  cur=broken ;;
    *)  cur=pending ;;   # 10/11 = まだ出来ていないだけ
esac

say() { [ "$DRY" = 1 ] && { printf 'WOULD-NOTIFY: %s\n' "$1"; return 0; }
        [ -x "$NOTIFY" ] && "$NOTIFY" "$1" >/dev/null 2>&1; }

# ★窓を作った直後は「作られた < まだ登録していない」の一瞬が必ず在る(Codex 2026-08-26)。
#   最初の1回で鳴らすと、正常な起動のたびに偽の警報が出て、本物が埋もれる。
#   2回続けて同じ異常を見てから鳴らす(= 少なくとも1周期は待つ)。
streak="$(/usr/bin/python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print(int(d.get('streak',0) or 0))" "$STATE" 2>/dev/null || echo 0)"
if [ "$cur" = "$prev" ]; then streak=$(( streak + 1 )); else streak=1; fi

fire=0
if [ "$cur" != "$prev" ] && [ "$cur" = "ok" ]; then
    fire=1                                   # 直った = すぐ言う(待たせる理由が無い)
elif [ "$cur" != "ok" ] && [ "$cur" != "pending" ] && [ "$streak" -eq 2 ]; then
    fire=1                                   # 2回続けて異常 = 初めて言う
elif [ "$cur" != "ok" ] && [ "$cur" != "pending" ] && [ "$streak" -gt 2 ] && [ $(( now - last )) -ge "$EVERY" ]; then
    fire=1                                   # 続いている = たまに思い出させる
fi

if [ "$fire" = 1 ]; then
    case "$cur" in
      wedged) say "電話の窓が固まっています(登録に届いていない = 一覧に出ません)。画面:
$(printf '%s' "$out" | tail -8)" ;;
      broken) say "電話の窓の見張り自体が壊れています(rc=3)。これは『異常なし』ではありません。
$(printf '%s' "$out" | tail -4)" ;;
      ok)     [ "$prev" = wedged ] || [ "$prev" = broken ] && say "電話の窓が戻りました。" ;;
    esac
fi

# 状態・連続回数は**毎回**書く(鳴らした時だけ書くと streak が育たず、2回目が永久に来ない)
/usr/bin/python3 -c "
import json,sys,os,tempfile
p,c,t,st,fired,prev_at = sys.argv[1:7]
at = int(t) if fired == '1' else int(prev_at)
fd,tmp = tempfile.mkstemp(dir=os.path.dirname(p)); os.close(fd)
open(tmp,'w').write(json.dumps({'last':c,'at':at,'streak':int(st)}))
os.replace(tmp,p)" "$STATE" "$cur" "$now" "$streak" "$fire" "$last"

printf '%s\n' "$out"
exit "$rc"
