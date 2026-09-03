// `/diff` の順番待ち(2026-09-03、Codex #1 の 4 の続き): 要求の側が居なくなったら待ち行列から
// 外れ、待ち行列が一杯なら待たずに `busy`(口は 503)。
//
// ★守る線:
//   1. 待っている間に要求が消えた(AbortSignal)→ git を 1 本も起こさず `aborted`、行列から消える。
//   2. 走り始めた後の abort は**効かない**(同じ cwd の合流者が結果を待っている)。
//   3. 待ち行列が `maxWaiting` を超える → 待たずに `busy`、git を起こさない。
//   4. 合流した要求(同じ cwd)は signal を無視して先客の結果を貰う。
//   5. 口(`server.mjs`)は `req.on("close")` を AbortController に繋ぎ、`busy` を 503 で返し、
//      `aborted` には何も書かない(静的検査、diff-routes.test.mjs と同じ理由)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { _inflight, MAX_CONCURRENT, MAX_WAITING, readWorkingDiff } from "../src/sessiondiff.mjs";

const always = () => true;
const dirStat = { isSymbolicLink: () => false, isDirectory: () => true, isFile: () => false };
const pinned = { realpath: (p) => p, lstat: (p) => (p.endsWith("/.git") ? dirStat : null) };

/** 席を塞ぐ git: `release()` を呼ぶまで返らない。呼ばれた cwd を数える。 */
function blockingGit() {
  let release;
  const gate = new Promise((r) => { release = r; });
  const calls = [];
  const exec = async (bin, args, opts) => { calls.push(opts.cwd); await gate; return { stdout: "", stderr: "" }; };
  return { exec, calls, release: () => release() };
}

async function drained() {
  // 全部の後始末(finally)が回るまで数 tick 待つ
  for (let i = 0; i < 20; i += 1) await new Promise((r) => setImmediate(r));
}

/**
 * ★「返らない」を赤にする。抑えを外した変異では要求が**永久に待つ**が、node の test runner は
 *   未解決の promise を失敗と数えず、event loop が空になると静かに終わる(実測: 変異 M1/M2 で
 *   `pass 2 fail 0` / `pass 0 fail 0` = 空振りの緑)。期限を切って `timeout` という reason に化かす。
 */
function within(ms, p) {
  let t;
  const clock = new Promise((r) => { t = setTimeout(() => r({ files: [], truncated: false, totalBytes: 0, reason: "timeout" }), ms); });
  return Promise.race([p, clock]).finally(() => clearTimeout(t));
}

test("★待っている間に要求が消えたら、git を起こさず `aborted` で返り、行列から消える(所見 4)", async () => {
  const g = blockingGit();
  // 席を全部塞ぐ(別々の cwd)
  const holders = [];
  for (let i = 0; i < MAX_CONCURRENT; i += 1) holders.push(readWorkingDiff(`/hold-${i}`, { exec: g.exec, exists: always, ...pinned }));
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().running, MAX_CONCURRENT);

  const ac = new AbortController();
  const waiter = readWorkingDiff("/waiter", { exec: g.exec, exists: always, ...pinned, signal: ac.signal });
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().waiting, 1, "順番待ちに入っていない");
  ac.abort();
  const r = await within(500, waiter);
  assert.equal(r.reason, "aborted", "abort を聞いていない(永久に待つ = timeout)");
  assert.deepEqual(r.files, []);
  assert.equal(_inflight().waiting, 0, "abort した要求が行列に残っている");
  assert.equal(g.calls.includes("/waiter"), false, "★居なくなった要求の為に git を起こした");

  g.release();
  await within(500, Promise.all(holders));
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("走り始めた後に本人が去っても git は止まらない: 本人は `aborted`、同乗者は結果を貰う", async () => {
  const g = blockingGit();
  const ac = new AbortController();
  const p = readWorkingDiff("/running", { exec: g.exec, exists: always, ...pinned, signal: ac.signal });
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().running, 1);
  const rider = readWorkingDiff("/running", { exec: g.exec, exists: always, ...pinned }); // 合流(signal 無し)
  ac.abort();
  const mine = await within(500, p);
  assert.equal(mine.reason, "aborted", "去った本人に応答を作っている(書く相手が居ない)");
  g.release();
  const r = await within(500, rider);
  assert.equal(r.reason, null, "本人の abort で走っている git を捨てた(同乗者が結果を貰えない)");
  assert.equal(g.calls.filter((c) => c === "/running").length, 3, "git が走り切っていない(config + 2 diff)");
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("★待ってから走り始めた要求も、走り始めた後の abort は効かない(待機中の合図を外し忘れる実装を落とす)", async () => {
  const g1 = blockingGit(); // 席を塞ぐ側
  const g2 = blockingGit(); // 待つ側の git(別の gate)
  const holders = [];
  for (let i = 0; i < MAX_CONCURRENT; i += 1) holders.push(readWorkingDiff(`/hh-${i}`, { exec: g1.exec, exists: always, ...pinned }));
  await new Promise((r) => setImmediate(r));
  const ac = new AbortController();
  const waiter = readWorkingDiff("/late", { exec: g2.exec, exists: always, ...pinned, signal: ac.signal });
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().waiting, 1);
  g1.release();                      // 席が空く → waiter が走り始める
  await within(500, Promise.all(holders));
  await new Promise((r) => setImmediate(r));
  assert.ok(g2.calls.includes("/late"), "waiter が走り始めていない");
  const rider = readWorkingDiff("/late", { exec: g2.exec, exists: always, ...pinned }); // 走行中に合流
  ac.abort();                        // 走り始めた後に先客が去る
  const mine = await within(500, waiter);
  assert.equal(mine.reason, "aborted");
  assert.equal(_inflight().running, 1, "★待機中に付けた abort の合図が走行後も生きていて、走行を捨てた");
  g2.release();
  const r = await within(500, rider);
  assert.equal(r.reason, null, "同乗者が結果を貰えない");
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("★待ち行列が一杯なら待たずに `busy`(git を起こさない)。錨: 上限の内側は待つ", async () => {
  const g = blockingGit();
  const holders = [];
  for (let i = 0; i < MAX_CONCURRENT; i += 1) holders.push(readWorkingDiff(`/h-${i}`, { exec: g.exec, exists: always, ...pinned }));
  await new Promise((r) => setImmediate(r));
  const maxWaiting = 2;
  const waiters = [];
  for (let i = 0; i < maxWaiting; i += 1) waiters.push(readWorkingDiff(`/w-${i}`, { exec: g.exec, exists: always, ...pinned, maxWaiting }));
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().waiting, maxWaiting);
  const over = await within(500, readWorkingDiff("/over", { exec: g.exec, exists: always, ...pinned, maxWaiting }));
  assert.equal(over.reason, "busy", "上限を見ずに並べた(永久に待つ = timeout)");
  assert.equal(g.calls.includes("/over"), false, "★一杯なのに git を起こした");
  assert.equal(_inflight().waiting, maxWaiting, "busy の要求が行列に入っている");

  g.release();
  const rs = await within(1000, Promise.all([...holders, ...waiters]));
  assert.ok(Array.isArray(rs) && rs.every((r) => r.reason === null), "上限の内側で待った要求が結果を貰えていない");
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("★合流: 合流者が abort しても自分だけ `aborted`、先客と共有 git は走り切る", async () => {
  const g = blockingGit();
  const first = readWorkingDiff("/same", { exec: g.exec, exists: always, ...pinned });
  await new Promise((r) => setImmediate(r));
  const ac = new AbortController();
  const joined = readWorkingDiff("/same", { exec: g.exec, exists: always, ...pinned, signal: ac.signal });
  ac.abort();
  const b = await within(500, joined);
  assert.equal(b.reason, "aborted", "abort した合流者が即 aborted にならない");
  g.release();
  const a = await within(500, first);
  assert.equal(a.reason, null, "合流者の abort で先客まで捨てた");
  assert.equal(g.calls.filter((c) => c === "/same").length, 3, "合流せず git を余分に起こした(config + unstaged + staged で 3 本が正)");
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("★★合流: 待機中の先客が abort しても、生きている合流者は待ち続けて結果を貰う(Codex #4 の High)", async () => {
  const g1 = blockingGit(); // 席を塞ぐ側
  const g2 = blockingGit(); // /same の git
  const holders = [];
  for (let i = 0; i < MAX_CONCURRENT; i += 1) holders.push(readWorkingDiff(`/hx-${i}`, { exec: g1.exec, exists: always, ...pinned }));
  await new Promise((r) => setImmediate(r));
  const acA = new AbortController();
  const leader = readWorkingDiff("/same2", { exec: g2.exec, exists: always, ...pinned, signal: acA.signal }); // 待機中
  await new Promise((r) => setImmediate(r));
  const joiner = readWorkingDiff("/same2", { exec: g2.exec, exists: always, ...pinned });               // 合流(signal 無し)
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().waiting, 1);
  acA.abort();                                                                                              // 先客が去る
  const a = await within(500, leader);
  assert.equal(a.reason, "aborted");
  assert.equal(_inflight().waiting, 1, "★先客が去っただけで共有の走行が行列から消えた(合流者が居るのに)");
  g1.release();                                                                                             // 席が空く → 走る
  await within(500, Promise.all(holders));
  await new Promise((r) => setImmediate(r));
  assert.ok(g2.calls.includes("/same2"), "★合流者が居るのに git が走らない(先客の abort に巻き込まれた)");
  g2.release();
  const b = await within(500, joiner);
  assert.equal(b.reason, null, "生きている合流者が結果を貰えない");
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("★合流: 全員が待機中に去れば共有の走行は行列から外れ、git は 1 本も起きない", async () => {
  const g1 = blockingGit();
  const g2 = blockingGit();
  const holders = [];
  for (let i = 0; i < MAX_CONCURRENT; i += 1) holders.push(readWorkingDiff(`/hy-${i}`, { exec: g1.exec, exists: always, ...pinned }));
  await new Promise((r) => setImmediate(r));
  const acA = new AbortController(), acB = new AbortController();
  const a = readWorkingDiff("/same3", { exec: g2.exec, exists: always, ...pinned, signal: acA.signal });
  await new Promise((r) => setImmediate(r));
  const b = readWorkingDiff("/same3", { exec: g2.exec, exists: always, ...pinned, signal: acB.signal });
  await new Promise((r) => setImmediate(r));
  acA.abort(); acB.abort();
  // ★錨: 去った**直後**(共有の entry が `finally` で消える前の隙間)に来た新しい要求は、古い
  //   `aborted` の entry に合流せず、自分の走行を持つ。await を挟まず同期で出す(2026-09-03、
  //   後から出す検体では変異「古い entry に合流させる」がすり抜けた)。
  const fresh = readWorkingDiff("/same3", { exec: g2.exec, exists: always, ...pinned });
  const [ra, rb] = await within(500, Promise.all([a, b]));
  assert.equal(ra.reason, "aborted"); assert.equal(rb.reason, "aborted");
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().waiting, 1, "全員去った共有の走行が行列に残っている / 新しい要求が行列に入っていない");
  assert.equal(g2.calls.includes("/same3"), false, "誰も居ないのに(席が空く前に)git を起こした");
  g1.release();                                    // 席が空く → fresh が走る
  await within(500, Promise.all(holders));
  await new Promise((r) => setImmediate(r));
  assert.ok(g2.calls.includes("/same3"), "新しい要求の git が走っていない");
  g2.release();
  const rf = await within(500, fresh);
  assert.equal(rf.reason, null, "去った直後の要求が古い aborted を貰った");
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("既定の上限は 8(電話 1 台が積める数より多く、4 秒 × 4 巡で捌ける数)— 動作で測る: 8 件待てて 9 件目が busy", async () => {
  assert.equal(MAX_WAITING, 8);
  const g = blockingGit();
  const holders = [];
  for (let i = 0; i < MAX_CONCURRENT; i += 1) holders.push(readWorkingDiff(`/d-h-${i}`, { exec: g.exec, exists: always, ...pinned }));
  await new Promise((r) => setImmediate(r));
  const waiters = [];
  for (let i = 0; i < 8; i += 1) waiters.push(readWorkingDiff(`/d-w-${i}`, { exec: g.exec, exists: always, ...pinned })); // override なし
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().waiting, 8, "既定で 8 件 待てない");
  const ninth = await within(500, readWorkingDiff("/d-w-9", { exec: g.exec, exists: always, ...pinned }));
  assert.equal(ninth.reason, "busy", "9 件目が待ってしまう(既定の上限が効いていない)");
  g.release();
  const rs = await within(2000, Promise.all([...holders, ...waiters]));
  assert.ok(rs.every((r) => r.reason === null));
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

// ── 口(server.mjs)の配線 ───────────────────────────────────────────────────
const SRC = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.mjs");
const real = readFileSync(SRC, "utf8");
const MARKER = 'if (action === "diff" && req.method === "GET")';

test("★口: 要求の close を AbortController に繋ぎ、busy は 503、aborted には書かない", () => {
  const i = real.indexOf(MARKER);
  assert.ok(i !== -1);
  const body = real.slice(i, i + 2200);
  assert.ok(/new AbortController\(\)/.test(body), "AbortController が無い");
  assert.ok(/req\.on\("close",/.test(body), "close を聞いていない");
  assert.ok(/readWorkingDiff\(cwd,\s*\{\s*signal:/.test(body), "signal を渡していない");
  assert.ok(/reason === "aborted"\) return;/.test(body), "aborted に応答を書こうとしている");
  assert.ok(/reason === "busy"\) return json\(res, 503/.test(body), "busy が 503 ではない");
  // 錨: 成功の道は今も 200
  assert.ok(/return json\(res, 200, diffBody\(r\)\)/.test(body));
});
