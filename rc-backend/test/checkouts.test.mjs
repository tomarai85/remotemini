// checkouts.mjs の単体(§9-2)。mirror root は temp dir に実物の形で組む。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  parseSentinel, listCheckouts, checkoutIdForCwd, requestReturn, readReturnRequest,
} from "../src/checkouts.mjs";

const makeRoot = () => mkdtempSync(join(tmpdir(), "mirror-"));
const plant = (root, pid, src = `/Users/tomtim/Infra/${pid}`) => {
  mkdirSync(join(root, pid, "worktree"), { recursive: true });
  writeFileSync(join(root, pid, "ID"), `pid=${pid}\nsrc=${src}\n`);
};

test("parseSentinel: remote-mini.sh が書く形をそのまま読む / 形が違えば null", () => {
  assert.deepEqual(parseSentinel("pid=abc-123\nsrc=/Users/tomtim/x\n"),
    { pid: "abc-123", src: "/Users/tomtim/x" });
  assert.equal(parseSentinel("こわれている"), null);
  assert.equal(parseSentinel(""), null);
  assert.equal(parseSentinel(undefined), null);
});

test("listCheckouts: ID を持つ dir だけ数える。印と dir 名の不一致は出さない", () => {
  const root = makeRoot();
  plant(root, "proj-a");
  mkdirSync(join(root, "no-id-dir", "worktree"), { recursive: true }); // 印なし
  mkdirSync(join(root, "liar"), { recursive: true });
  writeFileSync(join(root, "liar", "ID"), "pid=someone-else\nsrc=/x\n"); // 名乗りが別
  const list = listCheckouts(root);
  assert.deepEqual(list.map((c) => c.id), ["proj-a"]);
  assert.equal(list[0].source, "/Users/tomtim/Infra/proj-a");
  assert.equal(list[0].returnRequestedAt, null);
});

test("listCheckouts: root が無い = 空(持ち出しゼロの機で 500 にしない)", () => {
  assert.deepEqual(listCheckouts("/no/such/root"), []);
});

test("checkoutIdForCwd: worktree の下だけが持ち出し。区切りまで見る", () => {
  const root = makeRoot();
  assert.equal(checkoutIdForCwd(`${root}/proj-a/worktree`, root), "proj-a");
  assert.equal(checkoutIdForCwd(`${root}/proj-a/worktree/src/deep`, root), "proj-a");
  assert.equal(checkoutIdForCwd(`${root}/proj-a/ID`, root), null, "worktree の外は持ち出しではない");
  assert.equal(checkoutIdForCwd(`${root}x/proj-a/worktree`, root), null, "★前方一致の罠(root と rootx)");
  assert.equal(checkoutIdForCwd("/Users/tomtim/normal", root), null);
  assert.equal(checkoutIdForCwd("", root), null);
});

test("requestReturn: 印を置く -> 一覧に載る。冪等(連打で時刻が進まない)", () => {
  const root = makeRoot();
  plant(root, "proj-b");
  const t1 = new Date("2026-08-16T10:00:00Z");
  const r1 = requestReturn(root, "proj-b", "sid-1", t1);
  assert.deepEqual(r1, { at: "2026-08-16T10:00:00.000Z", already: false });
  const r2 = requestReturn(root, "proj-b", "sid-1", new Date("2026-08-16T11:00:00Z"));
  assert.equal(r2.at, "2026-08-16T10:00:00.000Z", "★2度目の依頼が時刻を進めない");
  assert.equal(r2.already, true);
  assert.equal(listCheckouts(root)[0].returnRequestedAt, "2026-08-16T10:00:00.000Z");
});

test("requestReturn: 持ち出しでない所には置けない(印のばら撒きをしない)", () => {
  const root = makeRoot();
  assert.deepEqual(requestReturn(root, "ghost", "sid"), { error: "no-such-checkout" });
  assert.equal(existsSync(join(root, "ghost")), false, "dir すら作らない");
});

test("requestReturn: 書きは tmp -> rename(読み手に書きかけを読ませない)", () => {
  const root = makeRoot();
  plant(root, "proj-c");
  requestReturn(root, "proj-c", "sid-9");
  assert.doesNotThrow(() =>
    JSON.parse(readFileSync(join(root, "proj-c", "RETURN-REQUESTED"), "utf8")));
  assert.equal(readReturnRequest(root, "proj-c").sessionId, "sid-9");
});
