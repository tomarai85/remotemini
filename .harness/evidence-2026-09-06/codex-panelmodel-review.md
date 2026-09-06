# Codex adversarial review — panel-model parser (2026-09-06, codex-quick inline with real captures)

Verdict: FAIL. Folded in: selection marker anchored to column 3 (a row whose text begins with ❯ is not selected); overflow hint end-anchored; footer start anchored to the line start in both the parser and classifyScreen; wrapped counters joined up to the first section header; model name = remainder joined with ' · '; tool rows picked up even without a Progress heading; promptTruncated flag. Not handled (unobserved): a section header wrapped across two lines — recorded as unmeasured.

```
[codex-quick started pid=15192 13:11:31 timeout=170s — background callers: wait on the pid, do not read the output early]
Reading additional input from stdin...
OpenAI Codex v0.144.3
--------
workdir: /Users/tomtim/Infra/mobile-work/rc-backend
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: read-only
reasoning effort: xhigh
reasoning summaries: none
session id: 01a077eb-1cc1-7cf2-8d9e-5df28d6d636b
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Adversarial review, under 500 words, no file access (all inline). Findings with function name + concrete failing input; no rewrites. A pure parser turns Claude Code's /tasks agent-panel screen (already classified as PANEL/DETAIL by another function that restricts to the region below the last ▔ separator) into a structure; it must NOT decide anything (no refusal), must keep duplicate rows as duplicates (two same-description subagents render byte-identical rows), must separate section headers (Shells (N) / Local agents (N) / Team: name (N)), mark the selected row (leading ❯), and put overflow hints (↓ N more) aside. Hunt: rows misattributed to the wrong section, a selected marker inside a row's text, counts line parsing when it wraps, a Team name containing ' (' or digits, the counters split on ' · ' when the model name itself contains ' · ', recentTools when Progress is absent, promptPrefix truncation marker (…), and any place the parser would silently drop a row.

=== src/panelmodel.mjs ===
// agent panel(`/tasks`)と其の詳細画面を**構造**に読む純関数(2026-09-06、対照表 #8 の後半 b)。
//
// ── 何を読むか、何を決めないか ───────────────────────────────────────────────
// 読む: 節(`Shells (N)` / `Local agents (N)` / `Team: … (N)`)ごとの行と、どの行に選択の印 `❯` が乗っているか、
//       繋いだ footer。詳細画面なら `<型> › <説明>`、数の行、Progress の道具呼び出し、Prompt の冒頭。
// 決めない: 断るか押すか。其れは次の段(設計文の c)の仕事で、此処は**画面の写しを表にする**だけ。
//
// ★行の同一性は文字列だけ(測定 2026-09-06: 同じ説明文の 2 本は byte 同一)。だから `rows` に id は無い。
//   同名の行が 2 本在る事を**そのまま返す** —— 畳んだり番号を付けたりすると、上の段が「区別できた」と誤読する。
// ★見る範囲は `inject.mjs` の `panelStateOf` と同じ「最後の `▔▔▔` の区切りより下」。区切りの判断を 2 箇所に
//   書かない為に `overlayRegionOf` を其処から借りる。
import { overlayRegionOf, panelStateOf } from "./inject.mjs";

const SECTION = /^\s*(Shells|Local agents|Team: .+?) \((\d+)\)\s*$/;
const FOOTER_START = /↑\/↓ to select/;

/** 折り返した footer を 1 文に繋ぐ(`stop` が出た行まで、最長 max 行)。 */
function joinFooter(lines, from, stop, max = 3) {
  const out = [];
  for (let i = from; i < lines.length && out.length < max; i++) {
    out.push(lines[i].trim());
    if (stop.test(lines[i])) break;
  }
  return out.join(" ");
}

/**
 * PANEL 画面 → `{ counts, sections:[{ name, count, rows:[{ text, selected }] }], footer, selected }`。
 * PANEL でなければ null。`selected` = `{ section, index, text }`(印の行が無ければ null)。
 *
 * 行の読み方(fixture 10 枚から): 節の見出しの下に 1 行 1 項目。選択の印は行頭の空白の後の `❯ `。
 * 印の無い行は空白 5 つで始まる。`↓ N more` の様な overflow の行は項目ではないので `rows` に入れず `hints` へ。
 */
export function parsePanel(text) {
  if (panelStateOf(text) !== "PANEL") return null;
  const lines = overlayRegionOf(text);
  const bg = lines.findIndex((l) => l.trim() === "Background");
  const counts = (lines[bg + 1] ?? "").trim() || null;
  const fi = lines.findIndex((l, i) => i > bg && FOOTER_START.test(l));
  const footer = fi >= 0 ? joinFooter(lines, fi, /Esc to close/) : "";
  const sections = [];
  const hints = [];
  let selected = null;
  let cur = null;
  for (let i = bg + 2; i < (fi >= 0 ? fi : lines.length); i++) {
    const l = lines[i];
    if (!l.trim()) continue;
    const m = SECTION.exec(l);
    if (m) { cur = { name: m[1], count: Number(m[2]), rows: [] }; sections.push(cur); continue; }
    if (/^\s*↓ \d+ more/.test(l)) { hints.push(l.trim()); continue; }
    if (!cur) continue;                       // 節の前に在る行(数の行の続き等)は項目ではない
    const sel = /^\s*❯ /.test(l);
    const row = { text: l.replace(/^\s*❯ ?/, "").replace(/^\s+/, ""), selected: sel };
    cur.rows.push(row);
    if (sel) selected = { section: cur.name, index: cur.rows.length - 1, text: row.text };
  }
  return { kind: "panel", counts, sections, hints, footer, selected };
}

/**
 * DETAIL 画面 → `{ agentType, description, counters:{ elapsed, tokens, tools, model }, recentTools:[…],
 *                  promptPrefix, footer }`。DETAIL でなければ null。
 *
 * `recentTools` は Progress の下の行(`Bash(sleep 12)` 等)を**上から順に**。進行中の印 `›` は落とす。
 * `promptPrefix` は Prompt の下の行を繋いだ物(画面が `…` で切った所まで = 全文ではない)。
 */
export function parseDetail(text) {
  if (panelStateOf(text) !== "DETAIL") return null;
  const lines = overlayRegionOf(text);
  const ti = lines.findIndex((l) => /^\s*\S[^›\n]* › .+$/.test(l));
  const [, agentType, description] = /^\s*(\S[^›]*?)\s*›\s*(.+?)\s*$/.exec(lines[ti]) ?? [null, null, null];
  const cLine = (lines[ti + 1] ?? "").trim();
  const parts = cLine.split(" · ").map((p) => p.trim()).filter(Boolean);
  const counters = {
    elapsed: parts.find((p) => /^\d+(\.\d+)?(s|m|h)\b/.test(p)) ?? null,
    tokens: parts.find((p) => /tokens$/.test(p)) ?? null,
    tools: parts.find((p) => /tools?$/.test(p)) ?? null,
    model: parts.find((p) => !/tokens$|tools?$|^\d+(\.\d+)?(s|m|h)\b/.test(p)) ?? null,
  };
  const pi = lines.findIndex((l, i) => i > ti && l.trim() === "Progress");
  const qi = lines.findIndex((l, i) => i > ti && l.trim() === "Prompt");
  const fi = lines.findIndex((l, i) => i > ti && l.includes("← to go back"));
  const end = fi >= 0 ? fi : lines.length;
  const recentTools = pi >= 0
    ? lines.slice(pi + 1, qi >= 0 ? qi : end).map((l) => l.replace(/^\s*›\s?/, "").trim()).filter(Boolean)
    : [];
  const promptPrefix = qi >= 0 ? lines.slice(qi + 1, end).map((l) => l.trim()).filter(Boolean).join(" ") : "";
  const footer = fi >= 0 ? joinFooter(lines, fi, /to close|stop all agents/) : "";
  return { kind: "detail", agentType, description, counters, recentTools, promptPrefix, footer };
}

/** 同じ文字列の行が節の中に 2 本以上在る名前の一覧(上の段が「曖昧」と断る材料。此処では断らない)。 */
export function duplicateRows(panel) {
  const seen = new Map();
  for (const s of panel?.sections ?? []) for (const r of s.rows) seen.set(r.text, (seen.get(r.text) ?? 0) + 1);
  return [...seen.entries()].filter(([, n]) => n > 1).map(([text, n]) => ({ text, count: n }));
}

=== real capture (friday 80x24) ===
  general-purpose, both with the exact description "count slowly", and do NOT
  pass a name. Each subagent has exactly one job: run the shell command sleep
  12 with the Bash tool, ten times in a row as ten separate sequential Bash
  tool calls (never in the background), then reply with the single word done.
  Do not use teams, do not use SendMessage, do not read or write files. After
  launching, wait silently for both results.

⏺ 2 background agents launched (↓ to manage)
   ├ count slowly
   └ count slowly

⏺ Both launched, running in background. Waiting for both to finish.

✻ Waiting for 2 background agents to finish
▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   Background
   2 active agents

     Local agents (2)
   ❯ count slowly (running) · Sonnet 5
     count slowly (running) · Sonnet 5

   ↑/↓ to select · Enter to view · f to foreground · x to stop · ctrl+x
   ctrl+k to stop all agents · Esc to close

=== real detail capture (Jervis) ===

 ▐▛███▛█   Claude Code v2.1.263
▝▜██████▀  Fable 5.1 with xhigh effort · Claude Max
  ▝▝ ▝▝    /private/tmp/claude-501/-Users-tomtim/30aa8c14-e081-4ad9-a7dc-81d86cfe5e09/scratchpad/panel-probe-3/cwd

⚠ 1 MCP server needs authentication · run /mcp

❯ Call the Agent tool twice in one single message, both with subagent_type general-purpose, both with the exact
  description "count slowly", and do NOT pass a name. Each subagent has exactly one job: run the shell command sleep 12
  with the Bash tool, ten times in a row as ten separate sequential Bash tool calls (never in the background), then
  reply with the single word done. Do not use teams, do not use SendMessage, do not read or write files. After
  launching, wait silently for both results.

⏺ 2 background agents launched (↓ to manage)
   ├ count slowly
   └ count slowly

⏺ 2体の subagent を起動済み。両方の完了通知を待機中。

✻ Waiting for 2 background agents to finish






▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   general-purpose › count slowly
   30s · 89.2k tokens · 2 tools · Sonnet 5

   Progress
     Bash(sleep 12)
   › Bash(sleep 12)

   Prompt
   You have exactly one job. Run the shell command `sleep 12` using the Bash tool, ten times in a row, as ten
   separate sequential Bash tool calls. Wait for each call to return before issuing the next one. Never use
   run_in_background. Do not combine the sleeps into one command, a loop, or a chain. Do…

   ← to go back · Esc/Enter/Space to close · x to stop · f to foreground · ctrl+x ctrl+k to stop all agents

End with a verdict line: PASS or FAIL naming blocking findings.
2026-09-06T18:11:32.899120Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T18:11:32.932039Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T18:11:33.306195Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
- `parsePanel`: wrapped counts are truncated. Input `Background\n2 active agents ·\n1 shell\nLocal agents (2)` yields `counts: "2 active agents ·"` and silently discards `1 shell`.

- `parsePanel`: wrapped section headers corrupt section ownership. Input after a local section:
  `Team: alpha (phase 2\n) (2)\nagent A\nagent B`
  fails `SECTION`; all four lines become local-agent rows. Unwrapped team names containing ` (` or digits parse correctly.

- `parsePanel`: an unselected row whose text begins `❯ ` is marked selected because `^\s*❯ ` ignores marker column. Concrete row: `     ❯ investigate marker handling`.

- `parsePanel`: overflow detection is not end-anchored. A legitimate row `     ↓ 2 more failures (running) · Sonnet 5` is silently removed into `hints`.

- `parsePanel`: `FOOTER_START` is unanchored. A row containing `investigate ↑/↓ to select text` becomes the footer boundary and that row plus every following row is silently dropped.

- `parseDetail`: only `lines[ti + 1]` is parsed. Input:
  `30s · 89k tokens ·`
  `2 tools · Sonnet 5`
  produces `tools: null`, `model: null`.

- `parseDetail`: splitting counters on every ` · ` corrupts model names. `30s · 89k tokens · 2 tools · Model X · Large` returns model `"Model X"` and drops `"Large"`.

- `parseDetail`: when `Progress` is absent but visible tool rows remain, e.g. `Bash(sleep 12)\nPrompt`, `recentTools` is silently `[]`.

- `parseDetail`: `Do…` is preserved, but the structure cannot distinguish UI truncation from a literal ellipsis because it provides no truncation flag.

Duplicate rows are preserved correctly.

FAIL — blocking findings: section misattribution, false selection, silent row loss, wrapped-counter loss, and model-name truncation.
tokens used
17,226
- `parsePanel`: wrapped counts are truncated. Input `Background\n2 active agents ·\n1 shell\nLocal agents (2)` yields `counts: "2 active agents ·"` and silently discards `1 shell`.

- `parsePanel`: wrapped section headers corrupt section ownership. Input after a local section:
  `Team: alpha (phase 2\n) (2)\nagent A\nagent B`
  fails `SECTION`; all four lines become local-agent rows. Unwrapped team names containing ` (` or digits parse correctly.

- `parsePanel`: an unselected row whose text begins `❯ ` is marked selected because `^\s*❯ ` ignores marker column. Concrete row: `     ❯ investigate marker handling`.

- `parsePanel`: overflow detection is not end-anchored. A legitimate row `     ↓ 2 more failures (running) · Sonnet 5` is silently removed into `hints`.

- `parsePanel`: `FOOTER_START` is unanchored. A row containing `investigate ↑/↓ to select text` becomes the footer boundary and that row plus every following row is silently dropped.

- `parseDetail`: only `lines[ti + 1]` is parsed. Input:
  `30s · 89k tokens ·`
  `2 tools · Sonnet 5`
  produces `tools: null`, `model: null`.

- `parseDetail`: splitting counters on every ` · ` corrupts model names. `30s · 89k tokens · 2 tools · Model X · Large` returns model `"Model X"` and drops `"Large"`.

- `parseDetail`: when `Progress` is absent but visible tool rows remain, e.g. `Bash(sleep 12)\nPrompt`, `recentTools` is silently `[]`.

- `parseDetail`: `Do…` is preserved, but the structure cannot distinguish UI truncation from a literal ellipsis because it provides no truncation flag.

Duplicate rows are preserved correctly.

FAIL — blocking findings: section misattribution, false selection, silent row loss, wrapped-counter loss, and model-name truncation.
```
