<!-- ★行番号引用は `doc-linerefs` の門が止める(行は書いた瞬間から写しでずれる)。此の文書は
     レビューを書いた subagent が file:line で引いていたので、中身の目印へ張り替えた(2026-09-04)。 -->

VERDICT: ship-with-changes

Blocking:
- Restructure the older/newer control (Q3) before implementing — it cannot literally "reuse `loadEarlierState`'s row" as written.
- Give the detached banner a visual weight distinct from `statusBanners` (Q1) — same styling makes it invisible next to banners the user already ignores.
- Specify the live-counter's tap action and drop the exact number (Q2/Q5) before building the counter.

## 1. Mode boundary clarity

The top of this screen is already crowded before the new banner arrives: `.searchable(..., placement: .navigationBarDrawer(displayMode: .always))` (`ConversationView.swift`) pins a search field permanently, and `statusBanners` (`ConversationView.swift`, rendered at — the first thing under the nav bar) stacks `latestGapNotice` and `degradationBanner` as thin `.font(.caption)` / `.foregroundStyle(.secondary)` lines. If `conversation.detached.banner` uses that same passive gray-caption idiom, it will read as one more system-status line the user has already learned to skim past — the opposite of what a mode boundary needs.

Nothing needs to be removed to make room; the fix is not making the new banner compete with `statusBanners` for the user's attention on the same visual channel — give it an accent background/color, not `.secondary` gray, so it reads as a different *kind* of information (a mode, not a status).

More importantly: the failure this is guarding against (send while unaware) happens at the composer, at the bottom of the screen, not at the top. This codebase already has a precedent for exactly this bottom-vs-top judgment — `loadEarlierFooter`'s own doc (`ConversationView.swift`) explicitly keeps the "load earlier" entry point pinned near the thumb *instead of* at the top of the content, reasoning that an affordance requiring a scroll-up first defeats its own purpose. The same logic argues the mode signal must also have a presence at the bottom, next to where the thumb and the send button already are — a banner that can be scrolled away from view while the user reads old messages is not load-bearing at the moment that matters. Recommend: keep the top banner, but also give the composer itself a quiet, permanent cue while detached (e.g., a one-line label directly above the text field) rather than relying on the top banner alone.

## 2. The live counter

A bare count ("3 new below") is the wrong affordance — it promises that scrolling down reveals those 3 messages, but invariant 1 (`DetachedHistoryWindow.swift`, enforced by `noteLiveArrival`) guarantees they are never merged into the window. The window is centered somewhere in history; "below" is spatially false relative to where those messages actually live (the real tail, possibly thousands of entries away). A user who scrolls down expecting them will hit `newerAvailable == false` / `.atEdge` and read that as a bug, not as "you have to leave detached mode first."

Tapping it should do exactly what "Back to live" does — same transition (`close()` then re-fetch tail, landing pinned to `Self.bottomAnchorID` per `ConversationView.swift`). Don't build a second code path. Word it as an action, not a stat: "3 new · Back to live", so the count sits inside the button people already understand how to use, rather than as a separate passive readout.

## 3. Older/newer navigation

The design says "reuse `loadEarlierState`'s row" for both directions, but that type (`ConversationViewModel.swift`) is a single enum representing *one* control's state (`hidden`/`available`/`atCeiling`/`stalledRetry`/`loading`), driving exactly one row (`loadEarlierFooter`, `ConversationView.swift`). `DetachedHistoryWindow` exposes `olderAvailable` and `newerAvailable` as two independent booleans () that can both be true, or one can be `.loading`/`.atEdge` while the other isn't — a single enum cannot represent that pair. As written, either both directions share one state (so tapping "older" would also show "newer" as loading) or the design silently needs a second, undesigned type.

Recommendation: keep the footer as the anchor point (that's the codebase's proven pattern — thumb-reachable, position-independent), but make it two independent controls (an HStack, each with its own available/loading/atEdge state) rather than one row that flips label. This is a small change in shape, not in placement — don't relitigate whether the footer is the right location; it is, for the same reason `loadEarlierFooter` already lives there.

On buttons vs. scroll-to-edge: buttons are correct here, and the design is right not to reconsider this. Scroll-triggered fetch would fight the one thing this screen must preserve — the user's exact read position after a jump — because a scroll-driven fetch prepending/appending rows shifts scroll offset under the reader's finger unless the same "keep the pre-fetch row where it was" mechanics as `earlierRevealToken` (`ConversationViewModel.swift`, `ConversationView.swift`) are rebuilt for both directions. Two buttons reuse existing exclusivity guards (`isWalking`) cleanly; scroll triggers would not.

## 4. Leaving

Yes — converge all three exits on one mechanism. `DetachedHistoryWindow.close()`'s own doc () already assumes a single re-entry path ("呼び手が末尾の窓を読み直す前に此れを呼び… 残すと、戻った後の画面が古い旗で「もっと古く」を出す"); a second, divergent return path is exactly how risk-table row 2 in the design doc (stale `truncated`/`currentLimit`) would actually happen.

Wording should differ by cause, because these are different events for the user, even though the destination is identical:
- **Explicit "Back to live" tap**: no message after landing — it's what they asked for, confirmation would be noise.
- **Send**: state it as a fact about where the message went, not as an apology — "Sent. Back to live." One line, near the composer where the user's eyes already are (not a top banner they've scrolled away from).
- **409 (anchor vanished)**: must not read like a connectivity failure. This codebase already separates "not found" from "unreachable" copy elsewhere (`ConversationViewModel.applyLoadEarlier`, `.failure(.notFound)` vs `.failure(.unreachable)`) — follow that split here too. Suggested wording: "That part of the history changed. Showing the latest instead." Never "couldn't load" or "connection lost" — the desk is fine; the anchor specifically is gone.

## 5. What to cut

Cut the exact number in the live counter (Q2/Q5) — go boolean ("New messages" or a plain dot on the "Back to live" button). A precise count is a promise the UI cannot keep synchronized: `noteLiveArrival` increments locally (`DetachedHistoryWindow.swift`) on a cadence independent of the actual tail fetch that happens on return, so the number shown at tap time is already stale relative to what "Back to live" will load. A boolean avoids being wrong; a stale "3" that turns out to load 5 reads as a bug.

Second candidate, flagged rather than decided: the "not doing" list already rejects features for lack of evidence Tom wants them (infinite scroll, minimap, raised ceiling — `around-window-phone-design-2026-09-04.md`). The same bar arguably applies to the *newer*-walk control specifically, since "Back to live" already reaches the common destination in one tap; a repeatable forward-walk only earns its keep if Tom actually wants to catch up gradually rather than jump straight to live. Worth a real answer before building it, not a default yes.

## 6. The one measurement

With no analytics and one user, the only honest signal is a local, inspectable log — not a dashboard. Log one line per `DetachedHistoryWindow` transition (open / walk / close) tagging the close *reason*: explicit tap, send, or 409. After a week of real use, the ratio that matters is closes-via-send vs. closes-via-explicit-tap. If "leave by sending" is common, the banner (Q1) is not being read before the reply is typed — that's the actual failure this whole design exists to prevent, and it's the one thing worth being able to answer without asking Tom to remember.
