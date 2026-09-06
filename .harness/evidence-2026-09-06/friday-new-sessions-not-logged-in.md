# Every new phone session on friday starts "Not logged in" — found while measuring row #8 (2026-09-06)

The measurement for the subagent stop half needed one disposable Claude Code session on friday, started the
way the phone starts them (`disposable-session.mjs up`, which runs `rc-claude` in a fresh `rc-e2e-*` tmux
session). The session came up with `Not logged in · Run /login` on screen. So did the next one. The long-lived
phone pane (`work:phone`, Claude Code 2.1.247, started Aug 28) answers fine — it holds a token in memory and
is one restart away from the same screen (an update is already pending on it: "Update installed · Restart").

## What was measured, in order

| # | probe | result |
|---|---|---|
| 1 | fresh `rc-claude` in a disposable tmux session (80x24, 2.1.260) | `Not logged in · Run /login` |
| 2 | `claude auth status` from ssh, for each installed binary (2.1.247 / .251 / .260 / .263) | `loggedIn:false, authMethod:none` for all |
| 3 | same from **inside the tmux server** (disposable `rc-e2e-*` session running the command) | same |
| 4 | same from a **gui/501 LaunchAgent** (`launchctl managername` = Aqua), bootstrapped and booted out | same — so it is not a keychain-access or session-type problem |
| 5 | login-keychain item `Claude Code-credentials`, read inside tmux (length and keys only, never the value) | **282 bytes, `expiresAt: 0`**; a real item is ~5.9 KB |
| 6 | friday's own `bin/friday-cswap-restart.sh` (2026-08-07) | already records the keychain lane as unreadable there and refuses to restart the swap daemon |
| 7 | how friday's working Claude processes authenticate | the setup-token lane: `~/個人/heartbeat/.claude-oauth-token` → `tokens/claude-token-team`, swapped by `token-failover.sh` (log: `ok active=team` every 15 min); x-auto-post's `claude -p` sessions export it as `CLAUDE_CODE_OAUTH_TOKEN` |
| 8 | the same disposable launch with that token exported by a throwaway wrapper (`--bin`) | banner `Claude Code v2.1.263 · Sonnet 5 · Claude API`, no `Not logged in`, generation started on a one-line prompt; session torn down |

Probe 8 is the one that matters: nothing on friday was changed, and the only difference between "Not logged
in" and a working session was which credential lane the wrapper used.

## Why the desk's own design already says this

`research/asset-survey.md` §5 (2026-07-29): lane A (setup-token) is "the maintained source of truth"; lane B
(Keychain `/login`) "rots — do not use"; "the RC backend must go through `claude-work`, never bare `claude`".
`rc-claude` execs bare `claude`. The worker route in `server.mjs` does point at `~/fleet-tools/claude-work`
— **which does not exist on friday** (the whole `~/fleet-tools/` directory is absent; the survey was taken on
the previous desk machine). So both launch paths are on lane B or on a missing file.

## What this blocks and what it does not

- Blocks: any phone-created session answering at all (row #11/#12 "new session" is `present` in the table
  only because the route creates the pane; the pane cannot talk to the model). Blocks the row #8 fixture and
  the row #32 live completion instrument, both of which need a session that produces activity.
- Does not block: the existing phone pane until its next restart; friday's own `claude -p` jobs.

## The change, and what Codex made of it

First draft: `rc-claude` exports the token itself. Codex (CRITICAL mode, with observed state) said the
direction was right but the draft was a conditional no-go on four points, all adopted:

1. Respecting a token already in the environment is only safe for a deliberate override (`cswap run`); a
   phone launch inherits the tmux server's environment, which can carry a stale value → the pointer wins
   when `RC_PHONE_LAUNCH=1`, the environment wins only for manual launches.
2. Only `ANTHROPIC_API_KEY` was unset, but the official precedence is cloud-provider > `ANTHROPIC_AUTH_TOKEN`
   > `ANTHROPIC_API_KEY` > apiKeyHelper > `CLAUDE_CODE_OAUTH_TOKEN` > keychain → both API env keys are unset
   (billing must not silently leave the subscription); a selected cloud provider is refused, not hidden.
3. Falling through to the known-broken keychain when the pointer exists but is unusable is fail-open → when
   the pointer exists (file or symlink) and is empty / dangling / unreadable / not exactly one token, the
   launcher exits 3 with a sentence, and `claude` is never started.
4. `tr -d '[:space:]'` turns corruption into a valid value → one read, one line, no inner whitespace, sane
   length bounds; no "repair".

Codex's preferred final form was also taken: the credential decision lives in **one** launcher,
`~/.claude/tools/claude-work` (git-synced to every fleet machine within 5 minutes), and `rc-claude` execs it.
The desk's worker route still points at `~/fleet-tools/claude-work`; making `server.mjs` fall back to the
synced launcher is the follow-up, not part of this change. Also noted by Codex: a setup-token is
inference-only — the official Remote Control and claude.ai connectors cannot run on it; this desk does not
use either.

Tests: `~/.claude/tools/claude-work.test.sh` — 10 cases with a fake `claude` (export / passthrough / manual
respects env / phone prefers pointer / empty → exit 3 / two lines → exit 3 / dangling → exit 3 / provider →
exit 3 / through `rc-claude` with `--settings` / mutation control), 10/10.

## Verified in production (09:41)

After friday's sync-pull delivered both files (`claude-work` 5424 bytes at 09:40), the real path — a
disposable session started by `disposable-session.mjs up` with its default launcher, no wrapper — came up
**without** `Not logged in` and answered a one-line prompt with a real `⏺ pong` line in 9 seconds. Torn down
(`down rc=0`). The long-lived phone pane was not touched; its next restart goes through the same launcher.

## Lesson

A production check that only asks "does the composer accept text and Enter" (`live-composer-guard-check`,
`live-send-check`) was green on 2026-09-05. Whether those sessions could have answered is an inference, not
a measurement — their transcripts were removed at teardown — but friday's own note dates the dead keychain
lane to 2026-08-07, so the same screen was almost certainly behind them. Delivery verified the keystroke, not
the conversation. The instrument that finally noticed was one that needed the model to do something.
