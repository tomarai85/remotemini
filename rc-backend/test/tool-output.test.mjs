// 道具呼び出しの結果を折り畳む(queue `transcript-tool-output-folds-into-the-entry`)。
//
// `tool_use` の entry と、其の後の行で届く `tool_result` を `entriesFromLines` が対にして
// `output` / `outputTruncated` / `outputError` を entry へ足す。転写の形は Claude Code の
// jsonl そのまま:
//   assistant 行: message.content に `{type:"tool_use", id, name, input}`
//   user 行     : message.content に `{type:"tool_result", tool_use_id, content, is_error?}`
// ★此の repo の fixture / spec に `tool_result` の実例が無かったので、上の形は課題の brief に
//   書かれた Claude Code の転写形をそのまま採った(report にも明記)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  entriesFromLines,
  extractHistory,
  readHistoryFromPath,
  readHistoryAround,
  searchHistoryFromPath,
  TOOL_OUTPUT_PREVIEW_MAX,
  TOOL_OUTPUT_LINE_MAX,
} from "../src/sessions.mjs";

const L = (o) => JSON.stringify(o);

function toolUseLine(id, name = "Bash", input = {}) {
  return L({ type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", id, name, input }] } });
}
function toolResultLine(toolUseId, content, isError) {
  const block = { type: "tool_result", tool_use_id: toolUseId, content };
  if (isError !== undefined) block.is_error = isError;
  return L({ type: "user", message: { role: "user", content: [block] } });
}
function userLine(text) {
  return L({ type: "user", message: { role: "user", content: text } });
}

function tmpFile(lines) {
  const dir = mkdtempSync(join(tmpdir(), "tool-output-"));
  const p = join(dir, "t.jsonl");
  writeFileSync(p, lines.join("\n") + "\n");
  return p;
}

test("① ペアリング: tool_use と、後の行の tool_result が対になり output が乗る", () => {
  const lines = [toolUseLine("tu_1", "Bash"), toolResultLine("tu_1", "出力その物")];
  const entries = entriesFromLines(lines);
  assert.equal(entries.length, 1, "tool_result 行は可視の entry を生まない");
  assert.equal(entries[0].role, "tool");
  assert.equal(entries[0].output, "出力その物");
  assert.equal(entries[0].outputTruncated, false);
  assert.equal("outputError" in entries[0], false);
});

test("② 複数の道具: 1つの assistant 行に2つの tool_use、其々の tool_result が正しい方に対応する", () => {
  const lines = [
    L({
      type: "assistant",
      message: {
        role: "assistant",
        content: [
          { type: "tool_use", id: "tu_a", name: "Read", input: {} },
          { type: "tool_use", id: "tu_b", name: "Bash", input: {} },
        ],
      },
    }),
    toolResultLine("tu_b", "b の結果"),
    toolResultLine("tu_a", "a の結果"),
  ];
  const entries = entriesFromLines(lines);
  assert.equal(entries.length, 2);
  const read = entries.find((e) => e.text === "⚙ Read");
  const bash = entries.find((e) => e.text === "⚙ Bash");
  assert.equal(read.output, "a の結果", "id で正しく対応していない(取り違え)");
  assert.equal(bash.output, "b の結果", "id で正しく対応していない(取り違え)");
});

test("③ 結果が無い: tool_use だけなら output 系の鍵は一切生えない", () => {
  const entries = entriesFromLines([toolUseLine("tu_1", "Bash")]);
  assert.equal(entries.length, 1);
  assert.equal("output" in entries[0], false);
  assert.equal("outputTruncated" in entries[0], false);
  assert.equal("outputError" in entries[0], false);
});

test("④ content が文字列そのもの", () => {
  const entries = entriesFromLines([toolUseLine("tu_1"), toolResultLine("tu_1", "そのままの文字列")]);
  assert.equal(entries[0].output, "そのままの文字列");
});

test("⑤ content が [{type:'text',text}] の配列: 破片を \\n で繋ぐ", () => {
  const entries = entriesFromLines([
    toolUseLine("tu_1"),
    toolResultLine("tu_1", [{ type: "text", text: "1行目" }, { type: "text", text: "2行目" }]),
  ]);
  assert.equal(entries[0].output, "1行目\n2行目");
});

test("⑥ is_error: is_error:true で outputError:true が乗る。false/未指定では乗らない", () => {
  const err = entriesFromLines([toolUseLine("tu_1"), toolResultLine("tu_1", "boom", true)]);
  assert.equal(err[0].outputError, true);

  const ok = entriesFromLines([toolUseLine("tu_2"), toolResultLine("tu_2", "fine", false)]);
  assert.equal("outputError" in ok[0], false);

  const noKey = entriesFromLines([toolUseLine("tu_3"), toolResultLine("tu_3", "fine")]);
  assert.equal("outputError" in noKey[0], false);
});

test("⑦ ANSI / CR を剥がす", () => {
  const dirty = "\x1B[31m赤\x1B[0m字\r\n続き\r";
  const entries = entriesFromLines([toolUseLine("tu_1"), toolResultLine("tu_1", dirty)]);
  assert.equal(/\x1B|\r/.test(entries[0].output), false, `ANSI/CR が残っている: ${JSON.stringify(entries[0].output)}`);
  assert.match(entries[0].output, /赤字/);
});

test("⑧ byte 上限で切られ outputTruncated:true になる", () => {
  const long = "あ".repeat(1000); // 1文字3byte、900文字だけで上限を超える
  const entries = entriesFromLines([toolUseLine("tu_1"), toolResultLine("tu_1", long)]);
  assert.equal(entries[0].outputTruncated, true);
  assert.ok(Buffer.byteLength(entries[0].output, "utf8") <= TOOL_OUTPUT_PREVIEW_MAX,
    `byte 上限を超えている: ${Buffer.byteLength(entries[0].output, "utf8")}`);
  // 多 byte 文字の境界を跨いで文字化けしていない事(有効な UTF-8 として再エンコードできる)
  assert.equal(Buffer.from(entries[0].output, "utf8").toString("utf8"), entries[0].output);
});

test("⑨ 行数上限で切られ outputTruncated:true になる", () => {
  const manyLines = Array.from({ length: 20 }, (_, i) => `行${i}`).join("\n");
  const entries = entriesFromLines([toolUseLine("tu_1"), toolResultLine("tu_1", manyLines)]);
  assert.equal(entries[0].outputTruncated, true);
  assert.equal(entries[0].output.split("\n").length, TOOL_OUTPUT_LINE_MAX);
  assert.equal(entries[0].output, ["行0", "行1", "行2", "行3", "行4", "行5"].join("\n"));
});

test("⑩ 探索(searchHistoryFromPath)は output を見ない: output だけに在る語では当たらない", () => {
  const p = tmpFile([
    userLine("最初の質問"),
    toolUseLine("tu_1", "Bash"),
    toolResultLine("tu_1", "しるしるだけの秘密語ZZZ99"),
  ]);
  const r = searchHistoryFromPath(p, "秘密語ZZZ99", 50);
  assert.equal(r.matched, 0, "output の中身が探索に当たっている(scope 違反)");
  assert.equal(r.history.length, 0);
  // 対照: 素の履歴には output として本当に載っている事(探索が的外れを測っていないか)
  const h = readHistoryFromPath(p, 50).history;
  const tool = h.find((e) => e.role === "tool");
  assert.match(tool.output, /秘密語ZZZ99/, "対照失敗: output に載っていない = 検体が壊れている");
});

test("⑪ tool_result だけの行は user entry として表に出ない", () => {
  const p = tmpFile([userLine("質問"), toolUseLine("tu_1"), toolResultLine("tu_1", "結果本文")]);
  const h = readHistoryFromPath(p, 50).history;
  assert.deepEqual(h.map((e) => e.role), ["user", "tool"], "tool_result の行が別途 user として出ている");
  assert.equal(h.some((e) => e.role === "user" && /結果本文/.test(e.text)), false);
});

test("⑫ readHistoryFromPath(末尾読み)でも preview が乗る", () => {
  const p = tmpFile([userLine("質問"), toolUseLine("tu_1", "Grep"), toolResultLine("tu_1", "grep hit x3")]);
  const r = readHistoryFromPath(p, 50);
  const tool = r.history.find((e) => e.role === "tool");
  assert.equal(tool.output, "grep hit x3");
  assert.equal(tool.outputTruncated, false);
});

test("⑬ readHistoryAround(窓読み)でも同じ側に在れば preview が乗る", () => {
  const lines = [];
  for (let i = 0; i < 30; i++) lines.push(userLine(`詰め物 ${i}`));
  lines.push(toolUseLine("tu_1", "Write"));
  lines.push(toolResultLine("tu_1", "書き込み完了"));
  for (let i = 0; i < 30; i++) lines.push(userLine(`後の詰め物 ${i}`));
  const p = tmpFile(lines);
  const full = readHistoryFromPath(p, 500).history;
  const toolEntry = full.find((e) => e.role === "tool");
  assert.ok(toolEntry, "前提: tool entry が読めていない");
  const r = readHistoryAround(p, toolEntry.anchor, 10);
  const tool = r.history.find((e) => e.role === "tool");
  assert.ok(tool, "窓に tool entry が入っていない");
  assert.equal(tool.output, "書き込み完了");
});

test("⑭ readHistoryAround: tool_result が両方の窓の外なら例外を投げず、output 系の鍵が無いまま出る" +
  "(2026-09-04、T-F2 の対照: before/after を跨いだ対にする修正は、実際に読んでいない行までは取りに行かない)", () => {
  const lines = [];
  lines.push(toolUseLine("tu_1", "Bash")); // これを錨にする(file 先頭 = before 側は空)
  // 錨と tool_result の間に十分な数の user 行を挟む。`readLinesForward` は chunk ごとに
  // `done`(項目数が limit に届いたか)を見て止まるので、**小さい chunk を明示**しないと
  // 小さな fixture は1 chunk で file 末尾まで読み切ってしまい、窓の外という状況が作れない
  // (`readHistoryFromPath` 等が tail を丸ごと読むのと同じ理由 —— 之は其の逆に振った検体)。
  for (let i = 0; i < 40; i++) lines.push(userLine(`間の埋め草 ${i}`));
  lines.push(toolResultLine("tu_1", "遠くの結果"));
  const p = tmpFile(lines);
  const full = readHistoryFromPath(p, 500).history;
  const toolEntry = full.find((e) => e.role === "tool");
  assert.ok(toolEntry);
  const opts = { chunk: 100 }; // 埋め草1行 ≈ 60-90B。limit=6 に届くのに数 chunk、tool_result(42行目)には遠く届かない
  assert.doesNotThrow(() => readHistoryAround(p, toolEntry.anchor, 6, opts));
  const r = readHistoryAround(p, toolEntry.anchor, 6, opts);
  const tool = r.history.find((e) => e.role === "tool");
  assert.ok(tool, "窓に tool entry 自体は入っている(anchor なので必ず入る)");
  assert.equal("output" in tool, false, "窓の外の tool_result で output が付いてしまっている");
  assert.equal("outputTruncated" in tool, false);
});

test("⑮ extractHistory(要約読み)でも preview が乗り、tail から limit 件で切られる", () => {
  const lines = [userLine("質問1"), toolUseLine("tu_1", "Bash"), toolResultLine("tu_1", "結果1"), userLine("質問2")];
  const h = extractHistory(lines.join("\n"), 10);
  const tool = h.find((e) => e.role === "tool");
  assert.equal(tool.output, "結果1");
});

// ── ここから Codex toolout-review (2026-09-04) の T-F1/T-F2/T-F3/T-F4/T-F5 追加分 ──────

test("★T-F1: 1.1MB の tool_result が在っても readHistoryFromPath(末尾読み)は tool entry を失わない", () => {
  const big = "x".repeat(1_100_000); // TAIL_MAX(1MiB既定)より大きい1レコード
  const p = tmpFile([toolUseLine("tu_1", "Bash"), toolResultLine("tu_1", big)]);
  const r = readHistoryFromPath(p, 50);
  const tool = r.history.find((e) => e.role === "tool");
  assert.ok(tool, "巨大な tool_result のせいで tool_use の entry ごと消えた(旧実装の不具合)");
  assert.equal(tool.output, "x".repeat(TOOL_OUTPUT_PREVIEW_MAX), "帯の上限までは中身が届いている筈");
  assert.equal(tool.outputTruncated, true);
});

test("★T-F2: readHistoryAround は before(手前)の tool_use と after(先)の tool_result も対にする", () => {
  const p = tmpFile([toolUseLine("tu_1", "Bash"), userLine("錨"), toolResultLine("tu_1", "結果本文")]);
  const full = readHistoryFromPath(p, 500).history;
  const anchorEntry = full.find((e) => e.role === "user" && e.text === "錨");
  assert.ok(anchorEntry, "fixture の組み立てが違う");
  const r = readHistoryAround(p, anchorEntry.anchor, 4);
  const tool = r.history.find((e) => e.role === "tool");
  assert.ok(tool, "窓に tool entry が入っていない(before 側に居る筈)");
  assert.equal(tool.output, "結果本文",
    "before の tool_use と after の tool_result が対にならなかった(継ぎ目を跨げていない)");
});

test("★T-F3: content が空文字列の破片を大量に(20万件)持っていても、予算より先に全走査しない", () => {
  const n = 200000;
  const items = new Array(n).fill('{"type":"text","text":""}');
  const contentJson = `[${items.join(",")}]`;
  const line1 = toolUseLine("tu_1", "Bash");
  // ★JSON.stringify(配列) だと**検体を作る側**が先に全要素へ触れてしまう(測りたい対象は
  //   `entriesFromLines` 側の遅延なので、検体は文字列連結で直接組み立てる)。
  const line2 = `{"type":"user","message":{"role":"user","content":[` +
    `{"type":"tool_result","tool_use_id":"tu_1","content":${contentJson}}]}}`;
  const t0 = Date.now();
  const entries = entriesFromLines([line1, line2]);
  const ms = Date.now() - t0;
  assert.equal(entries.length, 1);
  assert.equal(entries[0].outputTruncated, true,
    "空文字列の破片でも、繋ぐ改行だけで予算(8192文字)を使い切る筈(T-F3 の柵)");
  assert.ok(Buffer.byteLength(entries[0].output ?? "", "utf8") <= TOOL_OUTPUT_PREVIEW_MAX);
  assert.ok(ms < 500, `20万件の空文字列破片の処理に ${ms}ms も掛かっている = 予算より先に全走査している疑い`);
});

test("★T-F4: 表示できない block(image 等)が混ざると truncated:true になる(『全部載せた』と嘘をつかない)", () => {
  const lines = [
    toolUseLine("tu_1", "Read"),
    L({
      type: "user",
      message: {
        role: "user",
        content: [{
          type: "tool_result",
          tool_use_id: "tu_1",
          content: [
            { type: "text", text: "shown" },
            { type: "image", source: { type: "base64", media_type: "image/png", data: "AA==" } },
          ],
        }],
      },
    }),
  ];
  const entries = entriesFromLines(lines);
  assert.equal(entries[0].output, "shown");
  assert.equal(entries[0].outputTruncated, true, "image block を省いたのに truncated が立っていない");
});

test("★T-F4: content が配列でも文字列でもない形は、拾える文字列が無ければ output 系の鍵ごと省く", () => {
  const lines = [
    toolUseLine("tu_1", "Bash"),
    L({
      type: "user",
      message: {
        role: "user",
        content: [{ type: "tool_result", tool_use_id: "tu_1", content: { weird: "shape" } }],
      },
    }),
  ];
  const entries = entriesFromLines(lines);
  assert.equal("output" in entries[0], false, "何も読めていないのに output:\"\" を捏造している");
  assert.equal("outputTruncated" in entries[0], false);
});

test("★T-F5: 同じ id の tool_use が2つ在っても、tool_result は先に呼ばれた方(FIFO)に対応する", () => {
  const lines = [
    L({ type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", id: "dup", name: "Read", input: {} }] } }),
    L({ type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", id: "dup", name: "Bash", input: {} }] } }),
    toolResultLine("dup", "read result"),
  ];
  const entries = entriesFromLines(lines);
  const read = entries.find((e) => e.text === "⚙ Read");
  const bash = entries.find((e) => e.text === "⚙ Bash");
  assert.equal(read.output, "read result", "先に来た tool_use(Read)に対応していない(FIFO 違反)");
  assert.equal("output" in bash, false, "後の tool_use(Bash)にまで結果が付いている(二重に対応している)");
});
