# Sprint 1 Evaluation — iOS Native Shell, Day 1 (Key-entry)

- Mode: 3 (Full) — Planner -> Generator -> Evaluator per sprint
- Loop iteration: 1
- Spec: `.harness/spec-native-shell-2026-08-05.md` §6 Day-1 row (referenced: §0-4, §1, §2-1, §3-1..§3-9, §5-1)
- Progress claim under review: `.harness/progress.md`
- Commit evaluated: `b937428`
- Evaluated by: Evaluator agent, 2026-08-05
- Environment constraints observed: no GUI ever opened (no `open -a Simulator`, no Xcode.app), all builds via `xcodebuild -sdk iphonesimulator ... test` (headless, either through `ios/tools/build.sh --sim` or invoked directly with full log capture instead of build.sh's `tail -3`), no physical iPhone available, no browser/Playwright/screenshots used, no writes outside the repo, no writes under `~/.claude/`.

## Team-lead's 7 pre-verified claims — disprove attempt

I did not re-derive these from scratch; I specifically tried to break each one.

1. 55 tests / 9 suites green, exit 0 — re-ran clean (`rm -rf build && xcodebuild ... test`), captured full log (not `build.sh`'s truncated `tail -3`, which can hide compiler-vs-test-failure ambiguity — see mutation methodology below). Result: `Test Suite 'RemoteMiniTests.xctest' passed ... Executed 55 tests, with 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`. Confirmed, not disproved.
2. No embedded real hosts / no real secrets — `grep -rn 'https\?://' ios/Sources ios/Tests` returns exactly 2 hits, both non-host placeholder/instructional strings (`KeyEntryView.swift`'s bare `"https://"` TextField placeholder, and a doc-comment). Confirmed.
3. Only one `print(` call, safe — `grep -rn 'print(' ios/Sources` returns exactly one hit, `KeyEntryViewModel.swift`'s `print("healthz ok:\(result.ok) pid:\(result.pid)")`. No key/credential in scope at that call site. Confirmed.
4. Keychain accessibility attribute — `KeychainCredentialStore.swift` uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on both the save-add and save-update code paths, no iCloud-sync attribute anywhere in the file. Confirmed.
5. Redirect-refusal wired to production path — `KeyEntryViewModel`'s default init parameters (`healthz: HealthzChecking = HealthzClient()`, `sessionsProbe: SessionsAuthChecking = SessionsAuthProbe()`) resolve through `HealthzClient.init(session: URLSession = BackendSession.shared.session)` / `SessionsAuthProbe`'s identical pattern, to `BackendSession.shared`, whose `init` constructs `URLSession(configuration:, delegate: RedirectRefusingDelegate(), delegateQueue: nil)`. Today's actual call graph is safe. **But** see the Finding below — this claim is true only for the current call site, not structurally guaranteed.
6. `ReadablePoll` matches `view.mjs`'s three `typeof` quirks — traced by hand against `rc-backend/src/view.mjs`'s `readablePoll`/`isPlainEvent`, then confirmed empirically by mutation (below): forcing `ReadablePoll.check` to short-circuit `true` turned exactly 9 of 16 `ReadablePollTests` cases red, the ones exercising the fail-closed branches. Confirmed.
7. `project.yml` signing change scoped to simulator only — read the file: `CODE_SIGN_IDENTITY[sdk=iphonesimulator*]`/`CODE_SIGNING_REQUIRED[sdk=iphonesimulator*]`/`CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]` are the only conditioned keys; base (all-SDK) keys are unchanged (`CODE_SIGN_IDENTITY: ""`, `CODE_SIGNING_REQUIRED: NO`, `CODE_SIGNING_ALLOWED: NO`). I additionally ran the actual on-device xcodebuild invocation (`-sdk iphoneos`, unsigned, `tools/build.sh`'s own `CODE_SIGN_IDENTITY=-`/`CODE_SIGNING_REQUIRED=NO`/`CODE_SIGNING_ALLOWED=NO` flags on the command line) myself and got `** BUILD SUCCEEDED **` — command-line build settings win over `project.yml`'s `[sdk=iphonesimulator*]`-scoped values because the latter don't apply to `-sdk iphoneos` in the first place, and the base values (also `NO`) match what `tools/build.sh` passes anyway. Confirmed, not disproved.

None of the 7 broke under scrutiny.

## Directed suspicion: injectable `URLSession` on `HealthzClient`/`SessionsAuthProbe`

Confirmed as a real, narrow, structural gap — Finding 1 below.

## Directed suspicion: "green tests" vs "tests that actually detect the defect" (mutation testing)

Methodology note: my first mutation attempt (deleting `ReadablePoll.check`'s guard-let via string replace) produced a **compile error**, and `build.sh --sim`'s internal `| tail -3` made that indistinguishable from a test failure in the truncated output. I fixed this by (a) using a compile-safe mutation shape (`if true { return X } // MUTATION: ...` inserted right after the signature, never touching variable scope below it), and (b) abandoning `build.sh`'s truncated output for these runs in favor of invoking `xcodebuild` directly with full log capture, grepping for `** TEST FAILED **`/`** TEST SUCCEEDED **` and per-test pass/fail lines. All three mutations below were reverted via `git checkout --` immediately after observing the result; `git status --short` is clean.

| Mutation | File | Result |
|---|---|---|
| `ReadablePoll.check` short-circuited to always return `true` | `ios/Sources/Core/ReadablePoll.swift` | `** TEST FAILED **`; exactly 9/16 `ReadablePollTests` cases (the fail-closed-branch cases) went red, 7 stayed green (the already-true cases) — consistent with what the mutation should do, not a wholesale suite collapse |
| N6 order reversed in `HealthzClient.check` (decode body before checking `http.statusCode == 200`) | `ios/Sources/Core/HealthzClient.swift` | `** TEST FAILED **`; `testNon200StatusIsRejectedWithoutAttemptingToDecodeTheBody` went red |
| `Backoff.ms`'s `capMs` clamp removed (`min(capMs, ...)` -> unclamped) | `ios/Sources/Core/Backoff.swift` | `** TEST FAILED **`; `testCapsAtFifteenSeconds` and `testCapNegativeControlWouldExceedTheLimit` went red |

This satisfies both the team-lead's explicit instruction and the harness Mode-0-closure "adversarial, not just a green regression suite" requirement: these are genuine kill-mutant results, not a rerun of the same green suite.

I did not additionally mutation-test `PollCursor`, `KeychainCredentialStore`, or `SessionsAuthProbe` — code review of `PollCursorTests.swift`'s `testOpacityRoundTripsAnUnrecognizedFutureFormatUnchanged` and `BackoffTests.swift`'s several `*NegativeControl` cases shows they already carry a **self-verifying negative control** (the test itself asserts the wrong-but-tempting implementation would produce a different, and in the opacity case actively wrong, result before asserting the real implementation differs from it) — this is strictly stronger evidence than an external mutation for those two files, so I judged the marginal value of also mutating them to be low given the fixed evaluation budget. `SessionsAuthProbeTests` was reviewed but not mutated; flagged as UNVERIFIED below rather than claimed as tested.

## Finding 1 (Minor, carry over): injectable `URLSession` gives no structural guarantee of N5 redirect-refusal

- Location: `ios/Sources/Core/HealthzClient.swift`, `init(session: URLSession = BackendSession.shared.session)`; identical pattern in `ios/Sources/Core/SessionsAuthProbe.swift`.
- Both types accept *any* `URLSession` via the initializer; the safe default is a default, not a constraint. Nothing — not the type system, not a runtime assertion — stops a future call site from passing e.g. `URLSession(configuration: .default)` directly, silently dropping N5 (redirect-refusal) protection with no compiler warning and no test failure, because the test suite for these two types never exercises the safe path either way.
- Corroborating evidence this gap is not just theoretical: `ios/Tests/Support/MockURLProtocol.swift`'s `makeSession()` explicitly builds a session with **no delegate at all**, and carries the comment "Redirect behavior is tested separately in RedirectRefusalTests by exercising BackendSession's delegate directly, not through this stub." This means `HealthzClientTests`/`SessionsAuthProbeTests` never exercise N5 end-to-end through the actual production client classes — only `RedirectRefusalTests` proves the delegate itself refuses redirects (by calling the delegate method directly) and separately proves `BackendSession().session.delegate is RedirectRefusingDelegate` (by construction, not by observing an actual redirect through `HealthzClient`/`SessionsAuthProbe`).
- Today's actual production wiring is safe: `KeyEntryViewModel`'s default init args resolve through both types' defaults to `BackendSession.shared.session`. This is **not a current-sprint defect** — it is a forward-looking risk. Sprint 2+ (List/Conversation/poll network clients, per spec §3) will plausibly add more call sites following this same `init(session:)` pattern; if any one of them ever passes a session that bypasses `BackendSession`, N5 breaks silently with nothing in this test suite positioned to catch it.
- Suggested fix direction (not applied — Evaluator does not fix): either (a) drop the injectable-session parameter from the public/production initializer and add a separate `internal`/`@testable`-only test-injection point, or (b) add one integration-level test that stands up `HealthzClient()`/`SessionsAuthProbe()` with their real default sessions against a local stub server (or a delegate-aware `URLProtocol` stub) and asserts a 3xx is actually refused end-to-end, closing the gap the `MockURLProtocol` comment currently documents as an explicit non-goal.

## Finding 2 (informational, not a defect): two documented spec extrapolations

Both already disclosed in `progress.md`'s "Design decisions the spec didn't settle" section and both are reasonable, narrow, and consistent with adjacent spec language — noting them here only because Evaluator instructions require independent judgment, not acceptance of self-assessment:

- `SessionsAuthProbe.Outcome` groups non-200/non-401 responses (e.g. 5xx) under `.unreachable` rather than a spec-undefined third case. §5-1 only names two outcomes for this probe; grouping unknown-status under the "can't tell, treat as unreachable" bucket is the conservative (fail-closed toward "unreachable" rather than fail-open toward "authorized") reading. Judged reasonable, not scope creep.
- Client-side `https://` + non-empty-host pre-validation in `KeyEntryViewModel.normalizeBaseURL` before any network call. Not contradicted by spec; keeps a plainly malformed URL from ever reaching `HealthzClient`. Judged reasonable.

## Over-building / under-building check (Tom's fixed v1 scope: 一覧 / 履歴+ライブ / 打ち込む / 割り込む)

- Files under `ios/Sources/Screens/` are limited to `KeyEntry/` (`KeyEntryView.swift`, `KeyEntryViewModel.swift`) plus `RootView.swift`'s placeholder routing (`SignedInPlaceholderView`, not a real List screen). No List/Conversation screen code, no poll-loop code, no compose/send code, no interrupt code exists anywhere in `ios/Sources/`.
- This is correct for Day 1: none of the 4 v1 features are Day-1 deliverables per §6's table — Day 1 is Key-entry + the shared `Core/` primitives (`PollCursor`, `Backoff`, `ReadablePoll`, Keychain, `BackendSession`/N5, `HealthzClient`, `SessionsAuthProbe`) that the later 4 features will depend on.
- `BackendSession`/N5 redirect-refusal is not itself one of the 4 v1 features, but is shared plumbing exercised by this sprint's two HTTP clients and explicitly scoped in spec §3-1/§3-7 as applying to "全リクエスト共通" (all requests). Building it now, rather than duplicating ad hoc redirect handling per-screen later, is reasonable inclusion — not scope creep into Sprint 2+ feature territory.
- No evidence of under-building relative to the Day-1 row either: all three named unit-test categories (`PollCursor` opacity, `backoffMs` cap, `readablePoll` port-fidelity) exist and pass, plus the additional Key-entry-screen and Keychain/session/N5 test coverage the Day-1 row implies but doesn't itemize.
- Verdict: scope matches Day-1 exactly, no over-building into v2/Sprint-2+ territory, no gaps against the Day-1 row.

## Per-assertion verdicts (Day-1 DoD, spec §6 Day-1 row)

`PollCursor` opacity unit test green -> PASS (evidence: `cd ios && xcodebuild ... test 2>&1 | tee /tmp/full-clean-run.log` -> `Test Suite 'RemoteMiniTests.xctest' passed ... Executed 55 tests, with 0 failures`; `PollCursorTests.swift` contains `testOpacityRoundTripsAnUnrecognizedFutureFormatUnchanged` with a self-verifying negative control, code-reviewed directly)

`backoffMs` cap unit test green -> PASS (evidence: same clean run above, plus targeted mutation: removing `min(capMs, ...)` in `Backoff.ms` turned `testCapsAtFifteenSeconds`/`testCapNegativeControlWouldExceedTheLimit` red, confirming the green result is load-bearing, not vacuous)

`readablePoll` port matches `view.mjs` output, unit test green -> PASS (evidence: same clean run, plus targeted mutation: short-circuiting `ReadablePoll.check` to `true` turned exactly 9/16 `ReadablePollTests` red)

On-device `healthz ok:true pid:<n>` log grep via `devicectl device process launch --console` -> UNVERIFIED, not penalized (evidence: no physical iPhone available in this environment; explicitly pre-authorized as an expected exclusion by team-lead. `progress.md` itself lists this as "not attempted" rather than falsely claiming it — consistent, no misrepresentation found)

No secrets / no hardcoded real host in fixtures or source -> PASS (evidence: `grep -rn 'https\?://' ios/Sources ios/Tests` -> 2 hits, both non-host placeholder text; `grep -rn 'print(' ios/Sources` -> 1 hit, safe DoD diagnostic line only)

Keychain uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync -> PASS (evidence: direct read of `ios/Sources/Core/KeychainCredentialStore.swift`, attribute present on both save-add and save-update paths, no `kSecAttrSynchronizable` anywhere in the file)

N5 redirect refusal wired to production Key-entry network path -> PASS for current wiring / FAIL-adjacent structural gap for future call sites (evidence: traced `KeyEntryViewModel`'s default init args through `HealthzClient`/`SessionsAuthProbe` defaults to `BackendSession.shared`; separately confirmed via `ios/Tests/Support/MockURLProtocol.swift`'s `makeSession()` "no delegate" comment that `HealthzClientTests`/`SessionsAuthProbeTests` never exercise N5 end-to-end — see Finding 1)

`project.yml` simulator-only signing change does not affect on-device build path -> PASS (evidence: read `ios/project.yml`, all three signing keys conditioned on `[sdk=iphonesimulator*]`; independently ran `xcodebuild ... -sdk iphoneos ...` with `tools/build.sh`'s own signing flags myself -> `** BUILD SUCCEEDED **`)

§5-1 Key-entry error strings match spec verbatim -> PASS (evidence: direct string comparison, `KeyEntryViewModel.swift`'s `errorMessage` assignments against spec §5-1's table; `KeyEntryViewModelTests.swift` asserts the same strings via `FakeHealthzChecker`/`FakeSessionsAuthChecker`)

No scope creep beyond Day-1 (no List/Conversation/poll/compose/interrupt code) -> PASS (evidence: `ios/Sources/Screens/` contains only `KeyEntry/` + `RootView.swift`'s non-functional placeholder; no poll-loop, no compose, no interrupt code found by direct directory read)

`SessionsAuthProbeTests` mutation-verified to detect a genuine defect -> UNVERIFIED (evidence: code-reviewed only, not independently mutation-tested — see Methodology note above; test file structure and assertions are consistent with the other suites' pattern but I did not empirically confirm a kill)

## Axis scores

| Axis | Threshold | Score | Justification |
|---|---|---|---|
| Functional completeness | >=4/5 | 4/5 | All 3 named Day-1 unit-test categories present and mutation-confirmed live; Key-entry screen end-to-end logic matches spec §2-1/§5-1 exactly. Held to 4 not 5 because the on-device DoD item is unverified (structurally, not a fault of this sprint) and `SessionsAuthProbeTests`' kill-effectiveness is unverified rather than confirmed. |
| Operational stability | >=4/5 | 4/5 | Clean build, 55/55 tests green on a from-scratch run, `project.yml` edit independently confirmed not to leak into the device signing path. Held to 4 not 5 for Finding 1 (injectable-session gap) — a real, if narrow, structural stability risk for future sprints, not a current-sprint break. |
| UI/UX quality | >=3/5 | 3/5 | Minimal but complete Key-entry screen: placeholder text, secure field, disabled-while-checking submit, progress indicator, error footer, accessibility identifiers for future XCUITest. Meets the threshold; not scored higher since this sprint's UI surface is intentionally small (one screen) and there is no comparative basis yet for a stronger score. |
| Error handling | >=3/5 | 4/5 | Distinguishes "URL unreachable" vs "wrong key" per §2-1's stated purpose for `/healthz`, N6 status-before-body ordering is real and mutation-confirmed, Keychain save failure path (`KeychainError`) is modeled explicitly rather than silently swallowed. |
| No regressions | =5/5 mandatory | 5/5 | `BuildInfoTests.swift` (pre-existing scaffold test) unmodified and still passing in the clean 55/55 run; `git status --short` clean at both start and end of my session; no evidence any prior test was weakened or removed to make the suite pass. |

## Carry over to next sprint

1. Finding 1 (Minor): harden `HealthzClient`/`SessionsAuthProbe` against future call sites bypassing N5 via session injection, and/or add one integration test that exercises N5 through the real production client classes end-to-end rather than only through `RedirectRefusalTests`' direct-delegate-call approach.
2. On-device DoD verification (`devicectl device process launch --console`, grep for `healthz ok:true pid:<n>`) — still outstanding, requires Tom's physical iPhone; not this sprint's or this Evaluator's responsibility to close.
3. `SessionsAuthProbeTests`' mutation-kill effectiveness was reviewed but not empirically confirmed this sprint (budget-limited, not skipped for cause) — worth a quick confirming mutation early in Sprint 2 before more code is built on top of it.

## Verdict: PASS

All 5 standard axes meet or exceed threshold; no regressions; Finding 1 is real but scoped as Minor (does not block Day-1's own DoD, does not currently misbehave, has a clear low-cost carry-over path) and does not on its own justify CONDITIONAL PASS or FAIL. Scope matches Tom's fixed Day-1 allocation exactly, with no creep into v2/Sprint-2+ territory and no shortfall against what §6's Day-1 row requires. Adversarial evidence (3 independent kill-confirmed mutations across `ReadablePoll`, `HealthzClient`, `Backoff`) satisfies both team-lead's explicit "verify tests actually catch regressions" instruction and the harness Mode-0-closure adversarial-review requirement.
