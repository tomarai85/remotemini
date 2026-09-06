# What the agent panel actually renders (parity row #8, stop half) — measurement, 2026-09-06

`research/subagent-stop-panel-design-2026-09-04.md` ends with its retraction condition: "if the panel turns out
to render a stable per-row identifier, the ambiguity refusal becomes unnecessary". Its first task was to drive
the panel on a session with two subagents of the same agent type and look. This file is that measurement.

VERDICT: the panel renders **no identifier**. A classic subagent's row is its `description` text plus a status
word and the model name; two subagents with the same description are two byte-identical rows. The ambiguity
refusal in the design is therefore necessary, not defensive. The `Enter` detail view adds the agent type, the
elapsed time, the token count, the tool count, the last tool calls, and the prompt text — still no id, but
enough to tell apart two same-description agents whose prompts or recent tool calls differ. Two hazards the
design did not name were found: the panel mixes background **shells** into the same list and can start with
the selection on a shell row, and `Escape` after the overlay has already closed becomes an interrupt of the
parent turn.

## How it was measured

Three disposable tmux sessions on Jervis (`rc-probe-<pid>`, 120x40, bare `claude` 2.1.259, cwd = a scratch
directory), driven with `tmux send-keys`, screens read with `capture-pane -p` and `-p -e`. Captures live in the
session scratchpad (`panel-probe-1..3/`), outside the repo because the start banner carries the account email.
Scripts: `panel-probe-local.sh`, `panel-probe-view.sh` (same place).

| probe | what was running | why |
|---|---|---|
| 1 | two in-process **teammates** (`@sleeper-1`, `@sleeper-2`) — the model chose a team when asked for "two subagents" | first look; also shows the teammate branch of the panel |
| 2 | two classic `Agent`-tool subagents, same type, same description `sleep then done`, each backgrounding a `sleep 300` | the design's stated case |
| 3 | two classic subagents, same type, same description `count slowly`, same prompt, ten **foreground** `sleep 12` each | same case with the agents provably busy; also opened the `Enter` detail view; reopened after 30 s |

The prompt asked for "no name, no description beyond X" and the parent obeyed, so both probes 2 and 3 are the
worst case the design worried about, produced deliberately rather than waited for.

## What the panel shows

Probe 3, panel just opened (verbatim):

```
   Background
   2 active agents
     Local agents (2)
   ❯ count slowly (running) · Sonnet 5
     count slowly (running) · Sonnet 5
   ↑/↓ to select · Enter to view · f to foreground · x to stop · ctrl+x ctrl+k to stop all agents · Esc to close
```

- Row text for a classic subagent = `<description> (<status>) · <model>`. Nothing else. The two rows above are
  identical bytes; on disk they are `agent-a6276d12cef2e19e3.jsonl` and `agent-acf7282b4e3c46a4a.jsonl`.
- Row text for a teammate (probe 1) = `@<name>: <status>` under a `Team: session-<8 hex> (N)` header, with a
  `@team-lead` row that carries no `x` hint when selected. Teammate names are model-chosen and were distinct.
- Section headers seen: `Shells (N)`, `Local agents (N)`, `Team: … (N)`. Probe 2's list was
  `Shells (2)` / two `sleep 300 (running)` rows / `Local agents (1)` — the subagents' backgrounded `sleep`
  commands appear as shell rows in the same list, **and the initial selection sat on a shell row** with `x to
  stop` offered. A press there would kill a shell, not an agent.
- The selection marker is `❯` in column 4; the selected row's name is colour 35 or 110 (bold in the transcript,
  plain in the panel) and the status is 246 (dim). Down at the last row does not wrap (probe 3: three `Down`
  presses left the selection on row 2). Up from the first row does not wrap either.
- Footer hints seen on a selected subagent row: `↑/↓ to select · Enter to view · f to foreground · x to stop ·
  ctrl+x ctrl+k to stop all agents · Esc to close`. On the `@team-lead` row the `x` and `f` hints are absent.

## What the detail view shows

Probe 3, after `Enter` on the second row (verbatim, prompt truncated by the panel itself):

```
   general-purpose › count slowly
   30s · 89.2k tokens · 2 tools · Sonnet 5
   Progress
     Bash(sleep 12)
   › Bash(sleep 12)
   Prompt
   You have exactly one job. Run the shell command `sleep 12` using the Bash tool, ten times in a row, as ten
   separate sequential Bash tool calls. Wait for each call to return before issuing the next one. Never use
   run_in_background. Do not combine the sleeps into one command, a loop, or a chain. Do…
   ← to go back · Esc/Enter/Space to close · x to stop · f to foreground · ctrl+x ctrl+k to stop all agents
```

Everything here except the counters is on disk for the desk to compare against: `agentType` and `description`
are in `agent-<id>.meta.json`; the prompt is the first user record of `agent-<id>.jsonl`; the Progress entries
are that transcript's last `tool_use` blocks. `x to stop` works from the detail view too, so a press can be
made **after** a detail-level comparison rather than a row-level one.

## Consequences for the design

1. **Retraction condition not met.** No per-row identifier. Keep the ambiguity refusal.
2. **Verify by rendered text, at two levels.** Row level: description + status must match the intended agent
   and no other visible row may carry the same description. If two rows match, open the detail view of each
   candidate and compare the prompt prefix and the Progress entries against the intended `agentId`'s transcript;
   press `x` only from a detail view whose prompt and last tool calls match that transcript and no other
   candidate's. Identical description **and** identical prompt **and** identical recent tool calls → refuse as
   ambiguous (probe 3 is exactly this; the correct answer there is "cannot tell them apart").
3. **Shell rows are a second refusal.** A row under `Shells (N)` is never a target, and a press must not happen
   while the selection is anywhere but under `Local agents (N)` (or a `Team:` block, if teammates are ever in
   scope). The section header above the selected row is part of the verification, not just the row text.
4. **Escape is counted, not repeated.** Each `Escape` is followed by a capture; the next `Escape` is sent only if
   the overlay (the `Background` header or the detail footer) is still on screen. An `Escape` sent to a screen
   with no overlay interrupts the parent turn — the very thing the stop must not do.
5. **`PANEL` identification by rows** as the design demanded: the `Background` header line, at least one
   section header, and the `↑/↓ to select` footer line all present. The footer here is the overlay's own text,
   not the composer hint that `rc-claude` suppresses; whether it survives the statusLine is what the friday
   fixture (through `rc-claude`, Claude Code 2.1.260) has to confirm before any of this is wired.

## The friday fixture, through `rc-claude`, 80x24 (captured 09:33, same day)

Same probe on friday: `disposable-session.mjs up --bin <wrapper>` where the wrapper exports the fleet's
setup-token and execs `rc-claude` (without it the session starts `Not logged in` — see
`.harness/evidence-2026-09-06/friday-new-sessions-not-logged-in.md`); the window resized to the phone
window's 80x24; Claude Code **2.1.263** with the `rc-claude` statusLine (`[rc %56]`) present. Two same-type,
same-description, same-prompt subagents running foreground `sleep 12` calls. Verbatim:

```
   Background
   2 active agents
     Local agents (2)
   ❯ count slowly (running) · Sonnet 5
     count slowly (running) · Sonnet 5
   ↑/↓ to select · Enter to view · f to foreground · x to stop · ctrl+x
   ctrl+k to stop all agents · Esc to close
```

Identical to the Jervis capture except that the footer **wraps onto two lines at 80 columns** — a fixture
matcher must join wrapped footer lines or match on the `Background` header plus a section header, never on a
single footer line. `Enter` on a row opened the same detail view (`general-purpose › count slowly`, Progress
with the last `Bash(sleep 12)` calls, the Prompt prefix); one `Escape` from the detail view closed the whole
overlay (the next capture already showed the composer), so a second `Escape` would have gone to the parent.
The statusLine did not suppress any of the overlay's own text. VERDICT unchanged: **no identifier is rendered
on either machine**; the rows for two same-description agents are byte-identical at 80 and 120 columns.

## Limits of this measurement (Codex review, same day)

Four runs on two builds are observations under those conditions, not invariants of the panel: the two-line
footer wrap, the single-Escape closure of the overlay, and the shell row holding the initial selection were
each seen once. The "Consequences" above are therefore policies chosen to be safe under what was seen — a
shell row is refused because one was observed to take the selection, not because the panel is known to always
put it there — and the two-level match (row text, then detail prompt prefix and recent tool calls against the
on-disk transcript) is a heuristic for telling look-alike rows apart, not proof of identity: a prompt prefix
can truncate before the distinguishing word and two agents can share a recent tool-call sequence. When the
heuristic cannot separate candidates, the answer is "ambiguous", never a guess. Each of these needs its own
fixture before the code that relies on it is written.

## Not measured here, and what would change the answer

- The 5-row cap and its scroll hints (changelog) were not reached: the largest list driven had three rows
  (two agents plus a team lead, probe 1). A list of six or more agents is the next fixture to capture before
  the selection-move bound is chosen — a viewport can hide a duplicate row, reorder while scrolling, or move
  the selection under an asynchronous update, and any of those would invalidate a row-level match.
- Idle collapse (changelog: idle subagents collapse after 30 s) was not observed in the 30 s reopen because both
  agents were busy the whole time. It remains a reflow hazard and the "name disappears between render and
  press" refusal stays.
- If a future Claude Code version renders the agent id or a `#n` ordinal in the row, condition 2 simplifies to a
  single-level match; the shell-row and Escape refusals do not depend on that.
