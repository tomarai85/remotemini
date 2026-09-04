#!/bin/bash
# digest-notify.sh — **机が Tom の返事を待って止まっている**時に、電話を開かせずに知らせる。
# 2026-08-26 新設。Friday の上で走る(API は loopback、鍵は同じ機体に在る)。
#
# なぜ要るか(実測): 常駐が `attention=input / action=soon` のまま **60 分**座っていた。
#   Tom は「待たれている」事を知らないので、電話を開くまでその時間は丸ごと死ぬ。
#   此処が取り戻すのはその死に時間で、それ以上の物ではない。
#
# ★鳴らし方は `phone-window-notify.sh` が確立した規約に揃える:
#   検出と配達を分ける / 続いている間ずっと鳴らさない / 沈黙と正常を同じ顔にしない。
#   ただし**「直った時に1回鳴らす」は此処では採らない** —— この信号の「直った」は
#   *Tom が返事をした* であって、本人が知っている。知らせるのは騒音になる(Codex 2026-08-26)。
#
# ★鳴らす条件(Codex 2026-08-26 の裁定、本人が同日 amend した後の版):
#   1. `attention` が **`choice` か `input`** の時だけ。`unknown` は**永久に不適格** ——
#      正直だが役に立たない状態を人に見せると、信号ごと無視される様になる。
#   2. `action.level = now` … **2回続けて同じ指紋**なら鳴らす(この台本の刻みで 4-6 分)。
#   3. `action.level = soon` … **同じ指紋が実経過で 20 分**続いた時だけ。
#      ★回数ではなく**時間**で測る。同じ画面を2回読んでも独立した証拠にはならない。
#   4. 一度鳴らした指紋では二度と鳴らさない。指紋が変われば(= 会話が進めば)状態は消える。
#
# ★指紋 = `sessionId + attention + lastAt`。
#   - `lastAt` は最後の記録の時刻。Tom が返せば動く = 指紋が変わる = 状態が消える。
#   - 別の会話が同じ文面でも `sessionId` が違う。
#   - 台本が再起動しても状態は disk に在るので、続き具合を見失わない。
#   ★中身(本文)は指紋に入れない。この repo は「打った物の中身を残さない」線を引いている。
#
# ★此処が答えない事: 見張りは事後にしか気付かない。刻みの隙間に出て消えた要求は残らない。
#
# 使い方:
#   digest-notify.sh              1回見る(launchd から 2-3 分毎)
#   digest-notify.sh --dry-run    鳴らさずに判定だけ出す
#   digest-notify.sh --state      今の状態を出す
#
# 終了コード: 0=見た(鳴らしたかは問わない) / 2=使い方 / 3=見られなかった(= 監視が壊れている)
set -uo pipefail

API="${RC_DIGEST_API:-http://127.0.0.1:8787}"
KEYFILE="${RC_DIGEST_KEY:-$HOME/.rc-backend/api.key}"
STATE="${RC_DIGEST_STATE:-$HOME/.rc-backend/digest-notify.json}"
LOG="${RC_DIGEST_LOG:-$HOME/.rc-backend/digest-notify.log}"
NOTIFY="${RC_DIGEST_NOTIFY:-$HOME/bin/discord-notify.sh}"
SOON_MIN="${RC_DIGEST_SOON_MIN:-20}"          # `soon` を鳴らすまでの実経過(分)
NOW_OBS="${RC_DIGEST_NOW_OBS:-2}"             # `now` を鳴らすまでの連続観測回数
STALE_MIN="${RC_DIGEST_STALE_MIN:-720}"       # これを過ぎた記録は捨てる(状態が太らない)
PY="${RC_DIGEST_PY:-/usr/bin/python3}"
# ★完了の遷移だけを**記録する**先(2026-09-04、対照表 #32)。鳴らす先ではない。
#   設計 = research/notification-push-type-split-2026-09-04.md: 完了は画面の状態ではなく
#   **遷移**(前の刻みで動いていた → 今は止まっている)なので、刻みを跨ぐ状態を既に持つ
#   此の台本にしか置けない。既定オフで測る物ではなく、**既定で測って既定で鳴らさない**——
#   鳴らす既定を反転させる前に、設計書が指定した3つの数(頻度 / 窓の長さ / 在席中の割合)が要る。
COMPLETION_LOG="${RC_DIGEST_COMPLETION_LOG:-$HOME/.rc-backend/digest-completion.log}"
# 在席の心拍は下の抑止でも使うが、**記録には python 側でも要る**ので此処で解く。
# 下の抑止は「鳴らす物が在る」時しか走らない(その前に exit 0)ので、あちらに任せると
# 完了の記録は在席かどうかを永久に知れない = 3つ目の数が測れない。
PRESENCE_FILE="${RC_PRESENCE_FILE:-$HOME/.rc-backend/presence-desk}"
PRESENCE_MAX_S="${RC_PRESENCE_MAX_S:-180}"
presence_fresh=0
if [ -f "$PRESENCE_FILE" ]; then
    _pf_age=$(( $(date +%s) - $(stat -f %m "$PRESENCE_FILE" 2>/dev/null || echo 0) ))
    [ "$_pf_age" -ge 0 ] && [ "$_pf_age" -lt "$PRESENCE_MAX_S" ] && presence_fresh=1
fi

DRY=0; SHOW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --state)   SHOW=1; shift ;;
        -h|--help) sed -n '/^# 使い方:/,/^# 終了コード/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
        *) echo "不明な引数: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")" 2>/dev/null
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

if [ "$SHOW" -eq 1 ]; then cat "$STATE" 2>/dev/null || echo '{}'; exit 0; fi

[ -r "$KEYFILE" ] || { log "鍵が読めない: $KEYFILE"; echo "鍵が読めない: $KEYFILE" >&2; exit 3; }
KEY="$(cat "$KEYFILE")"

# ---- 一覧 → 各会話の digest を集める ---------------------------------------------
# ★取れなかった事を「静か = 正常」にしない。exit 3 で「見られなかった」と言う。
sessions="$(curl -s -m 20 -H "authorization: Bearer $KEY" "$API/api/sessions" 2>/dev/null \
    | "$PY" -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(3)
for s in (d.get("sessions") or []):
    i=s.get("id")
    if i: print(i)' 2>/dev/null)"; srn=$?

# ★「取れなかった」と「0 件だった」を分ける(2026-08-26 に自分の diff を読み返して足した)。
#   0 件は起こり得る —— 常駐が落ちてから `ensure-phone-window` が作り直すまでの間、
#   `cli` の会話は本当に 0 になる。それを「監視が壊れている」と言うのは誤診で、
#   誤診は次に本当に壊れた日に読まれなくなる。
#   ★取れなかった側(rc != 0)は今まで通り exit 3。**静かと正常を同じ顔にしない**。
if [ "$srn" != 0 ]; then
    log "会話の一覧が取れなかった(= 監視が壊れている。静かなのではない)"
    exit 3
fi
if [ -z "$sessions" ]; then
    log "会話が 0 件(壊れてはいない。常駐が立ち上がるまでの間に起こる)"
    exit 0
fi

now_epoch="$(date +%s)"
tmp="$(mktemp)"; : > "$tmp"
for sid in $sessions; do
    body="$(curl -s -m 20 -H "authorization: Bearer $KEY" "$API/api/sessions/$sid/digest" 2>/dev/null)"
    [ -n "$body" ] || { log "digest が取れない: ${sid:0:8}"; continue; }
    printf '%s\t%s\n' "$sid" "$body" >> "$tmp"
done

# ---- 判定と状態の更新は1つの python に閉じる(shell で JSON を切り貼りしない)-------
out="$("$PY" - "$tmp" "$STATE" "$now_epoch" "$SOON_MIN" "$NOW_OBS" "$STALE_MIN" "$DRY" "$COMPLETION_LOG" "$presence_fresh" <<'PY'
import json, os, sys, hashlib

feed, statep, now, soon_min, now_obs, stale_min, dry, comp_log, presence_fresh = sys.argv[1:10]
now = int(now); soon_min = int(soon_min); now_obs = int(now_obs); stale_min = int(stale_min)
dry = dry == "1"
presence_fresh = presence_fresh == "1"

try:
    state = json.load(open(statep))
    if not isinstance(state, dict): state = {}
except Exception:
    state = {}

fresh = {}
alerts = []
completions = []   # ★記録するだけ。`alerts` には**絶対に足さない**(鳴らす経路と混ぜない)

for line in open(feed):
    line = line.rstrip("\n")
    if "\t" not in line: continue
    sid, raw = line.split("\t", 1)
    try:
        d = json.loads(raw)
    except Exception:
        continue

    attention = str(d.get("attention") or "")
    action = d.get("action") or {}
    level = str(action.get("level") or "")
    dg = d.get("digest") or {}
    last_at = dg.get("lastAt")

    # ── 完了の遷移(2026-09-04、対照表 #32)──────────────────────────────
    # 「長い作業が終わった」は**画面の状態ではない**。終わった画面と、ただ待っている画面は
    # 同じ形(composer が在り、活動が見えない)で出る。違うのは**前の刻みで動いていたか**
    # だけなので、刻みを跨ぐ状態を持つ此処にしか置けない(設計 = notification-push-type-split)。
    #
    # ★鳴らさない。`completions` は記録専用で、`alerts` にも `alerted` にも触れない ——
    #   触れると「記録だけ」と名乗る仕掛けが本物の通知を1回食べる。此の台本は
    #   2026-09-01 に `--dry-run` で全く同じ事故を起こしている(上の註)。
    prev_rec = state.get(sid) if isinstance(state.get(sid), dict) else {}
    prev_att = str((prev_rec or {}).get("att") or "")
    counts = (dg.get("counts") or {}) if isinstance(dg, dict) else {}
    try:
        assistant_n = int(counts.get("assistant") or 0)
    except Exception:
        assistant_n = 0
    try:
        writes_n = int(dg.get("writeTargetsTotal") or 0)
    except Exception:
        writes_n = 0
    window_min = 0
    try:
        window_min = int(((dg.get("window") or {}) or {}).get("minutes") or 0)
    except Exception:
        window_min = 0
    # 不完全な要約からは「終わった」と言わない —— 此の台本が既に持つ規則
    # (読み切れていない窓で「大丈夫」と言わない)と同じ向き。
    if (prev_att == "none" and attention == "input"
            and dg.get("complete") is True
            and (assistant_n > 0 or writes_n > 0)):
        completions.append({"sid": sid, "window_min": window_min,
                            "assistant": assistant_n, "writes": writes_n,
                            "presence_fresh": 1 if presence_fresh else 0})

    # 1. 対象の状態だけ。`unknown` は永久に不適格。
    if attention not in ("choice", "input"):
        # ★記録は捨てず、**今の attention だけ上書きして持ち越す**(2026-09-04)。
        #   捨てると、次の刻みで遷移が見えないだけでなく `alerted` が消えて
        #   同じ指紋で二度鳴る。持ち越しは遷移の検出と重複抑止の両方に要る。
        #
        # ★但し**新しい記録は `none`(動いている)にだけ作る**(Codex 所見 F2、2026-09-04)。
        #   初版は見た会話を全部 `fresh` に載せて `seen` も更新していた。`sid in fresh` は
        #   刈り込みを飛ばす条件なので、其れをすると **一覧に出る限り永久に消えない記録**が
        #   会話の数だけ積む —— 以前は載りすらしなかった物が、消えない物に変わっていた。
        #   遷移の検出に要るのは `none` の記憶だけなので、其れ以外は
        #   **既存の記録が在る時に `att` だけ**書き換え、`seen` は触らない(= 通常通り古びる)。
        if attention == "none":
            carried = dict(prev_rec or {})
            carried["att"] = attention
            carried["seen"] = now
            fresh[sid] = carried
        elif prev_rec:
            carried = dict(prev_rec)
            carried["att"] = attention
            fresh[sid] = carried      # `seen` は据え置き = 古い記録は今まで通り刈られる
        continue
    if level not in ("now", "soon"):
        continue

    # 指紋: 会話 + 状態 + 最後の記録の時刻。中身は入れない。
    fp = hashlib.sha256(("%s|%s|%s" % (sid, attention, last_at)).encode("utf-8")).hexdigest()[:16]

    prev = state.get(sid) or {}
    if prev.get("fp") == fp:
        first = int(prev.get("first", now))
        obs = int(prev.get("obs", 0)) + 1
        alerted = bool(prev.get("alerted", False))
    else:
        first, obs, alerted = now, 1, False       # 指紋が変わった = 会話が進んだ = 状態を捨てる

    elapsed_min = (now - first) // 60
    fire = False
    if not alerted:
        if level == "now" and obs >= now_obs:
            fire = True
        elif level == "soon" and elapsed_min >= soon_min:
            # ★回数ではなく実経過。同じ画面を何度読んでも独立した証拠にならない。
            fire = True

    if fire:
        alerts.append({"sid": sid, "attention": attention, "level": level,
                       "elapsed_min": elapsed_min, "line": str(d.get("line") or "")[:160]})
        alerted = True

    fresh[sid] = {"fp": fp, "first": first, "obs": obs, "alerted": alerted, "seen": now,
                  "att": attention}

# 対象外になった会話と、古すぎる記録は捨てる(状態が静かに太らない)
for sid, v in (state or {}).items():
    if sid in fresh: continue
    if not isinstance(v, dict): continue
    if (now - int(v.get("seen", 0))) // 60 < stale_min:
        fresh[sid] = v

# ★★2026-09-01: `--dry-run` では**書かない**。
#
#   直前まで此の行は無条件だった —— つまり `--dry-run` が指紋台帳に `alerted: True` を
#   書き込み、**次の本番実行が「もう鳴らした」と判断して黙る**。
#   「鳴らさずに判定だけ出す」と名乗る旗が、**実際の通知を 1 回食べていた**。
#   `DRY` は python に渡されてすらいなかった(引数 6 個)ので、旗は此の層に届いていない。
#
#   ★同じ形は 2026-08-31 にも踏んでいる(dry-run が実在のカードを食べ、
#     「消失を通知しない」旗が締切をカレンダーから消した)。**旗が守るのは
#     「見える側」だけで、「書く側」は別に止めないと止まらない。**
#
#   刈り込み(古い記録の掃除)も dry では起きないが、それで正しい ——
#   観測する物が状態を変えないのが dry-run の定義。
if not dry:
    json.dump(fresh, open(statep, "w"), ensure_ascii=False, indent=1)
    # 完了の記録も**書く側**なので dry では止める(2026-09-01 の教訓: 旗は見える側しか守らない)。
    if completions:
        try:
            with open(comp_log, "a") as fh:
                for c in completions:
                    fh.write("%d\tcompletion\t%s\twindow_min=%d\tassistant=%d\twrites=%d\tpresence_fresh=%d\n"
                             % (now, c["sid"], c["window_min"], c["assistant"], c["writes"], c["presence_fresh"]))
        except Exception:
            pass   # 記録に失敗しても鳴らす側は止めない(此れは計測であって製品ではない)
for a in alerts:
    print("%s\t%s\t%s\t%s\t%s" % (a["sid"], a["attention"], a["level"], a["elapsed_min"], a["line"]))
PY
)"; prc=$?
rm -f "$tmp"
# ★★此処**だけ**鳴らす(Codex 2026-08-27 の裁定)。
#
#   此の台本が壊れる入口は3つ在るが、鳴らす価値が在るのは1つだけ:
#     ・鍵が読めない      … 電話も机と話せなくなるので、**製品の側から数分で判る**
#     ・一覧が取れない    … 机が落ちている事なので、`health-observer` が既に見ている
#     ・**判定が落ちた**  … 此れだけが、他の全部が健康に見えたまま静かに死ぬ
#   前の2つで鳴らすと、1つの障害で複数の通知が飛ぶ(重複の騒音)。
#
#   ★同じ日に、私は `health-observer` の**偽の**「監視が壊れている」を消したばかり。
#     狼を叫んだ見張りは3回目に読まれない —— だから新しい叫び口を足す時は、
#     **他の誰も見ていない失敗**に限る。
#
#   ★重さも合わせない。此の台本は「返事を待たれている」を知らせる**便利機能**であって、
#     製品の生死を見る物ではない。だから文面で「便利機能の側が止まった」と明示し、
#     `health-observer` の「監視側が壊れています」と混ぜない。
if [ "$prc" != 0 ]; then
    log "判定が落ちた(rc=$prc)= 此の台本だけが静かに死ぬ入口"
    if [ "$DRY" -eq 1 ]; then
        echo "DRY: 留守中の要約の判定が落ちました(rc=$prc)"
    elif [ -x "$NOTIFY" ]; then
        printf '%s' "留守中の要約の見張り(便利機能)が止まりました: 判定が落ちた(rc=$prc)。机の生死は別の見張りが見ています。log: $LOG" \
            | "$NOTIFY" >/dev/null 2>&1 || log "★判定の失敗を知らせられなかった"
    else
        log "★判定が落ちたが出し先が実行できない: $NOTIFY"
    fi
    exit 3
fi

[ -z "$out" ] && { log "鳴らす物は無い"; exit 0; }

# ── 在席抑止(2026-08-31)────────────────────────────────────────────────────
# Tom が机(Jervis)に座っている間は鳴らさない。着地点を作って通知の価値を上げた
# 直後に此れを入れないと、机に居る時間帯の分だけ騒音が増え、**狼少年化して信号ごと
# 無視される** —— 此の台本自身が上の註でその型を書いている。
#
# ★合図は「出来事」ではなく**心拍**にする。画面の施錠/解錠を捕まえる形だと、
#   Jervis が落ちた・寝た・網が切れた時に「施錠された」が届かず、**永久に在席扱い**で
#   通知が死ぬ。心拍なら止まった時点で自然に古くなる。
#
# ★★判らない時は**鳴らす側**へ倒す。印が無い / 古い / 読めない = 全部「居ない」。
#   通知を 1 回 余計に出す損失より、要る通知を落とす損失の方が重い ——
#   此の台本の存在理由が後者を防ぐ事だから。
# ★変数は上の設定塊で1度だけ解いてある(2026-09-04)。此処で解き直すと、
#   完了の記録が見た値と抑止が見た値が別々に動く余地が生まれる。
if [ -f "$PRESENCE_FILE" ]; then
    _age=$(( $(date +%s) - $(stat -f %m "$PRESENCE_FILE" 2>/dev/null || echo 0) ))
    if [ "$_age" -ge 0 ] && [ "$_age" -lt "$PRESENCE_MAX_S" ]; then
        log "在席のため鳴らさない(心拍 ${_age} 秒前 < ${PRESENCE_MAX_S})"
        exit 0
    fi
    log "心拍が古い(${_age} 秒前)= 居ないとみなす"
fi

# ★通知に**会話の名前**と**そこへ跳ぶリンク**を載せる(2026-08-31)。
#
#   直す前は「机が返事を待っています(N分)」だけで、**どの会話かも書いていなかった**。
#   受け取った側は、電話を開いて一覧から自分で探す事になる。
#   調査(3本)が一致して指した欠陥がこれ ——「気付く → 着地する → 答える」の鎖の、
#   **着地が切れている**。電話側は `remotemini` の scheme を Info.plist に登録済みなのに
#   `onOpenURL` を受ける行が 1 つも無かったので、同じ commit で其方も繋いだ。
#
# ★新しい通知系を作らない。此の台本には既に重複抑止(同一指紋2回・経過時間)が
#   入っていて、通知源が 2 つになると両方鳴って**狼少年になる** ——
#   :175-190 の註が自分でその型を書いている。載せるのは既存の 1 本にだけ。
title_of() {   # title_of <sid> -> 会話の名前(取れなければ空)
    curl -s -m 5 -H "authorization: Bearer $KEY" "$API/api/sessions" 2>/dev/null \
        | python3 -c "
import sys, json
sid = sys.argv[1]
try:
    for s in (json.load(sys.stdin) or {}).get('sessions', []):
        if s.get('id') == sid:
            print((s.get('title') or '').strip()); break
except Exception:
    pass
" "$1" 2>/dev/null
}

printf '%s\n' "$out" | while IFS="$(printf '\t')" read -r sid attention level mins line; do
    # ★配達する前に**読んだ行を検証する**(Codex 所見 F1、2026-09-04)。
    #   判定層の標準出力に書く物が 1 種類だった間は、此処が素通しでも意味は変わらなかった。
    #   完了の記録という**2 つ目の書き手**を足した時点で其の前提は消える —— 記録の行き先を
    #   誤って標準出力へ向けた設定が、記録をそのまま通知に変える。
    #   鳴らして良いのは「人を待っている」だけなので、其の語彙に一致しない行は捨てて記録する。
    case "$attention" in choice|input) ;; *)
        log "★配達しない: 語彙外の attention=[$attention](鳴らす行ではない物が判定層から出ている)"
        continue ;;
    esac
    case "$level" in now|soon) ;; *)
        log "★配達しない: 語彙外の level=[$level]"
        continue ;;
    esac
    _t="$(title_of "$sid")"
    # 名前が取れなければ id の頭 8 桁。**「どれか判らない通知」を出さない**のが此処の目的。
    _label="${_t:-${sid:0:8}}"
    msg="$(printf '%s が返事を待っています(%s分)\n%s\nremotemini://session/%s' "$_label" "$mins" "$line" "$sid")"
    log "鳴らす: ${sid:0:8} attention=$attention level=$level 経過=${mins}分"
    if [ "$DRY" -eq 1 ]; then
        echo "DRY: $msg"
    elif [ -x "$NOTIFY" ]; then
        printf '%s' "$msg" | "$NOTIFY" >/dev/null 2>&1 || log "★鳴らせなかった: $NOTIFY"
    else
        log "★鳴らす先が実行できない: $NOTIFY"
    fi
done
exit 0
