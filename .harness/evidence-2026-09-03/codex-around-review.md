# Codex review: history window addressed by anchor (`?around=`), 2026-09-03 23:17 run

Raw: `codex-around-review.raw.log` (read-only sandbox, prompt in scratchpad `around-review-prompt.txt`).
First run (22:2x) hung 50 minutes on stdin (detached `codex exec` without `< /dev/null`); second run hit the
usage limit at 23:0x; this run started 23:17 after the limit lifted. VERDICT: **fix-first**, blockers F1-F6.

| id | sev | where | failing input | fix |
|---|---|---|---|---|
| F1 | High | `readHistoryAround` / `readLinesForward` | first record 1.1 MB, `around=0:0`: the 1 MiB window budget runs out before the LF, `history: []`, `newerAvailable: true`, never converges | read the anchor record under its own line cap before the window budget |
| F2 | Med | `readHistoryAround` | `around=56:1` where record 56 has one entry: 200 echoing an anchor no entry carries | require the exact canonical anchor in the window, else `anchor-gone` |
| F3 | Med | history handler | `limit=bogus` -> NaN, trimming disabled, cap 500 bypassed | finite positive int clamped 1..500 (or 400) |
| F4 | Med | history handler | registered session without transcript + `around=`: early `!target` branch returns tail-shaped `{history:[]}` | choose mode before that return; around-shaped empty body |
| F5 | Med | `readHistoryAround` | 4-entry assistant record `:3` with limit=4 -> six entries ending at the anchor and `newerAvailable: true`, next request returns the same window; A/B/C `around=B` limit=1 -> `[A,B]` cannot advance | slice to `limit` around the anchor; a true flag must expose a strictly farther edge anchor |
| F6 | Med | history handler | `?q=A&around=garbage` -> search wins, 200 | reject both-present with 400 |
| F7 | Low | both readers | `{chunk: 65536, maxBytes: 1}` scans 65,536 bytes | `Math.min(..., maxBytes - scanned)` |

Disposition: all seven accepted. Fixes built by a worktree subagent (F7 also repoints the mutation targets
M43/M43f/M45/M45f whose search strings include the loop line). Landing recorded in `around-fixes.md`.
