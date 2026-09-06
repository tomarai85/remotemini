# The completion detector fires in production, once, and stays silent (parity row #32) — 2026-09-06

`digest-notify.sh` gained a log-only "completion transition" detector on 2026-09-04. After 36 hours on friday its
log file did not exist. That is two hypotheses with one face: the detector is broken, or the transition never
happened on a population of three registered sessions of which one is idle. The only way to separate them is to
cause one transition and watch.

## The instrument

`rc-backend/tools/live-completion-check.mjs` (exit codes 0 closed / 1 red / 2 setup aborted / 3 not measured,
registered in `test/live-exit-codes.test.mjs`; verdict controls `test/live-completion-log-controls.sh`, 15 cases).
It builds a disposable `rc-e2e-*` session through the phone's own launcher, sends one message through the
phone's own route (`POST /api/sessions/:id/messages`: run `sleep 200` in Bash, then say done), reads the
session's digest every 10 s until it has seen `attention=none` (generating) and then `input` (stopped), then
waits up to two notifier ticks for a line naming that session in `~/.rc-backend/digest-completion.log`, checks
that `digest-notify.log` never rang for that session, and tears the session down (verified gone, one retry).

## Observed (09:44–09:48, friday)

```
kind=ok activity_seen=1 stopped_seen=1 completion_logged=1 window_min=60 no_alert=1 torn_down=1 torn_retry=0 limited=not-limited
→ 完了の記録の確認: 観測で閉じた   (exit 0)
```

friday's completion log, first line it has ever held:

```
1788706067  completion  e083612b-…  window_min=60  assistant=2  writes=0  presence_fresh=1
```

`digest-notify.log` for the same ticks: 「鳴らす物は無い」. The detector records and does not ring — the design's
one load-bearing property, now seen on the real machine rather than in the 14 controls.

## Two things the numbers say that the design did not anticipate

1. **`window_min` is not the length of the work.** It is the digest's lookback window (60 minutes, fixed). The
   design asked for "the distribution of window lengths at fire time" as the empirical answer to "how long is
   long enough"; this field cannot answer it. The span that can is the one this instrument itself measured —
   the time between the first `none` and the first `input` (about 200 s here). Before any default flips, the
   detector should record that span (first-activity-seen to stop), which needs one more per-session field in
   the notifier's state, not a new classifier.
2. **`presence_fresh=1`.** `presence-beat.sh` had touched `~/.rc-backend/presence-desk` within 180 s, so this
   completion would have been suppressed as "Tom is at the desk". Correct behaviour for the feature; for the
   measurement it means the third number (fires while present) will be dominated by the beat's cadence unless
   the beat is only sent when a person is actually there.

## What this closes and what it does not

Closes: "is the detector alive in production" — yes. Does not close: the three numbers. Those come from real use,
and number 2 needs the span field above first. The phone-side toggle stays out of scope, as the design says.

## A defect this instrument's controls found in three older instruments

The verdict matched fields with `String.includes`, so `completion_logged=10` satisfied `completion_logged=1`.
The controls' "similar field name" case caught it before the first live run. `live-composer-guard-check`,
`live-write-routes-check` and `live-cold-routes-check` had the identical weakness and no such control; all three
now match whole fields and each carries the case. The mechanism is the usual one: a check that cannot fail on
a near-miss input is not measuring the field, it is measuring a substring.
