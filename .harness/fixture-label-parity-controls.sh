#!/bin/bash
# controls-for: rc-backend/test/fixture-labels-producible.test.mjs rc-backend/src/view.mjs rc-backend/src/blocked.mjs ios/Sources/Core/SessionsListingFixture.swift ios/Sources/Core/PollFixture.swift ios/UITests/RemoteMiniUITests.swift
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
# ★同じ形が同日中にもう1件出た(S8-20)。会話画面の選択カードは `PollFixture.swift` に
#   手で書いてあり、その escape ボタンは `中止(Escape)` と名乗っていた —— rc-backend の
#   何処にも無い文字列で、本番は `CHOICE_KEY_LABEL` の生の `Escape` 一語だった。
#   更に悪い事に、Sprint 7 に「画面を見て」直した割り込みの注意文が、その実在しない
#   ボタンを指していた = **偽の画面を根拠に本物の設計判断をしていた**。
#   だから此の対照は一覧(`routeLabel`)と選択カード(`choiceView`)の両方を張る。
#
# ★3件目(S8-22、同日)。一覧の**障害バナー**は3つとも腐っていた —— 本番は `paneFault` の
#   `reason`(内部トークン)と `detail`(生の JS エラー文)をそのまま描き、fixture は
#   `pane-scan-timeout` という `paneFaultReason` が作れない語と綺麗な日本語1文を持ち、
#   **UI 検査はその架空の2文を主張していた**。検査は在り、走り、緑で、測っていた物が
#   実在しなかった。だから此の対照は fixture だけでなく `RemoteMiniUITests.swift` が
#   主張する文言そのものも見張る。
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
POLLF="ios/Sources/Core/PollFixture.swift"
UITESTF="ios/UITests/RemoteMiniUITests.swift"
TESTF="rc-backend/test/fixture-labels-producible.test.mjs"

for f in "$FIXTURE" "$POLLF" "$UITESTF" "$TESTF" \
         rc-backend/test/subtree.mjs rc-backend/src/view.mjs rc-backend/src/blocked.mjs DESIGN.md; do
    if [ ! -f "$ROOT/$f" ]; then
        echo "UNMEASURED  読む file が無い: $f"
        exit 2
    fi
done

/bin/mkdir -p "$WORK/rc-backend/src" "$WORK/rc-backend/test" "$WORK/ios/Sources/Core" "$WORK/ios/UITests"
/bin/cp "$ROOT"/rc-backend/src/*.mjs "$WORK/rc-backend/src/"
/bin/cp "$ROOT/$TESTF" "$ROOT/rc-backend/test/subtree.mjs" "$WORK/rc-backend/test/"
/bin/cp "$ROOT/$FIXTURE" "$ROOT/$POLLF" "$WORK/ios/Sources/Core/"
/bin/cp "$ROOT/$UITESTF" "$WORK/ios/UITests/"
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
echo "== 選択カードの札(S8-20。同じ形が別の fixture で出た) =="

# ⑥ 起票時の実物そのもの。本番に無い「綺麗な」escape の札を植え直す。
probe "escape の札が本番に無い形になる(起票時の実物)" "$POLLF" \
    'ChoiceButton(key: "escape", label: "Escape(中止)")' \
    'ChoiceButton(key: "escape", label: "中止(Escape)")'

# ⑦ 向きが逆のズレ。fixture は触らずサーバ側の語だけ動かす。
probe "サーバ側の escape の語だけが動く(向きが逆)" "rc-backend/src/view.mjs" \
    'const CHOICE_KEY_ACTION = { escape: "中止" };' \
    'const CHOICE_KEY_ACTION = { escape: "取消" };'

# ⑧ 数字の札。escape だけ見て数字を素通しする検査を弾く。
probe "数字の札だけがズレる(escape しか見ない検査を弾く)" "$POLLF" \
    'ChoiceButton(key: "1", label: "1. はい")' \
    'ChoiceButton(key: "1", label: "1. はい(推奨)")'

# ⑨ 断り文の言い換え。`PollFixture.swift` は「逐語で写す」と自分で書いているが、
#    それを機械が見張っていた事は一度も無かった。
probe "断り文を1語だけ言い換える(逐語の約束を機械が見張るか)" "$POLLF" \
    '電話からは操作を出しません' \
    '電話からは操作を出せません'

# ⑩ カードを1枚も拾えなくする。⑤ と同じ穴が選択カード側にも在る ——
#    拾えなければ「比べる物ゼロ = 全部一致」。錨(`blocks.length >= 2`)が止めるか。
probe "選択カードを1枚も拾えなくする(錨が働くか)" "$TESTF" \
    'const parts = src.split("ChoiceView(");' \
    'const parts = src.split("ChoiceView@@@never@@@(");'

echo
echo "== 一覧の障害バナー(S8-22。fixture と UI 検査が揃って架空だった) =="

# ⑪ 起票時の実物。`paneFaultReason` が**作れない語**を fixture に戻す。
probe "帯の reason を本番が作れない語に戻す(起票時の実物)" "$FIXTURE" \
    'reason: "panes-unreadable",' \
    'reason: "pane-scan-timeout",'

# ⑫ 見出しだけを1語ズラす。reason は正しいままなので、reason しか見ない検査を弾く。
probe "帯の見出しだけがズレる(reason しか見ない検査を弾く)" "$FIXTURE" \
    'headline: "tmux の画面一覧を読めていません"' \
    'headline: "tmux の画面一覧が読めていません"'

# ⑬ 本文だけを1語ズラす。見出しだけ見る検査を弾く。
probe "帯の本文だけがズレる(見出ししか見ない検査を弾く)" "$FIXTURE" \
    '中身が壊れていて読めません' \
    '中身が壊れていて読み取れません'

# ⑭ ★向きが逆。fixture は触らず**サーバ側の帯の文言**を動かす。
#    此処が赤にならないと、検査は「fixture を直し忘れた日」しか守らない。
probe "サーバ側の帯の見出しだけが動く(向きが逆のズレ)" "rc-backend/src/blocked.mjs" \
    'headline: "tmux の画面一覧を読めていません",' \
    'headline: "tmux の一覧を読めていません",'

# ⑮ UI 検査の主張を**起票時の実物**(本番が作れない文)に戻す。
#    これが此の節を書いた直接の理由 —— 検査は在り、走り、緑で、測っていた物が架空だった。
probe "UI 検査が本番に無い文を主張する(起票時の実物)" "$UITESTF" \
    'tmux からの返事は来ていますが、中身が壊れていて読めません。復旧するまで、どの会話にも送れません。この故障は電話からは直せないので、机で確認してください。' \
    'tmux ペインの走査がタイムアウトしました。'

# ⑯ ★ producible **だが別の面**の文言に替える。`list-panefault` は panes-unreadable の面
#    なので、tmux-unavailable の見出しを主張する検査は実機で必ず落ちる —— しかも落ちる
#    理由が「本番の文言が悪い」ではなく「検査が別の面を見ている」。所属だけ見る検査は
#    此処を通してしまう(だから一致の主張を足した)。
probe "UI 検査が producible だが別の面の文言を主張する" "$UITESTF" \
    'app.staticTexts["tmux の画面一覧を読めていません"]' \
    'app.staticTexts["サーバが tmux に届いていません"]'

# ⑰ 主張を1本だけ黙って落とす。本数の錨が無いと、残った1本が producible なので緑になる。
probe "UI 検査の主張を1本だけ落とす(本数の錨が働くか)" "$UITESTF" \
    '        XCTAssertTrue(app.staticTexts["tmux の画面一覧を読めていません"].exists)
' \
    ''

# ⑱ 帯を1枚も拾えなくする。⑤⑩ と同じ穴 —— 拾えなければ「比べる物ゼロ = 全部一致」。
probe "帯を1枚も拾えなくする(錨が働くか)" "$TESTF" \
    '"paneFault: .init("' \
    '"paneFault: .init@@@never@@@("'

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

# 選択カード側の陰性対照。escape の**行ごと**落とすのは正しい fixture である ——
# 鍵の許しはカード毎に違い、数字しか許されない画面は本番に実在する。此処が赤くなる
# 検査は「常に escape が在る」を要求している事になり、正しい形を落とす側へ倒れている。
if mutate "$POLLF" \
    '                    ChoiceButton(key: "escape", label: "Escape(中止)"),
' \
    ''; then
    if run_suite; then
        echo "  PASS  escape を持たないカードは緑のまま"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  escape の無いカードを赤にした = 常に escape が在ると決めつけている"
        FAIL=$((FAIL + 1))
    fi
    restore "$POLLF"
else
    echo "  UNMEASURED  選択カード側の陰性対照の錨が1箇所に定まらない"
    UNMEASURED=$((UNMEASURED + 1))
    [ -f "$WORK/$POLLF.orig" ] && restore "$POLLF"
fi

# ★注釈は主張ではない。此処が要る理由も、私が今日実際に踏んだから —— 上の UI 検査に
#   「此処は staticTexts を突き合わせている」と**説明を書いた瞬間**に本数が3本になって
#   赤が出た。注釈は画面に何も出さないのに、素朴な正規表現からは主張と見分けが付かない。
#   直し方を「注釈の書き方を変える」にすると次に書く人が同じ罠を踏むので、検査の側で
#   注釈を落とす様にした(`stripSwiftComments`)。それが効いている事を機械で見張る。
if mutate "$UITESTF" \
    '(本数もちょうど2本と主張する ので、黙って1本にして緑にする事も出来ない)。' \
    '(本数もちょうど2本と主張する ので、黙って1本にして緑にする事も出来ない)。
        //   陰性対照: 注釈の中の app.staticTexts["架空の文字列"] は主張ではない。'; then
    if run_suite; then
        echo "  PASS  注釈の中の staticTexts は数に入らない"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  注釈を主張と数えた = 説明を書くと赤くなる検査(今日の実物)"
        FAIL=$((FAIL + 1))
    fi
    restore "$UITESTF"
else
    echo "  UNMEASURED  注釈側の陰性対照の錨が1箇所に定まらない"
    UNMEASURED=$((UNMEASURED + 1))
    [ -f "$WORK/$UITESTF.orig" ] && restore "$UITESTF"
fi

# ★`detail` を縛っていない事の陰性対照。本番の `detail` は `e.message` = 自由記述で、
#   閉じた語彙が無い = 「作れる集合」が存在しない。だから何に替えても緑でなければならない。
#   此処が赤くなる検査は、作れる集合の無い鍵に正解を1つ発明している事になる。
if mutate "$FIXTURE" \
    'detail: "fixture-detail: production puts a raw JS error message here; the banner never draws it",' \
    'detail: "TypeError: Cannot read properties of undefined",'; then
    if run_suite; then
        echo "  PASS  detail は何に替えても緑のまま(縛っていない)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  detail を赤にした = 閉じた語彙の無い鍵に正解を発明している"
        FAIL=$((FAIL + 1))
    fi
    restore "$FIXTURE"
else
    echo "  UNMEASURED  detail 側の陰性対照の錨が1箇所に定まらない"
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
for gone in "$FIXTURE" "$POLLF" "$UITESTF"; do
    /bin/mv "$WORK/$gone" "$WORK/gone.off"
    if run_suite; then
        echo "  FAIL  $(basename "$gone") が消えたのに緑 = 欠けを『問題なし』に丸めている"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS  $(basename "$gone") が消えたら赤"
        PASS=$((PASS + 1))
    fi
    /bin/mv "$WORK/gone.off" "$WORK/$gone"
done

echo
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
if [ "$UNMEASURED" -gt 0 ]; then exit 2; fi
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
