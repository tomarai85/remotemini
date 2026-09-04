# Nine shipped routes had never run against the real desk (2026-09-04)

The parity table was declared exhausted, so the question became what to build next. Three lenses ran in
parallel: a usage census of the production request log, an adversarial Codex read of the repo, and a check of
whether the official product had moved since the table's 2026-09-01 snapshot. The census produced the finding
that changed the plan.

## What the log says

Eight days of the desk's request log (2026-08-27 to 2026-09-04, 1,172 requests from `client=app`, no gap day).
Grouped by path, the phone has ever touched exactly eight endpoints:

| path | count |
|---|---|
| `GET /api/account` | 477 |
| `GET /api/sessions` | 450 |
| `GET /api/sessions/:id/poll` | 158 |
| `GET /api/sessions/:id/history` | 38 |
| `GET /api/sessions/:id/digest` | 32 |
| `POST /api/sessions/:id/messages` | **11** |
| `POST /api/sessions/:id/interrupt` | 5 |
| `POST /api/account/select` | 1 |

Seventy-nine per cent of it is the account and session-list screens. Actual sends: eleven in eight days.

Nine routes with a **finished iOS client** have zero traffic: `diff`, `status`, `paths`, `title`, `archive`,
`clearQueue`, `choice`, `attach-file`, `new`. Their tests are green and their e2e is green, but that e2e runs
against a fake tmux and a local server. On the real desk they had never executed.

## The distinction that mattered

"Never used" is not "broken". Before firing them, I could not tell which. So I fired the three read-only ones
by hand against the production desk:

| route | result |
|---|---|
| `status` | 200, `screen=SENDABLE` / `route=tmux` / `permissionMode` present |
| `diff` | 200, **36,471 bytes** of real uncommitted diff |
| `paths` | 200, the cwd listing |

They work. The defect was never in the code — it was that nothing distinguished "works" from "unknown", and
the project had been treating a green fixture suite as if it settled the question.

## The instrument

`rc-backend/tools/live-cold-routes-check.mjs` joins the twelve existing `live-*` instruments. It hits the
three read-only cold routes on the real desk and checks two things per route: a 200, **and** that the body
carries the key the phone's decoder requires (`screen` / `files` / `paths`). Status alone would go green
against a desk returning `{}`.

Exit codes follow the fleet contract: 0 closed by observation, 1 red, 2 aborted in setup, 3 not measured —
including when the desk is at its usage limit, where a green reading is not evidence of anything.

The write routes (`new`, `title`, `archive`, `choice`, `clearQueue`, `attach-file`) are deliberately **not** in
this instrument. They mutate the real desk, and that is a separate decision rather than something to fold
silently into a read-only check.

Controls (`rc-backend/test/live-cold-routes-controls.sh`): 14 / 14. Each route is failed individually rather
than as a set, because a verdict that only inspects one of three would pass a batch test. Three cases fail a
200 whose body lacks the required key. Three assert that an unreachable route reads as 3, not as red. Two
assert that a limited desk never reports green, and that the limit outranks a red observation.

Two census findings against my own instrument, both fixed: the exit-3 path was hidden behind an `EXIT`
constant where the static census could not see it (a value folded into a constant is invisible to the detector
that greps for it), and the header's exit-code explanation had split the "3 = limit" meaning across two lines.

## Observed

| what | result |
|---|---|
| live run against the production desk | `rc=0`, all six conditions green |
| controls | 14 / 14 |
| `live-exit-codes.test.mjs` (the census that now includes it) | 41 / 41 |
