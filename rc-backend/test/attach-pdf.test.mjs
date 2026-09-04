// `storeFile` の PDF 対応(行 #24「PDF 添付」、2026-09-03)の単体。
//
// ★`attach-file.test.mjs` と file を分けたのは、あちらが「v1 = 文書だけ」(sanitise した
//   申告名の拡張子だけで決める)の話に閉じているから —— PDF は唯一の binary 例外で、
//   **magic byte だけ**で見分ける(content-type-blind: 申告は読まない、バイトが決める)。
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync, readdirSync, readFileSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { storeFile, pathOf, sweepOld } from "../src/attach.mjs";

let DIR;
function base() {
  DIR = mkdtempSync(join(tmpdir(), "attach-pdf-test-"));
  return DIR;
}
test.after(() => { if (DIR) rmSync(DIR, { recursive: true, force: true }); });

// 最小の PDF fixture。頭は本物の magic(`%PDF-1.4\n`)、本体に **NUL バイトを1つ混ぜる**
// —— これが緑になる事自体が「NUL 拒否は PDF だけ迂回する」の裏取りになる
// (テキストの語彙にこの本体を通したら `binary` で落ちる、という対照は下に別途持つ)。
const PDF_MIN = Buffer.concat([
  Buffer.from("%PDF-1.4\n", "latin1"),
  Buffer.from([0x00, 0x01, 0x02, 0x03]),
  Buffer.from("\n1 0 obj\n<< >>\nendobj\n%%EOF", "latin1"),
]);

const PNG_HEAD = Buffer.from("89504e470d0a1a0a".repeat(4), "hex");

// ---- 置く ---------------------------------------------------------------------

test("★%PDF- で始まる本文(NUL 入り)は <id>.pdf / format:pdf で置ける。名前は sanitise 済み", () => {
  const d = base();
  const r = storeFile(PDF_MIN, { baseDir: d, name: "report.pdf" });
  assert.equal(r.name, "report.pdf");
  assert.equal(r.ext, "pdf");
  assert.equal(r.format, "pdf");
  const p = pathOf(d, r.id, r.ext);
  assert.equal(readdirSync(d).length, 1);
  assert.equal(readdirSync(d)[0], `${r.id}.pdf`);
  assert.equal(statSync(p).mode & 0o777, 0o600, "PDF も 0600 で置く(storeImage/storeFile と同じ規約)");
  assert.deepEqual(readFileSync(p), PDF_MIN, "バイトはそのまま置く(パース/変換しない)");
});

// ---- 断る系 ---------------------------------------------------------------------

test("★magic の無い本文が .pdf を申告しても bad-name(名前は PDF だと言うがバイトはそう言っていない)", () => {
  const d = base();
  assert.throws(
    () => storeFile(Buffer.from("this is not a pdf at all"), { baseDir: d, name: "notes.pdf" }),
    /bad-name/,
  );
  assert.deepEqual(readdirSync(d), [], "断った物を置き去りにした");
});

test("★%PDF- な本文を .txt で申告したら bad-name(中身が PDF でも申告拡張子は pdf に限定)", () => {
  const d = base();
  assert.throws(
    () => storeFile(PDF_MIN, { baseDir: d, name: "notes.txt" }),
    /bad-name/,
  );
  assert.deepEqual(readdirSync(d), [], "断った物を置き去りにした");
});

test("★テキストの NUL 入りは今まで通り binary(迂回は PDF magic の時だけ)", () => {
  const d = base();
  assert.throws(
    () => storeFile(Buffer.from("plain\x00text"), { baseDir: d, name: "a.txt" }),
    /binary/,
  );
});

test("★PNG バイトは(申告名が .pdf でも)use-image-door のまま(画像は storeImage の門)", () => {
  const d = base();
  assert.throws(
    () => storeFile(PNG_HEAD, { baseDir: d, name: "photo.pdf" }),
    /use-image-door/,
  );
});

// ---- 掃除 ---------------------------------------------------------------------

test("★sweepOld は古い .pdf も消す(拡張子語彙に pdf が入っている)", () => {
  const d = base();
  const stored = storeFile(PDF_MIN, { baseDir: d, name: "old.pdf" });
  const p = pathOf(d, stored.id, stored.ext);
  const past = new Date(Date.now() - 30 * 24 * 3600 * 1000);
  utimesSync(p, past, past);

  const r = sweepOld(d, Date.now());
  assert.equal(r.removed, 1);
  assert.equal(readdirSync(d).length, 0, "★古い .pdf が形の合わない名前として掃除から漏れた");
});

// ---- 検査は削らず落とす事の裏取り(mutation-style negative) --------------------

test("★4byte の `%PDF`(dash 無し)は PDF ではない —— NUL 迂回が効かず、pdf 拡張子も通らない", () => {
  const d = base();
  // dash が無い頭。仕様上あり得ない印を PDF として通していないかを直接測る。
  const almost = Buffer.concat([Buffer.from("%PDFxyz", "latin1"), Buffer.from([0x00]), Buffer.from("tail")]);
  // pdf 拡張子で申告 —— PDF だと誤認していれば NUL 迂回が効いて `pdf` 拡張子も
  // 通り、200 で置けてしまう所。実際は magic 不一致なので NUL 拒否が先に立って binary。
  assert.throws(() => storeFile(almost, { baseDir: d, name: "almost.pdf" }), /binary/);
  // 文書の拡張子で申告しても同じく NUL 拒否で binary(PDF だと誤認していれば
  // `pdf` しか許さない語彙のせいでむしろ bad-name になってしまう所 —— 別の症状で
  // バグが見える形にしてあるので、意図せず両方 binary で通っても取りこぼさない)。
  assert.throws(() => storeFile(almost, { baseDir: d, name: "almost.txt" }), /binary/);
  assert.deepEqual(readdirSync(d), [], "断った物を置き去りにした");
});
