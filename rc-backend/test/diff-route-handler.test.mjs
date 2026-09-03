// `GET /diff` の口の挙動(`src/diffroute.mjs`、2026-09-03、Codex #4 の 4)。
//
// 以前は正規表現の検査しか無く、`onClose` を空にしても listener を解除しなくても通った。
// 此処では偽の `req`(EventEmitter)/ `res` / `readWorkingDiff` / `json` で**実際に通す**:
//   close → signal が鳴る / aborted → 何も書かない / busy → 503 / 普通 → 200 / cwd 無し → 200 no_cwd /
//   listener の後始末。
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { handleDiffGet } from "../src/diffroute.mjs";
import { diffBody } from "../src/wire.mjs";

function harness(readWorkingDiff) {
  const req = new EventEmitter();
  const writes = [];
  const res = { id: "res" };
  const json = (r, code, obj) => { writes.push({ r, code, obj }); return "written"; };
  return { req, res, writes, json, run: (cwd) => handleDiffGet({ req, res, cwd, readWorkingDiff, json, diffBody }) };
}

const OK = { files: [{ path: "a.txt", staged: false, binary: false, added: 1, removed: 0, truncated: false, hunks: [] }], truncated: false, totalBytes: 5, reason: null };

test("普通: 200 で封筒を書く。close の listener は応答後に外れている", async () => {
  const h = harness(async () => OK);
  const out = await h.run("/w");
  assert.equal(out, "written");
  assert.equal(h.writes.length, 1);
  assert.equal(h.writes[0].code, 200);
  assert.equal(h.writes[0].r, h.res);
  assert.deepEqual(h.writes[0].obj, diffBody(OK));
  assert.equal(h.req.listenerCount("close"), 0, "close の listener が残っている(keep-alive で溜まる)");
});

test("cwd 無し: 200 + no_cwd、git(readWorkingDiff)は呼ばない", async () => {
  let called = 0;
  const h = harness(async () => { called += 1; return OK; });
  await h.run(null);
  assert.equal(called, 0);
  assert.equal(h.writes[0].code, 200);
  assert.equal(h.writes[0].obj.reason, "no_cwd");
});

test("★busy: 503 で普段の封筒(reason: busy)", async () => {
  const h = harness(async () => ({ files: [], truncated: false, totalBytes: 0, reason: "busy" }));
  await h.run("/w");
  assert.equal(h.writes.length, 1);
  assert.equal(h.writes[0].code, 503);
  assert.equal(h.writes[0].obj.reason, "busy");
  assert.deepEqual(Object.keys(h.writes[0].obj).sort(), ["files", "reason", "totalBytes", "truncated"]);
});

test("★aborted: 何も書かない(書く相手が居ない)", async () => {
  const h = harness(async () => ({ files: [], truncated: false, totalBytes: 0, reason: "aborted" }));
  const out = await h.run("/w");
  assert.equal(out, undefined);
  assert.equal(h.writes.length, 0, "aborted に応答を書いた");
  assert.equal(h.req.listenerCount("close"), 0);
});

test("★要求の close が readWorkingDiff の signal を鳴らす(順番待ちから外れる合図)", async () => {
  let seen = null;
  let resolveRead;
  const pending = new Promise((r) => { resolveRead = r; });
  const h = harness(async (cwd, o) => {
    seen = o.signal;
    // 本物と同じ: signal が鳴ったら aborted で返る
    return await Promise.race([
      pending,
      new Promise((r) => o.signal.addEventListener("abort", () => r({ files: [], truncated: false, totalBytes: 0, reason: "aborted" }), { once: true })),
    ]);
  });
  const p = h.run("/w");
  await new Promise((r) => setImmediate(r));
  assert.ok(seen && !seen.aborted, "signal が渡っていない");
  assert.equal(h.req.listenerCount("close"), 1, "close を聞いていない");
  h.req.emit("close");
  assert.equal(seen.aborted, true, "★close が signal を鳴らしていない");
  const out = await p;
  assert.equal(out, undefined);
  assert.equal(h.writes.length, 0);
  assert.equal(h.req.listenerCount("close"), 0, "listener が残っている");
  resolveRead(OK); // 後始末(誰も待っていない)
});

test("★close が応答の後に来ても、二重に扱わない(listener は既に無い)", async () => {
  const h = harness(async () => OK);
  await h.run("/w");
  h.req.emit("close"); // 応答後の切断
  assert.equal(h.writes.length, 1, "応答後の close で何かを書いた");
});

test("readWorkingDiff が投げても listener は外れる(例外は上へ)", async () => {
  const h = harness(async () => { throw new Error("boom"); });
  await assert.rejects(h.run("/w"), /boom/);
  assert.equal(h.req.listenerCount("close"), 0, "例外の経路で listener が残った");
  assert.equal(h.writes.length, 0);
});
