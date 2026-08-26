import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadRules, checkDeny, denyMessage, rulesSummary } from "../src/deny.mjs";

// ★この検査が守る一線は3つ。どれも「静かに効かなくなる」形を潰す為に在る。
//   1. 規則を書いていない機体で**挙動が1ミリも変わらない**(入れた人が最初に消したくならない)
//   2. 半分だけ読んだ事を黙らない(「書いたのに効かない」が一番怖い)
//   3. 合致しなかった事を「安全」と呼ばない

let D;
const write = (obj) => {
  D = D ?? mkdtempSync(join(tmpdir(), "deny-test-"));
  const p = join(D, "deny.json");
  writeFileSync(p, typeof obj === "string" ? obj : JSON.stringify(obj));
  return p;
};
test.after(() => { if (D) rmSync(D, { recursive: true, force: true }); });

const RULE = { id: "no-force-push", pattern: "git push .*--force", why: "他人の履歴を壊す" };

// ---- 既定は空 -----------------------------------------------------------------

test("★file が無い機体では規則ゼロ、error も無い(未設定は異常ではない)", () => {
  const r = loadRules("/nonexistent/deny.json");
  assert.deepEqual(r.rules, []);
  assert.equal(r.error, null);
});

test("★規則ゼロなら何も止めない(入れた瞬間に何かが止まる設計にしない)", () => {
  const hit = checkDeny("rm -rf / ; git push --force", []);
  assert.equal(hit.denied, false);
});

// ---- 止める -------------------------------------------------------------------

test("合致したら止め、どの規則かと理由を返す", () => {
  const { rules } = loadRules(write([RULE]));
  const hit = checkDeny("please run git push origin main --force now", rules);
  assert.equal(hit.denied, true);
  assert.equal(hit.id, "no-force-push");
  assert.equal(hit.why, "他人の履歴を壊す");
});

test("★断りの文は規則の why をそのまま使う(机で作文しない)", () => {
  const { rules } = loadRules(write([RULE]));
  const hit = checkDeny("git push --force", rules);
  const msg = denyMessage(hit);
  assert.ok(msg.includes("他人の履歴を壊す"), msg);
  assert.ok(msg.includes("no-force-push"), "どの規則か判らない断りは、ただの壁");
});

test("大文字小文字は問わない(打つ人は綴りを揃えない)", () => {
  const { rules } = loadRules(write([RULE]));
  assert.equal(checkDeny("GIT PUSH origin --FORCE", rules).denied, true);
});

test("★合致しない物は通す。そして『安全』とは名乗らない", () => {
  const { rules } = loadRules(write([RULE]));
  const hit = checkDeny("git push origin main", rules);
  assert.equal(hit.denied, false);
  assert.equal(hit.why, null, "通した時に理由を持たせると『安全の証明』に読まれる");
});

// ---- 壊れた設定 ---------------------------------------------------------------

test("★壊れた JSON では止めない(fail-open)。ただし黙らない", () => {
  const r = loadRules(write("{ oops not json"));
  assert.deepEqual(r.rules, []);
  assert.equal(r.error, "bad-json");
  // ここを fail-closed にすると、file が1文字壊れただけで電話から一言も打てなくなる。
  // 防いでいる害より大きいので、開ける代わりに error を必ず返す。
});

test("配列でない物も同じ扱い", () => {
  const r = loadRules(write({ id: "x" }));
  assert.deepEqual(r.rules, []);
  assert.equal(r.error, "not-an-array");
});

test("★形の欠けた規則は読み込まず、捨てた数を返す(半分効く状態を黙らない)", () => {
  const r = loadRules(write([
    RULE,
    { id: "no-why", pattern: "rm -rf" },                    // why が無い
    { id: "BAD ID", pattern: "x", why: "理由あり" },         // id の形が違う
    { id: "bad-regex", pattern: "([", why: "理由あり" },     // regex が壊れている
    { id: "no-pattern", why: "理由あり" },                   // pattern が無い
    { id: "short-why", pattern: "x", why: "a" },             // 理由が短すぎる
  ]));
  assert.equal(r.rules.length, 1, "壊れた規則を読み込んだ");
  assert.equal(r.skipped, 5);
  assert.equal(r.error, "skipped-5", "捨てた事を黙った = 『書いたのに効かない』が静かに起きる");
});

test("★理由の書けない規則は入れない(後で誰かが『何だったか分からない』で消す)", () => {
  const r = loadRules(write([{ id: "x", pattern: "y", why: "" }]));
  assert.equal(r.rules.length, 0);
});

test("要約は数と問題だけを出し、規則の中身は出さない", () => {
  const loaded = loadRules(write([RULE, { id: "broken" }]));
  const s = rulesSummary(loaded);
  assert.equal(s.count, 1);
  assert.equal(s.problem, "skipped-1");
  assert.equal(JSON.stringify(s).includes("git push"), false, "規則の中身が漏れた");
});

// ---- 素朴さを保つ --------------------------------------------------------------

test("★意図を推し量らない。素朴な一致だけ", () => {
  const { rules } = loadRules(write([RULE]));
  // 「--force と書いていないが実質同じ」を止めようとしない。
  // 推し量りが外れた時、外れた事に誰も気付けないので、そもそも推し量らない。
  assert.equal(checkDeny("git push -f origin main", rules).denied, false,
    "書いていない綴りまで止めた = 規則の効き方が読めなくなる");
});

test("空の本文は止めようがない", () => {
  const { rules } = loadRules(write([RULE]));
  assert.equal(checkDeny("", rules).denied, false);
  assert.equal(checkDeny(null, rules).denied, false);
});

test("★先に書いた規則が勝つ(どれが効いたか一意に決まる)", () => {
  const { rules } = loadRules(write([
    { id: "first", pattern: "danger", why: "先の理由" },
    { id: "second", pattern: "danger", why: "後の理由" },
  ]));
  assert.equal(checkDeny("this is danger", rules).id, "first");
});
