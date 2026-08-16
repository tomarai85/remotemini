import XCTest
@testable import RemoteMini

/// `ListViewModel` state-machine tests (Sprint 2 brief §5-a-4). Driven entirely
/// through `apply(_:)`, not `refresh()` -- see that method's own doc comment for why
/// the transition logic is split out: a scripted sequence of `Result`s exercises the
/// failure counter and every branch of §4/§4-a deterministically, with no real `Task`
/// cancellation race involved.
@MainActor
final class ListViewModelTests: XCTestCase {
    /// Never actually called by these tests (no `refresh()` invocation reaches the
    /// network) -- present only to satisfy the initializer.
    private struct UnusedClient: SessionsListing {
        func fetch(baseURL: URL, apiKey: String) async -> Result<SessionsResponse, SessionsFetchError> {
            .failure(.unreachable)
        }
    }

    private var unauthorizedCallCount = 0

    private func makeViewModel() -> ListViewModel {
        unauthorizedCallCount = 0
        return ListViewModel(
            client: UnusedClient(),
            baseURL: URL(string: "https://unit-test.invalid")!,
            apiKey: "unit-test-fixture-key-not-real",
            onUnauthorized: { [weak self] in self?.unauthorizedCallCount += 1 },
            now: { 1_000_000 }
        )
    }

    private func response(sessions: [SessionRow], paneFault: SessionsResponse.PaneFault? = nil, scan: String = "scan-line") -> SessionsResponse {
        SessionsResponse(sessions: sessions, display: .init(scan: scan), paneFault: paneFault)
    }

    private func row(_ id: String) -> SessionRow {
        SessionRow(
            id: id,
            title: "t-\(id)",
            updatedAt: "2026-08-05T09:00:00.000Z",
            fromRegistryOnly: nil,
            display: .init(route: .init(kind: .tmux, short: "s", text: "t", screen: ""), subtitle: "s"),
            machine: nil
        )
    }

    // MARK: - Brief §4's four branches

    func testSuccessWithSessionsShowsListWithScanLine() {
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")], scan: "12本のうち 12本を読み")))

        guard case .list(let sessions, let scanLine) = vm.phase else {
            return XCTFail("expected .list, got \(vm.phase)")
        }
        XCTAssertEqual(sessions.map(\.id), ["a"])
        XCTAssertEqual(scanLine, "12本のうち 12本を読み")
    }

    func testSuccessWithEmptySessionsAndNoPaneFaultShowsEmpty() {
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [])))

        guard case .empty = vm.phase else {
            return XCTFail("expected .empty, got \(vm.phase)")
        }
    }

    func testPaneFaultShowsPaneFaultEvenWhenSessionsEmptyNeverStackedWithEmpty() {
        // Brief §4: `paneFault` is checked FIRST -- never render "会話がありません"
        // underneath a paneFault banner, even when `sessions` is also empty.
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [], paneFault: .init(
            reason: "panes-unreadable",
            detail: "detail-never-drawn",
            display: .init(headline: "見出し", body: "本文")
        ))))

        guard case .paneFault(let headline, let body, let sessions, _) = vm.phase else {
            return XCTFail("expected .paneFault, got \(vm.phase)")
        }
        XCTAssertEqual(headline, "見出し")
        XCTAssertEqual(body, "本文")
        XCTAssertTrue(sessions.isEmpty)
    }

    /// サーバが説明を送ってこない場合 —— 電話の方が新しい時(2026-08-08 / 監査 S8-22)。
    ///
    /// 相に載るのは**読める文**でなければならない。以前は相が `reason` / `detail` を
    /// そのまま運んでいて、`ListView` が見出しに `panes-unreadable`、本文に生の JS
    /// エラー文を描いていた。相の型から生の値を外したので、描く側に選択肢が無い ——
    /// 此処が測るのは、その落とし所が**説明の代わりに空文字を配らない**事。
    func testPaneFaultWithoutServerCopyFallsBackToReadableTextNotTheRawFields() {
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [], paneFault: .init(
            reason: "panes-unreadable",
            detail: "pane 'secret-project' の出力が壊れています"
        ))))

        guard case .paneFault(let headline, let body, _, _) = vm.phase else {
            return XCTFail("expected .paneFault, got \(vm.phase)")
        }
        // 錨(此処が無いと、空文字を配る実装でも下の2つを満たせてしまう)。
        XCTAssertTrue(headline.contains("一覧"), "落とし所の見出しが文になっていない: \(headline)")
        XCTAssertTrue(body.contains("机で確認"), "落とし所の本文が文になっていない: \(body)")
        XCTAssertFalse(headline.contains("panes-unreadable"), "生の理由コードを見出しに据えている: \(headline)")
        XCTAssertFalse(body.contains("secret-project"), "生の detail を本文に載せている: \(body)")
    }

    func testPaneFaultWithSessionsShowsPaneFaultBannerAboveTheList() {
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")], paneFault: .init(reason: "r", detail: "d"))))

        guard case .paneFault(_, _, let sessions, _) = vm.phase else {
            return XCTFail("expected .paneFault, got \(vm.phase)")
        }
        XCTAssertEqual(sessions.map(\.id), ["a"])
    }

    // MARK: - Brief §4-a: consecutive-failure counter, prior list present

    func testFirstFailureWithPriorListStaysRetryableWithThePriorList() {
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")])))
        vm.apply(.failure(.unreachable))

        guard case .retryable(let prior) = vm.phase else {
            return XCTFail("expected .retryable, got \(vm.phase)")
        }
        XCTAssertEqual(prior?.map(\.id), ["a"], "1-2 failures with a prior list: keep it, no red banner")
    }

    func testSecondFailureWithPriorListStillRetryableNotUnreachable() {
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")])))
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.unreachable))

        guard case .retryable(let prior) = vm.phase else {
            return XCTFail("expected .retryable at 2 failures, got \(vm.phase)")
        }
        XCTAssertEqual(prior?.map(\.id), ["a"])
    }

    func testThirdConsecutiveFailureWithPriorListShowsUnreachableGrayedOut() {
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")])))
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.unreachable))

        guard case .unreachable(let prior) = vm.phase else {
            return XCTFail("expected .unreachable at 3 failures, got \(vm.phase)")
        }
        XCTAssertEqual(prior?.map(\.id), ["a"], "brief §4-a: never replace the existing list with an empty one")
    }

    func testSuccessAfterFailuresResetsTheCounterToZero() {
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")])))
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.unreachable))
        vm.apply(.success(response(sessions: [row("b")]))) // any 200 resets, regardless of paneFault
        vm.apply(.failure(.unreachable))

        guard case .retryable(let prior) = vm.phase else {
            return XCTFail("expected .retryable (counter reset to 1, not 3), got \(vm.phase)")
        }
        XCTAssertEqual(prior?.map(\.id), ["b"])
    }

    func testPaneFaultWith200ResetsTheCounterToZero() {
        // Brief §4-a / Codex finding #4: a 200 with `paneFault` is "arrived," not
        // "unreachable" -- the counter must reset even though the response also
        // carries a fault.
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")])))
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.unreachable))
        vm.apply(.success(response(sessions: [row("a")], paneFault: .init(reason: "r", detail: "d"))))
        vm.apply(.failure(.unreachable))

        guard case .retryable = vm.phase else {
            return XCTFail("expected .retryable (counter reset by the paneFault 200), got \(vm.phase)")
        }
    }

    // MARK: - Brief §4-a: the third, distinct state -- first fetch ever, no prior list

    func testFirstFailureWithNoPriorListShowsRetryableWithNilPriorSessionsNotEmpty() {
        let vm = makeViewModel()
        vm.apply(.failure(.unreachable))

        guard case .retryable(let prior) = vm.phase else {
            return XCTFail("expected .retryable, got \(vm.phase)")
        }
        XCTAssertNil(prior, "this is the third, distinct state -- not .empty, not a bare spinner")
    }

    func testSecondFailureWithNoPriorListStillRetryableWithNilPriorSessions() {
        let vm = makeViewModel()
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.unreachable))

        guard case .retryable(let prior) = vm.phase else {
            return XCTFail("expected .retryable, got \(vm.phase)")
        }
        XCTAssertNil(prior)
    }

    func testThirdFailureWithNoPriorListShowsUnreachableWithNilPriorSessions() {
        let vm = makeViewModel()
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.unreachable))

        guard case .unreachable(let prior) = vm.phase else {
            return XCTFail("expected .unreachable, got \(vm.phase)")
        }
        XCTAssertNil(prior, "no prior list exists, so grayout is impossible -- the banner alone")
    }

    // MARK: - Unauthorized and cancellation are not counted at all

    func testUnauthorizedInvokesCallbackAndDoesNotTouchThePhaseOrCounter() {
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")])))
        vm.apply(.failure(.unauthorized))

        XCTAssertEqual(unauthorizedCallCount, 1)
        guard case .list(let sessions, _) = vm.phase else {
            return XCTFail("a 401 must not replace .list with any failure phase, got \(vm.phase)")
        }
        XCTAssertEqual(sessions.map(\.id), ["a"])
    }

    func testMalformedBodyCountsAsAFailureLikeUnreachable() {
        // Brief's judgment call: `.malformedBody` is grouped with `.unreachable` for
        // counting purposes -- both mean "the fetch did not produce usable data."
        let vm = makeViewModel()
        vm.apply(.failure(.malformedBody))
        vm.apply(.failure(.malformedBody))
        vm.apply(.failure(.malformedBody))

        guard case .unreachable = vm.phase else {
            return XCTFail("expected .unreachable after 3 malformedBody failures, got \(vm.phase)")
        }
    }

    // MARK: - Negative controls (brief §5-a-4)

    func testOneFailureWithPriorListStaysRetryableNegativeControlForThresholdLoweredToOne() {
        // A mutant that lowered `unreachableThreshold` to 1 would jump straight to
        // `.unreachable` on the very first failure. The real threshold is 3, so this
        // must still be `.retryable`.
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")])))
        vm.apply(.failure(.unreachable))

        guard case .retryable = vm.phase else {
            return XCTFail("threshold=1 mutant detected: got \(vm.phase) after only 1 failure")
        }
    }

    func testThreeCancellationsDoNotAdvanceTheCounterNegativeControlForMergedCatch() {
        // The Codex-found defect (brief §4-a/§8): a naive `catch` that treats
        // `.cancelled` the same as `.unreachable` would make 3 rapid, cancelled
        // pull-to-refreshes on a perfectly healthy server look like 3 real failures
        // and flip to `.unreachable`. Real behavior: cancellation carries no
        // information about the backend and must not move the counter at all.
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")])))
        vm.apply(.failure(.cancelled))
        vm.apply(.failure(.cancelled))
        vm.apply(.failure(.cancelled))

        guard case .list(let sessions, _) = vm.phase else {
            return XCTFail("merged-catch mutant detected: got \(vm.phase) after 3 cancellations on a healthy server")
        }
        XCTAssertEqual(sessions.map(\.id), ["a"])
    }

    func testCancellationsInterleavedWithRealFailuresOnlyCountTheRealOnes() {
        // Same defect, interleaved: 2 real failures + 2 cancellations must still read
        // as 2 (not 4), staying under the threshold of 3.
        let vm = makeViewModel()
        vm.apply(.success(response(sessions: [row("a")])))
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.cancelled))
        vm.apply(.failure(.unreachable))
        vm.apply(.failure(.cancelled))

        guard case .retryable = vm.phase else {
            return XCTFail("merged-catch mutant detected: got \(vm.phase) after 2 real failures + 2 cancellations")
        }
    }
}
