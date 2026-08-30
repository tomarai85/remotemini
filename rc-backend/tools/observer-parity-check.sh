#!/bin/bash
# observer-parity-check.sh — friday の `~/rc-observer/tools/` が repo と**一致しているか**を測る。
#
# ── なぜ配備台本と分けるか(2026-08-30)────────────────────────────────────────
# 配る台本の自己申告(「配った」)は、配れた事の証拠にならない。実際 2026-08-30 に、
# `deploy-to-friday.sh` が **`~/rc-observer/` を守備範囲に持っていない**事を見落として
# いた為に、friday の `health-observer.sh` が repo より **139 行・22 日**古いまま動き、
# 毎日 Tom の Discord へ「監視が壊れている」の誤報を投げていた(実発火 08-28 / 08-29)。
# 古い事に気付いた経緯も配備の記録ではなく、**別レーンの Planner が md5 を突き合わせた**事だった。
#
# だから測る側を独立に置く。此の台本は何も配らない —— 配る台本が嘘をついても、
# 此処が赤くなる。
#
# ★測るのは**中身の一致**(md5)であって mtime ではない。0 バイトの file の mtime は
#   「最後に書いた時刻」ではなく「最後に開いた時刻」で、同じ日にそれで誤診している
#   (`/tmp/rc-health-observer.out` を見て「38 時間死んでいる」と読んだ)。
#
# 使い方:
#   bash tools/observer-parity-check.sh          # 一致 = rc 0 / ずれ = rc 1 / 測れない = rc 2
#   RC_OBSERVER_HOST=athenas bash tools/...      # 宛先を差す(検査の継ぎ目)
#
# 終了コード: 0=一致 / 1=ずれている(赤) / 2=**測れなかった**(0 に丸めない)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
HOST="${RC_OBSERVER_HOST:-athenas}"
REMOTE_DIR="${RC_OBSERVER_REMOTE_DIR:-\$HOME/rc-observer}"

# 同期の対象 = **observer が実行時に読む物の連鎖ぜんぶ**。
#
# ★2026-08-30、Codex の指摘で1件訂正した。初版は
#   「`health-step.mjs` は friday に在るが repo に無い(由来不明)」と書いて除外していたが、
#   **事実と逆**だった: `git ls-files` に `tools/health-step.mjs` も `src/health.mjs` も在る。
#   確かめずに書いた一文を、除外の根拠に使っていた。
#   結果、この検査は「3/3 一致」と言いながら**判定の本体が古くても緑**になる ——
#   まさに此の台本が防ごうとしている壊れ方の、一段上での再演。
#
# 連鎖: health-observer.sh → tools/health-step.mjs → src/health.mjs
#   (`health-step.mjs` の `from "../src/health.mjs"` の import)
# 相対 path で列挙する(向こうでは `~/rc-observer/` が根)。
FILES=(tools/health-observer.sh tools/funnel-exposure-check.sh tools/tailnet-key-expiry.sh
       tools/health-step.mjs src/health.mjs)

fail=0; measured=0

local_md5() { md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 向こう側の md5 を1回の ssh でまとめて取る(file 毎に繋ぐと遅く、途中で切れた時に
# 「ずれ」と「届かない」の区別が付かなくなる)。
remote_out="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" \
    "cd $REMOTE_DIR 2>/dev/null || exit 9; for f in ${FILES[*]}; do
       if [ -f \"\$f\" ]; then printf '%s %s\\n' \"\$(md5 -q \"\$f\")\" \"\$f\"; else printf 'MISSING %s\\n' \"\$f\"; fi
     done" 2>/dev/null)"
rc=$?
if [ $rc -ne 0 ] || [ -z "$remote_out" ]; then
    echo "observer-parity: 測れない(ssh rc=$rc / 出力が空)。**一致とは言わない**"
    exit 2
fi

for f in "${FILES[@]}"; do
    lf="$HERE/$f"
    if [ ! -f "$lf" ]; then
        echo "  ?  $f — repo に無い(列挙が古い)"; fail=1; continue
    fi
    want="$(local_md5 "$lf")"
    got="$(printf '%s\n' "$remote_out" | awk -v n="$f" '$2==n {print $1}')"
    # ★数えるのは**有効な md5 を読めた後だけ**(2026-08-30、Codex の指摘)。
    #   解析の前に数えていた初版は、向こうの出力が壊れていても件数検査を通した ——
    #   「空の和を一致と読ませない」為の検査自体が空回りしていた。
    case "$got" in
        [0-9a-f][0-9a-f]*) measured=$((measured + 1)) ;;
    esac
    if [ -z "$got" ]; then
        echo "  NG $f — 向こうの値が読めない"; fail=1
    elif [ "$got" = "MISSING" ]; then
        echo "  NG $f — friday に**無い**(依存物が欠けると閾値なしで鳴る枝が在る)"; fail=1
    elif [ "$got" != "$want" ]; then
        echo "  NG $f — ずれている(repo=$want friday=$got)"; fail=1
    else
        echo "  ok $f"
    fi
done

# ★件数を主張する。列挙が壊れて 0 件になっても「全部一致」に見えないようにする
# (此の repo が何度も踏んだ「空の和を一致と読ませない」型)。
if [ "$measured" -ne "${#FILES[@]}" ]; then
    echo "observer-parity: 測れた本数が $measured / ${#FILES[@]} = 測定不成立"
    exit 2
fi

if [ "$fail" -eq 0 ]; then
    echo "observer-parity: 一致 $measured/${#FILES[@]}"
    exit 0
fi
echo "observer-parity: ずれている(配り直しは tools/deploy-observer-to-friday.sh)"
exit 1
