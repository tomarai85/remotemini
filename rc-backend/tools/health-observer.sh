#!/bin/bash
# rc-backend の外向き生存信号(DESIGN §7-P)。**edith 以外**のノードから 10 分毎に叩く。
#
# 守りたいのは「サーバが上がっている」ではなく **「今この瞬間、電話から見える面が生きているか」**。
# だから見るのは §7 の鎖の①(= HTTP が返るか)であって、tmux も launchd も見ない。
#
# 使い方:
#   tools/health-observer.sh                 通常(launchd から)
#   tools/health-observer.sh --inject-fail   偽の失敗を1回注入(経路を撃つ試験用)
#   tools/health-observer.sh --inject-ok     偽の成功を1回注入
#   tools/health-observer.sh --dry-run       通知を出さず、出す筈だった文面を表示
#
# 終了コード: 0 = 正常(鳴らした/鳴らさない の両方) / 2 = 引数が不正(人が手で叩いた時だけ)
#             3 = ★**監視自体が壊れている**(状態ファイル / 起動前提 / 設定の値)
#   3 は「観測できなかった」であって「異常なし」ではない。ここを 0 に丸めると、
#   10 分毎に静かに失敗し続けて誰も気付かない = yoda の 46 時間と同じ形になる。
#
# ★観測者を**どのノードに置くかは決めていない**(艦隊の移動計画が未確定 = DESIGN §7-P)。
#   なので台本はどこでも動く形にし、機械依存は全部設定に出す。既定は Jervis で動く値。
set -uo pipefail

CONF="${RC_HEALTH_CONF:-$HOME/.rc-backend/observer.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

HOST="${RC_HEALTH_HOST:desk.tailnet.example}"
URL="${RC_HEALTH_URL:-https://$HOST/healthz}"
THRESHOLD="${RC_HEALTH_THRESHOLD:-3}"
STATE="${RC_HEALTH_STATE:-$HOME/.rc-backend/health-state.json}"
NOTIFY="${RC_HEALTH_NOTIFY:-$HOME/bin/discord-notify.sh}"
LOG="${RC_HEALTH_LOG:-$HOME/.rc-backend/health-observer.log}"
# 監視自体が壊れた時の通知を何秒に1回までにするか(既定 6 時間)。
# 壊れ方が続くと 10 分毎に鳴り続け、Tom が経路ごと黙らせる = yoda と同じ結末になる。
BROKEN_EVERY="${RC_HEALTH_BROKEN_EVERY:-21600}"
BROKEN_MARK="${RC_HEALTH_BROKEN_MARK:-$STATE.broken-notified}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEP="$ROOT/tools/health-step.mjs"
NODE="${RC_HEALTH_NODE:-$(command -v node || echo /opt/homebrew/bin/node)}"

MODE="probe"; DRY=0
for a in "$@"; do
    case "$a" in
        --inject-fail) MODE="fail" ;;
        --inject-ok)   MODE="ok" ;;
        --dry-run)     DRY=1 ;;
        *) echo "不明な引数: $a" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")" 2>/dev/null
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# ── 「監視自体が壊れている」を知らせる(up/down とは別系統)────────────
# ★なぜ在るか(2026-08-02、再現してから足した): 監視が**動き出す前**に落ちる形 ——
#   node の場所が違う / 設定の値が不正 / 判定の繋ぎが無い —— は、元は log 1 行だけ残して
#   黙っていた。実測: 閾値に `0` と書いた設定で5回叩いて通知 **0 通**、node の場所を
#   違えて3回叩いて **0 通**。どちらも据え付けた当日に起きる類の書き損じで、
#   起きた瞬間から監視は**永久に鳴らない**。判定の門(`health.mjs` の閾値検査)は
#   在ったが、**門が閉じた事を誰にも知らせていなかった** = 守り手自身が静かに死ぬ形。
#
# 抑制時計 `$BROKEN_MARK` は「状態ファイルが壊れている」と共用する。Tom 側から見れば
# どちらも「監視が壊れている」1つの事なので、2本の警報を並べても読む手間が増えるだけ。
#
# 引数: $1 = Tom に見せる短い語。**必ず我々の固定文字列**を渡す事 —— `$ERR` の中身は
#       渡さない(通知は Tom が読む面なので、素性の分からない文字列を流し込まない)。
# 返り値は常に 3(= 監視が壊れている)。鳴らせたかどうかで変えない。
notify_monitor_broken() {
    local why="$1" now last nrc
    if [ "$DRY" -eq 1 ]; then
        log "DRY-RUN: 監視が壊れている($why) — 通知は出さない"
        echo "監視側が壊れています($why)"
        return 3
    fi
    if [ ! -x "$NOTIFY" ]; then
        # ここだけは本当に知らせる術が無い。せめて「知らせられなかった」を log に残す。
        log "★監視が壊れている($why)が、出し先も実行できない: $NOTIFY"
        return 3
    fi
    now="$(date +%s)"
    last=0
    [ -f "$BROKEN_MARK" ] && last="$(cat "$BROKEN_MARK" 2>/dev/null || echo 0)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt "$BROKEN_EVERY" ]; then
        log "★監視が壊れている($why) — 前回の通知から $((now - last)) 秒 = 抑制"
        return 3
    fi
    printf '%s' "rc-backend の監視側が壊れています($(hostname -s) / $why)。log を見る事: $LOG" | "$NOTIFY"
    nrc=$?
    log "★監視が壊れている($why)を通知(出し先 rc=$nrc)"
    # ★抑制時計は**配達が済んでから**進める。「知らせると決めた」時点で進めると、
    #   出し先が壊れている間ずっと 6 時間黙る(この案件で既に3度踏んだ形)。
    if [ "$nrc" -eq 0 ]; then
        echo "$now" > "$BROKEN_MARK" 2>>"$LOG" \
            || log "  ★抑制時計を書けない($BROKEN_MARK) — 次回また鳴る(重複は沈黙よりまし)"
    else
        log "  ★出し先が失敗(rc=$nrc) — 抑制時計は進めない(次回また鳴らし直す)"
    fi
    return 3
}

# ★この行は現状**到達しない**(上の `${RC_HEALTH_URL:-…}` は空文字も既定へ倒すので)。
#   倒す先が既定の URL = 騒がしい側なので、そのままにして番人だけ残す。
[ -n "$URL" ] || { log "設定に URL が無い(CONF=$CONF)"; notify_monitor_broken "設定に URL が無い"; exit 3; }
[ -x "$NODE" ] || { log "node が見つからない: $NODE"; echo "node が見つからない: $NODE" >&2
                    notify_monitor_broken "node が無い"; exit 3; }
[ -f "$STEP" ] || { log "判定の繋ぎが無い: $STEP"; echo "判定の繋ぎが無い: $STEP" >&2
                    notify_monitor_broken "判定の繋ぎが無い"; exit 3; }

# ── 1回叩く ───────────────────────────────────────────────────────
# 本体は捨てずに見る: 200 を返すだけの別物(tailscale の受け口や proxy)を「生きている」と
# 読まない為。★ただし本体を**ログにも通知にも載せない**(会話の情報が混ざる余地を作らない)。
probe() {
    local body code
    body="$(curl -sS -m 8 -w $'\n%{http_code}' "$URL" 2>/dev/null)"; local rc=$?
    if [ $rc -ne 0 ]; then echo "ng|curl exit $rc"; return; fi
    code="$(printf '%s' "$body" | tail -1)"
    body="$(printf '%s' "$body" | sed '$d')"
    if [ "$code" != "200" ]; then echo "ng|http $code"; return; fi
    case "$body" in *'"ok"'*) : ;; *) echo "ng|本体に ok が無い"; return ;; esac
    case "$body" in *'"ok":true'*|*'"ok": true'*) echo "ok|" ;; *) echo "ng|ok が true でない" ;; esac
}

case "$MODE" in
    probe) R="$(probe)" ;;
    fail)  R="ng|注入した偽の失敗(経路の試験)" ;;
    ok)    R="ok|" ;;
esac
VERDICT="${R%%|*}"; REASON="${R#*|}"

# ── 判定に渡す ────────────────────────────────────────────────────
# ★stdout と stderr を混ぜない。混ぜると node の警告1行が**通知の文面に化ける**
#   (通知は Tom が読む面なので、そこに素性の分からない文字列を流し込まない)。
ERRF="$(mktemp "${TMPDIR:-/tmp}/health-step-err.XXXXXX")"
MSG="$("$NODE" "$STEP" "$STATE" "$VERDICT" "$REASON" "$(date +%s)" "$THRESHOLD" "$HOST" 2>"$ERRF")"
KIND=$?
ERR="$(cat "$ERRF" 2>/dev/null)"; /bin/rm -f "$ERRF"

# 値は `FLEET_NOTIFY_MENTION` にそのまま渡す物。"0" = ping を抑える / 空 = 既定(= @Tom 付き)
PING_SUPPRESS=""
# ★台本自身の終了コードは「監視が健全か」を表す。**通知を出したかどうかで変えない**。
#   (対照が拾った実際の不整合: 抑制された時だけ 3、鳴らした時は 0 を返していた ——
#    同じ「監視が壊れている」状態が、鳴らした回だけ launchd から見て正常に見えていた)
FINAL_RC=0
case "$KIND" in
    0)  log "$VERDICT ${REASON:+($REASON)} — 鳴らさない"; exit 0 ;;
    10) PING_SUPPRESS=""  ;;   # 落ちた = @Tom を付ける
    11) PING_SUPPRESS="0" ;;   # 戻った = ping 無し(既に一度鳴らしている)
    3)
        # ★監視自体が壊れている。これを黙って 0 に丸めると「静かに鳴らない監視」になる。
        log "★監視の状態が壊れている: $ERR"
        notify_monitor_broken "状態ファイル"
        exit 3
        ;;
    *)  # 判定が起動すらできなかった(設定の値が不正 / node の中で落ちた 等)。
        # ★元はここで log を1行残して `exit $KIND` = **誰にも届かなかった**。
        #   閾値に `0` と書いた設定で 5 回叩いて通知 0 通、というのがその実測。
        log "判定が異常終了(code=$KIND): ${ERR:-$MSG}"
        notify_monitor_broken "設定か引数が不正"
        exit 3
        ;;
esac

# ── 鳴らす ────────────────────────────────────────────────────────
if [ "$DRY" -eq 1 ]; then
    log "DRY-RUN: [$MSG] (ping抑制=${PING_SUPPRESS:-無し})"
    echo "$MSG"; exit "$FINAL_RC"
fi
[ -x "$NOTIFY" ] || { log "通知の出し先が実行できない: $NOTIFY"; echo "通知の出し先が実行できない: $NOTIFY" >&2; exit 2; }

if [ -n "$PING_SUPPRESS" ]; then
    printf '%s' "$MSG" | FLEET_NOTIFY_MENTION=0 "$NOTIFY"
else
    printf '%s' "$MSG" | "$NOTIFY"
fi
nrc=$?
log "通知(code=$KIND, ping抑制=${PING_SUPPRESS:-無し}, 出し先 rc=$nrc): $MSG"

# ── 配達が済んだ事を、済んでから記録する ──────────────────────────
# ★これを判定と同じ回に書かない事がこの層の要点。「知らせると決めた」時点で
#   `down` を確定させていた時は、出し先が壊れていると**出し先が直っても二度と鳴らなかった**
#   (実測: 壊した出し先で3回 → 0通、直して更に3回 → やはり 0通。ログには「鳴らさない」)。
#
# ★分かる事の限界を正確に: 掴めるのは「出し先が動かなかった / 非 0 で終わった」まで。
#   `~/bin/discord-notify.sh` は 2026-08-02 に直して**両脚(Discord と iMessage 退避)が
#   落ちた時だけ**非 0 を返す様になった(それ以前はどの経路でも 0 = ここが常に素通りだった)。
#   退避が通った時は 0 = 配達済み扱い。それで正しい —— Tom には届いているから。
#   「Discord に載った」だけを見たいなら `fleet-notify.sh` の FLEET_NOTIFY_STRICT=1 だが、
#   退避成功まで失敗と数える事になるので採らない。出し先を差し替えた時は、その出し先が
#   **失敗を非 0 で言うか**を先に確かめる事(言わない出し先ではこの層は効かない)。
# ここへ来るのは KIND=10/11 だけ(監視が壊れている回は上の case で完結する)。
if [ "$nrc" -eq 0 ]; then
    if ! "$NODE" "$STEP" --mark-delivered "$STATE" 2>>"$LOG"; then
        log "★配達済みの記録に失敗 — 次回もう一度鳴る(重複は沈黙よりまし)"
        FINAL_RC=3
    fi
else
    log "★出し先が失敗(rc=$nrc) — 状態は『未配達』のまま。落ちている限り次回また鳴らす"
    FINAL_RC=3
fi
exit "$FINAL_RC"
