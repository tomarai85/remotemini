# #3 jump from a search hit to that line (2026-09-03)

Parity row #3. Before: the search panel deliberately made rows unclickable ("a UI that can jump to the wrong place is
worse than one that can't jump") because the desk returned no position and `HistoryEntry` had no identity.

## Design

Two facts from the desk, no new window type on the phone:

| Key | Where | Meaning |
|---|---|---|
| `anchor` = `<line byte offset>:<index within the record>` | every history entry and every search hit | stable identity: a jsonl transcript is append-only, so a line's offset never changes; the same entry carries the same anchor in `/history` and in `/history?q=` |
| `fromEnd` | search hits only | how many entries from the newest (newest = 0) |

Phone: tapping a hit calls `ConversationViewModel.jump(to:)`. If the anchor is already among the loaded entries it is
revealed at once; otherwise the phone re-fetches `/history` with `limit = fromEnd + 1 + 20` (the same tail-window path
as "load earlier", so the live merge and the landing logic are untouched) and reveals the row whose anchor matches.
Deeper than the desk's per-request ceiling (500) answers `tooFar` in words instead of silently showing the top.
The row is scrolled to the centre through the same token-plus-index mechanism the "load earlier" reveal uses.

## Desk

`listing.mjs`: `tailLinesWithOffsets` and `readLinesBackward` now return per-line byte offsets (positions survive chunk
boundaries and multi-byte text; the previous `tailLines` is untouched). `sessions.mjs`: `entriesFromLines(lines, offsets)`
attaches anchors; `readHistoryFromPath` and `extractHistory` (full read) agree; `searchHistoryFromPath` adds `fromEnd`.
Tests: `test/search-anchor.test.mjs` (real files, chunk 97/101: offsets are the real positions; the same entry has the
same anchor in history and search; `fromEnd + 1` is exactly the limit that includes the hit and `fromEnd` is not;
anchors survive appends; callers without offsets get no anchors). Two existing exact-comparison tests were adapted to
ignore the new key while asserting its shape. Wire-key agreement: `withWho` specimens cover both branches.

## Phone

`HistoryEntry.anchor` / `.fromEnd` (optional), fixture lines carry anchors and the fixture search adds `fromEnd` the way
the desk does, `ConversationViewModel.jump(to:)` + `jumpRevealToken/Index`, result rows are buttons (disabled without an
anchor), a `jumpNotice` line for `tooFar` / `notFound` / failures, and the note under the results now says how to use it.
Tests: `SearchJumpTests` (already-loaded hit reveals without refetch; a deeper hit grows the window to exactly
`fromEnd + 1 + margin` and keeps the tail; beyond the ceiling is `tooFar` with no fetch; no anchor is `notFound`;
decoding both keys), `SearchJumpUITests` (search "line 155" in a 240-line fixture whose first window is the last 50,
tap the hit, the panel closes and the line is on screen).

## Results (observed)

| Run | Result |
|---|---|
| `test/search-anchor.test.mjs` (registered verifier) | 6 pass |
| desk unit suite | 1180 pass / 0 fail (two exact-comparison tests adapted, wire-key specimens extended) |
| desk e2e | 350 pass / 0 fail (5 anchor checks incl. the `fromEnd` off-by-one control) |
| phone unit `SearchJumpTests` + `SearchHighlightTests` | 10 pass |
| phone UI `SearchJumpUITests` + `SearchHighlightUITests` + `ConversationSearchUITests` | 12 pass |

One iteration on the phone: wrapping the result bubble in a `Button` folded its `Text` into the button label and broke
an existing search test that anchors on `staticTexts["line 155"]`; a tap gesture on the bubble keeps the accessibility
tree as it was. One on the desk: `readLinesBackward`'s default `done` stops after the first chunk, so the offsets test
passes `done: () => false` to read the whole file.
