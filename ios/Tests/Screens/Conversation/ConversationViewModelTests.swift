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

    /// ★DESIGN §2.54 の対照が要る窓 —— 「要求がまだ飛んでいる**最中**」を開ける stub。
    ///
    /// `deliveryDelay` では測れない。あれは 50ms 眠らせて、その間に別の `Task` が走る事を
    /// **期待**する形なので、読み取りが少しでも遅れれば送信は既に終わっていて、検査は
    /// 緑のまま何も測らなくなる(壁時計に結果を預けた検査は、緑になった理由を言えない)。
    ///
    /// 代わりに、`send` に入った所で MainActor へ跳んで `whileInFlight` を走らせる。
    /// `ConversationViewModel.send()` は `isSending = true` と `sendBanner = nil` を
    /// **置いてから**この client を await するので、この closure が走る瞬間が
    /// 「飛んでいる間」そのもの。眠りも継続も要らず、順序は言語が保証する。
    ///
    /// `probeCount` が要るのは、closure が一度も走らない実装(送る前に弾く等)でも
    /// closure の中の assert は1つも失敗しないから —— **走らなかった検査は緑になる**。
    private final class ProbingSendClient: MessageSending {
        var outcome: SendOutcome = .unreachable
        /// 送信が飛んでいる間に走る。`@MainActor` なのは覗く先が MainActor の ViewModel だから。
        var whileInFlight: (@MainActor () -> Void)?
        private(set) var probeCount = 0

        func send(baseURL: URL, apiKey: String, sessionID: String, text: String) async -> SendOutcome {
            if let whileInFlight {
                await MainActor.run { whileInFlight() }
                probeCount += 1
            }
            return outcome
        }
    }

    /// 同じ仕掛けの `/history` 側。§2.54 が要るのは**取り直しの段**(`isVerifyingSend`)を
    /// 中から覗く為で、そこは `verifySendByRereading` が `performResync()` を await して
    /// いる間にしか存在しない。
    ///
    /// `whileFetching` は最初の `load()` でも当たってしまうので、**`load()` の後に**
    /// 差し込む(armed でない間はただの `RecordingClient` として振る舞う)。
    private final class ProbingHistoryClient: HistoryFetching {
        var resultQueue: [Result<HistoryResponse, SessionsFetchError>] = []
        var whileFetching: (@MainActor () -> Void)?
        private(set) var probeCount = 0

        func fetch(baseURL: URL, apiKey: String, sessionID: String, limit: Int) async -> Result<HistoryResponse, SessionsFetchError> {
            if let whileFetching {
                await MainActor.run { whileFetching() }
                probeCount += 1
            }
            guard !resultQueue.isEmpty else { return .failure(.unreachable) }
            return resultQueue.removeFirst()
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

    /// Sprint 6's interrupt-path stub, shaped exactly like `RecordingSendClient` -- the
    /// only thing worth recording here is the CALL COUNT, since an interrupt carries no
    /// payload to inspect. That count is what separates "the button was greyed out" from
    /// "the request was actually stopped", which is the whole of the CHOICE gate.
    private final class RecordingInterruptClient: Interrupting {
        var outcomeQueue: [SendOutcome] = []
        private(set) var callCount = 0
        /// Same reasoning as `RecordingSendClient.deliveryDelay`: without a real
        /// suspension point there is no window in which to observe `isInterrupting`.
        var deliveryDelay: Duration = .zero
        /// ★2026-08-08(§2.56): `ProbingSendClient.whileInFlight` の複製。新しい仕掛けでは
        /// なく、送信で既に働いている物を割り込みにも通しただけ —— `interrupt()` は
        /// `isInterrupting = true` を**置いてから**この client を await するので、
        /// この closure が走る瞬間が「飛んでいる間」そのもの。壁時計に預けない。
        var whileInFlight: (@MainActor () -> Void)?
        private(set) var probeCount = 0

        func interrupt(baseURL: URL, apiKey: String, sessionID: String) async -> SendOutcome {
            callCount += 1
            if let whileInFlight {
                await MainActor.run { whileInFlight() }
                probeCount += 1
            }
            if deliveryDelay > .zero {
                try? await Task.sleep(for: deliveryDelay)
            }
            guard !outcomeQueue.isEmpty else { return .unreachable }
            return outcomeQueue.removeFirst()
        }
    }

    /// The default for every test that is not about interrupting -- fails loudly for
    /// the same reason `UnusedSendClient` does.
    private struct UnusedInterruptClient: Interrupting {
        func interrupt(baseURL: URL, apiKey: String, sessionID: String) async -> SendOutcome {
            XCTFail("this test's view model was not expected to interrupt anything")
            return .unreachable
        }
    }

    /// Sprint 7's choice-path stub. Unlike the interrupt stub, the CALL ARGUMENTS are
    /// the whole point here: `key` and `digest` are what carry the server's guarantee
    /// 見た物と押す物が同じ across the wire, and a phone that composed either of them
    /// itself would still produce a passing call count.
    private final class RecordingChoiceClient: ChoiceSending {
        var attemptQueue: [ChoiceAttempt] = []
        private(set) var calls: [(key: String, digest: String)] = []
        var deliveryDelay: Duration = .zero
        /// ★2026-08-08(§2.56): 割り込み側と同じ複製。`choose()` は
        /// `inFlightChoiceKey = key` を置いてから await するので、ここが
        /// 「どの鍵が飛んでいるか」を外から読める唯一の瞬間。
        var whileInFlight: (@MainActor () -> Void)?
        private(set) var probeCount = 0

        var callCount: Int { calls.count }

        func choose(
            baseURL: URL, apiKey: String, sessionID: String, key: String, digest: String
        ) async -> ChoiceAttempt {
            calls.append((key: key, digest: digest))
            if let whileInFlight {
                await MainActor.run { whileInFlight() }
                probeCount += 1
            }
            if deliveryDelay > .zero {
                try? await Task.sleep(for: deliveryDelay)
            }
            guard !attemptQueue.isEmpty else {
                return ChoiceAttempt(outcome: .unreachable, serverDigest: nil)
            }
            return attemptQueue.removeFirst()
        }
    }

    /// The default for every test that is not about choosing. ★This one carries more
    /// weight than the other two `Unused…` stubs: several tests below assert that a
    /// press was REFUSED, and the only difference between "refused" and "silently
    /// succeeded" is whether this failure fires.
    private struct UnusedChoiceClient: ChoiceSending {
        func choose(
            baseURL: URL, apiKey: String, sessionID: String, key: String, digest: String
        ) async -> ChoiceAttempt {
            XCTFail("this test's view model was not expected to press anything (key=\(key))")
            return ChoiceAttempt(outcome: .unreachable, serverDigest: nil)
        }
    }

    /// A `PollFetching` that issues no request and never returns a step -- it suspends
    /// until the driving `Task` is cancelled, which is precisely what a long-poll that
    /// is still waiting looks like from `PollLoop`'s side.
    ///
    /// It exists because the `pollClient:` default used to be a REAL `PollClient()`
    /// (that default is gone as of 2026-08-08 -- see
    /// `ios/Sources/Core/ConversationClients.swift` -- but this type is what made the
    /// suite quiet before it was), so every
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
        interruptClient: Interrupting = UnusedInterruptClient(),
        choiceClient: ChoiceSending = UnusedChoiceClient(),
        pollClient: PollFetching = SilentPollFetching(),
        draftStore: DraftStoring = InMemoryDraftStore(),
        initialLimit: Int = ConversationViewModel.initialLimit
    ) -> ConversationViewModel {
        unauthorizedCallCount = 0
        return ConversationViewModel(
            // 2026-08-08: 口は束で受ける形になった。この helper の引数はそのままで、
            // 束ねるのは此処1箇所 —— 呼ぶ側(検査 400 本超)は一切変わらない。
            clients: ConversationClients(
                history: client,
                poll: pollClient,
                send: sendClient,
                interrupt: interruptClient,
                choice: choiceClient
            ),
            // 既定は覚えない実装。本番の `UserDefaults` を検査が触ると、検査どうしが
            // 互いの打ちかけを見る上に開発機に残留物が残る(DESIGN §2.53)。
            draftStore: draftStore,
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

    /// Sprint 6. The step kind that used to change nothing at all -- §5-4's only input
    /// on this screen, and not to be confused with `unreadableStep()` above, which is
    /// §5-5's. The whole point of the pair is that they are different meters.
    private func unreachableStep() -> PollLoop.StepResult {
        PollLoop.StepResult(kind: .unreachable, nextWaitMs: 20_000, localBackoffMs: 1_000)
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

    // MARK: - 404 SESSION_NOT_FOUND during polling also stops the drive loop

    func testSessionNotFoundStepStopsTheDriveLoopAndShowsTheNotFoundPhase() async {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [], truncated: false))]
        let vm = makeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.phase, .loaded)

        let shouldContinue = vm.applyPollStep(PollLoop.StepResult(kind: .sessionNotFound, nextWaitMs: 20_000, localBackoffMs: 0))

        // `false` is the substance here, not the phase. A phase saying the conversation
        // is gone, over a loop that keeps asking it for updates, is the contradiction
        // this whole change exists to remove.
        XCTAssertFalse(shouldContinue, "a deleted session does not come back under the same id -- retrying it is unbounded and cannot succeed")
        XCTAssertEqual(vm.phase, .notFound)
        XCTAssertEqual(unauthorizedCallCount, 0, "a 404 is not an auth problem and must not eject to Key entry")
    }

    /// Negative control for the pair above: `false` is not simply what every non-
    /// `.readable` kind returns. `.unreachable` -- the value a `SESSION_NOT_FOUND`
    /// used to arrive as -- keeps the loop running, which is correct for it and was
    /// the bug for the 404. If this ever returns `false` too, the test above stops
    /// distinguishing anything.
    func testUnreachableStepKeepsTheDriveLoopRunningUnlikeSessionNotFound() async {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [], truncated: false))]
        let vm = makeViewModel(client: client)
        await vm.load()

        let shouldContinue = vm.applyPollStep(PollLoop.StepResult(kind: .unreachable, nextWaitMs: 20_000, localBackoffMs: 1_000))

        XCTAssertTrue(shouldContinue, "a transport failure can heal on the next attempt -- that loop must not stop")
        XCTAssertEqual(vm.phase, .loaded, "and it must not tear the loaded screen down either")
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
    ///
    /// `initialHistory` / `thenHistory` exist for DESIGN §2.52: the phone now issues a
    /// SECOND `/history` of its own after an unknown-result action, so a fixture that
    /// can only answer the first one no longer describes the whole path. `thenHistory`
    /// is what that re-read gets, in order.
    ///
    /// Leaving `thenHistory` empty is not a neutral default -- `RecordingClient`
    /// answers an exhausted queue with `.unreachable` -- so a test that does not name
    /// it is describing "the re-read could not be made", which is a real case and the
    /// one the pre-§2.52 tests were already implicitly in.
    private func loadedViewModel(
        screen screenValue: String?,
        sendClient: MessageSending = UnusedSendClient(),
        interruptClient: Interrupting = UnusedInterruptClient(),
        choiceClient: ChoiceSending = UnusedChoiceClient(),
        choiceJSON: String? = nil,
        initialHistory: [HistoryEntry] = [],
        thenHistory: [Result<HistoryResponse, SessionsFetchError>] = [],
        draftStore: DraftStoring = InMemoryDraftStore()
    ) async throws -> ConversationViewModel {
        let client = RecordingClient()
        client.resultQueue =
            [.success(HistoryResponse(history: initialHistory, truncated: false))] + thenHistory
        let vm = makeViewModel(
            client: client,
            sendClient: sendClient,
            interruptClient: interruptClient,
            choiceClient: choiceClient,
            draftStore: draftStore
        )
        await vm.load()
        if let screenValue {
            // `choiceJSON` rides in on the same step rather than a second one on
            // purpose: the server emits `screen` and `display.choice` from one capture,
            // and a fixture that delivered them separately would let a bug through in
            // which the two disagree for one poll.
            let display = choiceJSON.map { ", \"display\": { \"choice\": \($0) }" } ?? ""
            vm.applyPollStep(try readableStep("""
            { "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "\(screenValue)", "work": "quiet", "windowMs": 0 }\(display), "cursor": "t.a.1.0", "more": false }
            """))
        }
        return vm
    }

    /// A benign 2-option menu with both digit keys offered -- the shape `choice.mjs`
    /// emits when `classifyChoice` matched its allowlist.
    private func benignChoiceJSON(digest: String = "d-aaa") -> String {
        """
        {
          "show": true, "reason": "", "digest": "\(digest)",
          "head": ["Do you want to proceed?"],
          "options": [{ "n": 1, "label": "Yes" }, { "n": 2, "label": "No" }],
          "buttons": [{ "key": "1", "label": "1. Yes" }, { "key": "2", "label": "2. No" }]
        }
        """
    }

    /// A permission / trust prompt: `show` is true and the menu text is present, but
    /// `buttons` is empty and `reason` carries `view.mjs`'s `CHOICE_BLOCKED["hard-stop"]`.
    /// This is the shape 「自動化に安全確認を押させない」 reduces to on the wire.
    private func hardStopChoiceJSON(digest: String = "d-stop") -> String {
        """
        {
          "show": true, "digest": "\(digest)",
          "reason": "これは許可・信頼の確認画面です。電話からは操作を出しません(自動化に安全確認を押させない、という決め事)。机で確認してください。",
          "head": ["Claude requests permission to run:"],
          "options": [{ "n": 1, "label": "Yes" }, { "n": 2, "label": "Yes, and don't ask again" }, { "n": 3, "label": "No" }],
          "buttons": []
        }
        """
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

    /// Sprint 6 rewrote the second half of this assertion. Sprint 5 pinned the literal
    /// string, which ended 「…机で確認するか、割り込みで中断してください」 -- a promise
    /// about the interrupt button. Once `interruptAllowedOnChoiceScreen` exists, that
    /// sentence is only true on one side of it, so the test now asserts the RELATION
    /// (the sentence matches the switch) instead of one of the two strings. See
    /// `testTheChoiceSentenceAndTheChoiceButtonMoveTogetherNegativeControl` for the
    /// control that makes this relation load-bearing.
    /// The no-card fallback: the screen is a menu but no `display.choice` arrived. This
    /// is Sprint 6's sentence, kept verbatim including its dependence on
    /// `interruptAllowedOnChoiceScreen`, because with no card to point at the interrupt
    /// button is the only other thing the user could be told about.
    func testComposerIsDisabledOnCHOICEWithTheSpecsFixedWording() async throws {
        let vm = try await loadedViewModel(screen: "CHOICE")

        XCTAssertFalse(vm.composerEnabled)
        XCTAssertNil(vm.choiceView, "precondition: this row is the *no card* case")
        XCTAssertEqual(
            vm.composerDisabledReason,
            ConversationViewModel.interruptAllowedOnChoiceScreen
                ? "選択待ちです。文字は送れません。机で確認するか、割り込みで中断してください"
                : "選択待ちです。文字は送れません。机で確認してください"
        )
    }

    /// ★★The control on the sentence that Sprint 6 shipped and Sprint 7 had to change.
    ///
    /// 「v1 では電話から選べません」 was true when the phone could not select. The moment
    /// a pressable card ships, that exact sentence sits directly above a row of buttons
    /// that select -- the app calling itself a liar in two adjacent views. What is
    /// asserted is therefore the RELATION rather than a literal: whenever the card can
    /// be pressed, the sentence must not claim otherwise.
    func testTheComposerSentenceNeverClaimsSelectionIsImpossibleWhileTheCardIsPressable() async throws {
        let vm = try await loadedViewModel(screen: "CHOICE", choiceJSON: benignChoiceJSON())

        XCTAssertTrue(vm.choiceEnabled, "precondition: the card is pressable")
        XCTAssertFalse(vm.composerEnabled, "the composer is still disabled -- only the card acts")
        let sentence = try XCTUnwrap(vm.composerDisabledReason)
        XCTAssertFalse(
            sentence.contains("選べません"),
            "the sentence must not deny a capability the card right below it provides"
        )
        XCTAssertTrue(sentence.contains("下の選択肢"), "it must point at the card instead")

        // Not vacuous: Sprint 6's sentence really does contain the substring this
        // asserts is absent, so a revert to it fails here.
        XCTAssertTrue("v1 では電話から選べません。机で確認してください".contains("選べません"))
    }

    /// The hard-stop row: same screen classification, same `show: true`, but the server
    /// sent no keys. The sentence must point at the card (which carries the server's own
    /// refusal) rather than paraphrase it up here where it could drift.
    func testTheComposerSentencePointsAtTheCardWhenTheServerOfferedNoKeys() async throws {
        let vm = try await loadedViewModel(screen: "CHOICE", choiceJSON: hardStopChoiceJSON())

        XCTAssertFalse(vm.choiceEnabled)
        let sentence = try XCTUnwrap(vm.composerDisabledReason)
        XCTAssertTrue(sentence.contains("理由は下に出しています"))
        XCTAssertFalse(
            sentence.contains(" 机で確認してください"),
            "the desk instruction belongs to the server's `reason`, which the card renders verbatim"
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

    /// ★S8-8。`composerEnabled` は `isSending` を見ていないので、飛んでいる 30 秒の間
    /// composer は生きていて打ち足せる。そこで全部消すと、**送っていない物**が消える。
    ///
    /// 見付けたのは検査ではなく S8-7 で撮った1枚 —— 送信中の画面に本文が残って写って
    /// いて、そこから「では此の間に打ったらどうなるか」が出た。`InFlightUITests` は
    /// 撮るだけで此処は測れない(作り物の送信は 60 秒返らないので分類まで行かない)。
    func testTypingDuringAnInFlightSendIsNotClearedBySuccess() async throws {
        let sender = RecordingSendClient()
        sender.deliveryDelay = .milliseconds(200)
        sender.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "送った", keepText: false))]
        let vm = try await loadedViewModel(screen: "SENDABLE", sendClient: sender)
        vm.draft = "送る分"

        let sending = Task { await vm.send() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(vm.isSending, "前提: 本当に飛んでいる最中で打っている")
        vm.draft = "送る分まだ送っていない分"

        await sending.value

        XCTAssertEqual(sender.sentTexts, ["送る分"], "送ったのは押した時点の本文だけ")
        XCTAssertEqual(
            vm.draft, "まだ送っていない分",
            "keepText:false が消してよいのは送った分だけ。打ち足した分は一度も飛んでいない"
        )
    }

    /// 対照。前置きが一致しない = 飛んでいる間に**途中**を書き換えた場合で、
    /// 送った分がどれか言えない。此処で消しに行くと消し過ぎる側へ倒れるので何もしない。
    /// (消し損ねは画面に見えて手で消せる。同じ非対称を `clearSentText` が持っている)
    func testEditingTheMiddleDuringAnInFlightSendClearsNothing() async throws {
        let sender = RecordingSendClient()
        sender.deliveryDelay = .milliseconds(200)
        sender.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "送った", keepText: false))]
        let vm = try await loadedViewModel(screen: "SENDABLE", sendClient: sender)
        vm.draft = "送る分"

        let sending = Task { await vm.send() }
        try? await Task.sleep(for: .milliseconds(50))
        vm.draft = "書き直した分"

        await sending.value

        XCTAssertEqual(vm.draft, "書き直した分", "前置きが一致しないなら消さない")
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
        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "前回の結果", keepText: true)), sentText: "")
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

        vm.applySendOutcome(.display(display), sentText: "")

        XCTAssertEqual(vm.sendBanner?.text, display.text, "no suffix, no rewording, nothing appended")
        XCTAssertEqual(vm.sendBanner?.tone, .warn)
        XCTAssertEqual(vm.sendBanner?.fromServer, true)
    }

    /// ★Provenance is the assertion, not just the string. A regression that replaced
    /// the server's sentence with a locally-composed one of the same meaning would pass
    /// any "some text is shown" check; this is the one that catches it.
    func testPhoneWordedBannersAreMarkedAsNotComingFromTheServerNegativeControl() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: false)), sentText: "")
        let fromServer = vm.sendBanner
        vm.applySendOutcome(.unreachable, sentText: "")
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
            vm.applySendOutcome(.display(ResultDisplay(kind: kind, text: "t", keepText: true)), sentText: "")
            XCTAssertEqual(vm.sendBanner?.tone, expected, kind)
        }
    }

    // MARK: §2 step 5 -- keepText, read as a field

    func testKeepTextFalseClearsTheDraft() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"

        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: false)), sentText: "書いた")

        XCTAssertEqual(vm.draft, "")
    }

    func testKeepTextTrueKeepsTheDraft() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"

        vm.applySendOutcome(.display(ResultDisplay(kind: "refused", text: "今は入れられません", keepText: true)), sentText: "")

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

        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: nil)), sentText: "")

        XCTAssertEqual(vm.draft, "書いた", "absent keepText is not read as false")
    }

    /// `keepText` must be read as the field it is. Today `keepText:false` occurs on
    /// exactly one branch (`kind:"ok"`), so `kind == "ok"` would be green right now and
    /// silently wrong the day the server adds a second -- this pair of rows is what
    /// separates the two implementations.
    func testClearingFollowsKeepTextNotKindNegativeControl() async throws {
        let okKeeping = try await loadedViewModel(screen: "SENDABLE")
        okKeeping.draft = "書いた"
        okKeeping.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "t", keepText: true)), sentText: "")

        let errorClearing = try await loadedViewModel(screen: "SENDABLE")
        errorClearing.draft = "書いた"
        errorClearing.applySendOutcome(.display(ResultDisplay(kind: "error", text: "t", keepText: false)), sentText: "書いた")

        XCTAssertEqual(okKeeping.draft, "書いた", #"kind:"ok" with keepText:true must KEEP"#)
        XCTAssertEqual(errorClearing.draft, "", #"kind:"error" with keepText:false must CLEAR"#)
    }

    // MARK: The non-display outcomes

    func testUnreachableKeepsTheDraftAndRefusesToClaimEitherOutcome() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"

        vm.applySendOutcome(.unreachable, sentText: "")

        XCTAssertEqual(vm.draft, "書いた")
        XCTAssertEqual(vm.sendBanner?.tone, .warn)
        XCTAssertEqual(
            vm.sendBanner?.text,
            ConversationViewModel.sendUnknownInterim,
            "★これは答えではなく途中経過(DESIGN §2.52)。この method だけを叩いた時に見えるのはここまでで、"
                + "観測で置き換えるのは send() の側。文言と戻り値が同じ義務を指している。"
        )
        guard case .loaded = vm.phase else { return XCTFail("a transport failure must not tear the screen down") }
    }

    // MARK: - DESIGN §2.52: 結果が分からない時、電話が自分で机を読み直す
    //
    // 落とした一文は「机の画面を確認してください」だった。あの命令が出る条件は
    // 「電話しか手元に無い」で、渡米中はその条件が常に成立する —— 唯一の回復手段
    // として、構造的に実行できない事を指示していた。
    //
    // 置き換え先は**観測**であって推測ではない。だからどの本も、答えの文言ではなく
    // 「電話が何を見たか」を固定している。
    //
    // 数を書かないのは、この一覧が増えた実績が在るから(4本 → 7本)。代わりに条件で
    // 書く: **誤実装を1本ずつ名指しで落とす対照が要る**。実際に測った3つの誤実装と、
    // それを落とす対照は下の通り。
    //
    // | 誤実装 | 落とす対照 |
    // |---|---|
    // | 取り直した履歴に同じ本文が在る事**だけ**を見る | ④(負の対照)と⑦(重なり無し) |
    // | 差分を**件数の差**で書く | ⑥(窓ずれ)と⑦(重なり無し) |
    // | 「見分けられない」を「出ていません」へ潰す | ⑦だけ |
    //
    // ★上2つは、一度も落ちず単体検査も緑のまま、答えだけが常に当たりに見える型。
    // 3つ目は緑のまま**再送を勧める** = 二重配達を作る型。対照が無ければ全部通る。

    private func sendUnknownViewModel(
        initialHistory: [HistoryEntry] = [],
        thenHistory: [Result<HistoryResponse, SessionsFetchError>],
        draftStore: DraftStoring = InMemoryDraftStore()
    ) async throws -> (ConversationViewModel, RecordingSendClient) {
        let sendClient = RecordingSendClient()
        // `.unreachable` を代表に選ぶのは、結果不明の2つ(`.unreachable` /
        // `.contractViolation`)のうち渡米中に実際に起きる方だから。分岐は
        // `applySendOutcome` の戻り値で1本に合流しており、そこは既存の検査が持つ。
        sendClient.outcomeQueue = [.unreachable]
        let vm = try await loadedViewModel(
            screen: "SENDABLE",
            sendClient: sendClient,
            initialHistory: initialHistory,
            thenHistory: thenHistory,
            draftStore: draftStore
        )
        return (vm, sendClient)
    }

    /// ① 送れていた。電話は取り直した机にそれを見つけ、そう言う。
    func testAnUnknownSendIsAnsweredByWhatThePhoneSeesOnTheDeskAfterRereading() async throws {
        let (vm, sendClient) = try await sendUnknownViewModel(
            thenHistory: [.success(HistoryResponse(history: [e(.user, "止めて")], truncated: false))]
        )
        vm.draft = "止めて"

        await vm.send()

        XCTAssertEqual(sendClient.sentTexts, ["止めて"])
        XCTAssertEqual(vm.sendBanner?.text, ConversationViewModel.sendLandedText)
        XCTAssertEqual(vm.sendBanner?.tone, .ok)
        XCTAssertEqual(vm.sendBanner?.fromServer, false, "server は何も言えなかった。此処の文は電話自身の観測")
        XCTAssertEqual(vm.draft, "止めて", "★届いていても消さない。消して外した時だけ本文が失われる(非対称)")
        XCTAssertFalse(vm.isVerifyingSend, "取り直しは終わっている")
    }

    /// ② 今の机には出ていない。**「届いていません」とは言わない** —— 机側でまだ
    /// 処理中の可能性は取り直しでは消えないので、言えるのは見た物までとする。
    func testAnUnknownSendReportsOnlyWhatTheDeskShowsWhenTheTextIsNotThere() async throws {
        let (vm, _) = try await sendUnknownViewModel(
            thenHistory: [.success(HistoryResponse(history: [e(.assistant, "別の話")], truncated: false))]
        )
        vm.draft = "止めて"

        await vm.send()

        XCTAssertEqual(vm.sendBanner?.text, ConversationViewModel.sendNotOnDeskText)
        XCTAssertEqual(vm.sendBanner?.tone, .warn)
        XCTAssertFalse(
            try XCTUnwrap(vm.sendBanner?.text).contains("届いていません"),
            "★取り直して見えなかっただけで、届いていない事の証明にはならない"
        )
        XCTAssertEqual(vm.draft, "止めて", "もう一度送れる状態で返す")
    }

    /// ③ 取り直しそのものが通らなかった。此処だけは何も観測できていないので、
    /// 送信の可否について一切主張しない。
    func testAnUnknownSendSaysTheRereadItselfFailedRatherThanGuessing() async throws {
        let (vm, _) = try await sendUnknownViewModel(thenHistory: [.failure(.unreachable)])
        vm.draft = "止めて"

        await vm.send()

        XCTAssertEqual(vm.sendBanner?.text, ConversationViewModel.sendStillUnreachableText)
        XCTAssertEqual(vm.sendBanner?.tone, .warn)
        XCTAssertEqual(vm.draft, "止めて")
        XCTAssertFalse(vm.isVerifyingSend, "失敗しても錠は外す。外さないと二度と送れない")
    }

    /// ★④ 負の対照。**送る前から同じ本文が机に在る会話**。
    ///
    /// 取り直した履歴には確かに「止めて」の user 行が在る —— 但しそれは1通目で、
    /// 今回送った物ではない。存在で見る実装はここで「届いていました」と言い、
    /// Tom は届いていない指示を届いたと信じる。差分で見る実装だけが通る。
    func testAnUnknownSendDoesNotClaimDeliveryFromAnIdenticalOlderMessageNegativeControl() async throws {
        let alreadyThere = [e(.user, "止めて"), e(.assistant, "了解")]
        let (vm, _) = try await sendUnknownViewModel(
            initialHistory: alreadyThere,
            // 取り直しても増えた区間は空 = 2通目は机に無い。
            thenHistory: [.success(HistoryResponse(history: alreadyThere, truncated: false))]
        )
        vm.draft = "止めて"

        await vm.send()

        XCTAssertEqual(
            vm.sendBanner?.text,
            ConversationViewModel.sendNotOnDeskText,
            "★同じ本文が過去に在るだけで「届いた」と読む実装を落とす(実測: 変異①で⑦と共に赤)"
        )
        XCTAssertNotEqual(vm.sendBanner?.text, ConversationViewModel.sendLandedText)
    }

    /// ★⑥ 窓がずれた時。**「件数の差」で書いた実装を落とす**(実測: 変異②で⑦と共に赤)。
    ///
    /// 両方の履歴は同じ `limit` で取った**末尾の窓**なので、机が1行進めば窓は前から
    /// 1行こぼれる。ここでは送る前の一番古い行が、たまたま同じ本文の `user` 行だった:
    /// 取り直すとそれが窓から落ち、代わりに今送った物が末尾に付く。件数は 1 → 1 で
    /// 動かない。
    ///
    /// 件数で見る実装はここで「今の机には出ていません」と言う —— **届いているのに**。
    /// それは Tom に再送を勧める向きで、`POST /messages` に冪等鍵は無いので二重配達に
    /// なる。増えた区間(重なりの外側)で見る実装だけが通る。
    func testALandedMessageIsStillSeenWhenTheOldestEntryFellOutOfTheWindow() async throws {
        let oldest = e(.user, "止めて")
        let middle = [e(.assistant, "1"), e(.assistant, "2")]
        let (vm, _) = try await sendUnknownViewModel(
            initialHistory: [oldest] + middle,
            // 先頭が1行こぼれ、末尾に今回の送信が付いた。件数は増えていない。
            thenHistory: [.success(HistoryResponse(history: middle + [e(.user, "止めて")], truncated: true))]
        )
        vm.draft = "止めて"

        await vm.send()

        XCTAssertEqual(
            vm.sendBanner?.text,
            ConversationViewModel.sendLandedText,
            "★窓がずれても、重なりの外側に在る物は新しく来た物"
        )
    }

    /// ⑦ 重なりが1つも見付からない = 送信と取り直しの間に窓1枚分が丸ごと流れた
    /// (机側の圧縮や `/clear` は記録を丸ごと入れ替えるので、これは机上の空論ではない)。
    /// 境目が分からないので `after` 全体を見るしかなくなるが、そこには過去の同じ本文が
    /// 居るかもしれない。**見当を失った時は主張しない**方に倒す。
    ///
    /// ★答えは3つ目の専用文で、「今の机には出ていません」ではない。あの文は
    /// 「机に無い」と断言した上に「もう一度送れます」で再送 = 二重配達を勧める。
    /// 電話は境目を見失っていて、在るとも無いとも言えない —— ここで潰すのは、この節が
    /// 直している「電話が机の状態を語る」誤りそのものを、当ての中で再演する事になる。
    func testNoClaimIsMadeWhenThePhoneCannotLocateWhereTheNewEntriesBegin() async throws {
        let (vm, _) = try await sendUnknownViewModel(
            initialHistory: [e(.user, "古い話"), e(.assistant, "古い返事")],
            // 一行も重ならない。中に「止めて」は在るが、それが今回の物である保証は無い。
            thenHistory: [.success(HistoryResponse(
                history: [e(.user, "止めて"), e(.assistant, "全く別の区間")], truncated: true
            ))]
        )
        vm.draft = "止めて"

        await vm.send()

        XCTAssertEqual(
            vm.sendBanner?.text,
            ConversationViewModel.sendCannotTellText,
            "★一致行は在るが、それが今回の配達だとは言えない"
        )
        XCTAssertNotEqual(
            vm.sendBanner?.text,
            ConversationViewModel.sendNotOnDeskText,
            "★「分からない」を「無い」へ潰すと、再送 = 二重配達を勧める向きに出る"
        )
        XCTAssertNotEqual(vm.sendBanner?.text, ConversationViewModel.sendLandedText)
        XCTAssertEqual(vm.draft, "止めて", "本文はどちらに転んでも消さない")
    }

    /// ⑤ ④の裏返し。同じ本文を意図して2回送るのは正当な操作。増えた区間の中に在れば
    /// 2通目も「届いた」になる。`after` 全体への存在の真偽で見る実装は、④で落ちる。
    func testASecondIdenticalMessageIsSeenAsLandedWhenItArrivesInTheNewRegion() async throws {
        let before = [e(.user, "止めて")]
        let (vm, _) = try await sendUnknownViewModel(
            initialHistory: before,
            thenHistory: [.success(HistoryResponse(history: before + [e(.user, "止めて")], truncated: false))]
        )
        vm.draft = "止めて"

        await vm.send()

        XCTAssertEqual(vm.sendBanner?.text, ConversationViewModel.sendLandedText)
    }

    func testCancelledChangesNothingAtAll() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"
        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "前回", keepText: true)), sentText: "")
        let bannerBefore = vm.sendBanner

        vm.applySendOutcome(.cancelled, sentText: "")

        XCTAssertFalse(vm.isSending, "the in-flight flag still has to come down")
        XCTAssertEqual(vm.draft, "書いた")
        XCTAssertEqual(vm.sendBanner, bannerBefore, "whoever cancelled owns the outcome -- no banner of our own")
    }

    func testUnauthorizedRoutesOutAndKeepsWhatTheUserTyped() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"

        vm.applySendOutcome(.unauthorized, sentText: "")

        XCTAssertEqual(unauthorizedCallCount, 1)
        XCTAssertEqual(vm.draft, "書いた", "the user is about to make a round trip to Key-entry and back")
        XCTAssertNil(vm.sendBanner)
    }

    func testSessionNotFoundOnSendTearsTheScreenDown() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        vm.applySendOutcome(.sessionNotFound, sentText: "")

        XCTAssertEqual(vm.phase, .notFound)
    }

    // MARK: Contract violations -- the same fact, two different screen consequences

    func testContractViolationOnSendIsABannerOverAnIntactScreen() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.draft = "書いた"
        let violation = ResponseContractViolation(status: 202, code: nil)

        vm.applySendOutcome(.contractViolation(violation), sentText: "")

        guard case .loaded = vm.phase else {
            return XCTFail("the conversation and its poll loop must survive: this is the one view that can tell the user what happened")
        }
        XCTAssertEqual(vm.sendBanner?.text, violation.displayText + ConversationViewModel.sendUnknownInterim)
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
        onSend.applySendOutcome(.contractViolation(violation), sentText: "")

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

    // MARK: - Sprint 6 §2-b: the interrupt button -- when it is live
    //
    // Split from the composer's table on purpose. The two tables are NOT the same
    // table with a different name: they agree on SENDABLE and BUSY and disagree on
    // UNKNOWN, and the reason is the asymmetry between the two operations. Putting new
    // text into a screen nobody can read is a gamble; cancelling is not, and an
    // unreadable screen is precisely the state in which being unable to stop the desk
    // is worst.

    func testInterruptIsEnabledBeforeAnyScreenHasBeenObserved() async throws {
        let vm = try await loadedViewModel(screen: nil)

        XCTAssertNil(vm.screen)
        XCTAssertTrue(vm.interruptEnabled)
        XCTAssertNil(vm.interruptDisabledReason)
    }

    func testInterruptIsEnabledOnSENDABLE() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        XCTAssertTrue(vm.interruptEnabled)
        XCTAssertNil(vm.interruptDisabledReason)
    }

    /// ★Tom's own ruling on this app -- 「返答待ちであれ作業中であれいつでも見て、干渉
    /// できればいいんじゃないかな？」. `BUSY` is the state the interrupt button exists
    /// FOR, so a gate on it would be the one gate guaranteed to be wrong. Asserted as
    /// its own named case so that a later "tidy-up" that gates on observed generation
    /// has to delete a test that says why.
    func testInterruptStaysEnabledOnBUSY() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")

        XCTAssertEqual(vm.screen?.classification, .busy)
        XCTAssertTrue(vm.interruptEnabled)
        XCTAssertNil(vm.interruptDisabledReason)
    }

    /// ★The row where this table and the composer's disagree. `UNKNOWN` disables the
    /// composer and must NOT disable the interrupt button.
    func testInterruptStaysEnabledOnUNKNOWNEvenThoughTheComposerDoesNot() async throws {
        let vm = try await loadedViewModel(screen: "UNKNOWN")

        XCTAssertFalse(vm.composerEnabled, "precondition: this is the row the composer refuses")
        XCTAssertTrue(vm.interruptEnabled, "interrupting only ever cancels -- there is nothing to gamble")
        XCTAssertNil(vm.interruptDisabledReason)
    }

    func testAnUnrecognizedClassificationLeavesTheInterruptButtonEnabled() async throws {
        let vm = try await loadedViewModel(screen: "SOME_FUTURE_STATE")

        XCTAssertEqual(vm.screen?.classification, .unrecognized)
        XCTAssertTrue(vm.interruptEnabled, "an unknown value must not silently remove a capability")
    }

    /// The gated row, asserted against the named constant rather than against `false`.
    /// Pinning `false` here would mean flipping `interruptAllowedOnChoiceScreen` (the
    /// whole of the change if Tom re-defines D4 as 「承認は禁止、明示的な拒否は可」)
    /// turns a deliberate decision into a red suite.
    func testInterruptOnCHOICEFollowsTheNamedConstant() async throws {
        let vm = try await loadedViewModel(screen: "CHOICE")

        XCTAssertEqual(vm.interruptEnabled, ConversationViewModel.interruptAllowedOnChoiceScreen)
        XCTAssertEqual(
            vm.interruptDisabledReason,
            ConversationViewModel.interruptAllowedOnChoiceScreen
                ? nil
                : "確認待ちの画面では、v1 は電話から中断しません。机で確認してください"
        )
    }

    /// ★★The control named by `testComposerIsDisabledOnCHOICEWithTheSpecsFixedWording`,
    /// and the reason `interruptAllowedOnChoiceScreen` is a constant with two readers
    /// instead of an inline `return false`.
    ///
    /// Sprint 5 shipped the CHOICE composer sentence ending 「…机で確認するか、割り込みで
    /// 中断してください」 -- a promise about a button. If the button is not live on
    /// CHOICE, that sentence tells the user to press something that does nothing; if
    /// the button IS live and the sentence has been shortened, the app hides its own
    /// only remaining action. Either half moving alone is a lie, so what is asserted is
    /// the RELATION, in whichever position the constant is in.
    func testTheChoiceSentenceAndTheChoiceButtonMoveTogetherNegativeControl() async throws {
        let vm = try await loadedViewModel(screen: "CHOICE")

        let sentencePromisesTheButton = vm.composerDisabledReason?.contains("割り込み") ?? false
        XCTAssertEqual(
            sentencePromisesTheButton,
            vm.interruptEnabled,
            "the sentence and the button it points at must not be able to disagree"
        )

        // …and the relation is not vacuous: the two candidate sentences really do
        // differ on that substring, so the assertion above can fail.
        XCTAssertNotEqual(
            "選択待ちです。文字は送れません。机で確認するか、割り込みで中断してください".contains("割り込み"),
            "選択待ちです。文字は送れません。机で確認してください".contains("割り込み")
        )
    }

    // MARK: - Sprint 7: answering the menu from the phone

    /// ★★The defect a screenshot caught and 397 passing assertions did not.
    ///
    /// With a card offering `escape`, the screen showed 「v1 は電話から中断しません」 and
    /// a 「中止(Escape)」 button about 40 points apart. Each half was individually
    /// correct -- the interrupt path really is blocked, and that Escape really is
    /// allowlisted -- and every test passed, because each rule was checked against its
    /// own sentence and nothing checked the PAIR. So the pair is what is asserted here:
    /// while a stop key is on offer, no sentence on screen may say stopping is
    /// impossible.
    func testNoSentenceDeniesStoppingWhileTheCardOffersAStopKey() async throws {
        let withEscape = """
        {
          "show": true, "reason": "", "digest": "d-esc",
          "head": ["この変更を適用しますか？"],
          "options": [{ "n": 1, "label": "はい" }],
          "buttons": [{ "key": "1", "label": "1. はい" }, { "key": "escape", "label": "中止(Escape)" }]
        }
        """
        let vm = try await loadedViewModel(screen: "CHOICE", choiceJSON: withEscape)

        XCTAssertFalse(vm.interruptEnabled, "the interrupt PATH stays blocked -- that part is unchanged")
        let sentence = try XCTUnwrap(vm.interruptDisabledReason)
        XCTAssertFalse(
            sentence.contains("中断しません。"),
            "a flat 「中断しません」 above a 中止 button makes the app contradict itself"
        )
        XCTAssertTrue(sentence.contains("下の選択肢"), "it must send the user to the key that does work")

        // Not vacuous: the sentence shown when no stop key is on offer really does make
        // the flat claim, so this assertion can fail.
        let noEscape = try await loadedViewModel(screen: "CHOICE", choiceJSON: hardStopChoiceJSON())
        XCTAssertEqual(
            noEscape.interruptDisabledReason,
            "確認待ちの画面では、v1 は電話から中断しません。机で確認してください"
        )
    }

    /// ★★★**The safety control of this whole sprint.** A permission or trust prompt
    /// reaches the phone as a perfectly ordinary `CHOICE` with `show: true` and three
    /// numbered options -- it looks exactly like the benign menu two tests above. The
    /// only difference is that `buttons` is empty, because `classifyChoice` did not
    /// match it against the allowlist.
    ///
    /// So this asserts the property 「自動化に安全確認を押させない」 reduces to on this
    /// side of the wire: no key exists to press, and the attempt is refused even when
    /// something calls `choose` directly with a key it read off the options list. The
    /// `UnusedChoiceClient` default is what makes the second half real -- if the refusal
    /// were removed, the stub fires and this fails.
    func testAHardStopScreenOffersNoKeysAndCannotBePressedEvenByADirectCall() async throws {
        let vm = try await loadedViewModel(screen: "CHOICE", choiceJSON: hardStopChoiceJSON())

        let card = try XCTUnwrap(vm.choiceView)
        XCTAssertTrue(card.show, "the menu is still SHOWN -- hiding it would hide the desk's question")
        XCTAssertEqual(card.options.count, 3, "…including every option, so the user can read what is being asked")
        XCTAssertTrue(card.buttons.isEmpty)
        XCTAssertFalse(card.canPress)
        XCTAssertFalse(vm.choiceEnabled)
        XCTAssertTrue(card.reason.contains("許可・信頼"), "the server's own words, rendered verbatim")

        // The direct call: a key the user can plainly see in `options`, pressed anyway.
        await vm.choose(key: "1")
        XCTAssertNil(vm.choiceBanner, "nothing was attempted, so there is nothing to report")
    }

    /// The happy path, and what it checks is not "a request went out" but **which two
    /// values went out**. Both must be echoes of what the server handed the phone: a
    /// `key` from `buttons`, and the `digest` that arrived on the same card. A phone
    /// that derived either would still produce a request, and would still pass a
    /// call-count assertion.
    func testChoosingSendsBackExactlyTheKeyAndFingerprintTheServerHandedUs() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [
            ChoiceAttempt(
                outcome: .display(ResultDisplay(kind: "ok", text: "送りました", keepText: nil)),
                serverDigest: nil
            )
        ]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON(digest: "d-aaa")
        )

        await vm.choose(key: "2")

        XCTAssertEqual(choiceClient.callCount, 1)
        XCTAssertEqual(choiceClient.calls.first?.key, "2")
        XCTAssertEqual(choiceClient.calls.first?.digest, "d-aaa")
        XCTAssertEqual(vm.choiceBanner?.text, "送りました")
        XCTAssertEqual(vm.choiceBanner?.fromServer, true, "the server's sentence, not ours")
        XCTAssertNil(vm.staleChoiceDigest, "a 200 that named no fingerprint says nothing about staleness")
        XCTAssertFalse(vm.isChoosing)
    }

    /// A key that is not in `buttons` is refused before any request. Unreachable through
    /// the UI today -- every button is drawn from `buttons` -- which is exactly why it
    /// is asserted: the day a second caller appears, the failure this prevents is an
    /// unoffered keystroke reaching a prompt the server declined to expose.
    func testAKeyTheServerDidNotOfferIsNeverSent() async throws {
        // `UnusedChoiceClient` (the default) IS the assertion here.
        let vm = try await loadedViewModel(screen: "CHOICE", choiceJSON: benignChoiceJSON())

        await vm.choose(key: "3")
        await vm.choose(key: "escape")

        XCTAssertNil(vm.choiceBanner)
    }

    /// ★A 409 whose body names a DIFFERENT fingerprint means the desk moved between the
    /// draw and the tap. Two things must follow, and the second is the one worth having
    /// a test for: the card goes dead, **and the phone does not press again**.
    ///
    /// The server attaches the live fingerprint to that refusal precisely so a client
    /// could retry without re-capturing the screen -- so the obvious use of it is the
    /// one thing forbidden. Re-sending would mean answering a menu Tom has never seen.
    func testAMovedFingerprintKillsTheCardAndIsNeverAutoRetried() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [
            ChoiceAttempt(
                outcome: .display(ResultDisplay(kind: "refused", text: "画面が変わりました", keepText: nil)),
                serverDigest: "d-bbb"
            )
        ]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON(digest: "d-aaa")
        )

        await vm.choose(key: "1")

        XCTAssertEqual(choiceClient.callCount, 1, "★no auto-retry: exactly one request left the phone")
        XCTAssertEqual(vm.staleChoiceDigest, "d-aaa")
        XCTAssertFalse(vm.choiceEnabled, "the card the user is looking at is the stale one")
        XCTAssertEqual(vm.staleChoiceReason, "机の画面が変わりました。新しい選択肢が届くまで押せません")
        XCTAssertEqual(vm.choiceBanner?.text, "画面が変わりました")

        // And it stays dead to a second deliberate tap, rather than going out again
        // against a fingerprint we already know is gone.
        await vm.choose(key: "1")
        XCTAssertEqual(choiceClient.callCount, 1)
    }

    /// The recovery half of the test above: staleness expires when the poll delivers a
    /// card. Here the fingerprint also differs, so the banner is dropped alongside it --
    /// two effects on one signal, which the next two tests pull apart, because they
    /// answer different questions and expire on different evidence.
    func testANewFingerprintFromThePollRevivesTheCardAndDropsTheOldBanner() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [
            ChoiceAttempt(
                outcome: .display(ResultDisplay(kind: "refused", text: "画面が変わりました", keepText: nil)),
                serverDigest: "d-bbb"
            )
        ]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON(digest: "d-aaa")
        )
        await vm.choose(key: "1")
        XCTAssertFalse(vm.choiceEnabled)

        vm.applyPollStep(try readableStep("""
        { "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "CHOICE", "work": "quiet", "windowMs": 0 },
          "display": { "choice": \(benignChoiceJSON(digest: "d-bbb")) }, "cursor": "t.a.2.0", "more": false }
        """))

        XCTAssertTrue(vm.choiceEnabled, "a different fingerprint is a different card")
        XCTAssertNil(vm.staleChoiceReason)
        XCTAssertNil(
            vm.choiceBanner,
            "★the banner answered a keystroke aimed at d-aaa; leaving it under d-bbb would attribute an old answer to a new question"
        )
    }

    /// A card that arrives again UNCHANGED must keep its banner. This is the negative
    /// control on the clearing rule above -- an implementation that cleared on every
    /// poll would pass that test and wipe the user's answer within one poll interval,
    /// which on this app is under a second.
    func testAnUnchangedFingerprintKeepsTheBannerNegativeControl() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [
            ChoiceAttempt(
                outcome: .display(ResultDisplay(kind: "ok", text: "送りました", keepText: nil)),
                serverDigest: nil
            )
        ]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON(digest: "d-aaa")
        )
        await vm.choose(key: "1")
        XCTAssertEqual(vm.choiceBanner?.text, "送りました")

        vm.applyPollStep(try readableStep("""
        { "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "CHOICE", "work": "quiet", "windowMs": 0 },
          "display": { "choice": \(benignChoiceJSON(digest: "d-aaa")) }, "cursor": "t.a.2.0", "more": false }
        """))

        XCTAssertEqual(vm.choiceBanner?.text, "送りました", "same card, same answer -- do not wipe it")
    }

    /// ★★**The A→B→A deadlock** (Codex, 2026-08-08, question (b)).
    ///
    /// The desk leaves menu A and comes back to a byte-identical A between two polls. The
    /// phone never observes B, so the fingerprint that arrives is the very one it marked
    /// stale. Under the original rule -- expire only on a CHANGED fingerprint -- the card
    /// stayed dead permanently, under a sentence (「机の画面が変わりました」) that had become
    /// false, and the only escape was the desk drawing some other menu entirely.
    ///
    /// It is safe to revive because of what the 409 actually said: `digest-mismatch` is
    /// worded 「何も送っていません」, so menu A is genuinely unanswered when it returns. And
    /// the case this does NOT cover -- a menu that really was answered -- is not this
    /// flag's job: `inject.mjs` refuses a second keystroke to a spent fingerprint and the
    /// phone renders that refusal. The flag was only ever "do not press what is not on
    /// screen"; the moment a payload says what IS on screen, it has nothing left to say.
    func testAnIdenticalMenuComingBackRevivesTheCardTheABADeadlock() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [
            ChoiceAttempt(
                outcome: .display(ResultDisplay(kind: "refused", text: "画面が変わりました", keepText: nil)),
                serverDigest: "d-bbb"
            )
        ]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON(digest: "d-aaa")
        )
        await vm.choose(key: "1")

        // 対照: 生き返る前に本当に死んでいた事。これが無いと以下は「元から押せた」で緑になる。
        XCTAssertFalse(vm.choiceEnabled, "対照: the card must be dead here, or the revival below proves nothing")
        XCTAssertEqual(vm.staleChoiceDigest, "d-aaa")

        // The desk went A -> B -> A. `server.mjs` compares its screen revision to the
        // phone's cursor, not to the phone's fingerprint, so what arrives is A again.
        vm.applyPollStep(try readableStep("""
        { "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "CHOICE", "work": "quiet", "windowMs": 0 },
          "display": { "choice": \(benignChoiceJSON(digest: "d-aaa")) }, "cursor": "t.a.2.0", "more": false }
        """))

        XCTAssertTrue(vm.choiceEnabled, "★an arriving payload is a fresh observation, identical fingerprint or not")
        XCTAssertNil(vm.staleChoiceDigest)
        XCTAssertNil(vm.staleChoiceReason, "and the sentence that had become false is gone with it")
        XCTAssertEqual(
            vm.choiceBanner?.text, "画面が変わりました",
            "the banner is NOT cleared here: same fingerprint = same question, so the answer still belongs to it"
        )

        // Alive means alive: the button goes out again, carrying the fingerprint it was
        // drawn beside. (A revival that left the card pressable-looking but inert would
        // satisfy every assertion above.)
        await vm.choose(key: "2")
        XCTAssertEqual(choiceClient.callCount, 2)
        XCTAssertEqual(choiceClient.calls.last?.key, "2")
        XCTAssertEqual(choiceClient.calls.last?.digest, "d-aaa")
    }

    /// ★**The second terminator** (Codex, 2026-08-08, question (a)).
    ///
    /// On the healthy protocol `show: false` always arrives, because `server.mjs` emits
    /// `screen` and `display.choice` under one `screenChanged` condition. This test asserts
    /// the phone does not DEPEND on that: a screen that has left `CHOICE` kills the card by
    /// itself, even when no `display` key comes with it. Menu buttons floating over a desk
    /// that moved on hours ago is the outage failure it removes.
    func testACardIsNotDrawnOverAScreenThatHasLeftTheMenu() async throws {
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: UnusedChoiceClient(), choiceJSON: benignChoiceJSON(digest: "d-aaa")
        )
        XCTAssertNotNil(vm.visibleChoice, "対照: the card is on screen before the poll below")

        // The fragile shape: the classification moved, `display` never came.
        vm.applyPollStep(try readableStep("""
        { "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "BUSY", "work": "observed", "windowMs": 0 },
          "cursor": "t.a.2.0", "more": false }
        """))

        XCTAssertNil(vm.visibleChoice, "★the desk is not on a menu; a menu card would be a lie")
        XCTAssertFalse(vm.choiceEnabled)
        XCTAssertNil(vm.staleChoiceReason, "no card, so no sentence about a card")
        // And it is not merely hidden: `UnusedChoiceClient`'s failure IS the assertion that
        // nothing goes out, since `choiceView` still holds a card with a live key.
        await vm.choose(key: "1")
    }

    /// The negative control for the gate above. Same held-over shape -- a poll with no
    /// `display` key at all -- but the screen is STILL `CHOICE`. The card must survive:
    /// `null`/absent means 据え置き (§2-c), and a gate that fired on "a poll arrived"
    /// rather than on "the classification contradicts the card" would erase the desk's
    /// question roughly once a second while Tom is reading it.
    func testAHeldOverPollDoesNotEraseTheCardWhileTheDeskIsStillOnTheMenuNegativeControl() async throws {
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: UnusedChoiceClient(), choiceJSON: benignChoiceJSON(digest: "d-aaa")
        )

        vm.applyPollStep(try readableStep("""
        { "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "CHOICE", "work": "quiet", "windowMs": 0 },
          "cursor": "t.a.2.0", "more": false }
        """))

        XCTAssertEqual(vm.visibleChoice?.digest, "d-aaa", "held over, not cleared")
        XCTAssertTrue(vm.choiceEnabled)
    }

    /// A lost response must NOT mark the card stale: we learned nothing about the desk,
    /// and marking it would strand the user with a dead card over a live menu until the
    /// next poll happens to change the fingerprint. Pressing again is safe by
    /// construction -- the second request carries the same fingerprint, which
    /// `inject.mjs` refuses as a repeat -- so the card stays live.
    func testAnUnreachableAttemptLeavesTheCardLiveAndClaimsNeitherOutcome() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [ChoiceAttempt(outcome: .unreachable, serverDigest: nil)]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON()
        )

        await vm.choose(key: "1")

        XCTAssertNil(vm.staleChoiceDigest)
        XCTAssertTrue(vm.choiceEnabled, "still pressable -- a repeat is refused server-side, a dead card is not")
        let text = try XCTUnwrap(vm.choiceBanner?.text)
        XCTAssertTrue(
            text.contains("押せたかどうかは分かりません"),
            "★どちらの結末も主張しない、が此処の全て(DESIGN §2.52 でも打鍵は「効いた」を主張しない)"
        )
        // `thenHistory` を渡していないので取り直しも届かない = 「まだ繋がりません」側。
        // 繋がらない機械に打って、その直後だけ繋がる筋書きの方が不自然。
        XCTAssertTrue(text.hasPrefix("まだ繋がりません"), "取り直しも同じ回線を通る")
        XCTAssertEqual(vm.choiceBanner?.fromServer, false)
    }

    /// 401 goes to the recovery callback, not to a banner: the phone's whole session is
    /// wrong, and reporting that as a failed keystroke would hide it.
    func testAnUnauthorizedChoiceGoesToRecoveryNotToABanner() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [ChoiceAttempt(outcome: .unauthorized, serverDigest: nil)]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON()
        )

        await vm.choose(key: "1")

        XCTAssertEqual(unauthorizedCallCount, 1)
        XCTAssertNil(vm.choiceBanner)
    }

    /// A malformed response becomes a banner over an intact screen -- same call and same
    /// reasoning as the send and interrupt paths. The conversation is loaded and the
    /// keystroke may well have landed, so tearing the screen down would be a stronger
    /// claim than the evidence supports.
    func testAContractViolationOnChoiceBecomesABannerAndIsRecorded() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [
            ChoiceAttempt(
                outcome: .contractViolation(ResponseContractViolation(status: 500, code: nil)),
                serverDigest: nil
            )
        ]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON()
        )

        await vm.choose(key: "1")

        XCTAssertEqual(vm.phase, .loaded, "the screen stays up")
        XCTAssertEqual(vm.choiceBanner?.fromServer, false)
        XCTAssertNotNil(vm.choiceBanner?.text)
    }

    /// A cancelled press writes nothing at all -- no banner, no staleness. Cancellation
    /// is the app's own doing (a screen teardown), and inventing a sentence for it would
    /// put an error in front of a user who did nothing wrong.
    func testACancelledChoiceWritesNothing() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [ChoiceAttempt(outcome: .cancelled, serverDigest: nil)]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON()
        )

        await vm.choose(key: "1")

        XCTAssertNil(vm.choiceBanner)
        XCTAssertNil(vm.staleChoiceDigest)
        XCTAssertFalse(vm.isChoosing, "the in-flight flag must clear even on the path that reports nothing")
    }

    /// The three bands stay three bands. These are the operations most likely to be
    /// fired seconds apart, and one shared slot would leave the surviving sentence
    /// unattributable to any of them.
    func testTheChoiceBannerNeverLandsInTheSendOrInterruptBand() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [
            ChoiceAttempt(
                outcome: .display(ResultDisplay(kind: "ok", text: "送りました", keepText: nil)),
                serverDigest: nil
            )
        ]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON()
        )

        await vm.choose(key: "1")

        XCTAssertEqual(vm.choiceBanner?.text, "送りました")
        XCTAssertNil(vm.sendBanner)
        XCTAssertNil(vm.interruptBanner)
    }

    /// The two enablement rules must not be one rule. If `interruptEnabled` were
    /// `composerEnabled` under another name -- the obvious "simplification" -- every
    /// row above except `UNKNOWN` would still pass.
    func testInterruptEnablementIsNotACopyOfComposerEnablementNegativeControl() async throws {
        let vm = try await loadedViewModel(screen: "UNKNOWN")

        XCTAssertNotEqual(vm.interruptEnabled, vm.composerEnabled)
    }

    // MARK: §2-b: pressing it

    /// The gate has to stop the REQUEST, not merely grey out a button -- and the
    /// assertion is written against the constant so it stays true on both sides of
    /// Tom's ruling: allowed -> exactly one call, forbidden -> exactly zero.
    func testPressingInterruptOnCHOICEFollowsTheSameConstantAsTheButton() async throws {
        let interrupter = RecordingInterruptClient()
        interrupter.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "止めました(生成が止まったのを確認)。", keepText: nil))]
        let vm = try await loadedViewModel(screen: "CHOICE", interruptClient: interrupter)

        await vm.interrupt()

        XCTAssertEqual(interrupter.callCount, ConversationViewModel.interruptAllowedOnChoiceScreen ? 1 : 0)
        XCTAssertEqual(vm.interruptBanner == nil, !ConversationViewModel.interruptAllowedOnChoiceScreen)
    }

    func testPressingInterruptOnBUSYActuallyIssuesTheRequest() async throws {
        let interrupter = RecordingInterruptClient()
        interrupter.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "止めました(生成が止まったのを確認)。", keepText: nil))]
        let vm = try await loadedViewModel(screen: "BUSY", interruptClient: interrupter)

        await vm.interrupt()

        XCTAssertEqual(interrupter.callCount, 1, "the one screen this button exists for")
        XCTAssertEqual(vm.interruptBanner?.text, "止めました(生成が止まったのを確認)。")
    }

    /// Same guard shape as `isSending`/`isFetchingEarlier`: `isInterrupting` is set
    /// synchronously before the first `await` inside this `@MainActor` method, so a
    /// second press arriving before the first suspends sees it and returns. Without
    /// this, a double tap sends two Escapes -- and the second one lands on whatever
    /// screen the first one produced.
    func testASecondPressWhileOneIsInFlightDoesNotLaunchASecondRequest() async throws {
        let interrupter = RecordingInterruptClient()
        interrupter.deliveryDelay = .milliseconds(200)
        interrupter.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "止めました(生成が止まったのを確認)。", keepText: nil))]
        let vm = try await loadedViewModel(screen: "BUSY", interruptClient: interrupter)

        let first = Task { await vm.interrupt() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(vm.isInterrupting, "precondition: we really are looking mid-flight")
        XCTAssertFalse(vm.canInterrupt, "the button is not pressable while one is in flight")

        await vm.interrupt() // the double tap
        await first.value

        XCTAssertEqual(interrupter.callCount, 1)
        XCTAssertFalse(vm.isInterrupting)
    }

    /// A new interrupt clears the previous interrupt banner before its own outcome
    /// arrives -- otherwise 「止めました」 from the last press sits under an in-flight
    /// one and reads as this press's answer.
    func testStartingAnInterruptClearsThePreviousInterruptBanner() async throws {
        let interrupter = RecordingInterruptClient()
        interrupter.deliveryDelay = .milliseconds(200)
        interrupter.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "今回", keepText: nil))]
        let vm = try await loadedViewModel(screen: "BUSY", interruptClient: interrupter)
        vm.applyInterruptOutcome(.display(ResultDisplay(kind: "ok", text: "前回の結果", keepText: nil)))
        XCTAssertNotNil(vm.interruptBanner)

        let pressing = Task { await vm.interrupt() }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(vm.interruptBanner, "a stale 「止めました」 must not be readable as this press's outcome")
        await pressing.value
    }

    // MARK: §2-b: the two bands are separate

    /// ★The reason `interruptBanner` is its own `@Published` and not a second writer of
    /// `sendBanner`. These are the two operations most likely to be fired seconds
    /// apart -- the usual reason to interrupt is "I just sent the wrong thing" -- and
    /// one shared slot would leave the surviving sentence unattributable: 「送った」
    /// replaced by 「止める対象がありませんでした。」 reads as the send having failed.
    func testAnInterruptOutcomeNeverTouchesTheSendBanner() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")
        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: false)), sentText: "")

        vm.applyInterruptOutcome(.display(ResultDisplay(kind: "warn", text: "止める対象がありませんでした。", keepText: nil)))

        XCTAssertEqual(vm.sendBanner?.text, "送った", "the send's answer survives the interrupt's")
        XCTAssertEqual(vm.interruptBanner?.text, "止める対象がありませんでした。")
    }

    func testASendOutcomeNeverTouchesTheInterruptBanner() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")
        vm.applyInterruptOutcome(.display(ResultDisplay(kind: "ok", text: "止めました(生成が止まったのを確認)。", keepText: nil)))

        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: false)), sentText: "")

        XCTAssertEqual(vm.interruptBanner?.text, "止めました(生成が止まったのを確認)。")
        XCTAssertEqual(vm.sendBanner?.text, "送った")
    }

    /// The negative control for the split: with one shared slot, two outcomes applied
    /// in either order leave only ONE readable sentence. Asserting both survive, in
    /// both orders, is what a shared slot cannot satisfy.
    func testBothBandsSurviveInEitherOrderNegativeControl() async throws {
        let sendFirst = try await loadedViewModel(screen: "BUSY")
        sendFirst.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: false)), sentText: "")
        sendFirst.applyInterruptOutcome(.display(ResultDisplay(kind: "ok", text: "止めました", keepText: nil)))

        let interruptFirst = try await loadedViewModel(screen: "BUSY")
        interruptFirst.applyInterruptOutcome(.display(ResultDisplay(kind: "ok", text: "止めました", keepText: nil)))
        interruptFirst.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送った", keepText: false)), sentText: "")

        XCTAssertEqual(sendFirst.sendBanner?.text, "送った")
        XCTAssertEqual(sendFirst.interruptBanner?.text, "止めました")
        XCTAssertEqual(interruptFirst.sendBanner?.text, "送った")
        XCTAssertEqual(interruptFirst.interruptBanner?.text, "止めました")
    }

    // MARK: §2-b: what the interrupt banner says, and who wrote it

    // not-a-port: JS の検査を名指ししているのは「あちらが見られない性質」を指す為で、移植ではない。
    // 測るのは継ぎ目の側(SendOutcome が ResultDisplay しか運ばない)なので、あちらに対応する行は無い。

    /// ★The property `rc-backend/test/view.test.mjs` cannot check from its side. All
    /// four `stopped` sentences the server writes reach the banner unchanged -- no
    /// suffix, no rewording. Note what the view model never even sees: `SendOutcome`
    /// carries a `ResultDisplay` and nothing else, so `interrupted`/`stopped`/`route`
    /// do not cross this seam at all. That is the structural half of the same rule
    /// (`InterruptClientTests` asserts the wire half).
    func testEverySentenceTheServerWritesReachesTheBannerVerbatim() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")
        let sentences: [(String, String, ResultDisplay.Tone)] = [
            ("ok", "止めました(生成が止まったのを確認)。", .ok),
            ("ok", "押した時には終わっていました(止めるものは残っていません)。", .ok),
            ("warn", "Escape は押しましたが、まだ止まっていません。画面を見て確かめてください。", .warn),
            ("warn", "止める対象が見当たりませんでした(Escape は押しました)。", .warn),
            ("warn", "止める対象がありませんでした。", .warn),
            ("refused", "別の操作が進行中です", .refused),
        ]

        for (kind, text, tone) in sentences {
            vm.applyInterruptOutcome(.display(ResultDisplay(kind: kind, text: text, keepText: nil)))
            XCTAssertEqual(vm.interruptBanner?.text, text)
            XCTAssertEqual(vm.interruptBanner?.tone, tone, text)
            XCTAssertEqual(vm.interruptBanner?.fromServer, true, text)
        }
    }

    /// Provenance, same control as the send path's. A regression that replaced the
    /// server's sentence with a locally-composed one of the same meaning would pass any
    /// "some banner appeared" check -- and this is the exact path on which that already
    /// happened once, on the server, in the other direction.
    func testPhoneWordedInterruptBannersAreMarkedAsNotComingFromTheServerNegativeControl() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")

        vm.applyInterruptOutcome(.display(ResultDisplay(kind: "ok", text: "止めました", keepText: nil)))
        let fromServer = vm.interruptBanner
        vm.applyInterruptOutcome(.unreachable)
        let fromPhone = vm.interruptBanner

        XCTAssertEqual(fromServer?.fromServer, true)
        XCTAssertEqual(fromPhone?.fromServer, false)
        XCTAssertNotEqual(fromServer?.fromServer, fromPhone?.fromServer)
    }

    /// The one place the phone is allowed to word an interrupt result itself, and the
    /// wording refuses to claim either outcome for the same reason the send path's
    /// does: a request whose response was lost may well have been delivered.
    func testUnreachableInterruptRefusesToClaimEitherOutcome() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")

        vm.applyInterruptOutcome(.unreachable)

        XCTAssertEqual(vm.interruptBanner?.tone, .warn)
        XCTAssertEqual(vm.interruptBanner?.text, ConversationViewModel.interruptUnknownInterim)
        guard case .loaded = vm.phase else { return XCTFail("a transport failure must not tear the screen down") }
    }

    func testUnauthorizedOnInterruptRoutesOutWithoutABanner() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")

        vm.applyInterruptOutcome(.unauthorized)

        XCTAssertEqual(unauthorizedCallCount, 1)
        XCTAssertNil(vm.interruptBanner)
    }

    func testSessionNotFoundOnInterruptTearsTheScreenDown() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")

        vm.applyInterruptOutcome(.sessionNotFound)

        XCTAssertEqual(vm.phase, .notFound)
    }

    /// Same split as the send path's: the conversation is loaded, the poll loop is
    /// live, and the desk may well have received the Escape -- tearing the screen down
    /// would destroy the one view that could show it.
    func testContractViolationOnInterruptIsABannerOverAnIntactScreen() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")
        let violation = ResponseContractViolation(status: 200, code: nil)

        vm.applyInterruptOutcome(.contractViolation(violation))

        guard case .loaded = vm.phase else { return XCTFail("the screen and its poll loop must survive") }
        XCTAssertEqual(vm.interruptBanner?.text, violation.displayText + ConversationViewModel.interruptUnknownInterim)
        XCTAssertFalse(vm.interruptBanner?.text.isEmpty ?? true, "the screen must not go silent on an unreadable response")
        XCTAssertEqual(vm.interruptBanner?.tone, .error)
        XCTAssertEqual(vm.interruptBanner?.fromServer, false, "there was no server wording to carry -- that is the finding")
        XCTAssertEqual(vm.lastContractViolation, violation, "recorded even though it did not become the phase")
    }

    func testCancelledInterruptChangesNothingAtAll() async throws {
        let vm = try await loadedViewModel(screen: "BUSY")
        vm.applyInterruptOutcome(.display(ResultDisplay(kind: "ok", text: "前回", keepText: nil)))
        let bannerBefore = vm.interruptBanner

        vm.applyInterruptOutcome(.cancelled)

        XCTAssertFalse(vm.isInterrupting, "the in-flight flag still has to come down")
        XCTAssertEqual(vm.interruptBanner, bannerBefore, "whoever cancelled owns the outcome")
    }

    // MARK: - Sprint 6 §5-4: reachability on the Conversation screen
    //
    // This screen had no such meter before Sprint 6. `applyPollStep(.unreachable)`
    // returned `true` and touched nothing, so a phone that lost the backend mid-
    // conversation went on showing a perfectly normal, perfectly stale screen with no
    // indication whatsoever.

    func testTwoPollTransportFailuresAreNotEnoughAndTheThirdRaisesTheBanner() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        vm.applyPollStep(unreachableStep())
        XCTAssertFalse(vm.isBackendUnreachable, "1回")
        vm.applyPollStep(unreachableStep())
        XCTAssertFalse(vm.isBackendUnreachable, "2回")
        vm.applyPollStep(unreachableStep())

        XCTAssertTrue(vm.isBackendUnreachable, "3回目で立つ")
        XCTAssertEqual(vm.reachability.consecutiveFailures, 3, "the View prints this number, so it has to be the real one")
    }

    func testOneReadablePollClearsTheReachabilityBanner() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        for _ in 0..<5 { vm.applyPollStep(unreachableStep()) }
        XCTAssertTrue(vm.isBackendUnreachable, "precondition")

        vm.applyPollStep(try readableStep("""
        { "items": [], "cursor": "t.a.2.0", "more": false }
        """))

        XCTAssertFalse(vm.isBackendUnreachable, "§5-4: 「復帰(1回でも成功)したら即座に消す」")
        XCTAssertEqual(vm.reachability.consecutiveFailures, 0)
    }

    /// ★★The non-substitution control, and the single most important assertion in this
    /// section. Spec: 「片方をもう片方で代用しない —— 代用した瞬間、200 で返る壊れた配信が
    /// 『接続は健全』に見える」. Three unreadable polls drive §5-5's meter all the way to
    /// `.stalled` while §5-4's stays at zero, because an unreadable poll is a 200 that
    /// arrived: direct proof of the one thing §5-4 measures.
    ///
    /// Running the substitution in THIS direction is the mistake that looks harmless:
    /// a server shape regression would be reported to the user as a network problem,
    /// sending them to check their signal instead of the deploy.
    func testUnreadablePollsDriveTheOtherMeterAndNeverTheReachabilityOneNegativeControl() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")

        vm.applyPollStep(unreadableStep())
        vm.applyPollStep(unreadableStep())
        vm.applyPollStep(unreadableStep())

        XCTAssertEqual(vm.unreadableStage, .stalled, "§5-5's meter is at its worst stage")
        XCTAssertFalse(vm.isBackendUnreachable, "§5-4's is untouched: a 200 arrived, three times")
        XCTAssertEqual(vm.reachability.consecutiveFailures, 0)
    }

    /// ★And the direction call, stated as its own assertion because "don't count it" and
    /// "count it as a success" are different implementations that only diverge here: an
    /// unreadable poll CLEARS an existing reachability streak. `PollClient` only reaches
    /// `.unreadable` after a 200 has been read off the wire, so the backend demonstrably
    /// answered -- treating that as "no evidence" would leave a banner up that says the
    /// opposite of what was just observed.
    func testAnUnreadablePollClearsAnExistingReachabilityStreak() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.applyPollStep(unreachableStep())
        vm.applyPollStep(unreachableStep())
        vm.applyPollStep(unreachableStep())
        XCTAssertTrue(vm.isBackendUnreachable, "precondition")

        vm.applyPollStep(unreadableStep())

        XCTAssertFalse(vm.isBackendUnreachable, "a 200 that could not be decoded is still a 200")
        XCTAssertEqual(vm.reachability.consecutiveFailures, 0)
        XCTAssertNotEqual(vm.unreadableStage, .normal, "…and §5-5's meter did NOT get cleared by the same event")
    }

    /// The reverse pairing, which is the other half of "two meters, not one": a
    /// transport failure must not reset §5-5's streak either. §3-a: a transport failure
    /// does not touch `UnreadableMeter` in either direction.
    func testAPollTransportFailureDoesNotTouchTheUnreadableMeter() async throws {
        let vm = try await loadedViewModel(screen: "SENDABLE")
        vm.applyPollStep(unreadableStep())
        vm.applyPollStep(unreadableStep())
        let stageBefore = vm.unreadableStage

        vm.applyPollStep(unreachableStep())

        XCTAssertEqual(vm.unreadableStage, stageBefore, "§3-a: neither direction")
        XCTAssertEqual(vm.reachability.consecutiveFailures, 1)
    }

    /// A failed initial load is exactly as much evidence about the backend as a failed
    /// poll is, so it feeds the same meter -- and the phase it sets is a different
    /// statement ("there is no screen yet"), not a substitute for the count.
    func testAnInitialLoadTransportFailureFeedsTheSameMeter() async throws {
        let vm = makeViewModel(client: RecordingClient())

        vm.applyInitial(.failure(.unreachable))
        vm.applyInitial(.failure(.unreachable))
        XCTAssertFalse(vm.isBackendUnreachable)
        vm.applyInitial(.failure(.unreachable))

        XCTAssertTrue(vm.isBackendUnreachable)
        XCTAssertEqual(vm.phase, .unreachable, "the phase and the meter are both set, and neither replaces the other")
    }

    func testASuccessfulInitialLoadClearsTheStreak() async throws {
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [], truncated: false))]
        let vm = makeViewModel(client: client)
        vm.applyInitial(.failure(.unreachable))
        vm.applyInitial(.failure(.unreachable))
        vm.applyInitial(.failure(.unreachable))
        XCTAssertTrue(vm.isBackendUnreachable, "precondition")

        await vm.load()

        XCTAssertFalse(vm.isBackendUnreachable)
        XCTAssertEqual(vm.reachability.consecutiveFailures, 0)
    }

    /// The other `applyInitial` failure arms are NOT transport failures and must not
    /// feed §5-4 -- unlike List, which deliberately counts a superset. Conversation has
    /// a second escalation surface (§5-5 and the contract-violation banner), so here the
    /// meter can stay exactly the set §5-4 defines.
    func testNonTransportLoadFailuresDoNotFeedTheReachabilityMeter() async throws {
        let vm = makeViewModel(client: RecordingClient())

        vm.applyInitial(.failure(.malformedBody))
        vm.applyInitial(.failure(.notFound))
        vm.applyInitial(.failure(.contractViolation(ResponseContractViolation(status: 200, code: nil))))
        vm.applyInitial(.failure(.cancelled))

        XCTAssertEqual(vm.reachability.consecutiveFailures, 0, "§5-4 is 接続不可・タイムアウト・5xx and nothing else")
    }

    // MARK: - DESIGN §2.53: 打ちかけは画面ではなくセッションに属する
    //
    // §2.52 の3つの答えは全部「本文は残してあります」で終わる。特に見分けられなかった
    // 時の文面は Tom に「上の記録と見比べろ」と頼んでいる —— その為に一覧へ戻る動きは
    // 自然に起きるのに、戻って開き直すと ViewModel ごと作り直されて本文が消えていた。
    // §2.52 が落とした「実行できない指示」を、別の実行できない指示に置き換えていた事に
    // なる。ここで固定するのは**何が残ったか**であって、文言ではない。
    //
    // | 誤実装 | 落とす対照 |
    // |---|---|
    // | 復元しない(今まで) | ① |
    // | 打鍵を書き通さず、背面に回った時にまとめて書く | ② |
    // | 送信成功で store を消し忘れる | ③ |
    // | 送信不通でも store を消す | ④ |
    //
    // ★④ が §2.52 の約束を本当にする1本。

    /// ① 前に打ちかけた本文が、作り直した ViewModel に戻る。
    func testADraftFromAnEarlierVisitComesBack() async throws {
        let store = InMemoryDraftStore()
        store.save("止めて", sessionID: "sess-0001")

        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [], truncated: false))]
        let vm = makeViewModel(client: client, draftStore: store)

        XCTAssertEqual(vm.draft, "止めて", "画面を開き直しただけで打ちかけが消える実装を落とす")
    }

    /// ★② 打鍵は其のつど書き通される。
    ///
    /// まとめ書きにすると、送信成功で消した事が書き戻される窓ができる(落ちた後に
    /// 送信済みの本文が composer へ蘇る)。
    func testTypingIsWrittenThroughImmediately() async throws {
        let store = InMemoryDraftStore()
        let client = RecordingClient()
        client.resultQueue = [.success(HistoryResponse(history: [], truncated: false))]
        let vm = makeViewModel(client: client, draftStore: store)

        vm.draft = "止め"
        XCTAssertEqual(store.load(sessionID: "sess-0001"), "止め")

        vm.draft = "止めて"
        XCTAssertEqual(store.load(sessionID: "sess-0001"), "止めて", "★打鍵ごとに書き通す")
    }

    /// ③ 送信が通れば(`keepText:false`)、置き場からも消える。
    func testASuccessfulSendAlsoForgetsTheStoredDraft() async throws {
        let store = InMemoryDraftStore()
        let sendClient = RecordingSendClient()
        sendClient.outcomeQueue = [
            .display(ResultDisplay(kind: "ok", text: "送りました。", keepText: false))
        ]
        let vm = try await loadedViewModel(
            screen: "SENDABLE", sendClient: sendClient, draftStore: store
        )
        vm.draft = "止めて"
        XCTAssertEqual(store.load(sessionID: "sess-0001"), "止めて")

        await vm.send()

        XCTAssertEqual(vm.draft, "")
        XCTAssertNil(store.load(sessionID: "sess-0001"), "消した事も同じ経路で書かれる")
    }

    /// ★④ 送信が不通の時は残る —— §2.52 の「本文は残してあります」が、
    /// 一覧へ戻って開き直しても本当である事。
    ///
    /// ★置き場の中身を見て終わりにしない。この検査の名前は**画面を出た後**と言って
    /// いるので、実際に **2つ目の ViewModel を同じ置き場から作って**確かめる ——
    /// 名前が主張する事を走らせていない検査は、名前の分だけ嘘を持つ(一覧へ戻る =
    /// `ListView.makeConversationViewModel(for:)` が新しい ViewModel を作る、が
    /// この節の病気そのもの)。
    func testAnUnknownSendLeavesTheDraftRecoverableAfterLeavingTheScreen() async throws {
        let store = InMemoryDraftStore()
        let (vm, _) = try await sendUnknownViewModel(
            thenHistory: [.success(HistoryResponse(history: [], truncated: false))],
            draftStore: store
        )
        vm.draft = "止めて"

        await vm.send()

        XCTAssertEqual(vm.draft, "止めて")

        // 一覧へ戻って開き直した所。復元は `init` で起きるので `load()` は要らない
        // —— 履歴を1件も取らないまま打ちかけが戻る事まで含めて測る。
        let reopened = makeViewModel(client: RecordingClient(), draftStore: store)
        XCTAssertEqual(
            reopened.draft, "止めて",
            "★§2.52 は「本文は残してあります」と言う。一覧へ戻って開き直しても本当である事"
        )
    }

    // MARK: - DESIGN §2.54: 要求が飛んでいる間、電話は黙らない
    //
    // 体験側監査 #4 は「不通が既に分かっているなら、送信を先に断れ」と言う。断らない ——
    // 到達性の計器を降ろす口は poll しか無く、外れ方が**片側にしか出ない**(通るのに
    // 断る側にだけ外れる)。構造的に断ると、実際には通る送信が押せなくなる。
    //
    // ただし指摘が指していた痛みは本物で、それは断りの不在ではなく、`isSending` の
    // 最大30秒が **文の1つも無いスピナ**だった事。ここで固定するのはその一文の
    // **有無・出所・寿命・置き場**であって、文言ではない。
    //
    // | 誤実装 | 落とす対照 |
    // |---|---|
    // | 飛んでいる間に文が出ない(直す前の姿) | ① |
    // | 2つの待ちの段が同じ文を出す(段が見分けられない) | ★② |
    // | 秒数を copy に直書きし、timeout が変わっても文が古いまま | ★③ |
    // | 結果が出ても文が残る | ④ |
    // | 飛んでいる間の文を `sendBanner` に入れる | ★⑤ |
    //
    // ★① と ★③ は**片方だけでは鎖にならない**。`writeTimeout` は今ちょうど 30 なので、
    // 文の中に "30" を直書きした実装は①を緑で通る。逆に③だけなら、その関数を画面が
    // 一度も呼ばない実装が緑で通る。2本で初めて「電話が言った上限 = 実際の上限」を縛る。

    /// ① 飛んでいる間、画面に出る文が在る。しかもそれは `sendInFlightText` が作った物。
    func testTheInFlightStageSaysSomethingRatherThanSpinningSilently() async throws {
        let sendClient = ProbingSendClient()
        sendClient.outcome = .display(ResultDisplay(kind: "ok", text: "送りました。", keepText: false))
        let vm = try await loadedViewModel(screen: "SENDABLE", sendClient: sendClient)
        vm.draft = "止めて"

        var observed: String?
        sendClient.whileInFlight = { observed = vm.sendInFlightNotice }

        await vm.send()

        XCTAssertEqual(
            sendClient.probeCount, 1,
            "★覗く窓が開かなければ、この検査は緑になるだけで何も測っていない"
        )
        XCTAssertEqual(
            observed,
            ConversationViewModel.sendInFlightText(timeout: BackendSession.writeTimeout),
            "★飛んでいる間は黙らない。文は実際の timeout から作った物と同一である事"
        )
    }

    /// ★② 続けて起きる2つの待ちの段が、違う事を言う。
    ///
    /// 素直な誤実装は `(isSending || isVerifyingSend) ? …` で、これは**両方の段で同じ
    /// 一文**を出す。画面上は自然に見えるのに、Tom から見ると「まだ送っている」と
    /// 「送り終わったが届いたか分からない」の区別が消える —— §2.52 が作った区別を
    /// §2.54 が塗り潰す形になる。
    func testTheTwoWaitingStagesDoNotSayTheSameThing() async throws {
        let history = ProbingHistoryClient()
        history.resultQueue = [
            .success(HistoryResponse(history: [], truncated: false)), // 最初の load
            .success(HistoryResponse(history: [], truncated: false)), // §2.52 の取り直し
        ]
        let sendClient = ProbingSendClient()
        // 結果が分からない = `applySendOutcome` が true を返し、取り直しの段へ入る。
        sendClient.outcome = .unreachable

        let vm = makeViewModel(client: history, sendClient: sendClient)
        await vm.load()
        vm.draft = "止めて"

        var inFlight: String?
        sendClient.whileInFlight = { inFlight = vm.sendInFlightNotice }

        // 取り直しの最中を覗く。`load()` の**後に**差し込むのは、最初から armed だと
        // 初回の `load()` に当たって、取り直しでない所を測ってしまうから。
        var whileVerifying: (notice: String?, banner: String?)?
        history.whileFetching = { whileVerifying = (vm.sendInFlightNotice, vm.sendBanner?.text) }

        await vm.send()

        XCTAssertEqual(sendClient.probeCount, 1)
        XCTAssertEqual(history.probeCount, 1, "★取り直しが走らなければ、2つ目の段を測っていない")
        XCTAssertNotNil(inFlight)
        XCTAssertNotEqual(
            inFlight, ConversationViewModel.sendUnknownInterim,
            "飛んでいる間と、飛び終わって取り直している間は、違う事を言う"
        )
        XCTAssertNil(
            whileVerifying?.notice,
            "★取り直しの段では飛んでいる間の文は消えている(`isSending` にだけ張り付く)"
        )
        XCTAssertEqual(
            whileVerifying?.banner, ConversationViewModel.sendUnknownInterim,
            "その段で出ているのは §2.52 の途中経過の文"
        )
    }

    /// ★③ 文の中の秒数は、渡された timeout から作られている。
    ///
    /// 直書きでも①は緑で通る(`writeTimeout` が今ちょうど 30 だから)。ここが
    /// 「言った上限が実際の上限である」を本当にする1本。
    func testTheInFlightSentenceIsBuiltFromTheRealTimeout() {
        let thirty = ConversationViewModel.sendInFlightText(timeout: 30)
        let fortyFive = ConversationViewModel.sendInFlightText(timeout: 45)

        XCTAssertTrue(thirty.contains("30"), "受け取った秒数が文に出る")
        XCTAssertTrue(fortyFive.contains("45"), "★別の値を渡せば文の数字も変わる")
        XCTAssertFalse(fortyFive.contains("30"), "★直書きの 30 が居残っていない事")
    }

    /// ④ 答えが出た瞬間に、待ちの文は消える。
    func testTheInFlightLineIsGoneOnceTheOutcomeIsKnown() async throws {
        let sendClient = ProbingSendClient()
        sendClient.outcome = .display(ResultDisplay(kind: "ok", text: "送りました。", keepText: false))
        let vm = try await loadedViewModel(screen: "SENDABLE", sendClient: sendClient)
        vm.draft = "止めて"

        var sawItWhileInFlight = false
        sendClient.whileInFlight = { sawItWhileInFlight = vm.sendInFlightNotice != nil }

        await vm.send()

        XCTAssertTrue(
            sawItWhileInFlight,
            "出ていなかった物が消えても、この検査は何も言っていない"
        )
        XCTAssertNil(vm.sendInFlightNotice, "答えが出たら待ちの文は残さない")
    }

    /// ★⑤ 飛んでいる間の文は `sendBanner` を占領しない。
    ///
    /// `send()` 入口の `sendBanner = nil` は**意図**で、理由も其処に書いてある ——
    /// 前回の「送りました」が飛んでいる送信の下に残ると、古い成功が今回の結果として
    /// 読まれる。この検査はその意図を機械に写す1本。これが無いと次に読む人が
    /// 「行を1本増やすより既存の帯に入れる方が簡単」で穴を開け直せる。
    ///
    /// 色の理由も同じ所を指す: `ResultDisplay.Tone` は ok / refused / error / warn の
    /// 4つで**中立が無い**。まだ何も起きていない状態を warn で塗ると、warn という色が
    /// 「気にしなくていい事」を指し始める —— 一番使われる色を鈍らせる取引になる。
    func testTheInFlightLineDoesNotOccupyTheSendBanner() async throws {
        let sendClient = ProbingSendClient()
        sendClient.outcome = .display(ResultDisplay(kind: "ok", text: "送りました。", keepText: false))
        let vm = try await loadedViewModel(screen: "SENDABLE", sendClient: sendClient)

        // 前の送信の答えを画面に置いてから、次の送信を始める。
        vm.applySendOutcome(.display(ResultDisplay(kind: "ok", text: "送りました。", keepText: false)), sentText: "")
        XCTAssertNotNil(vm.sendBanner, "前の答えが出ている所から始める")

        vm.draft = "止めて"
        var bannerWhileInFlight: SendBanner?
        sendClient.whileInFlight = { bannerWhileInFlight = vm.sendBanner }

        await vm.send()

        XCTAssertEqual(sendClient.probeCount, 1, "★覗く窓が開かなければ何も測っていない")
        XCTAssertNil(
            bannerWhileInFlight,
            "★飛んでいる間の帯は空。前回の「送りました」も、今回の途中経過も、其処には置かない"
        )
    }

    // MARK: - DESIGN §2.56: 残る2操作の「飛んでいる間」(S8-6)
    //
    // §2.54 は送信だけを直した。残る2つを測った結果が非対称の3段階:
    //
    // | 操作 | 飛んでいる間 | 結果不明の取り直しの間 |
    // |---|---|---|
    // | 送信 | スピナ + 文 | 文 + ボタン伏せ |
    // | 割り込み | スピナ、**文なし** | 文 |
    // | 打鍵 | **スピナも文も無し** | 文 |
    //
    // ★**右の列は直さない。**この節は一度「割り込みと打鍵は取り直しの間も無言」と
    // 書き、`applyInterruptOutcome` の先頭と `.display` 枝しか読まずに結論を出していた。
    // 実際は `.unreachable` / `.contractViolation` の両方が文を置いている。
    // 足す物が無い所に足しに行くのは S8-5 で踏んだばかりの穴なので、記録として残す。
    //
    // ★秒数の前提も間違っていた: 割り込みと打鍵は `interactiveTimeout`(8秒)ではなく
    // 送信と同じ `writeTimeout`(30秒)。8秒だと「親切か鬱陶しいか」を測る必要が在ったが、
    // 30秒なら §2.54 の裁定がそのまま効く = 判断ではなく適用。

    /// ① 割り込みが飛んでいる間、文が出る。しかも `interruptInFlightText` が作った物。
    func testTheInterruptInFlightStageSaysSomethingRatherThanSpinningSilently() async throws {
        let interrupter = RecordingInterruptClient()
        interrupter.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "止めました。", keepText: nil))]
        let vm = try await loadedViewModel(screen: "BUSY", interruptClient: interrupter)

        var observed: String?
        interrupter.whileInFlight = { observed = vm.interruptInFlightNotice }

        await vm.interrupt()

        XCTAssertEqual(
            interrupter.probeCount, 1,
            "★覗く窓が開かなければ、この検査は緑になるだけで何も測っていない"
        )
        XCTAssertEqual(
            observed,
            ConversationViewModel.interruptInFlightText(timeout: BackendSession.writeTimeout),
            "★割り込みも飛んでいる間は黙らない。文は実際の timeout から作った物と同一である事"
        )
    }

    /// ① 打鍵側の同じ1本。
    func testTheChoiceInFlightStageSaysSomethingRatherThanGoingGrey() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [
            ChoiceAttempt(
                outcome: .display(ResultDisplay(kind: "ok", text: "押しました。", keepText: nil)),
                serverDigest: "d-aaa"
            )
        ]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON(digest: "d-aaa")
        )

        var observed: String?
        choiceClient.whileInFlight = { observed = vm.choiceInFlightNotice }

        await vm.choose(key: "2")

        XCTAssertEqual(choiceClient.probeCount, 1, "★覗く窓が開かなければ何も測っていない")
        XCTAssertEqual(
            observed,
            ConversationViewModel.choiceInFlightText(timeout: BackendSession.writeTimeout),
            "★打鍵は直す前、スピナすら無く灰色になるだけだった"
        )
    }

    /// ★② 3操作が違う事を言う。
    ///
    /// 素直な誤実装は `sendInFlightText` を3箇所から呼ぶ事で、それは①を3本とも緑で通す。
    /// この画面には帯が3本並ぶので、生き残った一文がどの操作の物か読み手が判別できなく
    /// なる —— `interruptBanner` / `choiceBanner` を別々の帯にした理由と同じ穴。
    func testTheThreeOperationsDoNotShareOneInFlightSentence() {
        let t = BackendSession.writeTimeout
        let sentences = [
            ConversationViewModel.sendInFlightText(timeout: t),
            ConversationViewModel.interruptInFlightText(timeout: t),
            ConversationViewModel.choiceInFlightText(timeout: t),
        ]

        XCTAssertEqual(Set(sentences).count, 3, "★3操作 3文。どれか2つが同じなら操作が見分けられない")

        // そして「飛んでいる間」と「飛び終わったが分からない間」も、操作ごとに別。
        XCTAssertNotEqual(sentences[1], ConversationViewModel.interruptUnknownInterim)
        XCTAssertNotEqual(sentences[2], ConversationViewModel.choiceUnknownInterim)
    }

    /// ★③ 秒数は渡された timeout から作られている(直書きではない)。
    ///
    /// これが無いと、`writeTimeout` が今ちょうど 30 なので "30" を直書きした実装が
    /// ①を緑で通る。電話が言った上限と実際の上限が食い違う形を塞ぐ1本。
    func testTheTwoNewInFlightSentencesAreBuiltFromTheRealTimeout() {
        for make in [ConversationViewModel.interruptInFlightText,
                     ConversationViewModel.choiceInFlightText] {
            XCTAssertTrue(make(30).contains("30"), "受け取った秒数が文に出る")
            XCTAssertTrue(make(45).contains("45"), "★別の値を渡せば文の数字も変わる")
            XCTAssertFalse(make(45).contains("30"), "★直書きの 30 が居残っていない事")
        }
    }

    /// ④ 答えが出たら、待ちの文は消える。残れば「答えの顔をした待ち」になる。
    func testTheInterruptInFlightLineIsGoneOnceTheOutcomeIsKnown() async throws {
        let interrupter = RecordingInterruptClient()
        interrupter.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "止めました。", keepText: nil))]
        let vm = try await loadedViewModel(screen: "BUSY", interruptClient: interrupter)

        var sawItWhileInFlight = false
        interrupter.whileInFlight = { sawItWhileInFlight = vm.interruptInFlightNotice != nil }

        await vm.interrupt()

        XCTAssertTrue(sawItWhileInFlight, "出ていなかった物が消えても、この検査は何も言っていない")
        XCTAssertNil(vm.interruptInFlightNotice)
    }

    /// ④ 打鍵側。★取り直しへ入る枝(結果不明)でも消える事を測る —— こちらの方が
    /// 危ない。`applyChoiceAttempt` が `inFlightChoiceKey` を倒し忘れると、
    /// §2.52 の「取り直しています」の上に「送っています」が重なって残る。
    func testTheChoiceInFlightLineIsGoneEvenOnThePathThatReportsNothing() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [ChoiceAttempt(outcome: .unreachable, serverDigest: nil)]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON()
        )

        var sawItWhileInFlight = false
        choiceClient.whileInFlight = { sawItWhileInFlight = vm.choiceInFlightNotice != nil }

        await vm.choose(key: "1")

        XCTAssertTrue(sawItWhileInFlight, "覗いた時に出ていなければ、消えた事に意味は無い")
        XCTAssertNil(vm.choiceInFlightNotice, "★結果が分からない枝でも、飛んでいる文は残さない")
        XCTAssertNotNil(vm.choiceBanner, "代わりに出るのは §2.52 の途中経過(既に在った物)")
    }

    /// ★⑤ 待ちの文は答えの帯を占領しない。§2.54 の⑤を残り2操作へ。
    func testTheNewInFlightLinesDoNotOccupyTheAnswerBanners() async throws {
        let interrupter = RecordingInterruptClient()
        interrupter.outcomeQueue = [.display(ResultDisplay(kind: "ok", text: "止めました。", keepText: nil))]
        let vm = try await loadedViewModel(screen: "BUSY", interruptClient: interrupter)

        // 前の割り込みの答えを画面に置いてから、次を始める。
        vm.applyInterruptOutcome(.display(ResultDisplay(kind: "ok", text: "止めました。", keepText: nil)))
        XCTAssertNotNil(vm.interruptBanner, "前の答えが出ている所から始める")

        var bannerWhileInFlight: SendBanner?
        interrupter.whileInFlight = { bannerWhileInFlight = vm.interruptBanner }

        await vm.interrupt()

        XCTAssertEqual(interrupter.probeCount, 1, "★覗く窓が開かなければ何も測っていない")
        XCTAssertNil(bannerWhileInFlight, "★飛んでいる間の帯は空")
    }

    /// ★⑥ 飛んでいるのが**どの鍵か**を持っている。
    ///
    /// 文だけでは足りない理由: 打鍵は3操作の中で唯一、同時に複数の的が画面に並ぶ。
    /// 「押しています」だけだと、2つ並んだボタンのどちらを押したのかが消える。
    func testThePressedKeyIsWhatIsRememberedWhileItIsInFlight() async throws {
        let choiceClient = RecordingChoiceClient()
        choiceClient.attemptQueue = [
            ChoiceAttempt(
                outcome: .display(ResultDisplay(kind: "ok", text: "押しました。", keepText: nil)),
                serverDigest: "d-aaa"
            )
        ]
        let vm = try await loadedViewModel(
            screen: "CHOICE", choiceClient: choiceClient, choiceJSON: benignChoiceJSON(digest: "d-aaa")
        )

        var keyWhileInFlight: String?
        var derivedWhileInFlight: Bool?
        choiceClient.whileInFlight = {
            keyWhileInFlight = vm.inFlightChoiceKey
            derivedWhileInFlight = vm.isChoosing
        }

        await vm.choose(key: "2")

        XCTAssertEqual(choiceClient.probeCount, 1)
        XCTAssertEqual(keyWhileInFlight, "2", "★押した鍵そのもの。`true` ではなく `\"2\"`")
        XCTAssertEqual(derivedWhileInFlight, true, "`isChoosing` は同じ一つの真実の読み方")
        XCTAssertNil(vm.inFlightChoiceKey, "答えが出たら忘れる")
        XCTAssertFalse(vm.isChoosing, "★導出なので、二重に倒す必要が無い = 食い違えない")
    }
}
