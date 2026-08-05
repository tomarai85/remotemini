import XCTest
@testable import RemoteMini

/// `ConversationViewModel` state-machine tests (Sprint 3 brief §4-a's 8-item table).
/// Driven through `load()`/`loadEarlier()` (not `applyInitial`/`applyLoadEarlier`
/// directly) wherever the requested `limit` itself is under test -- only the async
/// methods compute `MergeHistory.nextHistoryLimit`; `apply*` alone would let a test
/// pass while the wrong limit was actually requested.
@MainActor
final class ConversationViewModelTests: XCTestCase {
    private final class RecordingClient: HistoryFetching {
        var resultQueue: [Result<HistoryResponse, SessionsFetchError>] = []
        private(set) var requestedLimits: [Int] = []

        /// Sprint 3 test-only knob, same reasoning as `MockURLProtocol.deliveryDelay`
        /// (`ios/Tests/Support/MockURLProtocol.swift`): a body with no real
        /// suspension point gives Swift's cooperative scheduler no obligation to let
        /// a second, concurrently-launched `Task` run before this one resumes, which
        /// would make the double-press guard test below race wall-clock scheduling
        /// order instead of actually exercising `isFetchingEarlier`.
        var deliveryDelay: Duration = .zero

        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
            requestedLimits.append(limit)
            if deliveryDelay > .zero {
                try? await Task.sleep(for: deliveryDelay)
            }
            guard !resultQueue.isEmpty else { return .failure(.unreachable) }
            return resultQueue.removeFirst()
        }
    }

    /// Sprint 5's send-path stub. Records what `ConversationViewModel.send()` handed
    /// it -- which is the only way to check the "text is transmitted unmodified" rule
    /// from this side of the seam -- and hands back queued outcomes.
    private final class RecordingSendClient: MessageSending {
        var outcomeQueue: [SendOutcome] = []
        private(set) var sentTexts: [String] = []
        /// Same reasoning as `RecordingClient.deliveryDelay`: without a real suspension
        /// point, a test that wants to observe the *in-flight* state (`isSending` true,
        /// draft not yet touched) has no window in which to look.
        var deliveryDelay: Duration = .zero

        func send(baseURL: URL, apiKey: String, sessionID: String, text: String) async -> SendOutcome {
            sentTexts.append(text)
            if deliveryDelay > .zero {
                try? await Task.sleep(for: deliveryDelay)
            }
            guard !outcomeQueue.isEmpty else { return .unreachable }
            return outcomeQueue.removeFirst()
        }
    }

    /// The default for every test that is not about sending. Fails loudly rather than
    /// quietly returning something: a history/poll test that reaches the send path has
    /// a wiring bug, and the useful report for that is a named failure, not a plausible
    /// `.unreachable`.
    private struct UnusedSendClient: MessageSending {
        func send(baseURL: URL, apiKey: String, sessionID: String, text: String) async -> SendOutcome {
            XCTFail("this test's view model was not expected to send anything")
            return .unreachable
        }
    }

    /// A `PollFetching` that issues no request and never returns a step -- it suspends
    /// until the driving `Task` is cancelled, which is precisely what a long-poll that
    /// is still waiting looks like from `PollLoop`'s side.
    ///
    /// It exists because the default `pollClient:` is a REAL `PollClient()`, so every
    /// test that reached `startPolling()` was firing real requests at the `.invalid`
    /// fixture host. Those never affected an assertion -- but each failure wrote an
    /// `NSURLErrorDomain` line to the process's stdout, and on 2026-08-05 one of them
    /// interleaved into the middle of xcodebuild's own `Test Case '-[...]' passed`
    /// line, eating its leading `T`. `tools/sim-log-summary.sh` then could not see
    /// that result and correctly refused to call the run green (「始まった 290 件 に対し、
    /// 終わりを報告したのは 289 件」). The test had passed; the measurement had been
    /// destroyed by noise this suite had no reason to emit. Silencing the source is the
    /// fix -- not loosening the summariser, which is the only thing standing between a
    /// half-finished run and a green claim.
    private struct SilentPollFetching: PollFetching {
        func poll(
            baseURL: URL,
            apiKey: String,
            sessionID: String,
            cursor: PollCursor,
            waitMs: Int
        ) async -> PollOutcome {
            try? await Task.sleep(for: .seconds(3600))
            return .cancelled
        }
    }

    private var unauthorizedCallCount = 0

    private func makeViewModel(
        client: HistoryFetching,
        sendClient: MessageSending = UnusedSendClient(),
        pollClient: PollFetching = SilentPollFetching(),
        initialLimit: Int = ConversationViewModel.initialLimit
    ) -> ConversationViewModel {
        unauthorizedCallCount = 0
        return ConversationViewModel(
            client: client,
            pollClient: pollClient,
            sendClient: sendClient,
            baseURL: URL(string: "https://unit-test.invalid")!,
            apiKey: "unit-test-fixture-key-not-real",
            sessionID: "sess-0001",
            title: "t",
            onUnauthorized: { [weak self] in self?.unauthorizedCallCount += 1 },
            initialLimit: initialLimit
        )
    }

    private func e(_ role: EntryRole, _ text: String) -> HistoryEntry {
        HistoryEntry(role: role, text: text, display: .init(who: "who"))
    }

    // MARK: - ① initial fetch -> render array matches mergeHistory(history, live)

    func testInitialFetchRenderArrayMatchesHistorySinceLiveStaysEmpty() async {
        let client = RecordingClient()
        let h = [e(.user, "a"), e(.assistant, "b")]
        client.resultQueue = [.success(HistoryResponse(history: h, truncated: false))]
        let vm = makeViewModel(client: client)

        await vm.load()

        XCTAssertEqual(vm.entries, MergeHistory.merge(h, []))
        XCTAssertEqual(vm.entries, h)
        XCTAssertTrue(vm.live.isEmpty, "brief §2-d: live stays empty this sprint -- no poll loop yet")
        guard case .loaded = vm.phase else { return XCTFail("expected .loaded, got \(vm.phase)") }
    }

    // MARK: - ② load-earlier refetches with nextHistoryLimit's value, not a fixed step

    func testLoadEarlierRefetchesWithNextHistoryLimitValue() async {
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: true)),
            .success(HistoryResponse(history: [e(.user, "older"), e(.user, "a")], truncated: true)),
        ]
        let vm = makeViewModel(client: client)

        await vm.load()
        await vm.loadEarlier()

        XCTAssertEqual(client.requestedLimits, [50, 150], "50 -> nextHistoryLimit(50) == 150, not a fixed +N step")
    }

    // MARK: - ③ current == 500 retracts the button permanently, shows the ceiling line

    func testAtCeilingRetractsButtonPermanentlyAndShowsCeilingState() async {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [e(.user, "a")], truncated: true))]
        // Seeded directly at the ceiling (brief §3-b-1: `nextHistoryLimit(500) == 500`)
        // rather than driving 5 `loadEarlier()` calls to reach it -- same DI shape
        // `ListViewModelTests`'s `now:` injection uses to reach a state directly.
        let vm = makeViewModel(client: client, initialLimit: 500)

        await vm.load()

        XCTAssertEqual(vm.loadEarlierState, .atCeiling)
    }

    // MARK: - ④ oldest entry unchanged -> button stays (relabeled), "今回は読み込めませんでした"

    func testLoadEarlierWithUnchangedOldestEntryShowsStalledRetryNotPermanentCeiling() async {
        let client = RecordingClient()
        let oldest = e(.user, "a")
        client.resultQueue = [
            .success(HistoryResponse(history: [oldest], truncated: true)),
            .success(HistoryResponse(history: [oldest], truncated: true)), // oldest entry identical
        ]
        let vm = makeViewModel(client: client)

        await vm.load()
        await vm.loadEarlier()

        XCTAssertEqual(vm.loadEarlierState, .stalledRetry)
    }

    // MARK: - ⑤ count increased but oldest unchanged (concurrent growth) -> same as ④

    func testLoadEarlierWithGrowingLiveEndButUnchangedOldestStillReadsAsStalledRetry() async {
        // Brief §3-b-4's documented Codex-caught bug: the ORIGINAL rule measured
        // count (50 -> 150 "looks like success"), not "did the oldest entry actually
        // move." A conversation growing concurrently at the newest end while the
        // oldest end never advances must still read as a failed attempt.
        let client = RecordingClient()
        let oldest = e(.user, "a")
        client.resultQueue = [
            .success(HistoryResponse(history: [oldest, e(.assistant, "b")], truncated: true)), // count 2
            .success(HistoryResponse(
                history: [oldest, e(.assistant, "b"), e(.user, "c"), e(.assistant, "d"), e(.user, "f")],
                truncated: true
            )), // count jumped 2 -> 5, but `oldest` never moved
        ]
        let vm = makeViewModel(client: client)

        await vm.load()
        await vm.loadEarlier()

        XCTAssertEqual(vm.loadEarlierState, .stalledRetry, "count grew 2->5 but the oldest entry never advanced -- must not read as success")
    }

    // MARK: - ⑥ truncated:false -> no button, no persistent line

    func testTruncatedFalseHidesTheButtonEntirely() async {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [e(.user, "a")], truncated: false))]
        let vm = makeViewModel(client: client)

        await vm.load()

        XCTAssertEqual(vm.loadEarlierState, .hidden)
    }

    // MARK: - ⑦ 401 -> Key-entry, on both the initial load and a load-earlier attempt

    func testUnauthorizedOnInitialLoadInvokesCallback() async {
        let client = RecordingClient()
        client.resultQueue = [.failure(.unauthorized)]
        let vm = makeViewModel(client: client)

        await vm.load()

        XCTAssertEqual(unauthorizedCallCount, 1)
    }

    func testUnauthorizedOnLoadEarlierInvokesCallback() async {
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: true)),
            .failure(.unauthorized),
        ]
        let vm = makeViewModel(client: client)

        await vm.load()
        await vm.loadEarlier()

        XCTAssertEqual(unauthorizedCallCount, 1)
    }

    // MARK: - ⑨ positive anchor: .available is actually reached, not just inferred
    // from the fact that the negative-condition tests above expect something else

    func testLoadEarlierReachesAvailableStateWithoutAnyStallOrCeilingCondition() async {
        // Every test above that touches `loadEarlierState` asserts `.stalledRetry`
        // or `.atCeiling` -- each seeds a scenario where one of those IS the correct
        // outcome. None of them would catch a ViewModel that always fell through to
        // `.stalledRetry` regardless of whether the oldest entry actually advanced.
        // This is the one case where neither adverse condition applies, and
        // `.available` must be the result.
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: true)),
            .success(HistoryResponse(history: [e(.user, "older"), e(.user, "a")], truncated: true)),
        ]
        let vm = makeViewModel(client: client)

        await vm.load()
        await vm.loadEarlier()

        XCTAssertEqual(vm.loadEarlierState, .available, "oldest advanced, not at ceiling -- must land on .available")
    }

    // MARK: - Brief §3-c: 404 -> .notFound, distinct from .unreachable, on both the
    // initial load and a load-earlier attempt

    func testNotFoundOnInitialLoadSetsNotFoundPhaseNotUnreachable() async {
        let client = RecordingClient()
        client.resultQueue = [.failure(.notFound)]
        let vm = makeViewModel(client: client)

        await vm.load()

        XCTAssertEqual(vm.phase, .notFound)
    }

    func testNotFoundOnLoadEarlierSetsNotFoundPhase() async {
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: true)),
            .failure(.notFound),
        ]
        let vm = makeViewModel(client: client)

        await vm.load()
        await vm.loadEarlier()

        XCTAssertEqual(vm.phase, .notFound, "the conversation disappearing mid-load-earlier must not leave stale history showing under a working retry loop")
    }

    func testNotFoundIsNotCollapsedIntoUnreachablePhaseNegativeControl() async {
        // Guards against exactly the mistake this brief's own first draft made
        // (§3-c): folding 404 into `.unreachable` would offer a "再試行" button on
        // an outcome retrying can never fix.
        let client = RecordingClient()
        client.resultQueue = [.failure(.notFound)]
        let vm = makeViewModel(client: client)

        await vm.load()

        XCTAssertNotEqual(vm.phase, .unreachable)
    }

    // MARK: - ⑧ double-press does not launch two concurrent fetches

    func testDoublePressDoesNotLaunchTwoConcurrentFetches() async {
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: true)), // initial
            .success(HistoryResponse(history: [e(.user, "older"), e(.user, "a")], truncated: true)), // the one loadEarlier fetch that should actually run
        ]
        let vm = makeViewModel(client: client)
        await vm.load()

        client.deliveryDelay = .milliseconds(50)
        async let first: Void = vm.loadEarlier()
        async let second: Void = vm.loadEarlier()
        _ = await (first, second)

        XCTAssertEqual(
            client.requestedLimits, [50, 150],
            "only one loadEarlier fetch should have reached the client -- the second concurrent call must be dropped by the isFetchingEarlier guard"
        )
    }

    // MARK: - Negative control (brief §3-b-2's table order)

    func testCeilingTakesPriorityOverStalledRetryWhenBothConditionsCoOccurNegativeControl() async {
        // A mutant that checked "did the oldest entry advance" BEFORE checking the
        // ceiling would show the temporary "もう一度試す" state instead of
        // permanently retracting the button, at the exact moment the phone has
        // genuinely run out of budget (500) to read any further back.
        let client = RecordingClient()
        let oldest = e(.user, "a")
        let vm = makeViewModel(client: client, initialLimit: 450)
        client.resultQueue = [
            .success(HistoryResponse(history: [oldest], truncated: true)), // initial, limit 450
            .success(HistoryResponse(history: [oldest], truncated: true)), // load earlier -> limit 500 (the cap); oldest ALSO didn't advance
        ]

        await vm.load()
        await vm.loadEarlier()

        XCTAssertEqual(vm.loadEarlierState, .atCeiling, "ceiling must win even though the oldest entry also failed to advance")
    }

    // MARK: - Sprint 4: `applyPollStep(_:)` -- the poll loop's own synchronous test
    // seam, exactly mirroring `applyInitial(_:)` above. Driven directly with
    // hand-built `PollLoop.StepResult` values -- no real `PollFetching`, no real
    // `PollLoop` -- since none of N5/N7/§5-b branches 3/5/6/7/9 depend on the
    // network round trip itself, only on what `ConversationViewModel` does with an
    // already-arrived result. `vm.load()` is still called first in every case
    // below because `unreadableMeter` is only seeded inside `startPolling()`
    // (called from `applyInitial(_:)` on success) -- without it, `.unreadable`
    // outcomes would silently no-op via `unreadableMeter?.markUnreadable()`. This
    // does start a background poll `Task`, but since Sprint 5 that task drives
    // `SilentPollFetching` (see its doc comment above), so it issues no request and
    // writes no log line. The claim that used to stand here -- that the real
    // `PollClient()` it drove was "harmless" -- was wrong: it was assertion-neutral
    // but not output-neutral, and its noise is what destroyed a result line in the
    // 2026-08-05 run.

    private func readableStep(_ json: String) throws -> PollLoop.StepResult {
        let response = try JSONDecoder().decode(PollResponse.self, from: Data(json.utf8))
        return PollLoop.StepResult(kind: .readable(response), nextWaitMs: 20_000, localBackoffMs: 0)
    }

    private func unreadableStep() -> PollLoop.StepResult {
        PollLoop.StepResult(kind: .unreadable, nextWaitMs: 20_000, localBackoffMs: 0)
    }

    // MARK: - §5-b branch 3: a screen-only change updates screen, touches nothing else

    func testScreenOnlyChangeUpdatesScreenWithoutTouchingChoiceViewOrLive() async throws {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [], truncated: false))]
        let vm = makeViewModel(client: client)
        await vm.load()
        XCTAssertNil(vm.screen)
        XCTAssertNil(vm.choiceView)

        let step = try readableStep("""
        { "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "BUSY", "work": "observed", "windowMs": 12 }, "cursor": "t.a.1.0", "more": false }
        """)
        vm.applyPollStep(step)

        XCTAssertEqual(vm.screen?.classification, .busy)
        XCTAssertNil(vm.choiceView, "no display key in this response -- must not manufacture a choice view out of nothing")
        XCTAssertTrue(vm.live.isEmpty, "no items in this response -- live must stay empty")
    }

    // MARK: - N5 (§5-a): null screen/choice hold over the previous value, never clear it

    func testNullScreenAndChoiceHoldOverThePreviousValueRatherThanClearingItNegativeControl() async throws {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [], truncated: false))]
        let vm = makeViewModel(client: client)
        await vm.load()

        let first = try readableStep("""
        { "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "SENDABLE", "work": "quiet", "windowMs": 0 }, "display": { "choice": { "show": true, "reason": "confirm" } }, "cursor": "t.a.1.0", "more": false }
        """)
        vm.applyPollStep(first)
        XCTAssertEqual(vm.screen?.classification, .sendable)
        XCTAssertEqual(vm.choiceView, ChoiceView(show: true, reason: "confirm"))

        let second = try readableStep("""
        { "items": [], "screen": null, "display": null, "cursor": "t.a.2.0", "more": false }
        """)
        vm.applyPollStep(second)

        XCTAssertEqual(vm.screen?.classification, .sendable, "N5: a null screen in this response must hold over the previous value, not clear it")
        XCTAssertEqual(vm.choiceView, ChoiceView(show: true, reason: "confirm"), "N5: display.choice follows the same hold-over rule")

        // Negative control: prove a "null clears" twin actually diverges here --
        // unconditional assignment (rather than `if let`) would nil both out.
        struct ClearingTwin {
            var screen: ScreenBody?
            var choice: ChoiceView?
        }
        var twin = ClearingTwin(screen: nil, choice: nil)
        for step in [first, second] {
            guard case .readable(let response) = step.kind else { continue }
            twin.screen = response.screen // unconditional -- clears on null
            twin.choice = response.display?.choice
        }
        XCTAssertNil(twin.screen, "the clearing twin actually clears on the second, null response -- proof the control can fail")
        XCTAssertNotEqual(twin.screen?.classification, vm.screen?.classification)
    }

    // MARK: - §5-b branches 5/6/7: gap notice draw/suppress, refetch always, co-occurrence

    func testGapWithNoticeDrawsTheNoticeAndAlwaysTriggersARefetch() async throws {
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: false)), // initial load
            .success(HistoryResponse(history: [e(.user, "a"), e(.assistant, "post-gap")], truncated: false)), // the gap-triggered refetch
        ]
        let vm = makeViewModel(client: client)
        await vm.load()

        let step = try readableStep("""
        { "items": [ { "kind": "gap", "why": "ring-overflow", "display": { "notice": "少し飛びました" }, "seq": 9 } ], "cursor": "t.a.1.0", "more": false }
        """)
        vm.applyPollStep(step)
        XCTAssertEqual(vm.latestGapNotice, "少し飛びました")

        try? await Task.sleep(for: .milliseconds(100)) // let the fire-and-forget resync Task land
        XCTAssertEqual(client.requestedLimits.count, 2, "a gap item must trigger a /history refetch")
        XCTAssertEqual(vm.history.last?.text, "post-gap", "the refetch's own response must actually land in history")
    }

    func testGapWithNullNoticeTailAttachedDoesNotDrawButStillRefetches() async throws {
        // §0-b④, "the sprint's most dangerous single fact": a null notice
        // (`gapNotice("tail-attached")`) is benign and must draw nothing -- but
        // brief §4 is explicit that drawing and refetching are two SEPARATE
        // decisions, so the refetch must still fire.
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: false)),
            .success(HistoryResponse(history: [e(.user, "a"), e(.assistant, "post-gap")], truncated: false)),
        ]
        let vm = makeViewModel(client: client)
        await vm.load()

        let step = try readableStep("""
        { "items": [ { "kind": "gap", "why": "tail-attached", "display": { "notice": null }, "seq": 3 } ], "cursor": "t.a.1.0", "more": false }
        """)
        vm.applyPollStep(step)
        XCTAssertNil(vm.latestGapNotice, "tail-attached's null notice must not surface a fallback banner")

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.requestedLimits.count, 2, "draw and refetch are independent decisions -- a null notice must still refetch")
    }

    func testGapAndMessageInTheSameResponseAreBothProcessed() async throws {
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: false)),
            .success(HistoryResponse(history: [e(.user, "a"), e(.assistant, "post-gap")], truncated: false)),
        ]
        let vm = makeViewModel(client: client)
        await vm.load()

        let step = try readableStep("""
        { "items": [
            { "kind": "message", "seq": 1, "entries": [ { "role": "assistant", "text": "hi", "display": { "who": "w" } } ] },
            { "kind": "gap", "why": "ring-overflow", "display": { "notice": "飛びました" }, "seq": 2 }
          ], "cursor": "t.a.1.0", "more": false }
        """)
        vm.applyPollStep(step)

        XCTAssertEqual(vm.live.count, 1, "the co-located message item must still be applied")
        XCTAssertEqual(vm.live.first?.text, "hi")
        XCTAssertEqual(vm.latestGapNotice, "飛びました", "the co-located gap item must also be applied")

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.requestedLimits.count, 2, "the co-located gap must still trigger its own refetch")
    }

    // MARK: - §5-b branch 9: 401 stops the drive loop

    func testUnauthorizedStepStopsTheDriveLoopAndInvokesTheCallback() async {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [], truncated: false))]
        let vm = makeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(unauthorizedCallCount, 0)

        let shouldContinue = vm.applyPollStep(PollLoop.StepResult(kind: .unauthorized, nextWaitMs: 20_000, localBackoffMs: 0))

        XCTAssertFalse(shouldContinue, "the drive loop must stop on 401 -- brief §5-b branch 9")
        XCTAssertEqual(unauthorizedCallCount, 1)
    }

    // MARK: - Sprint 4 Evaluator RED 2: the three entry points (N4 resume, 再試行,
    // 読み直す) driven directly, not only reached indirectly through the gap tests
    // above. Same observation form the gap tests already use: count the requested
    // `/history` limits and assert the refetch's own response lands in `history`.

    /// RED 2, item (a): `handleForegroundResume()` is the desk-side half of DoD row
    /// 8 -- the actual backgrounding is Tom's real device, but that a call to this
    /// method causes a `/history` refetch is verifiable here without one.
    func testHandleForegroundResumeRefetchesHistoryAndTheRefetchLandsInHistory() async throws {
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: false)), // initial load
            .success(HistoryResponse(history: [e(.user, "a"), e(.assistant, "post-resume")], truncated: false)), // N4's resync
        ]
        let vm = makeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(client.requestedLimits.count, 1, "only the initial load so far")

        vm.handleForegroundResume()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(client.requestedLimits.count, 2, "N4: background -> foreground must refetch /history")
        XCTAssertEqual(vm.history.last?.text, "post-resume", "the refetch's own response must actually land in history")
    }

    /// RED 2, item (b): `retryPollingNow()` ("再試行") and `rereadNow()` ("読み直す")
    /// must be OBSERVABLY different, not two names for the same call --
    /// `retryPollingNow()`'s own doc comment says it restarts the driving `Task` from
    /// the existing cursor WITHOUT touching `history`/`live`, while `rereadNow()` runs
    /// the full resync (refetch + clear `live`). A test that passes under an
    /// implementation where both call `performResync()` tests nothing -- this one
    /// specifically would not.
    func testRetryPollingNowDoesNotRefetchOrClearLiveWhileRereadNowDoesBothNegativeControl() async throws {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [e(.user, "a")], truncated: false))] // initial load
        let vm = makeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(client.requestedLimits.count, 1, "only the initial load so far")

        // Seed `live` via a normal readable poll step -- this is what "without
        // disturbing history/live" has to survive.
        let step = try readableStep("""
        { "items": [ { "kind": "message", "seq": 1, "entries": [ { "role": "assistant", "text": "live-1", "display": { "who": "w" } } ] } ], "cursor": "t.a.1.0", "more": false }
        """)
        vm.applyPollStep(step)
        XCTAssertEqual(vm.live.count, 1)

        // 再試行: must not touch /history, must not clear live.
        vm.retryPollingNow()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.requestedLimits.count, 1, "retryPollingNow must not refetch /history -- it restarts the driving Task from the existing cursor")
        XCTAssertEqual(vm.live.count, 1, "retryPollingNow must not clear live -- only rereadNow's full resync does that")

        // 読み直す: must refetch /history, must clear live, and the refetch's own
        // response must land in history -- the full resync procedure.
        client.resultQueue = [.success(HistoryResponse(history: [e(.user, "a"), e(.assistant, "post-reread")], truncated: false))]
        vm.rereadNow()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.requestedLimits.count, 2, "rereadNow must refetch /history")
        XCTAssertTrue(vm.live.isEmpty, "rereadNow's full resync must clear live -- the fresh history supersedes it")
        XCTAssertEqual(vm.history.last?.text, "post-reread", "the refetch's own response must land in history")
    }

    // MARK: - N7 (§5-a) / §3-c: auto-resync fires once per stalled episode, not per response

    func testAutoResyncFiresAtMostOnceUntilAReadableResponseEndsTheEpisodeNegativeControl() async {
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: false)), // initial load
            .success(HistoryResponse(history: [e(.user, "a"), e(.assistant, "resync-1")], truncated: false)), // 1st episode's auto-resync
            .success(HistoryResponse(history: [e(.user, "a"), e(.assistant, "resync-1"), e(.assistant, "resync-2")], truncated: false)), // 2nd episode's auto-resync
        ]
        let vm = makeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(client.requestedLimits.count, 1, "only the initial load so far")

        // 3 consecutive unreadable responses reach .stalled via the streak-3 floor
        // alone (no elapsed-time wait needed -- `UnreadableMeter`'s own OR logic is
        // already covered with an injected clock in `UnreadableMeterTests`).
        vm.applyPollStep(unreadableStep()) // streak 1 -> .degraded
        vm.applyPollStep(unreadableStep()) // streak 2 -> .degraded
        vm.applyPollStep(unreadableStep()) // streak 3 -> .stalled, auto-resync fires ONCE
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.requestedLimits.count, 2, "the stalled transition must fire exactly one auto-resync")

        // Still stalled -- further unreadable responses must NOT fire a second resync.
        vm.applyPollStep(unreadableStep())
        vm.applyPollStep(unreadableStep())
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.requestedLimits.count, 2, "N7: one-shot per stalled EPISODE, not one-shot ever nor per-response")

        // A readable response ends the episode (streak back to 0) and re-arms the guard.
        let readable = PollLoop.StepResult(
            kind: .readable(PollResponse(items: [], screen: nil, display: nil, queued: nil, cursor: PollCursor(raw: "t.a.9.0"), more: false)),
            nextWaitMs: 20_000, localBackoffMs: 0
        )
        vm.applyPollStep(readable)
        XCTAssertEqual(vm.unreadableStage, .normal)

        vm.applyPollStep(unreadableStep())
        vm.applyPollStep(unreadableStep())
        vm.applyPollStep(unreadableStep())
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.requestedLimits.count, 3, "a fresh stalled episode after recovery must be allowed to auto-resync again")
    }

    // MARK: - Sprint 5: the composer
    //
    // Two halves, kept apart on purpose. `composerEnabled`/`canSend` are about what the
    // phone lets the user DO (decided from the polled screen classification, brief
    // §0-c ⑤); `applySendOutcome(_:)` is about what the phone SAYS afterwards (decided
    // entirely by the server's `display`, brief §0-c ③). The failure this separation
    // guards against is the natural drift between them -- a phone that starts deciding
    // wording from the same signals it uses for enablement.

    /// A view model that has loaded and then observed exactly one poll response
    /// carrying `screenValue` (or none at all, when `screenValue` is nil).
    private func loadedViewModel(
        screen screenValue: String?,
        sendClient: MessageSending = UnusedSendClient()
    ) async throws -> ConversationViewModel {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [], truncated: false))]
        let vm = makeViewModel(client: client, sendClient: sendClient)
        await vm.load()
        if let screenValue {
            vm.applyPollStep(try readableStep("""
            { "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "\(screenValue)", "work": "quiet", "windowMs": 0 }, "cursor": "t.a.1.0", "more": false }
            """))
        }
        return vm
    }

    // MARK: §0-c ⑤ -- the enablement table, one assertion per row

    func testComposerIsEnabledBeforeAnyScreenHasBeenObserved() async throws {
        let vm = try await loadedViewModel(screen: nil)

        XCTAssertNil(vm.screen)
        XCTAssertTrue(vm.composerEnabled)
        XCTAssertNil(vm.composerDisabledReason)
    }

    func testComposerIsEnabledOnSENDABLE() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        XCTAssertTrue(vm.composerEnabled)
        XCTAssertNil(vm.composerDisabledReason)
    }

    /// ★The row that contradicts a literal reading of brief §2 step 1. `BUSY` means
    /// Claude is generating, and `server.mjs`'s injector comment states outright that a
    /// send during generation is legitimate ("生成中でも composer はあるので送れる").
    /// Disabling here would mute the phone during exactly the state the app exists to
    /// watch -- which is why this is asserted as its own named case rather than left to
    /// a table row someone could "tidy up" later.
    func testComposerStaysEnabledOnBUSY() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")

        XCTAssertEqual(vm.screen?.classification, .busy)
        XCTAssertTrue(vm.composerEnabled, "§0-c ⑤: BUSY does not disable the composer")
        XCTAssertNil(vm.composerDisabledReason)
    }

    func testComposerIsDisabledOnCHOICEWithTheSpecsFixedWording() async throws {
        let vm = try await loadedViewModel(screen: "CHOICE")

        XCTAssertFalse(vm.composerEnabled)
        XCTAssertEqual(
            vm.composerDisabledReason,
            "v1 では電話から選べません。机で確認するか、割り込みで中断してください"
        )
    }

    func testComposerIsDisabledOnUNKNOWNWithTheSpecsFixedWording() async throws {
        let vm = try await loadedViewModel(screen: "UNKNOWN")

        XCTAssertFalse(vm.composerEnabled)
        XCTAssertEqual(vm.composerDisabledReason, "画面の状態を読めていません")
    }

    /// A classification this build has never heard of must not silently remove a
    /// capability -- same rule as `ResultDisplay.kind` not being a strict enum. The
    /// opposite behaviour (unknown -> disabled) would mean a future server release
    /// could mute every phone in the field without anyone shipping a phone change.
    func testAnUnrecognizedClassificationLeavesTheComposerEnabled() async throws {
        let vm = try await loadedViewModel(screen: "SOME_FUTURE_STATE")

        XCTAssertEqual(vm.screen?.classification, .unrecognized)
        XCTAssertTrue(vm.composerEnabled)
        XCTAssertNil(vm.composerDisabledReason)
    }

    /// ★Negative control for the whole table: an UNREADABLE poll must not disable the
    /// composer. Failing closed here is the intuitive move and it is wrong -- the
    /// fail-closed guard already exists on the side that can actually see the desk
    /// (`inject.mjs` refuses on CHOICE/UNKNOWN and aborts on a modal detected
    /// immediately before injection), so adding one here buys nothing and costs the
    /// user their only channel at the exact moment the desk stopped answering.
    func testAnUnreadablePollDoesNotDisableTheComposerNegativeControl() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        vm.applyPollStep(unreadableStep())
        vm.applyPollStep(unreadableStep())
        vm.applyPollStep(unreadableStep())

        XCTAssertEqual(vm.unreadableStage, .stalled, "precondition: the meter really did reach the worst stage")
        XCTAssertTrue(vm.composerEnabled, "§0-c ⑤: 「読めない = 送らせない」に倒さない")
    }

    /// The enablement table must actually discriminate. If `composerEnabled` were a
    /// constant `true` (or a constant `false`), every row above would still be
    /// satisfied by one of the two constants -- this is the assertion that neither
    /// constant passes.
    func testEnablementIsNotAConstantNegativeControl() async throws {
        let enabled = try await loadedViewModel(screen: "SENDABLE").composerEnabled
        let disabled = try await loadedViewModel(screen: "CHOICE").composerEnabled

        XCTAssertNotEqual(enabled, disabled)
    }

    // MARK: §canSend

    func testCanSendIsFalseForEmptyAndWhitespaceOnlyDrafts() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        XCTAssertFalse(vm.canSend, "empty draft")
        vm.draft = "   \n\t "
        XCTAssertFalse(vm.canSend, "whitespace-only draft")
        vm.draft = "x"
        XCTAssertTrue(vm.canSend)
    }

    func testCanSendIsFalseWhileTheComposerIsDisabledEvenWithText() async throws {
        let vm = try await loadedViewModel(screen: "CHOICE")

        vm.draft = "本当に送りたい"

        XCTAssertFalse(vm.canSend)
    }

    func testSendDoesNothingWhenCanSendIsFalse() async throws {
        let sender = RecordingSendClient()
        let vm = try await loadedViewModel(screen: "CHOICE", sendClient: sender)
        vm.draft = "blocked"

        await vm.send()

        XCTAssertTrue(sender.sentTexts.isEmpty, "the guard must stop the request, not merely grey out a button")
        XCTAssertNil(vm.sendBanner)
    }

    // MARK: §2 -- the send ORDER (the one thing the brief stars)

    /// ★The draft is not cleared on tap. Observed mid-flight, which is the only place
    /// the mistake is visible: an implementation that cleared on entry and restored on
    /// refusal would look identical from the outside once the response landed.
    func testDraftSurvivesUntilTheResponseHasBeenClassified() async throws {
        let sender = RecordingSendClient()
        sender.deliveryDelay = .milliseconds(200)
        sender.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "送った", keepText: false))]
        let vm = try await loadedViewModel(screen: "SENDABLE", sendClient: sender)
        vm.draft = "書いた文"

        let sending = Task { await vm.send() }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(vm.isSending, "precondition: we really are looking mid-flight")
        XCTAssertEqual(vm.draft, "書いた文", "brief §2: the composer text is untouched until the outcome is known")

        await sending.value
        XCTAssertFalse(vm.isSending)
        XCTAssertEqual(vm.draft, "", "keepText:false -> cleared, but only after classification")
    }

    func testTextIsTransmittedUnmodifiedIncludingSurroundingWhitespace() async throws {
        let sender = RecordingSendClient()
        sender.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "送った", keepText: false))]
        let vm = try await loadedViewModel(screen: "SENDABLE", sendClient: sender)
        vm.draft = "  改行あり\n  "

        await vm.send()

        XCTAssertEqual(sender.sentTexts, ["  改行あり\n  "], "the trim exists only to decide canSend; the server trims for real")
    }

    /// A new send clears the previous banner before its own outcome arrives. Otherwise
    /// "送った" from the last attempt sits under an in-flight send and reads as this
    /// send's result.
    func testStartingASendClearsThePreviousBanner() async throws {
        let sender = RecordingSendClient()
        sender.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "送った", keepText: false))]
        sender.deliveryDelay = .milliseconds(200)
        let vm = try await loadedViewModel(screen: "SENDABLE", sendClient: sender)
        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "前回の結果", keepText: true)))
        XCTAssertNotNil(vm.sendBanner)

        vm.draft = "次"
        let sending = Task { await vm.send() }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(vm.sendBanner, "a stale success must not be readable as this send's outcome")
        await sending.value
    }

    // MARK: §0-c ③ -- what the banner says, and who wrote it

    func testServerDisplayIsShownVerbatimAndMarkedAsComingFromTheServer() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        let display = ResultDisplay(
            kind: "warn",
            text: "入れた形跡が確認できません。本文は残してあります。送り直すと二重に入ることがあります。",
            keepText: true
        )

        vm.applySendOutcome(.display(display))

        XCTAssertEqual(vm.sendBanner?.text, display.text, "no suffix, no rewording, nothing appended")
        XCTAssertEqual(vm.sendBanner?.tone, .warn)
        XCTAssertEqual(vm.sendBanner?.fromServer, true)
    }

    /// ★Provenance is the assertion, not just the string. A regression that replaced
    /// the server's sentence with a locally-composed one of the same meaning would pass
    /// any "some text is shown" check; this is the one that catches it.
    func testPhoneWordedBannersAreMarkedAsNotComingFromTheServerNegativeControl() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: false)))
        let fromServer = vm.sendBanner
        vm.applySendOutcome(.unreachable)
        let fromPhone = vm.sendBanner

        XCTAssertEqual(fromServer?.fromServer, true)
        XCTAssertEqual(fromPhone?.fromServer, false)
        XCTAssertNotEqual(fromServer?.fromServer, fromPhone?.fromServer)
    }

    func testEveryDisplayToneReachesTheBannerUnchanged() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        let rows: [(String, ResultDisplay.Tone)] = [
            ("ok", .ok), ("warn", .warn), ("refused", .refused), ("error", .error), ("brand-new", .warn),
        ]

        for (kind, expected) in rows {
            vm.applySendOutcome(.display(ResultDisplay(kind: kind, text: "t", keepText: true)))
            XCTAssertEqual(vm.sendBanner?.tone, expected, kind)
        }
    }

    // MARK: §2 step 5 -- keepText, read as a field

    func testKeepTextFalseClearsTheDraft() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"

        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: false)))

        XCTAssertEqual(vm.draft, "")
    }

    func testKeepTextTrueKeepsTheDraft() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"

        vm.applySendOutcome(.display(ResultDisplay(kind: "refused", text: "今は入れられません", keepText: true)))

        XCTAssertEqual(vm.draft, "書いた")
    }

    /// ★The recorded deviation from brief §2 step 5 ("偽/不在なら消す"). Absent means
    /// KEEP here. Asserted rather than left implicit precisely BECAUSE it departs from
    /// the brief: an undocumented deviation and a bug look identical six weeks later.
    /// The asymmetry that justifies it: a kept draft that should have gone leaves a
    /// duplicate the user can see and delete; a cleared draft that should have stayed
    /// destroys something unrecoverable.
    func testKeepTextAbsentKeepsTheDraftDeliberateDeviationFromTheBrief() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"

        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: nil)))

        XCTAssertEqual(vm.draft, "書いた", "absent keepText is not read as false")
    }

    /// `keepText` must be read as the field it is. Today `keepText:false` occurs on
    /// exactly one branch (`kind:"ok"`), so `kind == "ok"` would be green right now and
    /// silently wrong the day the server adds a second -- this pair of rows is what
    /// separates the two implementations.
    func testClearingFollowsKeepTextNotKindNegativeControl() async throws {
        let okKeeping = try await loadedViewModel(screen: "SENDABLE")
        okKeeping.draft = "書いた"
        okKeeping.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "t", keepText: true)))

        let errorClearing = try await loadedViewModel(screen: "SENDABLE")
        errorClearing.draft = "書いた"
        errorClearing.applySendOutcome(.display(ResultDisplay(kind: "error", text: "t", keepText: false)))

        XCTAssertEqual(okKeeping.draft, "書いた", #"kind:"ok" with keepText:true must KEEP"#)
        XCTAssertEqual(errorClearing.draft, "", #"kind:"error" with keepText:false must CLEAR"#)
    }

    // MARK: The non-display outcomes

    func testUnreachableKeepsTheDraftAndRefusesToClaimEitherOutcome() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"

        vm.applySendOutcome(.unreachable)

        XCTAssertEqual(vm.draft, "書いた")
        XCTAssertEqual(vm.sendBanner?.tone, .warn)
        XCTAssertEqual(
            vm.sendBanner?.text,
            "送れたかどうか確認できませんでした。本文は残してあります。机の画面を確認してください。"
        )
        guard case .loaded = vm.phase else { return XCTFail("a transport failure must not tear the screen down") }
    }

    func testCancelledChangesNothingAtAll() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"
        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "前回", keepText: true)))
        let bannerBefore = vm.sendBanner

        vm.applySendOutcome(.cancelled)

        XCTAssertFalse(vm.isSending, "the in-flight flag still has to come down")
        XCTAssertEqual(vm.draft, "書いた")
        XCTAssertEqual(vm.sendBanner, bannerBefore, "whoever cancelled owns the outcome -- no banner of our own")
    }

    func testUnauthorizedRoutesOutAndKeepsWhatTheUserTyped() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"

        vm.applySendOutcome(.unauthorized)

        XCTAssertEqual(unauthorizedCallCount, 1)
        XCTAssertEqual(vm.draft, "書いた", "the user is about to make a round trip to Key-entry and back")
        XCTAssertNil(vm.sendBanner)
    }

    func testSessionNotFoundOnSendTearsTheScreenDown() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        vm.applySendOutcome(.sessionNotFound)

        XCTAssertEqual(vm.phase, .notFound)
    }

    // MARK: Contract violations -- the same fact, two different screen consequences

    func testContractViolationOnSendIsABannerOverAnIntactScreen() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"
        let violation = ResponseContractViolation(status: 202, code: nil)

        vm.applySendOutcome(.contractViolation(violation))

        guard case .loaded = vm.phase else {
            return XCTFail("the conversation and its poll loop must survive: this is the one view that can tell the user what happened")
        }
        XCTAssertEqual(vm.sendBanner?.text, violation.displayText)
        XCTAssertFalse(vm.sendBanner?.text.isEmpty ?? true, "§3-a control 1: the screen must not go silent on an unreadable response")
        XCTAssertEqual(vm.sendBanner?.tone, .error)
        XCTAssertEqual(vm.sendBanner?.fromServer, false, "there was no server wording to carry -- that is the whole finding")
        XCTAssertEqual(vm.draft, "書いた", "delivery is unknown, so the text is unrecoverable if we clear it")
        XCTAssertEqual(vm.lastContractViolation, violation, "recorded even though it did not become the phase")
    }

    /// ★The negative control for the split. The same `ResponseContractViolation` value
    /// arriving on a LOAD becomes the whole screen; arriving on a SEND it becomes one
    /// banner. Collapsing the two (either direction) is a single-line change that no
    /// other test in this file would notice.
    func testTheSameViolationBecomesThePhaseOnLoadButNotOnSendNegativeControl() async throws {
        let violation = ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE")

        let onLoad = makeViewModel(client: RecordingClient())
        onLoad.applyInitial(.failure(.contractViolation(violation)))

        let onSend = try await loadedViewModel(screen: "SENDABLE")
        onSend.applySendOutcome(.contractViolation(violation))

        XCTAssertEqual(onLoad.phase, .contractViolation(violation))
        XCTAssertNotEqual(onSend.phase, onLoad.phase)
        XCTAssertNil(onLoad.sendBanner, "the load path has no banner to show -- there is no screen left to show it on")
        XCTAssertNotNil(onSend.sendBanner)
        // Both paths record it, which is the half that makes violations countable.
        XCTAssertEqual(onLoad.lastContractViolation, violation)
        XCTAssertEqual(onSend.lastContractViolation, violation)
    }

    /// A contract violation on "load earlier" tears the screen down rather than showing
    /// `.stalledRetry`. The alternative keeps a perfectly good history on screen under a
    /// "もう一度試す" button that quietly asserts another attempt might work -- and a
    /// contract violation does not heal by retrying.
    func testContractViolationOnLoadEarlierTearsDownRatherThanOfferingARetry() async throws {
        let client = RecordingClient()
        client.resultQueue = [
            .success(HistoryResponse(history: [e(.user, "a")], truncated: true)),
            .failure(.contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE"))),
        ]
        let vm = makeViewModel(client: client)

        await vm.load()
        XCTAssertEqual(vm.loadEarlierState, .available, "precondition: the button was actually there to press")
        await vm.loadEarlier()

        XCTAssertEqual(vm.phase, .contractViolation(ResponseContractViolation(status: 404, code: "NO_SUCH_ROUTE")))
        XCTAssertNotEqual(vm.loadEarlierState, .stalledRetry, "no retry affordance for a response we are not permitted to interpret")
    }
}
