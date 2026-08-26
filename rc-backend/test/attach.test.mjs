import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, statSync, readFileSync, readdirSync, symlinkSync,
         mkdirSync, writeFileSync, utimesSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sniffFormat, newAttachmentId, pathOf, storeImage, sweepOld,
         assertNoSymlinkOnPath, ATTACH_MAX_BYTES, ATTACH_MAX_PIXELS } from "../src/attach.mjs";

// ★検体は**実物から作る**。手で書いた magic だけで通すと、「形式の見分けについての
//   自分の思い込み」ごと緑になる。macOS 同梱の壁紙を sips で縮めて作る。
const SRC = "/System/Library/Desktop Pictures/iMac Blue.heic";
const HAVE_SIPS = existsSync("/usr/bin/sips") && existsSync(SRC);

let DIR;
function fixtures() {
  DIR = mkdtempSync(join(tmpdir(), "attach-test-"));
  execFileSync("/usr/bin/sips", ["-s", "format", "heic", "-Z", "600", SRC, "--out", join(DIR, "a.heic")],
    { stdio: "ignore" });
  execFileSync("/usr/bin/sips", ["-s", "format", "png", "-Z", "300", SRC, "--out", join(DIR, "a.png")],
    { stdio: "ignore" });
  execFileSync("/usr/bin/sips", ["-s", "format", "jpeg", "-Z", "300", SRC, "--out", join(DIR, "a.jpg")],
    { stdio: "ignore" });
  return DIR;
}
const skip = HAVE_SIPS ? false : "sips か検体が無い機体 = 測っていない";

test.after(() => { if (DIR) rmSync(DIR, { recursive: true, force: true }); });

// ---- 形式の見分け -------------------------------------------------------------

test("実物の3形式を見分ける", { skip }, () => {
  const d = fixtures();
  assert.equal(sniffFormat(readFileSync(join(d, "a.heic"))), "heic");
  assert.equal(sniffFormat(readFileSync(join(d, "a.png"))), "png");
  assert.equal(sniffFormat(readFileSync(join(d, "a.jpg"))), "jpg");
});

test("★画像でない物は通さない(content-type を信じないので、ここが唯一の門)", () => {
  for (const s of ["<html>hello world padding here</html>", "#!/bin/sh\nrm -rf /\n", "{\"json\":true,\"pad\":1}"]) {
    assert.equal(sniffFormat(Buffer.from(s)), null, s.slice(0, 20));
  }
  assert.equal(sniffFormat(Buffer.alloc(4)), null, "短すぎる物");
  assert.equal(sniffFormat(null), null);
});

test("★PNG の magic を1バイト崩したら通らない(判定が飾りでない事)", () => {
  const b = Buffer.from("89504e470d0a1a0a".repeat(4), "hex");
  assert.equal(sniffFormat(b), "png");
  b[1] = 0x00;
  assert.equal(sniffFormat(b), null);
});

// ---- 名前とパス ---------------------------------------------------------------

test("id は 128bit hex で、毎回違う", () => {
  const a = newAttachmentId(), b = newAttachmentId();
  assert.match(a, /^[0-9a-f]{32}$/);
  assert.notEqual(a, b);
});

test("★id の形が違えばパスを作らない(トラバーサルの入口を閉じる)", () => {
  for (const bad of ["../../etc/passwd", "a".repeat(31), "AAAA", "", "..", "/abs", "x/y"]) {
    assert.throws(() => pathOf("/base", bad, "png"), /bad-attachment-id/, bad);
  }
});

test("★拡張子も自分の語彙だけ", () => {
  const id = newAttachmentId();
  for (const bad of ["sh", "exe", "png.sh", "", "../png"]) {
    assert.throws(() => pathOf("/base", id, bad), /bad-attachment-ext/, bad);
  }
});

test("★置き場の直前が symlink なら拒む", { skip }, () => {
  const d = fixtures();
  const real = join(d, "real"); mkdirSync(real);
  const link = join(d, "link"); symlinkSync(real, link);
  assert.throws(() => assertNoSymlinkOnPath(join(link, "store"), d), /symlink-on-path/);
});

test("★根より上の OS の symlink では落ちない(macOS の /var で必ず落ちた版の回帰)", () => {
  // 2026-08-26: `/` まで遡る版は `/var` が symlink なので**どの一時 dir でも**落ちた。
  // 正しそうに見えて一度も使えない検査だった。
  const d = mkdtempSync(join(tmpdir(), "attach-root-"));
  try { assertNoSymlinkOnPath(join(d, "store")); } finally { rmSync(d, { recursive: true, force: true }); }
});

// ---- 置く ---------------------------------------------------------------------

test("★PNG はそのまま、mode 0600、置き場は 0700", { skip }, () => {
  const d = fixtures(); const base = join(d, "s1");
  const r = storeImage(readFileSync(join(d, "a.png")), { baseDir: base });
  assert.equal(r.ext, "png");
  assert.equal(r.converted, false);
  assert.equal(statSync(pathOf(base, r.id, r.ext)).mode & 0o777, 0o600);
  assert.equal(statSync(base).mode & 0o777, 0o700);
});

test("★HEIC は JPEG へ変換され、変換後も 0600", { skip }, () => {
  // 2026-08-26 実測の回帰: `sips --out` が umask で作り直すので、0600 で開いた意味が
  // 消えて 644 に戻っていた。**開き方ではなく結果**を測る。
  const d = fixtures(); const base = join(d, "s2");
  const r = storeImage(readFileSync(join(d, "a.heic")), { baseDir: base });
  assert.equal(r.format, "heic");
  assert.equal(r.ext, "jpg");
  assert.equal(r.converted, true);
  const p = pathOf(base, r.id, r.ext);
  assert.equal(statSync(p).mode & 0o777, 0o600, "変換が権限を作り直した");
  assert.equal(sniffFormat(readFileSync(p)), "jpg", "heic のまま置かれた");
});

test("★失敗しても .part を残さない", { skip }, () => {
  const d = fixtures(); const base = join(d, "s3");
  const boom = () => { throw new Error("convert-failed"); };
  assert.throws(() => storeImage(readFileSync(join(d, "a.heic")), { baseDir: base, convert: boom }));
  assert.deepEqual(readdirSync(base).filter((n) => n.endsWith(".part")), []);
});

test("★画素数が多すぎる物は置かない(バイト数の門を素通りする圧縮爆弾)", { skip }, () => {
  const d = fixtures(); const base = join(d, "s4");
  const huge = () => ({ w: 100000, h: 100000 });   // 10G 画素
  assert.throws(() => storeImage(readFileSync(join(d, "a.png")), { baseDir: base, measure: huge }),
    /too-many-pixels/);
  assert.deepEqual(readdirSync(base), [], "弾いた物を置き去りにした");
});

test("★画素数が測れない時は置く(測れない事を『大きすぎる』に丸めない)", { skip }, () => {
  const d = fixtures(); const base = join(d, "s5");
  const cant = () => { throw new Error("nope"); };
  const r = storeImage(readFileSync(join(d, "a.png")), { baseDir: base, measure: cant });
  assert.equal(r.ext, "png");
});

test("大きすぎる / 空 / 形式不明は理由を分けて断る", { skip }, () => {
  const d = fixtures(); const base = join(d, "s6");
  assert.throws(() => storeImage(Buffer.alloc(ATTACH_MAX_BYTES + 1, 0x89), { baseDir: base }), /too-large/);
  assert.throws(() => storeImage(Buffer.alloc(0), { baseDir: base }), /empty-body/);
  assert.throws(() => storeImage(Buffer.from("not an image at all here"), { baseDir: base }), /unknown-format/);
});

test("★同じ id へ二度置けない(上書きしない)", { skip }, () => {
  const d = fixtures(); const base = join(d, "s7");
  const id = newAttachmentId();
  const buf = readFileSync(join(d, "a.png"));
  storeImage(buf, { baseDir: base, id });
  assert.throws(() => storeImage(buf, { baseDir: base, id }));
});

// ---- 掃除 ---------------------------------------------------------------------

test("★古い物だけ消す。形の合わない名前には触らない", { skip }, () => {
  const d = fixtures(); const base = join(d, "s8");
  const buf = readFileSync(join(d, "a.png"));
  const old = storeImage(buf, { baseDir: base });
  const fresh = storeImage(buf, { baseDir: base });
  // 他人の物を置いてみる
  writeFileSync(join(base, "important.txt"), "not mine");
  const oldPath = pathOf(base, old.id, old.ext);
  const past = new Date(Date.now() - 30 * 24 * 3600 * 1000);
  utimesSync(oldPath, past, past);

  const r = sweepOld(base, Date.now());
  assert.equal(r.removed, 1);
  assert.ok(existsSync(pathOf(base, fresh.id, fresh.ext)), "新しい物を消した");
  assert.ok(existsSync(join(base, "important.txt")), "★形の合わない名前を巻き込んだ");
});

test("置き場が無くても掃除は落ちない", () => {
  assert.deepEqual(sweepOld("/nonexistent/attach/dir", Date.now()), { removed: 0, kept: 0 });
});

// ---- 上限そのもの --------------------------------------------------------------

test("上限は電話の実物に足りる大きさ", () => {
  // スクリーンショット(この機能の主用途)は 200KB〜2MB、HEIC 写真は 2〜4MB。
  // ★ProRAW(25MB 超)は入らない —— 用途が違うので意図的。
  assert.ok(ATTACH_MAX_BYTES >= 8 * 1024 * 1024);
  assert.ok(ATTACH_MAX_PIXELS >= 12 * 1000 * 1000, "1200万画素の写真が入らない");
});
