# #11 roots-restricted new session (2026-09-03, Mode 2)

Tom ruling (2026-09-03 afternoon): implement parity row #11 restricted to a roots allowlist. Spec written by the
Planner agent: `.harness/spec-2026-09-03-roots-new-session.md` (`has_design_decisions: false`). Implementation by the
main session with gates; Codex adversarial review recorded below when it runs.

## Desk

| Piece | Where | Evidence |
|---|---|---|
| ledger + containment | `rc-backend/src/roots.mjs` | `test/roots.test.mjs` 9 tests; mutants: prefix containment 3 red, fail-open ledger 1 red, unresolved symlink 2 red |
| three doors + session `new` with `cwd` | `rc-backend/src/rootsroute.mjs`, `src/server.mjs` | `test/roots-routes.test.mjs` 16 tests (spec's 15 + rootAt) |
| route table | `rc-backend/src/reqlog.mjs` (`ROOTS_ROUTE_RE`, `pathShape`) | `test/reqlog.test.mjs` single-copy test |
| `dirsOnly` | `rc-backend/src/paths.mjs` | `test/paths.test.mjs` limit/truncated honesty |
| envelope | `rc-backend/src/wire.mjs` `rootsBody` | index + label only (route test 4, mutant M4) |

Route-layer mutants (each restored from a copy, changed-line count printed):
M1 skip `resolveUnderRoots` and hand the joined path to tmux -> 2 red; M2 answer 200 on `outside_roots` -> 1 red;
M3 empty ledger defaults to home -> 1 red; M4 `rootsBody` carries `path` -> 1 red.

## A pre-existing defect the e2e found

`SESSION_ROUTE_RE` did not list `new`. The handler for `POST /api/sessions/<id>/new` (added 2026-08-31, cf41905)
was therefore unreachable: the desk answered 404 `NO_SUCH_ROUTE`, and the phone's "New session here" mapped that to
"Couldn't reach the desk". No e2e check had ever posted to `/new`. Found when the new roots e2e check for the session
door came back 404 instead of 400. Fixed by adding `new` to the regex; a regression check now posts to `/new` with no
body and asserts 202 plus the tmux `-c` argument equal to the conversation's cwd.

## e2e

The fake tmux now answers `new-window` with ids and logs its argv, so the e2e reads the `-c` the desk actually
passed: inside a root -> 202 and `-c` is the resolved directory; outside -> 400 `outside_roots`; ledger removed ->
400 `no_roots` and the list answers 200 + empty + `no_roots`; ledger restored -> 202; index 9 -> 404; no key -> 401.

## Phone

`RootsModels.swift` (DeskRoot / RootsResponse / StartInRootOutcome / RootsWire), `RootsClient.swift`,
`RootsFixture.swift` (`RC_UI_ROOTS_FIXTURE`: roots-sample / roots-none / roots-outside), `DirectoryPickerView.swift`
(sheet: roots -> folders -> "Start here"; tapping a folder only descends), `ListView.swift` (`+` in the toolbar,
identifier `list.newSession`), `RootView.swift` (fixture wiring). Tests: `RootsClientTests` (4), `NewSessionPickerUITests`
(3, one per fixture state; the sample test asserts no notice appears after two folder taps).

## Deploy and operator steps

Ledger on friday is created before deploy and never overwritten (spec section "Deploy and operator steps").

## Runs (observed)

| Run | Result |
|---|---|
| desk unit suite (`npm test`) | 1171 pass / 0 fail (includes the two meta tests: request-shape coverage for RootsClient, wire-key pairing for RootsResponse / DeskRoot / RootsClient.Wire) |
| desk e2e (`node test/e2e-local.mjs`) | 343 pass / 0 fail, including the 10 roots checks and the `new` regression check |
| phone unit `RootsClientTests` | 8 pass (decoding, outcome mapping, request URL / method / header / body / timeout) |
| phone UI `NewSessionPickerUITests` | 3 pass (sample drill-down with "no notice after folder taps", no-roots face, outside_roots text) |
| friday ledger | `~/.rc-backend/roots` created 2026-09-03 15:52 (absent before), 3 lines, mode 600; `~/client-a` absent so the loader drops it |

Two e2e iterations were mine to fix: the fake tmux did not answer `new-window` (now it logs argv and returns ids), and
the root label for a sandbox outside `$HOME` is the ledger line as written, which on macOS differs from its realpath.

## Post-landing chain: one full-suite failure, bisected

The chain's full simulator run (1019 tests) failed exactly one: the account bar's failure text was gone
(`AccountUITests` "a backend failure is said out loud"). Isolated reruns failed twice; moving the `+` from trailing to
leading did not help; the same test on the commit before #11 (a detached worktree of 1e08792) passed. Mechanism:
toolbar items are measured at their ideal width, a one-line `Text` has ideal width equal to the whole sentence, and when
the bar no longer has room SwiftUI drops the item instead of truncating it; any extra item on either side shrinks the
room. Fix: the failure text gets `frame(maxWidth: 120)` so its ideal width always fits and the tail truncates; the full
reason stays on the settings screen behind it. The `+` stays in the leading slot (the root screen has nothing there).

## Deployed and observed (2026-09-03 17:35)

Post-landing chain on b24dc97: seeded simulator rebuilt, full simulator run 1019 tests / 0 failures, desk deployed to
friday (`healthz` version `b24dc97`), OTA build 145 baked and approved.
Live doors on friday, read with the desk key from Jervis over the tailnet:

| Request | Observed |
|---|---|
| `GET /api/roots` | 200 `{"roots":[{"index":0,"label":"~/Infra"},{"index":1,"label":"~/Personal"}],"reason":null}` (the ledger's `~/client-a` line is dropped because the directory does not exist) |
| `GET /api/roots/0/paths?q=` | 200, 1 directory, relative path, `truncated:false`, `reason:null` |
| `GET /api/roots/9/paths?q=` | 404 |
| `GET /api/roots` without a key | 401 |
| OTA page | 200, build 145 |

## Codex adversarial review

Five findings (2 High, 2 Medium, 1 Low), dispositions in `codex-roots-review.md`. Fixed: file-as-cwd (tmux `$HOME`
fallback), absolute paths on the wire (labels outside home, the session door's 202), malformed bodies. Declined with
reasons: containment on the no-body session door (the key already controls that conversation). Accepted: the
rename race (needs write access on the desk). After the fixes: roots + route tests 28, two more mutants killed
(no dir check -> 4 red, no body validation -> 1 red).
