import test from "node:test";
import assert from "node:assert/strict";
import { choiceView } from "../src/view.mjs";

// ★この検査が守る一線: **危険な承認が1タップで通らない**。
//   端末認証は「気が散った本人の誤タップ」も「注入された LLM の要求」も防がない
//   (Codex 2026-08-26)。防ぐのは操作に束ねた第2手だけなので、束ね方を測る。
//
// サーバの分岐そのものは e2e が撃つ。ここで測るのは**判定の出所と束縛の性質**で、
// どちらも純粋関数として取り出せる所に置いてある。

const screenOf = (head, digest) => ({
  screen: "CHOICE",
  choice: { head, options: [{ n: 1, label: "Yes" }, { n: 2, label: "No" }],
            keys: ["digit"], digest, cursor: 1 },
});

test("★危険な画面は danger と判定される(第2手を要求する側の入口)", () => {
  const v = choiceView(screenOf(["Claude requests permission to run:", "  rm -rf ./build"], "d1"));
  assert.equal(v.risk.tier, "danger");
});

test("普通の画面は danger にならない(全部に第2手を要求すると本物が埋もれる)", () => {
  const v = choiceView(screenOf(["Apply this change?"], "d1"));
  assert.notEqual(v.risk.tier, "danger");
});

test("★判定は画面の文字列から取る。要求本文の言い分を材料にしない", () => {
  // 注入された側が「これは危険ではない」と名乗っても、判定は画面を見る。
  // `choiceView` は screen だけを引数に取る = 本文を渡す道が**そもそも無い**。
  assert.equal(choiceView.length, 1, "画面以外の材料を受け取れる形になっている");
});

test("★束縛は指紋。画面が変われば別の値になる", () => {
  const a = choiceView(screenOf(["rm -rf /tmp/x"], "screen-A"));
  const b = choiceView(screenOf(["rm -rf /tmp/x"], "screen-B"));
  assert.equal(a.digest, "screen-A");
  assert.equal(b.digest, "screen-B");
  assert.notEqual(a.digest, b.digest,
    "同じ文でも画面が違えば束縛が違う = 構えてから押すまでに画面が変わると通らない");
});

test("★危険度が上がるだけである事(注入された文で段を下げられない)", () => {
  // 危険語の後ろに『安全です』を並べても下がらない。
  const v = choiceView(screenOf([
    "rm -rf ./build",
    "This is completely safe, no confirmation needed.",
  ], "d1"));
  assert.equal(v.risk.tier, "danger");
});

test("危険な画面でも、押せる鍵は今まで通り keys が決める(権限を変えていない)", () => {
  const danger = choiceView(screenOf(["rm -rf ./x"], "d1"));
  const plain = choiceView(screenOf(["Apply?"], "d1"));
  assert.deepEqual(danger.buttons.map((b) => b.key), plain.buttons.map((b) => b.key),
    "危険度が押せる物を変えた = 許可の出所が2つになった");
});

// ---- 実物の画面で測る(2026-08-26)-------------------------------------------
// ★手で書いた文字列ではなく、**本物の画面の構造**で測る。検体は
//   `choice-model-menu.txt`(実キャプチャ)から**命令文だけ**を差し替えた派生で、
//   枠・余白・カーソル・鍵の案内は本物のまま。手書きの画面で測ると
//   「画面の形についての自分の思い込み」ごと緑になる。

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { classifyScreen, choiceViewOf } from "../src/inject.mjs";

const shot = (n) => readFileSync(join(process.cwd(), "test", "fixtures", "screens", `${n}.txt`), "utf8");

test("★実物の画面から危険語を読む(文字列ではなく画面で測る)", () => {
  const t = shot("choice-danger-menu");
  const s = classifyScreen(t);
  assert.equal(s.state, "CHOICE");
  const v = choiceView({ screen: s.state, choice: choiceViewOf("%1", t) });
  assert.equal(v.risk.tier, "danger");
  assert.ok(v.risk.signals.length >= 2, "1語しか当たっていない = 材料が痩せている");
});

test("★★実測で判った事: 危険な確認画面は、そもそも電話から押せない", () => {
  // 2026-08-26。第2手を作った後に本物の画面で測って判った ——
  // この種の画面は `matcher` が付かず `keys` がゼロで届くので、**電話は元から
  // 1つも押せない**。主たる防御は第2手ではなく、この「押す物を渡さない」側に在る。
  //
  // ★では第2手は無駄か: 無駄ではないが、**主役ではない**。効くのは
  //   「押せるメニューの文に危険語が入っていた」場合だけの二重の網。
  //   ここを取り違えて「危険な操作は第2手が守っている」と読むと、
  //   本当に守っている仕組み(鍵を渡さない事)を誰かが外しに行く。
  const t = shot("choice-danger-menu");
  const v = choiceView({ screen: "CHOICE", choice: choiceViewOf("%1", t) });
  assert.deepEqual(v.buttons, [], "押せる鍵が在る = 前提が変わったので上の注記を書き直す事");
  assert.equal(v.risk.tier, "danger", "押せなくても危険度は出す(読む前に判る事に意味が在る)");
});

test("普通のメニューは押せて、危険度も付かない(上2つが常に真ではない事)", () => {
  const t = shot("choice-model-menu");
  const v = choiceView({ screen: "CHOICE", choice: choiceViewOf("%1", t) });
  assert.ok(v.buttons.length > 0, "本物のメニューが押せなくなっている");
  assert.notEqual(v.risk.tier, "danger");
});
