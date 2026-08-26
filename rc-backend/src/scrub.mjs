/**
 * scrub.mjs — 画像から**持ち主の居場所と機材**を剥がしてから机に置く。2026-08-26 新設。
 *
 * なぜ要るか(推測ではなく実測)
 *   本物の GPS 付き写真を本番の道で1枚送って、机に着いた物を取り戻して測った:
 *   **GPS 11 項目がそのまま、バイト数も完全一致**(緯度 65°40'58" N)。1バイトも触れていなかった。
 *
 * ★「Tom 自身の機械に Tom 自身の写真を置くだけ」は剥がさない理由にならない。
 *   受け手は**注入され得る LLM で、シェルと外部通信を持っている**。位置情報が読める状態は、
 *   写真を1枚送るたびに「今どこに居るか」を注入経路へ渡しているのと同じ。
 *   実害の大小ではなく、**渡す必要が無い物を渡している**事が問題。
 *
 * ★`sips` の再エンコードでは落ちない(実測: 再エンコード後も GPS 11 項目が残る)。
 *   「変換すれば消える」は**測る前の思い込みで、間違っていた**。だから外科的に外す。
 *
 * ★道具を増やさない。机には exiftool も jpegtran も ImageMagick も Pillow も無い(実測)。
 *   JPEG のマーカー構造は単純で、EXIF は `APP1` の1区画に収まっているので自前で外せる。
 *   PNG も同様に、位置や機材が載りうる補助チャンクだけを落とせる。
 *
 * ★向きは**落とさない**。EXIF を丸ごと捨てると、縦で撮った写真が横倒しで届く。
 *   落とすのは「誰が・いつ・どこで」に当たる物だけで、「どう表示するか」は残す。
 */

/** JPEG のセグメントのうち、丸ごと落とす物。 */
const JPEG_DROP = new Set([
  0xe1, // APP1  = EXIF / XMP(GPS・日時・端末・レンズはここ)
  0xe2, // APP2  = ICC / MPF(複数フレーム。iPhone の写真は付く事がある)
  0xed, // APP13 = Photoshop IRB(IPTC。撮影者・所在地が入りうる)
  0xee, // APP14 = Adobe
  0xfe, // COM   = 自由コメント
]);

/**
 * ★`APP1` を落とすと向きも消えるので、**先に読んで別に返す**。
 * 呼び手はこれを使って回転を焼き込むか、そのまま捨てるかを決める。
 */
export function jpegOrientation(buf) {
  const seg = findJpegApp1(buf);
  if (!seg) return null;
  return readOrientation(buf.subarray(seg.start, seg.end));
}

/**
 * JPEG から素性の載るセグメントを落とす。**画素は1つも触らない**(再エンコードしない)。
 * @returns {{out: Buffer, dropped: string[]}}
 */
export function scrubJpeg(buf) {
  if (!(buf[0] === 0xff && buf[1] === 0xd8)) return { out: buf, dropped: [] };
  const parts = [buf.subarray(0, 2)];
  const dropped = [];
  let i = 2;
  while (i + 3 < buf.length) {
    if (buf[i] !== 0xff) break;                 // マーカーの並びが崩れた = これ以上触らない
    const marker = buf[i + 1];
    // SOS(0xda)以降は圧縮データ本体。**ここから先は絶対に触らない。**
    if (marker === 0xda) { parts.push(buf.subarray(i)); i = buf.length; break; }
    // 長さを持たないマーカー(RSTn / SOI / EOI)
    if (marker === 0xd8 || marker === 0xd9 || (marker >= 0xd0 && marker <= 0xd7)) {
      parts.push(buf.subarray(i, i + 2)); i += 2; continue;
    }
    const len = buf.readUInt16BE(i + 2);
    if (len < 2 || i + 2 + len > buf.length) { parts.push(buf.subarray(i)); i = buf.length; break; }
    if (JPEG_DROP.has(marker)) {
      dropped.push(`APP${marker - 0xe0 >= 0 && marker <= 0xef ? marker - 0xe0 : "?"}:0x${marker.toString(16)}`);
    } else {
      parts.push(buf.subarray(i, i + 2 + len));
    }
    i += 2 + len;
  }
  if (i < buf.length) parts.push(buf.subarray(i));
  return { out: Buffer.concat(parts), dropped };
}

/**
 * PNG から素性の載る補助チャンクを落とす。画素(`IDAT`)と必須チャンクは触らない。
 */
const PNG_DROP = new Set(["tEXt", "zTXt", "iTXt", "eXIf", "tIME"]);

export function scrubPng(buf) {
  const SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (buf.length < 8 || !buf.subarray(0, 8).equals(SIG)) return { out: buf, dropped: [] };
  const parts = [buf.subarray(0, 8)];
  const dropped = [];
  let i = 8;
  while (i + 8 <= buf.length) {
    const len = buf.readUInt32BE(i);
    const type = buf.subarray(i + 4, i + 8).toString("latin1");
    const end = i + 12 + len;                    // len + type(4) + crc(4) + len(4)
    if (end > buf.length) { parts.push(buf.subarray(i)); i = buf.length; break; }
    if (PNG_DROP.has(type)) dropped.push(type);
    else parts.push(buf.subarray(i, end));
    i = end;
    if (type === "IEND") break;
  }
  return { out: Buffer.concat(parts), dropped };
}

/**
 * 形式を見て適切に剥がす。
 * @returns {{out: Buffer, dropped: string[], orientation: number|null}}
 */
export function scrub(buf, format) {
  if (format === "jpg") {
    const orientation = jpegOrientation(buf);
    const r = scrubJpeg(buf);
    return { ...r, orientation };
  }
  if (format === "png") return { ...scrubPng(buf), orientation: null };
  return { out: buf, dropped: [], orientation: null };
}

// ---- EXIF の中身を読むのに必要な最小限 ---------------------------------------

function findJpegApp1(buf) {
  if (!(buf[0] === 0xff && buf[1] === 0xd8)) return null;
  let i = 2;
  while (i + 3 < buf.length) {
    if (buf[i] !== 0xff) return null;
    const marker = buf[i + 1];
    if (marker === 0xda) return null;
    if (marker === 0xd8 || marker === 0xd9 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
    const len = buf.readUInt16BE(i + 2);
    if (len < 2 || i + 2 + len > buf.length) return null;
    if (marker === 0xe1) return { start: i + 4, end: i + 2 + len };
    i += 2 + len;
  }
  return null;
}

/** APP1 の中の TIFF ヘッダを辿って Orientation(0x0112)だけ読む。 */
function readOrientation(app1) {
  if (app1.length < 14) return null;
  if (app1.subarray(0, 6).toString("latin1") !== "Exif\0\0") return null;
  const tiff = app1.subarray(6);
  const le = tiff.subarray(0, 2).toString("latin1") === "II";
  const u16 = (o) => (le ? tiff.readUInt16LE(o) : tiff.readUInt16BE(o));
  const u32 = (o) => (le ? tiff.readUInt32LE(o) : tiff.readUInt32BE(o));
  if (u16(2) !== 42) return null;
  const ifd0 = u32(4);
  if (ifd0 + 2 > tiff.length) return null;
  const n = u16(ifd0);
  for (let k = 0; k < n; k++) {
    const e = ifd0 + 2 + k * 12;
    if (e + 12 > tiff.length) return null;
    if (u16(e) === 0x0112) return u16(e + 8);
  }
  return null;
}
