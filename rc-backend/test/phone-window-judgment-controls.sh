#!/bin/bash
# controls-for: tools/verify-phone-window.sh
#
# 何を守る対照か —— **鎖③④の証拠 JSON が、観測できなかった物を緑にしない事**。
#
# `verify-phone-window.sh` も safety-core HARD GATE 1 の artifact を作る側。頭に
# 「ssh が通らない = 判定不能(exit 2)。『見えない』を『無事』と書かない」と自分で
# 宣言している道具なので、その宣言が**実装で守られているか**を外から測る。
#
# ★この対照の範囲:
#   見る   = RAW(観測の生テキスト)を与えられた時の**判定**。本物のバイトを切り出す。
#   見ない = 観測そのもの(ssh / tmux / launchctl / 8787)。edith の上でしか動かない。
#   ssh は1回も呼ばない。本番にも edith にも触れない。
#
# ★一番効く壊れ方をここで名指しにしておく: `i(k, d=-1)` の既定値。
#   心拍の欄が**無い**時、-1 は `0 <= att` を外して赤になる。ここを 0 にすると
#   `0 <= 0 <= 180` が成立し、**観測が1つも無いのに「心拍は新鮮」**になる。
#   欄が消える壊れ方(観測側の変更・ssh の途中切れ)と同時に起きるので、
#   一番起きやすく、一番静かで、一番高くつく。§6 の変異がここを撃つ。
#
# 終了コード: 0 = 守られている / 1 = 破れている / 2 = 測れていない
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/tools/verify-phone-window.sh"

if [ ! -f "$TARGET" ]; then
    echo "UNMEASURED  読む file が無い: tools/verify-phone-window.sh"
    exit 2
fi

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
ng() { FAIL=$((FAIL + 1)); echo "  ng   $1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 —— 実際=[$2] 期待=[$3]"; fi; }

# ---- 判定(python)を本物から切り出す --------------------------------------
s=$(grep -n '^import json, os, sys$' "$TARGET" | cut -d: -f1)
e=$(grep -n '^sys.exit(0 if verdict == "ok" else 1)$' "$TARGET" | cut -d: -f1)
if [ "$(echo "$s" | wc -w)" -ne 1 ] || [ "$(echo "$e" | wc -w)" -ne 1 ] || [ "$e" -le "$s" ]; then
    echo "UNMEASURED  錨が一意でない(開始=[$s] 終了=[$e])。錨を付け直す事。"
    exit 2
fi
sed -n "${s},${e}p" "$TARGET" > "$SB/judge.py"
grep -q 'not_measured_here' "$SB/judge.py" || { echo "UNMEASURED  判定の本体が入っていない"; exit 2; }

# ---- 駆動 --------------------------------------------------------------------
judge() { # $1=RAW  $2=EXPECT(既定 present)  $3=判定器(既定 本物)
    RAW="$1" FRESH_S=180 EXPECT="${2:-present}" \
    LABEL=test.label SESSION=work WINDOW=phone HOST=test-host OUT="$SB/out.json" \
    /usr/bin/python3 "${3:-$SB/judge.py}" 2>/dev/null
}
verdict()  { judge "$@" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])' 2>/dev/null; }
chain()    { judge "$2" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin)['chains'].get('$1','—'))" 2>/dev/null; }
failtext() { judge "$@" | /usr/bin/python3 -c 'import json,sys; print(" / ".join(json.load(sys.stdin)["failures"]))' 2>/dev/null; }
rc_of()    { judge "$@" >/dev/null 2>&1; echo $?; }

# 健康な観測ひと揃い。ここから1欄ずつ壊して測る。
HEALTHY='job_present=true
attempt_age_s=12
success_age_s=30
phone_windows=1
phone_panes_alive=1
phone_pane_cmd=node
registry_hits=1
listed_in_api=true
script_procs=1
log_bytes=4096'

without() { printf '%s\n' "$HEALTHY" | grep -v "^$1="; }
withval() { printf '%s\n' "$HEALTHY" | sed "s/^$1=.*/$1=$2/"; }

echo "── 1. 揃っている時だけ緑 ──"
chk "  健康な観測は ok" "$(verdict "$HEALTHY")" "ok"
chk "  そのとき exit 0" "$(rc_of "$HEALTHY")" "0"

echo "── 2. ★観測の欄が「無い」時に緑にしない(未測定 ≠ 無事)──"
for k in job_present attempt_age_s success_age_s phone_windows registry_hits; do
    chk "  $k の欄が無い" "$(verdict "$(without $k)")" "fail"
done

echo "── 3. ★心拍は2本を別々に見る(attempt だけ新しくても緑にしない)──"
# 走ってはいるが毎回どこかの関門で止まっている形。心拍1本だとこれが健康に見える。
chk "  attempt は新しいが success が古い" "$(verdict "$(withval success_age_s 9999)")" "fail"
case "$(failtext "$(withval success_age_s 9999)")" in
    *"在る"*確かめられていない*) ok "  ★理由が「走ってはいるが確かめられていない」と分けて出る" ;;
    *) ng "  success 側の理由が attempt と同じ文言に丸められている" ;;
esac

echo "── 4. ★一覧に出るか測れなかった回を緑にしない ──"
# 「api.key か 8787 に届かない」= unknown。ここを ok に倒すと、電話から見えない window を
# 「用意できました」と報告する事になる(2026-08-02 に実際に起きた形)。
chk "  listed が unknown なら verdict は fail" "$(verdict "$(withval listed_in_api unknown)")" "fail"
chk "  ★鎖の欄は fail ではなく unknown(3値を潰さない)" "$(chain 4_listed "$(withval listed_in_api unknown)")" "unknown"
chk "  listed が false なら鎖は fail" "$(chain 4_listed "$(withval listed_in_api false)")" "fail"

echo "── 5. window の枚数と中身 ──"
chk "  0 枚(鎖③未達)" "$(verdict "$(withval phone_windows 0)")" "fail"
chk "  2 枚(増殖)" "$(verdict "$(withval phone_windows 2)")" "fail"
chk "  1 枚でも中のペインが死んでいる(抜け殻)" "$(verdict "$(withval phone_panes_alive 0)")" "fail"
chk "  ★中身が素の shell なら「話せる相手」ではない" "$(verdict "$(withval phone_pane_cmd zsh)")" "fail"
chk "  node が走っていれば通す(常に赤ではない)" "$(verdict "$(withval phone_pane_cmd node)")" "ok"

echo "── 6. ★負の対照: 欄が無い時の既定値。ここが 0 になると観測ゼロが「新鮮」になる ──"
sed 's/^def i(k, d=-1):$/def i(k, d=0):/' "$SB/judge.py" > "$SB/judge-mut.py"
if cmp -s "$SB/judge.py" "$SB/judge-mut.py"; then
    echo "UNMEASURED  既定値を壊す先が当たらない(負の対照が空撃ち)"
    exit 2
fi
# 心拍の2欄だけを消し、他は健康にしておく。本物は赤、既定値を 0 にした版は緑になる筈。
NOBEAT="$(printf '%s\n' "$HEALTHY" | grep -v '^attempt_age_s=' | grep -v '^success_age_s=')"
chk "  本物: 心拍の欄が無ければ赤" "$(verdict "$NOBEAT")" "fail"
chk "  ★既定値を 0 にすると、観測が1つも無いのに緑になる(= 本物では -1 が効いている)" \
    "$(judge "$NOBEAT" present "$SB/judge-mut.py" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])' 2>/dev/null)" "ok"

echo "── 7. ★負の対照: unknown を緑に倒す改変を捕まえるか ──"
sed 's/^    elif listed == "unknown": fail.append/    elif False: fail.append/' "$SB/judge.py" > "$SB/judge-mut2.py"
if cmp -s "$SB/judge.py" "$SB/judge-mut2.py"; then
    echo "UNMEASURED  unknown の検査を壊す先が当たらない(負の対照が空撃ち)"
    exit 2
fi
chk "  ★unknown の検査を外すと、届かなかった回が緑になる(= 本物では効いている)" \
    "$(judge "$(withval listed_in_api unknown)" present "$SB/judge-mut2.py" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])' 2>/dev/null)" "ok"

echo "── 8. --expect-absent は撤去だけを見る(present の軸を持ち込まない)──"
ABSENT='job_present=false
script_procs=0'
chk "  job も script も居なければ ok" "$(verdict "$ABSENT" absent)" "ok"
chk "  job が残っていれば fail" "$(verdict "$(printf 'job_present=true\nscript_procs=0\n')" absent)" "fail"
chk "  script が残っていれば fail" "$(verdict "$(printf 'job_present=false\nscript_procs=2\n')" absent)" "fail"
# ★撤去の確認に window や心拍の軸を混ぜない。混ぜると「消したのに赤」で永久に閉じない。
chk "  ★撤去の判定は window / 心拍を見ない(観測が空でも ok)" "$(verdict "$(printf 'job_present=false\nscript_procs=0\n')" absent)" "ok"
chk "  撤去の回に鎖の欄を作らない" "$(judge "$ABSENT" absent | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)["chains"]))' 2>/dev/null)" "0"

echo
echo "  == PASS $PASS / FAIL $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
