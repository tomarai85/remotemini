# What the desk can actually read about running subagents — measured, 2026-09-04

`research/subagent-stop-panel-design-2026-09-04.md` recommended shipping the enumeration half first, because
it needs no keystrokes. Before writing that code I read the real files on friday. **Three of the design's
disk claims were wrong**, and the correction changes what the phone can show.

## Corrections to the earlier brief

| the brief said | measured on friday |
|---|---|
| `subagents/agent-<name>-<hash>.jsonl` | `subagents/agent-<agentId>.jsonl` — no name in the filename |
| the meta carries `agentType`, `name`, `model`, `taskKind`, `permissionMode` | it carries exactly two keys: `agentType` and `description` |
| liveness is the transcript's mtime | mtime is a heuristic; the parent transcript answers it outright (below) |

Nine meta files across five sessions, every one of the same shape:

```json
{"agentType":"Explore","description":"x-auto-post test failure diagnosis"}
```

The model is not in the meta, but every line of the subagent's own transcript carries `message.model`, so it
is one read away. The description is the caller's own one-line summary, which is the most useful thing the
phone could show, and it is present for all nine.

## CORRECTION (2026-09-05): the liveness rule below is wrong as written

The section that follows says "an agentId named by a parent `tool_result` means finished." **It does not.**
Measured twice, independently, after this file was written:

| where | records naming an agentId | `completed` | `async_launched` | `forked` |
|---|---|---|---|---|
| Jervis | 520 | 217 | 302 | 1 |
| friday | 9 | 9 | 0 | 0 |

The parent names a child's `agentId` **at launch as well as at completion**. Reading "named" as "finished"
would report 303 of Jervis's 520 as finished while they were still starting or running — the exact inverse of
the error the three-way state was introduced to prevent, and the more harmful direction, because a person
told the work is done stops waiting for it.

The correct discriminator is the `status` field: `completed` means finished; anything else does not.
Background-launched agents also finish through a `<task-notification>` user line carrying `<task-id>` and
`<status>completed</status>`, so both forms count as evidence of completion.

Two further measurements, from a 991-subagent sweep:
- **49% of subagents never appear in the parent transcript at all** (in-process teammates). For those, the
  parent can say nothing, so the mtime-based third state is the main path rather than a fallback.
- The meta's two keys are the two that are always **present**, not the only keys that exist: of 1,082 metas,
  exactly two keys in 182; the rest add `spawnDepth` (900), `model` (568), `toolUseId` (497), `name` (424),
  and others. Read only the two that are guaranteed.

**Why I could not have caught this by measuring on the desk.** friday's nine records are all `completed`, so
the rule looks correct there. The machine that runs subagents heavily is the one that shows the launch
records. A rule verified on the quiet machine is a rule verified against the absence of the case that breaks
it.

## The liveness signal is authoritative, not a guess (SUPERSEDED — read the correction above)

The parent transcript records the delegation as a `tool_use` named **`Agent`** (not `Task` — I probed for
`Task` first and got a clean zero, which would have read as "the parent records nothing" if I had stopped
there). When the subagent finishes, the matching `tool_result` in the parent carries the child's `agentId`
inline, next to `agentType` and the returned content.

So, for a session whose transcript the desk already knows how to read:

- an `agentId` present in `subagents/` **and** named by a parent `tool_result` → **finished**
- present in `subagents/` and **not** named by any parent result → **still running**

Measured on `8fbbc33a…` : one Agent call at 15:16:15Z, its result at 15:17:27Z carrying
`agentId: a48767004a0ad94d2`, and that id is the filename in `subagents/`. The reverse link does not exist —
the child's transcript never mentions the parent's `toolu_…` id — so the join has to run parent-to-child.

**The failure mode this leaves**: a subagent whose session died never gets a result, so it would read as
running forever. The honest reading is three-way, not two: finished / running / **no result and the file has
not moved in a while**, reported as stalled rather than as running. A crashed agent shown as busy is the same
error as reading a log's last line as a health check.

## The path is a one-line derivation

The desk already resolves a session to `<projects>/<slug>/<sessionId>.jsonl`. The subagent directory is
`<projects>/<slug>/<sessionId>/subagents/` — the same stem without the extension. No new path resolution, no
new traversal surface, and the existing session-id validation still guards it.

## What this makes shippable

A read-only route returning, per running subagent: `agentType`, the caller's `description`, the model, when it
started moving, and the three-way state. That is the enumeration half of parity row #8 in the official
feature's own terms — *the device shows any subagents and workflows the session already has running* — with no
keystroke, no panel, and no new interaction class.

The stop half still needs everything in the panel brief, and its first task is unchanged: drive the panel
through `rc-claude` and find out whether rows render a stable identifier.
