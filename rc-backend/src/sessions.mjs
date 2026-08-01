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
import { nodeIo, readLinesBackward } from "./listing.mjs";

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
 * 明示名の機構は Phase I-1 に無いので実質 ai-title から始まる。
 */
export function resolveTitle(meta, sessionId) {
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

export function buildListing(entries) {
  return entries
    .filter((e) => isPhoneVisible(e.meta))
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .map((e) => ({
      id: e.sessionId,
      project: e.projectSlug,
      cwd: e.meta.cwd,
      title: resolveTitle(e.meta, e.sessionId),
      lastPrompt: e.meta.lastPrompt,
      turns: e.meta.turns,
      // ★層の中で測った正直さを HTTP の外まで出す。中で正直でも落とせば同じ事(§2.13 訂正 #5)。
      // これが無いと電話は「読み残し」と「本当に発言が無い」を区別できず、後者に丸めて嘘を書く。
      metadataIncomplete: !!e.meta.metadataIncomplete,
      updatedAt: new Date(e.mtimeMs).toISOString(),
    }));
}

/**
 * 会話履歴の抽出(GET /history 用)。user / assistant のテキストと、
 * tool-use は「何を使ったか」の要約1行に潰す(RC の会話ビュー相当の最小形)。
 * tail 側から limit 件。
 */
export function extractHistory(jsonlText, limit = 50) {
  if (typeof jsonlText !== "string") return [];
  return entriesFromLines(jsonlText.split("\n")).slice(-limit);
}

/** 行の配列(古い順)を表示用の項目列にする。壊れた行は飛ばす。 */
export function entriesFromLines(lines) {
  const out = [];
  for (const line of lines) {
    if (!line) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    out.push(...entriesFromRecord(obj));
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
    const all = entriesFromLines(r.lines);
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
    .map((b) => `⚙ ${b.name}`);
}
