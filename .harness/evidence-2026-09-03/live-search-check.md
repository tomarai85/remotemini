# Live check: search hit -> jump window, phone code against the real desk (2026-09-03)

Why: #3 landed with desk e2e (fake tmux) and phone fixtures, but the phone-to-real-desk chain had never run. The
other major doors have a `live-*-check.sh`; this adds one for search + jump.

## What runs

`ios/tools/live-search-check.sh` compiles `ios/tools/live-search-main.swift` with the product's `HistoryClient`,
`HistoryModels`, `SessionsClient`, `SessionsModels`, `ResultDisplay`, `BackendSession` (the same files as the app),
picks the newest conversation from friday's registry (`~/.rc-backend/panes/*.json`, id never printed), reads the key
over ssh into stdin only, then:

1. fetches the last 40 entries and takes a word from the **oldest** non-tool entry (so `fromEnd` is tens, not 0);
2. searches it: the hit must carry `anchor` and `fromEnd`;
3. fetches `limit = fromEnd + 1`: the window must contain that anchor; `limit = fromEnd` must not (off-by-one control);
4. searches a decoy token: `matched` must be 0.

All requests are GET; the desk state is untouched. Verdict codes: 0 closed by observation, 1 red, 3 not measured
(the desk did not answer). `ios/tools/live-search-check-control.sh` fires the verdict function across every branch
(9 cases, including "unknown flag prints usage", which is also the queue's registered verifier).

## Observed

Control 9 / 9. Live run on friday (desk e025b9f, transcript of the newest conversation):
`kind=ok matched=3 fromEnd=9 inWindow=1 shortMiss=1 neg=0`, all four verdict lines `ok`, exit 0. First run used the newest entry
(`fromEnd=0`, off-by-one control skipped); the query was moved to the oldest entry of the 40-entry tail so the
control actually bites.
