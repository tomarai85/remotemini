// 80 桁で折り返した `Team: <長い名前> (N)` の見出しを、シェルの行として読まない(Codex 所見 2026-09-06 #7)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { parsePanel } from "../src/panelmodel.mjs";

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
  assert.equal(p.sections[0].rows.length, 4);                          // 元の読み方(行として保持)に落ちる
});

test("★折り返した Team 見出しが唯一の節でも panel と認識する(Codex 3 回目 #1: 見出しの結合に辿り着く前に落ちていた)", () => {
  const s = ["⏺ x", "▔▔▔▔▔▔▔▔▔▔", "   Background", "   1 active agent",
    "     Team: a-very-long-team-name-that-wraps-at-eighty-columns-and-keeps", "     going (1)",
    "   ❯ deploy (running) · Sonnet 5", "   ↑/↓ to select · Enter to view · x to stop · Esc to close", ""].join("\n");
  const p = parsePanel(s);
  assert.ok(p, "panel と認識される");
  assert.deepEqual(p.sections.map((x) => [x.name, x.rows.map((r) => r.text)]), [["Team: a-very-long-team-name-that-wraps-at-eighty-columns-and-keeps going", ["deploy (running) · Sonnet 5"]]]);
});

test("折り返していない短い Team 見出しは今まで通り", () => {
  const s = CAPTURE.replace("     Team: this-team-name-is-deliberately-long-enough-to-wrap-at-eighty-\n     columns (1)", "     Team: alpha (1)");
  const p = parsePanel(s);
  assert.deepEqual(p.sections.map((x) => [x.name, x.rows.length]), [["Shells", 1], ["Team: alpha", 1]]);
});
