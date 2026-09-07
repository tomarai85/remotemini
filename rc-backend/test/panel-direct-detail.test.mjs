// panel-direct-detail.test.mjs — `/tasks` が一覧を飛ばして詳細に直行する形と、task が 0 本の空パネル(2026-09-07)。
//
// 何が起きたか: 本番 friday(Claude Code 2.1.263)で背景シェルを殺した後に `/tasks` を打つと、パネルの task が 1 本だけになり
//   TUI は一覧を**描かずに其の詳細へ直行**した(3/3 再現。`.harness/evidence-2026-09-07/repro-shell-kill-screens.log`)。
//   以前の driver は其処で `panel-did-not-open` と断り、開けた詳細を残していた(次の送信を塞ぐ)。
// 此処で守る物: (1) 実画面 2 枚が parser に正しく読める(fixture は撮ったまま)/ (2) planDirectDetail は「厳密な一致」でしか
//   押さない / (3) 空パネルは emptyPanel が拾う(panelStateOf は節が無いので null = 以前は誰も拾わなかった)。
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { panelStateOf, classifyScreen } from "../src/inject.mjs";
import { parseDetail } from "../src/panelmodel.mjs";
import { planDirectDetail, detailMatches } from "../src/panelstop.mjs";
import { emptyPanel } from "../src/panelstop-driver.mjs";

const FIX = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "panel");
const fx = (n) => readFileSync(join(FIX, n), "utf8");
const DIRECT = fx("friday-detail-direct.txt");
const EMPTY = fx("friday-panel-empty.txt");
const PROMPT = "Run the shell command `sleep 12` using the Bash tool, ten times in a row, as ten separate sequential Bash tool calls. Each call must be its own separate tool invocation — never combine them into one command, never run them in the background, never batch them in parallel. Do not read any files. After the tenth sleep returns, reply with the single word done.";
const T = (over = {}) => ({ agentType: "general-purpose", description: "count slowly", promptPrefix: PROMPT, recentTools: ["Bash(sleep 12)", "Bash(sleep 12)"], live: true, liveSameDescription: 1, ...over });

test("実画面: 直行した詳細は DETAIL と読め、型・説明・道具列・prompt 冒頭(297 字 + …)が取れる", () => {
  assert.equal(panelStateOf(DIRECT), "DETAIL");
  assert.equal(classifyScreen(DIRECT).state, "DETAIL");
  const d = parseDetail(DIRECT);
  assert.equal(d.kind, "detail");
  assert.equal(d.agentType, "general-purpose");
  assert.equal(d.description, "count slowly");
  assert.deepEqual(d.recentTools, ["Bash(sleep 12)", "Bash(sleep 12)"]);
  assert.match(d.promptPrefix, /^Run the shell command `sleep 12`/);
  assert.match(d.promptPrefix, /…$/);
});

test("実画面: 空パネルは panelStateOf では null(節が無い)だが emptyPanel が拾う。composer は無い", () => {
  assert.equal(panelStateOf(EMPTY), null);
  assert.equal(classifyScreen(EMPTY).state, "UNKNOWN");
  assert.equal(emptyPanel(EMPTY), true);
  assert.equal(emptyPanel(DIRECT), false, "詳細は空パネルではない");
});

test("planDirectDetail: 実画面の詳細と、転写から組んだ目標が一致 → press-x-in-detail(target.section=direct)", () => {
  const d = parseDetail(DIRECT);
  assert.equal(detailMatches(d, T(), { strict: false }).ok, true);
  const p = planDirectDetail({ detail: d, target: T() });
  assert.equal(p.ok, true, JSON.stringify(p));
  assert.equal(p.action, "press-x-in-detail");
  assert.equal(p.direct, true);
  assert.equal(p.target.section, "direct");
  assert.equal(p.target.text, "count slowly (running)");
});

test("planDirectDetail: 断りは閉じた語彙 —— 説明違い / prompt 違い = no-such-row、材料不足 = ambiguous、生存 2 本 + prompt 無し = ambiguous", () => {
  const d = parseDetail(DIRECT);
  assert.deepEqual(planDirectDetail({ detail: d, target: T({ description: "other" }) }), { ok: false, reason: "no-such-row", why: "description" });
  assert.deepEqual(planDirectDetail({ detail: d, target: T({ promptPrefix: "Something else entirely that is long enough to be a prompt." }) }), { ok: false, reason: "no-such-row", why: "prompt" });
  assert.deepEqual(planDirectDetail({ detail: d, target: T({ promptPrefix: "", recentTools: [] }) }), { ok: false, reason: "ambiguous", why: "insufficient" });
  assert.deepEqual(planDirectDetail({ detail: d, target: T({ promptPrefix: "", liveSameDescription: 2 }) }), { ok: false, reason: "ambiguous", why: "twin-without-prompt" });
  assert.equal(planDirectDetail({ detail: d, target: T({ liveSameDescription: 2 }) }).ok, true, "prompt が厳密に一致すれば生存 2 本でも押す");
  assert.deepEqual(planDirectDetail({ detail: d, target: T({ live: false }) }), { ok: false, reason: "no-such-row", why: "not-live" });
  assert.deepEqual(planDirectDetail({ detail: null, target: T() }), { ok: false, reason: "not-a-panel", why: "no-detail" });
  assert.deepEqual(planDirectDetail({ detail: d, target: T({ liveSameDescription: 0 }) }), { ok: false, reason: "ambiguous", why: "unknown-siblings" });
});

test("★否定対照: 直行した詳細の道具列の末尾が違えば押さない(切れていない行は同一の証明)", () => {
  const d = parseDetail(DIRECT);
  const p = planDirectDetail({ detail: d, target: T({ recentTools: ["Bash(sleep 12)", "Bash(sleep 13)"] }) });
  assert.equal(p.ok, false);
  assert.equal(p.reason, "no-such-row");
  assert.equal(p.why, "tools");
});
