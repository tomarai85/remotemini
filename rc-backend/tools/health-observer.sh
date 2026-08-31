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
# ★名前解決を迂回する口(既定は空 = 使わない = 従来どおり)。
#   2026-08-08、athenas に据えようとして見つけた: そのノードは MagicDNS が切れており
#   (`tailscale debug prefs` の `CorpDNS: false`)、`desk.tailnet.example` を引けない。
#   その時 curl が返すのは exit 6(名前が引けない)で、**「対象が落ちている」と区別が付かない**。
#   据えたその日から永久に嘘の赤を出し、閾値で1回鳴ってから黙る —— yoda の 46 時間と同じ形。
#   ここに tailnet の住所を入れると curl は住所へ繋ぎ、証明書と SNI は $HOST で検証する
#   (`--resolve`)。**機械の DNS 設定には触らない** = 他の常駐サービスを巻き込まない。
#   前提: 443(既定の https)。`RC_HEALTH_URL` に別 port を書く時はこの口を使わない事。
RESOLVE="${RC_HEALTH_RESOLVE:-}"
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
# ★**表示用の名前と、機体を引く名前は型が違う**(Codex 2026-08-26)。
#   以前は `${RC_HEALTH_KEY_PEER:-$HOST}` と書いて `HOST` を継いでいた。だが `HOST` は
#   URL を明示した構成では**人が読む札**になる —— 実際 athenas の `observer.conf` は
#   `RC_HEALTH_HOST="friday(loopback)"` を置いている(URL は loopback で別に指定済み)。
#   その札を機体名として引きに行くので必ず失敗し、`rc=2` = 「監視が壊れている」を鳴らした。
#   実測 2026-08-26 11:08、それが本物の障害でない事は同じ log の前後が全部 `ok` である事で判る。
#
#   ★狼を2回叫んだ見張りは、3回目に読まれない。だから継承を切る。
#   **未設定 = 相手が居ない**(単一機体構成)として扱い、鳴らさない。
#   相手を明示した時だけ、測れない事を「監視が壊れている」と言う —— そちらは正しい。
KEY_PEER="${RC_HEALTH_KEY_PEER:-}"           # 監視している相手。**空 = 相手が居ない**
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

# ---- 公開面への相乗りを見張る(2026-08-26 新設)------------------------------------
# 何を問うか: 「**公開されている入口の下に、机(127.0.0.1:$EXP_PORT)へ向く経路が在るか**」。
# なぜ此処か(Codex 2026-08-26 の裁定1): `tailscale serve status` は**この機体でしか**
#   権威ある値を読めない。机の外(Jervis)から見に行く案は、回線が不定期に落ちる度に
#   「到達できない」を「露出しているかもしれない」に翻訳してしまう = 安全の警報を
#   回線障害から作る事になる。
# ★間隔は KEY_* と違って**毎回**測る。serve の設定は1コマンドで変わるので、
#   日に1回では「変わって・使われて・戻った」を丸ごと見逃す。読むのは local なので安い。
EXP_CHECK="${RC_HEALTH_EXP_CHECK:-$ROOT/tools/funnel-exposure-check.sh}"
EXP_PORT="${RC_HEALTH_EXP_PORT:-8787}"
EXP_TS="${RC_HEALTH_EXP_TS:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
EXP_MARK="${RC_HEALTH_EXP_MARK:-$STATE.exposure}"
# 「測れなかった」が続いた時に鳴らす回数。**露出そのものより緩く、生存より厳しい** ——
# これは「保証を失った」であって「壊れた」でも「安全」でもない(Codex 裁定2)。
EXP_BLIND_THRESHOLD="${RC_HEALTH_EXP_BLIND_THRESHOLD:-2}"


MODE="probe"; DRY=0; EXPOSURE_ONLY=0
for a in "$@"; do
    case "$a" in
        --inject-fail) MODE="fail" ;;
        --inject-ok)   MODE="ok" ;;
        --dry-run)     DRY=1 ;;
        # ★露出の節だけを叩く口(2026-08-26)。対照の為に足した ——
        #   関数を sed で切り出して eval する駆動は、本文の書式が少し変わるだけで
        #   黙って何も走らなくなる(実際そうなり、対照が「鳴らない」と赤を出した。
        #   あれは実装の欠陥ではなく**駆動の欠陥**で、区別が付かないのが一番悪い)。
        #   本物の口を1つ開ける方が、測る物と測られる物が一致する。
        --exposure-only) EXPOSURE_ONLY=1 ;;
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

    # ★相手が居ない構成では、相手を引きに行かない。引けば必ず失敗し、その失敗を
    #   「監視が壊れている」と読む —— 居ない物を測れないのは異常ではない。
    # ★相手が居ない構成では `--chain` を渡さない。渡せば居ない相手を引きに行って必ず失敗し、
    #   その失敗を「監視が壊れている」と読む —— 居ない物を測れないのは異常ではない。
    #   ★判定は**後段の共通の rc=2 に1本化する**。此処にもう1つ置くと二重判定になり、
    #     片方だけ直しても もう片方が古い文言で鳴る(2026-08-27 に実際にそうなった)。
    if [ -z "$KEY_PEER" ]; then
        out="$(RC_KEY_WARN_DAYS="$KEY_WARN_DAYS" "$KEY_CHECK" --porcelain 2>/dev/null)"
    else
        out="$(RC_KEY_WARN_DAYS="$KEY_WARN_DAYS" "$KEY_CHECK" --porcelain --chain "$KEY_PEER" 2>/dev/null)"
    fi
    rc=$?
    if [ "$rc" -eq 2 ]; then
        # ★「測れなかった」を「切れない」と読まない。監視の材料が取れていない = 監視が壊れている。
        # ★どちらの構成で失敗したかを残す。相手なしで失敗 = 自分の側すら測れない
        #   (これは本当に監視が壊れている)。相手ありで失敗 = どちらかが測れない。
        if [ -z "$KEY_PEER" ]; then
            log "鍵の残日数: 自分の側を測れなかった(rc=2 / 相手は設定されていない)"
        else
            log "鍵の残日数: 少なくとも片方を測れなかった(rc=2 / 相手=$KEY_PEER)"
        fi
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

# ── 公開面への相乗り ───────────────────────────────────────────────
# 記録 `$EXP_MARK` の中身 = "<最後の判定> <連続で測れなかった回数>"。
#   判定 = safe / exposed / blind。
#
# ★通知の設計(Codex 2026-08-26 の裁定2、そのまま採った):
#   - **露出(exit 1)は閾値を置かずに即時**。生存の様に「3回続いたら」ではない ——
#     生存は揺れるが、公開設定は揺れない。1回でも見えたらそれは事実。
#   - **測れない(exit 3)は別の事象**として、緩めの閾値で鳴らす。これは「露出している」
#     でも「安全」でもなく **「保証を失った」**。同じ通知に混ぜると、どちらの意味でも
#     読めない警報になる。
#   - 安全(exit 0)へ戻ったら記録だけ更新して黙る(復旧の連呼をしない)。
#
# ★此の監視が答えない事を、先に書いておく(Codex 裁定4):
#   **見張りは事後にしか気付かない。** 経路を足して・使って・消す、が観測の隙間に収まれば
#   何も残らない。ここは防止ではなく検出で、防止は別の層(机が鍵を要求する事、
#   `rc-backend-launch.sh` が `funneled` の入口へ自分から乗らない事)が受け持つ。
check_exposure() {
    local now verdict prev_v prev_blind out rc
    now="$(date +%s)"
    prev_v="safe"; prev_blind=0
    if [ -f "$EXP_MARK" ]; then
        read -r prev_v prev_blind _rest < "$EXP_MARK" 2>/dev/null || true
        case "${prev_blind:-}" in ''|*[!0-9]*) prev_blind=0 ;; esac
        case "${prev_v:-}" in safe|exposed|blind) ;; *) prev_v="safe" ;; esac
    fi

    if [ ! -x "$EXP_CHECK" ]; then
        log "公開面を測れない(台本が無い/実行できない: $EXP_CHECK)"
        notify_monitor_broken "公開面を測る台本が無い" >/dev/null
        printf '%s %s\n' "blind" "$((prev_blind + 1))" > "$EXP_MARK" 2>>"$LOG"
        return 0
    fi
    if [ ! -x "$EXP_TS" ]; then
        # ★tailscale の実体が無い = この機体では測れない。**安全と言わない。**
        log "公開面を測れない(tailscale が無い: $EXP_TS)"
        printf '%s %s\n' "blind" "$((prev_blind + 1))" > "$EXP_MARK" 2>>"$LOG"
        [ "$((prev_blind + 1))" -ge "$EXP_BLIND_THRESHOLD" ] \
            && notify_monitor_broken "公開面を測れない(tailscale が無い)" >/dev/null
        return 0
    fi

    out="$("$EXP_TS" serve status --json 2>/dev/null | "$EXP_CHECK" "$EXP_PORT" 2>/dev/null)"
    rc=$?
    case "$rc" in
        0)
            [ "$prev_v" != "safe" ] && log "公開面: 机へ向く経路は無い(前回は $prev_v)"
            printf '%s %s\n' "safe" "0" > "$EXP_MARK" 2>>"$LOG"
            ;;
        1)
            # ★閾値を置かない。1回でも見えたら事実。
            log "★★公開面が机へ繋がっている: $out"
            printf '%s %s\n' "exposed" "0" > "$EXP_MARK" 2>>"$LOG"
            if [ "$DRY" -eq 1 ]; then
                echo "公開面が机(127.0.0.1:$EXP_PORT)へ繋がっています: $out"
            elif [ -x "$NOTIFY" ]; then
                # ★本文は **stdin** で渡す。この file の他の 3 箇所(168 / 321 / 323)が
                #   全部 stdin なので、此処だけ argv だと**偽の出し先が片方しか実装しない**。
                #   実際 `test/health-observer-controls.sh` の作り物は `$(cat)` しか読まない ——
                #   此処に検査を足した人は「鳴っているのに空文字が記録される」を見る事になり、
                #   実装の欠陥と駆動の欠陥が出力から区別できなくなる。
                #   (2026-08-26、別セッションの掃き取りが flagged。本物の `~/bin/discord-notify.sh`(repo の外)は
                #    両方読むので production は壊れていないが、**規約を1箇所だけ破る**のが害)
                printf '%s' "★公開面が机へ繋がっています($out)。生きた端末の操縦面が公開インターネットに出ます。" \
                    | "$NOTIFY" >/dev/null 2>&1 || \
                    log "★露出を検出したが通知を出せなかった"
            else
                log "★露出を検出したが出し先が実行できない: $NOTIFY"
            fi
            ;;
        *)
            # 3 = 読めない / それ以外も「判らない」に倒す。**安全と混ぜない。**
            log "公開面を測れなかった(rc=$rc)= 保証を失った"
            printf '%s %s\n' "blind" "$((prev_blind + 1))" > "$EXP_MARK" 2>>"$LOG"
            [ "$((prev_blind + 1))" -ge "$EXP_BLIND_THRESHOLD" ] \
                && notify_monitor_broken "公開面を測れない(rc=$rc)" >/dev/null
            ;;
    esac
    return 0
}
check_exposure
[ "$EXPOSURE_ONLY" -eq 1 ] && exit 0

# ── 掃除の job と配布口を見張る(2026-08-30 新設 / 同日 Codex 査読で作り直し)──────
# 何を問うか: 「**この鎖の中で、誰も見ていない機械が止まっていないか**」。
#   `com.fleet.rc-log-cap` は log を毎時掃く。止まっても誰も気付かない —— 気付くのは
#   disk が埋まった時か、台帳を読もうとして log が既に消えていた時。
#   配布口(OTA)は Tom の電話への**唯一の**経路。古い版を配り始めても、Tom が
#   「入れ直したのに直っていない」と気付くまで誰も知らない。
#
# ★言い方の規約: **状態の名前が変わった時だけ1行**。毎回書くと此の2つで log が埋まり、
#   本物の up/down が読めなくなる —— 鍵の段が「段を降りた時だけ」なのと同じ理由。
#   走った事の証拠は log ではなく記録 file の mtime が持つ。
#
# ★通知に `notify_monitor_broken` を**使わない**。あの文面は
#   「rc-backend の監視側が壊れています」で固定で、掃除の job が止まった事を其の文で
#   流すと**壊れていない物を壊れたと言う**事になる。時計も分ける —— 混ぜると、
#   掃除の話で6時間黙った隙に監視そのものが壊れても鳴らない。
#
# ★2026-08-30 の Codex 査読で直した4つ(初版は全部踏んでいた):
#   1. `巻き戻り(通知済) → 未配達 → ok` で**復帰通知が永久に消えた**。現在の状態に
#      括り付けた「通知済み」だけでは、間に別の状態を挟むと消える。だから
#      「**まだ片付いていないと言った問題が在るか**(open)」を状態と別に持つ。
#   2. `--dry-run` が「通知済み」を本番の記録に書いていた = 一度試すと本番が黙る。
#      dry の記録は `<file>.dry` へ分ける(混ざらないなら試して良い)。
#   3. 復帰通知の**失敗を捨てて** ok を書いていた = 直った事を永久に言わない。
#      配達できるまで open を降ろさない。
#   4. `未配達` を鳴らさない事にしていた。それは「**直っている物が Tom の電話に
#      届いていない**」= 一番利用者に見える失敗を捨てる判断だった。鳴らす —— ただし
#      HEAD との差ではなく**その状態が続いた時間**を起点にする(私が触っている間は
#      常に真なので、猶予を跨いだ時だけ1回)。
# ★既定は**空 = この機体では測らない**。鍵の `KEY_PEER` / 配布口の `OTA_CHECK` と同じ形。
#   `com.fleet.rc-log-cap` を回しているのは friday だけなので、他の機体の観測器が
#   其の生死を語る資格は無い —— 既定で実パスを読みに行くと、掃除を回していない機体で
#   必ず「印が無い」を鳴らす(2026-08-30、既存の対照 5 本が此れを掴んだ)。
#   回している機体の conf が指す。指していない = 測らない。
CAP_HEARTBEAT="${RC_HEALTH_CAP_MARK-}"
CAP_STATE_F="${RC_HEALTH_CAP_STATE:-$STATE.cap-seen}"
CAP_EVERY="${RC_HEALTH_CAP_EVERY:-3600}"      # 掃除は毎時。測るのは stat 1回なので安い
CAP_STALE_S="${RC_HEALTH_CAP_STALE_S:-10800}" # 3 時間成功していない = 3 回落とした
# 「印が無い」を鳴らすまでの猶予。★据え付けた直後は**まだ一度も走っていない**ので
#   印が無いのが正常 —— 猶予無しで鳴らすと、新しい機体に据える度に必ず1通誤報する
#   (2026-08-30 に既存の対照 5 本が此れを掴んだ)。掃除が走る機会を跨いでも
#   まだ無い時に初めて言う。`stale` と `failed` には猶予を置かない —— そちらは
#   「在った物が壊れた」で、据え付け直後と取り違えようが無い。
CAP_MISSING_GRACE="${RC_HEALTH_CAP_MISSING_GRACE:-7200}"

# ★`:-` でなく `-`(コロン無し)。`:-` は**空文字も未設定として既定へ倒す**ので、
#   「この機体では測らない」と明示した空が既定の台本に化ける。未設定 = 既定を使う、
#   空と明示 = 測らない、を区別する必要が在るのは此処だけ。
OTA_CHECK="${RC_HEALTH_OTA_CHECK-$ROOT/tools/ota-freshness-check.sh}"
OTA_STATE_F="${RC_HEALTH_OTA_STATE:-$STATE.ota-seen}"
OTA_EVERY="${RC_HEALTH_OTA_EVERY:-86400}"     # ssh を1本張るので日に1回
# 「測れない」が続いた時に鳴らすまでの**時間**。回数で数えると、日に1回の測定では
# 2 回目まで 48 時間かかる —— 計器が盲になった事を2日後に知らせる警報に意味は無い。
OTA_BLIND_S="${RC_HEALTH_OTA_BLIND_S:-3600}"
# 「出来ているのに配っていない」を鳴らすまでの猶予。私の作業中は常に真なので、
# 作業の1回ぶんより長く取る。跨いだら**1回だけ**言う。
OTA_UNDELIVERED_GRACE="${RC_HEALTH_OTA_UNDELIVERED_GRACE:-172800}"
# 壊れている間の測り直しの間隔。★これが Codex の指摘3/4 の本体 ——
# 通知の再送も、盲の時間を数える刻みも、**測る周期に縛られている**。
# 壊れている間だけ細かく測れば、両方が同時に直る。直れば元の周期に戻る。
BAD_EVERY="${RC_HEALTH_BAD_EVERY:-900}"
# 外の台本に許す時間。配布口の検査は中で ssh を張るので、相手が黙ると此処が返らない。
OTA_TIMEOUT="${RC_HEALTH_OTA_TIMEOUT:-45}"
# 台本へ渡す引数。★**自動判定にしない** —— 「材料が無いから局所模式へ落ちる」形にすると、
#   材料を置き忘れた日に検査が黙って別の物を測り始め、緑の意味が変わる。
#   どちらを測るかは据えた人が conf に書く。
OTA_ARGS="${RC_HEALTH_OTA_ARGS:-}"
PERL_BIN="${RC_HEALTH_PERL:-$(command -v perl 2>/dev/null || echo '')}"

# ── 電話が現れた事を1回だけ言う(2026-08-31)──────────────────────────────
# ★なぜ要るか: 「配布口が 115 を配っている」までは机の側で証明できるが、
#   **Tom の電話が実際に其れを動かしているか**は電話が名乗るまで誰にも判らない。
#   実測(2026-08-31): 彼の電話は配布口へ一度も取りに来ておらず、要求ログの
#   `client=app` は 861 本 在るのに版は全部 `-`(名乗る前の版)。
#   人が ssh して grep するしか無い状態だったので、机の側から1回だけ言わせる。
# ★**1回だけ**。版が変わるまで黙る —— 毎時「電話は 115 です」と鳴る警報は読まれない。
#   之は異常の通知ではなく**出来事の通知**なので、状態機械ではなく印 file で足りる。
# ★既定は空 = **この機体では見ない**(`CAP_MARK` / `OTA_CHECK` と同じ形)。
#   要求ログを持つのは机だけなので、他の機体が語る資格は無い。
PHONE_LOG="${RC_HEALTH_PHONE_LOG-}"
PHONE_MARK="${RC_HEALTH_PHONE_MARK:-$STATE.phone-seen}"
PHONE_EVERY="${RC_HEALTH_PHONE_EVERY:-600}"   # grep 1回なので安い。既定は毎回

# 記録の中身 = "<最後に測った epoch> <状態> <通知済み 0|1> <続いた回数> <未解決 0|1> <この状態になった epoch>"
subject_path() { [ "$DRY" -eq 1 ] && printf '%s.dry' "$1" || printf '%s' "$1"; }

subject_read() {   # subject_read <file> → S_TS / S_STATE / S_DONE / S_RUN / S_OPEN / S_SINCE
    local now; now="$(date +%s)"
    S_TS=0; S_STATE="unknown"; S_DONE=0; S_RUN=0; S_OPEN=0; S_SINCE=0
    [ -f "$1" ] || return 0
    # ★欄が 6 でない行は**丸ごと未知に倒す**(Codex の指摘)。欄が1つ増減しただけで
    #   全部が1つずれ、状態の名前の場所に epoch が入る —— そのずれは出力に出ないので
    #   気付く道が無い。欄数を検めれば、壊れた記録は「まだ見ていない」に落ちるだけで済む。
    if [ "$(awk 'NR==1{print NF; exit}' "$1" 2>/dev/null)" != "6" ]; then return 0; fi
    read -r S_TS S_STATE S_DONE S_RUN S_OPEN S_SINCE _rest < "$1" 2>/dev/null || true
    case "${S_TS:-}"    in ''|*[!0-9]*) S_TS=0 ;; esac
    case "${S_RUN:-}"   in ''|*[!0-9]*) S_RUN=0 ;; esac
    case "${S_SINCE:-}" in ''|*[!0-9]*) S_SINCE=0 ;; esac
    # ★0|1 を**厳密に**通す。数字でありさえすれば良い書き方だと `2` が入った時に
    #   「通知済み」とも「未解決」とも読めない値で両方の枝が黙る(Codex 指摘)。
    [ "${S_DONE:-}" = "1" ] || S_DONE=0
    [ "${S_OPEN:-}" = "1" ] || S_OPEN=0
    [ -n "${S_STATE:-}" ] || S_STATE="unknown"
    # ★未来の時刻は 0 に倒す。時計が飛ぶと `now - S_TS` が負になり、
    #   「まだ間隔が空いていない」として**二度と測らなくなる**(Codex 指摘)。
    [ "$S_TS" -gt "$now" ] 2>/dev/null && S_TS=0
    [ "$S_SINCE" -gt "$now" ] 2>/dev/null && S_SINCE="$now"
    return 0
}

subject_write() {  # subject_write <file> <epoch> <状態> <通知済み> <回数> <未解決> <since>
    local f="$1" tmp
    # ★差し替えで書く。printf の途中で死ぬと半端な行が残り、次に読んだ側が
    #   別の状態として読む(Codex 指摘)。
    tmp="$(mktemp "$(dirname "$f")/.subj.XXXXXX" 2>/dev/null)" || {
        log "★状態を書けない($f) — 次回また同じ判定になる(重複は沈黙よりまし)"; return 0; }
    if printf '%s %s %s %s %s %s\n' "$2" "$3" "$4" "$5" "$6" "$7" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f" 2>/dev/null || { /bin/rm -f "$tmp"; log "★状態を差し替えられない($f)"; }
    else
        /bin/rm -f "$tmp"; log "★状態を書けない($f)"
    fi
    return 0
}

# 外の台本を**時間で殴って**走らせる。返りは stdout、rc はその台本の物(切られたら非 0)。
# ★これが無いと、配布口の検査(中で ssh を張る)が固まった時に**観測器ごと止まる** ——
#   止まれば `open=1` の言い残しにも永久に到達しない(2026-08-30、Codex の指摘。
#   私は「壊れている間は細かく測り直す」で再送を代替したので、
#   **1回でも到達しない事が有り得る**という穴が致命になる)。
# ★`timeout(1)` は macOS の既定に無い。perl の `alarm` は在る(切られると rc=142)。
#   perl も無い環境では**時間を掛けずに走らせる**しか無いので、その事を log に残す ——
#   黙って無防備になるのが一番悪い。
# ★出力は**一時 file 経由**で受ける。`$( )` に直接流すと、時間で殺した後も
#   **孤児になった孫(ssh や sleep)がパイプの書き口を握ったまま**なので、
#   命令置換が EOF を待って結局最後まで止まる —— 殺せているのに待つ、という
#   一番判りにくい形になる(2026-08-30 実測: 3 秒で切った筈が 60 秒かかった)。
run_bounded() {   # run_bounded <秒> <台本> [引数...]
    local secs="$1"; shift
    local tf rc
    tf="$(mktemp 2>/dev/null)" || { "$@" 2>&1; return $?; }
    if [ -n "$PERL_BIN" ]; then
        "$PERL_BIN" -e 'alarm shift; exec @ARGV' "$secs" "$@" > "$tf" 2>&1
    else
        "$@" > "$tf" 2>&1
    fi
    rc=$?
    cat "$tf"; /bin/rm -f "$tf"
    return "$rc"
}

# 出し先へ1通。`notify_monitor_broken` と**時計を分ける**(上の註記)。
# 返り値 0 = 配達できた(= 「言った」と記録してよい)。非 0 = 出せていない。
notify_fleet() {   # notify_fleet <log 用の短い名> <本文>
    local tag="$1" msg="$2" nrc
    if [ "$DRY" -eq 1 ]; then
        log "DRY-RUN: $tag — 通知は出さない($msg)"
        return 0
    fi
    if [ ! -x "$NOTIFY" ]; then
        log "★$tag を知らせたいが出し先を実行できない: $NOTIFY"
        return 1
    fi
    printf '%s' "$msg" | "$NOTIFY"; nrc=$?
    log "$tag を通知(出し先 rc=$nrc)"
    return "$nrc"
}

# 状態が変わった時だけ 1 行 log し、猶予を跨いだ問題を**まだ言っていなければ**1 通出す。
# 戻った時は、**言った問題が残っている時だけ**戻った事を言い、配達できるまで降ろさない。
subject_settle() { # subject_settle <記録> <短い名> <新状態> <本文> <epoch> <鳴らすまでの猶予秒>
    local f="$1" tag="$2" state="$3" msg="$4" now="$5" grace="${6:-0}"
    local announced=0 run=1 since="$now" open="$S_OPEN"
    if [ "$state" = "$S_STATE" ]; then
        run=$((S_RUN + 1)); announced="$S_DONE"; since="$S_SINCE"
        [ "$since" -gt 0 ] || since="$now"
    else
        log "$tag: 状態が $S_STATE → $state"
    fi

    if [ "$state" != "ok" ] && [ "$announced" -eq 0 ] && [ $((now - since)) -ge "$grace" ]; then
        if notify_fleet "$tag($state)" "$msg"; then announced=1; open=1; fi
    fi
    # ★「言った問題」が残っている時だけ復帰を言う。言っていない状態(猶予の内に
    #   直った物など)の復帰を報せると、Tom は身に覚えの無い通知を受け取る。
    if [ "$state" = "ok" ] && [ "$open" -eq 1 ]; then
        if notify_fleet "$tag(戻った)" "$(hostname -s): $tag が直りました($S_STATE から回復)。"; then
            open=0
        fi
    fi
    subject_write "$f" "$now" "$state" "$announced" "$run" "$open" "$since"
}

# 壊れている間・言い残しが在る間は細かく測り直す。直れば元の周期へ戻る。
subject_due() {   # subject_due <now> <通常の間隔> → 0=測る時
    local now="$1" every="$2"
    { [ "$S_STATE" != "ok" ] && [ "$S_STATE" != "unknown" ]; } || [ "$S_OPEN" -eq 1 ] && every="$BAD_EVERY"
    [ $((now - S_TS)) -ge "$every" ]
}

# ── 掃除の job(com.fleet.rc-log-cap)が生きているか ─────────────────────────
# ★読むのは job 自身が書く**生存の印**(`<試みた epoch> <最後に成功した epoch> <終了コード>`)。
#   初版は log の「最後の行が掃除の要約か」で読んでいた。それは他人の出力の文言に
#   縛られる契約で、誰かが行を1本足した日から永久に「壊れている」と言い、Tom は
#   其の警告を読まなくなる(Codex 指摘2)。印は job が全部終わってから差し替える。
check_log_cap() {
    local now state msg f age rc ok_at
    now="$(date +%s)"
    [ -n "$CAP_HEARTBEAT" ] || return 0        # 空 = この機体では掃除を回していない
    f="$(subject_path "$CAP_STATE_F")"
    subject_read "$f"
    subject_due "$now" "$CAP_EVERY" || return 0

    if [ ! -f "$CAP_HEARTBEAT" ]; then
        state="missing"; age=0; rc=0
    else
        ok_at="$(awk '{print $2}' "$CAP_HEARTBEAT" 2>/dev/null)"
        rc="$(awk '{print $3}' "$CAP_HEARTBEAT" 2>/dev/null)"
        case "${ok_at:-}" in ''|*[!0-9]*) ok_at=0 ;; esac
        case "${rc:-}"    in ''|*[!0-9]*) rc=1 ;; esac   # 読めない = 失敗側に倒す
        age=$((now - ok_at))
        if   [ "$rc" -ne 0 ]              ; then state="failed"
        elif [ "$age" -ge "$CAP_STALE_S" ]; then state="stale"
        else                                     state="ok"
        fi
    fi

    case "$state" in
        missing) msg="$(hostname -s): com.fleet.rc-log-cap の生存の印が在りません($CAP_HEARTBEAT)。log の上限が掛かっていない可能性。" ;;
        stale)   msg="$(hostname -s): com.fleet.rc-log-cap が $((age / 3600)) 時間ぶん成功していません。log の上限が掛かっていない。" ;;
        failed)  msg="$(hostname -s): com.fleet.rc-log-cap の最後の回が失敗しています(終了コード $rc)。$CAP_HEARTBEAT" ;;
        *)       msg="" ;;
    esac
    local grace=0
    [ "$state" = "missing" ] && grace="$CAP_MISSING_GRACE"
    subject_settle "$f" "rc-log-cap" "$state" "$msg" "$now" "$grace"
}

# ── 電話が版を名乗ったら1回だけ言う ───────────────────────────────────────
# 判定は3つだけ: 「見ていない」/「前と同じ版」/「新しい版を名乗った」。
# 鳴るのは3つ目だけ。
check_phone_sighting() {
    local now line build seen f
    now="$(date +%s)"
    [ -n "$PHONE_LOG" ] || return 0
    [ -f "$PHONE_LOG" ] || return 0
    f="$(subject_path "$PHONE_MARK")"

    # 周期。★印 file の**更新時刻**では測らない —— 印は「版が変わった時」だけ動くので、
    #   其れを周期に使うと、変わらない限り毎回 grep する事になる(安いが、
    #   「いつ見たか」と「いつ変わったか」を同じ数で持つと後から読めない)。
    local last=0
    [ -f "$f.at" ] && last="$(tr -d '[:space:]' < "$f.at" 2>/dev/null)"
    case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
    [ "$PHONE_EVERY" -gt 0 ] && [ $((now - last)) -lt "$PHONE_EVERY" ] && return 0
    printf '%s\n' "$now" > "$f.at" 2>/dev/null

    # ★見るのは**今 走っている実装が書いた行だけ**(2026-08-31、実測で踏んだ)。
    #   08-31 より前の机は `build=` に UA 由来の**売り物の版**を書いていた(実測 `1`)。
    #   全部の行を見ると、其の古い数字を「電話が build=1 を名乗った」と読んで鳴る ——
    #   実際に friday の実ログで1度 鳴った。
    #   境界は推測しない: 机は起動のたびに `[rc-backend] listening on …` を書くので、
    #   **最後の其の行より後**が今の走行。時刻の比較も閾値も要らない。
    #   ★上限で切られて錨が消えた時は**黙る** —— 「判らない」を「見た」に丸めない。
    #   `build=-` は名乗っていない版(名乗るのは build 106 以降)。数えない。
    line="$(/usr/bin/awk '
        /^\[rc-backend\] listening on /  { seen = 1; last = ""; next }
        seen && /client=app/ && !/build=-/ { last = $0 }
        END { if (seen) print last }
    ' "$PHONE_LOG" 2>/dev/null)"
    [ -n "$line" ] || return 0
    build="$(printf '%s' "$line" | /usr/bin/sed -n 's/.* build=\([0-9][0-9]*\) .*/\1/p')"
    [ -n "$build" ] || return 0

    # ★憶えるのは「最後の版」ではなく **今までに言った版の集合**(Codex 2026-08-31)。
    #   最後の1つだけだと `114 → 115 → 114`(巻き戻し)で **114 を二度 言う**。
    #   一度言った版は二度と言わない。file は追記だけなので壊れ方も単純。
    if [ -f "$f" ] && grep -qx "$build" "$f" 2>/dev/null; then
        return 0
    fi
    seen="$(tail -1 "$f" 2>/dev/null)"

    log "電話が版を名乗った: build=$build(前回=${seen:-無し})"
    # ★言えた時だけ憶える。出し先が落ちていたら次の回にもう一度言う
    #   —— 重複は沈黙よりまし(此の木の他の枝と同じ判断)。
    notify_fleet "電話の版" \
        "$(hostname -s): 電話が build=$build を名乗りました(前回=${seen:-一度も無し})。" \
        && printf '%s\n' "$build" >> "$f" 2>/dev/null
    return 0
}

# ── 配布口が古い版を配っていないか ─────────────────────────────────────────
# `ota-freshness-check.sh` の終了コード: 0=順当 / 1=**配布が承認済みより古い**(巻き戻り) /
#   2=測れない / 3=承認済みが HEAD より古い(出来ているのに配っていない)。
check_ota_fresh() {
    local now rc out state msg grace f
    now="$(date +%s)"
    f="$(subject_path "$OTA_STATE_F")"
    subject_read "$f"
    subject_due "$now" "$OTA_EVERY" || return 0

    # ★空 = **この機体では測らない**。鍵の `KEY_PEER` と同じ形。
    #   測る材料(署名済み plist と承認の記録)は**焼いた機械にしか無い**ので、
    #   持っていない機体で測ろうとすれば必ず 2 を返し、その 2 を「配布口が判らない」
    #   として毎時鳴らす事になる —— 居ない物を測れないのは異常ではない。
    #   材料が揃った機体だけが台本を指す。
    if [ -z "$OTA_CHECK" ]; then
        return 0
    fi
    if [ ! -x "$OTA_CHECK" ]; then
        subject_settle "$f" "ota-freshness" "unmeasurable" \
            "$(hostname -s): 配布口の鮮度を測る台本が在りません($OTA_CHECK)。" "$now" "$OTA_BLIND_S"
        return 0
    fi

    # ★引数は**空かどうかで枝を分ける**(配列に入れて展開しない)。macOS の /bin/bash は
    #   3.2 で、`set -u` の下では空配列の `"${a[@]}"` 自体が落ちる —— 此の file が
    #   `RESOLVE` で同じ結論に到達している。
    if [ -n "$OTA_ARGS" ]; then
        out="$(run_bounded "$OTA_TIMEOUT" "$OTA_CHECK" $OTA_ARGS)"; rc=$?
    else
        out="$(run_bounded "$OTA_TIMEOUT" "$OTA_CHECK")"; rc=$?
    fi
    # ★切られた(rc=142 = SIGALRM)は「測れなかった」であって「古くない」ではない。
    #   下の `*)` が拾うので此処で分岐は要らないが、log に理由を残す。
    [ "$rc" -eq 142 ] && log "ota-freshness: $OTA_TIMEOUT 秒で切った(相手が返らない)"
    grace=0
    case "$rc" in
        0) state="ok" ;;
        1) state="rollback" ;;
        3) state="undelivered"; grace="$OTA_UNDELIVERED_GRACE" ;;
        *) state="unmeasurable"; grace="$OTA_BLIND_S" ;;
    esac
    case "$state" in
        rollback)     msg="$(hostname -s): 配布口が**承認済みより古い版**を配っています。Tom が入れ直すと巻き戻ります。$(printf '%s' "$out" | tail -1)" ;;
        undelivered)  msg="$(hostname -s): 配布口に**出来ている版が届いていません**($((OTA_UNDELIVERED_GRACE / 3600)) 時間このまま)。入れ直しても古いままです。$(printf '%s' "$out" | tail -1)" ;;
        unmeasurable) msg="$(hostname -s): 配布口の鮮度を測れません($rc)。古くないと読まない事。$(printf '%s' "$out" | tail -1)" ;;
        *)            msg="" ;;
    esac
    subject_settle "$f" "ota-freshness" "$state" "$msg" "$now" "$grace"
}

check_log_cap
check_ota_fresh
check_phone_sighting

# ── 1回叩く ───────────────────────────────────────────────────────
# 本体は捨てずに見る: 200 を返すだけの別物(tailscale の受け口や proxy)を「生きている」と
# 読まない為。★ただし本体を**ログにも通知にも載せない**(会話の情報が混ざる余地を作らない)。
probe() {
    local body code rc
    # ★`RESOLVE` が空かどうかで**枝を分ける**(配列に入れて展開しない)。
    #   macOS の /bin/bash は 3.2 で、`set -u` の下では**空配列の `"${a[@]}"` 自体が落ちる**。
    #   ここは観測の心臓なので、書き方の巧拙より落ちない事を採る。
    if [ -n "$RESOLVE" ]; then
        body="$(curl -sS -m 8 --resolve "$HOST:443:$RESOLVE" -w $'\n%{http_code}' "$URL" 2>/dev/null)"; rc=$?
    else
        body="$(curl -sS -m 8 -w $'\n%{http_code}' "$URL" 2>/dev/null)"; rc=$?
    fi
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
