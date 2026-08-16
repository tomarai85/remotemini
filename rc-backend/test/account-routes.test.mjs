// 口座の3つの道(`/api/account` / `/api/account/select` / `/api/account/next`)の**構造**を
// `src/server.mjs` の本文で押さえる。
//
// ★なぜ静的検査なのか: `src/server.mjs` は import した瞬間に listen する
//   (`server.listen(...)` が module 直下)。単体からは呼べないので、この層は e2e 越しに
//   しか触れない —— そして e2e が実際に見ているのは `GET /api/account` の1鍵だけで、
//   `/next` も誤り応答も**一度も測っていなかった**(2026-08-12 実測)。
//
// ★2026-08-14 に測る対象が変わった。以前は「本文に `json(res, 200, { account:` と
//   書いてあるか」を grep していた —— 封筒がハンドラの中の literal で、**単体から一度も
//   呼べなかった**から他に手が無かった。今は `accountBody`(src/wire.mjs)が純関数なので、
//   **鍵名は `test/wire-key-agreement.test.mjs` が実行して電話と突き合わせる**。
//   此処に残す仕事は、grep でしか見えない物だけ:
//     - 3本とも封筒を**経由している**(手書きの literal に戻っていない)
//     - 副作用の後に**観測し直している**(台本の自己申告を返していない)
//     - 副作用の前に**検証している**(白名簿 + 名前の不変条件)
//     - 進める道に**撃ち直しが無い**
//
// ★対照は2段: ①合成した偽物で「述語が区別できる」事、②**本物の文面から1本だけ剥がして**
//   「述語が本物の書き方に当たる」事。②が無いと「自分の書き癖に当たっているだけ」を
//   排除できない(`server-cwd.test.mjs` の規律をそのまま踏襲)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.mjs");
const real = readFileSync(SRC, "utf8");

/**
 * 或る道の分岐本文を切り出す。
 *
 * ★境界は `catch` 節の閉じ(`    }` = 4 桁字下げ)。最初の版は「次の `if (path ===` まで」
 *   にしていて、**30,618 字**を掴んでいた —— 進める道の下には暫く別の道が来ないので、
 *   遥か下の `for (const e of take)` まで本文に入り、A6(撃ち直しが無い事)が
 *   **本物の source で赤**になった(2026-08-12 実測)。
 *   検査が赤を出した時、成果物を疑う前に其の検査が緑になり得るかを確かめる、の実例。
 */
function routeBody(src, marker) {
  const i = src.indexOf(marker);
  if (i === -1) return null;
  const rest = src.slice(i + marker.length);
  // `      }\n    }` = catch の閉じ + 分岐の閉じ。実物の字下げに合わせてある。
  const end = rest.indexOf("\n    }\n");
  return end === -1 ? null : rest.slice(0, end);
}

const GET_MARKER = 'if (path === "/api/account" && req.method === "GET")';
const SELECT_MARKER = 'if (path === "/api/account/select" && req.method === "POST")';
const NEXT_MARKER = 'if (path === "/api/account/next" && req.method === "POST")';
const ROUTES = [
  ["読む道", GET_MARKER],
  ["選ぶ道", SELECT_MARKER],
  ["進める道", NEXT_MARKER],
];

/** 副作用を起こす口(台本を引数付きで叩く所)。読むだけの `readFleetAccount()` とは別物。 */
const SIDE_EFFECT = /execFileSync\(FLEET_ACCOUNT,\s*\[[^\]]/;

// ---- 要求(1件ずつ落ちる。束ねると「どれが壊れたか」が消える)----
const REQS = [
  {
    id: "A1 読む道が在る",
    why: "電話の口座画面が最初に叩く先。消えると口座欄が永久に失敗表示になる",
    ok: (s) => s.includes(GET_MARKER),
  },
  {
    id: "A2 選ぶ道が在る",
    why: "REQUIREMENTS §9-3(矢印1本ではなく名指しで選ぶ)そのもの",
    ok: (s) => s.includes(SELECT_MARKER),
  },
  {
    id: "A3 進める道が在る",
    why: "選ぶ道が使えない時の退避(トークンが1つしか無い等)。§5-8 の切替",
    ok: (s) => s.includes(NEXT_MARKER),
  },
  {
    id: "A4 3本とも封筒 `accountBody` を経由する",
    why: "鍵名の正本は `src/wire.mjs`。手書きの literal に戻すと、電話との突き合わせ"
      + "(wire-key-agreement)が**その道だけ**測らなくなる —— 緑のまま画面が痩せる形",
    ok: (s) => ROUTES.every(([, marker]) => {
      const b = routeBody(s, marker);
      return !!b && /return json\(res,\s*200,\s*accountBody\(/.test(b);
    }),
  },
  {
    id: "A5 3本とも失敗が `error` 鍵で理由を載せる",
    why: "電話は理由をそのまま人に見せる。鍵が動くと「机の側で失敗しました: (無)」に化ける",
    ok: (s) => ROUTES.every(([, marker]) => {
      const b = routeBody(s, marker);
      return !!b && /json\(res,\s*500,\s*\{\s*error:/.test(b);
    }),
  },
  {
    id: "A6 進める道に自動の撃ち直しが無い",
    why: "`fleet-account --next` は時間切れになる**前に**口座を進め終える(同関数の注釈)。"
      + "500 を見て撃ち直す物を置くと、二段進めて一段失敗したと報告する",
    ok: (s) => {
      const b = routeBody(s, NEXT_MARKER);
      return !!b && !/\bfor\s*\(|\bwhile\s*\(|retry|再試行/i.test(b);
    },
  },
  {
    id: "A7 副作用を起こす2本は、その**後で**観測し直す",
    why: "台本の exit 0 は「命令が通った」であって「今この口座に成っている」ではない"
      + "(Codex 2026-08-14)。頼んだ名前を返すと、切替が効かなかった日に画面だけが嘘を吐く",
    ok: (s) => [SELECT_MARKER, NEXT_MARKER].every((marker) => {
      const b = routeBody(s, marker);
      if (!b) return false;
      const hit = SIDE_EFFECT.exec(b);
      if (!hit) return false;
      const after = b.slice(hit.index).indexOf("readFleetAccount()");
      return after !== -1;
    }),
  },
  {
    id: "A8 選ぶ道は副作用の**前に** `selectionProblem` を通す",
    why: "白名簿と名前の不変条件を両方通す唯一の口。後ろに置くと、断るべき名前で"
      + "台本を叩いてから断る事になる(`--next` という名の口座で口座が進む)",
    ok: (s) => {
      const b = routeBody(s, SELECT_MARKER);
      if (!b) return false;
      const guard = b.indexOf("selectionProblem(");
      const hit = SIDE_EFFECT.exec(b);
      return guard !== -1 && !!hit && guard < hit.index;
    },
  },
  {
    id: "A9 選ぶ道は断り理由を `code` 以外の鍵で返す",
    why: "`code` は電話が**画面を移す**為の凍らせた語彙(`test/recovery-codes.test.mjs`)。"
      + "断り理由を同じ鍵で流すと遷移の判断が壊れる",
    ok: (s) => {
      const b = routeBody(s, SELECT_MARKER);
      return !!b && /json\(res,\s*400,\s*\{[^}]*error:/.test(b) && !/json\(res,\s*400,\s*\{[^}]*\bcode:/.test(b);
    },
  },
  {
    id: "A10 選ぶ道は本文の解釈を台本の try の**外**でやる",
    why: "同じ try に入れると、本文が JSON として読めなかっただけの要求に"
      + "`fleet-account <name> failed: ...` の 500 が返る —— 台本を一度も呼んでいないのに"
      + "edith 側が壊れたと名指しする応答で、読んだ人を机へ走らせる。64KB 超で `readBody` が"
      + "落ちる道も同じ所へ流れ込む",
    ok: (s) => {
      const b = routeBody(s, SELECT_MARKER);
      if (!b) return false;
      const parse = b.indexOf("readBody(");
      const script = b.indexOf("readFleetAccount()");
      if (parse === -1 || script === -1 || parse > script) return false;
      // 解釈と台本の呼び出しの**間**に本文用の受け(400)が在り、台本の 500 は無い。
      const between = b.slice(parse, script);
      return /json\(res,\s*400,\s*\{[^}]*error:/.test(between) && !/json\(res,\s*500,/.test(between);
    },
  },
];

test("口座の3つの道が契約通りの構造を持つ", () => {
  const bad = REQS.filter((r) => !r.ok(real)).map((r) => `${r.id} — ${r.why}`);
  assert.deepEqual(bad, [], "口座の道の契約が本文と食い違っている");
});

// ---- 対照① 合成した偽物で、述語が区別できる事 ----
test("対照①: 封筒を手書き literal に戻した偽物では A4 が落ちる", () => {
  const fake = real.replace(/return json\(res,\s*200,\s*accountBody\(/g, "return json(res, 200, { account: x, ...accountBodyX(");
  assert.notEqual(fake, real, "変異が当たっていない = 以降は測っていない");
  assert.ok(REQS.filter((r) => !r.ok(fake)).map((r) => r.id).includes("A4 3本とも封筒 `accountBody` を経由する"),
            "literal に戻しても A4 が緑 = 述語が封筒の経由を見ていない");
});

test("対照①: 誤り鍵を変えた偽物では A5 が落ちる", () => {
  const fake = real.replace(/json\(res,\s*500,\s*\{\s*error:/g, "json(res, 500, { reason:");
  assert.notEqual(fake, real, "変異が当たっていない = 以降は測っていない");
  assert.ok(REQS.filter((r) => !r.ok(fake)).map((r) => r.id).includes("A5 3本とも失敗が `error` 鍵で理由を載せる"));
});

test("対照①: 断り理由を `code` に戻した偽物では A9 が落ちる", () => {
  const fake = real.replace(/json\(res, 400, \{ error: selectionMessage\(problem\), reason: problem \}\)/,
                            "json(res, 400, { error: selectionMessage(problem), code: problem })");
  assert.notEqual(fake, real, "変異が当たっていない = 以降は測っていない");
  assert.ok(REQS.filter((r) => !r.ok(fake)).map((r) => r.id).includes("A9 選ぶ道は断り理由を `code` 以外の鍵で返す"));
});

test("対照①: 本文の受けを台本の 500 に戻した偽物では A10 が落ちる", () => {
  const fake = real.replace("return json(res, 400, { error: `Request body unreadable: ${e.message}` });",
                            "return json(res, 500, { error: `fleet-account <name> failed: ${e.message}` });");
  assert.notEqual(fake, real, "変異が当たっていない = 以降は測っていない");
  assert.ok(REQS.filter((r) => !r.ok(fake)).map((r) => r.id).includes("A10 選ぶ道は本文の解釈を台本の try の**外**でやる"),
            "台本の名前で 500 に戻しても A10 が緑 = 述語が受けの位置を見ていない");
});

// ---- 対照② 本物の文面から1本だけ剥がして、述語が本物の書き方に当たる事 ----
test("対照②: 選ぶ道を1本剥がすと A2/A4/A5/A7/A8/A9 が落ちる", () => {
  const stripped = real.replace(SELECT_MARKER, 'if (path === "/api/account/nope" && req.method === "POST")');
  assert.notEqual(stripped, real, "変異が当たっていない = 以降は測っていない");
  const failed = REQS.filter((r) => !r.ok(stripped)).map((r) => r.id);
  for (const id of ["A2 選ぶ道が在る", "A4 3本とも封筒 `accountBody` を経由する",
                    "A5 3本とも失敗が `error` 鍵で理由を載せる",
                    "A7 副作用を起こす2本は、その**後で**観測し直す",
                    "A8 選ぶ道は副作用の**前に** `selectionProblem` を通す",
                    "A9 選ぶ道は断り理由を `code` 以外の鍵で返す",
                    "A10 選ぶ道は本文の解釈を台本の try の**外**でやる"]) {
    assert.ok(failed.includes(id), `${id} が道を消しても緑 = 述語が本物に当たっていない`);
  }
});


test("対照②-b: 撃ち直しを植えると A6 が落ちる", () => {
  const b = routeBody(real, NEXT_MARKER);
  assert.ok(b, "進める道の本文が読めない");
  const injected = real.replace(b, b.replace("try {", "for (let i = 0; i < 2; i++) try {"));
  assert.notEqual(injected, real, "変異が当たっていない = A6 は測っていない");
  assert.ok(REQS.filter((r) => !r.ok(injected)).map((r) => r.id).includes("A6 進める道に自動の撃ち直しが無い"),
            "撃ち直しを植えても A6 が緑 = 此の的は空回りしている");
});

test("対照②-c: 副作用の後の観測し直しを剥がすと A7 が落ちる", () => {
  const b = routeBody(real, SELECT_MARKER);
  assert.ok(b, "選ぶ道の本文が読めない");
  const hit = SIDE_EFFECT.exec(b);
  assert.ok(hit, "副作用の口が読めない = A7 は測っていない");
  // 副作用より後ろの `readFleetAccount()` だけを潰す(前の観測は残す)
  const head = b.slice(0, hit.index);
  const tail = b.slice(hit.index).replace("readFleetAccount()", "({ raw: \"\", parsed: before.parsed })");
  const injected = real.replace(b, head + tail);
  assert.notEqual(injected, real, "変異が当たっていない = A7 は測っていない");
  assert.ok(REQS.filter((r) => !r.ok(injected)).map((r) => r.id).includes("A7 副作用を起こす2本は、その**後で**観測し直す"),
            "観測し直しを剥がしても A7 が緑 = 述語が順序を見ていない");
});

test("対照②-d: 検証を副作用の後ろへ動かすと A8 が落ちる", () => {
  const b = routeBody(real, SELECT_MARKER);
  assert.ok(b, "選ぶ道の本文が読めない");
  const injected = real.replace(b, b.replace("selectionProblem(", "問題なし(").replace("const after =", "const problem2 = selectionProblem(before.parsed, want); const after ="));
  assert.notEqual(injected, real, "変異が当たっていない = A8 は測っていない");
  assert.ok(REQS.filter((r) => !r.ok(injected)).map((r) => r.id).includes("A8 選ぶ道は副作用の**前に** `selectionProblem` を通す"),
            "検証を後ろへ動かしても A8 が緑 = 述語が順序を見ていない");
});

test("対照②-e: 本文の解釈を台本の try へ畳み戻すと A10 が落ちる", () => {
  // ★合成ではなく**直す前の書き方そのもの**。2026-08-15 に此の形で出しかけた。
  const folded = real.replace(
    "      let want;\n      try {\n        want = JSON.parse((await readBody(req)) || \"{}\")?.name;\n"
      + "      } catch (e) {\n        if (e instanceof BodyTooLarge) return tooLarge(req, res, e);\n"
      + "        return json(res, 400, { error: `Request body unreadable: ${e.message}` });\n"
      + "      }\n      try {\n",
    "      try {\n        const want = JSON.parse((await readBody(req)) || \"{}\")?.name;\n");
  assert.notEqual(folded, real, "変異が当たっていない = A10 は測っていない");
  assert.ok(REQS.filter((r) => !r.ok(folded)).map((r) => r.id).includes("A10 選ぶ道は本文の解釈を台本の try の**外**でやる"),
            "1つの try へ畳み戻しても A10 が緑 = 此の的は空回りしている");
});
