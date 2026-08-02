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
    this.signals = []; // 撃った信号の並び。SIGTERM → SIGKILL の順を測る為
    this.stdout = new EventEmitter();
    this.stderr = new EventEmitter();
    this.stdin = {
      write: (s) => { this.written.push(s); return true; },
      on: () => {},
      end: () => {},
    };
    this.exitCode = null;
  }
  // ★kill は「撃った」だけ。**死んだ事にはしない**(DESIGN §2.18-10(4))。
  //   SIGTERM は非同期で、handler が居れば流し終えるまで生きている。ここで close を
  //   その場で出すと「撃った = 死んだ」という現実に無い前提を検査が内蔵してしまう。
  kill(sig) { this.signals.push(sig || "SIGTERM"); this.killed = sig || "SIGTERM"; }
  emitLine(obj) { this.stdout.emit("data", Buffer.from(JSON.stringify(obj) + "\n")); }
  /** 実際に死んだ。Node は `exit` → `close` の順に出す。 */
  exit(code, signal = null) {
    this.exitCode = code;
    this.emit("exit", code, signal);
    this.emit("close", code, signal);
  }
}

function makeMgr(overrides = {}) {
  const spawned = [];
  const timers = [];
  const heads = overrides.heads;
  const mgr = new WorkerManager({
    spawn: (sessionId, opts) => {
      const p = new FakeProc();
      p.sessionId = sessionId;
      p.opts = opts;
      spawned.push(p);
      return p;
    },
    idleMs: overrides.idleMs ?? 60_000,
    now: overrides.now,
    heads,
    killGraceMs: overrides.killGraceMs,
    // 偽タイマー。実時間を待たずに猶予切れを起こす。
    setTimer: (fn, ms) => { const t = { fn, ms, cleared: false }; timers.push(t); return t; },
    clearTimer: (t) => { if (t) t.cleared = true; },
  });
  return { mgr, spawned, timers, fireTimers: () => timers.filter((t) => !t.cleared).forEach((t) => t.fn()) };
}

/** 頭の登録簿の偽物。呼ばれた回数と中身を記録する。 */
function makeHeads(initial = {}) {
  const store = { ...initial };
  const writes = [];
  return {
    store,
    writes,
    read: (ancestor) => store[ancestor] || "",
    write: (ancestor, head) => { writes.push([ancestor, head]); store[ancestor] = head; },
  };
}

const SID = "aaaaaaaa-1111-2222-3333-444444444444";
const NEW = "bbbbbbbb-5555-6666-7777-888888888888";
const HEAD = "cccccccc-9999-0000-1111-222222222222";

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

// ---- H2: 転写ファイルの書き手を1人に保つ ------------------------------------
// DESIGN.md §2.18-4〜6 と §2.18-10。既定の `--resume` は**元の ID を再利用する**ので、
// ワーカーと机の TUI が同じ転写 JSONL へ書く = 破壊。だからワーカーは fork して自分の枝を
// 持ち、2通目以降はその枝の先端へ resume する。
//
// ★4/5/6 は「無い事」の検査なので、対照(変異)無しでは常に緑になり得る。
//   変異 X1-X5 を `test/mutation-controls.py` に先に登録してある。

test("H2-1: 頭が無い初回は fork する(resumeId = 祖先)", () => {
  const heads = makeHeads();
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  assert.equal(spawned[0].opts.fork, true);
  assert.equal(spawned[0].opts.resumeId, SID);
});

test("H2-2: 頭が有れば fork せず、その枝の先端へ resume する", () => {
  const heads = makeHeads({ [SID]: HEAD });
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  assert.equal(spawned[0].opts.fork, false);
  assert.equal(spawned[0].opts.resumeId, HEAD);
});

test("H2-3: fork した子が名乗った新 ID を頭として書く", () => {
  const heads = makeHeads();
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  spawned[0].emitLine({ type: "system", subtype: "init", session_id: NEW });
  assert.deepEqual(heads.writes, [[SID, NEW]]);
  // 2回目以降の名乗り(result にも session_id が載る)で書き直さない
  spawned[0].emitLine({ type: "result", session_id: NEW, result: "ok" });
  assert.equal(heads.writes.length, 1);
});

test("H2-3b: fork していない時は名乗りを頭として書かない(無駄書きしない)", () => {
  const heads = makeHeads({ [SID]: HEAD });
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  spawned[0].emitLine({ type: "system", subtype: "init", session_id: HEAD });
  assert.deepEqual(heads.writes, []);
});

test("★H2-4b: 死んだ子に遅れて届いた名乗りは頭にしない(次を spawn していないので世代は同じ)", () => {
  // ★この場面は**同一性の検査だけ**が捕まえる。世代は進んでいない(再 spawn していない)ので
  //   世代照合は素通りする。X2(同一性を外す変異)が素通りしたのは、この検査が無かったから。
  const heads = makeHeads();
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  assert.equal(mgr.gens.get(SID), 1);
  spawned[0].exit(1);                    // 落ちた。再 spawn はまだしていない
  assert.equal(mgr.gens.get(SID), 1, "この検査は世代を進めない事が前提");
  spawned[0].emitLine({ type: "system", subtype: "init", session_id: NEW });
  assert.deepEqual(heads.writes, [], "死んだ子の枝を頭にすると、次はその死んだ枝へ resume する");
});

test("★H2-12: 退役が2人居て1人しか死を確認できていない間は、まだ分岐する", () => {
  // ★「未確認の先代」を**1件しか覚えない**形だと、ここで resume に戻ってしまう。
  //   先に死んだ方の頭の書き込みが失敗していれば、頭は**生きている方の枝**を指したままなので
  //   同じファイルに書き手が2人 = H2 そのもの。
  const heads = makeHeads({ [SID]: HEAD });
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  mgr.interrupt(SID);            // e1: 未確認
  mgr.send(SID, "b");
  mgr.interrupt(SID);            // e2: 未確認(e1 はまだ未確認のまま)
  spawned[1].exit(0, "SIGTERM"); // e2 だけ死を確認
  mgr.send(SID, "c");
  assert.equal(spawned.length, 3);
  assert.equal(spawned[2].opts.fork, true, "e1 の死が未確認なのに resume に戻っている");
});

test("★H2-4: 退役した entry に届いた名乗りは頭にしない", () => {
  const heads = makeHeads();
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  mgr.interrupt(SID); // retired = true を kill より先に立てる
  spawned[0].emitLine({ type: "system", subtype: "init", session_id: NEW });
  assert.deepEqual(heads.writes, [], "退役後の名乗りを書くと、居なくなった子の枝へ次を resume する");
});

test("★H2-5: 別の entry に差し替わった後に届いた古い名乗りは頭にしない", () => {
  const heads = makeHeads();
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  const old = spawned[0];
  old.exit(1);         // 落ちた
  mgr.send(SID, "b");  // 再 spawn(新しい entry)
  assert.equal(spawned.length, 2);
  const beforeLen = heads.writes.length;
  old.emitLine({ type: "system", subtype: "init", session_id: NEW }); // 遅れて届いた古い名乗り
  assert.equal(heads.writes.length, beforeLen, "古い子の名乗りが新しい子の頭を上書きしてはいけない");
});

test("★H2-6: 世代が進んでいたら頭を書かない(同期前提を外した時の守り)", () => {
  const heads = makeHeads();
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  const entry = mgr.workers.get(SID);
  // Map 上の同一性も retired も動かさず、世代だけを進める = 同一性の検査だけでは通ってしまう形。
  mgr.gens.set(SID, mgr.gens.get(SID) + 1);
  spawned[0].emitLine({ type: "system", subtype: "init", session_id: NEW });
  assert.equal(mgr.workers.get(SID), entry, "この検査は同一性を壊さない事が前提");
  assert.deepEqual(heads.writes, [], "世代照合が無ければここが緑にならない");
});

test("★H2-7: 死が未確認の先代が居る間は、頭が有っても fork する", () => {
  const heads = makeHeads({ [SID]: HEAD });
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  mgr.interrupt(SID);           // SIGTERM は撃つが exit はまだ来ない
  mgr.send(SID, "b");           // 再起動 — ★ここで待たない
  assert.equal(spawned.length, 2);
  assert.equal(spawned[1].opts.fork, true, "先代が生きているかもしれない枝へ resume すると書き手が2人になる");
  assert.equal(spawned[1].opts.resumeId, HEAD, "分岐元は最新の枝先端(祖先へ戻らない)");
});

test("H2-8: 先代の exit が来たら、次の再起動は resume に戻る", () => {
  const heads = makeHeads({ [SID]: HEAD });
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  mgr.interrupt(SID);
  spawned[0].exit(0, "SIGTERM"); // 死んだ事が確認できた
  mgr.send(SID, "b");
  assert.equal(spawned[1].opts.fork, false);
  assert.equal(spawned[1].opts.resumeId, HEAD);
});

test("H2-9: 猶予を過ぎても exit が来なければ SIGKILL を撃つ(送信は待たされない)", () => {
  const heads = makeHeads();
  const { mgr, spawned, fireTimers } = makeMgr({ heads, killGraceMs: 5000 });
  mgr.send(SID, "a");
  mgr.interrupt(SID);
  assert.deepEqual(spawned[0].signals, ["SIGTERM"]);
  fireTimers();
  assert.deepEqual(spawned[0].signals, ["SIGTERM", "SIGKILL"]);
});

test("H2-9b: exit が来たら猶予タイマーは取り消す(死体に SIGKILL を撃たない)", () => {
  const heads = makeHeads();
  const { mgr, spawned, timers, fireTimers } = makeMgr({ heads, killGraceMs: 5000 });
  mgr.send(SID, "a");
  mgr.interrupt(SID);
  spawned[0].exit(0, "SIGTERM");
  assert.ok(timers.every((t) => t.cleared), "取り消していないタイマーが残っている");
  fireTimers();
  assert.deepEqual(spawned[0].signals, ["SIGTERM"]);
});

test("H2-10: 頭の書き込みが失敗しても送信は落ちない(次回 fork = 安全側)", () => {
  const heads = makeHeads();
  heads.write = () => { throw new Error("disk full"); };
  const { mgr, spawned } = makeMgr({ heads });
  mgr.send(SID, "a");
  assert.doesNotThrow(() => spawned[0].emitLine({ type: "system", subtype: "init", session_id: NEW }));
  assert.equal(heads.read(SID), "", "書けなかったのだから頭は無いまま = 次は fork");
});

test("H2-11: 頭の登録簿を注入していなくても従来どおり動く(既存の配線を壊さない)", () => {
  const { mgr, spawned } = makeMgr(); // heads 無し
  mgr.send(SID, "a");
  assert.equal(spawned.length, 1);
  assert.doesNotThrow(() => spawned[0].emitLine({ type: "system", session_id: NEW }));
});
