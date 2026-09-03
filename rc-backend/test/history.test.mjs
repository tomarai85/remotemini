// readHistoryFromPath の unit test — 電話が会話を開くたびに通る経路。
//
// なぜ別建てで検査するか(2026-08-02): 履歴を有界読みに直した時、この関数だけ検査が0本のまま
// 出荷しかけた。e2e は /history を通しで叩くが、そこで使う jsonl は数行しかないので
// **「一部しか読まずに正しい件数を出す」という難所を1度も通っていない**。緑の数が増えても
// 難所を跨いでいなければ守りにならない、という同じ型の失敗(mutation-controls.py 冒頭)。
//
// listing.test.mjs と同じく本物のファイルで回す。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { entriesFromLines, extractHistory, readHistoryFromPath } from "../src/sessions.mjs";

const L = (o) => `${JSON.stringify(o)}\n`;
const user = (t) => L({ type: "user", message: { role: "user", content: t } });
const asst = (t) => L({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: t }] } });
const asstTool = (t, ...tools) =>
  L({
    type: "assistant",
    message: {
      role: "assistant",
      content: [{ type: "text", text: t }, ...tools.map((n) => ({ type: "tool_use", name: n }))],
    },
  });
const meta = (i) => L({ type: "ai-title", aiTitle: `題 ${i}` }); // 項目を1つも生まない行

const withFile = (body, fn, ...args) => {
  const d = mkdtempSync(join(tmpdir(), "rc-hist-"));
  const p = join(d, "s.jsonl");
  writeFileSync(p, body);
  try {
    return fn(p);
  } finally {
    rmSync(d, { recursive: true });
  }
};

test("末尾から limit 件、古い順で返る", () => {
  const body = Array.from({ length: 10 }, (_, i) => user(`発言${i}`)).join("");
  withFile(body, (p) => {
    const r = readHistoryFromPath(p, 3);
    assert.deepEqual(r.history.map((h) => h.text), ["発言7", "発言8", "発言9"]);
    assert.equal(r.history[0].role, "user");
  });
});

test("全部読み切って limit に満たない時は truncated=false(「まだ前がある」と嘘を言わない)", () => {
  withFile(user("あ") + asst("い"), (p) => {
    const r = readHistoryFromPath(p, 50);
    assert.equal(r.history.length, 2);
    assert.equal(r.truncated, false);
  });
});

test("limit より多く在れば truncated=true", () => {
  const body = Array.from({ length: 5 }, (_, i) => user(`x${i}`)).join("");
  withFile(body, (p) => {
    assert.equal(readHistoryFromPath(p, 2).truncated, true);
  });
});

test("★止める条件は行数でなく項目数(項目を生まない行が挟まっても limit 件そろう)", () => {
  // 1レコード = 1項目ではない。ai-title は 0項目、tool 付きの assistant は 3項目。
  // 「行が limit 本読めたら止める」に退行すると、meta 行だらけの区間で**足りないまま返る**。
  const body = Array.from({ length: 12 }, (_, i) => meta(i) + meta(i) + meta(i) + user(`u${i}`)).join("");
  withFile(body, (p) => {
    const r = readHistoryFromPath(p, 5, { chunk: 200 });
    assert.equal(r.history.length, 5, "meta 行を数に入れてしまうと 5 件に届かない");
    assert.deepEqual(r.history.map((h) => h.text), ["u7", "u8", "u9", "u10", "u11"]);
  });
});

test("★1レコードが複数項目でも数え違えない(本文 + 道具2つ = 3項目)", () => {
  withFile(user("お願い") + asstTool("やります", "Read", "Bash"), (p) => {
    const r = readHistoryFromPath(p, 3, { chunk: 64 });
    // 錨(対照表 #3)は行の位置 + 行内の番号。3 項目とも同じ行(1 レコード)なので位置が同じで番号が違う。
    assert.ok(r.history.every((e) => /^\d+:\d+$/.test(e.anchor)), JSON.stringify(r.history));
    assert.equal(new Set(r.history.map((e) => e.anchor.split(":")[0])).size, 1, "同じ 1 行の項目は同じ位置");
    assert.deepEqual(r.history.map(({ anchor, ...e }) => e), [
      { role: "user", text: "お願い" },
      { role: "assistant", text: "やります" },
      { role: "tool", text: "⚙ Read" },
      { role: "tool", text: "⚙ Bash" },
    ].slice(-3));
  });
});

test("★チャンク境界を跨いだレコードが1度だけ現れる(重複も欠落もしない)", () => {
  // 1行を故意にチャンクより長くし、境界が行の途中に落ちる形にする。
  const body = user("あ".repeat(120)) + user("しるし") + user("おわり");
  withFile(body, (p) => {
    const r = readHistoryFromPath(p, 50, { chunk: 96 });
    assert.equal(r.history.filter((h) => h.text === "しるし").length, 1);
    assert.equal(r.history.length, 3);
    assert.equal(r.history[0].text, "あ".repeat(120));
  });
});

test("★予算切れは truncated=true(読めた分だけ返す)", () => {
  const body = Array.from({ length: 60 }, (_, i) => user(`u${i}`)).join("");
  withFile(body, (p) => {
    const r = readHistoryFromPath(p, 50, { chunk: 64, maxBytes: 128 });
    assert.ok(r.history.length > 0, "少しは読めている");
    assert.ok(r.history.length < 50, "予算内では 50 件に届かない");
    assert.equal(r.truncated, true);
    assert.ok(r.scanned <= 128 + 64, "予算を大きく超えて読んでいない");
    assert.equal(r.history.at(-1).text, "u59", "打ち切っても**末尾側**が残る");
  });
});

test("壊れた行は飛ばし、前後の項目は残る", () => {
  withFile(user("前") + "{壊れた\n" + user("後"), (p) => {
    assert.deepEqual(readHistoryFromPath(p, 50).history.map((h) => h.text), ["前", "後"]);
  });
});

test("空ファイルは空配列(truncated=false)", () => {
  withFile("", (p) => {
    assert.deepEqual(readHistoryFromPath(p, 50), { history: [], truncated: false, scanned: 0 });
  });
});

test("多バイト文字がチャンク境界に来ても割れない", () => {
  const body = user("日本語の発言をここに置く".repeat(20)) + user("しめ");
  withFile(body, (p) => {
    const r = readHistoryFromPath(p, 50, { chunk: 37 }); // わざと文字幅の倍数から外す
    assert.equal(r.history[0].text, "日本語の発言をここに置く".repeat(20));
    assert.ok(!JSON.stringify(r.history).includes("�"), "置換文字が出ていない");
  });
});

test("有界読みと全部読みが同じ答えを出す(extractHistory との突き合わせ)", () => {
  const body = Array.from({ length: 30 }, (_, i) => (i % 3 === 0 ? meta(i) : "") + user(`u${i}`) + asstTool(`a${i}`, "Grep")).join("");
  withFile(body, (p) => {
    const bounded = readHistoryFromPath(p, 12, { chunk: 128 }).history;
    const whole = extractHistory(body, 12);
    assert.deepEqual(bounded, whole);
  });
});

test("entriesFromLines は行の配列をそのまま項目にする(履歴とライブで同じ関数)", () => {
  const lines = (user("q") + asstTool("a", "Read")).split("\n");
  assert.deepEqual(entriesFromLines(lines), [
    { role: "user", text: "q" },
    { role: "assistant", text: "a" },
    { role: "tool", text: "⚙ Read" },
  ]);
});
