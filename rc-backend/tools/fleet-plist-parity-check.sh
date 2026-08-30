#!/bin/bash
# no-operator: 人が撃つ。生きた机(friday)への ssh が要るので門からは回せない。配備の後と、plist を触った後に撃つ。
# fleet-plist-parity-check.sh — friday の `~/Library/LaunchAgents/com.fleet.*.plist` が
# repo と一致し、かつ**その job が登録されている**かを測る。何も配らない。
#
# ── なぜ要るか(2026-08-30)──────────────────────────────────────────────────
# 同じ日に2つ踏んでいる:
#   (1) `~/rc-observer/` が `deploy-to-friday.sh` の守備範囲の外に落ちていて、friday の
#       `health-observer.sh` が **139 行・22 日**古いまま毎日 Tom へ誤報を投げていた。
#       台本には `observer-parity-check.sh` を作って蓋をしたが、**plist は誰も見ていない**。
#   (2) `com.edith.log-rotate-check` は plist が置いて在るのに登録されていない ——
#       **置いた事は動いている事ではない**。此の検査はそこも見る。
# 初回の走行で `com.fleet.rc-ota.plist` のずれを1件掴んだ(中身はコメント1行で、
# friday 側が古い install 手順 `rc-backend/launchd/` を指していた)。
#
# ★測るのは**中身の一致**(md5)であって mtime ではない。0 バイトの file の mtime は
#   「最後に書いた時刻」ではなく「最後に開いた時刻」で、同じ日にそれで誤診している。
#   ★コメントだけの差も**残す**。今回の様に「配布経路が追随していない」実測だから。
#
# ★配る側と測る側を分ける。配る台本の自己申告(「配った」)は、配れた事の証拠にならない。
#
# ── ★★此の検査が言える事・言えない事(2026-08-30、Codex の指摘2)─────────────
# `ok` が言えるのは **「disk の中身が一致していて、job が登録されている」**まで。
# **今 launchd が使っている定義が其の file と同じ事は言えない** ——
# plist を書き換えても `bootout` + `bootstrap` しなければ、launchd は掴んだままの
# 古い定義で動き続ける(`kickstart` は再読込ではない。此の repo 自身が
# `deploy-to-edith.sh` にその事故を記録している)。
# 根治は「配る側が canonical な plist を置き、変えた時に bootout+bootstrap する」事で、
# 後から比べる此の検査ではない。だから文面で `有効定義は未確認` と刷る。
#
# 使い方:
#   bash rc-backend/tools/fleet-plist-parity-check.sh
#   RC_FLEET_HOST=athenas bash …            # 宛先を差す(検査の継ぎ目)
#
# 終了コード:
#   0 = 全部一致・全部登録済
#   1 = **ずれ**(中身が違う / 向こうに無い / 未登録 / repo に無い job が居る)
#   2 = **測定不成立**のみ(ssh が失敗 / 出力が空 / launchctl 自体が動かない /
#       repo の glob が 0 本)。★不在は「測れなかった」ではなく**確定したずれ**なので 1。
#       (2026-08-30、Codex の指摘4。初版は不在を 2 にしていて、対照がその誤った契約を
#        12/12 緑で固定していた。)
set -uo pipefail

HERE="${RC_FLEET_PLIST_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # = rc-backend/tools/
HOST="${RC_FLEET_HOST:-athenas}"
# ★継ぎ目。対照は本物の friday を叩けない(叩けば検査が本番の状態に依存する = 測れない日が出る)。
#   `RC_FLEET_SSH` に偽物を差せば、向こうの出力を対照の側で作れる。既定は本物。
SSH_BIN="${RC_FLEET_SSH:-ssh}"

# ★`rc-health-observer` は repo 側が `.example`(雛形)しか持たない。雛形は台本の絶対 path を
#   埋める前の形なので、**byte 一致を期待するのが誤り**。
#   ★だが「比べない」と刷るだけでは false green(Codex の指摘3)—— 説明は検査ではない。
#   固定値(Label / StartInterval / RunAtLoad)は**一致を要求**し、可変部分の
#   `ProgramArguments` は「許した形に収まっているか」だけ見る。
TEMPLATE_ONLY="com.fleet.rc-health-observer"
TEMPLATE_PROG_SUFFIX="/tools/health-observer.sh"

fail=0; measured=0
local_md5() { md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# repo 側の一覧(雛形は除く)。**glob で拾う** —— 名前を並べると、job が1本増えた時に
# 一覧を触る人が居ないと漏れる(observer が 22 日古くなったのと同じ形)。
repo_names=()
for p in "$HERE"/com.fleet.*.plist; do
    [ -f "$p" ] || continue
    repo_names+=("$(basename "$p" .plist)")
done
if [ "${#repo_names[@]}" -eq 0 ]; then
    echo "fleet-plist-parity: repo に com.fleet.*.plist が1本も無い = 測定不成立(glob を疑う事)"
    exit 2
fi

# 向こう側を**1回の ssh** でまとめて取る(file 毎に繋ぐと遅く、途中で切れた時に
# 「ずれ」と「届かない」の区別が付かなくなる)。
#
# ★登録の判定に `launchctl list | awk` を使わない(2026-08-30、Codex の指摘1)。二重に危ない:
#   (a) ssh の暗黙 domain と `~/Library/LaunchAgents` の GUI domain は同一とは限らない。
#       `gui/<uid>/<label>` を**名指し**すれば曖昧さが消える(`delivery-check.sh` と同じ手)。
#   (b) `launchctl` 自体が失敗しても `awk` は静かに 0 行を返すので、**全件が「未登録」**に
#       化ける = 本番に対する false red。だから launchctl が動く事を先に1行で確かめ、
#       駄目なら「未登録」ではなく**測定不成立**にする。
remote="$("$SSH_BIN" -o ConnectTimeout=15 -o BatchMode=yes "$HOST" '
    uid="$(id -u)"
    launchctl print "gui/$uid" >/dev/null 2>&1 && echo "LAUNCHCTL ok" || { echo "LAUNCHCTL fail"; exit 0; }
    cd "$HOME/Library/LaunchAgents" 2>/dev/null || exit 9
    for f in com.fleet.*.plist; do
        [ -f "$f" ] || continue
        label="${f%.plist}"
        printf "MD5 %s %s\n" "$(md5 -q "$f")" "$label"
        if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
            printf "REG yes %s\n" "$label"
        else
            printf "REG no %s\n" "$label"
        fi
        # 雛形しか repo に無い1本の為に、固定値だけ抜いて送る。
        printf "KV %s Label %s\n"         "$label" "$(/usr/libexec/PlistBuddy -c "Print :Label" "$f" 2>/dev/null)"
        printf "KV %s StartInterval %s\n" "$label" "$(/usr/libexec/PlistBuddy -c "Print :StartInterval" "$f" 2>/dev/null)"
        printf "KV %s RunAtLoad %s\n"     "$label" "$(/usr/libexec/PlistBuddy -c "Print :RunAtLoad" "$f" 2>/dev/null)"
        printf "KV %s Prog1 %s\n"         "$label" "$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:1" "$f" 2>/dev/null)"
    done
' 2>/dev/null)"
rc=$?
if [ $rc -ne 0 ] || [ -z "$remote" ]; then
    echo "fleet-plist-parity: 測れない(ssh rc=$rc / 出力が空)。**一致とは言わない**"
    exit 2
fi
if printf '%s\n' "$remote" | grep -q '^LAUNCHCTL fail$'; then
    echo "fleet-plist-parity: 向こうの launchctl が動かない = 登録の有無を測れない。"
    echo "  ★全件を『未登録』と読ませない(それは本番に対する嘘の赤になる)"
    exit 2
fi

remote_md5()  { printf '%s\n' "$remote" | awk -v n="$1" '$1=="MD5" && $3==n {print $2}'; }
remote_names(){ printf '%s\n' "$remote" | awk '$1=="MD5" {print $3}'; }
is_reg()      { printf '%s\n' "$remote" | awk -v n="$1" '$1=="REG" && $3==n && $2=="yes" {f=1} END{exit !f}'; }
kv()          { printf '%s\n' "$remote" | awk -v n="$1" -v k="$2" '$1=="KV" && $2==n && $3==k {$1=$2=$3=""; sub(/^ +/,""); print}'; }

for name in "${repo_names[@]}"; do
    want="$(local_md5 "$HERE/$name.plist")"
    got="$(remote_md5 "$name")"
    # ★数えるのは**有効な md5 を読めた後だけ**。解析の前に数えると、向こうの出力が
    #   壊れていても件数検査を通ってしまう(= 空の和を一致と読ませない検査が空回りする)。
    case "$got" in [0-9a-f][0-9a-f]*) measured=$((measured + 1)) ;; esac
    if [ -z "$got" ]; then
        # ★不在は「測れなかった」ではない。**据えていないという確定した事実**なので赤。
        echo "  NG $name — friday に**無い**(据えていないか、名前が違う)"; fail=1; continue
    fi
    if [ "$got" != "$want" ]; then
        echo "  NG $name — ずれている(repo=$want friday=$got)"; fail=1; continue
    fi
    if is_reg "$name"; then
        echo "  ok $name — disk 一致・登録済(★有効定義は未確認)"
    else
        echo "  NG $name — 中身は一致しているが **登録されていない**(据えただけで動いていない)"
        fail=1
    fi
done

# repo に無い job が friday に居る = 誰かが手で置いた物。消さない・触らない・**名指しする**。
for name in $(remote_names); do
    [ "$name" = "$TEMPLATE_ONLY" ] && continue
    case " ${repo_names[*]} " in
        *" $name "*) ;;
        *) echo "  ?  $name — friday に在るが repo に無い(所有者を確かめる事。消さない)"; fail=1 ;;
    esac
done

# ── 雛形しか repo に無い1本 ────────────────────────────────────────────────
# ★「比べない」と刷るだけでは false green。byte は比べられないが、**固定値は比べられる**。
if printf '%s\n' "$remote" | awk -v n="$TEMPLATE_ONLY" '$1=="MD5" && $3==n {f=1} END{exit !f}'; then
    tfail=0
    ex="$HERE/$TEMPLATE_ONLY.plist.example"
    # ★`PlistBuddy` は file が無い時に **"File ... Will Create: <path>" を stdout へ出して
    #   exit 0 する**(2026-08-30、対照の砂場で実測)。`2>/dev/null` では消えず、その文字列が
    #   そのまま「雛形の値」として比較に入っていた —— 検査の入力が壊れているのに
    #   「雛形と違う」という**もっともらしい赤**が出る形。入力の不在は入力の不在として言う。
    if [ ! -f "$ex" ]; then
        echo "  NG $TEMPLATE_ONLY — repo に雛形 $(basename "$ex") が無い(比べる基準が存在しない)"
        tfail=1
    else
    for k in Label StartInterval RunAtLoad; do
        w="$(/usr/libexec/PlistBuddy -c "Print :$k" "$ex" 2>/dev/null)"
        case "$w" in *"Will Create"*|*"Error Reading"*) w="" ;; esac
        g="$(kv "$TEMPLATE_ONLY" "$k")"
        if [ -z "$w" ]; then
            echo "  NG $TEMPLATE_ONLY — 雛形から $k を読めない(雛形の形が変わった)"; tfail=1
        elif [ "$w" != "$g" ]; then
            echo "  NG $TEMPLATE_ONLY — $k が雛形と違う(雛形=$w friday=$g)"; tfail=1
        fi
    done
    fi
    prog="$(kv "$TEMPLATE_ONLY" Prog1)"
    case "$prog" in
        /*"$TEMPLATE_PROG_SUFFIX") ;;    # 可変なのは前半の絶対 path だけ
        *) echo "  NG $TEMPLATE_ONLY — 実行する台本が許した形でない(friday=$prog)"; tfail=1 ;;
    esac
    if ! is_reg "$TEMPLATE_ONLY"; then
        echo "  NG $TEMPLATE_ONLY — **登録されていない**"; tfail=1
    fi
    if [ "$tfail" -eq 0 ]; then
        echo "  ok $TEMPLATE_ONLY — 雛形なので byte は比べないが、固定値3つと実行 path は一致・登録済"
    else fail=1; fi
else
    echo "  NG $TEMPLATE_ONLY — friday に無い(監視の段が据わっていない)"; fail=1
fi

# ★件数を主張する。glob が壊れて 0 件になっても「全部一致」に見えないようにする。
#   ★ただし此処は**測定の成否**だけを見る。「向こうに無い」は上で赤にしてあるので、
#     測れた本数が足りない事を測定不成立に混ぜない。
if [ "$measured" -eq 0 ]; then
    echo "fleet-plist-parity: 1本も md5 を読めなかった = 測定不成立"
    exit 2
fi

if [ "$fail" -eq 0 ]; then
    echo "fleet-plist-parity: 一致 $measured/${#repo_names[@]} + 雛形 1(全部登録済・★有効定義は未確認)"
    exit 0
fi
echo "fleet-plist-parity: ずれている(配り直しは scp … athenas:~/Library/LaunchAgents/ の後 bootout+bootstrap)"
exit 1
