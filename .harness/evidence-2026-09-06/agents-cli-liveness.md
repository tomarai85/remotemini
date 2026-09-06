# The list now carries Claude's own session roster as a second liveness signal (parity row #8 byproduct) — 2026-09-06

`rc-backend/src/agentscli.mjs` had read `claude agents --json` since 2026-09-04 and nothing called it. Row #8's
own cell named that as the byproduct still unused. Commit `26b8ebd` wires it into `GET /api/sessions` through a
new async, cached, single-flight reader (`src/agentscache.mjs`): the request never waits for the CLI, `ok:false`
is the only meaning of "could not read" (arrays empty then), and each row's `live.cliSeen` is three-valued —
`true` (the CLI knows it), `false` (registered but the CLI no longer knows it), `null` (cannot say).

## Observed in production (10:17, two GETs six seconds apart)

```
GET1 200  agentsCli ok=true reason=null ageMs=681   both=1 onlyInRegistry=1 onlyInCli=0 dropped=0
      note: Claude's own session list confirms 1 of 2 registered sessions; 1 it no longer knows.
      efe9ee71 route=tmux   cliSeen=true      ← the long-lived phone pane
      f76a7e72 route=worker cliSeen=null      ← no pane, so nothing to cross-check
GET2 200  same read served from the cache (ageMs=6887, no new child)
```

The desk log has no "セッション一覧を読めない" line since the deploy; the service is `running` (pid 79332). The
`onlyInRegistry=1` is the case the design exists for: a pane registration the CLI does not recognise — a
finished conversation the registry still lists. The phone reads none of this yet (`serverOnly` in the wire
ledger); the row value is display-only and changes no desk behaviour.

## What review found and changed before it shipped

The Claude Evaluator died on the account's session limit, so Codex reviewed twice
(`codex-agents-cli-review.md`). The first run, with file access, went to friday and reproduced the finding that
would have killed the feature on deploy: `/opt/homebrew/bin/claude` there is a May npm build that answers
`agents --json` with `unknown option`, and the child PATH put Homebrew first. The native install
(`~/.local/bin/claude`, 2.1.263) now comes first and is the default binary. The second run (inline) added six:
`onError` throwing escaped `read()`; a success at epoch 0 read as "no success" (the same shape as the
`lastAttemptAt` defect the Generator's own tests had caught); per-row `Array.includes` made the response
O(rows × registry); `agentsCliBody({ok:true})` with no arrays claimed "confirms 0 of 0"; `Number(x) || default`
accepted a negative TTL, which spawns a child per request; a missing HOME dropped `~/.local/bin` from the PATH.
Each has a test now (20 → 26).

## What the gate caught on the way in

The first gated commit stopped with one control **unmeasured** (not red): the wire-key-agreement control's
case ⑲ plants a mutation at an anchor that is the literal `sessionsBody` signature, and the signature had
gained `agentsCli`. The anchor now follows the new signature, with a note that it must move whenever the
builder's arguments change. An unmeasured control that halts the gate is the mechanism working — a control
whose anchor silently misses would have reported green forever.
