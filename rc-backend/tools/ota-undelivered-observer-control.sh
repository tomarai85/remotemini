#!/bin/bash
# controls-for: tools/ota-undelivered-observer.sh
#
# 「出来ているのに配っていない」を定期に気付く枝の対照。
#
# ★測る中心は「鳴るか」ではなく、**鳴らしてはいけない時に黙るか**。
#   此の枝が扱う `undelivered`(rc=3)は**作業中ほぼ常に真**なので、猶予を外すと
#   毎日鳴る警報になり、本当に配り忘れた日には読まれていない。
#   今日 同じ型を何度も踏んだので、其処を中心に据える。
#
#   U1 ★自分の回線が落ちていれば測らない(記録も通知も無い)
#   U2 ★rc=3 でも猶予の内なら鳴らない
#   U3 ★猶予を跨いだら1回だけ鳴る
#   U4 ★同じ状態が続いても2通目は出ない
#   U5 ★rc=1(巻き戻り)は**猶予なし**で鳴る(唯一の復旧経路が壊れている状態)
#   U6 ★測れない(rc=2)は鳴らさず、**試みた時刻も進めない**(次の tick で再挑戦)
#   U7 ★測れない状態が閾値を越えたら「見えていない」として鳴る(配り忘れとは別)
#   U8 rc=0 は黙る
#   U9 ★言った後に直ったら「戻った」を言う(言っていなければ言わない)
#   U10 ★間隔の内では測り直さない
#   U11 ★`--once` は周期を待たずに本当に測る(名乗りどおり動く)
#   U12 ★呼び手が**早期 exit より前**で呼んでいる(配線されて見えるのに走らない形を塞ぐ)
#   U13 ★見えていなかった時間を『続いた』と数えない(+ 陰性対照 U13b)
#   M1 ★変異: 猶予を外すと U2 が赤くなる
#   M2 ★変異: 回線の判定を外すと U1 が赤くなる
#   Z  台本を書き換えたまま終わらない
#
# 使い方: bash rc-backend/tools/ota-undelivered-observer-control.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # = rc-backend/tools
SUT="$HERE/ota-undelivered-observer.sh"
HOST_OBS="$HERE/tunnel-observer.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
cp "$SUT" "$SB/orig.sh"
restore() { cp -f "$SB/orig.sh" "$SUT"; }

# 偽の鮮度検査。<rc> を返すだけ。
mkchk() { printf '#!/bin/bash\necho "fake out"\nexit %s\n' "$1" > "$2"; chmod +x "$2"; }
NOTIFY="$SB/notify.sh"
printf '#!/bin/bash\ncat >/dev/null\necho x >> "%s"\n' "$SB/notified" > "$NOTIFY"; chmod +x "$NOTIFY"
notices() { [ -f "$SB/notified" ] && wc -l < "$SB/notified" | tr -d ' ' || echo 0; }

# run <状態file> <rc> [自分の回線 rc(既定 0)] [追加 env...]
run() {
    local st="$1" rc="$2" link="${3:-0}"; shift 3 2>/dev/null || shift 2
    mkchk "$rc" "$SB/chk.sh"
    env "$@" RC_OU_STATE="$st" RC_OU_EVERY="${RUN_EVERY:-0}" RC_OU_CHECK="$SB/chk.sh" \
        RC_TUNNEL_NOTIFY="$NOTIFY" RC_TUNNEL_LOG="$SB/o.log" \
        bash -c '
            self_link_state() { return '"$link"'; }
            . "'"$SUT"'"
            undelivered_observe
        ' >/dev/null 2>&1
}
state_of() { cut -d" " -f2 < "$1" 2>/dev/null; }
attempt_of() { cut -d" " -f1 < "$1" 2>/dev/null; }
DAY=86400

# ── U1 回線が落ちていれば測らない ─────────────────────────────────────────
: > "$SB/notified"
run "$SB/u1.json" 3 1
if [ ! -f "$SB/u1.json" ] && [ "$(notices)" = "0" ]; then
    ok "U1 ★自分の回線が落ちていれば測らない(記録も通知も無い)"
else ng "U1 回線が落ちている時" "記録=$(cat "$SB/u1.json" 2>/dev/null) 通知=$(notices)"; fi
: > "$SB/notified"
run "$SB/u1b.json" 3 2
[ ! -f "$SB/u1b.json" ] && ok "U1b 回線が判らない時も測らない" || ng "U1b" "測ってしまった"

# ── U2 猶予の内では鳴らない ───────────────────────────────────────────────
: > "$SB/notified"
run "$SB/u2.json" 3
if [ "$(state_of "$SB/u2.json")" = "undelivered" ] && [ "$(notices)" = "0" ]; then
    ok "U2 ★出来ているのに配っていない(rc=3)でも、猶予の内なら鳴らない"
else ng "U2 早鳴り" "state=$(state_of "$SB/u2.json") 通知=$(notices)"; fi

# ── U3 猶予を跨いだら1回 ─────────────────────────────────────────────────
# `since` を猶予より前へ差して、跨いだ状態を作る。
: > "$SB/notified"
printf '%s undelivered 0 %s %s\n' "$(date +%s)" "$(( $(date +%s) - 3 * DAY ))" "$(date +%s)" > "$SB/u3.json"
run "$SB/u3.json" 3
[ "$(notices)" = "1" ] && ok "U3 ★猶予(2日)を跨いだら1回だけ鳴る" \
                       || ng "U3 猶予越え" "通知=$(notices) 通(1 が期待)"

# ── U4 続いても2通目は出ない ─────────────────────────────────────────────
run "$SB/u3.json" 3
[ "$(notices)" = "1" ] && ok "U4 ★同じ状態が続いても2通目は出ない" \
                       || ng "U4 重複" "通知=$(notices) 通"

# ── U5 巻き戻りは猶予なし ────────────────────────────────────────────────
: > "$SB/notified"
run "$SB/u5.json" 1
if [ "$(state_of "$SB/u5.json")" = "rollback" ] && [ "$(notices)" = "1" ]; then
    ok "U5 ★配布が承認より古い(rc=1)は猶予なしで鳴る"
else ng "U5 巻き戻り" "state=$(state_of "$SB/u5.json") 通知=$(notices)(1 が期待)"; fi

# ── U6 測れない: 鳴らさず、時計も進めない ────────────────────────────────
: > "$SB/notified"
printf '%s ok 0 %s %s\n' "$(( $(date +%s) - 2 * DAY ))" "$(date +%s)" "$(date +%s)" > "$SB/u6.json"
before="$(attempt_of "$SB/u6.json")"
run "$SB/u6.json" 2
after="$(attempt_of "$SB/u6.json")"
if [ "$(notices)" = "0" ] && [ "$before" = "$after" ]; then
    ok "U6 ★測れない回は鳴らさず、試みた時刻も進めない(次の tick で再挑戦)"
else ng "U6 測れない回" "通知=$(notices) 試みた $before → $after"; fi

# ── U7 見えていない事は別に鳴る ──────────────────────────────────────────
: > "$SB/notified"
printf '%s unmeasured 0 %s %s\n' "$(( $(date +%s) - 2 * DAY ))" "$(( $(date +%s) - 4 * DAY ))" "$(( $(date +%s) - 4 * DAY ))" > "$SB/u7.json"
run "$SB/u7.json" 2
[ "$(notices)" = "1" ] && ok "U7 ★測れない状態が閾値を越えたら『見えていない』として鳴る" \
                       || ng "U7 鮮度" "通知=$(notices) 通(1 が期待)= 何日 見えなくても黙ったまま"

# ── U8 rc=0 は黙る ───────────────────────────────────────────────────────
: > "$SB/notified"
run "$SB/u8.json" 0
if [ "$(state_of "$SB/u8.json")" = "ok" ] && [ "$(notices)" = "0" ]; then
    ok "U8 順当(rc=0)なら黙る"
else ng "U8" "state=$(state_of "$SB/u8.json") 通知=$(notices)"; fi

# ── U9 言った後に直ったら戻ったと言う ────────────────────────────────────
: > "$SB/notified"
printf '%s undelivered 1 %s %s\n' "$(date +%s)" "$(( $(date +%s) - 3 * DAY ))" "$(date +%s)" > "$SB/u9.json"
run "$SB/u9.json" 0
[ "$(notices)" = "1" ] && ok "U9 ★言った物が直ったら『戻った』を1回言う" \
                       || ng "U9 復帰" "通知=$(notices) 通(1 が期待)"
# 言っていなければ言わない(陰性対照)。
: > "$SB/notified"
printf '%s undelivered 0 %s %s\n' "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$SB/u9b.json"
run "$SB/u9b.json" 0
[ "$(notices)" = "0" ] && ok "U9b ★言っていない物には『戻った』も言わない" \
                       || ng "U9b" "通知=$(notices) 通(0 が期待)"

# ── U10 間隔の内では測り直さない ─────────────────────────────────────────
printf '%s ok 0 %s %s\n' "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$SB/u10.json"
t1="$(attempt_of "$SB/u10.json")"
RUN_EVERY=999999 run "$SB/u10.json" 3
t2="$(attempt_of "$SB/u10.json")"
[ "$t1" = "$t2" ] && ok "U10 ★間隔の内では測り直さない" || ng "U10 間隔" "$t1 → $t2"

# ── U11 --once は本当に測る ──────────────────────────────────────────────
# ★人と同じ形(`bash "$SUT" --once`)で撃つ。`run` は source 前に env を差すので、
#   `--once` が壊れていても気付けない —— parity 側で実際に其の取り零しを踏んだ。
: > "$SB/notified"
printf '%s ok 0 %s %s\n' "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$SB/u11.json"
mkchk 1 "$SB/chk.sh"
RC_OU_STATE="$SB/u11.json" RC_OU_CHECK="$SB/chk.sh" RC_TUNNEL_NOTIFY="$NOTIFY" \
RC_TUNNEL_LOG="$SB/o.log" bash "$SUT" --once >/dev/null 2>&1
[ "$(state_of "$SB/u11.json")" = "rollback" ] \
    && ok "U11 ★--once は周期を待たずに本当に測る" \
    || ng "U11 --once" "state=$(state_of "$SB/u11.json") = 測らずに帰った"

# ── U12 呼び手が早期 exit より前で呼んでいる ─────────────────────────────
# ★2026-08-31 に parity 側で踏んだ形: 呼び出しを `if up … exit 0` の**後**に置くと、
#   通常は up なので事実上一度も走らない。行番号ではなく**前後関係**で縛る。
if [ -f "$HOST_OBS" ]; then
    call_line="$(grep -n 'undelivered_observe' "$HOST_OBS" | grep -v '^\s*#' | tail -1 | cut -d: -f1)"
    exit_line="$(grep -n 'if \[ "\$st" = up \]' "$HOST_OBS" | head -1 | cut -d: -f1)"
    if [ -n "$call_line" ] && [ -n "$exit_line" ] && [ "$call_line" -lt "$exit_line" ]; then
        ok "U12 ★呼び手は早期 exit($exit_line 行)より前($call_line 行)で呼んでいる"
    else ng "U12 配線の位置" "呼び出し=$call_line / 早期 exit=$exit_line = 落ちている時しか走らない"; fi
fi

# ── U13 ★見えていなかった時間を「続いた」と数えない(Codex 2026-08-31)─────────
# 素通りさせると此の順で誤報が出る:
#   rc=3 で開始 → 2日以上 測れない → 其の間に直って再発 → 次の観測で
#   「3日 続いている」として**即座に鳴る**。壁時計の差は連続性の証拠ではない。
: > "$SB/notified"
NOWE="$(date +%s)"
# since は 4 日前(= 猶予を越えている)だが、**最後に測れたのは 3 日前** = 間が見えていない。
printf '%s undelivered 0 %s %s\n' "$(( NOWE - 3 * DAY ))" "$(( NOWE - 4 * DAY ))" "$(( NOWE - 3 * DAY ))" > "$SB/u13.json"
run "$SB/u13.json" 3
if [ "$(notices)" = "0" ]; then
    ok "U13 ★見えていなかった間を根拠に鳴らない(続いた時間を数え直す)"
else ng "U13 連続性" "通知=$(notices) 通 = 見ていない時間を『続いた』と数えた"; fi
# ★陰性対照: 同じ長さでも**ずっと見えていた**なら鳴る(黙る側へ倒し過ぎていない事)。
: > "$SB/notified"
printf '%s undelivered 0 %s %s\n' "$NOWE" "$(( NOWE - 4 * DAY ))" "$NOWE" > "$SB/u13b.json"
run "$SB/u13b.json" 3
[ "$(notices)" = "1" ] && ok "U13b ★ずっと見えていたなら猶予越えで鳴る(黙り過ぎない)" \
                       || ng "U13b" "通知=$(notices) 通(1 が期待)= 何も鳴らない検査になった"

# ── 変異 ──────────────────────────────────────────────────────────────────
mutate() {
    python3 - "$SUT" "$1" "$2" <<'PY'
import io, sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding="utf-8").read()
if a not in s:
    sys.stderr.write("ANCHOR-MISS\n"); sys.exit(3)
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
}

if mutate '    [ "$state" = "undelivered" ] && grace="$OU_GRACE"' '    grace=0'; then
    : > "$SB/notified"
    run "$SB/m1.json" 3
    [ "$(notices)" != "0" ] && ok "M1 ★猶予を外すと U2 が赤くなる(猶予が本当に効いている)" \
                            || ng "M1" "変異しても鳴らない = U2 は猶予を測っていない"
    restore
else ng "M1" "錨が動いた"; restore; fi

if mutate '        self_link_state || return 0' '        self_link_state || true'; then
    : > "$SB/notified"
    run "$SB/m2.json" 3 1
    [ -f "$SB/m2.json" ] && ok "M2 ★回線の判定を外すと U1 が赤くなる" \
                         || ng "M2" "変異しても測らない = U1 は回線を測っていない"
    restore
else ng "M2" "錨が動いた"; restore; fi

if cmp -s "$SUT" "$SB/orig.sh"; then ok "Z 台本を書き換えたまま終わらない"
else ng "Z 木が汚れている" "手で git checkout -- rc-backend/tools/ota-undelivered-observer.sh する事"; fi

echo ""
echo "OTA-UNDELIVERED-OBSERVER-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
