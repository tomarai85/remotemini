#!/bin/bash
# controls-for: rc-backend/tools/tunnel-observer.sh
#
# ★この対照が守る一線: **緑しか出せない計器を緑と読まない**。
#   だから測るのは「生きている時に 0 を返す」ではなく、
#   死んだ時 / 遅い時 / 状態が古い時 / 一度も走っていない時に**別々の顔**をするか。
#   本物のトンネルには一切触らない(偽のサーバと偽の状態で回す)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS="$ROOT/tools/tunnel-observer.sh"
pass=0; fail=0
ok(){ printf '  OK   %s\n' "$1"; pass=$((pass+1)); }
ng(){ printf '  ★NG  %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

D="$(mktemp -d)"; trap 'kill %1 2>/dev/null; rm -rf "$D"' EXIT
mkdir -p "$D/home/.rc-backend" "$D/bin"
# 通知は撃たれた事だけ記録する偽物
printf '#!/bin/bash\necho "$*" >> "%s/notified"\n' "$D" > "$D/bin/notify"; chmod 755 "$D/bin/notify"

env_for() { # <url>
    echo "HOME=$D/home RC_TUNNEL_URL=$1 RC_TUNNEL_STATE=$D/home/.rc-backend/tunnel-state.json"
}

# --- 一度も走っていない時 ------------------------------------------------------
out="$(HOME=$D/home RC_TUNNEL_STATE=$D/home/.rc-backend/none.json bash "$OBS" --report 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "T1 一度も測っていない時は rc=3(異常なしと言わない)" || ng "T1" "rc=$rc"
printf '%s' "$out" | grep -q "異常なし" && ok "T2 その旨を文で名指しする" || ng "T2" "文が無い"

# --- 生きている時 --------------------------------------------------------------
PORT=$(( 20000 + RANDOM % 20000 ))
/usr/bin/python3 -c "
import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s): s.send_response(200); s.end_headers(); s.wfile.write(b'{\"ok\":true,\"pid\":1,\"uptime\":5,\"version\":\"abc1234\"}')
    def log_message(*a): pass
http.server.HTTPServer(('127.0.0.1',$PORT),H).serve_forever()" &
sleep 1
S="$D/home/.rc-backend/t.json"
HOME=$D/home RC_TUNNEL_STATE=$S RC_TUNNEL_URL="http://127.0.0.1:$PORT/healthz" \
  RC_TUNNEL_NOTIFY="$D/bin/notify" bash "$OBS" >/dev/null 2>&1
[ $? -eq 0 ] && ok "T3 200 なら 0" || ng "T3" "非零"
python3 -c "import json;d=json.load(open('$S'));exit(0 if d['status']=='up' and d['fails']==0 else 1)" \
  && ok "T4 状態に up が残る" || ng "T4" "状態が違う"
kill %1 2>/dev/null; sleep 1
# ★T5/T6 は「3回連続で失敗したら 3」を測る。前段の結果を持ち越すと数が合わない。
rm -f "$S"

# --- 死んだ時(サーバを落とした)-----------------------------------------------
for i in 1 2 3; do
  HOME=$D/home RC_TUNNEL_STATE=$S RC_TUNNEL_URL="http://127.0.0.1:$PORT/healthz" \
    RC_TUNNEL_NOTIFY="$D/bin/notify" RC_TUNNEL_TIMEOUT=2 bash "$OBS" >/dev/null 2>&1
done
[ $? -eq 1 ] && ok "T5 届かなければ 1" || ng "T5" "1 以外"
python3 -c "import json;d=json.load(open('$S'));exit(0 if d['status']=='down' and d['fails']==3 else 1)" \
  && ok "T6 連続失敗が積み上がる" || ng "T6" "fails が違う"
[ -s "$D/notified" ] && ok "T7 ★閾値で実際に鳴る(鳴らない見張りは見張りではない)" || ng "T7" "鳴っていない"
n1=$(wc -l < "$D/notified")
HOME=$D/home RC_TUNNEL_STATE=$S RC_TUNNEL_URL="http://127.0.0.1:$PORT/healthz" \
  RC_TUNNEL_NOTIFY="$D/bin/notify" RC_TUNNEL_TIMEOUT=2 bash "$OBS" >/dev/null 2>&1
n2=$(wc -l < "$D/notified")
[ "$n1" = "$n2" ] && ok "T8 ★超えている間は鳴らし続けない(経路ごと黙らされない為)" || ng "T8" "$n1 -> $n2"

# --- 状態が古い時 --------------------------------------------------------------
python3 -c "
import json;p='$S';d=json.load(open(p));d['status']='up';d['lastRunAt']=1;json.dump(d,open(p,'w'))"
HOME=$D/home RC_TUNNEL_STATE=$S bash "$OBS" --report >/dev/null 2>&1
[ $? -eq 3 ] && ok "T9 ★古い観測を『今 up』と読ませない(rc=3)" || ng "T9" "古くても up と言った"

# --- 陰性: 新しい up はちゃんと 0 -----------------------------------------------
python3 -c "
import json,time;p='$S';d=json.load(open(p));d['status']='up';d['lastRunAt']=int(time.time());json.dump(d,open(p,'w'))"
HOME=$D/home RC_TUNNEL_STATE=$S bash "$OBS" --report >/dev/null 2>&1
[ $? -eq 0 ] && ok "T10 ★陰性: 新しい up は 0(T9 が常に 3 を返す訳ではない)" || ng "T10" "新しくても 3"

# --- 使い方エラー ---------------------------------------------------------------
HOME=$D/home bash "$OBS" --nope >/dev/null 2>&1
[ $? -eq 2 ] && ok "T11 知らない引数は rc=2" || ng "T11" "2 以外"

# ★Codex 2026-08-26 の指摘を1件ずつ赤にできる形にする ------------------------
# 偽サーバを立てる小道具(本文を差し替えられる)
serve_body() { # <port> <http_code> <body>
    /usr/bin/python3 -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response($2); s.send_header('content-type','application/json'); s.end_headers()
        s.wfile.write(b'''$3''')
    def log_message(*a): pass
http.server.HTTPServer(('127.0.0.1',$1),H).serve_forever()" &
    sleep 1
}
probe() { # <port> <state file>
    HOME=$D/home RC_TUNNEL_STATE="$2" RC_TUNNEL_URL="http://127.0.0.1:$1/healthz" \
      RC_TUNNEL_NOTIFY="$D/bin/notify" RC_TUNNEL_TIMEOUT=3 bash "$OBS" >/dev/null 2>&1
}

P2=$(( 20000 + RANDOM % 20000 )); S2="$D/home/.rc-backend/t2.json"
serve_body $P2 200 '{"ok":true,"pid":1,"uptime":5,"version":"abc1234"}'
probe $P2 "$S2"; [ $? -eq 0 ] && ok "T12 正しい本文なら up" || ng "T12" "非零"
kill %1 2>/dev/null; sleep 1

# ★200 を返す「別のサーバ」を緑と読まない
P3=$(( 20000 + RANDOM % 20000 )); S3="$D/home/.rc-backend/t3.json"
serve_body $P3 200 '<html>someone elses service</html>'
probe $P3 "$S3"; [ $? -eq 1 ] && ok "T13 ★200 でも本文が別物なら down(別のサーバを緑にしない)" || ng "T13" "緑にした"
kill %1 2>/dev/null; sleep 1

# ★形は JSON でも ok:false は緑にしない
P4=$(( 20000 + RANDOM % 20000 )); S4="$D/home/.rc-backend/t4.json"
serve_body $P4 200 '{"ok":false,"pid":1,"uptime":5,"version":"x"}'
probe $P4 "$S4"; [ $? -eq 1 ] && ok "T14 ★ok:false を緑にしない" || ng "T14" "緑にした"
kill %1 2>/dev/null; sleep 1

# ★version が空 = 版を名乗れないサーバも緑にしない
P5=$(( 20000 + RANDOM % 20000 )); S5="$D/home/.rc-backend/t5.json"
serve_body $P5 200 '{"ok":true,"pid":1,"uptime":5,"version":""}'
probe $P5 "$S5"; [ $? -eq 1 ] && ok "T15 ★版を名乗れないサーバも緑にしない" || ng "T15" "緑にした"
kill %1 2>/dev/null; sleep 1

# ★観測の空白を事件として鳴らす
P6=$(( 20000 + RANDOM % 20000 )); S6="$D/home/.rc-backend/t6.json"
serve_body $P6 200 '{"ok":true,"pid":1,"uptime":5,"version":"abc1234"}'
probe $P6 "$S6"
python3 -c "
import json,time;p='$S6';d=json.load(open(p));d['lastRunAt']=int(time.time())-99999;json.dump(d,open(p,'w'))"
: > "$D/notified"
probe $P6 "$S6"
grep -q "空白" "$D/notified" && ok "T16 ★観測の空白を鳴らす(寝ていた間を『異常なし』にしない)" || ng "T16" "鳴っていない"
kill %1 2>/dev/null; sleep 1

# ★時計が巻き戻った時に古い観測を新しいと言わない
python3 -c "
import json,time;p='$S6';d=json.load(open(p));d['status']='up';d['lastRunAt']=int(time.time())+99999;json.dump(d,open(p,'w'))"
HOME=$D/home RC_TUNNEL_STATE="$S6" bash "$OBS" --report >/dev/null 2>&1
[ $? -eq 3 ] && ok "T17 ★時計の巻き戻りは『判らない』へ倒す" || ng "T17" "up と言った"

echo "--- 合計: PASS $pass / FAIL $fail ---"
exit $(( fail > 0 ))
