# Tool output folds into the entry (parity row 41; 2026-09-03 night)

Why: the transcript showed only the tool's name (`⚙ Bash`) because the desk never read the `tool_result`
record that follows a `tool_use`. Once a session's "Working · Bash" banner clears, what the tool did was
invisible from the phone. Row 41 was marked absent with exactly that note.

## Desk (`rc-backend/src/sessions.mjs`, worktree subagent)

- `entriesFromLines` does a pairing pass: a `pending` map of `tool_use.id` to the tool entry, filled from
  assistant records and consumed by the next `tool_result` record with the same `tool_use_id`. The id never
  reaches the entry object, so `withWho` cannot leak it onto the wire.
- `previewOf`: each content fragment is sliced to 8 KiB before joining (a multi-MB result is never joined
  whole), ANSI CSI sequences and CR are stripped, then `TOOL_OUTPUT_LINE_MAX = 6` lines and
  `TOOL_OUTPUT_PREVIEW_MAX = 600` bytes (UTF-8 safe). Keys: `output`, `outputTruncated`, `outputError`
  (`is_error`), all absent when no result was paired.
- Live SSE entries (`entriesFromRecord`) are untouched: the result arrives in a later record.
- Search does not match on output (tested). A pair split across the backward reader's window, or across the
  before/after seam of `readHistoryAround`, degrades to "no output keys" and never throws (tested).
- `tool_result`-only records already did not surface as `user` entries (`flattenContent` reads text blocks
  only); now pinned by a test.
- Wire: `HistoryEntry` registered as `phone-subset` with the three keys `serverOnly` in
  `wire-key-agreement.test.mjs`, so the phone may lag the desk.
- Transcript shape used (no fixture existed in the repo): `{type:"user", message:{content:[{type:"tool_result",
  tool_use_id, content: string | [{type:"text", text}], is_error?}]}}` per the Claude Code JSONL format.

## Phone

- `HistoryEntry` gains `output: String?`, `outputTruncated: Bool?`, `outputError: Bool?` (optional, so a desk
  that does not send them still decodes).
- `EntryBubble` `.tool`: a chevron on the chip when `output` is present; tapping the chip (`onTapGesture`, not
  `Button`, which would fold the chip text into a label) toggles `showOutput`; the output renders under the
  chip in `.caption` (no monospace, per the #40 ruling), red via `RCTheme.danger` when `outputError`, and a
  "… (trimmed by the desk)" line when `outputTruncated`. Default is folded: tool rows are near half of a
  transcript, and an open default would fill the screen with output.
- Identifiers: `conversation.tool.toggle` (value `collapsed` / `expanded`), `conversation.tool.output`,
  `conversation.tool.output.more`; chips without output keep `conversation.tool.chip`.
- Fixture `conversation-3roles`: the `⚙ Bash` row carries a two-line output with `outputTruncated: true`.

## Observed

- Desk: `tool-output.test.mjs` 15 / 15; suite 1231 / 1231; e2e 373 / 373 (new fixture session with a real
  HTTP round trip, 4 checks).
- Queue verifier `transcript-tool-output-folds-into-the-entry` run verbatim on the main tree: see the tasks
  file `verified_at`.
- Phone: `ToolOutputDecodeTests` (4), `ToolOutputFoldUITests` (1), plus `HistoryModelsTests` and
  `ConversationSearchUITests` as neighbours: see the commit's gate log.
