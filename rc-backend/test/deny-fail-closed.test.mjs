// deny-fail-closed.test.mjs — 打鍵の拒否規則が**読めない時は送らせない**(2026-09-08、机の掃引の所見 #3)。
//
// 何が問題だったか: `deny.mjs` は「電話が何を送っても効く唯一の層」と自分の頭で名乗るのに、`server.mjs` は
// `loadRules()` の戻りから `rules` だけを読み、`error`(読めない / 壊れた JSON / 配列でない)と `skipped`(形の
// 壊れた規則を落とした数)を**捨てていた**。壊れた `deny.json` は規則 0 本として通り、守りが黙って外れる。
// 誰にも見えない = 次に気づくのは、止めるべき打鍵が机に届いた時。
//
// 此処で守る物は 2 つ:
//   1. 判定の材料が揃わない時、`loadRules` は其れを**言う**(純関数の側)。
//   2. server は其の材料を**読み、送らない**(配線の側)。文は直す場所(Mac の deny.json)を名指す。
// ★「規則が無い」(ENOENT)は正常 —— 読めない事と、設定していない事は別。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { loadRules, checkDeny } from "../src/deny.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const file = (contents) => {
  const p = join(mkdtempSync(join(tmpdir(), "deny-")), "deny.json");
  writeFileSync(p, contents);
  return p;
};
const GOOD = JSON.stringify([{ id: "rm-rf", pattern: "rm -rf", why: "recursive delete" }]);

test("未設定(file が無い)は正常 —— error は null、規則 0 本", () => {
  const r = loadRules(join(tmpdir(), "deny-does-not-exist-", String(Date.now()), "deny.json"));
  assert.equal(r.error, null);
  assert.deepEqual(r.rules, []);
  assert.equal(r.skipped, 0);
});

test("読める規則は載り、判定に効く", () => {
  const r = loadRules(file(GOOD));
  assert.equal(r.error, null);
  assert.equal(r.skipped, 0);
  assert.equal(checkDeny("rm -rf /tmp/x", r.rules).denied, true);
});

test("★壊れた JSON / 配列でない / 形の壊れた規則は、規則 0 本のまま**理由を言う**", () => {
  const bad = loadRules(file("{ not json"));
  assert.equal(bad.error, "bad-json");
  assert.deepEqual(bad.rules, []);

  const notArray = loadRules(file('{"id":"x"}'));
  assert.equal(notArray.error, "not-an-array");

  // 1 本は正しく、1 本は `why` が短すぎる → 落とした事を **error にも** 数にも書く
  // (掃引の時に「skipped は error と別枝」と読んだが、実物は `skipped-N` を error に入れていた。
  //  server の条件 `error || skipped > 0` は其の儘で正しく、片方だけを見る実装への保険として両方見る)
  const partial = loadRules(file(JSON.stringify([
    { id: "rm-rf", pattern: "rm -rf", why: "recursive delete" },
    { id: "broken", pattern: "x", why: "no" },
  ])));
  assert.equal(partial.error, "skipped-1");
  assert.equal(partial.skipped, 1);
  assert.equal(partial.rules.length, 1, "★落とした規則が在っても、通った規則は載る —— 之を「0 本」と読むと守りが消える");
});

test("★配線(server.mjs): error か skipped が在れば 409 で送らせ、直す場所を名指す", () => {
  const src = readFileSync(join(HERE, "..", "src", "server.mjs"), "utf8");
  assert.ok(src.includes("if (loaded.error || loaded.skipped > 0) {"), "材料が揃わない時に分岐していない");
  assert.ok(src.includes('reason: "deny-rules-unusable"'), "閉じた語で断っていない");
  assert.ok(src.includes("Fix deny.json on the Mac."), "直す場所を名指していない");
  // ★否定対照: `rules` だけを読む形(旧の姿)に戻ったら此処が赤になる
  const i = src.indexOf("const loaded = loadRules(DENY_FILE);");
  const j = src.indexOf("const hit = checkDeny(text, loaded.rules);", i);
  assert.ok(i >= 0 && j > i, "読み込みと判定の順が変わった");
  assert.ok(src.slice(i, j).includes("loaded.error"), "読み込みと判定の間で error を見ていない");
});

test("★配線(server.mjs): 本文が大きすぎる時、title / archive も他の口と同じ 413 の道へ", () => {
  const src = readFileSync(join(HERE, "..", "src", "server.mjs"), "utf8");
  // 9 口すべてが `BodyTooLarge` を `tooLarge` へ渡す(400 に潰さない)
  const branches = src.split("if (e instanceof BodyTooLarge) return tooLarge(req, res, e);").length - 1;
  assert.ok(branches >= 9, `本文を読む口のうち ${branches} 口しか 413 の道を持っていない`);
  for (const action of ["title", "archive"]) {
    const at = src.indexOf(`if (action === "${action}" && req.method === "POST") {`);
    assert.ok(at > 0, `${action} の口が無い`);
    const window = src.slice(at, at + 900);
    assert.ok(window.includes("if (e instanceof BodyTooLarge) return tooLarge(req, res, e);"), `${action} が 413 の道を持たない`);
  }
});
