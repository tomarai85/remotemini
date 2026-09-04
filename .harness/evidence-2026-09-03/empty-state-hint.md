# The empty session list points at the `+` (follow-up to parity row 11; 2026-09-03)

Why: after build 145 a desk with zero sessions shows "No sessions" and nothing else, while the `+` that fixes
that sits in the toolbar. The research receipt (`research-empty-state-hint.md`) settled the form: one
sentence, not a second button, because the `+` is already one tap away and two tap targets for the same
destination is the pattern native Remote Control avoids.

## Change

`ios/Sources/Screens/List/ListView.swift`, the `.empty` face: a `VStack` with the existing
`Text("No sessions")` (`list.empty`) and a new tertiary line `Tap + above to start a session on this desk.`
(`list.empty.hint`). "above" rather than "top left" so the sentence stays true if the toolbar side of the `+`
moves again (it moved once today when the AccountBar had to yield width).

## Test

`ios/UITests/EmptySessionListHintUITests.swift` on fixture `list-empty`: the hint exists, names `+`, starts
with "Tap + above", the `list.newSession` toolbar button exists and is enabled, and the hint is not a button.

## Observed

- Scratch run with 4 classes (hint, attach button, list search, picker): `Executed 6 tests, with 0 failures`.
- Queue verifier (`xcodebuild test … -only-testing:RemoteMiniUITests/EmptySessionListHintUITests | grep -q 'Executed [1-9]'`)
  run verbatim: see the tasks file `verified_at`.
