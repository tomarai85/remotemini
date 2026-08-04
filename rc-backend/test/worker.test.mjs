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
  // ★前提: **時間の条件は満たしている**(満たしていなければ「殺されない」は当たり前で、
  //   busy を見ている事の証明にならない)。上の `idle timeout` 検査と同じ時計で回す。
  assert.equal(mgr.status("s1").state, "busy", "前提が崩れた(busy でない)");
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
  // ★前提を先に確かめる(2026-08-04、Codex Q3)。「書かなかった」は、**名乗りが処理系に
  //   届いていない**時にも成立する = 何も起きていないのに緑になる形。
  assert.equal(spawned[0].opts.fork, false, "前提が崩れた(fork してしまっている)");
  assert.ok(
    mgr.eventsSince(SID, 0).some((e) => e.data.type === "system"),
    "前提が崩れた(名乗りが処理系に届いていない)",
  );
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
  // ★猶予タイマーが**張られた**事を先に言う。`every` は空配列で true なので、
  //   タイマーを1本も作らない実装でも下の1行は緑になる(2026-08-04、§2.35)。変異 M119 の的。
  assert.ok(timers.length >= 1, "猶予タイマーが張られていない = 取り消しを測れていない");
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

// ---------------------------------------------------------------------------
// 死因を電話へ届ける(DESIGN §2.21 / §2.21-a)。
//
// 直す前: `proc.stderr` は捨てられていて、電話に出るのは `worker exited code=1` だけ。
// claude-work が理由を書いていても**最初から読んでいない** = §2.16 の production 側の同型。
//
// 上限は §2.21-a の値: 溜める側 4KB / 出す側 10行 か 1KB の小さい方。
// ---------------------------------------------------------------------------

/** stderr へ1行流す。改行込み。 */
const err = (p, s) => p.stderr.emit("data", Buffer.from(s + "\n"));
/** 直近の worker_error を取る。 */
const lastError = (mgr, id) =>
  mgr.eventsSince(id, 0).map((e) => e.data).filter((d) => d.type === "worker_error").at(-1);

test("死因の尻尾が worker_error に載る(異常終了)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  err(spawned[0], "Error: --resume 11111111 が解決できませんでした");
  spawned[0].exit(1);
  const ev = lastError(mgr, "s1");
  assert.ok(ev, "worker_error が出ていない");
  assert.deepEqual(ev.stderr, ["Error: --resume 11111111 が解決できませんでした"]);
});

test("★spawn 失敗側にも載る(変異 W26 = 片方だけに付ける)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  err(spawned[0], "spawn claude-work ENOENT");
  spawned[0].emit("error", new Error("spawn claude-work ENOENT"));
  const ev = lastError(mgr, "s1");
  assert.ok(Array.isArray(ev.stderr), "spawn 失敗側に尻尾が無い");
  assert.deepEqual(ev.stderr, ["spawn claude-work ENOENT"]);
});

test("★尾は閉包の entry から読む(変異 W18 = workers Map 経由 → delete 済みで必ず空)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  err(spawned[0], "理由の行");
  spawned[0].exit(1);
  // この時点で workers からは既に消えている。それでも尾は出る。
  assert.equal(mgr.workers.get("s1"), undefined, "前提が崩れた(まだ Map に居る)");
  assert.deepEqual(lastError(mgr, "s1").stderr, ["理由の行"]);
});

test("★何も言わずに死んだ時も欄は出す(空配列。欄が無い事と区別が付かなくなる)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  spawned[0].exit(1);
  assert.deepEqual(lastError(mgr, "s1").stderr, [], "空でも欄ごと落としてはいけない");
});

test("★出すのは末尾10行まで(変異 W25 = 出す側の上限を外す)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  for (let i = 0; i < 40; i++) err(spawned[0], `行${i}`);
  spawned[0].exit(1);
  const tail = lastError(mgr, "s1").stderr;
  assert.equal(tail.length, 10);
  assert.equal(tail[9], "行39", "**新しい方**を残す(古い方を残すと死因が落ちる)");
  assert.equal(tail[0], "行30");
});

test("★溜める側は 4KB で頭から捨てる(変異 W17 = 上限を外す)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  const line = "a".repeat(200);
  for (let i = 0; i < 200; i++) err(spawned[0], line); // 40KB 流す
  // ★**死ぬ前に**内部を見る。死ねば Map から消えて溜める側は覗けなくなり、出口(1KB)しか
  //   測れない —— それでは「4KB で捨てている」を測った事にならない(出口が隠してしまう)。
  const held = mgr.workers.get("s1").stderrTail;
  const bytes = held.reduce((n, s) => n + s.length + 1, 0);
  assert.ok(bytes <= 4096, `溜め込んだ: ${bytes}B`);
  assert.ok(bytes > 3000, `捨て過ぎ(上限まで持っていない): ${bytes}B`);
  assert.equal(held.at(-1), line, "**新しい方**を残す");
  spawned[0].exit(1);
  const tail = lastError(mgr, "s1").stderr;
  assert.ok(tail.join("\n").length <= 1024, `出す側が 1KB を超えた: ${tail.join("\n").length}`);
});

test("★秘密は伏せてから積む(変異 W16 = 網を通さない)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  err(spawned[0], "account=mail-redacted@example.invalid");
  spawned[0].exit(1);
  const tail = lastError(mgr, "s1").stderr;
  assert.ok(!tail[0].includes("client-a.team"), `生のまま積まれた: ${tail[0]}`);
  assert.ok(tail[0].includes("<mail>"));
});

test("★伏せてから切る。切ってから伏せると左半分が抜ける(変異 W24)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  // 切る位置(1024)の直前にメールを置く。切ってから伏せると `secret-use` で切れて網を抜ける。
  spawned[0].stderr.emit("data", Buffer.from("x".repeat(1014) + "secret-user@example.com" + "y".repeat(80)));
  spawned[0].exit(1);
  const joined = lastError(mgr, "s1").stderr.join("\n");
  assert.ok(!joined.includes("secret-us"), `切れた左半分が残った: ${joined.slice(-80)}`);
  assert.ok(joined.includes("<mail>"));
});

test("改行を1度も出さない子でも溜め込まない(切って積む)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  spawned[0].stderr.emit("data", Buffer.from("z".repeat(2600))); // 改行なし
  // ★**死ぬ前に**見る。出す側の 1KB が「2本に切った」事実を1本へ畳んでしまうので、
  //   死んだ後に `tail.length >= 2` を測ると必ず落ちる —— 4KB の検査で一度直した
  //   「出口が入口を隠す」を、同じ夜にもう一度書いた(今夜の型 #11)。
  const held = mgr.workers.get("s1").stderrTail;
  assert.ok(held.length >= 2, `改行が来るまで待ち続けている: ${held.length} 本`);
  assert.ok(held.every((l) => l.length <= 1024), "切らずに1本で抱えている");
  spawned[0].exit(1);
  const tail = lastError(mgr, "s1").stderr;
  assert.ok(tail.length >= 1, "全部落とした");
  assert.ok(tail.join("\n").length <= 1024);
});

test("★死ぬ間際の改行なしの一行を落とさない(一番読みたい行がそこに在る)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  spawned[0].stderr.emit("data", Buffer.from("Fatal: 転写ファイルが見つかりません")); // 改行なし
  spawned[0].exit(1);
  assert.deepEqual(lastError(mgr, "s1").stderr, ["Fatal: 転写ファイルが見つかりません"]);
});

test("stderr の断片(改行を跨ぐ chunk)を組み立てる", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  spawned[0].stderr.emit("data", Buffer.from("前半"));
  spawned[0].stderr.emit("data", Buffer.from("後半\n"));
  spawned[0].exit(1);
  assert.deepEqual(lastError(mgr, "s1").stderr, ["前半後半"]);
});

test("再 spawn で前の子の尾が混ざらない", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  err(spawned[0], "1人目の理由");
  spawned[0].exit(1);
  mgr.send("s1", "もう一度");
  err(spawned[1], "2人目の理由");
  spawned[1].exit(1);
  assert.deepEqual(lastError(mgr, "s1").stderr, ["2人目の理由"]);
});

test("正常終了(code=0)には死因を付けない", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "hi");
  err(spawned[0], "ただの警告");
  spawned[0].exit(0);
  const evs = mgr.eventsSince("s1", 0).map((e) => e.data);
  assert.ok(evs.some((d) => d.type === "worker_closed"));
  assert.ok(!evs.some((d) => d.type === "worker_error"));
});

// ============ 積んだ送信を黙って消さない(§2.18-12、2026-08-04) ============
//
// 2026-08-04 に鍵の層(tmux 経路)で「割り込みは積んだ送信を捨てない」を決めた直後、
// **ワーカー経路には捨てる実装が生きたまま残っている**事が分かった。`interrupt` が
// entry ごと退役させるので `entry.queue` が道連れで消え、`user_queued` と電話に出した
// turn が**何のイベントも出さずに**消滅していた(検査 538 本が全部緑のまま)。
//
// 決めた形(Codex `gpt-5.6-sol` xhigh 2026-08-04): ワーカー経路は tmux と同じ振る舞いに
// **しない**。子を殺す以上「積んだ分も届く」は作れないので、揃えるのは
// **turn の終端状態** = `accepted → delivered | failed(理由)`。
// 駄目なのは「`user_queued` と出した後、どちらにも落ちない」= 今日までの姿。

/** 積んだ turn の「届かなかった」通知だけを取り出す。 */
const drops = (mgr, sid) =>
  mgr.eventsSince(sid, 0).map((e) => e.data).filter((d) => d.type === "user_dropped");

test("★割り込みは、積んだ送信を黙って消さない(1件ずつ名指しで failed になる)", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");            // これが走る
  const q1 = mgr.send("s1", "b"); // 積まれる
  const q2 = mgr.send("s1", "c"); // 積まれる
  assert.equal(mgr.status("s1").queued, 2);

  assert.equal(mgr.interrupt("s1"), true);

  const d = drops(mgr, "s1");
  assert.deepEqual(d.map((x) => x.text), ["b", "c"], "積んだ本文が名指しで出ていない");
  assert.deepEqual(d.map((x) => x.reason), ["worker_interrupted", "worker_interrupted"]);
  // ★turn の名前は `user_queued` の seq。番号を別に発明せず、既に在る目盛りを使う。
  assert.deepEqual(d.map((x) => x.queuedSeq), [q1, q2], "どの turn が落ちたのか特定できない");
  assert.equal(mgr.status("s1").queued, 0);
  assert.equal(spawned[0].killed, "SIGTERM");
});

test("★届かなかった事は**揮発しない**(割り込みの瞬間に電話が切れていても後から拾える)", () => {
  const { mgr } = makeMgr();
  // onEvent を一度も渡さない = 誰も繋がっていない状態で割り込みが起きた場合。
  mgr.send("s1", "a");
  mgr.send("s1", "b");
  mgr.interrupt("s1");
  // 繋ぎ直した電話は seq 0 から読み直す。ここに残っていなければ、結局「無通知の消失」。
  assert.deepEqual(drops(mgr, "s1").map((x) => x.text), ["b"]);
});

test("★通知は entry を外す**前**に出る(繋がっている電話にはその場で届く)", () => {
  const { mgr } = makeMgr();
  const seen = [];
  mgr.send("s1", "a", { onEvent: (seq, data) => seen.push(data.type) });
  mgr.send("s1", "b");
  mgr.interrupt("s1");
  assert.ok(seen.includes("user_dropped"), `外した後に出している(seen=${seen.join(",")})`);
});

test("★予期しない死でも、積んだ送信は名指しで failed になる", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  mgr.send("s1", "b");
  spawned[0].exit(1); // 自分から死んだ(interrupt を通らない道)
  assert.deepEqual(drops(mgr, "s1").map((x) => [x.text, x.reason]), [["b", "worker_died"]]);
});

test("★shutdown でも、積んだ送信は名指しで failed になる(再配信はしない)", () => {
  const { mgr } = makeMgr();
  mgr.send("s1", "a");
  mgr.send("s1", "b");
  mgr.shutdown();
  assert.deepEqual(drops(mgr, "s1").map((x) => [x.text, x.reason]), [["b", "server_shutdown"]]);
});

// ★陰性対照。「積んだ物が無いのに『落ちました』と出す」方の壊れ方を掴む。
//   `_retire` は全部の退役路が通るので、ここで無条件に出す実装にすると
//   idle 回収のたびに嘘の failed が流れる。上の5本は全部それを**緑のまま**通す。
//   ★2026-08-04: この対照は**一度も回収していなかった**。`idleMs: 0` + 止まった時計だと
//     `t - lastActive > idleMs` が `0 > 0` = 偽で、`sweep()` は素通り。空を掃いて緑を名乗る形
//     (§2.33)を、この対照を書いた翌日に自分で踏んだ。時計を動かし、**回収された事**を
//     先に確かめてから「嘘の failed が無い」を主張する。
test("★積んだ物が無ければ、何も出さない(idle 回収で嘘の failed を流さない)", () => {
  let t = 1000;
  const { mgr, spawned } = makeMgr({ idleMs: 500, now: () => t });
  mgr.send("s1", "a");
  spawned[0].emitLine({ type: "result", result: "ok" }); // 走り切って ready
  assert.equal(mgr.status("s1").queued, 0);
  t += 501;
  mgr.sweep();
  assert.equal(mgr.status("s1").worker, "none", "回収が起きていない = 何も掃いていない");
  assert.deepEqual(drops(mgr, "s1"), [], "何も積んでいないのに failed を流している");
});

// ---------------------------------------------------------------------------
// ★生配信の宛先は**セッションが持つ**(2026-08-04、実測で発見)。
//
// 旧実装は `entry.onEvent`。`_emit` が `workers` から entry を引いていたので、
// **entry を外した後の通知は繋がっている電話に届かなかった**: 死亡通知 /
// `worker_interrupted` / idle 回収 —— つまり「この会話は終わった」と言う口の**全部**。
// 電話からは応答が止まったのと区別が付かない。
//
// 見つからなかった理由がそのまま教訓: この file の検査は全部 `eventsSince`(= リング)で
// 見ていて、**生配信の口を誰も見ていなかった**。だから下の3本は `onEvent` で受ける。
// ---------------------------------------------------------------------------
/** live で受けた type だけを並べる(リングは見ない)。 */
function liveTypes(fn) {
  const seen = [];
  return { on: (_s, d) => seen.push(d.type), seen, fn };
}

test("★割り込みの通知が、繋がっている電話へ**その場で**届く", () => {
  const L = liveTypes();
  const { mgr } = makeMgr();
  mgr.send("s1", "a", { onEvent: L.on });
  mgr.interrupt("s1");
  assert.ok(L.seen.includes("worker_interrupted"), `live に来ていない: ${L.seen}`);
});

test("★死亡通知が、繋がっている電話へ**その場で**届く", () => {
  const L = liveTypes();
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a", { onEvent: L.on });
  spawned[0].exit(1);
  assert.ok(L.seen.includes("worker_error"), `live に来ていない: ${L.seen}`);
});

test("★idle 回収の通知が、繋がっている電話へ**その場で**届く", () => {
  let t = 1000;
  const L = liveTypes();
  const { mgr, spawned } = makeMgr({ idleMs: 500, now: () => t });
  mgr.send("s1", "a", { onEvent: L.on });
  spawned[0].emitLine({ type: "result", result: "ok" });
  t += 501;
  mgr.sweep();
  assert.ok(L.seen.includes("worker_idle_closed"), `live に来ていない: ${L.seen}`);
});

// ★陰性対照。宛先をセッション持ちにした事で、**別のセッションの通知まで**流れたら壊れている。
test("★陰性対照: 宛先はセッションごと(隣の会話の通知が混ざらない)", () => {
  const A = liveTypes(), B = liveTypes();
  const { mgr } = makeMgr();
  mgr.send("s1", "a", { onEvent: A.on });
  mgr.send("s2", "b", { onEvent: B.on });
  mgr.interrupt("s1");
  assert.ok(A.seen.includes("worker_interrupted"), "本人に届いていない");
  assert.ok(!B.seen.includes("worker_interrupted"), `隣の会話へ漏れた: ${B.seen}`);
});

// ---------------------------------------------------------------------------
// ★退役の同一性は `exit`/`close` にしか付いていなかった(2026-08-04、自分の diff の読み直しで発見)。
//
// `proc.on("error")` は spawn 失敗だけでなく **kill 失敗**でも出る。kill は割り込みの中で
// 撃つので、その error は「退役 → 別の子に差し替わった」後に届き得る。届いた先で
// `workers.delete(sessionId)` を無条件にやると、**生きている次の子が Map から外れる**。
// 外れた子は誰も知らないまま同じ転写へ書き続け、次の送信はもう1本 spawn する = H2
// (1つの転写に書き手が2人)。設計が一番避けたい形に、後始末の1行で入ってしまう。
//
// 直し方は `onDeath` と同じ = 「名前で消さず、同一性で消す」。
// ---------------------------------------------------------------------------
test("★遅れて来た error は、差し替わった後の生きた子を Map から外さない", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  mgr.interrupt("s1");   // A を退役(Map から外れ、SIGTERM を撃つ。まだ死んではいない)
  mgr.send("s1", "b");   // B を spawn。ready なので即書き込み → busy
  mgr.send("s1", "c");   // B の行列に積む
  assert.equal(spawned.length, 2, "前提が崩れた(2本目が上がっていない)");
  assert.equal(mgr.workers.get("s1")?.proc, spawned[1], "前提が崩れた(Map が B でない)");

  spawned[0].emit("error", new Error("kill ESRCH"));  // ★A の遅い error

  assert.equal(mgr.workers.get("s1")?.proc, spawned[1], "生きている B が Map から消えた");
  assert.equal(mgr.status("s1").queued, 1, "B に積んだ turn が巻き添えで消えた");
  assert.deepEqual(drops(mgr, "s1"), [], "他人の行列を落としたと名乗っている");
  // ★失敗は黙らせない(§2.16)が、**誰の失敗か**は言う(Codex 2026-08-04)。
  assert.equal(lastError(mgr, "s1").stale, true, "先代の失敗が今の子の失敗として出ている");
});

// ★陰性対照。同一性で見る事にした結果、**本当に現役の子が error で死んだ**時に
//   Map から外れなくなったら、次の送信が死んだ子へ書きに行く。そちらの壊れ方を掴む。
test("★陰性対照: 現役の子の error では、ちゃんと Map から外れる / stale と名乗らない", () => {
  const { mgr, spawned } = makeMgr();
  mgr.send("s1", "a");
  spawned[0].emit("error", new Error("spawn ENOENT"));
  assert.equal(mgr.workers.get("s1"), undefined, "死んだ子が Map に残っている");
  // ★これが無いと「常に stale と言う」実装でも上の検査は緑になる。
  assert.equal(lastError(mgr, "s1").stale, false, "現役の失敗を先代扱いしている");
});

// ---- 電話からの「送信待ちを取り消す」(2026-08-04)-----------------------------

test("dropQueued は積んだ番だけを捨て、走っている番には触れない", () => {
  const { mgr, spawned } = makeMgr();
  const events = [];
  mgr.send("s1", "a", { onEvent: (seq, d) => events.push(d) });
  mgr.send("s1", "b");
  mgr.send("s1", "c");
  assert.equal(mgr.status("s1").queued, 2);
  const n = mgr.dropQueued("s1", "user_cleared");
  assert.equal(n, 2);
  assert.equal(mgr.status("s1").queued, 0);
  // ★走っている番は生きたまま。書いた物を取り消していない事を、書き込み数で固定する。
  assert.equal(spawned[0].written.length, 1, "捨てる操作が既に書いた番に触っている");
  assert.equal(mgr.status("s1").state, "busy", "取り消しが生成を止めている(それは interrupt の仕事)");
  const dropped = events.filter((d) => d.type === "user_dropped");
  assert.deepEqual(dropped.map((d) => d.text), ["b", "c"]);
  assert.deepEqual([...new Set(dropped.map((d) => d.reason))], ["user_cleared"]);
});

test("★捨てた事は EventRing に残る(電話が切れている間に捨てても後から拾える)", () => {
  const { mgr } = makeMgr();
  mgr.send("s1", "a"); // onEvent を渡さない = 電話が繋がっていない体
  mgr.send("s1", "b");
  assert.equal(mgr.dropQueued("s1", "user_cleared"), 1);
  const types = mgr.eventsSince("s1", 0).map((e) => e.data.type);
  assert.ok(types.includes("user_dropped"), "捨てた事が揮発している = 繋ぎ直した電話に届かない");
});

test("★積んでいない / ワーカーが居ない時は 0(捨てた事にしない)", () => {
  const { mgr } = makeMgr();
  assert.equal(mgr.dropQueued("居ない会話", "user_cleared"), 0);
  mgr.send("s1", "a");
  assert.equal(mgr.dropQueued("s1", "user_cleared"), 0, "走っている1番を捨てたと数えている");
  assert.equal(mgr.eventsSince("s1", 0).filter((e) => e.data.type === "user_dropped").length, 0,
    "捨てる物が無いのに user_dropped を出している");
});

test("★陰性対照: dropQueued を呼ばなければ行列は残る(上の3本が常に緑ではない事)", () => {
  const { mgr } = makeMgr();
  mgr.send("s1", "a");
  mgr.send("s1", "b");
  assert.equal(mgr.status("s1").queued, 1, "偽 spawn では最初から積まれていない = 何も測れていない");
});
