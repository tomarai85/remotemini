# Spec — `classifyScreen` learns the agent panel (`PANEL`) and its detail view (`PANEL_DETAIL`) (2026-09-06)

Mode 2 (Quick). Loop task `subagent-panel-state-fixtures-landed` (row #8 stop half, decomposition step a). Verify:
`cd rc-backend && test -d test/fixtures/panel && ! grep -rEq '@[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' test/fixtures/panel && node --test test/inject-panel-state.test.mjs` passes; the full desk suite stays green.

## Why (from disk)

`research/subagent-stop-panel-design-2026-09-04.md` requires a real `PANEL` state in `classifyScreen`, identified by
the panel's **rows**, never by footer text alone, and never inferred from "no composer found" (today's `UNKNOWN`
also covers an unreadable screen — the worst moment to press anything).
`research/subagent-stop-panel-row-identifier-measurement-2026-09-06.md` measured what the panel and its `Enter`
detail view look like on both machines: a `Background` header, a counts line (`2 active agents` /
`2 active shells · 1 active agent`), section headers (`Shells (N)` / `Local agents (N)` / `Team: … (N)`), rows
(`❯ ` selection marker in column 4), and a footer starting `↑/↓ to select` that **wraps onto two lines at 80
columns**; the detail view has a `<agentType> › <description>` title line, a counters line, `Progress` and
`Prompt` sections, and a footer starting `← to go back`. On Jervis the transcript above the overlay still
contains the echoed prompt line beginning `❯ ` — that line is NOT a composer and must not make the screen
`SENDABLE`.

## Behaviour

1. `rc-backend/src/inject.mjs` `classifyScreen(text)` returns two new states, checked **after** `menuAt`
   (a choice menu still wins) and **before** `findComposer`:
   - `PANEL` when the screen holds the overlay: a line whose trimmed text is exactly `Background`, followed within
     a few lines by at least one section header matching `^\s*(Shells|Local agents|Team: .+) \(\d+\)\s*$`, and a
     footer that, after joining consecutive footer lines, contains `↑/↓ to select` (the footer may be 1 or 2
     lines; join lines until one contains `Esc to close`). All three parts are required; any missing → not PANEL.
   - `PANEL_DETAIL` when the screen holds the detail view: a title line matching `^\s*\S[^›\n]* › .+$` followed by
     a counters line containing `·` and `tokens`, a line whose trimmed text is `Progress` or `Prompt`, and a footer
     (joined as above) containing `← to go back`.
   - Both carry `activity`/`activityFrom`/`limited` exactly as today and `composer: -1`.
   - Existing behaviour for every other screen is unchanged: same states, same composer index. The existing
     `inject.test.mjs` and `inject-serial.test.mjs` must pass untouched.
2. `rc-backend/src/server.mjs` `screenOf`: the wire `screen` value for the two new states is `"UNKNOWN"` (the
   phone's `Classification` enum has an `.unrecognized` fallback, but the send/attach copy for `UNKNOWN` is the
   right user-facing behaviour today and old builds must not change). Add one additive key `overlay:
   "panel" | "detail" | null` to `screenOf`'s result so the value is not lost; register it wherever the wire
   ledgers demand (`test/wire-vocabulary-agreement.test.mjs`, `test/wire-key-agreement.test.mjs`,
   `test/wire-shape-controls.sh` — follow what they say, never weaken them).
3. The injector's refusal path (`#typeLiteralGuarded`, `#sendExclusive`) already refuses every non-`SENDABLE`
   state; confirm with a test that a PANEL screen is refused with a reason that names the panel (add
   `panel-open` to the refusal vocabulary in `inject.mjs` and `SEND_REFUSAL` in `server.mjs` — the
   `send-refusal-vocabulary.test.mjs` ledger enforces 1:1; give it a sentence a person can act on: close the
   agent panel on the desk with Esc, then send again).

## Fixtures (`rc-backend/test/fixtures/panel/`)

Copy these captures verbatim (they contain no account email; keep the `[rc %NN]` statusLine lines):
- from `/private/tmp/claude-501/-Users-tomtim/30aa8c14-e081-4ad9-a7dc-81d86cfe5e09/scratchpad/panel-probe-3/`
  (Jervis, 120 cols, bare claude 2.1.259): `panel-open.txt` → `jervis-panel-open.txt`, `panel-down1.txt` →
  `jervis-panel-down1.txt`, `detail-open.txt` → `jervis-detail-open.txt`, `panel-closed.txt` →
  `jervis-panel-closed.txt`, `running.txt` → `jervis-running.txt`.
- from `/private/tmp/claude-501/-Users-tomtim/30aa8c14-e081-4ad9-a7dc-81d86cfe5e09/scratchpad/panel-probe-friday-3/`
  (friday, 80x24, rc-claude 2.1.263 with statusLine): `panel-open.txt` → `friday-panel-open.txt`,
  `panel-down1.txt` → `friday-panel-down1.txt`, `detail-open.txt` → `friday-detail-open.txt`,
  `after-esc1.txt` → `friday-after-esc1.txt` (overlay closed), `running.txt` → `friday-running.txt`.
- Add `README.md` in the fixtures dir: one line per file saying machine, columns, Claude Code version, and
  what the screen shows. Fixture files must not be edited by hand afterwards (they are evidence).

## Tests (`rc-backend/test/inject-panel-state.test.mjs`; must FAIL when the feature is reverted)

- Each `*-panel-open.txt` and `*-panel-down1.txt` → `PANEL`; each `*-detail-open.txt` → `PANEL_DETAIL`;
  `jervis-panel-closed.txt`, `friday-after-esc1.txt`, `*-running.txt` → NOT panel states (assert the exact
  state today's code returns for them, so the negatives are pinned, not just "not PANEL").
- The Jervis panel screen contains a `❯ ` transcript echo line: assert `PANEL`, never `SENDABLE`.
- 80-column footer wrap: build a screen from `friday-panel-open.txt` with the two footer lines and assert
  `PANEL`; then delete the second footer line (`ctrl+k to stop all agents · Esc to close`) and assert the
  screen is no longer `PANEL` (footer incomplete) — this pins the join.
- Mutation controls (negative): remove the section-header requirement in a scratch copy → the `running`
  negatives must go red (a `Background` word alone must not classify); remove the `Background` requirement →
  a synthetic screen with only a section header must not classify.
- `screenOf`-level: a unit test on the wire mapping function (export a pure helper from `wire.mjs` or
  `inject.mjs`, do not import `server.mjs`) asserting PANEL → `screen:"UNKNOWN", overlay:"panel"`,
  PANEL_DETAIL → `overlay:"detail"`, SENDABLE → `overlay:null`.
- Refusal: `TmuxInjector` with a fake tmux whose capture is a PANEL screen refuses `sendLiteral`/`#sendExclusive`
  with `reason:"panel-open"` and types nothing (count send-keys calls = 0).

## Constraints (lane)

No test imports `server.mjs`. Do not touch `choice.mjs`, `subagents.mjs`, `agentscache.mjs`. Never
`git stash`/`git checkout --`/`--no-verify`. Do not commit; leave the diff staged in the worktree. Run
`cd rc-backend && npm test` (exact counts before/after), `bash test/send-refusal-vocabulary.test.mjs` via
`node --test`, the wire ledgers, and `bash rc-backend/tools/preflight-ledgers.sh` from the worktree root
(every line). Write `.harness/progress-2026-09-06-panel-states.md` in the worktree: files, counts, ledgers
that stopped you and how you satisfied them, anything undone with the reason.
