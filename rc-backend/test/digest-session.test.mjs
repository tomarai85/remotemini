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

test("★usage が無ければ null / 欄が一部欠けても在る物だけ足す / 数でない物は無視", () => {
  assert.equal(digestOf([rec(5), rec(3)], { nowMs: NOW, sinceMs: NOW - 60 * 60_000 }).session.contextTokens, null);
  const partial = [rec(3, { message: { usage: { input_tokens: 7, cache_read_input_tokens: 5 } } })];
  assert.equal(digestOf(partial, { nowMs: NOW, sinceMs: NOW - 60 * 60_000 }).session.contextTokens, 12);
  const junk = [rec(3, { message: { usage: { input_tokens: "7", cache_read_input_tokens: -1, cache_creation_input_tokens: NaN } } })];
  assert.equal(digestOf(junk, { nowMs: NOW, sinceMs: NOW - 60 * 60_000 }).session.contextTokens, null);
});
