# Agent-panel fixtures (row #8 stop half) — captured 2026-09-06

Verbatim `tmux capture-pane -p` screens from the measurement in
`research/subagent-stop-panel-row-identifier-measurement-2026-09-06.md`. Two same-type, same-description
subagents (`count slowly`) running foreground `sleep 12` calls; the `/tasks` panel opened, moved, its `Enter`
detail view opened, then closed. Do not edit these files by hand — they are evidence; recapture instead.

| file | machine | columns | Claude Code | screen |
|---|---|---|---|---|
| `jervis-panel-open.txt` | Jervis (MBP), bare `claude` | 120 | 2.1.259 | panel just opened; selection on row 1; the transcript above still shows the echoed prompt line starting `❯ ` |
| `jervis-panel-down1.txt` | Jervis | 120 | 2.1.259 | after one `Down`; selection on row 2 |
| `jervis-detail-open.txt` | Jervis | 120 | 2.1.259 | `Enter` on row 2: `general-purpose › count slowly`, counters, Progress, Prompt, detail footer |
| `jervis-panel-closed.txt` | Jervis | 120 | 2.1.259 | after `Escape`: composer back, `❯ /tasks` echo in the transcript, no overlay |
| `jervis-running.txt` | Jervis | 120 | 2.1.259 | before opening the panel: both agents running, composer visible |
| `friday-panel-open.txt` | friday (Mac mini), `rc-claude` + statusLine | 80x24 | 2.1.263 | panel just opened; footer wraps onto two lines |
| `friday-panel-down1.txt` | friday | 80x24 | 2.1.263 | after one `Down` |
| `friday-detail-open.txt` | friday | 80x24 | 2.1.263 | `Enter` on row 2: detail view |
| `friday-after-esc1.txt` | friday | 80x24 | 2.1.263 | one `Escape` from the detail view closed the whole overlay; composer back |
| `friday-running.txt` | friday | 80x24 | 2.1.263 | before opening the panel |

No file contains an account email (the start banner had scrolled off before these captures).

## Added 2026-09-07 (disposable session on friday, 120x40 tmux, Claude Code 2.1.263)

Captured by `repro-shell-kill-v2.mjs` (screens log: `.harness/evidence-2026-09-07/repro-shell-kill-screens.log`).
One subagent `count slowly` plus a background shell `sleep 240.<nonce>` in the parent; the shell was killed from outside.

| file | screen |
|---|---|
| `friday-panel-empty.txt` | idle session, `/tasks` with zero tasks: `Background` / `No tasks currently running` / footer, no section header. `panelStateOf` = null; the driver's `emptyPanel` recognises it |
| `friday-detail-direct.txt` | after the shell died only one task remained and `/tasks` opened **straight into its detail** (no list): `general-purpose › count slowly`, counters, Progress, Prompt, detail footer with `x to stop · f to foreground`. Note the parent was mid-turn above the separator (`Wrangling… (running stop hooks…)`) |
| `friday-running-spinner.txt` | composer visible while the parent generates (`✶ Wrangling… (4s · thinking with xhigh effort)`): `classifyScreen` = SENDABLE with `activity: observed` (`activityFrom: spinner`). The stop driver refuses to type into this screen (`not-sendable`, why `in-flight`) |
