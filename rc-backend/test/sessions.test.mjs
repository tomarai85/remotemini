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

test("タイトル解決順: 明示名 → ai-title → last-prompt(60字丸め)→ id 短縮", () => {
  // ★明示名が全段に勝つ(2026-08-16、spec-audit A1。本家の優先順の1段目)
  assert.equal(resolveTitle({ title: "T", lastPrompt: "L" }, "abcdef123456", "手で付けた名"), "手で付けた名");
  assert.equal(resolveTitle({ title: "T", lastPrompt: "L" }, "abcdef123456"), "T");
  assert.equal(resolveTitle({ title: null, lastPrompt: "  多 空白\n圧縮  " }, "x"), "多 空白 圧縮");
  const long = "あ".repeat(80);
  assert.ok(resolveTitle({ title: null, lastPrompt: long }, "x").endsWith("…"));
  assert.equal(resolveTitle({ title: null, lastPrompt: null }, "abcdef123456"), "abcdef12");
  // ★空文字の明示名は「無い」と同じ(titles.mjs が保存を拒む値だが、防御は両側で)
  assert.equal(resolveTitle({ title: "T", lastPrompt: null }, "x", ""), "T");
});

test("buildListing: titles 台帳の明示名が行の title に乗る", () => {
  const entries = [
    { sessionId: "a", projectSlug: "p", mtimeMs: 100, meta: { entrypoint: "cli", title: "AI題", lastPrompt: null, turns: 1, cwd: "/x" } },
  ];
  assert.equal(buildListing(entries, { a: "俺の名前" })[0].title, "俺の名前");
  assert.equal(buildListing(entries)[0].title, "AI題"); // 台帳なしは従来どおり
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

test("C2: Task(subagent)は description を添えて名乗る。他の tool は名前だけ", () => {
  const mk = (blocks) => L({ type: "assistant", message: { content: blocks } });
  const h1 = extractHistory(mk([{ type: "tool_use", name: "Task", input: { description: "リークの犯人探し" } }]), 10);
  assert.match(h1[0].text, /⚙ Task: リークの犯人探し/);
  const h2 = extractHistory(mk([{ type: "tool_use", name: "Task", input: { prompt: "秘密の長文" } }]), 10);
  assert.equal(/秘密の長文/.test(h2[0].text), false, "★prompt 本文は線に出さない");
  assert.equal(h2[0].text, "⚙ Task");
  const h3 = extractHistory(mk([{ type: "tool_use", name: "Bash", input: { description: "無関係" } }]), 10);
  assert.equal(h3[0].text, "⚙ Bash", "Task 以外は今まで通り名前だけ");
  const long = "あ".repeat(60);
  const h4 = extractHistory(mk([{ type: "tool_use", name: "Task", input: { description: long } }]), 10);
  assert.match(h4[0].text, /…$/, "40字で丸める");
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
