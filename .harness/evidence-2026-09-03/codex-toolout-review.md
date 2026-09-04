# Codex review: tool output preview on transcript entries (parity row 41), 2026-09-03 23:3x run

Raw: `codex-toolout-review.raw.log` (read-only sandbox, prompt in scratchpad `toolout-review-prompt.txt`).
VERDICT: **fix-first**, blockers F1-F3.

| id | sev | where | failing input | fix |
|---|---|---|---|---|
| F1 | Med | `readHistoryFromPath` / `readLinesBackward` | `tool_use("u")` then one 1.1 MB `tool_result` record: the tail scan budget ends inside the record, `{history: [], truncated: true}`, even the tool entry is lost | a record larger than the window budget must not empty the window: finish the current record under a per-line cap (skip only records above that cap) |
| F2 | Med | `readHistoryAround` | `tool_use`, the anchored record, then its `tool_result`: before/after are paired in separate passes, so the tool entry has no output | one chronological pairing pass over before+after lines before slicing the window |
| F3 | Med | `textPartsOf` / `previewOf` | `content` = N empty text blocks: every fragment is materialised and N-1 separators are joined and split despite the 8 KiB guard | iterate lazily, charge separators to one aggregate budget, stop when exhausted |
| F4 | Low | `previewOf` | `[text "shown", image]` reports `outputTruncated: false` although a block was dropped; a non-array object yields an empty "complete" output | dropped unsupported blocks mark the preview truncated; nothing decodable means no output keys |
| F5 | Low | `entriesFromLines` | two `tool_use` with the same id then one result: `Map.set` overwrites, result lands on the wrong call | FIFO of pending entries per id |

Disposition: all five accepted (F1 with the same per-line-cap mechanism as the around review's F1, not a
streaming parser). Fixed in the same worktree as the around findings so the two patches to `sessions.mjs` do not
collide. Landing recorded in `around-fixes.md`.
