# Can the phone stop one subagent? (parity row #8) — feasibility, 2026-09-04

Row #8 says the native remote control has it: "Stop one of them from the device, and Claude Code stops that
task on your machine." Our desk's `interrupt` sends a single `Escape` into the tmux pane
(`inject.mjs`, `this.tmux.run(["send-keys", "-t", pane, "Escape"])`), which is whole-turn granularity.
The question this brief answers is whether finer granularity is even *representable* here, before anyone
designs a button for it.

## The verdict

VERDICT: per-subagent stop is reachable from where we stand, through the interactive agent panel, and row #8
is a real buildable gap rather than an architectural impossibility. Three routes exist and they are not
interchangeable. (a) Session-granular, from outside, no keystrokes: `claude agents --json` enumerates every
active session and `claude stop <id>` stops a background one. (b) Subagent-granular, from inside the session:
the `TaskStop` tool and the official Remote Control client, which is not an external process driving a
terminal but a client connected to the running session — unreachable for us. (c) Subagent-granular, from
outside, by driving the TUI: open the agent panel (`/tasks`), move the selection, press `x`. Route (c) is
real, is confirmed in the CLI's own changelog, and the panel's state is readable in the rendered pane, so it
is drivable **provided the desk refuses to press `x` until the pane shows the selection sitting on a row
whose text matches the intended subagent's name.** Without that check it is an off-by-one that silently kills
the wrong task. Recommendation: (c) earns a design brief before any implementation, because "drive a panel
and verify by name" is a new interaction class for this desk — every key it sends today is a single key on a
positively identified screen (`choice.mjs`).

### Evidence for route (c), checked on this machine

- `~/.claude/cache/changelog.md:2524` — "Fixed pressing `x` on a selected subagent in the agent panel typing
  into the prompt instead of stopping the agent." The key exists and its target is the selected subagent.
- `changelog.md:753` — the panel hides completed subagents and carries a `/tasks` footer hint, so `/tasks` is
  the documented way in.
- `changelog.md:1529` — idle subagents collapse into an expandable summary row. **This is the risk in one
  line**: the list reflows on its own, so a selection index captured a moment ago can point at a different
  row by the time the keystroke lands. Verification must be by rendered name at press time, never by index.
- `changelog.md:28` — Stop works in remote-control sessions (the official client's route (b)).
- No `~/.claude/keybindings.json` exists here, so defaults apply; a design would still have to read that file
  rather than assume, since it is user-editable.

### Two corrections, recorded because they share one cause

The first draft said the CLI "exposes no per-subagent stop" and called this not representable. That was
inferred from `claude --help` alone. The product page says the opposite in plain words: "the device shows any
subagents and workflows the session already has running in the background. Stop one of them from the device,
and Claude Code stops that task on your machine."

The second draft then said the capability exists but only inside the session boundary, and dismissed
keystroke-driving as a shape this repo has ruled against. That was also wrong: the changelog documents a
specific key on a specific panel, which is a far more concrete surface than the blind selection-driving I was
arguing against, and the panel is observable.

Both mistakes have the same cause: a capability question answered from one source that could not know the
answer — first the tool's own help text, then my own prior ruling on an adjacent shape — instead of the
artifacts that record what the product actually does. The rule that would have prevented both: when the
question is "can X be done", read what X's own release notes and product docs claim before reasoning from
the interface I happen to be looking at.

Recommendation: if row #8 is implemented at all, implement (a) and record (b) as not-representable. But (a)
is not a small task: it moves the desk's model from "one tmux pane I was told about" to "the set of sessions
the CLI itself knows about", which is an architectural decision, not a button.

## What I checked, and what it showed

### 1. The CLI has a session-level control surface this repo has never used

`claude --help` documents a whole subcommand family that does not go through tmux at all:

| command | what it does |
|---|---|
| `claude agents --json` | prints active sessions (interactive **and** background) as JSON and exits |
| `claude stop <id>` / `kill` | stops a background session; its conversation is kept |
| `claude attach <id>` | opens a background session in this terminal |
| `claude logs <id>` | prints a background session's recent terminal output |
| `claude rm <id>` | deletes a background session (and its worktree when safe) |
| `claude respawn [id]` | restarts one, or all with `--all` |

Observed output of `claude agents --json` on this machine: 11 entries, union of keys
`cwd id kind name pid sessionId startedAt state status`. Interactive sessions carry `pid` and a `status`
(`idle`/`busy`); background sessions carry a short `id` and a `state` (two were `blocked`). So the CLI already
publishes, account-wide and read-only, the thing our desk has been reconstructing from a tmux pane.

This is the "check for an existing solution before building" step, and it found one. It is also a finding that
outlives row #8: several desk capabilities (liveness, `attach`, log tail) currently ride on screen scraping
that this surface answers directly.

### 2. Subagents are individually identifiable — from the transcript, not from tmux

Every subagent of a session writes its own transcript beside the session's:

```
~/.claude/projects/<cwd-slug>/<session-uuid>/subagents/agent-<name>-<hash>.jsonl
~/.claude/projects/<cwd-slug>/<session-uuid>/subagents/agent-<name>-<hash>.meta.json
```

Observed on this session at 01:01: three such pairs. Every record in them carries `isSidechain: true` and a
stable `agentId` (e.g. `acc-guide-subagent-stop-3b9d17b9e71eaefb`); the `.meta.json` carries `agentType`,
`name`, `model`, `taskKind`, `teamName`, `permissionMode`. Liveness is the `.jsonl` mtime.

The repo had already measured half of this without noticing the directory: `listing.mjs`'s header records that
`entrypoint` appears on every main-thread user record and on **0 of 28,512 sidechain records**.

So **enumeration is solved**: the desk can list what is running under a session, by name, read-only, today.
"Which subagents are running" is not the hard half.

### 3. Stopping one of them is the hard half, and nothing exposes it

- `claude agents --json` is session-granular. No entry corresponds to an in-process subagent, so there is no
  id for `claude stop` to take.
- `claude stop <id>` is documented for **background sessions**. Pointing it at an interactive session's work
  is not what it does, and it would stop the session, not one task inside it.
- The remaining route is the interactive TUI's agent panel, which is route (c) in the verdict above. It is
  **not** blind driving: the panel renders into the pane the desk already reads, so the selected row's name is
  observable before the key is sent. The discipline it needs is the one `choice.mjs` already established —
  press only on a positively identified screen — extended from "identify the screen" to "identify the row".

## What follows for the mission table

- Row #8 stays **absent**, but its reason changes from "the desk has no concept of it" to "reachable through
  the agent panel by keystroke, pending a design brief for verify-by-name panel driving."
- A new candidate worth its own row: **the desk should read `claude agents --json` instead of inferring
  session state from a pane.** That is a real capability gap this brief found, it is read-only, and it is
  independent of row #8's verdict.
- If (a) is ever built, the phone-facing wording must not say "stop this task". It stops a whole background
  session, and saying otherwise would be the same class of lie as the 404 that told the user their
  conversation was deleted.
