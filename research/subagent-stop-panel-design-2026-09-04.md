# Driving the agent panel to stop one subagent (parity row #8) — design, 2026-09-04

Follows `research/subagent-stop-feasibility-2026-09-04.md`, which established that per-subagent stop **is**
reachable from outside the session: the interactive agent panel (`/tasks`) lists running subagents and `x`
stops the selected one (`~/.claude/cache/changelog.md`, the entry fixing `x` typing into the prompt instead of
stopping the agent). This brief answers the question that feasibility left open — what the desk would have to
be able to do, and under what refusal conditions — before anyone writes the code.

VERDICT: buildable, but only as a **new interaction class** with a verify-by-name press rule, and it should be
built in two separately shippable halves. Half one (list what is running) needs no keystrokes at all and
carries no risk; half two (press `x`) is the part that needs everything below. If only one half is ever built,
build the first — it delivers most of the user-visible value at none of the cost.

## Why this is a new interaction class, not another key press

Every key the desk sends today goes to a screen it has **positively identified**, and it sends exactly one:
`choice.mjs`'s `keyArgs` accepts only `1-9`, `enter`, `escape`, and refuses anything else before reaching
tmux; `inject.mjs`'s `classifyScreen` returns `CHOICE` only when `menuAt` matches, and `SENDABLE` only when
`findComposer` finds a composer. One key, one identified screen, no cursor state.

Stopping a subagent is different in three ways, and each one is a place the current design has no answer:

1. It is a **sequence**: open the panel, move a selection, press `x`. Three actions with state between them.
2. The target is identified by **position**, and position is not stable (below).
3. The failure is **silent and destructive**: pressing `x` on the wrong row stops work the user wanted.

## The hazard that decides the whole design: the panel reflows on its own

The changelog records that idle subagents collapse into an expandable summary row while others keep working,
and that completed subagents hide immediately. So the panel **reflows without input**. A selection index
captured from one render can point at a different subagent by the time a keystroke lands — not because the
desk did anything wrong, but because an agent finished in between.

This kills the obvious implementation (read the list, compute "target is 3rd", send Down Down Down, send `x`).

## The rule: verify by rendered name at press time

The press is allowed only when, in the **same pane render that immediately precedes it**, the selection
marker sits on a row whose rendered name equals the intended target's name. Not the row index, not the row
count, not a name captured earlier in the sequence — the name on the selected row, read now.

Consequences, all of which are refusals rather than retries:

- **Panel not positively identified** → do not press. This needs a real `PANEL` state added to
  `classifyScreen`, matching the panel's own rows. It must not be inferred as "no composer found", which is
  today's `UNKNOWN` — that state also covers an unreadable screen, and an unreadable screen is exactly when
  pressing is worst.
- **Selection cannot be brought onto the target within a small bounded number of moves** → abort, leave the
  panel, report that the target could not be selected. No unbounded search.
- **Two rows render the same name** → abort. The desk cannot tell them apart, and the transcript's stable
  `agentId` is not what the panel displays. Saying "ambiguous" is correct; guessing is not.
- **The name disappears between the identifying render and the press** → abort. That is the reflow case, and
  the honest reading is that the target probably finished on its own.

### The footer trap, measured

`classifyScreen`'s own header records a two-armed measurement: the footer hint (`esc to interrupt`) appears on
39 of 75 screens under a bare `claude`, and on **0 of 76** under `rc-claude`, the launcher wrapper the phone
always goes through, because it adds a statusLine. Any identification that leans on footer text will pass in a
hand-run terminal and silently never fire on the phone's path. The same file notes an instrument was written
that way that night. The panel must therefore be identified by its **rows**, not by any footer hint, and the
identification needs a fixture captured through `rc-claude`, not through a bare terminal.

### The Escape hazard already solved next door

`choice.mjs` keeps `ESC_SETTLE_MS = 150` because a terminal reads `Esc` plus the next character as an Alt
sequence, and the pane lock guarantees requests do not overlap but not that they are spaced. A panel sequence
sends more keys in a row than anything today, so it inherits that hazard for every step, not just after
Escape.

## Half one, which should ship first regardless

Enumeration needs no keystrokes. Each subagent already writes
`~/.claude/projects/<cwd-slug>/<session-uuid>/subagents/agent-<name>-<hash>.jsonl` plus a `.meta.json`
carrying `agentType`, `name`, `model`, `taskKind`, `permissionMode`; liveness is the `.jsonl` mtime. Reading
that directory gives the phone "what is running under this session, by name, since when" as a pure read, with
the same risk profile as the transcript reading the desk already does.

That is most of the value in the official feature's own words — *the device shows any subagents and workflows
the session already has running in the background* — and it is separable from the stop.

## What would make me retract

If the panel turns out to render a stable per-row identifier (not just a display name), the ambiguity refusal
becomes unnecessary and the design gets materially simpler. Nothing in the changelog says it does, and I have
not driven the panel to look; that measurement is the first task of any implementation, and it should be taken
through `rc-claude` on a session with two subagents of the same agent type running at once.
