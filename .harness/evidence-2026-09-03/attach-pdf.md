# Attach PDF through the sniffed door (parity row 23, second step; 2026-09-03)

Why: row 23 landed as text-only (build 149). A PDF is the one binary a phone user actually carries around
(a paper, a statement, a spec) and Claude Code reads it natively when given the path. The text door refuses
anything with a NUL byte, and a PDF has NULs within its first kilobyte.

## Desk (`rc-backend/src/attach.mjs`)

- `PDF_MAGIC = "%PDF-"`, `isPdfMagic(buf)` on the first 5 bytes. Only that shape bypasses the NUL refusal;
  every other binary still gets `binary`.
- `sanitiseAttachName(raw, allowedExts)`: the declared name must still be `[A-Za-z0-9._-]` (<= 64) and its
  extension must be in the list for the sniffed kind. For a PDF the list is `["pdf"]` only, so a file named
  `notes.txt` with PDF bytes is `bad-name` (the name may not lie about the kind), and `.pdf` is NOT in
  `TEXT_ATTACH_EXTS` (a text file called `x.pdf` is `bad-name` the other way).
- Stored as `<id>.pdf`; envelope gains `format: "pdf" | "text"` (`attachFileBody` in `src/wire.mjs`).
- 12 MiB cap, sweep, and the `injected/injectReason/swept` fields are unchanged.

Built in an isolated worktree by a subagent while the build 150 chain read the main tree; patched in after
the chain finished (`git apply` of the worktree's cached diff, 3 files, +187/-16).

## Phone

`ConversationView.fileImporter` adds `.pdf` to `allowedContentTypes`. The phone already posts the file's own
name and bytes; the wording ("sent <name>, N bytes") does not distinguish formats, so nothing else changes.
The `FileEnvelope` decoder ignores unknown keys, so `format` rides along without a phone type change.

## Observed

- `node --test test/attach-pdf.test.mjs`: 7 / 7 (magic accepted, NUL elsewhere still `binary`, name must be
  `.pdf`, `.pdf` name with text bytes refused, stored extension, 12 MiB cap holds for PDF, format on the
  envelope).
- e2e `RC_ATTACH_DIR` sandbox: +3 checks (200 + `ext === "pdf"`, the absolute `.pdf` path appears in the
  fake tmux `send-keys` log, a non-PDF binary is still `binary`); tally 362 / 362.
- Full suite 1201 / 1201 (includes the wire-key agreement test with the new `format` key).
- Queue verifier `attach-pdf-documents-via-a-sniffed-door` run verbatim: rc=0.
