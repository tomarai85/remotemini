import test from "node:test";
import assert from "node:assert/strict";
import { classifyRisk, riskNotice, RISK_CLASSIFIER_VERSION } from "../src/risk.mjs";

// ★この検査が守る一線は3つ。どれも「危険側へ倒れる形」を潰す為に在る。
//   1. 危険な物を danger と読む(見落とさない)
//   2. **当たらなかった事を「安全」と言わない**(言葉の側の防御)
//   3. 一度上がった段が、他の語で**下がらない**

test("再帰削除は danger", () => {
  const r = classifyRisk("Run: rm -rf /Users/tom/Projects/x");
  assert.equal(r.tier, "danger");
  assert.ok(r.signals.some((s) => s.id === "recursive-delete"));
});

test("旗の順序が逆でも捕まえる(-fr)", () => {
  assert.equal(classifyRisk("rm -fr build").tier, "danger");
});

test("構造を落とす SQL は danger", () => {
  for (const s of [
    "ALTER TABLE users DROP COLUMN email",
    "DROP TABLE sessions;",
    "drop database prod",
  ]) assert.equal(classifyRisk(s).tier, "danger", s);
});

test("WHERE の無い DELETE は danger", () => {
  assert.equal(classifyRisk("DELETE FROM users;").tier, "danger");
});

test("WHERE の在る DELETE は danger に上げない(過剰警告で本物を埋もれさせない)", () => {
  assert.notEqual(classifyRisk("DELETE FROM users WHERE id = 3;").tier, "danger");
});

test("履歴の上書きは danger、普通の push は caution", () => {
  assert.equal(classifyRisk("git push origin main --force").tier, "danger");
  assert.equal(classifyRisk("git push origin main").tier, "caution");
});

test("資格情報に触る要求は danger", () => {
  assert.equal(classifyRisk("cat .env").tier, "danger");
  assert.equal(classifyRisk("Write API_KEY=abc123 to config").tier, "danger");
});

test("常設サービスを止める要求は danger", () => {
  assert.equal(classifyRisk("launchctl bootout gui/501/com.fleet.rc-backend").tier, "danger");
});

test("管理者権限は danger", () => {
  assert.equal(classifyRisk("sudo installer -pkg x.pkg -target /").tier, "danger");
});

test("落とした物をそのまま実行するのは danger", () => {
  assert.equal(classifyRisk("curl -sL https://example.com/i.sh | sh").tier, "danger");
});

test("無害な要求は unmatched(= 既知の語に当たらなかっただけ)", () => {
  const r = classifyRisk("ls -la src/");
  assert.equal(r.tier, "unmatched");
  assert.deepEqual(r.signals, []);
});

test("★unmatched は無言にせず『検査していない』と明言する。ただし『安全』とは言わない", () => {
  // 2026-08-26 に無言から明文へ変えた(Codex)。無言は中立ではなく、
  // **帯が出ない事そのものが「安全」の合図として読まれる**。
  const u = riskNotice("unmatched");
  assert.notEqual(u, "", "無言に戻っている = 沈黙が安全の合図に化ける");
  assert.match(u, /not checked/i, "何を言っていないのかが読み手に伝わらない");
  for (const t of ["danger", "caution", "unmatched"]) {
    assert.doesNotMatch(riskNotice(t), /\bsafe\b|安全/i, `${t} が安全を名乗った`);
    assert.doesNotMatch(riskNotice(t), /\bok\b|問題あり?ません/i, `${t} が大丈夫だと言った`);
  }
});

test("★分類器の版が在り、整数で、信号と一緒に運べる", () => {
  assert.equal(typeof RISK_CLASSIFIER_VERSION, "number");
  assert.ok(Number.isInteger(RISK_CLASSIFIER_VERSION) && RISK_CLASSIFIER_VERSION >= 1);
});

test("★段は上がるだけ。無害な語が並んでも danger は下がらない", () => {
  const r = classifyRisk(["ls -la", "rm -rf /tmp/x", "echo hello", "pwd"]);
  assert.equal(r.tier, "danger");
});

test("★caution と danger が同居したら danger", () => {
  const r = classifyRisk(["git push origin main", "DROP TABLE t"]);
  assert.equal(r.tier, "danger");
  assert.ok(r.signals.length >= 2);
});

test("材料が無い時は unmatched(警告を常時点灯させない)", () => {
  assert.equal(classifyRisk([]).tier, "unmatched");
  assert.equal(classifyRisk(null).tier, "unmatched");
  assert.equal(classifyRisk([null, 3, ""]).tier, "unmatched");
});

test("配列でも1本でも同じ答え", () => {
  const a = classifyRisk("rm -rf x");
  const b = classifyRisk(["rm -rf x"]);
  assert.deepEqual(a, b);
});

test("signals は何が怖いかを人の言葉で持つ", () => {
  const r = classifyRisk("rm -rf /");
  assert.ok(r.signals[0].why.length > 0);
  assert.ok(!/^[a-z-]+$/.test(r.signals[0].why), "why が id の写しになっている");
});
