#!/bin/bash
# parity-observer.sh — 配備した物が repo とずれた事を、**配備の時でなく定期に**気付く。
# `tunnel-observer.sh` から source して使う(単体でも `--once` で撃てる)。
#
# ── なぜ要るか(CF-22 の本物の差分)──────────────────────────────────────────
# `observer-parity-check.sh` と `fleet-plist-parity-check.sh` は repo が要るので
# **Jervis からしか回せない**。そして今は**配備の前後にしか走らない** ——
# 配備した後にずれたら、次の配備まで誰も気付かない。CF-7(配備が手作業のまま古くなる道)の
# 再発路が其処に開いている。
#
# ── H-4 の教訓(此処が設計の中心)────────────────────────────────────────────
# friday の watchdog は「本当ではない条件」で毎日鳴り、Tom は経路ごと黙らせかけた。
# Jervis は**回線が不定期に落ちるのが仕様**(Tom 裁定。実測 2026-08-26 の 6 時間で
# 186 FAIL / 178 OK = ほぼ半分の時間 自分が落ちていた)。だから:
#   ★自分の回線が落ちている / 判らない時は **測らない**(鳴らない、記録もしない)
#   ★照合が「測れなかった」(rc=2)時も **鳴らさない** —— 測れない事は ずれた事ではない
#   ★鳴らすのは**状態の名前が変わった時だけ**。同じ状態で毎日鳴る警告は、
#     真になった日に読まれない
#
# ── 状態 ────────────────────────────────────────────────────────────────────
#   ok         両方の照合が緑
#   drift      どちらかが**ずれている**(rc=1)= 配備した物が repo と違う
#   unmeasured 測れない(ssh が届かない等。rc=2)—— **ずれとしては鳴らさない**。
#              但し測れない状態が `PO_STALE_S`(既定 3 日)続けば、
#              「照合が見えていない」として別途1回だけ鳴らす(Codex の指摘1)。
#
# 記録: `<最後に試みた epoch> <状態> <通知済み 0|1> <此の状態になった epoch> <最後に**測れた** epoch>`
#
# ★「試みた」と「測れた」を分ける(2026-08-31、Codex の指摘1/3)。
#   1つに畳むと2つの嘘が生まれる:
#     (a) `unmeasured` でも時計が進むので、**測れない1回が其の日を食う** ——
#         此の機体は実測で半分の時間オフラインなので、期待間隔が約2日に伸びる。
#     (b) 「照合が緑」と「照合を**見られている**」が同じ欄になり、机へ何日も
#         届かないまま drift が溜まっても外から判らない。
#   だから: 測れなかった回は時計を進めず(次の 10 分後に再挑戦)、
#   **測れた時刻**を別に持ち、其れが古くなったら「見えていない」として鳴らす。
#
# 走らせる物: `tunnel-observer.sh` が source して `parity_observe` を呼ぶ
#   (Jervis の `com.tomtim.rc-tunnel-observer`、10 分毎)。挙動は
#   `rc-backend/tools/parity-observer-control.sh` が門から測る。
#   単体で確かめたい時は `--once`。
set -uo pipefail

PO_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PO_STATE="${RC_PARITY_STATE:-$HOME/.rc-backend/parity-state.json}"
PO_EVERY="${RC_PARITY_EVERY:-86400}"          # 日に1回。配備は人が撃つ操作なので分単位は要らない
PO_OBS="${RC_PARITY_OBS_CHECK-$PO_HERE/observer-parity-check.sh}"
PO_FLEET="${RC_PARITY_FLEET_CHECK-$PO_HERE/fleet-plist-parity-check.sh}"
# ★1本あたりの上限。**相乗りの代償**(Codex の指摘2): 此の枝は 10 分毎に回る本体の
#   観測器の中で走るので、長引くと本体の周期がずれる(launchd は重ならないので後ろへ伸びる)。
#   90 秒 x2 は最悪 3 分。45 秒 x2 = 最悪 1.5 分に抑える。照合は ssh 1本ずつなので足りる。
PO_TIMEOUT="${RC_PARITY_TIMEOUT:-45}"
# 「測れない」が続いた時に「見えていない」として鳴らすまでの時間。
PO_STALE_S="${RC_PARITY_STALE_S:-259200}"     # 3 日
PO_PERL="${RC_PARITY_PERL:-$(command -v perl 2>/dev/null || echo '')}"

# 呼び手(tunnel-observer)が持っている物。単体で撃つ時の為に既定を置く。
[ -n "${LOG:-}" ]    || LOG="${RC_TUNNEL_LOG:-$HOME/.rc-backend/tunnel-observer.log}"
[ -n "${NOTIFY:-}" ] || NOTIFY="${RC_TUNNEL_NOTIFY:-$HOME/bin/discord-notify.sh}"
# ★`command -v log` で判じない。macOS には **`/usr/bin/log`**(unified logging)が在るので、
#   呼び手が関数を持っていなくても「在る」と読み、記録の行が全部 Apple の log 道具へ飛ぶ
#   (2026-08-31 実測: `log help <command>` が出力に出た)。**関数が在るか**を訊く。
declare -f log >/dev/null 2>&1 || log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# 外の台本を時間で殴る。固まった照合に観測器を道連れにさせない。
# ★出力は一時 file 経由。`$( )` に直接流すと、殺した後も孤児の孫がパイプを握ったままで
#   命令置換が EOF を待つ(friday の観測器で同じ罠を実測した)。
po__bounded() {  # po__bounded <秒> <台本> → rc
    local secs="$1" script="$2" tf rc
    tf="$(mktemp 2>/dev/null)" || { "$script" >/dev/null 2>&1; return $?; }
    if [ -n "$PO_PERL" ]; then
        "$PO_PERL" -e 'alarm shift; exec @ARGV' "$secs" bash "$script" > "$tf" 2>&1
    else
        bash "$script" > "$tf" 2>&1
    fi
    rc=$?
    PO_LAST_OUT="$(tail -3 "$tf" 2>/dev/null)"
    /bin/rm -f "$tf"
    return "$rc"
}

po__read() {   # → PO_TS / PO_STATE_NAME / PO_DONE / PO_SINCE / PO_MEASURED
    local now; now="$(date +%s)"
    PO_TS=0; PO_STATE_NAME="unknown"; PO_DONE=0; PO_SINCE=0; PO_MEASURED=0
    [ -f "$PO_STATE" ] || return 0
    # ★欄が 5 でない行は丸ごと未知に倒す。欄が1つずれると状態名の場所に epoch が入り、
    #   其のずれは出力に出ない(friday の観測器で同じ形を潰した)。
    [ "$(awk 'NR==1{print NF; exit}' "$PO_STATE" 2>/dev/null)" = "5" ] || return 0
    read -r PO_TS PO_STATE_NAME PO_DONE PO_SINCE PO_MEASURED _rest < "$PO_STATE" 2>/dev/null || true
    case "${PO_MEASURED:-}" in ''|*[!0-9]*) PO_MEASURED=0 ;; esac
    case "${PO_TS:-}"    in ''|*[!0-9]*) PO_TS=0 ;; esac
    case "${PO_SINCE:-}" in ''|*[!0-9]*) PO_SINCE=0 ;; esac
    [ "${PO_DONE:-}" = "1" ] || PO_DONE=0
    [ -n "${PO_STATE_NAME:-}" ] || PO_STATE_NAME="unknown"
    [ "$PO_TS" -gt "$now" ] 2>/dev/null && PO_TS=0      # 時計が飛んでも二度と測らなくならない
    return 0
}

po__write() {  # po__write <試みた> <状態> <通知済み> <since> <測れた>
    local tmp
    tmp="$(mktemp "$(dirname "$PO_STATE")/.parity.XXXXXX" 2>/dev/null)" || return 0
    printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$PO_STATE" 2>/dev/null || /bin/rm -f "$tmp" 2>/dev/null
    return 0
}

# 照合を1回まわす。0=ok / 1=drift / 2=測れない
po__measure() {
    local orc frc
    PO_DETAIL=""
    [ -x "$PO_OBS" ] || return 2
    po__bounded "$PO_TIMEOUT" "$PO_OBS"; orc=$?
    [ "$orc" -eq 1 ] && { PO_DETAIL="観測器: $PO_LAST_OUT"; return 1; }
    [ "$orc" -ne 0 ] && return 2
    [ -x "$PO_FLEET" ] || return 2
    po__bounded "$PO_TIMEOUT" "$PO_FLEET"; frc=$?
    [ "$frc" -eq 1 ] && { PO_DETAIL="plist: $PO_LAST_OUT"; return 1; }
    [ "$frc" -ne 0 ] && return 2
    return 0
}

# 呼び手から1回。自分の回線が生きている時だけ測る。
parity_observe() {
    local now state msg announced since
    now="$(date +%s)"
    po__read
    [ $((now - PO_TS)) -lt "$PO_EVERY" ] && return 0

    # ★自分の回線が落ちている / 判らない時は**測らない**。記録も進めない ——
    #   進めると「測ったが ok だった」と後から読める形になる。
    if command -v self_link_state >/dev/null 2>&1; then
        self_link_state || return 0
    fi

    po__measure; case $? in
        0) state="ok" ;;
        1) state="drift" ;;
        *) state="unmeasured" ;;
    esac

    announced="$PO_DONE"; since="$PO_SINCE"
    if [ "$state" != "$PO_STATE_NAME" ]; then
        log "parity-observer: 状態が $PO_STATE_NAME → $state${PO_DETAIL:+($PO_DETAIL)}"
        announced=0; since="$now"
    fi
    [ "$since" -gt 0 ] || since="$now"

    # ★測れた時だけ「測れた時刻」を進める。測れなかった回は**時計も進めない** ——
    #   進めると其の1回が丸一日を食い、半分オフラインの機体では期待間隔が
    #   約2日に伸びる(Codex の指摘3)。進めなければ次の 10 分後に再挑戦する。
    local measured="$PO_MEASURED" attempt="$now"
    if [ "$state" = "unmeasured" ]; then
        attempt="$PO_TS"          # 試みた時刻を据え置く = 次の tick で再挑戦
    else
        measured="$now"
    fi

    # ★**照合が見えていない事**を、ずれとは別に鳴らす(Codex の指摘1)。
    #   黙るだけだと、机へ何日も届かないまま drift が溜まっても外から判らない。
    #   ★但し「ずれた」とは言わない —— 測れない事は ずれた事ではない。
    if [ "$state" = "unmeasured" ] && [ "$measured" -gt 0 ] \
       && [ $((now - measured)) -ge "$PO_STALE_S" ] && [ "$announced" -eq 0 ] && [ -x "$NOTIFY" ]; then
        printf '%s' "$(hostname -s): 配備の照合を $(( (now - measured) / 86400 )) 日 測れていません(ずれた訳ではなく**見えていない**)。机へ届いているか確かめる事" \
            | "$NOTIFY" >/dev/null 2>&1 && announced=1
        log "parity-observer: $(( (now - measured) / 86400 )) 日 測れていない事を通知"
    fi

    # ★鳴らすのは `drift` だけ。`unmeasured` は鳴らさない —— 測れない事は ずれた事ではないし、
    #   Jervis の回線は落ちるのが仕様なので、鳴らせば H-4 の再演になる。
    if [ "$state" = "drift" ] && [ "$announced" -eq 0 ] && [ -x "$NOTIFY" ]; then
        printf '%s' "$(hostname -s): 配備した物が repo とずれています。$PO_DETAIL / 直す手: bash rc-backend/tools/deploy-observer-to-friday.sh" | "$NOTIFY" >/dev/null 2>&1 \
            && announced=1
        log "parity-observer: ずれを通知(出し先 rc=$?)"
    fi
    # 戻った時は、**ずれたと言った時だけ**戻った事も言う。
    if [ "$state" = "ok" ] && [ "$PO_STATE_NAME" = "drift" ] && [ "$PO_DONE" -eq 1 ] && [ -x "$NOTIFY" ]; then
        printf '%s' "$(hostname -s): 配備のずれは直りました。" | "$NOTIFY" >/dev/null 2>&1 && announced=0
    fi

    po__write "$attempt" "$state" "$announced" "$since" "$measured"
    return 0
}

[ "${1:-}" = "--once" ] && { RC_PARITY_EVERY=0 parity_observe; exit 0; }
