#!/bin/bash
# controls-for: tools/tunnel-observer.sh
# tunnel-observer-control.sh — 観測者が **「私が届かない」を「相手が死んだ」と言わない**事を測る。
# 2026-08-27 新設。
#
# なぜ要るか(実測)
#   この観測者は Tom が持ち歩く機体(Jervis)の上で走る。回線が不定期に落ちるのは**仕様**で、
#   実測では 2026-08-26 の 14:00-20:20 に **186 FAIL / 178 OK** —— ほぼ半分の時間 自分の
#   回線が死んでいた。閾値 3 回はそんな窓では容易に達する。
#   その時に鳴るのは「相手が死んだ」ではなく「**私が届かない**」で、別の事実。
#
# ★**片方だけの対照は必ず騙される**(Codex 2026-08-27):
#   偽陽性だけ測る → **何も鳴らさない実装**で緑。
#   偽陰性だけ測る → **何でも鳴らす実装**で緑。
#   だから両方測る —— 回線が死んでいる時に 0 通、生きている時に 1 通。
#
# ★偽 curl で駆動する。本物の外部へも本物の Discord へも出さない。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBS="$HERE/tunnel-observer.sh"
[ -f "$OBS" ] || { echo "★$OBS が無い"; exit 2; }

fail=0; reds=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- 偽 curl: 相手(トンネル)と 自分の確認先(外部)を別々に演じる -------------------
# `RC_TUNNEL_TARGET_OK` / `RC_TUNNEL_SELF_OK` の2つで挙動を決める。
# ★健康な本文は **ok/pid/uptime/version を4つとも**持つ。観測者は4つとも検めるので、
#   偽物が欠けていると『健康な相手』を作れず、実装が正しくても赤になる
#   (2026-08-27 実測。**偽物は本番に在る形を全部持つ**)。
cat >"$TMP/curl" <<'STUB'
#!/bin/bash
u=""
for a in "$@"; do case "$a" in http*) u="$a" ;; esac; done
case "$u" in
    *tunnel-target*)
        if [ "${RC_TUNNEL_TARGET_OK:-0}" = "1" ]; then
            printf '{"ok":true,"pid":123,"uptime":42,"version":"abc1234"}\n200'; exit 0
        fi
        exit 7 ;;
    *)
        # 自分の回線の確認先(tailnet の外)
        [ "${RC_TUNNEL_SELF_OK:-1}" = "1" ] && exit 0
        exit 7 ;;
esac
STUB
chmod +x "$TMP/curl"

cat >"$TMP/notify" <<STUB2
#!/bin/bash
if [ "\$#" -ge 1 ]; then M="\$*"; else M="\$(cat)"; fi
printf '%s\n' "\$M" >> "$TMP/notified"
STUB2
chmod +x "$TMP/notify"

run_obs() { # $1 = 相手が生きているか(0/1)、$2 = 自分の回線が生きているか(0/1)
    env PATH="$TMP:$PATH" \
        RC_TUNNEL_TARGET_OK="$1" RC_TUNNEL_SELF_OK="$2" \
        RC_TUNNEL_URL="https://tunnel-target.invalid/healthz" \
        RC_TUNNEL_SELF_URLS="https://self-probe-a.invalid/ https://self-probe-b.invalid/" \
        RC_TUNNEL_STATE="$TMP/state.json" \
        RC_TUNNEL_LOG="$TMP/obs.log" \
        RC_TUNNEL_NOTIFY="$TMP/notify" \
        RC_TUNNEL_LOCK="$TMP/state.json.lock" \
        RC_TUNNEL_OFFLINE_MARK="$TMP/offline.mark" \
        RC_TUNNEL_THRESHOLD=3 \
        /bin/bash "$OBS" </dev/null >/dev/null 2>&1
}
# ★数は**1つの経路**で出す。`&& ... || printf 0` は前半が成功しても後半が走る形に
#   なり得て、`00` の様な値が返る(2026-08-27 実測。今日この型は3件目)。
n_notified() {
    if [ -s "$TMP/notified" ]; then
        grep -c . "$TMP/notified" 2>/dev/null | head -1 | tr -dc 0-9
    else
        printf '0'
    fi
}
reset_all() { rm -f "$TMP/state.json" "$TMP/notified" "$TMP/offline.mark" "$TMP/obs.log"; : > "$TMP/notified"; }

echo "=== 1. ★自分の回線が落ちている時、閾値に達しても鳴らない[偽陽性の負] ==="
reset_all
run_obs 0 0; run_obs 0 0; run_obs 0 0
reds=$((reds + 1))
if [ "$(n_notified)" = "0" ]; then
    printf '  0 通(「私が届かない」を「相手が死んだ」と言っていない)  OK\n'
    [ -f "$TMP/offline.mark" ] && printf '  観測者が落ちていた事を記録している  OK\n' \
        || { printf '  ★記録が無い(後で戻った時に鳴らせない)\n'; fail=1; }
else
    printf '  ★%s 通 鳴った(狼を叫んでいる)\n' "$(n_notified)"; fail=1
fi

echo "=== 2. ★自分の回線が生きていて相手が死んでいる時、1 通鳴る[偽陰性の負] ==="
reset_all
run_obs 0 1; run_obs 0 1; run_obs 0 1
reds=$((reds + 1))
if [ "$(n_notified)" = "1" ]; then
    printf '  1 通(本物の障害を握り潰していない)  OK\n'
else
    printf '  ★%s 通(期待 1。抑えすぎ または 鳴らしすぎ)\n' "$(n_notified)"; fail=1
fi

echo "=== 3. ★自分が落ちている間に相手も死んでいた場合、回線が戻ったら鳴る ==="
reset_all
run_obs 0 0; run_obs 0 0; run_obs 0 0     # 自分が落ちている間に閾値へ達する
[ "$(n_notified)" = "0" ] || { printf '  ★前提が作れていない(此処で鳴っている)\n'; fail=1; }
run_obs 0 1                                # 回線が戻ったが相手はまだ死んでいる
reds=$((reds + 1))
if [ "$(n_notified)" = "1" ]; then
    printf '  戻った回に鳴る(取り逃がさない)  OK\n'
else
    printf '  ★%s 通(期待 1。自分が落ちている間の障害を永久に取り逃がす)\n' "$(n_notified)"; fail=1
fi

echo "=== 4. 相手が生きていれば何も鳴らない[過剰発火の負] ==="
reset_all
run_obs 1 1; run_obs 1 1; run_obs 1 1
if [ "$(n_notified)" = "0" ]; then
    printf '  0 通  OK\n'
else
    printf '  ★健康なのに %s 通\n' "$(n_notified)"; fail=1
fi

echo "=== 5. 自分の回線を確かめられない(unknown)時は黙らない ==="
# 確認先を1つも渡さない = 確かめる術が無い。**「生きている」に倒さない**が、
# 相手に届かない事実は事実なので鳴らす(文面に未確認と書く)。
reset_all
env PATH="$TMP:$PATH" RC_TUNNEL_TARGET_OK=0 \
    RC_TUNNEL_URL="https://tunnel-target.invalid/healthz" \
    RC_TUNNEL_SELF_URLS="" \
    RC_TUNNEL_STATE="$TMP/state.json" RC_TUNNEL_LOG="$TMP/obs.log" \
    RC_TUNNEL_NOTIFY="$TMP/notify" RC_TUNNEL_LOCK="$TMP/state.json.lock" \
    RC_TUNNEL_OFFLINE_MARK="$TMP/offline.mark" RC_TUNNEL_THRESHOLD=1 \
    /bin/bash "$OBS" </dev/null >/dev/null 2>&1
if [ "$(n_notified)" = "1" ] && grep -q "未確認" "$TMP/notified" 2>/dev/null; then
    printf '  鳴る + 文面に「未確認」が在る  OK\n'
else
    printf '  ★%s 通 / 文面: %s\n' "$(n_notified)" "$(head -1 "$TMP/notified" 2>/dev/null)"; fail=1
fi

echo
echo "  赤に倒れる入力: ${reds} 件"
[ "$reds" -lt 2 ] && { echo "  ★対照が空虚"; fail=1; }
echo
[ "$fail" = 0 ] && { echo "全ケース OK"; exit 0; } || { echo "★赤あり"; exit 1; }
