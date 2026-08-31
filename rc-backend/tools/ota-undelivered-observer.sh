#!/bin/bash
# ota-undelivered-observer.sh — 「**出来ているのに配っていない**」を、配備の時でなく
# 定期に気付く枝。`tunnel-observer.sh` が source して `undelivered_observe` を呼ぶ。
#
# ── なぜ要るか(2026-08-31、実測)────────────────────────────────────────────
# `ota-freshness-check.sh` の rc=3(配布は承認に追いついているが、**承認そのものが
# HEAD より古い**)を撃つのは2つだけだった:
#   1. `ios/tools/adhoc-ota.sh` の step 7 —— **配る時**にしか走らない
#   2. 人が手で撃つ時
# つまり「配った直後は必ず緑、其の後どれだけ離れても誰も言わない」。
# 実際に其の状態が起きていた: 配布 105 / HEAD 114 / Tom の電話は配布口へ一度も来ておらず、
# 08-29 以降の作業が**どれも彼の電話に載る経路に無い**。CF-11 で踏んだ形そのもの。
#
# 機構は在るのに届かない理由も測ってある: `health-observer.sh` は
# `OTA_UNDELIVERED_GRACE` を持つが、常設で走るのは friday だけで、其処では `--local` が
# 渡り、`--local` は自分で「承認が HEAD に追いついているかは測らない(木が要る =
# Jervis の担当)」と言う。そして **Jervis に其の担当が居なかった** ——
# 木が「Jervis の担当」と書き、受け渡しが片側だけ実装されていた形。
# 全文: `.harness/evidence-2026-08-31/undelivered-build-is-unwatched.md`
#
# ★**2本目の見張りは建てない**(CF-22 / CF-23 の判断の延長)。`parity-observer.sh` と
#   同じく `com.tomtim.rc-tunnel-observer` に相乗りする —— あれは既に
#   「自分の回線が落ちている時は黙る」判断を持ち、Jervis は実測で半分の時間オフライン
#   (6 時間の窓で 186 FAIL / 178 OK)。判断を2箇所で持つと片方だけ直る日が来る。
#
# 状態は3つ。鳴らし方が違う:
#   ok           配布 >= 承認 かつ 承認が HEAD に追いついている(rc=0)          … 黙る
#   undelivered  出来ているのに配っていない(rc=3)                              … **猶予を跨いだら1回**
#   rollback     配布が承認より古い(rc=1)= 栞を叩くと巻き戻る                  … **猶予なしで1回**
#   unmeasured   測れない(rc=2)                                                … 鳴らさない。時計も進めない
#
# ★`undelivered` に猶予を置くのは、**開発中は殆ど常に真**だから。常時鳴る警報は
#   読まれなくなり、本当に配り忘れた日に効かない(今日、同型を何度も踏んだ)。
#   `rollback` に猶予を置かないのは、あれが Tom の**唯一の復旧経路が壊れている**状態で、
#   「暫く様子を見る」性質の物ではないから。
#
# 走らせる物: `tunnel-observer.sh` が source して `undelivered_observe` を呼ぶ
#   (Jervis の `com.tomtim.rc-tunnel-observer`、10 分毎)。挙動は
#   `rc-backend/tools/ota-undelivered-observer-control.sh` が門から測る。
#   単体で確かめたい時は `--once`。
set -uo pipefail

# ★**直に撃たれたか**(2026-08-31、実測で踏んだ)。此の file は `tunnel-observer.sh` が
#   **source** する。source された時 `$1` は**呼び手の引数**なので、守り無しだと
#   `tunnel-observer.sh --report` が下の枝に吸われ、宿主の報告を出さずに exit 0 する
#   —— 実際に其れを出荷し、`tunnel-observer-controls.sh` の T1/T2/T9/T17 が
#   赤くなって初めて判った。引数の枝は**直に撃たれた時だけ**通す。
OU_DIRECT=0; [ "${BASH_SOURCE[0]}" = "$0" ] && OU_DIRECT=1

OU_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OU_STATE="${RC_OU_STATE:-$HOME/.rc-backend/ota-undelivered-state.json}"
OU_EVERY="${RC_OU_EVERY:-86400}"              # 日に1回。配るのは人が撃つ操作なので分単位は要らない
OU_CHECK="${RC_OU_CHECK-$OU_HERE/ota-freshness-check.sh}"
# 「出来ているのに配っていない」を鳴らすまでの猶予。作業の1回ぶんより長く取る。
OU_GRACE="${RC_OU_GRACE:-172800}"             # 2 日
# 「測れない」が続いた時に「見えていない」として鳴らすまでの時間(ずれとは別の状態)。
OU_STALE_S="${RC_OU_STALE_S:-259200}"         # 3 日
OU_TIMEOUT="${RC_OU_TIMEOUT:-45}"             # 中で ssh を張るので上限を置く
# ★「続いている」と言える為に、**その間ずっと見えていた**事を要求する上限(Codex 2026-08-31)。
#   前回 測れてから此れ以上 空いていたら、前の episode との連続性は**証明できない** ——
#   猶予は壁時計の差ではなく、観測できた時間で数える。
OU_CONTINUITY_MAX="${RC_OU_CONTINUITY_MAX:-$((2 * ${RC_OU_EVERY:-86400}))}"
OU_PERL="${RC_OU_PERL:-$(command -v perl 2>/dev/null || echo '')}"

[ -n "${LOG:-}" ]    || LOG="${RC_TUNNEL_LOG:-$HOME/.rc-backend/tunnel-observer.log}"
[ -n "${NOTIFY:-}" ] || NOTIFY="${RC_TUNNEL_NOTIFY:-$HOME/bin/discord-notify.sh}"
# ★`command -v log` で判じない。macOS には `/usr/bin/log` が在るので、呼び手が関数を
#   持っていなくても「在る」と読み、記録が全部 Apple の log 道具へ飛ぶ(2026-08-31 実測)。
declare -f log >/dev/null 2>&1 || log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# 外の台本を時間で殴る。★出力は一時 file 経由 —— `$( )` に直接流すと、殺した後も
#   孤児の孫がパイプを握ったままで命令置換が EOF を待つ(friday の観測器で実測)。
ou__bounded() {  # ou__bounded <秒> <台本> → rc
    local secs="$1" script="$2" tf rc
    tf="$(mktemp 2>/dev/null)" || { bash "$script" >/dev/null 2>&1; return $?; }
    if [ -n "$OU_PERL" ]; then
        "$OU_PERL" -e 'alarm shift; exec @ARGV' "$secs" bash "$script" > "$tf" 2>&1
    else
        bash "$script" > "$tf" 2>&1
    fi
    rc=$?
    OU_LAST_OUT="$(tail -2 "$tf" 2>/dev/null)"
    /bin/rm -f "$tf"
    return "$rc"
}

# 記録 = "<試みた epoch> <状態> <通知済み 0|1> <この状態になった epoch> <最後に測れた epoch>"
# ★欄が 5 でない行は丸ごと未知に倒す。欄が1つずれると状態名の場所に epoch が入り、
#   其のずれは出力に出ない(friday の観測器で同じ形を潰した)。
ou__read() {
    local now; now="$(date +%s)"
    OU_TS=0; OU_STATE_NAME="unknown"; OU_DONE=0; OU_SINCE=0; OU_MEASURED=0
    [ -f "$OU_STATE" ] || return 0
    [ "$(awk 'NR==1{print NF; exit}' "$OU_STATE" 2>/dev/null)" = "5" ] || return 0
    read -r OU_TS OU_STATE_NAME OU_DONE OU_SINCE OU_MEASURED _rest < "$OU_STATE" 2>/dev/null || true
    for _n in OU_TS OU_SINCE OU_MEASURED; do
        eval "case \"\${$_n:-}\" in ''|*[!0-9]*) $_n=0 ;; esac"
    done
    [ "${OU_DONE:-}" = "1" ] || OU_DONE=0
    [ -n "${OU_STATE_NAME:-}" ] || OU_STATE_NAME="unknown"
    [ "$OU_TS" -gt "$now" ] 2>/dev/null && OU_TS=0    # 時計が飛んでも二度と測らなくならない
    return 0
}

ou__write() {  # ou__write <試みた> <状態> <通知済み> <since> <測れた>
    local tmp
    tmp="$(mktemp "$(dirname "$OU_STATE")/.ota-und.XXXXXX" 2>/dev/null)" || return 0
    printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$OU_STATE" 2>/dev/null || /bin/rm -f "$tmp" 2>/dev/null
    return 0
}

# 呼び手から1回。自分の回線が生きている時だけ測る。
undelivered_observe() {
    local now state msg announced since measured attempt grace
    now="$(date +%s)"
    ou__read
    [ $((now - OU_TS)) -lt "$OU_EVERY" ] && return 0

    # ★空 = **この機体では測らない**。材料(repo の木)を持つ機体だけが指す。
    [ -n "$OU_CHECK" ] || return 0
    [ -x "$OU_CHECK" ] || [ -f "$OU_CHECK" ] || return 0

    # ★自分の回線が落ちている / 判らない時は**測らず何も書かない** ——
    #   書くと「測ったが ok だった」と後から読める形になる。
    if command -v self_link_state >/dev/null 2>&1; then
        self_link_state || return 0
    fi

    OU_DETAIL=""
    ou__bounded "$OU_TIMEOUT" "$OU_CHECK"; local rc=$?
    case "$rc" in
        0) state="ok" ;;
        3) state="undelivered"; OU_DETAIL="$OU_LAST_OUT" ;;
        1) state="rollback";    OU_DETAIL="$OU_LAST_OUT" ;;
        *) state="unmeasured" ;;
    esac

    announced="$OU_DONE"; since="$OU_SINCE"
    if [ "$state" != "$OU_STATE_NAME" ]; then
        log "ota-undelivered: 状態が $OU_STATE_NAME → $state${OU_DETAIL:+($OU_DETAIL)}"
        announced=0; since="$now"
    elif [ "$OU_MEASURED" -gt 0 ] && [ $((now - OU_MEASURED)) -gt "$OU_CONTINUITY_MAX" ]; then
        # ★**同じ状態に見えても、間が見えていなければ同じ episode ではない**
        #   (Codex 2026-08-31)。此処を素通りさせると:
        #     rc=3 で開始 → 2日以上 測れない → 其の間に直って再発 → 次の観測で
        #     「3日 続いている」として**即座に鳴る**。壁時計の差は連続性の証拠ではなく、
        #     離れた2回の観測が在るという証拠でしかない。
        #   数え直す(黙る方へ倒す)。★之で「本当に長く続いた物の通知が遅れる」代わりに
        #   「見ていない時間を根拠に鳴る」事が無くなる —— 後者の方が警報を殺す。
        log "ota-undelivered: $(( (now - OU_MEASURED) / 86400 )) 日 見えていなかったので、続いた時間を数え直す"
        since="$now"; announced=0
    fi
    [ "$since" -gt 0 ] || since="$now"

    # ★測れた時だけ「測れた時刻」を進める。測れなかった回は**時計も進めない** ——
    #   進めると其の1回が丸一日を食い、半分オフラインの機体では期待間隔が倍になる。
    measured="$OU_MEASURED"; attempt="$now"
    if [ "$state" = "unmeasured" ]; then
        attempt="$OU_TS"        # 試みた時刻を据え置く = 次の tick で再挑戦
    else
        measured="$now"
    fi

    # ★**見えていない事**を、配り忘れとは別に鳴らす。黙るだけだと、机へ何日も
    #   届かないまま離れが溜まっても外から判らない。「ずれた」とは言わない。
    if [ "$state" = "unmeasured" ] && [ "$measured" -gt 0 ] \
       && [ $((now - measured)) -ge "$OU_STALE_S" ] && [ "$announced" -eq 0 ] && [ -x "$NOTIFY" ]; then
        printf '%s' "$(hostname -s): 配布口の鮮度を $(( (now - measured) / 86400 )) 日 測れていません(配り忘れた訳ではなく**見えていない**)。" \
            | "$NOTIFY" >/dev/null 2>&1 && announced=1
        log "ota-undelivered: $(( (now - measured) / 86400 )) 日 測れていない事を通知"
    fi

    # ★猶予は状態ごとに違う。`rollback` は Tom の唯一の復旧経路が壊れている状態なので
    #   様子を見ない。`undelivered` は作業中ほぼ常に真なので、跨いだ時に1回だけ。
    grace=0
    [ "$state" = "undelivered" ] && grace="$OU_GRACE"
    if { [ "$state" = "undelivered" ] || [ "$state" = "rollback" ]; } \
       && [ $((now - since)) -ge "$grace" ] && [ "$announced" -eq 0 ] && [ -x "$NOTIFY" ]; then
        if [ "$state" = "rollback" ]; then
            msg="$(hostname -s): ★配布口が承認済みより古い版を配っています。栞を叩くと**巻き戻ります**。$OU_DETAIL / 直す手: cd ios && ./tools/adhoc-ota.sh"
        else
            msg="$(hostname -s): 出来ている物が $(( (now - since) / 86400 )) 日 配る対象になっていません。$OU_DETAIL / 配るなら: cd ios && ./tools/adhoc-ota.sh"
        fi
        printf '%s' "$msg" | "$NOTIFY" >/dev/null 2>&1 && announced=1
        log "ota-undelivered: $state を通知"
    fi
    # 戻った時は、**言った時だけ**戻った事も言う。
    if [ "$state" = "ok" ] && [ "$OU_DONE" -eq 1 ] && [ "$OU_STATE_NAME" != "ok" ] && [ -x "$NOTIFY" ]; then
        printf '%s' "$(hostname -s): 出来ている物が配る対象になりました。" | "$NOTIFY" >/dev/null 2>&1 && announced=0
    fi

    ou__write "$attempt" "$state" "$announced" "$since" "$measured"
    return 0
}

[ "$OU_DIRECT" = 1 ] && [ "${1:-}" = "--once" ] && { OU_EVERY=0; undelivered_observe; exit 0; }
