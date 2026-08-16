#!/bin/bash
# controls-for: rc-backend/test/wire-key-agreement.test.mjs rc-backend/src/view.mjs rc-backend/src/blocked.mjs rc-backend/src/wire.mjs rc-backend/src/sessions.mjs rc-backend/src/registry.mjs rc-backend/src/server.mjs ios/Sources/Core/PollModels.swift ios/Sources/Core/SessionsModels.swift ios/Sources/Core/ResultDisplay.swift ios/Sources/Core/HistoryModels.swift
#
# 何を守る対照か —— **電話の `Decodable` が名乗る鍵名と、サーバが実際に吐く鍵名が、
# 同じ綴りである事**。
#
# 2026-08-08(S8-24)。S8-19〜S8-22 は画面に出る**文字列**を、S8-23 は**秒数**を縛った。
# 根はどちらでもない —— **電話は境界の向こうの値を写して持ち、写しを照合する者が居ない**。
# 鍵名は同じ根の、一番静かな媒体である: 電話の model は**わざと緩く**復号するので、
# 鍵名が片側で変われば復号は通り、例外は出ず、両側の単体検査は全部緑のまま、
# **画面だけが痩せる**。`display.choice` が改名されれば選択カードは二度と出ず、
# `buttons`/`digest` が改名されればカードは出るのに何も押せない。
#
# ★対照が縛るのは「今日の綴り」ではない。下の陰性対照Ⓐが其の性質を機械にしている:
#   両側**揃えて** `headline` を `title` へ改名した木は緑でなければならない。
#   此処が赤い検査は鍵名を今日の姿に固定し、正しく直す人が「検査が通らない」で諦める。
#
# ★測り方が非対称なので、対照も両側から植える。側A(サーバ)は builder を**実行**して
#   出た鍵を拾い、側B(電話)は**原文を読む**。片側だけ植えて赤が出ても、もう片側の
#   走査が死んでいる可能性は消えない —— だから④は側Aから、①②は側Bから植える。
#
# ★「拾えなければ0件 = 全部一致」の穴を、此の repo は何度も踏んでいる。走査の錨を
#   外す変異(⑧⑨⑩⑲)と、側Aの入力を痩せさせる変異(⑦)を別に持つのはその為。
#
# ★2026-08-08(S8-25)、一覧の5本を足した。ここは形が3つ違うので対照も3つ要る:
#   (a) 行の鍵は**生産者3本の和**(jsonl から / 登録簿だけ / 読めなかった)。1本落とすと
#       その経路にしか無い鍵が「電話に無い鍵」ではなく「誰も吐かない鍵」として静かに
#       消える —— ⑰ が其の1本を抜く。
#   (b) 電話は行の13鍵のうち5鍵しか読まない。差は `serverOnly` に名前で書いてあるので、
#       **増えても減っても赤**でなければ白紙委任になる —— ⑯⑱ が両方向を植える。
#       但し縛るのは集合であって並び順ではない(陰性Ⓔ)。
#   (c) 封筒を純関数へ出しても、`src/server.mjs` が直書きへ戻せば上の照合は全部飾りになる。
#       server.mjs は import した瞬間 listen するので実行では捕まらない —— ⑳ が原文の錨を外す。
#
# ★写しは**根の形を保つ**。`wire-key-agreement.test.mjs` は木の外(`ios/Sources/**`)を
#   丸ごと走査するので、`rc-backend/` だけを写すと `subtree.mjs` の契約に従って
#   **飛ばされる**。飛ばしは緑ではない —— 下の `run_suite` はそれを赤として扱う。
#   `ios/Sources` を**選ばず丸ごと**写すのも同じ理由で、選んで写すと写した物しか
#   居ない木になり、走査の穴が見えなくなる。
#
# ★木の外で回すので、共有の復旧区画(`INFLIGHT=`)は持たない。触るのは `mktemp -d` の
#   写しだけで、殺されても本物の木には何も残らない。
#
# 終了コード: 0 = 守られている / 1 = 破れている / 2 = 測れていない
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d -t rc-wire-key-agreement)"
trap 'find "$WORK" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; /bin/rm -rf "$WORK" 2>/dev/null' EXIT

TESTF="rc-backend/test/wire-key-agreement.test.mjs"
VIEW="rc-backend/src/view.mjs"
BLOCKED="rc-backend/src/blocked.mjs"
WIRE="rc-backend/src/wire.mjs"
SESSJS="rc-backend/src/sessions.mjs"
REGJS="rc-backend/src/registry.mjs"
SERVER="rc-backend/src/server.mjs"
POLLM="ios/Sources/Core/PollModels.swift"
SESSM="ios/Sources/Core/SessionsModels.swift"
RESULTD="ios/Sources/Core/ResultDisplay.swift"
HISTM="ios/Sources/Core/HistoryModels.swift"
HEALTHM="ios/Sources/Core/HealthzClient.swift"

for f in "$TESTF" "$VIEW" "$BLOCKED" "$WIRE" "$SESSJS" "$REGJS" "$SERVER" \
         "$POLLM" "$SESSM" "$RESULTD" "$HISTM" "$HEALTHM" \
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
# Sources は**丸ごと**写す。検査は木を歩いて鍵付き型を数え上げ、`PAIRS`/`UNPAIRED` の
# どちらかに全員居る事を測るので、選んで写すと居ない型が「幻」として赤くなる。
/bin/cp -R "$ROOT/ios/Sources" "$WORK/ios/Sources"
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
    ( cd "$WORK/rc-backend" && node --test test/wire-key-agreement.test.mjs >"$WORK/out.txt" 2>&1 )
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

echo "== 電話の側だけ鍵名が動く(復号は通り、例外は出ない) =="

# ① 格納プロパティの名前がそのまま鍵になっている型。一覧の札の `screen` が改名されると、
#    札は出るのに画面名だけが空になる —— S8-19 が直した「生の英語」より静かな壊れ方。
probe "電話 RouteLabel.screen が改名される" "$SESSM" \
    "    let screen: String" \
    "    let screenName: String"

# ② `CodingKeys` を持つ型。property 名は無傷なので、Swift の側は**何も気付かない**。
#    `digest` が落ちれば選択カードは出るのに押しても通らない(S6 の症状に戻る)。
probe "電話 ChoiceView の CodingKeys digest が改名される" "$POLLM" \
    "case show, reason, head, options, buttons, digest" \
    "case show, reason, head, options, buttons, sig"

# ⑪ 一覧の行の `Bool?`。**任意の鍵**が改名されても Swift は何も言わない —— `nil` は
#    「サーバが送ってこなかった」と見分けが付かないので、一覧から札が1種類消えるだけ。
probe "電話 SessionRow.fromRegistryOnly が改名される" "$SESSM" \
    "    let fromRegistryOnly: Bool?" \
    "    let fromRegistryOnlyX: Bool?"

# ⑫ 封筒の一段内側。走査の件数(何本の会話を見たか)が黙って空になる形で、
#    「一覧が短い理由」を電話が言えなくなる —— 押しても何も起きないボタンに戻る。
probe "電話 SessionsResponse.OuterDisplay.scan が改名される" "$SESSM" \
    "        let scan: String" \
    "        let scanLine: String"

# ⑬ 行の副題。同じ `display` という名前の入れ物が封筒側にも在るので、**入れ子の位置**まで
#    合っていないと測った事にならない(組は `at: "display"` を2つ持っている)。
probe "電話 SessionRow.RowDisplay.subtitle が改名される" "$SESSM" \
    "        let subtitle: String" \
    "        let subtitleText: String"

# ⑭ ★下の陰性Ⓓ(生産者3本と電話を**そろえて** `title` → `heading`)の相方。片側だけ動かした
#    木が赤い事を先に押さえていないと、Ⓓ の緑は「両側そろっている」ではなく
#    「`title` を誰も測っていない」でも同じ顔をする。緑の意味は赤の在処でしか決まらない。
probe "電話 SessionRow.title だけ改名される(Ⓓ の相方)" "$SESSM" \
    "    let title: String" \
    "    let heading: String"

# --- ここから S8-26(2026-08-09)で足した poll / 履歴の8組 ---------------------
#
# ★8組のうち3組は `phone-subset`(PollResponse / MessageItem / GapItem)なので、
#   両側から植える。残り5組は完全一致なので、片側が死んでいれば組が空になり①が赤くなる
#   —— だから1本で足りる。**「両方植てあるから丁寧」ではなく、mode で必要本数が違う**。

# ㉑ poll の封筒で電話だけが `display` を落とす。ワーカー経路は元から `display` を送らないので、
#    電話は `PollDisplay?` で受けている —— つまり**改名しても復号は通り、例外も出ない**。
#    選択カードが二度と出なくなるのに、両側の単体検査は緑のまま。S8-24 の動機そのものの形。
probe "電話 PollResponse.display が改名される" "$POLLM" \
    "    let display: PollDisplay?" \
    "    let shown: PollDisplay?"

# ㉒ その一段内側。`choice` が落ちれば「選択待ちだと分かるのに答えられない」に戻る
#    (S6 が直した症状)。`ChoiceView?` なので、これも黙って `nil` になるだけ。
probe "電話 PollDisplay.choice が改名される" "$POLLM" \
    "    let choice: ChoiceView?" \
    "    let pick: ChoiceView?"

# ㉓ tmux 経路の発言の束。`[HistoryEntry]?` は「ワーカー経路だから無い」と見分けが付かないので、
#    改名すると**会話が永久に空のまま流れる**(切断でも誤りでもなく、ただ何も出ない)。
probe "電話 MessageItem.entries が改名される" "$POLLM" \
    "    let entries: [HistoryEntry]?" \
    "    let rows: [HistoryEntry]?"

# ㉔ 欠落の報せの `CodingKeys`。property 名は無傷なので Swift 側は何も気付かない。
#    `seq` が落ちても v1 は誰も読まないが、`serverOnly` の宣言(`kind` だけ)は嘘になる。
probe "電話 GapItem の CodingKeys seq が改名される" "$POLLM" \
    "    private enum CodingKeys: String, CodingKey { case why, display, seq }" \
    "    private enum CodingKeys: String, CodingKey { case why, display, num }"

# ㉕ 履歴の封筒の `CodingKeys`。`truncated` が落ちると `decodeIfPresent ?? false` が
#    **常に false** になり、「以前を読む」が出ない会話が出来る —— 押せないのではなく、無い。
probe "電話 HistoryResponse の CodingKeys truncated が改名される" "$HISTM" \
    "        case history, truncated" \
    "        case history, cut"

# ㉖ 発言者名。S8-21 が「fixture だけが良い版を持っていた」を直した所で、鍵名が動けば
#    元の木阿弥になる —— 名前が出ないのではなく、`who` が空文字で描かれる。
probe "電話 HistoryEntry.EntryDisplay.who が改名される" "$HISTM" \
    "        let who: String" \
    "        let whom: String"

# ㉞ 生存信号の1鍵。**認証の外**に在る唯一の応答なので、ここがズレると
#    「机の機械が生きているか」を旅先で確かめる唯一の窓が、静かに `nil` を返す
#    (`version` が落ちれば版の名乗りが空欄になる —— 誤りは出ない)。
#    此の組は `mode` 無し = 完全一致なので、片側だけ動かせば必ず赤になるはず。
probe "電話 HealthzClient.Wire.uptime が改名される" "$HEALTHM" \
    "struct Wire: Decodable { let ok: Bool; let pid: Int; let uptime: Int; let version: String }" \
    "struct Wire: Decodable { let ok: Bool; let pid: Int; let up: Int; let version: String }"

echo
echo "== サーバの側だけ鍵名が動く =="

# ③ 鍵が1つ増える。電話は知らない鍵を黙って捨てるので、増えた側は永久に画面へ出ない。
probe "サーバ paneFaultView が鍵を1つ増やす" "$BLOCKED" \
    '      headline: "机の画面一覧を取れていません",' \
    '      headline: "机の画面一覧を取れていません",
      code: reason,'

# ④ ★**枝を1本だけ**改名する。他の枝は `keepText` を出し続けるので、和を取るだけの
#    検査なら「両方在る」で誤魔化せる。入力欄の本文を残すかを電話が読めなくなる形。
probe "サーバ sendResult の成功枝だけ keepText を改名する" "$VIEW" \
    '      text: b.route === "worker" ? "送った(ワーカー)" : "送った",
      keepText: false,' \
    '      text: b.route === "worker" ? "送った(ワーカー)" : "送った",
      keepTextX: false,'

# ⑮ 行に**重ねる**側の鍵。生の行(3生産者)は無傷なので、和を取るだけの検査は
#    「鍵は全部在る」と読む。落ちるのは札1枚 = 一覧でその会話が今どこに居るかだけ。
probe "サーバ sessionRow の display.route が改名される" "$WIRE" \
    "display: { route: routeLabel(live), subtitle: subtitleOf(row) }" \
    "display: { routeName: routeLabel(live), subtitle: subtitleOf(row) }"

# ⑯ ★`serverOnly` に名前で書いた鍵が**サーバ側で**動く。電話は元から読まないので
#    画面は1ピクセルも変わらない —— 宣言が「電話が読まない鍵の名簿」として生きているか、
#    それとも書いた日から誰も見ていない作文かは、此処でしか分からない。
probe "サーバ unreadableRow の errorCode が改名される(宣言した serverOnly と食い違う)" "$SESSJS" \
    '    readable: false,
    errorCode,
  };' \
    '    readable: false,
    errorCodeX: errorCode,
  };'

# ⑰ ★生産者を**1本だけ**痩せさせる。`fromRegistryOnly` は登録簿だけの経路にしか無いので、
#    3本の和を取るのを止めた日(或いは此の1本を落とした日)、電話が読む鍵が
#    「誰も吐かない鍵」に変わる —— 例外は出ず、札が出ないだけ。
probe "サーバ registryOnlySessions が fromRegistryOnly を落とす" "$REGJS" \
    '      updatedAt: new Date(e.mtimeMs).toISOString(),
      fromRegistryOnly: true,
    });' \
    '      updatedAt: new Date(e.mtimeMs).toISOString(),
    });'

# ⑱ ★`phone-subset` が白紙委任でない事。電話が読まない鍵を**新しく**足したら、それは
#    「電話が読み落とした候補」なので人が見る。此処が緑になる検査は「電話は鍵を無視してよい」
#    と言っているのと同じで、電話が読むべき鍵を1本落とした日も同じ緑を出す。
probe "サーバ sessionsBody が宣言していない鍵を1つ増やす" "$WIRE" \
    "display: { scan: scanLine(scan) }," \
    "display: { scan: scanLine(scan) },
    debugTrace: \"x\","

# --- ここから S8-26(2026-08-09)の側A ------------------------------------------

# ㉗ 履歴の封筒の外側の鍵。落ちれば会話が**開いた瞬間に空**になる(誤りは出ない)。
#    下の陰性Ⓕ(両側そろえて `history` → `entries`)の相方 —— 片側だけ動かした木が
#    赤い事を先に押さえていないと、Ⓕ の緑は「両側そろっている」でも
#    「`history` を誰も測っていない」でも同じ顔をする。
probe "サーバ historyBody の history が改名される(Ⓕ の相方)" "$WIRE" \
    "  return { history: entries.map(withWho), truncated };" \
    "  return { entries: entries.map(withWho), truncated };"

# ㉘ ★`serverOnly: ["route"]` が生きた宣言か作文かを決める1本。電話は経路を読まないので
#    画面は1ピクセルも変わらない —— 此処が緑になる検査は「サーバは好きな鍵を足してよい」
#    と言っているのと同じで、電話が読むべき鍵を落とした日も同じ緑を出す。
probe "サーバ pollBodyTmux の route が改名される(宣言した serverOnly と食い違う)" "$WIRE" \
    '    route: "tmux",' \
    '    path: "tmux",'

# ㉙ ★`display` は **tmux 経路にしか無い鍵**。ここを改名すると `PollDisplay` の組が
#    比べる物ゼロになる —— 「0件 = 全部一致」を①が赤で止めているかの確認。
probe "サーバ pollBodyTmux の display が改名される(PollDisplay の組が空になる)" "$WIRE" \
    "    display: { choice: screen ? choiceView(screen) : null }," \
    "    shown: { choice: screen ? choiceView(screen) : null },"

# ㉚ ★ワーカー経路の封筒が**本当に読まれているか**。今日のワーカーの鍵は tmux の部分集合なので、
#    和から外しても何も変わらない —— つまり此の1本が無いと、組の `builders` に
#    `pollBodyWorker` が居る事に意味が在るかを誰も言えない。鍵を1つ足して赤を要求する
#    (S8-18 で足した「上限に当たった」の類が、明日ここへ来る)。
probe "サーバ pollBodyWorker が宣言していない鍵を1つ増やす" "$WIRE" \
    "  return { items, screen: null, route: \"worker\", queued, cursor, more };" \
    "  return { items, screen: null, route: \"worker\", queued, cursor, more, limitHit: false };"

# ㉛ 項目の振り分け語。電話は `PollItem` の enum 側で読むので `serverOnly` に書いてある。
#    改名すれば**発言も欠落も、どちらとしても解釈されない項目**が流れる。
probe "サーバ messageItem の kind が改名される(宣言した serverOnly と食い違う)" "$WIRE" \
    '    kind: "message",' \
    '    type: "message",'

# ㉜ 欠落の帯の文面。`GapItem` は `display` を1段剥がして `notice` を取るので、
#    ここが動くと**切れ目は検出されるのに帯が白紙**になる(`nil` = 描かない、が正しい値と
#    見分けられない —— `tail-attached` が実際に `null` を返す事の裏返し)。
probe "サーバ gapItem の display.notice が改名される" "$WIRE" \
    '  const item = { kind: "gap", why, display: { notice: gapNotice(why) } };' \
    '  const item = { kind: "gap", why, display: { text: gapNotice(why) } };'

# ㉝ 発言者名を作る側。S8-21 が fixture の手書きを潰した所の、サーバ側の相方。
probe "サーバ withWho の display.who が改名される" "$WIRE" \
    "  return { ...entry, display: { who: whoOf(entry.role) } };" \
    "  return { ...entry, display: { name: whoOf(entry.role) } };"

# ㉟ ★生存信号に鍵が**増える**。此処だけは `serverOnly` を1つも許していないので、
#    増えた鍵は必ず赤になる —— 「電話は読まないから」で認証の外へ値を足す道を塞ぐのが
#    この組を完全一致にした理由で、それが効いているかは此の1本でしか分からない。
#    植える鍵はわざと**実際に危ない物**(開いている会話の件数)にしてある。
probe "サーバ healthzBody が鍵を1つ増やす(認証の外へ件数が漏れる形)" "$WIRE" \
    "  return { ok: true, pid, uptime, version };" \
    "  return { ok: true, pid, uptime, version, sessions: 3 };"

# ㊱ ★`/healthz` のハンドラが直書きへ戻る。⑳ の一覧版と同じ形だが、こちらは**認証の外**なので
#    直書きへ戻った日に鍵を足しても、電話側の照合を1つも通らずに線へ出る。
probe "ハンドラが /healthz を直書きへ戻す(healthzBody を通らなくなる)" "$SERVER" \
    "      return json(res, 200, healthzBody({
        pid: process.pid,
        uptime: Math.floor((Date.now() - STARTED_AT) / 1000),
        version: DEPLOYED_REV,
      }));" \
    "      return json(res, 200, {
        ok: true,
        pid: process.pid,
        uptime: Math.floor((Date.now() - STARTED_AT) / 1000),
        version: DEPLOYED_REV,
      });"

echo
echo "== 走査から隠れる書き方が増える =="

# ⑤ 鍵付き型が1つ増える。`PAIRS` にも `UNPAIRED` にも居ない型は「測ったか」が
#    誰にも言えない —— 0件を「全部一致」と読ませない為の分割そのものの見張り。
NEWWIRE="ios/Sources/Core/InventedForControlWire.swift"
cat >"$WORK/$NEWWIRE" <<'SWIFTEOF'
// 対照が植えた作り物。誰にも突き合わせられていない新しい wire 型の代わり。
struct InventedForControlWire: Decodable, Equatable {
    let inventedKey: String
}
SWIFTEOF
if run_suite; then
    echo "  FAIL  鍵付き型が1つ増える  —— 緑のまま = 新しい型が黙って検査の外に落ちる"
    FAIL=$((FAIL + 1))
else
    echo "  PASS  鍵付き型が1つ増える  —— 植えたら赤が出た"
    PASS=$((PASS + 1))
fi
/bin/rm -f "$WORK/$NEWWIRE"

# ⑥ `extension` で準拠を足す書き方。**型宣言の行には何も残らない**ので、行を読む走査
#    からは完全に消える。此処を見張っていないと、鍵を持つ型が1つだけ静かに外れる道になる。
printf '\nextension RecoveryCode: Codable {}\n' >>"$WORK/$RESULTD"
if run_suite; then
    echo "  FAIL  extension で準拠を足す  —— 緑のまま = 走査から隠れる書き方が野放し"
    FAIL=$((FAIL + 1))
else
    echo "  PASS  extension で準拠を足す  —— 植えたら赤が出た"
    PASS=$((PASS + 1))
fi
restore_from_root "$RESULTD"

echo
echo "== 検査自身の錨が外れる(拾えない物を0件にしない) =="

# ⑦ ★側Aの入力を痩せさせる。此の検査が**嘘の緑**を出しうる唯一の道 —— 選択カードの
#    豊かな枝を1本落とすと `options[]`/`buttons[]` の鍵が一度も出ず、比べる物が消える。
#
#    ★2026-08-09、錨を `CHOICE_SCREEN` へ移した。S8-26 で fixture を定数へ括り出した時、
#      綴りで引いていた此処が**1箇所に定まらない**へ落ちた —— そして UNMEASURED として
#      声を上げた。S8-30 が潰した「錨が腐って製品の赤に化ける」型を、この対照は
#      **腐った時に測れていないと言う**形で持っている。緑にも赤にも化けない事が肝。
probe "側Aの入力が痩せて、或る枝の鍵が一度も出なくなる" "$TESTF" \
    '  choice: { head: ["h"], options: [{ n: 1, label: "a" }], keys: ["digit", "enter", "escape"], digest: "d", cursor: 1, kind: "select-model" },' \
    '  choice: null,'

# ⑧ builder の原文を切り出す錨が外れる。原文が読めなければ②(実行と原文の突き合わせ)は
#    比べる物ゼロになる —— 黙って飛ばさず赤で言う事の確認。
probe "builder の原文を切り出す錨が外れる" "$VIEW" \
    "export function routeLabel(" \
    "export  function routeLabel("

# ⑨ 単値 extension の宣言表が腐る。**部分集合ではなく一致**で測っている事の確認で、
#    片方向(表に居るのに本物には無い)を植える。
probe "単値 extension の宣言表が本物とズレる" "$TESTF" \
    '  "GapWhy",' \
    '  "GapWhyRenamed",'

# ⑩ 「測っていない」と書いた型の名前が腐る。理由を書いた側が本物と結び付いていなければ、
#    `UNPAIRED` は**名簿ではなく作文**になる。
probe "測っていない型の名前が本物とズレる" "$TESTF" \
    '
  RecoveryCode: ' \
    '
  RecoveryCodeRenamed: '

# ⑲ ★引数を分解する builder(`function f({ a, b })`)から明示の目印を外す。既定の目印の
#    直後に来る `{` は**引数の分解**なので、原文からは鍵が0件しか読めない —— ②は
#    「原文に鍵が無い」と読んで静かに緑になる。0件を赤と言えているかを此処で測る。
probe "引数を分解する builder の明示の目印が外れる" "$TESTF" \
    'sessionsBody: ["wire", "src/wire.mjs", "export function sessionsBody({ sessions, scan, paneFault }) {"],' \
    'sessionsBody: ["wire", "src/wire.mjs"],'

# ⑳ ★封筒を純関数へ出した意味そのもの。ハンドラが直書きへ戻れば、11組の照合は
#    **全部飾りになる**(検査は builder を測り、線に出るのは別物)。server.mjs は
#    import した瞬間 listen するので実行では捕まらない —— 原文の錨だけが此処を守る。
probe "ハンドラが封筒を直書きへ戻す(builder を通らなくなる)" "$SERVER" \
    "json(res, 200, sessionsBody({ sessions: listing, scan: scanBody, paneFault }));" \
    "json(res, 200, { sessions: listing, scan: scanBody, paneFault });"

echo
echo "== 正しい変更は赤にしない(陰性対照) =="

# Ⓐ ★此の対照の背骨。両側**揃えて** `headline` を `title` へ改名する。これは本番が
#   実際に取り得る正しい木なので、緑でなければならない。赤い検査は鍵名を今日の姿に
#   固定し、正しく直す人が「検査が通らない」で諦める —— S8-19 の初版で私が踏んだ形。
/usr/bin/python3 - "$WORK" <<'PYEOF'
import sys, io, os
work = sys.argv[1]
edits = {
    "rc-backend/src/blocked.mjs": [("headline:", "title:")],
    "ios/Sources/Core/SessionsModels.swift": [
        ("            let headline: String", "            let title: String"),
    ],
}
for rel, pairs in edits.items():
    p = os.path.join(work, rel)
    s = io.open(p, encoding="utf-8").read()
    for frm, to in pairs:
        s = s.replace(frm, to)
    io.open(p, "w", encoding="utf-8").write(s)
PYEOF
if run_suite; then
    echo "  PASS  両側そろえて鍵名を改名するのは緑のまま"
    PASS=$((PASS + 1))
else
    echo "  FAIL  揃えた改名を赤にした = 鍵名を今日の姿に固定している"
    FAIL=$((FAIL + 1))
    /usr/bin/tail -12 "$WORK/out.txt"
fi
restore_from_root "$BLOCKED"
restore_from_root "$SESSM"

# Ⓑ 縛っているのは**鍵名**であって Swift の property 名ではない。`CodingKeys` が
#   在る型は property を自由に改名できる —— 此処を赤にすると、電話の中だけの言い換えが
#   出来なくなる(境界は1文字も動いていないのに)。
probe_green() {
    local name="$1"
    local file="$2"
    local from="$3"
    local to="$4"
    if ! mutate "$file" "$from" "$to"; then
        echo "  UNMEASURED  $name  —— 錨が1箇所に定まらない"
        UNMEASURED=$((UNMEASURED + 1))
        [ -f "$WORK/$file.orig" ] && restore "$file"
        return
    fi
    if run_suite; then
        echo "  PASS  $name  —— 緑のまま"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name  —— 赤にした = 境界でない物まで縛っている"
        FAIL=$((FAIL + 1))
        /usr/bin/tail -12 "$WORK/out.txt"
    fi
    restore "$file"
}

probe_green "CodingKeys が在る型の property 名だけ改名する" "$POLLM" \
    "    let show: Bool" \
    "    let visible: Bool"

# Ⓒ 鍵を持たない型(単値 extension の相手)が1つ増えるのは正当。分割の対象外なので
#   名簿に足す必要は無い —— 此処を赤にすると、enum を足すたびに検査を書き足す事になる。
NEWENUM="ios/Sources/Core/InventedForControlEnum.swift"
cat >"$WORK/$NEWENUM" <<'SWIFTEOF'
// 対照が植えた作り物。鍵を持たない(単値で復号する)新しい型の代わり。
enum InventedForControlTone: String, Decodable {
    case quiet
}
SWIFTEOF
if run_suite; then
    echo "  PASS  鍵を持たない型が1つ増えても緑"
    PASS=$((PASS + 1))
else
    echo "  FAIL  鍵を持たない型まで名簿を要求した = enum を足すたびに赤が出る"
    FAIL=$((FAIL + 1))
    /usr/bin/tail -12 "$WORK/out.txt"
fi
/bin/rm -f "$WORK/$NEWENUM"

# Ⓓ 行の鍵を**生産者3本と電話の宣言を全部そろえて**改名する。行は生産者が分かれているので、
#   Ⓐ(2 file)より1段きつい陰性対照になる —— 1本でも直し忘れれば赤が正しい。
#   全部そろえた木は本番が実際に取り得るので、緑でなければ「鍵名を今日の姿に固定」した検査。
/usr/bin/python3 - "$WORK" <<'PYEOF'
import sys, io, os
work = sys.argv[1]
edits = {
    "rc-backend/src/sessions.mjs": [
        ("      title: resolveTitle(e.meta, e.sessionId, titles[e.sessionId]),", "      heading: resolveTitle(e.meta, e.sessionId, titles[e.sessionId]),"),
        ('    title: "(読めない)",', '    heading: "(読めない)",'),
    ],
    "rc-backend/src/registry.mjs": [('title: "新しいセッション",', 'heading: "新しいセッション",')],
    "ios/Sources/Core/SessionsModels.swift": [("    let title: String", "    let heading: String")],
}
for rel, pairs in edits.items():
    p = os.path.join(work, rel)
    s = io.open(p, encoding="utf-8").read()
    for frm, to in pairs:
        if s.count(frm) != 1:
            sys.stderr.write("anchor not unique: %s / %s\n" % (rel, frm))
            sys.exit(3)
        s = s.replace(frm, to)
    io.open(p, "w", encoding="utf-8").write(s)
PYEOF
if [ $? -ne 0 ]; then
    echo "  UNMEASURED  行の鍵を両側そろえて改名  —— 錨が1箇所に定まらない"
    UNMEASURED=$((UNMEASURED + 1))
elif run_suite; then
    echo "  PASS  行の鍵を生産者3本と電話でそろえて改名するのは緑のまま"
    PASS=$((PASS + 1))
else
    echo "  FAIL  そろえた改名を赤にした = 行の鍵名を今日の姿に固定している"
    FAIL=$((FAIL + 1))
    /usr/bin/tail -12 "$WORK/out.txt"
fi
restore_from_root "$SESSJS"
restore_from_root "$REGJS"
restore_from_root "$SESSM"

# Ⓔ 縛っているのは `serverOnly` の**集合**であって並び順ではない。順を要求すると、
#   鍵を1本足す人が「吐く順に並べ直す」まで赤を見る事になり、宣言が保守されなくなる。
probe_green "serverOnly の並び順だけを入れ替える" "$TESTF" \
    '    serverOnly: ["project", "cwd", "lastPrompt", "turns", "metadataIncomplete", "readable", "errorCode", "live"],' \
    '    serverOnly: ["live", "errorCode", "readable", "metadataIncomplete", "turns", "lastPrompt", "cwd", "project"],'

# Ⓕ ★履歴の外側の鍵を**両側そろえて** `history` → `entries` へ改名する(㉗ の相方)。
#   電話側で動かすのは `CodingKeys` の1行**だけ**で、Swift の property は `history` の
#   ままにする —— これが此の対照の眼目。境界に在るのは線の鍵名であって Swift の名前ではない
#   ので、`case history = "entries"` と書いた木は**本番が取り得る正しい形**であり、
#   緑でなければならない。`init(from:)` が `forKey: .history` を引き続き引けるので
#   木は壊れない(Ⓑ の「property だけ改名」を、線の側から挟んだ格好)。
/usr/bin/python3 - "$WORK" <<'PYEOF'
import sys, io, os
work = sys.argv[1]
edits = {
    "rc-backend/src/wire.mjs": [
        ("  return { history: entries.map(withWho), truncated };",
         "  return { entries: entries.map(withWho), truncated };"),
    ],
    "ios/Sources/Core/HistoryModels.swift": [
        ("        case history, truncated", '        case history = "entries", truncated'),
    ],
}
for rel, pairs in edits.items():
    p = os.path.join(work, rel)
    s = io.open(p, encoding="utf-8").read()
    for frm, to in pairs:
        if s.count(frm) != 1:
            sys.stderr.write("anchor not unique: %s / %s\n" % (rel, frm))
            sys.exit(3)
        s = s.replace(frm, to)
    io.open(p, "w", encoding="utf-8").write(s)
PYEOF
if [ $? -ne 0 ]; then
    echo "  UNMEASURED  履歴の鍵を両側そろえて改名  —— 錨が1箇所に定まらない"
    UNMEASURED=$((UNMEASURED + 1))
elif run_suite; then
    echo "  PASS  履歴の鍵を CodingKeys の側でそろえて改名するのは緑のまま"
    PASS=$((PASS + 1))
else
    echo "  FAIL  そろえた改名を赤にした = Swift の property 名まで境界と読んでいる"
    FAIL=$((FAIL + 1))
    /usr/bin/tail -12 "$WORK/out.txt"
fi
restore_from_root "$WIRE"
restore_from_root "$HISTM"

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

# 親が本物のまま木の外だけ消える形は**飛ばしではなく赤**でなければならない。
# `requireOutside` の三値(測った / 測っていない / 赤)が2値へ潰れていないかを此処で見る。
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
echo "== 対象が消えたら赤(改名・削除を素通りさせない) =="
for gone in "$POLLM" "$SESSM" "$RESULTD" "$HISTM" "$HEALTHM" "$VIEW" "$BLOCKED" \
            "$WIRE" "$SESSJS" "$REGJS" "$SERVER"; do
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
