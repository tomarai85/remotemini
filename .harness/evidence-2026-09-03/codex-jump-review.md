# Codex adversarial review: search-hit jump (2026-09-03)

Raw log: `codex-jump-review.raw.log` (untracked, 485 KB). Read-only review of the anchor/fromEnd desk change and the
phone jump. No High. Codex explicitly cleared: offset arithmetic across chunk boundaries, carry base, short reads, CRLF,
missing final newline, UTF-8 split, empty lines; `fromEnd` under early stop / `maxBytes` (the read range is always a
suffix ending at EOF); live merge keeps history indexes stable; the tests do kill "anchor = line index" and
"fromEnd from the matched subset only"; the wire is additive both ways.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | Medium | Entries appended between the search and the jump fetch make `fromEnd` stale; with the 20-entry margin exceeded the anchor falls outside the window and the jump answers `notFound`. | **Fix.** If the anchor is missing after the fetch and the response is `truncated`, grow the limit stepwise to the desk ceiling (500) and retry; still missing at 500 answers `tooFar`. |
| 2 | Medium | The jump target is held as a row index; a window replacement (resync) between reveal and render can scroll to a different row. | **Fix.** Hold the anchor; the view resolves the index from the current entries when the token changes and scrolls only if the anchor is still present. |
| 3 | Medium | Concurrent history fetches (jump vs load-earlier vs resync) have no latest-wins; a slow older response can overwrite the newer jump. | **Fix.** A jump generation counter: a response is applied only when it belongs to the latest jump; a jump in flight rejects further taps; the existing `isFetchingEarlier` flag is shared. |
| 4 | Medium | `fromEnd + 1 + margin` is computed before the range check, so a hostile `Int.max` traps. | **Fix.** Range-check `fromEnd` (0 ..< ceiling) before any arithmetic. |
| 5 | Low | A failed-jump notice survives into the next search. | **Fix.** Cleared on search close, on a new submit, and when a jump starts. |
| 6 | Low | Missing tests: early stop / `maxBytes` `fromEnd`, CRLF and no trailing newline offsets, append-after-search, resync-vs-reveal. | **Fix (partial).** Desk: `fromEnd` under early stop equals the full read; CRLF and missing final newline offsets. Phone: append-after-search recovers through the retry; `Int.max` does not trap; a second tap during a jump is ignored. The resync race itself is covered by the anchor-based reveal (finding 2) rather than a timing test. |

## Applied (observed)

| Run | Result |
|---|---|
| `test/search-anchor.test.mjs` | 8 pass (two new: early-stop / `maxBytes` `fromEnd` equals the full read; CRLF and no trailing newline offsets) |
| desk unit suite | 1182 pass / 0 fail |
| phone unit `SearchJumpTests` | 9 pass (new: hostile `fromEnd` values incl. `Int.max` -> `tooFar` without a trap; 30 entries appended after the search -> recovered by doubling the window, 122 entries loaded; whole transcript loaded and still missing -> `notFound`; a second tap during a jump -> `busy`, the first jump wins) |
| phone UI (`SearchJumpUITests`, `SearchHighlightUITests`, `ConversationSearchUITests`) | 12 pass |

Live check on friday after the first deploy (e1d3342, OTA 147): `/history` entries carry `anchor`; `/history?q=こんにち`
returned 3 hits with `anchor@fromEnd`, and `/history?limit=fromEnd+1` for the deepest hit contained that anchor.
