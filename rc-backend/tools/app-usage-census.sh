#!/bin/bash
# app-usage-census.sh — 電話(client=app)からの要求を**日ごとに数えて積む**。
#
# ── なぜ要るか(2026-08-30)──────────────────────────────────────────────────
# CONTINUITY の H-3 は OPEN で、解除条件が「合成の通知を送らずに 3〜7 日の起きている時間に
# 本物の機会が来た時、Tom がアプリ経由で動くか観測する」。その観測の手立ては
# **人が思い出して grep する**事だけだった —— 木を全部 grep しても `client=app` を
# **読む道具は1つも無い**(書き手 `src/reqlog.mjs` と其の検査だけ)。
#
# ★同じ日に据えた上限が、その観測窓を消しに来る。`rc-backend.log` は約 260KB/日で伸び、
#   5MB に当たるのは2週間ほど先。切ると末尾の半分だけが `<file>.tail` に残り、
#   **次に切った時に其の退避も上書きされる**(1世代しか持たない)。
#   つまり「数え終わる前に、数える元が消える」。
#
# だから**上限の外**へ、日ごとの数だけを積む。生の行は運ばない(要らないし、
# 運べば同じ大きさの問題を別の場所に作るだけ)。
#
# ★積み方は**日ごとの max**。和ではない。
#   log は切られるので、切った後の走行では過去の日の数が**減って**見える。
#   和にすると二重に数え、上書きにすると減る。max なら
#   「一度観測した数より下がらない」= 窓が消えても記録が残る。
#   同じ日に本当に増えた時も max で伸びる。
#
# 使い方:
#   bash rc-backend/tools/app-usage-census.sh
#   RC_CENSUS_LOG=<log> RC_CENSUS_OUT=<tsv> bash …     # 検査の継ぎ目
#
# 出力: `<date>\t<count>` の TSV(日付順)。既定の置き場は **上限を掛けている dir の外**。
#
# 終了コード: 0=積んだ / 1=書けない / 2=元 log が無い(測定不成立。0 に丸めない)
set -uo pipefail

LOG="${RC_CENSUS_LOG:-$HOME/Library/Logs/rc-backend/rc-backend.log}"
# ★置き場は `~/Library/Logs/rc-backend` でも `~/.rc-backend` でもない ——
#   どちらも `com.fleet.rc-log-cap` が掃く。掃かれる場所に「掃かれると困る物」を置かない。
OUT="${RC_CENSUS_OUT:-$HOME/rc-census/app-usage.tsv}"

if [ ! -f "$LOG" ]; then
    echo "app-usage-census: $LOG が無い = 測定不成立(0 件と読ませない)" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || { echo "app-usage-census: 置き場を作れない: $(dirname "$OUT")" >&2; exit 1; }
umask 077

tmp="$(mktemp "$(dirname "$OUT")/.census.XXXXXX")" || { echo "app-usage-census: 一時 file を作れない" >&2; exit 1; }
trap 'rm -f "$tmp" "$tmp.new"' EXIT

# 今の log から日ごとに数える。
# 行の形(`src/reqlog.mjs`): `[rc-backend] req <ISO8601> <METHOD> <path> route=… client=… code=… …`
# ★`client=app` を**語として**当てる。`client=apple` の様な将来の語に巻き込まれない為。
awk '
    /client=app([[:space:]]|$)/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) { split($i, d, "T"); n[d[1]]++; break }
        }
    }
    END { for (k in n) printf "%s\t%d\n", k, n[k] }
' "$LOG" | sort > "$tmp"

# 既にある記録と**日ごとの max** で畳む。
if [ -f "$OUT" ]; then
    awk -F'\t' '
        NR == FNR { if ($1 != "") old[$1] = $2 + 0; next }
        { cur = $2 + 0; if ($1 in old && old[$1] > cur) cur = old[$1]; seen[$1] = 1; printf "%s\t%d\n", $1, cur }
        END { for (k in old) if (!(k in seen)) printf "%s\t%d\n", k, old[k] }
    ' "$OUT" "$tmp" | sort > "$tmp.new"
else
    cp "$tmp" "$tmp.new"
fi

mv -f "$tmp.new" "$OUT" || { echo "app-usage-census: 書けない: $OUT" >&2; exit 1; }
days="$(wc -l < "$OUT" | tr -d ' ')"
total="$(awk -F'\t' '{s += $2} END {print s + 0}' "$OUT")"
echo "app-usage-census: $days 日 / 述べ $total 件を $OUT に積んだ"
exit 0
