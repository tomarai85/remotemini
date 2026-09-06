# Which registered session the CLI no longer knows, and why — 2026-09-06 10:5x

VERDICT: the `onlyInRegistry=1` in today's production `GET /api/sessions` is **e083612b** — the disposable
`rc-e2e-*` session that `live-completion-check.mjs` built at 09:44 and tore down at 09:48. Its pane (`%58`) is
gone (`tmux list-panes -a` on friday shows only `work:zsh %0` and `work:phone %1`), the CLI does not list it
(`claude agents --json` returns one interactive session, `efe9ee71`, pid 6306), but
`~/.rc-backend/panes/e083612b-….json` still exists with mtime **09:47** — written by the session's own
statusLine (`rc-pane-register.sh`, every 2 s while the process lives) **after** `disposable-session.mjs down`
had unlinked it and verified "不在を確認". The instrument's `torn_down=1` was a true observation at the instant
it looked; the file came back a second later from a process that had not yet exited. So the registry holds a
stale entry for a dead disposable session, and the new signal named it correctly: a registered id the CLI no
longer knows is exactly "a finished conversation the registry still lists".

## Facts (all read-only)

| source | value |
|---|---|
| `~/.rc-backend/panes/` on friday | `e083612b` (mtime 09:47, pane %58) and `efe9ee71` (mtime 10:33, pane %1) |
| `claude agents --json` on friday | one entry: `efe9ee71 interactive idle pid 6306` |
| `tmux list-panes -a` | `work:zsh %0`, `work:phone %1` — no `%58` |
| `registry.mjs` | no pruning; `livePaneFor` reports a vanished pane as not-ok and the list omits it (`消えたペインは出さない`), but the `registered` set passed to `crossCheck` is every entry, so a dead-pane entry shows as `onlyInRegistry` |
| `disposable-session.mjs down` | unlinks the exact-match `panes/<sid>.json` and checks absence once, immediately |

## Consequences

1. `onlyInRegistry` is a **stale-registration detector**, not a liveness verdict; treating it as "this
   conversation ended" would be right here but for the wrong reason (the entry is stale because a teardown
   raced the statusLine, not because Claude closed it). The row value `cliSeen=false` must keep meaning "the
   CLI does not know this registered id" and nothing more — which is what `agentscache.mjs` documents.
2. `disposable-session.mjs down` has a race the instruments' `torn_down=1` cannot see: the last statusLine
   write can land after the unlink. The fix is in the teardown, not the check — wait until the pane's process
   is gone (pane id absent from `list-panes`), then re-check the registry file once more after a short grace,
   and unlink again if it reappeared. Until then, a `panes/` entry whose pane id is not in tmux is the
   signature of this leftover and can be swept by the same tool's `reap`.
3. The desk itself never prunes `panes/`; entries only stop mattering when `livePaneFor` cannot find the
   pane. A registered-but-dead entry therefore stays in every `crossCheck` forever. Sweeping entries whose
   pane id is absent from tmux for longer than a statusLine interval would keep `onlyInRegistry` meaningful
   for the case it was built for (a conversation Claude closed while the pane lived on).
