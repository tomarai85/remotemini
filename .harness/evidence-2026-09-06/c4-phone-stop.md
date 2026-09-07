# The phone can stop one subagent (row #8 stop half, step c4) — 2026-09-06

## What landed

`SubagentsView` gains a "Stop" button on rows whose `state == "running"`. One tap arms the row ("Confirm stop", red),
a second tap on the same row sends `POST /api/sessions/:id/subagents/:agentId/stop`; tapping another row moves the
arming, tapping the list background disarms. While the desk drives the panel the button spins and every button is
disabled. The result is one sentence in `subagents.stopNotice`: `Stopped “<description>”.` on success, the desk's own
`error` sentence verbatim on a refusal, a fixed sentence on a transport failure. The list is reloaded afterwards; the
stopped row may still read "Working" for a while because the desk's liveness is transcript freshness — the banner is
the truth, the row stays honest about what the desk knows.

## Proof (simulator, `iPhone-controls`)

| suite | result |
|---|---|
| `SubagentsViewModelTests` (8) + `SubagentsStopClientTests` (5) + `SubagentsClientTests` (8) | 21/21 (`xcb-c4b.log`, after the research consult's fixes) |
| `rc-backend/test/device-ui-subagent-stop-controls.sh` (base + 2 mutations in a sandbox copy) | 3/3 — base green (11 ran); M1 "drop the arming" → 4 tests red; M2 "read 409 as transport failure" → 2 tests red (`c4-controls.log`, 2026-09-07 03:1x) |

## Research consult (SHIP-GATE `unverifiable_visual`)

`c4-phone-stop-research.md` — VERDICT: GAPS (4). Dispositions:

| # | gap | disposition |
|---|---|---|
| 1 | no minimum delay between the arm tap and the confirm tap: one mis-registered double-tap gesture arms and fires | `SubagentsViewModel.confirmDelay` (0.5 s, clock injected for tests): a second tap inside it is one gesture and does not send; the arming stays. Test `testTwoTapsInsideTheConfirmDelayAreOneGestureAndDoNotSend` |
| 2 | the accessibility id flipped `subagents.row.stop` → `.stop.confirm` on arm, breaking a UI test holding a reference | one stable id `subagents.row.stop`; the arming is the `accessibilityValue` (`idle` / `armed` / `stopping`) |
| 3 | after a stop the row can still say "Working" under a "Stopped" banner and invites a re-tap (the desk would refuse the second attempt harmlessly, per the reviewer's trace) | `stoppedHere`: an id stopped from this screen never shows the button again in this screen instance; the row's state word stays the desk's. Test `testAfterAStopTheRowLosesItsButtonEvenIfTheDeskStillSaysRunning` |
| 4 | the official wording covers "subagents and workflows"; teammates (`@name: status` rows) and background shells are on the desk panel but the phone's listing reads only `agent-*.jsonl` | out of c4's scope: it is the listing (row #8's first half). Named as a limit in the parity row; the stop planner already refuses shell rows and the driver refuses panels with shells by default |

## OTA

(appended below)
