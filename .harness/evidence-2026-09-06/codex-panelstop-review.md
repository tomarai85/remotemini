# Codex adversarial review — `rc-backend/src/panelstop.mjs` (row #8 stop half, step c1) — 2026-09-06

Reviewer: OpenAI Codex v0.144.3 via `~/.claude/tools/codex-review.sh` (read-only sandbox, `--cwd rc-backend`).
Attack brief: scratchpad `codex-panelstop-review-prompt.md` (goals: press `x` on the wrong agent or a shell row = fatal;
`verifySelection` ok while the marker is elsewhere = fatal; misleading refusal / throw / vocabulary leak /
`detailMatches` false positive or negative / assumptions that `parsePanel`/`parseDetail` do not honour = serious).

## Round 1 — `codex-panelstop-review3.out`
OpenAI Codex v0.144.3
session id: 01a07808-9888-7dd1-834e-6cd30ba2dad8

The wrapper was killed mid-run (harness background-task stop), but the reviewer's progress narration had already
named three findings, all real:
1. A single same-description row was pressed without a detail check — the twin that finished earlier leaves the
   OTHER agent alone on the panel. Fixed: no row-only press path exists; every press goes through a matched detail.
2. An untruncated prompt was accepted by prefix. Fixed: untruncated = whole-string equality.
3. `verifySelection` ignored position and accepted any same-text row after a detail. Fixed: position required.

## Round 2 — `codex-panelstop-review4.out` — VERDICT: FAIL (10 findings)
OpenAI Codex v0.144.3
session id: 01a07813-670b-7211-abe3-cb42f0f926f2

| # | severity | finding | disposition |
|---|---|---|---|
| 1 | FATAL | identical twin, one finished: the survivor is pressed | `target.live` and `target.liveSameDescription` required from the desk; desk count > shown rows → `ambiguous` |
| 2 | FATAL | `verifySelection` ignored `index` inside the section | flat + section + index + text all compared |
| 3 | FATAL | a prompt literally ending in `…` is read as UI truncation | truncated prefix is evidence only when ≥ `MIN_PREFIX` (40) chars; a target that would have fit must match whole |
| 4 | FATAL | `\s+` squash erased meaningful whitespace in code | only line folds (newline + indent) are normalised |
| 5 | FATAL | target had prompt + tools, detail lacked the prompt, tools alone matched | every material the target has must be present on the detail, else `insufficient` |
| 6 | SERIOUS | driver contract said `exclude`, function only read `examined` | both accepted; `exclude` = seen with no detail |
| 7 | SERIOUS | 80-column wrap of `Team: <long name> (N)` parsed as shell rows | `parsePanel` merges the wrapped header (`test/panel-model-wrapped-header.test.mjs`) |
| 8 | SERIOUS | section without `rows` threw | `flatRows` tolerates malformed input; refusals, never throws |
| 9 | SERIOUS | `reason: null` on success | removed |
| 10 | SERIOUS | `sameShape` ignored counts / overflow | counts, section counts, hints compared |

Each finding is pinned as a test in `test/panel-stop.test.mjs` (★ lines cite the Codex number).

## Round 3 — `codex-panelstop-review5.out` — VERDICT: FAIL (7 findings)
OpenAI Codex v0.144.3
session id: 01a0781e-ba75-79b1-b511-023caf4c03a2

| # | severity | finding | disposition |
|---|---|---|---|
| 1 | SERIOUS | a wrapped `Team:` header as the ONLY section: `panelStateOf` never saw a section, so `parsePanel` returned null before the merge ran | `panelStateOf` (inject.mjs) and `parsePanel`'s first-section scan both accept the two-line header |
| 2 | SERIOUS | `description + " ("` is not a boundary: `deploy (backup)` matched target `deploy` | `rowDescription` = text before the LAST ` (<status>)` (optional ` · <model>`) |
| 3 | FATAL | two `❯` markers in one capture: parser's `selected` = last, `verifySelection` took the first | zero or ≥2 markers = `reflow` in both `planStop` and `verifySelection` |
| 4 | FATAL | `section: null` / `index: null` acted as wildcards | all four of flat / section / index / text mandatory; missing = `mismatch` |
| 5 | SERIOUS | `foldLines` trimmed the whole prompt, so `"  Run this"` matched `"Run this"` | only newline folds are normalised (leading blank lines and trailing newlines dropped); inner, leading and trailing spaces kept |
| 6 | SERIOUS | a ≥40-char prompt literally ending in `…` still matched by prefix | measured: the UI cuts prompts at 297 chars + `…` on both 80 and 120 columns (both fixtures = 298). A trailing `…` with < `TRUNC_MIN` (250) visible chars is therefore literal → whole match only (`insufficient` if the target merely starts with it) |
| 7 | SERIOUS | `maxMoves: Symbol()` threw | non-integer / negative `maxMoves` falls back to the default 8 |

Pinned as tests: `test/panel-stop.test.mjs` (★ `Codex r3#n`) and `test/panel-model-wrapped-header.test.mjs`.

## Round 4 — `codex-panelstop-review6.out` — VERDICT: FAIL (8 findings)
OpenAI Codex v0.144.3
session id: 01a0782e-6bf7-7be0-bf52-40e78c0086a0

| # | severity | finding | disposition |
|---|---|---|---|
| 1 | FATAL | an examined candidate whose prompt was off-screen (`insufficient`) was counted as a non-match, so the other twin got pressed | verdicts are 3-valued (hit / miss / undecided); any undecided candidate → `ambiguous` |
| 2 | SERIOUS | a detail with no `agentType` matched a typed target | `insufficient` |
| 3 | SERIOUS | `planStop(null)` threw | non-object args → `not-a-panel` |
| 4 | SERIOUS | `parseDetail` trimmed prompt lines, erasing leading spaces the matcher was told to respect | only the 3-space overlay indent is stripped |
| 5 | SERIOUS | a long agent description wrapping to a second line became two fake rows | `parsePanel` merges a row that lacks the ` (<status>)` tail with its continuation (teammate `@name: status` rows exempt) |
| 6 | SERIOUS | a wrapped detail title truncated the description and polluted the counters | title continuation lines (before the counters line) are joined into the description |
| 7 | SERIOUS | Team headers wrapping to 3+ lines were not a panel | header span up to 4 lines in both `panelStateOf` and `parsePanel` |
| 8 | SERIOUS | a truncated tool line ≥ 12 chars still "proved" identity | truncated tool lines are consistent-only: evidence for a sole live candidate, `insufficient` whenever a same-description sibling exists (`strict`) |

Pinned as tests: `test/panel-stop.test.mjs` (★ `Codex r4#n`) and `test/panel-model-wrapped-header.test.mjs`.

## Round 5 — `codex-panelstop-review7.out` (planner + driver) — VERDICT: FAIL (3 fatal, 5 serious)
OpenAI Codex v0.144.3
session id: 01a0783d-7b26-7022-a33d-421b98466f09

All eight are about the driver (`src/panelstop-driver.mjs`, landed in `7522859` unwired) and its simulator.
Dispositions are applied in the follow-up commit named in the "fix" column.

| # | severity | finding | fix |
|---|---|---|---|
| 1 | FATAL | `/tasks` appended to existing composer text and submitted to the parent | require an empty composer before typing; echo must equal `/tasks` exactly; otherwise nothing is pressed and the leftover is retracted (Backspace × 6 only when the composer is exactly `/tasks`) |
| 2 | FATAL | a stale frame after Escape led to a second Escape (= parent interrupt) | one Escape per operation unless a close was observed in between; an unobserved close returns `escape-unverified` (new closed reason) |
| 3 | FATAL | agent finishes between the detail capture and `x`; the TUI is back on the panel with the marker on a shell row; `x` kills the shell | re-capture immediately before `x` (must still be the same detail); refuse `shell-row` when any shell row is present unless the caller opts in (`allowShells`); the residual race is a TUI input-state race and is named as a limit |
| 4 | SERIOUS | any redraw (a counter tick) counted as "x worked" | success only when the same detail is gone (overlay closed or PANEL without that row still `(running)`); staying in the same detail = `unverified` |
| 5 | SERIOUS | late redraws left `/tasks` in the composer or a panel open after a refusal | a grace poll before each refusal; leftover text retracted; a late panel is closed with the guarded Escape |
| 6 | SERIOUS | `budgetMs: NaN` held the pane mutex forever | validated before entry, default on nonsense |
| 7 | SERIOUS | an empty pane threw `MUTEX_KEY` | validated before entry → `no-pane` (new closed reason); any other mutex error → `pane-busy` |
| 8 | SERIOUS | the simulator mutates state and renders it in the same step, so stale frames / input-vs-render divergence / animated redraws cannot be expressed | the simulator gains a frame lag (`lag` captures behind the input state) and a counter tick on detail frames; findings 2–5 are pinned with it |
