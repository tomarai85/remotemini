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

## Second hole: commit messages

After the blobs came out clean (0 residual for every identifier across 559 commits), 17 commit messages still carried
the family reference, the client name, tailnet names and tailnet IPs. `git filter-repo --replace-text` rewrites blobs only,
and the PII checker used `git grep`, which also reads blobs only. So neither layer had ever looked at messages.

Fix, both layers:
- `.harness/publish-public.sh` passes the same rules file to `--replace-message`.
- `rc-backend/tools/check-no-pii.sh` reads every commit message (`git log --all`), prefixes each line with
  `<sha>:(commit message):`, and feeds it into the same history scan; the hostname (type 3) scan reads messages too.
  The Co-Authored-By trailer's organisation no-reply address is excluded in both the checker and the rule.

Controls: C22 address only in a commit message -> red and named, C22b MagicDNS only in a message -> red type 2,
C22c only a placeholder address in a message -> green. Negative control against the previous checker: C22 and C22b go NG.

A control-writing mistake on the way: my first draft reused the fixture directory name of an existing control, so the
old repo inherited my commit and its "working tree only" case turned red for a reason unrelated to the checker.
Renumbered to C22; the existing C14 is unchanged.

## Third hole: author and committer identities

Rehearsal three: blobs 0, messages 0, but 12 commits were authored with the personal address. Neither `--replace-text`
nor `--replace-message` touches identities, and the checker had not looked at them either.

Fix, both layers:
- `.harness/publish-public.sh` builds a mailmap at run time from the clone's own history (every identity that is neither
  a GitHub noreply nor an example address is folded into the most frequent noreply identity) and passes it to
  `--mailmap`. The same identities' local parts (8+ characters) become run-time redaction rules, because the bare handle
  also appeared once in a commit message. No real value enters a tracked file.
- `rc-backend/tools/check-no-pii.sh` feeds author and committer identities into the history scan; GitHub noreply
  addresses are excluded in both the checker and the mail rule.

Controls: C23 author with a real-looking address on a clean tree -> red and named; C23b GitHub noreply author -> green.

Layers a public push carries, and which tool covers each: blobs (replace-text, git grep), commit messages
(replace-message, git log), identities (mailmap, git log). A gate that reads one layer says nothing about the others.

## Fourth pass: a broader personal-data sweep of the clean clone

The PII checker is shape-based (addresses, tailnet names, this machine's hostname). Names are not shapes, so the
clone was also grepped across all history for: the family member's given name, the family mail handles, Japanese and
US phone-number shapes, the city and state, immigration terms, birth-date terms, third-party names from the client.
Everything was 0 except the family member's given name (501 across history, 3 files at HEAD). One literal rule folds it
into the same family placeholder. The tracked rules file rewrites itself in the copy, so the literal exists only in the
private history. Tom's own name stays: it is on the license.

## Published (observed 2026-09-03, GitHub API + fresh clone)

| Repo | Visibility | main | Content |
|---|---|---|---|
| github.com/tomarai85/remotemini-private | private | 95e621f | raw history, pushed from this repo over the `private` remote |
| github.com/tomarai85/remotemini | public | 80d2d66 | derived copy, 562 commits, 891 files, pushed only by the publish script's sandbox clone |

A fresh `git clone` of the public repo, checked independently: PII checker exit 0, secret sweep exit 0,
0 hits for every identifier shape above across blobs, commit messages and identities (only the GitHub noreply
identity remains), README and LICENSE present at the root.

Republish after new commits: `bash .harness/publish-public.sh --push mail-redacted@example.invalid:tomarai85/remotemini.git`
(fast-forward as long as the rules are unchanged; a rules change needs `--force` and rewrites the public history).

## Publish pipeline

`.harness/publish-public.sh`: sandbox clone -> `git filter-repo --replace-text` (rules + this machine's hostname added at run time) ->
PII checker on the clone -> secret sweep on the clone tree -> secret-shape grep over the clone's history -> push only when all are clean.
The raw repo never gets a public remote. The pre-push hook skips the PII check only for the remote named `private`.
