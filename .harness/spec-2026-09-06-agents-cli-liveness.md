# Spec — `GET /api/sessions` carries a second liveness signal from `claude agents --json` (2026-09-06)

Mode 2 (Quick). Loop task `server-liveness-cross-checked-live-against-claude-agents-json`. Verify:
`cd rc-backend && node --test test/server-agents-liveness-cross-check.test.mjs` passes, plus the full desk suite
(`npm test` in `rc-backend`) stays green.

## Why (one paragraph, from disk)

`rc-backend/src/agentscli.mjs` (2026-09-04) reads `claude agents --json` as pure functions with the process
injected, and `crossCheck(registryIds, agents)` says which desk-registered sessions the CLI also knows
(`both`), which the desk knows but the CLI does not (`onlyInRegistry` — a finished conversation the registry
still lists), and which the CLI knows but the desk does not (`onlyInCli`). It is imported by nothing in
`src/` (`grep -rn agentscli src tools` → only itself). The parity table's row 8 cell names this as the
byproduct the desk is not using. This spec wires it in **as a second signal beside the tmux-pane-text
liveness, never as a replacement**, and never in a way that can slow or block the list.

## Behaviour

1. `GET /api/sessions` (`server.mjs`, the branch that ends in `sessionsBody({...})` around line 1411) gains one
   envelope-level key: `agentsCli`. Shape (all keys always present):
   ```
   agentsCli: {
     ok: true|false,            // false = the CLI could not be read; nothing below may be inferred
     reason: null|string,       // "pending" (first request, read in flight) | "no-runner" | "spawn-failed" | "exit-N" | "not-json" | "not-array" | "timeout" | "stale"
     at: null|ISO8601,          // when the last successful read happened
     ageMs: null|int,           // now - at, when ok
     both: [sessionId…], onlyInRegistry: [sessionId…], onlyInCli: [sessionId…],
     dropped: int,              // rows the parser dropped (from parseAgents)
     display: { note: string }  // one sentence a person can read; composed HERE, not on the phone
   }
   ```
   `both`/`onlyInRegistry`/`onlyInCli` are `[]` when `ok:false` — and `ok:false` is the only thing that means
   "do not read the arrays". Never collapse "could not read" into "nothing running" (the same rule
   `agentscli.mjs` already enforces, and `digest-notify.sh`'s 「取れなかった」≠「0 件」).
2. Per session row, `live` gains one key: `cliSeen: true|false|null`. `null` whenever `agentsCli.ok` is false or
   the read is stale. `true` when the row's `id` is in `both`, `false` when in `onlyInRegistry`. Rows that are
   not registered (no pane) get `null`. This is a **display-only** signal in this spec: nothing in the desk
   changes behaviour on it (no attach refusal, no route change). The phone is out of scope here.
3. The read is **asynchronous and cached**. A module-level reader in `server.mjs` (or a small new
   `src/agentscache.mjs` if cleaner) keeps `{ result, at, inFlight }`:
   - On each list request, if the cache is older than `RC_AGENTS_TTL_MS` (default 10000) and no read is in
     flight, start one with `execFile(RC_CLAUDE_BIN, ["agents", "--json"], { timeout: RC_AGENTS_TIMEOUT_MS
     (default 4000), killSignal: "SIGKILL", env: tmuxChildEnv-style env with PATH including
     `/opt/homebrew/bin` and `$HOME/.local/bin` })`. The request **never awaits it** — it answers with what the
     cache holds (`reason:"pending"` on the very first request, `reason:"stale"` when the cache is older than
     `RC_AGENTS_STALE_MS` (default 60000) and the refresh has not landed).
   - `RC_CLAUDE_BIN` defaults to `claude`; resolve once at startup like `TMUX_BIN`/`CLAUDE_LAUNCHER` do.
   - A timeout is `ok:false, reason:"timeout"`, never a thrown error and never a hung request. Use
     `readAgents({ run })` from `agentscli.mjs` with a `run` that returns `{status, stdout}` from the completed
     execFile, so the parsing stays the already-tested code path.
   - The reader must be **injectable for tests** (pass `run`/clock), exactly like `screenOf`/`manager` are.
4. Registry ids handed to `crossCheck` = the `entries.map(e => e.sessionId)` set the handler already builds
   (`registered`).
5. The note (`display.note`) says, in one sentence: how many registered sessions the CLI confirms, how many it
   does not know, and — when `ok:false` — that the CLI could not be read and why. Compose in `wire.mjs`
   (`agentsCliView(agentsCli)`), consistent with `paneFaultView`/`scanLine`.

## Tests (write them so they FAIL when the feature is reverted)

`rc-backend/test/server-agents-liveness-cross-check.test.mjs` — **must not import `server.mjs`** (it listens
on import). Test the reader module and the wire composer directly, and the handler through the existing e2e
style only if an e2e already spawns the server as a process (see `test/e2e*.mjs` for the pattern). Cases:
- cache: first call returns `pending` and starts one read; second call within TTL returns the cached result
  without a second spawn (count spawns); after TTL a new read starts; while in flight the previous result is
  still served.
- timeout → `ok:false, reason:"timeout"`, arrays empty, `cliSeen:null` on rows.
- crossCheck mapping: given a registry of {A,B} and CLI rows {A,C}: `both=[A]`, `onlyInRegistry=[B]`,
  `onlyInCli=[C]`; row A `cliSeen:true`, row B `false`, an unregistered row `null`.
- `ok:false` never yields `cliSeen:true/false` (negative control: mutate the mapping to read arrays on
  `ok:false` and the test must go red).
- `display.note` mentions the counts and, on failure, the reason word.
- Register the new keys wherever the wire ledgers demand it: run `node --test test/wire-key-agreement.test.mjs`
  and `test/wire-vocabulary-agreement.test.mjs` and follow what they say (they stop you on a missing
  registration; do not weaken them). `bash test/wire-shape-controls.sh` too.

## Constraints (lane)

- No test imports `server.mjs`. No production desk calls from tests. Never `RC_NO_SEED=1`. No `git stash`,
  no `git checkout --`, no `--no-verify`. Do not touch `inject.mjs`, `choice.mjs`, `subagents.mjs`.
- The list endpoint's latency must not depend on the CLI (measure: a request with the reader stubbed to
  never resolve still answers).
- Additive only on the wire: no existing key changes meaning.
- Run `cd rc-backend && npm test` at the end and report the exact counts; run `bash tools/preflight-ledgers.sh`
  from the repo root and report each line.

## Deliverables

- Code + tests as above, in the worktree you are given. Do NOT commit; leave the diff in place.
- `.harness/progress-2026-09-06-agents-cli-liveness.md`: what changed (files), test counts before/after,
  every ledger that stopped you and how you satisfied it, and anything left undone with the reason.
