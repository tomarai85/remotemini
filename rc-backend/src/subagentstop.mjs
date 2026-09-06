// 「この subagent を止める」の**目標を組む**(2026-09-06、対照表 #8 の後半 c3)。
//
// 電話が名指すのは agentId(列挙の口 `GET /api/sessions/:id/subagents` が返す)。画面は id を描かないので、机は
// id から**画面で照合できる材料**を組む: 型・説明文(meta.json)/ prompt の全文と道具の全列(agent-<id>.jsonl)/
// 生死と同名の生存数(列挙の判定)。組めなければ其の理由で断る。打鍵は `panelstop-driver.mjs`。
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { readSubagentsFromPath, subagentDirFor, SUBAGENT_SCAN_MAX } from "./subagents.mjs";

/** 目標が組めない理由(閉じている)。文は電話にそのまま出せる形。 */
export const TARGET_REFUSAL = {
  "no-such-agent": "No subagent with that id was found under this conversation. It may have been cleaned up.",
  "not-live": "That subagent is not running right now (finished, stalled, or unknown), so there is nothing to stop.",
  "unreadable": "The desk could not read that subagent's transcript, so it cannot be identified on the panel. Nothing was pressed.",
  "no-material": "That subagent's transcript has no prompt and no tool calls yet, so it cannot be told apart on the panel. Try again in a moment.",
};

const AGENT_ID_RE = /^[A-Za-z0-9._-]{1,80}$/;

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
  // 改行は空白に(panel は 1 行で描く)。長い引数は panel 側が `…` で切るので此処では切らない(照合側が前方一致で読む)。
  return `${n}(${arg.replace(/\s*\n\s*/g, " ")})`;
}

/** 転写の先頭の user 記録 = prompt。文字列か、text ブロックの列。 */
function promptOf(rec) {
  const c = rec?.message?.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter((b) => b && b.type === "text" && typeof b.text === "string").map((b) => b.text).join("\n");
  return "";
}

/** agent-<id>.jsonl を読んで prompt と道具列を取り出す(上限まで。壊れた行は飛ばす)。 */
export function readAgentTranscript(path, { cap = SUBAGENT_SCAN_MAX } = {}) {
  let text;
  try {
    const size = statSync(path).size;
    const fd = readFileSync(path, { encoding: "utf8", flag: "r" });
    text = size > cap ? fd.slice(0, cap) : fd;
  } catch (e) {
    return { ok: false, reason: e && e.code === "ENOENT" ? "no-such-agent" : "unreadable" };
  }
  let promptPrefix = "";
  const recentTools = [];
  let sawPrompt = false;
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let rec;
    try { rec = JSON.parse(line); } catch { continue; }
    if (!sawPrompt && rec?.type === "user") { promptPrefix = promptOf(rec); sawPrompt = true; continue; }
    if (rec?.type === "assistant" && Array.isArray(rec?.message?.content)) {
      for (const b of rec.message.content) {
        if (b && b.type === "tool_use") { const r = renderToolCall(b.name, b.input); if (r) recentTools.push(r); }
      }
    }
  }
  return { ok: true, promptPrefix, recentTools };
}

/**
 * 目標を組む。`{ ok:true, target }` か `{ ok:false, reason, message }`。
 * target = { agentId, agentType, description, promptPrefix, recentTools, live, liveSameDescription, state }
 * `listing` を渡せば列挙を読み直さない(口は 1 要求に 1 回だけ読む)。
 */
export function buildStopTarget(transcriptPath, agentId, { listing = null, nowMs = Date.now() } = {}) {
  if (typeof agentId !== "string" || !AGENT_ID_RE.test(agentId)) return refuse("no-such-agent");
  const l = listing ?? readSubagentsFromPath(transcriptPath, { nowMs });
  const row = (l.agents ?? []).find((a) => a.agentId === agentId);
  // 子の dir が無い(absent)= 本当に居ない。読めない(unreadable)だけが unreadable。
  if (!row) return refuse(l.directory === "unreadable" ? "unreadable" : "no-such-agent", { directory: l.directory });
  if (row.state !== "running") return refuse("not-live", { state: row.state });
  if (typeof row.description !== "string" || !row.description) return refuse("unreadable", { meta: row.meta });
  const t = readAgentTranscript(join(subagentDirFor(transcriptPath), `agent-${agentId}.jsonl`));
  if (!t.ok) return refuse(t.reason);
  if (!t.promptPrefix.trim() && t.recentTools.length === 0) return refuse("no-material");
  const liveSameDescription = (l.agents ?? []).filter((a) => a.description === row.description && a.state === "running").length;
  return {
    ok: true,
    target: {
      agentId, agentType: row.agentType ?? null, description: row.description,
      promptPrefix: t.promptPrefix, recentTools: t.recentTools,
      live: true, liveSameDescription, state: row.state,
    },
  };
}

function refuse(reason, extra = {}) {
  return { ok: false, reason, message: TARGET_REFUSAL[reason], ...extra };
}
