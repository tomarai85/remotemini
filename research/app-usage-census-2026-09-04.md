# App usage census — what the phone actually touches

Source: `athenas:~/Library/Logs/rc-backend/rc-backend.log`, 25,885 `req` lines,
2026-08-25T20:11Z – 2026-09-04T15:42Z (no rotation; no `.tail` file exists, so this is the
complete history). Per-request `client=` classification only exists from 2026-08-27T06:40Z
onward (1,172 earlier lines predate that instrumentation and are excluded from all `client=`
splits below). All commands were run read-only over `ssh athenas`.

## VERDICT

1. Phone traffic (`client=app`) is real, daily, and **narrow**: 1,172 requests over 8 days
   (2026-08-27 → 2026-09-04, no gap day), but 79% of it (928/1172) is just `/api/account` +
   `/api/sessions` — the account/session-list screens, not conversation content.
2. Within actual conversations, usage is concentrated on **2 of 37 sessions ever seen by the
   desk** (88% of session-scoped app hits). The phone sends messages rarely (11 in 8 days) and
   interrupts rarely (5).
3. **9 routes with a fully-built iOS client have zero phone traffic ever**: diff, status,
   queue-clear, title/rename, archive-toggle, choice, attach-file, new-session (both entry
   points), account/next. Of those, **6 have zero traffic from ANY client** (not even your own
   control/test probes) — they are unbuilt-in-anger, not just unused by you.
4. Errors the phone actually saw are low: 6 `401`, 5 `404` in 8 days. The big non-2xx bucket
   (230, `code=0/aborted`) is normal connection-drop on poll, not a user-visible failure.
5. **Implication for what to build next**: don't add more parity rows. The next-session-in-root
   flow (`new-session`) just got un-404'd (2026-09-03) and has *never fired end-to-end even in
   your own testing* — that, plus status/diff/archive, are built-but-unverified, which is a
   different and higher-priority bug class than "missing feature."

## 1. Routes the phone has hit, and how often

```
ssh athenas 'grep "client=app" ~/Library/Logs/rc-backend/rc-backend.log | awk "{print \$5}" | sort | uniq -c | sort -rn'
```

| route (path shape) | app hits |
|---|---|
| `/api/account` | 477 |
| `/api/sessions` | 450 |
| `/api/sessions/:id/poll` | 158 |
| `/api/sessions/:id/history` | 38 |
| `/api/sessions/:id/digest` | 32 |
| `/api/sessions/:id/messages` (POST, sends) | 11 |
| `/api/sessions/:id/interrupt` (POST) | 5 |
| `/api/account/select` (POST) | 1 |

Total 1,172, matching the standalone `client=app` count exactly. Time span of app traffic:
first `2026-08-27T15:27:58Z`, last `2026-09-04T04:38:43Z` (11h before the log's overall last
line, which was a `tool` request — the phone's last touch was 09-04 pre-dawn, not "just now").
`route=tmux`/`route=worker` sub-labels (142/6 of the 158 polls) describe which backend engine
was driving the session being polled — almost always the live tmux pane, not the worker path.

## 2. Routes with ZERO phone traffic

```
ssh athenas 'for r in stream queue title archive choice new return-request attach-file; do grep -cE "sessions/:id/$r( |$)" ~/Library/Logs/rc-backend/rc-backend.log; done'
grep -rn "appendingPathComponent" ios/Sources/Core/*.swift
```

| route | app hits | any-client hits | phone UI exists? |
|---|---|---|---|
| `/api/sessions/:id/diff` | 0 | 17 (`tool`) | Yes — `DiffClient.swift`. Never used by phone. |
| `/api/sessions/:id/status` | 0 | 57 (`control`+`tool`) | Yes — `StatusClient.swift`, built 2026-09-02. Never used by phone (likely hasn't reached device build yet — see §3). |
| `/api/sessions/:id/queue` (DELETE) | 0 | **0** | Yes — `ClearQueueClient.swift`. Fired by nobody, ever. |
| `/api/sessions/:id/title` (rename) | 0 | **0** | Yes — `TitleClient.swift`. Fired by nobody, ever. |
| `/api/sessions/:id/archive` (toggle) | 0 | **0** | Yes — `ArchiveClient`/`ArchivedListView.swift`. Fired by nobody, ever. |
| `/api/sessions/:id/choice` | 0 | **0** | Yes — `ChoiceClient.swift`. Fired by nobody, ever. |
| `/api/sessions/:id/attach-file` | 0 | **0** | Yes — `AttachClient.swift`, added 2026-09-03. Expected to be zero (too new). |
| `/api/sessions/:id/new` | 0 | **0** | Yes — `NewSessionClient.swift`. Un-404'd 2026-09-03; never fired since, by anyone. |
| `/api/roots/:i/new` | 0 | **0** | Yes — `RootsClient.swift`. Same story as above. |
| `/api/account/next` | 0 | **0** | Yes — `AccountClient.swift`. Fired by nobody, ever. |
| `/api/roots`, `/api/roots/:i/paths` | 0 | 3 each (`tool`) | Yes — `RootsClient.swift`. Never used by phone. |
| `/api/sessions/:id/attach` (image) | 0 (app-tagged) | 3, all pre-instrumentation (client unknown) | Yes — `AttachClient.swift`. No confirmed phone use in the tagged window. |
| `/api/sessions/:id/stream` | — | — | **No client at all** — grepped `ios/Sources` for SSE/EventSource, no caller exists. Correctly absent, not a gap. |

**Cannot answer from this log**: whether any of the 450 `client=app` hits to `/api/sessions`
used `scope=archived` (the archived-list view) — `reqlog.mjs` deliberately strips query strings
before logging (`?…` discarded by design, see its own doc comment), so archived-list traffic is
indistinguishable from the default list in this data. Don't infer either way.

## 3. App builds that have talked to the desk

```
ssh athenas 'grep "client=app" ~/Library/Logs/rc-backend/rc-backend.log | awk "{for(i=1;i<=NF;i++){if(\$i~/^2026-/){split(\$i,d,\"T\");day=d[1]};if(\$i~/^build=/){b=\$i}};print day,b}" | sort | uniq -c'
```

Distinct `X-App-Build` values seen, oldest→newest: `1`, `96`, `100`, `102`, `105`, `115`, `116`,
`117`, `120`, `121`, `124`, `125`, `135`, `138`, `145`, `152`. Currently-approved build per
`.ota-approved-build` in this repo is **155** — the phone was 3 builds behind as of its last
request. Progression by day is roughly monotonic (108-30 → 152 on 09-04), consistent with normal
OTA delivery lag, not a stuck device.

**Cannot cleanly answer "which builds are really you vs. a stray test rig"**: `reqlog.mjs`'s own
doc comments record that the build-number field was flat-out wrong before 2026-08-31 (it read
the UA short-version string, which was `1` for effectively every real build), and that even the
current `client=app` bucket is an *upper bound* — it also catches your own device-Swift test
harnesses (`ios/tools/build.sh`, `live-*-check.sh`, anything not sending `X-RC-Role: control`)
that are indistinguishable from your real phone by user-agent alone. The 402 `build=1` /
84 `build=-` hits concentrated on 08-30/08-31 are most likely pre-fix noise, not 402 real
requests from a build-1 device — but the log cannot prove that either way, so treat build-level
attribution before 08-31 as unreliable, not zero.

## 4. Sessions touched

```
ssh athenas 'grep "client=app" ~/Library/Logs/rc-backend/rc-backend.log | grep -oE "sid=[a-f0-9]+" | sort | uniq -c | sort -rn'
```

14 distinct session ids out of 37 the desk saw at all in this window received any session-scoped
app request (244 requests total once the 928 non-scoped `/api/account`+`/api/sessions` hits are
excluded). Concentration: `sid=efe9ee71` (196) + `sid=7c625b3e` (19) = 215/244 = 88%. The
remaining 12 sessions got 1–5 touches each — one-off checks, not sustained conversations. One
oddity: `sid=00000000` appears 5 times — worth a look, likely a placeholder/unassigned session id
rather than a real conversation; not investigated further here (out of scope for a read-only
census).

## 5. Failures the phone actually hit

```
ssh athenas 'grep "client=app" ~/Library/Logs/rc-backend/rc-backend.log | grep -oE "code=[0-9]+ reason=[a-z0-9-]+" | sort | uniq -c | sort -rn'
```

| code | reason | count | read |
|---|---|---|---|
| 200 | - | 918 | normal |
| 0 | aborted | 230 | connection dropped before response — routine on mobile polling, not a user-visible error |
| 202 | - | 11 | accepted-async, normal |
| 401 | unauthorized | 6 | real auth failures the phone saw |
| 404 | unknown-session | 5 | phone referenced a session the desk no longer has (likely archived/expired) |
| 200 | not-running / not-in-flight | 2 | interrupt sent to a session with nothing to interrupt |

Nothing here suggests the phone is silently failing at scale. 401/404 total 11 events in 8 days
across 1,172 requests — worth knowing about but not the story.

## 6. What surprised me

- The **home-screen routes dominate everything else 4:1** (`/api/account` + `/api/sessions` =
  928 of 1,172). If build priority follows "what gets touched," that's the list/account screen,
  not the chat view.
- A meaningful slice of the "15 landed" parity rows are landed-but-cold: built client, wired
  route, **never once exercised**, not even by you testing it. That's a different risk than
  "feature missing" — it means the first real user of `queue`, `title`, `archive`, `choice`,
  `account/next`, and the new-session flow will be the first end-to-end test of each.
- The log is honest about its own limits by design (query strings dropped, raw UA never stored,
  `client=app` documented as an upper bound in its own source comments) — worth preserving that
  discipline rather than trying to sharpen attribution retroactively from this data.
