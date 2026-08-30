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
# ★時刻と版まで分けた副台帳(2026-08-30)。日次の合計だけだと H-3 の解除条件
# (「**起きている時間**に本物の機会が来た時、Tom がアプリ経由で動くか」)を後から評価できない ——
#   1日 100 件が深夜の常駐なのか昼の実使用なのかが、合計からは復元できない。
#   `build` も併せて持つ: 版が変わった前後で使い方が変わったかは、版を捨てた台帳では問えない。
# ★**日次の合計は形を変えない**。既に 4 日ぶん積んであり、形を変えると其の履歴が読めなくなる。
#   足すのは別 file。壊さずに増やす。
DETAIL_OUT="${RC_CENSUS_DETAIL_OUT:-${OUT%.tsv}-detail.tsv}"

# ── 世代(2026-08-30、Codex の指摘2 —— `max` は過大ではなく**過少**になる)────────
# ★同じ鍵が切断を跨ぐと、前半 3 件・後半 2 件で `max(3,2)=3` になり **2 件が消える**。
#   `max` が正しいのは「後の観測が前の完全な上位集合」である時だけで、切られた瞬間に
#   其の前提が崩れる。日次台帳にも同じ欠陥が入っていた。
#
#   直し: log の **inode と大きさ**で世代を見る。
#     - inode が変わった / 大きさが減った = 切られた = **新しい世代**
#       → 前回の合計を「繰越」に畳んでから、今の世代の数を**足す**
#     - それ以外 = 同じ世代(log は増える一方)= 今の数が其の世代の全部
#   これで「切られても減らない」と「切断を跨いでも失わない」が両立する。
epoch_state() {  # 現在の log の世代印
    local ino sz
    ino="$(stat -f%i "$LOG" 2>/dev/null || stat -c%i "$LOG" 2>/dev/null)"
    sz="$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null)"
    printf '%s %s' "${ino:-0}" "${sz:-0}"
}

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

# ── 世代の判定と繰越 ────────────────────────────────────────────────────────
EPOCH_FILE="${OUT%.tsv}.epoch"
CARRY="${OUT%.tsv}.carry"
now_epoch="$(epoch_state)"
prev_epoch="$(cat "$EPOCH_FILE" 2>/dev/null || echo '')"
prev_ino="${prev_epoch%% *}"; prev_sz="${prev_epoch##* }"
now_ino="${now_epoch%% *}";  now_sz="${now_epoch##* }"
rotated=0
if [ -n "$prev_epoch" ]; then
    case "$prev_ino$now_ino$prev_sz$now_sz" in *[!0-9]*) rotated=1 ;; esac
    [ "$rotated" -eq 0 ] && { [ "$now_ino" != "$prev_ino" ] || [ "$now_sz" -lt "$prev_sz" ]; } && rotated=1
fi
# 切られていたら、**前回書いた合計**を繰越に畳む(其れが完了した世代の総和)。
if [ "$rotated" -eq 1 ] && [ -f "$OUT" ]; then
    cp -f "$OUT" "$CARRY"
fi

# 繰越 + 今の世代 = 合計。**max ではなく和**。
if [ -f "$CARRY" ]; then
    awk -F'\t' '
        NR == FNR { if ($1 != "") c[$1] = $2 + 0; next }
        { seen[$1] = 1; printf "%s\t%d\n", $1, (($1 in c) ? c[$1] : 0) + $2 + 0 }
        END { for (k in c) if (!(k in seen)) printf "%s\t%d\n", k, c[k] }
    ' "$CARRY" "$tmp" | sort > "$tmp.new"
else
    cp "$tmp" "$tmp.new"
fi

mv -f "$tmp.new" "$OUT" || { echo "app-usage-census: 書けない: $OUT" >&2; exit 1; }

# ── 副台帳: 日 / 時 / 版 ────────────────────────────────────────────────────
# ★`build=` が無い行(2026-08-30 より前の机)は `-` として数える。捨てない ——
#   「版が判らない要求が在った」事自体が、後から読む人に要る情報。
dtmp="$(mktemp "$(dirname "$DETAIL_OUT")/.census-detail.XXXXXX" 2>/dev/null)" || \
    dtmp="$(mktemp "$(dirname "$OUT")/.census-detail.XXXXXX")"
awk '
    /client=app([[:space:]]|$)/ {
        d = ""; h = ""; b = "-"
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) { split($i, p, "T"); d = p[1]; h = substr(p[2], 1, 2) }
            else if ($i ~ /^build=/) { b = substr($i, 7) }
        }
        if (d != "" && h != "") n[d "\t" h "\t" b]++
    }
    END { for (k in n) printf "%s\t%d\n", k, n[k] }
' "$LOG" | sort > "$dtmp"

# 副台帳も**同じ世代の機構**に乗せる(日次と別の規則にすると、片方だけ正しい台帳が出来る)。
DCARRY="${DETAIL_OUT%.tsv}.carry"
if [ "$rotated" -eq 1 ] && [ -f "$DETAIL_OUT" ]; then
    cp -f "$DETAIL_OUT" "$DCARRY"
fi
if [ -f "$DCARRY" ]; then
    awk -F'\t' '
        NR == FNR { if (NF >= 4) c[$1 "\t" $2 "\t" $3] = $4 + 0; next }
        { k = $1 "\t" $2 "\t" $3; seen[k] = 1
          printf "%s\t%d\n", k, ((k in c) ? c[k] : 0) + $4 + 0 }
        END { for (k in c) if (!(k in seen)) printf "%s\t%d\n", k, c[k] }
    ' "$DCARRY" "$dtmp" | sort > "$dtmp.new"
else
    cp "$dtmp" "$dtmp.new"
fi
mv -f "$dtmp.new" "$DETAIL_OUT" || { echo "app-usage-census: 副台帳を書けない: $DETAIL_OUT" >&2; /bin/rm -f "$dtmp"; exit 1; }
/bin/rm -f "$dtmp"
days="$(wc -l < "$OUT" | tr -d ' ')"
total="$(awk -F'\t' '{s += $2} END {print s + 0}' "$OUT")"
printf '%s\n' "$now_epoch" > "$EPOCH_FILE"
drows="$(wc -l < "$DETAIL_OUT" 2>/dev/null | tr -d ' ')"
echo "app-usage-census: $days 日 / 述べ $total 件を $OUT に積んだ(時刻×版 $drows 行 = $DETAIL_OUT)"
exit 0
