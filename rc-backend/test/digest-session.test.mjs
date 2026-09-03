// 要約(digest)が「会話が今 何で走っているか」を転写から正しく拾うか。
//
// ── 何を守るか(2026-09-02)────────────────────────────────────────────────
// 公式 Remote Control は接続端末に現用モデルを出す(対照表 #14-16)。電話には今まで
// 何も出ていなかった。転写の各レコードは `message.model` / `gitBranch` / `version` を
// 持つ(friday の実転写で確認: `claude-sonnet-4-6` / `main` / `2.1.128`)。
//
// ★守る 3 点:
//   1. **最新のレコードの値**を採る。途中で `/model` を切り替えた会話では古い行が
//      別のモデルを名乗るので、頭の値を採ると嘘になる。
//   2. **後ろから前へ**見て、初めて値を持つレコードの物を採る。最後の 1 件が
//      メタ行(要約・分岐の印)で持たない事は実転写で普通に在る。
//   3. **無い物は null**。0 件の窓や古い版の転写には項目自体が無い。
//      `undefined` や空文字に丸めると、電話側の「無ければ出さない」判定が壊れる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { digestOf } from "../src/digest.mjs";

const NOW = Date.parse("2026-09-02T10:00:00.000Z");
const at = (m) => new Date(NOW - m * 60_000).toISOString();

function rec(minAgo, extra = {}) {
  return {
    type: "assistant",
    timestamp: at(minAgo),
    message: { role: "assistant", content: [{ type: "text", text: "x" }], ...(extra.message ?? {}) },
    ...(extra.top ?? {}),
  };
}

test("★最新のレコードの model / gitBranch / version を採る(頭の値ではない)", () => {
  const list = [
    rec(50, { message: { model: "claude-sonnet-4-6" }, top: { gitBranch: "main", version: "2.1.128" } }),
    rec(10, { message: { model: "claude-opus-5" }, top: { gitBranch: "feature/x", version: "2.1.240" } }),
  ];
  const d = digestOf(list, { nowMs: NOW, sinceMs: NOW - 60 * 60_000 });
  assert.deepEqual(d.session, { model: "claude-opus-5", gitBranch: "feature/x", version: "2.1.240", contextTokens: null });
  // ★錨は派生の出力に直に当てる(vacuous-gate の指摘 2026-09-02)。「頭の値を採る」実装へ
  //   変異させると此処が赤くなる。上の deepEqual だけでも赤くなるが、**何を守っているか**を
  //   名指しする —— 頭(50 分前)と尾(10 分前)で model が違う検体で、尾が勝つ事。
  assert.equal(list.length, 2, "検体は頭と尾の 2 件(之が 1 件なら「最新」に意味が無い)");
  assert.notEqual(d.session.model, "claude-sonnet-4-6", "頭の model を採っている = 古い値で嘘をつく");
});

test("★後ろから前へ: 最後がメタ行で持たなくても、その前の値を拾う", () => {
  const list = [
    rec(30, { message: { model: "claude-opus-5" }, top: { gitBranch: "main", version: "2.1.240" } }),
    // 最後の行 = 値を 1 つも持たない(要約・印の類)
    { type: "summary", timestamp: at(1), summary: "…" },
  ];
  const d = digestOf(list, { nowMs: NOW, sinceMs: NOW - 60 * 60_000 });
  assert.equal(d.session.model, "claude-opus-5");
  assert.equal(d.session.gitBranch, "main");
});

test("★項目が無ければ null(undefined でも空文字でもない)", () => {
  const list = [rec(5), rec(3)];
  const d = digestOf(list, { nowMs: NOW, sinceMs: NOW - 60 * 60_000 });
  assert.deepEqual(d.session, { model: null, gitBranch: null, version: null, contextTokens: null });
});

test("項目ごとに独立に拾う(model だけ持つ行と branch だけ持つ行が別でも合成する)", () => {
  const list = [
    rec(20, { top: { gitBranch: "main" } }),
    rec(10, { message: { model: "claude-opus-5" } }),
  ];
  const d = digestOf(list, { nowMs: NOW, sinceMs: NOW - 60 * 60_000 });
  assert.equal(d.session.model, "claude-opus-5");
  assert.equal(d.session.gitBranch, "main");
  assert.equal(d.session.version, null);
});

// ── contextTokens(2026-09-03、対照表 #14-16 の残り「使用量」)────────────────
// 直近の応答の `message.usage` から、入力 3 種(input / cache_creation / cache_read)の和 =
// 其の応答が抱えていた文脈の大きさ。friday の実転写の形:
//   "usage":{"input_tokens":2,"cache_creation_input_tokens":27124,"cache_read_input_tokens":11591,"output_tokens":2624,...}
const usage = (i, cc, cr, out = 100) => ({
  input_tokens: i, cache_creation_input_tokens: cc, cache_read_input_tokens: cr, output_tokens: out,
});

test("★contextTokens = 直近の usage の入力 3 種の和(output は足さない)", () => {
  const list = [
    rec(30, { message: { usage: usage(1, 50_000, 0, 999) } }),
    rec(10, { message: { usage: usage(2, 27_124, 11_591, 2_624) } }),
  ];
  const d = digestOf(list, { nowMs: NOW, sinceMs: NOW - 60 * 60_000 });
  assert.equal(d.session.contextTokens, 2 + 27_124 + 11_591);
  // ★錨: 出力を足す実装・累計する実装・頭を採る実装を名指しで落とす
  assert.notEqual(d.session.contextTokens, 2 + 27_124 + 11_591 + 2_624, "output_tokens を足している");
  assert.notEqual(d.session.contextTokens, 50_001 + 38_717, "累計している(compact で減った事が出なくなる)");
  assert.notEqual(d.session.contextTokens, 50_001, "頭の値を採っている");
});

test("★usage の無い最後の行を跨いで、その前の usage を拾う(model と同じ後方走査)", () => {
  const list = [
    rec(30, { message: { usage: usage(3, 100, 200) } }),
    { type: "summary", timestamp: at(1), summary: "…" },
  ];
  const d = digestOf(list, { nowMs: NOW, sinceMs: NOW - 60 * 60_000 });
  assert.equal(d.session.contextTokens, 303);
});

test("★usage が無ければ null / cache の欄が無いのは 0 扱い / 在るのに不正なら其の usage ごと null(部分和を出さない)", () => {
  const W = { nowMs: NOW, sinceMs: NOW - 60 * 60_000 };
  assert.equal(digestOf([rec(5), rec(3)], W).session.contextTokens, null);
  const partial = [rec(3, { message: { usage: { input_tokens: 7, cache_read_input_tokens: 5 } } })];
  assert.equal(digestOf(partial, W).session.contextTokens, 12, "cache_creation が無い古い版の usage");
  // ★Codex #3 の 3: `{input_tokens:-1, cache_read:100}` を 100 と出していた(負を捨てて残りを足す)
  const negative = [rec(3, { message: { usage: { input_tokens: -1, cache_read_input_tokens: 100, cache_creation_input_tokens: 0 } } })];
  assert.equal(digestOf(negative, W).session.contextTokens, null, "負の欄を捨てて部分和を出している");
  // ★cache 側が負の時も同じ(input_tokens の門だけで守ったつもりになる実装を落とす。変異 M5 が
  //   之の無い版をすり抜けた、2026-09-03)
  const cacheNegative = [rec(3, { message: { usage: { input_tokens: 5, cache_read_input_tokens: -1, cache_creation_input_tokens: 10 } } })];
  assert.equal(digestOf(cacheNegative, W).session.contextTokens, null, "cache の負の欄を捨てて 15 を出している");
  const junk = [rec(3, { message: { usage: { input_tokens: "7", cache_read_input_tokens: 1 } } })];
  assert.equal(digestOf(junk, W).session.contextTokens, null, "input_tokens が文字列");
  const noInput = [rec(3, { message: { usage: { cache_read_input_tokens: 100 } } })];
  assert.equal(digestOf(noInput, W).session.contextTokens, null, "input_tokens の欄が無い物は usage ではない");
  const huge = [rec(3, { message: { usage: { input_tokens: 1e308, cache_read_input_tokens: 1 } } })];
  assert.equal(digestOf(huge, W).session.contextTokens, null, "1e308 が通ると Infinity になる");
  const unsafe = [rec(3, { message: { usage: { input_tokens: Number.MAX_SAFE_INTEGER, cache_read_input_tokens: 1 } } })];
  assert.equal(digestOf(unsafe, W).session.contextTokens, null, "safe integer の外");
});

test("★全ゼロの usage は無効 = 走査を止めず、其の前の正しい値を採る(実転写に全ゼロ行と重複行が在る)", () => {
  const W = { nowMs: NOW, sinceMs: NOW - 60 * 60_000 };
  const list = [
    rec(30, { message: { usage: usage(2, 27_124, 11_591) } }),
    rec(10, { message: { usage: usage(0, 0, 0, 0) } }),
  ];
  assert.equal(digestOf(list, W).session.contextTokens, 38_717);
  // 錨: 全ゼロしか無ければ null(0 を「軽い」と描かない)
  assert.equal(digestOf([rec(10, { message: { usage: usage(0, 0, 0, 0) } })], W).session.contextTokens, null);
});

test("★assistant 以外の行の usage は読まない(後発の任意レコードに勝たせない)", () => {
  const W = { nowMs: NOW, sinceMs: NOW - 60 * 60_000 };
  const list = [
    rec(30, { message: { usage: usage(2, 27_124, 11_591) } }),
    { type: "user", timestamp: at(10), message: { role: "user", content: "q", usage: usage(9, 9, 9) } },
    { type: "queue-operation", timestamp: at(5), message: { usage: usage(1, 1, 1) } },
  ];
  assert.equal(digestOf(list, W).session.contextTokens, 38_717);
});

test("★★compaction の境界(`compact_boundary` の postTokens)が最新なら其れを採る(pre-compact の巨大値を名乗り続けない)", () => {
  const W = { nowMs: NOW, sinceMs: NOW - 60 * 60_000 };
  // 実転写の形: {"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":1000296,"postTokens":29023,...}}
  const boundary = (minAgo, post) => ({
    type: "system", subtype: "compact_boundary", timestamp: at(minAgo), content: "Conversation compacted", level: "info",
    compactMetadata: { trigger: "auto", preTokens: 1_000_296, postTokens: post, cumulativeDroppedTokens: 971_273 },
  });
  const list = [
    rec(30, { message: { usage: usage(296, 900_000, 100_000) } }), // compact 前の巨大な要求
    boundary(10, 29_023),
  ];
  assert.equal(digestOf(list, W).session.contextTokens, 29_023);
  // 境界の後に新しい応答が来れば、其の usage が勝つ(境界は「其の時点」の値)
  const after = [...list, rec(5, { message: { usage: usage(3, 20_000, 12_000) } })];
  assert.equal(digestOf(after, W).session.contextTokens, 32_003);
  // 境界の postTokens が壊れていれば(0 / 負 / 文字列)、境界は跨いで前の値を採る
  for (const bad of [0, -1, "29023"]) {
    assert.equal(digestOf([rec(30, { message: { usage: usage(1, 1, 1) } }), boundary(10, bad)], W).session.contextTokens, 3, `postTokens=${bad}`);
  }
});

test("★不完全な digest(scan-budget / too-many-records)でも session facts は出て、`contextTokens` の鍵が在る(Codex #3 の 2)", () => {
  const W = { nowMs: NOW, sinceMs: NOW - 60 * 60_000 };
  const list = [rec(10, { message: { model: "claude-opus-5", usage: usage(2, 27_124, 11_591) }, top: { gitBranch: "main" } })];
  const budget = digestOf(list, { ...W, reachedStart: false });
  assert.equal(budget.complete, false);
  assert.equal(budget.incompleteReason, "scan-budget");
  assert.equal(budget.session.model, "claude-opus-5");
  assert.equal(budget.session.gitBranch, "main");
  assert.equal(budget.session.contextTokens, 38_717, "★末尾は読めているのに facts を捨てている");
  // 鍵の形は完全な時と同じ(電話の Decodable と `wire-key-agreement` が同じ鍵を見る)
  const complete = digestOf(list, W);
  assert.deepEqual(Object.keys(budget.session).sort(), Object.keys(complete.session).sort());
  assert.ok("contextTokens" in digestOf([], { ...W, reachedStart: false }).session, "既定の session に鍵が無い");
  assert.ok("contextTokens" in digestOf([], { nowMs: NaN, sinceMs: NaN }).session, "bad-window の既定にも鍵");
});
