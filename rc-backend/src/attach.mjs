/**
 * attach.mjs — 電話から来た画像を Mac 上に置き、エージェントに読める形にする。2026-08-26 新設。
 *
 * なぜ要るか(研究 2026-08-26)
 *   **電話でしか出来ない用途**だから。バグが手の中の端末で起きている時、その画面を
 *   机まで持って行かずに送れる。Anthropic 自身のアプリにも未解決の要望として立っている
 *   (anthropics/claude-code#65868)。
 *
 * ★★これは「画像アップロード」ではない(Codex 2026-08-26 の裁定)。実体は
 *   **LLM への非信頼入力 + Mac へのファイル書込み + 端末への入力**が重なった境界で、
 *   3つとも別々に守る必要がある。
 *
 * ★**防げない物を先に書く。** 画像の中に書かれた文字による指示(視覚的プロンプト
 *   インジェクション)は、再エンコードでも画素数制限でも防げない。撮った写真を
 *   エージェントに読ませる以上、その画像は**信頼できない指示の運び手**になり得る。
 *   この層はそれを解決しない。緩和は別の2つが持つ:
 *     1. 承認の危険度分類(`src/risk.mjs`)—— 注入されたエージェントが破壊的操作を
 *        求めた時、その承認カードは赤帯で出る
 *     2. 「電話は安全確認を押さない」という既定(DESIGN §3)
 *   **この注記を消さない。** 消えた瞬間、次の担当は「画像は検証済みだから安全」と読む。
 *
 * 守る物(Codex の必須要件をそのまま):
 *   - `sessionId` を**パスに連結しない**。内部で生成した保管 id へ写す
 *   - 元のファイル名は**完全に無視**。CSPRNG 128bit の basename
 *   - 拡張子は申告ではなく**検証済みの実形式**から決める
 *   - 置き場は 0700、file は 0600、`O_EXCL | O_NOFOLLOW`、親を含め symlink を拒む
 *   - content-type は信じない。**先頭バイトで判定**し、デコードが通る事まで見る
 *   - 圧縮後の大きさとは別に**画素数**の上限を持つ(展開爆弾)
 *   - HEIC はそのまま渡さず JPEG へ変換する
 *   - 応答に**絶対パスを出さない**。`attachmentId` だけ返す
 */
import { randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { closeSync, constants as FS, mkdirSync, openSync, statSync, writeSync,
         lstatSync, readdirSync, unlinkSync, renameSync, realpathSync, chmodSync } from "node:fs";
import { join, dirname } from "node:path";

/** 圧縮後の上限。電話の写真1枚に十分で、置き場が育ちすぎない大きさ。 */
export const ATTACH_MAX_BYTES = 12 * 1024 * 1024;

/** ★展開後の画素数の上限。バイト数だけ見ると圧縮爆弾を通す。 */
export const ATTACH_MAX_PIXELS = 50 * 1000 * 1000;

/** 置いてから消えるまで。エージェントが読む時間より十分長く、溜め込まない長さ。 */
export const ATTACH_TTL_MS = 7 * 24 * 3600 * 1000;

/**
 * 先頭バイトで実形式を決める。**申告は読まない。**
 * 返すのは正規化した拡張子で、これが file 名に載る唯一の外部由来でない値。
 */
export function sniffFormat(buf) {
  if (!buf || buf.length < 16) return null;
  const b = buf;
  // PNG
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "png";
  // JPEG
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "jpg";
  // HEIF/HEIC: ftyp box。brand を見る(`heic` / `heix` / `mif1` / `msf1`)
  if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
    const brand = b.subarray(8, 12).toString("latin1");
    if (["heic", "heix", "hevc", "mif1", "msf1", "heim", "heis"].includes(brand)) return "heic";
  }
  return null;
}

/** 保管 id。**元の名前も sessionId も混ぜない**(パストラバーサルの入口を作らない)。 */
export function newAttachmentId() {
  return randomBytes(16).toString("hex");   // 128 bit
}

/**
 * 置き場の中の絶対パス。**外へ出さない**(応答には id だけ載せる)。
 * id は自分で作った 32 文字の hex だけを受ける —— 呼び手が別の物を渡した時に
 * 黙って外へ出ないよう、ここで形を検める。
 */
export function pathOf(baseDir, id, ext) {
  if (!/^[0-9a-f]{32}$/.test(String(id))) throw new Error("bad-attachment-id");
  if (!/^(png|jpg)$/.test(String(ext))) throw new Error("bad-attachment-ext");
  return join(baseDir, `${id}.${ext}`);
}

/**
 * 置き場までの道に**張り替え**が無い事を確かめる。
 *
 * ★根まで遡らない(2026-08-26 実測で直した)。macOS では `/var` 自体が
 *   `/private/var` への symlink なので、`/` まで遡る版は**どの一時ディレクトリでも
 *   必ず落ちる** —— 正しそうに見えて一度も使えない検査だった。
 *   脅威は OS が持つ正規の symlink ではなく、**自分が作る段が誰かに張り替えられる事**。
 *   だから信頼する根(`root`)を実体解決し、そこから下の段だけを見る。
 *
 * @param {string} baseDir 置き場
 * @param {string} root ここより上は見ない(既定 = baseDir の親の実体)
 */
export function assertNoSymlinkOnPath(baseDir, root) {
  const anchor = root ?? dirname(baseDir);
  let realAnchor;
  try { realAnchor = realpathSync(anchor); }
  catch (e) {
    if (e.code !== "ENOENT") throw e;
    return;                       // 根がまだ無い = 段は全部これから自分で作る
  }
  // ★解決後の置き場が、解決後の根の**下に居る**事。ここが本題 —— 途中の段が
  //   張り替えられていれば、実体解決した結果は根の外へ出る。
  const rel = baseDir.slice(anchor.length);
  const target = join(realAnchor, rel);
  let cur = target;
  const stop = realAnchor;
  const seen = new Set();
  while (cur && cur !== stop && cur !== "/" && !seen.has(cur)) {
    seen.add(cur);
    try {
      if (lstatSync(cur).isSymbolicLink()) throw new Error(`symlink-on-path:${cur}`);
    } catch (e) {
      if (String(e.message).startsWith("symlink-on-path")) throw e;
      if (e.code !== "ENOENT") throw e;
    }
    cur = dirname(cur);
  }
}

/** 置き場を用意する。0700。 */
export function ensureBaseDir(baseDir) {
  assertNoSymlinkOnPath(baseDir);
  mkdirSync(baseDir, { recursive: true, mode: 0o700 });
  const st = statSync(baseDir);
  if (!st.isDirectory()) throw new Error("base-not-directory");
  return baseDir;
}

/**
 * 画像を検めて置く。
 *
 * @param {Buffer} buf 受け取った生バイト
 * @param {{baseDir:string, convert?:Function, id?:string}} o
 *   `convert` は差し替え口(検査で本物の sips を撃たない為)。既定は macOS の sips。
 * @returns {{id:string, ext:string, bytes:number, format:string, converted:boolean}}
 * @throws Error("too-large"|"unknown-format"|"too-many-pixels"|"convert-failed"|...)
 */
export function storeImage(buf, o) {
  const baseDir = o?.baseDir;
  if (!baseDir) throw new Error("no-base-dir");
  if (!buf || !buf.length) throw new Error("empty-body");
  if (buf.length > ATTACH_MAX_BYTES) throw new Error("too-large");

  const format = sniffFormat(buf);
  // ★申告した content-type は一切見ていない。ここで null = 中身が画像として読めない。
  if (!format) throw new Error("unknown-format");

  ensureBaseDir(baseDir);
  const id = o?.id ?? newAttachmentId();
  const convert = o?.convert ?? sipsConvert;

  // まず生のまま一時名で置く(検めるにはファイルが要る)。
  const tmp = pathOf(baseDir, id, format === "heic" ? "jpg" : format) + ".part";
  writeExclusive(tmp, buf);

  let finalExt = format === "heic" ? "jpg" : format;
  let converted = false;
  try {
    if (format === "heic") {
      // ★HEIC はそのまま渡さない。エージェント側の対応が不安定で、向き・色域・
      //   複数フレーム・GPS 等の付随情報も付いて回る(Codex 2026-08-26)。
      convert(tmp, tmp, "jpeg");
      converted = true;
    }
    const px = pixelsOf(tmp, o?.measure);
    // ★バイト数とは別に画素数を見る。圧縮爆弾はバイト数の門を素通りする。
    if (px !== null && px > ATTACH_MAX_PIXELS) throw new Error("too-many-pixels");

    const dest = pathOf(baseDir, id, finalExt);
    renameExclusive(tmp, dest);
    // ★変換が権限を作り直す(2026-08-26 実測: `sips --out` の後は umask 既定の 644 に
    //   戻っていて、0600 で開いた意味が消えていた)。置いた後に**もう一度**締める。
    //   検査は「置いた物の mode が 0600」で見る —— 開き方ではなく結果を測る。
    chmodSync(dest, 0o600);
    return { id, ext: finalExt, bytes: statSync(dest).size, format, converted };
  } catch (e) {
    try { unlinkSync(tmp); } catch { /* 置きっぱなしにしない */ }
    throw e;
  }
}

/** `O_EXCL | O_NOFOLLOW` で開いて 0600 で書く。既に在れば失敗する(上書きしない)。 */
function writeExclusive(path, buf) {
  const flags = FS.O_WRONLY | FS.O_CREAT | FS.O_EXCL | FS.O_NOFOLLOW;
  const fd = openSync(path, flags, 0o600);
  try { writeSync(fd, buf); } finally { closeSync(fd); }
}

function renameExclusive(from, to) {
  // rename は宛先が在れば黙って上書きするので、先に無い事を確かめる。
  try { lstatSync(to); throw new Error("destination-exists"); }
  catch (e) { if (e.code !== "ENOENT") throw e; }
  renameSync(from, to);
}

/** 画素数。読めなければ null(**0 ではない** = 測れなかった)。 */
function pixelsOf(path, measure) {
  const m = measure ?? sipsMeasure;
  try {
    const { w, h } = m(path);
    if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) return null;
    return w * h;
  } catch { return null; }
}

function sipsMeasure(path) {
  // ★`killSignal: "SIGKILL"`(既存の錨 sync-exec-timeout.test.mjs が掴んだ)。
  //   `execFileSync` の既定は SIGTERM で、**TERM を握り潰す子には timeout が効かない**
  //   = 上限を書いたのに戻って来ない。画像デコーダは壊れた入力で固まり得るので、
  //   ここは実際に起こる話であって理屈ではない。
  const out = execFileSync("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", path],
    { encoding: "utf8", timeout: 15000, killSignal: "SIGKILL" });
  const w = Number(/pixelWidth:\s*(\d+)/.exec(out)?.[1]);
  const h = Number(/pixelHeight:\s*(\d+)/.exec(out)?.[1]);
  return { w, h };
}

function sipsConvert(from, to, fmt) {
  // 同上。変換は測定より長く掛かるので上限は緩いが、効かない上限は上限ではない。
  execFileSync("/usr/bin/sips", ["-s", "format", fmt, from, "--out", to],
    { encoding: "utf8", timeout: 60000, killSignal: "SIGKILL" });
}

/**
 * 古い添付を消す。**置き場の中の、形の合う名前だけ**を消す。
 * ★`readdir` の結果をそのまま join して消さない —— 置き場に別の物が紛れていた時に
 *   巻き込む。名前が自分の形式に一致する物だけが対象。
 */
export function sweepOld(baseDir, nowMs, ttlMs = ATTACH_TTL_MS) {
  let removed = 0, kept = 0;
  let names;
  try { names = readdirSync(baseDir); } catch { return { removed: 0, kept: 0 }; }
  for (const n of names) {
    if (!/^[0-9a-f]{32}\.(png|jpg)(\.part)?$/.test(n)) { kept++; continue; }
    const p = join(baseDir, n);
    try {
      const st = lstatSync(p);
      if (!st.isFile()) { kept++; continue; }        // symlink や dir は触らない
      if (nowMs - st.mtimeMs > ttlMs) { unlinkSync(p); removed++; } else kept++;
    } catch { kept++; }
  }
  return { removed, kept };
}
