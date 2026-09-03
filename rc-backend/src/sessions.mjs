// セッション一覧とメタデータ抽出 — ~/.claude/projects/**/*.jsonl を読む純関数群。
//
// 設計根拠(research/asset-survey.md §3、edith 実測):
//   - 人間の対話セッションは entrypoint:"cli"。EDITH 自身の自動化ログ(sdk-cli)が
//     数百件混在するため、絞らないと一覧がノイズに沈む。
//   - タイトルは {"type":"ai-title","aiTitle":"..."} の非同期追記行。
//   - 最後の意味あるメッセージは {"type":"last-prompt","lastPrompt":"..."} 行。
//   - 最終更新はファイル mtime で足りる(全パース不要)。
//
// この module は fs を受け取らない純関数(パース)と、fs を注入できる薄い走査層に分ける。
// テストは fixture 文字列だけで回る。
//
// 例外は履歴の有界読み(readHistoryFromPath)。末尾から必要な分だけ読む部分は
// listing.mjs の readLinesBackward に任せる — 持ち越し・短い read・多バイト境界の
// 扱いを2箇所に書かない為(2026-08-02)。
import { closeSync, openSync } from "node:fs";
import { nodeIo, readLinesBackward, TAIL_MAX } from "./listing.mjs";

/**
 * jsonl の1ファイル分のテキストから一覧用メタデータを抜く。
 * 全行 JSON.parse はしない — 必要な type の行だけを軽く探す。
 * 壊れた行は黙って飛ばす(読み手が一覧を得られないより、1項目欠ける方がよい)。
 */
export function extractSessionMeta(jsonlText) {
  const meta = {
    entrypoint: null,
    cwd: null,
    title: null,
    lastPrompt: null,
    turns: 0,
  };
  if (typeof jsonlText !== "string" || jsonlText.length === 0) return meta;
  const lines = jsonlText.split("\n");
  for (const line of lines) {
    if (!line) continue;
    // 高価な parse の前に安いフィルタ。field 名は JSON 内で必ず引用符付きで現れる。
    const wantsParse =
      meta.entrypoint === null && line.includes('"entrypoint"') ||
      line.includes('"ai-title"') ||
      line.includes('"last-prompt"') ||
      line.includes('"type":"user"') ||
      line.includes('"type": "user"');
    if (!wantsParse) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue; // 書き込み途中の末尾行など。壊れた行で全体を落とさない。
    }
    if (meta.entrypoint === null && typeof obj.entrypoint === "string") {
      meta.entrypoint = obj.entrypoint;
      if (typeof obj.cwd === "string") meta.cwd = obj.cwd;
    }
    if (obj.type === "ai-title" && typeof obj.aiTitle === "string") {
      meta.title = obj.aiTitle; // 後の行が勝つ(rename 相当の再生成に追従)
    }
    if (obj.type === "last-prompt" && typeof obj.lastPrompt === "string") {
      meta.lastPrompt = obj.lastPrompt;
    }
    if (obj.type === "user") meta.turns += 1;
  }
  return meta;
}

/**
 * タイトルの解決順は本家 RC を真似る(research/remote-control-teardown.md §2):
 *   明示名 → ai-title → 最後の意味あるメッセージ → id 短縮。
 * ★明示名の機構は 2026-08-16 に入った(src/titles.mjs、spec-audit A1)。
 *   それまで此処の註は「Phase I-1 に無いので実質 ai-title から始まる」と自認したまま
 *   1ヶ月放置されていた — 文書が掲げた優先順の1段目が製品に無かった。
 */
export function resolveTitle(meta, sessionId, explicit) {
  if (typeof explicit === "string" && explicit.length > 0) return explicit;
  if (meta.title) return meta.title;
  if (meta.lastPrompt) {
    const t = meta.lastPrompt.trim().replace(/\s+/g, " ");
    return t.length > 60 ? `${t.slice(0, 60)}…` : t;
  }
  return sessionId.slice(0, 8);
}

/**
 * 一覧の1項目を組む。listSessions(走査層)から呼ばれる。
 * live 状態(worker / tui)はここでは決めない — それはプロセス側の真実であって
 * ファイルから推測しない(DESIGN.md D3、Codex 補正)。呼び出し側が重ねる。
 */
/**
 * 電話の一覧に出す会話の定義 = **TUI(`entrypoint: "cli"`)だけ**。
 *
 * ★判定をここ1箇所に置く理由(2026-08-02、実機で踏んでから移した):
 *   同じ判定が「読む対象を選ぶ側」と「行を組む側」の両方に要る。2箇所に書くと、
 *   `limit` が**絞る前の file 数**に掛かる形に戻り、edith で一覧が空になる(下記)。
 *
 * ★なぜ `sdk-cli` を出さないか: あれは adapter が回す非対話の実行で、tmux の pane を
 *   持たない = 見ても打ち込めない。Tom の要求は「返答待ちであれ作業中であれ**干渉できる**」
 *   なので、干渉できない物を一覧に混ぜると本命が埋もれる。
 *
 * ★実測(2026-08-02):
 *   - edith: jsonl 642本のうち **`sdk-cli` 636 / `cli` 6**。mtime 順で最初の `cli` は **113本目**。
 *   - MBP  : 1,644本のうち `cli` 318。最初の `cli` は 1本目。
 *   = MBP だけで見ていると絶対に出ない差。**本番機で測って初めて出た**。
 */
export const isPhoneVisible = (meta) => meta?.entrypoint === "cli";

export function buildListing(entries, titles = {}) {
  return entries
    .filter((e) => isPhoneVisible(e.meta))
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .map((e) => ({
      id: e.sessionId,
      project: e.projectSlug,
      cwd: e.meta.cwd,
      title: resolveTitle(e.meta, e.sessionId, titles[e.sessionId]),
      lastPrompt: e.meta.lastPrompt,
      turns: e.meta.turns,
      // ★層の中で測った正直さを HTTP の外まで出す。中で正直でも落とせば同じ事(§2.13 訂正 #5)。
      // これが無いと電話は「読み残し」と「本当に発言が無い」を区別できず、後者に丸めて嘘を書く。
      metadataIncomplete: !!e.meta.metadataIncomplete,
      updatedAt: new Date(e.mtimeMs).toISOString(),
    }));
}

/**
 * 読めなかった会話の1行。★読めない会話を黙って消さない。消えると
 * 「一番長い会話だけが居なくなる」型に戻る。
 *
 * `buildListing` の隣に置く理由: 一覧の行を作る生産者は**この file と registry.mjs の
 * 2箇所だけ**にする。走査の途中(server.mjs のハンドラ)に literal で書くと、鍵名を
 * 実行して測れない = 電話の Decodable と突き合わせられない(監査 S8-25)。
 */
export function unreadableRow({ id, project, updatedAt, errorCode }) {
  return {
    id,
    project,
    cwd: null,
    title: "(unreadable)",
    lastPrompt: "",
    turns: null,
    updatedAt,
    readable: false,
    errorCode,
  };
}

/**
 * 会話履歴の抽出(GET /history 用)。user / assistant のテキストと、
 * tool-use は「何を使ったか」の要約1行に潰す(RC の会話ビュー相当の最小形)。
 * tail 側から limit 件。
 */
export function extractHistory(jsonlText, limit = 50) {
  if (typeof jsonlText !== "string") return [];
  // 錨(対照表 #3)は全読みでも同じ値になる様に、行の byte 位置を本文から積算する
  // (有界読み `readHistoryFromPath` と同じ答え = test/history.test.mjs の突き合わせ)。
  const lines = jsonlText.split("\n");
  const offsets = [];
  let pos = 0;
  for (const l of lines) {
    offsets.push(pos);
    pos += Buffer.byteLength(l, "utf8") + 1;
  }
  return entriesFromLines(lines, offsets).slice(-limit);
}

/** 行の配列(古い順)を表示用の項目列にする。壊れた行は飛ばす。 */
export function entriesFromLines(lines, offsets) {
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    const entries = entriesFromRecord(obj);
    // ★錨(2026-09-03、対照表 #3): 行の byte 位置 + 行内の何番目か。追記しか起きない jsonl では
    //   一度付いた位置が変わらないので、探索の当たりと素の履歴で**同じ項目が同じ錨**を持つ =
    //   電話が「其の項目へ跳ぶ」為の鍵。`offsets` が無い呼び手(要約など)には付けない。
    if (Array.isArray(offsets) && Number.isInteger(offsets[i])) {
      entries.forEach((e, k) => { e.anchor = `${offsets[i]}:${k}`; });
    }
    out.push(...entries);
  }
  return out;
}

/**
 * 直近 `limit` 件の履歴を、**末尾から必要な分だけ読んで**組む。
 *
 * なぜ全部読まないか(実測 2026-08-02): 一番長い会話は 280 MB。電話が会話を開くたびに
 * それを丸ごと1本の JS 文字列にしていた。文字列の上限 536,870,888 を超えれば
 * `ERR_STRING_TOO_LONG` で**その会話だけ履歴が空になる**(一覧で見つけたのと同じ型の穴)。
 *
 * @param {string} path
 * @param {number} limit 返す項目数
 * @param {object} [opts] io / chunk / maxBytes(test 用)
 * @returns {{history:Array, truncated:boolean, scanned:number}}
 *   `truncated` = これより前の履歴がまだ在る(読み切っていない)。UI はここで「以前がある」と言える。
 */
export function readHistoryFromPath(path, limit = 50, opts = {}) {
  const fd = openSync(path, "r");
  try {
    const r = readLinesBackward(opts.io ?? nodeIo, fd, {
      chunk: opts.chunk,
      maxBytes: opts.maxBytes,
      // 「行が limit 本」ではなく「**項目が limit 件**」で止める。
      // 1レコードが 0 件(meta 行)にも複数件(本文 + tool 呼び)にもなるので、
      // 行数で数えると足りない/読み過ぎのどちらにもなる。
      done: (lines) => entriesFromLines(lines).length >= limit,
    });
    const all = entriesFromLines(r.lines, r.offsets);
    return {
      history: all.slice(-limit),
      truncated: !r.reachedStart || all.length > limit,
      scanned: r.scanned,
    };
  } finally {
    closeSync(fd);
  }
}

/**
 * 転写の中を後ろから探す。
 *
 * ── 何故 要るか(2026-08-31)────────────────────────────────────────────────
 * 電話が読めるのは最新 500 件まで。3 時間走ったセッションを開いた時、
 * 「どこで転けたか」へ跳ぶ手段が無く、**500 件の壁の向こうは存在しないのと同じ**だった。
 * 調べた製品(Termius / Blink / Claude RC / Omnara / claudecodeui …)で
 * **転写内検索を持つ物は 1 つも無かった**ので、此処は素直に効く。
 *
 * ★設計の中心は「速く探す」ではなく **「見つからないを正直に言う」**。
 *   走査は有界(`maxBytes` / 見つけた件数)なので、0 件には 2 つの意味が在る:
 *     (a) 走査した範囲に無かった
 *     (b) 会話の最初まで見て無かった
 *   之を混ぜると「無い」と言い切れない物を言い切る事になる。だから
 *   `reachedStart` と `scanned` を返し、呼ぶ側が (a) と (b) を分けられる様にする。
 *
 * ★大小を区別しない。電話で打つ側は shift を押さない。
 *
 * @param {string} path
 * @param {string} q 探す文字列(空なら何も返さない —— 全件を「一致」にしない)
 * @param {number} limit 返す一致の数
 * @param {object} [opts] io / chunk / maxBytes(test 用)
 * @returns {{history:Array, matched:number, reachedStart:boolean, scanned:number}}
 */
export function searchHistoryFromPath(path, q, limit = 50, opts = {}) {
  const needle = String(q ?? "").toLowerCase();
  // ★空の問いを「全部に一致」にしない。空欄のまま送られた時に会話全部が返ると、
  //   利用者は「検索したのに何も絞れない」を見る事になる。
  if (!needle) return { history: [], matched: 0, reachedStart: false, scanned: 0 };

  const hit = (e) => String(e?.text ?? "").toLowerCase().includes(needle);
  const fd = openSync(path, "r");
  try {
    const r = readLinesBackward(opts.io ?? nodeIo, fd, {
      chunk: opts.chunk,
      maxBytes: opts.maxBytes,
      // 「項目が limit 件」ではなく **「一致が limit 件」** で止める。
      // 項目で数えると、一致が疎な会話で走査が早く止まって取りこぼす。
      done: (lines) => entriesFromLines(lines).filter(hit).length >= limit,
    });
    // ★`fromEnd`(対照表 #3) = 其の項目が**末尾から何番目か**(最新 = 0)。走査は末尾から始まるので
    //   読めた項目の並びの中の位置がそのまま file 全体での位置になる。電話は此の数で
    //   `/history?limit=` を伸ばして其の項目まで読み込み、`anchor` で其の行へ scroll する。
    const everything = entriesFromLines(r.lines, r.offsets);
    const total = everything.length;
    const all = [];
    everything.forEach((e, i) => { if (hit(e)) all.push({ ...e, fromEnd: total - 1 - i }); });
    return {
      history: all.slice(-limit),
      matched: all.length,
      reachedStart: r.reachedStart,
      scanned: r.scanned,
    };
  } finally {
    closeSync(fd);
  }
}

/**
 * jsonl の1レコードを表示用の項目列に直す。
 * 履歴(まとめ読み)とライブ配信(追記 tail)で**同じ関数**を通す — 2箇所に書くと、
 * 電話の画面で「後から読み直したら中身が違う」が起きる。
 */
export function entriesFromRecord(obj) {
  const out = [];
  if (!obj || typeof obj !== "object") return out;
  if (obj.type === "user" && obj.message) {
    const text = flattenContent(obj.message.content);
    if (text) out.push({ role: "user", text });
  } else if (obj.type === "assistant" && obj.message) {
    const text = flattenContent(obj.message.content);
    const tools = toolNames(obj.message.content);
    if (text) out.push({ role: "assistant", text });
    for (const t of tools) out.push({ role: "tool", text: t });
  }
  return out;
}

function flattenContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((b) => b && b.type === "text" && typeof b.text === "string")
    .map((b) => b.text)
    .join("");
}

function toolNames(content) {
  if (!Array.isArray(content)) return [];
  return content
    .filter((b) => b && b.type === "tool_use" && typeof b.name === "string")
    .map((b) => {
      // ★subagent(Task)は名前だけだと全部同じ「⚙ Task」になり、何が走っているのか
      //   電話から読めない(spec-audit C2、本家は subagent の進捗を見せる)。入力の
      //   description(短い人向けの題)が在れば添える。値の中身は description **だけ**
      //   読む — prompt 本文は長く、機密が乗り得るので線に出さない。
      if (b.name === "Task" && typeof b.input?.description === "string" && b.input.description.trim()) {
        const d = b.input.description.trim().replace(/\s+/g, " ");
        return `⚙ Task: ${d.length > 40 ? `${d.slice(0, 40)}…` : d}`;
      }
      return `⚙ ${b.name}`;
    });
}

/**
 * digest 用に**生のレコード**を後方から読む。2026-08-26 新設。
 *
 * ★`readHistoryFromPath` と分けた理由: あちらは表示用に均した項目を返し、**時刻を落とす**。
 *   digest は「いつからいつまで」が本題なので時刻が要る。均した物に時刻を足すと、
 *   表示側の期待(rolelとtextだけ)を壊すか、digest が表示用の丸めを引き継ぐかの
 *   どちらかになる。生を読む口を別に持つ方が、両方の意味が濁らない。
 *
 * ★`reachedStart` を返すのが肝。**遡り切れたかは呼び手にしか分からない**ので、
 *   digest 側が「読めた範囲で N 件」を「N 件」と言わずに済む唯一の材料。
 *
 * @param {string} path
 * @param {number} sinceMs これより古い行に届いたら止めてよい
 * @returns {{records: object[], reachedStart: boolean, scanned: number}}
 */
export const DIGEST_SCAN_MAX = 12 * 1024 * 1024;

export function readRawRecords(path, sinceMs, opts = {}) {
  const fd = openSync(path, "r");
  try {
    let oldestSeen = Infinity;
    const r = readLinesBackward(opts.io ?? nodeIo, fd, {
      chunk: opts.chunk,
      // ★予算は履歴の既定(1MB)より広く取る。実測(2026-08-26、この repo の実会話):
      //   **2時間ぶんが 1.9MB**。1MB のままだと digest は常に `scan-budget` で不完全になり、
      //   「正直だが役に立たない」に落ちる。digest は行を溜めずに数えるだけなので、
      //   広げても持つのは走査中の buffer と該当レコードだけ。
      //   ★それでも上限は残す —— 無制限にすると、長い会話1本でサーバが死ぬ形に変わる。
      maxBytes: opts.maxBytes ?? DIGEST_SCAN_MAX,
      // ★止める条件は「窓より古い行を1本見た」。件数で止めると、窓の中がまだ在るのに
      //   打ち切って、しかもそれを reachedStart では表せない。
      done: (lines) => {
        for (const ln of lines) {
          const t = tsOf(ln);
          if (t !== null && t < oldestSeen) oldestSeen = t;
        }
        return Number.isFinite(sinceMs) && oldestSeen < sinceMs;
      },
    });
    const records = [];
    for (const ln of r.lines) {
      const o = parseLine(ln);
      if (o) records.push(o);
    }
    // 窓の先頭より前まで見えた = 遡り切れた。ファイルの先頭に届いた場合も同じ。
    const covered = r.reachedStart || (Number.isFinite(sinceMs) && oldestSeen < sinceMs);
    return { records, reachedStart: covered, scanned: r.scanned };
  } finally {
    closeSync(fd);
  }
}

function parseLine(ln) {
  const t = String(ln).trim();
  if (!t) return null;
  try { const o = JSON.parse(t); return o && typeof o === "object" ? o : null; } catch { return null; }
}

function tsOf(ln) {
  // 全部 JSON.parse すると重い。時刻だけ先に安く見る。
  const m = /"timestamp":"([^"]+)"/.exec(String(ln));
  if (!m) return null;
  const t = Date.parse(m[1]);
  return Number.isFinite(t) ? t : null;
}

/**
 * 転写から**今**の permission mode を読む(対照表 #16、`status` の分岐)。読むだけ ——
 * D4(#17)の裁定(電話からは変えられない)には触れない。
 *
 * ★出所は2つ、優先順は**ファイルの並び**で決める(timestamp では決めない):
 *   - `{"type":"permission-mode","permissionMode":"…"}` — トグルの瞬間に追記される
 *     専用の行。**timestamp を持たない**(実転写で確認)。
 *   - `{"type":"user", …, "permissionMode":"…"}` — 送信した user turn に埋め込まれた
 *     同名の値のスナップショット。timestamp を持つが、**送信を挟まないトグルには
 *     付いてこない**(実転写で確認: 843 行中 213 行の user 行だけが持つ)。
 *   timestamp で揃えて後ろから拾うと、timestamp を持たない方が常に時刻 0 に落ちて
 *   負ける — 送信の無いトグルが「無かった事」になる(`digest.mjs` の `sessionOf` が
 *   model/gitBranch/version でやっている時刻ソートを、ここでは意図して**使わない**)。
 *   jsonl は追記なので、**ファイルの並びのまま最後尾から**見れば、種類を問わず
 *   本当に最後に起きた方が勝つ。
 *
 * @param {string} path
 * @param {object} [opts] readMetaFromPath と同じ形({io, tailChunk, tailMax})
 * @returns {string|null} 見つからなければ null(古い transcript には項目自体が無い/
 *   予算の外まで遡らないと無い)。null は「読めなかった」であって「無い」の断定ではない。
 */
export function permissionModeOf(path, opts = {}) {
  const fd = openSync(path, "r");
  try {
    return permissionModeFromFd(opts.io ?? nodeIo, fd, opts);
  } finally {
    closeSync(fd);
  }
}

/**
 * `lines`(古い順)の末尾側から、`permissionMode` を持つ最初の行を探す。
 * 高価な parse の前に安いフィルタ(このファイルの他の読み手と同じ流儀)。
 */
function scanPermissionMode(lines) {
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line.includes('"permissionMode"')) continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; } // 書き込み途中の行など
    if (typeof obj?.permissionMode === "string" && obj.permissionMode) return obj.permissionMode;
  }
  return null;
}

/**
 * `permissionModeOf` の fd 版。テストが偽の io を差せる様に分けてある。
 *
 * ★`done` の中だけでなく、戻った後の `r.lines` にも同じ走査を掛ける
 *   (`listing.mjs` の `readMetaFromFd` と同じ形)。1チャンクで足りる小さいファイルは
 *   `pos === 0` に先に当たって `done` が一度も呼ばれずに抜ける(`readLinesBackward` の
 *   ループ順)ので、`done` だけに探索を任せると小さい transcript で採り漏らす。
 */
export function permissionModeFromFd(io, fd, opts = {}) {
  const r = readLinesBackward(io, fd, {
    chunk: opts.tailChunk,
    maxBytes: opts.tailMax ?? TAIL_MAX,
    done: (lines) => scanPermissionMode(lines) !== null,
  });
  return scanPermissionMode(r.lines);
}
