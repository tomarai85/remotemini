# #23 attach a text document from the phone (2026-09-03)

Parity row #23. Before: the phone's attach button was `PhotosPicker(matching: .images)` and the desk's only store was
`storeImage` (magic-byte sniff, HEIC conversion, EXIF strip). A log tail or a CSV had no door.

## Design (settled)

- Desk door `POST /api/sessions/<id>/attach-file?name=<declared name>`, raw bytes in the body like the image door.
  `storeFile`: same 12 MiB cap; images are refused with `use-image-door` (they belong to the image pipeline);
  bytes containing NUL are refused as `binary` (v1 is text documents: logs, CSV, JSON, Markdown, YAML, source);
  the declared name is sanitised to `[A-Za-z0-9._-]`, at most 64 characters, no leading dot, path separators
  stripped, extension from an allowlist, else `bad-name`; the stored file is `<id>.<ext>` (never the user's name);
  the absolute stored path is typed into the pane exactly as for images. Envelope `attachFileBody`
  `{ attachmentId, bytes, name, ext, injected, injectReason, swept }`.
- Phone: a second composer button (`conversation.attachFileButton`, "Attach a text file") opens `fileImporter`
  restricted to text-like UTTypes; the file is read under its security scope, checked for emptiness and the 12 MiB
  cap before sending, then `AttachClient.attachFile` posts it; wording names the file and maps the desk's reasons.
  The Files picker is out of process, so the UI test only proves the button and its enabled state; the request shape
  and the outcome mapping are unit-tested.

Threat stance (from the Planner's note): this admits a new class of untrusted bytes into a shell-capable session, so
the desk keeps the content-type-blind stance (declared type is never trusted), the size cap, the id-based file name,
and refuses binaries; the text lands in the composer as an `@` path, never executed.

## Runs (observed)

Phone: `AttachFileClientTests` 4 (request path, `name` query, method, header, raw body, timeout; rejection reasons;
status mapping incl. contract violation on an id-less 200; wording), `AttachClientTests` 11 still green,
`AttachFileButtonUITests` 1 + `AttachButtonUITests` 2 green.

Desk (implemented by a worktree subagent from the settled design, then applied to the main tree as a patch):
`storeFile` rejects rather than strips bad names (`../../x.txt`, leading dot, unknown extension, 65+ chars all
throw), `pathOf` and `sweepOld` share one image+text extension vocabulary so text attachments are swept by TTL too,
`attach-file` is in the route table, `attachFileBody` is the envelope. `test/attach-file.test.mjs` 9 tests (store with
sanitised name and mode 0600, disk name never contains the user's name, duplicate id, all five rejection reasons,
orphan cleanup on failure, the bad-name matrix, the extension allowlist, a mutation-style negative that the raw name
straight into `pathOf` throws, route reachability). Worktree run: desk suite 1191, e2e 359.

A real gap the subagent found while writing the e2e: the spawned e2e server had no `RC_ATTACH_DIR`, so its attach
traffic would have fallen back to the host's real `~/.rc-backend/attachments`, which the live desk on this machine
uses. The e2e now passes a sandbox directory.

Main-tree reruns after applying the patch and pairing `AttachClient.FileEnvelope` with `attachFileBody` in the
wire-key agreement: wire/vocabulary/request-shape 23 pass, desk suite 1191 pass / 0 fail, e2e 359 pass / 0 fail
(8 attach-file checks: 401 without key, 200 with the sanitised name echoed, `injected` contract, the absolute stored
path typed into the fake pane with no Enter, NUL -> 400 `binary`, PNG -> 400 `use-image-door`).
