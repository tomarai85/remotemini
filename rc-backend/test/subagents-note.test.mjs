// subagents-note.test.mjs — `GET /api/sessions/:id/subagents` の `display.note` が、**此の一覧が見えない物**を毎回名乗る
// (2026-09-07、対照表 #8 の後半の限界 2)。
//
// ★何が見えないか: 一覧の源は `~/.claude/projects/<slug>/<sid>/subagents/agent-*.jsonl` だけ。`/tasks` パネルに並ぶ
//   **背景シェル**(`run_in_background` の Bash)と**チームの一員**(Team の節)は此処に転写を持たないので、一覧に出ない。
//   電話は `display.note` を其のまま描く(SubagentsView `subagents.note`)ので、文が名乗らない限り「一覧 = パネルの全部」
//   と読まれる。机で 1 文を足す。電話は変えない(机と電話で言葉を分けない —— wire.mjs の頭注と同じ判断)。
// ★読めない 2 枝(`directory:"unreadable"` / `parent:"unreadable"`)には足さない —— 其処は既に「読めない」と言っていて、
//   見えない物の列挙を重ねると何が読めないのかが濁る。
import test from "node:test";
import assert from "node:assert/strict";
import { subagentsBody, subagentsNote } from "../src/wire.mjs";

const DISCLOSE = /Background shells and teammates are not listed here/;
const running = (id) => ({ agentId: id, description: "count slowly", state: "running" });

test("空の一覧でも、見えない物を名乗る", () => {
  const note = subagentsNote({ agents: [], directory: "absent", parent: "read", truncated: false });
  assert.match(note, /no subagents/);
  assert.match(note, DISCLOSE);
});

test("走っている一覧にも同じ 1 文が付く(数の文の後ろ)", () => {
  const note = subagentsNote({ agents: [running("a"), running("b")], directory: "read", parent: "read", truncated: false });
  assert.match(note, /^2 subagents, 2 working\. /);
  assert.match(note, DISCLOSE);
  // 文は 1 回だけ
  assert.equal(note.split("Background shells").length - 1, 1);
});

test("打ち切りの旗と共存する", () => {
  const note = subagentsNote({ agents: [running("a")], directory: "read", parent: "read", truncated: true });
  assert.match(note, /list truncated\. /);
  assert.match(note, DISCLOSE);
});

test("dir が読めない枝には足さない(既に読めないと言っている)", () => {
  const note = subagentsNote({ agents: [], directory: "unreadable", parent: "read", truncated: false });
  assert.match(note, /Could not read/);
  assert.doesNotMatch(note, DISCLOSE);
});

test("親の転写が読めない枝にも足さない", () => {
  const note = subagentsNote({ agents: [{ agentId: "a", state: "unknown" }], directory: "read", parent: "unreadable", truncated: false });
  assert.match(note, /could not be read/);
  assert.doesNotMatch(note, DISCLOSE);
});

test("封筒の display.note を通っても同じ文が届く(電話は此れを其のまま描く)", () => {
  const body = subagentsBody({ agents: [running("a")], directory: "read", parent: "read", truncated: false, counts: null });
  assert.match(body.display.note, DISCLOSE);
  assert.match(body.display.note, /^1 subagent, 1 working\. /);
});

test("★否定対照: 文を外した note では此の検査が赤になる(検査が何かを測っている証拠)", () => {
  const bare = "1 subagent, 1 working.";
  assert.doesNotMatch(bare, DISCLOSE);
});
