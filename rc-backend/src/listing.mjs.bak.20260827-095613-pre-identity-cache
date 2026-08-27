// 一覧を作る為の**有界読み**。`/api/sessions` の下回り。
//
// なぜ要るか(実測 2026-08-02、MBP・キャッシュ温、1リクエスト分):
//   走査した jsonl 1,644本 / `readFileSync(...,"utf8")` 合計 3,062 MB / 9,530 ms /
//   rss 1,489 MB。最大の1本が 280.1 MB。**電話が一覧を開くたびに毎回これを払っていた**。
//   合格条件4「Loading で待たされない」は、既存 RC を却下した理由そのもの(DESIGN §4)。
//
// さらに二次の穴があった: JS 文字列の上限は 536,870,888 文字(MBP v22.14.0 /
// edith v25.9.0 で同値を実測)。280 MB は上限の約 55% で、超えた時の
// `ERR_STRING_TOO_LONG` は呼び手の `catch { continue; }` が飲むので、
// **一番長い会話だけが警告なく一覧から消える**。有界読みにすると、この事象は
// 「巨大 = 読めない」ではなくなり **クラスごと消える**(Codex 指摘 2026-08-02)。
//
// ★この module が引き受ける難しさ: **ファイルの一部しか読まずに、嘘をつかない事**。
//   - 欲しい行が読んだ範囲に無いかもしれない → `metadataIncomplete` で正直に言う
//   - 全部読み切った時だけ「無い」と断言してよい
//   - `turns`(user 行の数)は部分読みでは正確に出せない → **null**。それらしい数を置かない
//
// ★なぜ「先頭から entrypoint を読む」を**やめた**か(実測 2026-08-02、1,644本):
//   最初は head 16KB + tail という形で書いた。書いてから測ったら、
//   **`"entrypoint"` が先頭 16KB の外にあるファイルが 345本(21%)** あった(最遠 676KB)。
//   原因は「ヘッダが深い」ではない — 画像を貼った最初の発言が 1行 676KB になり、
//   `entrypoint` はその行の**末尾側のキー**だから。head 予算を増やす対処は青天井になる。
//   代わりに測ったのが下の3つ:
//     - `entrypoint` は**全ての本線 user レコードに付く**(sidechain 28,512本中 0本 = 付かない)
//     - EOF からの距離は p99 0.9KB / 最遠 199KB → **末尾側から必ず取れる**
//     - head と tail で `entrypoint` が食い違うファイルは **0本**
//   なので head 読みは丸ごと不要になった(1ファイルあたりの読みも1回減る)。
//   ★副作用として `cwd` の意味が変わる: 1,644本中 90本で先頭と末尾の cwd が違い、
//     全て「本線で `cd` した」= 起動地(`/Users/tomtim`)より**現在地**が出る。
//     電話の一覧としては現在地の方が正しいので、この変化は採る(DESIGN §2.11)。
import { closeSync, fstatSync, openSync, readSync } from "node:fs";

export const TAIL_CHUNK = 64 * 1024; // 後方探索の1歩
export const TAIL_MAX = 1024 * 1024; // 後方へ遡る上限。これを超えたら incomplete と言う

/**
 * 後方チャンクを、完全な行と**持ち越し**に分ける。
 *
 * チャンクの先頭は行の途中から始まっている(`atFileStart` の時を除く)。その断片は
 * **1つ前(より手前)のチャンクの末尾に繋がる**ので、捨てずに返して次の読みで前置きする。
 * ★捨てると、チャンク境界を跨いだレコードが**どのチャンクからも見えなくなり**、
 *   `ai-title` を「無い」と誤って断言する経路ができる(黙って間違える形なので致命的)。
 *
 * 改行 0x0A は UTF-8 多バイト文字の一部にならないので、ここで切る限り文字は割れない。
 *
 * @param {Buffer} buf
 * @param {boolean} atFileStart このチャンクがファイル先頭から始まっているか
 * @returns {{lines: string[], carry: Buffer}} carry = 手前のチャンクへ繋ぐ断片
 */
export function tailLines(buf, atFileStart) {
  let start = 0;
  if (!atFileStart) {
    const nl = buf.indexOf(0x0a);
    if (nl < 0) return { lines: [], carry: buf }; // 完全な行が1つも無い = 全部が断片
    start = nl + 1;
  }
  return {
    lines: buf.subarray(start).toString("utf8").split("\n").filter((l) => l !== ""),
    carry: buf.subarray(0, start),
  };
}

/**
 * 末尾側の行から一覧用の4項目を採る。**後ろから見て最初に当たった物が答え**
 * (jsonl は追記なので、後の行が新しい = 勝つ)。
 *
 * @param {string[]} lines 前から順に並んだ行
 * @returns {{entrypoint:string|null, cwd:string|null, title:string|null, lastPrompt:string|null}}
 */
export function parseTailMeta(lines) {
  let entrypoint = null;
  let cwd = null;
  let title = null;
  let lastPrompt = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (entrypoint !== null && lastPrompt !== null && title !== null) break;
    const line = lines[i];
    // 高価な parse の前に安いフィルタ。キー名は JSON 内で必ず引用符付きで現れる。
    const wantsEntry = entrypoint === null && line.includes('"entrypoint"');
    const wantsTitle = title === null && line.includes('"ai-title"');
    const wantsPrompt = lastPrompt === null && line.includes('"last-prompt"');
    if (!wantsEntry && !wantsTitle && !wantsPrompt) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue; // 壊れた行 / 書き込み途中の行で一覧を落とさない
    }
    if (wantsEntry && typeof obj.entrypoint === "string") {
      entrypoint = obj.entrypoint;
      cwd = typeof obj.cwd === "string" ? obj.cwd : null;
    }
    if (wantsTitle && obj.type === "ai-title" && typeof obj.aiTitle === "string") title = obj.aiTitle;
    if (wantsPrompt && obj.type === "last-prompt" && typeof obj.lastPrompt === "string") lastPrompt = obj.lastPrompt;
  }
  return { entrypoint, cwd, title, lastPrompt };
}

/**
 * 開いた fd から一覧用メタを採る。**同じ fd の `fstat` を正とする**
 * (`stat` の後に開くと、その間の追記 / truncate / rotate でサイズと中身がずれる)。
 *
 * ★遡るのを止める条件に **`ai-title` を入れてはいけない**。実測(1,644本):
 *   **1,252本(76%)には `ai-title` が最初から無い**(4MB 遡っても無い)。
 *   「3つ揃うまで遡る」形にすると、その 76% が毎回 TAIL_MAX を読み切る = 置き換える前と
 *   大差ない I/O になる。だから止める条件は `entrypoint` と `lastPrompt` だけ
 *   (どちらも p99 で EOF から 0.9KB 以内)。`ai-title` は**そのついでに拾う**:
 *   読んだチャンクに在れば採るし、無ければ null のまま返る。
 *   ★null は「無い」ではないので `metadataIncomplete` の判定材料にもしない —
 *   `resolveTitle` が lastPrompt に落ちるだけで、「タイトルは無い」と主張する経路にはならない。
 *   (最初ここを「64KB の窓の中でだけ探す」と書いた。76% 欠落と最遠 32.4KB という測定は
 *    本物だが、**それが支えるのは「止める条件に入れるな」であって「窓を作れ」ではなかった**。
 *    窓を入れると、窓の縁を跨いだ ai-title が組み立て途中で探索対象から外れて消える —
 *    実際 test/listing.test.mjs の境界検査2件がそれを捕まえた。)
 *
 * @param {object} io { fstat, read }
 * @param {number} fd
 * @param {object} [opts]
 * @returns {{entrypoint, cwd, title, lastPrompt, turns, size, metadataIncomplete, wholeFile}}
 *   `turns` は常に null。部分読みで正確な数は出せないので**数を発明しない**。
 *   `metadataIncomplete` = 上限まで遡っても一覧に要る物が揃わなかった(= 無いのか、
 *   予算の外なのかを**区別できない**)。全部読み切った時だけ false で、その時の null は「無い」。
 */
export function readMetaFromFd(io, fd, opts = {}) {
  const r = readLinesBackward(io, fd, {
    chunk: opts.tailChunk ?? TAIL_CHUNK,
    maxBytes: opts.tailMax ?? TAIL_MAX,
    // ★止める条件に ai-title を入れない(上の注記)。この2つが揃えば一覧は組める。
    done: (lines) => {
      const m = parseTailMeta(lines);
      return m.entrypoint !== null && m.lastPrompt !== null;
    },
  });
  const m = parseTailMeta(r.lines);
  return {
    ...m,
    turns: null,
    size: r.size,
    // ファイル先頭まで遡り切った時だけ「無い」と断言できる。
    // 上限で打ち切った時の null は「見つけられなかった」であって「無い」ではない。
    metadataIncomplete: !r.reachedStart && (m.entrypoint === null || m.lastPrompt === null),
    wholeFile: r.reachedStart,
  };
}

/**
 * ファイルの末尾から、チャンク単位で**完全な行だけ**を遡って集める。
 * 一覧(4項目)も履歴(直近 N 件)も、欲しい物が違うだけで読み方は同じなので
 * ここ1箇所に置く — 持ち越し・短い read・多バイト境界の扱いを2箇所に書かない。
 *
 * @param {object} io { fstat, read }
 * @param {number} fd
 * @param {object} [o]
 * @param {number} [o.chunk] 1歩の大きさ
 * @param {number} [o.maxBytes] 遡る上限。超えたら reachedStart=false のまま返る
 * @param {(lines:string[]) => boolean} [o.done] 十分集まったか。既定は1歩で止める
 * @returns {{lines:string[], reachedStart:boolean, scanned:number, size:number}}
 *   lines は**古い順**(ファイルの並びのまま)。reachedStart=false は「これより前がある」。
 */
export function readLinesBackward(io, fd, o = {}) {
  const chunk = o.chunk ?? TAIL_CHUNK;
  const maxBytes = o.maxBytes ?? TAIL_MAX;
  const done = o.done ?? (() => true);
  const size = io.fstat(fd).size;

  // 短く返ってきたら続きを読む。★1回で満たされる前提にすると、後方チャンクと
  // 持ち越しの間に**穴**が開き(持ち越しは pos+len から始まる物なので)、
  // 繋いだ buffer が実ファイルと違う並びになる = 黙って間違える形。
  const read = (len, pos) => {
    const b = Buffer.alloc(len);
    let got = 0;
    while (got < len) {
      const n = io.read(fd, b.subarray(got), pos + got);
      if (n <= 0) break; // EOF
      got += n;
    }
    return b.subarray(0, got);
  };

  // 各チャンクの先頭断片は捨てず、次(より手前)のチャンクの末尾に繋ぐ
  // — 境界を跨いだレコードを取りこぼさない為。
  let lines = [];
  let scanned = 0;
  let reachedStart = false;
  let carry = Buffer.alloc(0);
  while (scanned < maxBytes) {
    const step = Math.min(chunk, size - scanned);
    if (step <= 0) {
      reachedStart = true;
      break;
    }
    const pos = size - scanned - step;
    const raw = read(step, pos);
    // 読めた量が足りない = 読んでいる最中に切り詰められた。持ち越しは pos+step から
    // 始まる物なので、ここで繋ぐと**存在しない並び**を作る。繋がず捨てる方が正しい。
    const buf = carry.length > 0 && raw.length === step ? Buffer.concat([raw, carry]) : raw;
    const got = tailLines(buf, pos === 0);
    carry = got.carry;
    lines = got.lines.concat(lines); // 手前のチャンクほど前に積む = 古い順を保つ
    scanned += step;
    if (pos === 0) {
      reachedStart = true;
      break;
    }
    if (done(lines)) break;
  }
  return { lines, reachedStart, scanned, size };
}

/** 本物の fs。test で偽物に差し替えられる様に、ここ以外に `readSync` を書かない。 */
export const nodeIo = {
  fstat: (fd) => fstatSync(fd),
  read: (fd, buf, pos) => readSync(fd, buf, 0, buf.length, pos),
};

/**
 * パスから一覧用メタを採る。**開いてから `fstat`**(`stat` → `open` の順にすると、
 * その隙間の rotate で別のファイルの中身に前のサイズを当てる事になる)。
 */
export function readMetaFromPath(path, opts = {}) {
  const fd = openSync(path, "r");
  try {
    return readMetaFromFd(opts.io ?? nodeIo, fd, opts);
  } finally {
    closeSync(fd);
  }
}

/**
 * 読んだ結果を覚える。同じ木を2回読まない。
 * 鍵に dev/ino を入れるのは、同じパスが別のファイルに差し替わった時に
 * 前の中身を返さない為(`tail.mjs` の世代判定と同じ理由)。
 */
export class MetaCache {
  constructor({ max = 2000 } = {}) {
    this.max = max;
    this.map = new Map();
  }

  static keyOf(st) {
    return `${st.dev}-${st.ino}-${st.size}-${Math.round(st.mtimeMs)}`;
  }

  get(key) {
    if (!this.map.has(key)) return null;
    const v = this.map.get(key);
    this.map.delete(key); // 触った物を末尾へ(素朴な LRU)
    this.map.set(key, v);
    return v;
  }

  set(key, value) {
    if (this.map.has(key)) this.map.delete(key);
    this.map.set(key, value);
    while (this.map.size > this.max) this.map.delete(this.map.keys().next().value);
    return value;
  }

  get size() {
    return this.map.size;
  }
}
