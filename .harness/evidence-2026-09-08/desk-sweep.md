# Desk sweep — systematic defect search (2026-09-08)

Read-only audit of every file in `rc-backend/src` (all ~48 files, ~15,400 lines), plus
`tools/deploy-to-friday.sh` and `package.json`. This codebase has already been through many
rounds of adversarial (Codex) review — nearly every function carries a dated note explaining a
prior bug and the fix. Most files are extremely well hardened (fail-closed defaults, explicit
size/time/count caps, "observed vs. inferred" discipline enforced almost everywhere). The
findings below are the gaps that survived that scrutiny.

Total: **5 findings** (2 high, 2 medium, 1 low). No dead-or-unreachable-code findings survived
verification — every candidate I found was already covered by an existing test or Codex note
explaining why it's reachable. `tools/deploy-to-friday.sh` and `package.json` are clean (thin
wrapper / trivial manifest, nothing to flag).

---

## High severity

### 1. Two of nine body-reading routes mishandle an oversized request body

**File:** `server.mjs`
**Shape:** Seven of the nine handlers that call `readBody(req)` (a JSON-body reader capped at
64KB) correctly check `e instanceof BodyTooLarge` in their catch block and call `tooLarge(req,
res, e)`, which both sends `413` and — critically — calls `req.destroy()` once the response
finishes, draining the connection. The `title` action handler and the `archive` action handler
skip this check: they catch generically and return a plain `400 { error: "title required" }` /
`400 { error: "archived required" }` for *any* parse failure, oversized body included.

**Concrete failure:** Send `POST /api/sessions/<id>/title` (or `/archive`) with a body over
64KB. `readBody` calls `req.pause()` on the still-open request stream and rejects with
`BodyTooLarge`. The generic catch swallows the distinction, returns 400, and — because
`tooLarge()` is the only code path that calls `req.destroy()` — the socket is never closed and
the unread remainder of the oversized body is never drained. On a keep-alive HTTP/1.1
connection, those leftover bytes sit in the socket buffer and will be parsed as the start of
the *next* request line, corrupting whatever the client sends next on that connection (a
request-desync-shaped bug, not just a wrong status code). It also reports a misleading cause
("title required") when the real cause is body size — a claim (the field is missing/invalid)
stronger than what was actually observed (the body was cut off).
**Confidence:** high (verified by reading `readBody`, `tooLarge`, and all nine call sites; the
other seven routes' explicit `instanceof BodyTooLarge` checks confirm this is a known, applied
pattern that these two routes simply don't have).

### 2. `WorkerManager`'s per-session state grows without bound for the life of the process

**File:** `worker.mjs`
**Shape:** `WorkerManager` keeps four `Map`s keyed by `sessionId`: `rings` (one `EventRing` per
session, intentionally kept alive after the worker process exits so a reconnecting phone can
still catch up), `gens` (a small generation counter), `listeners` (the SSE/poll callback for
that session), and `lastSpawnError`. Every other cache in this codebase (`MetaCache`, the idem
store, the diff cache, `DeskStopMemory`, `agentscache`) has an explicit TTL and/or a hard
entry-count ceiling with eviction. These four do not: nothing ever calls `.delete()` on `rings`,
`gens`, or `listeners` for a session that will never be touched again, and `lastSpawnError` is
only cleared when a *new* `send()` happens for the same id (never on session end).
**Concrete failure:** `rc-backend` runs as a long-lived launchd daemon. Every session id that
ever goes through the worker path (i.e. any conversation reached while its tmux pane is
closed) permanently adds an entry to `rings` (each ring can hold up to its configured capacity
× per-event bytes, capped per-ring but not in aggregate) plus a `gens` entry and a `listeners`
closure. Over weeks/months of normal use across many distinct Claude Code sessions, this leaks
memory monotonically with no cap and no periodic sweep (the existing `setInterval(() =>
manager.sweep(), 30_000)` only reaps idle *worker processes* from `this.workers`, not the
sibling maps).
**Confidence:** high (confirmed by grepping every `.rings.`, `.gens.`, `.listeners.` write site
in `worker.mjs` and `server.mjs` — none is a delete).

---

## Medium severity

### 3. The one guard documented as "the only layer that works no matter what the phone sends" is fail-open by design

**File:** `deny.mjs`
**Shape:** `loadRules()` reads `~/.rc-backend/deny.json` (the desk's own keystroke-injection
denylist) on every send, and its own docstring says: "読めない・壊れている時は空で返す
(fail-open)... ここだけは fail-closed にしない" — i.e. the author deliberately chose fail-open
here, reasoning that a single corrupted byte in the rules file shouldn't silently block all
phone input.
**Concrete failure:** If `deny.json` becomes unreadable or malformed for any reason (disk
hiccup, a bad edit caught mid-write, permissions drift), `checkDeny()` receives zero rules and
every previously-blocked pattern (e.g. `git push --force`) is now allowed straight through with
no signal to Tom that protection is currently off — `rulesSummary().problem` carries the error,
but nothing surfaces it proactively. This is the literal fail-open case the sweep was asked to
find; it is not an oversight (it's reasoned about explicitly in the file), but it is real and
worth a second look given the module's own framing of itself as "the layer that always works."
**Confidence:** high that the behavior exists as described; low-medium that it constitutes a
"bug" rather than an accepted tradeoff, since the author already weighed and chose it.

### 4. Attachment cleanup only runs as a side effect of new attachments, not on a timer

**File:** `attach.mjs` (called from `server.mjs`)
**Shape:** `sweepOld(baseDir, now)` deletes attachments older than `ATTACH_TTL_MS` (7 days), but
it is only invoked inline inside the `attach` and `attach-file` route handlers — there is no
periodic timer for it, unlike `manager.sweep()` (worker idle reaping, every 30s).
**Concrete failure:** if phone attachments stop being sent for an extended period (very
plausible — it's a rarely-used feature per the file's own history), files already past the
7-day TTL are never deleted; the attachment directory only shrinks the next time someone
attaches something new. Bounded in practice (each file ≤ 12MB, feature is low-traffic) but it
is unbounded-until-next-use growth of the kind this codebase otherwise catches everywhere else.
**Confidence:** medium (verified only two call sites for `sweepOld`, both inside route
handlers; did not find any interval/cron wiring for it elsewhere in `server.mjs`).

---

## Low severity

### 5. Trust-file lookup does an uncapped linear scan with a syscall per entry

**File:** `trust.mjs`
**Shape:** `cwdVerdict()`'s "slow path" (symlink-keyed project entries) iterates every key in
`~/.claude.json`'s `projects` object and calls `realpathSync()` on each one until it finds a
match. This runs on every session's cwd-trust check (new-session flow), and the object grows
with however many distinct directories Claude Code has ever been trusted in on that machine —
there's no cap on iteration count or time budget, unlike almost every other read-path in this
codebase (`paths.mjs`, `sessiondiff.mjs`, `sessions.mjs`, etc. all have explicit entry/time
budgets).
**Concrete failure:** on a machine with a long history (hundreds of trusted project
directories), every new-session request pays hundreds of `realpathSync` calls in the worst
case. Not attacker-controlled (the file is local and Claude Code's own), and the "fast path"
(exact key match) covers the vast majority of cases per the file's own comment ("実測 57/59"),
so this is a latency/scaling concern rather than a correctness one.
**Confidence:** medium (mechanism confirmed by reading the code; real-world impact depends on
how large `~/.claude.json` grows on Tom's machine, which I did not measure).

---

## What I checked and found clean

- **Fail-open audit:** every other `catch` and default-branch in the reviewed files defaults to
  the *refusing* / *unreadable* / *unknown* side (roots.mjs, trust.mjs main path, choice.mjs,
  mutex.mjs, registry.mjs's liveness check, sessiondiff.mjs's git sandboxing). `deny.mjs` above
  is the one deliberate, documented exception.
- **Claims stronger than evidence:** the codebase has an unusually strong, consistently-applied
  discipline here (`ok:false` vs. empty array, `metadataIncomplete`, `stale`/`unknown` states,
  `spawnAck`/`delivered` verification tri-states). I did not find a new instance of this beyond
  the title/archive misreporting above.
- **Auth/exposure:** confirmed every `/api/*` route is gated by `authorized()` (constant-time
  bearer compare) before any handler runs; only `/healthz`, `/`, `/debug`, and static assets
  (which carry no secrets and require the key to do anything) bypass it, matching the code's own
  stated design. Cross-checked all 18 `action === "..."` branches against `SESSION_ROUTE_RE` /
  `SUBAGENT_STOP_RE` in `reqlog.mjs` — no orphaned or unlisted routes (a bug class this project
  has hit and fixed three times before).
- **Concurrency:** `mutex.mjs`'s keyed mutex, `TmuxInjector`'s pane-keyed send/interrupt/choice
  serialization, and `sessiondiff.mjs`'s cwd-keyed git-diff coalescing all correctly serialize
  the shared mutable state they touch. No new race found.
- **Dead/unreachable code:** several candidates (the `#refusedByLock` interrupt-only branch in
  `inject.mjs`, the `already-done` state exclusions in `worker.mjs`) are already flagged and
  justified in their own comments with a stated "覆る条件" (the condition that would resurrect
  them), so I did not re-report them as new findings.
