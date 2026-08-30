#!/bin/bash
# log-cap-all.sh — rc-backend 系のログを全部まとめて上限内に収める(launchd から回す入口)。
#
# なぜ1本にまとめるか: 上限を掛ける対象は増える(ota / phone-window / digest-notify …)。
# plist に file 名を並べると、log が1本増えるたびに**設定を触る人が居ないと漏れる** ——
# 今日 observer が 22 日古くなったのと同じ形。ここは dir を舐める。
#
# ★`*.error.log` も**同じ上限を掛ける**(2026-08-30、Codex の指摘4)。
#   「履歴が欲しいのは寧ろ error の方だから除外したい」に対する答えは**除外しない**:
#   除外した1本が暴走すると、上限を掛けた意味そのものが消える。
#   欲しいのは履歴であって無制限ではないので、必要なら CAP を大きくして掛ける。
#
# ★ディスク占有は「上限 × 本数」ではなく **(上限 + 上限/2) × 本数**。
#   log-size-cap.sh が末尾を `<file>.tail` へ退避する為(1世代のみ。次に切る時に上書き)。
#   `.tail` は `*.log` に当たらないので、此の掃きで二重に切る事は無い。
#
# 使い方:
#   bash tools/log-cap-all.sh [dir] [上限バイト]
# 既定: ~/Library/Logs/rc-backend / 5MB
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-$HOME/Library/Logs/rc-backend}"
CAP="${2:-5242880}"

[ -d "$DIR" ] || { echo "log-cap-all: $DIR が無い"; exit 0; }

n=0; capped=0; failed=0
for f in "$DIR"/*.log; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    before="$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)"
    # ★1本で止めない(2026-08-30、自分の差分を読み直して直した)。
    #   初版は最初の失敗で `exit 1` していた。掃引は名前順に回るので、
    #   壊れた1本より**後ろの log が全部上限なしのまま残る**。しかも此の job は
    #   1時間ごとに同じ場所で失敗し続けるので、その状態が自動で解けない。
    #   失敗は数えて最後に非 0 で帰る —— 止めるのは報告であって、掃引ではない。
    if ! bash "$HERE/log-size-cap.sh" "$f" "$CAP"; then
        echo "log-cap-all: ★$f で失敗(残りは続ける)"
        failed=$((failed + 1))
        continue
    fi
    after="$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)"
    [ "${before:-0}" != "${after:-0}" ] && capped=$((capped + 1))
done

# ★件数を言う。0 本を舐めて「全部上限内」に見えるのを防ぐ(此の repo が繰り返し踏んだ型)。
echo "log-cap-all: $DIR の $n 本を見て $capped 本を切った(上限 $CAP B)$([ "$failed" -gt 0 ] && echo "★失敗 $failed 本")"
[ "$n" -gt 0 ] || { echo "log-cap-all: 対象が 0 本 = 測定不成立(dir か glob を疑う事)"; exit 2; }
[ "$failed" -eq 0 ] || exit 1
exit 0
