# Sprint 3 Evaluation — Conversation (history) 画面

- Mode: 3 (Full) — Planner -> Generator -> Evaluator per sprint
- Loop iteration: 1
- Brief (authoritative, overrides spec prose): `.harness/sprint-3-brief.md`
- Progress claim under review: `.harness/progress.md` (Sprint 3 section, `<!-- session:
  2026-08-05 11:31 -->` through EOF, ~lines 567-905) — treated as an unverified claim throughout,
  not a fact, except where independently re-checked below.
- Commit evaluated (implementation): `d4f6584` ("Sprint 3: Conversation (history) screen --
  bubbles, load-earlier pagination, List navigation", 18 files, +1880/-12)
- Follow-up commit (tooling only, confirmed **not** touching `ios/`): `7170069` (team-lead) --
  builds `rc-backend/tools/port-coverage.py`, fixes a self-referential doc-comment bug in it and a
  false-red pattern in `no-linerefs.test.mjs`, switches several controls to a 3-valued
  OK/BROKEN/UNVERIFIABLE scheme. `git show --stat 7170069` confirms it touches exactly
  `.harness/sprint-3-brief.md`, `DESIGN.md`, `WORKLOG.md`, `rc-backend/test/no-linerefs.test.mjs`,
  `rc-backend/test/port-coverage-controls.sh` (new), `rc-backend/tools/port-coverage.py` (new),
  `rc-backend/tools/run-controls.sh` -- nothing under `ios/`.
- Evaluated by: Evaluator agent, 2026-08-05.
- Environment constraints observed: no GUI ever opened (no `open -a Simulator`, no Xcode.app);
  every build/test via `ios/tools/build.sh --sim`, headless, run by me directly, full log grepped
  myself (not the tool's truncated tail); no browser opened; `~/.ssh/` never read; `.harness/progress.md`
  was not modified by me; nothing under `ios/Sources/**` or `ios/Tests/**` left modified by me (see
  mutation-testing section -- both planted mutations were reverted and diff-confirmed clean).
- Pre-existing, unrelated uncommitted changes observed in the working tree at evaluation time
  (`.harness/spec-native-shell-2026-08-05.md`, `WORKLOG.md`, `rc-backend/test/no-linerefs.test.mjs`)
  were not authored by me and are outside `d4f6584`/`7170069` -- most likely a concurrent session's
  WIP (consistent with `mutation-freeze-controls.sh` reporting "別の走行が動いている" below). Not
  evaluated; flagged only so their presence in any later `git status` isn't misread as mine.

## Team-lead's 3 directed-suspicion items

### (a) C-group port denominator -- does every JS case show up 1:1 in Swift

Ran the tool myself: `python3 rc-backend/tools/port-coverage.py`.

```
■ mergeHistory: JS 呼び出し 8 件 / 相異なる第1引数 4 件(リテラル 0 / 照合できない 4)
   照合できるリテラルが 0 件 -- この関数はこの道具では測れない
■ nextHistoryLimit: JS 呼び出し 5 件 / 相異なる第1引数 5 件(リテラル 5 / 照合できない 0)
   受理した差し替え: nextHistoryLimit(480) -- Swift は同じ上限の節を 450 で踏んでいる
=== 集計 ===
   赤(移っていないリテラル入力 + 死んだ受理): 0
   照合できなかった入力: 20 件 / 測れなかった関数: 0
   受理した差し替え: 1 / 死んでいる受理: 0
```

This **confirms the tool cannot verify `mergeHistory`'s port coverage at all** (0 matchable
literal inputs -- `mergeHistory`'s test inputs are arrays/objects, not scalars the tool's literal
matcher can key on). Exit 0 here proves only "nothing it *can* check is red," not "mergeHistory is
fully ported" -- exactly the blind spot team-lead's brief flagged. My own manual cross-read was
therefore load-bearing, not redundant:

- Read `rc-backend/test/view.test.mjs`'s `mergeHistory` block and
  `ios/Tests/Core/MergeHistoryTests.swift` (91 lines) side by side. All 6 JS cases present, each as
  its own named Swift `func`, including case 6 (`testKnownLimitationSameUtteranceTwiceOverStrips`
  -- names the known over-stripping limitation rather than hiding it), plus a 7th Swift-only test
  for the `display`-must-not-affect-equality requirement (DoD row 12, not a JS case since JS's
  compared shape never carries `display` to begin with).
- Read `rc-backend/test/view.test.mjs`'s `nextHistoryLimit` block and
  `ios/Tests/Core/NextHistoryLimitTests.swift` (49 lines) side by side. All 5 JS assertions
  present, plus a 6th Swift-only `nil`-fallback test.
- **One real, non-verbatim deviation found**: JS case 4 uses input `480`;
  `testFourFiftyStepsToFiveHundredNotFiveFifty` uses `450`. This is exactly the "受理した差し替え"
  (accepted substitution) the tool's own output names -- team-lead's tooling had already caught and
  reasoned about it (both inputs land on the same cap-triggering property, `min(500, x+100)` where
  `x+100 > 500`). I independently corroborate the substitution is functionally harmless, but it is
  still a literal deviation from "port verbatim," worth a Sprint 4 line-item to close (change the
  literal to `480`) rather than re-justify indefinitely.
  - _(後から足した注記 2026-08-05 — 上の評価文は書かれた時点で正しい。この指摘は
    Sprint 4 (`e86d156`) で実際に閉じられ、検査は `testFourEightyStepsToFiveHundredNotFiveEighty`
    に改名されて `nextHistoryLimit(480) == 500` を見ている。従って**上で名指しされた
    `testFourFiftyStepsToFiveHundredNotFiveFifty` は現在の木に実在しない** —— 記録として
    正しく、現在の木の索引としては死んでいる。探しに行かない為の注記であって、
    評価文の訂正ではない。)_

**Verdict: PASS with one flagged, already-accepted, non-blocking deviation.** The
`mergeHistory`-side denominator was verified entirely by hand; the tooling's green result for it
is not evidence of anything and should not be read as such by a future evaluator.

### (b) Tests present vs. tests effective

Read all 5 new test files in full
(`MergeHistoryTests`/`NextHistoryLimitTests`/`HistoryModelsTests`/`HistoryClientTests`/
`ConversationViewModelTests`) -- found no vacuous or trivially-true assertions; every test uses a
specific, realistic fixture and asserts a specific outcome; multiple explicit negative controls
exist (co-occurring-conditions test, unrecognized-role-doesn't-crash-whole-decode test, 4-way
error-taxonomy pairwise negative controls, double-press concurrency race test).

Rather than trust that reading alone, I planted 2 mutations myself against the 2 pieces of logic
team-lead's brief and the 訂正6-1 note flag as highest-risk, rebuilt+ran the full suite via
`ios/tools/build.sh --sim` (headless) after each, then reverted and reran clean:

| Mutation | File | Expected defect | Result |
|---|---|---|---|
| Swapped `resolveLoadEarlierState`'s priority so `!advanced` is checked **before** the ceiling check (stalled-retry would win over ceiling) | `ConversationViewModel.swift` | ceiling no longer permanent when it co-occurs with a stalled attempt | `テスト 150件 実行 / 失敗 1件`. Exactly 1 red: `testCeilingTakesPriorityOverStalledRetryWhenBothConditionsCoOccurNegativeControl`, message `XCTAssertEqual failed: ("stalledRetry") is not equal to ("atCeiling") - ceiling must win even though the oldest entry also failed to advance`. Nothing else moved. |
| Reverted the 訂正6-1 fix: `let base = (current == 0 ? nil : current) ?? 50` -> `let base = current ?? 50` | `MergeHistory.swift` | `nextHistoryLimit(0)` returns 100 instead of 150 | `テスト 150件 実行 / 失敗 1件`. Exactly 1 red: `NextHistoryLimitTests.testZeroStepsToOneFiftyNotOneHundred`. Nothing else moved. |

Both files diffed byte-identical against their pre-mutation backups after revert
(`diff /tmp/*.bak ...` -> empty, printed `REVERT CLEAN`/`REVERT2 CLEAN`), and a clean rebuild
afterward is back to `テスト 150件 実行 / 失敗 0件`. `git status --short -uall` shows no trace of
either mutation (only the 3 pre-existing, not-mine files noted above).

I did not independently rerun progress.md's own claimed 5-mutation table (B1/B2/A1/A2/C1) given
the fixed evaluation budget -- the 2 mutations above were judged the highest-value use of that
budget (they target exactly the two things this brief and its 訂正 note call out as most
drift-prone: the priority table and the `||`-vs-`??` fallback). progress.md's table is read but
not independently re-derived beyond these 2.

**Verdict: PASS, self-verified by mutation on the two highest-risk spots**, not merely "test files
exist."

### (c) Ceiling vs. stalled-retry -- separate counters, or one mechanism

Read `ConversationViewModel.swift` in full. `resolveLoadEarlierState(truncated:currentLimit:advanced:)`
is a single pure static function, not two independently-mutated counters:

```swift
private static func resolveLoadEarlierState(truncated: Bool, currentLimit: Int, advanced: Bool) -> LoadEarlierState {
    guard truncated else { return .hidden }
    if MergeHistory.nextHistoryLimit(currentLimit) == currentLimit { return .atCeiling }
    return advanced ? .available : .stalledRetry
}
```

Priority is structural (an `if`/early-return, not a bitmask or two flags that could go out of
sync), matches the brief's table order exactly (ceiling > stalled > available > hidden), and is
called from both `applyInitial` (`advanced: true`, vacuous on first load) and `applyLoadEarlier`
(`advanced` computed via `!sameOldest(oldestBefore, history.first)`, itself reusing
`MergeHistory.sameRoleAndText` rather than inventing a second equality notion the brief explicitly
warns against). Mutation (b)'s first row above directly tests this exact concern -- swapping the
priority broke exactly the test purpose-built to co-occur both conditions
(`testCeilingTakesPriorityOverStalledRetryWhenBothConditionsCoOccurNegativeControl`, which seeds
`initialLimit: 450` to force both `atCeiling` and a non-advancing attempt simultaneously) and
nothing else.

**Verdict: concern unfounded. PASS, mutation-confirmed** -- one coherent priority-ordered function,
not two counters that could silently clobber each other.

## DESIGN.md §2.18-10 lens (shrinking-protective-surface pattern) -- swept, no live unflagged instance

Grepped `DESIGN.md` for the pattern (a check's target/measurement surface silently shrinking at
exactly the moment a defect occurs, so the check stays green instead of turning red) and used it
as a lens across this sprint's own new code and tooling. The closest matches are all **already
self-disclosed**, not silent:

- `port-coverage.py` reports "この関数はこの道具では測れない" for `mergeHistory` rather than
  reporting false-green -- this is the anti-pattern's fix, not an instance of it.
- `dod-sprint-3.sh` rows 2/14 explicitly hand off to a human/Evaluator rather than claiming
  machine coverage they don't have.
- `mutation-verdict-controls.sh`/`mutation-freeze-controls.sh` (see `run-controls.sh` below) report
  as UNMEA, not GREEN, when they can't produce a verdict -- consistent with `7170069`'s stated
  3-valued OK/BROKEN/UNVERIFIABLE fix.
- `HistoryFixture.swift`'s DEBUG-only gate (the one place a shrinking surface really would matter
  -- a fixture leaking into Release) was independently confirmed clean, not just assumed: see
  `ui-fixture-absence-control.sh` below.

No new, unflagged instance of the pattern found inside `d4f6584`'s own diff.

## `run-controls.sh` -- run myself in the foreground, current tally

First attempt exceeded the 120s foreground timeout and was moved to a background task by the
harness; I waited for it to finish rather than reading a partial/truncated run, then read its
completed output in full:

```
RUN-CONTROLS: green=35 red=0 未測定=2  (対象 37本、edith専用2本は除外)
  未測定(緑ではない): mutation-verdict-controls.sh mutation-freeze-controls.sh ← 条件が揃ってから回し直す事
```

This **supersedes** progress.md's own stale mid-session figure (`green=32 red=4 未測定=1`,
recorded before `7170069` landed) and confirms team-lead's `7170069` fix actually took effect: the
port-coverage.py-caused false-reds are gone (**0 red**, not 4). `ui-fixture-behavior-control.sh`,
which progress.md's Finding 5 flagged as "not yet isolated-confirmed," is now GREEN in this run
("Release + RC_UI_FIXTURE=list-empty は通常経路のみを通った"). The 2 remaining UNMEA items are
self-explained by the script's own output as non-deterministic under concurrent test lanes
(`mutation-freeze-controls.sh`: "別の走行が動いている" -- another run was active, consistent with
the pre-existing unrelated working-tree diffs noted above) and as "the record couldn't produce a
verdict" for `mutation-verdict-controls.sh` (`pass=10 fail=3`, but explicitly labeled not-green
rather than silently passed) -- neither is a Sprint 3 regression, and per the 3-valued scheme
that's the correct, honest label for them, not a defect to chase down in this evaluation.

`dod-sprint-3-controls.sh` (a meta-control that tests the DoD script's own behavior, 12 rows,
distinct from running `dod-sprint-3.sh` directly) reports `緑=12 赤=0 未測定=0` -- fully green,
not to be confused with `dod-sprint-3.sh`'s own direct-run tally below.

## `dod-sprint-3.sh` -- run myself, default (non-FULL) mode

```
緑=11 赤=0 未測定=4 (全15行)
```

Matches team-lead's own pre-measured result exactly. Unmeasured rows: 1 and 13 (need
`DOD_FULL=1`, covered instead by my own direct `build.sh --sim` and `run-controls.sh` runs below),
2 (screenshot existence-only by design, content verified by me separately below), 14 (explicitly
Evaluator-only prose per the script's own comment, covered by the DoD verdict table below).

## `ios/tools/build.sh --sim` -- independently re-run (baseline, before any mutation)

```
テスト 150件 実行 / 失敗 0件   (17.8s)
```

Matches progress.md's claim, now backed by my own direct execution rather than trust. Re-run again
clean after both mutations were reverted (see mutation table above) -- same `150件 / 失敗 0件`.

## `rc-backend && npm test` -- independently re-run

```
# tests 656
# pass 656
# fail 0
```

**Reconciles the 653/654-vs-656 discrepancy**: progress.md's Sprint 3 section (written before
`7170069`) reports `653/654`, one failure attributed to an untracked `port-coverage.py`.
`7170069`'s commit message claims `656/656`. My own run now shows **656/656, 0 fail** -- consistent
with `7170069` both fixing the root cause and adding new tests of its own
(`port-coverage-controls.sh`'s controls), which accounts for the +2 test count on top of the fix.
progress.md's figure was accurate for its own point in time; it is simply superseded.

## Screenshot content verification (DoD row 2) -- viewed directly, cross-checked against fixture source

Viewed `.harness/evidence-2026-08-05/conversation-3roles.png` directly (image read, not OCR/pixel
diff -- no such tool is in scope). Then read the fixture that produces it,
`ios/Sources/Core/HistoryFixture.swift`:

```swift
case threeRoles = "conversation-3roles"
...
HistoryEntry(role: .user, text: "予約の状況を確認して", display: .init(who: "Tom")),
HistoryEntry(role: .assistant, text: "確認します。少々お待ちください。", display: .init(who: "Claude")),
HistoryEntry(role: .tool, text: "⚙ Bash", display: .init(who: "道具")),
HistoryEntry(role: .assistant, text: "予約が2件見つかりました。詳細を送ります。", display: .init(who: "Claude")),
// truncated: true so the DoD screenshot also shows the "以前を読む" button
```

Every one of these 4 entries' `display.who` + `text` strings is **verbatim visible in the
screenshot**: a blue right-aligned "Tom" bubble reading "予約の状況を確認して"; two gray
left-aligned "Claude" full bubbles reading "確認します。少々お待ちください。" and "予約が2件見つかりました。詳細を送ります。";
one thin one-line "道具　⚙️ Bash" row, visually distinct in shape from the two full bubbles above it
(no background/bubble chrome) -- confirming `EntryBubble` really does render `.tool` differently
from `.assistant`, not just in a code comment. "以前を読む" is visible at the bottom, confirming the
`truncated: true` fixture setting reaches the footer. This is a byte-level cross-check against the
fixture's own source literals, not an eyeballed "looks plausible."

**Verdict: DoD row 2 genuinely satisfied** -- all 3 bubble kinds + the load-earlier control are
simultaneously visible and each one traces back to a specific fixture line.

## §6/DoD -- per-item verdict

- Full unit suite green, count > baseline -> **PASS** (150/150, run by me, twice, including after
  reverting 2 self-planted mutations).
- `run-controls.sh` all local controls green -> **PASS** (green=35 red=0 未測定=2, run by me to
  completion; the 2 unmeasured are self-disclosed non-green, not silent passes, and are
  concurrency-related, not Sprint 3 regressions -- see above).
- Screenshot present and correct content -> **PASS** (existence + content both verified by me; see
  above).
- C-group port complete and verbatim -> **CONDITIONAL PASS** (all 11 JS cases present and
  correctly asserted; 1 of 11 uses a non-verbatim-but-accepted-and-functionally-equivalent input
  substitution, already caught and reasoned about by team-lead's own tooling, not newly found by
  me -- see item (a) above).
- `nextHistoryLimit`'s 訂正6-1 fallback correct, no stale `?? 50`-only comment remaining -> **PASS**
  (mutation-confirmed above; `dod-sprint-3.sh` row 15 independently green in my own run).
- Load-earlier state machine matches brief §3-b-2's table, ceiling permanent -> **PASS**
  (mutation-confirmed above, negative control co-occurring both conditions holds).
- `.notFound` (404) suppresses retry button, distinct from `.unreachable` -> **PASS** (read
  `ConversationView.swift` in full: `.notFound` has its own branch, no shared `failureView` retry
  button; `phase != .loaded` on `.notFound` structurally hides `loadEarlierFooter` too since it
  only renders inside the `.loaded` branch).
- §5's 6 inherited hard constraints -> **PASS** (BackendSession-only HTTP confirmed in
  `HistoryClient.swift`'s call boundary; no hardcoded host found; Keychain-only keys inherited from
  Sprint 2's unmodified `BackendSession`; `no-linerefs-controls.sh` GREEN in my own `run-controls.sh`
  run; `progress.md` ownership respected -- I did not write to it; no GUI ever opened by me or by
  any script under `ios/tools/`).
- progress.md documents decisions/exclusions/findings -> **PASS** (read in full; Findings 1-5 read
  as claims, cross-checked above where independently re-derivable: Finding 3's `nextHistoryLimit(0)`
  bug matches my own mutation-2 result exactly; Finding 4's port-coverage.py attribution matches
  `7170069`'s own commit message; Finding 5's `ui-fixture-behavior-control.sh` "not yet
  isolated-confirmed" flag is now resolved GREEN in my current `run-controls.sh` run, consistent
  with time having passed since progress.md was written).

## Scoring (standard harness axes)

| Criterion | Threshold | Score | Basis |
|---|---|---|---|
| Functional completeness | >=4/5 | **5/5** | All Sprint 3 build items present in `d4f6584`'s actual diff (HistoryClient/Fixture/Models/MergeHistory, ConversationView/ViewModel, 5 test files, List/RootView/SessionsClient wiring); C-group ports verified complete against JS source by hand (port-coverage.py cannot verify `mergeHistory` at all -- 0 matchable literals); 1 non-blocking, already-flagged literal substitution. |
| Operational stability | >=4/5 | **5/5** | 150/150 iOS unit tests green (self-run, twice); 656/656 backend tests green (self-run); `run-controls.sh` 35/37 green + 2 honestly-disclosed unmeasured, 0 red (self-run to completion, superseding progress.md's stale mid-session 4-red figure); 2 self-planted mutations both killed cleanly, both reverted with diff-confirmed clean trees. |
| UI/UX quality | >=3/5 | **4/5** | Screenshot content verified against fixture source literals, byte-for-byte: 3 visually distinct bubble kinds + load-earlier control genuinely co-present; ceiling vs. stalled-retry footer text confirmed as two different literal strings, not a shared placeholder. Not deeply polished (no animation/transition review possible headless) -- same ceiling as Sprint 2, not this sprint's ask. |
| Error handling | >=3/5 | **5/5** | 4-way taxonomy (unreachable/malformedBody/notFound/cancelled) each distinctly handled and individually tested with negative controls; `.notFound` correctly has no retry path; priority-ordering between ceiling and stalled-retry is mutation-confirmed correct, directly resolving team-lead's item (c) concern. |
| No regressions | =5/5 (mandatory) | **5/5** | Clean rebuild after both mutations reverted returns to 150/150 + 656/656 + run-controls green=35/red=0; `git status --short -uall` shows no trace of either mutation, only pre-existing files not authored by me. |

**All criteria meet or exceed threshold. Verdict: PASS.**

(No production-effect axes apply -- phone-side screen feature only, no auto-send/launchd/mass-op/
external-API surface.)

## What I read but did not independently re-derive

- progress.md's own 5-row mutation table (B1/B2/A1/A2/C1) -- read as a claim; not personally
  rerun given budget, since my own 2 mutations targeted the same highest-risk logic from a
  different, independently-chosen angle (priority order + the 訂正6-1 fallback specifically) rather
  than re-running theirs.
- `HistoryClientTests.swift`/`HistoryModelsTests.swift` were read in full and judged thorough
  (status-code branching, decode negative controls, cancellation handling) but not separately
  mutation-tested this round -- reviewed only, consistent with the fixed evaluation budget.
- `ListView.swift`'s `baseURL`/`apiKey`/`onUnauthorized` constructor-param addition was read
  (first ~60 lines) and matches progress.md's stated rationale of preserving Sprint 2's
  `ListViewModel` encapsulation, but was not exhaustively diffed line-by-line against its Sprint 2
  version beyond `git show --stat d4f6584`'s file list.

## Carry-over to next sprint (named, not implied)

- `nextHistoryLimit`'s ported test case still uses `450` where the JS source uses `480`
  (functionally equivalent, already accepted, but genuinely non-verbatim) -- a one-line fix
  (`450` -> `480`) would close this cleanly rather than leaving a permanently-accepted deviation on
  the books.
- `port-coverage.py` structurally cannot verify `mergeHistory`'s port coverage (0 matchable literal
  inputs, confirmed by its own output) -- any future change to `mergeHistory` or its test suite
  will need the same manual JS-vs-Swift cross-read this evaluation did, since the tool cannot help
  there and its green exit code says nothing about that function.
- `mutation-verdict-controls.sh`/`mutation-freeze-controls.sh` were unmeasured (not red) in this
  run, both self-attributed to a concurrently-running session rather than a Sprint 3 defect -- worth
  a rerun once no other session is active, but not a Sprint 3 blocker.
- The pre-existing, not-mine uncommitted diffs to `.harness/spec-native-shell-2026-08-05.md`,
  `WORKLOG.md`, and `rc-backend/test/no-linerefs.test.mjs` observed in the working tree at
  evaluation time were outside this evaluation's scope (not part of `d4f6584` or `7170069`) and
  were left untouched; whoever owns that WIP should reconcile it before it's mistaken for Sprint 3
  scope by a future reader of `git status`.
