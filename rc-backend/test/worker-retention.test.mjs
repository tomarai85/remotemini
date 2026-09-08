// worker-retention.test.mjs — ワーカーの居ない会話の記憶に上限を付ける(2026-09-08、机の掃引 #2)。
//
// 何が問題だったか: `WorkerManager` の 4 本の Map(`rings` / `gens` / `listeners` / `lastSpawnError`)は
// 一度も `delete` されなかった。輪を残すのは**意図**(電話が背面から戻った時に取り零しを拾える)だが、
// 常駐の daemon なので worker 経路を通った会話 id が増えるだけ増える —— 他の cache は全部 TTL か上限を
// 持っているのに此処だけが例外だった。
//
// 守る物:
//   1. 生きているワーカーの会話は**絶対に捨てない**。
//   2. 死んで一定時間たった会話は捨てる(時間の縛り)。
//   3. 時間の内側でも、覚える数に上限がある(数の縛り。古い順に捨てる)。
//   4. 捨てるのは 4 本まとめて —— 片方だけ残すと「輪は無いのに世代だけ在る」形が生まれる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { WorkerManager } from "../src/worker.mjs";

/** 時計を手で進められる manager。spawn は呼ばない(記憶の掃除だけを見る)。 */
function manager() {
  let t = 1_000_000;
    const m = new WorkerManager({ spawn: () => { throw new Error("not used"); }, now: () => t });
  return { m, advance: (ms) => { t += ms; }, at: () => t };
}

/** ワーカー無しで「昔このセッションが居た」状態を作る。 */
function retire(m, sid, at) {
  m.rings.set(sid, { sid });
  m.gens.set(sid, 1);
  m.listeners.set(sid, () => {});
  m.lastSpawnError.set(sid, null);
  m.retiredAt.set(sid, at);
}
const remembers = (m, sid) => m.rings.has(sid) || m.gens.has(sid) || m.listeners.has(sid) || m.lastSpawnError.has(sid) || m.retiredAt.has(sid);

test("生きているワーカーの会話は捨てない(記憶の掃除の対象外)", () => {
  const { m, at } = manager();
  retire(m, "alive", at() - 10 * 60 * 60 * 1000);   // 10 時間前に「退役」した記録が在っても…
  m.workers.set("alive", { state: "ready", lastActive: at() });   // …今ワーカーが居るなら対象外
  m.sweep();
  assert.equal(remembers(m, "alive"), true);
});

test("★死んで保持時間を過ぎた会話は 4 本まとめて捨てる", () => {
  const { m, advance, at } = manager();
  retire(m, "old", at());
  advance(31 * 60 * 1000);
  m.sweep();
  assert.equal(m.rings.has("old"), false);
  assert.equal(m.gens.has("old"), false);
  assert.equal(m.listeners.has("old"), false);
  assert.equal(m.lastSpawnError.has("old"), false);
  assert.equal(m.retiredAt.has("old"), false);
});

test("保持時間の内側なら残る(電話が背面から戻って取り零しを拾える窓)", () => {
  const { m, advance, at } = manager();
  retire(m, "recent", at());
  advance(29 * 60 * 1000);
  m.sweep();
  assert.equal(m.rings.has("recent"), true);
});

test("★数の上限: 時間の内側でも、覚えるのは上限までで古い順に捨てる", () => {
  const { m, at } = manager();
  for (let i = 0; i < 100; i++) retire(m, `s${String(i).padStart(3, "0")}`, at() - (100 - i) * 1000);
  m.sweep();
  assert.equal(m.rings.size, 64, `残した数=${m.rings.size}`);
  assert.equal(m.rings.has("s000"), false, "一番古い物が残っている");
  assert.equal(m.rings.has("s099"), true, "一番新しい物が消えている");
  // 4 本の大きさが揃う(片方だけ残らない)
  assert.equal(m.gens.size, 64);
  assert.equal(m.listeners.size, 64);
  assert.equal(m.retiredAt.size, 64);
});

test("★否定対照: 掃除を呼ばなければ増え続ける(此の検査が何かを測っている証拠)", () => {
  const { m, advance, at } = manager();
  for (let i = 0; i < 100; i++) retire(m, `n${i}`, at());
  advance(31 * 60 * 1000);
  assert.equal(m.rings.size, 100, "掃除の前に既に減っているなら、上の検査は掃除を測っていない");
  m.sweep();
  assert.equal(m.rings.size, 0);
});
