// 探索の当たりから本文の其の項目へ跳ぶ為の**錨**(2026-09-03、対照表 #3)。
//
// 守る性質: ① 錨は行の byte 位置(追記しか起きない jsonl で不変)② 同じ項目は素の履歴と探索で同じ錨
// ③ `fromEnd` = 末尾から何番目か(最新 = 0)= 電話が limit を伸ばす数 ④ chunk の境界と多 byte 文字を跨いでも
// 位置がずれない ⑤ 錨は一意。実 file で測る(偽の io は境界の嘘を作れる)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, openSync, closeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readHistoryFromPath, searchHistoryFromPath, entriesFromLines } from "../src/sessions.mjs";
import { readLinesBackward, nodeIo, tailLinesWithOffsets } from "../src/listing.mjs";

function rec(type, text) {
  return JSON.stringify({ type, message: { role: type, content: [{ type: "text", text }] } });
}

/** 60 record の転写。多 byte 文字を混ぜ、探す語 `needle` を 3 箇所に置く。 */
function transcript() {
  const dir = mkdtempSync(join(tmpdir(), "anchor-"));
  const p = join(dir, "t.jsonl");
  const lines = [];
  for (let i = 0; i < 60; i++) {
    const text = (i % 7 === 3 ? `needle 針 ${i} ` : "") + `本文 ${i} ` + "x".repeat(i % 5 === 0 ? 300 : 20);
    lines.push(rec(i % 2 ? "assistant" : "user", text));
  }
  writeFileSync(p, lines.join("\n") + "\n");
  return { p, lines };
}

/** 錨 `<offset>:<k>` の offset で file を読むと、其の行が始まる(= 錨は本物の位置)。 */
function lineAt(p, anchor) {
  const off = Number(anchor.split(":")[0]);
  const buf = readFileSync(p);
  const nl = buf.indexOf(0x0a, off);
  return buf.subarray(off, nl < 0 ? buf.length : nl).toString("utf8");
}

test("tailLinesWithOffsets: 位置は base + 行頭、空行は飛ばす、断片は carry", () => {
  const buf = Buffer.from("frag\nab\n\ncd\n");
  const r = tailLinesWithOffsets(buf, false, 100);
  assert.deepEqual(r.lines, ["ab", "cd"]);
  assert.deepEqual(r.offsets, [105, 109]);
  assert.equal(r.carry.toString(), "frag\n");
  const s = tailLinesWithOffsets(Buffer.from("é\nz"), true, 0);
  assert.deepEqual(s.lines, ["é", "z"]); assert.deepEqual(s.offsets, [0, 3], "é は 2 byte");
});

test("★readLinesBackward: 小さい chunk で境界を跨いでも offset は file の実位置", () => {
  const { p, lines } = transcript();
  const fd = openSync(p, "r");
  try {
    const r = readLinesBackward(nodeIo, fd, { chunk: 97, maxBytes: 1 << 20, done: () => false });
    assert.equal(r.reachedStart, true);
    assert.equal(r.lines.length, lines.length);
    assert.equal(r.offsets.length, r.lines.length);
    const buf = readFileSync(p);
    r.lines.forEach((l, i) => {
      assert.equal(buf.subarray(r.offsets[i], r.offsets[i] + Buffer.byteLength(l)).toString("utf8"), l, `line ${i} の位置が違う`);
    });
    assert.deepEqual(r.offsets, [...r.offsets].sort((a, b) => a - b), "並びは file 順");
  } finally { closeSync(fd); }
});

test("★同じ項目は素の履歴と探索で同じ錨を持ち、錨は一意で本物の位置を指す", () => {
  const { p } = transcript();
  const h = readHistoryFromPath(p, 500, { chunk: 101 });
  assert.equal(h.history.length, 60);
  const anchors = h.history.map((e) => e.anchor);
  assert.equal(new Set(anchors).size, anchors.length, "錨が重複");
  for (const e of h.history) {
    assert.match(e.anchor, /^\d+:\d+$/);
    assert.ok(lineAt(p, e.anchor).includes(JSON.stringify(e.text).slice(1, 12)), "錨の位置に其の行が無い");
  }
  const s = searchHistoryFromPath(p, "needle", 50, { chunk: 101 });
  assert.equal(s.matched, 9, "7 で割って 3 余る番号 = 3,10,17,24,31,38,45,52,59 の 9 件");
  for (const hit of s.history) {
    const same = h.history.find((e) => e.anchor === hit.anchor);
    assert.ok(same, `探索の錨 ${hit.anchor} が素の履歴に無い`);
    assert.equal(same.text, hit.text);
  }
});

test("★fromEnd: 最新の当たりは末尾からの番号、電話が limit を其の数まで伸ばせば其の項目が入る", () => {
  const { p } = transcript();
  const s = searchHistoryFromPath(p, "needle", 50, { chunk: 101 });
  const newest = s.history[s.history.length - 1];
  assert.equal(newest.fromEnd, 0, "59 番目 = 最新の record が当たり = 末尾から 0");
  const oldest = s.history[0];
  assert.equal(oldest.fromEnd, 56, "3 番目の record = 末尾から 56");
  // 電話の使い方: limit = fromEnd + 1 で読めば其の錨が入る
  const h = readHistoryFromPath(p, oldest.fromEnd + 1, { chunk: 101 });
  assert.ok(h.history.some((e) => e.anchor === oldest.anchor), "limit を伸ばした履歴に錨が入っていない");
  const short = readHistoryFromPath(p, oldest.fromEnd, { chunk: 101 });
  assert.ok(!short.history.some((e) => e.anchor === oldest.anchor), "1 本足りない limit で入る = fromEnd が 1 ずれている");
});

test("offsets 無しの呼び手には錨を付けない(要約など、線に出さない経路)", () => {
  const es = entriesFromLines([rec("user", "a"), rec("assistant", "b")]);
  assert.equal(es.length, 2);
  assert.ok(es.every((e) => !("anchor" in e)));
});

test("追記しても既存の錨は動かない(jsonl は追記のみ)", () => {
  const { p } = transcript();
  const before = readHistoryFromPath(p, 500, { chunk: 101 }).history.map((e) => e.anchor);
  writeFileSync(p, rec("user", "appended 追記") + "\n", { flag: "a" });
  const after = readHistoryFromPath(p, 500, { chunk: 101 }).history;
  assert.deepEqual(after.slice(0, before.length).map((e) => e.anchor), before);
  assert.equal(after.length, before.length + 1);
});
