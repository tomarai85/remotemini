# #43 tool row above the keyboard (2026-09-03)

Parity row #43. The composer was a bare `TextField`; while walking, the sharpest input friction is reaching `@`, `/`
and the backtick (symbol plane, small targets).

## What was built, and what deliberately was not

- A keyboard toolbar (`ToolbarItemGroup(placement: .keyboard)`) on the composer field with three insert buttons
  (`@`, `/`, backtick) and a "Hide keyboard" button (`@FocusState`). Identifiers `conversation.kb.at`,
  `conversation.kb.slash`, `conversation.kb.backtick`, `conversation.kb.hide`.
- Insertion is **at the end of the draft**. SwiftUI's `TextField` exposes no cursor position or selection, so
  inserting at the caret is not possible without dropping to UIKit; while moving, typing is almost always at the end,
  so end-insertion covers the real case. `@` and `/` get a single space before them when the draft ends in a
  non-space character, because both only mean something at the start of a word.
- **Cursor-move buttons were not built** for the same reason (no cursor API); the task title mentioned them, the
  honest scope is symbols + hide. Recorded here rather than faked with end-of-text moves.
- Nothing on the row sends; "Hide" only folds the keyboard.

## Evidence

`ComposerKeyboardToolbarUITests`: the row is absent before the field is touched, appears on focus, `/` then typing
`compact` then `@` yields `/compact @` (the gap rule), backtick appends, Hide folds the keyboard (when a software
keyboard was showing) and leaves the text untouched, no send. Regressions run alongside: `SlashModelArgUITests`,
`SlashEffortArgUITests`, `ConversationSearchUITests`.

Observed: `ComposerKeyboardToolbarUITests` 1 pass, `ConversationSearchUITests` 10 pass, `SlashModelArgUITests` 1,
`SlashEffortArgUITests` 1 (13 tests, 0 failures on iPhone-controls); the registered verifier (the toolbar class alone)
re-run verbatim before marking the task done.
