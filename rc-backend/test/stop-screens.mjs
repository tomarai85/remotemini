// e2e 13-e(subagent の停止)が偽 tmux に置く画面を、実 fixture(test/fixtures/panel/)から組む。
// 検査 file の名前(末尾 .test.mjs)ではないので suite は拾わない(e2e と偽 tmux の共有部品)。
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const FIX = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "panel");
const fx = (n) => readFileSync(join(FIX, n), "utf8");

/** パネル画面。rows = [{ text, shell? }]、sel = 平らな位置(印)。実機の形(区切り `▔`、字下げ、footer)。 */
export function panelScreen(rows, sel) {
  const shells = rows.filter((r) => r.shell), agents = rows.filter((r) => !r.shell);
  const out = ["⏺ Launch two subagents", "", "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔", "   Background", `   ${shells.length} active shells · ${agents.length} active agents`, ""];
  let flat = 0;
  const emit = (r) => { out.push((flat === sel ? "   ❯ " : "     ") + r.text); flat++; };
  if (shells.length) { out.push(`     Shells (${shells.length})`); shells.forEach(emit); }
  if (agents.length) { out.push(`     Local agents (${agents.length})`); agents.forEach(emit); }
  out.push("", "   ↑/↓ to select · Enter to view · f to foreground · x to stop · ctrl+x ctrl+k to stop all agents · Esc to close", "");
  return out.join("\n");
}

/** 詳細画面: 実 fixture(jervis-detail-open.txt)の Prompt を差し替える(297 字で `…`、単語の境界で折り返す)。 */
export function detailScreen(prompt, { tools = null } = {}) {
  const lines = fx("jervis-detail-open.txt").split("\n");
  const qi = lines.findIndex((l) => l.trim() === "Prompt");
  const fi = lines.findIndex((l, i) => i > qi && /^\s*← to go back/.test(l));
  const shown = prompt.length > 297 ? prompt.slice(0, 297) + "…" : prompt;
  const wrapped = []; let cur = "";
  for (const w of shown.split(" ")) { if (cur && (cur + " " + w).length > 100) { wrapped.push("   " + cur); cur = w; } else cur = cur ? cur + " " + w : w; }
  if (cur) wrapped.push("   " + cur);
  let head = lines.slice(0, qi + 1);
  if (Array.isArray(tools)) {
    // Progress の下の道具行を差し替える(fixture は `Bash(sleep 12)` × 2)
    const pi = head.findIndex((l) => l.trim() === "Progress");
    if (pi >= 0) head = [...head.slice(0, pi + 1), ...tools.map((t, i) => (i === tools.length - 1 ? `   › ${t}` : `     ${t}`)), "", ...head.slice(qi)];
  }
  return [...head, ...wrapped, "", ...lines.slice(fi)].join("\n");
}
