// 口座の2つの道(`/api/account` と `/api/account/next`)が**電話の Decodable と
// 同じ鍵名**を出す事を、`src/server.mjs` の本文で押さえる。
//
// ★なぜ静的検査なのか: `src/server.mjs` は import した瞬間に listen する
//   (`server.listen(...)` が module 直下)。単体からは呼べないので、この層は e2e 越しに
//   しか触れない —— そして e2e が実際に見ているのは `GET /api/account` の `account` 鍵
//   1つだけで、`/next` も誤り応答の `error` 鍵も**一度も測っていなかった**
//   (2026-08-12 実測)。`server-cwd.test.mjs` と同じ理由・同じ形で文面を読む。
//
// ★対照は2段: ①合成した偽物で「述語が区別できる」事、②**本物の文面から1本だけ剥がして**
//   「述語が本物の書き方に当たる」事。②が無いと「自分の書き癖に当たっているだけ」を
//   排除できない(`server-cwd.test.mjs` の規律をそのまま踏襲)。
//
// ★電話側の正本 = `ios/Sources/Core/AccountClient.swift` の `Wire`
//   (`{account}` を読む / 失敗時に `{error}` を読む)。此処が動けば向こうが黙って痩せる。
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
const NEXT_MARKER = 'if (path === "/api/account/next" && req.method === "POST")';

// ---- 要求(1件ずつ落ちる。束ねると「どれが壊れたか」が消える)----
const REQS = [
  {
    id: "A1 読む道が在る",
    why: "電話の `AccountReading` が叩く先。消えると口座欄が永久に失敗表示になる",
    ok: (s) => s.includes(GET_MARKER),
  },
  {
    id: "A2 進める道が在る",
    why: "電話の `AccountAdvancing` が叩く先。REQUIREMENTS §5-8 の切替そのもの",
    ok: (s) => s.includes(NEXT_MARKER),
  },
  {
    id: "A3 読む道は `account` 鍵で返す",
    why: "電話の `Wire` は `account` を読む。鍵名が動くと復号が黙って失敗し、画面は空欄になる",
    ok: (s) => {
      const b = routeBody(s, GET_MARKER);
      return !!b && /json\(res,\s*200,\s*\{\s*account\b/.test(b);
    },
  },
  {
    id: "A4 進める道も `account` 鍵で返す",
    why: "切替の直後に電話が表示を更新する唯一の材料。片方だけ鍵名が動く形を塞ぐ",
    ok: (s) => {
      const b = routeBody(s, NEXT_MARKER);
      return !!b && /json\(res,\s*200,\s*\{\s*account\b/.test(b);
    },
  },
  {
    id: "A5 両方の失敗が `error` 鍵で理由を載せる",
    why: "電話は理由をそのまま人に見せる。鍵が動くと「机の側で失敗しました: (無)」に化ける",
    ok: (s) => {
      const g = routeBody(s, GET_MARKER);
      const n = routeBody(s, NEXT_MARKER);
      return !!g && !!n
        && /json\(res,\s*500,\s*\{\s*error:/.test(g)
        && /json\(res,\s*500,\s*\{\s*error:/.test(n);
    },
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
];

test("口座の2つの道が電話と同じ鍵名を出す", () => {
  const bad = REQS.filter((r) => !r.ok(real)).map((r) => `${r.id} — ${r.why}`);
  assert.deepEqual(bad, [], "口座の道の契約が本文と食い違っている");
});

// ---- 対照① 合成した偽物で、述語が区別できる事 ----
test("対照①: 鍵名を変えた偽物では A3/A4/A5 が落ちる", () => {
  const fake = real
    .replace(/json\(res,\s*200,\s*\{\s*account:/g, "json(res, 200, { acct:")
    .replace(/json\(res,\s*500,\s*\{\s*error:/g, "json(res, 500, { reason:");
  assert.notEqual(fake, real, "変異が当たっていない = 以降は測っていない");

  const failed = REQS.filter((r) => !r.ok(fake)).map((r) => r.id);
  for (const id of ["A3 読む道は `account` 鍵で返す", "A4 進める道も `account` 鍵で返す",
                    "A5 両方の失敗が `error` 鍵で理由を載せる"]) {
    assert.ok(failed.includes(id), `${id} が偽物でも緑 = 述語が鍵名を見ていない`);
  }
});

// ---- 対照② 本物の文面から1本だけ剥がして、述語が本物の書き方に当たる事 ----
test("対照②: 進める道を1本剥がすと A2/A4 が落ちる", () => {
  const stripped = real.replace(NEXT_MARKER, 'if (path === "/api/account/nope" && req.method === "POST")');
  assert.notEqual(stripped, real, "変異が当たっていない = 以降は測っていない");

  const failed = REQS.filter((r) => !r.ok(stripped)).map((r) => r.id);
  assert.ok(failed.includes("A2 進める道が在る"), "道を消しても A2 が緑 = 述語が本物に当たっていない");
  assert.ok(failed.includes("A4 進める道も `account` 鍵で返す"), "同上(A4)");
});

test("対照②-b: 撃ち直しを植えると A6 が落ちる", () => {
  const b = routeBody(real, NEXT_MARKER);
  assert.ok(b, "進める道の本文が読めない");
  const injected = real.replace(b, b.replace("try {", "for (let i = 0; i < 2; i++) try {"));
  assert.notEqual(injected, real, "変異が当たっていない = A6 は測っていない");

  const failed = REQS.filter((r) => !r.ok(injected)).map((r) => r.id);
  assert.ok(failed.includes("A6 進める道に自動の撃ち直しが無い"),
            "撃ち直しを植えても A6 が緑 = 此の的は空回りしている");
});
