#!/bin/bash
# 「変異の走行が今まさに動いているか」を判定する**唯一の場所**。
#   走行中 = exit 0 / **居ないと確認できた** = exit 1 / **測れなかった** = exit 2。
#
# 呼ぶ側は **exit が丁度 1 の時だけ**先へ進む事。0 と 2+ は等しく「進むな」である。
#   2026-08-04: 呼ぶ側が `if bash …; then 止める` と書いていて、2(測れなかった)が
#   「止めなくてよい」に落ちていた。門が答えていたのは「止めろと言われたか」で、
#   答えるべきだったのは**「進んでよいと確認できたか」**。この2つは計器が壊れた時に
#   だけ食い違い —— そして計器が壊れる時とは、まさに門が要る時である。
#
# なぜ独立した file にするか(2026-08-02):
#   同じ判定が `tools/deploy-to-edith.sh` `tools/check-mutation-targets.sh`
#   `test/mutation-target-controls.sh` の3箇所に**複製**されていて、その3つが
#   揃って同じ欠陥を持っていた。複製された判定は、片方だけ直して片方が腐る。
#
# ★★2026-08-04、判定の**根**を入れ替えた(DESIGN §2.38「まだ直っていない根」)。
#   旧版は `pgrep -f '[Pp]ython[0-9.]*( +-[^ ]+)* +[^ ]*mutation-controls\.py'`、
#   つまり argv 全体への文字列一致で、「走行が動いているか」ではなく
#   **「その字が誰かのコマンド行に在るか」**を訊いていた。推定なので両方向に外れ、
#   両方向とも実害が出ている:
#     - 偽陽性(8/02): 台本名を変数に持つだけの shell や、`until ! pgrep …` という
#       待ち受け**自身**に当たる。当たると配備が**恒久的に**塞がる。
#     - 偽陰性(8/02 夜): `python3 -u <台本>` の `-u` を `[^ ]*` が跨げず、走行中に
#       2本目を起こした。門も同じ判定なので黙って開いていた。
#   正規表現を精密にしても、精密な**推定**が残るだけである。直した形は
#   「走行台本自身が印を立て、その主の生死を訊く」 —— 誤検出も引数の揺れも
#   まとめて消える。**推定を観測に替える**のがこの入れ替えの中身。
#
# 印を書くのは `test/mutation-controls.py` の `_take_run_lock()`。書式:
#     pid=<走行の pid>
#     started=<`ps -o lstart=` の1行>
#     root=<測っている木>
#
# ★`started` が要る理由: pid だけでは足りない。SIGKILL された走行が印を残し、その pid が
#   別のプロセスへ再利用されると `kill -0` は「生きている」と答える。それは配備が二度と
#   通らない形 —— 8/02 の恒久的な詰まりと**同じ壊れ方**を、新しい根で作り直す事になる。
#   起動時刻まで一致して初めて「同じプロセス」と言える。
#
# ★既定の印の path は `test/mutation-controls.py` にも書いてある = **写しが2つ在る**。
#   消せない(片方は python、片方は sh)ので、`test/mutation-run-live-controls.sh` が
#   両方の本体から抜いて一致を見ている。写しを持たない事より、**写しが割れた事を
#   検出できる**事が大事(この file の頭に在る教訓の、そのままの適用)。
set -uo pipefail

LOCK="${RC_MUTATION_LOCK:-/tmp/rc-backend-mutation-run.lock}"
# ★継ぎ目。計器(`ps`)が**失敗した**時に本体が何と答えるかを、対照が駆動できる様にする。
#   囮プロセスを立てる方式では計器の失敗を起こせない —— そして最大の穴はいつも
#   「判らなかった」を「居ない」に丸める所に在る。
PS="${RC_PS_BIN:-/bin/ps}"

VERDICT=2
WHY=""
PID=""
STARTED=""
ROOT=""

probe() {
    if [ ! -e "$LOCK" ]; then
        # 印が無い = 走行が始まっていない、か、正しく終わって降ろされた。
        # **確認できた「居ない」**なので 1(呼ぶ側が進んでよい唯一の値)。
        VERDICT=1; WHY="印が無い($LOCK)= 走行していない"; return
    fi

    # 欄が丁度1本ずつでなければ測らない。曖昧さを「先頭を採る」で消すと、
    # 実際に書かれた物と違う値で判定してしまう。
    local npid nsta
    npid="$(/usr/bin/grep -c '^pid=' "$LOCK" 2>/dev/null || true)"
    nsta="$(/usr/bin/grep -c '^started=' "$LOCK" 2>/dev/null || true)"
    if [ "$npid" != "1" ] || [ "$nsta" != "1" ]; then
        VERDICT=2
        WHY="印が壊れている($LOCK: pid=${npid}行 / started=${nsta}行)= 走行の有無を測れていない"
        return
    fi
    PID="$(/usr/bin/sed -n 's/^pid=//p' "$LOCK")"
    STARTED="$(/usr/bin/sed -n 's/^started=//p' "$LOCK")"
    ROOT="$(/usr/bin/sed -n 's/^root=//p' "$LOCK" 2>/dev/null | /usr/bin/head -1)"
    case "$PID" in
        ''|*[!0-9]*)
            VERDICT=2; WHY="印の pid が数でない(${PID})= 測れていない"; PID=""; return ;;
    esac

    # 生死は `kill -0` と `ps` の**両方**に訊く。`kill -0` は自分の物でないプロセスで
    # EPERM(生きているのに非0)になり得るので、片方だけだと死と読み違える。
    local krc=0
    kill -0 "$PID" 2>/dev/null || krc=$?
    local psout prc=0
    # ★`TZ` と `LC_ALL` を固定する(2026-08-04、Codex 指摘 #4)。`lstart` は**呼び手の
    #   時間帯と locale で描かれる**。書き手(python)と読み手(此処)の環境が違うと ——
    #   片方が launchd 由来で TZ を持たない、片方が shell から走る —— 同じプロセスが
    #   違う文字列になり、下の照合が「pid の再利用」と読む。判定は exit 1、つまり
    #   **走行中に門が開く**。印は環境を跨いで読まれるので、両側で同じ描き方に固定する。
    psout="$(TZ=UTC LC_ALL=C "$PS" -o lstart= -p "$PID" 2>/dev/null)" || prc=$?
    if [ "$prc" -gt 1 ]; then
        # BSD ps は「居ない」を 1 で返す。2 以上は ps 自体が動いていない。
        VERDICT=2; WHY="ps が exit=${prc} で失敗した = 主の生死を測れていない"; return
    fi
    psout="$(printf '%s' "$psout" | /usr/bin/sed -e 's/^ *//' -e 's/ *$//')"

    if [ -z "$psout" ] && [ "$krc" -ne 0 ]; then
        VERDICT=1; WHY="印の主(pid=${PID})は既に居ない = 古い印。走行していない"; return
    fi
    if [ -n "$psout" ] && [ "$psout" != "$STARTED" ]; then
        VERDICT=1
        WHY="pid=${PID} は生きているが起動時刻が違う(印[${STARTED}] 実[${psout}])= pid の再利用。走行は終わっている"
        return
    fi
    if [ -z "$psout" ]; then
        # signal は届くのに ps が何も返さない。丁度終わった所で競ったか、計器の不調。
        # どちらにせよ**同一性を確かめていない**ので、居ないとは言えない。
        VERDICT=2; WHY="pid=${PID} に signal は届くのに ps が何も返さない = 同一性を確かめられない"; return
    fi
    VERDICT=0; WHY="走行中(pid=${PID}, 木=${ROOT:-?})"
}

probe

# ★`--who` = 「何が掴んでいるか」を、**引数を出さずに**言う。
#   塞がれた人が最初に要るのは「本当に変異走行か」で、それは印の中身と実行体の名前で判る。
#   ★argv は絶対に出さない: 過去に `pgrep -lf` が Google OAuth の client secret を会話へ
#     印字している。診断の為に秘密を印字する検査は、守る物を自分で壊している。
#     `comm` は実行体の名前だけなので、主が何であっても安全に見せられる。
if [ "${1:-}" = "--who" ]; then
    echo "$WHY"
    if [ -n "$PID" ]; then
        "$PS" -o pid=,comm= -p "$PID" 2>/dev/null
    fi
    exit 0
fi

if [ "$VERDICT" = "2" ]; then
    echo "mutation-run-live: $WHY" >&2
fi
exit "$VERDICT"
