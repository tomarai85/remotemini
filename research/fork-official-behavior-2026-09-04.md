# Is there enough evidence to build phone-side conversation fork? (parity row #28) — 2026-09-04

Row #28 asks whether the phone should be able to fork/branch a conversation. The mission table already flags
its own basis as weak: "動詞表に fork が無い。ただし公式の電話側の裏が取れていない" — the desk has no fork verb,
and nobody had checked whether the official phone side has one either. This brief closes the evidence
question and gives a build/no-build call.

VERDICT: do not build it now. The parity basis is not weak, it is **absent** — the official Remote Control
documentation never mentions forking or branching a conversation from a device, so there is nothing to copy.
Separately, the capability would be cheap for us to add (the CLI supports it and our launcher already passes
arguments through), so this is a deliberate "not now", not a "cannot". Revisit only if the user actually
reaches for it, or if the official surface grows one.

## The evidence question, answered

Fetched the official Remote Control page (`code.claude.com/docs/en/remote-control`) and searched it for
fork/branch wording. The page enumerates what a connected device can do — send messages, `@`-autocomplete
local file paths, watch subagents and workflows, answer permission prompts, stop a running subagent, survive
disconnects — and **never mentions forking or branching a session**. The only session-lifecycle verbs on that
page concern continuing and reconnecting.

So the row's premise ("公式の裏が取れていない") resolves to: there is no official phone-side fork to copy. The
row should be re-labelled from "absent, weak basis" to "absent, no parity basis — the reference product does
not have it either."

## What it would cost us, for the record

Cheap, and worth writing down so a future decision does not have to re-derive it.

- The CLI supports it directly: `--fork-session` — "When resuming, create a new session ID instead of reusing
  the original (use with `--resume` or `--continue`)."
- Our launcher already forwards arguments: `rc-claude` ends in `exec claude --settings "$RC_SETTINGS" "$@"`.
- The desk already knows how to open a session in a new tmux window with a chosen working directory:
  `startPhoneWindow(cwd)` runs `tmux new-window … "RC_PHONE_LAUNCH=1 exec ${CLAUDE_LAUNCHER}"`, and the
  launcher's statusLine registers the new session in `~/.rc-backend/panes/<session-id>.json`, which is how the
  phone's list learns about it.

So a fork would be `startPhoneWindow` with the source session's cwd plus two extra arguments
(`--resume <id> --fork-session`), a new route on the sessions door, and a row action on the phone. The
mechanism carries no new failure class: the new session registers itself exactly like a fresh one.

## Why "not now" even though it is cheap

- **No parity basis.** This project's mission is the 45-row table. Building a row the reference product does
  not have is scope creep wearing a row number.
- **It spends the phone's scarcest screen.** The session list is the most crowded surface in the app, and a
  fork's whole point is producing a second, near-identical entry. Every fork makes the list harder to read,
  and the list has no naming step at creation time.
- **The need has never been observed.** No captured request, no evidence file, no complaint asks for
  branching from the phone. Row #12 (start a session in the same place as an existing one) already covers the
  adjacent need that HAS been asked for, and it landed.

Falsification: if the user says "I wanted to branch this conversation from my phone", or the official docs
grow a fork verb, this verdict is wrong and the build is a small day's work per the cost note above.
