# Two things the desk could not previously answer (2026-09-04 morning)

Both come out of last night's research rather than the parity table, and both are about the same failure
shape: a system that cannot tell "I asked and the answer was nothing" from "I could not ask".

## 1. The completion transition, recorded but never sent (parity row #32)

Row #32 said our single push type conflates two. The design brief corrected that: we have the
**actions-required** type, well tuned, and the **completion** type does not exist at all. It cannot be built
where the current decision lives, because a finished task and an idle session render the same screen —
composer present, no activity, both landing on `SENDABLE` -> `input` -> `soon`. A completed long task
therefore notifies today as "stopped, needs a message", twenty minutes late, wearing another event's label.

What separates them is a **transition**, and the only layer that sees across ticks is `digest-notify.sh`,
which already keeps per-session fingerprints on disk.

The change:

- The per-session record now also carries the previous tick's `attention`. Crucially it is carried for
  sessions that are **not** alert-eligible too, which previously had their record dropped from `fresh` and
  restored only by the stale-retention pass. The carry preserves `fp` / `first` / `obs` / `alerted` rather
  than replacing them — dropping those would resurrect an already-fired alert whose fingerprint had not
  changed.
- A completion candidate is: previous `attention == "none"` (activity was observed), current
  `attention == "input"`, `digest.complete === true`, and the window holds real work
  (`counts.assistant > 0` or `writeTargetsTotal > 0`). An incomplete digest never qualifies — the same rule
  the script already applies when it refuses to say "fine" from a partial read.
- It **logs and never sends**. The candidate is appended to a separate log with the three numbers the brief
  asks for (window minutes, work counts, whether the desk presence heartbeat was fresh) and is never added to
  `alerts`, never sets `alerted`.
- Presence freshness is computed in shell **before** the decision layer and passed in, because the existing
  presence gate runs after `[ -z "$out" ] && exit 0` — on a tick with no alerts it never executes, so the
  third number would have been permanently unmeasurable.

Why the paranoia about the send path: on 2026-09-01 this same script's `--dry-run` wrote `alerted: true` into
the fingerprint ledger, so a dry run **ate one real notification**. The lesson recorded in its header is that
a flag protects the visible side and the writing side has to be stopped separately. A "log-only" feature is
the same shape, so the controls test it directly rather than trusting the design.

Controls (`rc-backend/test/digest-notify-completion-log-controls.sh`), 11 / 11:

| case | what it holds |
|---|---|
| C0 / C0b / C0c | the working -> stopped transition records one line carrying all three numbers |
| C1 | a stopped screen that merely persists is not a completion |
| C2 / C2b | an empty window, and an unread window, do not claim completion |
| C3b | the completion tick sends nothing |
| **C4** | a completion recorded in between does **not** eat the next actions-required alert |
| C5 | `--dry-run` writes no completion log either |
| C6 | a session that keeps working never records |

The default stays off in the sense that matters: nothing is ever sent for a completion. What flips later is a
send, and the brief requires the three measured numbers first.

## 2. A reader for `claude agents --json` (not a table row)

Last night's subagent-stop research turned up a surface this project has never used: the CLI publishes its own
session list, account-wide and read-only. Observed on this machine: `claude agents --json` returns records
whose key union is `cwd id kind name pid sessionId startedAt state status` — interactive sessions carry `pid`
and `status`, background ones a short `id` and a `state` — and `claude stop <id>` stops a background session.
A grep of `rc-backend/` for either returns nothing: the desk reconstructs liveness by scraping a tmux pane
instead.

`rc-backend/src/agentscli.mjs` adds the reading half only, as pure functions with the process injected, in the
style `roots.mjs` established:

- `parseAgents(text)` never throws and always returns `{ ok, sessions, dropped, reason }`. **`ok: false` with
  a reason is not the same value as an empty list** — that distinction is the whole point. A malformed row is
  dropped and counted rather than failing the whole read, because one sick session should not erase the
  observation of every other.
- `readAgents({ run })` refuses to read the body of a non-zero exit, and returns `no-runner` when no runner is
  injected rather than reaching for a real `claude`.
- `crossCheck(registryIds, agents)` compares the pane registry against the CLI list and **says nothing at all**
  when the CLI could not be read. Treating an unreadable CLI as "those sessions are gone" would declare every
  conversation dead the day the CLI is replaced.

Tests (`rc-backend/test/agents-cli-reader.test.mjs`), 13 / 13, including a negative control asserting that the
unreadable result and the empty result are not equal — without it, the distinction could be silently absent
and every other assertion would still pass.

Nothing is wired into `server.mjs` yet. This is the readable half, verified on its own.

## The ship-gate review, and what it changed

Codex reviewed the change to the live cron script (`codex-completion-log-review.raw.log`), verdict fix-first
with two blocking findings. Both were accepted and are now held by controls; the third was deferred with a
reason rather than silently dropped.

- **F1 (High) — the delivery loop trusted whatever the decision layer printed.** While the decision layer had
  exactly one writer, an unvalidated loop was harmless. Adding the completion record made a **second writer**,
  and a mistaken `RC_DIGEST_COMPLETION_LOG=/dev/stdout` turns a record into a Discord notification. Fixed by
  validating `attention` and `level` against their vocabularies before delivering, and logging what was
  dropped. Held by C7 / C7b, which point the completion log at stdout — the actual misconfiguration shape.
- **F2 (Medium) — the carry-over made the state file grow without bound.** The first version added every
  session it saw to `fresh` with a refreshed `seen`, and `sid in fresh` is exactly the condition that skips
  stale pruning. Records that previously were never created had become records that could never be pruned, one
  per session in the listing, forever. Fixed by creating a record only for `attention == "none"` (the only
  value the transition needs to remember) and, for other ineligible states, updating `att` on an existing
  record without touching `seen`. Held by C8.
- **F3 (Low) — `--dry-run` still creates directories and appends to the diagnostic log.** Deferred, not
  applied. This predates the change, and this script's dry-run contract is specifically about the fingerprint
  ledger — the thing that ate a real notification on 2026-09-01. A diagnostic line consumes nothing. Changing
  `log()`'s behaviour under dry would also move ground under the existing dry-run control for a Low finding on
  untouched behaviour. Recorded here so it is a decision rather than an omission.

## Observed

| what | result |
|---|---|
| completion controls | 14 / 14 (11 + C7/C7b/C8 for the two accepted Codex findings) |
| `agents-cli-reader.test.mjs` (registered verifier) | 13 / 13, rc=0 |
| full desk suite | 1256 / 1256 |
