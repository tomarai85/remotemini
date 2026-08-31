import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { searchHistoryFromPath } from "../src/sessions.mjs";

/**
 * 転写の中を探す。
 *
 * ★測る中心は「見つかるか」ではなく **「見つからないを正直に言えるか」**。
 *   走査は有界(`maxBytes` / 見つけた件数)なので、0 件には 2 つの意味が在る:
 *     (a) 走査した範囲に無かった
 *     (b) 会話の最初まで見て無かった
 *   之を混ぜると、言い切れない物を言い切る事になる。
 */

function fixture(lines) {
  const dir = mkdtempSync(join(tmpdir(), "rc-search-"));
  const p = join(dir, "t.jsonl");
  writeFileSync(p, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  return p;
}

const user = (t) => ({ type: "user", message: { role: "user", content: t } });
const asst = (t) => ({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: t }] } });

test("一致した項目だけを返す", () => {
  const p = fixture([user("hello world"), asst("nothing here"), user("world again")]);
  const r = searchHistoryFromPath(p, "world", 50);
  assert.equal(r.matched, 2);
  assert.ok(r.history.every((e) => e.text.toLowerCase().includes("world")));
});

test("大小を区別しない（電話で打つ側は shift を押さない）", () => {
  const p = fixture([user("Deploy FAILED on friday")]);
  assert.equal(searchHistoryFromPath(p, "failed", 50).matched, 1);
  assert.equal(searchHistoryFromPath(p, "DEPLOY", 50).matched, 1);
});

test("★空の問いは全件一致にしない", () => {
  // 空欄のまま送られた時に会話全部が返ると、利用者は「検索したのに何も絞れない」を見る。
  const p = fixture([user("a"), asst("b"), user("c")]);
  const r = searchHistoryFromPath(p, "", 50);
  assert.equal(r.matched, 0);
  assert.equal(r.history.length, 0);
});

test("★最初まで見たかどうかを名乗る（0 件の 2 つの意味を分ける）", () => {
  const p = fixture([user("alpha"), asst("beta")]);
  const whole = searchHistoryFromPath(p, "zzz", 50);
  assert.equal(whole.matched, 0);
  assert.equal(whole.reachedStart, true, "小さい file は最初まで読める = 「本当に無い」と言える");

  // 走査を絞ると、同じ 0 件でも「最初までは見ていない」になる筈。
  // ★`maxBytes` だけでは絞れない —— 最初のチャンクは `min(chunk, file 全体)` なので、
  //   小さい file は 1 回で読み切って `pos === 0` に達し `reachedStart = true` になる
  //   (2026-08-31、此の検査が最初 赤くなった。実装ではなく**検査の側**の誤り)。
  //   両方 渡して初めて「途中で止まった」を作れる。
  const bounded = searchHistoryFromPath(p, "zzz", 50, { chunk: 8, maxBytes: 8 });
  assert.equal(bounded.matched, 0);
  assert.equal(bounded.reachedStart, false, "★有界の 0 件を「本当に無い」と言ってはいけない");
});

test("★一致が疎でも取りこぼさない（項目数ではなく一致数で止める）", () => {
  // 一致 1 件 + 無関係 30 件。項目数で打ち切る実装だと、古い側の一致を落とす。
  const lines = [user("needle")];
  for (let i = 0; i < 30; i++) lines.push(asst(`filler ${i}`));
  const r = searchHistoryFromPath(fixture(lines), "needle", 5);
  assert.equal(r.matched, 1, "一致が疎な会話でも走査が早く止まらない");
});

test("上限を超える一致は新しい側を返す", () => {
  const lines = [];
  for (let i = 0; i < 10; i++) lines.push(user(`hit ${i}`));
  const r = searchHistoryFromPath(fixture(lines), "hit", 3);
  assert.equal(r.history.length, 3);
  assert.ok(r.history.at(-1).text.includes("hit 9"), "一番新しい一致が末尾に来る");
});
