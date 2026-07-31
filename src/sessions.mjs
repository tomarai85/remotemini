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
export function buildListing(entries) {
  return entries
    .filter((e) => e.meta.entrypoint === "cli")
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .map((e) => ({
      id: e.sessionId,
      project: e.projectSlug,
      cwd: e.meta.cwd,
      title: resolveTitle(e.meta, e.sessionId),
      lastPrompt: e.meta.lastPrompt,
      turns: e.meta.turns,
      updatedAt: new Date(e.mtimeMs).toISOString(),
    }));
}

/**
 * 会話履歴の抽出(GET /history 用)。user / assistant のテキストと、
 * tool-use は「何を使ったか」の要約1行に潰す(RC の会話ビュー相当の最小形)。
 * tail 側から limit 件。
 */
export function extractHistory(jsonlText, limit = 50) {
  const out = [];
  if (typeof jsonlText !== "string") return out;
  const lines = jsonlText.split("\n");
  for (const line of lines) {
    if (!line) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (obj.type === "user" && obj.message) {
      const text = flattenContent(obj.message.content);
      if (text) out.push({ role: "user", text });
    } else if (obj.type === "assistant" && obj.message) {
      const text = flattenContent(obj.message.content);
      const tools = toolNames(obj.message.content);
      if (text) out.push({ role: "assistant", text });
      for (const t of tools) out.push({ role: "tool", text: t });
    }
  }
  return out.slice(-limit);
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
