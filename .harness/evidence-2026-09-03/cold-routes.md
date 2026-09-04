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


## The write half, on a disposable session

The six write routes could not go into the read-only instrument, so they got their own:
`rc-backend/tools/live-write-routes-check.mjs`. Its safety rests entirely on
`tools/disposable-session.mjs`, whose own header records that it creates only tmux sessions named
`rc-e2e-<digits>` and therefore **has no path to touch a real conversation**. The instrument deliberately takes
no session-id argument — accepting one would create exactly that path.

Measured, three consecutive runs, all green: `title` (set, read back in the listing, clear back to null) and
`archive` (set, appears under `scope=archived`, unset). Both had never executed against the real desk.

Not measured, on purpose: `choice` sends a key to a menu screen and could press an approval, so it never runs
against a live desk; `attach-file` is safe on a disposable session but belongs in its own tier rather than
mixed with reversible writes; `queue` returns 409 `queue-not-ours` for a disposable pane, which is the desk
correctly refusing, not a defect — putting a structurally-refused route in an instrument makes a permanent red.

### Four mistakes worth keeping, all mine

1. **I left four disposable sessions on the desk.** `reap` only sweeps sessions older than 60 minutes by
   default, so freshly built ones are never its target. Teardown needs `down <tmux-name> <session-id>`.
2. **I then reported those four as "0".** Non-interactive ssh has a short PATH without `/opt/homebrew/bin`, so
   `tmux ls | grep -c` printed 0 because the command was not found. **A missing command and an empty result are
   indistinguishable through a counter.** The instrument now resolves `node` and `tmux` up front and exits 2
   rather than reading a 0.
3. **I briefly believed I had killed Tom's real session**, because the same PATH problem made every pane look
   dead. It had not; `work` was untouched throughout.
4. **The teardown result was nondeterministic** across runs. The cause was ordering: `limited` was being asked
   *after* the session was torn down, so it queried a dead pane and its non-zero ssh polluted the measurement.
   Asking before the teardown fixed it — **observe before you destroy, or the observation reports on the
   destruction.**

Controls (`rc-backend/test/live-write-routes-controls.sh`): 13 / 13, each field failed individually. The
`torn_down` case is called out as heavier than the others: missing that red leaves sessions piling up on the
desk, which is what happened the day it was written.

## Observed

| what | result |
|---|---|
| live run against the production desk | `rc=0`, all six conditions green |
| read-only controls | 14 / 14 |
| write controls | 13 / 13 |
| write instrument, live | rc=0 three runs, 0 leftovers |
| `live-exit-codes.test.mjs` (the census, now with both instruments) | 44 / 44 |
