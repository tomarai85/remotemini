# The phone can now stop one named subagent — route, e2e, and the production measurement (row #8 stop half, step c3) — 2026-09-06

## What landed

`POST /api/sessions/:id/subagents/:agentId/stop` (tmux route only). The desk builds the target from the agent's
transcript (`rc-backend/src/subagentstop.mjs`: agentType + description from `agent-<id>.meta.json`, the full prompt
and the ordered tool calls from `agent-<id>.jsonl`, rendered like the panel renders them — `Bash(<command>)`), adds
liveness and the count of live same-description agents from the listing, and hands it to the c2 driver. Every refusal
is 409 with a closed-vocabulary `reason` and a sentence in `error`; success is 200 `stopped:"observed"`.

## e2e 13-e (fake pane `%30` that changes screens on keys)

Two same-description agents (prompts differ: `sleep 12` vs `sleep 13`), a stale third, a paneless session, a pane
showing a choice menu. Observed in `node test/e2e-local.mjs`:

| case | result |
|---|---|
| stop the 2nd agent (`sleep 13`) | 200 `stopped:"observed"`; `x` reached row 1; keys `/tasks, Enter, Enter, Esc, /tasks, Enter, Down, Enter, x` |
| stop the 1st agent (`sleep 12`) | 200; keys `… Esc, /tasks, Enter, Enter, x`; `x` reached row 0 |
| stale agent | 409 `not-live`, zero keys |
| unknown id | 409 `no-such-agent`, zero keys |
| paneless (worker route) session | 409 `no-pane`, zero keys |
| choice menu on the pane | 409 `not-sendable`, zero keys |
| Escape into the composer | 0 (every Escape landed on an overlay) |

**The e2e found a planner defect** the five Codex rounds had not: with two same-description rows and the target being
the FIRST, the plan opened row 0 (match) → closed (row 1 unseen) → opened row 1 (mismatch) and then refused
`mismatch`, although the match had already been seen on row 0. `planStop` now returns `close-detail` with `final`
so the driver reopens and returns to the matched row. Pinned in `test/panel-stop.test.mjs` and
`test/panel-stop-driver.test.mjs`.

## Production measurement

(appended below by `tools/live-subagent-stop-check.mjs` after the deploy)
