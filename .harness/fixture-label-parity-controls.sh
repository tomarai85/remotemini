#!/bin/bash
# controls-for: rc-backend/test/fixture-labels-producible.test.mjs rc-backend/src/view.mjs ios/Sources/Core/SessionsListingFixture.swift
#
# 何を守る対照か —— **電話の見た目を確かめる時に使う fixture が、本番より綺麗な文字列を
# 出していない事**。
#
# 2026-08-08 の実測。一覧の札は `SessionsListingFixture.swift` に手で書いた5行で確かめて
# いたが、その5行のうち2行(tmux / worker)が `rc-backend/src/view.mjs` の `routeLabel` が
# 出しえない文字列だった。worker 行は `ワーカー・実行中` と綺麗な日本語で、**本番は
# `ワーカー・busy` と内部トークンを生で出していた**。撮影は成功し、見直しは通り、直すべき
# 物だけが画面に出て来ない —— 偽の値で緑になるのではなく、偽の値で**綺麗に見える**形。
#
# ★「2行」は数え直した後の値である。最初は3行と数えて blocked 行まで書き換えかけた ——
#   `送れない` は `BLOCKED_TAG` に個別の札を持たない reason の**既定形**で、本番が実際に
#   出す。数え違いの原因は検査の側(種類ごとに代表を1つ決めてバイト一致を要求した)で、
#   その形は下の「検査自身の陰性対照」が今は常に見張っている。
#
# 検査(`fixture-labels-producible.test.mjs`)は書いた。だが検査が在る事は、その検査が
# ズレを止める事を意味しない。この対照はズレを1つずつ植え直して、そのたびに赤が出る事を
# 実演する。
#
# ★此処が `.harness` に居る理由: 見張る対象が `rc-backend/` と `ios/` に跨がる。
#   `rc-backend/test/` の対照は宣言が rc-backend からの相対に解決されるので `ios/…` を
#   名指せない(`staged-controls-gate.sh` の SCAN_SPECS)。木を跨ぐ対照は `.harness` に
#   置くのが此の repo の先例(`live-interrupt-wording-controls.sh` と同じ)。
#
# ★働き場所は**木の外の写し**。本体のバイトは1つも動かさない(復旧区画を持たないのは
#   その為 —— `.harness` の対照でも `INFLIGHT=` を宣言しない物は復旧の輪に入らない)。
#
# ★写しは**根の形を保つ**。`fixture-labels-producible.test.mjs` は木の外(`ios/**`)を
#   読むので、`rc-backend/` だけを写すと `subtree.mjs` の契約に従って**飛ばされる**。
#   飛ばしは緑ではない —— 下の `run_suite` はそれを赤として扱う。
#
# 終了コード: 0 = 守られている / 1 = 破れている / 2 = 測れていない
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d -t rc-fixture-label-parity)"
trap 'find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; /bin/rm -rf "$WORK" 2>/dev/null' EXIT

FIXTURE="ios/Sources/Core/SessionsListingFixture.swift"
TESTF="rc-backend/test/fixture-labels-producible.test.mjs"

for f in "$FIXTURE" "$TESTF" rc-backend/test/subtree.mjs rc-backend/src/view.mjs DESIGN.md; do
    if [ ! -f "$ROOT/$f" ]; then
        echo "UNMEASURED  読む file が無い: $f"
        exit 2
    fi
done

/bin/mkdir -p "$WORK/rc-backend/src" "$WORK/rc-backend/test" "$WORK/ios/Sources/Core"
/bin/cp "$ROOT"/rc-backend/src/*.mjs "$WORK/rc-backend/src/"
/bin/cp "$ROOT/$TESTF" "$ROOT/rc-backend/test/subtree.mjs" "$WORK/rc-backend/test/"
/bin/cp "$ROOT/$FIXTURE" "$WORK/ios/Sources/Core/"
# 根の目印。`subtree.mjs` は此の1本の実在だけで「親が本物か」を決める。
/bin/cp "$ROOT/DESIGN.md" "$WORK/DESIGN.md"

PASS=0
FAIL=0
UNMEASURED=0

# 写しの検査を回す。緑なら0、赤なら非0。
#
# ★**飛ばしを緑と読まない**。`requireOutside` は木の外が見えない時に node:test の
#   `{ skip: 理由 }` を返し、node は skip を成功として数える。つまり「木の形を壊す」変異は
#   検査を無音にするだけで exit 0 のまま通る —— 対照が一番見落としやすい抜け道なので、
#   TAP の飛ばし数を此処で赤にする。
run_suite() {
    local rc
    ( cd "$WORK/rc-backend" && node --test test/fixture-labels-producible.test.mjs >"$WORK/out.txt" 2>&1 )
    rc=$?
    if /usr/bin/grep -qE '^# skipped [1-9]' "$WORK/out.txt"; then
        return 1
    fi
    return $rc
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
        echo "  FAIL  $name  —— 植えても緑のまま = この検査は飾りである"
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
    /usr/bin/tail -25 "$WORK/out.txt"
    exit 2
fi
echo "  OK  写しは緑"
echo

echo "== ズレを1つずつ植え直す(全部で赤が出なければならない) =="

# ① 起票時の実物そのもの。fixture 側だけを綺麗な日本語に戻す。
probe "fixture が本番より綺麗な札を出す(起票時の実物)" "$FIXTURE" \
    'short: "ワーカー・答え待ち",' \
    'short: "ワーカー・実行中",'

# ② `short` は合っているが `text` がズレている。片方しか見ない検査を通さない。
#    起票時の実物も `text` は `ワーカーが実行中` と、本番に無い語形だった。
probe "説明文だけがズレる(short しか見ない検査を弾く)" "$FIXTURE" \
    'text: "ワーカー・答え待ち", screen: ""' \
    'text: "ワーカーが実行中", screen: ""'

# ③ ★向きが逆のズレ。fixture は触らず**サーバ側の文言を変える**。
#    此処が赤にならないと、検査は「fixture を直し忘れた日」しか守らない。
probe "サーバ側の文言だけが動く(向きが逆のズレ)" "rc-backend/src/view.mjs" \
    'if (state === "busy") return "答え待ち";' \
    'if (state === "busy") return "実行中";'

# ④ 種類を1つ取り違える。`.tmux` の行に `.worker` の札を入れても、
#    種類ごとに引き当てているなら赤になる(全行を1つの正解と比べる実装を弾く)。
probe "種類の取り違え(tmux の行に worker の札)" "$FIXTURE" \
    'kind: .tmux, short: "机・動いている",' \
    'kind: .tmux, short: "ワーカー・答え待ち",'

# ⑤ 行を1つも拾えなくする。表の照合は「拾った行」しか見ないので、拾い方が壊れた日は
#    **比べる物がゼロ = 全部一致**に化ける。錨(`rows.length >= 5`)がそれを止めるか。
probe "行を1つも拾えなくする(錨が働くか)" "$TESTF" \
    'const re = /kind:\s*\.(\w+)\s*,\s*short:\s*"([^"]*)"\s*,\s*\n?\s*text:\s*"([^"]*)"/g;' \
    'const re = /kind:\s*\.(\w+)@@@never@@@/g;'

echo
echo "== 正しい別の札は赤にしない(検査自身の陰性対照) =="
# ★此処が要る理由は、私が実際に踏んだから(2026-08-08)。初版は種類ごとに代表を1つ決めて
#   バイト一致を要求し、blocked 行の `送れない` を「本番に無い」と赤にした —— 実際には
#   `routeLabel` が既定形として出す、完全に正しい札だった。fixture を直しかけて止まった。
#   正しい形を落とす検査は、それ自体が次の事故になる。だから「別の producible な札に
#   替えても緑のまま」を機械に見張らせる。
if mutate "$FIXTURE" \
    'short: "送れない",
            text: "宛先を確定できません。", screen: ""' \
    'short: "送れない(未登録)",
            text: "ペイン登録が無いため、宛先を確定できません。", screen: ""'; then
    if run_suite; then
        echo "  PASS  producible な別の札は緑のまま"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  正しい札を赤にした = 検査が代表1つに固定されている(初版の欠陥)"
        FAIL=$((FAIL + 1))
    fi
    restore "$FIXTURE"
else
    echo "  UNMEASURED  陰性対照の錨が1箇所に定まらない"
    UNMEASURED=$((UNMEASURED + 1))
    [ -f "$WORK/$FIXTURE.orig" ] && restore "$FIXTURE"
fi

echo
echo "== 飛ばしは緑ではない(部分木の写しを模す) =="
# `test/mutation-controls.py` は rc-backend だけを写す。その世界では此の検査は
# 「測っていない」と名乗って飛ぶ —— 正しい振る舞いだが、**対照がそれを緑と読んだら**
# 木の形を壊す変異が全部素通りする。此処だけは file を消して測る(文字の差し替えでは
# 作れない状況なので probe に載せない)。
/bin/mv "$WORK/DESIGN.md" "$WORK/DESIGN.md.off"
/bin/mv "$WORK/$FIXTURE" "$WORK/fixture.off"
if run_suite; then
    echo "  FAIL  部分木の写しで緑になった = 飛ばしを『一致』と読んでいる"
    FAIL=$((FAIL + 1))
else
    echo "  PASS  部分木の写しは緑にならない"
    PASS=$((PASS + 1))
fi
/bin/mv "$WORK/DESIGN.md.off" "$WORK/DESIGN.md"
/bin/mv "$WORK/fixture.off" "$WORK/$FIXTURE"

# ★逆側も見る。親が健在なのに fixture だけが消えた時は、飛ばさずに**赤**が正しい
#   (`subtree.mjs` の3値の契約 —— 「無い」を「測らなくてよい」に丸めない)。
echo
echo "== 親が健在なのに対象が消えたら赤(飛ばしに逃げない) =="
/bin/mv "$WORK/$FIXTURE" "$WORK/fixture.off"
if run_suite; then
    echo "  FAIL  対象が消えたのに緑 = 欠けを『問題なし』に丸めている"
    FAIL=$((FAIL + 1))
else
    echo "  PASS  対象が消えたら赤"
    PASS=$((PASS + 1))
fi
/bin/mv "$WORK/fixture.off" "$WORK/$FIXTURE"

echo
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
if [ "$UNMEASURED" -gt 0 ]; then exit 2; fi
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
