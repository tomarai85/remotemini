#!/bin/bash
# ota-delivery-census.sh — 配布口が**実際に何本渡したか**を、上限の外へ日ごと時ごとに積む。
#
# ── なぜ要るか(2026-08-30)──────────────────────────────────────────────────
# CF-11 で判った事: Tom の4つの UI 指摘への修正は、**彼の電話に一度も届いていなかった**。
# 気付いたのは私が焼いた時刻と commit 時刻を突き合わせたからで、
# 「**栞が叩かれたか**」を直接答える物は木に1つも無かった。
#
# 配布口の log は `~/Library/Logs/rc-backend/rc-ota.log` に在り、
# **`com.fleet.rc-log-cap` が掃く dir の中**。5MB を超えれば末尾の半分だけが残り、
# 次に切られた時に其の退避も上書きされる。つまり「数え終わる前に、数える元が消える」。
# だから上限の**外**へ、数だけを積む。
#
# ── 何を数え、何を数えないか ────────────────────────────────────────────────
# 数えるのは **`:ipa` の GET だけ**。manifest.plist や install ページは数えない ——
# 出力の欄に path が無いので混ぜると `done 3` が「3本渡した」なのか
# 「1本渡して 2 回 manifest を引いた」なのか判らなくなる。
# ★`manifest は引いたが ipa は来なかった`(= 叩いたが iOS が断った)は**別 file**が答える。
#   2026-08-30 の Codex 査読: 「`:ipa` だけでは『栞が叩かれたか』は判定できない ——
#   測っているのは IPA 取得の試行であって操作ではない」。其の通りで、
#   iOS は install ページ → manifest.plist → ipa の順に引くので、
#   **押した証拠は manifest の側**に出る。ipa まで来なかった回は「押したが入らなかった」。
#   ★但し**主台帳の形は変えない**(検査が5欄を固定しており、形を変えれば
#     既に積んだ履歴も読めなくなる)。足すのは別 file —— 壊さずに増やす。
#     朝の `app-usage-census.sh` と同じ流儀。
#
# 結末の三分:
#   done    = code=200  送り切った
#   aborted = code=0    途中で切れた(電話が圏外 / installd が諦めた)
#             ★ota-server.mjs は `finish` でなく `close` で記録するので此の行が必ず出る。
#               `finish` だけ見ていた版は中断が**1行も残らず**、
#               「叩いたのに入らなかった」を潰す当の欠陥と同じ形だった。
#   refused = それ以外(404 / 429 など)。断った事も観測値なので捨てない。
#
# 使い方:
#   bash rc-backend/tools/ota-delivery-census.sh
#   RC_OTA_CENSUS_LOG=<log> RC_OTA_CENSUS_OUT=<tsv> bash …     # 検査の継ぎ目
#
# 出力: `<date>\t<hour>\t<client>\t<結末>\t<件数>` の TSV(整列済み)。
# 終了コード: 0=積んだ / 1=書けない / 2=元 log が無い(測定不成立。0 に丸めない)
set -uo pipefail

LOG="${RC_OTA_CENSUS_LOG:-$HOME/Library/Logs/rc-backend/rc-ota.log}"
# ★置き場は掃く dir の外。掃かれる場所に「掃かれると困る物」を置かない。
OUT="${RC_OTA_CENSUS_OUT:-$HOME/rc-census/ota-delivery.tsv}"
# 事象まで分けた副台帳。`<date> <hour> <client> <事象> <結末> <件数>`。
# 事象 = page(install ページ)/ manifest / ipa / other。
EVENT_OUT="${RC_OTA_CENSUS_EVENT_OUT:-${OUT%.tsv}-events.tsv}"

# ── 世代(app-usage-census.sh と同じ機構。2026-08-30 の Codex 査読で確定した形)──
# ★`max` で畳むと**過少**になる。同じ鍵が切断を跨ぐと前半 3 件・後半 2 件で
#   `max(3,2)=3` になり 2 件が消える。log の inode と大きさで世代を見て、
#   切られていたら前回の合計を繰越に畳んでから今の世代を**足す**。
epoch_state() {
    local ino sz
    ino="$(stat -f%i "$LOG" 2>/dev/null || stat -c%i "$LOG" 2>/dev/null)"
    sz="$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null)"
    printf '%s %s' "${ino:-0}" "${sz:-0}"
}

if [ ! -f "$LOG" ]; then
    echo "ota-delivery-census: $LOG が無い = 測定不成立(0 本と読ませない)" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || { echo "ota-delivery-census: 置き場を作れない: $(dirname "$OUT")" >&2; exit 1; }
umask 077
tmp="$(mktemp "$(dirname "$OUT")/.otacensus.XXXXXX")" || { echo "ota-delivery-census: 一時 file を作れない" >&2; exit 1; }
trap 'rm -f "$tmp" "$tmp.new"' EXIT

# 行の形: `[ota] req <ISO8601> GET /:secret/:ipa client=… peer=… code=… bytes=…`
# ★`:ipa` を**欄として**当てる(path の欄が `/:secret/:ipa` で終わる事)。
#   部分一致にすると将来 `/:secret/:ipa.sha256` の様な path が出来た日に混ざる。
awk '
    $1 == "[ota]" && $2 == "req" {
        d = ""; h = ""; cl = "-"; code = ""
        # 3 欄目が時刻、4 欄目が method、5 欄目が path
        if ($3 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) { split($3, p, "T"); d = p[1]; h = substr(p[2], 1, 2) }
        if ($4 != "GET") next
        if ($5 !~ /\/:ipa$/) next
        for (i = 6; i <= NF; i++) {
            if      ($i ~ /^client=/) cl   = substr($i, 8)
            else if ($i ~ /^code=/)   code = substr($i, 6)
        }
        if (d == "" || h == "" || code == "") next
        out = (code == "200") ? "done" : ((code == "0") ? "aborted" : "refused")
        n[d "\t" h "\t" cl "\t" out]++
    }
    END { for (k in n) printf "%s\t%d\n", k, n[k] }
' "$LOG" | sort > "$tmp"

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
if [ "$rotated" -eq 1 ] && [ -f "$OUT" ]; then
    cp -f "$OUT" "$CARRY"
fi

if [ -f "$CARRY" ]; then
    awk -F'\t' '
        NR == FNR { if (NF >= 5) c[$1 "\t" $2 "\t" $3 "\t" $4] = $5 + 0; next }
        { k = $1 "\t" $2 "\t" $3 "\t" $4; seen[k] = 1
          printf "%s\t%d\n", k, ((k in c) ? c[k] : 0) + $5 + 0 }
        END { for (k in c) if (!(k in seen)) printf "%s\t%d\n", k, c[k] }
    ' "$CARRY" "$tmp" | sort > "$tmp.new"
else
    cp "$tmp" "$tmp.new"
fi

mv -f "$tmp.new" "$OUT" || { echo "ota-delivery-census: 書けない: $OUT" >&2; exit 1; }
printf '%s\n' "$now_epoch" > "$EPOCH_FILE"

# ── 副台帳: 事象まで分ける ──────────────────────────────────────────────────
etmp="$(mktemp "$(dirname "$EVENT_OUT")/.otaevents.XXXXXX" 2>/dev/null)" \
    || etmp="$(mktemp "$(dirname "$OUT")/.otaevents.XXXXXX")"
awk '
    $1 == "[ota]" && $2 == "req" {
        if ($3 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) next
        split($3, p, "T"); d = p[1]; h = substr(p[2], 1, 2)
        cl = "-"; code = ""
        for (i = 6; i <= NF; i++) {
            if      ($i ~ /^client=/) cl   = substr($i, 8)
            else if ($i ~ /^code=/)   code = substr($i, 6)
        }
        if (code == "") next
        ev = "other"
        if      ($5 ~ /\/:ipa$/)          ev = "ipa"
        else if ($5 ~ /manifest\.plist$/) ev = "manifest"
        else if ($5 ~ /\/$/)              ev = "page"
        out = (code == "200") ? "done" : ((code == "0") ? "aborted" : "refused")
        n[d "\t" h "\t" cl "\t" ev "\t" out]++
    }
    END { for (k in n) printf "%s\t%d\n", k, n[k] }
' "$LOG" | sort > "$etmp"

# 副台帳も**同じ世代の機構**に乗せる(別の規則にすると片方だけ正しい台帳が出来る)。
ECARRY="${EVENT_OUT%.tsv}.carry"
if [ "$rotated" -eq 1 ] && [ -f "$EVENT_OUT" ]; then
    cp -f "$EVENT_OUT" "$ECARRY"
fi
if [ -f "$ECARRY" ]; then
    awk -F'\t' '
        NR == FNR { if (NF >= 6) c[$1 "\t" $2 "\t" $3 "\t" $4 "\t" $5] = $6 + 0; next }
        { k = $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5; seen[k] = 1
          printf "%s\t%d\n", k, ((k in c) ? c[k] : 0) + $6 + 0 }
        END { for (k in c) if (!(k in seen)) printf "%s\t%d\n", k, c[k] }
    ' "$ECARRY" "$etmp" | sort > "$etmp.new"
else
    cp "$etmp" "$etmp.new"
fi
mv -f "$etmp.new" "$EVENT_OUT" || { echo "ota-delivery-census: 副台帳を書けない: $EVENT_OUT" >&2; /bin/rm -f "$etmp"; exit 1; }
/bin/rm -f "$etmp"

rows="$(wc -l < "$OUT" | tr -d ' ')"
done_n="$(awk -F'\t' '$4=="done"    {s += $5} END {print s + 0}' "$OUT")"
ab_n="$(  awk -F'\t' '$4=="aborted" {s += $5} END {print s + 0}' "$OUT")"
ref_n="$( awk -F'\t' '$4=="refused" {s += $5} END {print s + 0}' "$OUT")"
app_n="$( awk -F'\t' '$3=="app" && $4=="done" {s += $5} END {print s + 0}' "$OUT")"
# ★変数名は必ず `${}` で囲む。直後に全角記号が続くと bash が名前の一部として読み、
#   `unbound variable` で落ちる(2026-08-30 に踏んだ)。
# ★「栞が叩かれたか」は副台帳が答える。電話が **path を問わず** 1本も来ていないなら
#   一度も押していない。ipa だけ 0 なら「押したが入らなかった」。
tapped="$(awk -F'\t' '$3=="app" {s += $6} END {print s + 0}' "$EVENT_OUT")"
echo "ota-delivery-census: ${rows} 行 / 渡し切り ${done_n}・中断 ${ab_n}・断り ${ref_n}"
echo "  電話(client=app): ipa を受け取った ${app_n} 回 / 配布口へ来た事自体が ${tapped} 回 = ${EVENT_OUT}"
exit 0
