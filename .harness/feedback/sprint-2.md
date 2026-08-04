# Sprint 2 Evaluation — iOS Native Shell, List 画面

- Mode: 3 (Full) — Planner -> Generator -> Evaluator per sprint
- Loop iteration: 1
- Brief (authoritative, overrides spec prose): `.harness/sprint-2-brief.md`
- Progress claim under review: `.harness/progress.md` (committed section, lines 211-565, plus the
  currently uncommitted working-tree diff to the same file)
- Commit evaluated: `1871809` ("Sprint 2: sessions list screen, SessionsClient/models,
  RelTime/Freshness ports, UI-test fixture harness")
- Evaluated by: Evaluator agent, 2026-08-05
- Environment constraints observed: no GUI ever opened (no `open -a Simulator`, no Xcode.app --
  confirmed both by my own conduct and by grep that no tool script in the repo invokes them
  either); all builds via `xcodebuild -sdk iphonesimulator ... test`, headless, via
  `ios/tools/build.sh --sim` invoked directly with full log capture (not its own truncated
  summary line alone -- I grepped the full underlying log for every `Test Case ... failed` and
  `Executed N tests` line myself); no physical iPhone available (device-only DoD items are
  reported UNVERIFIED below, not penalized, per the team-lead's instruction); never pushed;
  never committed (read-only); `.harness/progress.md` was not modified by me.

## Team-lead's 5 directed-suspicion items

### 1. §4-a rulings -- verified by mutation, not just "a test exists"

I read `ListViewModel.swift` (state machine), `SessionsClient.swift` (error taxonomy), and
`ListViewModelTests.swift` (270 lines) in full, then planted three targeted mutations myself,
one at a time, rebuilt+ran the whole suite via `ios/tools/build.sh --sim`, and reverted each
before the next. All three went red exactly where they should, nothing else moved:

| Mutation | Expected defect class | Result |
|---|---|---|
| `static let unreachableThreshold = 3` -> `1` | wrong threshold value (1(d)) | `exit 65`. 8/17 `ListViewModelTests` cases red, including `testOneFailureWithPriorListStaysRetryableNegativeControlForThresholdLoweredToOne` (name is literally about this exact mutant). 9 cases in the same class stayed green -- not a wholesale suite collapse, a targeted hit. |
| Merged `.failure(.cancelled)` into the counted branch (`case .failure(.unreachable), .failure(.malformedBody), .failure(.cancelled): consecutiveFailures += 1 ...`) | cancellation wrongly counted as a failure (1(a)) | `exit 65`. Exactly 2 red: `testThreeCancellationsDoNotAdvanceTheCounterNegativeControlForMergedCatch` and `testCancellationsInterleavedWithRealFailuresOnlyCountTheRealOnes`, both failing with the literal assertion message `"merged-catch mutant detected: got unreachable(...) after N cancellations"` -- the test was purpose-built to name this exact mutant, not a coincidental catch. |
| `.success` only reset the counter when `response.paneFault == nil` (instead of unconditionally) | paneFault+200 not resetting the counter (1(b)) | `exit 65`. Exactly 1 red: `testPaneFaultWith200ResetsTheCounterToZero`, failure message `"expected .retryable (counter reset by the paneFault 200), got unreachable(...)"`. |

Item 1(c) (threshold held as a single named constant, no bare literal in the conditional) is a
static-structure claim, not a runtime-mutatable one -- confirmed by direct code reading:
`failurePhase()` reads `if consecutiveFailures >= Self.unreachableThreshold`, no bare `3`
anywhere in the branch logic. Item 1(d)'s value (3) is confirmed both by reading the constant
and by mutation above.

After all three mutations, `ListViewModel.swift` was diffed against
`git show HEAD:ios/Sources/Screens/List/ListViewModel.swift` and is **byte-identical** to the
committed version, and a clean rebuild afterward (`build.sh --sim`) is back to
`Executed 97 tests, with 0 failures` + `Executed 3 tests, with 0 failures` (unit + UI bundles),
exit 0. `git status --short -uall` shows exactly `M .harness/progress.md`, nothing else --
confirmed with a literal diff, not just eyeballing.

**Verdict: PASS, self-verified by mutation** (not merely "a test file exists for this").

### 2. The 3 evidence PNGs -- do they actually depict the claimed states

Confirmed distinct first (already done before this session's continuation): all three are valid
PNG, 1206x2622, three distinct MD5 hashes, three distinct non-trivial sizes (190731 / 332407 /
244753 bytes). That much only proves "not the same file three times," which the team-lead
explicitly said is not enough.

I then **visually inspected all three via direct image read** (no OCR/pixel-diff tool was
available to me -- Playwright/Simulator.app/computer-use are all out of scope per my hard
constraints, so this is a direct visual read, the strongest verification available to me, not a
fully automated one):

- `list-normal.png`: title "セッション", 5 distinct rows, one per `RouteLabel.Kind`
  (choice/tmux/worker/blocked/unknown), each with the emphasis/color the code assigns
  (red-tinted choice row, blue "ワーカー・実行中", orange "送れない", gray "状態不明" for the
  unknown-kind fallback row). No fault banner, no empty-state text visible. The row title
  "承認待ちの一件" is present verbatim -- the exact string `RemoteMiniUITests.swift` asserts via
  `app.staticTexts["承認待ちの一件"]`.
- `list-panefault.png`: an orange/peach banner at the top reading "pane-scan-timeout" /
  "tmux ペインの走査がタイムアウトしました。" -- both strings are byte-identical to what
  `testListPaneFaultShowsTheFaultBannerText` asserts against `app.staticTexts[...]`. Below the
  banner, the prior "承認待ちの一件" row is still visible, matching the `priorSessions` design
  (paneFault suppresses nothing but its own fault, prior list stays shown).
- `list-empty.png`: title "セッション", centered "会話がありません", nothing else -- matches
  `testListEmptyShowsTheNoConversationsMessage`'s `XCTAssertEqual(empty.label, "会話がありません")`
  exactly.

All three genuinely, visibly correspond to their claimed state, and each matches the literal
strings the UI-test suite independently asserts (not just "a banner appeared somewhere").

**Verdict: VERIFIED by direct visual inspection**, not UNVERIFIED -- with the caveat that this
was a manual visual read against known literal strings, not an automated pixel/OCR diff (none
was available to me).

### 3. Lethality of the new test suite (mutation testing, budget-bounded)

Covered directly by item 1's three mutations above -- all three real, all three killed by the
existing suite, all three cleanly reverted. `git status --short -uall` confirmed back to exactly
`M .harness/progress.md` after the last revert (see item 1 for the literal diff-empty
confirmation).

I did not attempt additional mutations beyond these three (e.g. against `RelTime`/`Freshness` or
the Decodable models) given the fixed evaluation budget; `RelTimeTests.swift`/`FreshnessTests.swift`
already carry their own inline "wrong implementation" negative controls (e.g.
`testFoldingUnknownToFreshEmptyMustGoRed`), which is a stronger, cheaper form of the same
guarantee than an externally-run mutation would add.

### 4. Scope creep / undelivered scope

Checked against the **actual commit diff**, not a grep of the whole tree (which would also catch
harmless Sprint-1 files that merely mention "Conversation" in an exclusion comment):

```
git show --stat 1871809
```

Touches exactly: `SessionsClient.swift`, `SessionsModels.swift`, `SessionsListingFixture.swift`,
`RelTime.swift`, `Freshness.swift`, `ListView.swift`, `ListViewModel.swift`, their four test
files, `RootView.swift` (List wiring), `AppState.swift`, `MockURLProtocol.swift` (test support),
`RemoteMiniUITests.swift`, `shots.sh` / `ui-fixture-absence-control.sh` /
`ui-fixture-behavior-control.sh`, `project.yml`, the three evidence PNGs, `progress.md`, and two
`run-controls.sh`-family registration files. Nothing from `Conversation`, poll/SSE, composer,
interrupt, `Backoff`/`PollCursor`/`ReadablePoll`/`HealthzClient`/`SessionsAuthProbe`/
`RedirectRefusal`/`KeyEntryViewModel` is in this diff -- those files exist in the tree (Sprint 1)
but this commit does not touch them. A broader `grep -rniE` across the whole `ios/` tree for
Conversation/poll/SSE/composer/interrupt/mergeHistory/unreadableStreak/queued turns up matches
only in comments explaining why those things are *deliberately absent this sprint* (e.g.
`ListViewModel.swift`'s "no fifth trigger, and in particular no 'return from Conversation'"),
never in actual implementation.

§1-a lists exactly 6 build items (SessionsClient / models / 2 C-group ports / List screen incl.
all §5-2 branches + memory cache / RootView swap / UI-test target + fixture gate). All 6 are
present in the diff above. I did not find any "Day 1 / Day 2" split inside `sprint-2-brief.md`
itself (§1-a is a flat list, not staged) -- if the team-lead has a separate schedule document
naming a Day-2 carve-out, I did not have it in scope and could not check it; flagging this as
UNVERIFIED rather than assuming nothing was missed.

**Verdict: no scope creep found (PASS); "Day-2" split not locatable in the brief itself
(UNVERIFIED against that specific framing, not a finding of omission).**

### 5. §6's six inherited hard constraints -- personally measured

1. **HTTP-carrying types must take `BackendSession`, never raw `URLSession`.** Read
   `rc-backend/test/session-guard.test.mjs` in full: it walks all of `ios/Sources/` line-by-line,
   skips comment lines, flags any `URLSession` spelling outside `Core/BackendSession.swift`
   (the sole ALLOWED entry, with a written reason), and has its own anchor test proving the
   allowed file is actually still scanned (not silently renamed out of range). Read
   `SessionsClient.swift`: takes `BackendSession`, not `URLSession`, at its call boundary.
   Confirmed GREEN in my own full `run-controls.sh` run (below), including the control's own
   plant-and-revert self-check reporting the planted probe file was cleanly removed.
2. **No default server host in Swift source/placeholder/fixture/comment.**
   `grep -rn 'https\?://' ios/Sources` (run by me this session) returns exactly 2 hits, both
   harmless UI strings (an error-message hint and a `TextField` prompt placeholder), no real or
   `.invalid`-adjacent host baked in as a default.
3. **No key in logs.** `grep -rn 'print(' ios/Sources` (run by me this session) returns exactly
   4 hits: two `"root flow:..."` diagnostic lines (state name only), one Sprint-1
   `"healthz ok:...pid:..."` line, and one comment referencing the Sprint-1 line. No key/bearer
   value in any of them.
4. **No line-number references outside `.harness/progress.md`.** Read
   `rc-backend/test/no-linerefs.test.mjs` in full: scans both `rc-backend/` and `ios/` trees
   (two independent floors so one tree silently going empty can't hide under the other's count),
   rejects any `name.ext:N` pattern, rejects any backtick-quoted filename that doesn't resolve,
   and carries three dedicated negative controls, including one added specifically because a
   Swift-side lineref once slipped through undetected. Confirmed GREEN in my own run.
5. **No GUI window; no real-device build this sprint.** Grepped every script under `ios/tools/`
   for `open -a Simulator` -- zero hits (two hits are comments *documenting* that it's never
   used). `build.sh --sim` targets `-sdk iphonesimulator` only; the repo's device-build path
   (`-sdk iphoneos`) is a separate, unexercised mode this sprint, consistent with §6-5. I did not
   open any GUI window myself either.
6. **Local commit only, no push.** Confirmed via `git status`/`git log` -- no push evidence; I
   did not push or commit anything myself.

## `run-controls.sh` -- methodology note (self-caught, worth flagging)

Before running anything, I checked for concurrent `run-controls`/`mutation-*` processes with
name-only `pgrep -l <name>` queries (never `pgrep -lf`, which would dump argv/env) -- none found,
both before my first attempt and again before the successful re-run below.

My **first** attempt was launched in the background and, when checked, had produced only 21 of
the 31 registered `LOCAL_CTLS` entries and **no final `RUN-CONTROLS: green=... red=... 未測定=...`
summary line** -- critically, it never reached `mutation-freeze-controls.sh` or
`copied-tree-controls.sh`, the two scripts central to Generator's Finding 5 self-correction. This
was an incomplete/truncated run (most likely killed by session-level teardown, not a code
defect), not a valid measurement, and I did not report its partial 21-green tally as a result.

I re-verified no process was still running (`pgrep -l run-controls.sh` -> no match) and re-ran
the full script to completion in the foreground with a long timeout. That run finished cleanly
with a proper summary line:

```
RUN-CONTROLS: green=34 red=0 未測定=0  (対象 34本、edith専用2本は除外)
```

All 34 local controls green, 0 red, 0 unmeasured -- **exactly matching** Generator's re-run claim
in the corrected Finding 5 ("green=34 red=0 未測定=0"). This is an independent reproduction, not
a re-reading of their log.

## `build.sh --sim` -- independently re-run

```
Test Suite 'All tests' passed ... Executed 97 tests, with 0 failures (0 unexpected)   (unit bundle)
Test Suite 'All tests' passed ... Executed 3 tests, with 0 failures (0 unexpected)    (UI bundle)
** TEST SUCCEEDED **
```

97 + 3 = 100 tests total, 0 failures, exit 0 -- matches Generator's claimed "100 tests, 0
failures" (55 Sprint-1 baseline + this sprint's additions) exactly, confirmed with the full log
grepped myself, not the tool's truncated tail.

`cd rc-backend && npm test` (run directly, not via the wrapper): 654/654 pass, 0 fail --
independently confirmed twice (once before, once implicitly re-covered by the full
`run-controls.sh` pass, which exercises the same suite via several of its controls).

## §7 Definition of Done -- per-item verdict

- `./ios/tools/build.sh --sim` rc=0, 0 failures, test count above 55 -> **PASS**
  (evidence: 100/100, exit 0, run by me).
- `run-controls.sh` all green including the two new controls -> **PASS**
  (evidence: `green=34 red=0 未測定=0`, run by me to completion after discarding an incomplete
  first attempt -- see methodology note above).
- 3 PNGs present under `.harness/evidence-2026-08-05/` -> **PASS**
  (evidence: present, valid, distinct, and visually confirmed to depict the claimed states --
  see item 2 above).
- XCUITest confirms banner strings via a11y identifier -> **PASS**
  (evidence: read `RemoteMiniUITests.swift` in full -- all three tests assert both the a11y
  identifier AND the literal banner text, e.g. `app.staticTexts["pane-scan-timeout"]`, not just
  "some element with this ID exists").
- `progress.md` documents decisions/exclusions/spec gaps -> **PASS** (read in full, read-only;
  I did not verify every individual claim inside it beyond what's independently re-checked above).
- Unstarted/carry-over items named, not "everything done" -> **PASS** (progress.md names specific
  carry-over items; see my own carry-over list below, compiled independently).

## Scoring (standard harness axes)

| Criterion | Threshold | Score | Basis |
|---|---|---|---|
| Functional completeness | >=4/5 | **5/5** | All 6 §1-a build items present in the actual commit diff; all 4 §4/§4-a phases implemented and mutation-confirmed; C-group ports read line-by-line against `view.mjs` and faithful; `live` correctly left undecoded per §1-b (a stated decision, not an omission). |
| Operational stability | >=4/5 | **5/5** | 100/100 iOS tests green (self-run); 654/654 backend tests green (self-run); 34/34 `run-controls.sh` local controls green (self-run to completion); three targeted mutations all correctly killed and cleanly reverted; git tree confirmed clean afterward. |
| UI/UX quality | >=3/5 | **4/5** | Screenshots show a coherent, color-differentiated row list, clear fault banner, clear empty state, consistent with the brief's design intent; not deeply polished (no animation/transition review possible headless) but that isn't this sprint's ask. |
| Error handling | >=3/5 | **5/5** | The failure-counter state machine's every branch (cancel-not-counted, paneFault-resets, unauthorized-exits, threshold=3-as-named-constant) is both implemented correctly and independently confirmed to fail loudly under mutation -- this is the sprint's highest-risk area and it held. |
| No regressions | =5/5 (mandatory) | **5/5** | Clean rebuild after all mutations reverted returns to 100/100 + 654/654 + 34/34 green; `git status --short -uall` shows only the pre-existing `.harness/progress.md` diff, nothing else touched. |

**All criteria meet or exceed threshold. Verdict: PASS.**

(No production-effect axes apply -- this sprint has no auto-send/launchd/mass-op/external-API
surface; it is local iOS app development.)

## What I read but did not independently re-derive

- The narrative prose inside `progress.md` (Findings 1-5, the Codex-delegation retrospective,
  the design-decision rationale) was read in full but treated as a claim, not a fact, except
  where independently re-checked above (Finding 5's re-run numbers, the test suite counts, the
  mutation lethality, the constraint scans).
- `SessionsClientTests.swift` / `SessionsModelsTests.swift` were read in full in an earlier part
  of this same evaluation session and judged thorough (dedicated negative controls for decode
  failure, `live`-ignored-regardless-of-shape, cancellation-vs-unreachable non-collapse) but were
  not separately mutation-tested this round given the fixed budget -- the three ListViewModel
  mutations were judged the highest-value use of that budget per the team-lead's stated priority.
- Device-only DoD items: none apply/were claimed this sprint (§6-5 explicitly excludes a
  real-device build); nothing here was marked UNVERIFIED-and-uncounted for that reason because
  nothing device-dependent was claimed.

## Carry-over to next sprint (named, not implied)

- The "Day-2 scope split" the team-lead asked me to check against does not appear inside
  `sprint-2-brief.md` itself -- if it lives in a separate schedule doc, that doc should be
  checked against this sprint's actual delivery before Sprint 3 planning locks in.
- `SessionsClientTests.swift`/`SessionsModelsTests.swift` have not been mutation-tested this
  round (reviewed only) -- worth a budgeted pass in a future sprint if a Sprint-3+ change touches
  the decode path, since Sprint 1's own precedent (`HealthzClient`/`SessionsAuthProbe`'s
  injectable-`URLSession` gap) shows this class of file can look green while carrying an
  un-mutation-tested structural gap.
- `live` union decoding remains deliberately undone (§1-b) -- Sprint 4 will need the real 3-way
  union shape from a live server response before writing the enum, not before.
- The incomplete-first-run behavior of `run-controls.sh` under a backgrounded, long-lived Bash
  invocation (21/31 controls before silent stop, no exit-summary line) is worth a harness-side
  note for future evaluators: prefer a foreground run with a generous timeout for this specific
  script over background+poll, since a truncated background run can look superficially like a
  valid partial-green result if the missing final summary line isn't checked for explicitly.
