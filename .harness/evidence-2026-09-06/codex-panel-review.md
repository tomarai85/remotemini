# Codex adversarial review — PANEL / DETAIL screen states (2026-09-06, codex-quick inline with real fixtures)

Verdict: FAIL. Finding 1 (overlayOf defined twice) was an artifact of the prompt pasting the function twice; the tree has one definition. Findings 2-5 (whole-screen matching lets a quoted panel hide a real composer; first-candidate-only search; 7-line section window) are real and folded in: the classifier now reads only the region below the last ▔ separator and treats a composer below it as 'not an overlay'; five tests pin the false-positive shapes.

```
[codex-quick started pid=16051 13:01:01 timeout=170s — background callers: wait on the pid, do not read the output early]
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
session id: 01a077e1-7e29-7eb1-8fd0-ca4b7c970941
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Adversarial review, under 600 words, no file access (all inline). Findings with function name + concrete failing input; no rewrites. Context: a Node desk classifies a tmux pane's screen text for a phone remote-control of Claude Code. Today it adds two states for Claude Code's agent panel (/tasks) and its Enter detail view, so that the desk never types into those screens and can later drive the panel to stop one subagent. Contract: PANEL/DETAIL must be identified by ROWS (Background header + section header + the ↑/↓ footer joined across a possible 2-line wrap at 80 columns), never inferred from a missing composer; the check runs after the choice-menu check and BEFORE the composer search (the Jervis capture has an echoed prompt line starting with ❯ above the overlay); on the wire the states become screen:UNKNOWN + overlay:panel|detail; the injector refuses with reason panel/detail and types nothing.

=== new code in inject.mjs ===
/** panel の節の見出し。実測(2026-09-06)の 3 種。数は `(N)`。 */
const PANEL_SECTION = /^\s*(Shells|Local agents|Team: .+) \(\d+\)\s*$/;

/** 或る行から始めて、`stop` が出る行まで(最長 `max` 行)を 1 つの文に繋ぐ。80 桁で footer が 2 行に折り返す為。 */
function joinedFooter(lines, from, stop, max = 3) {
  const out = [];
  for (let i = from; i < lines.length && out.length < max; i++) {
    out.push(lines[i].trim());
    if (stop.test(lines[i])) break;
  }
  return out.join(" ");
}

/**
 * agent panel(`/tasks`)か其の詳細画面か。`"PANEL"` / `"DETAIL"` / null。
 *
 * PANEL  = `Background` だけの行 → 其の後に節の見出し(`Shells (N)` 等)→ `↑/↓ to select` から `Esc to close`
 *          までを繋いだ footer。3 つ揃って初めて panel(1 つでも欠ければ null = 今までどおりの判定へ)。
 * DETAIL = `<型> › <説明>` の題 → `·` と `tokens` を持つ数の行 → `Progress` か `Prompt` の行 →
 *          `← to go back` から始まる footer。
 *
 * ★どちらも**画面に在る物**で決め、無い物(composer が無い)からは推測しない —— `UNKNOWN` は読めない画面も
 *   含むので、其処で押すのが一番危ない(設計文 2026-09-04)。
 */
export function panelStateOf(text) {
  const lines = String(text ?? "").split("\n");
  const bg = lines.findIndex((l) => l.trim() === "Background");
  if (bg >= 0) {
    const section = lines.slice(bg + 1, bg + 8).some((l) => PANEL_SECTION.test(l));
    const fi = lines.findIndex((l, i) => i > bg && l.includes("↑/↓ to select"));
    const footer = fi >= 0 ? joinedFooter(lines, fi, /Esc to close/) : "";
    if (section && footer.includes("↑/↓ to select") && footer.includes("Esc to close")) return "PANEL";
  }
  const ti = lines.findIndex((l) => /^\s*\S[^›\n]* › .+$/.test(l));
  if (ti >= 0) {
    const counters = lines.slice(ti + 1, ti + 3).some((l) => l.includes("·") && l.includes("tokens"));
    const section = lines.slice(ti + 1).some((l) => l.trim() === "Progress" || l.trim() === "Prompt");
    const fi = lines.findIndex((l, i) => i > ti && l.includes("← to go back"));
    const footer = fi >= 0 ? joinedFooter(lines, fi, /to close|stop all agents/) : "";
    if (counters && section && footer.includes("← to go back")) return "DETAIL";
  }
  return null;
}

/** 線に載せる形。panel の 2 状態は `UNKNOWN` のまま(古い電話の挙動を変えない)+ `overlay` で正体を足す。 */
export function overlayOf(state) {
export function overlayOf(state) {
  if (state === "PANEL") return { screen: "UNKNOWN", overlay: "panel" };
  if (state === "DETAIL") return { screen: "UNKNOWN", overlay: "detail" };
  return { screen: state, overlay: null };
}

=== classifyScreen hunk ===
436-  //   ★composer より**前**に見る: Jervis の panel 画面には転写の echo(`❯ ` で始まる行)が残っていて、
437-  //   composer の探索が其れを拾えば「送れる」と読む。panel は送れない画面(押した Enter は行を開く)。
438:  const overlay = panelStateOf(s);
439-  if (overlay) return { state: overlay, activity, activityFrom, composer: -1, limited };
440-  const composer = findComposer(s);

=== refusal site ===
1101-    if (s.state !== "SENDABLE") {
1102-      if (s.state === "CHOICE") return { typed: 0, reason: "choice" };
1103:      if (s.state === "PANEL") return { typed: 0, reason: "panel" };
1104-      if (s.state === "DETAIL") return { typed: 0, reason: "detail" };
1105-      return { typed: 0, reason: "unknown" };

=== a real friday capture (80 cols) the code must classify as PANEL ===
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

=== a real Jervis capture that must NOT be PANEL (panel closed) ===


                                                                                                     ◉ xhigh · /effort
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Fable 5.1 | Sleep for 12 seconds (2/10) | SUBAGENT x2
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent

  ⏺ main
  ◯ general-purpose  Running sleep 12 (1/10)                                                      31s · ↓ 89.3k tokens
  ◯ general-purpose  count slowly                                                                 29s · ↓ 89.2k tokens

Hunt: false positives (a transcript that merely CONTAINS these words — e.g. Claude printing a snippet of the panel, or a message containing 'Background' and 'Local agents (1)' and the footer text), false negatives (scroll hints at the 5-row cap, 'Team:' blocks, a '↓ N more' overflow line, a detail view whose Prompt section is empty), regexes over the whole screen vs the region below the ▔▔▔ separator, the joinedFooter max=3, the Team header regex, and whether classifying BEFORE findComposer can hide a real composer in any legitimate screen. End with a verdict line: PASS or FAIL naming blocking findings.
2026-09-06T18:01:02.612637Z ERROR codex_core_skills::loader: failed to stat skill path file:///Users/tomtim/.codex/skills/.system/imagegen/assets/imagegen.png: No such file or directory (os error 2)
2026-09-06T18:01:02.612676Z ERROR codex_core_skills::loader: failed to stat skill path file:///Users/tomtim/.codex/skills/.system/imagegen/assets/imagegen-small.svg: No such file or directory (os error 2)
2026-09-06T18:01:02.807008Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T18:01:02.810045Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-09-06T18:01:03.353194Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. **`overlayOf` — 構文エラー（致命的）**  
   `export function overlayOf(state) {` が二重です。このモジュールはロード不能で、分類処理まで到達しません。

2. **`panelStateOf` — transcript 内の引用で PANEL 誤判定**  
   失敗入力:
   ```text
   Background
   Local agents (1)
   ↑/↓ to select · Enter to view
   Esc to close
   ─────────────────────
   ❯ 本物の composer
   ```
   画面全体を検索するため PANEL になり、`findComposer` より前に返して正規 composer を隠します。injector は `reason: "panel"` で拒否します。

3. **`panelStateOf` — DETAIL も無関係な行を合成して誤判定**  
   失敗入力:
   ```text
   worker › example
   1s · 100 tokens
   （通常の会話）
   Progress
   ← to go back
   ─────────────────────
   ❯ 本物の composer
   ```
   title、counter、section、footer の同一 overlay 所属を検証せず、画面全域から拾います。

4. **`panelStateOf` — 最初の候補だけを見るため実在 overlay を見落とす**  
   transcript に先行する `Background` があり、その直後7行以内に section がない場合、下方に本物の `Background` + `Local agents (2)` + footer があっても再探索せず null になります。DETAIL も、先行する `foo › bar` が不完全なら後方の本物の detail titleを調べません。

5. **`panelStateOf` — section の7行制限で偽陰性**  
   失敗入力:
   ```text
   Background
   2 active agents
   hint 1
   hint 2
   hint 3
   hint 4
   hint 5
   ↓ 3 more
   Team: alpha (2)
   ↑/↓ to select · Enter to view
   Esc to close
   ```
   `Team:` が範囲外です。スクロールヒントや overflow 行を含む表示に弱いです。

`Team: .+ \(\d+\)` は通常名なら通り、`↓ N more` は範囲内なら妨げません。空の Prompt も見出し行があれば通ります。`joinedFooter(max=3)` は契約上の80列・2行折返しには十分です。

**FAIL — blocking: `overlayOf` の構文エラー、および全画面横断マッチによる composer 隠蔽。**
tokens used
15,792
1. **`overlayOf` — 構文エラー（致命的）**  
   `export function overlayOf(state) {` が二重です。このモジュールはロード不能で、分類処理まで到達しません。

2. **`panelStateOf` — transcript 内の引用で PANEL 誤判定**  
   失敗入力:
   ```text
   Background
   Local agents (1)
   ↑/↓ to select · Enter to view
   Esc to close
   ─────────────────────
   ❯ 本物の composer
   ```
   画面全体を検索するため PANEL になり、`findComposer` より前に返して正規 composer を隠します。injector は `reason: "panel"` で拒否します。

3. **`panelStateOf` — DETAIL も無関係な行を合成して誤判定**  
   失敗入力:
   ```text
   worker › example
   1s · 100 tokens
   （通常の会話）
   Progress
   ← to go back
   ─────────────────────
   ❯ 本物の composer
   ```
   title、counter、section、footer の同一 overlay 所属を検証せず、画面全域から拾います。

4. **`panelStateOf` — 最初の候補だけを見るため実在 overlay を見落とす**  
   transcript に先行する `Background` があり、その直後7行以内に section がない場合、下方に本物の `Background` + `Local agents (2)` + footer があっても再探索せず null になります。DETAIL も、先行する `foo › bar` が不完全なら後方の本物の detail titleを調べません。

5. **`panelStateOf` — section の7行制限で偽陰性**  
   失敗入力:
   ```text
   Background
   2 active agents
   hint 1
   hint 2
   hint 3
   hint 4
   hint 5
   ↓ 3 more
   Team: alpha (2)
   ↑/↓ to select · Enter to view
   Esc to close
   ```
   `Team:` が範囲外です。スクロールヒントや overflow 行を含む表示に弱いです。

`Team: .+ \(\d+\)` は通常名なら通り、`↓ N more` は範囲内なら妨げません。空の Prompt も見出し行があれば通ります。`joinedFooter(max=3)` は契約上の80列・2行折返しには十分です。

**FAIL — blocking: `overlayOf` の構文エラー、および全画面横断マッチによる composer 隠蔽。**
```
