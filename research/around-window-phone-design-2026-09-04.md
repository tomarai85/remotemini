# The phone side of the anchor-addressed window (`?around=`) — design, 2026-09-04

Written while the desk-side Codex fixes were being built, so implementation can start the moment they land.
Desk contract assumed: `GET /api/sessions/<id>/history?around=<anchor>&limit=N` returns
`{entries, anchor, olderAvailable, newerAvailable}`; the requested anchor is always inside the returned
window; when a flag is true the window's edge anchor on that side is strictly farther than the requested one,
so a client can walk outward by re-requesting around the edge anchor and always makes progress. `q` and
`around` together are refused; a bad anchor is 400, a vanished one 409.

## The problem this closes

`ConversationViewModel.jump(to:)` reaches a search hit by growing the **tail** window to
`fromEnd + 1 + margin`, doubling on a miss, capped at `deskHistoryLimitCeiling = 500`. Beyond that it answers
`.tooFar` honestly. So a match 2,000 entries back is visible in the search sheet and unreachable in the
transcript. Growing the cap is the wrong fix: the tail window is what the live SSE merge appends to, so a
5,000-entry tail means the phone holds and re-renders the whole transcript to show twenty lines.

## The shape: a detached window, not a bigger tail

The transcript screen gains a second mode.

- **Live mode** (today): `history` is the last N entries, SSE appends, "Load earlier" grows N.
- **Detached mode** (new): `history` is an around-window centred on an anchor. **SSE does not append** — the
  window is not adjacent to the tail, so merging live entries there would fabricate an ordering. Incoming
  live entries are counted, not shown.

Entering: `jump(to:)` uses `around` instead of growing the tail whenever the anchor is not already in the
current window. That removes `.tooFar` entirely (the outcome stays in the enum only if the desk answers 409).
Leaving: one control returns to live and refetches the tail.

Why one screen rather than a second sheet: the search hit tap already lands the reader inside the transcript
with the row highlighted. A separate viewer would duplicate `EntryBubble`, the highlight, the fold, and the
scroll-to-anchor, and it would break the continuity of "I searched, I am now reading there".

## UI

- A banner pinned under the toolbar in detached mode: `Viewing older history` + a `Back to live` button
  (`conversation.detached.banner`, `conversation.detached.backToLive`). It also carries the count of live
  entries that arrived while detached, once non-zero: `3 new below`.
- The existing "Load earlier" control becomes "older/newer" in detached mode: `olderAvailable` drives the top
  one, `newerAvailable` the bottom one, each re-requesting `around=<edge anchor>` (this is what the desk's
  F5 progress guarantee is for). Reuse `loadEarlierState`'s row rather than inventing a new affordance.
- Composer stays enabled: sending a message returns to live first (a message belongs at the tail), and the
  banner says so on the send path rather than silently jumping.

## Risks and the tests that hold them

| risk | test |
|---|---|
| SSE merges into a detached window and fabricates order | a live entry arrives while detached: `entries` unchanged, counter increments |
| "Back to live" leaves stale `truncated`/`currentLimit` | after returning, `loadEarlier` still works and the tail is the last N |
| Walking outward loops on the same window | walk older to the start and newer to the end on a 40-entry fixture, assert strict progress and termination (mirrors the desk-side property test) |
| A 409 mid-walk (transcript rewritten) leaves a dead screen | 409 returns to live with a one-line notice, never a blank transcript |
| Jump exclusivity regressions | the existing `busy` guard and generation token must cover the around path too |

## Not doing

Infinite scroll in detached mode (a scroll-driven fetch makes the exclusivity guard much harder and the
reader loses their place); a minimap or date jump (no evidence Tom wants either); raising the 500 ceiling
(the ceiling stops being load-bearing once jumps go through `around`).
