# The desk now knows when the agent panel is open — measured in production (row #8 stop half, steps a+b) — 2026-09-06

Commits `11e7567` (classifier) and `b61f0ef` (parser) were deployed to friday at 13:1x (deploy rc=0, service pid
7388). One disposable `rc-e2e-*` session, two same-description subagents running, `/tasks` opened, then read
through the phone's own routes:

```
GET  /status  (panel open)   200  screen:"UNKNOWN"  overlay:"panel"   activity:"unknown"
POST /messages (panel open)  409  reason:"panel"  error:"The agent panel is open on the desk, so nothing was sent. Press Esc on the desk to close it, then send again."
     pane after the send:    the panel is intact — no keystroke reached it
GET  /status  (after Esc)    200  screen:"SENDABLE" overlay:null
```

Torn down (`down rc=0`, the grace re-check in place).

## What this closes

Before today a phone send into an open panel would have typed into it: `findComposer` could pick the echoed
prompt line above the overlay (`❯ …`) as a composer, and `Enter` inside the panel opens a row rather than
sending. The desk now refuses with a sentence that names the fix. The wire keeps `screen:"UNKNOWN"` for old
builds and adds `overlay` for new ones, so nothing a shipped phone does changes.

## One inconsistency seen and fixed in the same day

The 409 body carried the raw state (`screen:"PANEL"`) while `/status` carried the wire form
(`screen:"UNKNOWN", overlay:"panel"`). The refusal body now goes through the same `overlayOf`, so the phone
sees one vocabulary. The `SERVER_ONLY` reason for `PANEL`/`DETAIL` in the vocabulary ledger was corrected
accordingly (it had said "never on the wire").

## Next (step c, per the design and the measurement)

A pure `planStop` over `parsePanel`/`parseDetail` (refusals: not-a-panel / shell-row / no-such-row / ambiguous /
too-far / mismatch / reflow), then the driver that moves ≤ N with a re-capture after every key, presses `x` only
from a verified detail view, and counts Escapes; then the route and a live instrument that stops one of two
same-description agents and proves the other kept running; then the phone button.
