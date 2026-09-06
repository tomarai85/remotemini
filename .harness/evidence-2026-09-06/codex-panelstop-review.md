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

## Round 4 — `codex-panelstop-review6.out`
(appended below when the run finishes)
