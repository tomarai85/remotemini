#!/bin/bash
# 生成物を触る走行を **1 本に絞る**。
#
# ★何を直しに来たか(2026-08-15、実測):
#   `build.sh --sim` と `run-controls.sh --all` を並走させたら、検査が 9 本落ちた。
#   製品の欠陥ではなく、**両者が同じ生成物を書き合った**だけだった:
#     - `ios/Info.plist` は `xcodegen generate` の生成物(`ios/.gitignore` 済)。
#     - `build.sh` は `RC_BUILD_REV` を export してから generate するので、刻印が入る。
#     - 対照台本(`account-ui-control.sh` 等 5 本)は **自分で generate を撃つ**が、
#       変数を持たない。xcodegen は未定義でも落ちず `${RC_BUILD_REV}` という
#       **文字列**を書く(`build.sh` の「未定義でも xcodegen は落ちず」の註に
#       実測として残っている)。
#       ★此処は最初 build.sh を**行番号で**引いていて、**同じ日の内に其の行が
#         私自身の追記で別物へずれた**(指していた先が、今は此の錠の註)。
#         行番号は書いた瞬間から写し —— 規則が正しい事を身をもって測った形。
#         ★註釈で「昔こう引いていた」と字面を再現するのも駄目。検出器は引用と
#           引用の**話**を区別できない(其れで commit が 1 回止まった)。
#   → 対照が刻印を潰した瞬間に、走行中の UI 検査が `rev unknown` を読む。
#     `BuildIdentityUITests` 3 本 + `ConversationViewModelTests` 6 本が此れで落ちた。
#
#   ★この赤の性質が悪いのは、**製品の欠陥と見分けが付かない**事。私は実際に
#     引き継ぎへ「main に居た製品の赤」と書いた。偽の赤は嘘の記録を作る。
#
# 何故「並走させるな」と書くだけでは駄目か: 註釈は強制しない。台本は AI にも
# `run-controls.sh` にも叩かれ、どちらも註釈を読まない。生成物の共有は**構造**なので、
# 塞ぐのも構造でなければならない(規約 = `DESIGN.md` の Gate 4「文書は強制しない」)。
#
# 機構は `rc-backend/tools/deploy-to-edith.sh` の配備錠と**同じ形**にしてある。
# 同じ症状に 2 つ目の機構を足すのは、この repo が commit `e5e15a3` で一度やって
# 剥がした失敗なので、増やさずに借りる。
#
# 使い方(呼ぶ側):
#   OWNER="build.sh $$"
#   "$HERE/xcode-tree-lock.sh" acquire "$OWNER" || exit 1
#   trap '"$HERE/xcode-tree-lock.sh" release "$OWNER"' EXIT
#
# fail-closed: 取れなければ **非零で終わる**。呼ぶ側が握り潰さない限り、
# 2 本目は生成物に触れないまま止まる。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS="$(cd "$HERE/.." && pwd)"

# 置き場所は `ios/build/`(`.gitignore` 済)。追跡ファイルは 1 文字も増えない。
LOCK="${RC_XCODE_TREE_LOCK:-$IOS/build/.xcode-tree.lock}"
# 実測の最長走行: `signout-notice-control.sh` 734 秒、`build.sh --sim` 約 15 分。
# 3600 秒はその 2 倍以上 = 生きている走行を「古い」と誤読しない余裕。
MAX_S="${RC_XCODE_TREE_LOCK_MAX_S:-3600}"
# 空くまで待つ秒数。**既定 0 = 待たずに断る**(手で叩いた時に理由が出る方が良い)。
# 立てるのは束ねて回す側だけ。詳細は下の acquire の註釈。
WAIT_S="${RC_XCODE_TREE_LOCK_WAIT_S:-0}"

usage() {
    echo "usage: $0 {acquire|release|holder} [owner]" >&2
    exit 2
}

# ─────────────────────────────────────────────────────────────────────────────
# ★死活を**時刻で推定しない**(2026-08-15、Codex に初版を否定されて書き直した)
#
# 初版は「札の時刻が MAX_S より古ければ落ちた跡」と見なしていた。3 点で不正:
#   1. `date +%s > "$LOCK/at"` はリダイレクトが先にファイルを**作って空にする**ので、
#      読む側の `cat` が空文字を**正常終了で**受け取る瞬間が在る。読み手側で
#      `stat` へ落としても此処は塞がらない(空文字は「読めた」なので)。
#   2. TTL は heartbeat でも lease でもないので、MAX_S を超えて走っている
#      **生きている**走行から錠を奪える。
#   3. 取り直しの「札を上書き → 2 秒寝る → 読み直す」は、遅れて来た 2 本目が
#      同じ事をすれば両方が勝つ。固定の待ちは競合の不在を証明しない。
#
# 1 台の中で走る錠なので、推定は要らない —— **PID の生死は直に見られる**。
# 札の形は `<台本名> <PID>`(取っ手 `xcode-tree-guard.sh` が作る)。
# 時刻に落ちるのは、札に PID が無い時(手で作った錠 / 対照)だけ。
#
# 過去の同型: 「調べる → 消す → 同じ名前で作り直す」を判定の厳しさで守ろうとして
# 二重取得が塞げなかった件(2026-08-08、リース)。判定を厳しくするのではなく、
# **判定に頼らない形へ変える**のが解だった。此処も同じ形にしてある。
# ─────────────────────────────────────────────────────────────────────────────

owner_pid() { printf '%s' "${1:-}" | /usr/bin/awk '{print $NF}' | /usr/bin/grep -E '^[0-9]+$' 2>/dev/null; }

holder_state() { # holder_state <札> -> alive | dead | unknown
    local o="${1:-}" pid name cmd
    pid="$(owner_pid "$o")"
    [ -n "$pid" ] || { echo unknown; return; }
    /bin/kill -0 "$pid" 2>/dev/null || { echo dead; return; }
    name="${o% *}"
    cmd="$(/bin/ps -o command= -p "$pid" 2>/dev/null)"
    # ps が答えない時は「生きている」へ倒す(fail-closed)。**奪う方向へは倒さない**。
    [ -n "$cmd" ] || { echo alive; return; }
    case "$cmd" in *"$name"*) echo alive; return;; esac
    echo dead   # 生きているが別の program = PID の使い回し
}

# 死んだ跡を退ける。**原子的 rename** なので 2 本が同時に来ても成功するのは 1 本。
# 退けた後は `mkdir` を撃ち直す = 勝者を決めるのは最初から最後まで `mkdir` 1 つ。
reclaim() {
    local dead="${LOCK}.dead.$$"
    /bin/mv "$LOCK" "$dead" 2>/dev/null || return 1
    /bin/rm -f "$dead"/owner "$dead"/at "$dead"/.owner.* "$dead"/.at.* 2>/dev/null
    /bin/rmdir "$dead" 2>/dev/null
    return 0
}

# 札は**書き終えてから置く**(temp → rename)。空の札を他人に読ませない。
stamp_owner() {
    printf '%s\n' "$owner" > "$LOCK/.owner.$$" && /bin/mv "$LOCK/.owner.$$" "$LOCK/owner"
    date +%s              > "$LOCK/.at.$$"    && /bin/mv "$LOCK/.at.$$"    "$LOCK/at"
}

cmd="${1:-}"
owner="${2:-}"

case "$cmd" in
acquire)
    [ -n "$owner" ] || usage
    mkdir -p "$(dirname "$LOCK")"
    waited=0
    tries=0
    while :; do
        # 勝者を決めるのは最初から最後まで此の `mkdir` 1 つだけ。
        if mkdir "$LOCK" 2>/dev/null; then
            stamp_owner
            exit 0
        fi

        held="$(cat "$LOCK/owner" 2>/dev/null || echo '')"
        state="$(holder_state "$held")"

        # 齢は**判定には使わない**(下の unknown を除く)。断り文に出すだけ。
        at="$(cat "$LOCK/at" 2>/dev/null)"
        case "$at" in ''|*[!0-9]*) at="$(/usr/bin/stat -f %m "$LOCK" 2>/dev/null || echo 0)";; esac
        age=$(( $(date +%s) - at ))

        if [ "$state" = "unknown" ]; then
            # 札に PID が無い = 手で置いた錠、対照、または `mkdir` は済んだが
            # 札をまだ置いていない瞬間。此の時だけ時刻に落ちる。
            # 錠 dir の mtime は `mkdir` 自身が打刻するので、札が無くても歳は取れる。
            if [ "$age" -ge "$MAX_S" ]; then state=dead; else state=alive; fi
        fi

        if [ "$state" = "dead" ]; then
            tries=$(( tries + 1 ))
            if [ "$tries" -gt 5 ]; then
                echo "★死んだ錠を退けられない($LOCK)。手で消してから回す事" >&2
                exit 1
            fi
            echo "★錠の持ち主が居ない(札 ${held:-不明} / ${age} 秒前)= 落ちた跡。退ける" >&2
            reclaim >/dev/null 2>&1   # 負けても良い。勝った者が居るなら次の周で判る
            continue
        fi

        # ここから先は「生きている持ち主が居る」で確定。
        # 既定は WAIT_S=0 = **即座に断る**。手で 1 本叩いた時は、黙って遅くなるより
        # 「今 build.sh が握っている」と名指しで断られた方が判る。
        # 束ねて回す走行(`run-controls.sh`)だけが WAIT_S を立てる —— 40 分走った掃きが
        # 途中で赤くなるより、待って通る方が正しいから(掛け場所は台本 1 本ずつなので
        # 待つ相手は最長 734 秒 = `signout-notice-control.sh` の実測)。
        if [ "$waited" -lt "$WAIT_S" ]; then
            if [ "$waited" -eq 0 ]; then
                echo "★生成物を触る走行が在る(持ち主 $held)。空くまで待つ(上限 ${WAIT_S} 秒)" >&2
            elif [ $(( waited % 60 )) -eq 0 ]; then
                echo "  …待機中 ${waited} 秒(持ち主 $held)" >&2
            fi
            sleep 5
            waited=$(( waited + 5 ))
            continue
        fi
        echo "★生成物(ios/Info.plist / RemoteMini.xcodeproj)を触る走行が既に在る:" >&2
        echo "  持ち主 ${held:-不明}(${age} 秒前)。重ねると刻印を潰し合い、**偽の赤**が出る。" >&2
        echo "  終わってから回すか、RC_XCODE_TREE_LOCK を分けて別の作業木で回す事。" >&2
        exit 1
    done
    ;;
release)
    [ -n "$owner" ] || usage
    # ★**自分の札が入っている時だけ**外す。無条件に外すと、古い錠を取り直した
    #   新しい走行の錠を、死にかけの古い走行が消してしまう。
    held="$(cat "$LOCK/owner" 2>/dev/null || echo '')"
    if [ "$held" != "$owner" ]; then
        exit 0
    fi
    rm -f "$LOCK"/owner "$LOCK"/at "$LOCK"/.owner.* "$LOCK"/.at.* 2>/dev/null
    rmdir "$LOCK" 2>/dev/null
    exit 0
    ;;
holder)
    cat "$LOCK/owner" 2>/dev/null || echo ''
    exit 0
    ;;
*)
    usage
    ;;
esac
