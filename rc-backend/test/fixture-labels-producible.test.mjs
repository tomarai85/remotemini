// 電話の一覧 fixture に書かれている札を、サーバが**実際に出せる**か。
//
// 何を守るか:
//   一覧の見た目を確かめる手段は `RC_UI_FIXTURE=list-normal` の撮影で、そこに並ぶ5行の
//   `short` / `text` は `SessionsListingFixture.swift` に**手で書いてある**。本番の同じ
//   文字列を作るのは `src/view.mjs` の `routeLabel` で、両者を突き合わせる物は無かった。
//
// 実測(2026-08-08、これを書いた理由):
//   R2-2 を測っている最中に、一覧の札が `ワーカー・busy` と内部トークンを生で出して
//   いるのが出て来た。ところが fixture の worker 行は `ワーカー・実行中` と**日本語**で、
//   `ワーカーが実行中` という production に存在しない語形まで持っていた。
//   つまり画面を何度見ても `busy` は一度も出て来ない —— **fixture の方が本番より綺麗な
//   文字列を出していたので、この欠陥は目視では原理的に見つからなかった**。
//   数えたら5行中2行(tmux / worker)が production に作れない文字列だった。
//
//   これは「答えを書き込んだ fixture は何も証明しない」の一種だが、質が悪い方の形:
//   偽の値で緑になるのではなく、**偽の値で綺麗に見える**。撮影は成功し、見直しは通り、
//   直すべき物だけが見えない。
//
// ★**一致ではなく所属**を見る(初版の設計を捨てた理由、同日中に実測):
//   最初は種類ごとに代表を1つ決めて「それとバイト一致」を要求した。それで blocked 行の
//   `送れない` / `宛先を確定できません。` が赤くなり、fixture が間違っていると読んで
//   書き換えかけた —— が、`routeLabel` はその文字列を**実際に出す**(`tmux-missing` 等、
//   `BLOCKED_TAG` に個別の札を持たない理由の既定形)。赤かったのは fixture ではなく
//   代表の選び方だった。正しい形の物を落とす検査は、それ自体が次の事故になる。
//   なので此処は「その種類で `routeLabel` が出しうる (short, text) の集合に居るか」を見る。
//
//   代償: 下の `INPUTS` は**網羅ではなく点検用の列挙**である。新しい入力形(新しい
//   `reason`、`N秒 動く印なし` の別の N)を使う行を fixture に足すと、その入力を此処へ
//   足すまで赤くなる。赤の本文は出しうる集合を全部印字するので、足す先はすぐ分かる。
//   「知らない物を黙って通す」より「知らない物で止まって名前を訊く」を選んでいる。
//
// 取らなかった道: Swift 側から JSON を生成して突き合わせる。xcodebuild が要るので commit の
//   門に置けない(数分待つ)。此処は文字列の照合なので node で足りる。
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { routeLabel, choiceView, whoOf } from "../src/view.mjs";
import { paneFaultReason, paneFaultView } from "../src/blocked.mjs";
import { REPO, requireOutside } from "./subtree.mjs";
import { stripSwiftComments } from "./swiftsrc.mjs";

const FIXTURE = "ios/Sources/Core/SessionsListingFixture.swift";
const POLL_FIXTURE = "ios/Sources/Core/PollFixture.swift";
const FAULT_UITEST = "ios/UITests/RemoteMiniUITests.swift";
const HISTORY_FIXTURE = "ios/Sources/Core/HistoryFixture.swift";
const outside = requireOutside([FIXTURE, POLL_FIXTURE, FAULT_UITEST, HISTORY_FIXTURE]);

/**
 * 種類ごとに `routeLabel` へ渡す入力。**期待値は書かない** —— 書いた瞬間に本番の文言の
 * 写しが1枚増える。ここに在るのは入力だけで、正解は毎回 `routeLabel` に作らせる。
 */
const INPUTS = {
  choice: [
    { route: "tmux", screen: "CHOICE" },
    { route: "tmux", screen: "CHOICE", limited: true },
  ],
  // ★`screen` は 2026-08-09 まで `"MAIN"` だった。`routeLabel` の tmux 枝は `=== "CHOICE"`
  //   しか見ず、それ以外は `v.screen || ""` と素通しするので、**此の検査が見ている
  //   (short, text) には一切効かない** = 6行とも緑のままだった。効かない欄に
  //   `classifyScreen` が返さない綴りが置ける事が問題で、実際に
  //   `SessionsListingFixture.swift` へ写って「線に出る値」の顔をした
  //   (`test/wire-vocabulary-agreement.test.mjs` が捕まえた1件)。
  //   分類器が返すのは `SENDABLE` / `CHOICE` / `UNKNOWN` の3つだけ
  //   (`src/inject.mjs` の `classifyScreen()`)。
  //   入力表に「入力として在りうる物」以外を置かない、を此処でも守る。
  tmux: [
    { route: "tmux", work: "observed", screen: "SENDABLE" },
    { route: "tmux", work: "quiet", windowMs: 90_000, screen: "SENDABLE" },
    { route: "tmux", work: "quiet", windowMs: 0, screen: "SENDABLE" },
    { route: "tmux", screen: "UNKNOWN" }, // work も activity も無い = 状態不明
    { route: "tmux", work: "observed", screen: "SENDABLE", limited: true },
    { route: "tmux", work: "quiet", windowMs: 90_000, screen: "SENDABLE", limited: true },
  ],
  worker: [
    { route: "worker", state: "busy" },
    { route: "worker", state: "ready" },
    { route: "worker", state: "idle" },
    { route: "worker" }, // state が無い = 素の「ワーカー」
    { route: "worker", state: "busy", limited: true },
    { route: "worker", state: "idle", limited: true },
    { route: "worker", state: "idle", errored: true },
  ],
  // `reason` の語彙は pane 解決の層が決める物で、此の file が正本ではない(上の但し書き)。
  blocked: [
    "ambiguous", "unregistered", "stale", "cwd-mismatch",
    "pane-gone", "not-claude", "panes-unreadable", "tmux-unavailable",
    "tmux-missing", undefined,
  ].map((reason) => ({ route: "blocked", reason })),
  unknown: [{ route: "nonesuch" }],
};

/** その種類で出しうる (short, text) の集合。 */
function producible(kind) {
  return (INPUTS[kind] || [])
    .map((input) => routeLabel(input))
    .filter((l) => l.kind === kind)
    .map((l) => `${l.short} ||| ${l.text}`);
}

/** `row(id: …, kind: .worker, short: "…", text: "…", screen: "…")` を1行ずつ拾う。 */
function fixtureRows(src) {
  const out = [];
  const re = /kind:\s*\.(\w+)\s*,\s*short:\s*"([^"]*)"\s*,\s*\n?\s*text:\s*"([^"]*)"/g;
  let m;
  while ((m = re.exec(src)) !== null) out.push({ kind: m[1], short: m[2], text: m[3] });
  return out;
}

test("★一覧 fixture の札は、サーバが実際に出せる物である", { skip: outside.skip }, () => {
  const src = readFileSync(join(REPO, FIXTURE), "utf8");
  const rows = fixtureRows(src);

  // ★錨。この木では逃げ道を通っていない事を、飛ばしと区別できる形で言う
  //   (`subtree.mjs` の契約)。0行を「全部一致」と読ませない。
  assert.ok(rows.length >= 5, `fixture の行を拾えていない(${rows.length} 行しか読めていない)`);

  for (const row of rows) {
    const set = producible(row.kind);
    assert.ok(set.length > 0, `種類 .${row.kind} の入力が決まっていない(INPUTS に足す)`);
    const got = `${row.short} ||| ${row.text}`;
    assert.ok(set.includes(got),
      `.${row.kind} の札を routeLabel は出せない(fixture だけが綺麗に見える)\n` +
      `  fixture : ${got}\n` +
      `  出しうる: \n    ${set.join("\n    ")}`);
  }
});

// ────────────────────────────────────────────────────────────────────────────
// 会話画面の選択カード。上と**同じ問い**を別の fixture に当てる:
// 「この Swift に手で書いた文字列を、サーバは実際に出せるか」。
//
// 実測(2026-08-08、S8-20):
//   `PollFixture.swift` の benign な選択カードは `中止(Escape)` というボタンを持っていた。
//   この文字列は rc-backend の何処にも無い —— 本番の escape は `CHOICE_KEY_LABEL` の
//   生の `Escape` 一語である。電話は `Text(button.label)` で札をそのまま描くので、
//   撮った画面に出ていた `中止(Escape)` は**一度も存在した事が無い**。
//   しかも Sprint 7 に「画面を見て」直した割り込みの注意文は、この実在しないボタンを
//   指していた —— 見た目で見つけた欠陥を、見た目の嘘の上で直していた事になる。
//
// 上と違って「種類ごとの入力表」を持たないのは、選択カードは fixture 自身が入力
// (`options` / `digest` / どの鍵を許したか)を全部書いている為。だから期待値どころか
// 入力も此処には書かず、**fixture の入力をサーバへ通し直して**出て来た物と比べる。

/** `ChoiceView( … digest: "…" )` を1枚ずつ。`digest` が最後の項なので其処で切る。 */
function choiceBlocks(src) {
  const parts = src.split("ChoiceView(");
  parts.shift(); // 先頭 = 1枚目より前の本文
  return parts.map((raw) => {
    const d = /digest:\s*"([^"]*)"/.exec(raw);
    if (!d) return null; // digest で閉じない = Swift 側の形が変わった
    const block = raw.slice(0, d.index + d[0].length);
    const options = [];
    const buttons = [];
    let m;
    const optRe = /ChoiceOption\(n:\s*(\d+),\s*label:\s*"([^"]*)"\)/g;
    while ((m = optRe.exec(block)) !== null) options.push({ n: Number(m[1]), label: m[2] });
    const btnRe = /ChoiceButton\(key:\s*"([^"]*)",\s*label:\s*"([^"]*)"\)/g;
    while ((m = btnRe.exec(block)) !== null) buttons.push({ key: m[1], label: m[2] });
    const reason = /reason:\s*"([^"]*)"/.exec(block);
    // ★危険度も拾う(2026-08-26)。fixture は `ChoiceRisk(...)` を**直値**で持つので、
    //   放っておけば必ずサーバから乖離する。乖離した瞬間、fixture で撮った画は
    //   「製品がこう見える」の証拠にならなくなる —— 8/16 に踏んだ「撮影器が製品を
    //   映していなかった」と同じ形。だから此処で拾い、下で `classifyRisk` と突き合わせる。
    //   ★`digest:` より後ろに在るので、block ではなく raw の当該範囲から取る。
    const after = raw.slice(d.index);
    const rk = /ChoiceRisk\(\s*tier:\s*"([^"]*)",\s*notice:\s*"([^"]*)"/.exec(after);
    const sigIds = [];
    const sigRe = /ChoiceRiskSignal\(id:\s*"([^"]*)",\s*why:\s*"([^"]*)"\)/g;
    if (rk) {
      const scope = after.slice(0, rk.index + 2000);
      let sm;
      while ((sm = sigRe.exec(scope)) !== null) sigIds.push({ id: sm[1], why: sm[2] });
    }
    // ★`head` も拾う。危険度の材料そのものなので、これが無いと突き合わせが成立しない。
    const headBlock = /head:\s*\[([^\]]*)\]/.exec(block);
    const head = [];
    if (headBlock) {
      let hm; const hRe = /"([^"]*)"/g;
      while ((hm = hRe.exec(headBlock[1])) !== null) head.push(hm[1]);
    }
    return { head, options, buttons, digest: d[1], reason: reason ? reason[1] : null,
             risk: rk ? { tier: rk[1], notice: rk[2], signals: sigIds } : null };
  });
}

/**
 * その入力でサーバが出しうるボタン列(JSON 文字列)の集合。
 *
 * カーソル位置だけは fixture が持っていない(Swift の `ChoiceView` に其の項が無い)。
 * 決め打ちで補うと「fixture の書いた答えを読んでいる」形になるので、**在りうる位置を
 * 全部サーバに通して集合を作る**。上の一覧と同じ「一致ではなく所属」。
 */
function producibleButtons(options, keys, digest) {
  return [undefined, ...options.map((o) => o.n)].map((cursor) =>
    JSON.stringify(choiceView({ screen: "CHOICE", choice: { head: [], options, keys, digest, cursor } }).buttons));
}

/** 断り文の出しうる集合。`CHOICE_BLOCKED` は export されていないので関数に作らせる。 */
function producibleReasons() {
  const c = { head: [], options: [], keys: [], digest: "d" };
  return [
    "", // 押せる画面 = 断らない
    choiceView({ screen: "CHOICE", choice: { ...c, kind: "hard-stop" } }).reason,
    choiceView({ screen: "CHOICE", choice: { ...c, kind: "unrecognized" } }).reason,
    choiceView({ screen: "CHOICE", choice: { ...c, digest: "" } }).reason,
  ];
}

test("★会話 fixture の選択ボタンは、サーバが実際に出せる物である", { skip: outside.skip }, () => {
  const blocks = choiceBlocks(readFileSync(join(REPO, POLL_FIXTURE), "utf8"));

  // ★錨。0枚を「全部一致」と読ませない。ボタンを1つも持たない枚数で通るのも防ぐ ——
  //   断り画面(`buttons: []`)だけを見て緑になったら、此の検査は札を一度も見ていない。
  assert.ok(blocks.length >= 2, `ChoiceView を拾えていない(${blocks.length} 枚)`);
  assert.ok(blocks.every((b) => b !== null), "ChoiceView が digest で閉じていない(Swift の形が変わった)");
  assert.ok(blocks.some((b) => b.buttons.length > 0), "ボタンを持つ ChoiceView が1枚も無い(札を見ていない)");

  const reasons = producibleReasons();
  for (const b of blocks) {
    // 許した鍵の種別は fixture のボタンから起こす。`keys` の中身は種別語であって
    // `"1"`..`"9"` ではない(`choice.mjs` の `keyKind`)。
    const keys = [];
    if (b.buttons.some((x) => /^[1-9]$/.test(x.key))) keys.push("digit");
    for (const k of ["enter", "escape"]) if (b.buttons.some((x) => x.key === k)) keys.push(k);

    const sets = producibleButtons(b.options, keys, b.digest);
    const got = JSON.stringify(b.buttons);
    assert.ok(sets.includes(got),
      `選択ボタンをサーバは出せない(fixture だけが綺麗に見える)\n` +
      `  fixture : ${got}\n  出しうる:\n    ${sets.join("\n    ")}`);

    assert.ok(reasons.includes(b.reason),
      `断り文をサーバは出せない\n  fixture : ${b.reason}\n  出しうる:\n    ${reasons.join("\n    ")}`);
  }
});

// ────────────────────────────────────────────────────────────────────────────
// 一覧の**帯**(paneFault)。同じ問いの3面目だが、出る場所が一番悪い。
//
// 実測(2026-08-08、S8-22):
//   本番の帯は `paneFaultReason` の作る内部トークン(`panes-unreadable` /
//   `tmux-unavailable`)を**太字の見出し**に、`e.message` = 生の JS エラー文を本文に、
//   そのまま描いていた。旅程で一番踏みそうな画面(一覧が出ない)が日本語ですらない。
//   ところが fixture は `pane-scan-timeout` +「tmux ペインの走査がタイムアウトしました。」
//   —— 前者は `paneFaultReason` が**作れない語**、後者は本番が絶対に出さない綺麗な日本語。
//   撮った帯だけが読める日本語だったので、本番が英語である事は画面から分かりようがなかった。
//
//   もう一段悪いのは UI 検査の方で、`RemoteMiniUITests` は帯の文言を
//   「right phase, wrong words を捕まえる為」と明記して主張していた —— その主張の対象が
//   本番に存在しない2文だった。**検査が在り、走り、緑で、測っていた物が架空**。
//
// なので此処は UI 検査の主張する文字列も一緒に見る。fixture と検査を両方直せば黙って
// 揃ってしまう(#43 と同じ穴)ので、両方を**サーバの作る集合**へ突き合わせる。

/** `marker` から括弧の対応で閉じるまでを1つずつ。Swift の `\(…)` は文字列の中なので数えない。 */
function initBlocks(src, marker) {
  const out = [];
  let i = 0;
  while ((i = src.indexOf(marker, i)) !== -1) {
    let j = i + marker.length;
    let depth = 1;
    let inStr = false;
    while (j < src.length && depth > 0) {
      const ch = src[j];
      if (inStr) {
        if (ch === "\\") j++;
        else if (ch === '"') inStr = false;
      } else if (ch === '"') inStr = true;
      else if (ch === "(") depth++;
      else if (ch === ")") depth--;
      j++;
    }
    out.push({ text: src.slice(i + marker.length, j - 1), closed: depth === 0 });
    i = j;
  }
  return out;
}

/** 名前で関数の本体を切り出す(UI 検査の1本だけを見る為)。 */
function swiftFuncBody(src, name) {
  const at = src.indexOf(`func ${name}(`);
  if (at === -1) return null;
  const open = src.indexOf("{", at);
  if (open === -1) return null;
  let j = open + 1;
  let depth = 1;
  while (j < src.length && depth > 0) {
    if (src[j] === "{") depth++;
    else if (src[j] === "}") depth--;
    j++;
  }
  return depth === 0 ? src.slice(open + 1, j - 1) : null;
}

test("★一覧の障害バナーは、サーバが実際に出せる文である", { skip: outside.skip }, () => {
  // 出しうる `reason` は**枝を呼んで作る**。2語を此処に書き写すと、本番の語彙の写しが
  // 1枚増えて S8-19 と同じ形になる。`paneFaultReason` は分岐が2つしか無い(test/blocked)。
  const reasons = [paneFaultReason({ code: "TMUX_UNAVAILABLE" }), paneFaultReason(new Error("x"))];
  assert.equal(new Set(reasons).size, 2, "paneFaultReason の枝が2つで無くなっている(此処の列挙を見直す)");
  const heads = reasons.map((r) => paneFaultView(r).headline);
  const bodies = reasons.map((r) => paneFaultView(r).body);

  const cards = initBlocks(readFileSync(join(REPO, FIXTURE), "utf8"), "paneFault: .init(");
  assert.equal(cards.length, 1, `fixture の paneFault を拾えていない(${cards.length} 枚)`);
  assert.ok(cards[0].closed, "paneFault の括弧が閉じない(Swift 側の形が変わった)");

  const card = cards[0].text;
  const reason = /reason:\s*"([^"]*)"/.exec(card);
  assert.ok(reason, "fixture の paneFault に reason が無い");
  assert.ok(reasons.includes(reason[1]),
    `paneFault の reason をサーバは作れない\n  fixture : ${reason[1]}\n  作れる  : ${reasons.join(" / ")}`);

  // `display` は帯に**描かれる**唯一の組。バイト一致を要求する —— `reason` が決まれば
  // 出る文は1組に決まるので、此処は所属ではなく一致でよい(上2つと違う所)。
  const headline = /headline:\s*"([^"]*)"/.exec(card);
  const body = /body:\s*"([^"]*)"/.exec(card);
  assert.ok(headline && body, "fixture の paneFault に display(headline / body)が無い");
  assert.equal(headline[1], paneFaultView(reason[1]).headline, "帯の見出しをサーバは出せない");
  assert.equal(body[1], paneFaultView(reason[1]).body, "帯の本文をサーバは出せない");

  // ★`detail` は**わざと縛らない**。本番の `detail` は `e.message` = 自由記述で、
  //   閉じた語彙が無いので「作れる集合」が存在しない。同じ理由で画面にも描かない
  //   (`test/wire-shape-controls.sh` は診断出力からも伏せている)。
  //   縛らない事を明示しておかないと、次に読む人が「拾い漏れ」と読んで足しに来る。
  assert.ok(/detail:\s*"/.test(card), "fixture の paneFault に detail が無い(鍵ごと消えている)");

  // UI 検査が主張している文字列も同じ集合で見る。
  const uiSrc = stripSwiftComments(readFileSync(join(REPO, FAULT_UITEST), "utf8"));
  const fn = swiftFuncBody(uiSrc, "testListPaneFaultShowsTheFaultBannerText");
  assert.ok(fn, "帯の UI 検査が見つからない(名前が変わったか消えた)");
  const asserted = [...fn.matchAll(/staticTexts\["([^"]*)"\]/g)].map((m) => m[1]);
  assert.equal(asserted.length, 2, `UI 検査が主張している文言が ${asserted.length} 本(見出しと本文の2本を期待)`);
  for (const s of asserted) {
    assert.ok(heads.includes(s) || bodies.includes(s),
      `UI 検査が本番に無い文言を主張している\n  検査: ${s}\n` +
      `  出しうる見出し: ${heads.join(" / ")}\n  出しうる本文: ${bodies.join(" / ")}`);
  }

  // ★更に、**この fixture が出す組**と一致していなければならない。
  //   producible なだけでは足りない —— `list-panefault` は `panes-unreadable` を出す面
  //   なのに、UI 検査が `tmux-unavailable` の文を主張していても上の輪は通ってしまう。
  //   それは実機で必ず落ちる検査で、落ちる理由が「本番の文言が悪い」ではなく
  //   「検査が別の面を見ている」——1本の UI 検査が撮る面は1つに決まっている。
  assert.deepEqual([...asserted].sort(), [headline[1], body[1]].sort(),
    `UI 検査の主張が fixture の出す組と違う\n  検査  : ${asserted.join(" | ")}\n` +
    `  fixture: ${headline[1]} | ${body[1]}`);
});

const WHO_MARK = "display: .init(who:";

/**
 * 手書きの `who` を1件ずつ拾う。**近い方の `role:` を後ろ向きに探す**のは、
 * `HistoryEntry(...)` の書き方が両 fixture で違う為(片方は1行、片方は複数行で
 * `text:` が関数呼び出し)。前から一気に正規表現で取ると、書き方の違う方が
 * **黙って0件**になる —— 拾えていない事が緑に見えるのが此の種の検査の一番の穴で、
 * だから下の検査は「拾えた数」ではなく **`who` の総数**を錨にしている。
 */
function whoSites(src) {
  const sites = [];
  let i = 0;
  while ((i = src.indexOf(WHO_MARK, i)) !== -1) {
    const before = src.slice(0, i);
    const roleRe = /role:\s*([^,\n]+),/g;
    let m;
    let last = null;
    while ((m = roleRe.exec(before)) !== null) last = m;

    const after = src.slice(i + WHO_MARK.length);
    const lit = /^\s*"([^"]*)"\)/.exec(after);
    const between = last ? before.slice(last.index) : "";
    const text = /text:\s*"([^"]*)"/.exec(between);

    sites.push({
      role: last ? last[1].trim() : null,
      who: lit ? lit[1] : null,   // null = 文字列リテラルで書かれていない(= 例外宣言が要る)
      text: text ? text[1] : null,
    });
    i += WHO_MARK.length;
  }
  return sites;
}

/**
 * リテラルで書けない `who` の宣言。**行番号ではなく式そのもの**で名指す ——
 * 行は動くが式は動かないし、式が動けば宣言が外れて総数が合わなくなり赤になる。
 * 免除ではなく「別の規則で測る」宣言である事に注意: 中の文字列は下で
 * whoOf の値域に属する事を要求される。
 */
const WHO_EXCEPTIONS = {
  [HISTORY_FIXTURE]: [
    'display: .init(who: role == .user ? "Tom" : "Claude")',
  ],
  [POLL_FIXTURE]: [],
};

test("★会話 fixture の発言者名は、サーバが role から作る名前と一致する", { skip: outside.skip }, () => {
  // 本番で `who` を作るのは `server.mjs` の1箇所だけ(whoOf(entry.role))で、
  // 電話は entry.display.who を逐語で描き role から作り直さない。つまり
  // fixture が本番の作れない名前を書けば、その名前がそのまま画面に出る ——
  // S8-19(札)/ S8-20(選択ボタン)/ S8-22(障害バナー)と同じ形の4面目。
  const PRODUCIBLE_WHO = new Set(["user", "assistant", "tool", "unknown"].map(whoOf));

  for (const rel of Object.keys(WHO_EXCEPTIONS)) {
    const src = readFileSync(join(REPO, rel), "utf8");
    const sites = whoSites(src);
    assert.ok(sites.length > 0, `${rel}: 手書きの who を1件も拾えていない(錨)`);

    const literal = sites.filter((s) => s.who !== null);
    const exceptions = WHO_EXCEPTIONS[rel];

    // 宣言そのものの健全さを先に見る。**総数の帳尻より前**に置くのは、宣言が
    // 腐った時に出てほしい言葉が「式が 0 箇所」であって「数が合わない」ではない為 ——
    // 後者を先に投げると、次の読み手は数を合わせにいって宣言の腐りを見落とす。
    for (const decl of exceptions) {
      const n = src.split(decl).length - 1;
      assert.equal(n, 1, `${rel}: 宣言した式が ${n} 箇所(1 でない)\n  ${decl}`);
      const inside = [...decl.matchAll(/"([^"]*)"/g)].map((x) => x[1]);
      assert.ok(inside.length > 0, `${rel}: 宣言した式に名前が無い\n  ${decl}`);
      for (const w of inside) {
        assert.ok(PRODUCIBLE_WHO.has(w),
          `${rel}: 宣言の中の名前をサーバは作れない\n  ${w}\n  作れる: ${[...PRODUCIBLE_WHO].join(" / ")}`);
      }
    }

    // ★総数の帳尻。新しい書き方の who が増えたら、照合も宣言もされないまま
    //   此処で赤になる —— 「拾えなかった物は無かった事にする」を塞ぐ唯一の場所。
    assert.equal(
      literal.length + exceptions.length, sites.length,
      `${rel}: who の書き方が増えている(全 ${sites.length} / 文字列 ${literal.length} / 宣言 ${exceptions.length})`
    );

    for (const s of literal) {
      assert.ok(s.role !== null, `${rel}: who の前に role が無い(who=${s.who})`);
      assert.ok(/^\.\w+$/.test(s.role),
        `${rel}: role が case で書かれていない(${s.role})—— 照合できないなら宣言側へ`);
      const wire = s.role.slice(1);
      assert.equal(s.who, whoOf(wire),
        `${rel}: 発言者名をサーバは作れない(role=${wire})\n  fixture: ${s.who}\n  本番   : ${whoOf(wire)}`);

      // 道具の行の本文は `sessions.mjs` の toolNames が作る形しか無い。
      // 名前だけ合っていても本文が別形なら、それは本番の出さない画面である。
      if (wire === "tool") {
        assert.ok(s.text !== null, `${rel}: 道具の行の本文が文字列で書かれていない`);
        assert.ok(s.text.startsWith("⚙ "),
          `${rel}: 道具の行の本文が本番の形でない\n  fixture: ${s.text}\n  本番   : ⚙ <道具名>`);
      }
    }
  }
});

test("★入力の列挙は5種類すべてを覆っている(種類が増えたら気付く)", () => {
  // 陽性の錨 —— 上の検査が fixture を1行も読めなかった日でも、此処は必ず何かを測る。
  // 入力が古くなって別の枝へ落ちていたら上の照合は無意味になるので、種類も一緒に見る。
  for (const kind of Object.keys(INPUTS)) {
    const set = producible(kind);
    assert.ok(set.length > 0, `.${kind} の入力が1つも その種類を作っていない(枝が動いた)`);
  }
  assert.equal(Object.keys(INPUTS).length, 5, "種類が増減している(fixture 側も見直す)");

  // ★集合が**広すぎない**事も見る。何でも通る集合は検査ではない ——
  //   実在しない札(起票時に fixture が出していた物)は、どの種類でも作れない。
  for (const kind of Object.keys(INPUTS)) {
    assert.ok(!producible(kind).includes("ワーカー・実行中 ||| ワーカーが実行中"),
      `.${kind} が起票時の偽の札まで出せる事になっている(集合が広すぎる)`);
  }
});

test("★fixture の危険度は、同じ文字列をサーバに食わせた答えと一致する", { skip: outside.skip }, () => {
  // なぜ要るか: `PollFixture.swift` の `ChoiceRisk(...)` は直値。直値は必ず古くなる。
  // 古くなった瞬間、fixture で撮った画は「製品がこう見える」の証拠でなくなる
  // (2026-08-16 に踏んだ「撮影器が製品を映していなかった」と同じ形)。
  // 語の一覧を此処に書き写すのではなく、**本物の分類器に同じ入力を通す**。
  const cards = choiceBlocks(readFileSync(join(REPO, POLL_FIXTURE), "utf8"))
    .filter(Boolean);
  assert.ok(cards.length > 0, "fixture のカードが1枚も読めていない");

  let checked = 0;
  for (const card of cards) {
    if (!card.risk) continue;                    // 危険度を書いていないカードは対象外
    checked++;
    const want = choiceView({
      screen: "CHOICE",
      choice: { head: card.head, options: card.options, keys: ["digit"],
                digest: card.digest || "d", cursor: 1 },
    }).risk;
    assert.equal(card.risk.tier, want.tier,
      `fixture の tier がサーバとズレた(head=${JSON.stringify(card.head)})`);
    assert.equal(card.risk.notice, want.notice, "fixture の notice がサーバとズレた");
    assert.deepEqual(card.risk.signals.map((x) => x.id).sort(),
                     want.signals.map((x) => x.id).sort(),
      "fixture の signals がサーバとズレた");
    for (const sig of card.risk.signals) {
      const server = want.signals.find((x) => x.id === sig.id);
      assert.equal(sig.why, server?.why, `signal ${sig.id} の説明文がズレた`);
    }
  }
  assert.ok(checked > 0, "★危険度を持つ fixture が1枚も無い = この検査は空振りしている");
});
