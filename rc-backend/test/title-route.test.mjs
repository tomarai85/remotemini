// 明示名(rename)の道の**構造**を src/server.mjs の本文で押さえる(spec-audit A1)。
//
// ★静的検査の理由は account-routes.test.mjs と同じ: server.mjs は import した瞬間に
//   listen するので単体から呼べない。純関数(normalizeTitle / setTitle / loadTitles)は
//   test/titles.test.mjs が実行して測っている。此処に残す仕事は grep でしか見えない物:
//     - 道が存在し、SESSION_ROUTE_RE の中(= 404 と存在検査の後ろ)に居る
//     - 検証(normalizeTitle)が保存(setTitle)より**前**に居る
//     - null で外す道が在る
//     - 一覧側は合流後の一括 override(生産者3人に個別配布しない)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.mjs");
const real = readFileSync(SRC, "utf8");

// ★字面ではなく**実行**で到達性を測る(2026-08-16、Codex #8)。handler が在っても
// SESSION_ROUTE_RE の白名簿に action が無ければ 404 で、字面の検査は全部素通りする —
// 現にその状態で3本を出荷しかけた。
import { SESSION_ROUTE_RE } from "../src/reqlog.mjs";

test("★到達できる: title / archive / return-request が route の白名簿に居る", () => {
  for (const action of ["title", "archive", "return-request"]) {
    const m = SESSION_ROUTE_RE.exec(`/api/sessions/abc-123/${action}`);
    assert.ok(m, `${action} が SESSION_ROUTE_RE に当たらない = handler が在っても永久に 404`);
    assert.equal(m[2], action);
  }
  // 錨: 出鱈目な action は今も当たらない(白名簿が全通しに緩んでいない)
  assert.equal(SESSION_ROUTE_RE.exec("/api/sessions/abc-123/nonsense"), null);
});

const MARKER = 'if (action === "title" && req.method === "POST")';

test("道が在り、セッション存在検査(SESSION_ROUTE_RE)より後ろに居る", () => {
  const route = real.indexOf(MARKER);
  const guard = real.indexOf("SESSION_ROUTE_RE.exec(path)");
  assert.ok(route !== -1, "title の道が server.mjs に無い");
  assert.ok(guard !== -1 && guard < route,
    "★存在しない session id に名前を書ける実装を落とす(存在検査の前に道が居る)");
});

test("検証が保存より前(拒否してから setTitle には到達しない順)", () => {
  const i = real.indexOf(MARKER);
  const body = real.slice(i, i + 1600);
  const v = body.indexOf("normalizeTitle(");
  const s = body.lastIndexOf("setTitle(");
  const r = body.lastIndexOf('"title required"'); // 検証失敗の側(catch 節にも同語が居るので最後の物)
  assert.ok(v !== -1 && s !== -1 && r !== -1, "検証・保存・拒否のどれかが道に無い");
  assert.ok(v < s, "★検証せずに保存する実装を落とす");
  assert.ok(v < r, "拒否は検証より後に居る");
});

test("null で外す道が在る(title:null -> setTitle(..., null))", () => {
  const i = real.indexOf(MARKER);
  const body = real.slice(i, i + 1200);
  assert.ok(/body\.title === null/.test(body), "外す道の分岐が無い");
  assert.ok(/setTitle\([^,]+,\s*sessionId,\s*null\)/.test(body), "外す保存が無い");
});

test("一覧側: 明示名は合流後の一括 override(3生産者への個別配布ではない)", () => {
  // 一括 map が listing の合流後に1箇所在る
  assert.ok(/explicitTitles\[s\.id\]\s*\?\s*\{\s*\.\.\.s,\s*title:\s*explicitTitles\[s\.id\]\s*\}/.test(real),
    "合流後の一括 override が無い");
  // unreadableRow / registryOnlySessions には台帳を渡していない(生産者への配布をしていない)
  assert.ok(!/registryOnlySessions\(\{[^}]*titles/.test(real),
    "★生産者への個別配布(片方だけ配り忘れる形)を落とす");
});
