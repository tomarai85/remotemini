// worker 経路の 202 は子が**最初の行を出した後**(2026-09-06、対照表 #8 の隣の欠陥 `1b81f79` の続き)。
// 1) WorkerManager.spawnAck の 4 値(ready / reused / failed / unconfirmed)を偽の子で測る。
//    ★`spawn` 事象では確定しない: 起きた直後に exit 23 で死ぬ launcher が 202 になる(Codex 2026-09-06、実 ChildProcess で再現)。
// 2) server.mjs の送信の口が **202 の前に** spawnAck を待ち、failed を 409 `spawn_failed` で断る構造を測る。
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { WorkerManager } from "../src/worker.mjs";
import { WORKER_REFUSAL } from "../src/blocked.mjs";

class FakeProc extends EventEmitter {
  constructor() {
    super();
    this.written = [];
    this.stdout = new EventEmitter();
    this.stderr = new EventEmitter();
    this.stdin = { write: (s) => { this.written.push(s); return true; }, on: () => {}, end: () => {} };
  }
  kill() {}
  line(obj) { this.stdout.emit("data", Buffer.from(JSON.stringify(obj) + "\n")); }
  exit(code, signal = null) { this.emit("exit", code, signal); this.emit("close", code, signal); }
}
function mgr() {
  const spawned = [];
  const events = [];
  const m = new WorkerManager({ spawn: (sessionId, opts) => { const p = new FakeProc(); p.opts = opts; spawned.push(p); return p; }, idleMs: 60_000 });
  return { m, spawned, events, on: (s, d) => events.push(d) };
}
const OPTS = (on) => ({ onEvent: on, cwd: "/tmp", launcher: "/x/claude-work" });

test("★子の最初の行を見てから ready(spawn 事象だけでは決まらない)", async () => {
  const { m, spawned, on } = mgr();
  m.send("s1", "hi", OPTS(on));
  const p = m.spawnAck("s1", { timeoutMs: 500 });
  let settled = false; p.then(() => { settled = true; });
  spawned[0].emit("spawn");
  await new Promise((r) => setImmediate(r));
  assert.equal(settled, false, "spawn 事象では決まらない(起きた直後に死ぬ launcher を通してしまう)");
  spawned[0].line({ type: "system", subtype: "init", session_id: "abc" });
  assert.deepEqual(await p, { status: "ready", error: null });
  assert.equal(settled, true);
});

test("★起きた直後に exit 23 → failed(worker_error は別に流れ、entry は外れ、次の send は新しい子)", async () => {
  const { m, spawned, events, on } = mgr();
  m.send("s1", "hi", OPTS(on));
  const p = m.spawnAck("s1", { timeoutMs: 500 });
  spawned[0].emit("spawn");
  spawned[0].exit(23);
  const r = await p;
  assert.equal(r.status, "failed");
  assert.match(r.error, /before its first line/);
  assert.equal(events.filter((e) => e.type === "worker_error").length, 1);
  assert.equal(m.workers.has("s1"), false);
  // entry が外れた後に聞かれても failed と答える(口が send の後に聞く順序でも取りこぼさない)
  assert.equal((await m.spawnAck("s1", { timeoutMs: 50 })).status, "failed");
  // 次の send は新しい子 → 其の受領は改めて待つ
  m.send("s1", "again", OPTS(on));
  assert.equal(spawned.length, 2);
  spawned[1].line({ type: "system", subtype: "init" });
  assert.equal((await m.spawnAck("s1", { timeoutMs: 500 })).status, "ready");
});

test("★exit 0 でも最初の行の前なら failed(番を処理していない)", async () => {
  const { m, spawned, on } = mgr();
  m.send("s1", "hi", OPTS(on));
  const p = m.spawnAck("s1", { timeoutMs: 500 });
  spawned[0].exit(0);
  assert.equal((await p).status, "failed");
});

test("spawn の error 事象(ENOENT)→ failed、文は伏せて運ぶ", async () => {
  const { m, spawned, events, on } = mgr();
  m.send("s1", "hi", OPTS(on));
  const p = m.spawnAck("s1", { timeoutMs: 500 });
  const err = new Error("spawn /x/claude-work ENOENT"); err.code = "ENOENT";
  spawned[0].emit("error", err);
  const r = await p;
  assert.equal(r.status, "failed");
  assert.match(r.error, /ENOENT/);
  assert.equal(events.filter((e) => e.type === "worker_error").length, 1);
});

test("既に起きている子へ書いた時は reused(待たない)", async () => {
  const { m, spawned, on } = mgr();
  m.send("s1", "one", OPTS(on));
  spawned[0].line({ type: "system", subtype: "init" });
  assert.equal((await m.spawnAck("s1", { timeoutMs: 500 })).status, "ready");
  m.send("s1", "two", OPTS(on));
  assert.equal(spawned.length, 1);
  assert.deepEqual(await m.spawnAck("s1", { timeoutMs: 500 }), { status: "reused", error: null });
});

test("★期限内に行も死も来なければ unconfirmed(失敗ではない)。受領は未了のまま = 次に聞けばもう一度待つ", async () => {
  const { m, spawned, on } = mgr();
  m.send("s1", "hi", OPTS(on));
  assert.deepEqual(await m.spawnAck("s1", { timeoutMs: 30 }), { status: "unconfirmed", error: null });
  const p = m.spawnAck("s1", { timeoutMs: 500 });
  spawned[0].line({ type: "system", subtype: "init" });
  assert.equal((await p).status, "ready");
});

test("知らない会話は reused(何も起こしていない = 待つ物が無い)、断りの文は語彙に在る", async () => {
  const { m } = mgr();
  assert.deepEqual(await m.spawnAck("nope", { timeoutMs: 30 }), { status: "reused", error: null });
  assert.match(WORKER_REFUSAL.spawn_failed, /nothing was sent/i);
});

// ---- 構造: 送信の口(server.mjs)-----------------------------------------------------------
const SRC = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.mjs"), "utf8");
function workerRoute(s) {
  const i = s.indexOf("// 机で開かれていない会話");
  const end = s.indexOf('route: "worker", seq', i);
  return i >= 0 && end >= 0 ? s.slice(i, end) : null;
}

test("★口は manager.send の後・202 の前に spawnAck を await する", () => {
  const b = workerRoute(SRC);
  assert.ok(b, "worker 経路の本文が見つかる");
  const send = b.indexOf("manager.send(");
  const ack = b.indexOf("await manager.spawnAck(");
  assert.ok(send >= 0 && ack > send, "spawnAck は send の後");
  assert.ok(/ack\.status === "failed"/.test(b), "failed を見る");
  assert.ok(/reason: "spawn_failed"/.test(b) && /WORKER_REFUSAL\.spawn_failed/.test(b), "409 spawn_failed で断る");
  assert.ok(/idem\.abandon\(sendId\)/.test(b.slice(ack)), "断る時は sendId の札を捨てる(撃ち直せる)");
});

test("202 の本文は受領を名乗る(ready / reused / unconfirmed)", () => {
  assert.ok(/route: "worker", seq, spawn: ack\.status/.test(SRC));
  assert.ok(/WORKER_SPAWN_ACK_MS = Math\.max\(50, Number\(process\.env\.RC_WORKER_SPAWN_ACK_MS \|\| 3000\)\)/.test(SRC));
});
