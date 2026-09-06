// 80 桁で折り返した `Team: <長い名前> (N)` の見出しを、シェルの行として読まない(Codex 所見 2026-09-06 #7)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { parsePanel, parseDetail } from "../src/panelmodel.mjs";

const CAPTURE = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   1 active shell · 1 active agent", "",
  "     Shells (1)", "     sleep 300 (running)",
  "     Team: this-team-name-is-deliberately-long-enough-to-wrap-at-eighty-", "     columns (1)",
  "   ❯ deploy api (running) · Sonnet 5", "",
  "   ↑/↓ to select · Enter to view · x to stop · Esc to close", ""].join("\n");

test("★折り返した Team 見出しは 1 つの節になり、其の下の agent 行はシェルに混ざらない", () => {
  const p = parsePanel(CAPTURE);
  assert.deepEqual(p.sections.map((s) => [s.name, s.count, s.rows.map((r) => [r.text, r.selected])]), [
    ["Shells", 1, [["sleep 300 (running)", false]]],
    ["Team: this-team-name-is-deliberately-long-enough-to-wrap-at-eighty-columns", 1, [["deploy api (running) · Sonnet 5", true]]],
  ]);
  assert.deepEqual(p.selected, { section: "Team: this-team-name-is-deliberately-long-enough-to-wrap-at-eighty-columns", index: 0, text: "deploy api (running) · Sonnet 5" });
});

test("折り返しに見えても、次の行が項目(` · ` を含む / 印が乗っている)なら繋がない", () => {
  const s = CAPTURE.replace("     columns (1)", "     columns (running) · Sonnet 5");
  const p = parsePanel(s);
  assert.equal(p.sections.length, 1);                                  // Team 見出しは成立しない
  // 見出しにならなかった `Team: …` の行は状態で終わらないので、次の行と繋いで 1 本の(折り返した)項目と読む
  assert.deepEqual(p.sections[0].rows.map((r) => r.text), ["sleep 300 (running)", "Team: this-team-name-is-deliberately-long-enough-to-wrap-at-eighty- columns (running) · Sonnet 5", "deploy api (running) · Sonnet 5"]);
});

test("★折り返した Team 見出しが唯一の節でも panel と認識する(Codex 3 回目 #1: 見出しの結合に辿り着く前に落ちていた)", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   1 active agent",
    "     Team: a-very-long-team-name-that-wraps-at-eighty-columns-and-keeps", "     going (1)",
    "   ❯ deploy (running) · Sonnet 5", "   ↑/↓ to select · Enter to view · x to stop · Esc to close", ""].join("\n");
  const p = parsePanel(s);
  assert.ok(p, "panel と認識される");
  assert.deepEqual(p.sections.map((x) => [x.name, x.rows.map((r) => r.text)]), [["Team: a-very-long-team-name-that-wraps-at-eighty-columns-and-keeps going", ["deploy (running) · Sonnet 5"]]]);
});

test("★3 行以上に折り返した Team 見出しも 1 つの節(Codex r4#7)", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   1 active agent",
    "     Team: alpha beta gamma delta epsilon zeta eta theta iota kappa", "     lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega", "     final segment (1)",
    "   ❯ same job (running) · Sonnet 5", "   ↑/↓ to select · Enter to view · x to stop · Esc to close", ""].join("\n");
  const p = parsePanel(s);
  assert.ok(p, "panel と認識される");
  assert.deepEqual(p.sections.map((x) => [x.name, x.count, x.rows.map((r) => r.text)]), [["Team: alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega final segment", 1, ["same job (running) · Sonnet 5"]]]);
});

test("★長い説明文の行が折り返しても 1 本の行(Codex r4#5)。印は先頭の行に付く", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   1 active agent", "     Local agents (1)",
    "   ❯ a deliberately very long description that wraps before its final", "     words (running) · Sonnet 5",
    "   ↑/↓ to select · Enter to view · x to stop · Esc to close", ""].join("\n");
  const p = parsePanel(s);
  assert.deepEqual(p.sections[0].rows, [{ text: "a deliberately very long description that wraps before its final words (running) · Sonnet 5", selected: true }]);
  assert.equal(p.selected.index, 0);
  // teammate の行(`@name: status`)は状態の括弧が無いが、続きの行ではない
  const t = s.replace("   ❯ a deliberately very long description that wraps before its final\n     words (running) · Sonnet 5", "   ❯ @lead: working\n     @worker: idle");
  assert.deepEqual(parsePanel(t).sections[0].rows.map((r) => r.text), ["@lead: working", "@worker: idle"]);
});

test("★詳細の題名が折り返しても説明文は 1 つ、数の行は壊れない(Codex r4#6)", () => {
  const d = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   general-purpose › a deliberately long description that wraps onto", "   the next physical line",
    "   1s · 1 tokens · Sonnet 5", "", "   Prompt", "   unique prompt", "", "   ← to go back · Esc/Enter/Space to close · x to stop", ""].join("\n");
  const p = parseDetail(d);
  assert.ok(p, "detail と認識される");
  assert.equal(p.description, "a deliberately long description that wraps onto the next physical line");
  assert.deepEqual(p.counters, { elapsed: "1s", tokens: "1 tokens", tools: null, model: "Sonnet 5" });
  assert.equal(p.promptPrefix, "unique prompt");
});

test("★prompt の先頭の空白は残す(overlay の字下げ 3 つだけ落とす。Codex r4#4)", () => {
  const d = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   general-purpose › spaced job", "   1s · 1 tokens · Sonnet 5", "", "   Prompt", "     keep leading", "",
    "   ← to go back · Esc/Enter/Space to close · x to stop", ""].join("\n");
  const p = parseDetail(d);
  assert.equal(p.promptPrefix, "  keep leading");
});

test("折り返していない短い Team 見出しは今まで通り", () => {
  const s = CAPTURE.replace("     Team: this-team-name-is-deliberately-long-enough-to-wrap-at-eighty-\n     columns (1)", "     Team: alpha (1)");
  const p = parsePanel(s);
  assert.deepEqual(p.sections.map((x) => [x.name, x.rows.length]), [["Shells", 1], ["Team: alpha", 1]]);
});
