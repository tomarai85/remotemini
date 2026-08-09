#!/bin/bash
# controls-for: rc-backend/test/wire-vocabulary-agreement.test.mjs rc-backend/src/server.mjs rc-backend/src/wire.mjs rc-backend/src/blocked.mjs ios/Sources/Core/ResultDisplay.swift ios/Sources/Core/SessionsListingFixture.swift ios/Tests/Core/PollModelsTests.swift
#
# 何を守る対照か —— **線に出る語彙の「値」が両側で一致する事**。
# 姉家族の `wire-key-agreement-controls.sh` が守るのは**鍵名**で、此処は其の値の側。
#
# 2026-08-09(S8-26 phase 3)。誤り応答4本も「封筒を builder へ切り出せば同じ手が効く」
# と思って測ったら**効かなかった**(理由は検査 file の冒頭)。誤り応答で本当に測れて
# いなかったのは鍵名ではなく、**電話が焼き込んでいる文字列の値**だった。
#
# ★此の対照の背骨は陰性対照Ⓐ/Ⓑ。両側を**揃えて**改名した木は緑でなければならない。
#   此処が赤い検査は語彙を今日の綴りに固定する = `recovery-codes.test.mjs` が
#   冒頭 20-22 行で意図的に避けた「検査が変更の追認機になる」形そのもの。
#   値を縛るのに追認機にならない事は、Ⓐ/Ⓑ が緑である事でしか主張できない。
#
# ★赤が出た事だけでは足りない。此の検査は6本在り、1つの変異が複数を倒しうる ——
#   例えば「サーバの `code` の値だけ変える」は**値の組**と**サーバにしか無い語**の
#   両方を倒す。狙った項が倒れたかを言えない対照は「何かが赤くなった」しか測っていない
#   ので、`probe` は倒れた項の名前まで見る(第5引数)。
#
# ★木の外(`ios/Sources/**`)を走査するので、`rc-backend/` だけを写すと `subtree.mjs` の
#   契約で**飛ばされる**。飛ばしは緑ではない —— `run_suite` が TAP の skip を赤で扱う。
#
# 終了コード: 0 = 守られている / 1 = 破れている / 2 = 測れていない
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d -t rc-wire-vocab)"
trap 'find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; /bin/rm -rf "$WORK" 2>/dev/null' EXIT

TESTF="rc-backend/test/wire-vocabulary-agreement.test.mjs"
SERVER="rc-backend/src/server.mjs"
WIRE="rc-backend/src/wire.mjs"
RESULTD="ios/Sources/Core/ResultDisplay.swift"
LISTFIX="ios/Sources/Core/SessionsListingFixture.swift"
# S8-28。此処だけ `ios/Tests/**` を読む —— 検査の中に在る「サーバが送りうる理由の全部」
# という主張を、サーバの正本(`src/blocked.mjs` の `WIRE_REASONS`)と突き合わせる為。
BLOCKED="rc-backend/src/blocked.mjs"
POLLTESTS="ios/Tests/Core/PollModelsTests.swift"

for f in "$TESTF" "$SERVER" "$WIRE" "$RESULTD" "$LISTFIX" "$BLOCKED" "$POLLTESTS" \
         rc-backend/test/subtree.mjs rc-backend/test/swiftsrc.mjs rc-backend/test/jssrc.mjs \
         DESIGN.md; do
    if [ ! -f "$ROOT/$f" ]; then
        echo "UNMEASURED  読む file が無い: $f"
        exit 2
    fi
done

/bin/mkdir -p "$WORK/rc-backend/src" "$WORK/rc-backend/test" "$WORK/ios"
/bin/cp "$ROOT"/rc-backend/src/*.mjs "$WORK/rc-backend/src/"
/bin/cp "$ROOT/$TESTF" "$WORK/rc-backend/test/"
/bin/cp "$ROOT"/rc-backend/test/subtree.mjs "$ROOT"/rc-backend/test/swiftsrc.mjs \
        "$ROOT"/rc-backend/test/jssrc.mjs "$WORK/rc-backend/test/"
# Sources は**丸ごと**。検査は木を歩いて語彙を数え上げるので、選んで写すと
# 「写した物にしか語が無い木」になり、走査の穴が見えなくなる。
/bin/cp -R "$ROOT/ios/Sources" "$WORK/ios/Sources"
# Tests 側は**名指しの1本だけ**(S8-28)。此の検査が読むのが其の1本だけで、丸ごと写すと
# 「検査の木が在る」事を測っているのか「あの主張が在る」事を測っているのか読めなくなる。
/bin/mkdir -p "$WORK/ios/Tests/Core"
/bin/cp "$ROOT/$POLLTESTS" "$WORK/$POLLTESTS"
# 根の目印。`subtree.mjs` は此の1本の実在だけで「親が本物か」を決める。
/bin/cp "$ROOT/DESIGN.md" "$WORK/DESIGN.md"

PASS=0
FAIL=0
UNMEASURED=0

# 写しの検査を回す。緑なら0、赤なら非0。飛ばしは緑と読まない(姉家族 file と同じ理由)。
run_suite() {
    local rc
    ( cd "$WORK/rc-backend" && node --test test/wire-vocabulary-agreement.test.mjs >"$WORK/out.txt" 2>&1 )
    rc=$?
    if /usr/bin/grep -qE '^# skipped [1-9]' "$WORK/out.txt"; then
        return 1
    fi
    return $rc
}

# 倒れた項の名前を1行に並べる(`probe` の第5引数の照合用)。
red_names() {
    /usr/bin/grep -E '^not ok [0-9]+ - ' "$WORK/out.txt" | /usr/bin/sed 's/^not ok [0-9]* - //' | /usr/bin/tr '\n' '|'
}

# 錨を1つ差し替える。当たらなければ 2(測れていない)—— 空撃ちを緑に見せない。
#
# ★macOS の bash は 3.2。同じ行で複数を `local` 宣言すると先に宣言した物が見えないので、
#   代入は1行ずつ書く事(姉家族 file で一度踏んでいる)。
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

restore_from_root() {
    /bin/cp "$ROOT/$1" "$WORK/$1"
}

# probe <名> <file> <from> <to> <倒れるべき項の一部>
#
# 第5引数を必須にしてあるのが姉家族 file との違い。「何かが赤くなった」で満足すると、
# 例えば走査を丸ごと殺す変異が「値の組を測れている証拠」として数えられる。
probe() {
    local name="$1"
    local file="$2"
    local from="$3"
    local to="$4"
    local want="$5"
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
        local names
        names="$(red_names)"
        case "$names" in
            *"$want"*)
                echo "  PASS  $name  —— 狙った項が赤になった"
                PASS=$((PASS + 1))
                ;;
            *)
                echo "  FAIL  $name  —— 赤は出たが**別の項**が倒れた"
                echo "        欲しかった: $want"
                echo "        倒れた項  : ${names%|}"
                FAIL=$((FAIL + 1))
                ;;
        esac
    fi
    restore "$file"
}

# plant <名> <相対path> <中身> <倒れるべき項の一部>  —— file を1本足す形の変異。
plant() {
    local name="$1"
    local rel="$2"
    local body="$3"
    local want="$4"
    printf '%s\n' "$body" >"$WORK/$rel"
    if run_suite; then
        echo "  FAIL  $name  —— 緑のまま = この検査は飾りである"
        FAIL=$((FAIL + 1))
    else
        local names
        names="$(red_names)"
        case "$names" in
            *"$want"*)
                echo "  PASS  $name  —— 狙った項が赤になった"
                PASS=$((PASS + 1))
                ;;
            *)
                echo "  FAIL  $name  —— 赤は出たが**別の項**が倒れた"
                echo "        欲しかった: $want"
                echo "        倒れた項  : ${names%|}"
                FAIL=$((FAIL + 1))
                ;;
        esac
    fi
    /bin/rm -f "$WORK/$rel"
}

echo "== 素の写しが緑か(ここが赤なら以下は全部読めない) =="
if ! run_suite; then
    echo "UNMEASURED  写しが最初から赤い。対照ではなく本体を先に見る事。"
    /usr/bin/tail -25 "$WORK/out.txt"
    exit 2
fi
echo "  OK  写しは緑"
echo

echo "== 片側だけが語彙を持つ(復号は通り、例外は出ない) =="

# ① ★**此の検査が実際に釣った1件を、そのまま対照にした物**(2026-08-09)。
#    fixture の tmux 行が `screen: "MAIN"` を持っていた —— `routeLabel` の tmux 枝が
#    `screen` に入れるのは `classifyScreen` の `SENDABLE`/`CHOICE`/`UNKNOWN` だけなので、
#    `MAIN` は**どの枝からも出ない**。今日の実害は無い(此の欄を読む UI が1つも無い)が、
#    fixture は「人が目で全状態を確かめる為の物」で、其処だけがサーバの語彙の外に居た形。
#    直した後も、同じ手が再び効かない事は此処でしか言えない。
probe "電話の fixture がサーバの出せない画面名へ戻る(実際に釣れた1件)" "$LISTFIX" \
    'text: "机で開いている・動いている", screen: "SENDABLE"),' \
    'text: "机で開いている・動いている", screen: "MAIN"),' \
    "電話にしか無い語"

# ② fixture ではなく**実コード**が語を発明する形。①と分けるのは、走査が
#    `ios/Sources/**` を丸ごと歩いている事(fixture だけを見ているのではない)の確認。
plant "電話の実コードが新しい語を発明する" "ios/Sources/Screens/InventedForControl.swift" \
'// 対照が植えた作り物。サーバが一度も吐かない語で電話が分岐する形。
enum InventedForControlState {
    static let token = "PANE_LOST"
}' \
    "電話にしか無い語"

# ③ サーバ側が宣言していない語を吐く。電話は知らない語を黙って捨てるので、
#    増えた語は**永久に画面へ出ない** —— 例外も出ず、単体検査も両方緑のまま。
plant "サーバが許可表に無い語を吐く" "rc-backend/src/control-invented.mjs" \
'// 対照が植えた作り物。宣言していない語彙が線へ出る形。
export const CONTROL_REASON = "QUEUE_FULL";' \
    "サーバにしか無い語"

echo
echo "== 名前は据え置き、値だけが動く(此の検査の眼目) =="

# ④ ★★背骨。`server.mjs` では定数名と `code` の値が**偶々同じ綴り**なので
#    (`SESSION_NOT_FOUND` = `code: "SESSION_NOT_FOUND"`)、電話のリテラルを
#    原文へ grep するだけの検査は此の変異を**緑で通す**。値を読んでいる事の証明。
probe "サーバの code の値だけ変わる(定数名は据え置き)" "$SERVER" \
    'const SESSION_NOT_FOUND = Object.freeze({ error: "unknown session", code: "SESSION_NOT_FOUND" });' \
    'const SESSION_NOT_FOUND = Object.freeze({ error: "unknown session", code: "SESSION_MISSING" });' \
    "復旧語彙の**値**"

# ⑤ 逆向き。電話が焼いている値だけが動く形 —— 応答は 404 のまま届き、
#    電話は「一覧へ戻る」を**選ばなくなる**(遷移が黙って死ぬ)。
probe "電話が焼いている値だけ変わる" "$RESULTD" \
    'static let sessionNotFound = "SESSION_NOT_FOUND"' \
    'static let sessionNotFound = "SESSION_GONE"' \
    "復旧語彙の**値**"

echo
echo "== 許可表が名簿でなく作文になる道 =="

# ⑥ 「サーバにしか無い」と書いた語が電話にも生える。理由を書いた日から誰も見ていない
#    作文なら、此処は緑のまま通る。
plant "許可表の server-only 語が電話にも生える" "ios/Sources/Core/InventedForControlDead.swift" \
'// 対照が植えた作り物。SERVER_ONLY に理由付きで載っている語が電話側にも生えた形。
enum InventedForControlSignal {
    static let kill = "SIGKILL"
}' \
    "許可表に死んだ項目が無い"

# ⑦ 逆向き。「電話にしか無い」と書いた語がサーバにも生える形。
plant "許可表の phone-only 語がサーバにも生える" "rc-backend/src/control-fixture-flag.mjs" \
'// 対照が植えた作り物。PHONE_ONLY に載っている語がサーバ側にも生えた形。
export const CONTROL_FLAG = "RC_UI_FIXTURE";' \
    "許可表に死んだ項目が無い"

# ⑧ 許可表に**実在しない語**を足す。名前だけ増やして通す道が開いていないか。
probe "許可表にどちらの木にも無い語を足す" "$TESTF" \
    'const PHONE_ONLY = {' \
    'const PHONE_ONLY = {
  INVENTED_FOR_CONTROL: "対照が植えた作り物。どちらの木にも居ない語",' \
    "許可表に死んだ項目が無い"

# ⑨ 理由を空にする。語を1つ許すのに1文を要求している事の確認 ——
#    此処が緑になる検査は、名前を並べるだけで何でも通せる。
probe "許可表の理由が空になる" "$TESTF" \
    'RC_UI_FIXTURE: "電話の環境変数名(UI 検査が fixture 画面を出す為の合図)。線には出ない",' \
    'RC_UI_FIXTURE: "",' \
    "許可表の理由が空でない"

echo
echo "== 走査と錨が死ぬ(拾えない物を0件にしない) =="

# ⑩ 語を採る網の目を潰す。両側が0語になる = **一致**と読めてしまう形で、
#    「0件 = 全部一致」の穴を床が塞いでいるかを見る。
probe "語を採る網が何も拾わなくなる" "$TESTF" \
    '/"([A-Z][A-Z0-9_]{2,})"/g' \
    '/"([A-Z][A-Z0-9_]{40,})"/g' \
    "走査が空振りしていない"

# ⑪ サーバ側の `code` を切り出す錨が外れる。値の組が比べる物ゼロになる形。
probe "サーバの凍らせた語彙を切り出す錨が外れる" "$TESTF" \
    'const re = /const\s+([A-Z][A-Z0-9_]*)\s*=\s*Object\.freeze\(\{([^}]*)\}\)/g;' \
    'const re = /const\s+([A-Z][A-Z0-9_]*)\s*=\s*Object\.frozen\(\{([^}]*)\}\)/g;' \
    "復旧語彙の**値**"

# ⑫ 電話側の `RecoveryCode` を切り出す錨が外れる。同じく比べる物ゼロ。
probe "電話の RecoveryCode を切り出す錨が外れる" "$TESTF" \
    'const at = src.indexOf("struct RecoveryCode");' \
    'const at = src.indexOf("struct RecoveryCodes");' \
    "復旧語彙の**値**"

echo
echo "== 送れない理由の8語が、片側でだけ動く(S8-28) =="
# 此の4本が守るのは**電話の検査が名乗っている主張**の側。
# `testEveryBlockedReasonTheServerCanSendDecodes` は名前で「サーバが送りうる理由の
# 全部が復号できる」と言っているが、其の「全部」は手で並べた8語の写しでしかない。
# 写しが痩せても太っても Swift 側は緑のまま —— 名前だけが嘘になる。

# ⑬ 写しが痩せる。サーバが出しうる語のうち1つを、電話側が復号確認しなくなる形。
probe "電話の写しから理由が1語落ちる" "$POLLTESTS" \
    '"cwd-mismatch", "pane-gone", "panes-unreadable", "tmux-unavailable",' \
    '"cwd-mismatch", "pane-gone", "panes-unreadable",' \
    "送れない理由"

# ⑭ 写しが太る。サーバが一度も出さない語で復号を確かめる形 = 測っているつもりの空振り。
#    ⑬と向きが逆なだけに見えるが、痩せは「漏れ」、太りは「幻の安心」で症状が違う。
probe "電話の写しにサーバが出さない理由が生える" "$POLLTESTS" \
    '"cwd-mismatch", "pane-gone", "panes-unreadable", "tmux-unavailable",' \
    '"cwd-mismatch", "pane-gone", "panes-unreadable", "tmux-unavailable", "pane-dead",' \
    "送れない理由"

# ⑮ 錨にした関数名が変わる/消える。採れる語が0になり、**空を一致と読む**道が開く。
#    検査側の床(`length >= 6`)が此処を塞いでいるかを見る —— 塞いでいなければ
#    「あの主張を測っている」ではなく「主張が在れば測る」になる。
probe "電話側の錨にした関数が改名される" "$POLLTESTS" \
    'func testEveryBlockedReasonTheServerCanSendDecodes() throws {' \
    'func testEveryBlockedReasonTheServerCanSendDecodesRenamed() throws {' \
    "送れない理由"

# ⑯ サーバ側が語を減らす。電話の写しが古い側に取り残される形で、
#    ⑬⑭と違って**製品の正本が動いた**時に鳴るか。
probe "サーバの WIRE_REASONS から語が1つ消える" "$BLOCKED" \
    '  "cwd-mismatch",
  "pane-gone",' \
    '  "cwd-mismatch",' \
    "送れない理由"

echo
echo "== 正しい変更は赤にしない(陰性対照) =="

probe_green_plant() {
    local name="$1"
    local rel="$2"
    local body="$3"
    printf '%s\n' "$body" >"$WORK/$rel"
    if run_suite; then
        echo "  PASS  $name  —— 緑のまま"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name  —— 赤にした"
        FAIL=$((FAIL + 1))
        /usr/bin/tail -12 "$WORK/out.txt"
    fi
    /bin/rm -f "$WORK/$rel"
}

# Ⓐ ★背骨その1。画面の状態語を**両側そろえて** `SENDABLE` → `READY_TO_SEND` へ改名する。
#   本番が実際に取り得る正しい木なので、緑でなければならない。赤い検査は語彙を今日の
#   綴りに固定し、正しく直す人を「検査が通らない」で止める。
/usr/bin/python3 - "$WORK" <<'PYEOF'
import io, os, sys
work = sys.argv[1]
hit = 0
for base, exts in (("rc-backend/src", (".mjs",)), ("ios/Sources", (".swift",))):
    for root, _dirs, files in os.walk(os.path.join(work, base)):
        for fn in files:
            if not fn.endswith(exts):
                continue
            p = os.path.join(root, fn)
            s = io.open(p, encoding="utf-8").read()
            if "SENDABLE" not in s:
                continue
            hit += 1
            io.open(p, "w", encoding="utf-8").write(s.replace("SENDABLE", "READY_TO_SEND"))
if hit < 2:
    sys.stderr.write("両側に SENDABLE が居ない(%d file)\n" % hit)
    sys.exit(3)
PYEOF
if [ $? -ne 0 ]; then
    echo "  UNMEASURED  画面の状態語を両側そろえて改名  —— 錨が両側に居ない"
    UNMEASURED=$((UNMEASURED + 1))
elif run_suite; then
    echo "  PASS  画面の状態語を両側そろえて改名するのは緑のまま"
    PASS=$((PASS + 1))
else
    echo "  FAIL  そろえた改名を赤にした = 語彙を今日の綴りに固定している"
    FAIL=$((FAIL + 1))
    /usr/bin/tail -12 "$WORK/out.txt"
fi
/bin/rm -rf "$WORK/ios/Sources"
/bin/cp -R "$ROOT/ios/Sources" "$WORK/ios/Sources"
/bin/cp "$ROOT"/rc-backend/src/*.mjs "$WORK/rc-backend/src/"

# Ⓑ ★背骨その2。復旧語彙の**値**を両側そろえて `SESSION_NOT_FOUND` → `SESSION_GONE` へ。
#   ④⑤ の相方 —— 片側だけ動かした木が赤い事を先に押さえていないと、此処の緑は
#   「両側そろっている」でも「値を誰も測っていない」でも同じ顔をする。
/usr/bin/python3 - "$WORK" <<'PYEOF'
import io, os, sys
work = sys.argv[1]
edits = {
    "rc-backend/src/server.mjs": [
        ('const SESSION_NOT_FOUND = Object.freeze({ error: "unknown session", code: "SESSION_NOT_FOUND" });',
         'const SESSION_NOT_FOUND = Object.freeze({ error: "unknown session", code: "SESSION_GONE" });'),
    ],
    "ios/Sources/Core/ResultDisplay.swift": [
        ('static let sessionNotFound = "SESSION_NOT_FOUND"',
         'static let sessionNotFound = "SESSION_GONE"'),
    ],
}
for rel, pairs in edits.items():
    p = os.path.join(work, rel)
    s = io.open(p, encoding="utf-8").read()
    for frm, to in pairs:
        if s.count(frm) != 1:
            sys.stderr.write("anchor not unique: %s\n" % rel)
            sys.exit(3)
        s = s.replace(frm, to)
    io.open(p, "w", encoding="utf-8").write(s)
PYEOF
if [ $? -ne 0 ]; then
    echo "  UNMEASURED  復旧語彙の値を両側そろえて改名  —— 錨が1箇所に定まらない"
    UNMEASURED=$((UNMEASURED + 1))
elif run_suite; then
    echo "  PASS  復旧語彙の値を両側そろえて改名するのは緑のまま"
    PASS=$((PASS + 1))
else
    echo "  FAIL  そろえた改名を赤にした = 値を今日の綴りに固定している(追認機)"
    FAIL=$((FAIL + 1))
    /usr/bin/tail -12 "$WORK/out.txt"
fi
restore_from_root "$SERVER"
restore_from_root "$RESULTD"

# Ⓕ ★背骨その3(S8-28)。送れない理由の綴りを**両側そろえて** `pane-gone` →
#   `pane-vanished` へ。⑬〜⑯ の相方 —— 片側だけ動かした木が赤い事を先に押さえて
#   いないと、此処の緑は「両側そろっている」でも「誰も此の8語を見ていない」でも
#   同じ顔をする。理由札は今日の綴りに固定してよい物ではない(`pane-gone` 自体、
#   `resolveSessionPane` が返さない名前をサーバが後から付けた語)。
/usr/bin/python3 - "$WORK" <<'PYEOF'
import io, os, sys
work = sys.argv[1]
edits = {
    "rc-backend/src/blocked.mjs": [
        ('  "cwd-mismatch",\n  "pane-gone",\n', '  "cwd-mismatch",\n  "pane-vanished",\n'),
    ],
    "ios/Tests/Core/PollModelsTests.swift": [
        ('"cwd-mismatch", "pane-gone", "panes-unreadable", "tmux-unavailable",',
         '"cwd-mismatch", "pane-vanished", "panes-unreadable", "tmux-unavailable",'),
    ],
}
for rel, pairs in edits.items():
    p = os.path.join(work, rel)
    s = io.open(p, encoding="utf-8").read()
    for frm, to in pairs:
        if s.count(frm) != 1:
            sys.stderr.write("anchor not unique: %s\n" % rel)
            sys.exit(3)
        s = s.replace(frm, to)
    io.open(p, "w", encoding="utf-8").write(s)
PYEOF
if [ $? -ne 0 ]; then
    echo "  UNMEASURED  送れない理由を両側そろえて改名  —— 錨が1箇所に定まらない"
    UNMEASURED=$((UNMEASURED + 1))
elif run_suite; then
    echo "  PASS  送れない理由を両側そろえて改名するのは緑のまま"
    PASS=$((PASS + 1))
else
    echo "  FAIL  そろえた改名を赤にした = 理由札を今日の綴りに固定している(追認機)"
    FAIL=$((FAIL + 1))
    /usr/bin/tail -12 "$WORK/out.txt"
fi
restore_from_root "$BLOCKED"
restore_from_root "$POLLTESTS"

# Ⓒ 注釈の中の語は**主張ではない**。`swiftsrc.mjs` の注釈落としが効いているかを、
#   Swift 側から見る(此処が赤い検査は、説明を書いた瞬間に赤くなる = 誰も説明を書かなくなる)。
probe_green_plant "Swift の注釈に語を書いても緑" "ios/Sources/Core/InventedForControlNote.swift" \
'// 対照が植えた作り物。注釈の中の "PANE_LOST" は線への主張ではない。
/* 塊注釈の中の "QUEUE_FULL" も同じ。 */
enum InventedForControlNote {}'

# Ⓓ JS 側の注釈落とし(`jssrc.mjs`)も同じく効いているか。
probe_green_plant "JS の注釈に語を書いても緑" "rc-backend/src/control-note.mjs" \
'// 対照が植えた作り物。注釈の中の "PANE_LOST" は線への主張ではない。
/* 塊注釈の中の "QUEUE_FULL" も同じ。 */
export const CONTROL_NOTE = 1;'

# Ⓔ 大文字だけの綴りが語彙の目印。小文字・混在は線の語彙ではないので、足しても緑。
#   此処を赤にすると、変数名や日本語混じりの文字列を足すたびに許可表が要る。
probe_green_plant "小文字・混在の文字列を足しても緑" "rc-backend/src/control-lower.mjs" \
'export const A = "pane_lost";
export const B = "Pane_Lost";
export const C = "送れません";'

echo
echo "== 飛ばしは緑ではない(部分木で無音になる道) =="
# 木の外が見えない写しでは `requireOutside` が `{ skip: 理由 }` を返し、node は skip を
# 成功として数える。対照が此処を緑と読むと「木の形を壊す」変異が全部素通りする。
/bin/mv "$WORK/DESIGN.md" "$WORK/DESIGN.md.hidden"
/bin/mv "$WORK/ios" "$WORK/ios.hidden"
if run_suite; then
    echo "  FAIL  木の外を隠したのに緑 = 飛ばしを緑と読んでいる"
    FAIL=$((FAIL + 1))
else
    echo "  PASS  木の外を隠したら赤(飛ばしを緑と読んでいない)"
    PASS=$((PASS + 1))
fi
/bin/mv "$WORK/ios.hidden" "$WORK/ios"
/bin/mv "$WORK/DESIGN.md.hidden" "$WORK/DESIGN.md"

# 親が本物のまま木の外だけ消える形は**飛ばしではなく赤**。`requireOutside` の三値
# (測った / 測っていない / 赤)が2値へ潰れていないかを此処で見る。
/bin/mv "$WORK/ios" "$WORK/ios.hidden"
if run_suite; then
    echo "  FAIL  親が本物のまま ios/ だけ消えても緑 = 三値が2値へ潰れている"
    FAIL=$((FAIL + 1))
else
    echo "  PASS  親が本物のまま ios/ だけ消えたら赤(飛ばしへ逃げていない)"
    PASS=$((PASS + 1))
fi
/bin/mv "$WORK/ios.hidden" "$WORK/ios"

echo
echo "== 名指しの入力が消えたら赤 =="
# 此の検査が**名前で開いている**3本だけを見る
# (`server.mjs` / `ResultDisplay.swift` / `PollModelsTests.swift`。S8-28 で3本目が増えた)。
# 他の file は木を歩いて拾われる側なので、消えても「語彙が減る」だけで、
# 此の検査の仕事(両側の一致)ではない —— 其処まで赤にすると
# 「file が消えた」を「語彙がズレた」と名乗る事になる。
#
# ★`SessionsListingFixture.swift` を此処に入れて **FAIL を1本出した**(2026-08-09)。
#   「あの file が消えれば `RC_UI_FIXTURE` が消えて許可表が死ぬ」と踏んだが、実測すると
#   同じ綴りは `HistoryFixture` / `SignOutNoticeFixture` / `KeyEntryProbeFixture` にも
#   在り、1本消しても語は残る。**検査ではなく対照の前提が誤っていた**ので、
#   検査を変えずに此処から外した。①が同じ file を別の形(語の発明)で見ている。
#   ★`PollModelsTests.swift` は①の轍を踏んでいない —— 此の1本が消えると
#   `requireOutside` の名簿から落ちるので、三値の契約(親が健在なら赤)がそのまま鳴る。
for gone in "$SERVER" "$RESULTD" "$POLLTESTS"; do
    /bin/mv "$WORK/$gone" "$WORK/$gone.hidden"
    if run_suite; then
        echo "  FAIL  $gone が消えても緑"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS  $gone が消えたら赤"
        PASS=$((PASS + 1))
    fi
    /bin/mv "$WORK/$gone.hidden" "$WORK/$gone"
done

echo
echo "--- 合計: PASS $PASS / FAIL $FAIL / UNMEASURED $UNMEASURED ---"
if [ "$UNMEASURED" -gt 0 ]; then exit 2; fi
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
