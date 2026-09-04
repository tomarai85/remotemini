// `storeFile`(行 #23「非画像の添付」、2026-09-03)の単体。
//
// ★`attach.test.mjs` と file を分けたのは、あちらが画像(sniff で形式を決める)の話に
//   閉じているから —— 文書は形式を sniff せず**申告名を sanitise した結果**で決める、
//   別の検め方を持つ(`src/attach.mjs` の `storeFile` 頭の註)。
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { storeFile, pathOf, ATTACH_MAX_BYTES } from "../src/attach.mjs";
import { SESSION_ROUTE_RE } from "../src/reqlog.mjs";

let DIR;
function base() {
  DIR = mkdtempSync(join(tmpdir(), "attach-file-test-"));
  return DIR;
}
test.after(() => { if (DIR) rmSync(DIR, { recursive: true, force: true }); });

// PNG magic の最小 fixture。`storeImage` 側と同じ判定(`sniffFormat`)を通す為の物で、
// 中身が完全な PNG である必要は無い(先頭 16 byte しか見ない)。
const PNG_HEAD = Buffer.from("89504e470d0a1a0a".repeat(4), "hex");

// ---- 置く ---------------------------------------------------------------------

test("★UTF-8 文書を置く。名前は sanitise 済みで返り、file の mode は 0600", () => {
  const d = base();
  const r = storeFile(Buffer.from("2026-09-03 の tail\nこんにちは\n", "utf8"), { baseDir: d, name: "notes.md" });
  assert.equal(r.name, "notes.md");
  assert.equal(r.ext, "md");
  assert.equal(r.format, "text");
  const p = pathOf(d, r.id, r.ext);
  assert.equal(statSync(p).mode & 0o777, 0o600);
  assert.equal(readFileSync(p, "utf8"), "2026-09-03 の tail\nこんにちは\n");
});

test("★置いた file の名前は id.ext だけ。申告名を一度も使わない", () => {
  const d = base();
  const r = storeFile(Buffer.from("hi"), { baseDir: d, name: "my-secret-project-plan.txt" });
  const names = readdirSync(d);
  assert.equal(names.length, 1);
  assert.equal(names[0], `${r.id}.${r.ext}`);
  assert.ok(!names[0].includes("my-secret-project-plan"), "申告名がディスク上の名前に漏れた");
});

test("同じ id へ二度置けない(storeImage と同じ規約)", () => {
  const d = base();
  const id = "b".repeat(32);
  storeFile(Buffer.from("first"), { baseDir: d, name: "a.txt", id });
  assert.throws(() => storeFile(Buffer.from("second"), { baseDir: d, name: "a.txt", id }));
});

// ---- 断る系 ---------------------------------------------------------------------

test("空・大きすぎ・NUL 入り・画像・申告なしを理由ごとに断る", () => {
  const d = base();
  assert.throws(() => storeFile(Buffer.alloc(0), { baseDir: d, name: "a.txt" }), /empty-body/);
  assert.throws(
    () => storeFile(Buffer.alloc(ATTACH_MAX_BYTES + 1, 0x61), { baseDir: d, name: "a.txt" }),
    /too-large/,
  );
  assert.throws(
    () => storeFile(Buffer.from("plain\x00text"), { baseDir: d, name: "a.txt" }),
    /binary/,
    "NUL バイトを含む本文",
  );
  // ★画像は別の門(storeImage)。ここへ来たら理由付きで押し返す —— 通してしまうと
  //   sniff/scrub の保護(GPS を落とす等)が素通りする。
  assert.throws(() => storeFile(PNG_HEAD, { baseDir: d, name: "a.txt" }), /use-image-door/);
});

test("★置けなかった時、置き場に何も残さない(空の readdir)", () => {
  const d = base();
  for (const attempt of [
    () => storeFile(Buffer.alloc(0), { baseDir: d, name: "a.txt" }),
    () => storeFile(PNG_HEAD, { baseDir: d, name: "a.txt" }),
    () => storeFile(Buffer.from("hi"), { baseDir: d, name: "../../etc/passwd" }),
  ]) {
    assert.throws(attempt);
  }
  assert.deepEqual(readdirSync(d), [], "断った物を置き去りにした");
});

test("★悪い申告名は理由を分けずに全部 bad-name(削って直さない)", () => {
  const d = base();
  const bad = [
    "../../x.txt",              // 経路トラバーサル
    "..%2Fx.txt",                // 経路っぽいが charset の外(% を含む)
    ".hidden.txt",                // 先頭が dot
    "noextensionatall",           // 拡張子が無い
    "a".repeat(70) + ".txt",      // 65+ 文字
    "trailing.dot.",              // dot で終わる = 拡張子が空
    "script.exe",                 // 実行系(語彙に無い)
    "archive.zip",                // アーカイブ(語彙に無い)
    "spaced name.txt",            // charset の外(空白)
    "",                            // 空
    null,                          // 未申告
    undefined,
  ];
  for (const name of bad) {
    assert.throws(() => storeFile(Buffer.from("hi"), { baseDir: d, name }), /bad-name/, JSON.stringify(name));
  }
});

test("語彙にある拡張子は通る(log tail / CSV / JSON / Markdown / ソースの代表)", () => {
  const d = base();
  for (const name of ["tail.log", "rows.csv", "data.json", "notes.md", "diff.patch", "app.ts", "run.sh"]) {
    const r = storeFile(Buffer.from("content"), { baseDir: d, name });
    assert.equal(r.name, name);
  }
});

// ---- 検査は削らず落とす事の裏取り(mutation-style negative) --------------------

test("★sanitise を経ずに申告名を直接 pathOf へ渡したら落ちる(sanitiser が飾りでない事)", () => {
  const id = "c".repeat(32);
  // ここは `storeFile` を通さず、`pathOf` 単体へ**生の**申告名を突っ込む —— sanitiser を
  // 経由しない道が在ったら何が起きるかを直接測る。落ちれば sanitiser は「無くても pathOf が
  // 拾う」二重の門ではなく、`storeFile` の唯一の防御である事の裏が取れる
  // (`storeFile` は `<id>.<ext>` しか `pathOf` へ渡さず、申告名をそのまま渡す事はない)。
  for (const raw of ["../../etc/passwd", "notes.md/../../x", "a b.txt", ""]) {
    assert.throws(() => pathOf("/base", id, raw), /bad-attachment-ext/, raw);
  }
});

// ---- 到達性(title-route.test.mjs と同じ形)-------------------------------------

test("★到達できる: attach-file が route の白名簿に居る", () => {
  const m = SESSION_ROUTE_RE.exec("/api/sessions/abc-123/attach-file");
  assert.ok(m, "attach-file が SESSION_ROUTE_RE に当たらない = handler が在っても永久に 404");
  assert.equal(m[2], "attach-file");
});
