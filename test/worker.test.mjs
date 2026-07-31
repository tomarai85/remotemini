// ワーカー管理の状態機械 — テスト先行。spawn は注入(実プロセスを起動しない)。
//
// 契約(spec「ワーカー管理の契約」= DESIGN.md D3):
//   - 1セッション1ワーカー。二重 spawn 構造的に不可
//   - idle timeout で kill、次メッセージで再 spawn(--resume 前提なので状態は失われない)
//   - 異常終了(exit≠0)は error イベントとして流し、次メッセージで再 spawn
//   - interrupt = kill(明示)
//   - 実行状態の真実はワーカーのイベント/プロセス状態(jsonl から推測しない)
import { test } from "node:test";
import assert from "node:assert/strict";
import { WorkerManager } from "../src/worker.mjs";
import { EventEmitter } from "node:events";

// 注入用の偽 claude プロセス。stdin 書き込みを記録し、テストから NDJSON 行を吐ける。
class FakeProc extends EventEmitter {
  constructor() {
    super();
    this.written = [];
    this.killed = false;
    this.stdout = new EventEmitter();
    this.stderr = new EventEmitter();
    this.stdin = {
      write: (s) => { this.written.push(s); return true; },
      on: () => {},
      end: () => {},
    };
    this.exitCode = null;
  }
  kill(sig) { this.killed = sig || "SIGTERM"; this.exitCode = null; this.emit("close", null, sig || "SIGTERM"); }
  emitLine(obj) { this.stdout.emit("data", Buffer.from(JSON.stringify(obj) + "\n")); }
  exit(code) { this.exitCode = code; this.emit("close", code, null); }
}

function makeMgr(overrides = {}) {
  const spawned = [];
  const mgr = new WorkerManager({
    spawn: (sessionId) => {
      const p = new FakeProc();
      p.sessionId = sessionId;
      spawned.push(p);
      return p;
    },
    idleMs: overrides.idleMs ?? 60_000,
    now: overrides.now,
  });
  return { mgr, spawned };
}

test("send はワーカーを spawn し、user turn を stream-json 形式で書く", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "こんにちは");
  assert.equal(spawned.length, 1);
  const msg = JSON.parse(spawned[0].written[0]);
  assert.equal(msg.type, "user");
  assert.equal(msg.message.content[0].text, "こんにちは");
});

test("同一セッションへの連投は同じワーカーを使う(1セッション1ワーカー)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  mgr.send("s1", "b"); // a が busy の間は queue される(契約: FIFO、二重書き込みしない)
  assert.equal(spawned.length, 1);
  assert.equal(spawned[0].written.length, 1);
  assert.equal(mgr.status("s1").queued, 1);
});

test("別セッションは別ワーカー", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  mgr.send("s2", "b");
  assert.equal(spawned.length, 2);
});

test("ワーカーの NDJSON 行はセッションのリングへ seq 付きで積まれる", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  spawned[0].emitLine({ type: "assistant", message: { content: [{ type: "text", text: "回" }] } });
  spawned[0].emitLine({ type: "result", result: "回" });
  const evs = mgr.eventsSince("s1", 0);
  assert.equal(evs.length >= 2, true);
  assert.equal(evs[evs.length - 1].data.type, "result");
});

test("異常終了は error イベントになり、次の send で再 spawn する", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  spawned[0].exit(1);
  const evs = mgr.eventsSince("s1", 0);
  assert.ok(evs.some((e) => e.data.type === "worker_error"));
  mgr.send("s1", "b");
  assert.equal(spawned.length, 2); // 再 spawn
});

test("interrupt はワーカーを kill し、状態 idle に戻る", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  assert.equal(mgr.status("s1").worker, "running");
  mgr.interrupt("s1");
  assert.ok(spawned[0].killed);
  assert.equal(mgr.status("s1").worker, "none");
});

test("result 受信で busy→ready。busy 中の send は queue され、result 後に流れる", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  assert.equal(mgr.status("s1").state, "busy");
  mgr.send("s1", "b"); // busy 中
  assert.equal(spawned[0].written.length, 1); // まだ書かれない
  spawned[0].emitLine({ type: "result", result: "ok-a" });
  assert.equal(mgr.status("s1").state, "busy"); // queue の b が流れて再び busy
  assert.equal(spawned[0].written.length, 2);
  spawned[0].emitLine({ type: "result", result: "ok-b" });
  assert.equal(mgr.status("s1").state, "ready");
});

test("idle timeout: ready のまま idleMs 経過で kill(sweep 呼び出しで発火)", () => {
  let t = 1000;
  const { mgr, spawned } = makeMgr({ idleMs: 500, now: () => t });
  mgr.send("s1", "a");
  spawned[0].emitLine({ type: "result", result: "ok" });
  t += 501;
  mgr.sweep();
  assert.ok(spawned[0].killed);
  assert.equal(mgr.status("s1").worker, "none");
});

test("busy 中は idle timeout の対象にならない", () => {
  let t = 1000;
  const { mgr, spawned } = makeMgr({ idleMs: 500, now: () => t });
  mgr.send("s1", "a"); // busy のまま
  t += 10_000;
  mgr.sweep();
  assert.ok(!spawned[0].killed);
});

test("stdout の断片行(改行を跨ぐ chunk)を正しく組み立てる", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  const line = JSON.stringify({ type: "result", result: "分割" }) + "\n";
  spawned[0].stdout.emit("data", Buffer.from(line.slice(0, 5)));
  spawned[0].stdout.emit("data", Buffer.from(line.slice(5)));
  const evs = mgr.eventsSince("s1", 0);
  assert.equal(evs[evs.length - 1].data.result, "分割");
});
