# Sprint 4 Evaluation — poll loop, unreadable meter, gap handling

Evaluator pass run 2026-08-05 by the team lead, independently of the Generator's own
report. Ground rule for this pass: **the Generator's prose is an input, not evidence.**
Every number below was re-derived on this desk; where I only read something and did not
re-derive it, it is listed under "read but not re-derived" and not counted as verified.

Deliverable of this pass, beyond the findings: the by-hand checks are now a script,
`.harness/dod-sprint-4.sh`, with its own control at `.harness/dod-sprint-4-controls.sh`
(27 assertions, registered in the standing battery). A hand measurement gets re-done by
hand next sprint; a scripted one does not.

---

## Verdict

**FAIL at first pass, on two rows.** Neither is a correctness defect in shipped behaviour
— the poll loop, the meter and the gap path are genuinely built and genuinely tested. Both
are *claim-vs-measurement* defects, which is the failure mode this project keeps hitting
and the one that erodes trust in every other green.

Rows sent back to the Generator, with the measurement attached, before this sprint closes.

---

## Finding 1 (highest) — "both buttons are wired and tested independently" is false as measured

The Sprint 4 design-decision list states that the retry and the re-read buttons are wired
and tested independently. Measured over `ios/Tests`:

| symbol | references from any test |
|---|---|
| `handleForegroundResume` | **0** |
| `retryPollingNow` | **0** |
| `rereadNow` | **0** |

Before writing this up I traced the call graph rather than declaring the feature untested,
because the two are not the same claim:

- `performResync()`'s **body** *is* exercised, end to end. The gap tests drive it and assert
  both that a second `/history` request is issued and that the refetch's own response lands
  in `history`. That is a real test of the resync mechanism.
- What is untested is every **entry point into** that mechanism: the foreground-resume hook,
  and each of the two buttons.

The sharpest part is the overlap with the Generator's own reasoning. The same decision list
records that splitting retry from re-read was a judgement call the brief did not pin — so
**the one behaviour that was invented is the one behaviour with no test**, and it was
reported as tested. A test that passes for both implementations of that split would test
nothing; the assertion has to be on the difference.

Also unguarded: the SwiftUI transition condition (fires only on background → active). As
written it is not reachable from a unit test, so an `.inactive` → `.active` transition
firing a spurious resync would not be caught. Either extract the decision into a pure
function and test it, or record explicitly why not.

The Generator's own note that this guard was "caught during implementation, not by a test
failure" is exactly the shape of the finding: it means nothing on the desk would catch it
coming back.

## Finding 2 — a cited test name does not exist

The progress file names `testUnreadableLeavesCursorUntouchedAndInventsNoLocalBackoffNegativeControl`
in two places. No such test exists. The real test is the same name **without** the trailing
`NegativeControl`, and it does exist and does assert the right thing — so the substance
holds and nothing shipped is weaker than reported.

It still matters, because a citation that cannot be grepped is documentation rot at step
one: the next reader either cannot check it, or checks it, finds nothing, and stops trusting
the surrounding table. Measured: **39 distinct test names cited across the progress file, 1
of which resolves to nothing.** That ratio is now a permanent row in the DoD script, so the
next table with an invented row fails the commit rather than being caught by chance.

## Finding 3 — the reported test count is 2 higher than the measured one

Reported: 214 tests, stated twice. Measured two independent ways:

- `func test` declarations on disk in `ios/Tests`: **212**
- the headless simulator run's own summary: **212, with 0 failures** (recorded twice in the log)

The DoD bar is "more than Sprint 3's 150", so 212 clears it and the row passes either way.
Recording it anyway: a count that is 2 off in the direction of the reporter's own success is
the cheapest possible early warning that a number was carried over rather than re-read, and
this project has already paid for ignoring that shape once tonight.

---

## DoD table — result at evaluation time

Run with `bash .harness/dod-sprint-4.sh` (default mode; exit 0 green / 1 red / 2 unmeasured).

| row | result | basis |
|---|---|---|
| 1. unit suite | green | log 212 / 0 failures / matches disk count / clears the 150 bar |
| 2. seven §5-a negative controls | green | 7/7 exist by name |
| 2-b. no mutation residue | green | 0 mutation markers under `ios/Sources` + `ios/Tests` |
| 3. ten §5-b branches | green | 10/10 exist by name |
| 4. §5-c stage transitions | green | 7/7 exist; the meter takes time as a parameter and never reads the clock itself |
| 5. standing controls battery | unmeasured by default | run separately, see below — 43/43 green at evaluation time; **44/44 green** after this pass (`no-linerefs-controls.sh` was registered into the standing list, so the denominator itself grew by one) |
| 6. simulator evidence | unmeasured by design | both PNGs exist; what is *in* them can only be judged by eye |
| 7. live device, message on the wire | unmeasured | needs Tom's phone |
| 8. live device, foreground refetch | unmeasured | needs Tom's phone |
| 8-b. resume / manual-refetch entry points | **red** | Finding 1 |
| 9. progress file citations resolve | **red** | Finding 2 |

Rows 5 and 6 are deliberately *not* green. Row 6 in particular: the files being present is
measurable, the pictures being right is not, and collapsing those two is how an evidence
directory turns into decoration.

## Independently re-run, in the foreground

- Standing controls battery — **43 green / 0 red / 0 unmeasured.** This supersedes the
  Generator's mid-sprint reading of 33 green / 8 red / 1 unmeasured; those reds were the
  six controls that were on disk but not registered in the standing list, plus fallout,
  and both halves are now closed.
- `npm test` on the backend, via the commit gate — **666 / 666 green.**
- Mutation-target check — **241 targets, 0 unmatched.**
- Vacuous-test scan — **0 anchorless tests** (self-test 17/17).

## Two defects the new DoD script and its control found in each other

Recording these because they are the same class as Finding 1, committed by me, in the tool
built to catch it:

1. The stage-transition row asserted "the meter does not read the clock itself" with a plain
   search for a clock call. It went red. What it had matched was the **doc comment saying the
   meter does not read the clock** — the implementation was correct and the criterion was
   wrong. When a check rejects a correct thing, suspect the reference point, not the thing.
   The row now strips comments *and* requires the positive form (a declaration that takes
   time as a parameter), and the control fires it three ways, including the middle case:
   a clock call inside a comment must stay green. Without that middle case the exact
   mistake I made becomes undetectable again.

2. The unit-suite row read the failure count from the last field of the summary line. The
   last word of that line is "failures" — a word, not a number — so the count was always
   zero: a suite with real failures would have been reported as clean. The control caught it
   on first run.

3. The control itself expected the evidence row to be green when both files exist. It is
   unmeasured by design. The control's expectation was what was wrong, not the subject.

## Screenshot content — viewed directly (DoD row 6's substance)

The DoD script leaves row 6 unmeasured on purpose: it can prove the files exist, not that
the right thing is in them. I opened both.

| | degraded (stage 1) | stalled (stage 2) |
|---|---|---|
| notice | grey, "更新が遅れています" | **red**, "応答が確認できません" |
| buttons | none | 再試行 and 読み直す both present |
| last-checked stamp | 13:49:13 | 13:49:16 |
| conversation body | fixture only — no account, no real name, no device identifier | same |

The two states are genuinely distinguishable, and the stage-2 shot is the only artifact in
the sprint that shows the two buttons actually rendering. Both were untracked; on a clean
clone row 6 would have been red for everyone but this machine. Now committed, after being
viewed rather than before.

**One gap the pictures reveal.** The stamps are three seconds apart. §5-c escalates to
stage 2 by *either* of two paths — three consecutive unreadable marks, or ten seconds
elapsed — and a three-second gap can only be the first. So the visual evidence covers one
escalation path of two. The ten-second path has a test and no picture. Not a defect; worth
naming, because "we have screenshots of the stalled state" reads as covering both.

## Read but not independently re-derived

- The plant → red → revert → green table for the seven negative controls. I verified the
  seven tests exist and that no mutation markers remain; I did not re-plant all seven.
- The backend-side poll route behaviour beyond what the suite asserts.

## Closing pass — both reds closed, verified on this desk (2026-08-05 14:45)

Re-ran the DoD script after the Generator's fix pass. Rows 8-b and 9 are green, and
the script itself is byte-identical to the version that failed them — a red closed by
weakening the check is not closed, so that was checked before the result was read.

- **Finding 1.** All three entry points are now driven directly. The load-bearing part
  is not that they are called but that the retry/re-read split is asserted as a
  *difference*: retry must not refetch and must not clear the live buffer, re-read must
  do both. An implementation that collapses the two into one call fails that test —
  which is exactly what the Generator's own mutation of it produced, with the failure
  numbers recorded. The scene-phase guard was extracted into a pure predicate and
  mutated two ways, the second being the case named in Finding 1: dropping the
  background half of the edge so that launch itself would fire a spurious resync.
- **Finding 2.** 42 cited test names, all resolving.
- **Finding 3.** 216 on disk, 216 in the log, one run, zero failures.

Committed after the full gate chain, no `--no-verify`. The gate stopped the first
attempt: the progress-file paragraph describing the removal of a line-number citation
had reproduced the removed numbers in order to describe them. Naming a bad citation is
not an exemption from the ratchet.

## A row the DoD script was missing, found while verifying it

Reading the run log to confirm the count, the tail turned out to be a second target:
the UI tests, a separate scheme target living outside the unit-test directory the
script scans. They ran and passed in the same run — but the script could not see them.
Deleting every UI test would have left the table fully green. Same shape as the rest of
this sprint's findings: a scope that quietly excludes something, reported as coverage.

Added as its own row, matched **by test name**, not by count — the log prints a
per-class `Executed N tests` line, so a count-based check would have matched an
unrelated class of the same size and gone green for the wrong reason. Its control
fires that specific case: a log with the right count and the wrong names must be red.
Without that assertion, "matched by name" would be an unproven design claim.

Controls: 27 → 31, all green. DoD: 8 green / 0 red / 4 unmeasured.

## The citation-accuracy question, and why it produced no tool

Line-number citations across the two long design documents were measured, since the
commit gate freezes their count but does nothing about the ones already written.

The measurement failed, repeatedly, and the failures are the result worth recording.
Five different numbers were produced and every one was an artifact of the instrument
rather than a property of the documents: a mismatch count that came from scoping
keywords to a single line when the citations sit on bare list lines; a revised count
whose "matching" side was then shown by hand to contain false greens; and a
missing-file count that was entirely composed of files that exist perfectly well
outside this repository, which the path resolver never looked in.

Two content-level alarms were raised from it and both were wrong, in the same way: a
table was judged without reading the section containing it. In one case the section was
a dated pre-implementation diagnosis, and the document's own stated convention is to
annotate such sections rather than rewrite them; the fix it planned is recorded as
landed further down. That is the same error as the false red this sprint's DoD script
produced against a doc comment — a fragment judged outside its enclosing context.

What survives is only what was read by hand: three sampled citations in the design
document all pointed at unrelated lines, two of them displaced by exactly the same
offset, which is the signature of a single insertion near the top of the file rather
than gradual drift. Two of three sampled *matches* were false. An earlier hand pass,
quoted in the commit gate's own advice text, found 13 of 33 stale. No citation was ever
out of range — a reader always lands somewhere plausible, which is why this rots
without anyone noticing.

The conclusion is a negative one and it is deliberate: no instrument was committed. A
proximity check cannot see document structure, and shipping one immediately after it
produced five wrong numbers and two wrong alarms would be repeating this sprint's own
central finding rather than acting on it. The mechanism that does work is already in
the repository — the ratchet that refuses new line-number citations and directs writers
to cite content instead. It stopped a commit tonight, which is the evidence for it.

## Carry-over, named

- (i) ~~Entry-point tests and the citation fix~~ — **closed**, see the closing pass above.
  Both turned green with the DoD script unchanged, and the difference between the two
  manual-refetch buttons is asserted rather than assumed.
- (ii) `port-coverage.py` structurally cannot verify the history-merge function — it has no
  matchable literals. Unchanged from Sprint 3, still not a Sprint 4 regression.
- (iii) ~~Two documentation ratchets diverge~~ — **the diagnosis was right and the
  prescription was wrong.** Closed with a fix at a different layer; see below.
- (iv) DoD rows 7 and 8 are the only two that cannot be closed on this desk at all. They
  need the physical phone.

## Carry-over (iii), closed — and the prescription in it was wrong

The carry-over said: the two ratchets disagree about what they read, so make the
code-side check read the index like the doc-side one. That was written without
measuring what the code-side check actually is.

**The premise, measured.** The commit chain is `pre-commit` → `pre-commit-gates.sh` →
`commit-suite-gate.sh` → `npm test`, and it runs in the working tree — no stash, no
`checkout-index`, no temporary worktree. So every test in that suite judges what is on
disk (the count is deliberately not repeated here: it changed with this pass and a
carried-over number is the defect Finding 3 is about). The
no-line-reference check is a member of that suite. Switching it alone to index content
would put **two different snapshots of the repo inside one `npm test` run**: its verdict
would describe the index while every neighbouring test described the disk. The doc-side
ratchet has no such constraint — it is pure prose accounting, and the index is the right
denominator there because it gates what enters the repo.

So the divergence is correct, and the fix as written would have made things worse while
looking like closure.

**What the carry-over got right was the symptom, and tonight it happened for real.** Not
to a teammate's file — to mine. The standing controls battery was still running in the
background (one process, confirmed by parentage; the other candidates were its own
children, already exited), and it had written a probe into the very directory the check
scans. My foreground `npm test` picked the probe up and went red. By the time the verdict
was on screen the file was gone: the control removes it on exit, so the cause of the red
does not survive in the tree. A red whose evidence deletes itself is the expensive kind.

The probe cannot be moved out. The control that places it exists to check that a mutation
run **freezes** its source tree, so dirtying the running tree is the measurement, not an
implementation detail of it.

**The fix, at the layer where it belongs.** The freeze control already refuses to start
while a run is live, using the repository's single liveness oracle. The commit gate did
not ask. It does now, and it follows the rule that oracle's own header states — proceed
only on *exactly* "confirmed absent"; both "running" and "could not tell" mean stop. It
stops as **unmeasured**, not as a failure, because what broke was the measuring condition
and not a test; and unmeasured still blocks the commit, so nothing is skipped into green.

Controls for that gate: 11 → 15. Against the pre-fix gate the three new ones go red and
the fourth stays green — the fourth is there so that "always returns unmeasured now" is
distinguishable from "discriminates".

## A third instance of the same shape, in a second instrument

The DoD script could not see the UI test target. Checking whether anything else was
scoped the same way turned up the line-reference check, which walks two trees by an
explicit list of directories — and the phone-side list named three of the four that
exist. `UITests` was absent. Every UI test file was outside the reach of the check that
is supposed to cover the phone tree, and had one been written with a line-number
citation, nothing would have reported it.

Adding the missing directory is the small half. The instrument was wrong in a way that
would recur on the next directory anyone adds, so the check now derives its own scope
from the tree: every directory at the top of a scanned tree must be either scanned or
excluded **by name with a reason**, and anything unlisted fails. Running it immediately
produced two unlisted directories that had never been considered, both correctly excluded
once looked at, and one exclusion written pre-emptively for a directory that does not
exist yet — because it appears the moment anyone installs dependencies, and discovering
that through a repo-wide false red is the expensive way to learn it.

The reverse direction — failing when an exclusion goes stale — is deliberately not
asserted, and the reason is in the code: build output is legitimately absent in a clean
clone, so that assertion would fire on exactly the machines that had done nothing wrong.

Its control: 8 → 11 assertions. The unit-level negative control inside the check proves
the *function* rejects an unlisted name; it cannot prove the function is wired to the
real tree. So the control plants an actual directory in the phone tree, requires the red
to name it, and requires green to return when it is removed. Against the pre-fix check
the first two fail and the third passes — the same discrimination test as above.

**Closing measurement for both fixes.** The standing battery was started *after* the last
edit, so what it measured is the shipped state and not a half-applied one: **44 green /
0 red / 0 unmeasured**, exit 0. The denominator is one larger than at evaluation time
because `no-linerefs-controls.sh` was registered into the standing list during this pass —
a control that exists on disk but is not in that list is exactly the shape this file has
now caught three times, so it was registered rather than left to be rediscovered.
