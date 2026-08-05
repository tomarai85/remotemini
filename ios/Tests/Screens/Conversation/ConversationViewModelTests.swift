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

    private var unauthorizedCallCount = 0

    private func makeViewModel(client: HistoryFetching, initialLimit: Int = ConversationViewModel.initialLimit) -> ConversationViewModel {
        unauthorizedCallCount = 0
        return ConversationViewModel(
            client: client,
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
    // does start a REAL background poll `Task` against a real `PollClient()`
    // hitting the `.invalid` fixture host (the same pre-existing Sprint 3 quirk
    // `makeViewModel`'s default `pollClient:` produces) -- harmless here for the
    // same reason it was harmless in Sprint 3: it runs on a different
    // `HistoryFetching` instance than the `RecordingClient` these tests inspect.

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
}
