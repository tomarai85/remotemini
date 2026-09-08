// attach-sweep-clock.test.mjs — 添付の掃除を時計でも回す(2026-09-08、机の掃引 #4)。
//
// 何が問題だったか: `sweepOld`(7 日を過ぎた添付を消す)は `attach` / `attach-file` の口の**中でしか**
// 走らなかった。添付は滅多に使わない機能なので、暫く誰も添付しなければ TTL を過ぎた物が残り続ける ——
// ディレクトリは「次に誰かが添付した時」にしか縮まない。ワーカーの掃除は 30 秒の時計で回っていて、
// 此処だけが例外だった。
//
// 掃除そのものの振る舞い(古い物だけ消す / 形の合わない名前は触らない)は `attach.test.mjs` が測る。
// 此処が測るのは**いつ回るか**だけ:
//   1. 間隔が TTL より十分細かい(粗すぎる時計は掃除しないのと同じ)。
//   2. 時計の側にも掃除が配線されている(口の中だけへ戻ったら赤)。
//   3. 時計の掃除は毎 30 秒ではなく間隔で間引く(readdir を無駄に叩かない)。
//   4. 口の中の掃除は残す(添付した直後に効くのが一番安い)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ATTACH_TTL_MS, ATTACH_SWEEP_EVERY_MS } from "../src/attach.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const SERVER = readFileSync(join(HERE, "..", "src", "server.mjs"), "utf8");

/** 30 秒の時計の本体だけを切り出す(配線の主張を口の中の呼び出しと混ぜない為)。 */
function clockBlock() {
  const i = SERVER.indexOf("setInterval(() => {");
  assert.ok(i > 0, "30 秒の時計が無い");
  const j = SERVER.indexOf("}, 30_000).unref();", i);
  assert.ok(j > i, "30 秒の時計の終わりが見つからない");
  return SERVER.slice(i, j);
}

test("掃除の間隔は TTL より十分細かい(粗すぎる時計は掃除しないのと同じ)", () => {
  assert.equal(typeof ATTACH_SWEEP_EVERY_MS, "number");
  assert.ok(ATTACH_SWEEP_EVERY_MS > 0);
  assert.ok(ATTACH_SWEEP_EVERY_MS * 24 <= ATTACH_TTL_MS, "間隔が TTL に対して粗すぎる");
});

test("★配線: 時計の中でも添付を掃除する(口の中だけへ戻ったら赤)", () => {
  const block = clockBlock();
  assert.ok(block.includes("manager.sweep()"), "ワーカーの掃除が時計から消えた");
  assert.ok(block.includes("sweepOld(ATTACH_DIR"), "添付の掃除が時計に配線されていない");
});

test("★時計の掃除は間隔で間引く(毎 30 秒 readdir しない)", () => {
  const block = clockBlock();
  assert.ok(block.includes("ATTACH_SWEEP_EVERY_MS"), "間引きの条件が無い = 30 秒毎に readdir する");
  assert.ok(block.includes("lastAttachSweep = t"), "最後に掃除した時刻を進めていない = 条件が効かない");
});

test("口の中の掃除は残す(添付した直後に効くのが一番安い)", () => {
  // 時計の 1 回 + `attach` + `attach-file` = 3 箇所以上
  const calls = SERVER.split("sweepOld(ATTACH_DIR").length - 1;
  assert.ok(calls >= 3, `sweepOld の呼び出しが ${calls} 箇所しかない(口の中が消えた可能性)`);
});

test("★時計の掃除は消した時だけ記録に残す(誰にも見えない削除を作らない)", () => {
  const block = clockBlock();
  assert.ok(block.includes("swept.removed > 0"), "消した時だけ言う条件が無い");
  assert.ok(block.includes("console.log"), "時計の掃除が何も記録しない = 見えない所で file が消える");
});

test("★否定対照: 切り出しているのは時計の本体だけ(file 全体を掴んでいたら上の 4 件は恒真)", () => {
  const block = clockBlock();
  assert.ok(block.length < 1200, `切り出しが ${block.length} 文字 = 時計の本体より広い`);
  assert.ok(!block.includes("attachBody"), "口の中の応答まで掴んでいる = 配線の主張が空回りする");
});
