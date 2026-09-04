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
 * `tailLines` と同じ切り方で、各行の **file 内の byte 位置** も返す(2026-09-03、対照表 #3)。
 * `base` = `buf[0]` が file の何 byte 目か。位置は行の先頭 byte で、追記しか起きない jsonl では
 * 一度付いた位置が変わらない = 電話が「其の行へ跳ぶ」為の錨に使える。
 * 空行は `tailLines` と同じく飛ばす(位置も付けない)。
 */
export function tailLinesWithOffsets(buf, atFileStart, base) {
  let start = 0;
  if (!atFileStart) {
    const nl = buf.indexOf(0x0a);
    if (nl < 0) return { lines: [], offsets: [], carry: buf };
    start = nl + 1;
  }
  const lines = [];
  const offsets = [];
  let i = start;
  while (i < buf.length) {
    let j = buf.indexOf(0x0a, i);
    if (j < 0) j = buf.length;
    if (j > i) {
      lines.push(buf.subarray(i, j).toString("utf8"));
      offsets.push(base + i);
    }
    i = j + 1;
  }
  return { lines, offsets, carry: buf.subarray(0, start) };
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
 * @param {number} [o.end] 走査の境界。渡すと此処を**あたかも file の末尾であるかのように**
 *   扱って遡る(2026-09-03、窓読み。対照表 #3 の続き)。既定は本物の file size で、その時の
 *   挙動は此のオプションが無かった頃と1 byte も変わらない —— 錨から**手前**だけを読みたい
 *   呼び手(`readHistoryAround`)が、持ち越し・短い read・多バイト境界の扱いを2箇所目に
 *   書かずに済む為だけに居る。
 * @param {(lines:string[]) => boolean} [o.done] 十分集まったか。既定は1歩で止める
 * @returns {{lines:string[], reachedStart:boolean, scanned:number, size:number}}
 *   lines は**古い順**(ファイルの並びのまま)。reachedStart=false は「これより前がある」。
 *   `size` は常に本物の file size(`end` を渡しても変わらない —— 境界は走査だけに効く)。
 */
export function readLinesBackward(io, fd, o = {}) {
  const chunk = o.chunk ?? TAIL_CHUNK;
  const maxBytes = o.maxBytes ?? TAIL_MAX;
  const done = o.done ?? (() => true);
  const size = io.fstat(fd).size;
  const end = Math.min(o.end ?? size, size);

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
  let offsets = []; // lines[i] の file 内 byte 位置(対照表 #3 の錨。`lines` と同じ並び)
  let scanned = 0;
  let reachedStart = false;
  let carry = Buffer.alloc(0);
  while (scanned < maxBytes) {
    const step = Math.min(chunk, end - scanned);
    if (step <= 0) {
      reachedStart = true;
      break;
    }
    const pos = end - scanned - step;
    const raw = read(step, pos);
    // 読めた量が足りない = 読んでいる最中に切り詰められた。持ち越しは pos+step から
    // 始まる物なので、ここで繋ぐと**存在しない並び**を作る。繋がず捨てる方が正しい。
    const buf = carry.length > 0 && raw.length === step ? Buffer.concat([raw, carry]) : raw;
    // `buf` の先頭は file の `pos` byte 目(持ち越しは raw の**後ろ**に繋がるので base は変わらない)
    const got = tailLinesWithOffsets(buf, pos === 0, pos);
    carry = got.carry;
    lines = got.lines.concat(lines); // 手前のチャンクほど前に積む = 古い順を保つ
    offsets = got.offsets.concat(offsets);
    scanned += step;
    if (pos === 0) {
      reachedStart = true;
      break;
    }
    if (done(lines)) break;
  }
  return { lines, offsets, reachedStart, scanned, size };
}

/**
 * ファイルの `o.start` byte から**前方**へ、チャンク単位で完全な行だけを集める
 * (2026-09-03、窓読み。`readLinesBackward` の対)。
 *
 * ★`o.start` は**行の先頭**でなければならない(呼び手 `readHistoryAround` が錨を検証してから
 *   渡す)。途中から読み始めると、最初に見付ける「完全な行」が実在しない継ぎ目になる。
 * ★`readLinesBackward` と対称な構造だが使い回さない —— 後方は「チャンクの**先頭**断片が
 *   前のチャンクに繋がる持ち越し」、前方は「チャンクの**末尾**断片が次のチャンクに繋がる
 *   持ち越し」で、繋ぐ向きが逆(`tailLinesWithOffsets` は後方専用の形)。
 *
 * @param {object} io { fstat, read }
 * @param {number} fd
 * @param {object} [o]
 * @param {number} [o.start] 読み始める byte 位置(既定 0。行頭である事は呼び手の責任)
 * @param {number} [o.chunk] 1歩の大きさ
 * @param {number} [o.maxBytes] 読む上限。超えたら reachedEnd=false のまま返る
 * @param {(lines:string[]) => boolean} [o.done] 十分集まったか。既定は1歩で止める
 * @returns {{lines:string[], offsets:number[], reachedEnd:boolean, scanned:number}}
 *   lines は**古い順**(ファイルの並びのまま)。reachedEnd=false は「これより後がある」。
 */
export function readLinesForward(io, fd, o = {}) {
  const chunk = o.chunk ?? TAIL_CHUNK;
  const maxBytes = o.maxBytes ?? TAIL_MAX;
  const done = o.done ?? (() => true);
  const size = io.fstat(fd).size;
  const start = o.start ?? 0;

  // `readLinesBackward` の `read` と同じ理由で同じ形(短く返れば続きを読む)。
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

  let lines = [];
  let offsets = [];
  let scanned = 0;
  let reachedEnd = false;
  let carry = Buffer.alloc(0); // 未完の断片(次の chunk で完成するかもしれない行の先頭)
  let carryBase = start; // carry の file 内 byte 位置
  let pos = start;
  while (scanned < maxBytes) {
    const step = Math.min(chunk, size - pos);
    if (step <= 0) {
      reachedEnd = true; // pos が size に届いた = 末尾まで読み切った
      break;
    }
    const raw = read(step, pos);
    // 読めた量が足りない(=読んでいる最中に切り詰められた)時は持ち越しを繋がない
    // (`readLinesBackward` と同じ理由 —— 繋ぐと存在しない並びを作る)。
    const buf = carry.length > 0 && raw.length === step ? Buffer.concat([carry, raw]) : raw;
    const base = carry.length > 0 && raw.length === step ? carryBase : pos;
    let i = 0;
    let j;
    while ((j = buf.indexOf(0x0a, i)) >= 0) {
      if (j > i) {
        lines.push(buf.subarray(i, j).toString("utf8"));
        offsets.push(base + i);
      }
      i = j + 1;
    }
    carry = buf.subarray(i);
    carryBase = base + i;
    pos += step;
    scanned += step;
    if (pos >= size) {
      reachedEnd = true;
      break;
    }
    if (done(lines)) break;
  }
  // ★改行無しで終わる最終行(または EOF)は、**本当に末尾まで読み切った時だけ**1行として拾う。
  //   予算切れ(reachedEnd=false)の時に拾うと、続きが在るかもしれない断片を完成した行として
  //   混ぜる事になる。
  if (reachedEnd && carry.length > 0) {
    lines.push(carry.toString("utf8"));
    offsets.push(carryBase);
  }
  return { lines, offsets, reachedEnd, scanned };
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
 *
 * ★2026-08-27 に作り直した。旧形(版を鍵にした素朴な LRU)は **本番で一度も効いて
 *   いなかった**。friday 実測、5要求連続で `files=10303 read=10303 cached=0`、毎回 470ms。
 *   理由は2つ在って、どちらか片方だけ直しても戻る:
 *
 *   1. **上限 4000 < 走査対象 10303**。走査は毎回頭から回るので、LRU は
 *      「次に要る物を必ず直前に捨てる」= 構造的にヒット率 0。上限を 40000 にする実験で
 *      470ms -> 60ms / cached 0 -> 10303 を観測(= 原因の確定)。
 *   2. **鍵に size と mtime が入っていた**ので、追記される度に**別の entry が増え**、
 *      古い版が残り続ける。上限を上げるだけでは、書き込みの多い機体で余白が版に
 *      食い潰されて同じ雪崩が戻る(Codex 2026-08-27。私はこれを見落としていた)。
 *
 *   新形は **生きた file の同一性 `dev+ino`** を鍵にし、指紋(size/mtime)は値に持つ:
 *   - 指紋が変われば値を**置き換える** = 1 file 1 entry。版は積み上がらない。
 *   - `beginScan()` で世代を進め、走査を**最後まで**回れた時だけ `sweep()` で
 *     今回見なかった entry を落とす。消えた file を永久に抱えない。
 *   - `ensureCapacity()` は**読む前**に呼ぶ。読み終えてから上げても、その回は既に
 *     全部捨てた後なので効かない(Codex 指摘)。下げないのは、部分走査や同時要求で
 *     上限が上下すると、その度に雪崩が起きるから(高水位)。
 *
 *   ★依然として残る限界(誠実に書いておく): 鍵ではなく値になっただけで、
 *   `Math.round(mtimeMs)` の丸め幅の中で**同じ長さに書き直された** file は
 *   「変わっていない」と読まれる。transcript が追記専用である限り起きないが、
 *   「古い値が返る事は原理的に無い」と言い切るのは誤り(Codex 2026-08-27)。
 */
export class MetaCache {
  constructor({ max = 2000, ceiling = Number(process.env.RC_META_CACHE_CEILING) || 60000 } = {}) {
    this.max = max;
    this.floor = max; // 走査で上げた上限を、ここより下へは戻さない
    this.ceiling = Math.max(ceiling, max); // これ以上は伸ばさない(RAM の天井)
    this.capped = false; // 天井に当たっているか = 遅くなる事を承知の状態
    this.map = new Map(); // id -> { size, mtime, meta, seen }
    this.epoch = 0;
    this.evictions = 0;
  }

  /** 生きた file の同一性。同じパスが別 file に差し替わっても取り違えない。 */
  static idOf(st) {
    return `${st.dev}-${st.ino}`;
  }

  /** 版の指紋。旧 API 互換(検査が鍵の性質を測っている)。 */
  static keyOf(st) {
    return `${st.dev}-${st.ino}-${st.size}-${Math.round(st.mtimeMs)}`;
  }

  /** 走査の開始。以後 `get`/`set` で触れた entry だけが「今回見た」になる。 */
  beginScan() {
    this.epoch += 1;
    return this.epoch;
  }

  /**
   * 走査対象の件数が判った時点で上限を引き上げる。**読む前に**呼ぶ事。
   * 余白は版の入れ替わりではなく、走査中に増える file の分だけで足りる
   * (指紋は値に持つので、追記は entry を増やさない)。
   */
  ensureCapacity(filesSeen) {
    const want = Math.ceil(filesSeen * 1.25) + 64;
    // ★天井。上限を corpus に追従させると RAM は corpus に比例して伸びる ——
    //   これは実在する運用上の罠なので、黙って伸ばし続けない(Codex 2026-08-27)。
    //   天井に当たった時に起きるのは**遅くなる事だけ**で、行が消える事は無い
    //   (キャッシュは読みを省くだけで、一覧の内容には関与しない)。だから
    //   「静かに会話を落とす」より「うるさく遅くなる」を選ぶ。
    if (want > this.ceiling) {
      this.capped = true;
      this.max = this.ceiling;
      return this.max;
    }
    this.capped = false;
    if (want > this.max) this.max = want;
    return this.max;
  }

  /** 指紋が一致した時だけ中身を返す。触れた事は(不一致でも)今回見たとして記録する。 */
  get(st) {
    const v = this.map.get(MetaCache.idOf(st));
    if (!v) return null;
    v.seen = this.epoch; // 版違いでも「この file は生きている」= sweep の対象外
    if (v.size !== st.size || v.mtime !== Math.round(st.mtimeMs)) return null;
    return v.meta;
  }

  set(st, meta) {
    const id = MetaCache.idOf(st);
    this.map.set(id, { size: st.size, mtime: Math.round(st.mtimeMs), meta, seen: this.epoch });
    while (this.map.size > this.max) {
      this.map.delete(this.map.keys().next().value);
      this.evictions += 1;
    }
    return meta;
  }

  /**
   * 今回の走査で見なかった entry を落とす。
   * ★`complete` が偽(= `limit` で途中で読むのを止めた)時は**掃かない**。
   *   見ていないだけの生きた file を落とすと、次の要求でそこを読み直す事になり、
   *   直そうとしている雪崩を自分で作る。
   */
  sweep({ complete } = { complete: false }) {
    if (!complete) return 0;
    let dropped = 0;
    for (const [id, v] of this.map) {
      if (v.seen !== this.epoch) {
        this.map.delete(id);
        dropped += 1;
      }
    }
    return dropped;
  }

  get size() {
    return this.map.size;
  }
}
