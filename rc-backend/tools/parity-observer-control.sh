#!/bin/bash
# controls-for: tools/parity-observer.sh tools/tunnel-observer.sh
#
# 配備のずれを定期に見る枝の**挙動**対照。
#
# ★測る中心は「ずれを見つけるか」ではない。測るのは **黙るべき時に黙るか**。
#   此の枝は Jervis(持ち歩く MBP、回線が落ちるのは仕様)で 10 分毎に回る ——
#   H-4 で friday の watchdog が「本当ではない条件」で毎日鳴り、Tom は経路ごと
#   黙らせかけた。同じ物をもう1本作るなら、黙る側を先に測る。
#
#   P1 ★自分の回線が落ちていれば**測らない**(記録も進めない)
#   P2 ずれ(rc=1)なら1回鳴る
#   P3 同じ状態が続けば**2回目は鳴らない**
#   P4 ★測れない(rc=2)は**鳴らさない**(測れない事は ずれた事ではない)
#   P5 ずれた→戻った は、**ずれたと言った時だけ**戻った事も言う
#   P6 間隔が空いていなければ測らない
#   P7 ★呼び出しが **up の経路で到達する**(落ちている時しか走らない配線になっていない)
#   P8 ★`--dry-run` / `--report` では回さない
#   P9 ★測れなかった回は**時計を進めない**(其の1回が1日を食わない)
#   P10 ★測れない状態が続いたら「**見えていない**」として鳴る(ずれとは別の状態)
#   P11 閾値の内なら鳴らない
#
# 変異(→ 赤くなるべき検査):
#   M1 回線の判定を外す        → P1
#   M2 測れないも鳴らす        → P4
#   M3 間隔の判定を外す        → P6
#
# 使い方: bash rc-backend/tools/parity-observer-control.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
#
# no-operator: `staged-controls-gate` が `controls-for:` で拾って回す。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # = rc-backend/tools
SUT="$HERE/parity-observer.sh"
TUN="$HERE/tunnel-observer.sh"
for f in "$SUT" "$TUN"; do [ -f "$f" ] || { echo "測る対象が無い: $f"; exit 1; }; done

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
cp "$SUT" "$SB/orig.sh"

# ★台帳の宛先は **suite 全体で export** する(2026-08-31、実際に汚した後)。
#   最初は `run()` にだけ差したが、直に `. "$SUT"; parity_observe` を撃つ枝が4本在り、
#   其処から**実物の `~/.rc-backend/parity-ledger` に偽の照合の結果が載った**
#   (`obs_rc=2` / `unmeasured=22` —— どれも対照が作った数)。
#   差し忘れられる形にしない: 既定ごと砂場へ寄せる。
export RC_PARITY_LEDGER="$SB/ledger"
# ★実物の台帳が **suite の間じゅう**動かない事を最後に確かめる(P16)。
#   1回の呼び出しの前後だけ見る形だと、汚した枝が其の窓の外に在れば通ってしまう
#   —— 最初に書いた P16 が正にそれで、汚れているのに緑だった。
REAL_LEDGER="${HOME}/.rc-backend/parity-ledger"
real_at_start="$( [ -f "$REAL_LEDGER" ] && md5 -q "$REAL_LEDGER" 2>/dev/null || echo absent )"
restore() { cp -f "$SB/orig.sh" "$SUT"; }

# 偽の照合台本。<rc> を返すだけ。
mkchk() { printf '#!/bin/bash\necho "fake"\nexit %s\n' "$1" > "$2"; chmod +x "$2"; }
# 偽の出し先。呼ばれた事を数える。
NOTIFY="$SB/notify.sh"
printf '#!/bin/bash\ncat >/dev/null\necho x >> "%s"\n' "$SB/notified" > "$NOTIFY"; chmod +x "$NOTIFY"
notices() { [ -f "$SB/notified" ] && wc -l < "$SB/notified" | tr -d ' ' || echo 0; }

# run <状態file> <観測 rc> <plist rc> [自分の回線 rc(既定 0)]
run() {
    local st="$1" orc="$2" frc="$3" link="${4:-0}"
    mkchk "$orc" "$SB/obs.sh"; mkchk "$frc" "$SB/fleet.sh"
    RC_PARITY_STATE="$st" RC_PARITY_EVERY="${RUN_EVERY:-0}" RC_PARITY_LEDGER="$SB/ledger" \
    RC_PARITY_OBS_CHECK="$SB/obs.sh" RC_PARITY_FLEET_CHECK="$SB/fleet.sh" \
    RC_TUNNEL_NOTIFY="$NOTIFY" RC_TUNNEL_LOG="$SB/o.log" \
    bash -c '
        self_link_state() { return '"$link"'; }
        . "'"$SUT"'"
        parity_observe
    ' >/dev/null 2>&1
}
state_of() { cut -d" " -f2 < "$1" 2>/dev/null; }

# ── P1 ★回線が落ちていれば測らない ───────────────────────────────────────
: > "$SB/notified"
run "$SB/p1.json" 1 0 1          # ずれている入力だが、自分の回線は落ちている
if [ ! -f "$SB/p1.json" ] && [ "$(notices)" = "0" ]; then
    ok "P1 ★自分の回線が落ちていれば測らない(記録も通知も無い)"
else ng "P1 回線が落ちている時" "記録=$(cat "$SB/p1.json" 2>/dev/null) 通知=$(notices)"; fi

: > "$SB/notified"
run "$SB/p1b.json" 1 0 2         # 判らない(2)も同じく測らない
[ ! -f "$SB/p1b.json" ] && ok "P1b 回線が判らない時も測らない" \
                        || ng "P1b 回線 不明" "測ってしまった"

# ── P2 / P3 ずれ ─────────────────────────────────────────────────────────
: > "$SB/notified"
run "$SB/p2.json" 1 0
if [ "$(state_of "$SB/p2.json")" = "drift" ] && [ "$(notices)" = "1" ]; then
    ok "P2 ずれ(rc=1)なら1回鳴る"
else ng "P2 ずれ" "state=$(state_of "$SB/p2.json") 通知=$(notices)"; fi

run "$SB/p2.json" 1 0            # 同じ状態でもう1回
[ "$(notices)" = "1" ] && ok "P3 同じ状態が続けば2回目は鳴らない" \
                       || ng "P3 重複通知" "通知=$(notices) 通(1 が期待)"

# ── P4 ★測れないは鳴らさない ─────────────────────────────────────────────
: > "$SB/notified"
run "$SB/p4.json" 2 0
if [ "$(state_of "$SB/p4.json")" = "unmeasured" ] && [ "$(notices)" = "0" ]; then
    ok "P4 ★測れない(rc=2)は記録するが鳴らさない(H-4 の再演を避ける)"
else ng "P4 測れない" "state=$(state_of "$SB/p4.json") 通知=$(notices)"; fi

# ── P5 戻り ──────────────────────────────────────────────────────────────
: > "$SB/notified"
run "$SB/p5.json" 1 0            # ずれ → 1通
run "$SB/p5.json" 0 0            # 戻る → 1通(計2)
[ "$(notices)" = "2" ] && ok "P5 ずれたと言った後に戻ったら、戻った事も言う" \
                       || ng "P5 復帰" "通知=$(notices) 通(2 が期待)"

: > "$SB/notified"
run "$SB/p5b.json" 2 0           # 測れない(鳴らない)
run "$SB/p5b.json" 0 0           # 戻る
[ "$(notices)" = "0" ] && ok "P5b 鳴らしていない状態から戻った時は黙って戻す" \
                       || ng "P5b 身に覚えの無い復帰" "通知=$(notices) 通"

# ── P6 間隔 ──────────────────────────────────────────────────────────────
mkchk 0 "$SB/obs.sh"; mkchk 0 "$SB/fleet.sh"
run "$SB/p6.json" 0 0
t1="$(cut -d' ' -f1 < "$SB/p6.json")"
RC_PARITY_STATE="$SB/p6.json" RC_PARITY_EVERY=999999 \
RC_PARITY_OBS_CHECK="$SB/obs.sh" RC_PARITY_FLEET_CHECK="$SB/fleet.sh" \
RC_TUNNEL_NOTIFY="$NOTIFY" RC_TUNNEL_LOG="$SB/o.log" \
bash -c 'self_link_state() { return 0; }; . "'"$SUT"'"; parity_observe' >/dev/null 2>&1
t2="$(cut -d' ' -f1 < "$SB/p6.json")"
[ -n "$t1" ] && [ "$t1" = "$t2" ] && ok "P6 間隔の内では測り直さない" \
                                  || ng "P6 間隔" "1回目=$t1 2回目=$t2"

# ── P7 ★up の経路で到達するか ────────────────────────────────────────────
# 実測で踏んだ欠陥: 呼び出しを `if [ "$st" = up ]; then … exit 0; fi` の**後**に
# 置いていた。通常は up なので、事実上一度も走らない配線だった。
# 行番号で測る(呼び出しが up の判定より前に在るか)。
call_ln="$(grep -n '^[[:space:]]*parity_observe' "$TUN" | head -1 | cut -d: -f1)"
up_ln="$(grep -n 'if \[ "\$st" = up \]' "$TUN" | head -1 | cut -d: -f1)"
if [ -n "$call_ln" ] && [ -n "$up_ln" ] && [ "$call_ln" -lt "$up_ln" ]; then
    ok "P7 ★呼び出しが up の判定より前に在る(落ちている時しか走らない配線ではない)"
else ng "P7 配線" "呼び出し=$call_ln / up の判定=$up_ln ← 後ろに在ると通常は一度も走らない"; fi

# ── P8 ★dry-run / report では回さない ────────────────────────────────────
if grep -qE '\[ "\$DRY" -eq 0 \] && \[ "\$REPORT" -eq 0 \]' "$TUN"; then
    ok "P8 ★--dry-run / --report では回さない(測る・鳴らすの約束を守る)"
else ng "P8 dry/report" "条件が無い = 測らない筈の走行が記録を進める"; fi

# ── 変異 ─────────────────────────────────────────────────────────────────
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

# ★錨は 2026-08-31 に更新した。台帳(飛ばした理由の数え上げ)を足した時に
#   此の行が `|| { po__bump …; return 0; }` へ変わり、対照が「錨が動いた」で赤くなった
#   —— 錨の守りが**設計どおり働いた**形なので、緩めずに錨を実態へ合わせる。
if mutate '        self_link_state || { po__bump PO_L_SKIP_LINK; return 0; }' '        self_link_state || true'; then
    : > "$SB/notified"; run "$SB/m1.json" 1 0 1
    [ -f "$SB/m1.json" ] && ok "M1 回線の判定を外す → P1 が守っている物が消える" \
                         || ng "M1" "変異が効いていない"
    restore
else ng "M1" "錨が動いた"; restore; fi

if mutate '    if [ "$state" = "drift" ] && [ "$announced" -eq 0 ]' '    if [ "$state" != "ok" ] && [ "$announced" -eq 0 ]'; then
    : > "$SB/notified"; run "$SB/m2.json" 2 0
    [ "$(notices)" != "0" ] && ok "M2 測れないも鳴らす → P4 が守っている物が消える" \
                            || ng "M2" "変異が効いていない"
    restore
else ng "M2" "錨が動いた"; restore; fi

# ★M3 は最初「変異を植えた」と言うだけで**赤を測っていなかった** —— 空虚な対照は
#   守っている振りそのもの(2026-08-31、書いた直後に自分で気付いた)。
#   間隔の判定を外す変異に替えた。此方は P6 が確実に赤くなる。
if mutate '    [ $((now - PO_TS)) -lt "$PO_EVERY" ] && { po__bump PO_L_SKIP_NOTDUE; return 0; }' '    [ $((now - PO_TS)) -lt 0 ] && { po__bump PO_L_SKIP_NOTDUE; return 0; }'; then
    mkchk 0 "$SB/obs.sh"; mkchk 0 "$SB/fleet.sh"
    run "$SB/m3.json" 0 0
    t1="$(cut -d' ' -f1 < "$SB/m3.json")"
    sleep 1
    RC_PARITY_STATE="$SB/m3.json" RC_PARITY_EVERY=999999 \
    RC_PARITY_OBS_CHECK="$SB/obs.sh" RC_PARITY_FLEET_CHECK="$SB/fleet.sh" \
    RC_TUNNEL_NOTIFY="$NOTIFY" RC_TUNNEL_LOG="$SB/o.log" \
    bash -c 'self_link_state() { return 0; }; . "'"$SUT"'"; parity_observe' >/dev/null 2>&1
    t2="$(cut -d' ' -f1 < "$SB/m3.json")"
    restore
    [ "$t1" != "$t2" ] && ok "M3 間隔の判定を外す → P6 が守っている物が消える(測り直してしまう)" \
                       || ng "M3" "変異が効いていない(t1=$t1 t2=$t2)"
else ng "M3" "錨が動いた"; restore; fi

cmp -s "$SUT" "$SB/orig.sh" && ok "Z 台本を書き換えたまま終わらない" \
                            || ng "Z 台本が汚れている" "手で git checkout -- する事"

# ── P9 ★測れなかった回は**時計を進めない**(Codex 2026-08-31 の指摘3)──────
# 進めると其の1回が丸一日を食う。此の機体は実測で半分の時間オフラインなので、
# 期待間隔が約2日に伸びる —— 「日に1回」が嘘になる。
: > "$SB/notified"
run "$SB/p9.json" 0 0                       # まず測れる回で記録を作る
t_ok="$(cut -d' ' -f1 < "$SB/p9.json")"
sleep 1
run "$SB/p9.json" 2 0                       # 次は測れない
t_un="$(cut -d' ' -f1 < "$SB/p9.json")"
if [ "$t_ok" = "$t_un" ]; then
    ok "P9 ★測れなかった回は試みた時刻を進めない(次の tick で再挑戦できる)"
else ng "P9 時計" "測れないのに進んだ($t_ok → $t_un)= 其の1回が1日を食う"; fi

# ── P10 ★「測れた時刻」を別に持ち、古くなったら**見えていない**として鳴らす ──
# 黙るだけだと、机へ何日も届かないまま drift が溜まっても外から判らない。
: > "$SB/notified"
printf '%s ok 0 %s %s\n' "$(date +%s)" "$(date +%s)" "$(( $(date +%s) - 900000 ))" > "$SB/p10.json"
mkchk 2 "$SB/obs.sh"; mkchk 0 "$SB/fleet.sh"
RC_PARITY_STATE="$SB/p10.json" RC_PARITY_EVERY=0 RC_PARITY_STALE_S=259200 \
RC_PARITY_OBS_CHECK="$SB/obs.sh" RC_PARITY_FLEET_CHECK="$SB/fleet.sh" \
RC_TUNNEL_NOTIFY="$NOTIFY" RC_TUNNEL_LOG="$SB/o.log" \
bash -c 'self_link_state() { return 0; }; . "'"$SUT"'"; parity_observe' >/dev/null 2>&1
if [ "$(notices)" = "1" ]; then
    ok "P10 ★測れない状態が閾値を越えたら『見えていない』として鳴る(ずれとは別)"
else ng "P10 鮮度" "通知=$(notices) 通(1 が期待)= 何日届かなくても黙ったまま"; fi

# ── P11 閾値の内なら鳴らない(測れないだけで毎回鳴らさない)────────────────
: > "$SB/notified"
printf '%s ok 0 %s %s\n' "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$SB/p11.json"
RC_PARITY_STATE="$SB/p11.json" RC_PARITY_EVERY=0 RC_PARITY_STALE_S=259200 \
RC_PARITY_OBS_CHECK="$SB/obs.sh" RC_PARITY_FLEET_CHECK="$SB/fleet.sh" \
RC_TUNNEL_NOTIFY="$NOTIFY" RC_TUNNEL_LOG="$SB/o.log" \
bash -c 'self_link_state() { return 0; }; . "'"$SUT"'"; parity_observe' >/dev/null 2>&1
[ "$(notices)" = "0" ] && ok "P11 測れないが閾値の内なら鳴らない" \
                       || ng "P11 早鳴り" "通知=$(notices) 通"

# ── P12-P15 ★台帳(2026-08-31、Codex の指摘3b の残り)────────────────────────
# 測る中心は「数が出るか」ではなく **理由ごとに別の欄が動くか**。
# 1つの合計しか持たない実装でも「数は出る」ので、其れでは周期を後から検証できない。
led() { /usr/bin/sed -n "s/^$1=//p" "$SB/ledger" 2>/dev/null | tail -1; }

/bin/rm -f "$SB/ledger"
run "$SB/p12.json" 0 0 1                       # 回線が落ちている回
[ "$(led skip_link_down)" = "1" ] && ok "P12 ★回線が落ちて飛ばした回を link-down として数える" \
                                 || ng "P12 link-down" "実測=[$(led skip_link_down)]"

/bin/rm -f "$SB/ledger"
printf '%s ok 0 %s %s\n' "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$SB/p13.json"
RUN_EVERY=86400 run "$SB/p13.json" 0 0         # まだ周期が来ていない回
if [ "$(led skip_not_due)" = "1" ] && [ "$(led skip_link_down)" = "0" ]; then
    ok "P13 ★周期前で飛ばした回は not-due だけが増える(理由が混ざらない)"
else ng "P13 not-due" "not_due=[$(led skip_not_due)] link_down=[$(led skip_link_down)]"; fi

/bin/rm -f "$SB/ledger"
run "$SB/p14.json" 2 0                         # 行ったが測れない
if [ "$(led skip_unmeasured)" = "1" ] && [ "$(led obs_rc)" = "2" ]; then
    ok "P14 ★測れなかった回を数え、**照合ごとの rc** も残す(片方の緑で隠れない)"
else ng "P14 unmeasured" "unmeasured=[$(led skip_unmeasured)] obs_rc=[$(led obs_rc)]"; fi

out="$(RC_PARITY_LEDGER="$SB/ledger" RC_PARITY_STATE="$SB/p14.json" bash "$SUT" --report 2>&1)"
if printf '%s' "$out" | grep -qE 'observer-parity-check\.sh[^0-9]*rc=[0-9-]' \
   && printf '%s' "$out" | grep -qE 'fleet-plist-parity-check\.sh[^0-9]*rc=[0-9-]' \
   && printf '%s' "$out" | grep -q 'link-down' \
   && printf '%s' "$out" | grep -q 'not-due' \
   && printf '%s' "$out" | grep -q 'unmeasured'; then
    ok "P15 --report が照合ごとの rc と理由別の回数を出す"
else ng "P15 --report" "$(printf '%s' "$out" | head -3)"; fi

# M4 ★台帳の書き込みを外すと P12 が赤くなる(= P12 が空虚でない)
if mutate 'po__bump() {   # po__bump <変数名>' 'po__bump() { return 0; }
po__bump_unused() {   # po__bump <変数名>'; then
    /bin/rm -f "$SB/ledger"
    run "$SB/m4.json" 0 0 1
    [ "$(led skip_link_down)" != "1" ] && ok "M4 ★数え上げを外すと P12 が赤くなる" \
                                       || ng "M4" "変異しても数が増えた = P12 は数え上げを測っていない"
    restore
else ng "M4" "錨が動いた"; restore; fi

# ── P17 ★`--once` が本当に測る(2026-08-31、実測で踏んだ)────────────────────
# 元の `--once` は `RC_PARITY_EVERY=0 parity_observe` と書いていた。`PO_EVERY` は
# **読み込み時**に確定済みなので、呼び出し時に env を差しても効かず、
# `--once` は「今すぐ測る」と名乗りながら **not-due で帰るだけ**だった。
# 対照が捕まえられなかったのは、`run()` が **source する前**に env を差していたから
# —— 検査の撃ち方が、人の撃ち方と違っていた。だから此処は**人と同じ形**で撃つ。
: > "$SB/notified"
printf '%s ok 0 %s %s\n' "$(date +%s)" "$(date +%s)" "$(date +%s)" > "$SB/p17.json"
/bin/rm -f "$SB/ledger"
mkchk 0 "$SB/obs.sh"; mkchk 0 "$SB/fleet.sh"
RC_PARITY_STATE="$SB/p17.json" RC_PARITY_OBS_CHECK="$SB/obs.sh" \
RC_PARITY_FLEET_CHECK="$SB/fleet.sh" RC_TUNNEL_NOTIFY="$NOTIFY" RC_TUNNEL_LOG="$SB/o.log" \
    bash "$SUT" --once >/dev/null 2>&1
if [ "$(led obs_rc)" = "0" ] && [ "$(led skip_not_due)" != "1" ]; then
    ok "P17 ★--once は周期を待たずに本当に測る(名乗りどおり動く)"
else ng "P17 --once" "obs_rc=[$(led obs_rc)] not_due=[$(led skip_not_due)] = 測らずに帰った"; fi

# ── P16 ★対照が**実物の台帳**を触らない(2026-08-31、実際に汚した)──────────
# 窓は **suite の最初から最後まで**。1回の呼び出しの前後だけ見る形だと、
# 汚した枝が窓の外に在れば通る —— 最初に書いた P16 が正にそれで、
# `~/.rc-backend/parity-ledger` に偽の数が載っているのに緑だった。
real_at_end="$( [ -f "$REAL_LEDGER" ] && md5 -q "$REAL_LEDGER" 2>/dev/null || echo absent )"
if [ "$real_at_start" = "$real_at_end" ]; then
    ok "P16 ★対照は実物の台帳を触らない(suite の最初から最後まで不変)"
else ng "P16 実物を汚した" "前=$real_at_start 後=$real_at_end — 砂場を差し忘れた枝が在る"; fi

echo ""
echo "PARITY-OBSERVER-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
