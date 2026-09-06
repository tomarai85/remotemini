// panel の画面を構造に読む純関数の検査(2026-09-06、対照表 #8 の後半 b)。fixture = `test/fixtures/panel/`。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parsePanel, parseDetail, duplicateRows } from "../src/panelmodel.mjs";

const FIX = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "panel");
const fx = (n) => readFileSync(join(FIX, n), "utf8");

test("★panel(両機、開いた直後): 節 Local agents (2) に同じ説明文の行が 2 本、印は 1 行目", () => {
  for (const f of ["jervis-panel-open.txt", "friday-panel-open.txt"]) {
    const p = parsePanel(fx(f));
    assert.ok(p, f);
    assert.equal(p.counts, "2 active agents", f);
    assert.equal(p.sections.length, 1, f);
    assert.equal(p.sections[0].name, "Local agents");
    assert.equal(p.sections[0].count, 2);
    assert.deepEqual(p.sections[0].rows.map((r) => r.text), ["count slowly (running) · Sonnet 5", "count slowly (running) · Sonnet 5"], f);
    assert.deepEqual(p.sections[0].rows.map((r) => r.selected), [true, false], f);
    assert.deepEqual(p.selected, { section: "Local agents", index: 0, text: "count slowly (running) · Sonnet 5" }, f);
    assert.ok(p.footer.includes("↑/↓ to select") && p.footer.includes("Esc to close"), f);
  }
});

test("★1 段下げた後は印が 2 行目へ(行の文字列は変わらない = 同名の行は印でしか区別できない)", () => {
  for (const f of ["jervis-panel-down1.txt", "friday-panel-down1.txt"]) {
    const p = parsePanel(fx(f));
    assert.deepEqual(p.sections[0].rows.map((r) => r.selected), [false, true], f);
    assert.equal(p.selected.index, 1, f);
  }
});

test("★同じ文字列の行を畳まない(duplicateRows が『2 本』と言う)", () => {
  const p = parsePanel(fx("friday-panel-open.txt"));
  assert.deepEqual(duplicateRows(p), [{ text: "count slowly (running) · Sonnet 5", count: 2 }]);
});

test("80 桁で 2 行に折り返した footer を 1 文に繋ぐ", () => {
  const p = parsePanel(fx("friday-panel-open.txt"));
  assert.ok(p.footer.includes("ctrl+x ctrl+k to stop all agents · Esc to close"), p.footer);
});

test("シェルの節と agent の節を分けて読み、印がシェル行に乗っている事が判る(合成画面)", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   2 active shells · 1 active agent", "     Shells (2)", "     sleep 300 (running)",
    "   ❯ sleep 300 (running)", "     Local agents (1)", "     sleep then done (running) · Sonnet 5",
    "   ↑/↓ to select · Enter to view · x to stop · Esc to close", ""].join("\n");
  const p = parsePanel(s);
  assert.deepEqual(p.sections.map((x) => [x.name, x.count, x.rows.length]), [["Shells", 2, 2], ["Local agents", 1, 1]]);
  assert.deepEqual(p.selected, { section: "Shells", index: 1, text: "sleep 300 (running)" });
});

test("Team の塊と overflow の行(↓ N more)は hints に分け、項目にしない", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   3 agents", "     Team: session-a184aba6 (3)", "   ❯ @team-lead",
    "     @sleeper-2: working", "     @sleeper-1: working", "   ↓ 2 more", "   ↑/↓ to select · Enter to view · Esc to close", ""].join("\n");
  const p = parsePanel(s);
  assert.equal(p.sections[0].name, "Team: session-a184aba6");
  assert.deepEqual(p.sections[0].rows.map((r) => r.text), ["@team-lead", "@sleeper-2: working", "@sleeper-1: working"]);
  assert.deepEqual(p.hints, ["↓ 2 more"]);
});

test("panel でない画面は null(閉じた / 走行中)", () => {
  for (const f of ["jervis-panel-closed.txt", "friday-after-esc1.txt", "jervis-running.txt"]) assert.equal(parsePanel(fx(f)), null, f);
  for (const f of ["jervis-detail-open.txt", "friday-detail-open.txt"]) assert.equal(parsePanel(fx(f)), null, f);
});

test("★detail(両機): 型・説明・数・直近の道具・prompt の冒頭", () => {
  for (const f of ["jervis-detail-open.txt", "friday-detail-open.txt"]) {
    const d = parseDetail(fx(f));
    assert.ok(d, f);
    assert.equal(d.agentType, "general-purpose", f);
    assert.equal(d.description, "count slowly", f);
    assert.match(d.counters.tokens ?? "", /tokens$/, f);
    assert.match(d.counters.tools ?? "", /tools?$/, f);
    assert.equal(d.counters.model, "Sonnet 5", f);
    assert.ok(d.recentTools.length >= 1 && d.recentTools.every((t) => t === "Bash(sleep 12)"), JSON.stringify(d.recentTools));
    assert.ok(d.promptPrefix.startsWith("Run the shell command") || d.promptPrefix.startsWith("You have exactly one job"), d.promptPrefix.slice(0, 60));
    assert.ok(d.footer.includes("← to go back"), f);
  }
});

test("detail でない画面は null", () => {
  for (const f of ["jervis-panel-open.txt", "friday-panel-open.txt", "jervis-running.txt"]) assert.equal(parseDetail(fx(f)), null, f);
});

// ── Codex 2026-09-06 の所見 ────────────────────────────────────────────────
test("★本文が `❯ ` で始まる非選択行(空白 5 つ)を選択と読まない", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   2 active agents", "     Local agents (2)", "   ❯ first (running) · Sonnet 5",
    "     ❯ investigate marker handling (running) · Sonnet 5", "   ↑/↓ to select · Enter to view · Esc to close", ""].join("\n");
  const p = parsePanel(s);
  assert.deepEqual(p.sections[0].rows.map((r) => [r.text, r.selected]), [["first (running) · Sonnet 5", true], ["❯ investigate marker handling (running) · Sonnet 5", false]]);
});

test("★`↓ N more` の overflow だけを hints にし、`↓ 2 more failures …` の様な行は項目のまま", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   3 active agents", "     Local agents (3)", "   ❯ a (running) · Sonnet 5",
    "     ↓ 2 more failures (running) · Sonnet 5", "   ↓ 1 more", "   ↑/↓ to select · Enter to view · Esc to close", ""].join("\n");
  const p = parsePanel(s);
  assert.deepEqual(p.sections[0].rows.map((r) => r.text), ["a (running) · Sonnet 5", "↓ 2 more failures (running) · Sonnet 5"]);
  assert.deepEqual(p.hints, ["↓ 1 more"]);
});

test("★本文に `↑/↓ to select` を含む行で一覧を切らない(footer は行頭から始まる物だけ)", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   2 active agents", "     Local agents (2)", "   ❯ investigate ↑/↓ to select text (running) · Sonnet 5",
    "     b (running) · Sonnet 5", "   ↑/↓ to select · Enter to view · Esc to close", ""].join("\n");
  const p = parsePanel(s);
  assert.equal(p.sections[0].rows.length, 2);
  assert.ok(p.footer.startsWith("↑/↓ to select · Enter"));
});

test("数の行が折り返しても繋ぐ", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   2 active shells ·", "   1 active agent", "     Shells (2)", "     sleep 300 (running)",
    "   ❯ sleep 300 (running)", "   ↑/↓ to select · Enter to view · Esc to close", ""].join("\n");
  assert.equal(parsePanel(s).counts, "2 active shells · 1 active agent");
});

test("★detail: 数の行が折り返しても読み、model 名の ` · ` を切らず、Progress 見出しが無くても道具の行を拾い、切れた prompt に旗", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   general-purpose › count slowly", "   30s · 89.2k tokens ·", "   2 tools · Model X · Large",
    "   › Bash(sleep 12)", "   Prompt", "   Run the shell command sleep 12 ten times, then say do…", "   ← to go back · Esc/Enter/Space to close", ""].join("\n");
  const d = parseDetail(s);
  assert.deepEqual(d.counters, { elapsed: "30s", tokens: "89.2k tokens", tools: "2 tools", model: "Model X · Large" });
  assert.deepEqual(d.recentTools, ["Bash(sleep 12)"]);
  assert.equal(d.promptTruncated, true);
  const full = parseDetail(fx("friday-detail-open.txt"));
  assert.equal(typeof full.promptTruncated, "boolean");
});
