# Public copy preparation (2026-09-03)

Tom ruling: keep the raw history in a private repo and publish a redacted derived copy in a public one.
Names: private `tomarai85/remotemini-private`, public `tomarai85/remotemini`, license MIT.
Extra redactions Tom approved: the client's name and the family reference. Machine nicknames stay.

## Sweeps before publishing

| Check | Scope | Result |
|---|---|---|
| secret sweep (`~/bin/secret-sweep.py`, structural rule) | tree at HEAD | exit 0 |
| secret shapes (keys, tokens, webhooks, private keys) | every revision | 1,804 matches, all placeholder fixtures in the redact test (body `AAAA...`); 0 real |
| third-party personal names | tree at HEAD | 0 |
| PII checker on the rewritten sandbox clone | tree + history | exit 0 |

## Hole found by the rehearsal, and closed

The rewritten history still carried the tailnet name 507 times. Every hit was one shape:
the desk test held the MagicDNS name as a **regex-escaped** literal (`host\.tail<id>\.ts\.net`).
Both the redaction rule and the PII checker required a bare `.` and passed it through.

Fix, both layers:
- `.harness/redaction-rules.txt`: an escaped-form rule and a bare `tail<id>.ts.net` rule (covers `*.tail<id>.ts.net` too).
- `rc-backend/tools/check-no-pii.sh`: the machine pattern now allows an optional backslash before each dot and an optional host part.
- The test itself now uses the placeholder host, so future public copies do not depend on the rule for this line.

Controls (`rc-backend/test/pii-controls.sh`): C13b escaped form -> red, C13c wildcard form -> red, C13d ordinary words containing "tail" -> green.
Run against the widened checker: PASS 25 / FAIL 0.
Negative control, same file against the previous checker: C13b and C13c go NG, C13d stays OK (PASS 23 / FAIL 2), so the new controls can fail.

The other residual my first grep reported (539 hits of `100.128.0.1`) is outside CGNAT 100.64/10 and is a deliberate negative fixture, not a leak.

## Publish pipeline

`.harness/publish-public.sh`: sandbox clone -> `git filter-repo --replace-text` (rules + this machine's hostname added at run time) ->
PII checker on the clone -> secret sweep on the clone tree -> secret-shape grep over the clone's history -> push only when all are clean.
The raw repo never gets a public remote. The pre-push hook skips the PII check only for the remote named `private`.
