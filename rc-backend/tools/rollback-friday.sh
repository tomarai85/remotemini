#!/bin/bash
# no-operator: 人が撃つ。配備が成功した後で「実は壊れていた」と分かった時の物。
#   門から回さない(生きた本番と launchd を触る)。
#
# rollback-friday.sh — **配備は通ったが後で壊れていると分かった時**に戻す。2026-08-26 新設。
#
# ★先に事実: 戻す仕組みは**部分的に既に在った**。`deploy-to-edith.sh` は本番の木に触る前に
#   `~/rc-releases/<時刻>-<版>/` へ実体で複製を取り(`$TMPDIR` に置かないのは「tmp は
#   一番戻したい瞬間に消えている」から)、**配備そのものが失敗した時**は自動で書き戻す。
#   実測 2026-08-26: 14 世代 / 61MB、全部その日の物。
#   足りなかったのは2つだけ:
#     (a) 配備は**成功**したが 10 分後に壊れていると分かった時の手が無い
#     (b) 間引きが無い(1回あたり ~4.3MB、機体は既に disk 81%)
#   だから此処は新しい仕組みを作らない。**既存の複製の上に、後からの戻しと間引きだけ**を足す。
#
# 設計は Codex 2026-08-26 の裁定に従う:
#   1. 錠を取る / `*.partial` を拒む / rsync は `--delete`(悪い版が足した file を消す為)/
#      **写し終えてから** launchd で再起動 / **本物の健康確認**を要求する。
#      やってはいけない: 写している最中の再起動 / 同期木の外の設定 file を触る /
#      tmux の窓番を再起動する / **rsync が 0 で帰った事を成功と呼ぶ**。
#   2. 「直前」を既定の行き先にしない。同じ壊れた版を2回配っていたり、良品から数世代
#      経っていると、直前は壊れている。**行き先は明示させる**(`--previous` は明示の1つ)。
#   3. 間引きは **keep-N**(disk に硬い上限が付く唯一の形)。★確認済みの良品は
#      `--pin` で輪番の外へ出す —— 悪い配備が連続すると N 枠を食い潰し、
#      **最後に使える版をちょうど消す**。
#
# ★此の道具が**戻せない物**(Codex 裁定5): file 系の巻き戻しであって、外に出た効果
#   (送信済みの物、外部 API を叩いた結果)は戻らない。版の間に互換性の無い変更が在る場合も
#   此処は面倒を見ない —— 見分けが付かないので、**判らない時は拒む**側に倒してある。
#
# 使い方:
#   rollback-friday.sh --list              世代を並べる(既定。何もしない)
#   rollback-friday.sh --to <名前>         その世代へ戻す
#   rollback-friday.sh --previous          一番新しい**完全な**世代へ戻す(明示の1つ)
#   rollback-friday.sh --pin <名前>        輪番の外へ固定(間引きが消さない)
#   rollback-friday.sh --unpin <名前>
#   rollback-friday.sh --prune [N]         完全な世代を新しい順に N 個残す(既定 8)
#   --dry-run を足すと**何も変えずに**手順だけ出す
#
# 終了コード: 0=やった / 1=戻したが健康確認が通らない / 2=使い方・拒否 / 3=材料が無い
set -uo pipefail

HOST="${RC_FRIDAY_HOST:-athenas}"
REMOTE_HOME="${RC_REMOTE_HOME:-/Users/athenas}"
RELEASES="${RC_ROLLBACK_RELEASES:-$REMOTE_HOME/rc-releases}"
LIVE="${RC_ROLLBACK_LIVE:-$REMOTE_HOME/rc-backend}"
JOB="${RC_ROLLBACK_JOB:-com.fleet.rc-backend}"
HEALTH="${RC_ROLLBACK_HEALTH:-https://desk.tailnet.example:9443/healthz}"
LOCK="${RC_ROLLBACK_LOCK:-$REMOTE_HOME/.rc-backend/deploy.lock}"
PINS="${RC_ROLLBACK_PINS:-$RELEASES/.pinned}"
AUDIT="${RC_ROLLBACK_AUDIT:-$REMOTE_HOME/.rc-backend/rollback.log}"
KEEP_DEFAULT="${RC_ROLLBACK_KEEP:-8}"
SSH="${RC_ROLLBACK_SSH:-ssh}"

mode="list"; want=""; keep="$KEEP_DEFAULT"; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)     mode="list"; shift ;;
        --to)       mode="to"; want="${2:-}"; shift 2 ;;
        --previous) mode="previous"; shift ;;
        --pin)      mode="pin"; want="${2:-}"; shift 2 ;;
        --unpin)    mode="unpin"; want="${2:-}"; shift 2 ;;
        --prune)    mode="prune"; case "${2:-}" in ''|-*) shift ;; *) keep="$2"; shift 2 ;; esac ;;
        --dry-run)  DRY=1; shift ;;
        -h|--help)  sed -n '/^# 使い方:/,/^# 終了コード/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
        *) echo "不明な引数: $1" >&2; exit 2 ;;
    esac
done

r() { $SSH -o ConnectTimeout=15 -o BatchMode=yes "$HOST" "$@"; }

# ★名前は**此方で組み立てない**。人が渡した物をそのまま遠隔の path に混ぜると、
#   `../` や空白で置き場の外を指せる。形を先に検める(白名簿)。
valid_name() {
    case "$1" in
        ''|*/*|*..*|*' '*) return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

audit() { [ "$DRY" -eq 1 ] && return 0
    r "printf '%s %s\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" '$1' >> '$AUDIT'" 2>/dev/null || true; }

# ---- 世代を並べる ---------------------------------------------------------------
# ★`*.partial` は**数に入れない**。途中で死んだ複製を「戻せる物」として見せるのが
#   一番危ない(戻した先が半端な木になる)。配備側も昇格させない規約なので、揃える。
list_raw() {
    r "cd '$RELEASES' 2>/dev/null || exit 3
       for d in */; do
           d=\"\${d%/}\"
           case \"\$d\" in *.partial|.*) continue ;; esac
           [ -d \"\$d\" ] || continue
           rev=\"\$(head -1 \"\$d/DEPLOYED-REV\" 2>/dev/null || echo '?')\"
           n=\"\$(find \"\$d\" -type f 2>/dev/null | wc -l | tr -d ' ')\"
           pin=''
           [ -f '$PINS' ] && grep -qxF \"\$d\" '$PINS' 2>/dev/null && pin='PINNED'
           printf '%s\t%s\t%s\t%s\n' \"\$d\" \"\$rev\" \"\$n\" \"\$pin\"
       done | sort -r"
}

case "$mode" in
list)
    out="$(list_raw)"; rc=$?
    [ "$rc" = 3 ] && { echo "置き場が無い: $HOST:$RELEASES" >&2; exit 3; }
    [ -z "$out" ] && { echo "戻せる世代が1つも無い" >&2; exit 3; }
    printf '%-28s %-16s %8s  %s\n' "世代" "版" "file数" "固定"
    printf '%s\n' "$out" | while IFS="$(printf '\t')" read -r d rev n pin; do
        printf '%-28s %-16s %8s  %s\n' "$d" "$rev" "$n" "$pin"
    done
    echo
    echo "戻すには: $0 --to <世代>   (直前へなら --previous)"
    exit 0 ;;

pin|unpin)
    valid_name "$want" || { echo "世代の名前が不正: ${want:-（空）}" >&2; exit 2; }
    if [ "$DRY" -eq 1 ]; then echo "DRY: $mode $want"; exit 0; fi
    if [ "$mode" = pin ]; then
        r "grep -qxF '$want' '$PINS' 2>/dev/null || printf '%s\n' '$want' >> '$PINS'" || exit 2
        echo "固定した(間引きの対象外): $want"
    else
        r "[ -f '$PINS' ] && grep -vxF '$want' '$PINS' > '$PINS.tmp' && mv '$PINS.tmp' '$PINS'" || true
        echo "固定を外した: $want"
    fi
    audit "$mode $want"; exit 0 ;;

prune)
    case "$keep" in ''|*[!0-9]*) echo "keep は数字: $keep" >&2; exit 2 ;; esac
    [ "$keep" -lt 1 ] && { echo "keep は 1 以上(全部消す口は作らない)" >&2; exit 2; }
    out="$(list_raw)" || { echo "並べられない" >&2; exit 3; }
    # 固定されている物は数に入れず、消しもしない。
    victims="$(printf '%s\n' "$out" | awk -F'\t' '$4 != "PINNED" {print $1}' | tail -n +$((keep + 1)))"
    if [ -z "$victims" ]; then echo "間引く物は無い(完全な世代が $keep 個以下)"; exit 0; fi
    echo "消す世代:"; printf '  %s\n' $victims
    if [ "$DRY" -eq 1 ]; then echo "DRY: ここで止める"; exit 0; fi
    for v in $victims; do
        valid_name "$v" || { echo "★名前が不正なので消さない: $v" >&2; continue; }
        r "rm -rf '$RELEASES/$v'" && audit "prune $v"
    done
    echo "間引いた"; exit 0 ;;
esac

# ---- 戻す -----------------------------------------------------------------------
if [ "$mode" = previous ]; then
    want="$(list_raw | head -1 | cut -f1)"
    [ -n "$want" ] || { echo "戻せる世代が無い" >&2; exit 3; }
    echo "一番新しい完全な世代: $want"
fi
valid_name "$want" || { echo "世代の名前が不正: ${want:-（空）}" >&2; exit 2; }

# ★存在と**完全性**を分けて見る。名前が在る事は中身が在る事ではない。
if ! r "[ -d '$RELEASES/$want' ] && [ -f '$RELEASES/$want/DEPLOYED-REV' ]"; then
    echo "★その世代が無いか、版の刻印が無い(戻せる物として数えない): $want" >&2; exit 2
fi
case "$want" in *.partial) echo "★途中で死んだ複製へは戻さない: $want" >&2; exit 2 ;; esac

torev="$(r "head -1 '$RELEASES/$want/DEPLOYED-REV' 2>/dev/null" || echo '?')"
fromrev="$(r "head -1 '$LIVE/DEPLOYED-REV' 2>/dev/null" || echo '?')"
echo "戻す: $fromrev → $torev  ($want)"

if [ "$DRY" -eq 1 ]; then
    echo "DRY: 錠を取り / rsync --delete で書き戻し / launchctl kickstart -k で再起動 / healthz が $torev を返すまで確認"
    exit 0
fi

# 1) 錠。配備と重ならない事。★`--delete` を撃つので、重なると片方の木が混ざる。
if ! r "mkdir '$LOCK' 2>/dev/null"; then
    echo "★配備か別の戻しが走っている($LOCK)。重ねない。" >&2; exit 2
fi
cleanup_lock() { r "rmdir '$LOCK' 2>/dev/null" >/dev/null 2>&1 || true; }
trap cleanup_lock EXIT

# 2) 書き戻す。`.git` と `.gitignore` は私の物ではないので触らない(配備側と同じ規約)。
#    ★同期木の**外**(~/.rc-backend/ の鍵・登録簿・拒否規則)には一切触れない。
if ! r "rsync -a --delete --exclude '.git/' --exclude '.gitignore' '$RELEASES/$want'/ '$LIVE'/"; then
    echo "★書き戻しに失敗した。本番は中途半端な可能性がある。" >&2
    audit "rollback FAILED-RSYNC $want"; exit 1
fi
audit "rollback rsync-done $want ($fromrev -> $torev)"

# 3) 写し終えて**から**再起動。★`unload` ではなく `kickstart -k`(この機体には
#    古い定義を掴んだ事故が在る)。窓番(rc-phone-window)は触らない。
r "launchctl kickstart -k gui/\$(id -u)/$JOB" >/dev/null 2>&1 || \
    echo "  (再起動の command が非ゼロ。下の健康確認で本当の所を見る)" >&2

# 4) ★**本物の健康確認**。rsync が 0 で帰った事を成功と呼ばない。
#    版まで見る —— 200 が返るだけなら別の物が答えている可能性がある。
ok=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    got="$(curl -s --max-time 10 "$HEALTH" 2>/dev/null \
           | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)"
    case "$got" in
        "$torev"|"$torev"*) ok=1; break ;;
    esac
done
if [ "$ok" = 1 ]; then
    echo "戻した: 本番は $torev を名乗っている(healthz で確認)"
    audit "rollback OK $want -> $torev"; exit 0
fi
echo "★書き戻したが、healthz が $torev を返さない(見えたのは: ${got:-無応答})。" >&2
echo "  木は戻っている。動いていないのは別の層(launchd / port / トンネル)。" >&2
audit "rollback UNHEALTHY $want -> $torev"; exit 1
