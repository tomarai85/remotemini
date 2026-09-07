// interrupt-overlay-honesty.test.mjs — 割り込みは、agent panel(`/tasks`)か其の詳細が開いていた時に**生成の判定を言わない**(2026-09-07)。
//
// 実機 friday 09:13(`.harness/evidence-2026-09-07/repro-shell-kill-screens.log` C→E): 詳細が開いた pane に `POST /interrupt` →
//   Escape は overlay を閉じただけで subagent は走り続けた(23s → 29s)のに、机は "Stopped (generation confirmed stopped)." と答えた。
//   `#interruptExclusive` は生成の印(spinner / Interrupted の行)しか見ず、「どの生成」も、overlay が在る事も知らなかった。
// 守る物: overlay が見えていたら `stopped:"overlay-closed"`(reason = 何が開いていたか)/ 閉じたのを見ていなければ
//   `stopped:"unverified"`(reason `overlay-stuck`)。どちらも `interrupted:false` に落ち、電話の文は「止めた」と言わない。
// 対照: overlay が無い画面では従来の判定(生成中 → verified)が変わらない。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { TmuxInjector, overlayKindIn, emptyPanelIn } from "../src/inject.mjs";
import { interruptResult } from "../src/view.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const panelFx = (n) => readFileSync(join(HERE, "fixtures", "panel", `${n}.txt`), "utf8");
const screenFx = (n) => readFileSync(join(HERE, "fixtures", "screens", `${n}.txt`), "utf8");
const DETAIL = panelFx("friday-detail-direct");
const PANEL = panelFx("friday-panel-open");
const EMPTY = panelFx("friday-panel-empty");
const COMPOSER = panelFx("friday-after-esc1");

const paneLine = "%1\t2.1.263\t/dev/ttys001\t/Users/athenas/Athenas\n";
/** 偽 tmux: 撮影ごとに frames を順に返す(最後の枠で止まる)。 */
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

test("実画面: overlayKindIn は detail / panel / panel-empty / null を返し、emptyPanelIn は空パネルだけ拾う", () => {
  assert.equal(overlayKindIn(DETAIL), "detail");
  assert.equal(overlayKindIn(PANEL), "panel");
  assert.equal(overlayKindIn(EMPTY), "panel-empty");
  assert.equal(overlayKindIn(COMPOSER), null);
  assert.equal(emptyPanelIn(EMPTY), true);
  assert.equal(emptyPanelIn(DETAIL), false);
});

test("詳細が開いた pane への割り込み: Escape 1 回、閉じたのを見て stopped=overlay-closed / reason=detail。生成の判定は言わない", async () => {
  const t = fakeTmux([DETAIL, DETAIL, COMPOSER]);
  const r = await inj(t).interrupt("%1");
  assert.equal(r.stopped, "overlay-closed");
  assert.equal(r.reason, "detail");
  assert.deepEqual(sends(t), ["Escape"], "Escape を 1 回だけ。C-c も 2 回目も無い");
});

test("一覧(panel)/ 空パネルでも同じ: reason が何が開いていたかを言う", async () => {
  const a = await inj(fakeTmux([PANEL, COMPOSER])).interrupt("%1");
  assert.deepEqual([a.stopped, a.reason], ["overlay-closed", "panel"]);
  const b = await inj(fakeTmux([EMPTY, COMPOSER])).interrupt("%1");
  assert.deepEqual([b.stopped, b.reason], ["overlay-closed", "panel-empty"]);
});

test("★閉じたのを見ていない(overlay が残る)→ stopped=unverified / reason=overlay-stuck。閉じたと言わない", async () => {
  const t = fakeTmux([DETAIL]);
  const r = await inj(t).interrupt("%1");
  assert.equal(r.stopped, "unverified");
  assert.equal(r.reason, "overlay-stuck");
  assert.deepEqual(sends(t), ["Escape"]);
});

test("対照: overlay の無い生成中の画面では従来どおり(Escape → 印が増えれば verified)", async () => {
  const t = fakeTmux([screenFx("generating"), screenFx("edith-interrupted")]);
  const r = await inj(t).interrupt("%1");
  assert.equal(r.stopped, "verified");
  assert.equal(r.reason, null);
});

test("電話の文: overlay-closed は『止めた』と言わず、もう一度押せと言う。overlay-stuck も『止めた』と言わない", () => {
  const closed = interruptResult(200, { interrupted: false, stopped: "overlay-closed", reason: "detail", waitedMs: 300, route: "tmux", pane: "%1" });
  assert.equal(closed.kind, "warn");
  assert.match(closed.text, /nothing was interrupted/i);
  assert.match(closed.text, /Tap Stop again to interrupt the conversation/);
  assert.match(closed.text, /stop one agent from Running/);
  assert.doesNotMatch(closed.text, /Stopped \(/);
  const stuck = interruptResult(200, { interrupted: false, stopped: "unverified", reason: "overlay-stuck", waitedMs: 300, route: "tmux", pane: "%1" });
  assert.equal(stuck.kind, "warn");
  assert.match(stuck.text, /did not close/);
  assert.doesNotMatch(stuck.text, /Stopped \(/);
  // 対照: verified の文は変えていない
  assert.equal(interruptResult(200, { interrupted: true, stopped: "verified", reason: null }).text, "Stopped (generation confirmed stopped).");
});

test("★server の封筒: interrupted は verified の時だけ true(overlay-closed は false に落ちる)", () => {
  const src = readFileSync(join(HERE, "..", "src", "server.mjs"), "utf8");
  assert.ok(src.includes('interrupted: out.stopped === "verified",'), "tmux 経路の interrupted は stopped===verified から導く");
});

// ── Codex 2026-09-07 の所見を畳んだ 2 本 ─────────────────────────────────────────
test("★TOCTOU(Codex #3): 撮った後に overlay が自分で閉じ、Escape が親の生成に届いた(印が増えた)→ verified を名乗る(閉じただけ、と嘘をつかない)", async () => {
  // 撮影 1 = 詳細、Escape 後の撮影 = 印が増えた画面(overlay は無い)
  const t = fakeTmux([DETAIL, screenFx("edith-interrupted")]);
  const r = await inj(t).interrupt("%1");
  assert.equal(r.stopped, "verified");
  assert.equal(r.reason, null);
  assert.deepEqual(sends(t), ["Escape"]);
});

test("★認識できない overlay(Codex #2/#5): 入力欄が見えない画面で spinner が消えただけなら unverified(overlay-unknown)。印が増えれば verified", async () => {
  // 入力欄の無い生成中の画面 = 詳細の上半分(親の spinner)だけを残し、下の overlay を別の形に崩した物
  const noComposer = DETAIL.split("\n").map((l) => (/^\s*← to go back/.test(l) ? "   ← unknown footer" : l)).join("\n");
  assert.equal(overlayKindIn(noComposer), null, "此の画面は panel/detail と認識されない(footer を崩した)");
  const quiet = fakeTmux([noComposer, noComposer, COMPOSER]);
  const r = await inj(quiet).interrupt("%1");
  assert.equal(r.stopped, "unverified");
  assert.equal(r.reason, "overlay-unknown");
  const marks = fakeTmux([noComposer, screenFx("edith-interrupted")]);
  const r2 = await inj(marks).interrupt("%1");
  assert.equal(r2.stopped, "verified");
  const text = interruptResult(200, { interrupted: false, stopped: "unverified", reason: "overlay-unknown" }).text;
  assert.match(text, /may have only closed an overlay/);
});
