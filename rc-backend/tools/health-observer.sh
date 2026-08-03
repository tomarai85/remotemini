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
# ★「監視が最後に働けた時刻」(Codex Q3)。「監視側が壊れています」だけでは、
#   10 分前からなのか 3 日前からなのかが分からず、Tom は log を開くまで緊急度を測れない。
#   ★記録するのは **対象が up だった時刻ではなく、判定が一周できた時刻**。
#     up を記録すると「対象が長く落ちている」が「監視が長く壊れている」に見え、
#     Q3 が消したがっている取り違えを別の場所で作り直す事になる。
#   状態 file とは**別の file** に置く。監視が壊れる二形のうち一方が
#   「状態 file が壊れている」なので、そこに相乗りすると肝心な時に読めない。
OK_MARK="${RC_HEALTH_OK_MARK:-$STATE.last-ok}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEP="$ROOT/tools/health-step.mjs"
NODE="${RC_HEALTH_NODE:-$(command -v node || echo /opt/homebrew/bin/node)}"

# ── tailnet 鍵の残日数(up/down とは**別系統**)────────────────────────
# 鍵が切れると機械は tailnet から落ちる。up/down の監視はそれを「落ちた」としてしか言えず、
# しかも**切れてから**しか言えない。切れる前に言う為の系統が要る = 此処。
#
# ★測る相手が2つ在る理由(2026-08-03 実測): 監視は「edith を、別のノードから」叩く形なので、
#   鎖には鍵が2本ある。実測値は 観測側(Jervis)46 日 / edith 143 日 —— **先に切れるのは
#   監視する側**。遠い方だけ見ていると、先に壊れる方を一度も見ない。だから両方を見る。
#   観測側が落ちると edith は無事なのに `/healthz` へ届かず、**本物の障害と区別が付かない
#   偽の警報**が出るか、監視ごと黙る。
KEY_CHECK="${RC_HEALTH_KEY_CHECK:-$ROOT/tools/tailnet-key-expiry.sh}"
KEY_PEER="${RC_HEALTH_KEY_PEER:-$HOST}"      # 監視している相手。既定 = 叩いている先
KEY_EVERY="${RC_HEALTH_KEY_EVERY:-86400}"    # 測る間隔(既定 1 日1回。10 分毎に測る物ではない)
KEY_MARK="${RC_HEALTH_KEY_MARK:-$STATE.key-checked}"
KEY_WARN_DAYS="${RC_HEALTH_KEY_WARN_DAYS:-45}"
# 段(この日数を**下回った**時に1回だけ鳴らす)。45 日間まいにち鳴らすと Tom が経路ごと
# 黙らせる —— yoda の 46 時間と同じ終わり方をする。だから段を降りた時だけ言う。
# ★2026-08-03 に 45/30/14/7/3/1 から減らした(査読 Q4)。どの段でも Tom がやる事は
#   「admin console で Disable key expiry を押す」の1つだけなので、段を増やしても情報は
#   増えず、鳴る回数だけ増えて「経路ごと黙らされる」側にだけ効く。期限切れの段(0)を
#   足しても**1台あたり最大5通**で、元の6通より少ない。
KEY_STEPS="${RC_HEALTH_KEY_STEPS:-45 14 7 1}"

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

# 「最後に監視が働けたのは何時か」を人が読む一言にする。
# ★分からない時に**数字を作らない**。記録が無い/読めない/未来を指している の3つは
#   それぞれ別の文を返す。ここで 0 や「今」を返すと、Tom は「さっきまで動いていた」と
#   読む —— 一度も動いた事が無い据え付け直後こそ、それが一番起きやすい。
last_worked_phrase() {
    local t now d
    [ -f "$OK_MARK" ] || { echo "一度も成功していない(据え付け以来か、記録ごと消えた)"; return; }
    t="$(cat "$OK_MARK" 2>/dev/null)"
    case "$t" in ''|*[!0-9]*) echo "不明(記録が読めない)"; return ;; esac
    now="$(date +%s)"; d=$((now - t))
    if   [ "$d" -lt 0 ]     ; then echo "不明(時計が巻き戻っている)"
    elif [ "$d" -lt 3600 ]  ; then echo "$((d / 60)) 分前"
    elif [ "$d" -lt 86400 ] ; then echo "$((d / 3600)) 時間前"
    else                           echo "$((d / 86400)) 日前"
    fi
}

notify_monitor_broken() {
    local why="$1" now last nrc
    if [ "$DRY" -eq 1 ]; then
        log "DRY-RUN: 監視が壊れている($why) — 通知は出さない"
        echo "監視側が壊れています($why / 最後に働けたのは $(last_worked_phrase))"
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
    printf '%s' "rc-backend の監視側が壊れています($(hostname -s) / $why)。最後に監視が働けたのは $(last_worked_phrase)。log を見る事: $LOG" | "$NOTIFY"
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

# ── 鍵の残日数を見る(段を降りた時だけ1回鳴らす)─────────────────────
# 記録 `$KEY_MARK` の中身 = "<最後に測った epoch> <self の段> <peer の段>"(段 9999 = 未通知)。
#
# ★up/down より**手前**で呼ぶ。KIND=0(異常なし)の回は下の case で `exit 0` するので、
#   後ろに置くと**平常時に一度も走らない** —— 平常時こそが、これが働くべき時。
# ★時計を配達が済んでから進めるのは、この file の他の2箇所と同じ理由。決めた時点で進めると
#   出し先が壊れている間ずっと黙る(この案件で既に3度踏んだ形)。
#
# ── ★2026-08-03 の査読(Codex)で塞いだ穴2つ ────────────────────────
#  (1) **段を「一番近い1本」だけで持つと、別の機械の初回警告が消える。**
#      最初の実装は鎖全体の最小値に対して段を1つだけ覚えていた。observer が残り3日で
#      段3を鳴らした後に edith が残り5日へ入ると、鎖の最小は3のままなので段は3、
#      「段3は通知済み」で**edith の話が一度も出ない**。段は **side ごと**に持つ。
#      → 対照 10-k。指摘は「状態は端末名でなく安定 ID + 期限に紐付けよ」。ここでは
#        side(self/peer)が安定 ID の役を果たす(相手は設定で1つに固定されている為)。
#  (2) **既に切れた鍵に固有の段が無い。**
#      残り -5 日は `-5 <= 1` なので段1に落ちる。段1を鳴らした後だと「通知済み」で黙る。
#      = 監視が数時間止まっている間に期限を越えると、**越えた事が一度も出ない**。
#      → 段 0(= 期限切れ)を追加し、文面も「あと N 日」ではなく「既に切れています」にする。
#      → 対照 10-l。
#
#  段の数は 45/30/14/7/3/1 から **45/14/7/1** へ減らした(同じ指摘の Q4)。どの段でも
#  Tom がやる事は「admin console で Disable key expiry を押す」の1つだけなので、
#  段を増やしても情報は増えず、鳴る回数だけ増えて経路ごと黙らされる側に効く。
#  期限切れの段を足しても窓全体で**最大5通**(元の6通より少ない)。
check_key_expiry() {
    local now last_ts out rc _k side days _rest
    local step bucket who msg nrc s_days p_days s_last p_last new_s new_p deliver_failed
    now="$(date +%s)"; last_ts=0; s_last=9999; p_last=9999
    # ★3 個読めない古い形(= "<epoch> <段>")は「未通知」に倒す。1通多く出るだけで、
    #   逆に倒すと黙る。この file は一貫して「沈黙より重複」を選んでいる。
    if [ -f "$KEY_MARK" ]; then
        read -r last_ts s_last p_last _rest < "$KEY_MARK" 2>/dev/null || true
    fi
    case "${last_ts:-}" in ''|*[!0-9]*) last_ts=0 ;; esac
    # 3欄目が無い = 段を鎖全体で1つしか持たなかった古い形。その1つが**どちらの側の段か**は
    # 記録から決められないので、両方「未通知」に倒す。多くて1台1通ぶん重複するだけで済む。
    [ -z "${p_last:-}" ] && { s_last=9999; p_last=9999; }
    case "${s_last:-}"  in ''|*[!0-9]*) s_last=9999 ;; esac
    case "${p_last:-}"  in ''|*[!0-9]*) p_last=9999 ;; esac
    [ $((now - last_ts)) -lt "$KEY_EVERY" ] && return 0

    if [ ! -x "$KEY_CHECK" ]; then
        log "鍵の残日数を測れない(台本が無い/実行できない: $KEY_CHECK)"
        notify_monitor_broken "鍵の残日数を測る台本が無い" >/dev/null
        printf '%s %s %s\n' "$now" "$s_last" "$p_last" > "$KEY_MARK" 2>>"$LOG"
        return 0
    fi

    out="$(RC_KEY_WARN_DAYS="$KEY_WARN_DAYS" "$KEY_CHECK" --porcelain --chain "$KEY_PEER" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 2 ]; then
        # ★「測れなかった」を「切れない」と読まない。監視の材料が取れていない = 監視が壊れている。
        log "鍵の残日数: 少なくとも片方を測れなかった(rc=2)"
        notify_monitor_broken "鍵の残日数を測れない" >/dev/null
        printf '%s %s %s\n' "$now" "$s_last" "$p_last" > "$KEY_MARK" 2>>"$LOG"
        return 0
    fi

    # 書式は `KEY <self|peer> <日数|-> <日付|-|none>` の固い1行/対象。side ごとに保つ。
    s_days=""; p_days=""
    while read -r _k side days _rest; do
        [ "${_k:-}" = "KEY" ] || continue
        case "$days" in ''|-) continue ;; esac
        case "$days" in *[!0-9-]*) continue ;; esac
        case "$side" in self) s_days="$days" ;; peer) p_days="$days" ;; esac
    done <<< "$out"

    if [ -z "$s_days" ] && [ -z "$p_days" ]; then
        # 両方とも「期限なし」= Tom が無効化した。段を戻し、また期限が付いた時に言い直せる様にする。
        log "鍵の残日数: 期限なし(無効化済み)"
        printf '%s %s %s\n' "$now" 9999 9999 > "$KEY_MARK" 2>>"$LOG"
        return 0
    fi

    # 降りた段 = `days <= step` を満たす中で**一番きつい** step。0 日以下は段 0(= 期限切れ)。
    key_bucket() {
        local d="$1" b=9999 st
        if [ "$d" -le 0 ]; then echo 0; return; fi
        for st in $KEY_STEPS; do
            case "$st" in ''|*[!0-9]*) continue ;; esac
            if [ "$d" -le "$st" ] && [ "$st" -lt "$b" ]; then b="$st"; fi
        done
        echo "$b"
    }

    new_s="$s_last"; new_p="$p_last"; deliver_failed=0
    for side in self peer; do
        case "$side" in
            self) days="$s_days"; bucket="$s_last" ;;
            *)    days="$p_days"; bucket="$p_last" ;;
        esac
        [ -n "$days" ] || { case "$side" in self) new_s=9999 ;; *) new_p=9999 ;; esac; continue; }
        step="$(key_bucket "$days")"
        if [ "$step" -ge 9999 ]; then
            # 段の外 = まだ遠い。ここで段を戻すので、鍵を**更新**した後も次に近付いた時に鳴る。
            case "$side" in self) new_s=9999 ;; *) new_p=9999 ;; esac
            log "鍵の残日数: $side が $days 日(段の外 = 鳴らさない)"
            continue
        fi
        if [ "$step" -ge "$bucket" ]; then
            log "鍵の残日数: $side が $days 日(段 $step は通知済み)"
            continue
        fi

        # ★文面は**我々が持っている値だけ**で組む(整数の日数と、設定に書いた相手の名前)。
        #   `$KEY_CHECK` の散文をそのまま流さないのは、`$ERR` を通知に載せないのと同じ理由。
        #   ★観測している主体を必ず名乗る(査読 Q3: 誰から見た話かが無いと取り違える)。
        case "$side" in
            self) who="この監視を動かしている機械($(hostname -s))" ;;
            *)    who="$KEY_PEER" ;;
        esac
        if [ "$step" -eq 0 ]; then
            msg="rc-backend: tailnet の鍵が**既に切れています**(${who} / $(hostname -s) から見て残り ${days} 日)。その機械は tailnet から落ちている筈で、電話の面と復旧用の ssh を同時に失っています。直す = Tailscale admin console → Machines → 該当機 → Disable key expiry、その機械で再ログイン"
        else
            msg="rc-backend: tailnet の鍵があと ${days} 日で切れます(${who} / $(hostname -s) から見た値)。切れるとその機械は tailnet から落ち、電話の面と復旧用の ssh を同時に失います。直す = Tailscale admin console → Machines → 該当機 → Disable key expiry"
        fi

        if [ "$DRY" -eq 1 ]; then
            log "DRY-RUN: 鍵の警報 [$msg]"
            echo "$msg"
            continue          # ★時計を進めない。試し打ちが本物の警報を1日黙らせない為。
        fi
        if [ ! -x "$NOTIFY" ]; then
            log "★鍵の警報を出せない(出し先が実行できない: $NOTIFY)"
            continue
        fi

        # 残り 7 日以内(と期限切れ)になってから @Tom を付ける。段を降りた時しか鳴らないので
        # 1台あたり最大5通、うち ping 付きは最後の3通。毎日鳴らす形にすると経路ごと黙らされる。
        if [ "$step" -le 7 ]; then
            printf '%s' "$msg" | "$NOTIFY"
        else
            printf '%s' "$msg" | FLEET_NOTIFY_MENTION=0 "$NOTIFY"
        fi
        nrc=$?
        log "鍵の警報を通知($side / 残り $days 日 / 段 $step / 出し先 rc=$nrc)"
        if [ "$nrc" -eq 0 ]; then
            case "$side" in self) new_s="$step" ;; *) new_p="$step" ;; esac
        else
            # ★この side の段だけ据え置く。次回また鳴らし直す。
            log "  ★出し先が失敗(rc=$nrc) — $side の記録を進めない(次回また鳴らし直す)"
            deliver_failed=1
        fi
    done

    if [ "$DRY" -eq 1 ]; then return 0; fi
    # ★配達に失敗した回は**時計を進めない**。進めると次の回が $KEY_EVERY(既定1日)の間ずっと
    #   早期 return し、出し先が直っても最大1日黙る。段は成功した side の分だけ進める
    #   (失敗した側は据え置き)ので、直った次の回に鳴るのは失敗した側だけになる。
    if [ "$deliver_failed" -eq 1 ]; then
        printf '%s %s %s\n' "$last_ts" "$new_s" "$new_p" > "$KEY_MARK" 2>>"$LOG"
    else
        printf '%s %s %s\n' "$now" "$new_s" "$new_p" > "$KEY_MARK" 2>>"$LOG"
    fi
    return 0
}
check_key_expiry

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

# ── ★監視が一周できた事を記録する(Codex Q3 の材料)──────────────────
# KIND 0/10/11 = 判定が使える答えを返した = **監視は働けている**(対象の up/down は別の話)。
# KIND 3 と その他 = 監視が壊れている回なので、ここは通らない。
# 書けなくても止めない: これは通知を読みやすくする為の材料であって、監視の可否ではない。
# ただし**黙って落とさない** —— 書けない状態が続けば通知が毎回「一度も成功していない」に
# なり、それは嘘に見える。log に理由を残して後から辿れる様にする。
case "$KIND" in
    0|10|11)
        date +%s > "$OK_MARK" 2>>"$LOG" \
            || log "  ★最終稼働時刻を書けない($OK_MARK) — 壊れた時の通知が『一度も成功していない』になる"
        ;;
esac

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
#   「Discord に載った」だけを見たいなら出し先の側に**退避を成功と数えない**切り替えが要るが、
#   `~/bin/discord-notify.sh` にその切り替えは無い(2026-08-03 実測: 環境変数は
#   `FLEET_NOTIFY_MENTION` / `ALERT_FLAG` / `REMOTE_CMD` の3つだけ)。仮に足しても
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
