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
| 5. standing controls battery | unmeasured by default | run separately, see below — 43/43 green |
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

## Read but not independently re-derived

- The plant → red → revert → green table for the seven negative controls. I verified the
  seven tests exist and that no mutation markers remain; I did not re-plant all seven.
- The screenshots' visual content.
- The backend-side poll route behaviour beyond what the suite asserts.

## Carry-over, named

- (i) Entry-point tests and the citation fix — dispatched to the Generator this pass; both
  must turn green in the DoD script without weakening it.
- (ii) `port-coverage.py` structurally cannot verify the history-merge function — it has no
  matchable literals. Unchanged from Sprint 3, still not a Sprint 4 regression.
- (iii) Two documentation ratchets diverge: the citation gate scans tracked and indexed
  content, while the no-line-reference check walks the working tree, so a teammate's
  in-progress file can block everyone. Recorded, not fixed, and not a Sprint 4 item.
- (iv) DoD rows 7 and 8 are the only two that cannot be closed on this desk at all. They
  need the physical phone.
