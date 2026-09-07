// interrupt-choice-honesty.test.mjs — 選択画面(許可の確認 / メニュー)が出ている pane への割り込みは**何も押さない**(2026-09-07 round 11)。
//
// 何が危なかったか: `#interruptExclusive` は overlay(panel / detail)は見る様になった(round 10)が、CHOICE は見ずに Escape を
//   打っていた。選択画面での Escape は**メニューへの答え**(許可の確認なら「断る」)であって割り込みではない。電話は許可の確認に
//   答えない(対照表 #17 の裁定)し、良性のメニューに答える口は指紋つきの `choice` 経路だけ(#18)。
// 守る物: CHOICE では send-keys が 0 回、`stopped:null` / `reason:"choice-open"`、電話の文は「何も押していない」と言う。
// 対照: 選択画面でない生成中の画面では従来どおり Escape を打つ。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { TmuxInjector, classifyScreen } from "../src/inject.mjs";
import { interruptResult } from "../src/view.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const screenFx = (n) => readFileSync(join(HERE, "fixtures", "screens", `${n}.txt`), "utf8");
const PERMISSION = screenFx("choice-permission-bash");
const MODEL_MENU = screenFx("choice-model-menu");
const DANGER = screenFx("choice-danger-menu");

const paneLine = "%1\t2.1.263\t/dev/ttys001\t/Users/athenas/Athenas\n";
function fakeTmux(frames) {
  const calls = []; let n = 0;
  const run = (args) => {
    calls.push(args);
    if (args[0] === "capture-pane") { const f = frames[Math.min(n, frames.length - 1)]; n++; return f; }
    if (args[0] === "list-panes") return paneLine;
    return "";
  };
  return { calls, run, runStrict: run, captures: () => n };
}
const sends = (t) => t.calls.filter((c) => c[0] === "send-keys").map((c) => c[c.length - 1]);
const inj = (t) => new TmuxInjector({ tmux: t, echoBudgetMs: 50, interruptBudgetMs: 200, sleep: async () => {} });

test("実画面 3 枚は CHOICE と読める(許可の確認 / model メニュー / 危険なメニュー)", () => {
  for (const s of [PERMISSION, MODEL_MENU, DANGER]) assert.equal(classifyScreen(s).state, "CHOICE");
});

test("★許可の確認が出ている pane への割り込み: 何も押さない(send-keys 0 回)、stopped=null / reason=choice-open", async () => {
  const t = fakeTmux([PERMISSION]);
  const r = await inj(t).interrupt("%1");
  assert.deepEqual(sends(t), [], "Escape は許可の確認への答えになる。打ってはいけない");
  assert.equal(r.stopped, null);
  assert.equal(r.reason, "choice-open");
  assert.equal(r.waited, 0);
});

test("メニュー(model / 危険)でも同じ: 押さない", async () => {
  for (const s of [MODEL_MENU, DANGER]) {
    const t = fakeTmux([s]);
    const r = await inj(t).interrupt("%1");
    assert.deepEqual(sends(t), []);
    assert.equal(r.reason, "choice-open");
  }
});

test("対照: 選択画面でない生成中の画面では従来どおり Escape を打つ(verified まで行く)", async () => {
  const t = fakeTmux([screenFx("generating"), screenFx("edith-interrupted")]);
  const r = await inj(t).interrupt("%1");
  assert.deepEqual(sends(t), ["Escape"]);
  assert.equal(r.stopped, "verified");
});

test("電話の文: 何も押していないと言い、答える場所を言う。『止めた』とは言わない", () => {
  const d = interruptResult(200, { interrupted: false, stopped: null, reason: "choice-open", waitedMs: 0, route: "tmux", pane: "%1" });
  assert.equal(d.kind, "warn");
  assert.match(d.text, /pressed nothing/i);
  assert.match(d.text, /would answer it/i, "何故押さないかを言う(Codex #2)");
  assert.match(d.text, /on the Mac/);
  assert.doesNotMatch(d.text, /Stopped \(/);
  // 対照: 従来の null(not-in-flight)の文は変えていない
  const old = interruptResult(200, { interrupted: false, stopped: null, reason: "not-in-flight", waitedMs: 900, route: "tmux", pane: "%1" });
  assert.match(old.text, /Nothing was running to stop/);
});

test("★server の封筒: interrupted は verified の時だけ true(choice-open は stopped:null なので false)", () => {
  const src = readFileSync(join(HERE, "..", "src", "server.mjs"), "utf8");
  assert.ok(src.includes('interrupted: out.stopped === "verified",'));
});


test("★順序(Codex #6): /tasks の overlay が開いている画面は choice-open ではなく overlay-closed(overlay の判定が先)", async () => {
  const panelFx = (n) => readFileSync(join(HERE, "fixtures", "panel", `${n}.txt`), "utf8");
  const t = fakeTmux([panelFx("friday-panel-open"), panelFx("friday-after-esc1")]);
  const r = await inj(t).interrupt("%1");
  assert.equal(r.stopped, "overlay-closed");
  assert.equal(r.reason, "panel");
});
