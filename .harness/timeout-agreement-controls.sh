#!/bin/bash
# controls-for: rc-backend/test/timeout-agreement.test.mjs rc-backend/src/server.mjs ios/Sources/Core/BackendSession.swift ios/Sources/Core/PollLoop.swift ios/Sources/Core/SendClient.swift ios/Sources/Screens/Conversation/ConversationViewModel.swift ios/Sources/Screens/KeyEntry/KeyEntryViewModel.swift ios/UITests/InFlightUITests.swift ios/UITests/KeyEntryUITests.swift ios/UITests/TapTargetUITests.swift
#
# 何を守る対照か —— **電話が言う秒数と、電話が実際に待つ秒数と、サーバが実際に保持する
# 秒数が、同じ数である事**。
#
# 2026-08-08(S8-23)。此処までの4件(S8-19 / S8-20 / S8-21 / S8-22)は画面に出る
# **文字列**を本番が作れるかを縛った。根は文字列ではない —— **電話は境界の向こうの値を
# 写して持ち、写しを照合する者が居ない**。秒数は同じ根の、より痛い媒体である。
#
# 起票時の実測(3つとも今日の値は正しかった。腐る前に囲った):
#   ・サーバの `POLL_MAX_WAIT_MS`(20_000ms)は電話側に `serverPollMaxWait = 20` として
#     手で写されている。`BackendSession.swift` の注釈は「離れない」と書いていたが、
#     離れない事を確かめる機械は1つも無かった。サーバが上限を伸ばした日、電話は先に
#     諦めるので**正常な「何も起きていない 200」が網の障害として画面に出る**。
#   ・「最大30秒待ちます」の秒数は定数から作られている(直書きは S8-4 / S8-6 で落とした)。
#     ただし**どの要求の待ちを言っているか**は注釈にしか無かった。`SendClient` の1行を
#     短い方の定数に替えると、要求は 8 秒で諦めるのに文は 30 秒と言い続け、
#     `SendClientTests` も `ConversationViewModelTests` も**両方緑のまま**通る。
#   ・画面検査は待つ文を文字列で焼いている(UI 検査は別過程なのでアプリの定数を読めない)。
#     UI の束を回す対照は1本も無い —— 焼いた数が腐っても、走らせるまで誰も気付かない。
#
# ★此の対照が縛るのは「今日の数」ではなく「**写しどうしが一緒に動く事**」。
#   下の陰性対照Ⓐが其の性質そのものを機械にしている: 定数と文と画面検査を**揃えて**
#   30 から 45 へ動かした木は、緑でなければならない。此処が赤い検査は秒数を今日の姿に
#   固定してしまい、正しく直す人が「検査が通らない」で諦める。
#
# ★写しは**根の形を保つ**。`timeout-agreement.test.mjs` は木の外(`ios/**`)を読むので、
#   `rc-backend/` だけを写すと `subtree.mjs` の契約に従って**飛ばされる**。
#   飛ばしは緑ではない —— 下の `run_suite` はそれを赤として扱う。
#
# ★木の外で回すので、共有の復旧区画(`INFLIGHT=`)は持たない。触るのは `mktemp -d` の
#   写しだけで、殺されても本物の木には何も残らない。
#
# 終了コード: 0 = 守られている / 1 = 破れている / 2 = 測れていない
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d -t rc-timeout-agreement)"
trap 'find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; /bin/rm -rf "$WORK" 2>/dev/null' EXIT

TESTF="rc-backend/test/timeout-agreement.test.mjs"
SERVER="rc-backend/src/server.mjs"
SESSION="ios/Sources/Core/BackendSession.swift"
POLLLOOP="ios/Sources/Core/PollLoop.swift"
SENDC="ios/Sources/Core/SendClient.swift"
CONVVM="ios/Sources/Screens/Conversation/ConversationViewModel.swift"
KEYVM="ios/Sources/Screens/KeyEntry/KeyEntryViewModel.swift"
INFLIGHTU="ios/UITests/InFlightUITests.swift"

for f in "$TESTF" "$SERVER" "$SESSION" "$POLLLOOP" "$SENDC" "$CONVVM" "$KEYVM" "$INFLIGHTU" \
         rc-backend/test/subtree.mjs DESIGN.md; do
    if [ ! -f "$ROOT/$f" ]; then
        echo "UNMEASURED  読む file が無い: $f"
        exit 2
    fi
done

/bin/mkdir -p "$WORK/rc-backend/src" "$WORK/rc-backend/test" \
              "$WORK/ios/Sources/Core" "$WORK/ios/Sources/Screens/Conversation" \
              "$WORK/ios/Sources/Screens/KeyEntry" "$WORK/ios/UITests"
/bin/cp "$ROOT"/rc-backend/src/*.mjs "$WORK/rc-backend/src/"
/bin/cp "$ROOT/$TESTF" "$ROOT/rc-backend/test/subtree.mjs" "$WORK/rc-backend/test/"
# Core は**丸ごと**写す。検査は「待ち時間を載せている file」を dir 走査で数えるので、
# 選んで写すと写した物しか居ない木になり、走査の穴が見えなくなる。
/bin/cp "$ROOT"/ios/Sources/Core/*.swift "$WORK/ios/Sources/Core/"
/bin/cp "$ROOT/$CONVVM" "$WORK/ios/Sources/Screens/Conversation/"
/bin/cp "$ROOT/$KEYVM" "$WORK/ios/Sources/Screens/KeyEntry/"
/bin/cp "$ROOT"/ios/UITests/*.swift "$WORK/ios/UITests/"
# 根の目印。`subtree.mjs` は此の1本の実在だけで「親が本物か」を決める。
/bin/cp "$ROOT/DESIGN.md" "$WORK/DESIGN.md"

PASS=0
FAIL=0
UNMEASURED=0

# 写しの検査を回す。緑なら0、赤なら非0。
#
# ★**飛ばしを緑と読まない**。`requireOutside` は木の外が見えない時に node:test の
#   `{ skip: 理由 }` を返し、node は skip を成功として数える。つまり「木の形を壊す」変異は
#   検査を無音にするだけで exit 0 のまま通る。TAP の飛ばし数を此処で赤にする。
run_suite() {
    local rc
    ( cd "$WORK/rc-backend" && node --test test/timeout-agreement.test.mjs >"$WORK/out.txt" 2>&1 )
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

# 写しの1本を本物から取り直す。複数 file を同時に動かす対照の後始末に使う
# (`mutate` の `.orig` は1本ずつしか持てない)。
restore_from_root() {
    /bin/cp "$ROOT/$1" "$WORK/$1"
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

echo "== 境界を跨いだ写しがズレる(サーバ ↔ 電話) =="

# ① サーバが上限を伸ばし、電話の写しが古いまま残る。**移動中に一番出てほしくない嘘**:
#    正常な「何も起きていない 200」が網の障害として画面に出る。
probe "サーバの上限が伸びて電話の写しが古くなる" "$SERVER" \
    "const POLL_MAX_WAIT_MS = 20_000;" \
    "const POLL_MAX_WAIT_MS = 25_000;"

# ② 要求に載せて送る待ち時間の方の写し。秒とミリ秒で**2種類**在るので片方だけ見ると漏れる。
probe "要求に載せる待ち時間が1箇所だけズレる" "$POLLLOOP" \
    "return StepResult(kind: .unreadable, nextWaitMs: 20_000, localBackoffMs: 0)" \
    "return StepResult(kind: .unreadable, nextWaitMs: 15_000, localBackoffMs: 0)"

# ③ サーバ側の宣言の**形**が変わって読めなくなる。読めない物を黙って飛ばすと
#    「照合したが一致した」と見分けが付かない。
probe "サーバ側の宣言の形が変わって読めなくなる" "$SERVER" \
    "const POLL_MAX_WAIT_MS = 20_000;" \
    "const POLL_MAX_WAIT_MS  = 20_000;"

echo
echo "== 文が言う秒数と、要求が実際に待つ秒数が別れる =="

# ④ ★起票の核。送信の要求だけを短い待ちに替える。要求は 8 秒で諦めるのに文は 30 秒と
#    言い続け、両側の単体検査は**両方緑のまま**通る。
probe "★送信の要求だけ短い待ちに替わる(文は30秒と言い続ける)" "$SENDC" \
    "request.timeoutInterval = BackendSession.writeTimeout" \
    "request.timeoutInterval = BackendSession.interactiveTimeout"

# ⑤ 反対側から。文が渡す定数だけを替える。
probe "文が渡す定数だけ替わる(要求は長い待ちのまま)" "$CONVVM" \
    "Self.interruptInFlightText(timeout: BackendSession.writeTimeout)" \
    "Self.interruptInFlightText(timeout: BackendSession.interactiveTimeout)"

# ⑥ 鍵入力画面の側も同じ形で見張られているか(会話画面だけ守られていないか)。
probe "鍵入力の文が渡す定数だけ替わる" "$KEYVM" \
    "return Self.keyProbeInFlightText(timeout: BackendSession.interactiveTimeout)" \
    "return Self.keyProbeInFlightText(timeout: BackendSession.writeTimeout)"

# ⑦ 対応の片側が消える(client が改名された/行が落ちた)。
probe "要求の側が待ち時間を載せなくなる" "$SENDC" \
    "request.timeoutInterval = BackendSession.writeTimeout" \
    "// request.timeoutInterval を消した"

echo
echo "== 画面検査に焼いた秒数が古くなる =="

# ⑧ 焼いた数だけが動く。UI の束を回す対照は無いので、此処が唯一の見張り。
probe "画面検査に焼いた秒数だけが動く" "$INFLIGHTU" \
    'private let sendSentence = "送っています…(机の返事を最大30秒待ちます)"' \
    'private let sendSentence = "送っています…(机の返事を最大45秒待ちます)"'

# ⑨ 宣言していない画面検査が秒数を焼き始める。「知っている file だけ見る」形だと
#    新しい file は黙って検査の外に落ちる —— 落ちた物は永久に見えない。
NEWUI="ios/UITests/InventedForControlUITests.swift"
cat >"$WORK/$NEWUI" <<'SWIFTEOF'
// 対照が植えた作り物。宣言の外で秒数を焼き始めた画面検査の代わり。
final class InventedForControlUITests {
    private let sentence = "作り物です(最大99秒待ちます)"
}
SWIFTEOF
if run_suite; then
    echo "  FAIL  宣言していない画面検査が秒数を焼き始める  —— 緑のまま = 新しい file が検査の外に落ちる"
    FAIL=$((FAIL + 1))
else
    echo "  PASS  宣言していない画面検査が秒数を焼き始める  —— 植えたら赤が出た"
    PASS=$((PASS + 1))
fi
/bin/rm -f "$WORK/$NEWUI"

echo
echo "== 分割そのものが畳まれる =="

# ⑩ 読む待ちと書く待ちを1本に畳む。写しどうしは一致したままなので①-⑨は全部緑で通り、
#    REQUIREMENTS §5-6 が直した症状(応答の無い網で白画面が長く続く)だけが戻る。
probe "読む待ちと書く待ちを1本に畳む" "$SESSION" \
    "static let interactiveTimeout: TimeInterval = 8" \
    "static let interactiveTimeout: TimeInterval = pollTimeout"

# ⑪ 秒数の式が評価器の解けない形になる。**飛ばさずに赤で言う**事の確認 ——
#    解けない式を黙って飛ばすと、その定数だけ誰にも照合されないまま緑に見える。
probe "秒数の式が解けない形になる(飛ばさずに赤で言うか)" "$SESSION" \
    "static let interactiveTimeout: TimeInterval = 8" \
    "static let interactiveTimeout: TimeInterval = max(8, 4)"

echo
echo "== 検査自身の錨が外れる(拾えない物を0件にしない) =="

# ⑫⑬⑭ 走査が1件も拾えなくなる形。拾えなければ「比べる物ゼロ = 全部一致」——
#       この repo が何度も踏んでいる穴で、S8-21 でも同じ3本を植えた。
probe "待ち時間を渡す所を1件も拾えなくする" "$TESTF" \
    '(code.match(/nextWaitMs:/g) || []).length' \
    '(code.match(/nextWaitMs@@@:/g) || []).length'

probe "飛んでいる間の文の呼び出しを1件も拾えなくする" "$TESTF" \
    'const m = /Self\.(\w*InFlightText)\(timeout:\s*BackendSession\.(\w+)\)/.exec(line);' \
    'const m = /Self\.@@@(\w*InFlightText)\(timeout:\s*BackendSession\.(\w+)\)/.exec(line);'

probe "画面検査に焼いた秒数を1件も拾えなくする" "$TESTF" \
    'const found = [...src.matchAll(/最大(\d+)秒/g)].map((m) => Number(m[1]));' \
    'const found = [...src.matchAll(/最大@@@(\d+)秒/g)].map((m) => Number(m[1]));'

# ⑮ 宣言(三項式)が行ではなく式で名指されている事。式が動けば宣言が外れて総数が合わない。
probe "三項式が動いて宣言が外れる(行ではなく式で名指しているか)" "$POLLLOOP" \
    "nextWaitMs: response.more ? 0 : 20_000" \
    "nextWaitMs: response.more ?  0 : 20_000"

echo
echo "== 正しい変更は赤にしない(陰性対照) =="

# Ⓐ ★此の対照の背骨。定数と文と画面検査を**揃えて** 30 から 45 へ動かす。
#   これは本番が実際に取り得る正しい木なので、緑でなければならない。
#   赤い検査は秒数を今日の姿に固定し、正しく直す人が「検査が通らない」で諦める ——
#   S8-19 の初版で私が踏んだ形と同じ。
/usr/bin/python3 - "$WORK" <<'PYEOF'
import sys, io, os
work = sys.argv[1]
edits = {
    "ios/Sources/Core/BackendSession.swift": [
        ("static let pollTimeout: TimeInterval = serverPollMaxWait + 10",
         "static let pollTimeout: TimeInterval = serverPollMaxWait + 25"),
    ],
    "ios/UITests/InFlightUITests.swift": [("最大30秒", "最大45秒")],
    "ios/UITests/TapTargetUITests.swift": [("最大30秒", "最大45秒")],
}
for rel, pairs in edits.items():
    p = os.path.join(work, rel)
    s = io.open(p, encoding="utf-8").read()
    for frm, to in pairs:
        s = s.replace(frm, to)
    io.open(p, "w", encoding="utf-8").write(s)
PYEOF
if run_suite; then
    echo "  PASS  定数と文と画面検査を揃えて動かすのは緑のまま"
    PASS=$((PASS + 1))
else
    echo "  FAIL  揃えた変更を赤にした = 秒数を今日の姿に固定している"
    FAIL=$((FAIL + 1))
    /usr/bin/tail -12 "$WORK/out.txt"
fi
restore_from_root "$SESSION"
restore_from_root "$INFLIGHTU"
restore_from_root "ios/UITests/TapTargetUITests.swift"

# Ⓑ 縛っているのは**数**であって文ではない。秒数以外を書き換えても緑。
#   文まで固定すると、言い回しを直すたびに赤が出る = 誰も直さない検査になる。
if mutate "$INFLIGHTU" \
    'private let sendSentence = "送っています…(机の返事を最大30秒待ちます)"' \
    'private let sendSentence = "送信中です…(机の返事を最大30秒待ちます)"'; then
    if run_suite; then
        echo "  PASS  秒数以外の言い回しは何に替えても緑のまま"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  言い回しまで縛った = 文を直すたびに赤が出る"
        FAIL=$((FAIL + 1))
    fi
    restore "$INFLIGHTU"
else
    echo "  UNMEASURED  言い回し側の陰性対照の錨が1箇所に定まらない"
    UNMEASURED=$((UNMEASURED + 1))
fi

# Ⓒ 待ち時間を渡す枝が1本増えるのは正当(値が上限のままなら)。
#   本数を固定すると、枝を足すたびに赤が出る。
if mutate "$POLLLOOP" \
    "return StepResult(kind: .unauthorized, nextWaitMs: 20_000, localBackoffMs: 0)" \
    "return StepResult(kind: .unauthorized, nextWaitMs: 20_000, localBackoffMs: 0)
            // 対照が植えた枝(値は上限のまま)
            _ = StepResult(kind: .unauthorized, nextWaitMs: 20_000, localBackoffMs: 0)"; then
    if run_suite; then
        echo "  PASS  待ち時間を渡す枝が増えても、値が上限のままなら緑"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  本数を固定した = 枝を足すたびに赤が出る"
        FAIL=$((FAIL + 1))
    fi
    restore "$POLLLOOP"
else
    echo "  UNMEASURED  枝の追加側の陰性対照の錨が1箇所に定まらない"
    UNMEASURED=$((UNMEASURED + 1))
fi

# Ⓓ 待ち時間を載せる client が1本増えるのは正当。宣言した対応が解ける事だけが要件で、
#   client の集合を固定すると、新しい要求を足すたびに赤が出る。
NEWCLIENT="ios/Sources/Core/InventedForControlClient.swift"
cat >"$WORK/$NEWCLIENT" <<'SWIFTEOF'
// 対照が植えた作り物。待ち時間を載せる新しい要求の代わり。
struct InventedForControlClient {
    func run() {
        var request = URLRequest(url: URL(string: "https://invented.invalid")!)
        request.timeoutInterval = BackendSession.interactiveTimeout
    }
}
SWIFTEOF
if run_suite; then
    echo "  PASS  待ち時間を載せる要求が1本増えても緑"
    PASS=$((PASS + 1))
else
    echo "  FAIL  client の集合を固定した = 新しい要求を足すたびに赤が出る"
    FAIL=$((FAIL + 1))
fi
/bin/rm -f "$WORK/$NEWCLIENT"

echo
echo "== 飛ばしは緑ではない(部分木で無音になる道) =="
# 木の外が見えない写しでは `requireOutside` が `{ skip: 理由 }` を返し、node は
# skip を成功として数える。対照が此処を緑と読むと「木の形を壊す」変異が全部素通りする。
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

echo
echo "== 対象が消えたら赤(改名・削除を素通りさせない) =="
for gone in "$SESSION" "$POLLLOOP" "$CONVVM" "$KEYVM" "$INFLIGHTU"; do
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
