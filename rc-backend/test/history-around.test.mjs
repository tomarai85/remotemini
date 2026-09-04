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
  // ★F5(2026-09-04、進む保証): 手前は `wantOlder` 件でなく `wantOlder+1` 件を要求する
  //   ("+1" が実際に見つかった時は窓へも残す —— chunk 不変に olderAvailable を決める為の
  //   証拠)。此の transcript は 300 件均一で手前に十分な数が在るので、上限が +1 される。
  assert.ok(idx >= Math.ceil(limit / 2) - 2 && idx <= Math.ceil(limit / 2) + 1, `手前が ~limit/2 件でない(idx=${idx})`);
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

// ── ここから Codex around-review (2026-09-04) の F1/F2/F5 追加分 ─────────────────

test("★F1: 巨大な1行(1.1MB)が最初の record でも around=0:0 は其の entry を返す(空にならない)", () => {
  const dir = mkdtempSync(join(tmpdir(), "hist-around-huge-"));
  const p = join(dir, "t.jsonl");
  const big = "x".repeat(1_100_000); // TAIL_MAX(1MiB既定)より大きい1行
  writeFileSync(p, `${rec("user", big)}\n`);
  const r = readHistoryAround(p, "0:0", 50);
  assert.equal(r.history.length, 1, "巨大な最初の record が消えた(空配列になった)");
  assert.equal(r.history[0].anchor, "0:0");
  assert.equal(r.history[0].text, big);
});

test("★F1: 巨大な1行が lineCap も超えれば anchor-gone になる(諦めて捏造しない)", () => {
  const dir = mkdtempSync(join(tmpdir(), "hist-around-toohuge-"));
  const p = join(dir, "t.jsonl");
  const big = "x".repeat(2_000_000); // 此の test の lineCap(1MiB)より大きい1行
  writeFileSync(p, `${rec("user", big)}\n`);
  assert.throws(() => readHistoryAround(p, "0:0", 50, { maxBytes: 64 * 1024, lineCap: 1024 * 1024 }), /anchor-gone/);
});

test("★F2: 錨の行内番号が其の行の実際の項目数を超えると anchor-gone(嘘の echo をしない)", () => {
  const dir = mkdtempSync(join(tmpdir(), "hist-around-f2-"));
  const p = join(dir, "t.jsonl");
  const line1 = rec("user", "1件目");
  const line2 = rec("user", "2件目"); // 1エントリ(index 0)しか持たない行
  writeFileSync(p, `${[line1, line2].join("\n")}\n`);
  const offset2 = Buffer.byteLength(line1, "utf8") + 1;
  assert.throws(() => readHistoryAround(p, `${offset2}:1`, 10), /anchor-gone/);
  // 対照: index 0 なら通る
  const ok = readHistoryAround(p, `${offset2}:0`, 10);
  assert.ok(ok.history.some((e) => e.anchor === `${offset2}:0`));
});

test("★F5(Codex 実例1): 4項目の行の最後の錨(:3)を limit=4 で要求しても、其の錨で再要求すると窓が進む", () => {
  const dir = mkdtempSync(join(tmpdir(), "hist-around-f5-tool-"));
  const p = join(dir, "t.jsonl");
  const asstTool = (t, ...tools) =>
    JSON.stringify({
      type: "assistant",
      message: { role: "assistant", content: [{ type: "text", text: t }, ...tools.map((n) => ({ type: "tool_use", name: n }))] },
    });
  const before = [rec("user", "前1"), rec("user", "前2")];
  const target = asstTool("やります", "Read", "Bash", "Grep"); // 4項目、番号3が最後
  const after = [rec("user", "後1"), rec("user", "後2")];
  writeFileSync(p, `${[...before, target, ...after].join("\n")}\n`);

  const full = readHistoryFromPath(p, 500).history;
  const anchorEntry = full.find((e) => e.text === "⚙ Grep");
  assert.ok(anchorEntry, "fixture の組み立てが違う");

  const r1 = readHistoryAround(p, anchorEntry.anchor, 4);
  assert.ok(r1.history.some((e) => e.anchor === anchorEntry.anchor));
  const lastAnchor1 = r1.history[r1.history.length - 1].anchor;
  assert.equal(r1.newerAvailable, true, "後に2件在るので newerAvailable は true の筈");
  assert.notEqual(lastAnchor1, anchorEntry.anchor,
    "newerAvailable なのに窓の最先が要求した錨と同じ(進めない = F5 違反)");

  const r2 = readHistoryAround(p, lastAnchor1, 4);
  assert.notDeepEqual(r2.history.map((e) => e.anchor), r1.history.map((e) => e.anchor),
    "窓の最先の錨で再要求しても同じ窓が返る(進んでいない)");
});

test("★F5(Codex 実例2): A/B/C(1件ずつ)を limit=1 で around=B すると窓が C まで届き、進める", () => {
  const dir = mkdtempSync(join(tmpdir(), "hist-around-f5-abc-"));
  const p = join(dir, "t.jsonl");
  writeFileSync(p, `${[rec("user", "A"), rec("user", "B"), rec("user", "C")].join("\n")}\n`);
  const full = readHistoryFromPath(p, 500).history;
  const b = full.find((e) => e.text === "B");
  assert.ok(b);
  const r = readHistoryAround(p, b.anchor, 1);
  const anchors = r.history.map((e) => e.anchor);
  assert.ok(anchors.includes(b.anchor), "窓に B(要求した錨)が無い");
  // 此の3件だけの file では C が最後 = 窓は本当に其処まで届いて良い(進めた証拠)。
  assert.deepEqual(r.history.map((e) => e.text), ["A", "B", "C"],
    "窓が B で止まっていて C まで届いていない(旧実装の不具合そのもの)");
  assert.equal(r.newerAvailable, false, "C が本当に最後なので newerAvailable は false");
});

test("★F5 property: 40件を中央から両端まで歩いても窓は繰り返さず、必ず端で止まる", () => {
  const dir = mkdtempSync(join(tmpdir(), "hist-around-walk-"));
  const p = join(dir, "t.jsonl");
  const lines = Array.from({ length: 40 }, (_, i) => rec(i % 2 ? "assistant" : "user", `entry ${i}`));
  writeFileSync(p, `${lines.join("\n")}\n`);
  const full = readHistoryFromPath(p, 500).history;
  assert.equal(full.length, 40);
  const limit = 5;
  const mid = full[20];

  // 前方(newerAvailable)へ、窓の最先の錨だけを使って歩く。
  let cur = readHistoryAround(p, mid.anchor, limit);
  const seenForward = new Set([cur.history.map((e) => e.anchor).join(",")]);
  let steps = 0;
  while (cur.newerAvailable && steps < 100) {
    const lastAnchor = cur.history[cur.history.length - 1].anchor;
    const next = readHistoryAround(p, lastAnchor, limit);
    assert.notEqual(next.history[next.history.length - 1].anchor, lastAnchor,
      `newerAvailable なのに窓が進んでいない(前方 step=${steps})`);
    const key = next.history.map((e) => e.anchor).join(",");
    assert.ok(!seenForward.has(key), `同じ窓を繰り返した(前方 step=${steps})`);
    seenForward.add(key);
    cur = next;
    steps += 1;
  }
  assert.ok(steps > 0 && steps < 100, `前方の歩数が異常(${steps})`);
  assert.equal(cur.newerAvailable, false, "前方の歩きが終端(newerAvailable:false)に届いていない");
  assert.equal(cur.history[cur.history.length - 1].anchor, full[full.length - 1].anchor,
    "前方の終点が本当の最後の錨でない");

  // 後方(olderAvailable)へ、窓の最古の錨だけを使って歩く。
  cur = readHistoryAround(p, mid.anchor, limit);
  const seenBackward = new Set([cur.history.map((e) => e.anchor).join(",")]);
  steps = 0;
  while (cur.olderAvailable && steps < 100) {
    const firstAnchor = cur.history[0].anchor;
    const next = readHistoryAround(p, firstAnchor, limit);
    assert.notEqual(next.history[0].anchor, firstAnchor,
      `olderAvailable なのに窓が進んでいない(後方 step=${steps})`);
    const key = next.history.map((e) => e.anchor).join(",");
    assert.ok(!seenBackward.has(key), `同じ窓を繰り返した(後方 step=${steps})`);
    seenBackward.add(key);
    cur = next;
    steps += 1;
  }
  assert.ok(steps > 0 && steps < 100, `後方の歩数が異常(${steps})`);
  assert.equal(cur.olderAvailable, false, "後方の歩きが終端(olderAvailable:false)に届いていない");
  assert.equal(cur.history[0].anchor, full[0].anchor, "後方の終点が本当の最初の錨でない");
});
