# The phone can finally see what a session is running (parity row #8, first half)

The official remote control shows "any subagents and workflows the session already has running in the
background." This desk had never shown any of it. The stop half — open the agent panel, move a selection,
press `x` — is a new interaction class and needs its own design; the listing half needs **no keystrokes at
all**, so `research/subagent-stop-panel-design-2026-09-04.md` recommended shipping it alone. That is what
landed.

## Three things I wrote in the handoff were wrong, and one of them was dangerous

The brief handed to the implementing agent described the on-disk layout from memory. Measured against 991
real subagents:

| the brief said | what is actually there |
|---|---|
| `agent-<name>-<hash>.jsonl` | `agent-<agentId>.jsonl` — no name in the filename |
| the meta has five keys | two keys are always present (`agentType`, `description`); the rest vary — of 1,082 metas, exactly two keys in only 182 |
| "the parent naming the agentId means finished" | **false, and backwards** |

The third one mattered. The parent records a child's `agentId` **at launch as well as at completion**,
distinguished only by a `status` field. Measured on this machine: 520 records naming an agentId, of which
`completed` 217, `async_launched` 302, `forked` 1. An implementation that reads the name alone reports every
just-started agent as finished — and that is the harmful direction, because a person told the work is done
stops waiting for it.

**Why I could not have caught this on the desk.** friday has nine such records and all nine are `completed`,
so the rule looks perfect there. The machine that runs subagents heavily is the one that carries the launch
records. A rule verified where the counterexample cannot occur has been verified against its own absence.

A fourth measurement changed the shape of the answer: **49% of subagents never appear in the parent
transcript at all** (in-process teammates). For those the parent can say nothing, which makes the
mtime-derived third state the main path rather than a fallback.

## The state is three-way plus "I don't know", and the order is the design

1. a completion record → `finished` — an observation beats any inference, whatever the mtime says
2. the parent cannot be read → `unknown` — not knowing whether it finished is not the same as knowing it
   stalled
3. the child's last write is older than the parent scan budget → `unknown` — outside the window, absence of
   a completion record proves nothing
4. only now does mtime decide `running` vs `stalled`

`stalled` is worded as "no sign of life recently", not "dead", because mtime can only report the last write.
Calling that a health check is the error this three-way split exists to prevent.

## An empty list means three different things

`subagents: []` is returned when nothing is running, when the directory could not be read, and when the
children are there but their fates are unknown. Collapsing those into one empty array lets the reader pick
the most convenient reading — "nothing is running" — which is exactly the case where something *is*. So
`directory` and `parent` go on the wire, `counts` is written **only when it can be trusted**, and the sentence
a person reads is composed at the desk (`display.note`) rather than assembled twice on both sides.

## Two ledgers stopped me during the merge, and both were right

- **wire-key-agreement**: five new `Decodable` types were in neither box. Registering them also required a
  specimen for **both branches** — a non-empty list is the only way the nested keys are ever emitted, so a
  single-branch specimen would have left `subagents[]` unchecked while looking green.
- **request-shape**: `SubagentsClient: requestedTimeouts` was never observed by any test. A dimension no test
  looks at cannot go red when mutated, so it is not actually protected.

Neither is the kind of omission attention prevents. A ledger that cross-checks itself against the real
artifacts stops you at the moment of forgetting.

## Observed

| what | result |
|---|---|
| desk suite | 1304 / 1304 |
| e2e (8 new cases for this route) | 389 / 389 |
| phone build + tests | 1089 / 0 failed |
| full control sweep | green 130 / red 0 / unmeasured 3 |
| route wired? | removing `subagents` from the verb table turns 6 e2e cases red |

Against the production desk, after deploying:

```
898298b7  200  4 subagents  dir=read parent=read  counts={finished:4,running:0,stalled:0,unknown:0}
          - Finished | general-purpose | Append running-memory lines      | parent-completed
          - Finished | Explore         | Service state snapshot for handoff | parent-completed
cbe18653  200  2 subagents  …  8fbbc33a  200  1 subagent  …
efe9ee71  200  0 subagents  dir=absent  "This session has no subagents."
```

Every `finished` carries `reason: parent-completed`, which is the design holding: only a `status:"completed"`
record promotes a child to finished. Sessions with no children answer `absent` rather than an ambiguous empty
list.
