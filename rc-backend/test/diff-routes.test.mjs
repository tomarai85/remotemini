// `GET /api/sessions/<id>/diff`(対照表 #4)の**道の構造**を src/server.mjs の本文で押さえる。
//
// ★静的検査の理由は title-route.test.mjs と同じ: server.mjs は import した瞬間に
//   listen するので単体から呼べない。中身(`readWorkingDiff`)は test/sessiondiff.test.mjs が
//   実行して測り、封筒の鍵名は wire-key-agreement が電話と突き合わせる。此処に残す仕事は
//   grep でしか見えない物:
//     - 道が白名簿(SESSION_ROUTE_RE)に居て、存在検査の**後ろ**に居る(= 無い id は 404)
//     - GET だけ(書く動詞が 1 つも無い道、という約束を method の側からも固定する)
//     - cwd が無い会話は **200 + reason** で返す(4xx/5xx にすると電話が「壊れた」と読む)
//     - 中身は `readWorkingDiff` から来て、封筒は `diffBody` だけが作る(鍵名の一元化)
//     - `diffBody` は `reason` を成功時も **null で必ず載せる**、`truncated` と `totalBytes` は対
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { SESSION_ROUTE_RE } from "../src/reqlog.mjs";
import { diffBody } from "../src/wire.mjs";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.mjs");
const real = readFileSync(SRC, "utf8");

const MARKER = 'if (action === "diff" && req.method === "GET")';

test("★到達できる: diff が route の白名簿に居る(handler が在っても白名簿に無ければ永久に 404)", () => {
  const m = SESSION_ROUTE_RE.exec("/api/sessions/abc-123/diff");
  assert.ok(m, "diff が SESSION_ROUTE_RE に当たらない");
  assert.equal(m[2], "diff");
  // 錨: 出鱈目な action は今も当たらない(白名簿が全通しに緩んでいない)
  assert.equal(SESSION_ROUTE_RE.exec("/api/sessions/abc-123/diffs"), null);
});

test("道が在り、セッション存在検査(SESSION_ROUTE_RE)より後ろに居る", () => {
  const route = real.indexOf(MARKER);
  const guard = real.indexOf("SESSION_ROUTE_RE.exec(path)");
  assert.ok(route !== -1, "diff の道が server.mjs に無い");
  assert.ok(guard !== -1 && guard < route,
    "★存在しない session id の差分を読みに行く実装を落とす(存在検査の前に道が居る)");
});

test("GET だけ(同じ action に POST / DELETE の道が無い)", () => {
  assert.equal((real.match(/action === "diff"/g) ?? []).length, 1,
    "diff の分岐が 2 つ以上在る = GET 以外の動詞が生えた");
  assert.ok(!/action === "diff" && req\.method === "(POST|PUT|DELETE)"/.test(real));
});

test("★道は `handleDiffGet`(src/diffroute.mjs)へ委ねるだけ(挙動は diff-route-handler.test.mjs が偽の req/res で通す)", () => {
  const i = real.indexOf(MARKER);
  const body = real.slice(i, i + 700);
  assert.ok(/return handleDiffGet\(\{/.test(body), "委ねていない(口の本体が server.mjs に戻っている = 単体から挙動を測れない)");
  assert.ok(/cwd: sessionCwd\(\)/.test(body), "会話の cwd を渡していない");
  for (const dep of ["readWorkingDiff", "json", "diffBody"]) {
    assert.ok(new RegExp(`\\b${dep}\\b`).test(body), `${dep} を渡していない`);
  }
  assert.ok(/import \{ handleDiffGet \} from "\.\/diffroute\.mjs"/.test(real), "diffroute.mjs を import していない");
  // 錨: 封筒の鍵名(hunks 等)を server.mjs が自前で書いていない
  assert.ok(!/hunks:\s*\[/.test(body), "server.mjs が封筒の鍵名を自前で書いている");
});

test("口の本体(diffroute.mjs): cwd 無しは 200 + no_cwd、読み手は await、封筒は diffBody だけ", () => {
  const file = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "diffroute.mjs"), "utf8");
  // ★頭の註にも同じ語が在るので、関数の本体から探す(註を拾うと「200 以外」に見える)
  const fnStart = file.indexOf("export async function handleDiffGet(");
  assert.ok(fnStart !== -1, "handleDiffGet が無い");
  const route = file.slice(fnStart);
  const noCwd = route.indexOf('reason: "no_cwd"');
  assert.ok(noCwd !== -1, "no_cwd の分岐が無い");
  const status = route.slice(route.lastIndexOf("json(res,", noCwd), noCwd);
  assert.ok(/json\(res,\s*200\b/.test(status), `no_cwd を 200 以外で返している: ${status.trim().slice(0, 60)}`);
  assert.ok(/await readWorkingDiff\(/.test(route), "★同期で待つ実装を落とす(事象ループを止める)");
  assert.ok(route.indexOf("readWorkingDiff(") < route.indexOf("diffBody(r)"), "封筒が読みより前に居る");
  assert.ok(!/hunks:\s*\[/.test(route), "封筒の鍵名を自前で書いている");
});

test("diffBody: reason は成功時も null で載り、truncated と totalBytes は対で載る", () => {
  const ok = diffBody({ files: [], truncated: false, totalBytes: 0 });
  assert.deepEqual(ok, { files: [], truncated: false, totalBytes: 0, reason: null });
  const bad = diffBody({ files: [], truncated: false, totalBytes: 0, reason: "not_a_repo" });
  assert.equal(bad.reason, "not_a_repo");
  assert.ok("truncated" in bad && "totalBytes" in bad);
});

test("diffBody: file の欄は path/staged/binary/added/removed/truncated/hunks だけ、行は kind/text だけ", () => {
  const out = diffBody({
    files: [{
      path: "a.txt", staged: false, binary: false, added: 1, removed: 0, truncated: false,
      extra: "must-not-leak",
      hunks: [{ header: "@@ -1 +1 @@", lines: [{ kind: "+", text: "x", secret: "no" }] }],
    }],
    truncated: false, totalBytes: 3,
  });
  assert.deepEqual(Object.keys(out.files[0]).sort(),
    ["added", "binary", "hunks", "path", "removed", "staged", "truncated"]);
  assert.deepEqual(Object.keys(out.files[0].hunks[0].lines[0]).sort(), ["kind", "text"]);
});
