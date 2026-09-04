# Landing the 12 Codex findings on the anchored window and the tool-output preview (2026-09-04)

Two reviews (`codex-around-review.md` F1-F7, `codex-toolout-review.md` T-F1..T-F5) both returned fix-first.
All twelve were accepted and built in one worktree, because six of them touch the same three functions in
`src/sessions.mjs` and splitting them across two patches would have meant merging the same hunks twice.

## What changed

`src/listing.mjs`
- `LINE_CAP_MAX` = 16 MiB, and an opt-in `lineCap` on both readers. When the ordinary `maxBytes` budget is
  exhausted having found **zero complete lines**, the reader extends to the line cap to finish that one
  record, then stops. This is what makes a window centred on a huge record return that record instead of an
  empty window that never converges (F1, T-F1).
- `maxBytes - scanned` joins the step `Math.min` in both loops, so the budget is a real upper bound (F7). The
  mutation targets M45/M45f were repointed to the new line text in the same change, and their payloads
  updated so the mutation still bites.

`src/sessions.mjs`
- `readHistoryAround` checks that the canonical `<offset>:<index>` is actually present in the built window and
  throws `anchor-gone` otherwise (F2) — the same check covers the "record above the line cap" case for free.
- Both directions ask `done()` for `want + 1` so the window is trimmed deterministically rather than by
  whatever the chunk size happened to over-read, and the kept window carries that extra entry when found.
  That is what makes an availability flag mean "re-request around this edge and you will move" (F5).
- `collectEntries` is split out of `entriesFromLines`, and the around path threads **one** pending map across
  before-then-after in chronological order, so a `tool_use` and its `tool_result` pair across the window seam
  (T-F2). A result outside both windows still degrades to no output keys, never throws.
- `textPartsOf` is a generator, `previewOf` charges the join separator to the same byte budget, so a content
  array of 200k empty parts is bounded work (T-F3, ~20 ms).
- `previewOf` marks the preview truncated when it dropped unsupported blocks, and returns a null sentinel when
  nothing decodable was found, in which case `applyToolOutput` omits the keys entirely rather than claiming an
  empty complete output (T-F4).
- The pending map holds a FIFO per id, so two `tool_use` sharing an id resolve oldest-first (T-F5).
- `readHistoryFromPath` (tail mode) turns the line cap on: an oversized straggling record no longer empties
  the whole read (T-F1). This is the one place the fix reaches beyond the around path, and it only changes
  behaviour where the old code returned `history: []` wrongly.

`src/server.mjs`
- `clampHistoryLimit` replaces the shared limit computation for all three modes. `Math.min(NaN, 500)` is NaN
  and `slice(-NaN)` is `slice(0)`, so a garbage `limit` had been removing the 500 cap in **tail mode too**,
  not only in the new one (F3). Unparseable or negative falls back to the default 50; a valid huge value
  clamps to 500, matching the `clampLimit` idiom already in `paths.mjs`.
- `q` and `around` together are refused with 400 `q_and_around` before either mode dispatches (F6), and the
  mode is resolved before the "registered session with no transcript" early return so that branch answers in
  the around shape (F4).

## Phone side, same landing

`HistoryClient.around(...)` and `HistoryAroundResponse` (`history`, `anchor`, `olderAvailable`,
`newerAvailable`), a separate type from `HistoryResponse` for the same reason the search response is separate:
the tail window says "more behind" in one direction, this window has two edges, and sharing a type leaves a
path for a window flag to drive the "load earlier" control. `HistoryFetchingFixture.around` honours the same
progress guarantee the desk now makes, so the UI tests cannot pass against a fixture that walks in place.
Registered in `wire-key-agreement.test.mjs` as a pair with two specimens whose flags point opposite ways.

## Observed

| what | result |
|---|---|
| desk suite | 1243 / 1243 |
| e2e (`RC_ATTACH_DIR` sandbox, fake tmux) | 379 / 379 |
| mutation targets | 246 matched, 0 stale |
| `history-around.test.mjs` (queue verifier) | 21 / 21, rc=0 |
| `tool-output.test.mjs` (queue verifier) | rc=0 |
| phone units (client / models / jump / view model) | 226 / 226 |

## Judgment recorded

The subagent's first pass at F5 computed the availability flags purely from "found proof beyond the kept
window" and dropped the `!reachedStart` / `!reachedEnd` disjunct. That broke the existing chunk-invariance
test, because how far a reader over-reads past a threshold is itself chunk-size dependent. The finding did not
spell this out; the existing suite did. The OR-form was restored and only the `done()` threshold and the trim
boundary changed.
