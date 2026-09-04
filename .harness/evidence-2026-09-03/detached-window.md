# The search hit past the ceiling becomes reachable (parity row #3, second half; 2026-09-04)

Row #3 landed on 2026-09-03: the desk returns an `anchor` on every entry and a `fromEnd` on every search hit,
and the phone grows its tail window until the hit is inside it. That works up to the desk's 500-entry cap. Past
it the phone said, honestly, "That match is further back than the phone can load." A match was visible in the
search sheet and unreachable in the transcript.

## The shape, and why not the obvious fix

The obvious fix is to raise the cap. It is wrong: the tail window is what live SSE entries append to, so a
5,000-entry tail means the phone holds and re-renders the whole transcript to show twenty lines. The window
does not need to be bigger. It needs to be somewhere else.

So the transcript gains a second mode. `ConversationViewModel.jump(to:)` no longer refuses beyond the ceiling;
it opens a **detached window** centred on the anchor via `GET /history?around=<anchor>&limit=N`.

`DetachedHistoryWindow` (its own type, not more state inside a 2,000-line view model, because it carries an
invariant the live mode contradicts) holds three rules, each with tests:

1. **Live entries are counted, never merged.** The window points into the middle of the transcript and is not
   adjacent to the tail, so appending live entries would fabricate an ordering. `ConversationViewModel.entries`
   returns the window verbatim while detached.
2. **Walking by the edge anchor must advance.** The desk promises it; the phone does not trust it. If the
   walked edge comes back unchanged, that direction is closed on the spot rather than left as a button that
   keeps hitting the desk forever.
3. **The requested anchor must be inside the returned window,** on open and on every walk, or the window is
   not reported as open or moved.

## The two reviews, and what each changed

**Codex (`codex-detached-review.raw.log`, fix-first, F1-F8).** Two High and three Medium were real defects in
code whose own unit tests were green — the case for keeping the adversarial pass mandatory:

- **F1**: a `close()` during an in-flight walk let the late response resurrect the closed window. Fixed with a
  generation token that `close()` and `open()` both advance; a response whose generation is stale is dropped.
- **F2**: 409 (`anchor_gone`) and a dropped connection were both `.unreachable`, and the window read that one
  value as "anchor gone" once open and "unreachable" before open — one error, two contradictory readings,
  chosen by unrelated state. `SessionsFetchError.anchorGone` now exists, keyed on the 409 *and* its reason, and
  a 409 with any other reason is a contract violation rather than a silent reinterpretation.
- **F3**: a walk accepted any non-empty window whose endpoints differed, even one not containing the anchor it
  asked for.
- **F4**: the progress guard compared the tuple of both edges, so a response that moved only the *opposite*
  edge counted as progress — an unbounded false-advance loop.
- **F5**: a stuck direction returned `.atEdge` while leaving its flag up, so the control kept calling the desk.
- **F6-F8**: three of my own tests could not fail. F8 was the sharpest: asserting "live entries did not merge"
  against a method that only takes an `Int` passes even with the method body deleted.

**Design review (`design-review-detached-window.md`, ship-with-changes).** Three blocking items, all applied:

- The older/newer control cannot reuse `loadEarlierState`'s row: that enum is one control's state, while the
  window has two independent booleans that can both be true. Two independent controls now.
- The banner needs weight the passive gray `statusBanners` do not have, and it needs to sit **beside the
  composer** — the failure being guarded against (sending while unaware) happens at the thumb, not at the top
  of the screen.
- The live indicator drops the exact count: it is stale by the time it is tapped. It says that new messages
  arrived, and tapping "Back to live" is the only path.

All three exits — the explicit tap, sending a message, and a 409 mid-walk — converge on `backToLive(reason:)`,
differing only in wording. The 409 wording says the history changed, never that the desk is unreachable.
`detachedExits` records the reason, because the review's one measurement is the ratio of closes-via-send to
closes-via-tap: if people keep leaving by sending, the mode boundary is not being read.

## Observed

| what | result |
|---|---|
| `DetachedHistoryWindowTests` | 15 / 15 |
| `JumpEntersDetachedModeTests` (registered verifier) | 6 / 6, rc=0 |
| `SearchJumpTests` (existing, contract updated) | 9 / 9 |
| combined run | 30 / 30, `xcode rc=0` |
| `HistoryClientTests` incl. the new 409 pair | 43 / 43 |

Two existing tests pinned the contract this change deliberately replaced (`.tooFar` beyond the ceiling). They
were not rewritten to match the new output; each was re-pointed at the property it had actually been
protecting — that the tail window is never grown past the ceiling, and that a hostile `fromEnd` is never
trusted enough to read from.
