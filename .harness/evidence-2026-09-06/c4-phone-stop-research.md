# Phone half of "stop one subagent" (parity row #8) — research consult, 2026-09-06

## 1. Contract match

The phone's `SubagentStopBody` decoder (`ios/Sources/Core/SubagentModels.swift`) matches the desk's
`subagentStopBody` envelope (`rc-backend/src/wire.mjs`) for every field it uses:

- `stopped`: desk sends the string `"observed"` on success (`panelstop-driver.mjs`: `stopped: "observed"`)
  and boolean `false` on every refusal (`wire.mjs`: `out.ok ? out.stopped : false`, and `panelstop-driver.mjs`
  `refusal()` always sets `stopped: false`). The custom decoder (`SubagentModels.swift`) tries String
  first (`== "observed"` → `true`), falls back to Bool. Both shapes decode correctly; confirmed by
  `SubagentsStopClientTests.testStoppedFalseAsBooleanAndMissingFieldsStillDecode` (`ios/Tests/Core/SubagentsStopClientTests.swift`).
- `reason` / `error`: always populated strings on refusal (`STOP_REFUSAL` in `rc-backend/src/panelstop.mjs`,
  `DRIVER_REFUSAL` in `panelstop-driver.mjs`, `TARGET_REFUSAL` in `rc-backend/src/subagentstop.mjs`).
  Phone falls back to a fixed sentence only if `error` is absent (`SubagentsViewModel.swift`), which the wire
  contract never actually omits.
- `sent`, `escapes`: decoded, unused by the UI — informational only.

Two fields the desk sends that the phone does **not** decode: `keys` and `after`
(`wire.mjs,462`; absent from `SubagentStopBody`'s `CodingKeys` at `SubagentModels.swift`). Both are
diagnostic-only (raw keystroke log, post-press screen state) and never rendered — dropping them changes nothing
the person sees.

One field is decoded but functionally dead: `target.description` (`SubagentModels.swift`). The success
banner uses the **locally-tapped row's** `description`, not the body's (`SubagentsViewModel.swift`:
`"Stopped "\(row.description ?? row.agentId)"."`), so `target` only matters if a future screen wants to show what
the desk actually matched. No divergence today, but worth knowing before anyone builds on it.

No field the phone reads is missing from the desk's envelope, and no field the desk sends changes phone-visible
behavior by its absence.

## 2. Interaction safety (two-tap arming)

Arming is keyed by `agentId`, not row position (`armed: String?` at `SubagentsViewModel.swift`), so most of
the desk-side hazards (reflow, reorder) don't translate to the phone at all — a re-render can only re-attach the
same arm to the same logical agent or make it point at nothing. Checked scenarios:

- **Scroll**: no gesture on `ScrollView` disarms on scroll; only the outer `.onTapGesture` disarms
  (`SubagentsView.swift`), and mere scrolling doesn't fire it. Safe by construction.
- **List refresh reordering while armed**: the only reload paths are `load()` (`SubagentsViewModel.swift`,
  resets `armed = nil` at start) and `reloadKeepingNotice()` (`:90-101`, fired only *after* `armed` was already
  cleared at `:65`). No reload can happen with `armed` non-nil, so there's no window for a refreshed list to
  reattach an arm to the wrong row.
- **A row disappearing**: harmless — SwiftUI just won't render a button for it; `armed` pointing at a vanished id
  has no visual target to fire.
- **Wrong-agent send**: each row's `onStop` closure captures the row bound to that render pass
  (`SubagentsView.swift`), so the id sent is always the id currently displayed on the tapped card. No path
  produces a stale/wrong agentId.
- **Concurrent taps across rows**: `busy: viewModel.stopping != nil` disables every row's button while one stop
  is in flight (`SubagentsView.swift`, `stopping` set at `SubagentsViewModel.swift`), so a second tap on a
  different row during the network round trip is a no-op.
- **Hit-target accuracy**: both Stop and Confirm-stop use `.tapTarget()` (`SubagentsView.swift`), which
  enforces Apple's 44pt minimum with `.contentShape(Rectangle())` (`ios/Sources/Screens/Shared/TapTarget.swift`),
  so a near-miss tap lands on the intended control rather than bleeding into the outer disarm gesture.

**Gap found**: there is no minimum time gap between the arming tap and the confirming tap. `tapStop`
(`SubagentsViewModel.swift`) has no `await` on the "arm" branch (`:60-64`, synchronous set-and-return), so
a single fast physical double-tap on the same button — a mis-registered gesture, not two deliberate decisions —
arms and fires in one motion. Nothing in the code distinguishes "two taps the person meant" from "one gesture the
OS reported as two." This is the one place a slipped finger could still stop the wrong (or an unintended) agent
with a single tap-tap, which is exactly the failure mode the two-tap pattern was built to prevent.

## 3. Honesty of the notice

The notice text is accurate and, on the safety-critical path, appropriately non-committal: when the desk can't
visually confirm the stop, it returns `unverified`/`escape-unverified` with `sent:true` and a sentence that says
outcome is unknown (`panelstop-driver.mjs`), and the phone shows that sentence verbatim (`error` fallback
path, `SubagentsViewModel.swift`) rather than claiming success.

The row's own status label can still say "Working" right under a "Stopped ..." banner, because liveness comes
from transcript-mtime freshness, not an in-place update (documented intentionally at
`SubagentsViewModel.swift`, `:76`). This is a real, acknowledged UX inconsistency, not a bug.

**A second stop attempt on the same agent is safe**, verified by reading the desk's own gates: `buildStopTarget`
first checks the *listing's* `state !== "running"` and refuses `not-live` (`rc-backend/src/subagentstop.mjs`)
if the listing has caught up; if the listing is still stale-optimistic, the live panel is the deciding fact —
`planStop` finds zero rows matching the (now-gone) description and refuses `no-such-row`, "It may have finished"
(`panelstop.mjs`, message at `:34`). Either way the second attempt is a harmless 409, never a re-match onto a
different agent, confirmed by the production run's own driver logic that counts panel rows, not client state
(`panelstop-driver.mjs`). So the banner wording is sufficient in effect (a re-tap can't hurt), even though
the contradictory row label invites an unnecessary re-tap.

## 4. Accessibility identifiers

Found: `subagents.row.stop` / `subagents.row.stop.confirm` (`SubagentsView.swift`, one identifier, switched
by `armed`), `subagents.stopNotice` (`:79`). Also present but not asked about: `subagents.loading`, `.retry`,
`.failed`, `.note`, `.list`, `.row`, `.row.title`, `.row.state` (`:35,49,53,70,96,117,123,158`).

**Yes, the switch breaks a held reference.** In XCUITest an `XCUIElement` obtained via
`app.buttons["subagents.row.stop"]` is a live query, not a snapshot. After the first tap flips the identifier to
`subagents.row.stop.confirm`, that query resolves to nothing — a test written as "grab the button once, tap it
twice" fails on the second tap because the element the query matches has vanished, even though visually it's the
same control. A correct test must re-query by the new identifier for the second tap, or key off the stable
container instead. The container identifier `subagents.row` (`:158`) doesn't help by itself: it's applied to
*every* row, isn't unique per `agentId`, and is a `.contain` accessibility element, not the button — so a test
targeting "the second running row's button" needs `.row.title`/description text or ordinal position, not id
alone.

## 5. Divergence from the official wording

"the device shows any subagents **and workflows**... Stop one of them from the device":

- Scope is narrower than advertised. The listing endpoint reads only classic `Agent`-tool subagent files
  (`agent-<id>.jsonl`/`.meta.json`, per the design doc's half-one description at
  `research/subagent-stop-panel-design-2026-09-04.md:73-77`). The panel itself also shows **teammates** (`Team:
  …` rows) and background **shells**, per the measurement (`research/subagent-stop-panel-row-identifier-measurement-2026-09-06.md:47-52`),
  neither of which the phone can list or target — teammates are explicitly out of scope
  ("if teammates are ever in scope", same file `:92`), and shell rows are a hard refusal
  (`panelstop-driver.mjs`, `hasShellRows`). Nothing in the app tells the person that a teammate or a shell
  process is invisible to this screen.
- "Claude Code stops that task on your machine" reads as unconditional. The actual implementation is more
  conservative than the promise: it only claims success when the driver visually confirms the row count dropped
  (`panelstop-driver.mjs`), and says "unknown" rather than guessing when it can't confirm. This is a
  correct safety choice, but it means the phone sometimes cannot deliver the certainty the wording implies.

## VERDICT: GAPS

1. Add a minimum arm-to-confirm delay (or ignore a confirm tap that lands within, e.g., ~250ms of the arm tap) in
   `SubagentsViewModel.tapStop` (`ios/Sources/Screens/Conversation/SubagentsViewModel.swift`) so a single
   double-tap gesture cannot arm-and-fire in one motion.
2. Give the confirm state its own stable identifier scheme (e.g. keep `subagents.row.stop` always present and add
   a separate `subagents.row.armed` flag/identifier) so a UI test can hold one reference across both taps, in
   `ios/Sources/Screens/Conversation/SubagentsView.swift`.
3. Consider a lightweight client-side "stop requested" flag on the row (cosmetic only, not a liveness claim) so
   the row doesn't keep saying "Working" directly under a banner that says "Stopped", in
   `ios/Sources/Screens/Conversation/SubagentsView.swift` / `SubagentsViewModel.swift`. Not unsafe
   today (the desk refuses a re-tap harmlessly), just confusing.
4. Surface, even briefly, that teammates and shell processes aren't shown/stoppable here, so the person doesn't
   assume "Running" (`ios/Sources/Screens/Conversation/SubagentsView.swift`) is the complete picture the official
   feature description promises.
