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
import { routeLabel } from "../src/view.mjs";
import { REPO, requireOutside } from "./subtree.mjs";

const FIXTURE = "ios/Sources/Core/SessionsListingFixture.swift";
const outside = requireOutside([FIXTURE]);

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
