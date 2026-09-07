// subagent-stopped-state.test.mjs — 止められた subagent は 5 つ目の状態 `stopped` で返す(2026-09-07 round 11、Codex #9)。
//
// 何が問題だったか: round 10 は机が止めた agent を `finished` + reason `stopped-by-desk` で返した。`finished` は成功の完了と読まれうる
//   (counts.finished に混ざる / 電話の filter は state で分ける)。止められた事は別の終端状態。
// 2 つの源: (a) 机の観測(`DeskStopMemory`、x を押して行が減った)= reason `stopped-by-desk` /
//          (b) 親転写の `<task-notification>` の `<status>killed</status>`(Claude Code 自身が「stopped by user」と書く。研究の判定
//              `subagent-stop-cause-binding-verdict.md`)= reason `stopped-by-user`。(b) は机の再起動でも消えず、机以外(Mac の鍵盤)の
//          停止も拾う。順位: 転写の記録(completed / killed)> 机の観測 > mtime。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { readSubagentsFromPath, stateOf, DeskStopMemory, SUBAGENT_STATES, SUBAGENT_STATE_TEXT, SUBAGENT_STALE_MS } from "../src/subagents.mjs";
import { subagentsNote } from "../src/wire.mjs";

const NOW = Date.parse("2026-09-07T12:00:00.000Z");
const SID = "3b5c9362-aaaa-bbbb-cccc-000000000003";

function world({ parentLines = [], agents = [] } = {}) {
  const base = mkdtempSync(join(tmpdir(), "stopped-state-"));
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
/** 本番 friday 2026-09-07 の実物の形(attic 転写)。 */
const notified = (id, status, summary) => ({
  type: "user", timestamp: "2026-09-07T11:30:00.000Z",
  message: { role: "user", content: `<task-notification>\n<task-id>${id}</task-id>\n<tool-use-id>toolu_x</tool-use-id>\n<output-file>/tmp/x.output</output-file>\n<status>${status}</status>\n<summary>${summary}</summary>\n</task-notification>` },
});
const base = () => ({ agentId: "a1", done: new Set(), launched: new Set(["a1"]), coveredFrom: 0, parentState: "read", nowMs: NOW, staleMs: SUBAGENT_STALE_MS });

test("語彙: stopped は 5 つ目の状態で、表示語は Stopped", () => {
  assert.deepEqual(SUBAGENT_STATES, ["finished", "running", "stalled", "unknown", "stopped", "failed"]);
  assert.equal(SUBAGENT_STATE_TEXT.stopped, "Stopped");
});

test("stateOf: 机の観測(転写が其の後 動いていない)→ stopped / stopped-by-desk(finished ではない)", () => {
  assert.deepEqual(stateOf({ ...base(), lastActivityMs: NOW - 30_000, deskStoppedAt: NOW - 20_000 }), { state: "stopped", reason: "stopped-by-desk" });
});

test("stateOf: 親転写の killed(通知の後 転写が動いていない)→ stopped / stopped-by-user", () => {
  assert.deepEqual(stateOf({ ...base(), killedAt: NOW - 60_000, lastActivityMs: NOW - 61_000 }), { state: "stopped", reason: "stopped-by-user" });
  assert.deepEqual(stateOf({ ...base(), killedAt: true, lastActivityMs: NOW - 1000 }), { state: "stopped", reason: "stopped-by-user" }, "通知の時刻が読めなければ通知を信じる");
});

test("★再開(Codex): killed の通知より後に転写が動いた(猶予を超えて)→ 再開した = running(stopped と言わない)", () => {
  assert.deepEqual(stateOf({ ...base(), killedAt: NOW - 60_000, lastActivityMs: NOW - 1000 }), { state: "running", reason: "no-result-active" });
});

test("stateOf: completed は killed より上(再開して完了した agent)", () => {
  assert.deepEqual(stateOf({ ...base(), done: new Set(["a1"]), killedAt: NOW - 60_000, lastActivityMs: NOW - 61_000 }), { state: "finished", reason: "parent-completed" });
});

test("stateOf: killed が無く、机の観測の後に転写が動いた → running(嘘にしない)", () => {
  assert.deepEqual(stateOf({ ...base(), lastActivityMs: NOW - 5_000, deskStoppedAt: NOW - 20_000 }), { state: "running", reason: "no-result-active" });
});

test("一覧: killed の通知が在る agent は stopped / 'Stopped'、counts.stopped に数え、finished には数えない", () => {
  // 通知は 11:30、a1 の転写は 11:29(通知より前)= 止まったまま。a2 は 2 秒前まで動いている。
  const w = world({ parentLines: [launched("a1"), launched("a2"), notified("a1", "killed", 'Agent "count slowly" was stopped by user')], agents: [{ id: "a1", mtimeSecAgo: 31 * 60 }, { id: "a2", mtimeSecAgo: 2 }] });
  const r = readSubagentsFromPath(w.parent, { nowMs: NOW });
  const a1 = r.agents.find((a) => a.agentId === "a1"), a2 = r.agents.find((a) => a.agentId === "a2");
  assert.equal(a1.state, "stopped"); assert.equal(a1.reason, "stopped-by-user"); assert.equal(a1.display.state, "Stopped");
  assert.equal(a2.state, "running");
  assert.deepEqual(r.counts, { finished: 0, running: 1, stalled: 0, unknown: 0, stopped: 1, failed: 0 });
});

test("一覧: 机の記憶からも stopped / stopped-by-desk。completed の通知は finished のまま(成功の完了と混ぜない)", () => {
  const w = world({ parentLines: [launched("a1"), launched("a2"), notified("a2", "completed", "done")], agents: [{ id: "a1", mtimeSecAgo: 40 }, { id: "a2", mtimeSecAgo: 40 }] });
  const m = new DeskStopMemory(); m.record(w.parent, "a1", NOW - 30_000);
  const r = readSubagentsFromPath(w.parent, { nowMs: NOW, deskStopped: m.for(w.parent, NOW) });
  const a1 = r.agents.find((a) => a.agentId === "a1"), a2 = r.agents.find((a) => a.agentId === "a2");
  assert.deepEqual([a1.state, a1.reason, a1.display.state], ["stopped", "stopped-by-desk", "Stopped"]);
  assert.deepEqual([a2.state, a2.reason, a2.display.state], ["finished", "parent-completed", "Finished"]);
  assert.deepEqual(r.counts, { finished: 1, running: 0, stalled: 0, unknown: 0, stopped: 1, failed: 0 });
});

test("一覧: 背景シェルの形の failed(`Background command …`)は agent の終端ではない —— mtime で読む(round 12: agent の failed は別の検査)", () => {
  const w = world({ parentLines: [launched("a1"), notified("a1", "failed", "Background command failed with exit code 144")], agents: [{ id: "a1", mtimeSecAgo: 5 }] });
  const a1 = readSubagentsFromPath(w.parent, { nowMs: NOW }).agents[0];
  assert.equal(a1.state, "running");
});

test("note: stopped は文に出る('1 stopped')、finished の数とは別", () => {
  const rows = [{ agentId: "a1", state: "stopped" }, { agentId: "a2", state: "running" }];
  const note = subagentsNote({ agents: rows, directory: "read", parent: "read", truncated: false });
  assert.match(note, /^2 subagents, 1 working, 1 stopped\. /);
});

test("★否定対照: 空の counts の形にも stopped が在る(鍵が常に在る = 電話の台帳と一致)", () => {
  const w = world({ parentLines: [], agents: [] });
  const r = readSubagentsFromPath(w.parent, { nowMs: NOW });
  assert.deepEqual(r.counts, { finished: 0, running: 0, stalled: 0, unknown: 0, stopped: 0, failed: 0 });
});

test("電話の模型は stopped を optional で持つ(古い机の応答も読める)。ios/ が隣に無い写しの木では測らない", (t) => {
  const swiftPath = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "ios", "Sources", "Core", "SubagentModels.swift");
  if (!existsSync(swiftPath)) { t.skip("ios/ is not beside rc-backend (copied tree)"); return; }
  assert.match(readFileSync(swiftPath, "utf8"), /let stopped: Int\?/);
});


test("一覧: killed の通知の後に転写が動いた agent(再開)は running(通知を鵜呑みにしない)", () => {
  const w = world({ parentLines: [launched("a1"), notified("a1", "killed", 'Agent "count slowly" was stopped by user')], agents: [{ id: "a1", mtimeSecAgo: 5 }] });
  const a1 = readSubagentsFromPath(w.parent, { nowMs: NOW }).agents[0];
  assert.deepEqual([a1.state, a1.reason], ["running", "no-result-active"]);
});

// ── Codex 2026-09-07(stopped-state)の所見を畳んだ 3 本 ─────────────────────────
test("★歴史(Codex #1): 終端は最後の記録が勝つ —— completed の後の killed は stopped、killed の後の completed は finished", () => {
  const w1 = world({ parentLines: [launched("a1"), notified("a1", "completed", "done"), notified("a1", "killed", "stopped by user")], agents: [{ id: "a1", mtimeSecAgo: 31 * 60 }] });
  const r1 = readSubagentsFromPath(w1.parent, { nowMs: NOW }).agents[0];
  assert.deepEqual([r1.state, r1.reason], ["stopped", "stopped-by-user"]);
  const w2 = world({ parentLines: [launched("a1"), notified("a1", "killed", "stopped by user"), notified("a1", "completed", "done")], agents: [{ id: "a1", mtimeSecAgo: 31 * 60 }] });
  const r2 = readSubagentsFromPath(w2.parent, { nowMs: NOW }).agents[0];
  assert.deepEqual([r2.state, r2.reason], ["finished", "parent-completed"]);
});

test("★帰属(Codex #3): 机が止めた agent は親転写にも killed が書かれるが、机の観測が在れば reason は stopped-by-desk", () => {
  const w = world({ parentLines: [launched("a1"), notified("a1", "killed", "stopped by user")], agents: [{ id: "a1", mtimeSecAgo: 31 * 60 }] });
  const m = new DeskStopMemory(); m.record(w.parent, "a1", NOW - 31 * 60_000 + 2000);
  const a1 = readSubagentsFromPath(w.parent, { nowMs: NOW, deskStopped: m.for(w.parent, NOW) }).agents[0];
  assert.deepEqual([a1.state, a1.reason], ["stopped", "stopped-by-desk"]);
});

test("★親が読めない(Codex #7): 机の観測が有効なら stopped-by-desk、無ければ unknown", () => {
  assert.deepEqual(stateOf({ ...base(), parentState: "unreadable", lastActivityMs: NOW - 30_000, deskStoppedAt: NOW - 20_000 }), { state: "stopped", reason: "stopped-by-desk" });
  assert.deepEqual(stateOf({ ...base(), parentState: "unreadable", lastActivityMs: NOW - 30_000 }), { state: "unknown", reason: "parent-unreadable" });
});
