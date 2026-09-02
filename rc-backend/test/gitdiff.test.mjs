// `gitdiff.mjs` — 差分の数を読む部分と、cwd ごとの箱。
//
// 守る物:
//   1. `--shortstat` の 3 形(files+ins+del / ins だけ / del だけ)と、空(= 差分ゼロ)と、
//      形が合わない文字列(= null)を**区別**する。0 と null は別の意味。
//   2. 箱は**同期で**返し、初回は null、取り直しは cwd ごとに 1 本だけ。
//   3. git が落ちたら null(例外を上へ投げない = 一覧が死なない)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseShortstat, makeDiffCache } from "../src/gitdiff.mjs";

test("files + insertions + deletions", () => {
  assert.deepEqual(parseShortstat(" 3 files changed, 42 insertions(+), 18 deletions(-)\n"),
    { files: 3, added: 42, removed: 18 });
});

test("insertion だけ(deletion の語が無い)→ removed は 0", () => {
  assert.deepEqual(parseShortstat(" 1 file changed, 5 insertions(+)"), { files: 1, added: 5, removed: 0 });
});

test("deletion だけ", () => {
  assert.deepEqual(parseShortstat(" 2 files changed, 7 deletions(-)"), { files: 2, added: 0, removed: 7 });
});

test("単数形(1 file / 1 insertion / 1 deletion)も読める", () => {
  assert.deepEqual(parseShortstat(" 1 file changed, 1 insertion(+), 1 deletion(-)"), { files: 1, added: 1, removed: 1 });
});

test("★空 = 差分ゼロ(git は差分が無いと何も出さない)。null ではない", () => {
  assert.deepEqual(parseShortstat(""), { files: 0, added: 0, removed: 0 });
  assert.deepEqual(parseShortstat("   \n"), { files: 0, added: 0, removed: 0 });
});

test("★形が合わない = null(0 に丸めない)", () => {
  assert.equal(parseShortstat("fatal: not a git repository"), null);
  assert.equal(parseShortstat("42"), null);
});

// ── 箱 ───────────────────────────────────────────────────────────────────
function fakeExec(script) {
  const calls = [];
  const exec = (cmd, args, opts, cb) => {
    calls.push({ cmd, args, opts });
    const cwd = args[1];
    const r = script(cwd);
    setImmediate(() => cb(r.err ?? null, r.stdout ?? ""));
  };
  return { exec, calls };
}

test("初回は null を返し、裏で 1 本だけ撃つ。settle 後は値が出る", async () => {
  let t = 1000;
  const { exec, calls } = fakeExec(() => ({ stdout: " 1 file changed, 2 insertions(+)" }));
  const box = makeDiffCache({ exec, now: () => t, ttlMs: 10_000 });
  assert.equal(box.get("/repo"), null, "まだ読んでいない = null");
  assert.equal(box.get("/repo"), null, "飛行中は重ねて撃たない");
  assert.equal(calls.length, 1, "同じ cwd に 2 本目を飛ばしていない");
  await box.settle("/repo");
  assert.deepEqual(box.get("/repo"), { files: 1, added: 2, removed: 0 });
  assert.equal(calls.length, 1, "TTL の内側では撃ち直さない");
  t += 10_001;
  box.get("/repo");
  assert.equal(calls.length, 2, "TTL を過ぎたら 1 本 撃ち直す");
});

test("★git が落ちたら null。例外を投げない(一覧を道連れにしない)", async () => {
  const { exec } = fakeExec(() => ({ err: new Error("fatal: not a git repository") }));
  const box = makeDiffCache({ exec, now: () => 0 });
  box.get("/nogit");
  await box.settle("/nogit");
  assert.equal(box.get("/nogit"), null);
});

test("cwd が無い行(null / 空)は撃たずに null", () => {
  const { exec, calls } = fakeExec(() => ({ stdout: "" }));
  const box = makeDiffCache({ exec, now: () => 0 });
  assert.equal(box.get(null), null);
  assert.equal(box.get(""), null);
  assert.equal(calls.length, 0);
});

test("git は読み取りの動詞だけ(`diff --shortstat`)、書く引数を渡していない", async () => {
  const { exec, calls } = fakeExec(() => ({ stdout: "" }));
  const box = makeDiffCache({ exec, now: () => 0 });
  box.get("/repo"); await box.settle("/repo");
  assert.deepEqual(calls[0].args, ["-C", "/repo", "diff", "--shortstat"]);
  assert.ok(calls[0].opts.timeout > 0, "上限が無いと動かない repo で固まる");
});
