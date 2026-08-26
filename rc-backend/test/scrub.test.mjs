import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { scrub, scrubJpeg, scrubPng, jpegOrientation } from "../src/scrub.mjs";

// ★検体は**本物の GPS 付き写真**(simulator の写真ライブラリから縮めた物、GPS 11 項目)。
//   手で組んだ EXIF で測ると「EXIF の形についての自分の思い込み」ごと緑になる。
//   実際、この機能は「sips の再エンコードで落ちる」という**測る前の思い込みが間違って
//   いた**所から始まっている(再エンコード後も GPS 11 項目が残っていた)。
const FIX = join(process.cwd(), "test", "fixtures", "photos", "gps-real.jpg");
const skip = existsSync(FIX) ? false : "検体が無い機体 = 測っていない";

/** EXIF/GPS が本当に消えたかを、**この file の外**(生バイト)で確かめる。 */
function hasExifMarker(buf) {
  for (let i = 0; i + 1 < buf.length; i++) {
    if (buf[i] === 0xff && buf[i + 1] === 0xe1) return true;
  }
  return false;
}
function containsAscii(buf, s) {
  return buf.includes(Buffer.from(s, "latin1"));
}

test("★本物の写真から EXIF セグメントが消える", { skip }, () => {
  const raw = readFileSync(FIX);
  assert.ok(hasExifMarker(raw), "検体に EXIF が無い = この検査は空振りしている");
  assert.ok(containsAscii(raw, "Exif"), "検体に Exif ヘッダが無い");

  const r = scrubJpeg(raw);
  assert.ok(!hasExifMarker(r.out), "APP1 が残っている");
  assert.ok(!containsAscii(r.out, "Exif"), "Exif ヘッダが残っている");
  assert.ok(r.dropped.length > 0, "何も落としていないのに緑になった");
});

test("★画素は1バイトも触らない(再エンコードしない)", { skip }, () => {
  const raw = readFileSync(FIX);
  const r = scrubJpeg(raw);
  // 圧縮データ本体(SOS 以降)がそのまま在る事。ここが変わっていたら再エンコードしている。
  const sosOf = (b) => {
    for (let i = 2; i + 1 < b.length; i++) if (b[i] === 0xff && b[i + 1] === 0xda) return i;
    return -1;
  };
  const a = raw.subarray(sosOf(raw));
  const c = r.out.subarray(sosOf(r.out));
  assert.ok(a.length > 1000, "SOS が見つからない");
  assert.ok(a.equals(c), "圧縮データが変わった = 画素を触っている");
});

test("★向きは剥がす**前に**読める(読んでから捨てる)", { skip }, () => {
  const raw = readFileSync(FIX);
  const o = jpegOrientation(raw);
  assert.ok(o === null || (Number.isInteger(o) && o >= 1 && o <= 8), `向きが変: ${o}`);
  // 剥がした後は読めない = 呼び手が先に読む契約である事の裏取り。
  assert.equal(jpegOrientation(scrubJpeg(raw).out), null);
});

test("★JPEG でない物を JPEG として壊さない", () => {
  const notJpeg = Buffer.from("hello world, not an image at all");
  const r = scrubJpeg(notJpeg);
  assert.ok(r.out.equals(notJpeg), "画像でない物を書き換えた");
  assert.deepEqual(r.dropped, []);
});

test("★壊れた JPEG(長さが嘘)でも落ちず、残りを捨てない", () => {
  const b = Buffer.concat([
    Buffer.from([0xff, 0xd8]),
    Buffer.from([0xff, 0xe1, 0xff, 0xff]),   // 長さが本体より大きい
    Buffer.from("tail-data-that-must-survive", "latin1"),
  ]);
  const r = scrubJpeg(b);
  assert.ok(containsAscii(r.out, "tail-data-that-must-survive"),
    "長さが壊れた所で残りを捨てた = データを失う直し方になっている");
});

test("PNG の素性チャンクだけ落とし、画素チャンクは残す", () => {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const chunk = (type, payload) => {
    const b = Buffer.alloc(12 + payload.length);
    b.writeUInt32BE(payload.length, 0);
    b.write(type, 4, "latin1");
    payload.copy(b, 8);
    return b;
  };
  const png = Buffer.concat([
    sig,
    chunk("IHDR", Buffer.alloc(13)),
    chunk("tEXt", Buffer.from("Comment\0secret location", "latin1")),
    chunk("eXIf", Buffer.from("Exif\0\0gps", "latin1")),
    chunk("IDAT", Buffer.from("PIXELS", "latin1")),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  const r = scrubPng(png);
  assert.ok(!containsAscii(r.out, "secret location"), "tEXt が残った");
  assert.ok(!containsAscii(r.out, "Exif"), "eXIf が残った");
  assert.ok(containsAscii(r.out, "PIXELS"), "★画素チャンクを落とした");
  assert.ok(containsAscii(r.out, "IHDR"), "★必須チャンクを落とした");
  assert.deepEqual(r.dropped.sort(), ["eXIf", "tEXt"]);
});

test("PNG でない物を PNG として壊さない", () => {
  const b = Buffer.from("not a png at all, really");
  assert.ok(scrubPng(b).out.equals(b));
});

test("★知らない形式は素通しする(黙って壊さない)", () => {
  const b = Buffer.from("some other format");
  const r = scrub(b, "heic");
  assert.ok(r.out.equals(b));
  assert.deepEqual(r.dropped, []);
});

test("★空振り防止: 落とす対象が1つも無い JPEG では dropped が空", () => {
  // SOI + SOS だけの最小 JPEG。落とす物が無い事を「落とせた」と読まない。
  const b = Buffer.concat([Buffer.from([0xff, 0xd8]), Buffer.from([0xff, 0xda, 0x00, 0x02]), Buffer.from("x")]);
  const r = scrubJpeg(b);
  assert.deepEqual(r.dropped, []);
  assert.ok(r.out.equals(b), "落とす物が無いのに書き換えた");
});

test("★★ICC プロファイルは残す(色を変えない)", { skip }, () => {
  // 2026-08-26 の回帰: 最初は APP2 を丸ごと落としていて、ICC 3144 bytes が消えていた。
  // agent が見る色が撮った時と違う = バグの見え方が変わる。Codex も「ICC は残せ」。
  const raw = readFileSync(FIX);
  assert.ok(containsAscii(raw, "ICC_PROFILE"), "検体に ICC が無い = この検査は空振りしている");
  const r = scrubJpeg(raw);
  assert.ok(containsAscii(r.out, "ICC_PROFILE"), "★ICC を落とした = 色が変わる");
});

test("★ICC でない APP2(MPF 等)は落とす", () => {
  // APP2 は識別子で中身が違う。ICC だけを通し、それ以外は通す理由が無い。
  const app2 = (id) => {
    const payload = Buffer.concat([Buffer.from(id, "latin1"), Buffer.from("payloadbytes")]);
    const seg = Buffer.alloc(4 + payload.length);
    seg[0] = 0xff; seg[1] = 0xe2;
    seg.writeUInt16BE(payload.length + 2, 2);
    payload.copy(seg, 4);
    return seg;
  };
  const build = (id) => Buffer.concat([
    Buffer.from([0xff, 0xd8]), app2(id),
    Buffer.from([0xff, 0xda, 0x00, 0x02]), Buffer.from("pixels"),
  ]);
  assert.ok(containsAscii(scrubJpeg(build("ICC_PROFILE\0")).out, "payloadbytes"), "ICC を落とした");
  assert.ok(!containsAscii(scrubJpeg(build("MPF\0")).out, "payloadbytes"), "MPF を残した");
  assert.ok(!containsAscii(scrubJpeg(build("????????????")).out, "payloadbytes"),
    "識別子の読めない APP2 を通した(何か分からない物を通す理由が無い)");
});
