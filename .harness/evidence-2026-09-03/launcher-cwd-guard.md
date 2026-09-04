# Launcher-side cwd guard (2026-09-03)

Closes Codex finding #3 from the roots review (`codex-roots-review.md`): the desk's realpath check on `new` and tmux's
`chdir` are two separate moments. The launcher now re-checks at the last moment.

## What changed

- `~/.claude/tools/rc-claude` (source on Jervis, tracked in the rules-backup repo; installed on friday by copy, backup
  `rc-claude.bak.20260903-192152`): when `RC_PHONE_LAUNCH=1`, resolve the physical cwd (`pwd -P`), read the ledger
  (`RC_ROOTS_FILE` or `~/.rc-backend/roots`, `~` expanded, each root resolved with `cd && pwd -P`), and refuse with
  exit 3 unless the cwd equals a root or lies under one. No ledger or an unreadable one refuses (fail closed). Without
  the flag the launcher behaves exactly as before, so a manual `rc-claude` outside the ledger keeps working: the ledger
  is for the phone, not for Tom's hands.
- `rc-backend/src/server.mjs` `startPhoneWindow`: the tmux command is now `RC_PHONE_LAUNCH=1 exec <launcher>`; the e2e
  reads the fake tmux argv and asserts the prefix.

## Evidence

| Check | Where | Result |
|---|---|---|
| outside + flag | Jervis temp ledger | refused, exit 3, stub `claude` not started |
| inside + flag | Jervis | started |
| outside, no flag (manual) | Jervis | started |
| symlink inside the root pointing outside + flag | Jervis | refused (physical cwd is outside) |
| flag, ledger missing | Jervis | refused |
| registered verifier (stub `claude` in PATH, temp cwd, flag) | friday, verbatim from the queue | `GUARD-OK`, rc 0 |
| positive control inside `~/Infra` + flag | friday | started |
| manual launch in `~/Direct` (outside the ledger, no flag) | friday | rc 0 (unaffected) |
| installed file | friday | sha256 prefix `8b82ab405b1aa97a` equals the Jervis source |

The task's verifier was written as a bare launch; it now sets `RC_PHONE_LAUNCH=1` because the guard is deliberately
gated on the phone launch (recorded in the queue as `verify_note`).
