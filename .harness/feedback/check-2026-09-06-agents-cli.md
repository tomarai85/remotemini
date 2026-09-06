# Evaluator record — agents-cli liveness signal (Mode 2, 2026-09-06)

The Claude Evaluator agent died on the account's session limit ("resets 12pm America/Chicago") after
confirming 1324/1324 in the worktree. Adversarial review was done by Codex instead, twice; the artifact with the
run signatures is `.harness/evidence-2026-09-06/codex-agents-cli-review.md`. Verdicts: run 1 timed out but had
already reproduced a deploy-killing defect on friday; run 2 returned FAIL with six findings. All seven were
folded in before the commit (`.harness/progress-2026-09-06-agents-cli-liveness.md`, 追記).

| axis | score | basis |
|---|---|---|
| Functional completeness | 5/5 | spec's envelope, row value, cache, injectability all present; production GET shows ok=true, both=1, onlyInRegistry=1 |
| Operational stability | 5/5 | request never awaits the CLI (test pins it); onError cannot escape; TTL/stale/timeout positive-only; native binary first |
| UI/UX | n/a | server-only in this change (phone reads nothing yet, declared in the wire ledger) |
| Error handling | 5/5 | ok:false is the only "unreadable"; malformed success → malformed; timeout/spawn/exit-N all named |
| No regressions | 5/5 | desk suite 1333/1333, wire ledgers 17/17, wire-key-agreement controls 55/55, deploy health checks green |

Negative controls measured by the Generator in a scratch copy: dropping the `ok` gate reds one test only;
arrays on failure reds five; passing arrays through on `ok:false` reds one; deleting the envelope key reds one.

PASS.
