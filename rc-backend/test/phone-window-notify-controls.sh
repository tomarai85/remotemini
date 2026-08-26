#!/bin/bash
# controls-for: tools/phone-window-notify.sh
#
# ★守る一線: **鳴らし過ぎと鳴らな過ぎを両方**捕まえる。
#   偽の health(終了コードを指定できる)を差し替えて、状態遷移ごとに何が起きるか見る。
#   通知は撃たれた回数だけ数える(本物の Discord には触らない)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$ROOT/tools/phone-window-notify.sh"
pass=0; fail=0
ok(){ printf '  OK   %s\n' "$1"; pass=$((pass+1)); }
ng(){ printf '  ★NG  %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
mkdir -p "$D/home/.rc-backend"
# ★1回の呼び出し = 1行。通知文は複数行なので、文を数えると1通が複数に化ける
#   (この対照の最初の版が実際にそれで偽の赤を出した)。呼ばれた回数と本文は別に持つ。
printf '#!/bin/bash\necho CALL >> "%s/n"\nprintf "%%s\\n" "$*" >> "%s/msg"\n' "$D" "$D" > "$D/notify"
chmod 755 "$D/notify"
fake(){ printf '#!/bin/bash\necho "fake out"\nexit %s\n' "$1" > "$D/h"; chmod 755 "$D/h"; }
# ★`VAR=x "$@" bash ...` と書くと効かない。bash は**展開後の語**を代入と見なさないので、
#   "$@" が RC_...=0 に展開された時点でそれは「代入」ではなく「コマンド名」になる
#   (この対照の最初の版が実際にそれで偽の赤を出した)。env で明示的に渡す。
run(){ env HOME="$D/home" RC_PHONE_HEALTH="$D/h" RC_PHONE_NOTIFY_BIN="$D/notify" \
       RC_PHONE_NOTIFY_STATE="$D/home/.rc-backend/n.json" "$@" bash "$N" >/dev/null 2>&1; }
count(){ [ -f "$D/n" ] && wc -l < "$D/n" | tr -d ' ' || echo 0; }

fake 0; run; [ "$(count)" = 0 ] && ok "N1 健康な時は鳴らさない" || ng "N1" "鳴った"

fake 1; run; c0=$(count)
[ "$c0" = 0 ] && ok "N2a ★1回目では鳴らない(起動直後の一瞬を事件にしない)" || ng "N2a" "count=$c0"
run; c1=$(count)
[ "$c1" = 1 ] && ok "N2 2回続けて固まったら1回鳴る" || ng "N2" "count=$c1"
grep -q "固まって" "$D/msg" && ok "N3 何が起きたかを名指しする" || ng "N3" "文が違う"

run; c2=$(count)
[ "$c2" = "$c1" ] && ok "N4 ★固まっている間ずっと鳴らさない(経路ごと黙らされない為)" || ng "N4" "$c1 -> $c2"

# ★時間が経てば思い出させる(N4 が「二度と鳴らない」ではない事の陰性)
run RC_PHONE_NOTIFY_EVERY_S=0; c3=$(count)
[ "$c3" -gt "$c2" ] && ok "N5 ★間隔を過ぎれば思い出させる(黙りっぱなしにしない)" || ng "N5" "$c2 -> $c3"

fake 0; run; c4=$(count)
[ "$c4" -gt "$c3" ] && ok "N6 直ったら1回鳴る" || ng "N6" "戻りを言わない"
grep -q "戻りました" "$D/msg" && ok "N7 戻りの文が出る" || ng "N7" "文が違う"

run; c5=$(count)
[ "$c5" = "$c4" ] && ok "N8 健康が続く間は黙る" || ng "N8" "鳴り続ける"

fake 3; run; run; c6=$(count)
[ "$c6" -gt "$c5" ] && ok "N9 ★見張り自体が壊れた時も鳴る(沈黙と正常を同じ顔にしない)" || ng "N9" "黙った"
grep -q "異常なし" "$D/msg" && ok "N10 その旨を明言する" || ng "N10" "文が無い"

fake 0; run
fake 10; run; c7=$(count)
fake 11; run; c8=$(count)
[ "$c8" = "$c7" ] && ok "N11 ★まだ出来ていないだけ(10/11)では鳴らさない" || ng "N11" "鳴った"

fake 1
env HOME="$D/home" RC_PHONE_HEALTH="$D/h" RC_PHONE_NOTIFY_BIN="$D/notify" \
  RC_PHONE_NOTIFY_STATE="$D/home/.rc-backend/dry.json" RC_PHONE_NOTIFY_DRY=1 bash "$N" >/dev/null 2>&1
out="$(HOME="$D/home" RC_PHONE_HEALTH="$D/h" RC_PHONE_NOTIFY_BIN="$D/notify" \
  RC_PHONE_NOTIFY_STATE="$D/home/.rc-backend/dry.json" RC_PHONE_NOTIFY_DRY=1 bash "$N" 2>&1)"
printf '%s' "$out" | grep -q "WOULD-NOTIFY" && ok "N12 dry では撃たずに文面を出す" || ng "N12" "dry が効かない"

echo "--- 合計: PASS $pass / FAIL $fail ---"
exit $(( fail > 0 ))
