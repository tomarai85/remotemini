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
  for (let i = 0; i < MAX_CONCURRENT; i += 1) holders.push(readWorkingDiff(`/hold-${i}`, { exec: g.exec, exists: always }));
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().running, MAX_CONCURRENT);

  const ac = new AbortController();
  const waiter = readWorkingDiff("/waiter", { exec: g.exec, exists: always, signal: ac.signal });
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().waiting, 1, "順番待ちに入っていない");
  ac.abort();
  const r = await within(500, waiter);
  assert.equal(r.reason, "aborted", "abort を聞いていない(永久に待つ = timeout)");
  assert.deepEqual(r.files, []);
  assert.equal(_inflight().waiting, 0, "abort した要求が行列に残っている");
  assert.equal(g.calls.includes("/waiter"), false, "★居なくなった要求の為に git を起こした");

  g.release();
  await Promise.all(holders);
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("走り始めた後の abort は効かない(合流者が結果を待っている)", async () => {
  const g = blockingGit();
  const ac = new AbortController();
  const p = readWorkingDiff("/running", { exec: g.exec, exists: always, signal: ac.signal });
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().running, 1);
  ac.abort();
  g.release();
  const r = await within(500, p);
  assert.equal(r.reason, null, "走っている git を abort で捨てた");
  await drained();
});

test("★待ってから走り始めた要求も、走り始めた後の abort は効かない(待機中の合図を外し忘れる実装を落とす)", async () => {
  const g1 = blockingGit(); // 席を塞ぐ側
  const g2 = blockingGit(); // 待つ側の git(別の gate)
  const holders = [];
  for (let i = 0; i < MAX_CONCURRENT; i += 1) holders.push(readWorkingDiff(`/hh-${i}`, { exec: g1.exec, exists: always }));
  await new Promise((r) => setImmediate(r));
  const ac = new AbortController();
  const waiter = readWorkingDiff("/late", { exec: g2.exec, exists: always, signal: ac.signal });
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().waiting, 1);
  g1.release();                      // 席が空く → waiter が走り始める
  await Promise.all(holders);
  await new Promise((r) => setImmediate(r));
  assert.ok(g2.calls.includes("/late"), "waiter が走り始めていない");
  ac.abort();                        // 走り始めた後
  g2.release();
  const r = await within(500, waiter);
  assert.equal(r.reason, null, "待機中に付けた abort の合図が走行後も生きていて、結果を捨てた");
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("★待ち行列が一杯なら待たずに `busy`(git を起こさない)。錨: 上限の内側は待つ", async () => {
  const g = blockingGit();
  const holders = [];
  for (let i = 0; i < MAX_CONCURRENT; i += 1) holders.push(readWorkingDiff(`/h-${i}`, { exec: g.exec, exists: always }));
  await new Promise((r) => setImmediate(r));
  const maxWaiting = 2;
  const waiters = [];
  for (let i = 0; i < maxWaiting; i += 1) waiters.push(readWorkingDiff(`/w-${i}`, { exec: g.exec, exists: always, maxWaiting }));
  await new Promise((r) => setImmediate(r));
  assert.equal(_inflight().waiting, maxWaiting);
  const over = await within(500, readWorkingDiff("/over", { exec: g.exec, exists: always, maxWaiting }));
  assert.equal(over.reason, "busy", "上限を見ずに並べた(永久に待つ = timeout)");
  assert.equal(g.calls.includes("/over"), false, "★一杯なのに git を起こした");
  assert.equal(_inflight().waiting, maxWaiting, "busy の要求が行列に入っている");

  g.release();
  const rs = await Promise.all([...holders, ...waiters]);
  assert.ok(rs.every((r) => r.reason === null), "上限の内側で待った要求が結果を貰えていない");
  await drained();
  assert.deepEqual(_inflight(), { running: 0, waiting: 0, keys: [] });
});

test("合流した要求は signal を無視して先客の結果を貰う", async () => {
  const g = blockingGit();
  const first = readWorkingDiff("/same", { exec: g.exec, exists: always });
  await new Promise((r) => setImmediate(r));
  const ac = new AbortController();
  const joined = readWorkingDiff("/same", { exec: g.exec, exists: always, signal: ac.signal });
  ac.abort();
  g.release();
  const [a, b] = await Promise.all([first, joined]);
  assert.deepEqual(a, b);
  assert.equal(b.reason, null);
  assert.equal(g.calls.filter((c) => c === "/same").length, 2, "合流せず git を余分に起こした(unstaged + staged で 2 本が正)");
  await drained();
});

test("既定の上限は 8(電話 1 台が積める数より多く、4 秒 × 4 巡で捌ける数)", () => {
  assert.equal(MAX_WAITING, 8);
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
