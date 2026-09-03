# Codex adversarial review: roots-restricted new session (2026-09-03)

Raw log: `codex-roots-review.raw.log` (untracked, 626 KB, 186k tokens). Prompt: read-only review of `roots.mjs`,
`rootsroute.mjs`, the server dispatch, `reqlog.mjs`, `paths.mjs` dirsOnly, `wire.mjs`, the tests and the e2e block,
against the threat model "a lost phone key must not start Claude outside the ledger roots".

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | High | `realpath` alone admits a regular file as cwd; tmux 3.6a falls back to `$HOME` (then `/`) when `chdir` fails and still spawns the child, so a file path starts Claude outside the allowlist. Ledger lines pointing at files had the same hole. | **Fixed.** `resolveUnderRoots` and `loadRoots` require `isDirectory()` after realpath (file -> `cwd_gone`, file root -> dropped). Tests: fake-fs and real-fs cases in `roots.test.mjs`, route test with `package.json`, e2e posts the ledger file itself and expects 409 with no tmux call. Mutant: dropping the check turns 4 tests red. |
| 2 | High | The session door with no `cwd` (or a malformed one) starts next to an existing conversation without consulting the ledger, so a conversation outside the roots is a way around the allowlist. | **Partly accepted, partly declined with reasons.** Malformed bodies (`cwd` present but empty / non-string, top-level not an object) now answer 400 `bad_body` instead of silently using the conversation's cwd. The no-body path stays outside the allowlist on purpose: a key that can post messages to that conversation already runs Claude in that directory, so a second window there adds no capability the key lacks; the allowlist confines places the phone chooses anew. Forcing containment would only break "New session here" for existing conversations outside the ledger. Recorded in `resolveRequestedCwd`'s comment. |
| 3 | Medium | TOCTOU: a directory renamed into an outward symlink between the realpath check and tmux's `chdir`. | **Accepted risk.** The attacker needs write access to the desk's file system, which already exceeds what the allowlist protects against. A launcher-side re-check (`rc-claude` on friday verifies its physical cwd against the ledger before exec) is the proportionate follow-up; the launcher lives outside this repo. |
| 4 | Medium | Absolute paths on the wire: roots outside `$HOME` were labelled with their full path; the session door's 202 echoed the canonical `cwd`. | **Fixed.** Labels outside home are `…/<basename>`; the 202 no longer carries `cwd` (the phone never read it). e2e asserts the sandbox path never appears in the roots list. |
| 5 | Low | `path` that is an object / array / number, or a top-level array body, was coerced to "" and started a session at the root itself. | **Fixed.** Body must be a plain object and `path` absent or a string; otherwise 400 `bad_body` and no tmux call. Mutant: removing the validation turns 1 test red. |

Codex also confirmed no escape via fixed symlinks, `..`, trailing slash, NUL, case-insensitive APFS, Unicode
normalisation, or negative / float / huge indexes; missing, unreadable and all-invalid ledgers fail closed on the
root-aware doors; the tests do catch a string-prefix or removed containment; the `new` regex fix and the dispatch
order introduce no other regression.
