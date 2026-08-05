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
}
