#!/bin/bash
# controls-for: src/worker.mjs src/view.mjs test/worker.test.mjs test/view.test.mjs
#
# 何を守る対照か —— **割り込みが「撃った事」を「止まった事」として名乗らない事**(DESIGN §2.64)。
#
# 2026-08-08 の監査 R2-3。ワーカー経路の `interrupt` は SIGTERM を撃った直後に `true` を
# 返し、電話には「止めました(Escape)。」と出ていた。二重に偽だった —— ①止まった事は
# 誰も観測していない ②この経路は Escape を押していない。tmux 経路は 2026-08-03 に同じ
# 誤りを直しており、**片方の経路にだけ古い形が残っていた**。
#
# 直した後、検査は緑になる。だが緑は「検査が在る」しか言わない。この対照は
# **嘘を1つずつ植え直して、そのたびに赤が出る事**を実演する。赤が出ない植え方が
# 1つでも在れば、その嘘は今日から誰にも止められない。
#
# ★働き場所は**木の外の写し**。本体のバイトは1つも動かさない(復旧区画を持たないのは
#   その為)。写しは毎回作り直すので「写しだけが古くなる」も起きない。
#
# 終了コード: 0 = 守られている / 1 = 破れている / 2 = 測れていない
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend
WORK="$(mktemp -d -t rc-interrupt-honesty)"
trap 'find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; /bin/rm -rf "$WORK" 2>/dev/null' EXIT

for f in src/worker.mjs src/view.mjs src/blocked.mjs test/worker.test.mjs test/view.test.mjs; do
    if [ ! -f "$HERE/$f" ]; then
        echo "UNMEASURED  読む file が無い: rc-backend/$f"
        exit 2
    fi
done

/bin/mkdir -p "$WORK/src" "$WORK/test"
/bin/cp "$HERE"/src/*.mjs "$WORK/src/"
/bin/cp "$HERE/test/worker.test.mjs" "$HERE/test/view.test.mjs" "$WORK/test/"

PASS=0
FAIL=0
UNMEASURED=0

# 写しの2本を回す。緑なら0、赤なら非0。
run_suite() {
    ( cd "$WORK" && node --test test/worker.test.mjs test/view.test.mjs >"$WORK/out.txt" 2>&1 )
}

# 錨を1つ差し替える。当たらなければ 2(測れていない)—— 空撃ちを緑に見せない。
#
# ★macOS の bash は 3.2。`local a="$1" b="${ARR[$a]}"` の様に**同じ行で**受けると
#   `$a` は呼び側の物が見えるので、代入は1行ずつ書く事。
mutate() {
    local file="$1"
    local from="$2"
    local to="$3"
    /bin/cp "$WORK/$file" "$WORK/$file.orig"
    /usr/bin/python3 - "$WORK/$file" "$from" "$to" <<'PYEOF'
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8").read()
if s.count(frm) != 1:
    sys.exit(3)
open(path, "w", encoding="utf-8").write(s.replace(frm, to))
PYEOF
    return $?
}

restore() {
    /bin/mv "$WORK/$1.orig" "$WORK/$1"
}

# 嘘を1つ植えて、赤が出る事を見る。
probe() {
    local name="$1"
    local file="$2"
    local from="$3"
    local to="$4"
    if ! mutate "$file" "$from" "$to"; then
        echo "  UNMEASURED  $name  —— 植える先が1箇所に定まらない(錨: ${from:0:40})"
        UNMEASURED=$((UNMEASURED + 1))
        [ -f "$WORK/$file.orig" ] && restore "$file"
        return
    fi
    if run_suite; then
        echo "  FAIL  $name  —— 嘘を植えても緑のまま = この検査群は飾りである"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS  $name  —— 植えたら赤が出た"
        PASS=$((PASS + 1))
    fi
    restore "$file"
}

echo "== 素の写しが緑か(ここが赤なら以下は全部読めない) =="
if ! run_suite; then
    echo "UNMEASURED  写しが最初から赤い。対照ではなく本体を先に見る事。"
    /usr/bin/tail -20 "$WORK/out.txt"
    exit 2
fi
echo "  OK  写しは緑"
echo

echo "== 嘘を1つずつ植え直す(全部で赤が出なければならない) =="

# ① 死の観測点でしか解決しない、という一番の要。撃った所で解決させると
#    「撃った = 死んだ」に戻る —— これが 2026-08-08 に見つかった形そのもの。
probe "撃った時点で死んだ事にする(旧 R2-3 の形)" "src/worker.mjs" \
    'this._retire(sessionId, e, "worker_interrupted");' \
    'this._retire(sessionId, e, "worker_interrupted"); e._markExited?.();'

# ② 待つ手段が無い時の逃げ場。ここを verified に倒すと、嘘は
#    「待つ物が無い時だけ復活する」= 一番見つけにくい形で戻る。
probe "待てない時に verified へ倒す" "src/worker.mjs" \
    'return { stopped: "unverified", reason: "no-exit-signal", waited: 0 };' \
    'return { stopped: "verified", reason: null, waited: 0 };'

# ③ 期限切れ = 死を観測できなかった。ここも verified に倒せてはいけない。
probe "期限切れを verified と読む" "src/worker.mjs" \
    'return { stopped: "unverified", reason: "still-alive", waited };' \
    'return { stopped: "verified", reason: null, waited };'

# ④ 押していない操作を報告する。ワーカー経路に Escape は無い。
probe "ワーカー経路で Escape を名乗る" "src/view.mjs" \
    'b.route === "worker" ? "停止の信号は送りました"' \
    'b.route === "worker" ? "Escape は押しました"'

# ⑤ 経路が読めない時に動作を創作する。両方を Escape と書くのが元の嘘なら、
#    片方に寄せるのも同じ誤り。
probe "経路不明でも Escape と書く" "src/view.mjs" \
    ': "止める操作は届きました";' \
    ': "Escape は押しました";'

# ⑥ 古いサーバへの道を、元の嘘に戻す。ここが緑で通ると、嘘は
#    「古い版が繋がった時だけ」復活する。
probe "古いサーバの応答を『止めました』に戻す" "src/view.mjs" \
    '{ kind: "warn", text: "止める操作は届きましたが、止まったかどうかは分かりません。画面を見て確かめてください。" }' \
    '{ kind: "ok", text: "止めました(Escape)。" }'

echo
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
if [ "$UNMEASURED" -gt 0 ]; then exit 2; fi
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
