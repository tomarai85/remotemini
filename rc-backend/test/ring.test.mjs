// SSE 再接続の追いつき用リングバッファ — テスト先行(tdd-gate の型)。
//
// 契約(spec §In-4): ストリーム切断→再接続で取りこぼした分を seq 番号で追いつく。
// 本家 RC の「再構築中の更新はキューして回復後に配送」(teardown §4, v2.1.207 の修正)を
// 最初から入れるための部品。
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventRing } from "../src/ring.mjs";

test("push は連番 seq を振る(1始まり)", () => {
  const r = new EventRing(4);
  assert.equal(r.push({ a: 1 }), 1);
  assert.equal(r.push({ a: 2 }), 2);
});

test("since(n) は n より後の全イベントを順に返す", () => {
  const r = new EventRing(8);
  for (let i = 1; i <= 5; i++) r.push({ i });
  const got = r.since(2);
  assert.deepEqual(got.map((e) => e.seq), [3, 4, 5]);
  assert.deepEqual(got.map((e) => e.data.i), [3, 4, 5]);
});

test("容量超過で古い物から落ち、落ちた範囲の since は gap を申告する", () => {
  const r = new EventRing(3);
  for (let i = 1; i <= 6; i++) r.push({ i });
  // 保持は 4,5,6。seq=1 からの追いつきは不可能 = gap。
  const res = r.since(1);
  assert.equal(res.gap, true); // 呼び手は「履歴を読み直せ」へ倒す
  assert.deepEqual(res.map((e) => e.seq), [4, 5, 6]);
});

test("gap なしの場合 gap フラグは falsy", () => {
  const r = new EventRing(8);
  r.push({});
  r.push({});
  assert.ok(!r.since(1).gap);
});

test("since(最新) は空配列", () => {
  const r = new EventRing(4);
  r.push({});
  assert.deepEqual(r.since(1), []);
});

test("空リングの since(0) は空・gap なし", () => {
  const r = new EventRing(4);
  const res = r.since(0);
  assert.equal(res.length, 0);
  assert.ok(!res.gap);
});
