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

## Production measurement — friday, 2026-09-06 21:05 (desk `5b8f728`, service pid 18564)

`node rc-backend/tools/live-subagent-stop-check.mjs` from Jervis (raw log: `live-subagent-stop-run1.log`):

```
send HTTP 202 (0s) → running=2 (31s) → target=a6de70ba039382014 (sleep 13) peer=ad7d13792955b159b (sleep 12)
stop HTTP 200 stopped=observed
keys=["-l /tasks","Enter","Enter","Escape","-l /tasks","Enter","Down","Enter","Escape","-l /tasks","Enter","Enter","-l x","Escape"] escapes=3 (34s)
target 183102->183102 bytes (frozen)   peer 181993->198610 bytes (still writing)   over 30 s
torn_down=1   verdict: kind=ok … → 閉じた(0)
```

What the real TUI did, now measured (it had only been modelled before):
- the panel listed the two same-description rows; the target sat on row **0** on this desk (the panel's order is not
  the launch order). The plan opened row 0 (match, but row 1 unseen → close), reopened, moved Down, opened row 1
  (mismatch → close), reopened and returned to row 0, and only then pressed `x` — the "return to the seen match"
  path the local e2e had forced into the planner an hour earlier;
- `x` in the detail view returns to the PANEL with the stopped row gone (the driver counted the same-text running rows
  decreasing and only then called it observed); one guarded Escape closed the panel;
- the stopped agent's transcript stopped growing at once; the peer kept appending (`sleep 12` × 10 in progress).

## Production measurement, run 3 — friday, 2026-09-07 08:12 (desk `0ad44c9`, the c3b code)

Run 2 aborted at "choose" (exit 3, not measured): the stricter target choice (contains `sleep 13` and not `sleep 12`)
matched neither transcript, because the parent writes both words into each subagent's prompt. The instrument now
picks by the DIFFERENCE of line counts (tool calls dominate). Run 3 (`live-subagent-stop-run3.log`):

```
running=2 (21s) → target=a096d7e1231c1f931 (+1) peer=aa016263e4a7f9a46 (−1)
stop HTTP 200 stopped=observed after={"screen":"SENDABLE","overlayClosed":true,"stopObserved":"panel"}
keys=[…14 keys, the same "see both, return to the seen match" shape as run 1…] escapes=3 (24s)
target 178328→180837→180837→180837 (frozen across both intervals)   peer 180249→181747→195456→200506 (growing in both)
kind=ok … → 閉じた(0)
```

So the c3b hardening (first-line/return-to-match planner, empty-panel handling, tail-side tools, no-body route) stops
the right agent on the real TUI too, and the success is now bound to the panel's row count, not to "the overlay closed".

## Codex adversarial review of c3 (`codex-c3-review.out`) — VERDICT: FAIL (6 fatal, 5 serious)
OpenAI Codex v0.144.3
session id: 01a0787f-1562-7250-8a62-4fbd7b2b7d8b

| # | severity | finding | disposition (commit c3b) |
|---|---|---|---|
| 1 | FATAL | a session with a worker branch: the listing shows the branch's agents while the pane belongs to the ancestor → a same-description agent on the pane could be stopped | route refuses `no-pane` (why `worker-branch`) when `transcriptTarget() !== file` |
| 2 | FATAL | `allowShells` accepted from the HTTP body disabled the shell guard | the route reads no options at all; the body is drained (413 on too large) |
| 3 | FATAL | the 12 MB cap took the FIRST 12 MB, so "recent" tools were the oldest | prompt from the head (256 KB), tools from the TAIL (512 KB), both via fd reads |
| 4 | FATAL | the re-capture before `x` compared only type + description | it now compares prompt prefix and tool list too |
| 5 | FATAL | `stopped:"observed"` fired on "overlay closed" or a bare count drop; non-overlay screens counted as closed | observed only when the PANEL shows the same-text running rows decreased; if the overlay closed, `/tasks` is reopened to count; any other screen → `unverified` |
| 6 | FATAL | a finished-but-fresh target + a stalled same-name sibling + prompts identical for 297 chars | siblings = every non-finished same-description agent (running/stalled/unknown); a prompt that matches a sibling's first 297 chars is dropped from the target (tools must discriminate) |
| 7 | SERIOUS | `readFileSync` of a multi-GB transcript | head/tail fd reads |
| 8 | SERIOUS | route id regex (80) narrower than the listing's (128) | both 128, same charset |
| 9 | SERIOUS | body errors bypassed the closed contract | no body parsing; too-large → the server's shared 413 |
| 10 | SERIOUS | instrument could pass with an ambiguous target, a stat failure read as 0, one late append, `limited=unknown` | target = exactly one transcript with `sleep 13` and not `sleep 12`; stat failure aborts; peer must grow across two intervals; unknown limit → not measured |
| 11 | SERIOUS | the fake pane's `x` always returned to the composer → "observed" was vacuous | the fake now returns to the PANEL with the row removed (what the real TUI did above) and a no-effect variant yields `unverified` |

A consequence of #6 worth naming: a same-description sibling that is stalled (no output for 15 min) but NOT on the
panel now makes the count exceed the rows shown, and the desk refuses `ambiguous`. That is the safe side (the
alternative was Codex's fatal case); the cost is a refusal until the listing marks the sibling finished. The e2e's
stale agent was given a different description for this reason.

Found while pinning #5 with the simulator (not by Codex): after stopping the LAST agent the panel has no section at
all (`Background` + footer only), which `panelStateOf` does not call PANEL — the driver therefore neither counted it as
"decreased" nor pressed Escape to close it. `emptyPanel()` now treats that shape as an open overlay with zero rows.
The production run above never hit it (two agents, one survived); the single-agent case is still unmeasured on the
real TUI and is named as a limit.
