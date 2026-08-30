Review a change to a production health observer. Be brief — attack the design decisions, don't summarise my code back to me.

## Context

A Mac mini ("friday") runs a Node backend that an iPhone app drives. A `launchd` job `com.fleet.rc-log-cap` sweeps its logs hourly (truncate-keep-tail, no root). A tailnet-only OTA endpoint serves the signed `.ipa` — it is the owner's **only** route to install the app on his phone.

Two failures had no observer at all: the cap job dying (logs grow until the disk or until a truncation eats the census window), and the OTA point serving an older build than the record allows (the owner reinstalls and silently rolls back).

The health observer already watches: service up/down (via a Node step that owns the notify state machine), tailnet key expiry (steps 45/14/7/1 days, fires once per step crossed), and public-surface exposure. Its governing doctrine, written in its own comments after a real incident: **a warning that is always on is not read on the day it is true.** A previous false alarm ("the monitor is broken", twice, from a config type confusion) is cited in the file as the reason.

## What I added

Two branches, each with a state file holding `<last-measure-epoch> <state> <announced 0|1> <consecutive-runs>`.

**Cap** (`CAP_EVERY` default 3600s, measurement is a local `stat` + `tail -1`):
- file missing → `missing`
- mtime older than 3h → `stale`
- last line is `log-cap-all:` **and** contains `★` → `failed`
- last line is not a `log-cap-all:` line → `failed`
- else → `ok`

That last rule exists because the plist runs `census && exec cap`. If the census fails, the cap never runs, but the census **already wrote to the same log**, so the mtime is fresh. mtime alone reads that as healthy. A control (C3) pins it.

**OTA** (`OTA_EVERY` default 86400s, costs one ssh). `ota-freshness-check.sh` exit codes: 0 ok, 1 published < approved (rollback), 2 unmeasurable, 3 approved < HEAD (built but never distributed).
- `1` → notify immediately
- `2` → notify only after 2 consecutive measurements (mirrors an existing `EXP_BLIND_THRESHOLD` in the same file, which exists because the observer's network is intermittent)
- `3` → **log the state change, never notify**
- `0` → silent

Notification uses a new `notify_fleet` with its **own** suppression state, not the existing `notify_monitor_broken` — that function's message text is hard-coded to "rc-backend の監視側が壊れています" (the monitor itself is broken), which would be a false claim about what failed.

Both branches log **only on state change**, and notify once per entry into a bad state. Recovery is announced **only if the problem was announced**.

## Controls

12 behavioural controls, all green. Four mutations each turn exactly one control red:
- drop the "last line" rule → C3 red
- drop the `announced` check → C6 red (3 notices instead of 1)
- notify on `undelivered` → C8 red
- notify immediately on `unmeasurable` → C9 red

## Attack these

1. **`3` (built but not distributed) is log-only.** My reasoning: it is true continuously while I develop, so notifying makes it permanent noise. But it is also the state that means "a fix exists that the owner's phone cannot get" — arguably the single most user-visible failure here. Am I trading away the most valuable signal to protect against noise I created by my own working pattern? What would a correct rule look like — a duration threshold (approved has lagged HEAD for N days)?

2. **The "last line must be a cap summary" heuristic** couples the observer to another script's output wording. If someone adds a trailing line to that job, the observer reports `failed` forever and the owner learns to ignore it. Is there a better epoch signal available given the cap job writes no structured state of its own — and if the honest answer is "make the cap job write one", say so.

3. **Delivery failure retry.** If `discord-notify.sh` fails, `announced` stays 0, but the next attempt only comes at the next measurement — up to 24h later for OTA. The existing key-expiry branch has the same property. Is that acceptable here, given `rollback` is the one state where a day of silence actually costs the owner something?

4. **`unmeasurable` requires 2 consecutive runs, which at `OTA_EVERY=86400` means 24h+ before the owner hears that the instrument is blind.** Is the threshold in the wrong unit — should it be consecutive runs, or elapsed time in the bad state?

5. Anything actually broken in the state machine: the 4-field record, the `floor=999999` trick used to make `undelivered` non-notifying, the recovery condition.

## The diff
```bash

# ── 掃除の job と配布口を見張る(2026-08-30 新設)──────────────────────────────
# 何を問うか: 「**この鎖の中で、誰も見ていない機械が止まっていないか**」。
#   `com.fleet.rc-log-cap` は log を毎時掃く。止まっても誰も気付かない —— 気付くのは
#   disk が埋まった時か、台帳を読もうとして log が既に消えていた時。
#   配布口(OTA)は Tom の電話への**唯一の**経路。古い版を配り始めても、Tom が
#   「入れ直したのに直っていない」と気付くまで誰も知らない。
#   どちらも 2026-08-30 に DESIGN §12 へ「誰も見ていない(既知・未着手)」と書いた穴。
#
# ★言い方の規約: **状態の名前が変わった時だけ1行**。毎回書くと此の2つで log が埋まり、
#   本物の up/down が読めなくなる —— 鍵の段が「段を降りた時だけ」なのと同じ理由。
#   走った事の証拠は log ではなく記録 file の mtime が持つ。
#
# ★通知に `notify_monitor_broken` を**使わない**。あの文面は
#   「rc-backend の監視側が壊れています」で固定で、掃除の job が止まった事を其の文で
#   流すと**壊れていない物を壊れたと言う**事になる。狼を1回でも誤って叫べば次から読まれない。
#   時計も分ける —— 混ぜると、掃除の話で6時間黙った隙に監視そのものが壊れても鳴らない。
CAP_MARK="${RC_HEALTH_CAP_MARK:-$HOME/Library/Logs/rc-backend/rc-log-cap.log}"
CAP_STATE_F="${RC_HEALTH_CAP_STATE:-$STATE.cap-seen}"
CAP_EVERY="${RC_HEALTH_CAP_EVERY:-3600}"      # 掃除は毎時。測るのは stat 1回なので安い
CAP_STALE_S="${RC_HEALTH_CAP_STALE_S:-10800}" # 3 時間 = 3 回続けて走らなかった

OTA_CHECK="${RC_HEALTH_OTA_CHECK:-$ROOT/tools/ota-freshness-check.sh}"
OTA_STATE_F="${RC_HEALTH_OTA_STATE:-$STATE.ota-seen}"
OTA_EVERY="${RC_HEALTH_OTA_EVERY:-86400}"     # ssh を1本張るので日に1回
# 「測れない」が続いた時に鳴らす回数。1 回で鳴らすと、回線が瞬いた度に
# 「配布口が判らない」を送る事になる —— EXP_BLIND_THRESHOLD と同じ理由で 2 から。
OTA_BLIND_THRESHOLD="${RC_HEALTH_OTA_BLIND_THRESHOLD:-2}"

# 記録の中身 = "<最後に測った epoch> <状態> <通知済み 0|1> <同じ状態が続いた回数>"
# ★4 語読めない古い形は「未知」に倒す。1 通多く出るだけで、逆に倒すと黙る。
subject_read() {   # subject_read <file> → S_TS / S_STATE / S_DONE / S_RUN
    S_TS=0; S_STATE="unknown"; S_DONE=0; S_RUN=0
    [ -f "$1" ] || return 0
    read -r S_TS S_STATE S_DONE S_RUN _rest < "$1" 2>/dev/null || true
    case "${S_TS:-}"   in ''|*[!0-9]*) S_TS=0 ;; esac
    case "${S_DONE:-}" in ''|*[!0-9]*) S_DONE=0 ;; esac
    case "${S_RUN:-}"  in ''|*[!0-9]*) S_RUN=0 ;; esac
    [ -n "${S_STATE:-}" ] || S_STATE="unknown"
    return 0
}

subject_write() {  # subject_write <file> <epoch> <状態> <通知済み> <回数>
    printf '%s %s %s %s\n' "$2" "$3" "$4" "$5" > "$1" 2>>"$LOG" \
        || log "★状態を書けない($1) — 次回また同じ判定になる(重複は沈黙よりまし)"
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

# 状態が変わった時だけ 1 行 log し、`ok` でない状態を**まだ言っていなければ**1 通出す。
# 戻った時は、**壊れたと言った時に限り**戻った事も言う(言っていないなら黙って戻す)。
subject_settle() { # subject_settle <記録 file> <短い名> <新状態> <本文> <epoch> [鳴らす最低回数]
    local f="$1" tag="$2" state="$3" msg="$4" now="$5" floor="${6:-1}"
    local announced=0 run=1
    if [ "$state" = "$S_STATE" ]; then run=$((S_RUN + 1)); announced="$S_DONE"; fi
    [ "$state" = "$S_STATE" ] || log "$tag: 状態が $S_STATE → $state"

    if [ "$state" != "ok" ] && [ "$announced" -eq 0 ] && [ "$run" -ge "$floor" ]; then
        notify_fleet "$tag($state)" "$msg" && announced=1
    fi
    if [ "$state" = "ok" ] && [ "$S_STATE" != "ok" ] && [ "$S_STATE" != "unknown" ] && [ "$S_DONE" -eq 1 ]; then
        notify_fleet "$tag(戻った)" "$(hostname -s): $tag が $S_STATE から戻りました。"
        announced=0
    fi
    subject_write "$f" "$now" "$state" "$announced" "$run"
}

# ── 掃除の job(com.fleet.rc-log-cap)が生きているか ─────────────────────────
# ★判定の要: **file の最後の行が掃除の要約か**。plist は `census && exec cap` なので、
#   台帳が落ちた回は掃除まで到達せず、最後の行が掃除の行にならない ——
#   mtime だけ見ていると台帳が書いた時刻で「新しい」に見えてしまい、其の回を見逃す。
check_log_cap() {
    local now state mt last_line age=0
    now="$(date +%s)"
    subject_read "$CAP_STATE_F"
    [ $((now - S_TS)) -lt "$CAP_EVERY" ] && return 0

    if [ ! -f "$CAP_MARK" ]; then
        state="missing"
    else
        mt="$(stat -f%m "$CAP_MARK" 2>/dev/null || stat -c%Y "$CAP_MARK" 2>/dev/null || echo '')"
        case "${mt:-}" in ''|*[!0-9]*) mt=0 ;; esac   # 読めない = 0 = 必ず stale(閉じる側に倒す)
        age=$((now - mt))
        last_line="$(tail -1 "$CAP_MARK" 2>/dev/null || echo '')"
        if [ "$age" -ge "$CAP_STALE_S" ]; then
            state="stale"
        else
            case "$last_line" in
                "log-cap-all:"*★*) state="failed" ;;   # 掃除は走ったが1本以上こけた
                "log-cap-all:"*)   state="ok" ;;
                *)                 state="failed" ;;   # 掃除の行で終わっていない = 到達していない
            esac
        fi
    fi

    local msg
    case "$state" in
        missing) msg="$(hostname -s): com.fleet.rc-log-cap の掃除の記録が在りません($CAP_MARK)。log の上限が掛かっていない可能性。" ;;
        stale)   msg="$(hostname -s): com.fleet.rc-log-cap が $((age / 3600)) 時間走っていません($CAP_MARK)。log の上限が掛かっていない。" ;;
        failed)  msg="$(hostname -s): com.fleet.rc-log-cap の最後の回が最後まで行っていません。$CAP_MARK の末尾: $last_line" ;;
        *)       msg="" ;;
    esac
    subject_settle "$CAP_STATE_F" "rc-log-cap" "$state" "$msg" "$now"
}

# ── 配布口が古い版を配っていないか ─────────────────────────────────────────
# `ota-freshness-check.sh` の終了コード: 0=順当 / 1=**配布が承認済みより古い**(巻き戻り) /
#   2=測れない / 3=承認済みが HEAD より古い(出来ているのに配っていない)。
# ★3 では鳴らさない。私が触っている間ずっと真なので、鳴らせば「いつも点いている警告」
#   になり、真になった日に読まれない。log には残す —— 記録と通知は別の道具。
check_ota_fresh() {
    local now rc out state msg floor
    now="$(date +%s)"
    subject_read "$OTA_STATE_F"
    [ $((now - S_TS)) -lt "$OTA_EVERY" ] && return 0

    if [ ! -x "$OTA_CHECK" ]; then
        log "ota-freshness: 測る台本が無い/実行できない: $OTA_CHECK"
        subject_settle "$OTA_STATE_F" "ota-freshness" "unmeasurable" \
            "$(hostname -s): 配布口の鮮度を測る台本が在りません($OTA_CHECK)。" "$now" "$OTA_BLIND_THRESHOLD"
        return 0
    fi

    out="$("$OTA_CHECK" 2>&1)"; rc=$?
    floor=1
    case "$rc" in
        0) state="ok" ;;
        1) state="rollback" ;;
        3) state="undelivered" ;;
        *) state="unmeasurable"; floor="$OTA_BLIND_THRESHOLD" ;;
```
