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
import { routeLabel, choiceView } from "../src/view.mjs";
import { REPO, requireOutside } from "./subtree.mjs";

const FIXTURE = "ios/Sources/Core/SessionsListingFixture.swift";
const POLL_FIXTURE = "ios/Sources/Core/PollFixture.swift";
const outside = requireOutside([FIXTURE, POLL_FIXTURE]);

/**
 * 種類ごとに `routeLabel` へ渡す入力。**期待値は書かない** —— 書いた瞬間に本番の文言の
 * 写しが1枚増える。ここに在るのは入力だけで、正解は毎回 `routeLabel` に作らせる。
 */
const INPUTS = {
  choice: [
    { route: "tmux", screen: "CHOICE" },
    { route: "tmux", screen: "CHOICE", limited: true },
  ],
  tmux: [
    { route: "tmux", work: "observed", screen: "MAIN" },
    { route: "tmux", work: "quiet", windowMs: 90_000, screen: "MAIN" },
    { route: "tmux", work: "quiet", windowMs: 0, screen: "MAIN" },
    { route: "tmux", screen: "MAIN" }, // work も activity も無い = 状態不明
    { route: "tmux", work: "observed", screen: "MAIN", limited: true },
    { route: "tmux", work: "quiet", windowMs: 90_000, screen: "MAIN", limited: true },
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
    return { options, buttons, digest: d[1], reason: reason ? reason[1] : null };
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
