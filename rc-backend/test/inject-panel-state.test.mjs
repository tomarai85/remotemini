// `classifyScreen` が agent panel(`/tasks`)と其の詳細画面を**行で**見分ける事の検査(2026-09-06、対照表 #8 の後半 a)。
//
// ── 何を測るか ────────────────────────────────────────────────────────────
// 設計(`research/subagent-stop-panel-design-2026-09-04.md`)は「PANEL は footer の文でなく**行**で識別し、
// 『composer が無い』から推測しない」と決めた。測定(`research/subagent-stop-panel-row-identifier-measurement-2026-09-06.md`)
// が両機の画面を残したので、其れを fixture(`test/fixtures/panel/`)にして、
//   ・panel が開いた画面 → PANEL / 詳細 → DETAIL / 閉じた・走行中 → 今までどおり
//   ・Jervis の panel 画面には転写の echo(`❯ ` で始まる行)が在る → **SENDABLE と読まない**
//   ・80 桁で 2 行に折り返した footer を繋いで読む(2 行目を消すと PANEL でなくなる = 繋ぎを測る)
//   ・線では `UNKNOWN` のまま + `overlay` を足す(古い電話の挙動を変えない)
//   ・注入器は PANEL 画面へ打鍵しない(`panel-open` で断る)
// を見る。陰性対照は写しに変異を植えて赤を確かめる(section 見出し / Background 見出しの要求を外す)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { classifyScreen, overlayOf, TmuxInjector } from "../src/inject.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIX = join(HERE, "fixtures", "panel");
const fx = (name) => readFileSync(join(FIX, name), "utf8");

const PANELS = ["jervis-panel-open.txt", "jervis-panel-down1.txt", "friday-panel-open.txt", "friday-panel-down1.txt"];
const DETAILS = ["jervis-detail-open.txt", "friday-detail-open.txt"];
const CLOSED = ["jervis-panel-closed.txt", "friday-after-esc1.txt", "jervis-running.txt", "friday-running.txt"];

test("★panel が開いた画面は PANEL(両機、開いた直後と 1 段下げた後)", () => {
  for (const f of PANELS) {
    const c = classifyScreen(fx(f));
    assert.equal(c.state, "PANEL", f);
    assert.equal(c.composer, -1, `${f}: PANEL に composer の行番号が在る`);
  }
});

test("★詳細画面は DETAIL(両機)", () => {
  for (const f of DETAILS) assert.equal(classifyScreen(fx(f)).state, "DETAIL", f);
});

test("閉じた後と走行中は今までどおり(SENDABLE、composer が在る)—— 陰性を固定する", () => {
  for (const f of CLOSED) {
    const c = classifyScreen(fx(f));
    assert.equal(c.state, "SENDABLE", f);
    assert.ok(c.composer >= 0, `${f}: composer の行番号が無い`);
  }
});

test("★Jervis の panel 画面には `❯ ` で始まる転写の echo が在るが、SENDABLE とは読まない", () => {
  const s = fx("jervis-panel-open.txt");
  assert.ok(/^❯ /m.test(s), "fixture の前提(echo 行が在る)が崩れている");
  assert.equal(classifyScreen(s).state, "PANEL");
});

test("★80 桁で 2 行に折り返した footer を繋いで読む(2 行目を消すと PANEL でなくなる)", () => {
  const s = fx("friday-panel-open.txt");
  assert.ok(s.includes("ctrl+k to stop all agents · Esc to close"), "fixture の前提(footer の 2 行目)が崩れている");
  assert.equal(classifyScreen(s).state, "PANEL");
  const cut = s.split("\n").filter((l) => !l.includes("ctrl+k to stop all agents · Esc to close")).join("\n");
  assert.notEqual(classifyScreen(cut).state, "PANEL", "footer の 2 行目が無いのに PANEL と読んだ = 繋ぎを測っていない");
});

test("Background の見出しだけでは PANEL にならない(section 見出しが要る)", () => {
  const s = ["⏺ something", "   Background", "   2 active agents", "   ↑/↓ to select · Enter to view · Esc to close", "", "❯ ", ""].join("\n");
  assert.notEqual(classifyScreen(s).state, "PANEL");
});

test("section 見出しと footer だけでは PANEL にならない(Background の見出しが要る)", () => {
  const s = ["⏺ something", "     Local agents (2)", "   ❯ count slowly (running) · Sonnet 5", "   ↑/↓ to select · Enter to view · Esc to close", ""].join("\n");
  assert.notEqual(classifyScreen(s).state, "PANEL");
});

test("activity / limited は PANEL でも今までどおり独立に出る", () => {
  for (const f of [...PANELS, ...DETAILS]) {
    const c = classifyScreen(fx(f));
    assert.ok(["observed", "unknown"].includes(c.activity), f);
    assert.equal(typeof c.limited, "boolean", f);
  }
});

test("★線には UNKNOWN のまま乗せ、overlay を足す(古い電話の挙動を変えない)", () => {
  assert.deepEqual(overlayOf("PANEL"), { screen: "UNKNOWN", overlay: "panel" });
  assert.deepEqual(overlayOf("DETAIL"), { screen: "UNKNOWN", overlay: "detail" });
  assert.deepEqual(overlayOf("SENDABLE"), { screen: "SENDABLE", overlay: null });
  assert.deepEqual(overlayOf("CHOICE"), { screen: "CHOICE", overlay: null });
  assert.deepEqual(overlayOf("UNKNOWN"), { screen: "UNKNOWN", overlay: null });
});

test("★注入器は PANEL 画面へ 1 打も打たず `panel` で断る", async () => {
  const calls = [];
  const screen = fx("friday-panel-open.txt");
  const tmux = { run: (args) => { calls.push(args); return args[0] === "capture-pane" ? screen : ""; }, runStrict: (args) => { calls.push(args); return args[0] === "capture-pane" ? screen : ""; } };
  const inj = new TmuxInjector({ tmux });
  const r = await inj.send("%1", "hello");
  assert.equal(r.sent, false);
  assert.equal(r.state, "PANEL");
  assert.equal(r.reason, "panel");
  // 添付の経路(打つだけ)も同じ画面で打たない
  const t = await inj.typeLiteralExclusive("%1", "hello");
  assert.equal(t.typed, 0);
  assert.equal(t.reason, "panel");
  assert.equal(calls.filter((a) => a[0] === "send-keys").length, 0, "PANEL 画面へ打鍵した");
  // 詳細画面も同じ(理由は detail)
  const detail = fx("friday-detail-open.txt");
  const tmux2 = { run: (a) => (a[0] === "capture-pane" ? detail : ""), runStrict: (a) => (a[0] === "capture-pane" ? detail : "") };
  const r2 = await new TmuxInjector({ tmux: tmux2 }).send("%1", "hello");
  assert.equal(r2.sent, false);
  assert.equal(r2.reason, "detail");
});

// ── Codex 2026-09-06 の所見(画面全体から語を拾う誤読)────────────────────────
test("★転写に panel の文が引用されただけの画面は PANEL ではない(本物の composer を隠さない)", () => {
  const quoted = ["⏺ ここに panel の例を貼る:", "   Background", "     Local agents (1)", "   ↑/↓ to select · Enter to view", "   Esc to close",
    "────────────────────────────────────────", "❯ ", "────────────────────────────────────────", ""].join("\n");
  const c = classifyScreen(quoted);
  assert.equal(c.state, "SENDABLE", "引用を overlay と読んだ");
  assert.ok(c.composer >= 0);
});

test("★区切り(▔)まで引用されていても、その下に本物の composer が在れば overlay ではない", () => {
  const quoted = ["⏺ 例:", "▔▔▔▔▔▔▔▔▔▔", "   Background", "     Local agents (1)", "   ↑/↓ to select · Enter to view · Esc to close",
    "────────────────────────────────────────", "❯ ", "────────────────────────────────────────", ""].join("\n");
  assert.equal(classifyScreen(quoted).state, "SENDABLE");
});

test("★転写に詳細画面の文が引用されても DETAIL ではない", () => {
  const quoted = ["⏺ worker › example", "   1s · 100 tokens · 2 tools", "   Progress", "   ← to go back · Esc to close",
    "────────────────────────────────────────", "❯ ", "────────────────────────────────────────", ""].join("\n");
  assert.equal(classifyScreen(quoted).state, "SENDABLE");
});

test("overlay は**最後の**区切りの下で探す(先行する Background の引用に惑わされない)", () => {
  const real = fx("friday-panel-open.txt");
  const s = ["⏺ 先に引用: Background", "   (節の見出しは無い)", ...real.split("\n")].join("\n");
  assert.equal(classifyScreen(s).state, "PANEL");
});

test("scroll hint と Team の塊が在っても PANEL(節の見出しは 7 行の窓に限らない)", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   8 active agents", "   hint 1", "   hint 2", "   hint 3", "   hint 4", "   hint 5",
    "   ↓ 3 more", "     Team: alpha (2)", "   ❯ @a: working", "   ↑/↓ to select · Enter to view · Esc to close", ""].join("\n");
  assert.equal(classifyScreen(s).state, "PANEL");
});
