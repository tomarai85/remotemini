// sessions.mjs の unit test — fixture 文字列のみ、fs 不要。
// 実行: node --test test/
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  extractSessionMeta,
  resolveTitle,
  buildListing,
  extractHistory,
} from "../src/sessions.mjs";

const L = (o) => JSON.stringify(o);

test("entrypoint と cwd を最初の該当行から拾う", () => {
  const text = [
    L({ type: "system" }),
    L({ entrypoint: "cli", cwd: "/Users/Shared/dev/roundtrip", type: "user", message: { content: "hi" } }),
    L({ entrypoint: "sdk-cli" }), // 後の行は最初の値を上書きしない
  ].join("\n");
  const m = extractSessionMeta(text);
  assert.equal(m.entrypoint, "cli");
  assert.equal(m.cwd, "/Users/Shared/dev/roundtrip");
});

test("ai-title は後の行が勝つ(再生成に追従)", () => {
  const text = [
    L({ type: "ai-title", aiTitle: "古い題" }),
    L({ type: "ai-title", aiTitle: "新しい題" }),
  ].join("\n");
  assert.equal(extractSessionMeta(text).title, "新しい題");
});

test("壊れた行(書き込み途中)は黙って飛ばし、残りは読む", () => {
  const text = [
    L({ entrypoint: "cli" }),
    '{"type":"ai-title","aiTitle":"完全な行"}',
    '{"type":"last-prompt","lastPrompt":"途中で切れ', // 破損
  ].join("\n");
  const m = extractSessionMeta(text);
  assert.equal(m.title, "完全な行");
  assert.equal(m.lastPrompt, null);
});

test("空文字・非文字列で落ちない", () => {
  assert.equal(extractSessionMeta("").entrypoint, null);
  assert.equal(extractSessionMeta(undefined).entrypoint, null);
});

test("タイトル解決順: ai-title → last-prompt(60字丸め)→ id 短縮", () => {
  assert.equal(resolveTitle({ title: "T", lastPrompt: "L" }, "abcdef123456"), "T");
  assert.equal(resolveTitle({ title: null, lastPrompt: "  多 空白\n圧縮  " }, "x"), "多 空白 圧縮");
  const long = "あ".repeat(80);
  assert.ok(resolveTitle({ title: null, lastPrompt: long }, "x").endsWith("…"));
  assert.equal(resolveTitle({ title: null, lastPrompt: null }, "abcdef123456"), "abcdef12");
});

test("一覧は cli のみ・mtime 降順", () => {
  const entries = [
    { sessionId: "a", projectSlug: "p", mtimeMs: 100, meta: { entrypoint: "cli", title: "A", lastPrompt: null, turns: 1, cwd: "/x" } },
    { sessionId: "b", projectSlug: "p", mtimeMs: 300, meta: { entrypoint: "sdk-cli", title: "B", lastPrompt: null, turns: 9, cwd: "/x" } },
    { sessionId: "c", projectSlug: "q", mtimeMs: 200, meta: { entrypoint: "cli", title: "C", lastPrompt: null, turns: 2, cwd: "/y" } },
  ];
  const list = buildListing(entries);
  assert.deepEqual(list.map((e) => e.id), ["c", "a"]); // sdk-cli の b は落ちる
});

test("履歴: user/assistant のテキスト + tool_use は要約1行、tail から limit 件", () => {
  const lines = [];
  lines.push(L({ type: "user", message: { content: "質問1" } }));
  lines.push(L({
    type: "assistant",
    message: { content: [{ type: "text", text: "回答1" }, { type: "tool_use", name: "Bash", input: {} }] },
  }));
  lines.push(L({ type: "user", message: { content: [{ type: "text", text: "質問2" }] } }));
  const h = extractHistory(lines.join("\n"), 10);
  assert.deepEqual(h, [
    { role: "user", text: "質問1" },
    { role: "assistant", text: "回答1" },
    { role: "tool", text: "⚙ Bash" },
    { role: "user", text: "質問2" },
  ]);
  assert.equal(extractHistory(lines.join("\n"), 2).length, 2);
  assert.equal(extractHistory(lines.join("\n"), 2)[1].text, "質問2"); // tail 側
});
