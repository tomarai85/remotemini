#!/usr/bin/env bash
# controls-for: tools/ota-server.mjs
#
# 此の配信には**認証が無い**(iOS の installd は header を送らない)。だから守っているのは
# 「秘密の一段」「一覧を出さない」「ROOT の外へ出られない」の3つだけで、
# 其の3つが本当に効いているかを毎回実測する。効いていない配信は、
# Tom の tailnet に居る全機体(2026-08-28 時点で edith を含む)へ束を開けている事になる。
#
# ★否定の対照を主にする。200 が返る事は必要条件でしかない。
#
# 終了コード: 0=全部緑 / 1=赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/ota-server.mjs"
NODE="${NODE_BIN:-node}"
PORT="${OTA_TEST_PORT:-18799}"

T=$(mktemp -d -t ota-controls)
ROOT="$T/ota"
mkdir -p "$ROOT/s3cret"
printf 'MANIFEST\n' > "$ROOT/s3cret/manifest.plist"
printf 'IPABYTES\n' > "$ROOT/s3cret/RemoteMini.ipa"
printf '<h1>install</h1>\n' > "$ROOT/s3cret/index.html"
# ROOT の**外**に置いた餌。此処が読めたら traversal が通っている。
printf 'TOPSECRET\n' > "$T/outside.txt"
# 接頭辞が同じ別の dir。`startsWith(ROOT)` だけの判定はこれを通してしまう。
mkdir -p "$T/ota-evil"; printf 'EVIL\n' > "$T/ota-evil/x.txt"

PASS=0; FAIL=0
ok() { printf '  OK   %s\n' "$1"; PASS=$((PASS+1)); }
ng() { printf '  NG   %s\n' "$1"; FAIL=$((FAIL+1)); }

OTA_ROOT="$ROOT" OTA_PORT="$PORT" "$NODE" "$SUT" > "$T/server.log" 2>&1 &
PID=$!
# ★`wait` で回収してから畳む(2026-08-30)。`kill` の stderr は既に捨てているが、
# **`Terminated: 15` を出すのは kill ではなく shell** —— 殺した背景ジョブを終了時に
# 回収する時に出す通知で、これが出力の**最後の行**になる。
# 門(`staged-controls-gate.sh`)の要約は最後の行を拾うので、一覧には
# 「GREEN 1s <Terminated…>」と出ていた = **15件測った事と落ちた事が読者から区別できない**。
# `wait` で先に回収すれば通知が出ず、最後の行が `ota-server-controls: OK n / NG m` になる。
cleanup() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

for _ in $(seq 1 40); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/s3cret/manifest.plist" && break
    sleep 0.25
done

# ★`--path-as-is` が要る(2026-08-28、嘘の緑を1本掴んで判った)。
#   curl は既定で URL の `..` を**送る前に**畳む。だから `/../outside.txt` は
#   `/outside.txt` になってサーバへ届き、ROOT に無いので 404 —— 守りが1行も
#   効いていなくても緑が出る。実際に守りを素朴な startsWith へ落とす変異を当てても
#   15 本全部緑のままだった。生の `..` を届かせて初めて測っている事になる。
code() { curl -s --path-as-is -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null; }
body() { curl -s --path-as-is --max-time 5 "$@" 2>/dev/null; }

# --- 本体が配れる(必要条件) --------------------------------------------------
[ "$(code "http://127.0.0.1:$PORT/s3cret/manifest.plist")" = "200" ] \
    && ok "manifest が返る" || ng "manifest が返らない"
[ "$(code "http://127.0.0.1:$PORT/s3cret/RemoteMini.ipa")" = "200" ] \
    && ok "束が返る" || ng "束が返らない"
[ "$(code "http://127.0.0.1:$PORT/s3cret/")" = "200" ] \
    && ok "dir を叩くと index.html が出る" || ng "index.html が出ない"

# --- N1 一覧を返さない --------------------------------------------------------
b=$(body "http://127.0.0.1:$PORT/")
if printf '%s' "$b" | grep -q "s3cret"; then
    ng "N1 ROOT が中身を一覧した = 秘密の一段が無意味になる"
else
    ok "N1 ROOT は一覧を返さない"
fi

# --- N2 ROOT の外へ出られない -------------------------------------------------
for p in "/../outside.txt" "/s3cret/../../outside.txt" "/%2e%2e/outside.txt" "/..%2foutside.txt"; do
    b=$(body "http://127.0.0.1:$PORT$p")
    if printf '%s' "$b" | grep -q "TOPSECRET"; then
        ng "N2 traversal が通った: $p"
    else
        ok "N2 traversal を弾く: $p"
    fi
done

# --- N3 接頭辞が同じ隣の dir へ出られない -------------------------------------
# ★`real.startsWith(ROOT)` だけで判定すると此処が通る。区切りまで見ているかの検査。
b=$(body "http://127.0.0.1:$PORT/../ota-evil/x.txt")
if printf '%s' "$b" | grep -q "EVIL"; then
    ng "N3 接頭辞が同じ隣の dir が読めた(ota → ota-evil)"
else
    ok "N3 接頭辞が同じ隣の dir を弾く"
fi

# --- N4 symlink で外へ出られない ----------------------------------------------
ln -s "$T/outside.txt" "$ROOT/s3cret/link.txt" 2>/dev/null || true
b=$(body "http://127.0.0.1:$PORT/s3cret/link.txt")
if printf '%s' "$b" | grep -q "TOPSECRET"; then
    ng "N4 symlink で ROOT の外が読めた"
else
    ok "N4 symlink で外へ出られない"
fi

# --- N5 書き込みの口が無い ----------------------------------------------------
for m in POST PUT DELETE; do
    c=$(code -X "$m" "http://127.0.0.1:$PORT/s3cret/manifest.plist")
    [ "$c" = "405" ] && ok "N5 $m は 405" || ng "N5 $m が $c(405 でない)"
done

# --- N6 外の網に listen していない --------------------------------------------
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -qv "127.0.0.1:$PORT"; then
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -q "\*:$PORT"; then
        ng "N6 全ての面に listen している = tailnet 限定が効かない"
    else
        ok "N6 127.0.0.1 だけに listen"
    fi
else
    ok "N6 127.0.0.1 だけに listen"
fi

# --- 型 -----------------------------------------------------------------------
ct=$(curl -s -o /dev/null -w '%{content_type}' --max-time 5 "http://127.0.0.1:$PORT/s3cret/RemoteMini.ipa")
[ "$ct" = "application/octet-stream" ] && ok "束の型が octet-stream" || ng "束の型が $ct"

# --- N7 読めない file が**配布口を殺さない** -----------------------------------
# ★2026-08-30、実測で落とした。`stream.pipe(res)` は読み手のエラーを転送せず、
#   `error` に聞き手が居なければ Node は投げる = プロセスごと終了。
#   `statSync` は読み権限を要らないので、stat が通っても `open` は落ちうる。
#   落ちた後は**正常な file も配れない**(接続すら出来ず curl は 000)。
#   同じ形は stat と open の間に file が消えた時、そして `EMFILE`(= 連打)でも来る。
# ★測るのは3つ: 落ちない / その要求は 404 になる / **その後も配れる**。
#   3つ目が要る —— 「404 が返った」だけでは、次の要求で死んでいても気付けない。
printf 'LOCKED\n' > "$ROOT/s3cret/locked.ipa"
chmod 000 "$ROOT/s3cret/locked.ipa"
c_locked=$(code "http://127.0.0.1:$PORT/s3cret/locked.ipa")
sleep 0.4
srv_alive=no; kill -0 "$PID" 2>/dev/null && srv_alive=yes
c_after=$(code "http://127.0.0.1:$PORT/s3cret/manifest.plist")
chmod 644 "$ROOT/s3cret/locked.ipa"
[ "$srv_alive" = "yes" ] && ok "N7 読めない file を叩いても配布口が生きている" \
                         || ng "N7 読めない file で配布口が死んだ(この1本で全配布が止まる)"
[ "$c_locked" = "404" ] && ok "N7b 読めない file は 404(嘘の 200 を出さない)" \
                        || ng "N7b 読めない file の応答が $c_locked"
[ "$c_after" = "200" ]  && ok "N7c その後も正常な file を配れる" \
                        || ng "N7c 読めない file の後、正常な file が $c_after"

# --- N8 連打を断る / ただし**本物の導入は絶対に止めない** ----------------------
# ★此の口には認証を付けられない(iOS の installd は独自の header を送らない)ので、
#   tailnet に居る誰でも叩ける。DESIGN §12 が「log の上限では押さえられない物」として
#   名指ししていたのが此処 —— 上限は暴走の**跡**を縛るだけで、暴走そのものは止めない。
#
# ★測る順が大事: **止まらない事**を先に測る。「429 が出る」だけを測る検査は、
#   限界を 1 に落とした実装でも緑になる —— そして其の実装は Tom の導入を殺す。
STAMP="$(date +%s)"
FLOOD_ROOT="$T/flood"; mkdir -p "$FLOOD_ROOT/s3cret"
printf 'MANIFEST\n' > "$FLOOD_ROOT/s3cret/manifest.plist"
printf 'IPABYTES\n' > "$FLOOD_ROOT/s3cret/RemoteMini.ipa"
printf '<h1>install</h1>\n' > "$FLOOD_ROOT/s3cret/index.html"

start_flood_srv() {  # $1 = OTA_RATE_PER_MIN
    OTA_ROOT="$FLOOD_ROOT" OTA_PORT="$FLOOD_PORT" OTA_RATE_PER_MIN="$1" "$NODE" "$SUT" > "$T/flood.log" 2>&1 &
    FPID=$!
    for _ in $(seq 1 40); do
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$FLOOD_PORT/s3cret/manifest.plist" && break
        sleep 0.25
    done
}
stop_flood_srv() { kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null; }
FLOOD_PORT="${OTA_FLOOD_PORT:-18797}"

# (a) 本物の導入の形。頁 -> manifest -> 束 を3周(installd の再試行を含んだ多めの見積り)。
start_flood_srv 120
install_codes=""
for _ in 1 2 3; do
    for f in "" "manifest.plist" "RemoteMini.ipa"; do
        install_codes="$install_codes$(code "http://127.0.0.1:$FLOOD_PORT/s3cret/$f") "
    done
done
stop_flood_srv
if printf '%s' "$install_codes" | grep -q "429"; then
    ng "N8 本物の導入(9 要求)が既定の限界で止まった" "$install_codes"
else
    ok "N8 本物の導入(9 要求 = 頁/manifest/束 を3周)は既定 120/分で1つも止まらない"
fi

# (b) 連打は断る。★限界を低く差して測る —— 本物の 120 を超える連打を打つのは
#     検査としては遅いだけで、測っている物は同じ。
start_flood_srv 10
n429=0; n200=0
for _ in $(seq 1 25); do
    c="$(code "http://127.0.0.1:$FLOOD_PORT/s3cret/manifest.plist")"
    [ "$c" = "429" ] && n429=$((n429+1))
    [ "$c" = "200" ] && n200=$((n200+1))
done
srv_alive=no; kill -0 "$FPID" 2>/dev/null && srv_alive=yes
stop_flood_srv
[ "$n429" -ge 1 ] && ok "N8b 限界を超えたら 429 を返す(200=$n200 / 429=$n429)" \
                  || ng "N8b 連打を断る" "429 が1つも出ない(200=$n200)"
# ★限界 10 に対して期待は **9**。`start_flood_srv` の起動待ちの probe が1枠使うから ——
#   対照は自分が使った分を勘定に入れる。初版は 10 を期待して赤くなり、
#   其れは限流の欠陥ではなく**此の検査が自分の足跡を数えていなかった**だけだった。
[ "$n200" -ge 9 ] && ok "N8c 限界(10)まで通す。起動待ちの probe が1枠使うので残り 9(実測 $n200)" \
                  || ng "N8c 限界までは通す" "200=$n200(9 未満 = 先頭から断っている)"
[ "$srv_alive" = "yes" ] && ok "N8d 連打の後も配布口が生きている" \
                         || ng "N8d 連打で配布口が死んだ" "限流が落とすなら守りになっていない"

# (c) 断る判定が**読み方の判定より前**に居る。無い path の連打も断られる事で測る ——
#     後ろに居ると、断る為の仕事(path 解決・stat)がそのまま攻撃者の欲しい仕事になる。
start_flood_srv 5
miss429=0
for _ in $(seq 1 15); do
    [ "$(code "http://127.0.0.1:$FLOOD_PORT/s3cret/no-such-file")" = "429" ] && miss429=$((miss429+1))
done
stop_flood_srv
[ "$miss429" -ge 1 ] && ok "N8e 無い path の連打も断る(判定が path 解決より前に居る)" \
                     || ng "N8e 判定の位置" "404 を返し続けた = 解決してから断っている"

# (d) ★`X-Forwarded-For` の**先頭を回すだけで素通りできない**事。
#   此の口は 127.0.0.1 にしか listen せず、唯一の入口は `tailscale serve` の代理なので、
#   相手は socket からは判らない(実測 2026-08-30: 本番の tailnet 経路で `peer=xff`)。
#   だが XFF は**客が自分で付けられる** —— 先頭を鍵にすると header を回すだけで
#   鍵が毎回変わり、限流が丸ごと無効になる。信頼できる代理が1段なら
#   **自分に一番近い末尾**が其の代理の書いた値で、客には書き換えられない。
#   ★変異(先頭を鍵に戻す)で実測: 20 回中 **429 が 0** = 完全に素通りできていた。
start_flood_srv 5
spoof429=0
for i in $(seq 1 20); do
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
         -H "X-Forwarded-For: 10.0.0.$i, 10.0.0.0" \
         "http://127.0.0.1:$FLOOD_PORT/s3cret/manifest.plist" 2>/dev/null)"
    [ "$c" = "429" ] && spoof429=$((spoof429+1))
done
stop_flood_srv
[ "$spoof429" -ge 1 ] && ok "N8f XFF の先頭を回しても素通りできない(末尾の hop を鍵にしている / 429=$spoof429)" \
                      || ng "N8f XFF 偽装で素通り" "429 が0件 = 先頭を鍵にしている(header を回すだけで限流が消える)"

# --- N9 資源を縛る(要求数だけでは足りない)------------------------------------
# ★2026-08-30、Codex の指摘2。限界 120/分は「1分に何回来られるか」でしかない。
#   120 本の束 GET を**同時に**張られると socket と file stream が 120 本開き、
#   しかも socket の timeout は**無活動**でしか切れないので、少しずつ読み続ければ
#   延々と保持できる。次の窓でさらに 120 本足せる = `EMFILE` で**持ち主まで巻き込める**。
#   だから重い方(束)だけ、同時本数と絶対の期限で別に縛る。
# ★測る順は N8 と同じ: **本物の導入が死なない**事を一緒に測る。
#   束の枠が埋まっている最中でも manifest は取れないといけない。
N9ROOT="$T/n9"; mkdir -p "$N9ROOT/s"
head -c 3000000 /dev/urandom > "$N9ROOT/s/RemoteMini.ipa"
printf 'MANIFEST\n' > "$N9ROOT/s/manifest.plist"
N9PORT="${OTA_N9_PORT:-18795}"
OTA_ROOT="$N9ROOT" OTA_PORT="$N9PORT" OTA_MAX_INFLIGHT_IPA=2 "$NODE" "$SUT" > "$T/n9.log" 2>&1 &
N9PID=$!
for _ in $(seq 1 40); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$N9PORT/s/manifest.plist" && break
    sleep 0.25
done

: > "$T/n9codes"
# ★`wait` を**引数なしで書かない**(2026-08-30、書いて固まった)。引数なしの `wait` は
#   此の shell の子を**全部**待つので、上で常駐させている検査用サーバ($PID / $N9PID)まで
#   待ち、永久に返らない。掴んだ curl の pid だけを待つ。
n9pids=""
for _ in 1 2 3 4 5 6; do
    ( curl -s -o /dev/null --limit-rate 20k --max-time 25 -w '%{http_code}\n' \
        "http://127.0.0.1:$N9PORT/s/RemoteMini.ipa" >> "$T/n9codes" 2>/dev/null ) &
    n9pids="$n9pids $!"
done
sleep 4
c_man="$(code "http://127.0.0.1:$N9PORT/s/manifest.plist")"
for pid in $n9pids; do wait "$pid" 2>/dev/null; done
n503=$(grep -c '^503' "$T/n9codes" 2>/dev/null || echo 0)
n200=$(grep -c '^200' "$T/n9codes" 2>/dev/null || echo 0)
c_after="$(code "http://127.0.0.1:$N9PORT/s/RemoteMini.ipa")"
kill "$N9PID" 2>/dev/null; wait "$N9PID" 2>/dev/null

[ "$n200" -le 2 ] && [ "$n503" -ge 1 ] \
  && ok "N9 束の同時転送が上限(2)で頭打ちになる(200=$n200 / 503=$n503)" \
  || ng "N9 束の同時本数を縛る" "200=$n200 / 503=$n503(上限が効いていない)"
[ "$c_man" = "200" ] \
  && ok "N9b 束の枠が埋まっている最中でも manifest は返る(本物の導入を殺さない)" \
  || ng "N9b 枠が埋まった時の manifest" "$c_man"
[ "$c_after" = "200" ] \
  && ok "N9c 転送が終われば席が返る(守りが詰まりに化けない)" \
  || ng "N9c 席が返らない" "$c_after = 数回叩かれただけで以後誰も束を取れない"

# --- N10 限界の値そのものが壊れていたら起動しない ------------------------------
# ★`Number()` は `NaN` も `Infinity` も通す。どちらでも `arr.length >= RATE_PER_MIN` が
#   永遠に偽になり、限流が**黙って消えた上に**時刻の配列が無限に伸びる ——
#   守りが消えるだけでなく、守りの器がそのまま漏れになる。fail-closed に倒す。
n10bad=0
for bad in abc Infinity 0 -5; do
    if OTA_RATE_PER_MIN="$bad" OTA_ROOT="$N9ROOT" OTA_PORT="$N9PORT" "$NODE" "$SUT" >/dev/null 2>&1; then
        ng "N10 壊れた限界値($bad)で起動した" "限流が黙って消える"
        n10bad=1
    fi
done
[ "$n10bad" -eq 0 ] && ok "N10 限界値が正の整数でなければ起動しない(abc / Infinity / 0 / 負)"

echo
echo "ota-server-controls: OK $PASS / NG $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
