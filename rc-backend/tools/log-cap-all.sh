#!/bin/bash
# log-cap-all.sh — rc-backend 系のログを全部まとめて上限内に収める(launchd から回す入口)。
#
# なぜ1本にまとめるか: 上限を掛ける対象は増える(ota / phone-window / digest-notify …)。
# plist に file 名を並べると、log が1本増えるたびに**設定を触る人が居ないと漏れる** ——
# observer が 22 日古くなったのと同じ形。ここは dir を舐める。
#
# ★**dir も1つでは足りなかった**(2026-08-30、出荷した後の指摘で気付いた)。
#   初版は `~/Library/Logs/rc-backend` だけを見ていた。理由は「大きい file が其処に在る」で、
#   それ自体は正しい。だが此の上限が防ぎたいのは**暴走**であって大きさではない ——
#   そして此のレーンが実際に踏みかけた暴走(CONTINUITY H-4: 依存物を欠いたまま observer を
#   配ると、日1回の誤報が **10 分毎**のループに化ける)が書き込む先は
#   `~/.rc-backend/health-observer.log` = **上限の外**だった。
#   **上限を、大きい物の在る場所ではなく、暴走の起きる場所に置く。**
#   実測(2026-08-30 friday、上限の外): health-observer.log 131,982 B(600 秒毎に追記)/
#   digest-notify.log 89,500 B(150 秒毎)。大きくはない —— 大きさは論点ではない。
#
# ★glob は `*.log` のまま広げない。退避先 `<file>.tail` が当たらない事が §12 の前提。
#
# 使い方:
#   bash tools/log-cap-all.sh [dir ...] [上限バイト]
#     - 末尾の引数が**数字だけ**なら上限。それ以外は全部 dir。
#     - dir を1つも書かなければ ~/Library/Logs/rc-backend
#   例: log-cap-all.sh                                   # 既定 dir・5MB
#       log-cap-all.sh ~/Library/Logs/rc-backend 1048576 # 従来の形(そのまま動く)
#       log-cap-all.sh ~/Library/Logs/rc-backend ~/.rc-backend
#
# ★`*.error.log` も**同じ上限を掛ける**(2026-08-30、Codex の指摘4)。
#   「履歴が欲しいのは寧ろ error の方だから除外したい」に対する答えは**除外しない**:
#   除外した1本が暴走すると、上限を掛けた意味そのものが消える。
#   欲しいのは履歴であって無制限ではないので、必要なら CAP を大きくして掛ける。
#
# ★ディスク占有は「上限 × 本数」ではなく **(上限 + 上限/2) × 本数**。
#   log-size-cap.sh が末尾を `<file>.tail` へ退避する為(1世代のみ。次に切る時に上書き)。
#
# 終了コード: 0=全部上限内 / 1=1本以上で失敗 / 2=**測定不成立**(対象 0 本 / dir が無い)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP=5242880
DIRS=()

# ★引数の解釈。末尾が**数字だけ**の時に限り上限として外す —— こうすると従来の
#   `log-cap-all.sh <dir> <bytes>` がそのまま動き、dir を足すのに形を変えずに済む。
#   (数字だけの名前の dir は扱えない。実在しないので受け入れる制限。)
args=("$@")
n_args=${#args[@]}
if [ "$n_args" -gt 0 ]; then
    last="${args[$((n_args - 1))]}"
    case "$last" in
        ''|*[!0-9]*) ;;                                   # 数字でない = dir
        *) CAP="$last"; unset 'args[n_args-1]' ;;
    esac
fi
for a in ${args+"${args[@]}"}; do DIRS+=("$a"); done
[ "${#DIRS[@]}" -eq 0 ] && DIRS=("$HOME/Library/Logs/rc-backend")

# ── 生存の印(2026-08-30、Codex の指摘2)──────────────────────────────────────
# 何の為か: 此の job が止まった事を**観測側が読める形**で残す。
#   初版の観測側は log の「最後の行が掃除の要約か」で読んでいた。それは他人の出力の
#   文言に縛られる契約で、誰かが行を1本足した日から観測側が永久に「壊れている」と言い、
#   Tom は其の警告を読まなくなる —— 狼を叫ぶ見張りの作り方そのもの。
#
# 中身 = `<この回を始めた epoch> <最後に成功した epoch> <この回の終了コード>`。
# ★**成功した時刻を別に持つ**のが要。試みた時刻だけだと、毎回起動して毎回こける job が
#   「新しい印」を書き続け、観測側からは元気に見える。
# ★`*.log` しか掃かないので此の file 自身は切られない(glob を広げるなら此処も見る事)。
HEARTBEAT="${RC_CAP_HEARTBEAT:-$HOME/.rc-backend/rc-log-cap.heartbeat}"
CAP_STARTED="$(date +%s)"
write_heartbeat() {   # EXIT で必ず走る。失敗した回も「試みた」事は残す。
    local rc=$? prev_ok=0 tmp
    prev_ok="$(awk '{print $2}' "$HEARTBEAT" 2>/dev/null)"
    case "${prev_ok:-}" in ''|*[!0-9]*) prev_ok=0 ;; esac
    [ "$rc" -eq 0 ] && prev_ok="$CAP_STARTED"
    mkdir -p "$(dirname "$HEARTBEAT")" 2>/dev/null
    # ★書き足しでなく差し替え。途中で死んだ半端な行を観測側に読ませない。
    tmp="$(mktemp "$(dirname "$HEARTBEAT")/.hb.XXXXXX" 2>/dev/null)" || return 0
    printf '%s %s %s\n' "$CAP_STARTED" "$prev_ok" "$rc" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$HEARTBEAT" 2>/dev/null || /bin/rm -f "$tmp" 2>/dev/null
    return 0
}
trap write_heartbeat EXIT

[ "$CAP" -gt 1024 ] 2>/dev/null || { echo "log-cap-all: 上限が不正($CAP)"; exit 2; }

n=0; capped=0; failed=0; missing=0; seen_dirs=0
for DIR in "${DIRS[@]}"; do
    # ★無い dir を 0 で帰さない(初版はそうしていた = fail-open)。
    #   綴りを1文字間違えただけの引数が「全部上限内」に見え、しかも launchd から
    #   1時間ごとに同じ嘘を出し続ける。数えて、最後に測定不成立として帰す。
    if [ ! -d "$DIR" ]; then
        echo "log-cap-all: ★$DIR が無い(測っていない)"
        missing=$((missing + 1)); continue
    fi
    seen_dirs=$((seen_dirs + 1))
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
done

# ★件数を言う。0 本を舐めて「全部上限内」に見えるのを防ぐ(此の repo が繰り返し踏んだ型)。
echo "log-cap-all: ${seen_dirs}/${#DIRS[@]} dir の $n 本を見て $capped 本を切った(上限 $CAP B)$([ "$failed" -gt 0 ] && echo "★失敗 $failed 本")$([ "$missing" -gt 0 ] && echo "★無い dir $missing 件")"
[ "$missing" -eq 0 ] || { echo "log-cap-all: 指定された dir が欠けている = 測定不成立(綴りを疑う事)"; exit 2; }
[ "$n" -gt 0 ] || { echo "log-cap-all: 対象が 0 本 = 測定不成立(dir か glob を疑う事)"; exit 2; }
[ "$failed" -eq 0 ] || exit 1
exit 0
