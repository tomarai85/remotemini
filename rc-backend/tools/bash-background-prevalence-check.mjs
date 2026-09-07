// bash-background-prevalence-check.mjs — 「背景シェル(`run_in_background:true` の Bash)は実セッションでどれだけ使われるか」を
// 転写から数える(2026-09-07、対照表 #8 の後半の限界 = 停止の driver はシェル行が在るパネルを既定で断る、の裁定材料)。
//
// ── なぜ道具にするか ─────────────────────────────────────────────────────────
// 2026-09-07 の判断材料は手打ちの grep 1 回(Jervis 14 日・120 転写: Bash 17,843 / run_in_background 956 = 5.4% / 8 セッション)
// だった。安全既定を反転するかの根拠なので、同じ数え方で誰でも・friday でも・後日でも出せる形に置く。
// 数え方: 親の転写(`~/.claude/projects/<slug>/<sid>.jsonl`、`subagents/` 配下は除く)を mtime の新しい順に最大 `--max` 本、
// `--days` 日以内。各行を JSON として読み、`type:"assistant"` の `tool_use` で `name:"Bash"` を数え、其の `input.run_in_background`
// が true の物を数える。文字列の部分一致ではない(綴りや空白で揺れない)。
//
// 出力(1 行、表として読む): `kind=ok days=14 files=N bash=B bg=G bg_pct=P sessions=S sessions_bg=T`
//   bg_pct は小数 1 桁。files=0 なら `kind=ng reason=no-transcripts`(0 件を「使われていない」と読ませない)。
// 使い方: node rc-backend/tools/bash-background-prevalence-check.mjs [--root DIR] [--days N] [--max M]
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

/** 1 本の転写(文字列)を数える。壊れた行は飛ばす。 */
export function tallyTranscript(text) {
  let bash = 0, bg = 0;
  for (const line of String(text).split("\n")) {
    if (!line.trim()) continue;
    let rec;
    try { rec = JSON.parse(line); } catch { continue; }
    if (rec?.type !== "assistant") continue;
    const content = rec?.message?.content;
    if (!Array.isArray(content)) continue;
    for (const b of content) {
      if (!b || b.type !== "tool_use" || b.name !== "Bash") continue;
      bash += 1;
      if (b.input && typeof b.input === "object" && b.input.run_in_background === true) bg += 1;
    }
  }
  return { bash, bg };
}

/** 複数の転写の集計。`texts` = 文字列の配列。 */
export function tally(texts) {
  let bash = 0, bg = 0, sessionsBg = 0;
  for (const t of texts) {
    const r = tallyTranscript(t);
    bash += r.bash; bg += r.bg;
    if (r.bg > 0) sessionsBg += 1;
  }
  const pct = bash > 0 ? Math.round((bg / bash) * 1000) / 10 : 0;
  return { files: texts.length, bash, bg, bg_pct: pct, sessions_bg: sessionsBg };
}

/** 親の転写の path を新しい順に(`subagents/` 配下は除く)。 */
export function listParentTranscripts(root, { days = 14, max = 120, nowMs = Date.now() } = {}) {
  const out = [];
  let slugs = [];
  try { slugs = readdirSync(root); } catch { return out; }
  const cutoff = nowMs - days * 86400 * 1000;
  for (const slug of slugs) {
    const dir = join(root, slug);
    let names = [];
    try { names = readdirSync(dir); } catch { continue; }
    for (const n of names) {
      if (!n.endsWith(".jsonl")) continue;
      const p = join(dir, n);
      let st;
      try { st = statSync(p); } catch { continue; }
      if (!st.isFile() || st.mtimeMs < cutoff) continue;
      out.push({ path: p, mtimeMs: st.mtimeMs });
    }
  }
  out.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return out.slice(0, max).map((x) => x.path);
}

export function formatLine(r, { days }) {
  if (!r.files) return `kind=ng reason=no-transcripts days=${days}`;
  return `kind=ok days=${days} files=${r.files} bash=${r.bash} bg=${r.bg} bg_pct=${r.bg_pct} sessions=${r.files} sessions_bg=${r.sessions_bg}`;
}

function main(argv) {
  let root = join(homedir(), ".claude", "projects"), days = 14, max = 120;
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === "--root") root = argv[i + 1];
    else if (argv[i] === "--days") days = Number(argv[i + 1]);
    else if (argv[i] === "--max") max = Number(argv[i + 1]);
    else { console.log("usage: bash-background-prevalence-check.mjs [--root DIR] [--days N] [--max M]"); process.exit(2); }
  }
  if (!Number.isFinite(days) || days <= 0 || !Number.isInteger(max) || max <= 0) { console.log("usage: bash-background-prevalence-check.mjs [--root DIR] [--days N] [--max M]"); process.exit(2); }
  const paths = listParentTranscripts(root, { days, max });
  const texts = [];
  for (const p of paths) { try { texts.push(readFileSync(p, "utf8")); } catch { /* 読めない転写は数に入れない */ } }
  const r = tally(texts);
  console.log(formatLine(r, { days }));
  process.exit(r.files ? 0 : 1);
}

const isMain = process.argv[1] && /bash-background-prevalence-check\.mjs$/.test(process.argv[1]);
if (isMain) main(process.argv.slice(2));
