// 停止の目標を組む(2026-09-06、対照表 #8 の後半 c3)。実 fixture の形の転写から prompt と道具列を取り、列挙の判定で
// 生死と同名の生存数を付ける。組めなければ閉じた語彙で断る。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildStopTarget, readAgentTranscript, renderToolCall, TARGET_REFUSAL } from "../src/subagentstop.mjs";

const SID = "11111111-2222-3333-4444-555555555555";
function fixture({ agents }) {
  const base = mkdtempSync(join(tmpdir(), "rc-stop-"));
  const transcript = join(base, `${SID}.jsonl`);
  writeFileSync(transcript, JSON.stringify({ type: "user", message: { role: "user", content: "parent" } }) + "\n");
  const dir = join(base, SID, "subagents");
  mkdirSync(dir, { recursive: true });
  for (const a of agents) {
    const lines = [JSON.stringify({ type: "user", agentId: a.id, isSidechain: true, message: { role: "user", content: a.prompt } })];
    for (const t of a.tools ?? []) lines.push(JSON.stringify({ type: "assistant", agentId: a.id, message: { role: "assistant", content: [{ type: "tool_use", name: t[0], input: t[1] }] } }));
    writeFileSync(join(dir, `agent-${a.id}.jsonl`), lines.join("\n") + "\n");
    writeFileSync(join(dir, `agent-${a.id}.meta.json`), JSON.stringify({ agentType: a.type ?? "general-purpose", description: a.description }));
    if (a.staleMs) { const t = new Date(Date.now() - a.staleMs); utimesSync(join(dir, `agent-${a.id}.jsonl`), t, t); }
  }
  return { transcript, dir };
}
const A = { id: "a1111111111111111", description: "count slowly", prompt: "Run `sleep 12` ten times.", tools: [["Bash", { command: "sleep 12" }], ["Bash", { command: "sleep 12" }]] };
const B = { id: "a2222222222222222", description: "count slowly", prompt: "Run `sleep 13` ten times.", tools: [["Bash", { command: "sleep 13" }]] };

test("語彙は閉じていて文が在る", () => {
  assert.deepEqual(Object.keys(TARGET_REFUSAL).sort(), ["no-material", "no-such-agent", "not-live", "unreadable"]);
  for (const v of Object.values(TARGET_REFUSAL)) assert.ok(v.length > 30);
});

test("renderToolCall: panel の描き方(`Bash(sleep 12)`)。第 1 引数は道具ごと、無ければ最初の文字列、改行は空白", () => {
  assert.equal(renderToolCall("Bash", { command: "sleep 12", description: "wait" }), "Bash(sleep 12)");
  assert.equal(renderToolCall("Read", { file_path: "/a/b.txt" }), "Read(/a/b.txt)");
  assert.equal(renderToolCall("Grep", { pattern: "foo", path: "/x" }), "Grep(foo)");
  assert.equal(renderToolCall("Custom", { thing: "v", n: 1 }), "Custom(v)");
  assert.equal(renderToolCall("Custom", { n: 1 }), "Custom");
  assert.equal(renderToolCall("Bash", { command: "echo a\n  && echo b" }), "Bash(echo a && echo b)");
  assert.equal(renderToolCall("", {}), null);
});

test("★実 fixture の形の転写から prompt(先頭の user)と道具列(tool_use の順)を取る。text ブロックの列も読む", () => {
  const { dir } = fixture({ agents: [A, { ...B, prompt: undefined, promptBlocks: true }] });
  const a = readAgentTranscript(join(dir, `agent-${A.id}.jsonl`));
  assert.deepEqual(a, { ok: true, promptPrefix: "Run `sleep 12` ten times.", recentTools: ["Bash(sleep 12)", "Bash(sleep 12)"] });
  writeFileSync(join(dir, "agent-a3.jsonl"), JSON.stringify({ type: "user", message: { role: "user", content: [{ type: "text", text: "first" }, { type: "text", text: "second" }] } }) + "\nnot json\n");
  assert.deepEqual(readAgentTranscript(join(dir, "agent-a3.jsonl")), { ok: true, promptPrefix: "first\nsecond", recentTools: [] });
  assert.equal(readAgentTranscript(join(dir, "agent-none.jsonl")).reason, "no-such-agent");
});

test("★目標: 生きている 2 本の同名 → liveSameDescription 2、prompt と道具列が付く", () => {
  const { transcript } = fixture({ agents: [A, B] });
  const r = buildStopTarget(transcript, B.id);
  assert.equal(r.ok, true);
  assert.equal(r.target.description, "count slowly");
  assert.equal(r.target.agentType, "general-purpose");
  assert.equal(r.target.promptPrefix, "Run `sleep 13` ten times.");
  assert.deepEqual(r.target.recentTools, ["Bash(sleep 13)"]);
  assert.equal(r.target.live, true);
  assert.equal(r.target.liveSameDescription, 2);
});

test("★片方が古い(stale)なら同名の生存数は 1、其の古い方は not-live で断る", () => {
  const { transcript } = fixture({ agents: [A, { ...B, staleMs: 60 * 60 * 1000 }] });
  const a = buildStopTarget(transcript, A.id);
  assert.equal(a.ok, true);
  assert.equal(a.target.liveSameDescription, 1);
  const b = buildStopTarget(transcript, B.id);
  assert.equal(b.ok, false);
  assert.equal(b.reason, "not-live");
  assert.ok(b.message.length > 30);
});

test("知らない id / 変な id / 転写の無い会話は no-such-agent、材料の無い転写は no-material", () => {
  const { transcript } = fixture({ agents: [A, { id: "a4444444444444444", description: "empty", prompt: "" }] });
  assert.equal(buildStopTarget(transcript, "a9999999999999999").reason, "no-such-agent");
  assert.equal(buildStopTarget(transcript, "../etc/passwd").reason, "no-such-agent");
  assert.equal(buildStopTarget(transcript, "").reason, "no-such-agent");
  assert.equal(buildStopTarget(transcript, "a4444444444444444").reason, "no-material");
  assert.equal(buildStopTarget(join(tmpdir(), "nope.jsonl"), A.id).reason, "no-such-agent");
});

test("listing を渡せば列挙を読み直さない(口は 1 要求 1 回)", () => {
  const { transcript } = fixture({ agents: [A] });
  const listing = { agents: [{ agentId: A.id, agentType: "general-purpose", description: "count slowly", state: "running", meta: "read" }], directory: "read" };
  const r = buildStopTarget(transcript, A.id, { listing });
  assert.equal(r.ok, true);
  assert.equal(r.target.liveSameDescription, 1);
});
