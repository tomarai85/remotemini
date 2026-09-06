# Codex adversarial review — worker route "202 only after the child is up" + phone `worker_error` banner — 2026-09-06

Reviewer: OpenAI Codex v0.144.3 via `~/.claude/tools/codex-review.sh` (read-only sandbox, `--cwd rc-backend`, read the
iOS sources too). Attack brief: scratchpad `codex-w1-review-prompt.md`. Raw output: scratchpad `codex-w1-review.out`.

OpenAI Codex v0.144.3
session id: 01a0784b-df86-7c22-960e-d21c1d6285ad

VERDICT: FAIL (2 fatal, 3 serious). Codex reproduced the fatal paths with a real `ChildProcess` on Node v24.15.0.

| # | severity | finding | disposition |
|---|---|---|---|
| 1 | FATAL | the `spawn` event only says the process started; a launcher that exits 23 (or 127, `claude` not found) right after it still got 202 `spawn:"spawned"`, then `worker_error`. `sendResult` showed "Sent (worker)" and dropped the draft even for `unconfirmed` | the ack is the child's FIRST stdout line (`ready`); exit or error before that line = `failed` regardless of exit code; `spawned` no longer exists as a status. `sendResult` renders `unconfirmed` as a warning that keeps the text. e2e 13-d gained the exit-23 launcher and the ok launcher now prints an init line |
| 2 | FATAL | 202 was stored in the idempotency slot before liveness; a retry with the same `sendId` after a late death replayed the stale 202 | success is stored only after `ready` (the CLI started and answered). `unconfirmed` is ALSO stored on purpose: replaying the same "unconfirmed" to the same `sendId` is safer than abandoning it and queuing a duplicate turn on a child that may have consumed the first. A death after `ready` reaches the phone as the `worker_error` banner |
| 3 | SERIOUS | the phone showed a retired child's `stale:true` failure as the current turn's failure | `WorkerEvent.stale` decoded; stale events carry no notice |
| 4 | SERIOUS | `user_dropped` with `reason:"user_cleared"` (the person's own DELETE /queue) rendered as "the desk dropped it, send again" | `user_cleared` carries no notice |
| 5 | SERIOUS | after a worker failure, a successful tmux-route send left the red banner standing | any accepted send (`keepText:false`) retires the banner |

Codex also measured the healthy path: `spawn` for `/usr/bin/true` arrives in 0.20–1.90 ms (mean 0.51 ms); the await holds
neither the event loop nor the pane mutex, so the 3 s ceiling costs nothing on a healthy desk.

Pinned as tests: `test/worker-route-spawn-ack.test.mjs` (ready / exit-23 / exit-0-before-line / ENOENT / reused /
unconfirmed-then-ready), e2e 13-d (three launchers), `test/view.test.mjs` (202 unconfirmed), iOS `PollModelsTests`
(stale / user_cleared / odd event) and `ConversationViewModelTests` (tmux-route success clears the banner).
