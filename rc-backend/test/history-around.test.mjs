// 錨(対照表 #3)を中心にした履歴窓(2026-09-03、窓読み)。
//
// 何故 要るか(`.harness/evidence-2026-09-03/search-jump.md`): 電話の探索は机の1要求あたりの
// 上限(500件)より深い当たりに `tooFar` と正直に言うだけで、其処へ着地する手段が無かった。
// `readHistoryAround` は錨の byte 位置から手前・先の両方を有界に読み、其の当たりを中心に
// した窓を返す。
//
// 守る性質: ① 錨は窓に必ず入る ② 前後 ~limit/2 件、file 順 ③ chunk の大小で窓が変わらない
// (境界の外側が1歩で読めてしまう chunk と、細かく刻む chunk が同じ答えを出す) ④ 先頭/末尾の
// 錨では片側が「続きなし」 ⑤ 壊れた錨(形が違う/行頭でない)を正直に断る ⑥ readLinesForward が
// 改行無しの最終行・多 byte 境界を跨いだ chunk を正しく扱う ⑦ readLinesBackward の既存呼び手は
// 無傷(`end` を渡さない呼び手は挙動が1 byte も変わらない = 全 suite で測る)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, openSync, closeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readHistoryAround, readHistoryFromPath, entriesFromLines } from "../src/sessions.mjs";
import { readLinesForward, nodeIo } from "../src/listing.mjs";

function rec(type, text) {
  return JSON.stringify({ type, message: { role: type, content: [{ type: "text", text }] } });
}

/** 300 record の転写。多 byte 文字を混ぜる(1件1項目 —— tool 呼び出しは別 test で扱う)。 */
function transcript300() {
  const dir = mkdtempSync(join(tmpdir(), "hist-around-"));
  const p = join(dir, "t.jsonl");
  const lines = [];
  for (let i = 0; i < 300; i++) {
    const text = `本文 ${i} 錨 ` + "字".repeat(i % 5 === 0 ? 40 : 5);
    lines.push(rec(i % 2 ? "assistant" : "user", text));
  }
  writeFileSync(p, lines.join("\n") + "\n");
  return { p, lines };
}

/** 錨の byte 位置に、其の行が本当に始まっているか(実 file を読んで確かめる)。 */
function lineAt(p, anchor) {
  const off = Number(anchor.split(":")[0]);
  const buf = readFileSync(p);
  const nl = buf.indexOf(0x0a, off);
  return buf.subarray(off, nl < 0 ? buf.length : nl).toString("utf8");
}

test("★窓: 中央の錨は必ず入り、前後 ~limit/2 件が file 順で並び、全ての錨が本物の位置を指す", () => {
  const { p } = transcript300();
  const full = readHistoryFromPath(p, 500).history;
  assert.equal(full.length, 300);
  const mid = full[150];
  const limit = 50;
  const r = readHistoryAround(p, mid.anchor, limit);
  const anchors = r.history.map((e) => e.anchor);

  assert.ok(anchors.includes(mid.anchor), "窓に中心の錨が無い");
  for (const e of r.history) {
    assert.match(e.anchor, /^\d+:\d+$/);
    assert.ok(lineAt(p, e.anchor).includes(e.text.slice(0, 4)), `錨 ${e.anchor} の位置に其の行が無い`);
  }
  const offs = anchors.map((a) => Number(a.split(":")[0]));
  assert.deepEqual(offs, [...offs].sort((a, b) => a - b), "並びが file 順でない");

  const idx = anchors.indexOf(mid.anchor);
  assert.ok(idx >= Math.ceil(limit / 2) - 2 && idx <= Math.ceil(limit / 2), `手前が ~limit/2 件でない(idx=${idx})`);
  assert.ok(r.history.length >= limit - 2 && r.history.length <= limit + 2, `窓の大きさが limit から離れすぎ(${r.history.length})`);
  assert.equal(r.olderAvailable, true, "中央の錨なら手前にまだ在る");
  assert.equal(r.newerAvailable, true, "中央の錨ならまだ先も在る");
  assert.equal(new Set(anchors).size, anchors.length, "錨が重複");
});

test("★窓: 窓の錨は readHistoryFromPath(500) の錨列の連続した部分列", () => {
  const { p } = transcript300();
  const full = readHistoryFromPath(p, 500).history.map((e) => e.anchor);
  const r = readHistoryAround(p, full[150], 40);
  const windowAnchors = r.history.map((e) => e.anchor);
  const start = full.indexOf(windowAnchors[0]);
  assert.notEqual(start, -1, "窓の先頭が全読みの錨列に無い");
  assert.deepEqual(full.slice(start, start + windowAnchors.length), windowAnchors, "連続した部分列でない");
});

test("先頭の錨: olderAvailable は false、窓は錨から始まる", () => {
  const { p } = transcript300();
  const full = readHistoryFromPath(p, 500).history;
  const r = readHistoryAround(p, full[0].anchor, 20);
  assert.equal(r.history[0].anchor, full[0].anchor);
  assert.equal(r.olderAvailable, false);
  assert.ok(r.history.length > 0);
});

test("末尾の錨: newerAvailable は false、窓は錨で終わる", () => {
  const { p } = transcript300();
  const full = readHistoryFromPath(p, 500).history;
  const last = full[full.length - 1];
  const r = readHistoryAround(p, last.anchor, 20);
  assert.equal(r.history[r.history.length - 1].anchor, last.anchor);
  assert.equal(r.newerAvailable, false);
  assert.ok(r.history.length > 0);
});

test("行の先頭でない byte 位置の錨は anchor-gone", () => {
  const { p } = transcript300();
  const full = readHistoryFromPath(p, 500).history;
  const off = Number(full[10].anchor.split(":")[0]);
  assert.throws(() => readHistoryAround(p, `${off + 2}:0`, 10), /anchor-gone/);
});

test("範囲外の byte 位置の錨は anchor-gone(捏造・書き換わった転写)", () => {
  const { p } = transcript300();
  assert.throws(() => readHistoryAround(p, "999999999:0", 10), /anchor-gone/);
  assert.throws(() => readHistoryAround(p, `${readFileSync(p).length}:0`, 10), /anchor-gone/, "= file size はEOFで行頭ではない");
});

test("形の壊れた錨は bad-anchor(file を開く前に断る)", () => {
  const { p } = transcript300();
  for (const bad of ["xyz", "5", "5:5:5", "-5:0", "5:-1", "", "5:", ":5", "5.0:0"]) {
    assert.throws(() => readHistoryAround(p, bad, 10), /bad-anchor/, `"${bad}" を弾いていない`);
  }
});

test("★small chunk(97/101)と既定 chunk が同じ窓を返す(chunk の大小で答えが変わらない)", () => {
  const { p } = transcript300();
  const full = readHistoryFromPath(p, 500).history;
  const anchor = full[150].anchor;
  const big = readHistoryAround(p, anchor, 40);
  for (const chunk of [97, 101]) {
    const small = readHistoryAround(p, anchor, 40, { chunk });
    assert.deepEqual(small.history.map((e) => e.anchor), big.history.map((e) => e.anchor), `chunk=${chunk} で窓が違う`);
    assert.deepEqual(small.history.map((e) => e.text), big.history.map((e) => e.text), `chunk=${chunk} で本文が違う`);
    assert.equal(small.olderAvailable, big.olderAvailable);
    assert.equal(small.newerAvailable, big.newerAvailable);
  }
});

test("★錨が複数項目を持つ行(道具呼び出し込み)を指す時、其の番号までは trim で切り落とさない", () => {
  const dir = mkdtempSync(join(tmpdir(), "hist-around-tool-"));
  const p = join(dir, "t.jsonl");
  const asstTool = (t, ...tools) =>
    JSON.stringify({
      type: "assistant",
      message: { role: "assistant", content: [{ type: "text", text: t }, ...tools.map((n) => ({ type: "tool_use", name: n }))] },
    });
  const before = Array.from({ length: 20 }, (_, i) => rec("user", `前 ${i}`));
  const target = asstTool("やります", "Read", "Bash", "Grep"); // 4項目: 本文+道具3つ、番号3が最後
  const after = Array.from({ length: 20 }, (_, i) => rec("user", `後 ${i}`));
  writeFileSync(p, [...before, target, ...after].join("\n") + "\n");

  const full = readHistoryFromPath(p, 500).history;
  const lastOfTarget = full.find((e) => e.text === "⚙ Grep");
  assert.ok(lastOfTarget, "fixture の組み立てが違う");
  // limit を小さくして、trim が効く条件を作る(手前だけで limit に届く)。
  const r = readHistoryAround(p, lastOfTarget.anchor, 4);
  assert.ok(r.history.some((e) => e.anchor === lastOfTarget.anchor), "行内番号が高い錨が trim で消えた");
  const toolEntries = r.history.filter((e) => e.anchor.startsWith(`${lastOfTarget.anchor.split(":")[0]}:`));
  assert.equal(toolEntries.length, 4, "同じ行の4項目が全部揃っていない");
  assert.deepEqual(toolEntries.map((e) => e.text), ["やります", "⚙ Read", "⚙ Bash", "⚙ Grep"]);
});

test("readLinesForward: 改行無しの最終行を拾う(EOF まで読み切った時だけ)", () => {
  const dir = mkdtempSync(join(tmpdir(), "fwd-"));
  const p = join(dir, "t.jsonl");
  writeFileSync(p, "行1\n行2\n行3(改行無し)"); // 末尾に改行が無い
  const fd = openSync(p, "r");
  try {
    const r = readLinesForward(nodeIo, fd, { start: 0, chunk: 4096, maxBytes: 1 << 20, done: () => false });
    assert.deepEqual(r.lines, ["行1", "行2", "行3(改行無し)"]);
    assert.equal(r.reachedEnd, true);
    assert.equal(r.offsets.length, r.lines.length);
    const buf = readFileSync(p);
    r.lines.forEach((l, i) => {
      assert.equal(buf.subarray(r.offsets[i], r.offsets[i] + Buffer.byteLength(l)).toString("utf8"), l, `line ${i} の位置が違う`);
    });
  } finally { closeSync(fd); }
});

test("readLinesForward: 予算切れ(reachedEnd=false)では改行無しの断片を行として拾わない", () => {
  const dir = mkdtempSync(join(tmpdir(), "fwd-budget-"));
  const p = join(dir, "t.jsonl");
  writeFileSync(p, "行1\n行2\n行3(改行無し・長い断片で埋める)");
  const fd = openSync(p, "r");
  try {
    // maxBytes を「行1\n」だけ読める大きさにする —— 断片は在るがまだ全部ではない。
    const r = readLinesForward(nodeIo, fd, { start: 0, chunk: 4, maxBytes: 4, done: () => false });
    assert.equal(r.reachedEnd, false);
    assert.ok(!r.lines.includes("行3(改行無し・長い断片で埋める)"), "読み切っていないのに最終行を確定させた");
  } finally { closeSync(fd); }
});

test("readLinesForward: 小さい chunk で多 byte 文字の境界を跨いでも offset は file の実位置", () => {
  const dir = mkdtempSync(join(tmpdir(), "fwd-mb-"));
  const p = join(dir, "t.jsonl");
  const lines = Array.from({ length: 15 }, (_, i) => `${i} 日本語の行 ${"字".repeat(i)}`);
  writeFileSync(p, lines.join("\n") + "\n");
  const fd = openSync(p, "r");
  try {
    // わざと文字幅の倍数から外す chunk で、境界が多 byte 文字の途中に落ちる様にする。
    const r = readLinesForward(nodeIo, fd, { start: 0, chunk: 11, maxBytes: 1 << 20, done: () => false });
    assert.deepEqual(r.lines, lines);
    assert.ok(!JSON.stringify(r.lines).includes("�"), "置換文字が出ていない(多 byte 文字が割れた)");
    const buf = readFileSync(p);
    r.lines.forEach((l, i) => {
      assert.equal(buf.subarray(r.offsets[i], r.offsets[i] + Buffer.byteLength(l)).toString("utf8"), l, `line ${i} の位置が違う`);
    });
  } finally { closeSync(fd); }
});

test("readLinesForward: start が末尾より後ろ(EOF そのもの)なら即 reachedEnd", () => {
  const dir = mkdtempSync(join(tmpdir(), "fwd-eof-"));
  const p = join(dir, "t.jsonl");
  writeFileSync(p, "行1\n行2\n");
  const size = readFileSync(p).length;
  const fd = openSync(p, "r");
  try {
    const r = readLinesForward(nodeIo, fd, { start: size, chunk: 64, maxBytes: 1 << 20, done: () => false });
    assert.deepEqual(r.lines, []);
    assert.equal(r.reachedEnd, true);
  } finally { closeSync(fd); }
});

test("ENOENT: file が無い会話は readHistoryAround も投げる(呼び手が ENOENT を見分けられる)", () => {
  assert.throws(() => readHistoryAround("/no/such/dir/none.jsonl", "0:0", 10), (e) => e.code === "ENOENT");
});

test("readLinesForward: read が 1 byte ずつしか返らなくても、繋いだ buffer に穴が開かない(M43f の対照)", () => {
  const data = Buffer.from("aaa\nbbb\nccc\n");
  const io = {
    fstat: () => ({ size: data.length }),
    read: (_fd, buf, pos) => { if (pos >= data.length) return 0; buf[0] = data[pos]; return 1; },
  };
  const r = readLinesForward(io, 0, { start: 0, chunk: 8, maxBytes: 1 << 20, done: () => false });
  assert.deepEqual(r.lines, ["aaa", "bbb", "ccc"]);
  assert.deepEqual(r.offsets, [0, 4, 8]);
  assert.equal(r.reachedEnd, true);
});
