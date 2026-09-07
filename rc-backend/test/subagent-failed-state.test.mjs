// subagent-failed-state.test.mjs — 失敗した subagent は 6 つ目の状態 `failed` で返す(2026-09-07 round 12)。
//
// 何が問題だったか: `completionsIn` は `<status>failed</status>` を読まず、失敗した agent は mtime で running / stalled / unknown に見えた
//   (作業中と見分けが付かない)。Jervis の転写を全部 grep すると failed 470 件のうち 42 件が agent の失敗(残りは背景シェル / Monitor)。
//   本物の形(此の session 自身の転写): `<summary>Agent "Implement the transcript search UI" failed: Agent terminated early due to an
//   API error: API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND) (error type server_error)</summary>`。
// 読み方: summary が `Agent "…" failed` の物だけ(背景シェル `Background command … failed` / Monitor `Monitor "…" script failed` は読まない)。
//   順位は killed の次(completed > 転写が読めない > 机の観測 > 親が読めない > killed > failed > 予算 > mtime)。再開できるので、通知の後に
//   転写が動いていれば mtime で読む(killed と同じ守り)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { readSubagentsFromPath, stateOf, SUBAGENT_STATES, SUBAGENT_STATE_TEXT, SUBAGENT_STALE_MS } from "../src/subagents.mjs";
import { subagentsNote } from "../src/wire.mjs";

const NOW = Date.parse("2026-09-07T12:00:00.000Z");
const SID = "4b5c9362-aaaa-bbbb-cccc-000000000004";
const REAL_SUMMARY = 'Agent "Implement the transcript search UI" failed: Agent terminated early due to an API error: API Error: Can\'t reach the API server — check your internet or DNS (ENOTFOUND) (error type server_error)';

function world({ parentLines = [], agents = [] } = {}) {
  const base = mkdtempSync(join(tmpdir(), "failed-state-"));
  const parent = join(base, `${SID}.jsonl`);
  writeFileSync(parent, parentLines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  const dir = join(base, SID, "subagents");
  mkdirSync(dir, { recursive: true });
  for (const a of agents) {
    const jl = join(dir, `agent-${a.id}.jsonl`);
    writeFileSync(jl, JSON.stringify({ agentId: a.id, type: "assistant", message: { role: "assistant", model: "claude-opus-5" } }) + "\n");
    const t = (NOW - (a.mtimeSecAgo ?? 0) * 1000) / 1000;
    utimesSync(jl, t, t);
    writeFileSync(join(dir, `agent-${a.id}.meta.json`), JSON.stringify({ agentType: "general-purpose", description: a.description ?? "count slowly" }));
  }
  return { base, parent };
}
const launched = (id) => ({
  type: "user", timestamp: "2026-09-07T11:00:00.000Z",
  message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_y" }] },
  toolUseResult: { agentId: id, status: "async_launched", isAsync: true },
});
const notified = (id, status, summary, ts = "2026-09-07T11:30:00.000Z") => ({
  type: "user", timestamp: ts,
  message: { role: "user", content: `<task-notification>\n<task-id>${id}</task-id>\n<tool-use-id>toolu_x</tool-use-id>\n<output-file>/tmp/x.output</output-file>\n<status>${status}</status>\n<summary>${summary}</summary>\n</task-notification>` },
});
const base = () => ({ agentId: "a1", done: new Set(), launched: new Set(["a1"]), coveredFrom: 0, parentState: "read", nowMs: NOW, staleMs: SUBAGENT_STALE_MS });

test("語彙: failed は 6 つ目の状態で、表示語は Failed", () => {
  assert.deepEqual(SUBAGENT_STATES, ["finished", "running", "stalled", "unknown", "stopped", "failed"]);
  assert.equal(SUBAGENT_STATE_TEXT.failed, "Failed");
});

test("stateOf: 親転写の failed(通知の後 転写が動いていない)→ failed / agent-failed", () => {
  assert.deepEqual(stateOf({ ...base(), failedAt: NOW - 60_000, lastActivityMs: NOW - 61_000 }), { state: "failed", reason: "agent-failed" });
  assert.deepEqual(stateOf({ ...base(), failedAt: true, lastActivityMs: NOW - 1000 }), { state: "failed", reason: "agent-failed" }, "通知の時刻が読めなければ通知を信じる");
});

test("stateOf: 再開(通知の後に転写が動いた)→ running。completed は failed より上。killed は failed より上", () => {
  assert.deepEqual(stateOf({ ...base(), failedAt: NOW - 60_000, lastActivityMs: NOW - 1000 }), { state: "running", reason: "no-result-active" });
  assert.deepEqual(stateOf({ ...base(), done: new Set(["a1"]), failedAt: NOW - 60_000, lastActivityMs: NOW - 61_000 }), { state: "finished", reason: "parent-completed" });
  assert.deepEqual(stateOf({ ...base(), killedAt: NOW - 60_000, failedAt: NOW - 60_000, lastActivityMs: NOW - 61_000 }), { state: "stopped", reason: "stopped-by-user" });
});

test("一覧: 本物の形の failed 通知 → failed / 'Failed'、counts.failed に数える。note に '1 failed'", () => {
  const w = world({ parentLines: [launched("a1"), launched("a2"), notified("a1", "failed", REAL_SUMMARY)], agents: [{ id: "a1", mtimeSecAgo: 31 * 60 }, { id: "a2", mtimeSecAgo: 2 }] });
  const r = readSubagentsFromPath(w.parent, { nowMs: NOW });
  const a1 = r.agents.find((a) => a.agentId === "a1"), a2 = r.agents.find((a) => a.agentId === "a2");
  assert.deepEqual([a1.state, a1.reason, a1.display.state], ["failed", "agent-failed", "Failed"]);
  assert.equal(a2.state, "running");
  assert.deepEqual(r.counts, { finished: 0, running: 1, stalled: 0, unknown: 0, stopped: 0, failed: 1 });
  assert.match(subagentsNote({ agents: r.agents, directory: "read", parent: "read", truncated: false }), /^2 subagents, 1 working, 1 failed\. /);
});

test("★否定対照: 背景シェル / Monitor の failed は id が agent の転写と重ならないので行にならず、agent の行にも触らない(id で束ねる、文は読まない)", () => {
  const w = world({ parentLines: [launched("a1"), notified("bo357kwj2", "failed", 'Background command "Sleep for ~240 seconds in background" failed with exit code 144'), notified("mon1", "failed", 'Monitor "wait" script failed (exit 144)')], agents: [{ id: "a1", mtimeSecAgo: 5 }] });
  const r = readSubagentsFromPath(w.parent, { nowMs: NOW });
  assert.equal(r.agents.length, 1);
  assert.equal(r.agents[0].state, "running");
  assert.equal(r.counts.failed, 0);
});

test("★再開(Codex #4/#5): failed の後に親転写へ起動の記録が書かれた = 再開 → 終端を捨てて mtime で読む(時刻の推定に依らない)", () => {
  const w = world({ parentLines: [launched("a1"), notified("a1", "failed", REAL_SUMMARY, "2026-09-07T11:20:00.000Z"), launched("a1")], agents: [{ id: "a1", mtimeSecAgo: 45 * 60 }] });
  const a1 = readSubagentsFromPath(w.parent, { nowMs: NOW }).agents[0];
  assert.notEqual(a1.state, "failed");
  assert.equal(a1.reason, "no-result-idle", "転写は 45 分前 = stalled(mtime の 3 値)");
});

test("一覧: 最後の終端が勝つ —— failed の後の completed は finished、completed の後の failed は failed", () => {
  const w1 = world({ parentLines: [launched("a1"), notified("a1", "failed", REAL_SUMMARY, "2026-09-07T11:10:00.000Z"), notified("a1", "completed", "done", "2026-09-07T11:20:00.000Z")], agents: [{ id: "a1", mtimeSecAgo: 31 * 60 }] });
  assert.equal(readSubagentsFromPath(w1.parent, { nowMs: NOW }).agents[0].state, "finished");
  // 転写の最終書き込み(11:15)は failed の通知(11:20)より前 = 再開していない
  const w2 = world({ parentLines: [launched("a1"), notified("a1", "completed", "done", "2026-09-07T11:10:00.000Z"), notified("a1", "failed", REAL_SUMMARY, "2026-09-07T11:20:00.000Z")], agents: [{ id: "a1", mtimeSecAgo: 45 * 60 }] });
  assert.equal(readSubagentsFromPath(w2.parent, { nowMs: NOW }).agents[0].state, "failed");
});

test("★否定対照: 空の counts の形にも failed が在る(鍵が常に在る)", () => {
  const w = world({ parentLines: [], agents: [] });
  assert.deepEqual(readSubagentsFromPath(w.parent, { nowMs: NOW }).counts, { finished: 0, running: 0, stalled: 0, unknown: 0, stopped: 0, failed: 0 });
});

test("電話の模型は failed を optional で持つ。ios/ が隣に無い写しの木では測らない", (t) => {
  const swiftPath = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "ios", "Sources", "Core", "SubagentModels.swift");
  if (!existsSync(swiftPath)) { t.skip("ios/ is not beside rc-backend (copied tree)"); return; }
  assert.match(readFileSync(swiftPath, "utf8"), /let failed: Int\?/);
});
