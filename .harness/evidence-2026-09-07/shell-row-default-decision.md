# Shell-row default: decided (kept) — 2026-09-07

## Question
The stop driver (`rc-backend/src/panelstop-driver.mjs`) refuses to press `x` whenever the `/tasks` panel contains a
background-shell row, because pressing `x` acts on the TUI's current focus: if the target agent finishes between the
last capture and the keystroke, the panel reflows with the marker on the first row — a shell — and `x` kills it.
Measured prevalence (`tools/bash-background-prevalence-check.mjs`, Jervis, 14 days / 120 parent transcripts):
5.4% of Bash calls run in the background, in 8 of 120 sessions (30 days / 300: 10 sessions). So the refusal bites
only while such a shell is alive and only in the heaviest sessions — which are where a phone stop is wanted most.

## Codex consult (`codex-shellrow.out`)
OpenAI Codex v0.144.3
session id: 01a07b02-a888-7b51-9da4-231a5318e45c

> DON'T SHIP. Strongest objection: post-`x` verification detects failure but cannot prevent or undo killing the wrong
> shell. The operation remains an unavoidable TOCTOU race because `x` acts on current UI focus, not a stable target
> identity. Initial marker position, row adjacency, and a second capture only reduce probability; none closes the race.
> Flip the default only after `x` can be bound atomically to the verified agent ID, or shell rows cannot receive
> destructive input through this flow.

Checked whether the CLI offers an id-bound stop: `claude stop <id>` (2.1.263 on friday) stops a *background session*,
not a subagent; `claude agents` manages background sessions. No id-bound subagent stop exists today.

## Decision
Keep the refusal. What changes: the refusal becomes its own closed word, `shells-present`, with a sentence that names
the cause and the way out ("a background shell is running under this conversation; the desk will not press stop while
a shell row is on the panel, because a late redraw could kill the shell instead. Wait for the shell to finish, or stop
it from the desk, then try again."). Before, this case borrowed `shell-row` ("the selection is on a background shell"),
which was wrong for a panel where the marker sat on the agent.

## What would flip it
Either (a) Claude Code exposes a stop bound to the agent id (a `claude` subcommand or a panel key that acts on an id,
not on focus), or (b) the panel stops listing shells (or lists them in a section `x` cannot reach). Re-run the
prevalence tool when reconsidering; the number is the cost side, the race is the risk side.
