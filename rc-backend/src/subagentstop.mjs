// 「この subagent を止める」の**目標を組む**(2026-09-06、対照表 #8 の後半 c3)。
//
// 電話が名指すのは agentId(列挙の口 `GET /api/sessions/:id/subagents` が返す)。画面は id を描かないので、机は
// id から**画面で照合できる材料**を組む: 型・説明文(meta.json)/ prompt の全文と道具の全列(agent-<id>.jsonl)/
// 生死と同名の生存数(列挙の判定)。組めなければ其の理由で断る。打鍵は `panelstop-driver.mjs`。
//
// Codex 敵対レビュー(2026-09-06、c3)で変えた事:
//   - 転写は**頭と尻尾だけ**を fd から読む(prompt は先頭の user 記録、道具は末尾側が「直近」。全部を同期で読んで
//     先頭 12 MB を使う初版は、巨大な転写で event loop を止め、しかも古い道具を「直近」と読んでいた)。
//   - 同名の生存数は running だけでなく **finished でない全部**(stalled / unknown も)。列挙の「running」は mtime の
//     鮮度なので、終わった直後の目標が running に見え、止まっている同名の隣が数から漏れる形を塞ぐ。
//   - 同名の兄弟と prompt の先頭 297 字(UI が切る長さ)が同じなら、prompt は画面で見分ける材料にならない = 目標から
//     prompt を外す(道具列だけで見分ける。其れも同じなら ambiguous)。
//   - agentId の字種と長さは列挙(subagents.mjs)と同じ。
import { openSync, readSync, closeSync, fstatSync } from "node:fs";
import { join } from "node:path";
import { readSubagentsFromPath, subagentDirFor } from "./subagents.mjs";

/** 目標が組めない理由(閉じている)。文は電話にそのまま出せる形。 */
export const TARGET_REFUSAL = {
  "no-such-agent": "No subagent with that id was found under this conversation. It may have been cleaned up.",
  "not-live": "That subagent is not running right now (finished, stalled, or unknown), so there is nothing to stop.",
  "unreadable": "The desk could not read that subagent's transcript, so it cannot be identified on the panel. Nothing was pressed.",
  "no-material": "That subagent's transcript has no prompt and no tool calls yet, so it cannot be told apart on the panel. Try again in a moment.",
};

/** 列挙(subagents.mjs)と同じ字種・長さ。 */
export const AGENT_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
/** UI が prompt を切る長さ(`panelstop.mjs` の TRUNC_MIN と同じ根拠: 実測 297 字 + `…`)。 */
export const PROMPT_SHOWN = 297;
export const HEAD_BYTES = 256 * 1024;
export const TAIL_BYTES = 512 * 1024;

/** 道具呼び出しを panel の描き方(`Bash(sleep 12)`)に合わせて 1 行にする。第 1 引数は道具ごとに決まっている。 */
const PRIMARY = {
  Bash: "command", Read: "file_path", Write: "file_path", Edit: "file_path", NotebookEdit: "notebook_path",
  Grep: "pattern", Glob: "pattern", Agent: "description", WebFetch: "url", WebSearch: "query", Skill: "skill", ToolSearch: "query",
};
export function renderToolCall(name, input) {
  const n = typeof name === "string" ? name : "";
  if (!n) return null;
  const inp = input && typeof input === "object" && !Array.isArray(input) ? input : {};
  const key = PRIMARY[n];
  let arg = key && typeof inp[key] === "string" ? inp[key] : null;
  if (arg === null) { const first = Object.values(inp).find((v) => typeof v === "string"); arg = first ?? null; }
  if (arg === null) return n;
  return `${n}(${arg.replace(/\s*\n\s*/g, " ")})`;
}

/** 転写の先頭の user 記録 = prompt。文字列か、text ブロックの列。 */
function promptOf(rec) {
  const c = rec?.message?.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter((b) => b && b.type === "text" && typeof b.text === "string").map((b) => b.text).join("\n");
  return "";
}

/** file の先頭 `n` バイトと末尾 `n` バイトを fd から読む(全部は読まない)。 */
function readHeadTail(path, head, tail) {
  const fd = openSync(path, "r");
  try {
    const size = fstatSync(fd).size;
    const h = Buffer.alloc(Math.min(head, size));
    readSync(fd, h, 0, h.length, 0);
    let t = null;
    if (size > head) {
      const start = Math.max(head, size - tail);
      t = Buffer.alloc(size - start);
      readSync(fd, t, 0, t.length, start);
    }
    return { size, head: h.toString("utf8"), tail: t ? t.toString("utf8") : null };
  } finally {
    closeSync(fd);
  }
}

/**
 * agent-<id>.jsonl から prompt(先頭の user 記録)と道具列(直近側)を取り出す。
 * 頭から読んだ道具列と尻尾から読んだ道具列を、尻尾が在れば尻尾を優先して繋ぐ(尻尾の先頭の切れた行は捨てる)。
 * `toolsComplete` = 転写全体を読めた(道具列が全部揃っている)。
 */
export function readAgentTranscript(path, { headBytes = HEAD_BYTES, tailBytes = TAIL_BYTES } = {}) {
  let ht;
  try { ht = readHeadTail(path, headBytes, tailBytes); } catch (e) {
    return { ok: false, reason: e && e.code === "ENOENT" ? "no-such-agent" : "unreadable" };
  }
  const parseLines = (text, { dropFirst }) => {
    const lines = text.split("\n");
    if (dropFirst) lines.shift();
    const out = [];
    for (const line of lines) {
      if (!line.trim()) continue;
      try { out.push(JSON.parse(line)); } catch { /* 切れた行・壊れた行は飛ばす */ }
    }
    return out;
  };
  const headRecs = parseLines(ht.head, { dropFirst: false });
  let promptPrefix = "";
  for (const rec of headRecs) { if (rec?.type === "user") { promptPrefix = promptOf(rec); break; } }
  const toolsOf = (recs) => {
    const out = [];
    for (const rec of recs) {
      if (rec?.type === "assistant" && Array.isArray(rec?.message?.content)) {
        for (const b of rec.message.content) if (b && b.type === "tool_use") { const r = renderToolCall(b.name, b.input); if (r) out.push(r); }
      }
    }
    return out;
  };
  const complete = ht.tail === null;
  const recentTools = complete ? toolsOf(headRecs) : toolsOf(parseLines(ht.tail, { dropFirst: true }));
  return { ok: true, promptPrefix, recentTools, toolsComplete: complete, size: ht.size };
}

/** 折り返しだけ畳んだ prompt の、UI が見せる長さぶん。 */
const shownPrefix = (s) => String(s ?? "").replace(/^\s*\n/, "").replace(/\n\s*$/, "").replace(/[ \t]*\n[ \t]*/g, " ").slice(0, PROMPT_SHOWN);

/**
 * 目標を組む。`{ ok:true, target }` か `{ ok:false, reason, message }`。
 * target = { agentId, agentType, description, promptPrefix, recentTools, live, liveSameDescription, state,
 *            promptDistinct(同名の兄弟と先頭 297 字が違う), toolsComplete }
 * `listing` を渡せば列挙を読み直さない(口は 1 要求に 1 回だけ読む)。
 */
export function buildStopTarget(transcriptPath, agentId, { listing = null, nowMs = Date.now() } = {}) {
  if (typeof agentId !== "string" || !AGENT_ID_RE.test(agentId)) return refuse("no-such-agent");
  const l = listing ?? readSubagentsFromPath(transcriptPath, { nowMs });
  const row = (l.agents ?? []).find((a) => a.agentId === agentId);
  if (!row) return refuse(l.directory === "unreadable" ? "unreadable" : "no-such-agent", { directory: l.directory });
  if (row.state !== "running") return refuse("not-live", { state: row.state });
  if (typeof row.description !== "string" || !row.description) return refuse("unreadable", { meta: row.meta });
  const dir = subagentDirFor(transcriptPath);
  const t = readAgentTranscript(join(dir, `agent-${agentId}.jsonl`));
  if (!t.ok) return refuse(t.reason);
  if (!t.promptPrefix.trim() && t.recentTools.length === 0) return refuse("no-material");
  // 同名の兄弟 = 説明文が同じで finished でない全部(running だけに絞ると、止まっている隣が数から漏れる)。
  const siblings = (l.agents ?? []).filter((a) => a.agentId !== agentId && a.description === row.description && a.state !== "finished");
  const liveSameDescription = 1 + siblings.length;
  // prompt が兄弟と先頭 297 字で同じなら、画面では見分けられない = prompt を材料から外す。
  let promptDistinct = true;
  const mine = shownPrefix(t.promptPrefix);
  for (const s of siblings) {
    const st = readAgentTranscript(join(dir, `agent-${s.agentId}.jsonl`), { tailBytes: 0 });
    if (st.ok && shownPrefix(st.promptPrefix) === mine) { promptDistinct = false; break; }
  }
  return {
    ok: true,
    target: {
      agentId, agentType: row.agentType ?? null, description: row.description,
      promptPrefix: promptDistinct ? t.promptPrefix : "", recentTools: t.recentTools,
      live: true, liveSameDescription, state: row.state, promptDistinct, toolsComplete: t.toolsComplete,
    },
  };
}

function refuse(reason, extra = {}) {
  return { ok: false, reason, message: TARGET_REFUSAL[reason], ...extra };
}
