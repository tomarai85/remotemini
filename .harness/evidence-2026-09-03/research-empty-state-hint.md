# Research: one-line hint on the empty session list, pointing at `+`

## 1. What HIG says (empty states + referring to controls)

`developer.apple.com/design/human-interface-guidelines` is JS-rendered; `WebFetch` returned only
the page `<title>`, no body. Below is via `WebSearch` snippets (search engine's own text extraction
of the live page), not a direct fetch — **treat as likely-accurate but unverified against the raw
HTML**.

- **Writing** page (`.../foundations/writing`), empty-state section: "An empty state, like a
  completed to-do list or bookmarks folder with nothing in it, can provide a good opportunity to
  make people feel welcome... make sure the content is useful and fits the context." And: "Provide
  clear next steps on any blank screens. An empty screen can be daunting if it isn't obvious what
  to do next, so guide people on actions they can take, and give them a button or link to do so if
  possible." This directly supports a hint line — HIG's own guidance is "give them a button or
  link," not just prose, though prose that names the control is a lighter-weight version of the
  same idea.
- No HIG text turned up that specifically bans naming a control ("the + button") in copy. A
  secondary source (NN/g-adjacent UI-copy guidance, not HIG itself) says avoid "Tap"/"Click" as the
  verb **inside a button's own label**, but that's a different surface than descriptive text
  pointing at a button elsewhere — Apple's own apps (Reminders, Notes) routinely say "Tap + to add
  a reminder" in empty states. Not finding a prohibition is not the same as confirming HIG endorses
  it — flagged unverified.

## 2. `ContentUnavailableView.actions:` and XCUITest reachability

**Correction to the task's premise**: `list.empty` in `ListView.swift` (the `.empty` case, `Text("No sessions")`) is **not** a
`ContentUnavailableView` today — it's a plain `Text("No sessions")` in a `ScrollView`, identifier
`list.empty`. Only `list.paneFault`-adjacent and `DiffView`'s `diff.reason`/`diff.empty` states use
`ContentUnavailableView` in this codebase.

`DiffView.swift` (the comment above its `ContentUnavailableView`) documents the exact defect the task is asking about, found 2026-09-03: a
`Button` placed inside `ContentUnavailableView`'s `actions:` closure does not appear as an
individually addressable element in the accessibility tree — `XCUITest` descending with `.any`
never found it, even though it renders correctly on screen. The fix there was to move the button
**outside** `actions:`, as an ordinary `Button` in the enclosing `VStack`, given its own
`accessibilityIdentifier` (`diff.retry`).

Consequence for this task: a plain sentence (`Text`) needs no such workaround — description text
isn't a tap target, so the addressability defect doesn't apply. It only matters if the hint becomes
a *button*.

## 3. Three candidate lines (English, <60 chars)

| # | Line | Chars |
|---|------|-------|
| A | `Tap + above to start a session on this desk.` | 46 |
| B | `Use the + button above to start one.` | 38 |
| C | `Tap + in the top-left to get started.` | 38 |

**Recommendation: A.** "Above" stays true regardless of exact toolbar placement (it's a nav-bar
item, always above the list body), whereas "top-left" (C) breaks if the `+` ever moves — and
`ListView.swift` (the comment on the `list.newSession` toolbar item) already documents one placement flip (trailing→leading) driven by a
layout collision, so wording that encodes a side is fragile. A also echoes the app's existing
vocabulary — the toolbar button's own `accessibilityLabel` is "New session" and the row's
long-press action is "New session here" — "start a session on this desk" reads as the same feature
family, not a fresh coinage.

## 4. Sentence or button?

**Recommendation: plain sentence, not a button.** Reasons:
- The `+` is one tap away in the same screen; a second button doing the same thing is a redundant
  target to keep in sync with the toolbar (two places that must agree on what "start a session"
  means).
- Since `list.empty` is currently plain `Text`, a hint-as-sentence is a same-shape, low-risk change:
  add a second `Text` line, no new interactive element, no accessibility-testability question to
  solve.
- The repo's rule the task cites ("a button that opens a picker is fine") means a button *would*
  be permitted here — but permitted isn't the same as warranted. If a button is wanted later, §2's
  precedent applies directly: keep it out of any `ContentUnavailableView.actions:` closure, give it
  its own `accessibilityIdentifier`, and place it as a sibling view, exactly as `DiffView`'s
  `diff.retry` does.

## Recommended line
`Tap + above to start a session on this desk.` — as body/description text under the existing
`Text("No sessions")` headline, not a new button.
