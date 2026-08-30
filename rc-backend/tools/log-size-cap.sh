#!/bin/bash
# log-size-cap.sh — ログ1本を上限内に収める(root 不要・追記者を殺さない)。
#
# ── なぜ要るか(2026-08-30、Codex の指摘)──────────────────────────────────────
# `rc-ota.log` は**認証を付けられない配布口**の記録で、tailnet に居れば誰でも 404 を連打でき、
# URL も長くできる。回転が1つも無いので素直に伸びる。同じディスクに机の tmux 転写も載る。
#
# ★ただし**常用では溢れない**。実測(friday 2026-08-30):
#     rc-backend.log 1,034,264 B / 起動から4日 = 約 260KB/日 ・ 空き 32Gi
#   これは「今すぐ溢れる」対策ではなく、**暴走に上限を置く**物。
#   `newsyslog` は `/etc/newsyslog.d/` に置くので root が要る(この環境では sudo が構造的に不可)。
#
# ── 形の選択(2回変えた。両方とも実測と外部の指摘で)────────────────────────────
# (1) **mv 回転は採らない**。追記者は file を開いたままなので、mv すると fd が古い inode に
#     残り、新しい file には1行も書かれない。実測: mv 後の新 file **0 B** / 旧 inode 7,488,895 B。
# (2) **tail を同じ file へ書き戻すのも採らない**(初版はこれだった)。
#     `cat "$tmp" > "$F"` は**追記 mode ではなく offset 0 から**書くので、書いている最中に
#     追記された行を後続の write が**上書きし得る**。
#     ★私の「fd が生きている」の実測は**追記が続く事**しか示しておらず、
#       **行が失われない事は測っていなかった**(大きさが増えるのは上書きでも起きる)。
#     採るのは Codex の助言どおり「**退避してから1回だけ空にする**」:
#       末尾を**別 file**へ写す → `: > "$F"` を1回。
#     残る損失は「写した後・空にする前」に入った行だけで、上書きは起きない。
#
# ★この上限が**押さえられない物**(正直に): 悪意ある連打。次の実行までの1時間に書ける量が
#   そのまま上乗せされるので、実効の上限は「CAP + 1時間ぶん」。本当の対策は配布口側の
#   認証か流量制限で、それは此の台本の役目ではない。
#
# 使い方:
#   bash tools/log-size-cap.sh <file> [上限バイト]     # 既定 5MB
#   退避先 = <file>.tail(1世代だけ。次に切る時に上書きされる)
#
# 終了コード: 0=上限内(切ったかは問わない) / 1=失敗 / 2=引数が不正
set -uo pipefail

F="${1:-}"
CAP="${2:-5242880}"
KEEP_FRAC="${LOG_CAP_KEEP_FRAC:-2}"   # 退避に残す量 = 上限の 1/KEEP_FRAC

[ -n "$F" ] || { echo "usage: log-size-cap.sh <file> [bytes]"; exit 2; }
[ -f "$F" ] || { echo "log-size-cap: $F が無い(何もしない)"; exit 0; }
case "$CAP" in ''|*[!0-9]*) echo "log-size-cap: 上限が数値でない: $CAP"; exit 2 ;; esac
[ "$CAP" -gt 1024 ] || { echo "log-size-cap: 上限が小さすぎる($CAP)"; exit 2; }

size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }

now="$(size "$F")"
case "$now" in ''|*[!0-9]*) echo "log-size-cap: 大きさを測れない: $F"; exit 1 ;; esac
[ "$now" -le "$CAP" ] && exit 0

keep=$((CAP / KEEP_FRAC))
snap="$F.tail"

# 1) 末尾を**別 file** へ退避(ここでは元 file を1バイトも触らない)
if ! tail -c "$keep" "$F" > "$snap.new" 2>/dev/null; then
    /bin/rm -f "$snap.new"
    echo "log-size-cap: 末尾を退避できない: $F"; exit 1
fi
# 先頭の欠けた行は落とす。**ただし、それで殆ど全部消えるなら落とさない** ——
# 2026-08-30 に実測で踏んだ: 検体が巨大な1行だったので `sed 1d` が 500KB を **81 B** にした。
# task の verifier は「上限以下かつ 0 でない」しか見ないので **PASS のまま**通った。
dropped="$(sed '1d' "$snap.new" | wc -c | tr -d ' ')"
whole="$(wc -c < "$snap.new" | tr -d ' ')"
{ printf '[log-size-cap] %s に %s B から切り詰め(上限 %s B。以降は元の file に続く)\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$now" "$CAP"
  if [ "$whole" -gt 0 ] && [ "$((dropped * 2))" -lt "$whole" ]; then
      cat "$snap.new"        # 1行が長すぎる: 途中から始まるが、捨てるよりまし
  else
      sed '1d' "$snap.new"
  fi
} > "$snap" 2>/dev/null || { /bin/rm -f "$snap.new"; echo "log-size-cap: 退避を書けない"; exit 1; }
/bin/rm -f "$snap.new"

# 2) 元 file を**1回だけ**空にする。offset 0 から書き戻さないので、追記との競合で
#    行を上書きする道が無い(失うのは 1) と 2) の間に入った行だけ)。
: > "$F" || { echo "log-size-cap: 空にできない: $F"; exit 1; }

# 3) 何処へ消えたかを本体に1行だけ残す。**`>>` は O_APPEND = 常に EOF へ書く**ので、
#    同時に追記している writer の行を上書きしない(offset 0 へ書き戻す初版とはここが違う)。
#    此の1行が無いと、log を開いた人には「空 = 何も起きていない」としか見えない。
printf '[log-size-cap] %s 時点で %s B を切り詰め。以前の末尾 %s B は %s に在る\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$now" "$(size "$snap")" "$snap" >> "$F" \
    || { echo "log-size-cap: 註記を追記できない: $F"; exit 1; }

after="$(size "$F")"
echo "log-size-cap: $F  $now B -> $after B(退避 $(size "$snap") B = $snap / 上限 $CAP)"
[ "${after:-0}" -le "$CAP" ] || { echo "log-size-cap: 切ったのに上限を超えている"; exit 1; }
exit 0
