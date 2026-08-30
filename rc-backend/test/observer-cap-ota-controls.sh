#!/bin/bash
# controls-for: tools/health-observer.sh tools/log-cap-all.sh
# 見張る場所: health-observer.sh の check_log_cap / check_ota_fresh と、
#             log-cap-all.sh が書く生存の印。
# ★宣言の行には **path だけ**を並べる(門は空白で切って path として読むので、
#   括弧書きの関数名を混ぜると「宣言先が実在しない」と言われ、
#   宣言が外れた対照は誰にも呼ばれなくなる)。
#
# 掃除の job と配布口を見張る2枝の**挙動**対照。
#
# ★測る中心は「名前が log に出るか」ではない。それは grep 2本で通る ——
#   そして其れは**機構**しか測っていない。測るのは次の4つ:
#     1. 状態を正しく読み分けるか(生存の印の3語)
#     2. **同じ状態では黙る**か(毎回鳴る警告は、真になった日に読まれない)
#     3. 猶予を跨いだ時**だけ**鳴らすか(未配達 / 測れない)
#     4. **言った問題を必ず片付けるか** ← 2026-08-30 の Codex 査読で見つかった実害
#
#   C1  印が無い              → missing、名指しする
#   C2  最後の成功が古い       → stale
#   C3  終了コードが非 0       → failed
#   C4  印が読めない           → failed(緑に丸めない)
#   C5  健全                   → ok、鳴らさない
#   C6  同じ状態が3回          → log 1行・通知1通                    ★doctrine
#   C7  一度測った後は間隔内で測り直さない(初回は測る)
#   C8  未配達(3)は猶予の内は鳴らさない
#   C9  未配達(3)は猶予を跨げば鳴る                                  ★Codex 指摘4
#   C10 測れない(2)は猶予の内は鳴らさない
#   C11 巻き戻り(1)は即鳴らす
#   C12 壊れた→戻った          → 戻った事も言う
#   C13 言っていない→戻った    → 黙って戻す
#   C14 巻き戻り(通知済)→未配達→ok で**復帰通知が消えない**        ★Codex 指摘1
#   C15 --dry-run は本番の記録を汚さない                             ★Codex 指摘2
#   C16 復帰通知の配達に失敗したら、次の回でやり直す                 ★Codex 指摘3
#   C17 生存の印: 失敗した回は**成功時刻を更新しない**
#
# 使い方: bash rc-backend/test/observer-cap-ota-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/health-observer.sh"
CAPSUT="$HERE/tools/log-cap-all.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
: > "$SB/none.conf"

# run <状態dir> [env...] — 観測を1回まわす(dry)。記録は <…>.dry に付く。
run() {
    local d="$1"; shift
    env RC_HEALTH_CONF="$SB/none.conf" RC_HEALTH_URL=http://127.0.0.1:9/z \
        RC_HEALTH_HOST=test.example RC_HEALTH_STATE="$d/s.json" \
        RC_HEALTH_NOTIFY=/usr/bin/true RC_HEALTH_LOG="$d/o.log" \
        RC_HEALTH_BROKEN_MARK="$d/b" RC_HEALTH_OK_MARK="$d/ok" RC_HEALTH_KEY_PEER= \
        "$@" bash "$SUT" --dry-run >/dev/null 2>&1
}
# runlive — 本当に出し先を叩く(出し先の成否を測る対照用)。
runlive() {
    local d="$1" notify="$2"; shift 2
    env RC_HEALTH_CONF="$SB/none.conf" RC_HEALTH_URL=http://127.0.0.1:9/z \
        RC_HEALTH_HOST=test.example RC_HEALTH_STATE="$d/s.json" \
        RC_HEALTH_NOTIFY="$notify" RC_HEALTH_LOG="$d/o.log" \
        RC_HEALTH_BROKEN_MARK="$d/b" RC_HEALTH_OK_MARK="$d/ok" RC_HEALTH_KEY_PEER= \
        "$@" bash "$SUT" >/dev/null 2>&1
}
CAPONLY=(RC_HEALTH_CAP_EVERY=0 RC_HEALTH_OTA_EVERY=999999 RC_HEALTH_BAD_EVERY=0 RC_HEALTH_CAP_MISSING_GRACE=0)
OTAONLY=(RC_HEALTH_CAP_EVERY=999999 RC_HEALTH_OTA_EVERY=0 RC_HEALTH_BAD_EVERY=0)

field()   { cut -d' ' -f"$2" < "$1" 2>/dev/null; }
state_of(){ cut -d' ' -f2 < "$1" 2>/dev/null; }
notices() { grep -c "DRY-RUN: $2" "$1/o.log" 2>/dev/null | tr -d ' '; }
changes() { grep -c "$2: 状態が" "$1/o.log" 2>/dev/null | tr -d ' '; }
mk_hb()   { printf '%s %s %s\n' "$2" "$3" "$4" > "$1"; }
mk_ota()  { printf '#!/bin/bash\necho "%s"\nexit %s\n' "$2" "$1" > "$3"; chmod +x "$3"; }
NOW="$(date +%s)"

# ── C1 印が無い ───────────────────────────────────────────────────────────
d="$SB/c1"; mkdir -p "$d"
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/nope"
[ "$(state_of "$d/s.json.cap-seen.dry")" = "missing" ] && grep -q "rc-log-cap" "$d/o.log" \
    && ok "C1 生存の印が無ければ missing で名指しする" \
    || ng "C1 missing" "state=$(state_of "$d/s.json.cap-seen.dry")"

# ── C2 最後の成功が古い ───────────────────────────────────────────────────
d="$SB/c2"; mkdir -p "$d"; mk_hb "$d/hb" "$NOW" "$((NOW - 86400))" 0
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb"
[ "$(state_of "$d/s.json.cap-seen.dry")" = "stale" ] \
    && ok "C2 試みは新しくても**成功**が古ければ stale(毎回こける job を元気と読まない)" \
    || ng "C2 stale" "state=$(state_of "$d/s.json.cap-seen.dry")"

# ── C3 終了コードが非 0 ───────────────────────────────────────────────────
d="$SB/c3"; mkdir -p "$d"; mk_hb "$d/hb" "$NOW" "$NOW" 2
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb"
[ "$(state_of "$d/s.json.cap-seen.dry")" = "failed" ] && ok "C3 終了コードが非 0 なら failed" \
    || ng "C3 failed" "state=$(state_of "$d/s.json.cap-seen.dry")"

# ── C4 印が読めない ───────────────────────────────────────────────────────
d="$SB/c4"; mkdir -p "$d"; printf 'garbage line\n' > "$d/hb"
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb"
[ "$(state_of "$d/s.json.cap-seen.dry")" = "failed" ] \
    && ok "C4 印が読めなければ failed(読めなかったを元気に丸めない)" \
    || ng "C4 読めない印" "state=$(state_of "$d/s.json.cap-seen.dry")"

# ── C5 健全 ───────────────────────────────────────────────────────────────
d="$SB/c5"; mkdir -p "$d"; mk_hb "$d/hb" "$NOW" "$NOW" 0
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb"
if [ "$(state_of "$d/s.json.cap-seen.dry")" = "ok" ] && [ "$(notices "$d" rc-log-cap)" = "0" ]; then
    ok "C5 健全なら ok で、通知は 0 通"
else ng "C5 健全" "state=$(state_of "$d/s.json.cap-seen.dry") 通知=$(notices "$d" rc-log-cap)"; fi

# ── C6 同じ状態が3回 ★doctrine ───────────────────────────────────────────
d="$SB/c6"; mkdir -p "$d"
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/nope"
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/nope"
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/nope"
if [ "$(changes "$d" rc-log-cap)" = "1" ] && [ "$(notices "$d" rc-log-cap)" = "1" ]; then
    ok "C6 同じ状態で3回まわしても log 1行・通知1通"
else ng "C6 状態変化の時だけ" "log=$(changes "$d" rc-log-cap) 行 / 通知=$(notices "$d" rc-log-cap) 通"; fi

# ── C7 間隔 ───────────────────────────────────────────────────────────────
# ★初回は必ず測る(記録が無い = まだ一度も見ていない)。此処で測るのは
#   「**健全な**記録が在って間隔の内なら手を出さないか」。壊れている間は
#   わざと細かく測り直すので、健全な状態で測らないと間隔の枝を測れない。
d="$SB/c7"; mkdir -p "$d"; mk_hb "$d/hb" "$NOW" "$NOW" 0
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb"
t1="$(field "$d/s.json.cap-seen.dry" 1)"
run "$d" RC_HEALTH_CAP_EVERY=999999 RC_HEALTH_OTA_EVERY=999999 RC_HEALTH_CAP_MARK="$d/hb"
t2="$(field "$d/s.json.cap-seen.dry" 1)"
[ -n "$t1" ] && [ "$t1" = "$t2" ] && ok "C7 健全なら間隔の内では測り直さない(初回は測る)" \
    || ng "C7 間隔" "1回目=$t1 2回目=$t2"

# ── C8 / C9 未配達の猶予 ★Codex 指摘4 ────────────────────────────────────
d="$SB/c8"; mkdir -p "$d"; mk_ota 3 "承認 105 < HEAD 107" "$d/ota.sh"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh" RC_HEALTH_OTA_UNDELIVERED_GRACE=999999
if [ "$(state_of "$d/s.json.ota-seen.dry")" = "undelivered" ] && [ "$(notices "$d" ota-freshness)" = "0" ]; then
    ok "C8 未配達は猶予の内なら鳴らさない(作業中は常に真なので)"
else ng "C8 未配達の猶予内" "state=$(state_of "$d/s.json.ota-seen.dry") 通知=$(notices "$d" ota-freshness)"; fi

d="$SB/c9"; mkdir -p "$d"; mk_ota 3 "承認 105 < HEAD 107" "$d/ota.sh"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh" RC_HEALTH_OTA_UNDELIVERED_GRACE=0
[ "$(notices "$d" ota-freshness)" = "1" ] \
    && ok "C9 未配達は猶予を跨げば鳴る(直っている物が電話に届いていない = 一番見える失敗)" \
    || ng "C9 未配達の猶予外" "通知=$(notices "$d" ota-freshness) 通"

# ── C10 測れない ─────────────────────────────────────────────────────────
d="$SB/c10"; mkdir -p "$d"; mk_ota 2 "ssh に届かない" "$d/ota.sh"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh" RC_HEALTH_OTA_BLIND_S=999999
n1="$(notices "$d" ota-freshness)"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh" RC_HEALTH_OTA_BLIND_S=0
n2="$(notices "$d" ota-freshness)"
[ "$n1" = "0" ] && [ "$n2" = "1" ] \
    && ok "C10 測れないは猶予の内で黙り、跨いで鳴る(回線の瞬きで叫ばない)" \
    || ng "C10 測れない" "猶予内=$n1 通 / 猶予外=$n2 通"

# ── C11 巻き戻り ─────────────────────────────────────────────────────────
d="$SB/c11"; mkdir -p "$d"; mk_ota 1 "配布 96 < 承認済み 105" "$d/ota.sh"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh"
if [ "$(state_of "$d/s.json.ota-seen.dry")" = "rollback" ] && [ "$(notices "$d" ota-freshness)" = "1" ]; then
    ok "C11 巻き戻りは猶予無しで即鳴らす(Tom の唯一の復旧経路)"
else ng "C11 巻き戻り" "state=$(state_of "$d/s.json.ota-seen.dry") 通知=$(notices "$d" ota-freshness)"; fi

# ── C12 壊れた→戻った ────────────────────────────────────────────────────
d="$SB/c12"; mkdir -p "$d"
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/nope"
mk_hb "$d/hb" "$NOW" "$NOW" 0
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb"
grep -q "rc-log-cap(戻った)" "$d/o.log" && ok "C12 壊れたと言った後に戻ったら、戻った事も言う" \
    || ng "C12 復帰" "$(tail -2 "$d/o.log")"

# ── C13 言っていないのに戻った ───────────────────────────────────────────
d="$SB/c13"; mkdir -p "$d"; mk_ota 3 "承認 105 < HEAD 107" "$d/ota.sh"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh" RC_HEALTH_OTA_UNDELIVERED_GRACE=999999
mk_ota 0 "順当" "$d/ota.sh"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh"
grep -q "ota-freshness(戻った)" "$d/o.log" && ng "C13 黙って戻す" "身に覚えの無い復帰通知" \
    || ok "C13 鳴らしていない状態から戻った時は黙って戻す"

# ── C14 間に別の状態を挟んでも復帰が消えない ★Codex 指摘1 ────────────────
# 巻き戻りを通知 → 未配達(鳴らさない状態)を経由 → ok。
# 「通知済み」を**現在の状態に括り付ける**設計だと、間の状態で 0 に戻り、
# ok に着いた時には「言った問題」が消えていて **永久に復帰を言わない**。
d="$SB/c14"; mkdir -p "$d"; mk_ota 1 "配布 96 < 承認済み 105" "$d/ota.sh"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh"
mk_ota 3 "承認 105 < HEAD 107" "$d/ota.sh"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh" RC_HEALTH_OTA_UNDELIVERED_GRACE=999999
mk_ota 0 "順当" "$d/ota.sh"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/ota.sh"
grep -q "ota-freshness(戻った)" "$d/o.log" \
    && ok "C14 巻き戻り→未配達→ok でも復帰通知が消えない(状態と『言った問題』を分けている)" \
    || ng "C14 復帰が消えた" "壊れたと言ったまま直ったと言わない = Tom は直った事を知れない"

# ── C15 dry-run は本番の記録を汚さない ★Codex 指摘2 ──────────────────────
d="$SB/c15"; mkdir -p "$d"
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/nope"
if [ -f "$d/s.json.cap-seen.dry" ] && [ ! -f "$d/s.json.cap-seen" ]; then
    ok "C15 --dry-run は .dry にだけ書く(一度試すと本番が黙る、を作らない)"
else ng "C15 dry の分離" "本番の記録に書いた"; fi

# ── C16 復帰通知の配達に失敗したらやり直す ★Codex 指摘3 ──────────────────
# 出し先を失敗させて「壊れた」を通知 → 出し先を直して「戻った」を通知。
# 復帰の配達失敗を捨てて ok を書く実装だと、直った事を**永久に**言わない。
d="$SB/c16"; mkdir -p "$d"
runlive "$d" /usr/bin/true  "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/nope"     # missing を通知
mk_hb "$d/hb" "$NOW" "$NOW" 0
runlive "$d" /usr/bin/false "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb"       # 復帰の配達が失敗
o1="$(field "$d/s.json.cap-seen" 5)"
runlive "$d" /usr/bin/true  "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb"       # やり直して成功
o2="$(field "$d/s.json.cap-seen" 5)"
if [ "$o1" = "1" ] && [ "$o2" = "0" ]; then
    ok "C16 復帰の配達に失敗したら未解決のまま残し、次の回でやり直す"
else ng "C16 復帰の再送" "失敗後=$o1(1 が期待) 成功後=$o2(0 が期待)"; fi

# ── C17 生存の印: 失敗した回は成功時刻を更新しない ───────────────────────
d="$SB/c17"; mkdir -p "$d/logs"; printf 'x\n' > "$d/logs/a.log"
RC_CAP_HEARTBEAT="$d/hb" bash "$CAPSUT" "$d/logs" >/dev/null 2>&1
ok1="$(awk '{print $2}' "$d/hb")"
sleep 1
RC_CAP_HEARTBEAT="$d/hb" bash "$CAPSUT" "$d/nope" >/dev/null 2>&1
ok2="$(awk '{print $2}' "$d/hb")"; at2="$(awk '{print $1}' "$d/hb")"; rc2="$(awk '{print $3}' "$d/hb")"
if [ "$ok1" = "$ok2" ] && [ "$at2" != "$ok2" ] && [ "$rc2" != "0" ]; then
    ok "C17 失敗した回は試みだけ更新し、成功時刻は据え置く"
else ng "C17 生存の印" "成功 $ok1→$ok2 / 試み=$at2 / rc=$rc2"; fi

# ── C18 台本が空 = この機体では測らない(材料を持たない機体で毎時鳴らさない)────
d="$SB/c18"; mkdir -p "$d"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK=
if [ ! -f "$d/s.json.ota-seen.dry" ] && [ "$(notices "$d" ota-freshness)" = "0" ]; then
    ok "C18 台本が空なら測らず鳴らさない(居ない物を測れないのは異常ではない)"
else ng "C18 空の台本" "記録=$([ -f "$d/s.json.ota-seen.dry" ] && cat "$d/s.json.ota-seen.dry") 通知=$(notices "$d" ota-freshness)"; fi

# ── C19 台本を指しているのに実行できない = 測れない(空と混同しない)──────────
d="$SB/c19"; mkdir -p "$d"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/absent.sh" RC_HEALTH_OTA_BLIND_S=0
[ "$(state_of "$d/s.json.ota-seen.dry")" = "unmeasurable" ] && [ "$(notices "$d" ota-freshness)" = "1" ] \
    && ok "C19 台本を指しているのに無ければ測れない扱いで鳴る(空と別物)" \
    || ng "C19 台本が無い" "state=$(state_of "$d/s.json.ota-seen.dry") 通知=$(notices "$d" ota-freshness)"

# ── C20 印が無いのは据え付け直後と区別が付かない → 猶予の内は鳴らさない ──────
# ★据え付けた直後は掃除がまだ一度も走っていないので印が無いのが正常。
#   猶予無しで鳴らすと、新しい機体に据える度に必ず1通誤報する。
d="$SB/c20"; mkdir -p "$d"
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/nope" RC_HEALTH_CAP_MISSING_GRACE=999999
n1="$(notices "$d" rc-log-cap)"
d="$SB/c20b"; mkdir -p "$d"
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/nope" RC_HEALTH_CAP_MISSING_GRACE=0
n2="$(notices "$d" rc-log-cap)"
[ "$n1" = "0" ] && [ "$n2" = "1" ] \
    && ok "C20 印が無いのは猶予の内なら鳴らさない(据え付け直後を誤報しない)" \
    || ng "C20 印が無い猶予" "猶予内=$n1 通 / 猶予外=$n2 通"

# ── C21 壊れた印(stale/failed)には猶予を置かない ─────────────────────────
# 「在った物が壊れた」は据え付け直後と取り違えようが無い。猶予を掛けると
# 上限が外れたまま黙る時間が伸びる。
d="$SB/c21"; mkdir -p "$d"; mk_hb "$d/hb" "$NOW" "$((NOW - 86400))" 0
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb" RC_HEALTH_CAP_MISSING_GRACE=999999
[ "$(notices "$d" rc-log-cap)" = "1" ] \
    && ok "C21 stale は印が無い時の猶予に巻き込まれず即鳴る" \
    || ng "C21 stale の即時性" "通知=$(notices "$d" rc-log-cap) 通"

# ── C22 掃除の印を指していない機体では測らない ───────────────────────────
# `com.fleet.rc-log-cap` を回しているのは friday だけ。回していない機体の観測器が
# 其の生死を語ると、必ず「印が無い」を鳴らす。
d="$SB/c22"; mkdir -p "$d"
run "$d" RC_HEALTH_CAP_EVERY=0 RC_HEALTH_OTA_EVERY=999999 RC_HEALTH_CAP_MARK=
if [ ! -f "$d/s.json.cap-seen.dry" ] && [ "$(notices "$d" rc-log-cap)" = "0" ]; then
    ok "C22 印を指していない機体では測らず鳴らさない"
else ng "C22 空の印" "測ってしまった"; fi

# ── C23 固まった台本を時間で切る ★Codex 2巡目 ────────────────────────────
# 配布口の検査は中で ssh を張る。相手が黙ると此処が返らず、**観測器ごと止まる** ——
# 止まれば「言い残した通知」の再送にも永久に到達しない。
d="$SB/c23"; mkdir -p "$d"
printf '#!/bin/bash\nsleep 60\n' > "$d/hang.sh"; chmod +x "$d/hang.sh"
t0="$(date +%s)"
run "$d" "${OTAONLY[@]}" RC_HEALTH_OTA_CHECK="$d/hang.sh" RC_HEALTH_OTA_TIMEOUT=3 RC_HEALTH_OTA_BLIND_S=0
el=$(( $(date +%s) - t0 ))
if [ "$el" -lt 30 ] && [ "$(state_of "$d/s.json.ota-seen.dry")" = "unmeasurable" ]; then
    ok "C23 固まった台本は $el 秒で切られ、測れない扱いになる(観測器を道連れにしない)"
else ng "C23 時間で切る" "${el}秒 / state=$(state_of "$d/s.json.ota-seen.dry")"; fi

# ── C24 欄が壊れた記録は丸ごと未知に倒す ★Codex 2巡目 ────────────────────
# 欄が1つずれると状態の名前の場所に epoch が入る。そのずれは出力に出ない。
d="$SB/c24"; mkdir -p "$d"; mk_hb "$d/hb" "$NOW" "$NOW" 0
printf 'junk %s ok 0 1 0 %s\n' "$NOW" "$NOW" > "$d/s.json.cap-seen.dry"   # 欄が 7
run "$d" "${CAPONLY[@]}" RC_HEALTH_CAP_MARK="$d/hb"
# 未知から見直すので「unknown → ok」の行が出る(壊れた記録を信じない)
grep -q "rc-log-cap: 状態が unknown → ok" "$d/o.log" \
    && ok "C24 欄数が合わない記録は信じず、未知から見直す" \
    || ng "C24 壊れた記録" "$(grep rc-log-cap "$d/o.log" | tail -1)"

echo ""
echo "OBSERVER-CAP-OTA-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
