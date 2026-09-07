// subagent-desk-stop-memory.test.mjs — 机が止めたのを見た subagent を、一覧が直ちに `finished`(stopped-by-desk)で返す(2026-09-07)。
//
// 何が起きていたか: 一覧(`GET /subagents`)は転写の mtime で生死を読むので、止めた直後も最長 SUBAGENT_STALE_MS(15 分)
//   「Working」のままだった。電話の帯は "Stopped" と言うのに行は "Working" —— 15 分の矛盾(`SubagentsViewModel.tapStop` の注記)。
//   机は x を押してパネルで行が減ったのを**見ている**(`stopped:"observed"`)ので、其の観測は mtime より強い。
// 守る順位: 転写の終了記録(done)> 机の観測 > mtime。★机の観測の後に転写が動いた(猶予を超えて書かれた)なら止まっていない =
//   記憶を捨てて mtime で読む(嘘にしない)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { readSubagentsFromPath, stateOf, DeskStopMemory, DESK_STOP_GRACE_MS, DESK_STOP_TTL_MS, SUBAGENT_STALE_MS } from "../src/subagents.mjs";

const NOW = Date.parse("2026-09-07T12:00:00.000Z");
const SID = "2b5c9362-aaaa-bbbb-cccc-000000000002";

function world({ parentLines = [], agents = [] } = {}) {
  const base = mkdtempSync(join(tmpdir(), "desk-stop-"));
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
const completed = (id) => ({
  type: "user", timestamp: "2026-09-07T11:30:00.000Z",
  message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_x" }] },
  toolUseResult: { agentId: id, status: "completed", agentType: "general-purpose" },
});
const base = () => ({ agentId: "a1", done: new Set(), launched: new Set(["a1"]), coveredFrom: 0, parentState: "read", nowMs: NOW, staleMs: SUBAGENT_STALE_MS });

// ── stateOf(純関数)──────────────────────────────────────────────────────────
test("机が止めたのを見て、転写が其の後 動いていない → stopped / stopped-by-desk", () => {
  const r = stateOf({ ...base(), lastActivityMs: NOW - 30_000, deskStoppedAt: NOW - 20_000 });
  assert.deepEqual(r, { state: "stopped", reason: "stopped-by-desk" });
});

test("猶予の内側の書き込み(止めた 3 秒後の最後の行)は止まったと読む", () => {
  const r = stateOf({ ...base(), lastActivityMs: NOW - 17_000, deskStoppedAt: NOW - 20_000 });
  assert.equal(r.reason, "stopped-by-desk");
  assert.ok(DESK_STOP_GRACE_MS >= 3_000);
});

test("★否定対照: 止めた後も転写が動いた(猶予を超えて)→ 記憶を捨てて mtime で読む = running", () => {
  const r = stateOf({ ...base(), lastActivityMs: NOW - 5_000, deskStoppedAt: NOW - 20_000 });
  assert.deepEqual(r, { state: "running", reason: "no-result-active" });
});

test("転写の終了記録は机の観測より上(parent-completed が勝つ)", () => {
  const r = stateOf({ ...base(), done: new Set(["a1"]), lastActivityMs: NOW - 30_000, deskStoppedAt: NOW - 20_000 });
  assert.deepEqual(r, { state: "finished", reason: "parent-completed" });
});

test("転写が読めない時は机の観測でも unknown(知らない物を知っていると言わない)。親が読めないだけなら机の観測が生きる(Codex #7)", () => {
  assert.deepEqual(stateOf({ ...base(), parentState: "unreadable", lastActivityMs: NOW - 30_000, deskStoppedAt: NOW - 20_000 }), { state: "stopped", reason: "stopped-by-desk" });
  assert.equal(stateOf({ ...base(), parentState: "unreadable", lastActivityMs: NOW - 30_000 }).state, "unknown", "観測が無ければ従来どおり unknown");
  assert.equal(stateOf({ ...base(), lastActivityMs: null, deskStoppedAt: NOW - 20_000 }).state, "unknown");
});

test("deskStoppedAt が無い / 数でない時は従来どおり(既定 null)", () => {
  assert.deepEqual(stateOf({ ...base(), lastActivityMs: NOW - 30_000 }), { state: "running", reason: "no-result-active" });
  assert.deepEqual(stateOf({ ...base(), lastActivityMs: NOW - 30_000, deskStoppedAt: "soon" }), { state: "running", reason: "no-result-active" });
});

// ── DeskStopMemory ────────────────────────────────────────────────────────────
test("記憶: record → for は写し(Map)を返し、期限(TTL)を過ぎた物は落とす。forget で消える", () => {
  const m = new DeskStopMemory();
  m.record("/t/x.jsonl", "a1", NOW - 1000);
  m.record("/t/x.jsonl", "a2", NOW - DESK_STOP_TTL_MS - 1);
  m.record("/t/y.jsonl", "b1", NOW);
  const x = m.for("/t/x.jsonl", NOW);
  assert.deepEqual([...x.keys()], ["a1"], "期限切れの a2 は落ちる");
  assert.equal(x.get("a1"), NOW - 1000);
  x.set("zz", 1);
  assert.equal(m.for("/t/x.jsonl", NOW).has("zz"), false, "返した Map は写し(外から記憶を書き換えられない)");
  assert.equal(m.for("/t/none.jsonl", NOW).size, 0);
  m.forget("/t/y.jsonl", "b1");
  assert.equal(m.for("/t/y.jsonl", NOW).size, 0);
  assert.equal(m.size, 1);
  m.record(null, "a9"); m.record("/t/x.jsonl", 42);
  assert.equal(m.size, 1, "文字列でない鍵・id は無視");
});

// ── 一覧(readSubagentsFromPath)を通して ───────────────────────────────────────
test("一覧: 机が止めた行は stopped / stopped-by-desk、display.state は 'Stopped'、counts.stopped に数える。隣は Working のまま", () => {
  const w = world({ parentLines: [launched("a1"), launched("a2")], agents: [{ id: "a1", mtimeSecAgo: 40 }, { id: "a2", mtimeSecAgo: 2 }] });
  const m = new DeskStopMemory();
  m.record(w.parent, "a1", NOW - 30_000);
  const r = readSubagentsFromPath(w.parent, { nowMs: NOW, deskStopped: m.for(w.parent, NOW) });
  const a1 = r.agents.find((a) => a.agentId === "a1"), a2 = r.agents.find((a) => a.agentId === "a2");
  assert.equal(a1.state, "stopped"); assert.equal(a1.reason, "stopped-by-desk"); assert.equal(a1.display.state, "Stopped");
  assert.equal(a2.state, "running"); assert.equal(a2.display.state, "Working");
  assert.deepEqual(r.counts, { finished: 0, running: 1, stalled: 0, unknown: 0, stopped: 1 });
});

test("一覧: 記憶が無ければ従来どおり Working(opts.deskStopped 省略 / Map でない物は無視)", () => {
  const w = world({ parentLines: [launched("a1")], agents: [{ id: "a1", mtimeSecAgo: 40 }] });
  assert.equal(readSubagentsFromPath(w.parent, { nowMs: NOW }).agents[0].state, "running");
  assert.equal(readSubagentsFromPath(w.parent, { nowMs: NOW, deskStopped: { a1: NOW } }).agents[0].state, "running");
});

test("一覧: 親が終了を記録していれば parent-completed(机の記憶より上)、display は 'Finished'", () => {
  const w = world({ parentLines: [launched("a1"), completed("a1")], agents: [{ id: "a1", mtimeSecAgo: 40 }] });
  const m = new DeskStopMemory(); m.record(w.parent, "a1", NOW - 30_000);
  const a1 = readSubagentsFromPath(w.parent, { nowMs: NOW, deskStopped: m.for(w.parent, NOW) }).agents[0];
  assert.equal(a1.reason, "parent-completed"); assert.equal(a1.display.state, "Finished");
});

// ── 配線(server.mjs)────────────────────────────────────────────────────────────
test("配線: server は観測した停止(stopped:observed)だけを記憶し、一覧に其の記憶を渡す", () => {
  const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.mjs"), "utf8");
  assert.ok(src.includes('if (out.ok && out.stopped === "observed") deskStops.record(target, stopAgentId, Date.now());'), "停止の成功で記憶する行");
  assert.ok(src.includes("readSubagentsFromPath(target, { deskStopped: deskStops.for(target) })"), "一覧に記憶を渡す行");
  assert.ok(src.includes("const deskStops = new DeskStopMemory();"), "記憶はプロセス内に 1 つ");
});
